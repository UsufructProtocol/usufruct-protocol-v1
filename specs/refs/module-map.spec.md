# Module Map — Sui Move Implementation

Single reference for implementation design.
For protocol rationale and incentive analysis see `design-compact.md`.

**Status key:** `[ ]` pending · `[~]` speccing · `[x]` specced · `[*]` coded

---

## Object Model

Three shared objects per asset instance. Grouped by function access pattern
to minimize contention between independent operations.

```
 OWNER'S WALLET                        TENANT'S WALLET (current / pending)
 ┌───────────────────┐                 ┌──────────────────────┐
 │    OwnerCap       │                 │      TenantCap        │
 │   · escrow_id: ID │                 │   · escrow_id: ID     │
 └─────────┬─────────┘                 └──────────┬────────────┘
           │                                       │
           │ retire()                               │ borrow_asset()
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
║  ┌────────────────────────┐  │  · retire_floor                  │  ║
║  │  AssetState            │  │  · CurveShape g  (credit)        │  ║
║  │  Idle                  │  │  · CurveShape h  (descent)       │  ║
║  │  Rented                │  │  · PriceFunction                 │  ║
║  │    HandoverOpen        │  └──────────────────────────────────┘  ║
║  │    HandoverConfirmed   │                                         ║
║  │  AtDutchAuction        │  ┌───────────────────────────────────┐ ║
║  │  Retired               │  │  Phase anchors                    │ ║
║  └────────────────────────┘  │  · last_rent_price: u64           │ ║
║                               │  · phase_start_ms: u64            │ ║
║  ┌──────────────────┐         │  · handover_countdown_expiry      │ ║
║  │  tenant_stake    │         │  · current_tenant_cap_id          │ ║
║  │  Balance<C>      │         │  · current_tenant_address         │ ║
║  └──────────────────┘         │  · pending_tenant_cap_id          │ ║
║  ┌──────────────────┐         │  · pending_tenant_address         │ ║
║  │  pending_bid     │         └───────────────────────────────────┘ ║
║  │  Balance<C>      │                                               ║
║  └──────────────────┘         ┌───────────────────────────────────┐ ║
║                               │  Flags                            │ ║
║                               │  · retire_flag: bool              │ ║
║                               │  · integrated_at_ms: u64          │ ║
║                               └───────────────────────────────────┘ ║
╚══════════════════════════════════════════════════════════════════════╝
           │
           │ earnings push at each boundary (handover / tenure expiry)
           │
           ▼
╔══════════════════════════════════════════╗
║  IntegratorTreasury<CoinType>              ║  [SHARED — per asset]
║  · id: UID                               ║
║  · escrow_id: ID                         ║
║  · earnings: Balance<CoinType>           ║
╚══════════════════════════════════════════╝
           │
           │ withdraw(cap: &OwnerCap)  →  Coin<C>  (pull)
           ▼ owner's wallet


╔══════════════════════════════════════════╗
║  ProtocolTreasury<CoinType>              ║  [SHARED — per asset]
║  · id: UID                               ║
║  · escrow_id: ID                         ║
║  · balance: Balance<CoinType>            ║
╚══════════════════════════════════════════╝
           │
           │ withdraw(cap: &ProtocolAdminCap)  →  Coin<C>  (pull)
           │ batched across instances in a single PTB by admin
           ▼ admin's wallet


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
 rent() / rent_auction()  →  Coin<C>           →  RentalEscrow.tenant_stake
 takeover()               →  Coin<C>           →  RentalEscrow.pending_bid
   (if superseded)        ←  Coin<C>           ←  RentalEscrow.pending_bid  (refund, push)
 handover fires           :  pending_bid       →  tenant_stake (new tenant)
                          :  used_credit×0.95  →  IntegratorTreasury.earnings
                          :  used_credit×0.05  →  ProtocolTreasury.balance
                          ←  Coin<C>           ←  remain_credit (to old tenant, push)
 tenure expiry            :  stake×0.95        →  IntegratorTreasury.earnings
                          :  stake×0.05        →  ProtocolTreasury.balance
 IntegratorTreasury.withdraw()  ←  Coin<C>  ←  earnings  (pull, OwnerCap)
 ProtocolTreasury.withdraw()  ←  Coin<C>  ←  balance   (pull, ProtocolAdminCap, batch PTB)
 retire()                 —  sets retire_flag only, no asset movement
 claim_asset()           ←  Coin<C>           ←  IntegratorTreasury.earnings (sweep, if any)
                         ←  Asset             ←  RentalEscrow (unwrapped)
                            IntegratorTreasury deleted
                            RentalEscrow deleted
```

