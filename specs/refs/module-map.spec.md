# Module Map — Sui Move Implementation

Single reference for implementation design.
For protocol rationale and incentive analysis see `design-compact.md`.

**Status key:** `[ ]` pending · `[~]` speccing · `[x]` specced · `[*]` coded

---

## Object Model

One shared object per asset instance (`RentalEscrow`). At publish time, `init`
creates two singletons: `ProtocolFeeInbox` (owned by deployer — fee inbox) and
`ProtocolFeeRef` (frozen — immutable pointer to the inbox's ID, accessible
by any PTB without consensus).
At each boundary event (handover, tenure expiry), `send_fee()` creates a
`FeeMessage<C>` and transfers it to `ProtocolFeeInbox` via transfer-to-object
(free, no contention on the inbox). The admin drains all messages via
`collect_fee_messages`, presenting `&mut ProtocolFeeInbox` — owned object, fastpath,
no consensus. All other operations stay on the single escrow object.

```
 ADMIN'S WALLET
 ┌─────────────────────────────────────────────┐
 │   ProtocolFeeInbox              [OWNED]      │
 │   · fee inbox (child objects accumulate here)│
 │   collect_fee_messages()                       │
 └──────────────────────┬──────────────────────┘
                        │ (child objects, one per boundary event with non-zero fees)
                        │ transfer-to-object — free, no contention on FeeInbox
╔══════════════════════════════════════════════════════════════════════╗
║  FeeMessage<CoinType>                [OWNED by ProtocolFeeInbox]    ║
║                                                                      ║
║  ┌──────────────────┐  Created by send_fee() inside do_handover()  ║
║  │  balance         │  and do_tenure_expiry(). Transferred to      ║
║  │  Balance<C>      │  ProtocolFeeInbox as child.                  ║
║  └──────────────────┘  Deleted by collect_fee_messages().            ║
║                         traceability via events.                     ║
╚══════════════════════════════════════════════════════════════════════╝

 [FROZEN — singleton]
 ┌──────────────────────────────────────────────┐
 │   ProtocolFeeRef                             │
 │   · inbox_id: ID  ← ID of FeeInbox          │
 │   Immutable. Accessible without consensus.   │
 │   Passed to integrate() by any integrator.   │
 └──────────────────────────────────────────────┘

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
║  │  Balance<C>      │         │  Flags + routing                  │ ║
║  └──────────────────┘         │  · retire_flag: bool              │ ║
║  ┌──────────────────┐         │  · integrated_at_ms: u64          │ ║
║  │  owner_earnings  │         │  · fee_inbox_id: ID               │ ║
║  │  Balance<C>      │         └───────────────────────────────────┘ ║
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
 rent() [Idle]              →  Coin<C> (== min_rent_price)       →  tenant_stake
 rent() [AtDutchAuction]    →  Coin<C> (>= price_descent(now))  →  tenant_stake  (full amount, no refund)
 rent() [Rented]            →  Coin<C> (== next_rent_price)      →  pending_bid
   (if superseded)          ←  Coin<C>  ←  pending_bid  (refund, push)

 apply_pending_transitions() — handover fires:
   pending_bid              →  tenant_stake  (new tenant)
   used_credit × 0.95       →  owner_earnings
   used_credit × 0.05       →  FeeMessage<C>  →  transfer-to-object  →  fee_inbox_id
   remain_credit            ←  Coin<C>  (push to current_tenant_address)

 apply_pending_transitions() — tenure expiry:
   tenant_stake × 0.95      →  owner_earnings
   tenant_stake × 0.05      →  FeeMessage<C>  →  transfer-to-object  →  fee_inbox_id

 withdraw_earnings()        ←  Coin<C>  ←  owner_earnings                   (pull, OwnerCap)
 retire()                   —  sets retire_flag only, no asset movement
 claim_asset()              ←  Coin<C>  ←  owner_earnings (sweep)
                            ←  Asset    ←  RentalEscrow (unwrapped, deleted)
 collect_fee_messages<C>()    ←  Coin<C>  ←  FeeMessage<C>[]                  (&mut ProtocolFeeInbox, fastpath, deleted, one call per CoinType)
```

