# Liquid Renting Protocol — Implementation Inventory

Map of every design construct that needs a Sui Move implementation.
Each item will be specced individually before writing code.
Grouped by concern — module boundaries are a spec-level decision.

**Status key:** `[ ]` pending · `[~]` speccing · `[x]` specced · `[*]` coded


---

## 0. Object Model Diagram

Where each construct lives in Sui's object model.

```
 OWNER'S WALLET                        TENANT'S WALLET (current / pending)
 ┌───────────────────┐                 ┌──────────────────────┐
 │    OwnerCap       │                 │      TenantCap        │
 │   · escrow_id: ID │                 │   · escrow_id: ID     │
 └─────────┬─────────┘                 └──────────┬────────────┘
           │                                       │
           │ retire()                               │ borrow_asset()
           │ withdraw_earnings                      │
           ▼                                       ▼
╔══════════════════════════════════════════════════════════════════════╗
║  RentalEscrow<Asset, CoinType>            [SHARED OBJECT]           ║
║                                                                      ║
║  ┌────────────────────────┐  ┌──────────────────────────────────┐  ║
║  │  Asset (key + store)   │  │  IntegrationConfig  (immutable)  │  ║
║  │                        │  │  · min_rent_price                │  ║
║  │  ← lives here always   │  │  · tenure_ceiling                │  ║
║  │    except during a PTB │  │  · handover_floor/ceiling        │  ║
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
║  │  Retired               │  │  · phase_start_ms: u64           │ ║
║  └────────────────────────┘  │  · handover_countdown_expiry     │ ║
║                               │  · current_tenant_cap_id         │ ║
║  ┌──────────────────┐         │  · pending_tenant_cap_id         │ ║
║  │  tenant_stake    │         └───────────────────────────────────┘ ║
║  │  Balance<C>      │                                               ║
║  └──────────────────┘         ┌───────────────────────────────────┐ ║
║  ┌──────────────────┐         │  Flags                            │ ║
║  │  pending_bid     │         │  · retire: bool                   │ ║
║  │  Balance<C>      │         │  · integrated_at_ms: u64         │ ║
║  ┌──────────────────┐         └───────────────────────────────────┘ ║
║  │  owner_earnings  │                                               ║
║  │  Balance<C>      │                                               ║
║  └──────────────────┘                                               ║
╚══════════════════════════════════════════════════════════════════════╝
                            ▲
                            │  reads + mutates
                            │
┌───────────────────────────────────────────────────────────────────┐
│  resolve_state(escrow, clock)           [INTERNAL — pure logic]   │
│                                                                    │
│  Reads: AssetState + phase anchors + IntegrationConfig + clock    │
│  Calls: compute_used_credit / compute_price_descent  (§4)         │
│                                                                    │
│  Resolves up to 3 lazy transitions in order:                      │
│  1. HandoverConfirmed + expiry passed  → execute handover         │
│  2. Rented + tenure expired            → AtDutchAuction/Retired   │
│  3. AtDutchAuction + descent expired  → Idle/Retired              │
│                                                                    │
│  Mutates: AssetState, phase anchors, Balance<C> fields            │
└───────────────────────────────────────────────────────────────────┘
                            ▲
                            │  called first by every public function
                            │
       ▲            ▲               ▲                  ▲
       │            │               │                  │
  rent()       takeover()    return_asset()    withdraw_earnings()
  Coin<C> in   Coin<C> in    Asset back in     Coin<C> out
  → tenant_    → pending_
    stake        bid


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


 COIN FLOWS SUMMARY
 ──────────────────
 rent() / auction entry  →  Coin<C>           →  tenant_stake
 takeover()              →  Coin<C>           →  pending_bid
   (if superseded)       ←  Coin<C>           ←  pending_bid  (refund)
 handover fires          :  pending_bid       →  tenant_stake (new tenant)
                         :  used_credit×0.95  →  owner_earnings
                         :  used_credit×0.05  →  protocol_treasury
                         ←  Coin<C>           ←  remain_credit (to old tenant)
 tenure expiry           :  stake×0.95        →  owner_earnings (full)
                         :  stake×0.05        →  protocol_treasury
 withdraw_earnings()     ←  Coin<C>           ←  owner_earnings
 retire()                ←  Asset             ←  escrow (unwrapped, deleted)
```


---

## 1. Core State

### [ ] 1.1 `RentalEscrow<Asset, CoinType>` — shared object

The central object. Wraps the asset, holds all protocol state,
locked funds, and immutable configuration. One per integrated asset.

