# Liquid Renting Protocol — Technical Specification

**Version:** 1.0.0-draft
**Target Runtime:** Sui Move
**Authors:** [Protocol Team]
**Status:** Draft — For Review

---
## Abstract

Historically, the right of full ownership (dominium) over an asset is grounded in three faculties defined by Roman law:

**Usus:** The right to use the asset without altering its essence or appropriating its fruits.

**Fructus:** The faculty to receive the yields or fruits the asset produces, whether natural or civil.

**Abusus:** The absolute attribute that defines the owner — the right to dispose of the asset (sell it, modify it, or destroy it).

The logic of contemporary leasing is not far from the ancient Roman locatio conductio rei: it consists of a temporary and fragmented transfer of these faculties. In a traditional arrangement, the lessor (owner) retains the abusus, while the lessee (tenant) temporarily acquires the right over the usus and fructus.

The process of renting an asset has historically been governed by two implicit assumptions:

**Rigid temporality:** The rental occurs for a fixed and predetermined period of time.

**Exclusivity:** During that period, the tenant holds an exclusive monopoly over the usus and fructus of the asset.

Liquid Renting Protocol challenges both assumptions. This protocol redefines the traditional rules of renting, introducing a dynamic model that loosens time constraints and breaks the exclusivity of usus and fructus over a rented asset.

---

## Table of Contents

