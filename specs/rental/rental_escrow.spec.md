RENTAL_ESCROW MODULE — SPECIFICATION
=====================================

Module: `rental_escrow`
Design reference: design-compact.md §1 (state machine), §2 (access model),
  §3 (fund flows), §4 (handover countdown), §6 (integration parameters / retire),
  §9 (lazy evaluation)
Module map reference: module-map.spec.md §11
Depends on: `math`, `curve_shape`, `price_function`, `config`, `owner_cap`,
  `tenant_cap`, `payment_ticket`, `protocol_fee_inbox`, `fee_message`


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
- Public read-only queries: `compute_used_credit`, `compute_floor_price`.
- Package-visible price helpers: `compute_price_descent`,
  `compute_next_rent_price` (backing `compute_floor_price`).
- Private settlement helpers: `do_handover`, `do_tenure_expiry`,
  `do_auction_expiry`, `split_fee`, `settle_stake_earnings`,
  `register_pending_bid`.
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
- `PaymentTicket` struct and lifecycle — lives in `payment_ticket`. This
  module calls `payment_ticket::new` in the two `Rented` sub-branches
  of `rent()` to obtain the ticket by value; `rent` then surfaces it to
  the PTB caller through its `Option<PaymentTicket>` return slot. No
  push happens inside `payment_ticket` — `PaymentTicket : key + store`,
  so return-by-value composition crosses the module boundary directly.
  The ticket has no protocol power and is invisible to every other call
  site.
- `FeeMessage<C>` type or the drain path — lives in `fee_message`. This module
  only calls `fee_message::post` at boundary events where a non-zero
  protocol fee exists; construction, transfer-to-inbox and event emission
  are fused inside that call.
- `ProtocolFeeInbox` / `ProtocolFeeRef` — live in `protocol_fee_inbox`. This
  module reads `inbox_id(&fee_ref)` at `integrate` to store the inbox
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
  `withdraw_earnings` take `&OwnerCap` and assert inline
  `owner_cap::escrow_id(cap) == object::id(escrow)` (aborts
  `E_WRONG_ESCROW_OWNER_CAP`). `borrow_asset` takes `&TenantCap` and
  checks both cap/escrow binding and `object::id(cap) ==
  current_tenant_cap_id` (staleness) inline. Cap modules expose only
  getters and lifecycle; the gating predicates and their abort
  codes live here, where the operation semantic lives. No address
  check is performed anywhere.


1. CONSTANTS
------------

### 1.1 Error constants

All error constants are `public` so the SDK can map abort codes to
human-readable messages. All errors raised on the rental-flow paths —
including the cap-gating checks at `retire` / `claim_asset` /
`withdraw_earnings` / `borrow_asset` — live here. Cap modules
(`owner_cap`, `tenant_cap`) expose only lifecycle and getters; they
own no abort codes. The rationale: "wrong escrow", "stale tenant cap",
etc. are interpretations the consumer places on an ID mismatch — that
semantic belongs where the operation is being gated, not in the cap
type itself.

    public const E_NOT_RENTED:                  u64 = 0;  // compute_used_credit: state != Rented
    public const E_INSUFFICIENT_PAYMENT:        u64 = 1;  // payment < floor price (all acquisition paths)
    public const E_RETIRE_FLAG_BLOCKS_BID:      u64 = 2;  // rent() during Rented(HandoverOpen) with retire_flag
    public const E_RETIRED_NO_BID:              u64 = 3;  // rent() / compute_floor_price: state is Retired (asset not rentable)
    public const E_RETIRE_FLOOR_NOT_ELAPSED:    u64 = 4;  // retire() before integrated_at_ms + retire_floor
    public const E_ALREADY_RETIRED:             u64 = 5;  // retire() when retire_flag already set
    public const E_NOT_RETIRED:                 u64 = 6;  // claim_asset() when state != Retired
    public const E_RECEIPT_ESCROW_MISMATCH:     u64 = 7;  // return_asset: receipt.escrow_id != object::id(escrow)
    public const E_RECEIPT_ASSET_MISMATCH:      u64 = 8;  // return_asset: receipt.asset_id != object::id(&asset)
    public const E_NO_EARNINGS:                 u64 = 9;  // withdraw_earnings: owner_earnings == 0 after settlement
    public const E_ASSET_ALREADY_BORROWED:      u64 = 10; // borrow_asset called while asset is already out of escrow
    public const E_WRONG_ESCROW_OWNER_CAP:      u64 = 11; // retire / claim_asset / withdraw_earnings: owner_cap::escrow_id(cap) != object::id(escrow)
    public const E_WRONG_ESCROW_TENANT_CAP:     u64 = 12; // borrow_asset: tenant_cap::escrow_id(cap) != object::id(escrow)
    public const E_STALE_TENANT_CAP:            u64 = 13; // borrow_asset: current_tenant_cap_id is none, or cap's ID != the one recorded

### 1.2 Protocol constants

Named protocol parameters used by `split_fee` (§7.4). Internal — the SDK
reads the actual fee split via `HandoverCompleted.protocol_fee` /
`TenureExpired.protocol_fee` event fields, not by reading the constant.

    const PROTOCOL_FEE_BPS: u64 = 1_000;   // 10% of the stake-settlement base
    const BPS_PER_UNIT:     u64 = 10_000;  // basis-point denominator (100% == 10_000 bps)

`BPS_PER_UNIT` is spelled identically to `price_function::BPS_PER_UNIT`
by convention — the basis-point denominator is a module-scoped name in
each module that needs it; `math` is deliberately not burdened with a
protocol-policy constant.


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
| `AtDutchAuction` | Price descends from `last_acquisition_price` toward `min_rent_price`. See `compute_price_descent` (§8.2). |
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
    last_acquisition_price:     u64,
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
| `fee_inbox_id` | ID of `ProtocolFeeInbox`. Stored at integrate from `&ProtocolFeeRef`. Passed to `fee_message::post` at each boundary event so the resulting `FeeMessage<C>` carries its routing target. |
| `integrated_at_ms` | Timestamp at integration. Used to enforce `retire_floor`: `retire()` aborts if `clock.timestamp_ms() < integrated_at_ms + config.retire_floor`. |
| `state` | Current `AssetState`. |
| `last_acquisition_price` | Price paid at the most recent acquisition. Written once per cycle by `install_new_tenant` (direct acquisition from `Idle` or `AtDutchAuction`) and by `do_handover` step 5 (handover acquisition). Initialized to `0` at `integrate` — coherent, since no acquisition has occurred. Never read before the first acquisition. Inert in `Rented` states — floor computation reads `tenant_stake` and `pending_bid` directly. Used in `AtDutchAuction` as the descent ceiling: `price_descent(t) = last_acquisition_price − (last_acquisition_price − min_rent_price) · h(t)`. |
| `phase_start_ms` | Timestamp at which the current phase began. See §5 for exact assignment per transition. |
| `current_tenant_cap_id` | `Some(id)` while `state` is `Rented`; `None` otherwise. The live `TenantCap` for the current tenant. Staleness enforced structurally — any other `TenantCap` with the same `escrow_id` fails `object::id(cap) == current_tenant_cap_id`. |
| `current_tenant_address` | `Some(addr)` while `state` is `Rented`; `None` otherwise. Target of `remain_credit` push at handover. |
| `pending_tenant_address` | `Some(addr)` only while `state` is `Rented(HandoverConfirmed)`. Target of `TenantCap` push at handover completion. |
| `handover_countdown_expiry` | `Some(ts)` only while `state` is `Rented(HandoverConfirmed)`. Deterministic from the first bid — subsequent bids do not alter it. |
| `tenant_stake` | Balance paid by the current tenant. Non-zero only while `state` is `Rented`. At handover: `used_credit` splits into `owner_earnings` (90%) + fee (10%); `remain_credit` pushed to displaced tenant; `pending_bid` becomes the new `tenant_stake`. At tenure expiry: full balance splits into `owner_earnings` (90%) + fee (10%). |
| `pending_bid` | Balance paid by the pending tenant. Non-zero only while `state` is `Rented(HandoverConfirmed)`. Refunded on supersede; becomes new `tenant_stake` at handover. |
| `owner_earnings` | Accumulated 90% share. Withdrawn via `withdraw_earnings` or swept at `claim_asset`. |
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
public struct AssetIntegrated<phantom Asset, phantom CoinType> has copy, drop {
    escrow_id:        ID,
    owner_cap_id:     ID,
    asset_id:         ID,   // object::id(&asset) at integrate time
}

public struct RentStarted has copy, drop {
    escrow_id:        ID,
    tenant_cap_id:    ID,
    price_paid:       u64,     // stake amount transferred to escrow
    floor_price:      u64,     // minimum required at acquisition time
    from_state:       AssetState,  // Idle or AtDutchAuction
}

public struct BidPlaced has copy, drop {
    escrow_id:                 ID,
    pending_tenant:            address,
    bid_amount:                u64,
    floor_price:               u64,   // f_next_rent_price(value(tenant_stake)) at bid time
    handover_countdown_expiry: u64,
}

public struct BidSuperseded has copy, drop {
    escrow_id:         ID,
    displaced_bidder:  address,
    refunded_amount:   u64,
    new_bidder:        address,
    new_bid_amount:    u64,
    floor_price:       u64,   // f_next_rent_price(value(pending_bid)) at bid time — escalates with each supersede
}

public struct HandoverCompleted has copy, drop {
    escrow_id:         ID,
    displaced_tenant:  address,
    new_tenant_cap_id: ID,
    used_credit:       u64,   // amount consumed by owner (pre-fee split)
    owner_share:       u64,   // used_credit × 0.90
    protocol_fee:      u64,   // used_credit × 0.10
    remain_credit:     u64,   // refunded to displaced tenant
    new_rent_price:    u64,   // winning bid amount — written to escrow.last_acquisition_price at do_handover step 5
    timestamp_ms:      u64,   // = handover_countdown_expiry
}

public struct TenureExpired has copy, drop {
    escrow_id:        ID,
    tenant:           address,
    owner_share:      u64,   // tenant_stake × 0.90
    protocol_fee:     u64,   // tenant_stake × 0.10
    last_acquisition_price:  u64,   // frozen at expiry — anchor of Dutch descent if next_state=AtDutchAuction
    next_state:       AssetState,  // AtDutchAuction or Retired
    timestamp_ms:     u64,   // = phase_start_ms + tenure_ceiling
}

public struct AuctionExpired has copy, drop {
    escrow_id:        ID,
    timestamp_ms:     u64,   // = phase_start_ms + descent_ceiling, always
}

public struct RetireFlagSet has copy, drop {
    escrow_id:        ID,
    owner:            address,     // cap holder at retire time (first-observed)
    state_at_set:     AssetState,  // settled state when retire was called
}

public struct AssetRetired has copy, drop {
    escrow_id:        ID,
    from_state:       AssetState,  // Idle | AtDutchAuction | Rented
}

public struct AssetBorrowed has copy, drop {
    escrow_id:        ID,
    tenant_cap_id:    ID,
}

public struct AssetReturned has copy, drop {
    escrow_id:        ID,
    tenant_cap_id:    ID,
}

public struct AssetClaimed has copy, drop {
    escrow_id:        ID,
    owner_cap_id:     ID,
    swept_earnings:   u64,
}

