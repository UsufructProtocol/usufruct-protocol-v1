# Module Map — Sui Move Implementation

Single reference for implementation design.
For protocol rationale and incentive analysis see `design-compact.md`.

**Status key:** `[ ]` pending · `[~]` speccing · `[x]` specced · `[*]` coded

---

## Object Model

One shared object per asset instance (`RentalEscrow`). No global singleton.
Protocol fees accumulate in a `protocol_treasury` `Balance` field inside each escrow.
At retirement, `claim_asset()` extracts that balance into a `ProtocolFeeReceipt<C>`
hot potato — resolved in the same PTB by `share_protocol_fees()`, which creates an
independent `OrphanedTreasury<C>` shared object if fees are non-zero. All other
operations stay on the single escrow object.

```
 OWNER'S WALLET                        TENANT'S WALLET (current / pending)
 ┌───────────────────┐                 ┌──────────────────────┐
 │    OwnerCap       │                 │      TenantCap        │
 │   · escrow_id: ID │                 │   · escrow_id: ID     │
 └─────────┬─────────┘                 └──────────┬────────────┘
           │                                       │
           │ retire() / claim_asset()              │ borrow_asset()
           │ withdraw_earnings()                   │
           ▼                                       ▼
╔══════════════════════════════════════════════════════════════════════╗
║  RentalEscrow<Asset, CoinType>       [SHARED — per asset]           ║
║                                                                      ║
║  ┌────────────────────────┐  ┌──────────────────────────────────┐  ║
║  │  Asset (key + store)   │  │  IntegrationConfig  (immutable)  │  ║
║  │  ← always present;     │  │  · min_rent_price                │  ║
║  │    escrow exists ↔     │  │  · tenure_ceiling                │  ║
║  │    asset exists        │  │  · handover_floor                │  ║
║  └────────────────────────┘  │  · descent_ceiling               │  ║
║                               │  · retire_floor                  │  ║
║  ┌────────────────────────┐  │  · CurveShape g  (credit)        │  ║
║  │  AssetState            │  │  · CurveShape h  (descent)       │  ║
║  │  Idle                  │  │  · PriceFunction                 │  ║
║  │  Rented                │  └──────────────────────────────────┘  ║
║  │    HandoverOpen        │                                         ║
║  │    HandoverConfirmed   │  ┌───────────────────────────────────┐ ║
║  │  AtDutchAuction        │  │  Phase anchors                    │ ║
║  │  Retired               │  │  · last_rent_price: u64           │ ║
║  └────────────────────────┘  │  · phase_start_ms: u64            │ ║
║                               │  · handover_countdown_expiry      │ ║
║  ┌──────────────────┐         │  · current_tenant_cap_id          │ ║
║  │  tenant_stake    │         │  · current_tenant_address         │ ║
║  │  Balance<C>      │         │  · pending_tenant_address         │ ║
║  └──────────────────┘         └───────────────────────────────────┘ ║
║  ┌──────────────────┐                                               ║
║  │  pending_bid     │         ┌───────────────────────────────────┐ ║
║  │  Balance<C>      │         │  Flags                            │ ║
║  └──────────────────┘         │  · retire_flag: bool              │ ║
║  ┌──────────────────┐         │  · integrated_at_ms: u64          │ ║
║  │  owner_earnings  │         └───────────────────────────────────┘ ║
║  │  Balance<C>      │                                               ║
║  └──────────────────┘                                               ║
║  ┌──────────────────┐                                               ║
║  │protocol_treasury │                                               ║
║  │  Balance<C>      │                                               ║
║  └──────────────────┘                                               ║
╚══════════════════════════════════════════════════════════════════════╝

╔══════════════════════════════════════════════════════════════════════╗
║  OrphanedTreasury<CoinType>          [SHARED — created at retire]   ║
║                                                                      ║
║  ┌──────────────────┐                                               ║
║  │  balance         │  Created by share_protocol_fees() inside     ║
║  │  Balance<C>      │  claim_asset() PTB. Floats until drained.    ║
║  └──────────────────┘  Deleted by drain_orphaned_treasury().       ║
╚══════════════════════════════════════════════════════════════════════╝


 PTB SCOPE ONLY  (hot potato — no abilities)
 ┌──────────────────────────────────────────────────────────────────┐
 │                                                                  │
 │   borrow_asset() ──→  Asset (out of escrow)  +  AssetReceipt   │
 │                              │                       │           │
 │                    used by tenant                 consumed by   │
 │                    in integrating protocol        return_asset() │
 │                              │                       │           │
 │   return_asset() ◀──  Asset (back to escrow) ◀──────┘           │
 │                                                                  │
 └──────────────────────────────────────────────────────────────────┘
```

---

## Coin Flows

