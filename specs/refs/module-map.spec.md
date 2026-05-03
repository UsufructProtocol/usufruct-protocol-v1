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
║  │    asset exists        │  │  · handover: HandoverPolicy      │  ║
║  └────────────────────────┘  │  · descent:  DescentPolicy       │  ║
║                               │  · retire:   RetirePolicy        │  ║
║  ┌────────────────────────┐  │  · CurveShape g  (credit)        │  ║
║  │  AssetState            │  │  · CurveShape h  (descent)       │  ║
║  │  Idle                  │  │  · PriceFunction                 │  ║
║  │  Rented                │  └──────────────────────────────────┘  ║
║  │    HandoverOpen        │                                         ║
║  │    HandoverConfirmed   │  ┌───────────────────────────────────┐ ║
║  │  AtDutchAuction        │  │  Phase anchors                    │ ║
║  │  Retired               │  │  · last_acquisition_price: u64    │ ║
║  └────────────────────────┘  │  · phase_start_ms: u64            │ ║
║                               │  · bid_time_ms: u64               │ ║
║  ┌──────────────────┐         │      (HandoverConfirmed only;     │ ║
║  │  tenant_stake    │         │       handover boundary derived   │ ║
║  │  Balance<C>      │         │       via handover_policy::       │ ║
║  └──────────────────┘         │       expiry_at — not cached)     │ ║
║  ┌──────────────────┐         │  · current_tenant_cap_id          │ ║
║  │  pending_bid     │         │  · current_tenant_address         │ ║
║  │  Balance<C>      │         │  · pending_tenant_address         │ ║
║  └──────────────────┘         └───────────────────────────────────┘ ║
║  ┌──────────────────┐                                               ║
║  │  owner_earnings  │         ┌───────────────────────────────────┐ ║
║  │  Balance<C>      │         │  Flags + routing                  │ ║
║  └──────────────────┘         │  · retiring: bool                 │ ║
║                               │  · integrated_at_ms: u64          │ ║
║                               │  · fee_inbox_id: ID               │ ║
║                               └───────────────────────────────────┘ ║
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
   used_credit × 0.90       →  owner_earnings
   used_credit × 0.10       →  FeeMessage<C>  →  transfer-to-object  →  fee_inbox_id
   remain_credit            ←  Coin<C>  (push to current_tenant_address)

 apply_pending_transitions() — tenure expiry:
   tenant_stake × 0.90      →  owner_earnings
   tenant_stake × 0.10      →  FeeMessage<C>  →  transfer-to-object  →  fee_inbox_id

 withdraw_earnings()        ←  Coin<C>  ←  owner_earnings                   (pull, OwnerCap)
 retire()                   —  sets retiring flag only, no asset movement
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
| `compute_used_credit`, `compute_floor_price` | read-only (`&RentalEscrow`) — no contention |

---

## Package

```toml
[package]
name    = "usufruct"
edition = "2024"

[addresses]
usufruct = "0x0"
```

---

## Module Dependency Graph

```
INFRASTRUCTURE LAYER                        │  ENTITY LAYER
────────────────────────────────────────────┼─────────────────────────────────────────

   math                                     │  asset
   ↑     ↑                                  │  (leaf — Asset<U> wrapper, AssetReceipt)
   │     │                                  │         │
curve_shape  price_function                 │         ↓
(math)       (math)                         │    asset_state
                                            │    (asset)
phases                                      │
(std::u64 only)                             │  owner_cap   protocol_fee_inbox
  ↑         ↑         ↑                     │     │             │
  │         │         │                     │     ↓             ↓
handover  descent  retire                   │   owner       fee_message
_policy   _policy  _policy                  │  (owner_cap)  (protocol_fee_inbox)
  │         │         │                     │     │              │
  └────┬────┴─────────┘                     │     └──────┬───────┘
       ↓                                    │            ↓
     config                                 │          tenant
     (curve_shape, price_function,          │       (fee_message, owner)
      *_policy)                             │        ↙             ↘
                                            │  tenant_state     refund_state
protocol_fee_inbox ← fee_message            │  (tenant)         (tenant, owner,
owner_cap · tenant_cap  (leaves)            │                    fee_message)
                                            │        ↘             ↙
                                            │       lifecycle_state
                                            │       (asset_state, refund_state,
                                            │        tenant, tenant_state)
────────────────────────────────────────────┴─────────────────────────────────────────

                           escrow_coordinator
       ┌──────────────────────────────────────────────────────────────────┐
       │  ENTITY LAYER:  lifecycle_state · asset_state · tenant_state      │
       │                 tenant · owner · refund_state · fee_message        │
       │                 asset                                              │
       │                                                                    │
       │  INFRASTRUCTURE: config · owner_cap · tenant_cap                  │
       │                  protocol_fee_inbox · phases                       │
       │                  handover_policy · descent_policy · retire_policy  │
       │                  curve_shape · price_function · math               │
       └──────────────────────────────────────────────────────────────────┘
```

Arrows point from dependency to dependent.
`escrow_coordinator` is the integration point — it consumes every other module.
`rental_escrow.move` is the legacy predecessor; `escrow_coordinator.move` replaces it.

**Infrastructure layer** (left column): modules that existed before the entity-layer
refactor (C1–C6b). Unchanged; `escrow_coordinator` imports them directly — policies,
config, caps, time primitives.

**Entity layer** (right column): new modules from the C1–C6b refactor. Encode the
protocol's domain objects (`Tenant`, `Owner`, `Asset`, `RefundState`) and their per-rental
state machines. `escrow_coordinator` composes both layers; every `RefundState` hot-potato
produced at a lifecycle boundary is consumed inline by a `match` in `escrow_coordinator`.

**Time-layer single-owner invariant:** `phases` is the only module in the
codebase that performs `+` or `u64::min` on values whose semantic is a
timestamp (the `_ms` discriminator is what makes the invariant
mechanically chequeable — see `phases.spec.md` §6 P7). Every other module
that needs temporal arithmetic — including the policy modules and
`rental_escrow` — calls `phases::has_passed`, `phases::elapsed_since`,
`phases::boundary_at`, or `phases::earliest`.

