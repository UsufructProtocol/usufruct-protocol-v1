LIQUID RENTING PROTOCOL — DESIGN COMPACT
=========================================

Condensed reference extracted verbatim from the full design document.
For rationale, incentive analysis, and examples see liquid-renting-protocol-design.md.


1. STATE MACHINE
----------------

### States

| State | Description |
|---|---|
| **Idle** | Resting state. Asset available at exactly `min_rent_price`. No usage commitment. |
| **Rented** | Tenant holds usus + fructus. Two sub-states: |
|  — `rent_handover_open` | No pending displacement. Current tenant holds position. |
|  — `rent_handover_confirmed` | A new tenant has paid `next_rent_price`. `handover_countdown` running. Current tenant retains access until expiry; asset transfers to last valid bidder. |
| **At Dutch Auction** | Price descends from `last_rent_price` toward `min_rent_price` via `f_price_descent`. |
| **Retired** | Terminal. Asset exits protocol, returned to owner. |

### Transitions

| From | To | Trigger |
|---|---|---|
| Idle | Rented | User pays exactly `min_rent_price`. Sets `last_rent_price = min_rent_price`, `current_tenant`, `phase_start = now`. |
| Rented (handover_open) | Rented (handover_confirmed) | New tenant pays exactly `next_rent_price`. Computes `handover_countdown_expiry`. Stores `pending_tenant` + `pending_bid`. |
| Rented (handover_confirmed) | Rented (handover_confirmed) | Another bid arrives. Previous pending tenant refunded immediately in full. Replaced by new pending tenant. `handover_countdown_expiry` unchanged. |
| Rented (handover_confirmed) | Rented (handover_open) | `handover_countdown_expiry` reached. Handover executes: access transfers to last bidder, funds distributed (see §3). New tenant's cycle starts at `handover_countdown_expiry`. |
| Rented (handover_open) | At Dutch Auction | `used_credit = last_rent_price` (time exhausted) AND asset in `handover_open`. Full `tenant_stake` → `owner_earnings`. |
| Rented (handover_confirmed) | Rented (new tenant) | If handover fires at or after tenure expiry: Dutch Auction bypassed, demand already confirmed. |
| At Dutch Auction | Rented | Buyer pays current `price_descent`. New cycle begins. |
| At Dutch Auction | Idle | `descent_ceiling` elapsed, no buyer. Price reached `min_rent_price`. |
| Idle | Retired | Owner calls `retire()`. |
| At Dutch Auction | Retired | Owner calls `retire()`: immediate termination. |
| Rented (handover_open) | Retired | Owner calls `retire()`: sets `retire` flag. Blocks new bids. Tenant completes full block. At tenure expiry → Retired. |

### Transition constraints

- Price only ascends during Rented (via `f_next_rent_price`). Price only descends during Dutch Auction (via `f_price_descent`).
- At most 3 lazy transitions resolve in a single `resolve_state` call: handover → tenure expiry → auction expiry.


2. ACCESS MODEL
---------------

### Capability objects

| Cap | Abilities | Holder | Granted at | Burned at |
|---|---|---|---|---|
| `OwnerCap` | `key + store` (transferable) | Asset owner | Integration | Retirement |
| `TenantCap` | `key` only (non-transferable) | Current / next tenant | Each valid bid | Never forced — holder burns voluntarily |

**OwnerCap:** Sole verification for owner-privileged operations: `withdraw_earnings()`, `retire()`. `used_credit` accumulates as a balance inside the escrow — the `OwnerCap` holder withdraws it actively. The protocol never tracks who holds the cap. Mutual exclusivity: `OwnerCap` exists ↔ asset is in escrow; at retirement, asset is returned and `OwnerCap` is burned.

**TenantCap:** Minted only when a bidder becomes the current tenant — at `rent()` from Idle or AtDutchAuction, and at handover completion. Bids placed during Rented states do not mint a cap. Non-transferable by type (`key` only — no `store`, no module transfer function). The escrow registers `current_tenant_cap_id` (ID) and the addresses of the current and pending tenant (`current_tenant_address`, `pending_tenant_address`) to enable push fund flows. Verification: `object::id(cap) == escrow.current_tenant_cap_id`. At handover, the displaced tenant's cap becomes stale — inert, failing the ID check. A burn function is provided for voluntary gas recovery.

