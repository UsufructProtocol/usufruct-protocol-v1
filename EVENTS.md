# Usufruct — Event Observability

Usufruct is fully observable through its event stream. Every state transition emits an event; no information needed for off-chain analytics requires querying on-chain objects. This document explains the indexing strategy, the event catalogue, canonical analytical queries enabled by the high configuration space, and the boundary where on-chain queries are unavoidable.

## 1. Star Schema on `escrow_id`

Every event in the protocol carries `escrow_id` as its **first field**, with one deliberate exception: `GovernanceCapBurned` has no `escrow_id` because a `GovernanceCap` may govern many escrows and the burn operation is not tied to any specific one. In all other events `escrow_id` is the root foreign key of a SQL star schema: each event type is a fact table, and `escrow_id` is the join key across all of them.

```
                    PolicyEnsembleRegistered ──┐
         UsufructCapMinted / UsufructCapBurned ────┤
                          GovernanceCapMinted  ────┤
                              AssetIntegrated ─┤
                               RentStarted ────┼──── escrow_id (root FK)
                  BidPlaced / BidSuperseded ───┤
                         HandoverCompleted ────┤
   Active/PendingUsufructuaryRefundAddressUpdated ───┤
                              TenureExpired ───┤
            EarningsMessagePosted / EarningsMessageCollected ─┤
               FeeMessagePosted / FeeMessageCollected    ────┤
                              AssetRetired ────┤
                              AssetClaimed ────┘
```

Two secondary join keys appear in multiple events and act as dimension PKs:

- **`usufruct_cap_id`** — links `UsufructCapMinted → RentStarted → BidPlaced → BidSuperseded → HandoverCompleted → TenureExpired → UsufructCapBurned`, plus `Active/PendingUsufructuaryRefundAddressUpdated` for any seat whose refund address was redirected. The complete history of a single tenancy is reconstructable by filtering on this key.
- **`governance_cap_id`** — links `GovernanceCapMinted → AssetIntegrated → AssetClaimed → GovernanceCapBurned`. One cap may govern many escrows (portfolio), so this key fans out to every escrow integrated under it.
- **`earnings_inbox_id`** — links the income stream: `AssetIntegrated → EarningsMessagePosted → EarningsMessageCollected`. Born paired with the cap at `integrate` but independently transferable, so it is its own dimension: filtering on it reconstructs the full post/collect history of one inbox, across whatever fleet of escrows posts to it.

All other fields (addresses, amounts, timestamps, policy strings) are attributes of the fact rows — they never require a secondary lookup.

### The chain holds no registry — the event graph *is* the index

These join keys are not redundant with on-chain state — they are the *only* complete index of the protocol's cross-object relationships. By design the chain stores no registry: a `GovernanceCap` does not list the escrows it governs (it is a pure governance token, validated seat-side), escrows are independent shared objects, and nothing iterates a fleet. That omission is precisely what gives the protocol O(1) operations and zero gas debt — there is no growing list to update or contend on. The relationships did not disappear; they live in the event log. Replaying `AssetIntegrated` — which carries `governance_cap_id`, `earnings_inbox_id`, and `escrow_id` in one row — reconstructs the entire governance topology (which cap governs which fleet, which inbox each escrow feeds) without a single on-chain read.

This is not theoretical. A v1.4.1 testnet teardown reconstructed all 516 escrows a single governor had ever integrated — each paired with its governing cap — purely by replaying the `AssetIntegrated` stream, precisely *because* the cap cannot point back to them on-chain. The reconstruction is a working reference for the pattern: `getIntegratedEscrows` in [`profiling/setup/cleanup.ts`](profiling/setup/cleanup.ts) pages the `AssetIntegrated` events (`queryEvents` on `MoveEventType`), filters by `governor_address`, and emits `(escrow_id, governance_cap_id)` pairs — exactly the indexing step a marketplace or governor dashboard would run, here used to drive teardown. Minimal execution state (which scales) and a complete relational graph (which is observable) are not a trade-off here: the chain runs the machine, the events are the database.

## 2. Event Catalogue

Events are grouped by lifecycle phase. All amounts are in MIST (u64). All timestamps are epoch milliseconds (u64).

**Field ordering conventions (BCS wire format):**