---

## Contention Map

| Operation | Objects touched | Parallel with |
|---|---|---|
| `rent`, `rent_auction` | RentalEscrow only | IntegratorTreasury.withdraw, ProtocolTreasury.withdraw |
| `takeover` | RentalEscrow only | IntegratorTreasury.withdraw, ProtocolTreasury.withdraw |
| `execute_handover` | RentalEscrow + IntegratorTreasury + ProtocolTreasury | nothing (serial on RentalEscrow) |
| boundary transition fires (inside other fns) | RentalEscrow + IntegratorTreasury + ProtocolTreasury | nothing (already serial on RentalEscrow) |
| `borrow_asset`, `return_asset` | RentalEscrow only | IntegratorTreasury.withdraw, ProtocolTreasury.withdraw |
| `retire` | RentalEscrow only | IntegratorTreasury.withdraw, ProtocolTreasury.withdraw |
| `claim_asset` | RentalEscrow + IntegratorTreasury | ProtocolTreasury.withdraw |
| `resolve_state` | RentalEscrow read-only | everything |
| `IntegratorTreasury.withdraw` | IntegratorTreasury only | all RentalEscrow operations |
| `ProtocolTreasury.withdraw` | ProtocolTreasury only | all RentalEscrow operations |

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
               config
                  ^
                  |
  owner_cap   tenant_cap   events   admin
       ^                              ^
       |                              |
  integrator_treasury          protocol_treasury
       \                              /
        \                            /
         v                          v
              rental_escrow
