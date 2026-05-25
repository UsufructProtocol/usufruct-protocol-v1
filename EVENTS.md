# Usufruct — Event Observability

Usufruct is fully observable through its event stream. Every state transition emits an event; no information needed for off-chain analytics requires querying on-chain objects. This document explains the indexing strategy, the event catalogue, canonical analytical queries enabled by the high configuration space, and the boundary where on-chain queries are unavoidable.

## 1. Star Schema on `escrow_id`

Every event in the protocol carries `escrow_id` as its first field. This is the root foreign key of a SQL star schema: each event type is a fact table, and `escrow_id` is the join key across all of them.

```
                    PolicyEnsembleRegistered ──┐
         TenantCapMinted / TenantCapBurned ────┤
         OwnerCapMinted  / OwnerCapBurned  ────┤
                              AssetIntegrated ─┤
                               RentStarted ────┼──── escrow_id (root FK)
                  BidPlaced / BidSuperseded ───┤
                         HandoverCompleted ────┤
                              TenureExpired ───┤
                          EarningsWithdrawn ───┤
               FeeMessageSent/Collected    ────┤
                              AssetRetired ────┤
                              AssetClaimed ────┘
```

Two secondary join keys appear in multiple events and act as dimension PKs:

- **`tenant_cap_id`** — links `TenantCapMinted → RentStarted → BidPlaced → BidSuperseded → HandoverCompleted → TenureExpired → TenantCapBurned`. The complete history of a single tenancy is reconstructable by filtering on this key.
- **`owner_cap_id`** — links `OwnerCapMinted → AssetIntegrated → EarningsWithdrawn → AssetClaimed → OwnerCapBurned`.

All other fields (addresses, amounts, timestamps, policy strings) are attributes of the fact rows — they never require a secondary lookup.

## 2. Event Catalogue

Events are grouped by lifecycle phase. All amounts are in MIST (u64). All timestamps are epoch milliseconds (u64).

### Asset lifecycle

| Event | Trigger | Key fields |
|-------|---------|------------|
| `AssetIntegrated<Asset, CoinType>` | Owner calls `integrate` | `escrow_id`, `owner_cap_id`, `owner`, `asset_id`, `fee_inbox_id`, `integrated_at_ms` |
| `AssetRetired` | Asset leaves protocol (retire path or claim) | `escrow_id`, `timestamp_ms` |
| `AssetClaimed` | Owner reclaims asset after retirement | `escrow_id`, `owner_cap_id`, `owner`, `swept_earnings`, `timestamp_ms` |
| `RetireFlagSet` | Owner signals intent to retire | `escrow_id`, `owner`, `timestamp_ms` |

### Policy configuration

| Event | Trigger | Key fields |
|-------|---------|------------|
| `PolicyEnsembleRegistered` | First `integrate` call | Full 23-field snapshot of all policies + `escrow_id` |
| `EnsembleUpdated` | Policy change applied immediately (escrow was Idle) | Same 23-field snapshot |
| `EnsembleUpdateScheduled` | Policy change queued (escrow was active) | Same 23-field snapshot |

The 23 fields include: `rest_price_policy`, `rest_price`, `tenure_duration_policy`, `tenure_duration_ms`, `tenure_extend_policy`, `handover_policy`, `handover_floor_ms`, `auction_window_policy`, `auction_window_ceiling_ms`, `credit_shape_policy`, `credit_alpha_num/den/abs/neg`, `auction_shape_policy`, `auction_alpha_num/den/abs/neg`, `price_escalation_policy`, `price_escalation_delta`, `price_escalation_bps`.

Policy events carry the complete configuration snapshot at the moment of the event, not a diff. This means any point-in-time policy reconstruction requires only the most recent `PolicyEnsembleRegistered` or `EnsembleUpdated` event before a given timestamp — no event chain needed.

### Tenancy

| Event | Trigger | Key fields |
|-------|---------|------------|
| `RentStarted` | Tenant enters Occupied state | `escrow_id`, `tenant_cap_id`, `tenant`, `phase_start_ms`, `price_paid`, `floor_price` |
| `TenureExpired` | Tenure ceiling reached without handover | `escrow_id`, `tenant_cap_id`, `tenant`, `phase_start_ms`, `owner_share`, `protocol_fee`, `last_acquisition_price`, `timestamp_ms` |
| `CommitmentExtended` | Deferred commitment deadline extended | `escrow_id`, `commitment_policy`, `commitment_floor_ms`, `new_expiry_ms`, `timestamp_ms` |
| `AssetBorrowed` | Tenant takes physical custody of asset | `escrow_id`, `tenant_cap_id`, `tenant` |
| `AssetReturned` | Tenant returns physical custody | `escrow_id`, `tenant_cap_id`, `tenant` |