1. `escrow_id` — always first (root FK; exception: `GovernanceCapBurned` has none).
2. `asset_type`, `coin_type` — immediately after `escrow_id` in every event that carries them. Financial and operational events carry both; cap and policy events carry neither. This positions both partition keys before any variable-length identity or monetary field, so an indexer can filter by asset or coin type without decoding the rest of the struct.
3. Everything else — identity blocks (cap IDs + addresses), monetary fields, schedule fields, metadata — in semantic groups.

**Timestamp conventions:**

- `timestamp_ms` — the wall-clock instant the event fired (always `now` or the boundary timestamp of a lazy transition).
- `*_phase_start_ms` (e.g. `active_phase_start_ms`, `departing_phase_start_ms`) — a *stored historical* timestamp retrieved from protocol state, representing when a past phase began. Always distinct in time from the event's own `timestamp_ms`.

### Asset lifecycle

| Event | Trigger | Key fields |
|-------|---------|------------|
| `AssetIntegrated` | Governor calls `integrate` / `integrate_into_portfolio` | `escrow_id`, `asset_type`, `coin_type`, `governance_cap_id`, `governor_address`, `asset_id`, `fee_inbox_id`, `earnings_inbox_id`, `retire_commitment_unlock_at_ms`, `ensemble_commitment_unlock_at_ms`, `timestamp_ms` |
| `AssetRetired` | Asset leaves protocol (retire path or claim) | `escrow_id`, `asset_type`, `coin_type`, `timestamp_ms` |
| `AssetClaimed` | Governor reclaims asset after retirement | `escrow_id`, `asset_type`, `coin_type`, `governance_cap_id`, `governor_address`, `timestamp_ms` |
| `RetireFlagSet` | Governor signals intent to retire | `escrow_id`, `asset_type`, `coin_type`, `governance_cap_id`, `governor_address`, `timestamp_ms` |

`AssetIntegrated` now includes `retire_commitment_unlock_at_ms` and `ensemble_commitment_unlock_at_ms` — the governance commitment deadlines in effect at integration time. These are the unlock timestamps computed from the initial `RetireCommitmentPolicy` and `EnsembleCommitmentPolicy`, anchored at `timestamp_ms`. Subsequent extensions emit `RetireCommitmentExtended` / `EnsembleCommitmentExtended`.

### Policy configuration

| Event | Trigger | Key fields |
|-------|---------|------------|
| `PolicyEnsembleRegistered` | First `integrate` call | `escrow_id`, `timestamp_ms`, full 23-field policy snapshot |
| `EnsembleUpdated` | Policy change applied immediately (escrow was Idle) | Same 23-field snapshot |
| `EnsembleUpdateScheduled` | Policy change queued (escrow was active) | Same 23-field snapshot |
| `CycleParamsResolved` | Engine adopts new operating parameters | `escrow_id`, `floor_mist`, `ceiling_ms`, `handover_ms`, `descent_ms`, `timestamp_ms` |

`CycleParamsResolved` carries the *resolved* parameters the engine actually operates on — the floor price, tenure ceiling, handover (protection) window, and descent window — as opposed to the policy snapshot, which carries the *inputs*. They are a pure function of the active ensemble, so an indexer could recompute them by joining the latest snapshot and replaying the resolution; emitting them directly avoids that async temporal join and pins the values the engine used as ground truth. It fires only when a new ensemble is adopted, **not** on the no-op recompute at an auction expiry with no pending ensemble (the parameters are unchanged there).

The 23 fields include: `rest_price_policy`, `rest_price`, `tenure_duration_policy`, `tenure_duration_ms`, `tenure_extend_policy`, `handover_policy`, `handover_floor_ms`, `auction_window_policy`, `auction_window_ceiling_ms`, `credit_shape_policy`, `credit_alpha_num/den/abs/neg`, `auction_shape_policy`, `auction_alpha_num/den/abs/neg`, `price_escalation_policy`, `price_escalation_delta`, `price_escalation_bps`.

Policy events carry the complete configuration snapshot at the moment of the event, not a diff. This means any point-in-time policy reconstruction requires only the most recent `PolicyEnsembleRegistered` or `EnsembleUpdated` event before a given timestamp — no event chain needed.

### Tenancy