```
 rent() [Idle]              →  Coin<C>  →  tenant_stake
 rent() [AtDutchAuction]    →  Coin<C>  →  tenant_stake
 rent() [Rented]            →  Coin<C>  →  pending_bid
   (if superseded)          ←  Coin<C>  ←  pending_bid  (refund, push)

 apply_pending_transitions() — handover fires:
   pending_bid              →  tenant_stake  (new tenant)
   used_credit × 0.95       →  owner_earnings
   used_credit × 0.05       →  protocol_treasury  (local, inside escrow)
   remain_credit            ←  Coin<C>  (push to current_tenant_address)

 apply_pending_transitions() — tenure expiry:
   tenant_stake × 0.95      →  owner_earnings
   tenant_stake × 0.05      →  protocol_treasury  (local, inside escrow)

 withdraw_earnings()           ←  Coin<C>  ←  owner_earnings              (pull, OwnerCap)
 withdraw_treasury()           ←  Coin<C>  ←  protocol_treasury local      (pull, ProtocolAdminCap, on escrow)
 retire()                   —  sets retire_flag only, no asset movement
 claim_asset()              ←  Coin<C>  ←  owner_earnings (sweep)
                            —  protocol_treasury  →  OrphanedTreasury<C>  (shared, if balance > 0)
                            —  protocol_treasury  →  destroy_zero          (if balance == 0)
                            ←  Asset    ←  RentalEscrow (unwrapped, deleted)
 drain_orphaned_treasury()  ←  Coin<C>  ←  OrphanedTreasury<C>             (pull, ProtocolAdminCap, deleted)
```

---

## Contention Map

One shared object per asset for all normal operations. No global singleton exists.

| Operation | Contention |
|---|---|
| `rent`, `retire`, `borrow_asset`, `apply_pending_transitions` | serial on RentalEscrow |
| `return_asset` | serial on RentalEscrow |
| `withdraw_earnings` | serial on RentalEscrow |
| `withdraw_treasury` | serial on RentalEscrow |
| `claim_asset` | serial on RentalEscrow only |
| `drain_orphaned_treasury` | serial on OrphanedTreasury only |

---

## Package

```toml
[package]
name    = "LiquidRenting"
edition = "2024"

[addresses]
liquid_renting = "0x0"
```

---

## Module Dependency Graph

```
  math
   ^
   |
 curve
   ^
   |
config    owner_cap    tenant_cap    events    admin
    ^          ^            ^          ^        ^
     \         |            |          |       /
      \        |            |          |      /
                    rental_escrow
```

Arrows point from dependency to dependent.
`rental_escrow` is the integration point; every other module is independent of it.

---

## Modules

### 1. `math.move` — Fixed-point arithmetic primitives

**Responsibility:** Pure integer math with u128 intermediates.
No protocol types, no objects, no Sui framework dependencies.

**Exports (public):**

| Function | Signature | Purpose |
|---|---|---|
| `mul_div` | `(a: u64, b: u64, c: u64): u64` | `a * b / c` via u128, overflow-safe |
| `pow_frac` | `(base: u64, exp_num: u64, exp_den: u64, scale: u64): u64` | `base^(n/d)` for PowerLaw curves |
| `exp_scaled` | `(alpha: u64, x_num: u64, x_den: u64, scale: u64): u64` | `(e^(ax)-1)/(e^a-1)` for Exponential curves |
| `smoothstep` | `(x_num: u64, x_den: u64, scale: u64): u64` | `3x^2 - 2x^3` for Smoothstep curves |

**Status:** [ ] `mul_div` · [ ] `pow_frac` · [ ] `exp_scaled` · [ ] `smoothstep`

**Depends on:** nothing.

---

### 2. `curve.move` — Shape functions and price functions

**Responsibility:** Defines the `CurveShape` and `PriceFunction` enum types.
Evaluates normalized shape functions and price computations.
All functions are pure — no objects, no mutation, no Sui state.

**Types:**

| Type | Abilities | Variants |
|---|---|---|
| `CurveShape` | `copy, drop, store` | `Linear`, `Smoothstep`, `PowerLaw { alpha_num: u8, alpha_den: u8 }`, `Exponential { alpha_abs: u8, alpha_neg: bool }`, `Logistic` (no fields — k=20 fixed, denom precomputed as module constant) |
| `PriceFunction` | `copy, drop, store` | `FixedDelta { delta: u64 }`, `Percentage { bps: u64 }`, `CompoundDelta { bps: u64, delta: u64 }` |

**Functions:**

| Function | Visibility | Signature | Purpose |
|---|---|---|---|
| `evaluate` | private | `(shape: &CurveShape, x_num: u64, x_den: u64, scale: u64): u64` | Evaluate normalized shape at `x = x_num/x_den`, result in `[0, scale]`. Used only by `compute_used_credit` and `compute_price_descent`. |
| `compute_used_credit` | `public(package)` | `(shape: &CurveShape, elapsed_ms: u64, tenure_ceiling: u64, last_rent_price: u64): u64` | `last_rent_price * g(elapsed / tenure_ceiling)`. Saturates at `last_rent_price`. |
| `compute_price_descent` | `public(package)` | `(shape: &CurveShape, elapsed_ms: u64, descent_ceiling: u64, last_rent_price: u64, min_rent_price: u64): u64` | `last_rent_price - (last_rent_price - min_rent_price) * h(elapsed / descent_ceiling)`. Saturates at `min_rent_price`. |
| `compute_next_rent_price` | `public(package)` | `(price_fn: &PriceFunction, last_rent_price: u64): u64` | Dispatches on variant. Result always `> last_rent_price`. |