```

Arrows point from dependency to dependent.
`rental_escrow` is the integration point.
`integrator_treasury` depends on `owner_cap` (authorization check).
`protocol_treasury` depends on `admin` (authorization check).

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
| `CurveShape` | `copy, drop, store` | `Linear`, `PowerLaw { alpha_num: u64, alpha_den: u64 }`, `Exponential { alpha: u64 }`, `Smoothstep` |
| `PriceFunction` | `copy, drop, store` | `FixedDelta { delta: u64 }`, `Percentage { bps: u64 }`, `CompoundDelta { bps: u64, delta: u64 }` |

**Exports (public):**

| Function | Signature | Purpose |
|---|---|---|
| `evaluate` | `(shape: &CurveShape, x_num: u64, x_den: u64, scale: u64): u64` | Evaluate normalized shape at `x = x_num/x_den`, result in `[0, scale]` |
| `compute_used_credit` | `(shape: &CurveShape, elapsed_ms: u64, tenure_ceiling: u64, last_rent_price: u64): u64` | `last_rent_price * g(elapsed / tenure_ceiling)`. Saturates at `last_rent_price`. |
| `compute_price_descent` | `(shape: &CurveShape, elapsed_ms: u64, descent_ceiling: u64, last_rent_price: u64, min_rent_price: u64): u64` | `last_rent_price - (last_rent_price - min_rent_price) * h(elapsed / descent_ceiling)`. Saturates at `min_rent_price`. |
| `compute_next_rent_price` | `(price_fn: &PriceFunction, last_rent_price: u64): u64` | Dispatches on variant. Result always `> last_rent_price`. |

**Constructors (public):** One `new_*` per variant for each type, with validation:
- `CurveShape`: `PowerLaw` requires `alpha_num > 0, alpha_den > 0`.
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
Proves authority for `retire()` and `IntegratorTreasury::withdraw()`.

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
| `burn(cap)` | `public(package)` | Destroy. Called only by `rental_escrow::retire`. |
| `escrow_id(cap): ID` | `public` | Getter. |
| `assert_escrow(cap, escrow_id)` | `public(package)` | Aborts if `cap.escrow_id != escrow_id`. |

**Status:** [ ] `OwnerCap` · [ ] `new` · [ ] `burn` · [ ] `escrow_id` · [ ] `assert_escrow`

**Depends on:** nothing (only `sui::object`).

---

### 5. `tenant_cap.move` — Tenant capability and asset receipt

**Responsibility:** `TenantCap` object and `AssetReceipt` hot potato.
`TenantCap` is minted on every valid bid; stale caps are inert.
`AssetReceipt` enforces same-PTB return of borrowed assets.

**Types:**

| Type | Abilities | Notes |
|---|---|---|
| `TenantCap` | `key` | Non-transferable (no `store`). |
| `AssetReceipt` | *(none)* | Hot potato. |

**`TenantCap` fields:**
- `id: UID`
- `escrow_id: ID`

**`AssetReceipt` fields:**
- `escrow_id: ID`

**Exports:**

| Function | Visibility | Purpose |
|---|---|---|
| `new(escrow_id, ctx): TenantCap` | `public(package)` | Mint. Called by `rental_escrow::{rent, takeover, rent_auction}`. |
| `burn(cap)` | `public` | Voluntary destroy for gas recovery. No state mutation. |
| `escrow_id(cap): ID` | `public` | Getter. |
| `new_receipt(escrow_id): AssetReceipt` | `public(package)` | Create hot potato. Called by `rental_escrow::borrow_asset`. |
| `consume_receipt(receipt, escrow_id)` | `public(package)` | Destroy receipt. Aborts if `receipt.escrow_id != escrow_id`. |

**Status:** [ ] `TenantCap` · [ ] `AssetReceipt` · [ ] `new` · [ ] `burn` · [ ] `escrow_id` · [ ] `new_receipt` · [ ] `consume_receipt`

**Depends on:** nothing (only `sui::object`).

---

### 6. `events.move` — Protocol events

**Responsibility:** Event struct definitions and package-scoped emit helpers.
No logic, no state. Pure data carriers.

**Types (all `copy, drop`):**

| Event | Key Fields |
|---|---|
| `AssetIntegrated` | `escrow_id, owner_cap_id, integrator_treasury_id, protocol_treasury_id, min_rent_price, tenure_ceiling` |
| `RentalStarted` | `escrow_id, tenant_cap_id, price` |
| `TakeoverInitiated` | `escrow_id, outgoing_cap_id, incoming_cap_id, new_price, handover_expiry` |
| `BidSuperseded` | `escrow_id, refunded_cap_id, refunded_amount` |
| `HandoverCompleted` | `escrow_id, from_cap_id, to_cap_id, remain_credit_returned, owner_earned, protocol_fee` |
| `TenureExpired` | `escrow_id, cap_id, owner_earned, protocol_fee` |
| `DutchAuctionStarted` | `escrow_id, start_price, floor_price` |
| `DutchAuctionEntry` | `escrow_id, tenant_cap_id, entry_price` |
| `AssetIdled` | `escrow_id` |
| `RetireInitiated` | `escrow_id, current_state: u8` |
| `AssetRetired` | `escrow_id` |

**Exports:** One `emit_*` function per event (`public(package)`), so only `rental_escrow` can fire them.

**Status:** [ ] all event structs · [ ] all `emit_*` helpers

**Depends on:** nothing (only `sui::event`).

---

### 7. `admin.move` — Protocol administration

**Responsibility:** `ProtocolAdminCap` and the package `init` function.
Created once at publish time via one-time witness (OTW) pattern.
Required for `ProtocolTreasury::withdraw()`.

**Types:**

| Type | Abilities | Notes |
|---|---|---|
| `ADMIN` | `drop` | OTW. Consumed in `init`. |
| `ProtocolAdminCap` | `key, store` | Singleton. Held by protocol deployer. |

**Fields (`ProtocolAdminCap`):**
- `id: UID`

**Exports:**

| Function | Visibility | Purpose |
|---|---|---|
| `init(witness, ctx)` | private | Creates `ProtocolAdminCap`, transfers to sender. |
| `assert_admin(cap)` | `public(package)` | Type-level check (receiving `&ProtocolAdminCap` is sufficient). |

**Status:** [ ] `ADMIN` OTW · [ ] `ProtocolAdminCap` · [ ] `init` · [ ] `assert_admin`

**Depends on:** nothing.

---

### 8. `integrator_treasury.move` — Integrator earnings

**Responsibility:** `IntegratorTreasury` shared object. Receives the owner's 95% share
of `used_credit` at each boundary transition. Fully decoupled from `RentalEscrow`
so owner earnings withdrawals never contend with rental operations.

**Types:**

| Type | Abilities | Notes |
|---|---|---|
| `IntegratorTreasury<phantom CoinType>` | `key` | Shared object. One per asset instance. |

**Fields:**
- `id: UID`
- `escrow_id: ID` — back-reference to the associated `RentalEscrow`
- `earnings: Balance<CoinType>`

**Exports:**

| Function | Visibility | Purpose |
|---|---|---|
| `new(escrow_id, ctx): IntegratorTreasury<C>` | `public(package)` | Create and share. Called only by `rental_escrow::integrate`. |
| `deposit(self, amount: Balance<C>)` | `public(package)` | Push earnings in. Called by `rental_escrow` at boundaries. |
| `withdraw(self, cap: &OwnerCap, ctx): Coin<C>` | `public` | Drain all earnings. Verifies `cap.escrow_id == self.escrow_id`. |

**Status:** [ ] `IntegratorTreasury` · [ ] `new` · [ ] `deposit` · [ ] `withdraw`

**Depends on:** `owner_cap`.

---

### 9. `protocol_treasury.move` — Protocol fee accumulator

**Responsibility:** `ProtocolTreasury` shared object. Receives the protocol's 5% share
of `used_credit` at each boundary transition. Per-asset instance eliminates
cross-escrow contention. Admin collects across instances via a single batch PTB.

**Types:**

| Type | Abilities | Notes |
|---|---|---|
| `ProtocolTreasury<phantom CoinType>` | `key` | Shared object. One per asset instance. |

**Fields:**
- `id: UID`
- `escrow_id: ID` — back-reference to the associated `RentalEscrow`
- `balance: Balance<CoinType>`

**Exports:**

| Function | Visibility | Purpose |
|---|---|---|
| `new(escrow_id, ctx): ProtocolTreasury<C>` | `public(package)` | Create and share. Called only by `rental_escrow::integrate`. |
| `deposit(self, amount: Balance<C>)` | `public(package)` | Push fees in. Called by `rental_escrow` at boundaries. |
| `withdraw(self, cap: &ProtocolAdminCap, ctx): Coin<C>` | `public` | Drain all fees. |

**Status:** [ ] `ProtocolTreasury` · [ ] `new` · [ ] `deposit` · [ ] `withdraw`

**Depends on:** `admin`.

---

### 10. `rental_escrow.move` — Core escrow and public API

**Responsibility:** The central shared object, state machine, lazy evaluation,
all public entry points, and fund distribution logic.
This is the integration point — it consumes every other module.

**Types:**

| Type | Abilities | Notes |
|---|---|---|
| `RentalEscrow<phantom Asset, phantom CoinType>` | `key` | Shared object. One per integrated asset. |
| `AssetState` | `copy, drop, store` | Public enum: `Idle`, `Rented { phase: RentPhase }`, `AtDutchAuction`, `Retired` |
| `RentPhase` | `copy, drop, store` | Public enum: `HandoverOpen`, `HandoverConfirmed` |

`AssetState` and `RentPhase` are public because `resolve_state` returns `AssetState`
in its public signature. External callers must be able to pattern-match on the result.
The state machine logic that mutates them remains private.

**`RentalEscrow` fields:**
- `id: UID`
- `asset: Asset`
- `config: IntegrationConfig`
- `state: AssetState`
- `last_rent_price: u64`
- `phase_start_ms: u64`
- `current_tenant_cap_id: Option<ID>`
- `current_tenant_address: Option<address>`
- `pending_tenant_cap_id: Option<ID>`
- `pending_tenant_address: Option<address>`
- `pending_bid: Balance<CoinType>`
- `handover_countdown_expiry: Option<u64>`
- `tenant_stake: Balance<CoinType>`
- `retire_flag: bool`
- `integrated_at_ms: u64`

**Public API:**

| Function | Visibility | Objects required | Summary |
|---|---|---|---|
| `integrate` | `public` | — | Creates RentalEscrow + IntegratorTreasury + ProtocolTreasury (all shared). Returns `OwnerCap`. |
| `rent` | `public` | RentalEscrow | Pay exactly `min_rent_price`. Mint `TenantCap`. Enter Rented. |
| `takeover` | `public` | RentalEscrow | Pay exactly `next_rent_price`. Stores `pending_tenant_address`. Does NOT mint `TenantCap` (lazy minting). Computes `handover_countdown_expiry`. |
| `rent_auction` | `public` | RentalEscrow | Pay current descent price. Mint `TenantCap`. Enter Rented. |
| `borrow_asset` | `public` | RentalEscrow | Extract asset + `AssetReceipt`. Requires current `TenantCap`. |
| `return_asset` | `public` | RentalEscrow | Consume `AssetReceipt`, return asset to escrow. |
| `retire` | `public` | RentalEscrow | Requires `OwnerCap`. Initiates retirement — sets `retire_flag`, blocks new bids. Never returns asset. Valid from any non-Retired state after `retire_floor` elapsed. |
| `claim_asset` | `public` | RentalEscrow + IntegratorTreasury | Requires `OwnerCap`. Finalizes retirement — state must be `Retired`. In order: sweeps any remaining `IntegratorTreasury.earnings` to caller, deletes `IntegratorTreasury`, burns `OwnerCap`, deletes `RentalEscrow`, returns asset. No orphaned objects. No locked funds. |
| `execute_handover` | `public` | RentalEscrow + IntegratorTreasury + ProtocolTreasury | Permissionless. Time-gated: aborts if `handover_countdown_expiry` not yet passed. Executes the handover in strict order: (1) push `remain_credit` to `current_tenant_address`, (2) deposit `used_credit` splits into IntegratorTreasury and ProtocolTreasury, (3) mint `TenantCap` and push to `pending_tenant_address`, (4) rotate addresses and cap IDs, (5) move `pending_bid` → `tenant_stake`, (6) set `phase_start_ms = handover_countdown_expiry`. Pushes before rotations — invariant. Natural actor: new tenant (wants cap) or displaced tenant (wants remain_credit). |
| `resolve_state` | `public` | RentalEscrow (read) | Pure read. Derives current logical state from anchors + clock. |

`withdraw_earnings` → `integrator_treasury::withdraw` (on `IntegratorTreasury`)
`withdraw_treasury` → `protocol_treasury::withdraw` (on `ProtocolTreasury`)

**Status:** [ ] `integrate` · [ ] `rent` · [ ] `takeover` · [ ] `rent_auction` · [ ] `execute_handover` · [ ] `borrow_asset` · [ ] `return_asset` · [ ] `retire` · [ ] `claim_asset` · [ ] `resolve_state`

**Internal functions (private):**

| Function | Objects mutated | Purpose |
|---|---|---|
| `execute_handover` | RentalEscrow + IntegratorTreasury + ProtocolTreasury | Rotate cap IDs. Push `remain_credit` to displaced tenant. Split `used_credit` via `deposit()`. Move `pending_bid` → `tenant_stake`. |
| `execute_tenure_expiry` | RentalEscrow + IntegratorTreasury + ProtocolTreasury | Split full `tenant_stake` via `deposit()`. Transition to `AtDutchAuction` or `Retired`. |
| `execute_auction_expiry` | RentalEscrow | Transition to `Idle`. No funds to move. |
| `split_fee` | — | Pure: splits amount into (95%, 5%) tuple. |

**Depends on:** `math`, `curve`, `config`, `owner_cap`, `tenant_cap`, `events`, `admin`, `integrator_treasury`, `protocol_treasury`.

---

## State Resolution

`resolve_state` is the single point of truth for the current logical state of any escrow.

**Signature:** `public fun resolve_state<A, C>(escrow: &RentalEscrow<A, C>, clock: &Clock): AssetState`

**Sole responsibility:** derive the current logical state from the stored phase anchors,
the immutable config, and the current timestamp. Nothing else.

No mutation. No fund movement. No side effects.

**Derivation logic** (boundaries evaluated in order against `clock::timestamp_ms(clock)`):

1. Stored state `Rented(HandoverConfirmed)` + `handover_countdown_expiry` passed
   → returns `Rented(HandoverOpen)`. Continues to next check.
2. Logical state `Rented` + `phase_start_ms + tenure_ceiling` passed
   → if `retire_flag`: returns `Retired`.
   → else: returns `AtDutchAuction`.
3. Logical state `AtDutchAuction` + `phase_start_ms + descent_ceiling` passed
   → returns `Idle`.

At most 3 boundaries evaluated per call.

**How public functions use it:**

Each public function calls `resolve_state` first to know the current state,
asserts its own pre-condition against the result, then calls the appropriate
private `execute_*` helpers to apply any elapsed transitions before performing
its own mutation. `resolve_state` never triggers those helpers — that is the
caller's responsibility.

**Off-chain use:**

Takes only immutable references. Can be called via `devInspectTransactionBlock`
with no gas cost. Frontend and indexers derive the current state without
replicating the state machine logic off-chain.

---

## Fund Flows

### Tenant stake lifecycle

Payment enters as `Coin<CoinType>` → split exact amount → `Balance` in `RentalEscrow.tenant_stake`.
At handover: split into `used_credit` + `remain_credit`.
`remain_credit` → pushed immediately to displaced tenant as `Coin`.
`used_credit` → split 95/5 → deposited into `IntegratorTreasury` and `ProtocolTreasury`.

### Pending bid lifecycle

Incoming bid enters as `Coin<CoinType>` → `Balance` in `RentalEscrow.pending_bid`.
If superseded: refunded immediately as `Coin` (push to registered address).
At handover: becomes new `tenant_stake`.

### Integrator earnings lifecycle

Accumulated via `IntegratorTreasury::deposit()` at each handover and tenure expiry (95% share).
Withdrawn by owner via `IntegratorTreasury::withdraw()` → `Coin` (pull, requires `OwnerCap`).
Never touches `RentalEscrow` — fully decoupled.

### Protocol fee lifecycle

Accumulated via `ProtocolTreasury::deposit()` at each handover and tenure expiry (5% share).
Per-asset instance — no cross-escrow contention.
Withdrawn by admin via `ProtocolTreasury::withdraw()` → `Coin` (pull, requires `ProtocolAdminCap`).
Admin batches withdrawals across all instances in a single PTB.

---

## Notes

- All timestamps in milliseconds (`sui::clock::Clock::timestamp_ms`).
- All prices in base token units (no decimals at protocol level).
- Asset requires `key + store` abilities to live inside `RentalEscrow`.
- `integrate()` creates and shares 3 objects atomically: `RentalEscrow`, `IntegratorTreasury`, `ProtocolTreasury`.
- `asset: Asset` — the asset is always present while the escrow exists. There is no valid persistent state where the escrow exists without the asset. `claim_asset()` extracts the asset and deletes the escrow atomically. The PTB borrow mechanism (`borrow_asset`/`return_asset`) is an implementation detail — the temporary extraction never persists across transaction boundaries.
- Fund flows are asymmetric: owner and admin pull from their own objects; tenants receive pushes to the address registered at mint time.
- Stale `TenantCap` objects in a wallet are inert — they fail the ID check. `burn(cap)` is available for gas recovery.
- Maximum nesting depth for `OwnerCap` as asset: 2. Integration is rejected if the asset being integrated is an `OwnerCap` whose own escrow asset is also an `OwnerCap`.
- `ProtocolTreasury` is per-asset (not global) to avoid cross-escrow contention on boundary transitions.
- Object discovery: `AssetIntegrated` includes `integrator_treasury_id` and `protocol_treasury_id` so off-chain consumers can track all instances from events. Sui RPC (`suix_queryObjects` by type) serves as a bootstrap fallback.

---

## File Layout

```
sources/
    math.move                §1  — pure arithmetic
    curve.move               §2  — shape + price function types and evaluation
    config.move              §3  — IntegrationConfig struct + validation
    owner_cap.move           §4  — OwnerCap object
    tenant_cap.move          §5  — TenantCap + AssetReceipt objects
    events.move              §6  — event structs + emit helpers
    admin.move               §7  — ProtocolAdminCap + init (OTW)
    integrator_treasury.move   §8  — IntegratorTreasury shared object + withdraw
    protocol_treasury.move   §9  — ProtocolTreasury shared object + withdraw
    rental_escrow.move       §10 — RentalEscrow shared object + full public API
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