**Events:** there is no standalone `events` module. Each module owns its own
observability — event structs are defined in the module that emits them.
All protocol state-machine events live in `escrow_coordinator`. Cap lifecycle events
(`TenantCapMinted`, `TenantCapBurned`, `OwnerCapMinted`, `OwnerCapBurned`) live in
`tenant_cap` and `owner_cap` respectively. Fee events live in `fee_message`.
The integration registration event (`IntegrationConfigRegistered`) lives in
`config`. This follows the idiomatic Sui Move pattern: the Sui Verifier requires
the emitted type to be internal to the module calling `event::emit`.

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
| `EMulDivOverflow` | `u64` | `0` | Abort code when `mul_div` result overflows u64. |

**Exports (public):**

| Function | Signature | Purpose |
|---|---|---|
| `mul_div` | `(a: u64, b: u64, c: u64): u64` | `floor(a * b / c)` via u128, overflow-safe. |
| `nth_root_u128` | `(n: u128, d: u32): u128` | `floor(n^(1/d))` via Newton-Raphson. Used by `curve_shape` for the PowerLaw variant. `d ∈ {2, 3, 4}`. |

**Status:** [*] `mul_div` · [*] `nth_root_u128`

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

**Constructors (`public`):** `new_linear()`, `new_smoothstep()`, `new_logistic()` — no validation. `new_power_law(alpha_num, alpha_den)` — validates `alpha_num ∈ [1, 8]`, `alpha_den ∈ {1, 2, 3, 4}`, `alpha_num != alpha_den`; normalizes by `gcd(alpha_num, alpha_den)`. `new_exponential(alpha_abs, alpha_neg)` — validates `alpha_abs ∈ [1, 8]`.

**Functions:**

| Function | Visibility | Signature | Purpose |
|---|---|---|---|
| `evaluate_curve` | `public(package)` | `(shape: &CurveShape, t: u64, t_max: u64): u64` | Evaluate normalized shape at `x = t/t_max`, result in `[0, SCALE]`. Short-circuits at `t == 0 → 0` and `t >= t_max → SCALE`. Protocol-level scaling (by `tenant_stake`, spread) is applied by `rental_escrow` callers. |

**Status:** [*] `CurveShape` · [*] `evaluate_curve`

**Depends on:** `math`.

---

### 3. `price_function.move` — Price escalation function (PriceFunction)

**Responsibility:** Defines the `PriceFunction` enum type and evaluates
`f_next_rent_price`. All functions are pure — no objects, no mutation, no Sui state.

**Types:**

| Type | Abilities | Variants |
|---|---|---|
| `PriceFunction` | `copy, drop, store` | `FixedDelta { delta: u64 }`, `CompoundDelta { bps: u64, delta: u64 }` |

**Constructors (`public`):** `new_fixed_delta(delta)` — validates `delta > 0`. `new_compound_delta(bps, delta)` — validates `bps ∈ [1, u64::MAX − 10000]`, `delta > 0`.

**Functions:**

| Function | Visibility | Signature | Purpose |
|---|---|---|---|
| `evaluate_price_fn` | `public(package)` | `(price_fn: &PriceFunction, last_rent_price: u64): u64` | Dispatcher — match on `PriceFunction` variant. Called by `rental_escrow::compute_next_rent_price`. Result always `> last_rent_price` (constructor-enforced). |

**Status:** [*] `PriceFunction` · [*] `evaluate_price_fn`

**Depends on:** `math`.

---

### 4. `phases.move` — Time-layer primitives

**Responsibility:** Single-owner module for all timestamp arithmetic and
clock comparisons. Every other module that needs to reason about time
calls into `phases`; no module performs naked `+` or `u64::min` on a
timestamp-tagged value (`_ms` suffix). Mechanically chequeable invariant
(see `phases.spec.md` §6 P7).

**Functions:**

| Function | Visibility | Signature | Purpose |
|---|---|---|---|
| `has_passed` | `public(package)` | `(anchor_ms: u64, duration_ms: u64, now_ms: u64): bool` | True iff `now_ms >= anchor_ms + duration_ms`. The bool gate that every policy dispatcher delegates to. |
| `elapsed_since` | `public(package)` | `(start_ms: u64, now_ms: u64): u64` | Saturating `now - start` (returns 0 if `now < start`). Used by `compute_used_credit` and `compute_price_descent`. |
| `boundary_at` | `public(package)` | `(anchor_ms: u64, duration_ms: u64): u64` | `anchor + duration`. The u64 sister of `has_passed`. Used by every policy module's `expiry_at` and by `apply_pending_transitions` HandoverOpen. |
| `earliest` | `public(package)` | `(a_ms: u64, b_ms: u64): u64` | `min(a, b)`. Used both for clock-vs-boundary clamps (`compute_used_credit`) and boundary-vs-boundary saturation (`handover_policy::expiry_at` Countdown). |

**Architectural property:** the four primitives split into two pairs:
`has_passed` (bool) ↔ `boundary_at` (u64) are sister views of the same
"is the boundary crossed?" concept; `elapsed_since` and `earliest` cover
saturating subtraction and minimum-over-timestamps. The sister identity
`has_passed(a, d, n) ⇔ n >= boundary_at(a, d)` is the time-layer
invariant — every policy module's own `has_expired ⇔ now >= expiry_at`
identity collapses to this one.

**Status:** [*] `has_passed` · [*] `elapsed_since` · [*] `boundary_at` · [*] `earliest`

**Depends on:** `std::u64` (for `min` in `earliest`). Nothing else.

---

### 5. `handover_policy.move` — Handover countdown rule

**Responsibility:** Defines the `HandoverPolicy` enum and dispatches over
its variants. Parameterizes how long the protocol waits between a bid
landing in `HandoverOpen` (transitioning to `HandoverConfirmed`) and the
actual handover firing.

**Types:**

| Type | Abilities | Variants |
|---|---|---|
| `HandoverPolicy` | `copy, drop, store` | `Instant`, `Countdown { floor_ms: u64 }`, `FixedTime` |

**Constructors (`public`):** `new_handover_instant()`, `new_handover_fixed_time()` — no validation. `new_handover_countdown(floor_ms)` — validates `floor_ms > 0` (zero is the `Instant` mode).