**Constructors (public):** One `new_*` per variant for each type, with validation:
- `CurveShape`: `PowerLaw` requires `alpha_num ∈ [1,8], alpha_den ∈ {1,2,3,4}, alpha_num != alpha_den`. `Exponential` requires `alpha_abs ∈ [1,8]`. `Logistic` has no fields — no validation needed.
- `PriceFunction`: `FixedDelta` requires `delta > 0`; `Percentage` requires `bps > 0`; `CompoundDelta` requires `bps > 0 || delta > 0`.

**Status:** [ ] `CurveShape` · [ ] `PriceFunction` · [ ] `evaluate` · [ ] `compute_used_credit` · [ ] `compute_price_descent` · [ ] `compute_next_rent_price`

**Depends on:** `math`.

---

### 3. `config.move` — Integration configuration

**Responsibility:** `IntegrationConfig` struct and its validated constructor.
Bundles all immutable parameters set once at integration time.
No UID, no object identity — plain data struct embedded inside `RentalEscrow`.

**Types:**

| Type | Abilities |
|---|---|
| `IntegrationConfig` | `store` |

**Fields:**
- `min_rent_price: u64`
- `tenure_ceiling: u64` — ms
- `handover_floor: u64` — ms
- `descent_ceiling: u64` — ms
- `retire_floor: u64` — ms
- `credit_curve: CurveShape` — g, for `f_credit_ascent`
- `descent_curve: CurveShape` — h, for `f_price_descent`
- `price_function: PriceFunction` — for `f_next_rent_price`

**Exports (public):**

| Function | Purpose |
|---|---|
| `new(min_rent_price, tenure_ceiling, handover_floor, descent_ceiling, retire_floor, credit_curve, descent_curve, price_function): IntegrationConfig` | Validates all constraints, aborts on violation |
| One getter per field | Immutable access |

**Validation constraints (enforced in `new`):**
```
min_rent_price   > 0
tenure_ceiling   > 0
0 < handover_floor <= tenure_ceiling
descent_ceiling  > 0
retire_floor     >= 0   (always true for u64)
```

**Status:** [ ] `IntegrationConfig` · [ ] `new` · [ ] getters

**Depends on:** `curve`.

---

### 4. `owner_cap.move` — Owner capability

**Responsibility:** `OwnerCap` object. One per integration instance.
Proves authority for `retire()`, `claim_asset()`, and `withdraw_earnings()`.

**Types:**

| Type | Abilities | Notes |
|---|---|---|
| `OwnerCap` | `key, store` | Transferable. Can itself be integrated into a level-2 escrow. |

**Fields:**
- `id: UID`
- `escrow_id: ID`

**Exports:**

| Function | Visibility | Purpose |
|---|---|---|
| `new(escrow_id, ctx): OwnerCap` | `public(package)` | Mint. Called only by `rental_escrow::integrate`. |
| `burn(cap)` | `public(package)` | Destroy. Called only by `rental_escrow::claim_asset`. |
| `escrow_id(cap): ID` | `public` | Getter. |
| `assert_escrow(cap, escrow_id)` | `public(package)` | Aborts if `cap.escrow_id != escrow_id`. |

**Status:** [ ] `OwnerCap` · [ ] `new` · [ ] `burn` · [ ] `escrow_id` · [ ] `assert_escrow`

**Depends on:** nothing (only `sui::object`).

---

### 5. `tenant_cap.move` — Tenant capability and asset receipt

**Responsibility:** `TenantCap` object only.
`TenantCap` is minted only when a bidder becomes the current tenant — not at bid time.
Stale caps from displaced tenants are inert.

**Types:**

| Type | Abilities | Notes |
|---|---|---|
| `TenantCap` | `key` | Non-transferable (no `store`). |

**`TenantCap` fields:**
- `id: UID`
- `escrow_id: ID`

**Exports:**

| Function | Visibility | Purpose |
|---|---|---|
| `new(escrow_id, ctx): TenantCap` | `public(package)` | Mint. Called by `rental_escrow::rent` (Idle, AtDutchAuction) and `rental_escrow::do_handover` (handover completion). |
| `burn(cap)` | `public` | Voluntary destroy for gas recovery. No state mutation. |
| `escrow_id(cap): ID` | `public` | Getter. |

**Status:** [ ] `TenantCap` · [ ] `new` · [ ] `burn` · [ ] `escrow_id`

**Depends on:** nothing (only `sui::object`).

---

### 6. `events.move` — Protocol events

**Responsibility:** Event struct definitions and package-scoped emit helpers.
No logic, no state. Pure data carriers.

**Types (all `copy, drop`):**

| Event | Key Fields | Emitted by |
|---|---|---|
| `AssetIntegrated` | `escrow_id, owner_cap_id, min_rent_price, tenure_ceiling` | `integrate` |
| `RentalStarted` | `escrow_id, tenant_cap_id, price` | `rent` (Idle, AtDutchAuction) |
| `TakeoverInitiated` | `escrow_id, outgoing_cap_id, pending_tenant_address, new_price, handover_expiry` | `rent` (HandoverOpen) |
| `BidSuperseded` | `escrow_id, refunded_address, refunded_amount` | `rent` (HandoverConfirmed) |
| `HandoverCompleted` | `escrow_id, from_cap_id, to_cap_id, remain_credit_returned, owner_earned, protocol_fee` | `apply_pending_transitions` → `do_handover` (lazy) |
| `TenureExpired` | `escrow_id, cap_id, owner_earned, protocol_fee` | `apply_pending_transitions` → `do_tenure_expiry` (lazy) |
| `DutchAuctionStarted` | `escrow_id, start_price, floor_price` | `apply_pending_transitions` → `do_tenure_expiry` (lazy) |
| `DutchAuctionEntry` | `escrow_id, tenant_cap_id, entry_price` | `rent` (AtDutchAuction) |
| `AssetIdled` | `escrow_id` | `apply_pending_transitions` → `do_auction_expiry` (lazy) |
| `RetireInitiated` | `escrow_id, current_state: u8` | `retire` |
| `AssetRetired` | `escrow_id` | `claim_asset` |