Fields:
- `id: UID`
- `asset: Asset`
- `config: IntegrationConfig`
- `state: AssetState`
- `last_rent_price: u64`
- `phase_start_ms: u64` — timestamp at which the current phase began
- `current_tenant_cap_id: Option<ID>`
- `current_tenant_address: Option<address>`
- `pending_tenant_cap_id: Option<ID>`
- `pending_tenant_address: Option<address>`
- `pending_bid: Balance<CoinType>`
- `handover_countdown_expiry: Option<u64>`
- `tenant_stake: Balance<CoinType>`
- `owner_earnings: Balance<CoinType>`
- `protocol_treasury: Balance<CoinType>`
- `retire: bool`
- `integrated_at_ms: u64`

### [ ] 1.2 `AssetState` — enum

`Idle | Rented { phase: RentPhase } | AtDutchAuction | Retired`

### [ ] 1.3 `RentPhase` — enum

`HandoverOpen | HandoverConfirmed`

Sub-state of `Rented`, nested inside the `Rented` variant.
Determines whether a pending displacement exists.


---

## 2. Configuration

### [ ] 2.1 `IntegrationConfig` — struct, immutable after creation

All parameters set once at integration time:
- `min_rent_price: u64`
- `tenure_ceiling: u64` — ms
- `handover_floor: u64` — ms
- `handover_ceiling: u64` — ms
- `descent_ceiling: u64` — ms
- `retire_floor: u64` — ms
- `credit_curve: CurveShape` — g, for `f_credit_ascent`
- `descent_curve: CurveShape` — h, for `f_price_descent`
- `price_function: PriceFunction` — for `f_next_rent_price`

### [ ] 2.2 `CurveShape` — enum

Normalized shape function type for `g` and `h`.
All members must satisfy: `f(0)=0`, `f(1)=1`, strictly increasing, bounded in `[0,1]`.

| Variant | Definition |
|---|---|
| `Linear` | `g(x) = x` |
| `PowerLaw { alpha_num, alpha_den }` | `g(x) = x^(alpha_num/alpha_den)` |
| `Exponential { alpha }` | `g(x) = (e^(ax)-1)/(e^a-1)` |
| `Smoothstep` | `g(x) = 3x² - 2x³` |

### [ ] 2.3 `PriceFunction` — enum

`f_next_rent_price` type. Must satisfy `f(x) > x` for all valid `x`.

| Variant | Definition |
|---|---|
| `FixedDelta { delta: u64 }` | `f(x) = x + delta` |
| `Percentage { bps: u64 }` | `f(x) = x * (10000 + bps) / 10000` |
| `CompoundDelta { bps: u64, delta: u64 }` | `f(x) = x * (10000 + bps) / 10000 + delta` |


---

## 3. Access Control

### [ ] 3.1 `OwnerCap` — owned object (`key + store`, transferable)

Capability proving authority over the integration instance.
Linked to a specific `RentalEscrow` by ID.
Required for: `retire()`, `withdraw_earnings()`.
Authorization check: `cap.escrow_id == object::id(escrow)`.
Burned unconditionally at retirement. Mutual exclusivity: `OwnerCap` exists ↔ asset is in escrow.

### [ ] 3.2 `TenantCap` — owned object (`key` only, non-transferable)

Capability proving tenancy over a specific `RentalEscrow`.
Minted on every valid bid. The holder's address is recorded in the escrow at mint time for push fund flows.
Valid only if its ID matches `escrow.current_tenant_cap_id`.
Superseded or displaced caps remain in the holder's wallet but are inert — they fail the ID check.
Required for: `borrow_asset()`.
Authorization check: `object::id(cap) == escrow.current_tenant_cap_id`.
A `burn_tenant_cap()` function is exposed for voluntary destruction of stale caps (gas recovery).

### [ ] 3.3 `AssetReceipt` — hot potato (no abilities)

Temporary access grant for usus operations.
Created by `borrow_asset()`, consumed by `return_asset()`.
The asset must return to escrow within the same PTB.

Fields:
- `escrow_id: ID` — must match on return


---

## 4. Math

### [ ] 4.1 Fixed-point arithmetic — utility module

Integer-only implementations needed for curve evaluation.

Core operations:
- `mul_div(a, b, c)` → `a*b/c` with u128 intermediate to avoid overflow
- `pow_frac(base, exp_num, exp_den)` → `base^(n/d)` for PowerLaw
- `exp_scaled(alpha, x)` → `e^(alpha*x)` scaled, for Exponential
- Polynomial evaluation for Smoothstep (trivial: `3x² - 2x³`)

Precision: all prices are `u64`, intermediates `u128`. Scaling factor TBD.

