RENTAL_ESCROW MODULE — SPECIFICATION
=====================================

Module: `rental_escrow`
Design reference: design-compact.md §1 (state machine), §2 (access model),
  §3 (fund flows), §4 (handover countdown), §6 (integration parameters / retire),
  §9 (lazy evaluation)
Module map reference: module-map.spec.md §10
Depends on: `math`, `curve_shape`, `price_function`, `config`, `owner_cap`,
  `tenant_cap`, `protocol_fee_inbox`, `fee_message`


0. MODULE RESPONSIBILITY
------------------------

`rental_escrow` owns the central `RentalEscrow<Asset, CoinType>` shared object,
the public state enum (`AssetState` + `RentPhase`), the protocol state machine,
the lazy-settlement engine (`apply_pending_transitions`), all public entry
points, and the fund distribution logic for every boundary event.

**Owns:**

- `RentalEscrow<phantom Asset, phantom CoinType>` — `key` only. One shared
  object per integrated asset. Holds the asset, immutable `IntegrationConfig`,
  phase anchors, balance fields, addresses, and the retire flag.
- `AssetState` — public enum: `Idle | Rented { phase: RentPhase } |
  AtDutchAuction | Retired`. Copy/drop/store. Returned by
  `apply_pending_transitions`. External callers may pattern-match.
- `RentPhase` — public enum: `HandoverOpen | HandoverConfirmed`. Carried
  inside `Rented`.
- `AssetReceipt` — hot potato struct with no abilities. Created by
  `borrow_asset`, consumed by `return_asset` in the same PTB.
- All public entry points: `integrate`, `rent`, `retire`, `claim_asset`,
  `withdraw_earnings`, `borrow_asset`, `return_asset`,
  `apply_pending_transitions`.
- Read-only queries: `compute_used_credit`,
  `compute_price_descent`, `compute_next_rent_price`.
- Private settlement helpers: `do_handover`, `do_tenure_expiry`,
  `do_auction_expiry`, `split_fee`.
- Protocol state-machine events: `AssetIntegrated`, `RentStarted`,
  `BidPlaced`, `BidSuperseded`, `HandoverCompleted`, `TenureExpired`,
  `AuctionExpired`, `RetireFlagSet`, `AssetClaimed`, `EarningsWithdrawn`.

**Does not own:**

- `IntegrationConfig` construction or validation — lives in `config`.
- `CurveShape` / `PriceFunction` construction or evaluation — lives in
  `curve_shape` / `price_function`.
- `OwnerCap` / `TenantCap` struct definitions or mint/burn internals —
  live in `owner_cap` / `tenant_cap`. This module calls their constructors and
  destructors.
- `FeeMessage<C>` type or the drain path — lives in `fee_message`. This module
  only calls `fee_message::new` + `fee_message::send_message` at boundary
  events where a non-zero protocol fee exists.
- `ProtocolFeeInbox` / `ProtocolFeeRef` — live in `protocol_fee_inbox`. This
  module reads `fee_ref_inbox_id(&fee_ref)` at `integrate` to store the inbox
  ID.
- Raw arithmetic (`mul_div`, roots, exp) — lives in `math`.

**Dependency direction:** every other module is independent of
`rental_escrow`. This module is the single integration point: it consumes
all others and is consumed by none.

**Key design properties:**

- **Single shared object per instance.** The only shared object on the
  critical path is `RentalEscrow` itself. `FeeMessage<C>` routing uses
  transfer-to-object (free) and the drain path uses the owned
  `ProtocolFeeInbox` (fastpath). No consensus cost beyond the escrow.
- **Lazy evaluation.** No keeper, no off-chain coordinator. All elapsed
  boundary events are resolved by `apply_pending_transitions`, which every
  public mutating function calls before its own logic. Making it public also
  lets keepers, frontends, and `devInspectTransactionBlock` settle state
  without performing a full protocol operation.
- **All tenant fund deliveries are pushes.** `remain_credit`, superseded-bid
  refunds, and `TenantCap` are all pushed to the address registered at mint.
  Owner uses pull (`withdraw_earnings`, `claim_asset`).
- **Push-before-rotate invariant** (inside `do_handover`): balances and caps
  are pushed to the current/pending addresses before those address fields are
  overwritten.
- **Asset always present while escrow exists.** `asset: Option<Asset>` is the
  internal field representation. `None` exists only between `borrow_asset` and
  `return_asset` within a single PTB — never across transaction boundaries.
  The invariant is enforced by the hot-potato `AssetReceipt`, not by the type.
- **Capability-based authorization.** `retire`, `claim_asset`, and
  `withdraw_earnings` take `&OwnerCap` and forward to
  `owner_cap::assert_escrow`. `borrow_asset` takes `&TenantCap` and checks
  `object::id(cap) == current_tenant_cap_id` (staleness check). No address
  check is performed anywhere.


1. ERROR CONSTANTS
------------------

All constants are `public` so the SDK can map abort codes to human-readable
messages.

    public const E_OWNER_CAP_MISMATCH:          u64 = 0;  // forwarded from owner_cap::assert_escrow
    public const E_TENANT_CAP_WRONG_ESCROW:     u64 = 1;  // cap.escrow_id != object::id(escrow)
    public const E_TENANT_CAP_STALE:            u64 = 2;  // object::id(cap) != current_tenant_cap_id
    public const E_NOT_AUCTION:                 u64 = 3;  // compute_price_descent: state != AtDutchAuction
    public const E_NOT_RENTED:                  u64 = 4;  // compute_used_credit / compute_next_rent_price: state != Rented
    public const E_INSUFFICIENT_PAYMENT:        u64 = 5;  // payment < floor price (all acquisition paths)
    public const E_RETIRE_FLAG_BLOCKS_BID:      u64 = 6;  // rent() during Rented(HandoverOpen) with retire_flag
    public const E_RETIRED_NO_BID:              u64 = 7;  // rent() called when state is Retired
    public const E_RETIRE_FLOOR_NOT_ELAPSED:    u64 = 8;  // retire() before integrated_at_ms + retire_floor
    public const E_ALREADY_RETIRED:             u64 = 9;  // retire() when retire_flag already set
    public const E_NOT_RETIRED:                 u64 = 10; // claim_asset() when state != Retired
    public const E_RECEIPT_ESCROW_MISMATCH:     u64 = 11; // return_asset: receipt.escrow_id != object::id(escrow)
    public const E_RECEIPT_ASSET_MISMATCH:      u64 = 12; // return_asset: receipt.asset_id != object::id(&asset)
    public const E_NO_EARNINGS:                 u64 = 13; // withdraw_earnings: owner_earnings == 0 after settlement
    public const E_ASSET_ALREADY_BORROWED:      u64 = 14; // borrow_asset called while asset is already out of escrow


2. TYPES
--------

### 2.1 AssetState — public enum

```move
public enum AssetState has copy, drop, store {
    Idle,
    Rented { phase: RentPhase },
    AtDutchAuction,
    Retired,
}
```

**Abilities:** `copy + drop + store`. Returned by value from
`apply_pending_transitions`. Embedded inside `RentalEscrow`.

**Semantics:**

| Variant | Meaning |
|---|---|
| `Idle` | No tenant. Asset available at `min_rent_price`. Entry: `rent()`. |
| `Rented { HandoverOpen }` | Current tenant holds exclusive access. No pending bid. |
| `Rented { HandoverConfirmed }` | Current tenant holds access until `handover_countdown_expiry`. A pending tenant has paid `>= next_rent_price`. |
| `AtDutchAuction` | Price descends from `last_rent_price` toward `min_rent_price`. See `compute_price_descent` (§8.2). |
| `Retired` | Terminal. `retire_flag` is set and the state machine has reached a point where the asset is extractable via `claim_asset`. |

The `state` field is not directly writable from outside the module. All
transitions flow through public functions — `apply_pending_transitions`,
`rent`, `retire`, and `claim_asset`.

### 2.2 RentPhase — public enum

```move
public enum RentPhase has copy, drop, store {
    HandoverOpen,
    HandoverConfirmed,
}
```

**Abilities:** `copy + drop + store`. Always carried inside `AssetState::Rented`.

- `HandoverOpen` — no pending tenant. `handover_countdown_expiry` is `None`.
  `pending_tenant_address` is `None`. `pending_bid` holds zero balance.
- `HandoverConfirmed` — a pending tenant exists. `handover_countdown_expiry`
  is `Some`. `pending_tenant_address` is `Some`. `pending_bid` is non-zero.

### 2.3 RentalEscrow — shared struct

```move
public struct RentalEscrow<phantom Asset: key + store, phantom CoinType> has key {
    id:                         UID,
    asset:                      Option<Asset>,
    config:                     IntegrationConfig,
    fee_inbox_id:               ID,
    integrated_at_ms:           u64,
    state:                      AssetState,
    last_rent_price:            u64,
    phase_start_ms:             u64,
    current_tenant_cap_id:      Option<ID>,
    current_tenant_address:     Option<address>,
    pending_tenant_address:     Option<address>,
    handover_countdown_expiry:  Option<u64>,
    tenant_stake:               Balance<CoinType>,
    pending_bid:                Balance<CoinType>,
    owner_earnings:             Balance<CoinType>,
    retire_flag:                bool,
}
```

**Abilities:** `key` only.
- `key` — required for `transfer::share_object`. The escrow is shared so any
  participant may interact with it (rent, apply transitions, read state).
- No `store` — the shared object should never be wrapped by external code.
  `store` would allow an external module to include `RentalEscrow` as a field
  of another type, breaking the one-shared-object-per-instance invariant.