**Exports:** One `emit_*` function per event (`public(package)`), so only `rental_escrow` can fire them.

**Status:** [ ] all event structs · [ ] all `emit_*` helpers

**Depends on:** nothing (only `sui::event`).

---

### 7. `admin.move` — Protocol administration

**Responsibility:** `ProtocolAdminCap`, `OrphanedTreasury`, and the package `init` function.
`ProtocolAdminCap` is created once at publish time via one-time witness (OTW) pattern.
`OrphanedTreasury` is created per retired escrow with non-zero protocol fees — one independent shared object per retirement, floats until the admin drains it.

**Types:**

| Type | Abilities | Notes |
|---|---|---|
| `ADMIN` | `drop` | OTW. Consumed in `init`. |
| `ProtocolAdminCap` | `key, store` | Singleton. Held by protocol deployer. |
| `OrphanedTreasury<phantom CoinType>` | `key` | Shared object. Created by `share_protocol_fees()` at escrow retirement. Deleted by `drain_orphaned_treasury()`. |

**Fields (`ProtocolAdminCap`):**
- `id: UID`

**Fields (`OrphanedTreasury`):**
- `id: UID`
- `balance: Balance<CoinType>`
- `escrow_id: ID`
- `asset_id: ID`

**Exports:**

| Function | Visibility | Purpose |
|---|---|---|
| `init(witness, ctx)` | private | Creates `ProtocolAdminCap` (transfer to sender). |
| `share_protocol_fees<C>(balance: Balance<C>, escrow_id: ID, asset_id: ID, ctx)` | `public(package)` | If `balance > 0`: creates and shares `OrphanedTreasury<C>` with `escrow_id` and `asset_id` for traceability. If `balance == 0`: destroys zero balance. Called only by `rental_escrow::claim_asset`. |
| `drain_orphaned_treasury<C>(treasury, cap, ctx): Coin<C>` | `public` | Requires `ProtocolAdminCap`. Drains `OrphanedTreasury.balance` → `Coin`, deletes the object. |

**Status:** [ ] `ADMIN` OTW · [ ] `ProtocolAdminCap` · [ ] `OrphanedTreasury` · [ ] `init` · [ ] `share_protocol_fees` · [ ] `drain_orphaned_treasury`

**Depends on:** nothing.

---

### 8. `rental_escrow.move` — Core escrow and public API

**Responsibility:** The central shared object, state machine, lazy evaluation,
all public entry points, and fund distribution logic.
This is the integration point — it consumes every other module.

**Types:**

| Type | Abilities | Notes |
|---|---|---|
| `RentalEscrow<phantom Asset, phantom CoinType>` | `key` | Shared object. One per integrated asset. |
| `AssetState` | `copy, drop, store` | Public enum: `Idle`, `Rented { phase: RentPhase }`, `AtDutchAuction`, `Retired` |
| `RentPhase` | `copy, drop, store` | Public enum: `HandoverOpen`, `HandoverConfirmed` |
| `AssetReceipt` | *(none)* | Hot potato. Created by `borrow_asset`, consumed by `return_asset`. Carries `escrow_id` and `asset_id` to enforce same-PTB return of the exact asset to the exact escrow. |

`AssetState` and `RentPhase` are public so external callers can pattern-match on
`escrow.state` after `apply_pending_transitions` settles it. The `state` field is
not directly writable from outside the module — all transitions go through module
functions.

**`RentalEscrow` fields:**
- `id: UID`
- `asset: Asset`
- `config: IntegrationConfig`
- `state: AssetState`
- `last_rent_price: u64`
- `phase_start_ms: u64`
- `current_tenant_cap_id: Option<ID>`
- `current_tenant_address: Option<address>`
- `pending_tenant_address: Option<address>`
- `pending_bid: Balance<CoinType>`
- `handover_countdown_expiry: Option<u64>`
- `tenant_stake: Balance<CoinType>`
- `owner_earnings: Balance<CoinType>`
- `protocol_treasury: Balance<CoinType>`
- `retire_flag: bool`
- `integrated_at_ms: u64`

**Public API:**

