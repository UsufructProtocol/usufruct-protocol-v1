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
5. [Incentive-driven Functions](#5-incentive-driven-functions)

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

**Utility-grounded value:** The intrinsic value of the asset must reside strictly in its capacity to be used (usus) and in the yields or cash flows derived from it (fructus), rather than in mere speculation over its ownership.

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
The tenant has acquired the monopoly over usus and fructus through upfront liquidity injection. In this state, the tenant does not trade the asset — they enjoy its utility while their position remains active. The injected liquidity is bound to the asset, and the tenant enjoys use of the asset until a new renter pays a higher price for it, at which point the usus is revoked from the previous tenant through a compensation mechanism explained below.

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
- The displaced tenant is economically compensated: they receive the full value of their unconsumed_rent_credit (the value of unused time) plus 100% of the difference between their entry price and the new price.

Note: The physical transfer of the right is governed by a notice_period that determines the exact time of the handover, calculated as min(notice_period_parameter, remaining_time). Notice_period >= 0.

**Rented ➔ At Dutch Auction (Exhaustion and Liquidation):**
This transition is triggered when the current tenant's time block ends (all their unconsumed_rent_credit is exhausted) and the market has not validated or exceeded the last known price. The protocol sends the asset to auction to initiate a descending price curve that attracts new demand.

**At Dutch Auction ➔ Rented (Price Discovery):**
During the auction, a new buyer accepts the current descending price and injects the required liquidity. They automatically assume the usus of the asset, initiating a new time block and returning the system to State 1.

**At Dutch Auction ➔ Idle (Lack of Demand):**
If the auction descends to the lower bound (price floor) and the market does not absorb the asset, it returns to the Idle state, waiting for reactivation.

**Idle ➔ Retired (Delisting):**
From the resting state, the integration module evaluates the asset's situation. If it determines that no real market or genuine interest exists to justify its continued presence, it executes the asset's permanent withdrawal from the protocol.

---

## 4. Asset State Flow (Low-Level View)

At a deeper level, the Liquid Renting architecture operates as a dynamic equilibrium system between consumed time and market valuation.

### 1. The Resting State (State 0: Idle)

![Asset State Transition Flow](./media/1.png "Asset State Transition Flow")

The initial equilibrium point. The asset_current_renting_price equals the asset_min_renting_price. The asset is "open" with no liquidity barrier protecting its usus.

### 2. The Consumption and Competition Cycle (State 1: Rented)

![Asset State Transition Flow](./media/2.png "Asset State Transition Flow")
![Asset State Transition Flow](./media/3.png "Asset State Transition Flow")
![Asset State Transition Flow](./media/4.png "Asset State Transition Flow")

Once a user injects liquidity, the asset enters a state of active utilization that is, by definition, a renewable cycle:

**Price as Entry Barrier:** When renting the asset, the user purchases at next_renting_price(), establishing a new asset_last_renting_price. This value acts as a physical liquidity barrier: any other actor wishing to access the usus of the asset must "clear" this barrier by injecting capital greater than next_renting_price(). A higher price than next_renting_price() is allowed.

**The Takeover Dynamic (Cycle Reactivation):** If a new renter pays a higher price before the time runs out, the cycle restarts instantaneously:

- The new price becomes the new "barrier" (asset_last_renting_price).
- The consumption vector (Red Arrow) — consumption_credit_strategy — resets to zero.
- The new tenant receives a full block of unconsumed_rent_credit.

**The Trigger:** The transition to auction only occurs if the market does not validate the asset_last_renting_price known. That is, if no one clears the barrier established by the last tenant before their consumed_rent_credit reaches the limit of asset_last_renting_price. In practice, the current tenant only reaches the end of the road if they were the last one to establish asset_last_renting_price.


### 3. Price Discovery (State 2: At Dutch Auction)

![Asset State Transition Flow](./media/5.png "Asset State Transition Flow")
![Asset State Transition Flow](./media/6.png "Asset State Transition Flow")
![Asset State Transition Flow](./media/7.png "Asset State Transition Flow")

When the entry barrier (the price) proves too high for current demand and the last tenant's consumed_rent_credit is exhausted, the protocol initiates the liquidation:

**Descent Strategy (Green Arrow):** The price_discovery_strategy begins eroding the entry barrier. The asset_current_renting_price descends from the last known maximum.

**Resolution:** The moment the descending price reaches a point the market finds attractive, a new user injects that liquidity, the asset returns to State 1, and a new entry barrier is established — restarting the utility cycle. Otherwise, the asset_current_renting_price equals the asset_min_renting_price and the asset enters the Idle state.

---

## 5. Tenant Compensation Mechanism

The compensation mechanism is the economic guarantee that makes liquid renting viable. It ensures that no tenant ever suffers a net loss from being displaced, and that the incentive to enter the rental market remains rational at every price level.

### 1. The Consumption Function

At the core of the mechanism lies the `consumption_rent_credit` function. This function couples time and credit into a single unified variable: as time elapses, the consumed credit grows, and the unconsumed credit shrinks. The function is defined to pass through two fixed points:

- `(t = 0, consumed = 0)` — at the start of a rental, no credit has been consumed.
- `(t = T_rent, consumed = Pn)` — at the end of the rental period, all credit is exhausted.

This means time and credit are not independent: **when the clock runs out, the credit is exactly zero**. The two conditions are one and the same event seen from two dimensions. The exact shape of the curve between these two points (linear, convex, concave) is defined by the `consumption_credit_strategy` and will be detailed in the Incentive-driven Functions section.

At any moment during an active rental, the following invariant holds:

```
consumed_rent_credit + unconsumed_rent_credit = Pn
```

### 2. Takeover and Compensation

While a tenant Tn holds the usus at price Pn, the asset remains liquid. Any market participant may displace Tn by injecting a new price `P(n+1) > Pn`. When this occurs:

**Tn receives:**
- `unconsumed_rent_credit` — the unused portion of their own locked payment, returned directly from the protocol.
- `(P(n+1) - Pn)` — 100% of the price delta, funded by T(n+1)'s injection.

**The asset owner (integrating protocol) receives:**
- `consumed_rent_credit` — the portion of Pn that corresponds to time already consumed. This is the rent earned for the usus already delivered.

**T(n+1)'s new rental block:**
- T(n+1) injects `P(n+1)`, which becomes their full rental stake. The `consumption_rent_credit` function resets and runs from `(t=0, 0)` to `(t=T_rent, P(n+1))`.

### 3. Invariants and Guarantees

**No tenant loses money on takeover.** Since the takeover can only occur while `unconsumed_rent_credit > 0` (i.e., before time expires and the Dutch Auction is triggered), Tn always receives a strictly positive refund of their unused time, plus a premium on the price appreciation.

**The pattern is symmetric.** For any sequence of tenants T1, T2, ..., Tn at prices P1 < P2 < ... < Pn:

| Event | Tenant receives | Owner receives |
|---|---|---|
| T2 displaces T1 at P2 | `unconsumed_T1 + (P2 - P1)` | `consumed_T1` |
| T3 displaces T2 at P3 | `unconsumed_T2 + (P3 - P2)` | `consumed_T2` |
| Tn displaces T(n-1) at Pn | `unconsumed_T(n-1) + (Pn - P(n-1))` | `consumed_T(n-1)` |

**Each new block is fully funded.** T(n+1) injects `P(n+1)`. Of that, `(P(n+1) - Pn)` is the delta paid to Tn. The protocol retains the remainder as T(n+1)'s effective stake, against which the consumption function runs up to `P(n+1)`.

### 4. Dutch Auction as Boundary Condition

If no T(n+1) arrives before Tn's time expires, `consumed_rent_credit` reaches `Pn` and `unconsumed_rent_credit` reaches zero simultaneously. There is no remaining stake to return to Tn — it has been fully delivered to the owner as earned rent.

At this point, the Dutch Auction is triggered. It carries no stake of its own. Its sole function is to prevent the last known price Pn from freezing as the market entry barrier, allowing the price to descend until a new tenant finds it attractive and injects liquidity, restarting the cycle.

> **TODO:** Define exact `notice_period` semantics: does T(n+1)'s time block begin counting at payment or at physical handover? What guarantees does T(n+1) have during the notice window?

---

## 6. Incentive-driven Functions

The Liquid Renting Protocol exposes a set of pluggable functions that govern the economic behavior of the protocol without prescribing a single strategy. Each function must satisfy a set of formal constraints, but its exact shape is left to the integrating protocol, which selects it according to the market behavior it wishes to incentivize.

---

### 6.1 `f_consumption_rent_credit(t_rented)`

#### Purpose

This function defines the rate at which a tenant's rental credit is consumed over the duration of their rental period. It is the mechanism that couples time and economic stake into a single unified variable.

#### Formal Definition

```
f_consumption_rent_credit : [0, rental_time_fixed] → [0, last_renting_price]
```

#### Constraints

The function must satisfy the following conditions:

1. **Origin:** `f(0) = 0` — at the start of the rental, no credit has been consumed.
2. **Termination:** `f(rental_time_fixed) = last_renting_price` — at the end of the rental period, all credit is exactly exhausted.
3. **Boundedness:** `∀ t ∈ [0, rental_time_fixed] : 0 ≤ f(t) ≤ last_renting_price` — the function is always contained within the bounding rectangle.

Any function satisfying these three constraints is a valid implementation. The protocol imposes no further restriction on its shape.

#### The Dutch Auction Trigger as a Corollary

Constraints (1), (2), and (3) together imply that time exhaustion and credit exhaustion are the same event. When `t = rental_time_fixed`, `f(t) = last_renting_price` by definition — meaning `unconsumed_rent_credit = 0` at the exact moment the clock reaches zero. These two conditions are not independent; they are two projections of the same point `(rental_time_fixed, last_renting_price)`. The Dutch Auction is therefore triggered when either description is satisfied — they are equivalent.

#### Incentive Implications of Curve Shape

The integrating protocol selects the curve shape to incentivize a specific market behavior:

**Concave curve (e.g., `f(t) = Pn · √(t / T)`):** Credit is consumed rapidly at the start and slowly toward the end. A tenant displaced early recovers little `unconsumed_rent_credit`. This penalizes speculative entry — entering with the expectation of a quick takeover and a large refund is costly, since the curve has already consumed most of the credit. Suited for protocols that want to discourage high-frequency rotation and reward sustained usage.

**Linear curve (`f(t) = Pn · (t / T)`):** Credit is consumed proportionally to time. The protocol takes no position on when rotation is more or less convenient. Agnostic and neutral.

**Convex curve (e.g., `f(t) = Pn · (t / T)²`):** Credit is consumed slowly at the start and accelerates toward the end. A tenant displaced early still holds a large `unconsumed_rent_credit`, making entry safer. This incentivizes rotation — the cost of entering is partially recoverable at any early point, lowering the risk of taking a position. Suited for protocols that want high liquidity and active price discovery.

---

### 6.2 `f_price_discovery(t_at_auction)`

#### Purpose

This function defines the rate at which the `current_renting_price` decays during a Dutch Auction. It is the symmetric counterpart to `f_consumption_rent_credit`: where the first function drives a value upward from zero to a ceiling, this function drives a value downward from a ceiling to a floor.

#### Formal Definition

```
f_price_discovery : [0, t_at_auction_fixed] → [min_renting_price, last_renting_price]
```

#### Constraints

The function must satisfy the following conditions:

1. **Origin:** `f(0) = last_renting_price` — the auction begins at the last known rental price, the barrier the market failed to validate.
2. **Termination:** `f(t_at_auction_fixed) = min_renting_price` — if no buyer is found, the price reaches the floor and the asset returns to Idle.
3. **Boundedness:** `∀ t ∈ [0, t_at_auction_fixed] : min_renting_price ≤ f(t) ≤ last_renting_price` — the function is always contained within the bounding rectangle.

The function is monotonically non-increasing — the price can only descend during a Dutch Auction.

#### Symmetry with `f_consumption_rent_credit`

Both functions share an identical structural contract: two fixed endpoints and a boundedness constraint. The protocol prescribes no curve shape beyond these. The symmetry is exact:

| | `f_consumption_rent_credit` | `f_price_discovery` |
|---|---|---|
| Fixed point at t=0 | `f(0) = 0` | `f(0) = last_renting_price` |
| Fixed point at t=T | `f(T_rent) = last_renting_price` | `f(T_auction) = min_renting_price` |
| Bounded by | `[0, last_renting_price]` | `[min_renting_price, last_renting_price]` |
| Direction | Monotonically non-decreasing | Monotonically non-increasing |

This design decision — fixing both endpoints and leaving the interior free — is deliberate. The space of valid curves between two fixed points is already vast enough to express any incentive behavior the integrating protocol may require. Adding discontinuities or free starting points would introduce complexity without expanding expressive power.

#### Incentive Implications of Curve Shape

The shape of the decay curve determines when buyers are incentivized to act during the auction:

**Concave curve (e.g., `f(t) = last_renting_price - (last_renting_price - min_renting_price) · √(t / T)`):** Price drops sharply at the start and flattens toward the end. Most of the discount is captured early. Incentivizes buyers to act quickly — waiting yields diminishing returns.

**Linear curve:** Price decays at a constant rate. Neutral. No moment in the auction is structurally more attractive than another.

**Convex curve (e.g., `f(t) = last_renting_price - (last_renting_price - min_renting_price) · (t / T)²`):** Price remains high for most of the auction and falls steeply at the end. Incentivizes patient buyers to wait — the largest discounts arrive late. Creates a "cliff" dynamic near `t_at_auction_fixed`.