### Three shared objects per instance

`RentalEscrow`, `IntegratorTreasury`, and `ProtocolTreasury` are separate shared objects
grouped by function access pattern. `withdraw_earnings` and `withdraw_treasury` only
touch their respective objects — they never contend with rental operations on
`RentalEscrow`. Boundary transitions (handover, tenure expiry) touch all three, but
those transactions are already serialized by `RentalEscrow`, so no new contention
is introduced within that group.

### ProtocolTreasury per-asset, not global

A single global `ProtocolTreasury` would cause boundary transitions from different
escrow instances to contend on it. Per-asset instances eliminate cross-escrow
contention entirely. The admin collects fees across all instances in a single PTB
by calling `ProtocolTreasury::withdraw()` on each and merging the coins.

### Why `resolve_state` is public

The protocol is deterministic and lazy — state is always derivable from
`(immutable_params, phase_anchors, clock)`. Making `resolve_state` public
with only immutable references allows off-chain consumers to call it via
`devInspectTransactionBlock` without gas. Frontend and indexers derive current
state without replicating the state machine. Internal public functions use
the same function to determine state before acting.

### Why `AssetState` and `RentPhase` live inside `rental_escrow`

`AssetState` and `RentPhase` are public types defined in `rental_escrow` because
`resolve_state` returns `AssetState` in its public signature — external callers
must be able to pattern-match on the result.