| Event | Trigger | Key fields |
|-------|---------|------------|
| `RentStarted` | Usufructuary enters Occupied state | `escrow_id`, `asset_type`, `coin_type`, `usufruct_cap_id`, `usufructuary_address`, `price_paid`, `floor_price`, `committed_tenures`, `timestamp_ms`, `ceiling_total_ms`, `handover_total_ms` |
| `TenureExpired` | Tenure ceiling reached without handover | `escrow_id`, `asset_type`, `coin_type`, `usufruct_cap_id`, `usufructuary_address`, `phase_start_ms`, `governor_share`, `protocol_fee`, `last_acquisition_price`, `timestamp_ms` |
| `RetireCommitmentExtended` | Deferred retire-commitment deadline extended | `escrow_id`, `asset_type`, `coin_type`, `commitment_policy`, `commitment_floor_ms`, `new_unlock_at_ms`, `timestamp_ms` |
| `EnsembleCommitmentExtended` | Deferred ensemble-commitment deadline extended | `escrow_id`, `asset_type`, `coin_type`, `commitment_policy`, `commitment_floor_ms`, `new_unlock_at_ms`, `timestamp_ms` |
| `AssetBorrowed` | Usufructuary takes physical custody of asset | `escrow_id`, `asset_type`, `coin_type`, `usufruct_cap_id`, `usufructuary_address`, `timestamp_ms` |
| `AssetReturned` | Usufructuary returns physical custody | `escrow_id`, `asset_type`, `coin_type`, `usufruct_cap_id`, `usufructuary_address` |
| `ActiveUsufructuaryRefundAddressUpdated` | Active (Occupied) usufructuary redirects refund address | `escrow_id`, `asset_type`, `coin_type`, `usufruct_cap_id`, `old_address`, `active_address`, `timestamp_ms` |
| `PendingUsufructuaryRefundAddressUpdated` | Pending bidder (Demand) redirects refund address | `escrow_id`, `asset_type`, `coin_type`, `usufruct_cap_id`, `old_address`, `active_address`, `timestamp_ms` |

In `RentStarted`, `timestamp_ms` is the instant the tenant enters Occupied state — equivalently, the start of the tenure phase. The schedule fields describe the incoming usufructuary's terms: `committed_tenures` is the number of tenures paid for; `ceiling_total_ms` is the total tenure duration (projected expiry = `timestamp_ms + ceiling_total_ms`); `handover_total_ms` is the incumbent's protection window.

### Auction and handover

| Event | Trigger | Key fields |
|-------|---------|------------|
| `BidPlaced` | Incoming usufructuary outbids active usufructuary | `escrow_id`, `asset_type`, `coin_type`, `active_usufruct_cap_id`, `active_usufractuary_address`, `active_stake_balance`, `active_phase_start_ms`, `pending_usufruct_cap_id`, `pending_usufractuary_address`, `pending_bid_amount`, `pending_ceiling_total_ms`, `pending_handover_total_ms`, `floor_price`, `handover_countdown_expiry`, `committed_tenures`, `timestamp_ms` |
| `BidSuperseded` | A higher bid supersedes the standing pending bid | `escrow_id`, `asset_type`, `coin_type`, `active_usufract_cap_id`, `active_usufractuary_address`, `active_stake_balance`, `active_phase_start_ms`, `displaced_usufract_cap_id`, `displaced_bidder_address`, `refunded_amount`, `pending_usufract_cap_id`, `pending_bidder_address`, `pending_bid_amount`, `pending_ceiling_total_ms`, `pending_handover_total_ms`, `floor_price`, `handover_countdown_expiry`, `committed_tenures`, `timestamp_ms` |
| `HandoverCompleted` | Countdown expires; the pending bid takes over | `escrow_id`, `asset_type`, `coin_type`, `departing_usufract_cap_id`, `departing_usufractuary_address`, `departing_phase_start_ms`, `departing_ceiling_total_ms`, `departing_handover_total_ms`, `active_usufract_cap_id`, `active_usufractuary_address`, `active_stake_balance`, `used_credit`, `remain_credit`, `governor_share`, `protocol_fee`, `departing_refund_amount`, `new_rent_price`, `committed_tenures`, `ceiling_total_ms`, `handover_total_ms`, `timestamp_ms` |
| `AuctionExpired` | Descent auction window closes with no bid | `escrow_id`, `asset_type`, `coin_type`, `phase_start_ms`, `last_acq_price`, `timestamp_ms` |