### [ ] 4.2 `evaluate_curve(shape, x_num, x_den) -> u64` — pure function

Evaluates the normalized shape function at `x = x_num/x_den`.
Returns result scaled to a precision denominator.
Dispatches on `CurveShape` variant.

### [ ] 4.3 `compute_used_credit(config, phase_start, now, last_rent_price) -> u64`

Applies `f_credit_ascent`:
```
x = (now - phase_start) / tenure_ceiling
used_credit = last_rent_price * g(x)
```
Saturates at `last_rent_price` when `now >= phase_start + tenure_ceiling`.

### [ ] 4.4 `compute_price_descent(config, phase_start, now, last_rent_price) -> u64`

Applies `f_price_descent`:
```
x = (now - phase_start) / descent_ceiling
price = last_rent_price - (last_rent_price - min_rent_price) * h(x)
```
Saturates at `min_rent_price` when `now >= phase_start + descent_ceiling`.

### [ ] 4.5 `compute_next_rent_price(price_fn, last_rent_price) -> u64`

Applies `f_next_rent_price`. Dispatches on `PriceFunction` variant.
Guarantees result `> last_rent_price` (checked at integration time).


---

## 5. Protocol Functions (public API)

### [ ] 5.1 `integrate<Asset, CoinType>(asset, config_params...) -> OwnerCap`

Wraps asset into a new `RentalEscrow` (shared object).
Validates all config constraints. Asset enters Idle.
Stores `integrated_at_ms` from Clock. Mints and returns `OwnerCap`.

### [ ] 5.2 `rent<Asset, CoinType>(escrow, payment, clock)`

Entry from Idle only. Tenant pays `P >= min_rent_price`.
Mints `TenantCap`, sets `current_tenant_cap_id`, `last_rent_price = P`, `phase_start_ms = now`.
Asset enters `Rented(HandoverOpen)`.

### [ ] 5.3 `takeover<Asset, CoinType>(escrow, payment, clock, random)`

From Rented only. Payment `>= next_rent_price`. Mints `TenantCap` for incoming bidder.

If `HandoverOpen`:
- Samples `handover_countdown_expiry` from on-chain randomness.
- Sets `pending_tenant_cap_id`, stores `pending_bid`.
- Transitions to `HandoverConfirmed`.

If `HandoverConfirmed`:
- Refunds previous `pending_bid` immediately.
- Overwrites `pending_tenant_cap_id` with new cap ID.
- `handover_countdown_expiry` unchanged.

### [ ] 5.4 `borrow_asset<Asset, CoinType>(escrow, cap, clock, ctx) -> (Asset, AssetReceipt)`

Caller must hold the current `TenantCap` (`object::id(cap) == escrow.current_tenant_cap_id`).
Extracts asset from escrow. Returns asset + hot-potato `AssetReceipt`.
Runs `resolve_state` first.

### [ ] 5.5 `return_asset<Asset, CoinType>(escrow, asset, receipt)`

Consumes `AssetReceipt`. Verifies `receipt.escrow_id` matches escrow.
Places asset back into escrow.

### [ ] 5.6 `retire<Asset, CoinType>(escrow, cap, clock) -> Asset`

Sole exit mechanism. Requires `retire_floor` elapsed. Consumes `OwnerCap`.

| State | Effect |
|---|---|
| `Idle` | Immediate → Retired. Asset unwrapped. `OwnerCap` burned. `RentalEscrow` deleted. |
| `AtDutchAuction` | Immediate → Retired. Asset unwrapped. `OwnerCap` burned. `RentalEscrow` deleted. |
| `Rented(HandoverOpen)` | Sets `retire` flag. Blocks new bids. Current tenant completes full block. At tenure expiry → Retired. |
| `Rented(HandoverConfirmed)` | Sets `retire` flag. Handover completes normally. T(n+1) enters `HandoverOpen` with flag active (no new bids). T(n+1) completes full block. At tenure expiry → Retired. |

### [ ] 5.8 `burn_tenant_cap(cap)`

Voluntarily destroys a stale `TenantCap` (one whose ID no longer matches any active escrow position).
Returns the storage deposit. No protocol state is mutated.

### [ ] 5.9 `withdraw_earnings<CoinType>(escrow, cap) -> Coin<CoinType>`

Owner claims accumulated `used_credit` from `owner_earnings` balance.

### [ ] 5.10 `withdraw_treasury<CoinType>(escrow, admin_cap) -> Coin<CoinType>`

Protocol admin claims accumulated fees from `protocol_treasury` balance.
Requires a `ProtocolAdminCap` (one-time witness pattern, held by protocol deployer).
No effect on rental state.