### Auction and handover

| Event | Trigger | Key fields |
|-------|---------|------------|
| `BidPlaced` | Incoming tenant outbids current tenant | `escrow_id`, `current_tenant_cap_id`, `current_tenant_addr`, `current_tenant_stake`, `current_phase_start_ms`, `tenant_cap_id`, `pending_tenant`, `bid_amount`, `floor_price`, `handover_countdown_expiry`, `timestamp_ms` |
| `BidSuperseded` | Second incoming tenant outbids first | `escrow_id`, `protected_tenant_cap_id/addr/stake/phase_start_ms`, `displaced_tenant_cap_id`, `new_tenant_cap_id`, `displaced_bidder`, `refunded_amount`, `new_bidder`, `new_bid_amount`, `floor_price`, `handover_countdown_expiry`, `timestamp_ms` |
| `HandoverCompleted` | Countdown expires; incoming tenant takes over | `escrow_id`, `displaced_tenant_cap_id`, `displaced_tenant`, `displaced_phase_start_ms`, `new_tenant_cap_id`, `new_tenant_addr`, `new_tenant_stake`, `used_credit`, `owner_share`, `protocol_fee`, `remain_credit`, `new_rent_price`, `timestamp_ms` |
| `AuctionExpired` | Descent auction window closes with no bid | `escrow_id`, `phase_start_ms`, `last_acq_price`, `timestamp_ms` |

`BidPlaced` captures a snapshot of the current tenant's state at the moment the bid arrives. `BidSuperseded` captures a three-party snapshot: protected (current), displaced (first bidder), new (second bidder). This makes bid competition fully reconstructable without any on-chain read.

### Financial

| Event | Trigger | Key fields |
|-------|---------|------------|
| `EarningsWithdrawn` | Owner withdraws accumulated earnings | `escrow_id`, `owner_cap_id`, `owner`, `amount`, `timestamp_ms` |
| `FeeMessageSent<CoinType>` | Protocol fee posted to inbox after a transition | `fee_message_id`, `fee_inbox_id`, `escrow_id`, `amount` |
| `FeeMessageCollected<CoinType>` | Admin collects fee message | `fee_message_id`, `fee_inbox_id`, `escrow_id`, `amount`, `collector` |

`FeeMessageSent` and `FeeMessageCollected` are generic over `CoinType`. The coin type is encoded in the Sui event type name, not as a field, so filtering by currency is done by event type filter rather than by field.

### Cap lifecycle

| Event | Trigger | Key fields |
|-------|---------|------------|
| `TenantCapMinted` | Tenant enters protocol | `tenant_cap_id`, `escrow_id`, `tenant` |
| `TenantCapBurned` | Tenant cap destroyed (soft burn or claim) | `tenant_cap_id`, `escrow_id`, `tenant` |
| `OwnerCapMinted` | Owner cap created at integration | `owner_cap_id`, `escrow_id`, `owner` |
| `OwnerCapBurned` | Owner cap destroyed | `owner_cap_id`, `escrow_id`, `owner` |

## 3. Canonical Analytical Queries

These queries assume a PostgreSQL indexer where each event type maps to a table of the same name, with one row per event and columns matching the event fields. `policy_ensemble_registered` is the policy snapshot table (one row per integration; updated rows come from `ensemble_updated`).

### Q1 — Which `credit_shape` yields the most owner earnings, by coin type?

```sql
SELECT
    p.credit_shape_policy,
    p.price_escalation_policy,
    SUM(e.amount)            AS total_earnings,
    COUNT(DISTINCT e.escrow_id) AS escrow_count,
    AVG(e.amount)            AS avg_per_withdrawal
FROM earnings_withdrawn e
JOIN LATERAL (
    SELECT credit_shape_policy, price_escalation_policy
    FROM policy_ensemble_registered
    WHERE escrow_id = e.escrow_id
    ORDER BY integrated_at_ms DESC
    LIMIT 1
) p ON true
GROUP BY p.credit_shape_policy, p.price_escalation_policy
ORDER BY total_earnings DESC;
```

The lateral join picks the active policy at integration time. For escrows that received an `EnsembleUpdated`, use the most recent policy snapshot before the withdrawal timestamp instead.

### Q2 — Which `auction_shape` drives the most competitive bidding?