**Error constants:**
- `EHandoverFloorZero: u64 = 0` — `new_handover_countdown(0)`

**Dispatchers (`public(package)`):**

| Function | Signature | Purpose |
|---|---|---|
| `has_expired` | `(policy: &HandoverPolicy, bid_time_ms, phase_start_ms, tenure_ceiling, now_ms): bool` | Bool gate: has the handover countdown expired? Called by `apply_pending_transitions` HandoverConfirmed branch. |
| `expiry_at` | `(policy: &HandoverPolicy, bid_time_ms, phase_start_ms, tenure_ceiling): u64` | u64 sister: canonical handover boundary. Used by the same call site to forward to `do_handover`, by `compute_used_credit` to clamp credit accrual, and by `do_place_bid` to emit `BidPlaced.handover_countdown_expiry`. |
| `countdown_floor_lt` | `(policy: &HandoverPolicy, ceiling: u64): bool` | Cross-field predicate consumed by `config::new_config` to enforce `Countdown.floor_ms < tenure_ceiling`. Encapsulated here because Move 2024 restricts variant pattern-matching to the defining module. |

**Status:** [*] `HandoverPolicy` · [*] constructors · [*] `has_expired` · [*] `expiry_at` · [*] `countdown_floor_lt`

**Depends on:** `phases`.

---

### 6. `descent_policy.move` — Dutch auction descent rule

**Responsibility:** Defines the `DescentPolicy` enum and dispatches over
its variants. Parameterizes whether the auction window exists and (if so)
its duration.

**Types:**

| Type | Abilities | Variants |
|---|---|---|
| `DescentPolicy` | `copy, drop, store` | `Skipped`, `Window { ceiling_ms: u64 }` |

**Constructors (`public`):** `new_descent_skipped()` — no validation. `new_descent_window(ceiling_ms)` — validates `ceiling_ms > 0` (zero is the `Skipped` mode).

**Error constants:**
- `EDescentCeilingZero: u64 = 0` — `new_descent_window(0)`
- `EDescentSkippedNoWindow: u64 = 1` — `window_ceiling` on `Skipped` (structurally unreachable; defensive landmine)

**Dispatchers (`public(package)`):**

| Function | Signature | Purpose |
|---|---|---|
| `has_expired` | `(policy: &DescentPolicy, phase_start_ms, now_ms): bool` | Bool gate: has the descent window expired? Called by `apply_pending_transitions` AtDutchAuction branch. |
| `expiry_at` | `(policy: &DescentPolicy, phase_start_ms): u64` | u64 sister: canonical auction-collapse boundary. Used by the same call site to forward to `do_auction_expiry` for the `AuctionExpired.timestamp_ms` event payload. |
| `window_ceiling` | `(policy: &DescentPolicy): u64` | Width of the descent window — `t_max` input for `evaluate_curve` in `compute_price_descent`. Aborts on `Skipped`. |

**Status:** [*] `DescentPolicy` · [*] constructors · [*] `has_expired` · [*] `expiry_at` · [*] `window_ceiling`

**Depends on:** `phases`.

---

### 7. `retire_policy.move` — Retire unlock rule

**Responsibility:** Defines the `RetirePolicy` enum and dispatches over
its variants. Parameterizes whether `retire()` may be called immediately
upon integration or only after a deferred floor elapses.

**Types:**

| Type | Abilities | Variants |
|---|---|---|
| `RetirePolicy` | `copy, drop, store` | `Immediate`, `Deferred { floor_ms: u64 }` |

**Constructors (`public`):** `new_retire_immediate()` — no validation. `new_retire_deferred(floor_ms)` — validates `floor_ms > 0` (zero is the `Immediate` mode).

**Error constants:**
- `ERetireFloorZero: u64 = 0` — `new_retire_deferred(0)`

**Dispatchers (`public(package)`):**

| Function | Signature | Purpose |
|---|---|---|
| `is_unlocked` | `(policy: &RetirePolicy, integrated_at_ms, now_ms): bool` | Bool gate: may `retire()` proceed? Called by `rental_escrow::retire`. |

**No u64 sister.** Unlike `handover_policy` and `descent_policy`,
`retire_policy` exposes only the bool view — the unlock timestamp has
no non-gate consumer downstream (no event payload, no time-clamp, no
boundary forwarding). See `retire_policy.spec.md` §4 P3.

**Status:** [*] `RetirePolicy` · [*] constructors · [*] `is_unlocked`

**Depends on:** `phases`.

---

### 8. `config.move` — Integration configuration (data carrier)

**Responsibility:** Owns the `IntegrationConfig` struct that bundles all
immutable integration parameters embedded inside `RentalEscrow`, the
bundle constructor, the registration event, and the per-field getters.
Pure data-carrier role — does not own the policy enums or their dispatch
logic (those live in their own modules).

**Types:**

| Type | Abilities |
|---|---|
| `IntegrationConfig` | `copy, drop, store` |
| `IntegrationConfigRegistered` | `copy, drop` (event) |

**Fields (`IntegrationConfig`):**
- `min_rent_price: u64`
- `tenure_ceiling: u64` — ms
- `handover: HandoverPolicy`
- `descent: DescentPolicy`
- `retire: RetirePolicy`
- `credit_curve: CurveShape` — g, for `f_credit_ascent`
- `descent_curve: CurveShape` — h, for `f_price_descent`
- `price_function: PriceFunction` — for `f_next_rent_price`

**Error constants (public):**
- `E_MIN_RENT_PRICE_ZERO: u64 = 0`
- `E_TENURE_CEILING_ZERO: u64 = 1`
- `E_HANDOVER_FLOOR_EXCEEDS_TENURE: u64 = 2` — strict `>=` (equality is FixedTime)

The remaining intra-variant errors (`E_HANDOVER_FLOOR_ZERO`,
`E_DESCENT_CEILING_ZERO`, `E_RETIRE_FLOOR_ZERO`,
`E_DESCENT_SKIPPED_NO_WINDOW`) live in their owning policy modules.

**Exports (public):**

