# Module Map — Sui Move Implementation

Single reference for implementation design.
For protocol rationale and incentive analysis see `design-compact.md`.

**Status key:** `[ ]` pending · `[~]` speccing · `[x]` specced · `[*]` coded

---

## Object Model

```
 OWNER'S WALLET                        TENANT'S WALLET (current / pending)
 ┌───────────────────┐                 ┌──────────────────────┐
 │    OwnerCap       │                 │      TenantCap        │
 │   · escrow_id: ID │                 │   · escrow_id: ID     │
 └─────────┬─────────┘                 └──────────┬────────────┘
           │                                       │
           │ retire()                               │ borrow_asset()
           │ withdraw_earnings()                    │
           ▼                                       ▼
╔══════════════════════════════════════════════════════════════════════╗
║  RentalEscrow<Asset, CoinType>            [SHARED OBJECT]           ║
║                                                                      ║
║  ┌────────────────────────┐  ┌──────────────────────────────────┐  ║
║  │  Asset (key + store)   │  │  IntegrationConfig  (immutable)  │  ║
║  │                        │  │  · min_rent_price                │  ║
║  │  ← lives here always   │  │  · tenure_ceiling                │  ║
║  │    except during a PTB │  │  · handover_floor                │  ║
║  │    borrow (see below)  │  │  · descent_ceiling               │  ║
║  └────────────────────────┘  │  · retire_floor                  │  ║
║                               │  · CurveShape g  (credit)       │  ║
║  ┌────────────────────────┐  │  · CurveShape h  (descent)       │  ║
║  │  AssetState            │  │  · PriceFunction                 │  ║
║  │  Idle                  │  └──────────────────────────────────┘  ║
║  │  Rented                │                                         ║
║  │    HandoverOpen        │  ┌───────────────────────────────────┐ ║
║  │    HandoverConfirmed   │  │  Phase anchors                    │ ║
║  │  AtDutchAuction        │  │  · last_rent_price: u64           │ ║
║  │  Retired               │  │  · phase_start_ms: u64            │ ║
║  └────────────────────────┘  │  · handover_countdown_expiry      │ ║
║                               │  · current_tenant_cap_id         │ ║
║  ┌──────────────────┐         │  · pending_tenant_cap_id         │ ║
║  │  tenant_stake    │         └───────────────────────────────────┘ ║
║  │  Balance<C>      │                                               ║
║  └──────────────────┘         ┌───────────────────────────────────┐ ║
║  ┌──────────────────┐         │  Flags                            │ ║
║  │  pending_bid     │         │  · retire_flag: bool              │ ║
║  │  Balance<C>      │         │  · integrated_at_ms: u64          │ ║
║  └──────────────────┘         └───────────────────────────────────┘ ║
║  ┌──────────────────┐                                               ║
║  │  owner_earnings  │                                               ║
║  │  Balance<C>      │                                               ║
║  └──────────────────┘                                               ║
║  ┌──────────────────┐                                               ║
║  │ protocol_treasury│                                               ║
║  │  Balance<C>      │                                               ║
║  └──────────────────┘                                               ║
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
 rent() / rent_auction()  →  Coin<C>           →  tenant_stake
 takeover()               →  Coin<C>           →  pending_bid
   (if superseded)        ←  Coin<C>           ←  pending_bid  (refund, push)
 handover fires           :  pending_bid       →  tenant_stake (new tenant)
                          :  used_credit×0.95  →  owner_earnings
                          :  used_credit×0.05  →  protocol_treasury
                          ←  Coin<C>           ←  remain_credit (to old tenant, push)
 tenure expiry            :  stake×0.95        →  owner_earnings
                          :  stake×0.05        →  protocol_treasury
 withdraw_earnings()      ←  Coin<C>           ←  owner_earnings  (pull)
 withdraw_treasury()      ←  Coin<C>           ←  protocol_treasury  (pull)
 retire()                 ←  Asset             ←  escrow (unwrapped, deleted)
```

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

**Status:** [ ] all event structs · [ ] all `emit_*` helpers

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

**Status:** [ ] `ADMIN` OTW · [ ] `ProtocolAdminCap` · [ ] `init` · [ ] `assert_admin`

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
| `resolve_state` | `public` | — | Pure read. Derives current logical state from anchors + clock. See §State Resolution. |

**Status:** [ ] `integrate` · [ ] `rent` · [ ] `takeover` · [ ] `rent_auction` · [ ] `borrow_asset` · [ ] `return_asset` · [ ] `retire` · [ ] `withdraw_earnings` · [ ] `withdraw_treasury` · [ ] `resolve_state`

**Internal functions (private):**

| Function | Purpose |
|---|---|
| `execute_handover` | Distributes funds at handover boundary. Rotates cap IDs. Pushes `remain_credit` to displaced tenant. |
| `execute_tenure_expiry` | Distributes full `tenant_stake` at tenure boundary. Transitions to `AtDutchAuction` or `Retired`. |
| `execute_auction_expiry` | Transitions to `Idle`. No funds to move. |
| `split_fee` | Splits an amount into owner (95%) and treasury (5%). |