| Function | Visibility | Summary |
|---|---|---|
| `integrate` | `public` | Creates and shares `RentalEscrow`. Returns `OwnerCap`. |
| `rent` | `public` | Single entry point to become tenant. Calls `apply_pending_transitions()` first, then applies sub-logic by state: **Idle** — pays `min_rent_price`, mints + pushes `TenantCap`. **AtDutchAuction** — pays `compute_price_descent()`, mints + pushes `TenantCap`. **Rented(HandoverOpen)** — pays `compute_next_rent_price()`, stores `pending_tenant_address`, sets `handover_countdown_expiry = min(clock.now() + handover_floor, phase_start_ms + tenure_ceiling)`. Aborts if `retire_flag` is set — no new bids accepted, current tenant runs to `tenure_ceiling`. **Rented(HandoverConfirmed)** — pays `compute_next_rent_price()`, refunds previous `pending_bid` (push), overwrites `pending_tenant_address`. `handover_countdown_expiry` is unchanged. `retire_flag` does not abort here — the pending bid is already committed; handover completes normally and T(n+1) enters `HandoverOpen` with the flag active. **Retired** — aborts. |
| `borrow_asset` | `public` | Integration point between the protocol and the integrating ecosystem. Calls `apply_pending_transitions()` first. Verifies current `TenantCap`. Extracts asset, creates `AssetReceipt { escrow_id, asset_id: object::id(&asset) }` inline. The tenant holds the asset within the PTB and can pass it to any function in the integrating protocol — this is how usus and fructus are exercised. Asset must be returned in the same PTB via `return_asset()`. |
| `return_asset` | `public` | Consumes `AssetReceipt` inline. Verifies `receipt.escrow_id` matches the escrow and `receipt.asset_id` matches `object::id(&asset)`. Returns asset to escrow. No state resolution needed. |
| `retire` | `public` | Requires `OwnerCap`. Calls `apply_pending_transitions()` first. Sets `retire_flag`. Never returns asset. |
| `claim_asset` | `public` | Requires `OwnerCap`. Calls `apply_pending_transitions()` first. State must be `Retired`. Sweeps `owner_earnings` to caller as `Coin`. Calls `admin::share_protocol_fees(protocol_treasury, ctx)` directly — creates and shares `OrphanedTreasury<C>` if balance > 0, destroys zero balance if == 0. Burns `OwnerCap`, deletes `RentalEscrow`. Returns `(Asset, Coin<C>)`. |
| `withdraw_earnings` | `public` | Requires `OwnerCap`. Drains `owner_earnings` → `Coin`. No state resolution needed. |
| `withdraw_treasury` | `public` | Requires `ProtocolAdminCap` + `&mut RentalEscrow`. Drains `protocol_treasury` (local) → `Coin`. No state resolution needed. Admin utility — allows collecting fees from an active escrow without waiting for retirement. |
| `apply_pending_transitions` | `public` | Permissionless settler. Executes all elapsed lazy transitions in order, no return value. Called internally by every public mutating function. Also callable directly by incentivized actors (frontend, bots) to advance state and credit pending earnings without triggering a full operation. See §Pending Transitions. |
| `current_used_credit` | `public` | `(escrow: &RentalEscrow, timestamp_ms: u64): u64`. Read-only query. Clamps `timestamp_ms` to `handover_countdown_expiry` if state is `HandoverConfirmed` — prevents showing used_credit beyond the boundary. Delegates to `curve::compute_used_credit`. Used internally by `do_handover` (passes `handover_countdown_expiry`) and externally by frontends (pass `clock.timestamp_ms()`). |
| `current_price_descent` | `public` | `(escrow: &RentalEscrow, timestamp_ms: u64): u64`. Read-only query. Current Dutch Auction price at `timestamp_ms`. Only meaningful when state is `AtDutchAuction`. Delegates to `curve::compute_price_descent`. |
| `current_next_rent_price` | `public` | `(escrow: &RentalEscrow): u64`. Read-only query. Price to displace the current tenant. Only meaningful when state is `Rented`. Delegates to `curve::compute_next_rent_price`. |
**Status:** [ ] `integrate` · [ ] `rent` · [ ] `borrow_asset` · [ ] `return_asset` · [ ] `retire` · [ ] `claim_asset` · [ ] `withdraw_earnings` · [ ] `withdraw_treasury` · [ ] `apply_pending_transitions` · [ ] `current_used_credit` · [ ] `current_price_descent` · [ ] `current_next_rent_price`

**`phase_start_ms` assignment:**

| Transition | New `phase_start_ms` |
|---|---|
| `rent()` from Idle | `clock.now()` |
| `rent()` from AtDutchAuction | `clock.now()` |
| Handover completes | `handover_countdown_expiry` |
| Tenure expiry → AtDutchAuction | `phase_start_ms + tenure_ceiling` |
| Auction expiry → Idle | `phase_start_ms + descent_ceiling` |

`clock.now()` is used only when a tenant voluntarily starts a new tenure. All lazy
boundaries use the exact expiry timestamp so no time is gifted or lost between
when a transition logically occurred and when it was executed.

**Internal functions (private):**

| Function | Purpose |
|---|---|
| `do_handover` | Executes handover boundary: push `remain_credit`, split `used_credit` (95/5) into `owner_earnings` and `protocol_treasury` (local), move `pending_bid` → `tenant_stake`, mint + push `TenantCap`, rotate addresses. Push-before-rotate invariant enforced here. |
| `do_tenure_expiry` | Executes tenure boundary: split full `tenant_stake` (95/5) into `owner_earnings` and `protocol_treasury` (local). Transition to `AtDutchAuction` or `Retired`. |
| `do_auction_expiry` | Transition to `Idle`. No funds to move. |
| `split_fee` | Pure: splits an amount into (amount×0.95, amount×0.05) tuple. |