public struct EarningsWithdrawn has copy, drop {
    escrow_id:        ID,
    owner_cap_id:     ID,
    owner:            address,   // cap holder at withdraw time (first-observed)
    amount:           u64,
}
```

**Sui Verifier constraint:** every event struct has `copy + drop` and is
internal to this module. `event::emit` requires these abilities.

**`AssetIntegrated` is phantom-generic over the escrow's type parameters.**
The root-fact creation event carries `Asset` and `CoinType` as phantom type
parameters so the off-chain indexer recovers both from the event type tag
(`AssetIntegrated<0x...::game::Sword, 0x2::sui::SUI>`) without paying any
on-chain bytes. This is the unique entry point: downstream fact rows
(`RentStarted`, `HandoverCompleted`, etc.) are non-generic and recover
`Asset` / `CoinType` by PK-JOIN on `escrow_id` back to `AssetIntegrated`.
Rationale: `Asset` and `CoinType` are escrow-level configuration (generics
of `RentalEscrow<Asset, CoinType>`), not `IntegrationConfig`-level
parameters — `IntegrationConfig` is coin-agnostic and asset-agnostic.

**Cap-gated ops that do not co-emit a cap lifecycle event carry the
cap holder's address.** `RetireFlagSet` and `EarningsWithdrawn` both
take `&OwnerCap` — the cap is neither minted nor burned in these calls
— so no `OwnerCap*` event is co-emitted. `OwnerCap` has `key + store`,
so the caller address at retire-time / withdraw-time may differ from
`OwnerCapMinted.owner` (mint-time) and from every other cap-gated
call. It is **first-observed** and PK-unrecoverable per star-schema
invariant (c), so both events carry `owner: address =
tx_context::sender(ctx)`. The field name is `owner` — not `caller` —
because the protocol defines "owner" as whoever holds the cap at call
time (README, "The caps"), so this is protocol semantics, not
transaction metadata.

`AssetClaimed` does **not** carry `owner`: `claim_asset` consumes the
cap by value and calls `owner_cap::burn`, which emits
`OwnerCapBurned.owner` in the same transaction. The claim-time caller
address is therefore PK-recoverable by JOIN on `owner_cap_id` into
`owner_cap_burned` — duplicating it on `AssetClaimed` would violate
invariant (c).

**Timestamp convention:** only boundary events — `HandoverCompleted`,
`TenureExpired`, `AuctionExpired` — carry a `timestamp_ms` field. Its
value is the exact boundary timestamp (`handover_countdown_expiry`,
`phase_start_ms + tenure_ceiling`, `phase_start_ms + descent_ceiling`)
— not `clock.now()` — so the event timeline stays aligned with the
state machine even when settlement is lazy and runs in a later
checkpoint than the boundary itself.

Immediate events (`AssetIntegrated`, `RentStarted`, `BidPlaced`,
`BidSuperseded`, `RetireFlagSet`, `AssetRetired`, `AssetBorrowed`,
`AssetReturned`, `AssetClaimed`, `EarningsWithdrawn`) do not carry a
`timestamp_ms` field. Consumers read the event-envelope timestamp
(`SuiEvent.timestampMs`, the checkpoint time of the emitting
transaction), which is authoritative for anything that happens at tx
time. Duplicating it in the event body would add no information and
would force `&Clock` into the signature of functions that otherwise
have no reason to read the clock.

**`AssetRetired` — timestamp recovery rule.** `AssetRetired` has two
disparate emission sites: immediate (from `retire()` when settled state
is `Idle` or `AtDutchAuction`) and deferred (from
`apply_pending_transitions` → `do_tenure_expiry` when `retire_flag` is
set and tenure expires, `from_state = Rented`). The deferred case
co-emits with `TenureExpired` in the same transaction, so the
authoritative boundary time is recoverable by JOIN on `escrow_id` to
`TenureExpired.timestamp_ms` (= `phase_start_ms + tenure_ceiling`). The
immediate case has no boundary — tx time == semantic time — so the
envelope is authoritative. Carrying a `timestamp_ms` field on
`AssetRetired` itself would give the same field two different meanings
depending on `from_state`; recovery by JOIN is cheaper and structurally
unambiguous.

**Price-anchor fields — `new_rent_price` on `HandoverCompleted`,
`last_acquisition_price` on `TenureExpired`.** The state field
`escrow.last_acquisition_price` anchors two downstream computations
— the takeover/supersede floor (`compute_next_rent_price` in `Rented`
arms) and `compute_price_descent` (Dutch descent, §8.2). Both events
carry it explicitly because it is **not** PK-JOIN-recoverable via a
single JOIN: recovering the value off-chain requires locating the most
recent `HandoverCompleted.new_rent_price` or `RentStarted.price_paid`
for the escrow — an `ORDER BY ts DESC LIMIT 1` walk, not a keyed JOIN
— and is fragile under partial ingestion. Emitting it at each
transition that freezes it makes each fact row self-describing for
price-floor and Dutch-price analytics. Consistent with invariant (c):
the rule constrains redundant **addresses** recoverable by PK-JOIN, not
amounts recoverable only by chain-walk. `AuctionExpired` does not need
its own field — its anchor is the directly preceding `TenureExpired`,
PK-JOIN-recoverable 1:1 by `escrow_id` and temporal order.

### Star schema — the protocol's event emission strategy

The full event surface of the protocol — this module plus the three
child-object modules (`owner_cap`, `tenant_cap`, `fee_message`) — is
shaped as a **SQL star schema** anchored on `escrow_id` as the root
foreign key. Every event emitted anywhere in the package carries
`escrow_id`, so an off-chain indexer can ingest them into a unified
view of per-escrow activity with zero envelope-metadata dependency.

Around that root, four satellite dimensions exist. Three are
protocol-internal child-object types (`owner_cap`, `tenant_cap`,
`fee_message`), each with its own natural primary key — the child
object's own ID — and a pair of lifecycle events (create / destroy,
send / collect) joined on that PK. Address fields are non-redundant
across each pair: they appear only on the event where they are
first-observed or where they diverge from their counterpart. The
fourth satellite is `config` — a 1:1 dimension keyed only by
`escrow_id`, with a single emission at integration time (configs are
immutable, so there is no update or burn event).

```
                    ┌──────────────────────────────────┐
                    │         escrows (root fact)      │
                    │           PK: escrow_id          │
                    │                                  │
                    │  AssetIntegrated  RentStarted    │
                    │  BidPlaced        BidSuperseded  │
                    │  HandoverCompleted               │
                    │  TenureExpired    AuctionExpired │
                    │  RetireFlagSet    AssetRetired   │
                    │  AssetBorrowed    AssetReturned  │
                    │  AssetClaimed     EarningsWithdrawn│
                    └──────────────┬───────────────────┘
                                   │  FK: escrow_id
                                   │  (on every row below)
     ┌──────────────┬──────────────┼──────────────┬─────────────────┐
     │              │              │              │                 │
     ▼              ▼              ▼              ▼                 ▼
┌──────────┐  ┌───────────┐  ┌────────────┐  ┌──────────────────────────┐
│  config  │  │ owner_cap │  │ tenant_cap │  │       fee_message        │
│ PK:      │  │ PK:       │  │ PK:        │  │ PK: fee_message_id       │
│ escrow_id│  │ owner_    │  │ tenant_    │  │                          │
│   (1:1)  │  │  cap_id   │  │  cap_id    │  │   FeeMessageSent         │
│          │  │           │  │            │  │     tenant               │
│ Integra- │  │ OwnerCap  │  │ TenantCap  │  │                          │
│ tionCfg  │  │  Minted   │  │  Minted    │  │   FeeMessageCollected    │
│ Regis-   │  │    owner  │  │    tenant  │  │     collector            │
│ tered    │  │           │  │            │  │                          │
│          │  │ OwnerCap  │  │ TenantCap  │  │                          │
│ (once)   │  │  Burned   │  │  Burned    │  │                          │
│          │  │    owner  │  │    tenant  │  │                          │
└──────────┘  └───────────┘  └────────────┘  └──────────────────────────┘
   no UID →    key + store →   key + store →    key only →
   immutable    owner may       tenant may       tenant first-observed
   snapshot     diverge across  diverge across   at send; collector
   at integrate mint/burn       mint/burn        first-observed at
                → kept on both  → kept on both   consume
                  events          events