| Function | Visibility | Purpose |
|---|---|---|
| `new_config(...)` | `public` | Validates scalar fields and the one cross-field constraint (delegates to `handover_policy::countdown_floor_lt`); aborts on violation. PTB-callable bundle constructor. |
| `emit_registration(cfg, escrow_id)` | `public(package)` | Emits `IntegrationConfigRegistered`. Called from `rental_escrow::integrate` once the escrow ID is known. |
| One getter per field | `public(package)` | Scalars by value; policy/curve/price-function fields by `&` reference. |

**Status:** [*] `IntegrationConfig` · [*] `new_config` · [*] `emit_registration` · [*] getters

**Depends on:** `curve_shape`, `price_function`, `handover_policy`, `descent_policy`, `retire_policy` (type imports + the cross-field predicate).

---

### 9. `owner_cap.move` — Owner capability

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
| `new(escrow_id, owner, ctx): OwnerCap` | `public(package)` | Mint. Called only by `rental_escrow::integrate`. Emits `OwnerCapMinted { owner_cap_id, escrow_id, owner }`. |
| `burn(cap, owner)` | `public(package)` | Destroy. Called only by `rental_escrow::claim_asset`. `owner: address` is the burn-time holder (hoisted by the caller from `tx_context::sender`); recorded in `OwnerCapBurned`. |
| `escrow_id(cap): ID` | `public` | Getter. Read by `rental_escrow` at each owner-gated entry to compare against the target escrow's ID inline (abort constant `E_WRONG_ESCROW_OWNER_CAP` lives in rental_escrow). |

**Status:** [*] `OwnerCap` · [*] `new` · [*] `burn` · [*] `escrow_id`

**Depends on:** nothing (only `sui::object`).

---

### 10. `tenant_cap.move` — Tenant capability

**Responsibility:** `TenantCap` object only.
`TenantCap` is minted only when a bidder becomes the current tenant — not at bid time.
Stale caps from displaced tenants are inert.

**Types:**

| Type | Abilities | Notes |
|---|---|---|
| `TenantCap` | `key + store` | Symmetric with `OwnerCap`. Holders may custody / multisig / transfer; the protocol does not police ownership. |

**Fields:**
- `id: UID`
- `escrow_id: ID`

**Exports:**

| Function | Visibility | Purpose |
|---|---|---|
| `new(escrow_id, tenant, ctx): (TenantCap, ID)` | `public(package)` | Pure constructor + emitter. Builds the cap, emits `TenantCapMinted { tenant_cap_id, escrow_id, tenant }`, returns `(cap, cap_id)` by value. No transfer. |
| `burn(cap, ctx)` | `public(package)` | Destroys the cap by value. Emits `TenantCapBurned { tenant_cap_id, escrow_id, tenant: tx_context::sender(ctx) }`. Called only from `rental_escrow::burn_tenant_cap`, which gates the call on the cap being structurally stale. |
| `escrow_id(cap): ID` | `public` | Getter. Read by `rental_escrow::borrow_asset` to compare against the target escrow's ID inline (abort constants `E_WRONG_ESCROW_TENANT_CAP` and `E_STALE_TENANT_CAP` live in rental_escrow). |

**Status:** [*] `TenantCap` · [*] `new` · [*] `burn` · [*] `escrow_id`

**Depends on:** nothing (only `sui::object`).

---

### 11. ~~`events.move`~~ — No standalone events module

Event structs live in the module that emits them. See **Events** note in the
dependency graph above. Protocol state-machine events are specified in
`rental_escrow.spec.md`. Cap lifecycle events in `owner_cap.spec.md` and
`tenant_cap.spec.md`. Fee events in `fee_message.spec.md`. The integration
registration event in `config.spec.md`.

---

### 12. `protocol_fee_inbox.move` — Protocol fee inbox

**Responsibility:** `ProtocolFeeInbox` singleton and `ProtocolFeeRef` frozen pointer.
`ProtocolFeeInbox` is the transfer-to-object target for all `FeeMessage<C>` objects
created at boundary events. `ProtocolFeeRef` is a frozen, immutable pointer to the
inbox's ID — passed to `integrate` by any integrator without consensus overhead.

**Types:**

| Type | Abilities | Notes |
|---|---|---|
| `ProtocolFeeInbox` | `key, store` | Singleton. Transferable. Fee inbox. |
| `ProtocolFeeRef` | `key` | Frozen singleton. Immutable pointer to `ProtocolFeeInbox`. |

**Exports:**

| Function | Visibility | Purpose |
|---|---|---|
| `init(ctx)` | private | Creates `ProtocolFeeInbox` (transfers to deployer) and `ProtocolFeeRef` (freezes). |
| `uid_mut(inbox): &mut UID` | `public(package)` | Exposes `&mut UID` for `transfer::receive` in `fee_message`. |
| `inbox_id(fee_ref): ID` | `public` | Returns `inbox_id`. Used by `rental_escrow::integrate`. |

**Status:** [*] `ProtocolFeeInbox` · [*] `ProtocolFeeRef` · [*] `init` · [*] `uid_mut` · [*] `inbox_id`

**Depends on:** nothing.

---

### 13. `fee_message.move` — Protocol fee message and drain

**Responsibility:** `FeeMessage<C>` per-boundary-event fee object, and all
fund-routing logic: `post` creates and routes to the inbox at each boundary;
`collect_fee_messages` receives and drains. `transfer::receive` is restricted to this
module (`key` only type).

**Types:**

| Type | Abilities | Notes |
|---|---|---|
| `FeeMessage<phantom CoinType>` | `key` | Per-boundary-event. Transferred to `ProtocolFeeInbox` as child. Deleted at drain. |

**Exports:**

| Function | Visibility | Purpose |
|---|---|---|
| `post<C>(balance, escrow_id, payer, fee_inbox_id, ctx)` | `public(package)` | If `balance > 0`: creates `FeeMessage<C>`, transfers to `fee_inbox_id`. If `balance == 0`: destroys zero balance. Called by `do_distribute_balance` in `rental_escrow`. |
| `collect_fee_messages<C>(inbox, tickets, ctx): Coin<C>` | `public` | Pipeline of receive + consume over `tickets` via `vector::do!`. Single pass O(n). Returns `Coin<C>`. Fastpath — no shared objects. One call per CoinType. |