**Fund flow asymmetry:**
- Owner: **pull** — `used_credit` accumulates in escrow, withdrawn actively with `OwnerCap`.
- Tenant: **push** — `remain_credit` and superseded bid refunds pushed immediately to the address registered at mint time.

**OwnerCap recursive property:** Because `OwnerCap` has `key + store`, it satisfies the integration requirements and may itself be deposited into a new escrow. The outer tenant holds temporary administrative authority over the wrapped escrow — including `retire()` — for the duration of the tenancy. This enables implicit sale of the underlying asset. The protocol imposes no nesting-depth limit: any type-level check would fail to prevent deeper chains composed via external `key + store` wrappers, so the limit is neither stated nor enforced.

Asset lives in the shared escrow for its entire lifecycle. Only access designation changes:

| State | Access granted to |
|---|---|
| Idle | No one |
| Rented (handover_open) | `current_tenant` — exclusive |
| Rented (handover_confirmed) | `current_tenant` — exclusive until `handover_countdown_expiry`, then last bidder |
| At Dutch Auction | No one |
| Retired | Owner (asset unwrapped from escrow) |

**Bounded access mechanism:** Escrow releases asset temporarily via hot-potato `AccessKey`. Tenant interacts with integrating protocol directly. Asset must return within same PTB. Escrow knows nothing about the asset's semantics.

**Fructus:** Tenant captures fructus by calling integrating protocol's functions while holding asset. Yield accrues in the integrating protocol's state, not in the escrow. The first tenant after a vacant period captures all accumulated yield.


3. FUND FLOWS
-------------

### Invariant (always holds during Rented)

```
used_credit + remain_credit = last_rent_price
```

### Protocol fee

A fixed 5% fee is deducted from `used_credit` at the moment it flows — before reaching `owner_earnings`. This is the sole revenue mechanism of the protocol and applies to both events that generate `used_credit`:

```
owner_share    = used_credit × 0.95  →  owner_earnings
protocol_fee   = used_credit × 0.05  →  protocol_treasury
```

The fee rate is hardcoded at the module level. Not configurable per integration.

### At handover (handover_countdown_expiry reached)

```
used_credit_at_handover   = last_rent_price · g(t_handover / tenure_ceiling)
remain_credit_at_handover = last_rent_price - used_credit_at_handover

remain_credit_at_handover            → returned to displaced tenant (Tn)
used_credit_at_handover × 0.95       → owner_earnings
used_credit_at_handover × 0.05       → protocol_treasury
pending_bid                          → becomes new tenant_stake (for T(n+1))
```

T(n+1)'s cycle starts at `handover_countdown_expiry`. Their `f_credit_ascent` runs from `(0, 0)` to `(tenure_ceiling, P(n+1))`.

### At tenure expiry (used_credit = last_rent_price, handover_open)

```
tenant_stake × 0.95  →  owner_earnings (fully consumed, minus fee)
tenant_stake × 0.05  →  protocol_treasury
```

Triggers Dutch Auction. No stake carried into auction.

### At auction entry

New tenant pays current `price_descent`. Becomes new `tenant_stake`. Cycle begins.

### At auction expiry (descent_ceiling elapsed, no buyer)

No funds to move. Asset → Idle.

### At takeover (bid during Rented)

Payment enters as `pending_bid`. If superseded by another bid: refunded immediately in full. At handover: becomes new `tenant_stake`.

### Renewal (self-takeover)

Tn pays `P(n+1) = f_next_rent_price(Pn)` and simultaneously receives `remain_credit`:

```
net_cost = P(n+1) - remain_credit
         = P(n+1) - Pn + used_credit
         = increment + consumed_rent
```

Tn's structural advantage over external competitor: `remain_credit` (the discount no external actor can access).