1. [Motivation](#1-motivation)
2. [Core Principles](#2-core-principles)
3. [Asset State Flow - High Level](#3-asset-state-flow-high-level)
4. [Asset State Flow - Low Level](#4-asset-state-flow-low-level)
5. [Tenant Compensation Mechanism](#5-tenant-compensation-mechanism)
6. [Incentive-driven Functions](#6-incentive-driven-functions)
7. [Glossary](#7-glossary)
8. [Integration Parameters](#8-integration-parameters)
9. [Asset Custody and Transfer Model](#9-asset-custody-and-transfer-model)
10. [The Renewal Mechanism](#10-the-renewal-mechanism)
11. [Attack Vectors and Protocol Resilience](#11-attack-vectors-and-protocol-resilience)

---

## 1. Motivation

The rental market generates a problem inherent to its own nature. Demanding total exclusivity over the usus and fructus of an asset inevitably creates an illiquidity problem. Rented assets cannot remain on sale or open for negotiation, since their rights of use and enjoyment are locked within a temporary monopoly.

How can the usus and fructus of a rented asset be kept liquid and on the market while their exclusive right temporarily belongs to someone? And if this were possible without punitive models for the current tenant, we would achieve:

**Continuous and uninterrupted liquidity:** Transforming a static market into a dynamic one, where usage rights can be traded in real time without requiring the termination of the original contract.

**Efficient secondary markets:** Allowing the current tenant to transfer, sell, or delegate their position to a third party without friction, giving them a fair exit path and recovering the value of unused time.

**Maximization of capital efficiency:** The asset is never economically immobilized. The market can continue discovering the real rental price based on current supply and demand, not past estimates.

This is possible, and it is called **Liquid Renting**.

---

## 2. Core Principles

The Liquid Renting model is designed to apply fundamentally to rental assets that meet the following non-negotiable principles:

**Utility-grounded value:** The intrinsic value of the asset must reside strictly in its capacity to be used (usus) and in the yields or cash flows derived from it (fructus), rather than in mere speculation over its ownership. This principle extends to market participation: the rational motive for entering the rental market is the value derived from holding and using the asset, not the expectation of a profit on displacement. The protocol does not reward speculation — a displaced tenant recovers only the unused portion of their payment, never a gain from price appreciation.

**Proven organic demand:** The asset must generate genuine interest and possess real traction. The protocol optimizes liquidity, fractions time, and eliminates friction — but operates under an immutable economic premise: no technology or protocol can create sustainable demand for an asset that lacks a market.

## Protocol Purpose

The protocol has been designed as a new modular DeFi infrastructure primitive. Its goal is to provide a standardized Liquid Renting logic layer that can be integrated agnostically by any ecosystem.

By importing this module, developers can equip their native assets with a liquid rental architecture, allowing utility (usus) and yield (fructus) to flow programmatically without compromising the asset's availability in the market.

---

## 3. Asset State Flow (High-Level View)

![Asset State Transition Flow](./media/8.png "Asset State Transition Flow")

The lifecycle of an asset within the Liquid Renting protocol is governed by a strict state flow. This model ensures that the transfer of usus and fructus executes predictably, maintaining continuous liquidity of the asset.

The following details the state machine through which any integrated asset transitions:

### 1. State Definitions (Asset States)

**State 0: Idle (Baseline / Price Floor):**
The entry or resting state. The asset is available at the base rental price. No usage right is committed. The usus and fructus are waiting for a first tenant to inject the liquidity necessary to activate the protocol.

**State 1: Rented (Position Secured):**
The tenant has acquired the monopoly over usus and fructus through upfront liquidity injection. In this state, the tenant does not trade the asset — they enjoy its utility while their position remains active. The injected liquidity is bound to the asset. This state has two sub-states:

- **rented_handover_open:** No next tenant has paid yet. The current tenant holds usus and fructus with no pending displacement.
- **rented_handover_confirmed:** A new tenant has paid `next_renting_price`. The `handover_countdown` is running. The current tenant retains usus and fructus until the countdown expires, at which point the asset transfers to the last tenant who placed a valid bid.

**State 2: At Dutch Auction (Price Discovery):**
A market rebalancing mechanism. If the asset is no longer rented and the market does not validate the last known rental price, a descending Dutch Auction is triggered. The goal is to perform a dynamic liquidation of the rental price until a new equilibrium is found where demand once again absorbs the usus of the asset.

**State 3: Retired (Off-boarding):**
The exit state from the protocol. An asset can only be retired when it is in the Idle state (no active usage commitments). At this point, the integration module revokes rental permissions and the usus/fructus is reintegrated into the absolute domain (abusus) of the original issuer or owner, exiting the protocol's liquidity circuit.

### 2. State Transitions

The flow of the asset between states obeys strict rules of liquidity and time, ensuring the market always has the final word on the value of the usus.

**Idle ➔ Rented (Initial Activation):**
A user injects the initial liquidity corresponding to the asset's base rental fee. The protocol assigns the usus and fructus, initiating a rental time block that is fixed and immovable by the protocol's architecture.

**Rented ↺ (Takeover / Market Relay):**
Even while the asset is rented, its usus remains liquid. If the market values the asset above the current price, a new tenant can inject liquidity at a higher price. In doing so:

- The last known rental price in the protocol is updated.
- A new full time block is initialized for the new tenant.
- The displaced tenant is economically compensated: they receive their `remaining_credit` — the value of unused time still locked in the protocol.

The physical transfer of the right is governed by the `handover_countdown`, detailed in Section 5.

**Rented ➔ At Dutch Auction (Exhaustion and Liquidation):**
This transition requires two conditions to be true simultaneously: the current tenant's time block is exhausted (`remaining_credit = 0`) AND the asset is in the `rented_handover_open` sub-state. If a next tenant has already paid (`rented_handover_confirmed`), the asset transfers directly to them — the Dutch Auction is bypassed entirely, as demand is already confirmed.

**At Dutch Auction ➔ Rented (Price Discovery):**
During the auction, a new buyer accepts the current descending price and injects the required liquidity. They automatically assume the usus of the asset, initiating a new time block and returning the system to State 1.

**At Dutch Auction ➔ Idle (Lack of Demand):**
If the auction descends to the lower bound (price floor) and the market does not absorb the asset, it returns to the Idle state, waiting for reactivation.

**Idle ➔ Retired (Delisting):**
From the resting state, the integration module evaluates the asset's situation. If it determines that no real market or genuine interest exists to justify its continued presence, it executes the asset's permanent withdrawal from the protocol.

**Idle ↺ Retired (Parameter Reconfiguration):**
The retire → re-integrate cycle is the protocol's only mechanism for changing integration parameters. The owner retires the asset from `Idle`, adjusting any parameters, and re-introduces it — which places the asset back into `Idle` under the new configuration. This cycle is the natural feedback loop for integrators experimenting with incentive shapes: poor parameters drive the asset to `Idle` frequently, making reconfiguration fast and low-cost. The protocol is forgiving by design — wrong parameters surface quickly and the correction path is always available.

---

## 4. Asset State Flow (Low-Level View)

At a deeper level, the Liquid Renting architecture operates as a dynamic equilibrium system between consumed time and market valuation.

### 1. The Resting State (State 0: Idle)

![Asset State Transition Flow](./media/1.png "Asset State Transition Flow")

The initial equilibrium point. The asset_descent_price equals the asset_min_renting_price. The asset is "open" with no liquidity barrier protecting its usus.

### 2. The Consumption and Competition Cycle (State 1: Rented)

![Asset State Transition Flow](./media/2.png "Asset State Transition Flow")
![Asset State Transition Flow](./media/3.png "Asset State Transition Flow")
![Asset State Transition Flow](./media/4.png "Asset State Transition Flow")

Once a user injects liquidity, the asset enters a state of active utilization that is, by definition, a renewable cycle:

**Price as Entry Barrier:** When renting the asset, the user purchases at next_renting_price(), establishing a new asset_last_renting_price. This value acts as a physical liquidity barrier: any other actor wishing to access the usus of the asset must "clear" this barrier by injecting capital greater than next_renting_price(). A higher price than next_renting_price() is allowed.

**The Takeover Dynamic (Cycle Reactivation):** If a new renter pays a higher price before the time runs out, the cycle restarts instantaneously:

- The new price becomes the new "barrier" (asset_last_renting_price).
- The consumption vector (Red Arrow) — consumption_credit_strategy — resets to zero.
- The new tenant's credit block is initialized at their full entry price P(n+1) — unconsumed, starting from zero.

**The Trigger:** The transition to auction only occurs if the market does not validate the asset_last_renting_price known. That is, if no one clears the barrier established by the last tenant before their used_credit reaches the limit of asset_last_renting_price. In practice, the current tenant only reaches the end of the road if they were the last one to establish asset_last_renting_price.


### 3. Price Discovery (State 2: At Dutch Auction)

![Asset State Transition Flow](./media/5.png "Asset State Transition Flow")
![Asset State Transition Flow](./media/6.png "Asset State Transition Flow")
![Asset State Transition Flow](./media/7.png "Asset State Transition Flow")

When the entry barrier (the price) proves too high for current demand and the last tenant's used_credit is exhausted, the protocol initiates the liquidation:

**Descent Strategy (Green Arrow):** The price_discovery_strategy begins eroding the entry barrier. The asset_descent_price descends from the last known maximum.

**Resolution:** The moment the descending price reaches a point the market finds attractive, a new user injects that liquidity, the asset returns to State 1, and a new entry barrier is established — restarting the utility cycle. Otherwise, the asset_descent_price equals the asset_min_renting_price and the asset enters the Idle state.

---

## 5. Tenant Compensation Mechanism

The compensation mechanism is the economic guarantee that makes liquid renting viable. It ensures that any displaced tenant always recovers the unused portion of their payment, and that the incentive to enter the rental market remains rational at every price level.

The compensation is strictly bounded by the tenant's own stake. No price appreciation flows to displaced tenants — the protocol deliberately excludes this. Displacement is a neutral-to-negative economic event for the outgoing tenant: they recover `remaining_credit` and absorb `used_credit` as the cost of the time they held the asset. This design is a direct consequence of the utility-grounded value principle: if a tenant's motivation is the usus and fructus of the asset, displacement interrupts that utility and the partial refund is fair compensation. If a tenant's motivation is speculation on price appreciation, the protocol offers no support for that strategy.

### 1. The Consumption Function

At the core of the mechanism lies the `consumption_rent_credit` function. This function couples time and credit into a single unified variable: as time elapses, the used credit grows, and the remaining credit shrinks. The function is defined to pass through two fixed points:

- `(t = 0, consumed = 0)` — at the start of a rental, no credit has been consumed.
- `(t = T_rent, consumed = Pn)` — at the end of the rental period, all credit is exhausted.

This means time and credit are not independent: **when the clock runs out, the credit is exactly zero**. The two conditions are one and the same event seen from two dimensions. The exact shape of the curve between these two points (linear, convex, concave) is defined by the `consumption_credit_strategy` and will be detailed in the Incentive-driven Functions section.

At any moment during an active rental, the following invariant holds:

```
used_credit + remaining_credit = Pn
```

### 2. Takeover and Compensation

While a tenant Tn holds the usus at price Pn, the asset remains liquid. Any market participant may displace Tn by injecting a new price `P(n+1) > Pn`. When this occurs:

**Tn receives:**
- `remaining_credit` — the unused portion of their own locked payment, returned directly from the protocol.

**The asset owner (integrating protocol) receives:**
- `used_credit` — the portion of Pn that corresponds to time already consumed. This is the rent earned for the usus already delivered.

**T(n+1)'s new rental block:**
- T(n+1) injects `P(n+1)`, which is locked in full as their rental stake. The `consumption_rent_credit` function resets and runs from `(t=0, 0)` to `(t=T_rent, P(n+1))`.

### 3. Invariants and Guarantees

**The displaced tenant always recovers unused time.** Since the takeover can only occur while `remaining_credit > 0` (i.e., before time expires and the Dutch Auction is triggered), Tn always receives a strictly positive refund. A net loss relative to the entry price is possible when significant credit has already been consumed — the guarantee is that the displaced tenant always receives something, not that they profit from displacement.

**The pattern is symmetric.** For any sequence of tenants T1, T2, ..., Tn at prices P1 < P2 < ... < Pn:

| Event | Tenant receives | Owner receives |
|---|---|---|
| T2 displaces T1 at P2 | `remaining_T1` | `used_T1` |
| T3 displaces T2 at P3 | `remaining_T2` | `used_T2` |
| Tn displaces T(n-1) at Pn | `remaining_T(n-1)` | `used_T(n-1)` |

**Each new block is fully funded.** T(n+1) injects `P(n+1)`, which is locked in full as their rental stake. The consumption function runs from `(t=0, 0)` to `(t=T_rent, P(n+1))`. The displaced tenant Tn receives only their `remaining_credit` from their own previously locked stake — no delta flows from the incoming payment. The arithmetic is exact: Tn's `used_credit` goes to the owner, Tn's `remaining_credit` returns to Tn, and T(n+1)'s `P(n+1)` is held in full as their new stake.

### 4. Dutch Auction as Boundary Condition

If no T(n+1) arrives before Tn's time expires, `used_credit` reaches `Pn` and `remaining_credit` reaches zero simultaneously. There is no remaining stake to return to Tn — it has been fully delivered to the owner as earned rent.

At this point, the Dutch Auction is triggered. It carries no stake of its own. Its sole function is to prevent the last known price Pn from freezing as the market entry barrier, allowing the price to descend until a new tenant finds it attractive and injects liquidity, restarting the cycle.

### 5. The Handover Countdown

#### Definition

When a new tenant T(n+1) pays `next_renting_price`, the asset transitions to `rented_handover_confirmed` and a countdown begins:

```
handover_countdown = min(handover_floor, remaining_rent_time)
```

Where `handover_floor` is a protocol-level parameter constrained by:

```
0 ≤ handover_floor ≤ tenure_ceiling
```

The `handover_countdown` is fixed at the moment the first bid arrives. Subsequent bids during the countdown do not restart it — it keeps running from the moment it began.

#### Dual Guarantee

The `handover_countdown` serves two roles simultaneously:

- **For the current tenant Tn:** a guaranteed minimum window of usus and fructus after being displaced. The protocol cannot transfer the asset before this countdown expires.
- **For the asset owner:** a guaranteed minimum `used_credit`. Since the consumption function keeps running during the countdown, the owner earns rent for every second of Tn's remaining use.

#### Consumption During the Countdown

The `f_credit_ascent` function continues running throughout the `handover_countdown`. Tn retains full usus and fructus until the physical handover. As a consequence, Tn's `remaining_credit` at the moment of handover is lower than at the moment T(n+1) paid — the difference is additional earned rent for the owner.

#### Multiple Bids During the Countdown

The asset continues accepting new bids while in `rented_handover_confirmed`. If T(n+1), T(n+2), ... all pay during the same countdown window:

- The countdown does not restart — it keeps running from the original start.
- Each intermediate bidder (all except the last) receives their full injection returned immediately.
- The asset transfers to the **last** tenant who placed a valid bid before the countdown expired.
- Tn's compensation is calculated at the moment of physical handover: `remaining_credit_at_handover` — the unused portion of their stake at the time of physical transfer.

#### New Tenant's Cycle

T(n+1)'s rental cycle — and their `f_credit_ascent` clock — begins at physical handover, not at payment. The time between payment and handover is the `handover_countdown` itself, during which T(n+1) holds a confirmed position but has not yet received the usus.

#### Dutch Auction Bypass

If the `handover_countdown` exhausts Tn's remaining time (`handover_countdown = remaining_rent_time`), then `remaining_credit` reaches zero exactly at handover. In this case the asset passes directly to the confirmed next tenant — the Dutch Auction is never triggered. The `rented_handover_confirmed` sub-state is proof of existing demand, making the price discovery mechanism unnecessary.

#### Edge Cases

- **`handover_floor = 0`:** The handover is instantaneous. The moment T(n+1) pays, Tn loses the asset with no guaranteed window.
- **`handover_floor = tenure_ceiling`:** The countdown equals the full rental block. The current tenant is guaranteed the entirety of their remaining time before any handover — equivalent in behavior to a traditional fixed-term lease, with the liquid renting compensation mechanics preserved.

---

## 6. Incentive-driven Functions

The Liquid Renting Protocol exposes a set of pluggable functions that govern the economic behavior of the protocol without prescribing a single strategy. Each function must satisfy a set of formal constraints, but its exact shape is left to the integrating protocol, which selects it according to the market behavior it wishes to incentivize.

The three functions are the only configuration points of the protocol. Their responsibilities are exclusive and non-overlapping — the integrating protocol selects each one independently without risk of interference between them:

| Function | Active state | Price direction | Independent variable |
|---|---|---|---|
| `f_credit_ascent` | Rented | — (consumes credit) | time |
| `f_price_descent` | At Dutch Auction | descends only | time |
| `f_next_renting_price` | Rented (takeover) | ascends only | price |

Price can only descend in one place in the protocol: the Dutch Auction. Everywhere else, it ascends or holds.

---

### 6.1 `f_credit_ascent(t_rented)`

#### Purpose

This function defines the rate at which a tenant's rental credit is consumed over the duration of their rental period. It is the mechanism that couples time and economic stake into a single unified variable.

#### Formal Definition

```
f_credit_ascent : [0, tenure_ceiling] → [0, last_renting_price]
```

#### Constraints

The function must satisfy the following conditions:

1. **Origin:** `f(0) = 0` — at the start of the rental, no credit has been consumed.
2. **Termination:** `f(tenure_ceiling) = last_renting_price` — at the end of the rental period, all credit is exactly exhausted.
3. **Boundedness:** `∀ t ∈ [0, tenure_ceiling] : 0 ≤ f(t) ≤ last_renting_price` — the function is always contained within the bounding rectangle.

Any function satisfying these three constraints is a valid implementation. The protocol imposes no further restriction on its shape.

#### The Dutch Auction Trigger as a Corollary

Constraints (1), (2), and (3) together imply that time exhaustion and credit exhaustion are the same event. When `t = tenure_ceiling`, `f(t) = last_renting_price` by definition — meaning `remaining_credit = 0` at the exact moment the clock reaches zero. These two conditions are not independent; they are two projections of the same point `(tenure_ceiling, last_renting_price)`. The Dutch Auction is therefore triggered when either description is satisfied — they are equivalent.

#### Incentive Implications of Curve Shape

The integrating protocol selects the curve shape to incentivize a specific market behavior:

**Concave curve (e.g., `f(t) = Pn · √(t / T)`):** Credit is consumed rapidly at the start and slowly toward the end. A tenant displaced early recovers little `remaining_credit`. This penalizes speculative entry — entering with the expectation of a quick takeover and a large refund is costly, since the curve has already consumed most of the credit. Suited for protocols that want to discourage high-frequency rotation and reward sustained usage.

**Linear curve (`f(t) = Pn · (t / T)`):** Credit is consumed proportionally to time. The protocol takes no position on when rotation is more or less convenient. Agnostic and neutral.

**Convex curve (e.g., `f(t) = Pn · (t / T)²`):** Credit is consumed slowly at the start and accelerates toward the end. A tenant displaced early still holds a large `remaining_credit`, making entry safer. This incentivizes rotation — the cost of entering is partially recoverable at any early point, lowering the risk of taking a position. Suited for protocols that want high liquidity and active price discovery.

---

### 6.2 `f_price_descent(t_at_auction)`

#### Purpose

This function defines the rate at which the `descent_price` decays during a Dutch Auction. It is the symmetric counterpart to `f_credit_ascent`: where the first function drives a value upward from zero to a ceiling, this function drives a value downward from a ceiling to a floor.

#### Formal Definition

```
f_price_descent : [0, descent_ceiling] → [min_renting_price, last_renting_price]
```

#### Constraints

The function must satisfy the following conditions:

1. **Origin:** `f(0) = last_renting_price` — the auction begins at the last known rental price, the barrier the market failed to validate.
2. **Termination:** `f(descent_ceiling) = min_renting_price` — if no buyer is found, the price reaches the floor and the asset returns to Idle.
3. **Boundedness:** `∀ t ∈ [0, descent_ceiling] : min_renting_price ≤ f(t) ≤ last_renting_price` — the function is always contained within the bounding rectangle.

The function is monotonically non-increasing — the price can only descend during a Dutch Auction.

#### Symmetry with `f_credit_ascent`

Both functions share an identical structural contract: two fixed endpoints and a boundedness constraint. The protocol prescribes no curve shape beyond these. The symmetry is exact:

| | `f_credit_ascent` | `f_price_descent` |
|---|---|---|
| Fixed point at t=0 | `f(0) = 0` | `f(0) = last_renting_price` |
| Fixed point at t=T | `f(T_rent) = last_renting_price` | `f(T_auction) = min_renting_price` |
| Bounded by | `[0, last_renting_price]` | `[min_renting_price, last_renting_price]` |
| Direction | Monotonically non-decreasing | Monotonically non-increasing |

This design decision — fixing both endpoints and leaving the interior free — is deliberate. The space of valid curves between two fixed points is already vast enough to express any incentive behavior the integrating protocol may require. Adding discontinuities or free starting points would introduce complexity without expanding expressive power.

#### Scaling Behavior and the Role of `last_renting_price`

Both functions can be decomposed into a pure shape component and a price-dependent scale factor:

```
f_credit_ascent(t)  = last_renting_price · g(t / tenure_ceiling)
f_price_descent(t)  = last_renting_price - (last_renting_price - min_renting_price) · h(t / descent_ceiling)
```

Where `g` and `h` are the normalized shape functions mapping `[0,1] → [0,1]`, chosen freely by the integrator.

As `last_renting_price` grows through successive takeovers, both functions scale accordingly:

Both functions have a fixed range within their active state — the range does not change during execution. What grows across successive cycles is the amplitude of each function, because `last_renting_price` rises with each takeover:

- **`f_credit_ascent`** has amplitude `last_renting_price` (floor fixed at 0). At any given time fraction `t/T`, the absolute credit consumed scales proportionally with `last_renting_price`. A tenant who paid twice the price pays twice the rent per unit of time.

- **`f_price_descent`** has amplitude `last_renting_price - min_renting_price` (floor fixed at `min_renting_price`). At any given time fraction `t/T`, the absolute price shed scales proportionally with `last_renting_price - min_renting_price`. An auction that starts twice as high descends twice as fast in absolute terms per unit of time — the market must absorb proportionally larger price drops to find a new equilibrium.

The duality is symmetric: both functions are anchored by a fixed floor (0 and `min_renting_price` respectively) and a moving ceiling (`last_renting_price`). As the protocol's price history rises, both mechanisms scale their amplitude by the same reference point.

#### Incentive Implications of Curve Shape

The shape of the decay curve determines when buyers are incentivized to act during the auction:

**Concave curve (e.g., `f(t) = last_renting_price - (last_renting_price - min_renting_price) · √(t / T)`):** Price drops sharply at the start and flattens toward the end. Most of the discount is captured early. Incentivizes buyers to act quickly — waiting yields diminishing returns.

**Linear curve:** Price decays at a constant rate. Neutral. No moment in the auction is structurally more attractive than another.

**Convex curve (e.g., `f(t) = last_renting_price - (last_renting_price - min_renting_price) · (t / T)²`):** Price remains high for most of the auction and falls steeply at the end. Incentivizes patient buyers to wait — the largest discounts arrive late. Creates a "cliff" dynamic near `descent_ceiling`.

---

### 6.3 `f_next_renting_price(last_renting_price)`

#### Purpose

This function defines the minimum price a new tenant must inject to legally displace the current one. It is the protocol's sole anti-penny-jumping and anti-griefing mechanism, and the only force that drives prices upward during the Rented state.

#### Formal Definition

```
f_next_renting_price : last_renting_price → next_renting_price
```

The function is strictly one-dimensional. The only input is `last_renting_price`. No time variable, no state dependency.

#### Constraints

1. **Strict increase:** `f(last_renting_price) > last_renting_price` — the next price must always be strictly greater than the last.

Any function satisfying this constraint is a valid implementation.

#### Design Rationale: Why One Dimension

Two alternative designs were considered and rejected:

A time-dependent minimum increment — where the required premium decreases as the tenant's block is consumed — was discarded because it introduces a second price-lowering mechanism during the Rented state, competing directly with `f_price_descent`. In this protocol, price descent has exactly one owner: the Dutch Auction. During the Rented state, price only moves upward.

A minimum increment dependent on `remaining_credit` was rejected for the same reason: as `remaining_credit → 0`, the required increment approaches zero, implicitly encoding a time-based price reduction. Same redundancy, different variable.

The one-dimensional form is not a simplification — it is the correct design. Each function in the protocol has a single, non-overlapping responsibility.

#### The Increment as a Critical Design Parameter

The size of the increment defined by `f_next_renting_price` carries more weight in this protocol than it might initially appear. The self-renewal cost for the current tenant is:

```
renewal_cost = used_credit + (P(n+1) - Pn)
```

Where `(P(n+1) - Pn)` is the increment. This means the increment is **a direct component of the incumbent's defense cost**, not merely a barrier against external competitors. The integrating protocol must balance two competing forces:

**A small increment** (δ → 0): Self-renewal is cheap — the incumbent pays nearly `used_credit` to reset their block. However, a small increment also exposes the protocol to griefing — a well-funded actor can execute repeated takeovers at negligible cost, continuously disrupting tenants (Attack Vector 1).

**A large increment**: Self-renewal is expensive — the incumbent must pay significantly above `used_credit` to maintain their position. This weakens the structural advantage and makes sustained hold more capital-intensive. On the other hand, it accelerates genuine price discovery and makes the asset more accessible to competing market participants.

There is no universally correct increment. The integrating protocol must select a `f_next_renting_price` that reflects the specific competitive dynamics of the asset: how actively it is contested, the capital profile of expected participants, and how aggressively genuine price discovery should be driven.

#### The Renewal Mechanism as an Implicit Consequence

The protocol places no restriction on the identity of the new tenant. `f_next_renting_price` is evaluated against a price, not a party. This means the current tenant Tn is free to invoke a takeover against themselves, paying `P(n+1) = f_next_renting_price(Pn)`.

The mathematics of the compensation mechanism produce a clean result. Tn pays `P(n+1)` and simultaneously receives, as the displaced tenant, `remaining_credit`. Their net cost is:

```
P(n+1) - remaining_credit
= P(n+1) - Pn + used_credit
```

**The tenant pays the minimum increment plus what they have already consumed.** The unconsumed portion is returned, the block resets to `P(n+1)`, and the clock starts over.

This renewal mechanism was never explicitly designed into the protocol. It is a free consequence of the compensation invariant and the identity-agnostic takeover rule. When simple rules produce emergent behaviors that are both useful and mathematically clean, it is a signal that the underlying design is sound.

---

## 7. Glossary

### Actors

**Tenant (Tn):** The party that holds the usus and fructus of an asset at price Pn. Identified by their position in the sequence T1, T2, ..., Tn.

**Owner:** The integrating protocol that issued the asset. Receives `used_credit` as earned rent for every consumed time unit.

### Roman Law Concepts

**Usus:** The right to use the asset without altering its essence. The faculty the protocol transfers temporarily to each tenant.

**Fructus:** The right to receive the yields or cash flows the asset produces. Held by the current tenant alongside usus.

**Abusus:** The right to dispose of the asset — sell, modify, or destroy it. Retained by the owner at all times. Never transferred by this protocol.

### Asset States

**Idle:** The resting state. The asset is available at `min_renting_price` with no active usage commitment.

**Rented:** The active state. A tenant holds usus and fructus. Has two sub-states:

- **`rented_handover_open`:** No next tenant has paid yet. The current tenant holds the position with no pending displacement.
- **`rented_handover_confirmed`:** A next tenant has paid `next_renting_price`. The `handover_countdown` is running toward physical transfer.

**At Dutch Auction:** The price discovery state. Triggered when `used_credit = Pn` (time exhausted) and the asset is in `rented_handover_open`. The `descent_price` descends via `f_price_descent` until a new tenant enters or the floor is reached.

**Retired:** The terminal state. The asset exits the protocol permanently from Idle. Usus and fructus are reabsorbed into the owner's abusus.

### Prices

**`min_renting_price`:** The price floor. The lowest valid rental price and the lower bound of the Dutch Auction descent.

**`last_renting_price`:** The price paid by the current tenant. Acts as the entry barrier — any takeover must exceed this value via `f_next_renting_price`.

**`next_renting_price`:** The minimum price required to legally displace the current tenant. Always strictly greater than `last_renting_price`. Defined by `f_next_renting_price`.

**`descent_price`:** The live price during a Dutch Auction. Descends from `last_renting_price` to `min_renting_price` via `f_price_descent`.

### Credit

**`used_credit`:** The portion of a tenant's locked payment that has been earned by the owner. Grows monotonically from 0 to `last_renting_price` over the rental period.

**`remaining_credit`:** The portion of a tenant's locked payment not yet consumed. Returned to the tenant on takeover. At any moment: `used_credit + remaining_credit = last_renting_price`.

### Time Parameters

**`tenure_ceiling`:** The fixed duration of each rental block. The maximum time any tenant can hold the asset in a single position. Constraint: `handover_floor ≤ tenure_ceiling`.

**`handover_floor`:** The minimum guaranteed usage window for the current tenant after a takeover is initiated. Protocol parameter constrained by `0 ≤ handover_floor ≤ tenure_ceiling`.

**`handover_countdown`:** The actual countdown to physical transfer, calculated at the moment the first bid arrives: `min(handover_floor, remaining_rent_time)`. Fixed once started — subsequent bids do not restart it.

**`descent_ceiling`:** The maximum duration of a Dutch Auction. If no buyer is found within this window, the price reaches `min_renting_price` and the asset returns to Idle.

### Incentive-driven Functions

**`f_credit_ascent(t_rented)`:** Defines how `used_credit` grows over time during a rental. Must pass through `(0, 0)` and `(tenure_ceiling, last_renting_price)`, bounded within the rectangle. Shape is chosen by the integrating protocol.

**`f_price_descent(t_at_auction)`:** Defines how `descent_price` decays during a Dutch Auction. Must pass through `(0, last_renting_price)` and `(descent_ceiling, min_renting_price)`, monotonically non-increasing. Symmetric counterpart to `f_credit_ascent`.

**`f_next_renting_price(last_renting_price)`:** Defines the minimum price to displace the current tenant. Strictly one-dimensional. Must satisfy `f(last_renting_price) > last_renting_price`.

### Actions

**Takeover:** The act of displacing the current tenant by paying `next_renting_price`. Transitions the asset to `rented_handover_confirmed` and starts the `handover_countdown`.

**Handover:** The physical transfer of usus and fructus from the outgoing tenant to the incoming tenant when `handover_countdown` expires.

---

## 8. Integration Parameters

The following parameters must be provided by any protocol integrating Liquid Renting. They are the complete configuration surface of the protocol — nothing else is required.

| Parameter | Type | Description | Constraints |
|---|---|---|---|
| `asset` | Object | The asset to be placed under the Liquid Renting protocol. | Must not already be under an active rental position. |
| `min_renting_price` | Amount | The price floor. The lowest valid rental price and the lower bound of `f_price_descent`. | `min_renting_price > 0` |
| `tenure_ceiling` | Duration | Maximum duration of a single rental block. | `tenure_ceiling > 0` ; `handover_floor ≤ tenure_ceiling` |
| `handover_floor` | Duration | Minimum guaranteed usage window for the current tenant after a takeover is initiated. | `0 ≤ handover_floor ≤ tenure_ceiling` |
| `descent_ceiling` | Duration | Maximum duration of a Dutch Auction before the price reaches `min_renting_price` and the asset returns to Idle. | `descent_ceiling > 0` |
| `f_credit_ascent` | Function | Shape of the credit consumption curve during the Rented state. | `f(0) = 0` ; `f(tenure_ceiling) = last_renting_price` ; `∀ t : 0 ≤ f(t) ≤ last_renting_price` |
| `f_price_descent` | Function | Shape of the auction price decay curve during the Dutch Auction state. | `f(0) = last_renting_price` ; `f(descent_ceiling) = min_renting_price` ; monotonically non-increasing |
| `f_next_renting_price` | Function | Defines the minimum price required to displace the current tenant. | `f(last_renting_price) > last_renting_price` |
| `payment_token` | Token type | The currency in which all prices and payments are denominated. | Must be a fungible token with deterministic value. |

### Parameter Immutability

All parameters are set once at integration time and are permanently immutable for the lifetime of that integration instance. There is no mechanism to modify them mid-lifecycle — not even during `Idle`.

**The asset lifecycle is:**

```
integrate (enter Idle with fixed params)
    → Idle → Rented → ... → Idle → ...   (params never change)
    → Retired
```

**To change any parameter, the owner must:**

1. Wait for the asset to reach `Idle` — the only state from which retirement is possible.
2. Execute retirement (`Idle → Retired`) — the asset exits the protocol and returns to the owner.
3. Re-introduce the asset as a fresh integration with the new parameters — the asset enters `Idle` again under the new configuration.

This constraint is a trust guarantee for tenants: the rules under which a tenant entered cannot be altered while their position is active, or at any point during the integration instance. The owner retains the abusus — they may retire the asset — but they may not change the conditions of use while the protocol is live.

### Graceful Exit: the `to_retire` Flag

The integrating protocol may set a `to_retire` flag on the asset at any time, regardless of the current state. The flag does not interrupt any active rental or auction — it is a deferred instruction.

When the asset next reaches `Idle` — the only path being a Dutch Auction that exhausted `descent_ceiling` without finding a new tenant — the protocol checks the `to_retire` flag. If set, the asset is transferred directly to the owner and marked `Retired`, bypassing the normal re-entry into the rental cycle.

This gives the owner a graceful, non-disruptive exit path:

- No active tenant is interrupted.
- No auction is aborted.
- The asset simply does not re-enter the market at the next natural resting point.

The `to_retire` flag may also be unset by the owner at any time before the asset reaches `Idle`, cancelling the deferred retirement.

If the asset never reaches `Idle` — because the market perpetually validates its price through continuous takeovers or Dutch Auctions that always find a buyer — the `to_retire` flag never executes. The owner cannot force an exit while demand is active. This is not a limitation of the protocol; it is the signal of a successful asset. An asset that never reaches `Idle` is an asset that never stops generating `used_credit` for its owner. The market has the final word — and a market that never goes quiet is precisely the outcome the protocol was designed to produce.

> **Keep in mind:** Since an asset can only be retired when it reaches `Idle`, the integrating protocol should study carefully what incentive behaviors it wants to produce before setting its parameters. The success of an asset in this protocol is measured by exactly one metric: how rarely it sits idle. Parameters are the only lever the owner has to shape that outcome. Choose them with intention.
>
> **Don't panic** if the asset reaches `Idle` frequently — it simply means the owner can retire and re-integrate often, adjusting parameters with each cycle. Frequent idle periods are not failure; they are an invitation to experiment. The protocol is forgiving by design: wrong parameters surface quickly, and the retire → re-integrate cycle is the natural feedback loop for finding the right configuration.

---

## 9. Asset Custody and Transfer Model

### The Protocol as Escrow

The Liquid Renting Protocol takes full custody of the asset at the moment of integration. From that point, the protocol acts as the authoritative escrow — it is the sole entity responsible for determining who holds the asset at any given moment, based strictly on the state machine.

This design eliminates the need for any external hook or callback to deliver usus and fructus. **Holding the asset is the delivery mechanism.** Whoever has custody of the asset has the usus and fructus. The protocol does not need to know what the asset produces or how it is used — it only needs to know who should hold it.

### Custody by State

| State | Asset held by |
|---|---|
| `Idle` | Protocol (escrow) |
| `Rented` (`rented_handover_open`) | Current tenant |
| `Rented` (`rented_handover_confirmed`) | Current tenant (until `handover_countdown` expires) |
| `At Dutch Auction` | Protocol (escrow) |
| `Retired` | Integrating protocol (returned) |

### Transfer Events

The protocol executes an asset transfer at exactly four moments:

1. **Idle → Rented:** The first tenant pays `min_renting_price`. The protocol transfers the asset from escrow to the tenant.
2. **Takeover → Handover:** When `handover_countdown` expires, the protocol transfers the asset from the outgoing tenant to the incoming tenant.
3. **Rented → At Dutch Auction:** The tenant's `used_credit` exhausts their stake in `rented_handover_open`. The protocol reclaims the asset into escrow.
4. **Idle → Retired:** The integrating protocol requests retirement. The protocol returns the asset from escrow to the integrating protocol.

### Fructus as a Natural Consequence

Because tenants hold the asset directly, fructus flows to them without any protocol intervention. If the asset generates yield, accrues rewards, or produces any on-chain output while held, the tenant captures it naturally by virtue of ownership. The protocol never intermediates fructus — it only intermediates the asset itself.

### Yield During Escrow

Not all assets generate yield while in escrow. Many assets are purely utility-based — they produce nothing while held by the protocol during `Idle` or `At Dutch Auction`. For these assets, escrow yield is a non-issue: there is nothing to distribute.

This section applies exclusively to **yield-bearing assets** — assets that continue to accrue rewards, interest, or any on-chain output regardless of who holds them. For these assets, yield accumulates in the protocol's escrow during vacant periods and must be handled explicitly.

The protocol adopts the following rule: **accumulated escrow yield is delivered to the first tenant who takes the asset out of escrow.**

When a new tenant pays to enter from `Idle` or wins the asset during a Dutch Auction, they receive the full yield accumulated since the asset entered escrow, in addition to the usus and fructus of the asset itself.

This design produces the following incentive properties:

**Urgency to end vacant periods.** The longer the asset sits in escrow, the larger the yield bonus for whoever claims it. This creates positive market pressure to exit vacant states quickly — not through punishment of the owner, but through reward for the incoming tenant.

**Double incentive during Dutch Auction.** As the `descent_price` falls via `f_price_descent`, the accumulated yield bonus grows simultaneously. The combination makes the entry point more attractive than the descending price alone. Actors who would not enter at a given price might be drawn in by the growing yield bonus, resolving the auction earlier.

**Aligned with the owner's interest.** The owner does not receive the escrow yield directly. However, the incentive it creates — faster re-entry into the Rented state — means `used_credit` starts flowing sooner. The owner earns more through occupancy than they would through passive yield accumulation.

---

## 10. The Renewal Mechanism

### Origin

The renewal mechanism was never designed. It appears nowhere in the protocol's intent. It is a free consequence of three rules that were designed for entirely different purposes:

1. **The protocol is identity-agnostic.** `f_next_renting_price` is evaluated against a price, not a party. The protocol has no concept of "same address" or "different address."
2. **The last valid bidder wins.** During `rented_handover_confirmed`, the asset transfers to the last tenant who placed a valid bid before the `handover_countdown` expired.
3. **The displaced tenant always recovers unused time.** Any tenant displaced by a takeover receives `remaining_credit`, returned from their own locked stake.

From these three rules alone, a complete renewal system emerges.

### The Mathematics of Self-Renewal

Suppose Tn holds the asset at price Pn, with some `used_credit` already accumulated. At any moment, Tn may invoke a takeover against themselves — paying `P(n+1) = f_next_renting_price(Pn)`.

The compensation mechanism processes this identically to any takeover. Tn pays P(n+1) and simultaneously receives, as the displaced tenant:

```
remaining_credit
```

Their net cost is:

```
P(n+1) - remaining_credit
= P(n+1) - Pn + used_credit
```

**The tenant pays the minimum increment plus what they have already consumed.** The unconsumed portion is returned, the block resets to `P(n+1)`, and the clock starts over from zero.

### The Structural Asymmetry — The Current Asset Tenant's Advantage

The renewal mechanism creates a structural cost asymmetry between the current tenant and any external competitor — without the protocol encoding it.

When an external actor T(m) pays `P(m+1)` and wins the asset, their net cost is `P(m+1)` — the full price of entry. They have purchased a new block at market price.

When the current tenant Tn self-renews at the same price, their net cost is `P(n+1) - remaining_credit` — the minimum increment plus the rent already consumed. Their advantage over an external competitor is exactly `remaining_credit`: the unused portion of their existing stake that returns to them, a discount no external actor can access.

This asymmetry is not a privilege granted by the protocol. It is a mathematical consequence of the fact that Tn is simultaneously the payer and the displaced party in the same transaction.

### Identity-Agnosticism and the Second-Wallet Game

Because the protocol does not verify identity, a single actor operating two addresses is indistinguishable from two competing actors. Tn may place a renewal bid from a second wallet — the protocol processes it as a standard takeover. The effect is identical: Tn pays `P(n+1) - remaining_credit` net, the block resets, the price rises by the minimum increment.

This is not a loophole. It is the correct behavior. The protocol has no reason to distinguish between a self-renewal and a competitive takeover — both result in a valid new tenant paying a higher price. The market outcome is the same; only the identity of the recipient changes.

### Renewal as a Defensive Mechanism

The renewal mechanism is equally available during `rented_handover_confirmed`. If an external actor T(m) has already placed a bid — initiating the `handover_countdown` — Tn may counter-bid at `P(m+2) = f_next_renting_price(P(m+1))`.

When Tn counter-bids:
- T(m) receives their full `P(m+1)` injection back immediately — they are superseded.
- Tn, as the displaced tenant at Pn, receives `remaining_credit`.
- Tn, as the new winning bidder at P(m+2), will receive the asset when the `handover_countdown` expires.
- Tn's net cost: `P(m+2) - remaining_credit`.

The current tenant can always neutralize a takeover attempt. Their structural advantage — `remaining_credit` — is the discount they hold over any external competitor who must pay `P(m+2)` in full. This advantage is largest at the start of the block and shrinks as credit is consumed.

### The Competitive Bidding Window

The `handover_countdown` is not merely a grace period for the current tenant. It is an open competitive window during which any number of actors may bid for the asset. The rules are simple:

- Each new valid bid supersedes the previous one.
- The superseded bidder is refunded immediately and in full.
- The `handover_countdown` keeps running from its original start — it does not reset.
- The asset transfers to whoever holds the winning bid when the countdown expires.

This creates a transparent ascending auction of bounded duration. The current tenant participates in this auction with a structural cost advantage — their net cost is always `P_bid - remaining_credit`, strictly less than the full price any external bidder must pay. The advantage is proportional to `remaining_credit`: maximum at the start of a block, approaching zero as the block nears expiry. The market resolves who values the position more.

### The Cost of Abusing the Defense

The structural advantage of the current tenant is real, but it is self-limiting. Each defensive counter-bid invokes `f_next_renting_price`, raising `last_renting_price` by the minimum increment. The tenant neutralizes the competitor — but anchors their new block to a progressively higher price.

If Tn counter-bids repeatedly against successive challengers, arriving at `P(n+k)`:

- Tn is now the last to have established `last_renting_price = P(n+k)` — the asset is in `rented_handover_open`.
- Their `f_credit_ascent` runs from `0` to `P(n+k)`, a ceiling far above their original entry.
- If the market does not validate this elevated price — if no new bidder arrives — Tn consumes their full block alone at the higher cost.

The price ladder that Tn used as a defensive weapon becomes the cost they bear if the market refuses to follow. The protocol does not punish defensive overuse — the price does. A tenant who counter-bids beyond what the market genuinely supports will find themselves holding an expensive position with no successor to compensate them.

This creates a natural discipline: the defensive mechanism is rational to use when the tenant believes the market will continue to validate the higher price, and irrational when it will not. The protocol need not encode this judgment — it falls out automatically from the price-only-ascends rule during the Rented state.

### What the Protocol Did Not Build

The following behaviors exist in the protocol without being explicitly implemented:

- **A renewal system** — tenants can extend their position indefinitely by paying the minimum increment plus consumed rent.
- **A right of first refusal** — the current tenant can always match and exceed any incoming bid.
- **A cost floor for the incumbent** — displacement is never free; it requires paying at least `f_next_renting_price` above the current barrier.
- **A competitive takeover market** — multiple actors can compete for the asset during the `handover_countdown` window.
- **A self-correcting price ladder** — every renewal raises the floor, ensuring prices only move upward during the Rented state.
- **A self-limiting defense** — abusing the counter-bid mechanism raises the tenant's own cost floor. The protocol does not punish overuse; the price does.

None of these were designed. They are the natural output of identity-agnosticism, the last-bidder-wins rule, and the compensation invariant operating together. When simple primitives produce emergent behaviors that are both economically rational and mathematically clean, it is a signal that the underlying design is sound.

---

## 11. Attack Vectors and Protocol Resilience

The following vectors were identified and analyzed against the protocol's design. Each is resolved either by a formal constraint, an emergent property, or by being correctly identified as integrator responsibility rather than a protocol flaw.

---

### 1. Griefing via Trivial Minimum Increment

**Vector:** An integrator configures `f_next_renting_price` with δ ≈ 0. A well-funded actor can execute repeated takeovers paying a negligible premium, continuously disrupting tenants at low cost.

**Resolution:** Not a protocol flaw. The protocol only enforces `f(last_renting_price) > last_renting_price`. The responsibility of choosing an increment that disincentivizes griefing falls entirely on the integrator. A trivial function is a misconfiguration, not a vulnerability.

---

### 2. Perpetual Self-Renewal as Monopoly

**Vector:** A well-capitalized actor self-renews indefinitely, paying `used_credit + (P(n+1) - Pn)` per cycle — consumed rent plus the minimum increment. The price rises with each cycle but never discovers the real market price. Competition is blocked.

**Resolution:** Reframed — this is the protocol's success scenario, not an attack. The protocol is identity-agnostic: a self-renewing actor is indistinguishable from one who genuinely values the usus and never stops paying for it. In both cases the owner continuously earns `used_credit` and the price rises with each cycle. "Blocked competition" is simply the market correctly pricing the position.

---

### 3. Flash Takeover for Fructus Extraction

**Vector:** An actor takes over the asset, extracts available fructus, then is displaced by an accomplice. Net cost: `used_credit + (P_entry - P_prev)` for the interval — the rent consumed plus the minimum price increment. If fructus exceeds that cost, the attack is profitable.

**Resolution:** The minimum cost of any takeover is the price increment — even a flash takeover at t≈0 costs at least `P_entry - P_prev`. A sufficiently large increment configured in `f_next_renting_price` raises the floor for this attack. Additionally, the current tenant holds the structural asymmetric advantage — they can counter-bid at a net cost of `P_counter - remaining_credit`, always less than the full price the attacker must pay, immediately returning the attacker's payment and retaining their position. If the tenant does not defend, it is because they do not value the usus sufficiently — the market found a better use for the asset. If the asset generates enough yield to make the attack attractive, it is a signal of real demand: the price rises and the owner earns `used_credit`. The protocol functions correctly in both cases.

---

### 4. Artificial Price Inflation to Block Access

**Vector:** An actor abuses the current tenant's structural advantage, inflating the price through coordinated takeovers between their own wallets, making the asset inaccessible to organic demand.

**Resolution:** This is the self-limiting defense property operating at its perverse extreme. Each escalation raises `last_renting_price` via `f_next_renting_price`. If the market does not validate the inflated price and no external competitor arrives, the attacker is trapped consuming an expensive block alone — paying `used_credit` at prices they themselves inflated. The protocol does not need to punish this behavior: the price does. The cost of the attack is proportional to its own aggressiveness.

---

### 5. Dutch Auction Sniping

**Vector:** Multiple actors wait for the `descent_price` to reach the floor before entering, seeking the minimum possible entry price.

**Resolution:** Waiting while `descent_price` falls is inherently risky — another actor may enter first, gaining the incumbent's structural advantage: the ability to renew at a discount of `remaining_credit` relative to any external competitor. The actor who waits potentially surrenders that advantage entirely. The shape of `f_price_descent` directly mitigates this: a concave curve concentrates discounts early in the auction, eliminating the incentive to wait for the end. Integrator's choice.

---

### 6. Fructus Extraction During `handover_countdown`

**Vector:** The outgoing tenant retains usus and fructus during the `handover_countdown`. If they can extract disproportionate value during this window, there is a perverse incentive.

**Resolution:** The `handover_countdown` is not free for the outgoing tenant. `f_credit_ascent` continues running throughout — `used_credit` keeps accruing and flowing to the owner. The tenant pays for every second they retain the asset. Any fructus extracted during the countdown is implicitly paid for via `used_credit`. There is no free extraction.

---

### 7. Indefinite Takeover Queue During `handover_countdown`

**Vector:** If T3 arrives during the T1→T2 `handover_countdown`, an attacker could create an arbitrarily deep queue of pending takeovers, indefinitely delaying physical transfer.

**Resolution:** The `handover_countdown` does not restart with new bids. There is only ever one pending recipient — the last bidder. No queue is possible by construction.

---

### 8. Step Function for `f_credit_ascent`

**Vector:** An integrator configures `f_credit_ascent` as a step function: `f(t) = 0` for all `t < tenure_ceiling`, jumping to `Pn` at the last instant. `remaining_credit ≈ Pn` for almost the entire block. The owner earns almost nothing, and any takeover returns nearly the full stake to the displaced tenant. The asset is effectively shielded from market competition.

**Resolution:** Not a vulnerability — it is a self-punishing misconfiguration. The owner earns almost no `used_credit`, the price does not rise, and when the block expires with no successor the asset goes straight to Dutch Auction → Idle. The protocol is self-regulating: bad configurations drive the asset to Idle quickly, allowing the owner to retire and reconfigure. The feedback loop is immediate.

---

### 9. Perverse Coordination on Escrow Yield

**Vector:** If yield accumulates at a known rate during `Idle`/`At Dutch Auction`, actors may coordinate to withhold entry until the accumulated bonus is large enough — paradoxically extending the vacant period instead of shortening it.

**Resolution:** Waiting surrenders the current tenant's structural advantage. The first actor to enter captures both the accumulated yield and the structural protection of the tenant position. The actor who waited loses both simultaneously. The protocol permits the waiting strategy but does not make it free: competition between actors is the natural mitigation. No one can guarantee the optimal entry moment without risking that another actor claims it first.

---

### 10. `to_retire` as Market Manipulation Signal

**Vector:** The `to_retire` flag is publicly visible. The owner can set and unset it to signal that the asset is "about to be retired," discouraging new tenants and manufacturing artificial `Idle` periods to change parameters faster.

**Resolution:** The owner can mark `to_retire` but cannot control the market. If the asset generates real value, tenants will continue competing for it regardless of the flag. If the market cools in response to the signal, that is a rational market decision — not manipulation. The owner also has an incentive against abusing the flag: setting it reduces rental activity and therefore their own `used_credit` earnings. This is a reversible market signal whose effectiveness depends entirely on whether the market validates it.

---

### 11. Rapid Retire/Re-integrate for Parameter Manipulation

**Vector:** With a low `min_renting_price` and short `descent_ceiling`, an owner can engineer rapid `Idle` cycles to re-integrate the asset with different parameters frequently — effectively changing the rules of the game at high frequency while formally respecting immutability per instance.

**Resolution:** This falls outside the protocol's control and is the owner's responsibility. The protocol guarantees immutability per instance — nothing more. Each `Idle` cycle is time without `used_credit` and without rent. An asset with constantly changing parameters loses market trust. The strategy is self-defeating: the owner pays the price of their own instability.