**Status:** [*] `FeeMessage` · [*] `post` · [*] `collect_fee_messages`

**Depends on:** `protocol_fee_inbox`.

---

### 14. `asset.move` — Asset wrapper (entity layer)

**Responsibility:** `Asset<U>` wrapper for borrow-capable custody; `AssetIdentity { asset_id, escrow_id }` composite identity; `AssetReceipt` hot-potato for the take/put borrow protocol. `new(u, escrow_id)` stamps the escrow binding at wrap-time. `take`/`put` drive the borrow cycle with three independent asserts (cross-escrow, receipt-mismatch, asset-swap). `unbundle` exits the borrow-capable state by extracting the raw `U`.

**Status:** [*]

**Depends on:** nothing (leaf — no usufruct imports).

---

### 15. `owner.move` — Owner entity (entity layer)

**Responsibility:** `OwnerIdentity { cap_id }`, `OwnerEarnings<C> { balance }`, `Owner<C> { identity, earnings }`. `deposit` accumulates incoming `OwnerEarnings`; `withdraw` drains all earnings, gated by the matching `OwnerCap`; `destroy_empty` tears down a zero-balance owner at escrow deletion.

**Status:** [*]

**Depends on:** `owner_cap`.

---

### 16. `tenant.move` — Tenant entity (entity layer)

**Responsibility:** `TenantIdentity { cap_id, address }`, `TenantStake<C> { balance }`, `Tenant<C> { identity, stake }`. `new(cap_id, address, balance)` is the sole constructor. `take_fee_share` / `take_owner_earnings` drain typed shares off the stake. `liquidate(stake, to, ctx)` is the terminal consumer — transfers remainder to the tenant's address.

**Status:** [*]

**Depends on:** `fee_message`, `owner`.

---

### 17. `refund_state.move` — Refund state hot-potato (entity layer)

**Responsibility:** `RefundState<C>` hot-potato enum with three variants encoding the legal distribution shape at every lifecycle boundary:
- `Nothing { identity, fee_share, owner_earnings }` — full stake consumed
- `Parcial { identity, stake, fee_share, owner_earnings }` — three-way split with remainder
- `Total { identity, stake }` — full refund (e.g. displaced bid)

No abilities — must be consumed in the same PTB by a `match` in `escrow_coordinator`. Constructors only; no internal routing logic.

**Status:** [*]

**Depends on:** `tenant`, `owner`, `fee_message`.

---

### 18. `tenant_state.move` — Tenant slot state machine (entity layer)

**Responsibility:** `TenantState<C>` enum (`Absence`, `Occupied { t1 }`, `Demand { t1, t2, handover_countdown_expiry }`). Transitions: `absence` → `occupy` → `demand` ⇄ `redemand` → `reoccupy` → `vacate`. Guards illegal paths with `EInvariantViolation`.

**Status:** [*]

**Depends on:** `tenant`.

---

### 19. `asset_state.move` — Asset custody state machine (entity layer)

**Responsibility:** `AssetState<U>` enum (`Idle`, `AtDutch { last_acquisition_price }`, `HandoverOpen { Asset<U> }`, `HandoverConfirmed { Asset<U> }`, `Retired`). Non-borrowable variants (`Idle`, `AtDutch`, `Retired`) carry raw `U`; borrow-capable variants carry `Asset<U>`. `give`/`give_back` implement the within-state borrow cycle via `asset::take`/`put`. `expire` enforces borrow-blocks-expiry via `asset::unbundle`.

**Status:** [*]

**Depends on:** `asset`.

---

### 20. `lifecycle_state.move` — Cross-product lifecycle state machine (entity layer)

**Responsibility:** `LifecycleState<U, C>` enum (`NotRented { a_state, t_state }`, `Rented { a_state, t_state, phase_start_ms, retiring }`). Composes `AssetState<U>` × `TenantState<C>`. Every boundary transition that touches a tenant's stake returns a `RefundState<C>` hot-potato: `expire_tenure`, `accept_bid`, `supersede_bid`. Caller (`escrow_coordinator`) is forced to consume it via `match`.

**Status:** [*]

**Depends on:** `asset_state`, `refund_state`, `tenant`, `tenant_state`.

---

### 21. `escrow_coordinator.move` — Core shared object and public API

**Status:** [ ] pending (replaces legacy `rental_escrow.move`)

**Responsibility:** The central shared object (`EscrowCoordinator<U, C>`), lazy evaluation engine (`apply_pending_transitions`), all public entry points, and fund distribution via `RefundState` matching. Fields: `id`, `config`, `fee_inbox_id`, `integrated_at_ms`, `state: Option<LifecycleState<U, C>>` (StateReceipt discipline), `owner: Owner<C>`.

**Public API:**

| Function | Summary |
|---|---|
| `integrate` | Creates and shares `EscrowCoordinator`. Returns `OwnerCap`. |
| `rent` | Single entry — `do_install_new_tenant` / `do_place_bid` / `do_supersede_bid` depending on state. |
| `borrow_asset` | APT first. Verifies `TenantCap`. Calls `lifecycle_state::give`. Returns `(U, AssetReceipt)`. |
| `return_asset` | Calls `lifecycle_state::give_back`; three-assert safety inside `asset::put`. |
| `burn_tenant_cap` | APT first. Burns structurally-stale cap. |
| `retire` | APT first. `do_retire_immediately` (Idle/AtDutch) or `do_set_retiring_flag` (Rented). |
| `claim_asset` | APT first. Requires Retired. Decompose, drain owner, burn cap, delete object. |
| `withdraw_earnings` | APT first. `owner::withdraw` directly — not through lifecycle_state. |
| `apply_pending_transitions` | Public permissionless settler. Loop over 3 checks; max 4 iterations. |
| `compute_used_credit` | Read-only. Clamps effective time at handover countdown expiry if Demand. |
| `compute_floor_price` | Read-only. Routes by state tag. |
| `state_tag` | Pure projection `&LifecycleState → EscrowStateTag` (5 variants). |