`BidPlaced` captures a snapshot of the current usufructuary's state at the moment the bid arrives, plus the full schedule commitment of the incoming bid: `pending_ceiling_total_ms` and `pending_handover_total_ms` are the total tenure duration and protection window that will apply if the bid fires. `BidSuperseded` captures a three-party snapshot: **active** (the untouched incumbent), **displaced** (the prior pending bid, refunded), **pending** (the new leading bid). The party vocabulary is consistent across the handover events — a cap moves `pending → active`, then exits as `displaced` (outbid while pending) or `departing` (completed its tenure and handed over). This makes bid competition fully reconstructable without any on-chain read.

The schedule fields on `HandoverCompleted` describe the incoming usufructuary's terms (rescaled from the departing usufructuary's schedule by the incoming/outgoing tenure ratio), keeping every tenancy self-describing from a single row with no need to walk the handover chain back to the originating `RentStarted`.

### Financial

| Event | Trigger | Key fields |
|-------|---------|------------|
| `EarningsMessagePosted` | A settlement mails the governor's share to the inbox | `escrow_id`, `earnings_message_id`, `earnings_inbox_id`, `amount`, `coin_type` |
| `EarningsMessageCollected` | Inbox bearer drains an earnings message | `escrow_id`, `earnings_message_id`, `earnings_inbox_id`, `amount`, `collector`, `coin_type` |
| `FeeMessagePosted` | Protocol fee posted to inbox after a transition | `escrow_id`, `fee_message_id`, `fee_inbox_id`, `amount`, `coin_type` |
| `FeeMessageCollected` | Admin collects fee message | `escrow_id`, `fee_message_id`, `fee_inbox_id`, `amount`, `collector`, `coin_type` |

Governor income mirrors the fee layer exactly: `EarningsMessagePosted` when a settlement mails an `EarningsMessage` to the `EarningsInbox`, `EarningsMessageCollected` when the bearer drains it. Uncollected income is `SUM(EarningsMessagePosted.amount) − SUM(EarningsMessageCollected.amount)` per `earnings_inbox_id` — fully answerable from events, no on-chain read. All message events carry `coin_type` as a fully-qualified type string and lead with `escrow_id` so they join cleanly with the rest of the star schema.

### Cap lifecycle

| Event | Trigger | Key fields |
|-------|---------|------------|
| `UsufructCapMinted` | Usufructuary enters protocol | `escrow_id`, `usufruct_cap_id`, `usufractuary_address` |
| `UsufructCapBurned` | Usufructuary cap destroyed (soft burn or stale cleanup) | `escrow_id`, `usufract_cap_id`, `usufractuary_address` |
| `GovernanceCapMinted` | Governor cap created at integration | `escrow_id`, `governance_cap_id`, `governor_address` |
| `GovernanceCapBurned` | Governor cap destroyed | `governance_cap_id`, `governor_address` |

`GovernanceCapBurned` is the only event without `escrow_id`: a `GovernanceCap` may govern many escrows, and burning it is not tied to any specific one. All other cap events carry `escrow_id` first.

`UsufructCapBurned` is emitted by the `usufruct_cap` module only when the cap holder explicitly burns the cap — either the guarded, escrow-checked `escrow::burn_stale_usufruct_cap` or the unguarded, escrow-free `cap::burn_usufruct_cap`. It is **not** emitted at `HandoverCompleted` or `TenureExpired`: those settle the usufructuary's seat internally, but the `UsufructCap` object lives in the holder's wallet and is not an input to that transaction, so the protocol cannot burn it there. Consequently the logical end of a tenancy is `HandoverCompleted` / `TenureExpired` (keyed by `usufruct_cap_id`), and the absence of a `UsufructCapBurned` does **not** imply the tenancy is still live — the cap may simply be a dead object the holder never cleaned up.

`usufractuary_address` in `UsufructCapBurned` is always `ctx.sender()` — the address that submitted the burn transaction. For a holder self-burning via `cap::burn_usufruct_cap` this equals the original holder; for a stale cleanup via `escrow::burn_stale_usufruct_cap` it is the cleaner (any third party). To recover the original holder, join `usufruct_cap_id → UsufructCapMinted.usufract_cap_id` and read `UsufructCapMinted.usufractuary_address`.