**Depends on:** `math`, `curve`, `config`, `owner_cap`, `tenant_cap`, `events`, `admin`.

---

## Pending Transitions

### `apply_pending_transitions` — private, called by every public mutating function

**Signature:** `public fun apply_pending_transitions<A, C>(escrow: &mut RentalEscrow<A, C>, clock: &Clock, ctx: &mut TxContext)`

**Sole responsibility:** execute every elapsed lazy transition — in order — before
any public function applies its own logic. This guarantees that `owner_earnings`
and `protocol_treasury` are never bypassed regardless of how long the escrow has
been inactive or what state the caller finds it in.

This is the critical invariant of the protocol. Every boundary event
(handover, tenure expiry, auction expiry) distributes funds to the owner and
the protocol. If any boundary is skipped, those funds never materialize.
`apply_pending_transitions()` makes skipping impossible.

**The three checks — sequential, each reads the state mutated by the previous:**

```
// Check 1 — pending handover
if escrow.state == Rented(HandoverConfirmed)
   && clock.now() >= escrow.handover_countdown_expiry:
     do_handover(escrow, clock, ctx)
     // escrow.state is now Rented(HandoverOpen)
     // escrow.phase_start_ms is now handover_countdown_expiry
     // owner_earnings and protocol_treasury (local) credited with used_credit splits
     // remain_credit pushed to displaced tenant

// Check 2 — tenure expired (reads state as mutated by check 1)
if escrow.state == Rented(...)
   && clock.now() >= escrow.phase_start_ms + config.tenure_ceiling:
     do_tenure_expiry(escrow, ctx)
     // escrow.state is now AtDutchAuction (or Retired if retire_flag)
     // owner_earnings and protocol_treasury (local) credited with full stake splits

// Check 3 — auction expired (reads state as mutated by check 2)
if escrow.state == AtDutchAuction
   && clock.now() >= escrow.phase_start_ms + config.descent_ceiling:
     do_auction_expiry(escrow)
     // escrow.state is now Idle
```

**Properties:**
- Always exactly 3 checks — O(1), no loops, no counters.
- At most 3 transitions fire in a single call — structural property of the state machine.
- Each check reads the state written by the previous. Sequential order is mandatory.
- No prior knowledge of how many transitions are pending. The clock and the stored
  state fields contain all necessary information.
- If no transitions are pending, all 3 checks are no-ops. Zero overhead.
- **Check 1 always precedes Check 2 when `pending_bid` is present.** `rent()` clamps
  `handover_countdown_expiry = min(clock.now() + handover_floor, phase_start_ms + tenure_ceiling)`,
  guaranteeing the handover fires at or before tenure expiry. Check 2 never sees
  `HandoverConfirmed` with an orphaned `pending_bid`.

**Why every public mutating function calls it:**

A public function that mutates state without first calling `apply_pending_transitions()`
could act on a stale state — for example, treating an asset as AtDutchAuction when
a handover and tenure expiry have logically occurred but not been executed. In that
case, the owner's `used_credit` and the protocol's fees from those boundaries would
never be credited. `apply_pending_transitions()` closes this gap unconditionally.

**Exception — functions that do not call it:**
- `return_asset()` — only returns the asset to escrow, no state dependency.
- `withdraw_earnings()` — drains `owner_earnings` directly, no state change.
- `withdraw_treasury()` — drains `protocol_treasury` (local) directly, no state change.

---

## State Settlement

`apply_pending_transitions` is both the internal settlement engine and a public
permissionless entry point. Making it public eliminates the need for a separate
`resolve_state` wrapper — the function is its own interface.

**Signature:** `public fun apply_pending_transitions<A, C>(escrow: &mut RentalEscrow<A, C>, clock: &Clock, ctx: &mut TxContext)`

**The protocol does not need external callers.** Every public mutating function
(`rent`, `retire`, `claim_asset`, `borrow_asset`) calls it before its own logic.
No boundary event can be skipped, and no funds can be permanently left uncredited,
regardless of how long an escrow remains inactive.

**Why it is public:** it allows incentivized actors to advance state and credit
`owner_earnings` and `protocol_treasury` without performing a full protocol
operation. Use cases:
- A frontend that wants to display up-to-date on-chain state before the owner
  calls `withdraw_earnings()`.
- A keeper bot settling expired escrows on behalf of inactive owners.
- Via `devInspectTransactionBlock`: simulate settlement for free to read the
  resulting `escrow.state` without committing the transaction.

---

## Fund Flows

### Tenant stake lifecycle

Payment enters as `Coin<CoinType>` → `Balance` in `RentalEscrow.tenant_stake`.
At handover: split into `used_credit` + `remain_credit`.
`remain_credit` → pushed immediately to displaced tenant as `Coin`.
`used_credit` → split 95/5 → `owner_earnings` (95%) and `protocol_treasury` local (5%).
At tenure expiry: full `tenant_stake` → split 95/5 → `owner_earnings` and `protocol_treasury` local.

### Pending bid lifecycle