**Internal `do_*` dispatch pattern:** every `do_*` that crosses a lifecycle boundary calls the corresponding `lifecycle_state::*` transition, receives a `RefundState<C>`, then matches it to route `owner::deposit`, `fee_message::post`, and `tenant::liquidate` in the correct combination. See `escrow_coordinator.note` for full call-site pseudocode.

**Depends on:** `lifecycle_state`, `asset_state`, `tenant_state`, `tenant`, `owner`, `refund_state`, `fee_message`, `asset`, `config`, `owner_cap`, `tenant_cap`, `protocol_fee_inbox`, `phases`, `handover_policy`, `descent_policy`, `retire_policy`, `curve_shape`, `price_function`, `math`.

---

### ~~`rental_escrow.move`~~ — Legacy predecessor (not deleted yet)

Behavioral reference only. The public API and fund-flow semantics documented in
`rental_escrow.spec.md` remain the target behavior for `escrow_coordinator.move`.
The implementation strategy (flat `Balance`, internal `Tenant` struct, `route_fund`,
`owner_state`) is obsolete — replaced by the entity layer above.

---

## Pending Transitions

### `apply_pending_transitions` — public, called by every public mutating function

**Sole responsibility:** execute every elapsed lazy transition — in order — before
any public function applies its own logic. This guarantees that `owner_earnings`
and protocol fees are never bypassed regardless of how long the escrow has been
inactive or what state the caller finds it in.

**The three checks — sequential, each reads the state mutated by the previous:**

```
EscrowState::HandoverConfirmed { phase_start_ms, bid_time_ms, .. } => {
    let policy = config::handover(&escrow.config);
    let tenure = config::tenure_ceiling(&escrow.config);
    if (handover_policy::has_expired(policy, *bid_time_ms, *phase_start_ms, tenure, now)) {
        let e = handover_policy::expiry_at(policy, *bid_time_ms, *phase_start_ms, tenure);
        do_handover(escrow, e, ctx);
        true
    } else false
},

EscrowState::HandoverOpen { phase_start_ms, .. } => {
    let tenure = config::tenure_ceiling(&escrow.config);
    if (phases::has_passed(*phase_start_ms, tenure, now)) {
        do_tenure_expiry(escrow, phases::boundary_at(*phase_start_ms, tenure), ctx);
        true
    } else false
},

EscrowState::AtDutchAuction { phase_start_ms, .. } => {
    let policy = config::descent(&escrow.config);
    if (descent_policy::has_expired(policy, *phase_start_ms, now)) {
        do_auction_expiry(escrow, descent_policy::expiry_at(policy, *phase_start_ms));
        true
    } else false
},

EscrowState::Idle | Retired => false,
```

**Pattern:** every gate uses a bool dispatcher (`has_expired` for handover/descent,
`phases::has_passed` for tenure — there's no `tenure_policy` enum, just a scalar
`tenure_ceiling`); the u64 boundary is derived only when the gate fires, for
forward-passing to `do_*` cascades and for event timestamps. The architectural
property: no naked `now >= e` outside the bool dispatchers; no naked `+`/`min`
on timestamps outside `phases`.

**Properties:**
- Bounded iterations: the loop runs while a transition fires, capped at
  `MAX_APT_ITERATIONS = 4` (structural property — no real chain exceeds 3).
- Each check reads the state written by the previous. Sequential order is mandatory.
- No prior knowledge of how many transitions are pending. The clock and the stored
  state fields contain all necessary information.
- If no transitions are pending, all checks are no-ops. Zero overhead.
- **Check 1 (Handover) always precedes Check 2 (Tenure) when `bid_time_ms` is
  present.** `do_place_bid` records `bid_time_ms = now`, and `expiry_at`
  saturates Countdown's boundary at `phase_start_ms + tenure_ceiling`,
  guaranteeing the handover fires at or before tenure expiry. Check 2 never
  sees `HandoverConfirmed` with an orphaned `bid_time_ms`.

**Why every public mutating function calls it:**

A public function that mutates state without first calling `apply_pending_transitions()`
could act on a stale state — for example, treating an asset as `AtDutchAuction` when
a handover and tenure expiry have logically occurred but not been executed. In that
case, the owner's `used_credit` and the protocol's fees from those boundaries would
never be credited. `apply_pending_transitions()` closes this gap unconditionally.

**Exception — functions that do not call it:**
- `return_asset()` — only returns the asset to escrow, no state dependency.

---

## State Settlement

`apply_pending_transitions` is both the internal settlement engine and a public
permissionless entry point. Making it public eliminates the need for a separate
`resolve_state` wrapper — the function is its own interface.

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

Payment enters as `Coin<CoinType>` → `Balance` in the current `Tenant`'s
`stake` (inside `EscrowState::HandoverOpen` or `HandoverConfirmed`).
At handover: split into `used_credit` + `remain_credit`.
`remain_credit` → pushed immediately to displaced tenant as `Coin`.
`used_credit` → split 90/10 → `owner_earnings` (90%) and `FeeMessage<C>` transferred to `ProtocolFeeInbox` (10%).
At tenure expiry: full `tenant.stake` → split 90/10 → `owner_earnings` and `FeeMessage<C>` transferred to `ProtocolFeeInbox`.

### Pending bid lifecycle

Incoming bid enters as `Coin<CoinType>` → `Balance` in the pending `Tenant`'s
`stake` (inside `EscrowState::HandoverConfirmed`).
If superseded: refunded immediately as `Coin` (push to registered address).
At handover: becomes new current `Tenant.stake`.

### Owner earnings lifecycle

Accumulated in `RentalEscrow.owner_earnings` at each handover and tenure expiry (90% share).
Withdrawn by owner via `withdraw_earnings()` → `Coin` (pull, requires `OwnerCap`).
Swept atomically by `claim_asset()` when the escrow is deleted.

### Protocol fee lifecycle