## 3. What You Can Build

The event stream is sufficient to build any of the following without touching on-chain objects:

**Marketplace listing page** — active escrows, their current policy (floor price, tenure duration), and last activity timestamp. Filter by coin type via the `coin_type` field on `AssetIntegrated`.

**Governor dashboard** — all escrows a governor has ever integrated (via `governor_address` field on `AssetIntegrated`), total lifetime income earned (`SUM(EarningsMessagePosted.amount)` per `earnings_inbox_id`) and uncollected income (`SUM(EarningsMessagePosted.amount) − SUM(EarningsMessageCollected.amount)`), current active usufructuaries, and pending fee messages not yet collected.

**Usufructuary portfolio** — all tenancies a wallet has held cross-escrow, filtering on `usufractuary_address` in `RentStarted`. Includes completed tenancies, active ones, and bids currently in Demand state via `BidPlaced`.

**Escrow activity feed** — ordered timeline of all events for a single `escrow_id`. Sufficient to render a complete history page: integrated → rented → bid placed → handover → rented again → expired → claimed.

**Bid competition tracker** — live view of escrows currently in Demand state, showing `BidPlaced.pending_bid_amount`, `handover_countdown_expiry`, and whether a `BidSuperseded` has already fired in this cycle.

**Protocol fee dashboard** — `FeeMessagePosted` vs `FeeMessageCollected` per `fee_inbox_id`, showing collected vs. pending fees by coin type.

**Policy change audit log** — sequence of `PolicyEnsembleRegistered → EnsembleUpdateScheduled → EnsembleUpdated` events for any escrow, showing exactly what changed and when it took effect.

**Configuration analytics (protocol-level)** — which combinations of `credit_shape`, `auction_shape`, and `price_escalation` appear most often, and how they correlate with tenure duration and earnings. Useful for documentation, recommendations, or a config simulator.

---

## 4. Canonical Queries

These queries assume a PostgreSQL indexer where each event type maps to a table of the same name, one row per event, columns matching event fields. `policy_ensemble_registered` holds the active policy snapshot per escrow (updated when `EnsembleUpdated` fires).

### Q1 — All active escrows

```sql
SELECT i.escrow_id, i.governor_address, i.asset_id, i.timestamp_ms
FROM asset_integrated i
WHERE NOT EXISTS (SELECT 1 FROM asset_retired  r WHERE r.escrow_id = i.escrow_id)
  AND NOT EXISTS (SELECT 1 FROM asset_claimed  c WHERE c.escrow_id = i.escrow_id)
ORDER BY i.timestamp_ms DESC;
```

### Q2 — All escrows for a governor, with lifetime earnings

```sql
SELECT
    i.escrow_id,
    i.timestamp_ms,
    COALESCE(SUM(e.amount), 0)              AS total_earned,
    COUNT(DISTINCT r.usufract_cap_id)        AS total_tenancies,
    CASE
        WHEN cl.escrow_id IS NOT NULL THEN 'claimed'
        WHEN re.escrow_id IS NOT NULL THEN 'retired'
        ELSE 'active'
    END                                     AS status
FROM asset_integrated i
LEFT JOIN earnings_message_posted e  ON e.escrow_id = i.escrow_id
LEFT JOIN rent_started            r  ON r.escrow_id = i.escrow_id
LEFT JOIN asset_claimed           cl ON cl.escrow_id = i.escrow_id
LEFT JOIN asset_retired           re ON re.escrow_id = i.escrow_id
WHERE i.governor_address = $governor_address
GROUP BY i.escrow_id, i.timestamp_ms, cl.escrow_id, re.escrow_id
ORDER BY i.timestamp_ms DESC;
```

### Q3 — Full activity timeline for one escrow

