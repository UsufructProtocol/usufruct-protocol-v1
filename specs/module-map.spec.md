# Module Map — Sui Move Implementation

Authoritative map of every module in the `liquid_renting` package.
Derived from the design compact, implementation inventory, and
Sui Move best-practice guidelines (one module = one object / one responsibility).

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
       \          |          /        /
        \         |         /        /
         v        v        v        v
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
- `CurveShape`: PowerLaw requires `alpha_num > 0, alpha_den > 0`.
- `PriceFunction`: FixedDelta requires `delta > 0`; Percentage requires `bps > 0`; CompoundDelta requires `bps > 0 \|\| delta > 0`.

**Depends on:** `math`.

---

### 3. `config.move` — Integration configuration

**Responsibility:** `IntegrationConfig` struct and its validated constructor.
Bundles all immutable parameters set once at integration time.
No UID, no object identity — this is a plain data struct embedded inside `RentalEscrow`.

**Types:**

| Type | Abilities |
|---|---|
| `IntegrationConfig` | `store` |

**Fields:**
- `min_rent_price: u64`
- `tenure_ceiling: u64`
- `handover_floor: u64`
- `descent_ceiling: u64`
- `retire_floor: u64`
- `credit_curve: CurveShape`
- `descent_curve: CurveShape`
- `price_function: PriceFunction`

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

**Depends on:** `curve` (owns `CurveShape`, `PriceFunction`).

---

### 4. `owner_cap.move` — Owner capability

**Responsibility:** `OwnerCap` object. One per integration instance.
Proves authority for `retire()` and `withdraw_earnings()`.

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
| `new(escrow_id, ctx): TenantCap` | `public(package)` | Mint. Called by `rental_escrow::{rent, takeover}`. |
| `burn(cap)` | `public` | Voluntary destroy for gas recovery. No state mutation. |
| `escrow_id(cap): ID` | `public` | Getter. |
| `new_receipt(escrow_id): AssetReceipt` | `public(package)` | Create hot potato. Called by `rental_escrow::borrow_asset`. |
| `consume_receipt(receipt, escrow_id)` | `public(package)` | Destroy receipt. Aborts if `receipt.escrow_id != escrow_id`. |

**Depends on:** nothing (only `sui::object`).

---

### 6. `events.move` — Protocol events

**Responsibility:** Event struct definitions and package-scoped emit helpers.
No logic, no state. Pure data carriers.

**Types (all `copy, drop`):**

| Event | Key Fields |
|---|---|
| `AssetIntegrated` | `escrow_id, owner_cap_id, min_rent_price, tenure_ceiling` |
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

**Depends on:** nothing (only `sui::event`).

---

### 7. `admin.move` — Protocol administration

**Responsibility:** `ProtocolAdminCap` and the package `init` function.
Created once at publish time via one-time witness (OTW) pattern.
Required for `withdraw_treasury`.

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
| `AssetState` | `copy, drop, store` | Enum: `Idle`, `Rented { phase: RentPhase }`, `AtDutchAuction`, `Retired` |
| `RentPhase` | `copy, drop, store` | Enum: `HandoverOpen`, `HandoverConfirmed` |

`AssetState` and `RentPhase` are internal to this module. They are never exposed
in public function signatures — external code only interacts through the public API.

**`RentalEscrow` fields:**
- `id: UID`
- `asset: Option<Asset>` (None only during PTB borrow)
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
- `owner_earnings: Balance<CoinType>`
- `protocol_treasury: Balance<CoinType>`
- `retire_flag: bool`
- `integrated_at_ms: u64`

**Public API:**

| Function | Visibility | State pre-condition | Summary |
|---|---|---|---|
| `integrate` | `public` | — | Wrap asset, create shared escrow, return `OwnerCap`. |
| `rent` | `public` | Idle | Pay exactly `min_rent_price`. Mint `TenantCap` (transferred to sender). Enter Rented. |
| `takeover` | `public` | Rented, `!retire_flag` | Pay exactly `next_rent_price`. Mint `TenantCap`. Compute/update handover. |
| `rent_auction` | `public` | AtDutchAuction | Pay current descent price. Mint `TenantCap`. Enter Rented. |
| `borrow_asset` | `public` | Rented (current tenant) | Extract asset + `AssetReceipt`. |
| `return_asset` | `public` | — | Consume `AssetReceipt`, return asset to escrow. |
| `retire` | `public` | See design §6 | Consumes `OwnerCap`. Behavior depends on state. |
| `withdraw_earnings` | `public` | Any (owner pull) | Drain `owner_earnings` → `Coin`. Requires `OwnerCap`. |
| `withdraw_treasury` | `public` | Any (admin pull) | Drain `protocol_treasury` → `Coin`. Requires `ProtocolAdminCap`. |
| `burn_tenant_cap` | — | — | Delegated to `tenant_cap::burn` (re-exported or called directly by user). |

**Internal functions (private):**

| Function | Purpose |
|---|---|
| `resolve_state` | Lazy evaluation engine. Resolves up to 3 elapsed transitions. Called first by every public function that reads/mutates state. |
| `execute_handover` | Distributes funds at handover boundary. |
| `execute_tenure_expiry` | Distributes funds at tenure expiry boundary. |
| `execute_auction_expiry` | Transitions to Idle. |
| `split_fee` | Splits `used_credit` into owner (95%) and treasury (5%). |

**Depends on:** `math`, `curve`, `config`, `owner_cap`, `tenant_cap`, `events`, `admin`.

---

## File Layout

```
sources/
    math.move               §1  — pure arithmetic
    curve.move              §2  — shape + price function types and evaluation
    config.move             §3  — IntegrationConfig struct + validation
    owner_cap.move          §4  — OwnerCap object
    tenant_cap.move         §5  — TenantCap + AssetReceipt objects
    events.move             §6  — event structs + emit helpers
    admin.move              §7  — ProtocolAdminCap + init (OTW)
    rental_escrow.move      §8  — RentalEscrow shared object + full public API
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

### Why `AssetState` and `RentPhase` live inside `rental_escrow`

The best practice says "a variant structure should have its own module."
However, `AssetState` and `RentPhase` are *internal* to the escrow's state machine.
They never appear in any public function signature — no external module needs to
construct, pattern-match, or hold them. Extracting them would create a module
with no public API whose sole consumer is `rental_escrow`, adding indirection
without reducing complexity. They stay private.

### Why `OwnerCap` and `TenantCap` are separate modules

Each is an independent Sui object with its own lifecycle, abilities, and
authorization semantics. The escrow mints and burns them via `public(package)`
functions. Separating them:
- Makes abilities and transfer rules immediately visible from the type definition.
- Prevents the escrow module from growing beyond readable size.
- Follows the one-module-one-object principle for objects that *do* leave the module.

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

### Why `rent_auction` is a separate function from `rent`

`rent` operates from Idle (no prior state, no lazy transitions beyond auction expiry).
`rent_auction` operates from AtDutchAuction (must read current descent price from
the clock). Different pre-conditions, different fund sources, different events.
A single function with mode branching would obscure the state machine.

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

Steps 4-7 are independent of each other and of steps 1-3.
They can be specced and implemented in any order or in parallel.