```

**Star schema properties:**

| Property | Consequence |
|---|---|
| **`escrow_id` on every row.** | Any analytical question ("activity on escrow X") answers with a single `WHERE escrow_id = X`. No cross-table joins needed for scoping. |
| **Child PK pairs lifecycle.** | `owner_cap_id`, `tenant_cap_id`, `fee_message_id` each join their Minted↔Burned / Sent↔Collected pair. Full object history = one JOIN. |
| **1:1 config satellite.** | `IntegrationConfigRegistered` is emitted exactly once per escrow, at integration, from the `config` module. It has no child UID — the only key is `escrow_id`, the root FK itself. This lets analytical queries group escrows by any integration parameter (tenure, curve shapes, price function) with a single JOIN on `escrow_id`, without having to read the on-chain object. |
| **Addresses are first-observed, never duplicated.** | Redundancy recoverable by PK-JOIN is dropped; addresses that may diverge between paired events are kept on both. `TenantCapBurned` keeps `tenant` — `key + store` transferability means the burn-sender may differ from the mint-recipient and is genuinely new information (symmetric with `OwnerCapBurned.owner`). `FeeMessageCollected` has no `tenant` (JOIN on `fee_message_id` recovers it — `FeeMessage` is `key`-only and the tenant address from `FeeMessageSent` is unambiguous). `OwnerCapBurned` keeps `owner` — same reasoning as `TenantCapBurned`. Fact-table events comply: `AssetIntegrated` omits `integrator` (JOIN on `owner_cap_id` to `OwnerCapMinted`), `RentStarted` omits `tenant` (JOIN on `tenant_cap_id` to `TenantCapMinted`), `HandoverCompleted` omits `new_tenant` (JOIN on `new_tenant_cap_id`). `HandoverCompleted.displaced_tenant` is kept — no PK reaches the outgoing cap from this row. |
| **Fact-table rows carry child PK-FKs to dimensions they co-emit with.** | `AssetIntegrated.owner_cap_id`, `RentStarted.tenant_cap_id`, `HandoverCompleted.new_tenant_cap_id`, `AssetBorrowed.tenant_cap_id`, `AssetReturned.tenant_cap_id`, `AssetClaimed.owner_cap_id`, `EarningsWithdrawn.owner_cap_id` — every fact row whose semantics touch a child object exposes that child's PK so the indexer can JOIN into the dimension without envelope-timing. |
| **Borrow/return measure actual usage.** | `AssetBorrowed` / `AssetReturned` pair JOIN on `tenant_cap_id` within a single tenancy (multiple pairs possible — a tenant may borrow and return N times during their block). Provides the off-chain indexer a measurable signal of "did the tenant actually use the capability?" — the core liquid-renting demand metric, previously invisible (borrow was PTB-internal only). |
| **`AssetIntegrated` is the Asset/CoinType dictionary.** | `AssetIntegrated<Asset, CoinType>` is the only event phantom-generic on the escrow's type params. Any query that needs to group or filter by `Asset` or `CoinType` JOINs on `escrow_id` back to `asset_integrated` and reads the type tag — including queries over `IntegrationConfigRegistered` (min_rent_price, tenure_ceiling, curves) that want to bucket by coin. The `config` module stays coin-agnostic. |
| **`AssetIntegrated.asset_id` enables level-2 linkage and asset-instance tracing.** | The object ID of the wrapped asset at integrate time. Level-2 escrows (`Asset = rental_escrow::OwnerCap`) pair to their underlying level-1 escrow via `asset_id = level-1 OwnerCap ID` → JOIN on `owner_cap_id` to `OwnerCapMinted.escrow_id`. The same-asset-across-integrations thread (integrate → retire → re-integrate) becomes queryable with `GROUP BY asset_id`. Without this field the mapping is only reachable through Sui's object-state-changes layer, not through the protocol's event surface. |
| **Owner address on `&OwnerCap`-gated ops.** | `RetireFlagSet.owner` and `EarningsWithdrawn.owner` record the cap holder at call time. These ops take the cap by reference — no `OwnerCap*` lifecycle event is co-emitted — so the address is first-observed and PK-unrecoverable. `AssetClaimed` does not carry `owner` because it consumes the cap by value; `OwnerCapBurned.owner` co-emits the same address and is reachable by JOIN on `owner_cap_id` (invariant c). Enables per-human queries (withdraw frequency per owner, multi-cap operators). |
| **Intent vs settlement on retirement.** | `RetireFlagSet` records the owner's intent (when `retire()` was called, from which settled state). `AssetRetired` records the actual transition to `Retired` — immediate for `from_state ∈ {Idle, AtDutchAuction}`, deferred to the next tenure expiry for `from_state = Rented`. Co-emission matrix: `TenureExpired.next_state = Retired` ⇔ `AssetRetired` with `from_state = Rented` is co-emitted. Both events are needed — `TenureExpired` carries the stake-settlement facts (`owner_share`, `protocol_fee`, tenant), `AssetRetired` carries the pure state-transition fact. |
| **Price-anchor fields on block-boundary events.** | `HandoverCompleted.new_rent_price` carries the winning bid amount written to `escrow.last_acquisition_price` at handover; `TenureExpired.last_acquisition_price` carries the same field frozen at tenure expiry. Neither is PK-JOIN-recoverable via a single JOIN — recovering the value requires locating the most recent `HandoverCompleted.new_rent_price` or `RentStarted.price_paid` for the escrow (`ORDER BY ts DESC LIMIT 1`). Emitting them in-row makes (a) the takeover-floor query `floor = f_next_rent_price(last_acquisition_price)` answerable from `HandoverCompleted` alone, and (b) the Dutch current price `price(t) = last_acquisition_price − h(t)·(last_acquisition_price − min_rent_price)` answerable from `TenureExpired` + `IntegrationConfigRegistered` alone — no stateful replay in the indexer. Consistent with invariant (c). |
| **`floor_price` on acquisition and bid events.** | `RentStarted.floor_price`, `BidPlaced.floor_price`, `BidSuperseded.floor_price` carry the minimum required payment at call time. The voluntary premium `price_paid − floor_price` (or `bid_amount − floor_price`) is the core demand signal — invisible without this field. For `RentStarted{AtDutchAuction}` the floor is `compute_price_descent(now)`, which requires a timestamp and curve application to reconstruct off-chain. For `BidPlaced` it requires locating the most recent acquisition price and applying `f_next_rent_price`. For `BidSuperseded` it is `f_next_rent_price(refunded_amount)` — computable from the same row but only with function application. Emitting it directly makes the premium a single-column subtraction on any query engine. |
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

**Deliberate exclusion — `PaymentTicket`.** The `payment_ticket`
module (built and returned by value to the bidder via `rent`'s
`Option<PaymentTicket>` slot in the two `Rented` sub-branches of
`rent()`) emits **no** events and is therefore **not** a satellite of
this star schema. Each ticket mint corresponds 1:1 to exactly one
`BidPlaced` or `BidSuperseded` row, which already carries `escrow_id`
and the bidder's address in the same transaction; an indexer that
wishes to track tickets per wallet can do so by filtering Sui's
object-creation envelope on the `PaymentTicket` type tag. The ticket
carries no protocol authority — its purpose is the bidder's wallet
UX, symmetric with the `TenantCap` returned (also by value) from
`rent` in the `Idle` / `AtDutchAuction` branches. Full rationale:
`payment_ticket.spec.md` §3.


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
3. Read `fee_inbox_id = protocol_fee_inbox::inbox_id(fee_ref)`.
4. Capture `asset_id = object::id(&asset)` — needed by the emit in
   step 7. Must be read before the `option::some(asset)` wrap below,
   since after wrapping the asset is moved into the escrow and the
   escrow itself is consumed by `share_object` in step 6. Then
   construct the escrow with:
   - `asset = option::some(asset)`
   - `state = AssetState::Idle`
   - `last_acquisition_price = 0`
   - `phase_start_ms = 0`
   - `integrated_at_ms = clock.timestamp_ms()`
   - All remaining `Option` fields `None`, all `Balance` fields `balance::zero()`
   - `retire_flag = false`
5. Call `config::emit_registration(&escrow.config, escrow_id)` to emit
   `IntegrationConfigRegistered` carrying the full parameter snapshot keyed
   by `escrow_id`. Emitted from the `config` module per the module-ownership
   principle. Must happen *before* `share_object` consumes `escrow` by
   value; safe to borrow `&escrow.config` at this point because the escrow
   has already been constructed (step 4) and the config↔escrow_id binding
   is a realized semantic fact (emit-last).
6. `transfer::share_object(escrow)`.
7. Emit `AssetIntegrated<Asset, CoinType> { escrow_id, owner_cap_id,
   asset_id }`. Both type parameters are phantom — no on-chain payload
   — and are recovered by the indexer from the event type tag, making
   this event the root dictionary row for every downstream JOIN that
   needs `Asset` or `CoinType`. `asset_id` is the object ID of the
   wrapped asset at integrate time; it anchors (a) level-2 linkage
   when `Asset = rental_escrow::OwnerCap`, pairing the level-2 escrow
   to a specific level-1 `OwnerCap`, (b) cross-integration lifecycle
   tracing of the same asset instance (integrate → retire → re-integrate
   under a new escrow), and (c) integrator-catalog cross-reference
   queries without dropping to Sui's object-state-changes layer. The
   integrator address is not carried here — already recorded on the
   co-emitted `OwnerCapMinted.owner` row and recoverable by JOIN on
   `owner_cap_id` (star-schema invariant c: no PK-recoverable
   redundancy).
8. Return `OwnerCap`. The PTB routes it (typically via
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
1. `assert!(owner_cap::escrow_id(owner_cap) == object::id(escrow), E_WRONG_ESCROW_OWNER_CAP);`
   — **security-critical** escrow-match gate (PTB-pairing attack;
   see `claim_asset` step 2 for the full threat model). Abort code
   is rental-local because the "wrong escrow" semantic is this
   module's interpretation of the cap/escrow ID mismatch.
2. `apply_pending_transitions(escrow, clock, ctx)` — settle all elapsed
   boundaries first.
3. Assert `!escrow.retire_flag`, abort `E_ALREADY_RETIRED`.
4. Assert `clock.timestamp_ms() >= escrow.integrated_at_ms +
   config::retire_floor(&escrow.config)`, abort `E_RETIRE_FLOOR_NOT_ELAPSED`.
5. Set `escrow.retire_flag = true`.
6. Let `prior_state = escrow.state` — bind before any state mutation so the
   subsequent `AssetRetired` emit can report the pre-transition state.
7. If `prior_state` is `Idle` or `AtDutchAuction` (no active tenant, no
   pending bid), transition immediately. Both branches set `state =
   Retired` and `phase_start_ms = clock.timestamp_ms()`. Neither branch
   emits `AuctionExpired`: the auction was *interrupted*, not *expired* —
   `AuctionExpired` names the end-of-descent-ceiling boundary, which is
   the only case where `do_auction_expiry` (§7.3) reaches it. The retire
   transition is fully captured by `RetireFlagSet` (step 8) and
   `AssetRetired` (step 9). The `phase_start_ms` update follows the
   convention that every transition site records the moment of transition
   (see `do_tenure_expiry` §7.2 and `do_auction_expiry` §7.3). The field
   is not read in `Retired`, but the uniform invariant simplifies auditing.
8. Emit `RetireFlagSet { escrow_id, owner: tx_context::sender(ctx),
   state_at_set: prior_state }`. The `owner` field captures the cap
   holder at retire time — first-observed, PK-unrecoverable (cap is
   transferable between mint and this call).
9. If `prior_state` was `Idle` or `AtDutchAuction`, emit
   `AssetRetired { escrow_id, from_state: prior_state }`. Emit-last: the
   state machine has already reached `Retired` (step 7). For the `Rented`
   branch there is no `AssetRetired` here — the transition is deferred to
   `do_tenure_expiry` (§7.2) and emitted there alongside `TenureExpired`.

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
2. `assert!(owner_cap::escrow_id(&owner_cap) == object::id(&escrow), E_WRONG_ESCROW_OWNER_CAP);`
   — **security-critical** escrow-match gate. PTBs can pair any
   `&OwnerCap` with any `RentalEscrow` passed as argument; the type
   system does not constrain that pairing. Without this assert,
   Alice could pass her own legitimate `OwnerCapA` alongside Bob's
   shared `EscrowB` and `claim_asset` would delete `EscrowB`,
   extract its asset, and burn `OwnerCapA` — Alice walks away with
   Bob's asset. The check is load-bearing, not a sanity check: the
   cap being honestly minted for `EscrowA` says nothing about which
   escrow was passed as the other argument at call time.
3. Call `apply_pending_transitions(&mut escrow, clock, ctx)` — settle any
   remaining elapsed boundaries.
4. Assert `escrow.state == Retired`, abort `E_NOT_RETIRED`. This covers
   callers who never called `retire()` first or who called `claim_asset`
   during an active tenancy.
5. Destructure the escrow:

        let RentalEscrow {
            id, asset: asset_opt, config: _, fee_inbox_id: _,
            integrated_at_ms: _, state: _, last_acquisition_price: _, phase_start_ms: _,
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
   first; also hoist the burn-time caller address here so the `burn`
   signature advertises exactly what it records):
   - `let escrow_id      = object::uid_to_inner(&id);`
   - `let owner_cap_id   = object::id(owner_cap);`
   - `let swept_earnings = coin::value(&earnings);`
   - `let owner          = tx_context::sender(ctx);`
9. `owner_cap::burn(owner_cap, owner);` — `OwnerCapBurned.owner`
   records the claim-time caller passed in explicitly. This address is
   recoverable on `AssetClaimed` by JOIN on `owner_cap_id`, which is
   why `AssetClaimed` does not duplicate it (invariant c).
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
1. `assert!(owner_cap::escrow_id(owner_cap) == object::id(escrow), E_WRONG_ESCROW_OWNER_CAP);`
   — **security-critical** escrow-match gate (PTB-pairing attack;
   see `claim_asset` step 2 for the full threat model).
2. `apply_pending_transitions(escrow, clock, ctx)` — settle any elapsed
   boundaries first so the withdrawn amount includes all accrued earnings.
3. `let amount = balance::value(&escrow.owner_earnings);`
4. Assert `amount > 0`, abort `E_NO_EARNINGS`.
5. `let balance = balance::withdraw_all(&mut escrow.owner_earnings);`
6. Emit `EarningsWithdrawn { escrow_id, owner_cap_id: object::id(owner_cap),
   owner: tx_context::sender(ctx), amount }`. `owner_cap_id` is the cap's
   identity PK. `owner` is the cap holder at this call — first-observed
   and PK-unrecoverable: `OwnerCap` is `key + store` and may have
   changed hands between `OwnerCapMinted` and now (or be held inside a
   level-2 tenant cap), and no `OwnerCap*` lifecycle event co-emits
   here. Without this field, per-owner queries (withdraw frequency per
   address, multi-cap operators) would have to rely on envelope
   `sender` — forbidden by invariant (d).
7. Return `coin::from_balance(balance, ctx)`.


5. RENTAL FUNCTIONS
--------------------

### 5.1 `rent`

    public fun rent<Asset: key + store, CoinType>(
        escrow:  &mut RentalEscrow<Asset, CoinType>,
        payment: Coin<CoinType>,
        clock:   &Clock,
        ctx:     &mut TxContext,
    ): (Option<TenantCap>, Option<PaymentTicket>)

**Visibility:** `public`. Single entry point to become or displace a tenant.

**Return shape — exclusive disjunction.** Exactly one of the two
`Option` slots is `Some` in every non-`Retired` state; the other is
`None`. The state machine guarantees this at runtime; the type does
not. Callers (typically PTB authors) know which branch they are
exercising and consume the corresponding slot.

| Pre-rent state (post-settle) | Returned tuple |
|---|---|
| `Idle` | `(some(TenantCap), none)` |
| `AtDutchAuction` | `(some(TenantCap), none)` |
| `Rented { HandoverOpen }` | `(none, some(PaymentTicket))` |
| `Rented { HandoverConfirmed }` | `(none, some(PaymentTicket))` |
| `Retired` | aborts `E_RETIRED_NO_BID` (never returns) |

The choice of `(Option, Option)` over a sum type — e.g. `enum
RentOutcome { Tenant(TenantCap), Bid(PaymentTicket) }` — is driven by
PTB ergonomics: PTBs cannot pattern-match enums (match is a Move-level
construct, unavailable at the PTB layer), so an enum return would
force every caller through a custom `unwrap_*` MoveCall per variant.
`std::option::destroy_some` / `destroy_none` are universal and
already wired into every PTB toolchain.

**Behavior:**

1. `apply_pending_transitions(escrow, clock, ctx)` — settle first, act on
   post-settlement `escrow.state`.
2. Let `floor = compute_floor_price(escrow, clock.timestamp_ms())` — unified
   floor for all acquisition paths. Aborts `E_RETIRED_NO_BID` if state is
   `Retired`, so no `Retired` arm is needed below. `compute_floor_price` is
   also the public query SDK/frontend callers use — internal and external floor
   computation share a single source of truth with no divergence possible.
3. Assert `coin::value(&payment) >= floor`, abort `E_INSUFFICIENT_PAYMENT`.
4. Dispatch on `escrow.state`:

#### Case: `Idle`

- Let `price_paid = coin::value(&payment);`
- Let `(cap, tenant_cap_id) = install_new_tenant(escrow, payment, clock, ctx);`
  — §7.5 is the single source of truth for "install tenant from payment
  into an empty escrow". It handles balance absorption, phase anchor, cap
  construction (`tenant_cap::new`), address registration, and state
  transition to `Rented { HandoverOpen }`. Returns the cap by value plus
  its ID; `current_tenant_cap_id` is updated inside the helper.
- Emit `RentStarted { escrow_id, tenant_cap_id, price_paid, floor_price: floor,
  from_state: AssetState::Idle }`. The tenant address is not carried
  here — it is already recorded on the co-emitted `TenantCapMinted.tenant`
  row and recoverable by JOIN on `tenant_cap_id` (star-schema invariant c).
- Return `(option::some(cap), option::none())`.

#### Case: `AtDutchAuction`

- Let `price_paid = coin::value(&payment);`
- Let `(cap, tenant_cap_id) = install_new_tenant(escrow, payment, clock, ctx);` — §7.5.
- Emit `RentStarted { escrow_id, tenant_cap_id, price_paid, floor_price: floor,
  from_state: AssetState::AtDutchAuction }`. Tenant address recoverable
  via JOIN on `tenant_cap_id` into `TenantCapMinted`.
- Return `(option::some(cap), option::none())`.

#### Case: `Rented { HandoverOpen }`

- Assert `!escrow.retire_flag`, abort `E_RETIRE_FLAG_BLOCKS_BID`.
- Let `pending_tenant = tx_context::sender(ctx);`
- Let `remaining = tenure_expiry_ms(escrow) - clock.timestamp_ms()` — §8.5.
- Let `countdown = min(escrow.config.handover_floor, remaining)`.
- `escrow.handover_countdown_expiry = some(clock.timestamp_ms() + countdown);`
- `escrow.pending_tenant_address = some(pending_tenant);`
- `escrow.state = Rented { phase: HandoverConfirmed };`
- **Register pending bid** — §7.7 is the single source of truth for
  "absorb payment into `pending_bid`, build a `PaymentTicket` for the
  bidder via `payment_ticket::new`". Consumes `payment`; returns
  `(ticket, bid_amount)`:
  - `let (ticket, bid_amount) = register_pending_bid(escrow, payment, ctx);`
- Emit `BidPlaced { escrow_id, pending_tenant, bid_amount, floor_price: floor,
  handover_countdown_expiry }` — emit-last: all state mutations complete
  and the ticket has been built, so the escrow's post-state and the
  caller's about-to-be-returned ticket match the event's semantics.
- Return `(option::none(), option::some(ticket))`.

**Retire flag rationale:** blocking new bids is what "retire during Rented"
means — the current tenant completes their block uncontested and the asset
exits afterward.

#### Case: `Rented { HandoverConfirmed }`

- `retire_flag` check is **not** performed here. A pending bid was already
  accepted before `retire` could have fired; the committed bid is
  honored, handover completes normally, and T(n+1) then enters
  `HandoverOpen` with the flag still set (no further bids accepted).
- **Pre-bind event locals** for the refund push (captured before
  `pending_bid` and `pending_tenant_address` are overwritten):
  - `let displaced_bidder = *option::borrow(&escrow.pending_tenant_address);`
  - `let new_bidder       = tx_context::sender(ctx);`
- **Refund previous pending bid** (push before rotate). The push targets
  the address registered on `pending_tenant_address` at the time of the
  prior bid. Under `key + store` the prior bidder's `PaymentTicket` may
  have changed hands since, but that is off-protocol — the protocol's
  commitment is to the placer's address, recorded publicly on-chain at
  bid time. (Symmetric with all other pushes to addresses-of-record.)
  - Take the previous balance: `let prev = balance::withdraw_all(&mut escrow.pending_bid);`
  - `let refunded_amount = balance::value(&prev);`
  - `transfer::public_transfer(coin::from_balance(prev, ctx), displaced_bidder);`
- `escrow.pending_tenant_address = some(new_bidder);`
- **Register the new pending bid** — §7.7, same helper as the HandoverOpen
  branch. The displaced bidder keeps the ticket they received from their
  own prior `rent()` call; the protocol does not and cannot revoke it.
  - `let (ticket, new_bid_amount) = register_pending_bid(escrow, payment, ctx);`
- `handover_countdown_expiry` is **not** updated — subsequent bids do not
  reset the countdown (design-compact §4).
- `state` remains `Rented { HandoverConfirmed }`.
- Emit `BidSuperseded { escrow_id, displaced_bidder, refunded_amount,
  new_bidder, new_bid_amount, floor_price: floor }` — emit-last: all state
  rotations, the refund push, and the new ticket construction complete,
  so the escrow's post-state (new bidder installed, old refunded, new
  ticket about to be returned to the caller) matches the event's
  semantics.
- Return `(option::none(), option::some(ticket))`.

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
    let expiry = tenure_expiry_ms(escrow);                // §8.5
    if clock.timestamp_ms() >= expiry:
        do_tenure_expiry(escrow, expiry, ctx)
        // Post: state = AtDutchAuction, unless retire_flag → Retired
        // Post: phase_start_ms = expiry

// Check 3 — auction expiry (reads state possibly mutated by Check 2)
if escrow.state == AtDutchAuction:
    let expiry = descent_expiry_ms(escrow);               // §8.5
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
2. `let escrow_id = object::id(escrow);` — bound once and reused by the
   escrow-match assert (step 3) and the receipt construction (step 6).
3. `assert!(tenant_cap::escrow_id(tenant_cap) == escrow_id, E_WRONG_ESCROW_TENANT_CAP);`
   — **security-critical** escrow-match gate. Same threat model as
   `claim_asset` step 2: PTBs can pair any `&TenantCap` with any
   `&mut RentalEscrow` argument, and the type system does not
   constrain that pairing. Without this assert, a tenant holding a
   legitimate cap for `EscrowA` could pair it with `EscrowB` (for
   which they are not the tenant) and extract `EscrowB`'s asset.
4. **Security-critical** staleness check. Defends against a
   different attack than step 3: *displaced-tenant retention*.
   After `do_handover`, the evicted tenant (or any later holder of
   their cap, since `TenantCap : key + store` is transferable) still
   has the old cap — `burn` is voluntary, so the holder is not
   forced to destroy it. Step 3 alone accepts that cap because
   `cap.escrow_id` still matches; only the current-id comparison
   exposes the displacement.

   ```
   assert!(escrow.current_tenant_cap_id.is_some(), E_STALE_TENANT_CAP);
   assert!(object::id(tenant_cap) == *escrow.current_tenant_cap_id.borrow(), E_STALE_TENANT_CAP);
   ```

   Rejects:
   - Displaced caps (`Some(other_id)` path — a later `do_handover`
     rotated the slot; aborts at the identity compare).
   - Caps presented after `do_tenure_expiry` cleared the slot
     (`None` path; aborts at the `is_some` guard).

   Both surface as `E_STALE_TENANT_CAP` — one uniform abort code
   for both staleness paths, because `None ⇒ every cap is stale`
   and `Some(other) ⇒ this cap is stale` are the same semantic to
   the consumer.
5. Assert `option::is_some(&escrow.asset)`, abort `E_ASSET_ALREADY_BORROWED`.
   This is the only protocol state in which the internal `Option<Asset>` field
   can be `None` — when a previous `borrow_asset` call in the same PTB has
   already extracted the asset. Prevents a double-borrow from producing an
   opaque framework abort via `option::extract`.
   `let asset = option::extract(&mut escrow.asset);`
6. Construct `receipt = AssetReceipt { escrow_id, asset_id: object::id(&asset) }`.
7. Emit `AssetBorrowed { escrow_id: receipt.escrow_id,
   tenant_cap_id: object::id(tenant_cap) }`. Emit-last: the extraction
   (step 5) has already succeeded and the receipt (step 6) witnesses the
   asset has left the escrow. The tenant's identity is recoverable by
   JOIN on `tenant_cap_id` to `TenantCapMinted` — not duplicated here.
8. Return `(asset, receipt)`.

**Why `return_asset` requires no cap re-verification:** `return_asset` can
only be called by a PTB that holds an `AssetReceipt`. An `AssetReceipt` can
only exist if `borrow_asset` was called and succeeded in the same PTB — the
hot-potato type makes it impossible to store, transfer, or fabricate. And
`borrow_asset` only succeeds for the current tenant (steps 3–4). The receipt
is therefore irrefutable proof that cap authorization was already verified.
No re-check is needed.

**PTB clock-fixity — supporting invariant:** Sui fixes `clock::timestamp_ms()`
at checkpoint time; it does not advance between PTB steps. Any handover due
at that timestamp was already resolved by `apply_pending_transitions` in
step 1. No new transitions can fire within the same transaction, so
`current_tenant_cap_id` cannot rotate after the receipt is issued. This
explains why no state change can have occurred between the two calls —
but the primary authorization argument is the receipt itself.

**Event rationale.** `AssetBorrowed` is the first observable record that
the capability actually leaves custody to be used. The hot-potato
receipt guarantees the borrow is paired with a `return_asset` in the
same PTB, but it does not reach the off-chain indexer — only emitted
events do. Without `AssetBorrowed` / `AssetReturned`, the indexer
cannot distinguish a tenant who actively uses the asset from one who
merely holds the capability — the core demand signal of liquid renting
would be invisible.

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
   `E_RECEIPT_ESCROW_MISMATCH`.
3. Assert `asset_id == object::id(&asset)`, abort
   `E_RECEIPT_ASSET_MISMATCH`.

**Together these encode: "the same asset returns to the same
escrow."**

- `asset_id` ties receipt to asset: prevents substitution
  (returning a type-compatible but different object — `Asset` is a
  generic `key + store` type, so two instances of `T` are
  structurally indistinguishable except by `object::id`).
- `escrow_id` ties receipt to destination: prevents cross-return
  (redirecting to a different escrow the caller happens to hold
  tenancy of, with compatible `Asset` type).

The hot-potato itself only forces *that* a return happens in the
same PTB; these two fields force *what* that return looks like.
Both asserts are independent — neither alone is sufficient.
4. Let `tenant_cap_id = *option::borrow(&escrow.current_tenant_cap_id);`
   Safe: PTB clock-fixity (§6.1) guarantees `current_tenant_cap_id` has
   not rotated since `borrow_asset` succeeded earlier in the same PTB —
   it is the same tenant cap that authorized the borrow.
5. `option::fill(&mut escrow.asset, asset);`
6. Emit `AssetReturned { escrow_id, tenant_cap_id }`. Emit-last: the
   asset has already been restored to the escrow (step 5) so the
   `AssetReturned` semantic is realized.
7. Does **not** call `apply_pending_transitions` — returning an asset never
   needs to resolve boundary events; no balance is touched, no state field
   changes. The PTB clock-fixity invariant (§6.1) guarantees no new
   transition can have fired since `borrow_asset` ran in the same PTB.

**Event rationale.** See §6.1 — `AssetReturned` closes the borrow pair
the indexer needs to measure actual capability usage. JOIN on
`tenant_cap_id` to the preceding `AssetBorrowed` reconstructs the full
borrow window.


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
   principal used is `balance::value(&escrow.tenant_stake)` (see §8.1).
2. Let `remain_credit = balance::value(&escrow.tenant_stake) - used_credit`.
   (Invariant `used_credit + remain_credit == tenant_stake` from curve
   bijectivity.)
3. **Push `remain_credit` before any address rotation** (push-before-rotate
   invariant): bring `tenant_stake` down to exactly `used_credit` so §7.6's
   precondition holds.
   - `let displaced_tenant = *option::borrow(&escrow.current_tenant_address);`
   - `if remain_credit > 0`:
     - `let remain_balance = balance::split(&mut escrow.tenant_stake, remain_credit);`
     - `transfer::public_transfer(coin::from_balance(remain_balance, ctx), displaced_tenant);`
     // When countdown == remaining_rent_time the curve saturates:
     // used_credit == tenant_stake and remain_credit == 0. Skipping the split
     // avoids creating a zero Balance that Move requires to be consumed.
     // Consequence of `countdown = min(escrow.config.handover_floor, remaining)`.
4. **Settle `used_credit`** — §7.6 is the single source of truth for
   "split 90/10, route fee iff > 0, drain remainder into owner_earnings".
   Precondition `balance::value(&escrow.tenant_stake) == used_credit` is
   established by step 3.
   - `let (owner_share, protocol_fee) = settle_stake_earnings(escrow, used_credit, displaced_tenant, ctx);`
     — `displaced_tenant` is the stake funder; `FeeMessageSent<C>.tenant`
     records it verbatim. The returned `(owner_share, protocol_fee)` is
     consumed by the `HandoverCompleted` emit at step 9.
5. **Rotate `pending_bid` → `tenant_stake`** and record acquisition price:
   - `balance::join(&mut escrow.tenant_stake,
     balance::withdraw_all(&mut escrow.pending_bid));`
   - `escrow.last_acquisition_price = balance::value(&escrow.tenant_stake);`
   — Written here because handover is an acquisition: the new tenant takes
   possession at `boundary_ms`. `last_acquisition_price` is the descent
   ceiling if this tenant's block later expires into `AtDutchAuction`.
6. **Mint new TenantCap and push to the absent recipient** (split:
   `tenant_cap::new` returns the cap by value, then this module pushes
   it via `transfer::public_transfer` — legal under `TenantCap : key +
   store`):
   - `let pending_addr = *option::borrow(&escrow.pending_tenant_address);`
   - `let (new_cap, new_cap_id) = tenant_cap::new(object::id(escrow), pending_addr, ctx);`
     — `TenantCapMinted.tenant` records `pending_addr`, the new tenant
     installed by this handover. The address is not `tx_context::sender`
     (the caller of `apply_pending_transitions` may be a keeper or any
     permissionless settler, not the incoming tenant).
   - `transfer::public_transfer(new_cap, pending_addr);` — push to the
     absent recipient (the bid placer is not in this transaction). The
     `new_cap_id` is consumed at step 7 to update
     `current_tenant_cap_id`.
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
   new_rent_price: escrow.last_acquisition_price, timestamp_ms: boundary_ms }`.
   `new_rent_price` is the winning bid amount — `escrow.last_acquisition_price`
   was written at step 5 of this function (`pending_bid → tenant_stake`
   rotation); reading it here is the canonical snapshot of the new block's price. The new
   tenant's address is not carried — it is already on the co-emitted
   `TenantCapMinted.tenant` row and recoverable by JOIN on
   `new_tenant_cap_id`. `displaced_tenant` *is* carried: no PK path
   reaches the outgoing cap from this row, so recovering it via JOIN
   would force envelope-timing reconstruction (violating invariant d).