---

## Contention Map

One shared object per asset for all normal operations. Admin operations use owned
objects — fastpath, no consensus.

| Operation | Contention |
|---|---|
| `rent`, `retire`, `borrow_asset`, `apply_pending_transitions` | serial on RentalEscrow |
| `return_asset` | serial on RentalEscrow |
| `withdraw_earnings` | serial on RentalEscrow |
| `integrate` | serial on RentalEscrow · read `ProtocolFeeRef` (frozen — no consensus) |
| `claim_asset` | serial on RentalEscrow only — transfer-to-object does not touch `ProtocolFeeInbox` |
| `collect_fee_messages<C>` | owned `ProtocolFeeInbox` only — fastpath, no consensus, one call per CoinType |
| `current_state`, `compute_used_credit`, `compute_price_descent`, `current_next_rent_price` | read-only (`&RentalEscrow`) — no contention |

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
     ^    ^
     |    |
 curve_shape  price_function
          \        /
           \      /
            \    /
             \  /
              \/
           config    owner_cap    tenant_cap    protocol_fee_inbox
               ^          ^            ^              ^
                \         |            |              |
                 \        |            |    fee_message
                  \       |            |              ^
                   \      |            |             /
                                    rental_escrow
```

Arrows point from dependency to dependent.
`rental_escrow` is the integration point; every other module is independent of it.
`rental_escrow` also imports `protocol_fee_inbox` directly (for `ProtocolFeeRef` in
`integrate`) in addition to `fee_message`.

**Events:** there is no standalone `events` module. Each module owns its own
observability — event structs are defined in the module that emits them.
All protocol state-machine events live in `rental_escrow`. Cap lifecycle events
(`TenantCapMinted`, `TenantCapBurned`, `OwnerCapMinted`, `OwnerCapBurned`) live in
`tenant_cap` and `owner_cap` respectively. Fee events live in `fee_message`.
This follows the idiomatic Sui Move pattern: the Sui Verifier requires the emitted
type to be internal to the module calling `event::emit`.

---

## Modules

### 1. `math.move` — Fixed-point arithmetic primitives

**Responsibility:** Pure integer math with u128 intermediates.
No protocol types, no objects, no Sui framework dependencies.

**Constants (public):**

| Symbol | Type | Value | Purpose |
|---|---|---|---|
| `TAYLOR_SCALE` | `u128` | `10^18` | Fixed-point denominator for `exp_scaled` results. Used by `curve_shape` to interpret them. |
| `TAYLOR_SCALE_SQ` | `u128` | `10^36` | `TAYLOR_SCALE²`. Used by `curve_shape` for the `exp_scaled` negative path. |
| `E_MUL_DIV_OVERFLOW` | `u64` | `0` | Abort code when `mul_div` result overflows u64. |

**Exports (public):**

| Function | Signature | Purpose |
|---|---|---|
| `mul_div` | `(a: u64, b: u64, c: u64): u64` | `floor(a * b / c)` via u128, overflow-safe. |
| `nth_root_u128` | `(n: u128, d: u32): u128` | `floor(n^(1/d))` via Newton-Raphson. Used by `curve_shape` for the PowerLaw variant. `d ∈ {2, 3, 4}`. |
| `exp_scaled` | `(y_num: u64, y_den: u64, neg: bool): u128` | `floor(e^(y_num/y_den) · TAYLOR_SCALE)` with sign via `neg`. Used by `curve_shape` for the Exponential and Logistic variants. |

**Status:** [ ] `mul_div` · [ ] `nth_root_u128` · [ ] `exp_scaled`

**Depends on:** nothing.

---

### 2. `curve_shape.move` — Shape functions (CurveShape)

**Responsibility:** Defines the `CurveShape` enum type and evaluates normalized
shape functions. All functions are pure — no objects, no mutation, no Sui state.

**Types:**

| Type | Abilities | Variants |
|---|---|---|
| `CurveShape` | `copy, drop, store` | `Linear`, `Smoothstep`, `PowerLaw { alpha_num: u8, alpha_den: u8 }`, `Exponential { alpha_abs: u8, alpha_neg: bool }`, `Logistic` (no fields — k=12 fixed, `LOGISTIC_DENOM` precomputed as module constant) |

**Constants (module-level):**
- `SCALE: u64 = 1_000_000_000`
- `LOGISTIC_K: u64 = 12`
- `LOGISTIC_DENOM: u64` — algorithm-derived literal, established once at initial implementation

**Error constants (public):**
- `E_ALPHA_NUM_RANGE: u64 = 0`
- `E_ALPHA_DEN_RANGE: u64 = 1`
- `E_DEGENERATE_LINEAR: u64 = 2`
- `E_ALPHA_ABS_RANGE: u64 = 3`

**Constructors (`public`):** `new_linear()`, `new_smoothstep()`, `new_logistic()` — no validation. `new_power_law(alpha_num, alpha_den)` — validates `alpha_num ∈ [1, 8]`, `alpha_den ∈ {1, 2, 3, 4}`, `alpha_num != alpha_den`; normalizes by `gcd(alpha_num, alpha_den)`. `new_exponential(alpha_abs, alpha_neg)` — validates `alpha_abs ∈ [1, 8]`.

**Functions:**

| Function | Visibility | Signature | Purpose |
|---|---|---|---|
| `evaluate_curve` | `public(package)` | `(shape: &CurveShape, t: u64, t_max: u64): u64` | Evaluate normalized shape at `x = t/t_max`, result in `[0, SCALE]`. Short-circuits at `t == 0 → 0` and `t >= t_max → SCALE`. Protocol-level scaling (by `tenant_stake`, spread) is applied by `rental_escrow` callers. |

**Status:** [ ] `CurveShape` · [ ] `evaluate_curve`

**Depends on:** `math`.

---

### 3. `price_function.move` — Price escalation function (PriceFunction)

**Responsibility:** Defines the `PriceFunction` enum type and evaluates
`f_next_rent_price`. All functions are pure — no objects, no mutation, no Sui state.

**Types:**

| Type | Abilities | Variants |
|---|---|---|
| `PriceFunction` | `copy, drop, store` | `FixedDelta { delta: u64 }`, `CompoundDelta { bps: u64, delta: u64 }` |

Note: there is no standalone `Percentage` variant. Pure percentage behavior is expressed as `CompoundDelta { bps, delta: 1 }`.

**Error constants (public):**
- `E_FIXED_DELTA_ZERO: u64 = 0`
- `E_BPS_RANGE: u64 = 1`

**Constructors (`public`):** `new_fixed_delta(delta)` — validates `delta > 0`. `new_compound_delta(bps, delta)` — validates `bps ∈ [1, u64::MAX − 10000]`, `delta > 0`.

**Functions:**

| Function | Visibility | Signature | Purpose |
|---|---|---|---|
| `evaluate_price_fn` | private | `(price_fn: &PriceFunction, last_rent_price: u64): u64` | Dispatch on `PriceFunction` variant. Called only by `compute_next_rent_price`. |
| `compute_next_rent_price` | `public(package)` | `(price_fn: &PriceFunction, last_rent_price: u64): u64` | Thin wrapper over `evaluate_price_fn`. Result always `> last_rent_price`. |

**Status:** [ ] `PriceFunction` · [ ] `evaluate_price_fn` · [ ] `compute_next_rent_price`

**Depends on:** `math`.

---

### 4. `config.move` — Integration configuration

**Responsibility:** `IntegrationConfig` struct and its validated constructor.
Bundles all immutable parameters set once at integration time.
No UID, no object identity — plain data struct embedded inside `RentalEscrow`.

**Types:**

| Type | Abilities |
|---|---|
| `IntegrationConfig` | `copy, drop, store` |

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
| `new_config(min_rent_price, tenure_ceiling, handover_floor, descent_ceiling, retire_floor, credit_curve, descent_curve, price_function): IntegrationConfig` | Validates all constraints, aborts on violation |
| One `public(package)` getter per field | Immutable access for `rental_escrow` |

**Validation constraints (enforced in `new`):**
```
min_rent_price   > 0
tenure_ceiling   > 0
0 <= handover_floor <= tenure_ceiling
descent_ceiling  > 0
retire_floor     >= 0   (always true for u64)
```

**Status:** [ ] `IntegrationConfig` · [ ] `new` · [ ] getters

**Depends on:** `curve_shape`, `price_function`.

---

### 5. `owner_cap.move` — Owner capability

**Responsibility:** `OwnerCap` object. One per integration instance.
Proves authority for `retire()`, `claim_asset()`, and `withdraw_earnings()`.

**Types:**

| Type | Abilities | Notes |
|---|---|---|
| `OwnerCap` | `key, store` | Transferable. Satisfies the `Asset: key + store` bound and may itself be integrated as an asset. |

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

### 6. `tenant_cap.move` — Tenant capability and asset receipt

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
| `new(escrow_id, ctx): TenantCap` | `public(package)` | Mint. Called by `rental_escrow::install_new_tenant` (shared body of `rent()` Idle / AtDutchAuction) and `rental_escrow::do_handover` (handover completion). |
| `burn(cap)` | `public` | Voluntary destroy for gas recovery. No state mutation. |
| `escrow_id(cap): ID` | `public` | Getter. |

**Status:** [ ] `TenantCap` · [ ] `new` · [ ] `burn` · [ ] `escrow_id`

**Depends on:** nothing (only `sui::object`).

---

### 7. ~~`events.move`~~ — No standalone events module

Event structs live in the module that emits them. See **Events** note in the
dependency graph above. Protocol state-machine events are specified in
`rental_escrow.spec.md`. Cap lifecycle events in `owner_cap.spec.md` and
`tenant_cap.spec.md`. Fee events in `fee_message.spec.md`.

---

### 8. `protocol_fee_inbox.move` — Protocol fee inbox

**Responsibility:** `ProtocolFeeInbox` singleton and `ProtocolFeeRef` frozen pointer.
`ProtocolFeeInbox` is the transfer-to-object target for all `FeeMessage<C>` objects
created at boundary events. `ProtocolFeeRef` is a frozen, immutable pointer to the
inbox's ID — passed to `integrate` by any integrator without consensus overhead.

**Types:**

| Type | Abilities | Notes |
|---|---|---|
| `ProtocolFeeInbox` | `key, store` | Singleton. Transferable. Fee inbox. |
| `ProtocolFeeRef` | `key` | Frozen singleton. Immutable pointer to `ProtocolFeeInbox`. |

**Fields (`ProtocolFeeInbox`):**
- `id: UID`

**Fields (`ProtocolFeeRef`):**
- `id: UID`
- `inbox_id: ID`

**Exports:**

| Function | Visibility | Purpose |
|---|---|---|
| `init(ctx)` | private | Creates `ProtocolFeeInbox` (transfers to deployer) and `ProtocolFeeRef` (freezes). |
| `uid_mut(inbox): &mut UID` | `public(package)` | Exposes `&mut UID` for `transfer::receive` in `fee_message`. |
| `fee_ref_inbox_id(fee_ref): ID` | `public` | Returns `inbox_id`. Used by `rental_escrow::integrate`. |

**Status:** [x] `ProtocolFeeInbox` · [x] `ProtocolFeeRef` · [x] `init` · [x] `uid_mut` · [x] `fee_ref_inbox_id`

**Depends on:** nothing.

---

### 9. `fee_message.move` — Protocol fee message and drain

**Responsibility:** `FeeMessage<C>` per-boundary-event fee object, and all
fund-routing logic: `send_fee` creates and routes to the inbox at each boundary;
`collect_fee_messages` receives and drains. `transfer::receive` is restricted to this
module (`key` only type).

**Types:**

| Type | Abilities | Notes |
|---|---|---|
| `FeeMessage<phantom CoinType>` | `key` | Per-boundary-event. Transferred to `ProtocolFeeInbox` as child. Deleted at drain. |

**Fields (`FeeMessage`):**
- `id: UID`
- `balance: Balance<CoinType>`

**Exports:**

| Function | Visibility | Purpose |
|---|---|---|
| `send_fee<C>(balance, fee_inbox_id, ctx)` | `public(package)` | If `balance > 0`: creates `FeeMessage<C>`, transfers to `fee_inbox_id`. If `balance == 0`: destroys zero balance. Called by `do_handover` and `do_tenure_expiry` in `rental_escrow`. |
| `receive_message<C>(inbox, ticket)` | private | Receives one `FeeMessage<C>` from inbox via `transfer::receive`. |
| `consume_message<C>(msg)` | private | Destructures `FeeMessage<C>`, deletes UID, returns `Balance<C>`. |
| `collect_fee_messages<C>(inbox, tickets, ctx): Coin<C>` | `public` | Pipeline of `receive_message` + `consume_message`. Single pass O(n). Returns `Coin<C>`. Fastpath — no shared objects. One call per CoinType. |

**Status:** [x] `FeeMessage` · [x] `send_fee` · [x] `receive_message` · [x] `consume_message` · [x] `collect_fee_messages`

**Depends on:** `protocol_fee_inbox`.

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
- `retire_flag: bool`
- `integrated_at_ms: u64`
- `fee_inbox_id: ID` — ID of `ProtocolFeeInbox`. Registered at `integrate` via `ProtocolFeeRef`.

**Public API:**

| Function | Visibility | Summary |
|---|---|---|
| `integrate` | `public` | Creates and shares `RentalEscrow`. Accepts `&ProtocolFeeRef` (frozen, no consensus) — reads `fee_ref_inbox_id(fee_ref)` and stores it as `fee_inbox_id`. Returns `OwnerCap`. |
| `rent` | `public` | Single entry point to become tenant. Calls `apply_pending_transitions()` first, then applies sub-logic by state: **Idle** — pays `min_rent_price`, mints + pushes `TenantCap`. **AtDutchAuction** — pays `>= compute_price_descent(now)`. Full `coin.value` becomes `tenant_stake` — no refund. Accepts overpayment to handle latency between PTB construction and execution. Mints + pushes `TenantCap`. **Rented(HandoverOpen)** — pays `compute_next_rent_price()`, stores `pending_tenant_address`, sets `handover_countdown_expiry = min(clock.now() + handover_floor, phase_start_ms + tenure_ceiling)`. Aborts if `retire_flag` is set — no new bids accepted, current tenant runs to `tenure_ceiling`. **Rented(HandoverConfirmed)** — pays `compute_next_rent_price()`, refunds previous `pending_bid` (push), overwrites `pending_tenant_address`. `handover_countdown_expiry` is unchanged. `retire_flag` does not abort here — the pending bid is already committed; handover completes normally and T(n+1) enters `HandoverOpen` with the flag active (no new bids). **Retired** — aborts. |
| `borrow_asset` | `public` | Integration point between the protocol and the integrating ecosystem. Calls `apply_pending_transitions()` first. Verifies current `TenantCap`. Extracts asset, creates `AssetReceipt { escrow_id, asset_id: object::id(&asset) }` inline. The tenant holds the asset within the PTB and can pass it to any function in the integrating protocol — this is how usus and fructus are exercised. Asset must be returned in the same PTB via `return_asset()`. |
| `return_asset` | `public` | Consumes `AssetReceipt` inline. Verifies `receipt.escrow_id` matches the escrow and `receipt.asset_id` matches `object::id(&asset)`. Returns asset to escrow. No state resolution needed. |
| `retire` | `public` | Requires `OwnerCap`. Calls `apply_pending_transitions()` first. Sets `retire_flag`. Never returns asset. |
| `claim_asset` | `public` | Requires `OwnerCap`. Calls `apply_pending_transitions()` first. State must be `Retired`. Sweeps `owner_earnings` to caller as `Coin`. Burns `OwnerCap`, deletes `RentalEscrow`. Returns `(Asset, Coin<C>)`. |
| `withdraw_earnings` | `public` | Requires `OwnerCap`. Drains `owner_earnings` → `Coin`. No state resolution needed. |
| `apply_pending_transitions` | `public` | Permissionless settler. Executes all elapsed lazy transitions in order. Returns `AssetState` — the settled state after all transitions. Called internally by every public mutating function. Also callable directly by incentivized actors (frontend, bots) to advance state on-chain, credit pending earnings, and read the resulting state in one transaction. See §Pending Transitions. |
| `current_state` | `public` | `(escrow: &RentalEscrow, clock: &Clock): AssetState`. Read-only. Computes the settled state without mutating — free via `devInspectTransactionBlock`. Does not advance state on-chain. Use when the caller only needs to read state without paying gas. |
| `compute_used_credit` | `public` | `(escrow: &RentalEscrow, timestamp_ms: u64): u64`. Read-only query. Aborts `E_NOT_RENTED` if state is not `Rented`. Clamps `timestamp_ms` to `handover_countdown_expiry` if state is `HandoverConfirmed` — prevents showing used_credit beyond the boundary. Calls `curve_shape::evaluate_curve` and scales by `tenant_stake` with `math::mul_div`. |
| `compute_price_descent` | `public` | `(escrow: &RentalEscrow, timestamp_ms: u64): u64`. Read-only query. Aborts `E_NOT_AUCTION` if state is not `AtDutchAuction`. Calls `curve_shape::evaluate_curve` and descends from `last_rent_price` by the spread with `math::mul_div`. |
| `current_next_rent_price` | `public` | `(escrow: &RentalEscrow): u64`. Read-only query. Aborts `E_NOT_RENTED` if state is not `Rented`. Delegates to `price_function::compute_next_rent_price`. |

**Status:** [ ] `integrate` · [ ] `rent` · [ ] `borrow_asset` · [ ] `return_asset` · [ ] `retire` · [ ] `claim_asset` · [ ] `withdraw_earnings` · [ ] `apply_pending_transitions` · [ ] `current_state` · [ ] `compute_used_credit` · [ ] `compute_price_descent` · [ ] `current_next_rent_price`

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
| `do_handover` | Executes handover boundary: push `remain_credit`, split `used_credit` (95/5) into `owner_earnings` (95%) and `send_fee()` call (5% → `FeeMessage<C>` → transfer-to-object → `fee_inbox_id`), move `pending_bid` → `tenant_stake`, mint + push `TenantCap`, rotate addresses. Push-before-rotate invariant enforced here. |
| `do_tenure_expiry` | Executes tenure boundary: split full `tenant_stake` (95/5) into `owner_earnings` (95%) and `send_fee()` call (5% → `FeeMessage<C>` → transfer-to-object → `fee_inbox_id`). Transition to `AtDutchAuction` or `Retired`. |
| `do_auction_expiry` | Transition to `Idle`. No funds to move. |
| `split_fee` | Pure: splits an amount into (amount×0.95, amount×0.05) tuple. |
| `install_new_tenant` | Shared acquisition path for `rent()` Idle / AtDutchAuction arms: absorb payment into `tenant_stake`, anchor `phase_start_ms = clock.now()`, mint + push `TenantCap`, register addresses, transition to `Rented { HandoverOpen }`. Returns the new `TenantCap` ID so the caller emits `RentStarted` with its arm-specific `from_state`. |

**Depends on:** `math`, `curve_shape`, `price_function`, `config`, `owner_cap`, `tenant_cap`,
`protocol_fee_inbox`, `fee_message`.

---

## Pending Transitions

### `apply_pending_transitions` — private, called by every public mutating function

**Signature:** `public fun apply_pending_transitions<A, C>(escrow: &mut RentalEscrow<A, C>, clock: &Clock, ctx: &mut TxContext)`

**Sole responsibility:** execute every elapsed lazy transition — in order — before
any public function applies its own logic. This guarantees that `owner_earnings`
and protocol fees are never bypassed regardless of how long the escrow has
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
     // owner_earnings credited with used_credit × 0.95
     // FeeMessage<C> created and transferred to fee_inbox_id (used_credit × 0.05)
     // remain_credit pushed to displaced tenant

// Check 2 — tenure expired (reads state as mutated by check 1)
if escrow.state == Rented(...)
   && clock.now() >= escrow.phase_start_ms + config.tenure_ceiling:
     do_tenure_expiry(escrow, ctx)
     // escrow.state is now AtDutchAuction (or Retired if retire_flag)
     // owner_earnings credited with tenant_stake × 0.95
     // FeeMessage<C> created and transferred to fee_inbox_id (tenant_stake × 0.05)

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
`owner_earnings` (and push `FeeMessage<C>` objects to the inbox) without performing
a full protocol operation. Use cases:
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
`used_credit` → split 95/5 → `owner_earnings` (95%) and `FeeMessage<C>` transferred to `ProtocolFeeInbox` (5%).
At tenure expiry: full `tenant_stake` → split 95/5 → `owner_earnings` and `FeeMessage<C>` transferred to `ProtocolFeeInbox`.

### Pending bid lifecycle

Incoming bid enters as `Coin<CoinType>` → `Balance` in `RentalEscrow.pending_bid`.
If superseded: refunded immediately as `Coin` (push to registered address).
At handover: becomes new `tenant_stake`.

### Owner earnings lifecycle

Accumulated in `RentalEscrow.owner_earnings` at each handover and tenure expiry (95% share).
Withdrawn by owner via `withdraw_earnings()` → `Coin` (pull, requires `OwnerCap`).
Swept atomically by `claim_asset()` when the escrow is deleted.

### Protocol fee lifecycle

At each handover and tenure expiry (5% share), `send_fee()` is called inline by
`do_handover` and `do_tenure_expiry`. It immediately creates a `FeeMessage<C>` and
transfers it to `ProtocolFeeInbox` via transfer-to-object — free, does not mutate
`ProtocolFeeInbox`. No fee balance ever accumulates inside `RentalEscrow`.
`FeeMessage<C>` objects are discoverable as children of `ProtocolFeeInbox`
via `suix_getOwnedObjects`. The admin groups them by CoinType and calls
`collect_fee_messages<C>()` once per type — up to 1024 messages per PTB — presenting
only `&mut ProtocolFeeInbox` (owned object, fastpath, no consensus).
All messages are deleted after draining. The CoinType is encoded in the object type,
so no coordination is needed to identify which coin to drain.

---

## Notes

- All timestamps in milliseconds (`sui::clock::Clock::timestamp_ms`).
- All prices in base token units (no decimals at protocol level).
- Asset requires `key + store` abilities to live inside `RentalEscrow`.
- `integrate()` creates and shares 1 object: `RentalEscrow`. It takes `&ProtocolFeeRef` (frozen — no consensus) and stores `fee_ref_inbox_id(fee_ref)` as `fee_inbox_id`. Publish-time `init()` creates two singletons: `ProtocolFeeInbox` (transferred to deployer) and `ProtocolFeeRef` (frozen).
- `asset: Asset` — the asset is always present while the escrow exists. There is no valid persistent state where the escrow exists without the asset. `claim_asset()` extracts the asset and deletes the escrow atomically. The PTB borrow mechanism (`borrow_asset`/`return_asset`) is an implementation detail — the temporary extraction never persists across transaction boundaries.
- Fund flows are asymmetric: owner pulls via `withdraw_earnings()` and `claim_asset()`; admin pulls via `collect_fee_messages()`; tenants receive pushes to the address registered at mint time.
- Stale `TenantCap` objects in a wallet are inert — they fail the ID check. `burn(cap)` is available for gas recovery.
- `OwnerCap` as asset is permitted without depth limit. The protocol does not inspect the type of the wrapped asset at integration time — any `key + store` type, including `OwnerCap`, is accepted.
- Object discovery: `AssetIntegrated` includes `escrow_id` so off-chain consumers can track all instances from events. Sui RPC (`suix_queryObjects` by type) serves as a bootstrap fallback.
- `CoinType` is a phantom type parameter fixed at integration time. Any fungible token satisfying Move's abilities works — integrating protocols can use their own native tokens as the rental currency rather than USDC or USDT. A protocol that mints its own asset can rent it out denominated in its own coin, creating a self-contained economic loop without dependency on external stablecoins.

---

## File Layout

```
sources/
    math.move                     §1   — pure arithmetic
    curve_shape.move              §2   — CurveShape type and shape function evaluation
    price_function.move           §3   — PriceFunction type and price escalation
    config.move                   §4   — IntegrationConfig struct + validation
    owner_cap.move                §5   — OwnerCap object (includes cap lifecycle events)
    tenant_cap.move               §6   — TenantCap object (includes cap lifecycle events)
    protocol_fee_inbox.move       §8   — ProtocolFeeInbox + ProtocolFeeRef
    fee_message.move              §9   — FeeMessage + send_fee + drain
    rental_escrow.move            §10  — RentalEscrow shared object + full public API