**Depends on:** `math`, `curve`, `config`, `owner_cap`, `tenant_cap`, `events`, `admin`.

---

## State Resolution

`resolve_state` is the single point of truth for the current logical state of any escrow.

**Signature:** `public fun resolve_state<A, C>(escrow: &RentalEscrow<A, C>, clock: &Clock): AssetState`

Pure derivation from phase anchors and the clock. No mutation, no fund movement, no side effects.

**Derivation logic** (boundaries evaluated in order):

1. If stored state is `Rented(HandoverConfirmed)` and `handover_countdown_expiry` has passed:
   → logical state advances to `Rented(HandoverOpen)` for the pending tenant.
   → continue to check tenure boundary.
2. If logical state is `Rented` and `phase_start_ms + tenure_ceiling` has passed:
   → if `retire_flag`: → `Retired`.
   → else: → `AtDutchAuction`.
3. If logical state is `AtDutchAuction` and `phase_start_ms + descent_ceiling` has passed:
   → `Idle`.

At most 3 boundaries evaluated per call.

**How public functions use it:**

Each public function that reads or mutates state calls `resolve_state` first to derive
the current logical state, asserts its pre-condition, then calls the appropriate
`execute_*` helpers to apply any elapsed transitions before performing its own operation.
The protocol is fully deterministic — incentivized actors (tenants, owners, new renters)
drive all state advancement. No keeper required.

**Off-chain use:**

Because `resolve_state` takes only immutable references, it can be called via
`devInspectTransactionBlock` with no gas cost. Frontend and indexers can derive
the current state without replicating the state machine logic off-chain.

---

## Fund Flows

### Tenant stake lifecycle

Payment enters as `Coin<CoinType>` → split exact amount → `Balance` in `tenant_stake`.
At handover: split into `used_credit` + `remain_credit`.
`remain_credit` → pushed immediately to displaced tenant as `Coin`.
`used_credit` → split into `owner_earnings` (95%) and `protocol_treasury` (5%).

### Pending bid lifecycle

Incoming bid enters as `Coin<CoinType>` → `Balance` in `pending_bid`.
If superseded: refunded immediately as `Coin` (push to registered address).
At handover: becomes new `tenant_stake`.

### Owner earnings lifecycle

Accumulated from `used_credit × 0.95` at each handover and tenure expiry.
Held as `Balance<CoinType>` inside escrow.
Withdrawn by owner via `withdraw_earnings()` → `Coin` (pull, requires `OwnerCap`).

### Protocol treasury lifecycle

Accumulated from `used_credit × 0.05` at each handover and tenure expiry.
Held as `Balance<CoinType>` inside each escrow instance.
Withdrawn by protocol admin via `withdraw_treasury()` with `ProtocolAdminCap` (pull).
Accumulates passively — no dependency on owner activity or `OwnerCap` state.

---

## Notes

- All timestamps in milliseconds (`sui::clock::Clock::timestamp_ms`).
- All prices in base token units (no decimals at protocol level).
- Asset requires `key + store` abilities to live inside the shared escrow object.
- `CoinType` is constrained via `Balance<CoinType>` (Coin framework).
- `handover_countdown_expiry` is deterministic: `t_bid + min(handover_floor, remaining_rent_time)`. No randomness.
- Fund flows are asymmetric: owner pulls (`OwnerCap`), tenants receive pushes to the address registered at mint time.
- Stale `TenantCap` objects in a wallet are inert — they fail the ID check. `burn(cap)` is available for gas recovery.
- Maximum nesting depth for `OwnerCap` as asset: 2. Integration is rejected if the asset being integrated is an `OwnerCap` whose own escrow asset is also an `OwnerCap`.

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

### Why `resolve_state` is public

The protocol is deterministic and lazy — state is always derivable from
`(immutable_params, phase_anchors, clock)`. Making `resolve_state` public
with only immutable references allows off-chain consumers to call it via
`devInspectTransactionBlock` without gas. Frontend and indexers derive current
state without replicating the state machine. Internal public functions use
the same function to determine state before acting.

### Why `AssetState` and `RentPhase` live inside `rental_escrow`

`AssetState` and `RentPhase` are internal to the escrow's state machine.
They never appear in any public function signature — no external module needs to
construct, pattern-match, or hold them. Extracting them would create a module
with no public API whose sole consumer is `rental_escrow`. They stay private.

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

### Why `rent_auction` is a separate function from `rent`

`rent` operates from Idle — no prior state beyond a possible auction expiry.
`rent_auction` operates from AtDutchAuction and must read the current descent
price from the clock. Different pre-conditions, different fund sources, different
events. A single function with mode branching would obscure the state machine.

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
They can be specced and implemented in any order or in parallel.