**Edge cases — both extremes fall out of the `if remain_credit > 0` guard
(step 3) and the `if protocol_fee > 0` gate inside `settle_stake_earnings`
(§7.6):**

- **`used_credit == 0`** (very convex curve, handover fires very early):
  `remain_credit == tenant_stake > 0`. The `if remain_credit > 0` guard fires —
  the full stake is pushed to the displaced tenant as `Coin<C>`. Step 4 then
  calls `settle_stake_earnings(escrow, 0, ...)`: `split_fee(0)` returns
  `(0, 0)`, the in-helper `if protocol_fee > 0` gate is skipped — no fee
  split and no `FeeMessage<C>` construction — and the helper's
  `withdraw_all` on the now-empty stake returns `Balance(0)`, joined as a
  no-op into `owner_earnings`. No zero-value coin transfer occurs.

- **`used_credit == tenant_stake`** (Dutch Auction bypass — curve saturated,
  `remain_credit == 0`): the `if remain_credit > 0` guard is skipped — no coin
  is pushed to the displaced tenant. Step 4 then calls
  `settle_stake_earnings(escrow, tenant_stake, ...)`: `split_fee` produces
  the normal 90/10 split, the in-helper `if protocol_fee > 0` gate fires —
  `fee_message::post` routes a non-zero `FeeMessage<C>` — and the helper's
  `withdraw_all` moves the owner share into `owner_earnings`.

In the `used_credit == 0` branch, after the full-stake push to the displaced
tenant the stake is empty when the helper runs.
`balance::withdraw_all(Balance(0))` returns `Balance(0)` and
`balance::join(_, Balance(0))` is a no-op — both are valid operations
against the framework source (`withdraw_all` delegates to `split(self,
self.value)`, and `split` asserts `self.value >= value` which holds for 0).
No zero-valued `Balance<CoinType>` is ever handed to `fee_message::post`:
the in-helper `if protocol_fee > 0` gate filters those out.

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

1. Let `stake_total = balance::value(&escrow.tenant_stake)` — used_credit saturated to full.
2. Let `tenant = *option::borrow(&escrow.current_tenant_address);`
3. **Settle the full stake** — §7.6 is the single source of truth for
   "split 90/10, route fee iff > 0, drain remainder into owner_earnings".
   Precondition `balance::value(&escrow.tenant_stake) == stake_total` holds
   directly — tenure expiry does not pre-split the stake.
   - `let (owner_share, protocol_fee) = settle_stake_earnings(escrow, stake_total, tenant, ctx);`
     — `tenant` is the outgoing tenant bound at step 2; `FeeMessageSent<C>.tenant`
     records it verbatim. The in-helper `if protocol_fee > 0` gate short-circuits
     on pathological `stake_total < BPS_PER_UNIT / PROTOCOL_FEE_BPS == 10`
     (since fee = `mul_div(stake, PROTOCOL_FEE_BPS, BPS_PER_UNIT)` floors to
     zero); protocols enforcing `min_rent_price ≥ 10` never see this branch,
     but the gate keeps the function structurally total.
4. **Clear tenant fields** (no new tenant to register):
   - `escrow.current_tenant_cap_id = none();`
   - `escrow.current_tenant_address = none();`
5. **Determine next state:**
   - If `escrow.retire_flag`: `escrow.state = Retired`.
     `escrow.phase_start_ms = boundary_ms;` (bookkeeping).
   - Else: `escrow.state = AtDutchAuction;
     escrow.phase_start_ms = boundary_ms;`.
     `last_acquisition_price` is preserved — it is the starting price of the descent.
6. Emit `TenureExpired { escrow_id, tenant, owner_share, protocol_fee,
   last_acquisition_price: escrow.last_acquisition_price, next_state: escrow.state,
   timestamp_ms: boundary_ms }`. `last_acquisition_price` is preserved by
   step 5 (see AtDutchAuction branch) and frozen into this row: it is the
   anchor of the subsequent Dutch descent (if `next_state =
   AtDutchAuction`) and makes the Dutch current-price computation a
   single-event query.
7. If `escrow.state == Retired` (the `retire_flag` branch of step 5),
   emit `AssetRetired { escrow_id, from_state: Rented }` immediately
   after `TenureExpired`. Structural co-emission: the indexer recovers
   the authoritative transition timestamp by JOIN on `escrow_id` to the
   co-emitted `TenureExpired.timestamp_ms`. Emit order is
   `TenureExpired` first (stake settlement), `AssetRetired` second
   (state-machine transition); both belong to the same semantic moment.

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
4. Emit `AuctionExpired { escrow_id, timestamp_ms: boundary_ms }`. The
   transition is always `AtDutchAuction → Idle`; `do_auction_expiry` is
   the sole emission site (retire from AtDutchAuction takes a different
   path — §4.2 step 7). Unambiguous by construction, no `next_state`
   field.

**Note on `last_acquisition_price`:** not modified here. After auction expiry,
`last_acquisition_price` holds what the last tenant paid. The next `rent()` from
Idle overwrites it via `install_new_tenant` as part of its normal acquisition logic.

---

### 7.4 `split_fee`

    fun split_fee(amount: u64): (u64, u64)

**Purpose:** pure function that splits an amount into (owner_share,
fee_share) at 90/10.

**Algorithm:**

    let fee   = math::mul_div(amount, PROTOCOL_FEE_BPS, BPS_PER_UNIT);
    let owner = amount - fee;
    (owner, fee)

**Properties:**
- `owner + fee == amount` always (no rounding loss — subtraction is exact).
- `fee <= floor(amount * 0.10)` — floor rounding favors the owner by at most
  1 base unit. Economically negligible; structurally simple.
- `split_fee(0) == (0, 0)`.
- `split_fee(n) == (n, 0)` for `n < 10` — fee floors to zero on amounts
  below 10 base units. Callers
  (`do_handover`, `do_tenure_expiry`) gate on `protocol_fee > 0` and skip the
  split + `fee_message::post` when it is zero, so no zero-balance
  `FeeMessage<C>` is ever constructed.

---

### 7.5 `install_new_tenant`

    fun install_new_tenant<Asset: key + store, CoinType>(
        escrow:  &mut RentalEscrow<Asset, CoinType>,
        payment: Coin<CoinType>,
        clock:   &Clock,
        ctx:     &mut TxContext,
    ): (TenantCap, ID)

**Preconditions:** `escrow.state` is one of `{ Idle, AtDutchAuction }`. The
caller has already validated `payment` against `compute_floor_price`
(unified floor check in `rent()` §5.1 step 2).

**Purpose:** shared installation sequence for the two acquisition arms of
`rent()` that land on an empty escrow — build `TenantCap`, absorb payment,
anchor the new phase, transition to `Rented { HandoverOpen }`. Both arms
produce structurally identical post-state; the only arm-specific signal is
the `from_state` field of the emitted `RentStarted` event, which the caller
owns. Returns the cap by value so `rent()` can surface it through its
`Option<TenantCap>` slot — no push happens in or below this helper.

**Algorithm:**