4. THE HANDOVER COUNTDOWN
--------------------------

### Formula

When first bid arrives during `rent_handover_open`:

```
handover_countdown_expiry = t_bid + min(handover_floor, remaining_rent_time)
```

Computed deterministically at bid time. Fixed from that point. Subsequent bids do NOT alter it.

### Constraint

```
0 < handover_floor <= tenure_ceiling
```

### Behavior during countdown

- `f_credit_ascent` continues running — Tn pays for every second retained.
- Asset accepts new bids. Each supersedes the previous; superseded bidder refunded immediately.
- `handover_countdown_expiry` does not change with new bids.
- Access transfers to the **last** valid bidder when `handover_countdown_expiry` is reached.

### Dutch Auction bypass

When `remaining_rent_time <= handover_floor`: `handover_countdown_expiry = t_bid + remaining_rent_time`. Countdown exhausts Tn's remaining time exactly, `remain_credit = 0` at handover. Dutch Auction never triggered.

### Edge case

- `handover_floor = tenure_ceiling`: full block guaranteed before handover — equivalent to fixed-term lease with compensation mechanics.


5. INCENTIVE-DRIVEN FUNCTIONS
-----------------------------

### 5.1 `f_credit_ascent` — shape function `g`

**Type:** `g : [0, 1] → [0, 1]`

**Scaling (by protocol):**

```
used_credit(t) = last_rent_price · g(t / tenure_ceiling)
```

**Constraints on `g`:**

1. `g(0) = 0`
2. `g(1) = 1`
3. `∀ x ∈ [0, 1] : 0 ≤ g(x) ≤ 1`
4. Strictly monotonically increasing

**Bijectivity:** `g` is a bijection `[0, 1] ↔ [0, 1]`. The scaled function `f_credit_ascent : [0, tenure_ceiling] ↔ [0, last_rent_price]`. Time and used_credit are equivalent representations.

**Concrete families:**

| Family | Definition | Parameter effect |
|---|---|---|
| Power-law | `g(x) = x^α`, α > 0 | α < 1 concave, α = 1 linear, α > 1 convex |
| Exponential | `g(x) = (e^(αx) - 1) / (e^α - 1)`, α ≠ 0 | α < 0 concave, α → 0 linear, α > 0 convex |
| Smoothstep (sigmoidal) | `g(x) = 3x² - 2x³` | Convex on [0, 0.5), concave on (0.5, 1] |

### 5.2 `f_price_descent` — shape function `h`

**Type:** `h : [0, 1] → [0, 1]`

**Scaling (by protocol):**

```
price_descent(t) = last_rent_price - (last_rent_price - min_rent_price) · h(t / descent_ceiling)
```

**Constraints on `h`:** identical to `g` — same type, same four constraints.

**Bijectivity:** `f_price_descent : [0, descent_ceiling] ↔ [min_rent_price, last_rent_price]`.

**Concrete families:** same as `g` (power-law, exponential, smoothstep). `g` and `h` share the same type. The economic direction (ascent vs descent) comes from the protocol's application, not the shape.

### 5.3 `f_next_rent_price`

**Type:** `f : last_rent_price → next_rent_price`

**Constraint:** `f(last_rent_price) > last_rent_price` — strictly one-dimensional, no time or state dependency.

**Concrete implementations:**

| Variant | Definition |
|---|---|
| FixedDelta { delta } | `f(x) = x + delta` |
| Percentage { bps } | `f(x) = x * (10000 + bps) / 10000` |
| CompoundDelta { bps, delta } | `f(x) = x * (10000 + bps) / 10000 + delta` |


6. INTEGRATION PARAMETERS
--------------------------

All set once at integration time. Immutable for the lifetime of that instance. To change: retire (from Idle) → re-integrate.

| Parameter | Constraints |
|---|---|
| `min_rent_price` | `> 0` |
| `tenure_ceiling` | `> 0`, `handover_floor <= tenure_ceiling` |
| `handover_floor` | `0 < handover_floor <= tenure_ceiling` |
| `descent_ceiling` | `> 0` |
| `g` (credit shape) | `g(0)=0, g(1)=1, bounded [0,1], strictly increasing` |
| `h` (descent shape) | same constraints as `g` |
| `f_next_rent_price` | `f(x) > x` for all valid x |
| `payment_token` | Fungible token with deterministic value |