At each handover and tenure expiry (10% share), `do_distribute_balance` calls
`fee_message::post` inline. It immediately creates a `FeeMessage<C>` and
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
- `integrate()` creates and shares 1 object: `RentalEscrow`. It takes `&ProtocolFeeRef` (frozen — no consensus) and stores `inbox_id(fee_ref)` as `fee_inbox_id`. Publish-time `init()` creates two singletons: `ProtocolFeeInbox` (transferred to deployer) and `ProtocolFeeRef` (frozen).
- `EscrowState` carries the asset by variant (always present in non-degenerate states; held in `Option<Asset>` for `HandoverOpen` / `HandoverConfirmed` to support the `borrow_asset`/`return_asset` cycle within a single PTB; held by value for `Idle` / `AtDutchAuction` / `Retired`).
- Fund flows are asymmetric: owner pulls via `withdraw_earnings()` and `claim_asset()`; admin pulls via `collect_fee_messages()`; tenants receive pushes to the address registered at mint time.
- Stale `TenantCap` objects in a wallet are inert — they fail the ID check. `rental_escrow::burn_tenant_cap(escrow, cap, clock, ctx)` is available for gas recovery.
- `OwnerCap` as asset is permitted without depth limit. The protocol does not inspect the type of the wrapped asset at integration time.
- Object discovery: `AssetIntegrated` includes `escrow_id` so off-chain consumers can track all instances from events.
- `CoinType` is a phantom type parameter fixed at integration time. Any fungible token works — integrating protocols can use their own native tokens as the rental currency rather than USDC or USDT.
- **Time-layer single-owner invariant:** `phases` is the only module that performs `+` or `u64::min` on timestamp-tagged values (`_ms` suffix). Mechanically chequeable — see `phases.spec.md` §6 P7. Any future change that introduces naked timestamp arithmetic outside `phases` surfaces as a grep hit.

---

## File Layout