1. `escrow.last_acquisition_price = coin::value(&payment);`
2. `balance::join(&mut escrow.tenant_stake, coin::into_balance(payment));`
3. `escrow.phase_start_ms = clock.timestamp_ms();`
4. `let tenant_addr = tx_context::sender(ctx);`
5. `let (new_cap, new_cap_id) = tenant_cap::new(object::id(escrow), tenant_addr, ctx);`
   — pure constructor + emitter inside `tenant_cap`. No transfer.
   `TenantCapMinted.tenant` records `tenant_addr`. Unlike `do_handover`,
   here the sender IS the new tenant (paid `rent()` directly), present
   in the same transaction, so the cap travels back through the return
   tuple instead of via a push.
6. `escrow.current_tenant_cap_id = some(new_cap_id);`
7. `escrow.current_tenant_address = some(tenant_addr);`
8. `escrow.state = Rented { phase: HandoverOpen };`
9. Return `(new_cap, new_cap_id)`.

**Return value:** the new `TenantCap` (by value) and its `ID`. The
caller (`rent()`) uses the `ID` to emit `RentStarted { ...,
tenant_cap_id: new_cap_id, ... }` with its arm-specific `from_state`,
and surfaces the cap itself in its `Option<TenantCap>` return slot.

**Why the helper does not emit `RentStarted`:** the event's `from_state`
field discriminates between `Idle` and `AtDutchAuction` callers. Keeping
the emit at each arm preserves that signal explicitly at the callsite
instead of threading an extra `from_state` argument through the helper.

**Two call sites:**

| Caller | Floor source | Event `from_state` |
|---|---|---|
| `rent()` Case `Idle` (§5.1) | `compute_floor_price` (step 2) | `AssetState::Idle` |
| `rent()` Case `AtDutchAuction` (§5.1) | `compute_floor_price` (step 2) | `AssetState::AtDutchAuction` |

Both arms share the same post-state; the helper is the single source of
truth for "install a new tenant from payment into an empty escrow".

**Not reused by `do_handover`:** `do_handover` also mints a `TenantCap` and
transitions to `HandoverOpen`, but the surrounding state differs
structurally — `pending_bid` rotates into `tenant_stake` (not a fresh
payment), the target address is `pending_tenant_address` (not
`sender(ctx)`), the cap is **pushed** to the absent recipient (not
returned by value), and `phase_start_ms = boundary_ms` (not
`clock.now()`). Merging the two would force context-dependent branching
inside the helper and obscure the distinct semantics of each rotation
site.


### 7.6 `settle_stake_earnings`

    fun settle_stake_earnings<Asset: key + store, CoinType>(
        escrow:    &mut RentalEscrow<Asset, CoinType>,
        principal: u64,
        payer:     address,
        ctx:       &mut TxContext,
    ): (u64, u64)

**Purpose:** shared stake-settlement tail for `do_handover` (§7.1 step 4)
and `do_tenure_expiry` (§7.2 step 3). Splits `principal` 90/10, routes the
fee via `fee_message::post` (gated on `> 0`), drains the remainder into
`owner_earnings`. Returns `(owner_share, protocol_fee)` for the caller's
event emission.

**Preconditions:**
- `balance::value(&escrow.tenant_stake) == principal` — the caller has
  already drained any non-settlement portion before invoking the helper
  (`remain_credit` in the handover path; nothing in the tenure path). The
  helper is an unconditional settlement of whatever is in `tenant_stake`;
  the amount is passed explicitly so `split_fee` and the returned shares
  agree with the caller's event.
- `payer` is the address whose stake funded `principal` — recorded on
  `FeeMessageSent<C>.tenant`: `displaced_tenant` in `do_handover`
  (outgoing current tenant whose `tenant_stake` is being settled at
  handover); `tenant` in `do_tenure_expiry` (outgoing current tenant whose
  stake saturated to full at tenure expiry).

**Algorithm:**

    let (owner_share, protocol_fee) = split_fee(principal);

    if protocol_fee > 0 {
        let fee_balance = balance::split(&mut escrow.tenant_stake, protocol_fee);
        fee_message::post<CoinType>(
            fee_balance, object::id(escrow), payer,
            escrow.fee_inbox_id, ctx,
        );
    };
    balance::join(
        &mut escrow.owner_earnings,
        balance::withdraw_all(&mut escrow.tenant_stake),
    );
    (owner_share, protocol_fee)

**Postconditions:**
- `escrow.tenant_stake` is empty (`balance::zero()`).
- `escrow.owner_earnings` grew by `owner_share`.
- A `FeeMessage<C>` carrying `protocol_fee` was routed to `fee_inbox_id` iff
  `protocol_fee > 0`.

**Why the gate on `protocol_fee > 0`:** §7.4 `split_fee` floors the fee to
zero when `principal < BPS_PER_UNIT / PROTOCOL_FEE_BPS == 10`. Constructing
and consuming a zero-valued `Balance<CoinType>` — or a zero-valued
`FeeMessage<C>` — would be valid Move but semantically noisy and would emit
a `FeeMessageSent<C>` row the indexer cannot usefully aggregate. The gate
is a structural filter; see §9 P12.

**Why the helper does not emit `HandoverCompleted` / `TenureExpired`:** the
two events carry arm-specific fields (`HandoverCompleted.displaced_tenant`
+ `new_tenant_cap_id` + `used_credit` + `remain_credit` + `new_rent_price`;
`TenureExpired.tenant` + `last_acquisition_price` + `next_state`) beyond the
shared `(owner_share, protocol_fee)`. Emit-last at the caller keeps each
event's semantic timestamp aligned with the full boundary transition
(`do_handover` through the TenantCap rotation; `do_tenure_expiry` through
the next-state decision) rather than with a partial stake settlement.

**Two call sites:**

| Caller | `principal` | `payer` | Tenant-stake state at entry |
|---|---|---|---|
| `do_handover` (§7.1 step 4) | `used_credit` | `displaced_tenant` | equals `used_credit` — step 3 pushed `remain_credit` out |
| `do_tenure_expiry` (§7.2 step 3) | `stake_total` | `tenant` | equals `stake_total` — no pre-split |


### 7.7 `register_pending_bid`

    fun register_pending_bid<Asset: key + store, CoinType>(
        escrow:  &mut RentalEscrow<Asset, CoinType>,
        payment: Coin<CoinType>,
        ctx:     &mut TxContext,
    ): (PaymentTicket, u64)

**Purpose:** shared pending-bid installation tail for the two `Rented` arms
of `rent()` (§5.1). Absorbs `payment` into `escrow.pending_bid` and builds
a `PaymentTicket` via `payment_ticket::new`. Returns `(ticket, bid_amount)`
— the ticket travels back through `rent`'s `Option<PaymentTicket>` return
slot to the bidder (the PTB caller); the caller uses `bid_amount` to emit
`BidPlaced` / `BidSuperseded` with the correct amount field.

**Preconditions:**
- Caller has already verified `coin::value(&payment) >= floor` (from
  `compute_floor_price`, step 2 of `rent()`).
- For the supersede path (`HandoverConfirmed` caller), the previous
  `pending_bid` has already been refunded and drained, and
  `pending_tenant_address` has been rotated to the new bidder
  (push-before-rotate invariant, §9 P3 — owned by the caller).

**Algorithm:**

    let bid_amount = coin::value(&payment);
    balance::join(&mut escrow.pending_bid, coin::into_balance(payment));
    let ticket = payment_ticket::new<Asset, CoinType>(
        object::id(escrow), bid_amount, ctx,
    );
    (ticket, bid_amount)

**Postconditions:**
- `escrow.pending_bid` grew by `bid_amount`.
- A `PaymentTicket` carrying `escrow_id`, `bid_amount`, and the canonical
  `Asset` / `CoinType` strings has been built (no transfer); ownership
  travels back to `rent`'s caller through the return tuple.

**Why no `recipient` parameter:** the bidder is, by construction, the PTB
caller of `rent` — the same actor across both `Rented` sub-branches.
Under `key + store` the ticket can be returned by value; the helper does
not need to know the recipient address because it never performs a
transfer. The recipient address is recorded separately on
`escrow.pending_tenant_address` (which the caller sets) and on the
emitted `BidPlaced` / `BidSuperseded` event row.

**Why the helper does not emit `BidPlaced` / `BidSuperseded`:** the two
events differ structurally — `BidPlaced` carries `pending_tenant` and
`handover_countdown_expiry`; `BidSuperseded` carries `displaced_bidder`,
`refunded_amount`, `new_bidder`, `new_bid_amount`. Both carry `floor_price`,
which is the `floor` local from `rent()` step 2 — available at the caller,
not inside the helper. Their arm-specific
pre-tail setup (countdown computation + state transition for HandoverOpen;
refund + address rotation for HandoverConfirmed) also differs. Emit-last at
each caller keeps the event semantic aligned with the full bid-placement
transition, not with the shared tail alone. See non-starter §9 in
rental_escrow.note for why a fuller merge would reintroduce branching.

**Two call sites:**

| Caller | Pre-tail work | Emitted event |
|---|---|---|
| `rent()` Case `Rented { HandoverOpen }` (§5.1) | retire-flag check, floor check, countdown write, `pending_tenant_address = some(sender)`, state → `HandoverConfirmed` | `BidPlaced` |
| `rent()` Case `Rented { HandoverConfirmed }` (§5.1) | floor check, refund previous `pending_bid` to `displaced_bidder`, rotate `pending_tenant_address` to new bidder | `BidSuperseded` |

Both arms share the same post-state for `pending_bid` / ticket
construction; the helper is the single source of truth for that tail.


8. READ-ONLY QUERIES
---------------------

Read-only functions do not mutate the escrow. Via `devInspectTransactionBlock`
they execute for free with no consensus involvement. In a regular PTB, taking
`&RentalEscrow` (shared object) still requires consensus, but read-only
transactions on the same object can execute in parallel without ordering
between them — reducing contention compared to mutable access.

**Reading settled state:** use `apply_pending_transitions` via
`devInspectTransactionBlock`. It resolves all pending transitions and returns
the settled `AssetState` without committing the transaction — free, no
consensus. This is more correct than a dedicated read-only query because it
reflects the actual settled state, not a speculative computation.

**Public API surface — two queries:**

| Function | Visibility | Returns |
|---|---|---|
| `compute_used_credit(escrow, timestamp_ms)` (§8.1) | `public` | credit consumed by the current tenant at `timestamp_ms` |
| `compute_floor_price(escrow, timestamp_ms)` (§8.4) | `public` | minimum payment required to acquire the asset in the current state |

These two cover every externally observable read: "how much has my tenancy
consumed" and "what would it cost to become tenant right now". Both can abort
on precondition violation — a deliberate choice. Abort codes carry named
semantic load (§1.1 is `public` for exactly this reason); an SDK receiving
`E_NOT_RENTED` or `E_RETIRED_NO_BID` maps it to a user-facing condition
directly. A sentinel return (`Option<u64>`, magic `0`) would collapse that
information and force the caller into a secondary state fetch.

**Per-arm price helpers — `public(package)`:**

The price dispatched by `compute_floor_price` is computed by two arm-specific
helpers, visible only inside the package:

| Helper | Visibility | Arms served |
|---|---|---|
| `compute_price_descent(escrow, timestamp_ms)` (§8.2) | `public(package)` | `AtDutchAuction` |
| `compute_next_rent_price(escrow, price)` (§8.3) | `public(package)` | `Rented{HandoverOpen}`, `Rented{HandoverConfirmed}` |

Both are called from exactly one site: `compute_floor_price` (§8.4), which
dispatches by state before calling. `rent()` (§5.1) reaches both through
`compute_floor_price` — keeping internal and external floor computations in
lockstep with no divergence possible. Neither helper carries a state guard —
it would be structurally unreachable, defensive against nothing. Keeping them
`public(package)` makes that guarantee a visibility-level fact rather than a
prose claim.

**Naming convention — `compute_*`:**

All read-only queries use the `compute_*` prefix uniformly.
`compute_X(escrow, ...)` reads as "compute the value of X from the escrow's
state (and the supplied inputs)" — an honest description regardless of
whether a timestamp is passed:

- `compute_used_credit(escrow, timestamp_ms)` (§8.1),
  `compute_price_descent(escrow, timestamp_ms)` (§8.2), and
  `compute_floor_price(escrow, timestamp_ms)` (§8.4) take an arbitrary
  timestamp and evaluate at that instant — not necessarily `clock.now()`.
  External callers typically pass `clock.timestamp_ms()` for "live" reads,
  but internal callers (e.g. `do_handover` passing `boundary_ms`) evaluate
  at past or boundary timestamps.
- `compute_next_rent_price(escrow, price)` (§8.3) depends only on the
  competitive price passed by the caller, so it needs no timestamp.

The `current_*` prefix is deliberately not used: it implies "now", and
a function accepting an arbitrary timestamp — or that any external caller
may inspect at an arbitrary point in a PTB — lies under that prefix.
Uniform `compute_*` keeps one convention for four functions that all do
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
    //    Principal is balance::value(&escrow.tenant_stake): the current
    //    tenant's payment. last_acquisition_price is inert in Rented states.
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

    public(package) fun compute_price_descent<Asset: key + store, CoinType>(
        escrow:       &RentalEscrow<Asset, CoinType>,
        timestamp_ms: u64,
    ): u64

**Precondition:** `escrow.state == AtDutchAuction`. Structurally guaranteed by
both call sites — no runtime guard. Returns `min_rent_price` once the descent
saturates.

**Algorithm:**

    // 1. Elapsed time since the auction started.
    //    phase_start_ms is set to the tenure-expiry boundary when AtDutchAuction begins.
    //    If timestamp_ms < phase_start_ms, return last_acquisition_price — auction has not started yet.
    if timestamp_ms < escrow.phase_start_ms { return escrow.last_acquisition_price };
    let elapsed_ms = timestamp_ms - escrow.phase_start_ms;

    // 2. Evaluate the normalized descent curve.
    let h = curve_shape::evaluate_curve(
        config::descent_curve(&escrow.config),
        elapsed_ms,
        config::descent_ceiling(&escrow.config),
    );

    // 3. Scale by the spread, then descend from last_acquisition_price.
    //    evaluate_curve returns SCALE when elapsed >= descent_ceiling, so
    //    consumed == spread and the result saturates at min_rent_price.
    //    Precondition last_acquisition_price >= min_rent_price is guaranteed by the
    //    protocol — every acquisition asserts payment >= compute_floor_price,
    //    and all floors (min_rent_price, compute_price_descent, compute_next_rent_price)
    //    are themselves >= min_rent_price. Note last_acquisition_price does NOT
    //    monotonically increase: a rent from AtDutchAuction can write a value
    //    below the previous last_acquisition_price (but still >= min_rent_price).
    let spread = escrow.last_acquisition_price - config::min_rent_price(&escrow.config);
    let consumed = math::mul_div(spread, h, SCALE);
    escrow.last_acquisition_price - consumed