```sql
-- Ratio of bid amount to floor price, by auction curve shape
SELECT
    p.auction_shape_policy,
    AVG(b.bid_amount::float / NULLIF(b.floor_price, 0)) AS avg_bid_premium,
    COUNT(*)                                             AS bid_count,
    COUNT(DISTINCT b.escrow_id)                          AS escrow_count
FROM bid_placed b
JOIN policy_ensemble_registered p ON p.escrow_id = b.escrow_id
GROUP BY p.auction_shape_policy
ORDER BY avg_bid_premium DESC;
```

### Q3 — What `handover_floor_ms` correlates with bid supersession (real competition)?

```sql
SELECT
    p.handover_floor_ms,
    COUNT(s.escrow_id)                         AS superseded_count,
    COUNT(b.escrow_id)                         AS placed_count,
    COUNT(s.escrow_id)::float
        / NULLIF(COUNT(b.escrow_id), 0)        AS supersession_rate
FROM bid_placed b
LEFT JOIN bid_superseded s
    ON s.escrow_id = b.escrow_id
    AND s.new_tenant_cap_id = b.tenant_cap_id
JOIN policy_ensemble_registered p ON p.escrow_id = b.escrow_id
GROUP BY p.handover_floor_ms
ORDER BY p.handover_floor_ms;
```

### Q4 — Which `price_escalation_bps` retains tenants longest?

```sql
-- Average tenure duration in ms, by price escalation configuration
SELECT
    p.price_escalation_policy,
    p.price_escalation_bps,
    AVG(t.timestamp_ms - r.phase_start_ms) AS avg_tenure_ms,
    COUNT(*)                                AS tenure_count
FROM tenure_expired t
JOIN rent_started r
    ON r.escrow_id = t.escrow_id
    AND r.tenant_cap_id = t.tenant_cap_id
JOIN policy_ensemble_registered p ON p.escrow_id = t.escrow_id
GROUP BY p.price_escalation_policy, p.price_escalation_bps
ORDER BY avg_tenure_ms DESC;
```

### Q5 — How efficiently does `HandoverCompleted` convert credit into owner earnings?

```sql
-- For each credit_shape, what fraction of used_credit ends up as owner_share?
SELECT
    p.credit_shape_policy,
    SUM(h.owner_share)::float
        / NULLIF(SUM(h.used_credit), 0)  AS credit_to_owner_ratio,
    SUM(h.protocol_fee)::float
        / NULLIF(SUM(h.used_credit), 0)  AS credit_to_fee_ratio,
    SUM(h.remain_credit)::float
        / NULLIF(SUM(h.used_credit + h.remain_credit), 0) AS credit_wasted_ratio,
    COUNT(*)                              AS handover_count
FROM handover_completed h
JOIN policy_ensemble_registered p ON p.escrow_id = h.escrow_id
GROUP BY p.credit_shape_policy
ORDER BY credit_to_owner_ratio DESC;
```

### Q6 — Full asset lifecycle duration and terminal event

```sql
SELECT
    i.escrow_id,
    i.integrated_at_ms,
    COALESCE(c.timestamp_ms, r.timestamp_ms)          AS closed_at_ms,
    COALESCE(c.timestamp_ms, r.timestamp_ms)
        - i.integrated_at_ms                          AS lifetime_ms,
    CASE
        WHEN c.escrow_id IS NOT NULL THEN 'claimed'
        WHEN r.escrow_id IS NOT NULL THEN 'retired'
        ELSE 'active'
    END                                               AS terminal_state,
    COALESCE(c.swept_earnings, 0)                     AS swept_at_claim
FROM asset_integrated i
LEFT JOIN asset_claimed  c ON c.escrow_id = i.escrow_id
LEFT JOIN asset_retired  r ON r.escrow_id = i.escrow_id
ORDER BY lifetime_ms DESC NULLS LAST;
```

## 4. What Events Cannot Answer

Events record transitions. They do not record current state. Three categories of questions require an on-chain read:

**Accrued but unwithdawn earnings.** `EarningsWithdrawn` records each withdrawal, but the amount currently sitting in `OwnerEarning` between withdrawals is computed on-chain from stake flows. The event stream only tells you what was withdrawn, not what has accrued since.

**Real-time floor price during Descent.** The descent auction price is a function of the curve shape, the time elapsed since the auction started, and `now`. It is a live calculation, not an event. `AuctionExpired.last_acq_price` gives the price at which the auction closed, but the intermediate price at any given timestamp requires re-running the curve formula against the current clock.

**Current FSM state when no transition is pending.** If an escrow is in `Occupied` and no event has fired recently, you can infer the state from the last transition event, but you cannot confirm it without reading the object. Lag in the event indexer makes this inference unreliable for time-sensitive decisions (e.g., deciding whether to place a bid).

For these three cases, query the escrow object directly via the Sui RPC. All other analytical and historical questions are answerable from the event stream alone.