Incoming bid enters as `Coin<CoinType>` → `Balance` in `RentalEscrow.pending_bid`.
If superseded: refunded immediately as `Coin` (push to registered address).
At handover: becomes new `tenant_stake`.

### Owner earnings lifecycle

Accumulated in `RentalEscrow.owner_earnings` at each handover and tenure expiry (95% share).
Withdrawn by owner via `withdraw_earnings()` → `Coin` (pull, requires `OwnerCap`).
Swept atomically by `claim_asset()` when the escrow is deleted.

### Protocol fee lifecycle

Accumulated in `RentalEscrow.protocol_treasury` (local `Balance`) at each handover
and tenure expiry (5% share). No cross-escrow contention — stays inside the escrow.
Admin drains via `withdraw_treasury()` at any time (requires `ProtocolAdminCap` + escrow).
On `claim_asset()`: `protocol_treasury` is passed directly to `admin::share_protocol_fees()`.
If balance > 0, a shared `OrphanedTreasury<C>` is created and floats on chain;
if balance == 0, the zero balance is destroyed cleanly. No local balance is ever dropped.
`OrphanedTreasury<C>` objects are discoverable by type (`suix_queryObjects`). The admin
batch-drains them via `drain_orphaned_treasury()` — up to 1024 per PTB — collecting
`Coin<C>` and deleting each object. The CoinType is fixed at integration time and encoded
in the object type, so no coordination is needed to identify which coin to drain.

---

## Notes

- All timestamps in milliseconds (`sui::clock::Clock::timestamp_ms`).
- All prices in base token units (no decimals at protocol level).
- Asset requires `key + store` abilities to live inside `RentalEscrow`.
- `integrate()` creates and shares 1 object: `RentalEscrow`. `admin::init()` creates `ProtocolAdminCap` (transferred to deployer). No global shared singleton exists.
- `asset: Asset` — the asset is always present while the escrow exists. There is no valid persistent state where the escrow exists without the asset. `claim_asset()` extracts the asset and deletes the escrow atomically. The PTB borrow mechanism (`borrow_asset`/`return_asset`) is an implementation detail — the temporary extraction never persists across transaction boundaries.
- Fund flows are asymmetric: owner pulls via `withdraw_earnings()` and `claim_asset()`; admin pulls via `withdraw_treasury()` and `drain_orphaned_treasury()`; tenants receive pushes to the address registered at mint time.
- Stale `TenantCap` objects in a wallet are inert — they fail the ID check. `burn(cap)` is available for gas recovery.
- Maximum nesting depth for `OwnerCap` as asset: 2. Integration is rejected if the asset being integrated is an `OwnerCap` whose own escrow asset is also an `OwnerCap`.
- `ProtocolTreasury` is per-asset (not global) to avoid cross-escrow contention on boundary transitions.
- Object discovery: `AssetIntegrated` includes `escrow_id` so off-chain consumers can track all instances from events. Sui RPC (`suix_queryObjects` by type) serves as a bootstrap fallback.
- `CoinType` is a phantom type parameter fixed at integration time. Any fungible token satisfying Move's abilities works — integrating protocols can use their own native tokens as the rental currency rather than USDC or USDT. A protocol that mints its own asset can rent it out denominated in its own coin, creating a self-contained economic loop without dependency on external stablecoins.

---

## File Layout

```
sources/
    math.move            §1  — pure arithmetic
    curve.move           §2  — shape + price function types and evaluation
    config.move          §3  — IntegrationConfig struct + validation
    owner_cap.move       §4  — OwnerCap object
    tenant_cap.move      §5  — TenantCap + AssetReceipt objects
    events.move          §6  — event structs + emit helpers
    admin.move           §7  — ProtocolAdminCap + init (OTW)
    rental_escrow.move   §8  — RentalEscrow shared object + full public API
tests/
    math_tests.move
    curve_tests.move
    config_tests.move
    rental_escrow_tests.move
Move.toml
Move.lock
```

---

## Design Decisions

### One shared object per instance — no global treasury

All balances (`owner_earnings`, `protocol_treasury`) live inside `RentalEscrow` as
`Balance<CoinType>` fields. `apply_pending_transitions()` credits both at every
boundary event without touching any external object. Every public mutating function
carries only one shared object reference — no contention beyond the escrow itself.

`protocol_treasury` cannot be dropped when the escrow is deleted — `Balance` has no
`drop` ability in Move. `claim_asset()` passes it directly to `admin::share_protocol_fees()`,
a `public(package)` function that creates and shares an `OrphanedTreasury<C>` if the
balance is non-zero, or destroys the zero balance cleanly. The caller receives only
`(Asset, Coin<C>)` — no hot potato to resolve. No global accumulator exists — each
`OrphanedTreasury<C>` is an independent object with no contention on any other escrow
or treasury.

The admin discovers orphaned treasuries by type via `suix_queryObjects` and batch-drains
them — up to 1024 per PTB — collecting `Coin<C>` and deleting each object atomically.
The CoinType is fixed at integration time and encoded in the object type: no coordination
between owner and admin is required at any point in the lifecycle.

### Why `apply_pending_transitions` is public

The protocol guarantees settlement through its normal operations — no external
caller is required for correctness. `apply_pending_transitions` is public because
it is useful, not necessary: it lets any actor advance an idle escrow's state and
credit pending earnings without performing a full protocol operation. A separate
`resolve_state` wrapper would be a redundant indirection with an identical signature
— making the function itself public is the simpler design.