**`retire()`:** Sole exit mechanism. Behavior by state:

| State | Effect |
|---|---|
| At Dutch Auction | Immediate → Retired |
| Rented (handover_open) | Sets `retire` flag. Blocks new bids. Tenant completes full block. At tenure expiry → Retired (not Dutch Auction). |
| Rented (handover_confirmed) | Sets `retire` flag. Handover completes normally. T(n+1) enters `handover_open` with flag active (no new bids). T(n+1) completes full block. At tenure expiry → Retired. |
| Idle | Immediate → Retired |


7. THE NATIVE TOKEN DEMAND CIRCUIT
-----------------------------------

When an integrating protocol uses its own native token `$X` as `payment_token`, the rental market creates an organic demand loop for that token.

**Mechanism:** Any participant who wants to acquire the usus of the asset must first acquire `$X`. Competing for the asset converts directly into buy pressure on the native token — not speculative demand, but operational demand.

**The feedback loop:**

```
demand for usus
    → acquire $X to bid
    → buy pressure on $X
    → rising last_rent_price → more $X required per cycle
    → owner earnings in $X → aligned incentive to hold $X
    → protocol fees in $X → treasury grows in $X
    → stronger ecosystem → more demand for the asset
    → demand for usus
```

**Self-limiting property:** The loop is grounded in the utility-grounded value principle. If the asset's usus loses real value, rental demand collapses and token demand from this source disappears. The circuit cannot sustain itself on price speculation alone.

**Design implication:** Integration parameters directly shape the circuit's intensity. `min_rent_price` too high → no participants → no token demand. `f_next_rent_price` increment too large → rapid price escalation, concentrated participation. `tenure_ceiling` too long → slow rotation, weak demand circuit.

Full analysis: §15 of design document.


9. LAZY EVALUATION
------------------

The protocol stores only:
- **Immutable parameters** (set at integration)
- **Phase anchors** (`last_rent_price`, `phase_start_ms`, `handover_countdown_expiry`)

State is always derivable:

```
current_state = f(immutable_params, phase_anchors, clock::timestamp_ms())
```

Functions are pure and deterministic. No keeper, no off-chain coordinator, no liveness assumption. Every state transition is resolved lazily by the next transaction that touches the shared object. Gas paid by whoever initiates the interaction.


10. GLOSSARY (CONDENSED)
------------------------

### Prices

| Term | Meaning |
|---|---|
| `min_rent_price` | Floor. Lowest valid rental price. Lower bound of Dutch Auction. |
| `last_rent_price` | Price paid by current tenant. Entry barrier for takeover. |
| `next_rent_price` | `f_next_rent_price(last_rent_price)`. Exact price to displace. Always > `last_rent_price`. |
| `price_descent` | Live Dutch Auction price. Descends from `last_rent_price` to `min_rent_price`. |

### Credit

| Term | Meaning |
|---|---|
| `used_credit` | Portion earned by owner. Grows 0 → `last_rent_price` over rental. |
| `remain_credit` | Portion refundable to tenant. `used_credit + remain_credit = last_rent_price`. |

### Time

| Term | Meaning |
|---|---|
| `tenure_ceiling` | Fixed duration of each rental block. |
| `handover_floor` | Fixed duration of competitive bidding window after takeover bid. |
| `handover_countdown_expiry` | Timestamp of access transfer. Computed deterministically at first bid, fixed. |
| `descent_ceiling` | Max Dutch Auction duration. |


### Actions

| Term | Meaning |
|---|---|
| Takeover | Displace current tenant by paying `>= next_rent_price`. Starts `handover_countdown`. |
| Handover | Automatic access transfer at `handover_countdown_expiry`. Resolved lazily. |
| Renewal | Self-takeover. Net cost = `increment + consumed_rent`. |