`last_acquisition_price` is the starting price of the descent — set by the
last tenant's payment and preserved through tenure expiry and auction entry.

**One call site (dispatches by state before calling, so precondition holds):**

| Caller | Purpose |
|---|---|
| `compute_floor_price` (§8.4), `AtDutchAuction` arm | floor at `timestamp_ms` — used by both `rent()` and SDK/frontend via the public entry point |

**Why no state guard:** with `public(package)` visibility, every caller is
inside this package and has already dispatched on `escrow.state`. A guard
here would be defensive against a call path that cannot exist. See §8
preamble, "Per-arm price helpers".

---

### 8.3 `compute_next_rent_price`

    public(package) fun compute_next_rent_price<Asset: key + store, CoinType>(
        escrow: &RentalEscrow<Asset, CoinType>,
        price:  u64,
    ): u64

**Precondition:** `escrow.state` matches `Rented { .. }`. Structurally
guaranteed by all call sites — no runtime guard. No `timestamp_ms`
parameter — `f_next_rent_price` depends only on the current competitive
price, not on elapsed time. The caller passes the correct price based on state.

**Algorithm:**

    price_function::evaluate_price_fn(
        config::price_function(&escrow.config),
        price,
    )

**One call site (dispatches by state before calling):**

| Caller | Purpose |
|---|---|
| `compute_floor_price` (§8.4), `Rented{_}` arm | floor computation — passes `balance::value(&escrow.tenant_stake)` for `HandoverOpen` and `balance::value(&escrow.pending_bid)` for `HandoverConfirmed` |

**Why no state guard:** see §8.2 and §8 preamble. Same structural argument
— `public(package)` + pre-dispatched callers = guard unreachable.

---

### 8.4 `compute_floor_price`

    public fun compute_floor_price<Asset: key + store, CoinType>(
        escrow:       &RentalEscrow<Asset, CoinType>,
        timestamp_ms: u64,
    ): u64

Single public entry point for "minimum payment required to acquire the asset
at `timestamp_ms`". Dispatches by `escrow.state` to the arm-specific helper.

**Algorithm:**

    match (escrow.state) {
        AssetState::Idle                         => config::min_rent_price(&escrow.config),
        AssetState::Rented { HandoverOpen }      => compute_next_rent_price(escrow, balance::value(&escrow.tenant_stake)),
        AssetState::Rented { HandoverConfirmed } => compute_next_rent_price(escrow, balance::value(&escrow.pending_bid)),
        AssetState::AtDutchAuction               => compute_price_descent(escrow, timestamp_ms),
        AssetState::Retired                      => abort E_RETIRED_NO_BID,
    }

**Dispatch table:**

| State | Returns | Rationale |
|---|---|---|
| `Idle` | `config.min_rent_price` | floor is the configured minimum; time-invariant — `timestamp_ms` unused |
| `Rented { HandoverOpen }` | `compute_next_rent_price(escrow, balance::value(&escrow.tenant_stake))` | takeover floor — current tenant's stake is the competitive bar; time-invariant — `timestamp_ms` unused |
| `Rented { HandoverConfirmed }` | `compute_next_rent_price(escrow, balance::value(&escrow.pending_bid))` | supersede floor — pending bid escalates with each supersede; time-invariant — `timestamp_ms` unused |
| `AtDutchAuction` | `compute_price_descent(escrow, timestamp_ms)` | current Dutch price at `timestamp_ms`; time-varying |
| `Retired` | aborts `E_RETIRED_NO_BID` | asset is not rentable — same abort code that `rent()` raises on the same state |

**Why abort on `Retired` (not `Option<u64>` / sentinel):**

The error constants in §1.1 are `public` so the SDK can map abort codes to
human-readable messages — abort codes are the protocol's semantic signalling
channel between contract and client. `E_RETIRED_NO_BID` names the exact
condition ("asset retired, no acquisition possible"). Collapsing that to
`None` forces the SDK into a secondary `escrow.state` read to reconstruct
the reason — information already present on the abort path is lost in the
type. Aborting also keeps `compute_floor_price` symmetric with every other
public function on the protocol (`rent`, `borrow_asset`, `retire`,
`claim_asset`, `withdraw_earnings`, `compute_used_credit`), all of which
abort on precondition violation.

**Reuse of `E_RETIRED_NO_BID`:** the condition — "caller asks to acquire a
Retired escrow" — is semantically identical whether the caller is `rent()`
(write path) or `compute_floor_price` (read path). One named condition, one
constant.

**Why `timestamp_ms` is always taken, even when unused:** the parameter
signals "this function accepts a point in time", and is honest for the only
arm that reads it (`AtDutchAuction`). The three time-invariant arms ignore
it rather than overloading the function with a second signature. External
callers that want a live read pass `clock.timestamp_ms()`; frontends
painting the descent curve pass hypothetical future timestamps; both are
first-class uses.

**`rent()` is also an internal caller.** `rent()` calls `compute_floor_price`
at step 2 before the state dispatch — the same function external callers use.
This guarantees that the floor enforced on-chain and the floor the SDK queries
are always identical. `compute_floor_price` is therefore both the internal
enforcement gate and the external read-only query.

**UX note — lifecycle price chart:** a frontend graphing "price to acquire"
across the full escrow lifecycle calls `compute_floor_price(escrow,
clock.now())` whenever `state ∈ {Idle, Rented{_}, AtDutchAuction}`, and
renders a "not rentable" marker on catching `E_RETIRED_NO_BID`. The same
function also answers hypothetical "what would I pay at t = T" queries by
passing any `timestamp_ms` — critical for rendering the Dutch descent curve
ahead of time.

---

### 8.5 Boundary-timestamp helpers — `public(package)`

Two package-internal one-liners that name the boundary arithmetic
`escrow.phase_start_ms + escrow.config.<ceiling>`. Visible only inside
the package and used by `rent()` (§5.1) and `apply_pending_transitions`
(§5.2). The name transports the semantic — "the tenure / descent boundary
for the current phase" — which bare arithmetic does not.

    public(package) fun tenure_expiry_ms<Asset: key + store, CoinType>(
        escrow: &RentalEscrow<Asset, CoinType>,
    ): u64 {
        escrow.phase_start_ms + config::tenure_ceiling(&escrow.config)
    }

    public(package) fun descent_expiry_ms<Asset: key + store, CoinType>(
        escrow: &RentalEscrow<Asset, CoinType>,
    ): u64 {
        escrow.phase_start_ms + config::descent_ceiling(&escrow.config)
    }

**Call sites:**

| Helper | Caller | Purpose |
|---|---|---|
| `tenure_expiry_ms` | `rent()` Case `Rented{HandoverOpen}` (§5.1) | compute `remaining = tenure_expiry_ms(escrow) - clock.timestamp_ms()` for the handover-countdown clamp |
| `tenure_expiry_ms` | `apply_pending_transitions` Check 2 (§5.2) | compare against `clock.timestamp_ms()` to decide whether tenure expiry fires |
| `descent_expiry_ms` | `apply_pending_transitions` Check 3 (§5.2) | compare against `clock.timestamp_ms()` to decide whether auction expiry fires |

**Visibility:** `public(package)` — parallel to `compute_price_descent` and
`compute_next_rent_price` (§8.2 / §8.3). Not on the SDK surface; external
callers wanting these boundaries read them off the corresponding event
rows (`HandoverCompleted.timestamp_ms`, `TenureExpired.timestamp_ms`,
`AuctionExpired.timestamp_ms`) or derive them by reading
`IntegrationConfigRegistered.tenure_ceiling` / `.descent_ceiling` plus the
escrow's `phase_start_ms` — all already in the event surface (§3).


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
`owner_cap::new(escrow_id, owner, ctx)` / `owner_cap::burn(cap, owner)`
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
`protocol_fee == 0`. Both functions gate the `fee_message::post` call
behind `if protocol_fee > 0`, so no `FeeMessage<C>` is constructed on
the zero path. The escrow balances settle to their normal post-condition
via the owner-share branch alone.

10. TEST CASES
--------------

### 10.0 Test strategy

Tests live in module `rental_escrow_tests`, driven by `sui::test_scenario` plus
explicit `sui::clock::Clock` manipulation. `rental_escrow` is the integration
point of every other module in the package; the test surface is correspondingly
broad and must balance **full-state-machine rows** (drive the public API end-
to-end) with **unit rows** (isolate pure helpers with declarative inputs).

#### Canonical actors

| Alias | Address | Role |
|---|---|---|
| `OWNER` | `@0x0A` | Integrator / `OwnerCap` holder |
| `OWNER2` | `@0x0B` | Second owner address for cap-transfer rows (W2a) |
| `TENANT_A` | `@0xA1` | First tenant (T1) |
| `TENANT_B` | `@0xA2` | Second tenant (T2), pending bidder, displaced tenant |
| `BIDDER` | `@0xA3` | Third bidder for supersede rows |
| `KEEPER` | `@0x5E` | Permissionless `apply_pending_transitions` caller |
| `ADMIN` | `@0xAD` | `ProtocolFeeInbox` holder / fee collector |
| `ZERO` | `@0x0` | Negative-space rows |

The distinction between `TENANT_A`/`TENANT_B`/`BIDDER` and `KEEPER` is
load-bearing for several rows — e.g., `TenantCapMinted.tenant` inside
`do_handover` must equal `pending_tenant_address` (not `tx_context::sender`);
exercising that assertion requires `KEEPER` to call
`apply_pending_transitions` (§7.1 step 6).

#### Test fixtures

- **Asset witness.** A canonical `#[test_only]` type is declared in the test
  module so generics can be instantiated without dragging a real third-party
  asset crate:
  ```move
  #[test_only] public struct DemoAsset has key, store { id: UID }
  ```
  Rows that cover level-2 integration (T2, L3) use `rental_escrow::OwnerCap`
  directly as the `Asset` type parameter — no new witness needed.
- **CoinType witness.** `sui::sui::SUI` is the default; `balance::create_for_testing<SUI>(amount)`
  and `coin::mint_for_testing<SUI>(amount, ctx)` are the sole sources of funds.
  A second witness `#[test_only] public struct FAKE_USDC has drop {}` covers
  multi-coin rows in §10.11.
- **`ProtocolFeeInbox`.** Instantiated via `protocol_fee_inbox::init_for_testing`
  under `ADMIN`; the `ProtocolFeeRef` is retrieved with `take_immutable`.
- **`IntegrationConfig`.** Built through the public `config::new_config`
  constructor with a shared helper:
  ```move
  #[test_only] fun demo_config(
      tenure_ceiling_ms:  u64,
      descent_ceiling_ms: u64,
      handover_floor_ms:  u64,
      retire_floor_ms:    u64,
      min_rent_price:     u64,
  ): IntegrationConfig { ... }
  ```
  Curve shapes and price function default to a linear credit curve, linear
  descent, and `price_function::new_fixed_delta(1)` — unless a row
  specifically exercises curve behavior (those rows override via the helper
  variant).
- **Clock.** `sui::clock::create_for_testing(ctx)` plus
  `clock::set_for_testing(&mut clock, ms)` to advance deterministically.
  Scenario epoch helpers are **avoided** — `scenario.later_epoch(...)` does
  not map to `clock.timestamp_ms()` with guaranteed millisecond granularity,
  and every boundary in the spec is expressed in ms.

#### Test-only shims on private helpers

The private helpers (§7) are exercised indirectly through the state machine
for most rows. Three need direct unit coverage because their behavior is only
reachable through integration paths that mask their edge cases:

```move
#[test_only] public fun split_fee_for_testing(amount: u64): (u64, u64)
    { split_fee(amount) }
#[test_only] public fun tenure_expiry_ms_for_testing<A: key + store, C>(
    escrow: &RentalEscrow<A, C>,
): u64 { tenure_expiry_ms(escrow) }
#[test_only] public fun descent_expiry_ms_for_testing<A: key + store, C>(
    escrow: &RentalEscrow<A, C>,
): u64 { descent_expiry_ms(escrow) }
```

`do_handover`, `do_tenure_expiry`, `do_auction_expiry`, `install_new_tenant`,
`settle_stake_earnings`, `register_pending_bid` are **not** shimmed: they
have preconditions on `escrow.state` and balance fields that only the state
machine can establish cleanly, and exposing them would invite tests that
contradict real call-site invariants. They are covered through the public
API (rent, retire, apply_pending_transitions).

#### Event inspection

All rows that assert "N events emitted" use `test_scenario::next_tx`'s
`TransactionEffects` plus `event::events_by_type<T>()` — one call per event
type yields the typed vector, and row asserts check `length` + field
contents. The star-schema JOIN rows (B2, W2a) assert identity triples
across event pairs (`tenant_cap_id` across AssetBorrowed↔AssetReturned,
`owner_cap_id` across EarningsWithdrawn repetitions) rather than relying on
tx-envelope data.

#### Abort-row split-tx pattern

Already documented in §10.13. Lifted to this section so rows in §10.8
(C10–C13), §10.9 (W4–W5), §10.7 (B9–B10) can reference it by name: an
abort row that also needs to assert APT's work splits into two
transactions — tx1 calls `apply_pending_transitions` standalone (asserts
settled state + events + balances before the abort), tx2 calls the
aborting function. This applies anywhere an `#[expected_failure]` row
needs observable APT effects, not just in §10.13.

A secondary invariant for this pattern: **tx1 must fully succeed.** If
tx1 itself aborts (e.g., a bug makes APT read a `None` field), the
framework's abort catcher at tx2 sees no tx, and `expected_failure` still
matches by abort_code — masking the tx1 regression. Every tx1 in a
split-tx abort row therefore asserts at least one concrete postcondition
(an event count or a balance delta) before the `next_tx` boundary.

#### Axes (row prefixes already in §10.1–10.13 — retained)

- T — Integration
- R — rent() per-state paths
- A — apply_pending_transitions
- B — borrow_asset / return_asset
- C — retire / claim_asset
- W — withdraw_earnings
- Q — read-only queries
- F — fee routing
- L — full lifecycle
- M — APT + rent() composite matrix

New prefixes introduced in this audit:

- U — unit rows on pure helpers (§10.14)
- P — property mapping (§10.15)

### 10.1 Integration