### Why `AssetState` and `RentPhase` live inside `rental_escrow`

`AssetState` and `RentPhase` are public types defined in `rental_escrow` so
external callers can read and pattern-match on `escrow.state` after settlement.

They still live in `rental_escrow` rather than a separate module because no other
module needs to construct or own them. Extracting them would create a module with
no independent responsibility whose sole consumer remains `rental_escrow`.
The `state` field is not directly writable from outside the module. All transitions
go through module functions — `apply_pending_transitions`, `rent`, `retire`, and
`claim_asset` — which control when and how state changes.

### Why `OwnerCap` and `TenantCap` are separate modules

Each is an independent Sui object with its own lifecycle, abilities, and
authorization semantics. Separating them makes abilities and transfer rules
immediately visible from the type definition, and follows the one-module-one-object
principle for objects that leave the module.

### Why `config` is its own module

`IntegrationConfig` aggregates types from `curve` and applies cross-field validation.
Inlining it in `rental_escrow` would force curve types and validation logic into
the already-large escrow module. A dedicated module keeps the constructor focused
and the validation constraints testable in isolation.

### Why `admin` owns `init`

Sui's OTW pattern requires the witness type name to match the module name.
Placing the package `init` in `admin.move` yields the `ADMIN` witness, creating
`ProtocolAdminCap` at publish time. This keeps governance concerns out of
`rental_escrow` and makes the admin cap trivially locatable.

### Why `rent()` is the single entry point

All paths to becoming a tenant go through `rent()`. The function calls
`apply_pending_transitions()` first, then applies the appropriate sub-logic based
on the resulting `escrow.state`: Idle, AtDutchAuction, Rented(HandoverOpen), or
Rented(HandoverConfirmed).

One responsibility: pay for access. The state determines the price and the mechanics.
The API surface is minimal — no `takeover()`, no `rent_auction()`.

The caller queries the current state and price off-chain via `devInspectTransactionBlock`
before constructing the PTB with the exact payment amount.

### Lazy minting of TenantCap

`TenantCap` is minted only when someone actually becomes the current tenant —
not at bid time. `rent()` in Rented states stores `pending_tenant_address` but mints nothing.

This eliminates the entire class of orphaned caps from superseded bidders.
The only unavoidable orphan is one per completed handover: the displaced tenant's
cap, whose storage cost they paid themselves and whose rebate is theirs to claim.

The handover executes lazily inside `apply_pending_transitions()` — it fires
automatically as a side effect of the next operation on the escrow (`rent()`,
`borrow_asset()`, `retire()`, or `apply_pending_transitions()`). Two incentivized
actors exist: the new tenant (wants cap and access) and the displaced tenant
(wants remain_credit). Either can trigger it by calling `apply_pending_transitions()`.
No cooperative dependency between
them — `remain_credit` and `TenantCap` are pushed regardless of who triggers the
settlement.

**Push ordering invariant:** balances are pushed before addresses are rotated.
`remain_credit` goes to `current_tenant_address` before that field is overwritten.
`TenantCap` is pushed to `pending_tenant_address` before that field is cleared.

**TenantCap as signal:** the cap appearing in the wallet is the clearest possible
notification of tenancy. No indexer query, no event subscription needed —
the object in the wallet says everything.

**Edge case — both actors inactive:** if neither actor calls `apply_pending_transitions()`
and the new tenant's tenure expires, the full lazy chain (handover → tenure expiry
→ AtDutchAuction) executes when the next actor touches the escrow. No funds are
permanently lost. The new tenant bears the cost of inaction — their stake is
consumed for time they held exclusive rights but did not exercise.

### Why `retire` and `claim_asset` are separate functions

`retire()` initiates retirement — it sets `retire_flag` and blocks new bids,
but never returns the asset. `claim_asset()` finalizes retirement — it requires
state `Retired`, extracts the asset, burns the `OwnerCap`, and deletes the escrow.

The owner always makes two calls regardless of the prior state:
- `retire()` on Idle or AtDutchAuction: state transitions to Retired immediately
  (no active tenant). Owner then calls `claim_asset()` to collect.
- `retire()` on Rented: sets flag, tenant completes their block. Owner calls
  `claim_asset()` after tenure expires and state has lazily resolved to Retired.

Consistent two-step flow for all cases. `retire()` never returns an asset.
`claim_asset()` always does — and in the same call: sweeps `owner_earnings` to the
owner, wraps `protocol_treasury` into a `ProtocolFeeReceipt<C>` hot potato and
immediately resolves it via `share_protocol_fees()` (both internal to the call),
burns `OwnerCap`, and deletes `RentalEscrow`. All local balances are consumed before
deletion — no orphaned funds, no locked balances.


---

## Implementation Order

Build bottom-up following the dependency graph:

```
1. math          (leaf — no dependencies)
2. curve         (depends on math)
3. config        (depends on curve)
4. owner_cap     (leaf)
5. tenant_cap    (leaf)
6. events        (leaf)
7. admin         (leaf)
8. rental_escrow (depends on all above)
```

Steps 4–7 are independent of each other and of steps 1–3.