---

## 6. State Resolution (internal)

### [ ] 6.1 `resolve_state(escrow, clock)` — internal function

The lazy evaluation engine. Called at the top of every public function.
Given `(config, phase_anchors, clock)`, resolves all elapsed transitions.

**Transition chain** (in order, each checked against clock):

1. `Rented(HandoverConfirmed)` + `handover_countdown_expiry` passed
   → execute handover: update `current_tenant_cap_id`, distribute funds,
     set `phase_start_ms = handover_countdown_expiry`. Transition to `HandoverOpen`.
2. `Rented` + tenure expired (`phase_start_ms + tenure_ceiling` passed)
   → if `retire` flag: → Retired
   → else: → `AtDutchAuction` (set `phase_start_ms = phase_start_ms + tenure_ceiling`)
   → full `tenant_stake → owner_earnings`
3. `AtDutchAuction` + `descent_ceiling` passed
   → Idle

At most 3 transitions resolve in a single `resolve_state` call.

**Fund distribution at each boundary:**

| Boundary | Distribution |
|---|---|
| Handover | `remain_credit → current tenant (Coin)`. `used_credit × 0.95 → owner_earnings`. `used_credit × 0.05 → protocol_treasury`. `pending_bid → tenant_stake`. |
| Tenure expiry | `tenant_stake × 0.95 → owner_earnings`. `tenant_stake × 0.05 → protocol_treasury`. |
| Auction expiry | No funds to move. |


---

## 7. Events

| # | Event | Fields |
|---|---|---|
| 7.1 | `AssetIntegrated` | `escrow_id, owner_cap_id, min_rent_price, tenure_ceiling` |
| 7.2 | `RentalStarted` | `escrow_id, tenant_cap_id, price` |
| 7.3 | `TakeoverInitiated` | `escrow_id, outgoing_cap_id, incoming_cap_id, new_price, handover_expiry` |
| 7.4 | `BidSuperseded` | `escrow_id, refunded_cap_id, refunded_amount` |
| 7.5 | `HandoverCompleted` | `escrow_id, from_cap_id, to_cap_id, remain_credit_returned, owner_earned, protocol_fee` |
| 7.6 | `TenureExpired` | `escrow_id, cap_id, owner_earned, protocol_fee` |
| 7.7 | `DutchAuctionStarted` | `escrow_id, start_price, floor_price` |
| 7.8 | `DutchAuctionEntry` | `escrow_id, tenant_cap_id, entry_price` |
| 7.9 | `AssetIdled` | `escrow_id` |
| 7.10 | `RetireInitiated` | `escrow_id, current_state` |
| 7.11 | `AssetRetired` | `escrow_id` |


---

## 8. Fund Flows

### [ ] 8.1 Tenant stake lifecycle

Payment enters as `Coin<CoinType>` → split exact amount → `Balance` in escrow.
At handover: split into `used_credit` + `remain_credit`.
`remain_credit → transfer to displaced tenant (Coin)`.
`used_credit → owner_earnings Balance`.

### [ ] 8.2 Pending bid lifecycle

Incoming bid enters as `Coin<CoinType>` → `Balance` in `pending_bid`.
If superseded: refunded immediately as `Coin`.
At handover: becomes new `tenant_stake`.

### [ ] 8.3 Owner earnings lifecycle

Accumulated from `used_credit × 0.95` at each transition.
Held as `Balance<CoinType>` inside escrow.
Withdrawn by owner via `withdraw_earnings()` → `Coin`.

### [ ] 8.4 Protocol treasury lifecycle

Accumulated from `used_credit × 0.05` at each transition (handover and tenure expiry).
Held as `Balance<CoinType>` inside each escrow instance.
Withdrawn by protocol admin via `withdraw_treasury()` with `ProtocolAdminCap`.
Accumulates passively — no dependency on owner activity or `OwnerCap` state.


---

## Notes

- All timestamps in milliseconds (`sui::clock::Clock::timestamp_ms`).
- All prices in base token units (no decimals at protocol level).
- Asset requires `key + store` abilities to live inside the shared object.
- `CoinType` is constrained via `Balance<CoinType>` (Coin framework).
- Randomness for candle auction via `sui::random::Random` (Sui mainnet).
- Module boundaries (likely split):
  - `rental_escrow.move` — core state, entry functions, `resolve_state`
  - `curve.move` — `CurveShape`, `PriceFunction`, `evaluate_curve`, `compute_*`
  - `math.move` — fixed-point arithmetic primitives
  - `events.move` — event structs