tests/
    math_tests.move
    curve_shape_tests.move
    price_function_tests.move
    config_tests.move
    fee_message_tests.move
    rental_escrow_tests.move
Move.toml
Move.lock
```

---

## Design Decisions

### One shared object per instance — ProtocolFeeInbox as fee inbox

Only `owner_earnings` lives inside `RentalEscrow` as a `Balance<CoinType>` field.
`apply_pending_transitions()` credits it at every boundary event without touching any
external object. Every public mutating function carries only one shared object
reference — no contention beyond the escrow itself.

At each boundary event, `do_handover` and `do_tenure_expiry` call `send_fee()` to
immediately create a `FeeMessage<C>` and transfer it to `ProtocolFeeInbox` via
transfer-to-object. This is a free operation — it does not mutate `ProtocolFeeInbox`.
No fee balance ever accumulates inside `RentalEscrow`. `claim_asset()` does not need
to perform any fee cleanup — it simply sweeps `owner_earnings`, burns `OwnerCap`,
and deletes the escrow.

`ProtocolFeeInbox` is an owned singleton (`key + store`) created at publish time and
transferred to the deployer. Its ID is registered in each escrow at `integrate` time
via `ProtocolFeeRef` — a frozen (immutable) pointer accessible by any PTB without
consensus overhead.

The admin discovers `FeeMessage<C>` objects as children of `ProtocolFeeInbox`
via `suix_getOwnedObjects`, groups them by CoinType, and batch-drains each group via
`collect_fee_messages<C>()` — up to 1024 messages per PTB, one call per CoinType,
presenting only `&mut ProtocolFeeInbox` (owned, fastpath, no consensus).
The CoinType is encoded in the object type: no coordination between owner and admin is
required at any point in the lifecycle.

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

### Why admin types are split into two modules

`ProtocolFeeInbox` and `ProtocolFeeRef` are co-located in `protocol_fee_inbox.move` —
they are created together at init and are tightly coupled: `ProtocolFeeRef` exists
solely to carry the ID of `ProtocolFeeInbox`. Neither type has meaning without the other.
`FeeMessage` lives in its own module because it owns the `transfer::receive`
logic (restricted by `key` only) and depends on `protocol_fee_inbox` for `uid_mut`.
Separating it keeps the drain logic isolated and independently testable. Two modules
for admin concerns — not three — reflects the actual coupling in the design.

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
owner, burns `OwnerCap`, and deletes `RentalEscrow`. All local balances are consumed
before deletion — no orphaned funds, no locked balances.


---

## Implementation Order

Build bottom-up following the dependency graph:

```
1.  math                      (leaf — no dependencies)
2.  curve_shape               (depends on math)
3.  price_function            (depends on math)
4.  config                    (depends on curve_shape, price_function)
5.  owner_cap                 (leaf)
6.  tenant_cap                (leaf)
7.  protocol_fee_inbox        (leaf)
8.  fee_message               (depends on protocol_fee_inbox)
9.  rental_escrow             (depends on all above)
```

Steps 2–3 are independent of each other (both depend only on math) and can be built in parallel.
Steps 5–7 are independent leaves — build in parallel.
Step 4 (config) waits on steps 2–3. Step 8 waits on step 7. Step 9 waits on all.