They still live in `rental_escrow` rather than a separate module because no other
module needs to construct or own them. Extracting them would create a module with
no independent responsibility whose sole consumer remains `rental_escrow`.
The state machine logic that mutates them stays private to the module.

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

### Lazy minting of TenantCap and execute_handover

`TenantCap` is minted only when someone actually becomes the current tenant —
not at bid time. `takeover()` stores `pending_tenant_address` but mints nothing.

This eliminates the entire class of orphaned caps from superseded bidders.
The only unavoidable orphan is one per completed handover: the displaced tenant's
cap, whose storage cost they paid themselves and whose rebate is theirs to claim.

`execute_handover()` is the permissionless function that triggers the handover
execution and delivers the `TenantCap` to the winner via push. Two incentivized
actors exist: the new tenant (wants cap and access) and the displaced tenant
(wants remain_credit). Either can trigger it. No cooperative dependency between
them — the displaced tenant receives remain_credit as a push regardless of who
calls the function.

**Push ordering invariant:** balances are pushed before addresses are rotated.
`remain_credit` goes to `current_tenant_address` before that field is overwritten.
`TenantCap` is pushed to `pending_tenant_address` before that field is cleared.

**TenantCap as signal:** the cap appearing in the wallet is the clearest possible
notification of tenancy. No indexer query, no event subscription needed —
the object in the wallet says everything.