**Asset field — why `Option<Asset>`:** in Sui Move, a field cannot be moved
out of a struct accessed via `&mut`. `borrow_asset` receives
`&mut RentalEscrow<Asset, CoinType>` and must temporarily move the asset out.
`Option<Asset>` enables this via `option::extract` (take, leaving `None`) and
`option::fill` (restore). The `None` window exists only between `borrow_asset`
and `return_asset` within a single PTB — never at a transaction boundary.
This is the canonical Move borrow pattern, used internally by
`sui::borrow::Referent<T>` in the Sui framework
(https://docs.sui.io/guides/developer/objects/simulating-refs).

**Field semantics:**

| Field | Meaning |
|---|---|
| `asset` | The integrated asset, wrapped in `Option`. `Some` at all transaction boundaries; `None` only within a PTB borrow window (`borrow_asset` → `return_asset`). Inner type requires `key + store`. |
| `config` | Immutable `IntegrationConfig` — all protocol parameters. |
| `fee_inbox_id` | ID of `ProtocolFeeInbox`. Stored at integrate from `&ProtocolFeeRef`. Passed to `fee_message::new` at each boundary event so the resulting `FeeMessage<C>` carries its routing target. |
| `integrated_at_ms` | Timestamp at integration. Used to enforce `retire_floor`: `retire()` aborts if `clock.timestamp_ms() < integrated_at_ms + config.retire_floor`. |
| `state` | Current `AssetState`. |
| `last_rent_price` | Price paid by the most recent tenant. Entry barrier for takeover and starting price of the Dutch Auction descent. Initialized to `min_rent_price` at `integrate` as a sentinel — the first Idle acquisition overwrites it with its own `coin::value(&payment)`. Updated at every acquisition to `coin::value(&payment)` — always ≥ the arm-specific floor (`min_rent_price` from Idle, `compute_price_descent(now)` from AtDutchAuction, `compute_next_rent_price(escrow)` from Rented). Overpayment is absorbed verbatim; there is no refund path. |
| `phase_start_ms` | Timestamp at which the current phase began. See §5 for exact assignment per transition. |
| `current_tenant_cap_id` | `Some(id)` while `state` is `Rented`; `None` otherwise. The live `TenantCap` for the current tenant. Staleness enforced structurally — any other `TenantCap` with the same `escrow_id` fails `object::id(cap) == current_tenant_cap_id`. |
| `current_tenant_address` | `Some(addr)` while `state` is `Rented`; `None` otherwise. Target of `remain_credit` push at handover. |
| `pending_tenant_address` | `Some(addr)` only while `state` is `Rented(HandoverConfirmed)`. Target of `TenantCap` push at handover completion. |
| `handover_countdown_expiry` | `Some(ts)` only while `state` is `Rented(HandoverConfirmed)`. Deterministic from the first bid — subsequent bids do not alter it. |
| `tenant_stake` | Balance paid by the current tenant. Non-zero only while `state` is `Rented`. At handover: `used_credit` splits into `owner_earnings` (95%) + fee (5%); `remain_credit` pushed to displaced tenant; `pending_bid` becomes the new `tenant_stake`. At tenure expiry: full balance splits into `owner_earnings` (95%) + fee (5%). |
| `pending_bid` | Balance paid by the pending tenant. Non-zero only while `state` is `Rented(HandoverConfirmed)`. Refunded on supersede; becomes new `tenant_stake` at handover. |
| `owner_earnings` | Accumulated 95% share. Withdrawn via `withdraw_earnings` or swept at `claim_asset`. |
| `retire_flag` | Once set by `retire()`, stays set. In `Rented(HandoverOpen)`: blocks new bids and redirects tenure expiry to `Retired` instead of `AtDutchAuction`. `Idle` and `AtDutchAuction`: `retire()` transitions to `Retired` immediately. Not checked in `do_handover`. |

### 2.4 AssetReceipt — hot potato

```move
public struct AssetReceipt {
    escrow_id: ID,
    asset_id:  ID,
}
```

**Abilities:** none. Cannot be stored, transferred, dropped, or copied.
Must be consumed by `return_asset` in the same PTB that created it via
`borrow_asset`. The Move linear type system enforces this structurally — a
PTB that does not consume the receipt fails to type-check at the transaction
boundary.

**Fields:**

| Field | Meaning |
|---|---|
| `escrow_id` | ID of the escrow the asset was borrowed from. Enforces return to the correct escrow. |
| `asset_id` | `object::id(&asset)` captured at borrow. Enforces that the same asset — not a substitute — is returned. |

**Why both fields:** without `asset_id`, a malicious tenant with two assets of
the same type (from two different escrows) could borrow from escrow A and
return a different asset to close the receipt. `escrow_id` alone does not
prevent asset substitution. Capturing both makes return structurally
unambiguous.


3. EVENTS
---------

All events are defined inline and emitted from this module. The Sui Move
event verifier requires the emitted type to be internal to the calling
module — this is why there is no standalone events module.

```move
public struct AssetIntegrated has copy, drop {
    escrow_id:        ID,
    owner_cap_id:     ID,
}

public struct RentStarted has copy, drop {
    escrow_id:        ID,
    tenant_cap_id:    ID,
    price_paid:       u64,     // stake amount transferred to escrow
    from_state:       AssetState,  // Idle or AtDutchAuction
}

public struct BidPlaced has copy, drop {
    escrow_id:                 ID,
    pending_tenant:            address,
    bid_amount:                u64,
    handover_countdown_expiry: u64,
}

public struct BidSuperseded has copy, drop {
    escrow_id:         ID,
    displaced_bidder:  address,
    refunded_amount:   u64,
    new_bidder:        address,
    new_bid_amount:    u64,
}

public struct HandoverCompleted has copy, drop {
    escrow_id:         ID,
    displaced_tenant:  address,
    new_tenant_cap_id: ID,
    used_credit:       u64,   // amount consumed by owner (pre-fee split)
    owner_share:       u64,   // used_credit × 0.95
    protocol_fee:      u64,   // used_credit × 0.05
    remain_credit:     u64,   // refunded to displaced tenant
    timestamp_ms:      u64,   // = handover_countdown_expiry
}

public struct TenureExpired has copy, drop {
    escrow_id:        ID,
    tenant:           address,
    owner_share:      u64,   // tenant_stake × 0.95
    protocol_fee:     u64,   // tenant_stake × 0.05
    next_state:       AssetState,  // AtDutchAuction or Retired
    timestamp_ms:     u64,   // = phase_start_ms + tenure_ceiling
}

public struct AuctionExpired has copy, drop {
    escrow_id:        ID,
    next_state:       AssetState,  // always Idle
    timestamp_ms:     u64,   // = phase_start_ms + descent_ceiling
}

public struct RetireFlagSet has copy, drop {
    escrow_id:        ID,
    state_at_set:     AssetState,  // settled state when retire was called
}

public struct AssetClaimed has copy, drop {
    escrow_id:        ID,
    owner_cap_id:     ID,
    swept_earnings:   u64,
}

public struct EarningsWithdrawn has copy, drop {
    escrow_id:        ID,
    owner_cap_id:     ID,
    amount:           u64,
}
```

**Sui Verifier constraint:** every event struct has `copy + drop` and is
internal to this module. `event::emit` requires these abilities.

**Timestamp convention:** only boundary events — `HandoverCompleted`,
`TenureExpired`, `AuctionExpired` — carry a `timestamp_ms` field. Its
value is the exact boundary timestamp (`handover_countdown_expiry`,
`phase_start_ms + tenure_ceiling`, `phase_start_ms + descent_ceiling`)
— not `clock.now()` — so the event timeline stays aligned with the
state machine even when settlement is lazy and runs in a later
checkpoint than the boundary itself.

Immediate events (`AssetIntegrated`, `RentStarted`, `BidPlaced`,
`BidSuperseded`, `RetireFlagSet`, `AssetClaimed`, `EarningsWithdrawn`)
do not carry a `timestamp_ms` field. Consumers read the event-envelope
timestamp (`SuiEvent.timestampMs`, the checkpoint time of the emitting
transaction), which is authoritative for anything that happens at tx
time. Duplicating it in the event body would add no information and
would force `&Clock` into the signature of functions that otherwise
have no reason to read the clock.

### Star schema — the protocol's event emission strategy

The full event surface of the protocol — this module plus the three
child-object modules (`owner_cap`, `tenant_cap`, `fee_message`) — is
shaped as a **SQL star schema** anchored on `escrow_id` as the root
foreign key. Every event emitted anywhere in the package carries
`escrow_id`, so an off-chain indexer can ingest them into a unified
view of per-escrow activity with zero envelope-metadata dependency.

Around that root, three satellite dimensions exist, one per
protocol-internal child-object type. Each dimension has its own
natural primary key — the child object's own ID — and a pair of
lifecycle events (create / destroy, send / collect) joined on that
PK. Address fields are non-redundant across each pair: they appear
only on the event where they are first-observed or where they diverge
from their counterpart.

```
                    ┌──────────────────────────────────┐
                    │         escrows (root fact)      │
                    │           PK: escrow_id          │
                    │                                  │
                    │  AssetIntegrated  RentStarted    │
                    │  BidPlaced        BidSuperseded  │
                    │  HandoverCompleted               │
                    │  TenureExpired    AuctionExpired │
                    │  RetireFlagSet    AssetClaimed   │
                    │  EarningsWithdrawn               │
                    └──────────────┬───────────────────┘
                                   │  FK: escrow_id
                                   │  (on every row below)
            ┌──────────────────────┼──────────────────────────┐
            │                      │                          │
            ▼                      ▼                          ▼
 ┌───────────────────┐  ┌────────────────────┐  ┌────────────────────────┐
 │     owner_cap     │  │     tenant_cap     │  │      fee_message       │
 │  PK: owner_cap_id │  │ PK: tenant_cap_id  │  │   PK: fee_message_id   │
 │                   │  │                    │  │                        │
 │  OwnerCapMinted   │  │  TenantCapMinted   │  │   FeeMessageSent       │
 │    owner          │  │    tenant          │  │     tenant             │
 │                   │  │                    │  │                        │
 │  OwnerCapBurned   │  │  TenantCapBurned   │  │   FeeMessageCollected  │
 │    owner          │  │    —               │  │     collector          │
 └───────────────────┘  └────────────────────┘  └────────────────────────┘
   key + store →          key only →                 key only →
   owner may diverge      mint-tenant ≡              tenant first-observed
   across mint/burn       burn-tenant →              at send; collector
   → kept on both         no JOIN loss               first-observed at
     events                 → dropped on Burned        consume
```

**Star schema properties:**

| Property | Consequence |
|---|---|
| **`escrow_id` on every row.** | Any analytical question ("activity on escrow X") answers with a single `WHERE escrow_id = X`. No cross-table joins needed for scoping. |
| **Child PK pairs lifecycle.** | `owner_cap_id`, `tenant_cap_id`, `fee_message_id` each join their Minted↔Burned / Sent↔Collected pair. Full object history = one JOIN. |
| **Addresses are first-observed, never duplicated.** | Redundancy recoverable by PK-JOIN is dropped. `TenantCapBurned` has no `tenant` (non-transferable → JOIN recovers it). `FeeMessageCollected` has no `tenant` (JOIN on `fee_message_id` recovers it). `OwnerCapBurned` keeps `owner` — `key + store` transferability means the burn-sender is genuinely new information. Fact-table events also comply: `AssetIntegrated` omits `integrator` (JOIN on `owner_cap_id` to `OwnerCapMinted`), `RentStarted` omits `tenant` (JOIN on `tenant_cap_id` to `TenantCapMinted`), `HandoverCompleted` omits `new_tenant` (JOIN on `new_tenant_cap_id`). `HandoverCompleted.displaced_tenant` is kept — no PK reaches the outgoing cap from this row. |
| **Fact-table rows carry child PK-FKs to dimensions they co-emit with.** | `AssetIntegrated.owner_cap_id`, `RentStarted.tenant_cap_id`, `HandoverCompleted.new_tenant_cap_id`, `AssetClaimed.owner_cap_id`, `EarningsWithdrawn.owner_cap_id` — every fact row whose semantics touch a child object exposes that child's PK so the indexer can JOIN into the dimension without envelope-timing. |
| **No envelope dependence.** | Events never require the indexer to join against `SuiEvent.timestampMs` or `SuiEvent.sender` to reconstruct meaning — except for pure wall-clock ordering of immediate events (which the envelope provides for free). |
| **Cross-module events are self-contained.** | An indexer ingesting only `fee_message` events can answer every fee-message-level question; likewise for each cap module. Cross-module JOINs are always on `escrow_id`, never on implicit co-emission. |

**Strategy statement.** This star schema is the protocol's uniform
event-emission strategy. Every future event added to the package
anywhere **must**: (a) carry `escrow_id`, (b) if it concerns a
child object's lifecycle, carry that object's own ID as lifecycle PK,
and (c) carry address fields only where first-observed or divergent.
Deviations — co-emission dependencies, envelope-metadata reliance,
redundant addresses across a PK-joinable pair — degrade the schema
and are disallowed.


4. LIFECYCLE FUNCTIONS
-----------------------

### 4.1 `integrate`

    public fun integrate<Asset: key + store, CoinType>(
        asset:    Asset,
        config:   IntegrationConfig,
        fee_ref:  &ProtocolFeeRef,
        clock:    &Clock,
        ctx:      &mut TxContext,
    ): OwnerCap

**Visibility:** `public` — entry point for any integrator.

**Purpose:** wraps `asset` in a new `RentalEscrow<Asset, CoinType>`, shares
the escrow, mints one `OwnerCap`, and returns it to the PTB.

**Behavior:**
1. Allocate `uid = object::new(ctx)`. Compute `escrow_id = object::uid_to_inner(&uid)`.
2. Mint `OwnerCap` via `owner_cap::new(escrow_id, tx_context::sender(ctx), ctx)`.
   The sender is the default recipient; PTBs that wish to deliver the cap
   to a distinct address (custody, multisig) can transfer it further after
   `integrate` returns, but the `OwnerCapMinted.owner` field records the
   integrator at mint time.
3. Read `fee_inbox_id = protocol_fee_inbox::fee_ref_inbox_id(fee_ref)`.
4. Construct the escrow with:
   - `asset = option::some(asset)`
   - `state = AssetState::Idle`
   - `last_rent_price = config::min_rent_price(&config)`
   - `phase_start_ms = 0`
   - `integrated_at_ms = clock.timestamp_ms()`
   - All remaining `Option` fields `None`, all `Balance` fields `balance::zero()`
   - `retire_flag = false`
5. `transfer::share_object(escrow)`.
6. Emit `AssetIntegrated { escrow_id, owner_cap_id }`. The integrator
   address is not carried here — it is already recorded on the
   co-emitted `OwnerCapMinted.owner` row and recoverable by JOIN on
   `owner_cap_id` (star-schema invariant c: no PK-recoverable
   redundancy).
7. Return `OwnerCap`. The PTB routes it (typically via
   `transfer::public_transfer` to `tx_context::sender(ctx)`).

**Why return the cap instead of pushing it:** `OwnerCap` has `store`; the PTB
author may want to stash it in a multisig, a custody object, or chain it as
input to a subsequent PTB step. Returning gives the PTB full control; pushing
would force every integrator to issue a second transfer.

**`Asset = OwnerCap` is permitted.** `OwnerCap` has `key + store` and
satisfies the `Asset` bound like any other integrable type. Renting an
`OwnerCap` is equivalent to renting administrative authority over the
wrapped escrow (including `retire()`) for the duration of the tenancy —
a mechanism for implicit sale of the underlying asset. The protocol does
not impose a nesting-depth limit: any type-level check would fail to
prevent deeper chains composed via external `key + store` wrappers, so a
self-imposed limit would be defense-in-type without real guarantee.
Integrators who want to limit exposure must do so outside the protocol.

---

### 4.2 `retire`

    public fun retire<Asset: key + store, CoinType>(
        escrow:    &mut RentalEscrow<Asset, CoinType>,
        owner_cap: &OwnerCap,
        clock:     &Clock,
        ctx:       &mut TxContext,
    )

**Visibility:** `public` — callable by the `OwnerCap` holder.

**Purpose:** initiate retirement. Sets `retire_flag`. Does not return the
asset. Does not mutate balances.

**Behavior:**
1. `owner_cap::assert_escrow(owner_cap, object::id(escrow))` — abort
   `E_OWNER_CAP_MISMATCH` if mismatch.
2. `apply_pending_transitions(escrow, clock, ctx)` — settle all elapsed
   boundaries first.
3. Assert `!escrow.retire_flag`, abort `E_ALREADY_RETIRED`.
4. Assert `clock.timestamp_ms() >= escrow.integrated_at_ms +
   config::retire_floor(&escrow.config)`, abort `E_RETIRE_FLOOR_NOT_ELAPSED`.
5. Set `escrow.retire_flag = true`.
6. If `escrow.state` is `Idle` or `AtDutchAuction` (no active tenant, no
   pending bid), transition immediately:
   - `AtDutchAuction` → set `state = Retired`, set `phase_start_ms =
     clock.timestamp_ms()`. Emit `AuctionExpired { next_state: Retired, ... }`
     with `timestamp_ms = clock.timestamp_ms()` (not the would-be auction expiry —
     retire cuts it short).
   - `Idle` → set `state = Retired`, set `phase_start_ms = clock.timestamp_ms()`.
     No auxiliary event (the state was already "empty"; `RetireFlagSet` covers it).
   Both branches update `phase_start_ms` as bookkeeping, following the
   convention that every transition site records the moment of transition
   (see `do_tenure_expiry` §7.2 and `do_auction_expiry` §7.3). The field is
   not read in `Retired`, but the uniform invariant simplifies auditing.
7. Emit `RetireFlagSet { escrow_id, state_at_set: escrow.state }`.

**State after `retire` completes:**

| State at call | `retire_flag` | `state` after |
|---|---|---|
| Idle | true | Retired (immediate) |
| Rented(HandoverOpen) | true | Rented(HandoverOpen) — tenant runs to tenure_ceiling, then Retired via `do_tenure_expiry` |
| Rented(HandoverConfirmed) | true | Rented(HandoverConfirmed) — handover fires normally, T(n+1) inherits the flag, runs to their tenure_ceiling, then Retired |
| AtDutchAuction | true | Retired (immediate) |

**Idempotency:** not idempotent — second call aborts with `E_ALREADY_RETIRED`.

---

### 4.3 `claim_asset`

    public fun claim_asset<Asset: key + store, CoinType>(
        escrow:    RentalEscrow<Asset, CoinType>,
        owner_cap: OwnerCap,
        clock:     &Clock,
        ctx:       &mut TxContext,
    ): (Asset, Coin<CoinType>)

**Visibility:** `public`.

**Purpose:** finalize retirement. Sweeps `owner_earnings`, burns `OwnerCap`,
deletes the escrow, returns the asset and earnings.

**Preconditions:**
- `escrow.retire_flag == true`.
- `escrow.state == Retired` after lazy settlement.

**Behavior:**
1. Consume both `escrow` and `owner_cap` by value.
2. Assert `owner_cap::escrow_id(&owner_cap) == object::id(&escrow)`,
   abort `E_OWNER_CAP_MISMATCH` (redundant safety — the cap could not have
   been minted otherwise, but the assertion prevents a cross-escrow cap
   passed through a malicious PTB).
3. Call `apply_pending_transitions(&mut escrow, clock, ctx)` — settle any
   remaining elapsed boundaries.
4. Assert `escrow.state == Retired`, abort `E_NOT_RETIRED`. This covers
   callers who never called `retire()` first or who called `claim_asset`
   during an active tenancy.
5. Destructure the escrow:

        let RentalEscrow {
            id, asset: asset_opt, config: _, fee_inbox_id: _,
            integrated_at_ms: _, state: _, last_rent_price: _, phase_start_ms: _,
            current_tenant_cap_id: _, current_tenant_address: _,
            pending_tenant_address: _, handover_countdown_expiry: _,
            tenant_stake, pending_bid, owner_earnings,
            retire_flag: _,
        } = escrow;
        let asset = option::destroy_some(asset_opt);

6. Both `tenant_stake` and `pending_bid` must be zero at this point — the
   only path to `Retired` drains them via `do_tenure_expiry` (stake) and,
   for any unresolved pending bid, via a preceding `do_handover`. Destroy
   them: `balance::destroy_zero(tenant_stake); balance::destroy_zero(pending_bid);`.
   An abort here indicates a state-machine bug; the destroy-zero call aborts
   on non-zero, which serves as a structural assertion.
7. `let earnings = coin::from_balance(owner_earnings, ctx);`
8. **Pre-bind event locals** (emit-last: the two destructive ops below
   consume the `UID`s needed for the event body — bind IDs to locals
   first):
   - `let escrow_id    = object::uid_to_inner(&id);`
   - `let owner_cap_id = object::id(owner_cap);`
   - `let swept_earnings = coin::value(&earnings);`
9. `owner_cap::burn(owner_cap, ctx);` — `OwnerCapBurned.owner` records
   `tx_context::sender(ctx)`, the address that presented the cap (the
   owner at claim time, which may differ from the mint recipient since
   `OwnerCap` is transferable).
10. `object::delete(id);`
11. Emit `AssetClaimed { escrow_id, owner_cap_id, swept_earnings }` —
    emit-last, after the cap is burned and the escrow UID is deleted.
12. Return `(asset, earnings)`.

**Why both returned:** the owner gets everything they are owed atomically in
one call — the asset, the accumulated earnings. No residual state, no
locked balances.

---

### 4.4 `withdraw_earnings`

    public fun withdraw_earnings<Asset: key + store, CoinType>(
        escrow:    &mut RentalEscrow<Asset, CoinType>,
        owner_cap: &OwnerCap,
        clock:     &Clock,
        ctx:       &mut TxContext,
    ): Coin<CoinType>

**Visibility:** `public`.

**Purpose:** pull `owner_earnings` without exiting the protocol.

**Behavior:**
1. `owner_cap::assert_escrow(owner_cap, object::id(escrow))` —
   abort `E_OWNER_CAP_MISMATCH`.
2. `apply_pending_transitions(escrow, clock, ctx)` — settle any elapsed
   boundaries first so the withdrawn amount includes all accrued earnings.
3. `let amount = balance::value(&escrow.owner_earnings);`
4. Assert `amount > 0`, abort `E_NO_EARNINGS`.
5. `let balance = balance::withdraw_all(&mut escrow.owner_earnings);`
6. Emit `EarningsWithdrawn { escrow_id, owner_cap_id: object::id(owner_cap), amount }`.
   `owner_cap_id` is carried so the withdrawer is recoverable via
   PK-JOIN into `owner_cap_minted` / `owner_cap_burned` (star-schema
   invariant d: no envelope dependence for address recovery).
   `OwnerCap` is `key + store` and may be transferred between mint and
   this call, so the JOIN target is the Mint row for the cap's identity,
   with any subsequent transfers observable at system level on Sui.
7. Return `coin::from_balance(balance, ctx)`.


5. RENTAL FUNCTIONS
--------------------

### 5.1 `rent`

    public fun rent<Asset: key + store, CoinType>(
        escrow:  &mut RentalEscrow<Asset, CoinType>,
        payment: Coin<CoinType>,
        clock:   &Clock,
        ctx:     &mut TxContext,
    )

**Visibility:** `public`. Single entry point to become or displace a tenant.

**Behavior:**

1. `apply_pending_transitions(escrow, clock, ctx)` — settle first, act on
   post-settlement `escrow.state`.
2. Dispatch on `escrow.state`:

#### Case: `Idle`

- Assert `coin::value(&payment) >= escrow.config.min_rent_price`, abort
  `E_INSUFFICIENT_PAYMENT`.
- Let `price_paid = coin::value(&payment);`
- Let `tenant_cap_id = install_new_tenant(escrow, payment, clock, ctx);` — §7.5
  is the single source of truth for "install tenant from payment into an
  empty escrow". It handles balance absorption, phase anchor, cap mint and
  push, address registration, and state transition to
  `Rented { HandoverOpen }`.
- Emit `RentStarted { escrow_id, tenant_cap_id, price_paid,
  from_state: AssetState::Idle }`. The tenant address is not carried
  here — it is already recorded on the co-emitted `TenantCapMinted.tenant`
  row and recoverable by JOIN on `tenant_cap_id` (star-schema invariant c).

#### Case: `AtDutchAuction`

- Let `price = compute_price_descent(escrow, clock.timestamp_ms())`.
- Assert `coin::value(&payment) >= price`, abort `E_INSUFFICIENT_PAYMENT`.
- Let `price_paid = coin::value(&payment);`
- Let `tenant_cap_id = install_new_tenant(escrow, payment, clock, ctx);` — §7.5.
- Emit `RentStarted { escrow_id, tenant_cap_id, price_paid,
  from_state: AssetState::AtDutchAuction }`. Tenant address recoverable
  via JOIN on `tenant_cap_id` into `TenantCapMinted`.

#### Case: `Rented { HandoverOpen }`

- Assert `!escrow.retire_flag`, abort `E_RETIRE_FLAG_BLOCKS_BID`.
- Let `floor = compute_next_rent_price(escrow)` (delegates to
  `price_function::evaluate_price_fn`).
- Assert `coin::value(&payment) >= floor`, abort `E_INSUFFICIENT_PAYMENT`.
- Let `remaining = (escrow.phase_start_ms + escrow.config.tenure_ceiling) -
  clock.timestamp_ms()`.
- Let `countdown = min(escrow.config.handover_floor, remaining)`.
- `escrow.handover_countdown_expiry = some(clock.timestamp_ms() + countdown);`
- `escrow.pending_tenant_address = some(tx_context::sender(ctx));`
- `escrow.last_rent_price = coin::value(&payment);`
- `balance::join(&mut escrow.pending_bid, coin::into_balance(payment));`
- `escrow.state = Rented { phase: HandoverConfirmed };`
- Emit `BidPlaced { escrow_id, pending_tenant, bid_amount,
  handover_countdown_expiry }`.

**Retire flag rationale:** blocking new bids is what "retire during Rented"
means — the current tenant completes their block uncontested and the asset
exits afterward.

#### Case: `Rented { HandoverConfirmed }`

- `retire_flag` check is **not** performed here. A pending bid was already
  accepted before `retire` could have fired; the committed bid is
  honored, handover completes normally, and T(n+1) then enters
  `HandoverOpen` with the flag still set (no further bids accepted).
- Let `floor = compute_next_rent_price(escrow)` — `last_rent_price` holds
  the previous bidder's payment, so the floor escalates with each supersede.
- Assert `coin::value(&payment) >= floor`, abort `E_INSUFFICIENT_PAYMENT`.
- **Pre-bind event locals** (emit-last: capture values before the
  state rotations consume the source data; emit runs after all
  mutations so the escrow's post-state matches the event semantics):
  - `let displaced_bidder = *option::borrow(&escrow.pending_tenant_address);`
  - `let new_bidder      = tx_context::sender(ctx);`
  - `let new_bid_amount  = coin::value(&payment);`
- **Refund previous pending bid** (push before rotate):
  - Take the previous balance: `let prev = balance::withdraw_all(&mut escrow.pending_bid);`
  - `let refunded_amount = balance::value(&prev);`
  - `transfer::public_transfer(coin::from_balance(prev, ctx), displaced_bidder);`
- **Rotate to new bid:**
  - `escrow.last_rent_price = new_bid_amount;`
  - `balance::join(&mut escrow.pending_bid, coin::into_balance(payment));`
  - `escrow.pending_tenant_address = some(new_bidder);`
- `handover_countdown_expiry` is **not** updated — subsequent bids do not
  reset the countdown (design-compact §4).
- `state` remains `Rented { HandoverConfirmed }`.
- Emit `BidSuperseded { escrow_id, displaced_bidder, refunded_amount,
  new_bidder, new_bid_amount }` — emit-last: all state rotations
  complete, so the escrow's post-state (new bidder installed, old
  refunded) matches the event's semantics.

#### Case: `Retired`

- Abort `E_RETIRED_NO_BID`. No refund path needed — payment is consumed by
  the abort (the coin in the PTB is returned to sender by Sui's abort
  semantics).

---

### 5.2 `apply_pending_transitions`

    public fun apply_pending_transitions<Asset: key + store, CoinType>(
        escrow: &mut RentalEscrow<Asset, CoinType>,
        clock:  &Clock,
        ctx:    &mut TxContext,
    ): AssetState

**Visibility:** `public`. Permissionless. Idempotent — a second call with no
elapsed time is a triple no-op.

**Purpose:** execute every elapsed lazy transition, in order. Returns the
settled `AssetState`.

**Algorithm — three sequential checks, O(1):**

```
// Check 1 — pending handover
if let Rented { phase: HandoverConfirmed } = escrow.state:
    let expiry = option::borrow(&escrow.handover_countdown_expiry);
    if clock.timestamp_ms() >= *expiry:
        do_handover(escrow, *expiry, ctx)
        // Post: state = Rented { HandoverOpen }
        // Post: phase_start_ms = expiry
        // Post: retire_flag unchanged (inherited by the new tenant)

// Check 2 — tenure expiry (reads state possibly mutated by Check 1)
if let Rented { .. } = escrow.state:
    let expiry = escrow.phase_start_ms + escrow.config.tenure_ceiling;
    if clock.timestamp_ms() >= expiry:
        do_tenure_expiry(escrow, expiry, ctx)
        // Post: state = AtDutchAuction, unless retire_flag → Retired
        // Post: phase_start_ms = expiry

// Check 3 — auction expiry (reads state possibly mutated by Check 2)
if escrow.state == AtDutchAuction:
    let expiry = escrow.phase_start_ms + escrow.config.descent_ceiling;
    if clock.timestamp_ms() >= expiry:
        do_auction_expiry(escrow, expiry)
        // Post: state = Idle
        // Post: phase_start_ms = expiry

return escrow.state
```

**Properties:**
- At most 3 transitions fire per call — structural property of the state
  machine (proved in design-compact §1 "At most 3 lazy transitions").
- Check ordering is mandatory: Check 2 would misfire on a stale
  `HandoverConfirmed` state if Check 1 is skipped. Check 3 requires Check 2
  to have moved the state to `AtDutchAuction`.
- Idle as a starting state is a fast path — Check 1 fails (not Rented),
  Check 2 fails (not Rented), Check 3 fails (not AtDutchAuction). No
  operations, no events.
- `Retired` as a starting state is also a fast path — all three checks fail.
- **`pending_bid` is never orphaned.** `rent()` clamps
  `handover_countdown_expiry = min(now + handover_floor, phase_start_ms +
  tenure_ceiling)`, so the handover boundary is always ≤ tenure boundary.
  The only case where both thresholds coincide (`remaining <= handover_floor`,
  producing `handover_countdown_expiry == phase_start_ms + tenure_ceiling`)
  is resolved by Check 1 firing first — by algorithm order — leaving state
  `HandoverOpen` and `pending_bid = 0` before Check 2 evaluates.

**Emits one event per boundary fired** (`HandoverCompleted`,
`TenureExpired`, `AuctionExpired`) at the boundary's exact timestamp —
not `clock.timestamp_ms()`. When the boundary fires in the same call as a rent/retire,
the caller observes the chain: e.g. `apply_pending_transitions` fires
`HandoverCompleted`, then `rent()` fires `BidPlaced` on the settled state.


6. ACCESS FUNCTIONS
--------------------

### 6.1 `borrow_asset`

    public fun borrow_asset<Asset: key + store, CoinType>(
        escrow:     &mut RentalEscrow<Asset, CoinType>,
        tenant_cap: &TenantCap,
        clock:      &Clock,
        ctx:        &mut TxContext,
    ): (Asset, AssetReceipt)

**Visibility:** `public`. Single in/out door between the protocol and the
integrating ecosystem.

**Behavior:**
1. `apply_pending_transitions(escrow, clock, ctx)` — settle first. A
   handover that completes here will rotate `current_tenant_cap_id` before
   the staleness check — the displaced tenant correctly fails.
2. Assert `tenant_cap::escrow_id(tenant_cap) == object::id(escrow)`,
   abort `E_TENANT_CAP_WRONG_ESCROW`.
3. Assert `escrow.current_tenant_cap_id ==
   some(object::id(tenant_cap))`, abort `E_TENANT_CAP_STALE`. This
   check rejects both stale caps (displaced tenants) and caps from other
   escrows (covered by step 2, but layered here for clarity).
4. Assert `option::is_some(&escrow.asset)`, abort `E_ASSET_ALREADY_BORROWED`.
   This is the only protocol state in which the internal `Option<Asset>` field
   can be `None` — when a previous `borrow_asset` call in the same PTB has
   already extracted the asset. Prevents a double-borrow from producing an
   opaque framework abort via `option::extract`.
   `let asset = option::extract(&mut escrow.asset);`
5. Construct `receipt = AssetReceipt { escrow_id: object::id(escrow),
   asset_id: object::id(&asset) }`.
6. Return `(asset, receipt)`.

**Why `return_asset` requires no cap re-verification:** `return_asset` can
only be called by a PTB that holds an `AssetReceipt`. An `AssetReceipt` can
only exist if `borrow_asset` was called and succeeded in the same PTB — the
hot-potato type makes it impossible to store, transfer, or fabricate. And
`borrow_asset` only succeeds for the current tenant (steps 2–3). The receipt
is therefore irrefutable proof that cap authorization was already verified.
No re-check is needed.

**PTB clock-fixity — supporting invariant:** Sui fixes `clock::timestamp_ms()`
at checkpoint time; it does not advance between PTB steps. Any handover due
at that timestamp was already resolved by `apply_pending_transitions` in
step 1. No new transitions can fire within the same transaction, so
`current_tenant_cap_id` cannot rotate after the receipt is issued. This
explains why no state change can have occurred between the two calls —
but the primary authorization argument is the receipt itself.

**No event emitted.** Borrow is a PTB-internal event with no observable
state change across transactions; the receipt is consumed in the same PTB.

---

**PTB borrow window — where the tenant actually uses the asset:**

This window is the core value exchange of the entire protocol. To understand
it, three actors and two protocols must be distinguished:

**Actors:**

- **Integrating protocol** — the protocol that issued the asset and defines
  what it does (a game, a marketplace, a DeFi app). Its functions take the
  asset as an argument and give it meaning. It has no knowledge of rental
  terms, tenants, or escrow state. It does not import `rental_escrow`.
- **Owner** — the current holder of the asset who placed it into the escrow
  via `integrate`. The owner may be the same entity as the integrating
  protocol (e.g. the game studio renting out its own items) or a completely
  independent actor (e.g. a user who bought the asset on a secondary market
  and now wants to rent it out). The two do not need to coincide.
- **Tenant** — the user who paid `rent()` and holds `TenantCap`. They
  acquire temporary access to use the asset through the integrating
  protocol's functions for the duration of their tenure.

**Protocols:**

- **`rental_escrow`** — the rental market layer. Generic over
  `Asset: key + store`. Owns custody, enforces payment and time bounds,
  manages the state machine. Has no knowledge of what the asset does.
- **Integrating protocol** — defines the asset's utility. Has no knowledge
  of rental terms or escrow state. Was not modified to support renting.

The owner bridges the two at setup time: they call `integrate`, moving the
asset out of their wallet and into `rental_escrow`. From that point,
`rental_escrow` holds custody and tenants can rent it.

The tenant bridges the two at use time — and this window is that moment:

```
  ┌─ rental_escrow ──────────────────────────────────────────────────┐
  │                                                                  │
  │  PTB step N:  borrow_asset(escrow, tenant_cap, clock, ctx)       │
  │                   → (asset, receipt)                             │
  │                          │                                       │
  └──────────────────────────┼───────────────────────────────────────┘
                             │  asset crosses the protocol boundary
                             ▼
  ┌─ integrating protocol ───────────────────────────────────────────┐
  │                                                                  │
  │  PTB steps (N+1 … M-1)                                          │
  │                                                                  │
  │  The tenant — the person who paid `rent()` and holds            │
  │  `TenantCap` — calls the integrating protocol's own             │
  │  functions, passing `asset` by value. This is the actual        │
  │  use the tenant paid for: play with a game item, interact        │
  │  with a marketplace listing, exercise a DeFi position, etc.     │
  │                                                                  │
  │  `receipt` must be threaded through unconsumed.                  │
  │                                                                  │
  │  In practice, the integrating protocol's app constructs this     │
  │  PTB for the tenant — the tenant interacts with the app's UI,   │
  │  not with the raw PTB steps. The borrow/return wrapping is an   │
  │  implementation detail the integrating protocol abstracts away.  │
  │                                                                  │
  └──────────────────────────┬───────────────────────────────────────┘
                             │  asset crosses back
                             ▼
  ┌─ rental_escrow ──────────────────────────────────────────────────┐
  │                                                                  │
  │  PTB step M:  return_asset(escrow, asset, receipt)               │
  │                                                                  │
  └──────────────────────────────────────────────────────────────────┘
```

The hot-potato `AssetReceipt` structurally enforces this window: the PTB
cannot type-check unless `receipt` is consumed by `return_asset` before the
transaction boundary. The asset cannot be stored, transferred, or dropped
inside the window — it must be passed by value and returned. The tenant
cannot extend the window beyond a single PTB.

This composition is zero-overhead for the integrating protocol: it requires
no changes, imports no `rental_escrow` types, and is unaware that its asset
is being rented. Any protocol that uses `key + store` objects gains a rental
market by integrating with `rental_escrow`.

**Note on integration levels:** the integrating protocol never needs to
change any contract code. The decoupling is complete: the asset is the
only interface between the two protocols, and the integrating protocol's
functions work identically whether the asset comes from an owner's wallet
or from a liquid renting escrow. A power-user tenant can always construct
the PTB manually — `borrow_asset`, call the integrating protocol's
functions, `return_asset` — with zero involvement from the integrating
protocol.

For non-power-user tenants, the liquid renting SDK provides a tool to
construct this PTB without exposing the escrow mechanics. The SDK operates
exclusively at the frontend/backend layer — it generates PTBs, never
deploys or modifies blockchain code. An integrating protocol that wants to
surface liquid renting natively in its own app can adopt the SDK
optionally, abstracting the borrow window entirely from its users. This is
a UX choice, not a technical requirement. A protocol that has never heard
of liquid renting is already compatible at the contract level.

---

### 6.2 `return_asset`

    public fun return_asset<Asset: key + store, CoinType>(
        escrow:  &mut RentalEscrow<Asset, CoinType>,
        asset:   Asset,
        receipt: AssetReceipt,
    )

**Visibility:** `public`. Consumes the hot-potato receipt.

**Behavior:**
1. Destructure `receipt`: `let AssetReceipt { escrow_id, asset_id } = receipt;`
2. Assert `escrow_id == object::id(escrow)`, abort
   `E_RECEIPT_ESCROW_MISMATCH`. Enforces return to the correct escrow.
3. Assert `asset_id == object::id(&asset)`, abort
   `E_RECEIPT_ASSET_MISMATCH`. Enforces return of the exact asset borrowed.
4. `option::fill(&mut escrow.asset, asset);`
5. Does **not** call `apply_pending_transitions` — returning an asset never
   needs to resolve boundary events; no balance is touched, no state field
   changes. The PTB clock-fixity invariant (§6.1) guarantees no new
   transition can have fired since `borrow_asset` ran in the same PTB.

**No event emitted.** Same rationale as `borrow_asset`.


7. PRIVATE HELPERS
-------------------

All helpers are private (`fun`) — visible only within `rental_escrow`.

### 7.1 `do_handover`

    fun do_handover<Asset: key + store, CoinType>(
        escrow:       &mut RentalEscrow<Asset, CoinType>,
        boundary_ms:  u64,       // = handover_countdown_expiry
        ctx:          &mut TxContext,
    )

**Preconditions:** `escrow.state == Rented { HandoverConfirmed }` and
`boundary_ms` equals the stored `handover_countdown_expiry`.

**Algorithm:**

1. Let `used_credit = compute_used_credit(escrow, boundary_ms)` — §8.1 is the
   single source of truth for "used credit at timestamp T". Its state guard
   and `HandoverConfirmed` clamp are structurally satisfied here: Check 1 of
   `apply_pending_transitions` already confirmed
   `state == Rented { HandoverConfirmed }`, and
   `boundary_ms == handover_countdown_expiry` makes the clamp a no-op. The
   principal used is `balance::value(&escrow.tenant_stake)` (see §8.1 for
   why `tenant_stake` and not `last_rent_price`).
2. Let `remain_credit = balance::value(&escrow.tenant_stake) - used_credit`.
   (Invariant `used_credit + remain_credit == tenant_stake` from curve
   bijectivity.)
3. Compute `(owner_share, protocol_fee) = split_fee(used_credit)` — §7.4.
4. **Take funds before any address rotation** (push-before-rotate invariant):
   - `let displaced_tenant = *option::borrow(&escrow.current_tenant_address);`
   - `if remain_credit > 0`:
     - `let remain_balance = balance::split(&mut escrow.tenant_stake, remain_credit);`
     - `transfer::public_transfer(coin::from_balance(remain_balance, ctx), displaced_tenant);`
     // When countdown == remaining_rent_time the curve saturates:
     // used_credit == tenant_stake and remain_credit == 0. Skipping the split
     // avoids creating a zero Balance that Move requires to be consumed.
     // Consequence of `countdown = min(escrow.config.handover_floor, remaining)`.
   - `if protocol_fee > 0`:
     - `let fee_balance = balance::split(&mut escrow.tenant_stake, protocol_fee);`
     - `let msg = fee_message::new<CoinType>(fee_balance, escrow.fee_inbox_id, object::id(escrow), ctx);`
     - `fee_message::send_message(msg, displaced_tenant);`
     // `displaced_tenant` is the stake funder — already bound at step 4.
     // The resulting `FeeMessageSent<C>.tenant` records whose elapsed-time
     // consumption produced this fee.
     // Gate mirrors the `remain_credit > 0` branch above: when `protocol_fee == 0`
     // we skip the split entirely instead of creating and destroying a zero
     // `Balance<CoinType>`. No `FeeMessage<C>` is constructed on the zero path.
   - Remaining `escrow.tenant_stake` = `owner_share` exactly. Move it into
     `owner_earnings` via `balance::join(&mut escrow.owner_earnings,
     balance::withdraw_all(&mut escrow.tenant_stake))`.
5. **Rotate `pending_bid` → `tenant_stake`** (new tenant's stake):
   - `balance::join(&mut escrow.tenant_stake,
     balance::withdraw_all(&mut escrow.pending_bid));`
   — `last_rent_price` already holds the pending bid amount (set at bid time).
6. **Mint + push new TenantCap:**
   - `let pending_addr = *option::borrow(&escrow.pending_tenant_address);`
   - `let cap = tenant_cap::new(object::id(escrow), pending_addr, ctx);`
     — `TenantCapMinted.tenant` records `pending_addr`, the new tenant
     installed by this handover. The address is not `tx_context::sender`
     (the caller of `apply_pending_transitions` may be a keeper or any
     permissionless settler, not the incoming tenant).
   - `let new_cap_id = object::id(&cap);`
   - `transfer::transfer(cap, pending_addr);`
7. **Rotate address fields:**
   - `escrow.current_tenant_address = some(pending_addr);`
   - `escrow.current_tenant_cap_id = some(new_cap_id);`
   - `escrow.pending_tenant_address = none();`
8. **Reset phase anchors for the new tenant:**
   - `escrow.phase_start_ms = boundary_ms;`
   - `escrow.handover_countdown_expiry = none();`
   - `escrow.state = Rented { phase: HandoverOpen };`
9. Emit `HandoverCompleted { escrow_id, displaced_tenant,
   new_tenant_cap_id, used_credit, owner_share, protocol_fee, remain_credit,
   timestamp_ms: boundary_ms }`. The new tenant's address is not
   carried — it is already on the co-emitted `TenantCapMinted.tenant`
   row and recoverable by JOIN on `new_tenant_cap_id`.
   `displaced_tenant` *is* carried: no PK path reaches the outgoing
   cap from this row, so recovering it via JOIN would force
   envelope-timing reconstruction (violating invariant d).

**Edge cases — both extremes fall out of the two `if ... > 0` guards above
(`remain_credit`, `protocol_fee`):**

- **`used_credit == 0`** (very convex curve, handover fires very early):
  `remain_credit == tenant_stake > 0`. The `if remain_credit > 0` guard fires —
  the full stake is pushed to the displaced tenant as `Coin<C>`. `split_fee(0)`
  returns `(0, 0)`, so the `if protocol_fee > 0` guard is skipped — no fee
  split and no `FeeMessage<C>` construction. `withdraw_all` on the now-empty
  stake returns `Balance(0)`; `join` into `owner_earnings` is a no-op. No
  zero-value coin transfer occurs.

- **`used_credit == tenant_stake`** (Dutch Auction bypass — curve saturated,
  `remain_credit == 0`): the `if remain_credit > 0` guard is skipped — no coin
  is pushed to the displaced tenant. `split_fee(tenant_stake)` produces the
  normal 95/5 split, so the `if protocol_fee > 0` guard fires —
  `fee_message::new` + `send_message` routes a non-zero `FeeMessage<C>` and
  `withdraw_all` moves the owner share into `owner_earnings`.

In the `used_credit == 0` branch, after the full-stake push to the displaced
tenant the stake is empty. `balance::withdraw_all(Balance(0))` returns
`Balance(0)` and `balance::join(_, Balance(0))` is a no-op — both are valid
operations against the framework source (`withdraw_all` delegates to
`split(self, self.value)`, and `split` asserts `self.value >= value` which
holds for 0). No zero-valued `Balance<CoinType>` is ever handed to
`fee_message::new`: the `if protocol_fee > 0` guard filters those out at the
call site.

---

### 7.2 `do_tenure_expiry`

    fun do_tenure_expiry<Asset: key + store, CoinType>(
        escrow:      &mut RentalEscrow<Asset, CoinType>,
        boundary_ms: u64,       // = phase_start_ms + tenure_ceiling
        ctx:         &mut TxContext,
    )

**Preconditions:** `escrow.state == Rented { HandoverOpen }`. Guaranteed by
the ordering of `apply_pending_transitions`: Check 1 always executes before
Check 2. The clamp in `rent()` — `countdown = min(handover_floor, remaining)`
— ensures `handover_countdown_expiry <= phase_start_ms + tenure_ceiling`.
Two cases:
- `remaining > handover_floor`: handover fires strictly before tenure expiry.
  Check 2 sees `HandoverOpen` with a fresh `phase_start_ms` and does not fire.
- `remaining <= handover_floor`: both boundaries coincide at
  `phase_start_ms + tenure_ceiling`. Check 1 fires first, resetting
  `phase_start_ms` to `boundary_ms`. Check 2 evaluates against the new
  `phase_start_ms + tenure_ceiling` — in the future — and does not fire.
  T(n+1) receives a full tenure.

**Algorithm:**

1. Let `stake_total = balance::value(&escrow.tenant_stake)` — equal to
   `escrow.last_rent_price` (used_credit saturated to full).
2. Let `tenant = *option::borrow(&escrow.current_tenant_address);`
3. Compute `(owner_share, protocol_fee) = split_fee(stake_total)`.
4. Route the protocol fee through `fee_message`, gating on `protocol_fee > 0`:
   - `if protocol_fee > 0`:
     - `let fee_balance = balance::split(&mut escrow.tenant_stake, protocol_fee);`
     - `let msg = fee_message::new<CoinType>(fee_balance, escrow.fee_inbox_id, object::id(escrow), ctx);`
     - `fee_message::send_message(msg, tenant);`
     // `tenant` is the outgoing tenant's address — bound at step 2.
     // The resulting `FeeMessageSent<C>.tenant` records whose stake funded
     // this fee (full saturation at tenure expiry).
   - Same pattern as §7.1: skip the split entirely when the fee rounds to
     zero (reachable only at pathological `stake_total < 20`, since fee =
     `mul_div(stake, 500, 10_000)`; protocols enforcing `min_rent_price ≥ 20`
     will never see this branch, but the gate keeps the function structurally
     total).
5. Move remaining stake into earnings:
   `balance::join(&mut escrow.owner_earnings,
    balance::withdraw_all(&mut escrow.tenant_stake));`
6. **Clear tenant fields** (no new tenant to register):
   - `escrow.current_tenant_cap_id = none();`
   - `escrow.current_tenant_address = none();`
7. **Determine next state:**
   - If `escrow.retire_flag`: `escrow.state = Retired`.
     `escrow.phase_start_ms = boundary_ms;` (bookkeeping).
   - Else: `escrow.state = AtDutchAuction;
     escrow.phase_start_ms = boundary_ms;`.
     `last_rent_price` is preserved — it is the starting price of the descent.
8. Emit `TenureExpired { escrow_id, tenant, owner_share, protocol_fee,
   next_state: escrow.state, timestamp_ms: boundary_ms }`.

**Note:** the displaced tenant's `TenantCap` is not burned here. It becomes
stale (ID no longer matches `current_tenant_cap_id` which is now `None`) and
is inert. The holder may call `tenant_cap::burn` voluntarily for gas
recovery.

---

### 7.3 `do_auction_expiry`

    fun do_auction_expiry<Asset: key + store, CoinType>(
        escrow:      &mut RentalEscrow<Asset, CoinType>,
        boundary_ms: u64,       // = phase_start_ms + descent_ceiling
    )

**Preconditions:** `escrow.state == AtDutchAuction`.

**Algorithm:**

1. No balances to move — no funds were placed at auction entry.
2. `escrow.state = Idle`.
3. `escrow.phase_start_ms = boundary_ms;`
4. Emit `AuctionExpired { escrow_id, next_state: escrow.state,
   timestamp_ms: boundary_ms }`.

**Note on `last_rent_price`:** not modified here. After auction expiry,
`last_rent_price` holds what the last tenant paid. The next `rent()` from Idle
overwrites it with the actual payment (`>= min_rent_price`) as part of its
normal acquisition logic.

---

### 7.4 `split_fee`

    fun split_fee(amount: u64): (u64, u64)

**Purpose:** pure function that splits an amount into (owner_share,
fee_share) at 95/5.

**Algorithm:**

    let fee   = math::mul_div(amount, 500, 10_000);   // 5% = 500 bps
    let owner = amount - fee;
    (owner, fee)

**Properties:**
- `owner + fee == amount` always (no rounding loss — subtraction is exact).
- `fee <= floor(amount * 0.05)` — floor rounding favors the owner by at most
  1 base unit. Economically negligible; structurally simple.
- `split_fee(0) == (0, 0)`.
- `split_fee(1) == (1, 0)` — fee floors to zero on tiny amounts. Callers
  (`do_handover`, `do_tenure_expiry`) gate on `protocol_fee > 0` and skip the
  split + `fee_message::new` when it is zero, so no zero-balance `FeeMessage<C>`
  is ever constructed.

---

### 7.5 `install_new_tenant`

    fun install_new_tenant<Asset: key + store, CoinType>(
        escrow:  &mut RentalEscrow<Asset, CoinType>,
        payment: Coin<CoinType>,
        clock:   &Clock,
        ctx:     &mut TxContext,
    ): ID

**Preconditions:** `escrow.state` is one of `{ Idle, AtDutchAuction }`. The
caller has already validated `payment` against the applicable floor
(`config.min_rent_price` for Idle, `compute_price_descent(..., now)` for
AtDutchAuction).

**Purpose:** shared installation sequence for the two acquisition arms of
`rent()` that land on an empty escrow — mint `TenantCap`, absorb payment,
anchor the new phase, transition to `Rented { HandoverOpen }`. Both arms
produce structurally identical post-state; the only arm-specific signal is
the `from_state` field of the emitted `RentStarted` event, which the caller
owns.

**Algorithm:**

1. `escrow.last_rent_price = coin::value(&payment);`
2. `balance::join(&mut escrow.tenant_stake, coin::into_balance(payment));`
3. `escrow.phase_start_ms = clock.timestamp_ms();`
4. `let tenant_addr = tx_context::sender(ctx);`
5. `let cap = tenant_cap::new(object::id(escrow), tenant_addr, ctx);` —
   `TenantCapMinted.tenant` records `tenant_addr`. Unlike `do_handover`,
   here the sender IS the new tenant (paid `rent()` directly), so passing
   the sender is correct and matches the transfer target below.
6. `let new_cap_id = object::id(&cap);`
7. `escrow.current_tenant_cap_id = some(new_cap_id);`
8. `escrow.current_tenant_address = some(tenant_addr);`
9. `escrow.state = Rented { phase: HandoverOpen };`
10. `transfer::transfer(cap, tenant_addr);`
11. Return `new_cap_id`.

**Return value:** the new `TenantCap` ID, returned so the caller can emit
`RentStarted { ..., tenant_cap_id: new_cap_id, ... }` with its arm-specific
`from_state`.

**Why the helper does not emit `RentStarted`:** the event's `from_state`
field discriminates between `Idle` and `AtDutchAuction` callers. Keeping
the emit at each arm preserves that signal explicitly at the callsite
instead of threading an extra `from_state` argument through the helper.

**Two call sites:**

| Caller | Floor source | Event `from_state` |
|---|---|---|
| `rent()` Case `Idle` (§5.1) | `config.min_rent_price` | `AssetState::Idle` |
| `rent()` Case `AtDutchAuction` (§5.1) | `compute_price_descent(escrow, clock.timestamp_ms())` | `AssetState::AtDutchAuction` |

Both arms share the same post-state; the helper is the single source of
truth for "install a new tenant from payment into an empty escrow".

**Not reused by `do_handover`:** `do_handover` also mints a `TenantCap` and
transitions to `HandoverOpen`, but the surrounding state differs
structurally — `pending_bid` rotates into `tenant_stake` (not a fresh
payment), the target address is `pending_tenant_address` (not
`sender(ctx)`), and `phase_start_ms = boundary_ms` (not `clock.now()`).
Merging the two would force context-dependent branching inside the helper
and obscure the distinct semantics of each rotation site.


8. READ-ONLY QUERIES
---------------------

All read-only functions are `public`. They do not mutate the escrow.
Via `devInspectTransactionBlock` they execute for free with no consensus
involvement. In a regular PTB, taking `&RentalEscrow` (shared object) still
requires consensus, but read-only transactions on the same object can execute
in parallel without ordering between them — reducing contention compared to
mutable access.

**Reading settled state:** use `apply_pending_transitions` via
`devInspectTransactionBlock`. It resolves all pending transitions and returns
the settled `AssetState` without committing the transaction — free, no
consensus. This is more correct than a dedicated read-only query because it
reflects the actual settled state, not a speculative computation.

**Naming convention — `compute_*`:**

All protocol-level read-only queries use the `compute_*` prefix uniformly.
`compute_X(escrow, ...)` reads as "compute the value of X from the escrow's
state (and the supplied inputs)" — an honest description regardless of
whether a timestamp is passed:

- `compute_used_credit(escrow, timestamp_ms)` (§8.1) and
  `compute_price_descent(escrow, timestamp_ms)` (§8.2) take an arbitrary
  timestamp and evaluate at that instant — not necessarily `clock.now()`.
  External callers typically pass `clock.timestamp_ms()` for "live" reads,
  but internal callers (e.g. `do_handover` passing `boundary_ms`) evaluate
  at past or boundary timestamps.
- `compute_next_rent_price(escrow)` (§8.3) depends only on escrow state,
  so it needs no timestamp.

The `current_*` prefix is deliberately not used: it implies "now", and
a function accepting an arbitrary timestamp — or that any external caller
may inspect at an arbitrary point in a PTB — lies under that prefix.
Uniform `compute_*` keeps one convention for three functions that all do
the same thing semantically: produce a value from escrow state.

### 8.1 `compute_used_credit`

    public fun compute_used_credit<Asset: key + store, CoinType>(
        escrow:       &RentalEscrow<Asset, CoinType>,
        timestamp_ms: u64,
    ): u64

**Algorithm:**

    // 1. State guard — only meaningful in Rented state.
    assert!(matches!(escrow.state, AssetState::Rented { .. }), E_NOT_RENTED);

    // 2. Clamp to handover boundary when in HandoverConfirmed.
    //    Past that point the current tenant's stake is no longer growing —
    //    the boundary is where their credit froze.
    let effective_ts =
        if let Rented { HandoverConfirmed } = escrow.state {
            let expiry = *option::borrow(&escrow.handover_countdown_expiry);
            std::u64::min(timestamp_ms, expiry)
        } else {
            timestamp_ms  // HandoverOpen: evaluate_curve saturates at tenure_ceiling
        };

    // 3. Elapsed time since the current phase started.
    //    If effective_ts < phase_start_ms (caller passed a timestamp before the phase
    //    began), return 0 — no credit consumed yet.
    if effective_ts < escrow.phase_start_ms { return 0 };
    let elapsed_ms = effective_ts - escrow.phase_start_ms;

    // 4. Evaluate the normalized credit curve.
    let g = curve_shape::evaluate_curve(
        config::credit_curve(&escrow.config),
        elapsed_ms,
        config::tenure_ceiling(&escrow.config),
    );

    // 5. Scale by the current tenant's principal.
    //    Principal is tenant_stake, not last_rent_price: in HandoverConfirmed
    //    last_rent_price already holds the pending bid amount, making
    //    tenant_stake the only accurate source for the current tenant's payment.
    //    evaluate_curve returns SCALE when elapsed >= tenure_ceiling, so the
    //    scaled result saturates at tenant_stake.
    math::mul_div(balance::value(&escrow.tenant_stake), g, SCALE)

**Two call sites:**

| Caller | `timestamp_ms` passed | Purpose |
|---|---|---|
| `do_handover` (internal, §7.1) | `handover_countdown_expiry` | used_credit at the exact boundary — clamp is a no-op; state guard is structurally satisfied |
| Frontend / read query (external) | `clock.timestamp_ms()` | live display of accrued credit |

Internal and external callers share the same function to guarantee a single
source of truth for "used credit at timestamp T". The state guard and the
`HandoverConfirmed` clamp are defensive — they protect against wrong-state
external calls and unsettled boundaries. For `do_handover` both are
structurally satisfied and evaluate as no-ops.

---

### 8.2 `compute_price_descent`

    public fun compute_price_descent<Asset: key + store, CoinType>(
        escrow:       &RentalEscrow<Asset, CoinType>,
        timestamp_ms: u64,
    ): u64

Only meaningful when `escrow.state == AtDutchAuction`. Returns
`min_rent_price` once the descent saturates.

**Algorithm:**

    // 1. State guard — only meaningful in AtDutchAuction state.
    assert!(escrow.state == AssetState::AtDutchAuction, E_NOT_AUCTION);

    // 2. Elapsed time since the auction started.
    //    phase_start_ms is set to the tenure-expiry boundary when AtDutchAuction begins.
    //    If timestamp_ms < phase_start_ms, return last_rent_price — auction has not started yet.
    if timestamp_ms < escrow.phase_start_ms { return escrow.last_rent_price };
    let elapsed_ms = timestamp_ms - escrow.phase_start_ms;

    // 3. Evaluate the normalized descent curve.
    let h = curve_shape::evaluate_curve(
        config::descent_curve(&escrow.config),
        elapsed_ms,
        config::descent_ceiling(&escrow.config),
    );

    // 4. Scale by the spread, then descend from last_rent_price.
    //    evaluate_curve returns SCALE when elapsed >= descent_ceiling, so
    //    consumed == spread and the result saturates at min_rent_price.
    //    Precondition last_rent_price >= min_rent_price is guaranteed by the
    //    protocol — every acquisition asserts payment >= arm-specific floor,
    //    and all floors (min_rent_price, compute_price_descent, compute_next_rent_price)
    //    are themselves >= min_rent_price. Note last_rent_price does NOT
    //    monotonically increase: a rent from AtDutchAuction can write a value
    //    below the previous last_rent_price (but still >= min_rent_price).
    let spread = escrow.last_rent_price - config::min_rent_price(&escrow.config);
    let consumed = math::mul_div(spread, h, SCALE);
    escrow.last_rent_price - consumed

`last_rent_price` is the starting price of the descent — it was set by the
last tenant's payment and preserved through tenure expiry and auction entry.

---

### 8.3 `compute_next_rent_price`

    public fun compute_next_rent_price<Asset: key + store, CoinType>(
        escrow: &RentalEscrow<Asset, CoinType>,
    ): u64

Only meaningful when `escrow.state == Rented`. No `timestamp_ms` parameter —
`f_next_rent_price` depends only on `last_rent_price`, not on elapsed time.

**Algorithm:**

    // Guard — only meaningful in Rented state.
    assert!(matches!(escrow.state, AssetState::Rented { .. }), E_NOT_RENTED);

    price_function::evaluate_price_fn(
        config::price_function(&escrow.config),
        escrow.last_rent_price,
    )

In `HandoverConfirmed`, `last_rent_price` already holds the pending bidder's
payment — so `compute_next_rent_price` returns the price to supersede the
pending bidder, not the current tenant.


9. PROPERTIES
-------------

The following hold for any `RentalEscrow` whose lifecycle flows exclusively
through the public API.

**P1 — Fund conservation at every boundary:**
For every `do_handover` call: `used_credit + remain_credit == tenant_stake`
(the current tenant's payment), and
`owner_share + protocol_fee == used_credit` (split_fee is exact).
For every `do_tenure_expiry` call: `owner_share + protocol_fee ==
tenant_stake_at_expiry`.

**P2 — No trapped balances at terminal state:**
When `state == Retired`, `tenant_stake == 0` and `pending_bid == 0`.
`claim_asset` enforces this structurally via `balance::destroy_zero`.

**P3 — Push-before-rotate:**
Inside `do_handover`, every push (`remain_credit` → current_tenant_address,
`TenantCap` → pending_tenant_address) occurs before its corresponding
address field is overwritten. No loss of delivery target across the
handover window.

**P4 — At most three lazy transitions per call:**
`apply_pending_transitions` executes at most `do_handover` +
`do_tenure_expiry` + `do_auction_expiry` in a single call. Bounded gas.

**P5 — Check order is a safety invariant:**
Check 1 before Check 2 before Check 3 in `apply_pending_transitions`.
Reordering would create `pending_bid` orphan windows or miss intermediate
earnings splits.

**P6 — Retire flag is monotonic:**
Once `retire_flag` is set, it stays set. No function clears it. All lazy
transitions on a flagged escrow terminate in `Retired` rather than
`Idle` / `AtDutchAuction`.

**P7 — OwnerCap uniqueness:**
Exactly one live `OwnerCap` per escrow at any time. Minted once in
`integrate`, burned once in `claim_asset`. Enforced by visibility of
`owner_cap::new(escrow_id, owner, ctx)` / `owner_cap::burn(cap, ctx)`
(both `public(package)` with a single call site each). The recipient
and burner addresses are recorded in `OwnerCapMinted` / `OwnerCapBurned`
respectively so the cap's full lifecycle is reconstructible from the
event stream alone.

**P8 — TenantCap staleness is inert:**
Displaced tenants' `TenantCap` objects remain in their wallets but fail
`current_tenant_cap_id` check in `borrow_asset`. No protocol state is
corrupted by the presence of stale caps.

**P9 — Tenancy ↔ Rented state:**
`escrow.current_tenant_cap_id.is_some()` ⇔ `escrow.state` matches
`Rented(_)`. Both are set together in `rent()`/`do_handover` and cleared
together in `do_tenure_expiry`.

**P10 — Pending bid ↔ HandoverConfirmed:**
`balance::value(&escrow.pending_bid) > 0` ⇔ `escrow.state == Rented {
HandoverConfirmed }`. Both set together in `rent()` (takeover path) and
cleared together in `do_handover`.

**P11 — Asset present while escrow exists:**
A protocol guarantee, not a structural type guarantee. `escrow.asset` is
`Option<Asset>`; `None` exists only within a PTB borrow window
(`borrow_asset` → `return_asset`), never across transaction boundaries.
Enforced by the hot-potato `AssetReceipt`.

**P12 — Fee routing is idempotent at zero:**
`do_handover` with `used_credit == 0` (e.g. handover at t = phase_start_ms,
pathological edge case) and `do_tenure_expiry` with zero stake produce
`protocol_fee == 0`. Both functions gate the `fee_message::new` +
`send_message` pair behind `if protocol_fee > 0`, so no `FeeMessage<C>` is
constructed on the zero path. The escrow balances settle to their normal
post-condition via the owner-share branch alone.

10. TEST CASES
--------------

### 10.1 Integration

| # | Description | Expected |
|---|---|---|
| T1 | `integrate<SomeAsset, C>` with a valid config and fee_ref | Returns `OwnerCap`. `RentalEscrow` shared. `state == Idle`. `last_rent_price == config.min_rent_price`. `phase_start_ms == 0`. `integrated_at_ms == clock.timestamp_ms()`. `fee_inbox_id == object::id(&protocol_fee_inbox)`. `AssetIntegrated` event emitted. |
| T2 | `integrate<OwnerCap, C>` (deposit an existing escrow's cap) | Succeeds. Returns a second `OwnerCap` for the wrapping escrow. The wrapped cap becomes the wrapping escrow's `asset`. No depth check. |

### 10.2 `rent` — Idle path

| # | Description | Expected |
|---|---|---|
| R1 | Pay exactly `min_rent_price` | State → `Rented(HandoverOpen)`. `last_rent_price == min_rent_price`. `TenantCap` pushed to sender. `RentStarted` event. |
| R2 | Pay less than `min_rent_price` | Aborts `E_INSUFFICIENT_PAYMENT`. |
| R3 | Overpay from Idle | Accepted. `last_rent_price == full payment`. State → `Rented(HandoverOpen)`. |
| R4 | Rent when `retire_flag` set and state was Idle | State was moved to `Retired` by the prior `retire()` call (§4.2 step 6, Idle branch); `apply_pending_transitions` is a no-op here. Dispatch hits the `Retired` arm → aborts `E_RETIRED_NO_BID`. |

### 10.3 `rent` — AtDutchAuction path

| # | Description | Expected |
|---|---|---|
| R5 | Pay exactly `compute_price_descent(now)` | State → `Rented(HandoverOpen)`. `last_rent_price == payment`. `RentStarted{ from_state: AtDutchAuction }`. |
| R6 | Overpay (e.g. PTB latency) | Accepted. `last_rent_price == full payment`. No refund. |
| R7 | Underpay | Aborts `E_INSUFFICIENT_PAYMENT`. |
| R8 | Descent fully elapsed, pay `min_rent_price` | State → `Rented(HandoverOpen)`. |

### 10.4 `rent` — Rented(HandoverOpen) takeover path

| # | Description | Expected |
|---|---|---|
| R9 | Pay exactly `next_rent_price` | State → `Rented(HandoverConfirmed)`. `handover_countdown_expiry` set. `BidPlaced` event. |
| R10 | Overpay above `next_rent_price` | Accepted. `pending_bid == full payment`. `BidPlaced` event. |
| R11 | Bid with `retire_flag` set | Aborts `E_RETIRE_FLAG_BLOCKS_BID`. |
| R12 | Remaining rent time <= `handover_floor` (Dutch auction bypass) | `handover_countdown_expiry == phase_start_ms + tenure_ceiling`. |

### 10.5 `rent` — Rented(HandoverConfirmed) supersede path

| # | Description | Expected |
|---|---|---|
| R13 | New bid supersedes pending | Previous pending refunded to previous address. `pending_bid == new bid`. `pending_tenant_address == new bidder`. `handover_countdown_expiry` unchanged. `BidSuperseded` event. |
| R14 | Supersede with retire_flag set | Allowed — flag was set after this pending bid committed; the bid is honored. |
| R15 | Supersede with insufficient amount | Aborts `E_INSUFFICIENT_PAYMENT`. |

### 10.6 `apply_pending_transitions`

| # | Description | Expected |
|---|---|---|
| A1 | Called on Idle, no time elapsed | No-op. Returns `Idle`. No events. |
| A2 | Called on Rented(HandoverConfirmed), handover expiry reached | `do_handover` fires. Returns `Rented(HandoverOpen)`. `HandoverCompleted` emitted with `timestamp_ms == boundary`. |
| A3 | Called on Rented(HandoverOpen), tenure expiry reached | `do_tenure_expiry` fires. Returns `AtDutchAuction`. `TenureExpired` emitted. |
| A4 | Called on AtDutchAuction, descent expiry reached | `do_auction_expiry` fires. Returns `Idle`. `AuctionExpired` emitted. |
| A5 | Called after long inactivity: handover + tenure + auction all due | All three fire in order. Returns `Idle`. Three events emitted. |
| A6 | Called with retire_flag, Rented(HandoverOpen), tenure expired | `do_tenure_expiry` fires with `next_state: Retired`. Returns `Retired`. |
| A7 | `do_handover` with `used_credit == 0` (very convex PowerLaw curve, handover fires immediately after bid) | `remain_credit == tenant_stake`. Full stake pushed to displaced tenant as `Coin<C>`. `owner_earnings` unchanged. No `FeeMessage<C>` constructed (the `if protocol_fee > 0` guard skips `fee_message::new` + `send_message`). `HandoverCompleted` emitted with `used_credit: 0`, `owner_share: 0`, `protocol_fee: 0`. |
| A8 | `do_handover` with `used_credit == tenant_stake` (Dutch Auction bypass — `remain_credit == 0`) | No coin pushed to displaced tenant. Full stake split 95/5 into `owner_earnings` and `FeeMessage`. `HandoverCompleted` emitted with `remain_credit: 0`. |

### 10.7 `borrow_asset` / `return_asset`

| # | Description | Expected |
|---|---|---|
| B1 | Borrow with valid current cap | Returns `(asset, receipt)`. |
| B2 | Return via correct receipt + same asset | Asset back in escrow. Receipt consumed. |
| B3 | Borrow with a stale cap (previous tenant after handover) | Aborts `E_TENANT_CAP_STALE`. |
| B4 | Borrow with cap for a different escrow | Aborts `E_TENANT_CAP_WRONG_ESCROW`. |
| B5 | Return with receipt for a different escrow | Aborts `E_RECEIPT_ESCROW_MISMATCH`. |
| B6 | Return a different asset (substitution attempt) | Aborts `E_RECEIPT_ASSET_MISMATCH`. |
| B7 | Forget to return (receipt unconsumed) | PTB fails to type-check — hot potato must be consumed. |
| B8 | `borrow_asset` called twice in the same PTB | Second call aborts `E_ASSET_ALREADY_BORROWED` — asset field is `None` after the first extraction. |
| B9 | `borrow_asset` called by T(n) with T(n)'s cap when pre-APT state is `Rented(HandoverConfirmed)` and handover has expired — APT fires C1 rotating `current_tenant_cap_id` to T(n+1) before the staleness check | Split-tx per §10.13 abort-row strategy. **tx1** (standalone `apply_pending_transitions`): fires `do_handover` — T(n+1) installed, `current_tenant_cap_id` rotates to T(n+1)'s cap ID, `HandoverCompleted` emitted, `owner_earnings` credited, new `TenantCap` pushed to T(n+1), state → `Rented(HandoverOpen)`. **tx2** (`borrow_asset` with T(n)'s cap): §6.1 step 2 passes (cap belongs to this escrow), step 3 fails — `current_tenant_cap_id` now holds T(n+1)'s ID, not T(n)'s — aborts `E_TENANT_CAP_STALE`. Distinct from B3 (cap that was already stale pre-call): here the cap becomes stale **during** the call via APT's own work. Asserts §6.1 step 1 runs before step 3. |
| B10 | `borrow_asset` called by T(n) with T(n)'s cap when pre-APT state is `Rented(HandoverOpen)` and tenure has expired (no handover pending) — APT fires C2 clearing `current_tenant_cap_id` before the staleness check | Split-tx per §10.13 abort-row strategy. **tx1** (standalone `apply_pending_transitions`): fires `do_tenure_expiry` — `tenant_stake × 0.95` → `owner_earnings`, `FeeMessage<C>` routed, `current_tenant_cap_id = none`, `current_tenant_address = none`, state → `AtDutchAuction`, `TenureExpired` emitted. **tx2** (`borrow_asset` with T(n)'s cap): step 3 fails — `current_tenant_cap_id` is `None`, so `None == some(...)` is false — aborts `E_TENANT_CAP_STALE`. Complements B9: same abort code, different APT transition (C2 clears vs C1 rotates). |

### 10.8 `retire` / `claim_asset`

| # | Description | Expected |
|---|---|---|
| C1 | `retire` before `retire_floor` elapsed | Aborts `E_RETIRE_FLOOR_NOT_ELAPSED`. |
| C2 | `retire` from Idle (after `retire_floor`) | `retire_flag = true`. `state → Retired`. `RetireFlagSet`. |
| C3 | `retire` from AtDutchAuction | `retire_flag = true`. `state → Retired`. `AuctionExpired(next_state: Retired)` + `RetireFlagSet`. |
| C4 | `retire` from Rented(HandoverOpen) | `retire_flag = true`. `state` unchanged. Subsequent `rent()` aborts `E_RETIRE_FLAG_BLOCKS_BID`. |
| C5 | `retire` from Rented(HandoverConfirmed) | `retire_flag = true`. `state` unchanged. Handover completes normally; new tenant enters HandoverOpen with flag set. |
| C6 | Second `retire` call | Aborts `E_ALREADY_RETIRED`. |
| C7 | `claim_asset` when `state != Retired` | Aborts `E_NOT_RETIRED`. |
| C8 | `claim_asset` with non-matching `OwnerCap` | Aborts `E_OWNER_CAP_MISMATCH`. |
| C9 | `claim_asset` on Retired with accumulated earnings | Returns `(asset, coin == owner_earnings)`. OwnerCap burned. Escrow deleted. `AssetClaimed` event. |
| C10 | Full retire-then-claim flow from Rented | `retire` → wait for tenure expiry → `apply_pending_transitions` moves to Retired → `claim_asset` succeeds. |
| C11 | `claim_asset` with `retire_flag` already set, pre-APT state `Rented(HandoverConfirmed)`, both handover and T(n+1)'s tenure expired — APT chains C1 → C2(→Retired) before claim's own logic | APT fires `do_handover`: T(n+1) installed, `owner_earnings += used_credit × 0.95`, `remain_credit` pushed to T(n), new `TenantCap` pushed to T(n+1), `retire_flag` preserved. APT then fires `do_tenure_expiry` with the flag set: `owner_earnings += T(n+1)_stake × 0.95`, state → `Retired`. Claim body asserts `state == Retired` ✓ and returns `(asset, Coin == accumulated owner_earnings)`. Events in order: `HandoverCompleted`, `TenureExpired(next_state: Retired)`, `AssetClaimed`. Pairs with C10 (which covers the chain starting from HandoverOpen). |
| C12 | `retire` called when pre-APT state is `Rented(HandoverOpen)` and tenure has expired (no prior retire_flag) — APT fires C2 moving state to `AtDutchAuction` before retire's own logic | APT fires `do_tenure_expiry` with flag unset: `owner_earnings += tenant_stake × 0.95`, state → `AtDutchAuction`, `TenureExpired` emitted with `timestamp_ms = boundary`. Retire body then asserts `!retire_flag` ✓ and sets it; §4.2 step 6 matches the AtDutchAuction branch: `state → Retired`, `phase_start_ms = clock.now()`, emits `AuctionExpired(next_state: Retired, timestamp_ms = clock.now())` + `RetireFlagSet(state_at_set: Retired)`. Asserts retire's dispatch branch is driven by the post-APT state, not the pre-call state (C4 covers the static Rented pre-state where APT is a no-op). |
| C13 | `retire` called when pre-APT state is `Rented(HandoverConfirmed)` and handover has expired (no prior retire_flag) — APT fires C1 moving state to `Rented(HandoverOpen)` with T(n+1) installed before retire's own logic | APT fires `do_handover`: T(n+1) installed, owner earnings credited, `HandoverCompleted` emitted. Retire body then sets `retire_flag = true`; state is `Rented(HandoverOpen)` so §4.2 step 6 is a no-op (no immediate transition). Emits `RetireFlagSet(state_at_set: Rented(HandoverOpen))`. Flag now applies to T(n+1)'s tenure — any subsequent `rent()` from another bidder aborts `E_RETIRE_FLAG_BLOCKS_BID`. Distinct from C5, where retire runs on `Rented(HandoverConfirmed)` directly (APT no-op) and the flag is inherited by T(n+1) via the later handover. |

### 10.9 `withdraw_earnings`

| # | Description | Expected |
|---|---|---|
| W1 | Withdraw with zero earnings | Aborts `E_NO_EARNINGS`. |
| W2 | Withdraw with positive earnings | Returns Coin of exact balance. `owner_earnings == 0` after. `EarningsWithdrawn { escrow_id, owner_cap_id, amount }` event with `owner_cap_id == object::id(owner_cap)`. |
| W3 | Withdraw with wrong cap | Aborts `E_OWNER_CAP_MISMATCH`. |
| W4 | Withdraw when pre-call state is `Rented(HandoverOpen)` and tenure has expired — APT fires `do_tenure_expiry` before drain | APT credits `owner_earnings += tenant_stake × 0.95`, routes `tenant_stake × 0.05` as `FeeMessage<C>` to `fee_inbox_id`, state → `AtDutchAuction`. Withdraw returns `Coin == (pre_earnings + stake × 0.95)`; `owner_earnings == 0` after. Events in order: `TenureExpired`, then `EarningsWithdrawn`. Asserts APT materializes earnings that a drain-only implementation would miss. |
| W5 | Withdraw when pre-call state is `Rented(HandoverConfirmed)` and handover has expired — APT fires `do_handover` before drain | APT credits `owner_earnings += used_credit × 0.95`, pushes `remain_credit` to displaced tenant, rotates `pending_bid → tenant_stake`, mints + pushes new `TenantCap`, state → `Rented(HandoverOpen)` with T(n+1) installed. Withdraw returns `Coin == (pre_earnings + used_credit × 0.95)`. Events in order: `HandoverCompleted`, then `EarningsWithdrawn`. Exercises the C1-path credit (distinct from W4's C2-path). |

### 10.10 Read-only queries — state guard

| # | Description | Expected |
|---|---|---|
| Q1 | `compute_used_credit` called when state is `Idle` | Aborts `E_NOT_RENTED`. |
| Q2 | `compute_used_credit` called when state is `AtDutchAuction` | Aborts `E_NOT_RENTED`. |
| Q3 | `compute_used_credit` called when state is `Retired` | Aborts `E_NOT_RENTED`. |
| Q4 | `compute_price_descent` called when state is `Idle` | Aborts `E_NOT_AUCTION`. |
| Q5 | `compute_price_descent` called when state is `Rented` | Aborts `E_NOT_AUCTION`. |
| Q6 | `compute_next_rent_price` called when state is `Idle` | Aborts `E_NOT_RENTED`. |
| Q7 | `compute_next_rent_price` called when state is `AtDutchAuction` | Aborts `E_NOT_RENTED`. |

### 10.11 Fee routing

| # | Description | Expected |
|---|---|---|
| F1 | `do_handover` with non-zero `used_credit` | `owner_earnings += 0.95 × used_credit`. One `FeeMessage<C>` constructed via `fee_message::new(fee_balance, escrow.fee_inbox_id, object::id(escrow), ctx)` and posted via `fee_message::send_message(msg, displaced_tenant)`, with balance `0.05 × used_credit` and `escrow_id == object::id(escrow)`. `HandoverCompleted` event includes both shares. |
| F2 | `do_handover` at Dutch Auction bypass (used_credit = last_rent_price) | `remain_credit == 0`, zero push to displaced tenant. Fee and owner share computed on full `last_rent_price`. Fee path as in F1. |
| F3 | `do_tenure_expiry` | `owner_earnings += 0.95 × stake`. One `FeeMessage<C>` of `0.05 × stake` constructed + sent as in F1. |
| F4 | Fee on tiny `used_credit` (`split_fee` floors fee to zero) | `if protocol_fee > 0` guard short-circuits: no split, no `fee_message::new` call, no `FeeMessage<C>` constructed. `owner_share == used_credit`. |

### 10.12 Full lifecycle

| # | Description | Expected |
|---|---|---|
| L1 | integrate → rent (Idle) → borrow → return → (time passes) → tenure expiry → auction expiry → rent (Idle) → retire → claim | All transitions fire correctly. Owner receives asset + earnings. Protocol fees accumulated in `ProtocolFeeInbox`. No orphaned balances. |
| L2 | integrate → rent → takeover bid → handover → (new tenant active) → retire → tenure expiry → claim | `retire_flag` inherited by new tenant. Claim succeeds after their tenure ends. |
| L3 | integrate an inner escrow → deposit its `OwnerCap` via `integrate` into an outer escrow → outer tenant borrows the cap and calls `retire` on the inner escrow | Inner escrow enters the retire flow. Outer escrow unaffected (its asset is the cap, which is now "pointing at a retiring escrow"). |

### 10.13 APT + `rent()` composite matrix

Every `rent()` call chains `apply_pending_transitions` (APT) before dispatching
on the settled state. This matrix enumerates the reachable combinations of
(pre-APT state × APT outcome × `rent()` branch) so the settlement-then-dispatch
flow is exercised on every path the state machine admits.

**Test structure under Move's test framework.** Move's `#[test]` fns take no
parameters, `#[expected_failure]` is strictly function-level, and there is no
try/catch or abort-catching primitive — an abort inside a looped test
terminates the whole test. Success and abort rows therefore cannot share a
single parametric loop. The matrix maps to two clusters:

1. **Success cluster (11 rows: M1–M6, M8–M11, M15)** — one `#[test]` fn
   iterates a `vector<Case>` of records and calls a `#[test_only]` helper
   `check_case((pre_state, elapsed_ms, retire_flag, payment),
   expected(post_state, events, balances))`. Each iteration opens a fresh
   `test_scenario`, builds the pre-APT state via a setup helper, advances the
   clock with `scenario.later_epoch(...)`, calls `rent()`, and asserts the
   post-state / emitted events / balance deltas. Adding a row is one line.
2. **Abort cluster (4 rows: M7, M12, M13, M14)** — one
   `#[test, expected_failure(abort_code = E_...)]` fn per row. `expected_failure`
   catches the abort at the function boundary, so looping over abort rows is
   not possible. For the abort-row testing strategy (M7, M12, M13), the fn
   runs two transactions via `test_scenario::next_tx`: tx1 calls
   `apply_pending_transitions` standalone to exercise and assert APT's work
   (this tx **must succeed** — if it aborts, the framework would accept the
   wrong abort code and mask the bug), tx2 calls `rent()` which aborts with
   the expected code. M14 is a pure rent-abort — APT is a no-op, so no tx1
   is needed.

The golden-path standalone cases (R1 for Idle entry, R13 for HandoverConfirmed
supersede) remain separate from the success-cluster loop — they stay readable
even if the parametric helper regresses, and a failure in the helper cannot
mask a regression in the canonical paths.

| # | Pre-APT | Elapsed conditions | APT fires | Post-APT | `rent()` branch | Expected |
|---|---|---|---|---|---|---|
| M1 | Idle | — | none | Idle | Idle | Cross-ref R1–R3. APT no-op, `install_new_tenant` writes on empty escrow. |
| M2 | AtDutchAuction | `now < phase_start + descent_ceiling` | none | AtDutchAuction | AtDutchAuction | Cross-ref R5–R7. APT no-op, `compute_price_descent(now)` against preserved `phase_start_ms`. |
| M3 | AtDutchAuction | `now ≥ phase_start + descent_ceiling` | C3 | Idle | Idle | `AuctionExpired(Idle)` then `RentStarted(from_state: Idle)`. `last_rent_price` is overwritten by payment inside `install_new_tenant` (do_auction_expiry preserves the stale value per §7.3). |
| M4 | Rented(HandoverOpen), no retire_flag | tenure not expired | none | HandoverOpen | HandoverOpen | Cross-ref R9, R10, R12 (success paths). The subtraction `phase_start + tenure_ceiling - now` is u64-safe exactly because C2 did not fire. |
| M5 | Rented(HandoverOpen) | tenure expired, no retire_flag | C2 | AtDutchAuction | AtDutchAuction | `TenureExpired(AtDutchAuction)` then `RentStarted(from_state: AtDutchAuction)`. `owner_earnings += stake × 0.95`; one `FeeMessage<C>` created and transferred to `fee_inbox_id`. |
| M6 | Rented(HandoverOpen) | tenure + descent expired, no retire_flag | C2 → C3 | Idle | Idle | `TenureExpired` + `AuctionExpired` + `RentStarted(from_state: Idle)`. |
| M7 | Rented(HandoverOpen) | tenure expired, retire_flag set | C2 | Retired | — | `rent()` aborts `E_RETIRED_NO_BID`. The abort rolls back the whole transaction — APT's state changes and `TenureExpired(Retired)` event do not persist. See abort-row note below. |
| M8 | Rented(HandoverConfirmed), no retire_flag | handover not expired | none | HandoverConfirmed | HandoverConfirmed | Cross-ref R13, R15. APT no-op; supersede refund + push-before-rotate exercised. |
| M9 | Rented(HandoverConfirmed) | handover expired, new tenure still active, no retire_flag | C1 | HandoverOpen | HandoverOpen | `HandoverCompleted` (push `remain_credit`, rotate `pending_bid → tenant_stake`, mint new `TenantCap`) then `BidPlaced` on the fresh open state with the caller as the new pending tenant. |
| M10 | Rented(HandoverConfirmed) | handover + new tenure expired, no retire_flag | C1 → C2 | AtDutchAuction | AtDutchAuction | `HandoverCompleted` + `TenureExpired(AtDutchAuction)` + `RentStarted(from_state: AtDutchAuction)`. The stake consumed by C2 is the one rotated in from the original `pending_bid`, not the original tenant's. |
| M11 | Rented(HandoverConfirmed) | all three boundaries expired, no retire_flag | C1 → C2 → C3 | Idle | Idle | Upper bound of the lazy chain (P4 §9). Four events: `HandoverCompleted`, `TenureExpired`, `AuctionExpired`, `RentStarted(from_state: Idle)`. |
| M12 | Rented(HandoverConfirmed) | handover + new tenure expired, retire_flag set | C1 → C2 (→ Retired) | Retired | — | `rent()` aborts `E_RETIRED_NO_BID`. APT would execute `do_handover` (flag preserved by `do_handover`) then `do_tenure_expiry` (routes to Retired because of flag), but the abort rolls them back. See abort-row note below. |
| M13 | Rented(HandoverConfirmed) | handover expired, new tenure still active, retire_flag set | C1 | HandoverOpen | — | `rent()` aborts `E_RETIRE_FLAG_BLOCKS_BID`. APT would complete the handover with flag preserved, but the abort rolls it back. Covers "T(n+1) enters HandoverOpen with flag active — no new bids" (design-compact §6). See abort-row note below. |
| M14 | Rented(HandoverOpen), retire_flag set | tenure not expired | none | HandoverOpen | — | `rent()` aborts `E_RETIRE_FLAG_BLOCKS_BID`. APT is a no-op (nothing to roll back). Equivalent to R11 as a direct test; included here so the (pre-APT × retire_flag × APT outcome) matrix is exhaustive. |
| M15 | Rented(HandoverConfirmed), retire_flag set | handover not expired | none | HandoverConfirmed | HandoverConfirmed | Supersede succeeds — `rent()` HandoverConfirmed branch does not check `retire_flag`. APT no-op. Equivalent to R14; included so retire_flag sub-variants are explicit in the matrix. |

**Novel coverage:** M3, M5–M7, M9–M13 exercise paths where APT changes the
state before dispatch — not reachable from the single-state tables §10.2–10.5.
M1/M2/M4/M8/M14/M15 are matrix anchors where APT is a no-op; they map onto
R-rows but are listed so the (pre-APT × retire_flag × APT outcome) matrix is
exhaustive at 15 rows. Idle and AtDutchAuction have no retire_flag sub-variant
because `retire()` on those states transitions directly to Retired (§4.2).

**Abort-row testing strategy (M7, M12, M13):** when `rent()` aborts, Sui Move
rolls back the whole transaction — APT's state mutations, balance movements,
`FeeMessage<C>` transfers, and events are all reverted. To assert APT's work
independently, split the test into two transactions: tx1 calls
`apply_pending_transitions` standalone (observe settled state, events,
balances); tx2 calls `rent()` (observe the expected abort code). Testing the
composite in a single transaction can only assert the abort code — no
mid-transaction APT effect is observable.

**Phase-anchor correctness:** every row implicitly asserts that
`phase_start_ms` equals the value assigned by the last transition fired
before `rent()` body runs (§5 table in module-map.spec.md). After M10 it
equals the new tenure's start (= previous `handover_countdown_expiry`) at
APT exit, then gets overwritten with `clock.now()` by `install_new_tenant`
inside the rent body.

**Retire_flag coverage closure:**
- HandoverOpen block on live bid: M14 (no APT transition, ≡ R11) + M13 (via APT).
- HandoverConfirmed tolerates retire_flag on supersede: M15 (≡ R14).
- Retired dispatch abort via APT: M7, M12.
- Idle/AtDutchAuction immediate retire: C2, C3 (§10.8).

Together these exercise every branch where `retire_flag` is read by `rent()`
or by an APT-driven transition.


11. MODULE BOUNDARY
--------------------

`rental_escrow.move` exports:

| Symbol | Visibility | Notes |
|---|---|---|
| `E_OWNER_CAP_MISMATCH` | `public` | SDK error handling. Forwarded from `owner_cap`. |
| `E_TENANT_CAP_WRONG_ESCROW` | `public` | borrow_asset. |
| `E_TENANT_CAP_STALE` | `public` | borrow_asset. |
| `E_NOT_AUCTION` | `public` | compute_price_descent: state != AtDutchAuction. |
| `E_NOT_RENTED` | `public` | compute_used_credit / compute_next_rent_price: state != Rented. |
| `E_INSUFFICIENT_PAYMENT` | `public` | rent — payment below floor price (all acquisition paths). |
| `E_RETIRE_FLAG_BLOCKS_BID` | `public` | rent (takeover, flagged). |
| `E_RETIRED_NO_BID` | `public` | rent (Retired). |
| `E_RETIRE_FLOOR_NOT_ELAPSED` | `public` | retire. |
| `E_ALREADY_RETIRED` | `public` | retire. |
| `E_NOT_RETIRED` | `public` | claim_asset. |
| `E_RECEIPT_ESCROW_MISMATCH` | `public` | return_asset. |
| `E_RECEIPT_ASSET_MISMATCH` | `public` | return_asset. |
| `E_NO_EARNINGS` | `public` | withdraw_earnings. |
| `E_ASSET_ALREADY_BORROWED` | `public` | borrow_asset called while asset is already out of escrow. |
| `RentalEscrow<Asset, CoinType>` (type) | `public` | `key` only. Shared. |
| `AssetState` (type) | `public` | `copy + drop + store`. External pattern-match. |
| `RentPhase` (type) | `public` | `copy + drop + store`. |
| `AssetReceipt` (type) | `public` | Hot potato (no abilities). |
| All event structs | `public` | `copy + drop`. |
| `integrate(...)` | `public` | Generic entry. Accepts any `Asset: key + store`, including `OwnerCap`. |
| `rent(...)` | `public` | Single entry for tenancy. |
| `retire(...)` | `public` | Sets flag. Never returns asset. |
| `claim_asset(...)` | `public` | Returns `(Asset, Coin<CoinType>)`. Deletes escrow. |
| `withdraw_earnings(...)` | `public` | Pull owner share. |
| `borrow_asset(...)` | `public` | Returns `(Asset, AssetReceipt)`. |
| `return_asset(...)` | `public` | Consumes `AssetReceipt`. |
| `apply_pending_transitions(...)` | `public` | Permissionless settlement. Returns settled `AssetState`. |
| `apply_pending_transitions(...)` via `devInspectTransactionBlock` | — | Free settled-state read. No consensus, no commit. |
| `compute_used_credit(...)` | `public` | Read-only. Aborts `E_NOT_RENTED` if state != Rented. |
| `compute_price_descent(...)` | `public` | Read-only. Aborts `E_NOT_AUCTION` if state != AtDutchAuction. |
| `compute_next_rent_price(...)` | `public` | Read-only. Aborts `E_NOT_RENTED` if state != Rented. |
| `do_handover(...)` | private | §7.1 |
| `do_tenure_expiry(...)` | private | §7.2 |
| `do_auction_expiry(...)` | private | §7.3 |
| `split_fee(...)` | private | §7.4 |
| `install_new_tenant(...)` | private | §7.5 — shared install path for `rent()` Idle / AtDutchAuction arms. |

**Depends on:**
- `math` — `mul_div` via `split_fee`, `compute_used_credit`, and `compute_price_descent`.
- `curve_shape` — `CurveShape`, `evaluate_curve`.
- `price_function` — `PriceFunction`, `evaluate_price_fn`.
- `config` — `IntegrationConfig` and `public(package)` getters.
- `owner_cap` — `OwnerCap`, `new`, `burn`, `escrow_id`, `assert_escrow`.
- `tenant_cap` — `TenantCap`, `new`, `escrow_id`.
- `protocol_fee_inbox` — `ProtocolFeeRef`, `fee_ref_inbox_id`.
- `fee_message` — `new`, `send_message`.

**Integration flow for a third-party integrator:**

1. Build `CurveShape` values via `curve_shape::new_*`.
2. Build `PriceFunction` value via `price_function::new_*`.
3. Build `IntegrationConfig` via `config::new_config(...)`.
4. Call `rental_escrow::integrate(asset, config, fee_ref, clock, ctx)` →
   receive `OwnerCap`.
5. The escrow is now shared and addressable. Any participant may
   `apply_pending_transitions`, read state, or `rent`.
6. The owner may `withdraw_earnings` at any time; `retire` when ready;
   and `claim_asset` once the state has resolved to `Retired`.

All three layers (`curve_shape`, `price_function`, `config`, `rental_escrow`)
are composable from a single PTB. No off-chain coordinator or keeper is
required — the protocol is fully lazy and permissionlessly settleable.