```
sources/
    math.move                     §1   — pure arithmetic
    curve_shape.move              §2   — CurveShape type and shape function evaluation
    price_function.move           §3   — PriceFunction type and price escalation
    phases.move                   §4   — time-layer primitives (single owner of `+`/`min` on timestamps)
    handover_policy.move          §5   — HandoverPolicy enum + dispatchers
    descent_policy.move           §6   — DescentPolicy enum + dispatchers
    retire_policy.move            §7   — RetirePolicy enum + dispatcher
    config.move                   §8   — IntegrationConfig data carrier + validation + event
    owner_cap.move                §9   — OwnerCap object (includes cap lifecycle events)
    tenant_cap.move               §10  — TenantCap object (includes cap lifecycle events)
    protocol_fee_inbox.move       §12  — ProtocolFeeInbox + ProtocolFeeRef
    fee_message.move              §13  — FeeMessage + post + drain
    asset.move                    §14  — Asset<U> wrapper + AssetIdentity + AssetReceipt (entity)
    owner.move                    §15  — Owner<C> entity + OwnerIdentity + OwnerEarnings (entity)
    tenant.move                   §16  — Tenant<C> entity + TenantIdentity + TenantStake (entity)
    refund_state.move             §17  — RefundState<C> hot-potato enum (entity)
    tenant_state.move             §18  — TenantState<C> per-rental slot state machine (entity)
    asset_state.move              §19  — AssetState<U> custody state machine (entity)
    lifecycle_state.move          §20  — LifecycleState<U,C> cross-product state machine (entity)
    escrow_coordinator.move       §21  — EscrowCoordinator shared object + full public API  [pending]
    rental_escrow.move            [legacy — behavioral reference; will be deleted post §21]
    usufruct.move                 [init — ProtocolFeeInbox + ProtocolFeeRef singletons]
tests/
    math_tests.move
    curve_shape_tests.move
    price_function_tests.move
    phases_tests.move
    handover_policy_tests.move
    descent_policy_tests.move
    retire_policy_tests.move
    config_tests.move
    owner_cap_tests.move
    tenant_cap_tests.move
    protocol_fee_inbox_tests.move
    fee_message_tests.move
    asset_tests.move
    owner_tests.move
    tenant_tests.move
    refund_state_tests.move
    tenant_state_tests.move
    asset_state_tests.move
    lifecycle_state_tests.move
    escrow_coordinator_tests.move  [pending]
    rental_escrow_tests.move       [legacy]
    usufruct_tests.move
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

At each boundary event, `do_handover` and `do_tenure_expiry` route through
`do_distribute_balance`, which calls `fee_message::post` to immediately create a
`FeeMessage<C>` and transfer it to `ProtocolFeeInbox` via transfer-to-object.
This is a free operation — it does not mutate `ProtocolFeeInbox`. No fee balance
ever accumulates inside `RentalEscrow`. `claim_asset()` does not need to perform
any fee cleanup — it simply sweeps `owner_earnings`, burns `OwnerCap`, and
deletes the escrow.

### Why the time layer (`phases`) is its own module

Every operation that takes a timestamp as input — clock-vs-boundary
comparisons, anchor + duration arithmetic, saturating subtraction,
minimum-of-two-timestamps — lives in `phases`. The architectural goal is
a **single-owner property** that is mechanically chequeable: a single
grep (`grep -nE "_ms\\s*\\+|u64::min" usufruct/sources/*.move | grep -v
phases.move`) returns no code hits in any other source file. Properties
defended by judgment-under-precondition erode; properties defended by
grep survive.

The four primitives (`has_passed`, `elapsed_since`, `boundary_at`,
`earliest`) split into two pairs: bool/u64 sister views of "is the
boundary crossed?" and saturating arithmetic. Every policy module's
own bool/u64 sister identity collapses to the time-layer one.

### Why each policy is its own module

`HandoverPolicy`, `DescentPolicy`, and `RetirePolicy` were originally
defined inside `config` along with their dispatchers (`handover_expiry`,
`descent_boundary`, `retire_unlock`, etc.). The dispatchers returned u64
boundaries, and `rental_escrow` re-implemented `now >= boundary` checks
at every call site.

The refactor split each policy into its own module that owns:
1. The enum definition + `public` PTB-callable variant constructors with
   intra-variant validation (e.g., `Countdown.floor_ms > 0`).
2. A bool dispatcher (`has_expired` / `is_unlocked`) — gate.
3. A u64 dispatcher (`expiry_at`) — sister view, used at non-gate
   consumers (event payloads, credit clamps, `do_handover` cascade).
4. Module-specific helpers (e.g., `descent_policy::window_ceiling` for
   the curve's `t_max`; `handover_policy::countdown_floor_lt` for the
   cross-field check that `config::new_config` consumes).

`config` becomes a pure data carrier — it stores the policies as fields,
delegates back to `handover_policy::countdown_floor_lt` for the one
cross-field check, and otherwise has no dispatch logic.

The bool/u64 sister identity (`has_expired ⇔ now >= expiry_at`) is the
load-bearing architectural invariant of the layer. Verified per module
by `*_policy_tests::has_expired_iff_now_ge_expiry_at`. The vacuous
variants (`Instant`, `Skipped`, `Immediate`) are implemented as
`phases::has_passed(anchor, 0, now)` rather than `=> true` so the
sister identity holds **unconditionally** — every variant gates through
the time layer; none are vacuous.

### Why `apply_pending_transitions` is public

The protocol guarantees settlement through its normal operations — no external
caller is required for correctness. `apply_pending_transitions` is public because
it is useful, not necessary: it lets any actor advance an idle escrow's state and
credit pending earnings without performing a full protocol operation.

### Why `EscrowState` carries fields per variant

State-relevant fields (`asset`, `phase_start_ms`, tenant slots, `bid_time_ms`)
live inside the `EscrowState` variant they apply to, not as flat fields on
`RentalEscrow`. Each variant exposes exactly what its semantic requires —
`Idle` has only `asset`; `HandoverConfirmed` has the full bid context.
This eliminates `Option<...>` fields that would otherwise need to be threaded
through every state, and lets the compiler enforce variant-specific invariants
(can't read `bid_time_ms` from `Idle` because the field doesn't exist).

The handover boundary is **derived on demand** (`expiry_at(policy, bid_time_ms,
...)`), not cached. The state stores the input (`bid_time_ms`); the boundary
is a derivation. Future policy changes propagate naturally — the cached
boundary would have lied; the input still tells the truth.

### Why `OwnerCap` and `TenantCap` are separate modules

Each is an independent Sui object with its own lifecycle, abilities, and
authorization semantics. Separating them makes abilities and transfer rules
immediately visible from the type definition, and follows the one-module-one-object
principle for objects that leave the module.

### Why `config` is its own module

`IntegrationConfig` aggregates types from `curve_shape`, `price_function`,
and the three policy modules, and applies the one cross-field validation
(`Countdown.floor_ms < tenure_ceiling`). Inlining it in `rental_escrow`
would force all those type imports and validation logic into the already-large
escrow module. A dedicated module keeps the constructor focused, the
event emission scoped, and the validation testable in isolation.

### Why admin types are split into two modules

`ProtocolFeeInbox` and `ProtocolFeeRef` are co-located in `protocol_fee_inbox.move`.
`FeeMessage` lives in its own module because it owns the `transfer::receive`
logic (restricted by `key` only) and depends on `protocol_fee_inbox` for `uid_mut`.
Two modules for admin concerns — not three — reflects the actual coupling.

### Why `rent()` is the single entry point

All paths to becoming a tenant go through `rent()`. The function calls
`apply_pending_transitions()` first, then applies the appropriate sub-logic based
on the resulting `escrow.state`. One responsibility: pay for access. The state
determines the price and the mechanics. The API surface is minimal.

### Eager minting of TenantCap at bid time

`TenantCap` is minted at bid time — at `do_place_bid` and `do_supersede_bid` —
not deferred to handover. This is required because the event star schema binds
`BidPlaced.tenant_cap_id` and `BidSuperseded.new_tenant_cap_id`; the cap ID must
exist at emit time. Stale caps from superseded bidders are inert (they fail the
ID check) and burnable for gas recovery via `burn_tenant_cap`.

### Why `retire` and `claim_asset` are separate functions

`retire()` initiates retirement — it sets the `retiring` flag and blocks new bids,
but never returns the asset. `claim_asset()` finalizes retirement — it requires
state `Retired`, extracts the asset, burns the `OwnerCap`, and deletes the escrow.

The owner always makes two calls regardless of the prior state:
- `retire()` on Idle or AtDutchAuction: state transitions to Retired immediately.
- `retire()` on Rented: sets flag, tenant completes their block. Owner calls
  `claim_asset()` after tenure expires and state has lazily resolved to Retired.

---

## Implementation Order

Build bottom-up following the dependency graph:

```
INFRASTRUCTURE (completed)
1.  math                      (leaf)
2.  curve_shape               (math)
3.  price_function            (math)
4.  phases                    (leaf — std::u64 only)
5.  handover_policy           (phases)
6.  descent_policy            (phases)
7.  retire_policy             (phases)
8.  config                    (curve_shape, price_function, *_policy)
9.  owner_cap                 (leaf)
10. tenant_cap                (leaf)
11. protocol_fee_inbox        (leaf)
12. fee_message               (protocol_fee_inbox)

ENTITY LAYER (C1–C6b, completed)
13. asset                     (leaf)
14. owner                     (owner_cap)
15. tenant                    (fee_message, owner)
16. refund_state              (tenant, owner, fee_message)
17. tenant_state              (tenant)
18. asset_state               (asset)
19. lifecycle_state           (asset_state, refund_state, tenant, tenant_state)

INTEGRATION (pending)
20. escrow_coordinator        (all above)
```

Steps 2–3 are independent (both depend only on math).
Step 4 is independent (std::u64 only).
Steps 5–7 are independent of each other (each depends only on phases).
Step 8 waits on steps 2–3 + 5–7.
Steps 9–11 are independent leaves.
Step 12 waits on step 11.

Entity layer build order:
Steps 13–14 are independent of each other.
Step 15 waits on steps 12 + 14.
Steps 16–17 wait on step 15 (and 12 for refund_state).
Step 18 waits on step 13.
Step 19 waits on steps 16 + 17 + 18.
Step 20 waits on all.

Step 20 (escrow_coordinator) begins with Phase 0 prerequisite additions to
asset_state, tenant_state, owner, and lifecycle_state — see `escrow_coordinator.note`
for the full execution order and Phase 0 requirements.