**Edge case — both actors inactive:** if neither actor calls `execute_handover()`
and the new tenant's tenure expires, `resolve_state()` correctly derives the full
lazy chain (handover → tenure expiry → AtDutchAuction). The next actor to touch
the escrow (a new renter, owner calling retire) triggers execution. No funds are
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
`claim_asset()` always does — and in the same call: sweeps any remaining earnings
from `IntegratorTreasury` to the owner, deletes `IntegratorTreasury`, burns
`OwnerCap`, and deletes `RentalEscrow`. Taking advantage of the owner already
being present to leave no orphaned objects and no locked funds.

`ProtocolTreasury` is not included — `ProtocolAdminCap` is never burned, so the
admin can drain it independently before or after retirement.

### Why `rent_auction` is a separate function from `rent`

`rent` operates from Idle — no prior state beyond a possible auction expiry.
`rent_auction` operates from AtDutchAuction and must read the current descent
price from the clock. Different pre-conditions, different fund sources, different
events. A single function with mode branching would obscure the state machine.

---

## Implementation Order

Build bottom-up following the dependency graph:

```
1. math                  (leaf — no dependencies)
2. curve                 (depends on math)
3. config                (depends on curve)
4. owner_cap             (leaf)
5. tenant_cap            (leaf)
6. events                (leaf)
7. admin                 (leaf)
8. integrator_treasury     (depends on owner_cap)
9. protocol_treasury     (depends on admin)
10. rental_escrow        (depends on all above)
```

Steps 4–7 are independent of each other and of steps 1–3.
Steps 8 and 9 are independent of each other.