| # | Description | Expected |
|---|---|---|
| T1 | `integrate<SomeAsset, C>` with a valid config and fee_ref | Returns `OwnerCap`. `RentalEscrow` shared. `state == Idle`. `last_acquisition_price == 0`. `phase_start_ms == 0`. `integrated_at_ms == clock.timestamp_ms()`. `fee_inbox_id == object::id(&protocol_fee_inbox)`. `IntegrationConfigRegistered` and `AssetIntegrated<SomeAsset, C>` events emitted (config first, then asset). Event type tag of `AssetIntegrated` carries both phantom type params — asserts the indexer can recover Asset and CoinType without reading the on-chain object. `AssetIntegrated.asset_id == object::id(&input_asset)` — asserts the wrapped instance is identifiable. |
| T2 | `integrate<OwnerCap, C>` (deposit an existing escrow's cap) | Succeeds. Returns a second `OwnerCap` for the wrapping escrow. The wrapped cap becomes the wrapping escrow's `asset`. `AssetIntegrated.asset_id == object::id(&input_owner_cap)` — this is the level-1 `OwnerCap`'s ID; JOINing on `owner_cap_id` in `OwnerCapMinted` recovers the level-1 escrow, closing the level-2 → level-1 linkage from events alone. No depth check. |

### 10.2 `rent` — Idle path

| # | Description | Expected |
|---|---|---|
| R1 | Pay exactly `min_rent_price` | State → `Rented(HandoverOpen)`. `last_acquisition_price == min_rent_price`. `TenantCap` pushed to sender. `RentStarted` event. |
| R2 | Pay less than `min_rent_price` | Aborts `E_INSUFFICIENT_PAYMENT`. |
| R3 | Overpay from Idle | Accepted. `last_acquisition_price == full payment`. State → `Rented(HandoverOpen)`. |
| R4 | Rent when `retire_flag` set and state was Idle | State was moved to `Retired` by the prior `retire()` call (§4.2 step 6, Idle branch); `apply_pending_transitions` is a no-op here. Dispatch hits the `Retired` arm → aborts `E_RETIRED_NO_BID`. |

### 10.3 `rent` — AtDutchAuction path

| # | Description | Expected |
|---|---|---|
| R5 | Pay exactly `compute_price_descent(now)` | State → `Rented(HandoverOpen)`. `last_acquisition_price == payment`. `RentStarted{ from_state: AtDutchAuction }`. |
| R6 | Overpay (e.g. PTB latency) | Accepted. `last_acquisition_price == full payment`. No refund. |
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
| A7 | `do_handover` with `used_credit == 0` (very convex PowerLaw curve, handover fires immediately after bid) | `remain_credit == tenant_stake`. Full stake pushed to displaced tenant as `Coin<C>`. `owner_earnings` unchanged. No `FeeMessage<C>` constructed (the `if protocol_fee > 0` guard skips `fee_message::post`). `HandoverCompleted` emitted with `used_credit: 0`, `owner_share: 0`, `protocol_fee: 0`. |
| A8 | `do_handover` with `used_credit == tenant_stake` (Dutch Auction bypass — `remain_credit == 0`) | No coin pushed to displaced tenant. Full stake split 90/10 into `owner_earnings` and `FeeMessage`. `HandoverCompleted` emitted with `remain_credit: 0`. |

### 10.7 `borrow_asset` / `return_asset`

| # | Description | Expected |
|---|---|---|
| B1 | Borrow with valid current cap | Returns `(asset, receipt)`. `AssetBorrowed { escrow_id, tenant_cap_id }` event where `tenant_cap_id == object::id(tenant_cap)`. |
| B2 | Return via correct receipt + same asset | Asset back in escrow. Receipt consumed. `AssetReturned { escrow_id, tenant_cap_id }` event where `tenant_cap_id` matches the B1 borrow — JOIN on `tenant_cap_id` reconstructs the borrow window. |
| B2a | Multiple borrow/return pairs in the same tenancy | Each pair emits its own `AssetBorrowed` / `AssetReturned` on the same `tenant_cap_id`; indexer can count usage frequency per tenant. |
| B3 | Borrow with a stale cap (previous tenant after handover) | Aborts `E_STALE_TENANT_CAP`. |
| B4 | Borrow with cap for a different escrow | Aborts `E_WRONG_ESCROW_TENANT_CAP`. |
| B5 | Return with receipt for a different escrow | Aborts `E_RECEIPT_ESCROW_MISMATCH`. |
| B6 | Return a different asset (substitution attempt) | Aborts `E_RECEIPT_ASSET_MISMATCH`. |
| B7 | Forget to return (receipt unconsumed) | PTB fails to type-check — hot potato must be consumed. |
| B8 | `borrow_asset` called twice in the same PTB | Second call aborts `E_ASSET_ALREADY_BORROWED` — asset field is `None` after the first extraction. |
| B9 | `borrow_asset` called by T(n) with T(n)'s cap when pre-APT state is `Rented(HandoverConfirmed)` and handover has expired — APT fires C1 rotating `current_tenant_cap_id` to T(n+1) before the staleness check | Split-tx per §10.13 abort-row strategy. **tx1** (standalone `apply_pending_transitions`): fires `do_handover` — T(n+1) installed, `current_tenant_cap_id` rotates to T(n+1)'s cap ID, `HandoverCompleted` emitted, `owner_earnings` credited, new `TenantCap` pushed to T(n+1), state → `Rented(HandoverOpen)`. **tx2** (`borrow_asset` with T(n)'s cap): §6.1 step 3 passes (cap belongs to this escrow), step 4 fails — `current_tenant_cap_id` now holds T(n+1)'s ID, not T(n)'s — aborts `E_STALE_TENANT_CAP` at the identity compare. Distinct from B3 (cap that was already stale pre-call): here the cap becomes stale **during** the call via APT's own work. Asserts §6.1 step 1 runs before step 4. |
| B10 | `borrow_asset` called by T(n) with T(n)'s cap when pre-APT state is `Rented(HandoverOpen)` and tenure has expired (no handover pending) — APT fires C2 clearing `current_tenant_cap_id` before the staleness check | Split-tx per §10.13 abort-row strategy. **tx1** (standalone `apply_pending_transitions`): fires `do_tenure_expiry` — `tenant_stake × 0.90` → `owner_earnings`, `FeeMessage<C>` routed, `current_tenant_cap_id = none`, `current_tenant_address = none`, state → `AtDutchAuction`, `TenureExpired` emitted. **tx2** (`borrow_asset` with T(n)'s cap): step 4's `is_some` guard on `escrow.current_tenant_cap_id` fails — slot was cleared — aborts `E_STALE_TENANT_CAP` at the unwrap guard. Complements B9: same abort code, different APT transition (C2 clears ⇒ unwrap-guard path; C1 rotates ⇒ identity-compare path). |

### 10.8 `retire` / `claim_asset`

| # | Description | Expected |
|---|---|---|
| C0 | `retire(escrowA, capB)` where `capB` is a legitimate `OwnerCap` for a different escrow B | Aborts `E_WRONG_ESCROW_OWNER_CAP` at §4.2 step 1 — the escrow-match gate. Same PTB-pairing defense as `claim_asset` (C8) and `withdraw_earnings` (W3). Asserts the gate is present on all three `&OwnerCap`-taking functions, not just the two that consume the cap. |
| C1 | `retire` before `retire_floor` elapsed | Aborts `E_RETIRE_FLOOR_NOT_ELAPSED`. |
| C1a | `retire` at exactly `integrated_at_ms + retire_floor` | Succeeds — boundary is inclusive per §4.2 step 4 (`>=`). Complements C1 (strict-less) to pin the comparator. |
| C2 | `retire` from Idle (after `retire_floor`) | `retire_flag = true`. `state → Retired`. Events in order: `RetireFlagSet(owner, state_at_set: Idle)` with `owner == tx_context::sender(ctx)`, `AssetRetired(from_state: Idle)`. |
| C3 | `retire` from AtDutchAuction | `retire_flag = true`. `state → Retired`. Events in order: `RetireFlagSet(owner, state_at_set: AtDutchAuction)`, `AssetRetired(from_state: AtDutchAuction)`. No `AuctionExpired` — the auction was interrupted, not expired. |
| C4 | `retire` from Rented(HandoverOpen) | `retire_flag = true`. `state` unchanged. Subsequent `rent()` aborts `E_RETIRE_FLAG_BLOCKS_BID`. |
| C5 | `retire` from Rented(HandoverConfirmed) | `retire_flag = true`. `state` unchanged. Handover completes normally; new tenant enters HandoverOpen with flag set. |
| C6 | Second `retire` call | Aborts `E_ALREADY_RETIRED`. |
| C7 | `claim_asset` when `state != Retired` | Aborts `E_NOT_RETIRED`. |
| C8 | `claim_asset` with non-matching `OwnerCap` | Aborts `E_WRONG_ESCROW_OWNER_CAP`. |
| C9 | `claim_asset` on Retired with accumulated earnings | Returns `(asset, coin == owner_earnings)`. OwnerCap burned. Escrow deleted. `AssetClaimed` event. |
| C10 | Full retire-then-claim flow from Rented | `retire` (tx1) emits `RetireFlagSet(state_at_set: Rented(HandoverOpen))` only — no `AssetRetired` yet (deferred). Tenure expiry resolved in tx2 by `apply_pending_transitions`: state → `Retired`, events in order `TenureExpired(next_state: Retired)`, `AssetRetired(from_state: Rented)`. `claim_asset` (tx3) succeeds. |
| C11 | `claim_asset` with `retire_flag` already set, pre-APT state `Rented(HandoverConfirmed)`, both handover and T(n+1)'s tenure expired — APT chains C1 → C2(→Retired) before claim's own logic | APT fires `do_handover`: T(n+1) installed, `owner_earnings += used_credit × 0.90`, `remain_credit` pushed to T(n), new `TenantCap` pushed to T(n+1), `retire_flag` preserved. APT then fires `do_tenure_expiry` with the flag set: `owner_earnings += T(n+1)_stake × 0.90`, state → `Retired`. Claim body asserts `state == Retired` ✓ and returns `(asset, Coin == accumulated owner_earnings)`. Events in order: `HandoverCompleted`, `TenureExpired(next_state: Retired)`, `AssetRetired(from_state: Rented)`, `AssetClaimed`. Pairs with C10 (which covers the chain starting from HandoverOpen). |
| C12 | `retire` called when pre-APT state is `Rented(HandoverOpen)` and tenure has expired (no prior retire_flag) — APT fires C2 moving state to `AtDutchAuction` before retire's own logic | APT fires `do_tenure_expiry` with flag unset: `owner_earnings += tenant_stake × 0.90`, state → `AtDutchAuction`, `TenureExpired` emitted with `timestamp_ms = boundary`. Retire body then asserts `!retire_flag` ✓ and sets it; §4.2 step 7 matches the AtDutchAuction branch: `state → Retired`, `phase_start_ms = clock.now()`. Events in order: `TenureExpired`, `RetireFlagSet(state_at_set: AtDutchAuction)`, `AssetRetired(from_state: AtDutchAuction)`. No `AuctionExpired` — the auction was interrupted by retire, not expired. Asserts retire's dispatch branch is driven by the post-APT state, not the pre-call state (C4 covers the static Rented pre-state where APT is a no-op). |
| C13 | `retire` called when pre-APT state is `Rented(HandoverConfirmed)` and handover has expired (no prior retire_flag) — APT fires C1 moving state to `Rented(HandoverOpen)` with T(n+1) installed before retire's own logic | APT fires `do_handover`: T(n+1) installed, owner earnings credited, `HandoverCompleted` emitted. Retire body then sets `retire_flag = true`; state is `Rented(HandoverOpen)` so §4.2 step 6 is a no-op (no immediate transition). Emits `RetireFlagSet(state_at_set: Rented(HandoverOpen))`. Flag now applies to T(n+1)'s tenure — any subsequent `rent()` from another bidder aborts `E_RETIRE_FLAG_BLOCKS_BID`. Distinct from C5, where retire runs on `Rented(HandoverConfirmed)` directly (APT no-op) and the flag is inherited by T(n+1) via the later handover. |

### 10.9 `withdraw_earnings`

| # | Description | Expected |
|---|---|---|
| W1 | Withdraw with zero earnings | Aborts `E_NO_EARNINGS`. |
| W2 | Withdraw with positive earnings | Returns Coin of exact balance. `owner_earnings == 0` after. `EarningsWithdrawn { escrow_id, owner_cap_id, owner, amount }` event with `owner_cap_id == object::id(owner_cap)` and `owner == tx_context::sender(ctx)`. |
| W2a | Same cap transferred between two distinct addresses, each withdraws once | Two `EarningsWithdrawn` rows sharing `owner_cap_id` but with different `owner` values. Confirms `owner` is first-observed per call — not cached from mint-time. |
| W3 | Withdraw with wrong cap | Aborts `E_WRONG_ESCROW_OWNER_CAP`. |
| W4 | Withdraw when pre-call state is `Rented(HandoverOpen)` and tenure has expired — APT fires `do_tenure_expiry` before drain | APT credits `owner_earnings += tenant_stake × 0.90`, routes `tenant_stake × 0.10` as `FeeMessage<C>` to `fee_inbox_id`, state → `AtDutchAuction`. Withdraw returns `Coin == (pre_earnings + stake × 0.90)`; `owner_earnings == 0` after. Events in order: `TenureExpired`, then `EarningsWithdrawn`. Asserts APT materializes earnings that a drain-only implementation would miss. |
| W5 | Withdraw when pre-call state is `Rented(HandoverConfirmed)` and handover has expired — APT fires `do_handover` before drain | APT credits `owner_earnings += used_credit × 0.90`, pushes `remain_credit` to displaced tenant, rotates `pending_bid → tenant_stake`, mints + pushes new `TenantCap`, state → `Rented(HandoverOpen)` with T(n+1) installed. Withdraw returns `Coin == (pre_earnings + used_credit × 0.90)`. Events in order: `HandoverCompleted`, then `EarningsWithdrawn`. Exercises the C1-path credit (distinct from W4's C2-path). |

### 10.10 Read-only queries

| # | Description | Expected |
|---|---|---|
| Q1 | `compute_used_credit` called when state is `Idle` | Aborts `E_NOT_RENTED`. |
| Q2 | `compute_used_credit` called when state is `AtDutchAuction` | Aborts `E_NOT_RENTED`. |
| Q3 | `compute_used_credit` called when state is `Retired` | Aborts `E_NOT_RENTED`. |
| Q4 | `compute_floor_price` called when state is `Idle` | Returns `config.min_rent_price`. |
| Q5 | `compute_floor_price` called when state is `Rented{HandoverOpen}` | Returns `compute_next_rent_price(escrow, balance::value(&escrow.tenant_stake))`. |
| Q6 | `compute_floor_price` called when state is `Rented{HandoverConfirmed}` | Returns `compute_next_rent_price(escrow, balance::value(&escrow.pending_bid))` — the supersede floor, driven by the pending bid. |
| Q7 | `compute_floor_price` called when state is `AtDutchAuction` and `timestamp_ms` within descent window | Returns `compute_price_descent(escrow, timestamp_ms)` — non-abortive, time-dependent. |
| Q8 | `compute_floor_price` called when state is `AtDutchAuction` after `descent_ceiling` elapsed | Returns `config.min_rent_price` (saturation point of the Dutch descent). |
| Q9 | `compute_floor_price` called when state is `Retired` | Aborts `E_RETIRED_NO_BID`. Same abort code that `rent()` raises on the same state — one named condition, one constant. |
| Q10 | `compute_floor_price` value equals the floor actually enforced by `rent()` | For any state in which `rent()` does not abort on state, the value returned by `compute_floor_price(escrow, clock.now())` is exactly the threshold against which `rent()` asserts `coin::value(&payment) >= ...` (modulo the `retire_flag` check in `Rented{HandoverOpen}`, which is a separate precondition). Asserts that the public query and the enforcement path agree. |

**Note on `compute_price_descent` and `compute_next_rent_price`:** these are
`public(package)` helpers (§8.2, §8.3) with no state guard. They are not
reachable from outside the package, so no state-guard test is applicable —
their correctness is covered by the `compute_floor_price` dispatch tests above
and by the `rent()` acquisition tests (R5–R8 for `compute_price_descent`, R9–R15
for `compute_next_rent_price`).

### 10.11 Fee routing

| # | Description | Expected |
|---|---|---|
| F1 | `do_handover` with non-zero `used_credit` | `owner_earnings += 0.90 × used_credit`. One `FeeMessage<C>` posted via `fee_message::post<CoinType>(fee_balance, object::id(escrow), displaced_tenant, escrow.fee_inbox_id, ctx)`, with balance `0.10 × used_credit` and `escrow_id == object::id(escrow)`. `HandoverCompleted` event includes both shares. |
| F2 | `do_handover` at Dutch Auction bypass (used_credit = last_acquisition_price) | `remain_credit == 0`, zero push to displaced tenant. Fee and owner share computed on full `last_acquisition_price`. Fee path as in F1. |
| F3 | `do_tenure_expiry` | `owner_earnings += 0.90 × stake`. One `FeeMessage<C>` of `0.10 × stake` constructed + sent as in F1. |
| F4 | Fee on tiny `used_credit` (`split_fee` floors fee to zero) | `if protocol_fee > 0` guard short-circuits: no split, no `fee_message::post` call, no `FeeMessage<C>` constructed. `owner_share == used_credit`. |

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
| M3 | AtDutchAuction | `now ≥ phase_start + descent_ceiling` | C3 | Idle | Idle | `AuctionExpired` then `RentStarted(from_state: Idle)`. `last_acquisition_price` is overwritten by payment inside `install_new_tenant` (do_auction_expiry preserves the stale value per §7.3). |
| M4 | Rented(HandoverOpen), no retire_flag | tenure not expired | none | HandoverOpen | HandoverOpen | Cross-ref R9, R10, R12 (success paths). The subtraction `phase_start + tenure_ceiling - now` is u64-safe exactly because C2 did not fire. |
| M5 | Rented(HandoverOpen) | tenure expired, no retire_flag | C2 | AtDutchAuction | AtDutchAuction | `TenureExpired(AtDutchAuction)` then `RentStarted(from_state: AtDutchAuction)`. `owner_earnings += stake × 0.90`; one `FeeMessage<C>` created and transferred to `fee_inbox_id`. |
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

### 10.14 Unit rows on pure helpers

Direct tests via the `#[test_only]` shims in §10.0. These isolate behavior
that is semantically important — flooring rounding, boundary arithmetic —
but whose specific numeric cases are hard to reach through the state
machine without fragile multi-step scenarios.

#### 10.14.1 `split_fee`

`split_fee` is pure (§7.4). Parametric `#[test]` over a `vector<Case>`:

| # | `amount` | Expected `(owner, fee)` | Property anchored |
|---|---|---|---|
| U1 | `0` | `(0, 0)` | P12 zero-path identity |
| U2 | `1` | `(1, 0)` | Fee flooring — `mul_div(1, 1000, 10000) = 0` |
| U3 | `9` | `(9, 0)` | Still below threshold |
| U4 | `10` | `(9, 1)` | Smallest non-zero fee (`mul_div(10, 1000, 10000) = 1`) |
| U5 | `100` | `(90, 10)` | Round numbers — 90/10 exact |
| U6 | `1_000` | `(900, 100)` | Canonical scale |
| U7 | `999` | `(900, 99)` | Flooring favors owner by 1 base unit at the fractional boundary |
| U8 | `u64::MAX / 10` | `((u64::MAX / 10) - fee, fee)` with `fee = mul_div(u64::MAX / 10, 1000, 10000)` | Upper bound — no overflow under `math::mul_div` (intermediate product uses u128) |
| U9 | `u64::MAX` | `(u64::MAX - fee, fee)` | Overflow-free at the u64 ceiling; asserts the helper is total |

Assertion: for every row, `owner + fee == amount` (P1 fund conservation).

#### 10.14.2 `tenure_expiry_ms` / `descent_expiry_ms`

Boundary-helper wrappers (§8.5). Each is a two-field addition — the rows
verify that the addition targets the correct `IntegrationConfig` field
(regression guard against a future edit that accidentally swaps
`tenure_ceiling` and `descent_ceiling`):

| # | Fixture | Expected |
|---|---|---|
| U10 | `phase_start_ms = 0`, `tenure_ceiling = 1_000`, `descent_ceiling = 500` | `tenure_expiry_ms == 1_000`; `descent_expiry_ms == 500` |
| U11 | `phase_start_ms = 1_000_000`, same ceilings | `tenure_expiry_ms == 1_001_000`; `descent_expiry_ms == 1_000_500` |
| U12 | Swap-check: build two escrows, one with `tenure_ceiling=A, descent_ceiling=B`, the other with `tenure_ceiling=B, descent_ceiling=A` (both `phase_start_ms = 0`) | Each helper returns the expected field — confirms the helpers do not read the wrong `config::*_ceiling` getter |

#### 10.14.3 `compute_used_credit` boundary guards

Rows extending §10.10 (which only covered dispatch on state). These pin
the in-function clamps and underflow guards (§8.1 steps 2–3):

| # | Scenario | Expected |
|---|---|---|
| Q11 | `Rented{HandoverConfirmed}`, `timestamp_ms > handover_countdown_expiry` | Returns the value at exactly `handover_countdown_expiry` — not `timestamp_ms`; the post-handover-boundary clamp is observable (step 2) |
| Q12 | `Rented{HandoverConfirmed}`, `timestamp_ms == handover_countdown_expiry` | Same value as Q11 — clamp at equality is the fixed point |
| Q13 | `Rented{HandoverOpen}`, `timestamp_ms < phase_start_ms` | Returns `0` — the pre-phase guard (step 3) fires before `evaluate_curve` is called |
| Q14 | `Rented{HandoverOpen}`, `timestamp_ms == phase_start_ms` | Returns `0` — `elapsed == 0`, curve returns 0, scaled result is 0 |
| Q15 | `Rented{HandoverOpen}`, `timestamp_ms == phase_start_ms + tenure_ceiling` | Saturates to `tenant_stake` — curve returns `SCALE`, `mul_div(stake, SCALE, SCALE) == stake` |
| Q16 | `Rented{HandoverOpen}`, `timestamp_ms >> phase_start_ms + tenure_ceiling` (way past saturation) | Still saturates to `tenant_stake` — `evaluate_curve` clamps on its own |

#### 10.14.4 `compute_price_descent` pre-phase guard

Similar refinement for §8.2 step 1:

| # | Scenario | Expected |
|---|---|---|
| Q17 | `AtDutchAuction`, `timestamp_ms < phase_start_ms` | Returns `last_acquisition_price` — the "auction has not started yet" guard (step 1), not `min_rent_price` |
| Q18 | `AtDutchAuction`, `timestamp_ms == phase_start_ms` | `elapsed == 0`, `h == 0`, result `== last_acquisition_price` |
| Q19 | `AtDutchAuction`, `timestamp_ms == phase_start_ms + descent_ceiling` | Curve saturates to `SCALE`, `consumed == spread`, result `== min_rent_price` — exact arithmetic even at the boundary |

### 10.15 Property → row mapping

| Prop | Anchored rows |
|------|---|
| P1 Fund conservation at every boundary | A7, A8, F1–F4, L1; U1–U9 (exact split invariant) |
| P2 No trapped balances at terminal state | C9, C10, C11, L1 |
| P3 Push-before-rotate | A2, A7, R13, W5 |
| P4 At most three lazy transitions per call | A5, M11 |
| P5 Check order is a safety invariant | A5, A6, M6, M10, M11 (C1 → C2 → C3 ordering observed) |
| P6 Retire flag is monotonic | C4, C5, C6, C10, C11, L2, M7, M12, M13 |
| P7 OwnerCap uniqueness | T1 (mint), C9 (burn); unmintability of a second cap is visibility-enforced and compile-time |
| P8 TenantCap staleness is inert | B3, B9, B10 |
| P9 Tenancy ↔ Rented state | R1 (set together), A3/A6 (cleared together in tenure expiry) |
| P10 Pending bid ↔ HandoverConfirmed | R9, R13, A2 (cleared by do_handover) |
| P11 Asset present while escrow exists | B1–B2, B7 (hot potato enforces), B8 (double-borrow abort) |
| P12 Fee routing is idempotent at zero | F4, A7, U1–U3 |

### 10.16 Open questions

- **`demo_config` drift.** The test fixture is shared across dozens of rows.
  A parameter addition to `IntegrationConfig` will break the helper
  signature in one place, which is desirable; but a parameter *default*
  change (e.g., changing the default curve) would silently shift many
  success rows. Rule: numeric defaults inside `demo_config` are pinned in
  the helper body as named constants — `DEMO_TENURE_MS = 1_000_000`,
  etc. — so a default change is visible in the diff.
- **Clock primitive choice.** `clock::set_for_testing` sets absolute ms;
  `clock::increment_for_testing` moves it forward. Rows that test pre-
  phase guards (Q13, Q17) need absolute-set semantics because the
  "before" timestamp may be earlier than any value the test has ever
  written; prefer the absolute setter uniformly.
- **Level-2 integration rows (T2, L3).** `Asset = rental_escrow::OwnerCap`
  is a structural test that exercises the generic bound but not the
  state machine of the inner escrow in a single row. A full L3 run is
  ~40 lines; marked as a single integration-style test (not parametric).
- **Abort-row split-tx spurious pass.** Documented in §10.0; every tx1 in
  a §10.13 abort row asserts at least one concrete postcondition before
  `next_tx` so a silently-failing tx1 cannot mask the regression behind
  the tx2 abort catcher.
- **`KEEPER`-driven APT rows.** Several rows require `KEEPER ≠ TENANT_A`
  to assert that `do_handover` reads `pending_tenant_address`, not
  `tx_context::sender`. A subtle regression that replaced
  `pending_tenant_address` with `tx_context::sender` in the `TenantCap`
  mint path would pass a test where `KEEPER == TENANT_B`. Rule: KEEPER
  is always disjoint from every tenant / bidder alias in setup.
- **Private helpers without shims.** `do_handover`, `do_tenure_expiry`,
  `do_auction_expiry`, `install_new_tenant`, `settle_stake_earnings`,
  `register_pending_bid` are covered only via public API. A future audit
  that wants to pin a specific helper invariant (e.g., `settle_stake_earnings`
  postcondition `tenant_stake == 0`) may need to add a shim; doing so
  is explicitly permitted but requires the helper's full precondition
  list to be re-stated in the `_for_testing` doc comment.


11. MODULE BOUNDARY
--------------------

`rental_escrow.move` exports:

| Symbol | Visibility | Notes |
|---|---|---|
| `E_NOT_RENTED` | `public` | compute_used_credit: state != Rented. |
| `E_INSUFFICIENT_PAYMENT` | `public` | rent — payment below floor price (all acquisition paths). |
| `E_RETIRE_FLAG_BLOCKS_BID` | `public` | rent (takeover, flagged). |
| `E_RETIRED_NO_BID` | `public` | rent / compute_floor_price: state is Retired (asset not rentable). |
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
| `compute_floor_price(...)` | `public` | Read-only. Dispatches by state — returns min_rent_price (Idle), compute_next_rent_price (Rented), compute_price_descent (AtDutchAuction). Aborts `E_RETIRED_NO_BID` on Retired. |
| `compute_price_descent(...)` | `public(package)` | Read-only helper backing `compute_floor_price` (AtDutchAuction arm). No state guard — structurally guaranteed by caller. |
| `compute_next_rent_price(...)` | `public(package)` | Read-only helper backing `compute_floor_price` (Rented arms). Takes explicit `price: u64`. No state guard — structurally guaranteed by caller. |
| `tenure_expiry_ms(...)` | `public(package)` | §8.5 — `phase_start_ms + tenure_ceiling`. Used by `rent()` HandoverOpen and `apply_pending_transitions` Check 2. |
| `descent_expiry_ms(...)` | `public(package)` | §8.5 — `phase_start_ms + descent_ceiling`. Used by `apply_pending_transitions` Check 3. |
| `do_handover(...)` | private | §7.1 |
| `do_tenure_expiry(...)` | private | §7.2 |
| `do_auction_expiry(...)` | private | §7.3 |
| `split_fee(...)` | private | §7.4 |
| `install_new_tenant(...)` | private | §7.5 — shared install path for `rent()` Idle / AtDutchAuction arms. |
| `settle_stake_earnings(...)` | private | §7.6 — shared stake-settlement tail for `do_handover` and `do_tenure_expiry`. |
| `register_pending_bid(...)` | private | §7.7 — shared pending-bid installation tail for `rent()` Rented arms. |

**Depends on:**
- `math` — `mul_div` via `split_fee`, `compute_used_credit`, and `compute_price_descent`.
- `curve_shape` — `CurveShape`, `evaluate_curve`.
- `price_function` — `PriceFunction`, `evaluate_price_fn`.
- `config` — `IntegrationConfig` and `public(package)` getters.
- `owner_cap` — `OwnerCap`, `new`, `burn`, `escrow_id`.
- `tenant_cap` — `TenantCap`, `new`, `escrow_id`.
- `payment_ticket` — `PaymentTicket`, `new`.
- `protocol_fee_inbox` — `ProtocolFeeRef`, `inbox_id`.
- `fee_message` — `post`.

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
