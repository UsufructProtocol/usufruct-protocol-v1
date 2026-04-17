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
  AtDutchAuction | Retired`. Copy/drop/store. Returned by `current_state` and
  `apply_pending_transitions`. External callers may pattern-match.
- `RentPhase` — public enum: `HandoverOpen | HandoverConfirmed`. Carried
  inside `Rented`.
- `AssetReceipt` — hot potato struct with no abilities. Created by
  `borrow_asset`, consumed by `return_asset` in the same PTB.
- All public entry points: `integrate`, `rent`, `retire`, `claim_asset`,
  `withdraw_earnings`, `borrow_asset`, `return_asset`,
  `apply_pending_transitions`.
- Read-only queries: `current_state`, `current_used_credit`,
  `current_price_descent`, `current_next_rent_price`.
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
  only calls `send_fee` at boundary events.
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
- **Asset always present while escrow exists.** `asset: Asset` is a direct
  field — not `Option`. The only window in which the asset is not inside the
  escrow is a single PTB borrow (`borrow_asset` → `return_asset`), which is
  enforced structurally by the hot-potato `AssetReceipt`.
- **Capability-based authorization.** `retire`, `claim_asset`, and
  `withdraw_earnings` take `&OwnerCap` and forward to
  `owner_cap::assert_escrow`. `borrow_asset` takes `&TenantCap` and checks
  `object::id(cap) == current_tenant_cap_id` (staleness check). No address
  check is performed anywhere.


1. ERROR CONSTANTS
------------------

All constants are `public` so the SDK can map abort codes to human-readable
messages.

    public const E_OWNER_CAP_MISMATCH:       u64 = 0;  // forwarded from owner_cap::assert_escrow
    public const E_TENANT_CAP_WRONG_ESCROW:  u64 = 1;  // cap.escrow_id != object::id(escrow)
    public const E_TENANT_CAP_STALE:         u64 = 2;  // object::id(cap) != current_tenant_cap_id
    public const E_NOT_IDLE:                 u64 = 3;  // rent() Idle-path: state is not Idle
    public const E_NOT_AUCTION:              u64 = 4;  // (reserved — dispatch abort guard)
    public const E_NOT_RENTED:               u64 = 5;  // (reserved — dispatch abort guard)
    public const E_INSUFFICIENT_PAYMENT:     u64 = 6;  // payment < floor price (all acquisition paths)
    public const E_RETIRE_FLAG_BLOCKS_BID:   u64 = 7;  // rent() during Rented(HandoverOpen) with retire_flag
    public const E_RETIRED_NO_BID:           u64 = 8;  // rent() called when state is Retired
    public const E_ALREADY_RETIRED:          u64 = 9;  // retire() when retire_flag already set
    public const E_NOT_RETIRED:              u64 = 10; // claim_asset() when state != Retired
    public const E_RECEIPT_ESCROW_MISMATCH:  u64 = 11; // return_asset: receipt.escrow_id != object::id(escrow)
    public const E_RECEIPT_ASSET_MISMATCH:   u64 = 12; // return_asset: receipt.asset_id != object::id(&asset)
    public const E_NO_EARNINGS:              u64 = 13; // withdraw_earnings: owner_earnings == 0 after settlement


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
`apply_pending_transitions` and `current_state`. Embedded inside
`RentalEscrow`.

**Semantics:**

| Variant | Meaning |
|---|---|
| `Idle` | No tenant. Asset available at `min_rent_price`. Entry: `rent()`. |
| `Rented { HandoverOpen }` | Current tenant holds exclusive access. No pending bid. |
| `Rented { HandoverConfirmed }` | Current tenant holds access until `handover_countdown_expiry`. A pending tenant has paid `>= next_rent_price`. |
| `AtDutchAuction` | Price descends from `last_rent_price` toward `min_rent_price` via `compute_price_descent`. |
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
    asset:                      Asset,
    config:                     IntegrationConfig,
    fee_inbox_id:               ID,
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

**Asset field — why not `Option<Asset>`:** the escrow and the asset are
conceptually identical — the escrow exists iff the asset is inside it.
`claim_asset` destructures the escrow and returns the asset in the same
transaction. The borrow mechanism (`borrow_asset` / `return_asset`) uses
`Asset` by value + hot-potato receipt, so the asset leaves and returns within
a single PTB without ever persisting in an "escrow exists but is empty"
state. Using a plain `Asset` field rather than `Option<Asset>` makes this
structural invariant explicit.

**Field semantics:**

| Field | Meaning |
|---|---|
| `asset` | The integrated asset. `key + store` required. |
| `config` | Immutable `IntegrationConfig` — all protocol parameters. |
| `fee_inbox_id` | ID of `ProtocolFeeInbox`. Stored at integrate from `&ProtocolFeeRef`. Target of `send_fee` transfers. |
| `state` | Current `AssetState`. |
| `last_rent_price` | Price paid by the most recent tenant. Entry barrier for takeover and starting price of the Dutch Auction descent. Initialized to `min_rent_price` at `integrate` — the price the first Idle acquisition will write anyway. Updated at every acquisition: `min_rent_price` from Idle, `next_rent_price` from Rented, and the actual amount paid from AtDutchAuction. |
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
    integrator:       address,  // tx_context::sender(ctx)
}

public struct RentStarted has copy, drop {
    escrow_id:        ID,
    tenant:           address,
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
    new_tenant:        address,
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


4. LIFECYCLE FUNCTIONS
-----------------------

### 4.1 `integrate`

    public fun integrate<Asset: key + store, CoinType>(
        asset:    Asset,
        config:   IntegrationConfig,
        fee_ref:  &ProtocolFeeRef,
        ctx:      &mut TxContext,
    ): OwnerCap

**Visibility:** `public` — entry point for any integrator.

**Purpose:** wraps `asset` in a new `RentalEscrow<Asset, CoinType>`, shares
the escrow, mints one `OwnerCap`, and returns it to the PTB.

**Behavior:**
1. Allocate `uid = object::new(ctx)`. Compute `escrow_id = object::uid_to_inner(&uid)`.
2. Mint `OwnerCap` via `owner_cap::new(escrow_id, ctx)`.
3. Read `fee_inbox_id = protocol_fee_inbox::fee_ref_inbox_id(fee_ref)`.
4. Construct the escrow with:
   - `state = AssetState::Idle`
   - `last_rent_price = config::min_rent_price(&config)`
   - `phase_start_ms = 0`
   - All `Option` fields `None`, all `Balance` fields `balance::zero()`
   - `retire_flag = false`
5. `transfer::share_object(escrow)`.
6. Emit `AssetIntegrated { escrow_id, owner_cap_id, integrator }`.
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
4. Set `escrow.retire_flag = true`.
5. If `escrow.state` is `Idle` or `AtDutchAuction` (no active tenant, no
   pending bid), transition immediately:
   - `AtDutchAuction` → set `state = Retired`. Emit `AuctionExpired { next_state: Retired, ... }`
     with `timestamp_ms = clock.timestamp_ms()` (not the would-be auction expiry —
     retire cuts it short).
   - `Idle` → set `state = Retired`. No auxiliary event (the state was
     already "empty"; `RetireFlagSet` covers it).
6. Emit `RetireFlagSet { escrow_id, state_at_set: escrow.state }`.

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
            id, asset, config: _, fee_inbox_id: _,
            state: _, last_rent_price: _, phase_start_ms: _,
            current_tenant_cap_id: _, current_tenant_address: _,
            pending_tenant_address: _, handover_countdown_expiry: _,
            tenant_stake, pending_bid, owner_earnings,
            retire_flag: _,
        } = escrow;

6. Both `tenant_stake` and `pending_bid` must be zero at this point — the
   only path to `Retired` drains them via `do_tenure_expiry` (stake) and,
   for any unresolved pending bid, via a preceding `do_handover`. Destroy
   them: `balance::destroy_zero(tenant_stake); balance::destroy_zero(pending_bid);`.
   An abort here indicates a state-machine bug; the destroy-zero call aborts
   on non-zero, which serves as a structural assertion.
7. `let earnings = coin::from_balance(owner_earnings, ctx);`
8. `owner_cap::burn(owner_cap);`
9. `object::delete(id);`
10. Emit `AssetClaimed { escrow_id, owner_cap_id, swept_earnings }`.
11. Return `(asset, earnings)`.

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
6. Emit `EarningsWithdrawn { escrow_id, amount }`.
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
- `escrow.last_rent_price = coin::value(&payment);`
- `balance::join(&mut escrow.tenant_stake, coin::into_balance(payment));`
- `escrow.phase_start_ms = clock.timestamp_ms();`
- Mint `cap = tenant_cap::new(object::id(escrow), ctx)`.
- `escrow.current_tenant_cap_id = some(object::id(&cap));`
- `escrow.current_tenant_address = some(tx_context::sender(ctx));`
- `escrow.state = Rented { phase: HandoverOpen };`
- `transfer::transfer(cap, tx_context::sender(ctx));`
- Emit `RentStarted { escrow_id, tenant: sender, tenant_cap_id, price_paid,
  from_state: Idle }`.

#### Case: `AtDutchAuction`

- Let `price = current_price_descent(escrow, clock.timestamp_ms())`.
- Assert `coin::value(&payment) >= price`, abort `E_INSUFFICIENT_PAYMENT`.
- `escrow.last_rent_price = coin::value(&payment);`
- `balance::join(&mut escrow.tenant_stake, coin::into_balance(payment));`
- `escrow.phase_start_ms = clock.timestamp_ms();`
- Mint `cap = tenant_cap::new(object::id(escrow), ctx)`.
- `escrow.current_tenant_cap_id = some(object::id(&cap));`
- `escrow.current_tenant_address = some(tx_context::sender(ctx));`
- `escrow.state = Rented { phase: HandoverOpen };`
- `transfer::transfer(cap, tx_context::sender(ctx));`
- Emit `RentStarted { ..., from_state: AtDutchAuction, ... }`.

#### Case: `Rented { HandoverOpen }`

- Assert `!escrow.retire_flag`, abort `E_RETIRE_FLAG_BLOCKS_BID`.
- Let `floor = current_next_rent_price(escrow)` (delegates to
  `price_function::compute_next_rent_price`).
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
- Let `floor = current_next_rent_price(escrow)` — `last_rent_price` holds
  the previous bidder's payment, so the floor escalates with each supersede.
- Assert `coin::value(&payment) >= floor`, abort `E_INSUFFICIENT_PAYMENT`.
- **Refund previous pending bid** (push before rotate):
  - Take the previous balance: `let prev = balance::withdraw_all(&mut escrow.pending_bid);`
  - `let refund_amount = balance::value(&prev);`
  - `transfer::public_transfer(coin::from_balance(prev, ctx),
    option::destroy_some(escrow.pending_tenant_address));`
  - Emit `BidSuperseded { escrow_id, displaced_bidder, refunded_amount,
    new_bidder, new_bid_amount }`.
- `escrow.last_rent_price = coin::value(&payment);`
- `balance::join(&mut escrow.pending_bid, coin::into_balance(payment));`
- `escrow.pending_tenant_address = some(tx_context::sender(ctx));`
- `handover_countdown_expiry` is **not** updated — subsequent bids do not
  reset the countdown (design-compact §4).
- `state` remains `Rented { HandoverConfirmed }`.

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
        do_auction_expiry(escrow, expiry, ctx)
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
- **Check 1 always precedes Check 2 when `pending_bid` is non-zero.**
  `rent()` clamps `handover_countdown_expiry = min(now + handover_floor,
  phase_start_ms + tenure_ceiling)`, so the handover boundary is ≤ tenure
  boundary. Check 2 never observes `Rented(HandoverConfirmed)` with an
  orphaned `pending_bid`.

**Emits one event per boundary fired** (`HandoverCompleted`,
`TenureExpired`, `AuctionExpired`) at the boundary's exact timestamp —
not `clock.now()`. When the boundary fires in the same call as a rent/retire,
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
4. Extract `asset` from the escrow. (In Move: a `mem::replace`-style
   swap, or direct field move — the asset is moved out and the field is
   statically unreachable until `return_asset` runs. See "Asset field
   mechanism" below.)
5. Construct `receipt = AssetReceipt { escrow_id: object::id(escrow),
   asset_id: object::id(&asset) }`.
6. Return `(asset, receipt)`.

**Asset field mechanism:** the `asset: Asset` field is a direct (non-Option)
field. To move it out temporarily, the implementation uses a private
`Option<Asset>` wrapper internally — exposed as a structurally-invariant
`Asset` to external readers. The wrapper is `Some` at every persistent
state; the `None` window exists only between `borrow_asset` and
`return_asset` inside a single PTB, never across transaction boundaries.

*(Alternative: Sui dynamic fields. Either works; the spec fixes the
observable invariant — asset present iff escrow exists persistently — and
leaves the concrete field encoding to the implementation.)*

**No event emitted.** Borrow is a PTB-internal event with no observable
state change across transactions; the receipt is consumed in the same PTB.

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
4. Insert `asset` back into the escrow's asset slot.
5. Does **not** call `apply_pending_transitions` — returning an asset never
   needs to resolve boundary events; no balance is touched, no state field
   changes.

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

1. Let `used_credit = current_used_credit(escrow, boundary_ms)`.
   (`boundary_ms == handover_countdown_expiry`, so the clamp is a no-op;
   the call reads `balance::value(&escrow.tenant_stake)` as the principal —
   see §8.2.)
2. Let `remain_credit = balance::value(&escrow.tenant_stake) - used_credit`.
   (Invariant `used_credit + remain_credit == tenant_stake` from curve
   bijectivity.)
3. Compute `(owner_share, protocol_fee) = split_fee(used_credit)` — §7.4.
4. **Take funds before any address rotation** (push-before-rotate invariant):
   - `if remain_credit > 0`:
     - `let remain_balance = balance::split(&mut escrow.tenant_stake, remain_credit);`
     - `transfer::public_transfer(coin::from_balance(remain_balance, ctx),
       *option::borrow(&escrow.current_tenant_address));`
     // When countdown == remaining_rent_time the curve saturates:
     // used_credit == tenant_stake and remain_credit == 0. Skipping the split
     // avoids creating a zero Balance that Move requires to be consumed.
     // Consequence of `countdown = min(escrow.config.handover_floor, remaining)`.
   - `let fee_balance = balance::split(&mut escrow.tenant_stake, protocol_fee);`
   - `fee_message::send_fee<CoinType>(fee_balance, escrow.fee_inbox_id, ctx);`
   - Remaining `escrow.tenant_stake` = `owner_share` exactly. Move it into
     `owner_earnings` via `balance::join(&mut escrow.owner_earnings,
     balance::withdraw_all(&mut escrow.tenant_stake))`.
5. **Rotate `pending_bid` → `tenant_stake`** (new tenant's stake):
   - `balance::join(&mut escrow.tenant_stake,
     balance::withdraw_all(&mut escrow.pending_bid));`
   — `last_rent_price` already holds the pending bid amount (set at bid time).
6. **Mint + push new TenantCap:**
   - `let cap = tenant_cap::new(object::id(escrow), ctx);`
   - `let new_cap_id = object::id(&cap);`
   - `let pending_addr = *option::borrow(&escrow.pending_tenant_address);`
   - `transfer::transfer(cap, pending_addr);`
7. **Rotate address fields:**
   - `escrow.current_tenant_address = some(pending_addr);`
   - `escrow.current_tenant_cap_id = some(new_cap_id);`
   - `escrow.pending_tenant_address = none();`
8. **Reset phase anchors for the new tenant:**
   - `escrow.phase_start_ms = boundary_ms;`
   - `escrow.handover_countdown_expiry = none();`
   - `escrow.state = Rented { phase: HandoverOpen };`
9. Emit `HandoverCompleted { escrow_id, displaced_tenant, new_tenant,
   new_tenant_cap_id, used_credit, owner_share, protocol_fee, remain_credit,
   timestamp_ms: boundary_ms }`.

---

### 7.2 `do_tenure_expiry`

    fun do_tenure_expiry<Asset: key + store, CoinType>(
        escrow:      &mut RentalEscrow<Asset, CoinType>,
        boundary_ms: u64,       // = phase_start_ms + tenure_ceiling
        ctx:         &mut TxContext,
    )

**Preconditions:** `escrow.state` matches `Rented { HandoverOpen }` —
`apply_pending_transitions` Check 1 has already resolved any
`HandoverConfirmed` + `pending_bid`. Tenure expiry while in
`HandoverConfirmed` would mean `pending_bid` still exists, which is the
bug prevented by the clamp in `rent()`.

**Algorithm:**

1. Let `stake_total = balance::value(&escrow.tenant_stake)` — equal to
   `escrow.last_rent_price` (used_credit saturated to full).
2. Compute `(owner_share, fee_share) = split_fee(stake_total)`.
3. Take `fee_balance = balance::split(&mut escrow.tenant_stake, fee_share)`.
   Call `fee_message::send_fee<CoinType>(fee_balance, escrow.fee_inbox_id, ctx)`.
4. Move remaining stake into earnings:
   `balance::join(&mut escrow.owner_earnings,
    balance::withdraw_all(&mut escrow.tenant_stake));`
5. **Clear tenant fields** (no new tenant to register):
   - `escrow.current_tenant_cap_id = none();`
   - `escrow.current_tenant_address = none();`
6. **Determine next state:**
   - If `escrow.retire_flag`: `escrow.state = Retired`.
     `escrow.phase_start_ms = boundary_ms;` (bookkeeping; no subsequent
     boundaries will fire).
   - Else: `escrow.state = AtDutchAuction;
     escrow.phase_start_ms = boundary_ms;`.
     `last_rent_price` is preserved — it is the starting price of the descent.
7. Emit `TenureExpired { escrow_id, tenant, owner_share, protocol_fee,
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
        ctx:         &mut TxContext,
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
overwrites it with `min_rent_price` — the price paid from Idle — as part of
its normal acquisition logic.

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
- `split_fee(1) == (1, 0)` — fee floors to zero on tiny amounts. `send_fee`
  short-circuits zero.


8. READ-ONLY QUERIES
---------------------

All read-only functions are `public`. They do not mutate the escrow and are
callable via `devInspectTransactionBlock` for free, and from within PTBs
without consensus cost when the escrow is already referenced.

### 8.1 `current_state`

    public fun current_state<Asset: key + store, CoinType>(
        escrow: &RentalEscrow<Asset, CoinType>,
        clock:  &Clock,
    ): AssetState

Computes the settled state without mutating. Used by frontends and
indexers to read "what state would `apply_pending_transitions` produce if
called now?"

**Algorithm:** replicates the three sequential checks of
`apply_pending_transitions` but reads-only — it computes the would-be
state without writing. Does not fire events. Does not touch balances.

### 8.2 `current_used_credit`

    public fun current_used_credit<Asset: key + store, CoinType>(
        escrow:       &RentalEscrow<Asset, CoinType>,
        timestamp_ms: u64,
    ): u64

Delegates to `curve_shape::compute_used_credit`, passing
`balance::value(&escrow.tenant_stake)` as the principal. Using
`tenant_stake` rather than `last_rent_price` is correct in both sub-states:
in `HandoverOpen` the two are equal; in `HandoverConfirmed` `last_rent_price`
already holds the pending bid, so `tenant_stake` is the only accurate source
for the current tenant's payment.

**Clamping rule:** if `escrow.state` is `Rented { HandoverConfirmed }` and
`timestamp_ms > handover_countdown_expiry`, the function clamps
`timestamp_ms` to `handover_countdown_expiry`. Past the boundary, the
displayed used_credit would otherwise exceed the amount actually consumed
by the current tenant — misleading at the UI layer.

### 8.3 `current_price_descent`

    public fun current_price_descent<Asset: key + store, CoinType>(
        escrow:       &RentalEscrow<Asset, CoinType>,
        timestamp_ms: u64,
    ): u64

Delegates to `curve_shape::compute_price_descent`. Only meaningful when
`current_state(escrow) == AtDutchAuction`. Returns `min_rent_price` once
the descent is saturated.

### 8.4 `current_next_rent_price`

    public fun current_next_rent_price<Asset: key + store, CoinType>(
        escrow: &RentalEscrow<Asset, CoinType>,
    ): u64

Delegates to `price_function::compute_next_rent_price(
&escrow.config.price_function, escrow.last_rent_price)`. Only meaningful
when the state is `Rented`.


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
`owner_cap::new` / `owner_cap::burn` (both `public(package)` with a single
call site each).

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
Across transaction boundaries, `escrow.asset` is always present.
The borrow-return window is confined to a single PTB by the hot-potato
`AssetReceipt`.

**P12 — Fee routing is idempotent at zero:**
`do_handover` with `used_credit == 0` (e.g. handover at t = phase_start_ms,
pathological edge case) and `do_tenure_expiry` with zero stake produce
zero fee, which `send_fee` short-circuits without creating a `FeeMessage`.

10. TEST CASES
--------------

### 10.1 Integration

| # | Description | Expected |
|---|---|---|
| T1 | `integrate<SomeAsset, C>` with a valid config and fee_ref | Returns `OwnerCap`. `RentalEscrow` shared. `state == Idle`. `last_rent_price == config.min_rent_price`. `phase_start_ms == 0`. `fee_inbox_id == object::id(&protocol_fee_inbox)`. `AssetIntegrated` event emitted. |
| T2 | `integrate<OwnerCap, C>` (deposit an existing escrow's cap) | Succeeds. Returns a second `OwnerCap` for the wrapping escrow. The wrapped cap becomes the wrapping escrow's `asset`. No depth check. |

### 10.2 `rent` — Idle path

| # | Description | Expected |
|---|---|---|
| R1 | Pay exactly `min_rent_price` | State → `Rented(HandoverOpen)`. `last_rent_price == min_rent_price`. `TenantCap` pushed to sender. `RentStarted` event. |
| R2 | Pay less than `min_rent_price` | Aborts `E_INSUFFICIENT_PAYMENT`. |
| R3 | Overpay from Idle | Accepted. `last_rent_price == full payment`. State → `Rented(HandoverOpen)`. |
| R4 | Rent when `retire_flag` set and state was Idle | State has already been moved to `Retired` by `apply_pending_transitions`; dispatch hits the `Retired` arm → aborts `E_RETIRED_NO_BID`. |

### 10.3 `rent` — AtDutchAuction path

| # | Description | Expected |
|---|---|---|
| R5 | Pay exactly `current_price_descent(now)` | State → `Rented(HandoverOpen)`. `last_rent_price == payment`. `RentStarted{ from_state: AtDutchAuction }`. |
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

### 10.8 `retire` / `claim_asset`

| # | Description | Expected |
|---|---|---|
| C1 | `retire` from Idle | `retire_flag = true`. `state → Retired`. `RetireFlagSet`. |
| C2 | `retire` from AtDutchAuction | `retire_flag = true`. `state → Retired`. `AuctionExpired(next_state: Retired)` + `RetireFlagSet`. |
| C3 | `retire` from Rented(HandoverOpen) | `retire_flag = true`. `state` unchanged. Subsequent `rent()` aborts `E_RETIRE_FLAG_BLOCKS_BID`. |
| C4 | `retire` from Rented(HandoverConfirmed) | `retire_flag = true`. `state` unchanged. Handover completes normally; new tenant enters HandoverOpen with flag set. |
| C5 | Second `retire` call | Aborts `E_ALREADY_RETIRED`. |
| C6 | `claim_asset` when `state != Retired` | Aborts `E_NOT_RETIRED`. |
| C7 | `claim_asset` with non-matching `OwnerCap` | Aborts `E_OWNER_CAP_MISMATCH`. |
| C8 | `claim_asset` on Retired with accumulated earnings | Returns `(asset, coin == owner_earnings)`. OwnerCap burned. Escrow deleted. `AssetClaimed` event. |
| C9 | Full retire-then-claim flow from Rented | `retire` → wait for tenure expiry → `apply_pending_transitions` moves to Retired → `claim_asset` succeeds. |

### 10.9 `withdraw_earnings`

| # | Description | Expected |
|---|---|---|
| W1 | Withdraw with zero earnings | Aborts `E_NO_EARNINGS`. |
| W2 | Withdraw with positive earnings | Returns Coin of exact balance. `owner_earnings == 0` after. `EarningsWithdrawn` event. |
| W3 | Withdraw with wrong cap | Aborts `E_OWNER_CAP_MISMATCH`. |

### 10.10 Fee routing

| # | Description | Expected |
|---|---|---|
| F1 | `do_handover` with non-zero `used_credit` | `owner_earnings += 0.95 × used_credit`. One `FeeMessage<C>` transferred to `fee_inbox_id` with balance `0.05 × used_credit`. `HandoverCompleted` event includes both. |
| F2 | `do_handover` at Dutch Auction bypass (used_credit = last_rent_price) | `remain_credit == 0`, zero push to displaced tenant. Fee and owner share computed on full `last_rent_price`. |
| F3 | `do_tenure_expiry` | `owner_earnings += 0.95 × stake`. One `FeeMessage<C>` of `0.05 × stake`. |
| F4 | Fee on tiny `used_credit` (fee floors to zero) | `send_fee` destroys zero balance. No `FeeMessage` created. `owner_share == used_credit`. |

### 10.11 Full lifecycle

| # | Description | Expected |
|---|---|---|
| L1 | integrate → rent (Idle) → borrow → return → (time passes) → tenure expiry → auction expiry → rent (Idle) → retire → claim | All transitions fire correctly. Owner receives asset + earnings. Protocol fees accumulated in `ProtocolFeeInbox`. No orphaned balances. |
| L2 | integrate → rent → takeover bid → handover → (new tenant active) → retire → tenure expiry → claim | `retire_flag` inherited by new tenant. Claim succeeds after their tenure ends. |
| L3 | integrate an inner escrow → deposit its `OwnerCap` via `integrate` into an outer escrow → outer tenant borrows the cap and calls `retire` on the inner escrow | Inner escrow enters the retire flow. Outer escrow unaffected (its asset is the cap, which is now "pointing at a retiring escrow"). |


11. MODULE BOUNDARY
--------------------

`rental_escrow.move` exports:

| Symbol | Visibility | Notes |
|---|---|---|
| `E_OWNER_CAP_MISMATCH` | `public` | SDK error handling. Forwarded from `owner_cap`. |
| `E_TENANT_CAP_WRONG_ESCROW` | `public` | borrow_asset. |
| `E_TENANT_CAP_STALE` | `public` | borrow_asset. |
| `E_NOT_IDLE` | `public` | (reserved) |
| `E_NOT_AUCTION` | `public` | (reserved) |
| `E_NOT_RENTED` | `public` | (reserved) |
| `E_INSUFFICIENT_PAYMENT` | `public` | rent — payment below floor price (all acquisition paths). |
| `E_RETIRE_FLAG_BLOCKS_BID` | `public` | rent (takeover, flagged). |
| `E_RETIRED_NO_BID` | `public` | rent (Retired). |
| `E_ALREADY_RETIRED` | `public` | retire. |
| `E_NOT_RETIRED` | `public` | claim_asset. |
| `E_RECEIPT_ESCROW_MISMATCH` | `public` | return_asset. |
| `E_RECEIPT_ASSET_MISMATCH` | `public` | return_asset. |
| `E_NO_EARNINGS` | `public` | withdraw_earnings. |
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
| `current_state(...)` | `public` | Read-only. |
| `current_used_credit(...)` | `public` | Read-only. |
| `current_price_descent(...)` | `public` | Read-only. |
| `current_next_rent_price(...)` | `public` | Read-only. |
| `do_handover(...)` | private | §7.1 |
| `do_tenure_expiry(...)` | private | §7.2 |
| `do_auction_expiry(...)` | private | §7.3 |
| `split_fee(...)` | private | §7.4 |

**Depends on:**
- `math` — `mul_div` via `split_fee`.
- `curve_shape` — `CurveShape`, `compute_used_credit`, `compute_price_descent`.
- `price_function` — `PriceFunction`, `compute_next_rent_price`.
- `config` — `IntegrationConfig` and `public(package)` getters.
- `owner_cap` — `OwnerCap`, `new`, `burn`, `escrow_id`, `assert_escrow`.
- `tenant_cap` — `TenantCap`, `new`, `escrow_id`.
- `protocol_fee_inbox` — `ProtocolFeeRef`, `fee_ref_inbox_id`.
- `fee_message` — `send_fee`.

**Integration flow for a third-party integrator:**

1. Build `CurveShape` values via `curve_shape::new_*`.
2. Build `PriceFunction` value via `price_function::new_*`.
3. Build `IntegrationConfig` via `config::new_config(...)`.
4. Call `rental_escrow::integrate(asset, config, fee_ref, ctx)` →
   receive `OwnerCap`.
5. The escrow is now shared and addressable. Any participant may
   `apply_pending_transitions`, read state, or `rent`.
6. The owner may `withdraw_earnings` at any time; `retire` when ready;
   and `claim_asset` once the state has resolved to `Retired`.

All three layers (`curve_shape`, `price_function`, `config`, `rental_escrow`)
are composable from a single PTB. No off-chain coordinator or keeper is
required — the protocol is fully lazy and permissionlessly settleable.