```sql
SELECT timestamp_ms, 'RentStarted'             AS event, usufractuary_address      AS actor, price_paid     AS amount FROM rent_started              WHERE escrow_id = $id
UNION ALL
SELECT timestamp_ms, 'TenureExpired'           AS event, usufractuary_address      AS actor, governor_share AS amount FROM tenure_expired            WHERE escrow_id = $id
UNION ALL
SELECT timestamp_ms, 'HandoverCompleted'       AS event, active_usufractuary_address AS actor, new_rent_price AS amount FROM handover_completed       WHERE escrow_id = $id
UNION ALL
SELECT timestamp_ms, 'EarningsMessageCollected' AS event, collector                AS actor, amount         AS amount FROM earnings_message_collected WHERE escrow_id = $id
UNION ALL
SELECT timestamp_ms, 'BidPlaced'              AS event, pending_usufractuary_address AS actor, pending_bid_amount AS amount FROM bid_placed            WHERE escrow_id = $id
UNION ALL
SELECT timestamp_ms, 'AssetRetired'           AS event, NULL                      AS actor, NULL           AS amount FROM asset_retired             WHERE escrow_id = $id
ORDER BY timestamp_ms;
```

### Q4 — Usufructuary portfolio: all tenancies for a wallet

```sql
SELECT
    r.escrow_id,
    r.usufract_cap_id,
    r.timestamp_ms                                      AS started_ms,
    COALESCE(t.timestamp_ms, h.timestamp_ms)            AS ended_ms,
    r.price_paid,
    CASE
        WHEN t.escrow_id IS NOT NULL THEN 'expired'
        WHEN h.escrow_id IS NOT NULL THEN 'displaced'
        ELSE 'active'
    END                                                 AS outcome
FROM rent_started r
LEFT JOIN tenure_expired      t ON t.usufract_cap_id = r.usufract_cap_id
LEFT JOIN handover_completed  h ON h.departing_usufract_cap_id = r.usufract_cap_id
WHERE r.usufractuary_address = $usufractuary_address
ORDER BY r.timestamp_ms DESC;
```

### Q5 — Escrows currently in Demand (bid placed, countdown live)

```sql
SELECT
    b.escrow_id,
    b.active_usufractuary_address,
    b.pending_usufractuary_address,
    b.pending_bid_amount,
    b.floor_price,
    b.handover_countdown_expiry
FROM bid_placed b
WHERE NOT EXISTS (
    SELECT 1 FROM handover_completed h
    WHERE h.escrow_id = b.escrow_id
      AND h.active_usufract_cap_id = b.pending_usufract_cap_id
)
AND NOT EXISTS (
    SELECT 1 FROM tenure_expired t
    WHERE t.escrow_id = b.escrow_id
      AND t.phase_start_ms = b.active_phase_start_ms
)
ORDER BY b.handover_countdown_expiry ASC;
```

### Q6 — Protocol fee collected vs. pending, by coin type

```sql
SELECT
    p.fee_inbox_id,
    p.coin_type,
    SUM(p.amount)                                        AS total_posted,
    COALESCE(SUM(c.amount), 0)                          AS total_collected,
    SUM(p.amount) - COALESCE(SUM(c.amount), 0)          AS pending
FROM fee_message_posted   p
LEFT JOIN fee_message_collected c ON c.fee_message_id = p.fee_message_id
GROUP BY p.fee_inbox_id, p.coin_type;
```

### Q7 — Configuration analytics: which `credit_shape` yields the most governor earnings?

```sql
SELECT
    p.credit_shape_policy,
    SUM(e.amount)               AS total_earnings,
    COUNT(DISTINCT e.escrow_id) AS escrow_count,
    AVG(e.amount)               AS avg_per_settlement
FROM earnings_message_posted e
JOIN policy_ensemble_registered p ON p.escrow_id = e.escrow_id
GROUP BY p.credit_shape_policy
ORDER BY total_earnings DESC;
```

## 5. What Events Cannot Answer

Events record transitions. They do not record current state. Two categories of questions require an on-chain read:

**Real-time floor price during Descent.** The descent auction price is a function of the curve shape, the time elapsed since the auction started, and `now`. It is a live calculation, not an event. `AuctionExpired.last_acq_price` gives the price at which the auction closed, but the intermediate price at any given timestamp requires re-running the curve formula against the current clock.

**Current FSM state when no transition is pending.** If an escrow is in `Occupied` and no event has fired recently, you can infer the state from the last transition event, but you cannot confirm it without reading the object. Lag in the event indexer makes this inference unreliable for time-sensitive decisions (e.g., deciding whether to place a bid).

For these two cases, query the escrow object directly via the Sui RPC. All other analytical and historical questions are answerable from the event stream alone.
