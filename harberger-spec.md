# Harberger — Technical Specification

**Version:** 2.0.0-draft
**Target Runtime:** Sui Move
**Authors:** [Protocol Team]
**Status:** Draft — For Review

---

## Abstract

Harberger is a composable Sui Move module that places any asset under continuous Harberger taxation. Any asset wrapped by the module is always for sale at its declared price. Tax accrues as a deferred lien on the asset — a growing debt that reduces the holder's proceeds on sale, increases the cost of any price adjustment, and moves the asset toward a Dutch Auction if left unaddressed. The lien is settled automatically at the moment of sale.

The declared price is set once at acquisition and cannot be changed for free. The only way to adjust it is to repurchase the asset (even from oneself), which settles the accumulated lien. This makes price changes possible but costly — the cost growing with time, replacing the need for artificial cooldown mechanisms.

When the tax lien reaches the declared price, a Dutch Auction is triggered. The auction is irrevocable and descends until a buyer appears or the price reaches zero. The holder faces total capital loss. This threat — combined with the lien's continuous pressure on proceeds and adjustment cost — disciplines pricing without requiring any prepaid vault or keeper network.

The module is designed as a protocol-level primitive — not an application. It can be imported by any Sui protocol to bring Harberger market mechanics to its own assets. The integrating protocol defines its own tax formula (which determines what holder behavior is penalized) and auction descent curve (which determines how severely). Harberger handles everything else.

The name honors Arnold Harberger, the economist who first proposed self-assessed taxation with forced sale as a mechanism for efficient resource allocation.

---

## Table of Contents

1. [Motivation](#1-motivation)
2. [Core Concepts](#2-core-concepts)
3. [State Machine](#3-state-machine)
4. [Module Interface](#4-module-interface)
5. [Tax Engine](#5-tax-engine)
6. [Dutch Auction](#6-dutch-auction)
7. [Configurable Parameters](#7-configurable-parameters)
8. [Game Theory Analysis](#8-game-theory-analysis)
9. [Edge Cases & Attack Vectors](#9-edge-cases--attack-vectors)
10. [Integration Guide](#10-integration-guide)
11. [Application Examples](#11-application-examples)
12. [Fee Model](#12-fee-model)

---

## 1. Motivation

Most on-chain assets suffer from the same structural problem: once acquired, they can be held indefinitely at zero cost, regardless of whether the holder is using them productively. This creates squatting, price opacity, and resource misallocation.

Harberger taxation solves this elegantly:

- The holder declares a price for their asset at the moment of acquisition.
- A tax accrues proportional to that price, reducing the holder's proceeds on any future sale.
- Anyone can buy the asset at the declared price at any time.

This creates a one-time, irreversible dilemma: declare too low and risk losing the asset cheaply; declare too high and face a growing lien that erodes proceeds and eventually triggers a forced auction. The optimal strategy is honest pricing — the holder declares close to their true private valuation.

**Why existing solutions fall short:**

- **Traditional marketplaces** require the holder to actively list. There is no cost to holding an unlisted asset indefinitely.
- **Harberger with vaults** require the holder to prepay tax and manage a vault balance. If the vault empties, forced liquidation creates perverse incentives that can be gamed.
- **AMM-based pricing** requires liquidity pools and counterparties. Price discovery depends on active market making.

**What Harberger the module does differently:**

- **No vault, no prepayment.** Tax accrues as a deferred lien, settled at the moment of sale. The holder manages nothing.
- **No free price changes.** The declared price is set once. Changing it requires repurchasing the asset, which settles the accumulated lien. This replaces artificial cooldowns with an economic cost that grows with time.
- **Always for sale.** Every asset in Harberger State is permanently purchasable at its declared price. No listing required.
- **Dutch Auction as terminal discipline.** When the tax lien reaches the declared price, a Dutch Auction guarantees the asset confronts the market. The speed of the auction determines whether this functions as price discovery or liquidation — the integrator decides.
- **Genuine market only.** If an asset has no buyers at any price, the protocol acknowledges this honestly. No mechanism can manufacture interest where none exists — that is a property of the asset, not a limitation of the protocol.

---

## 2. Core Concepts

### 2.1 HarbergerAsset

A `HarbergerAsset<T, PAYMENT>` is any asset of type `T` wrapped under Harberger mechanics, with `PAYMENT` as the coin type for all transactions. Wrapping transfers the asset into the module and attaches a `HarbergerState` to it.

```
HarbergerAsset<T, PAYMENT> {
    id: UID,
    asset: T,                          // The underlying asset
    state: HarbergerState,             // Harberger mechanics
    tax_strategy: TaxStrategy,         // How tax is calculated (set by integrator)
    auction_strategy: AuctionStrategy, // How auction price descends (set by integrator)
    wrapped_at: u64,                   // Timestamp of wrapping
}
```

`T` is the underlying asset type (must have `store + key`). `PAYMENT` is the coin type used for all transactions on this asset (e.g., `USDC`, `SUI`). The payment type is fixed at wrap time and cannot change — all `buy()`, `auction_buy()`, and `unwrap()` calls must use the same coin type.

### 2.2 HarbergerState

The internal state tracking pricing, tax lien, and auction status.

```
HarbergerState {
    declared_price: u64,               // Self-assessed price in payment token
    last_sale_at: u64,                 // Timestamp of last sale (lien resets here)
    in_auction: bool,                  // Whether a Dutch Auction is active
    auction_start_time: u64,           // Timestamp when auction was triggered
}
```

### 2.3 TaxStrategy

Defined by the integrating protocol. Encodes the formula for computing the tax lien.

```move
public struct TaxStrategy has store, copy, drop {
    params: vector<u8>,                // Encoded formula parameters
    strategy_type: u8,                 // Identifier for the formula variant
}
```

Harberger calls this at settlement time:

```move
/// Implemented by the integrating protocol.
public fun compute_tax(
    strategy: &TaxStrategy,
    declared_price: u64,
    last_sale_at: u64,
    clock: &Clock,
): u64
```

**Invariants enforced by Harberger:**

1. If `declared_price > 0` and `elapsed_time > 0`, then `compute_tax()` must return > 0. Validated at wrap time with a dry-run check.
2. The function must be deterministic and depend only on on-chain state.

### 2.4 AuctionStrategy

Defined by the integrating protocol. Encodes the price descent curve of the Dutch Auction.

```move
public struct AuctionStrategy has store, copy, drop {
    params: vector<u8>,                // Encoded curve parameters
    strategy_type: u8,                 // Identifier for the curve variant
}
```

Harberger calls this during an active auction:

```move
/// Implemented by the integrating protocol.
public fun compute_auction_price(
    strategy: &AuctionStrategy,
    declared_price: u64,
    auction_start_time: u64,
    clock: &Clock,
): u64
```

The auction always starts at `declared_price`. The integrator controls how fast it descends.

---

## 3. State Machine

The protocol has exactly three states.

```
              ┌─────────────────────────────────────────────────┐
              │              STANDARD STATE                     │
              │                                                 │
              │  Asset is held. Tax lien accrues.               │
              │  Asset is always purchasable at declared_price. │
              │                                                 │
              │  The holder can:                                │
              │    • Hold indefinitely (lien grows)             │
              │    • Unwrap the asset (paying the lien)         │
              │                                                 │
              │  Anyone can:                                    │
              │    • Buy the asset at declared_price            │
              │    • Trigger auction if tax_owed >= declared_price│
              │                                                 │
              └──────────────┬──────────────────────────────────┘
                             │
                  tax_owed >= declared_price
                             │
                             ▼
              ┌─────────────────────────────────────────────────┐
              │              AUCTION STATE                      │
              │                                                 │
              │  Price descends per AuctionStrategy.            │
              │  First buyer acquires the asset.                │
              │  Irrevocable — holder cannot cancel.            │
              │  Protocol takes tax debt first.                 │
              │  Remainder (if any) to previous holder.         │
              │                                                 │
              └────────┬──────────────────────┬────────────────┘
                       │                      │
                buyer acquires         price reaches zero
                       │               (no buyer appeared)
                       ▼                      │
                STANDARD STATE                ▼
              (new owner, lien reset)  ┌──────────────────────┐
                                       │   EXPIRED STATE      │
                                       │                      │
                                       │   No market exists.  │
                                       │   Tax debt is lost.  │
                                       │   Integrator resolves│
                                       └──────────────────────┘
```

### 3.1 Transition Rules

| Transition | Trigger | Pre-condition | Post-condition |
|---|---|---|---|
| **Wrap** | `wrap()` | Caller owns asset of type `T` | HarbergerAsset created in Standard State |
| **Buy** | `buy()` | Asset in Standard State. Buyer pays ≥ declared_price. | Tax lien settled. Ownership transfers. Lien resets. New declared_price set by buyer. |
| **Trigger Auction** | `trigger_auction()` | `tax_owed >= declared_price` | Asset enters Auction State. Irrevocable. |
| **Auction Buy** | `auction_buy()` | Asset in Auction State. Buyer pays ≥ current_price(t). | Tax settled. Ownership transfers. Back to Standard State. New declared_price set by buyer. |
| **Expire** | `is_expired()` | Auction price has reached zero. No buyer. | Asset enters Expired State. |
| **Resolve** | `resolve_expired_auction()` | Asset in Expired State. Called by integrator. | HarbergerAsset destroyed. Underlying asset returned to integrator. |
| **Unwrap** | `unwrap()` | Caller owns asset. Tax lien paid by caller. | HarbergerAsset destroyed. Underlying asset returned. |

---

## 4. Module Interface

### 4.1 Core Functions

```move
/// Wraps an asset under Harberger mechanics.
/// The integrator provides TaxStrategy, AuctionStrategy, and initial declared price.
/// PAYMENT is the coin type for all future transactions on this asset.
public fun wrap<T: store + key, PAYMENT>(
    asset: T,
    declared_price: u64,
    tax_strategy: TaxStrategy,
    auction_strategy: AuctionStrategy,
    config: &HarbergerConfig,
    clock: &Clock,
    ctx: &mut TxContext
): HarbergerAsset<T, PAYMENT>
```

```move
/// Purchases the asset at its declared price.
/// Tax lien is deducted from proceeds before seller receives payment.
/// The buyer must declare a new price — this is irrevocable until the next sale.
/// There is no set_price(). The only way to change a declared price is to buy the asset
/// (including from yourself), which settles the accumulated tax lien.
public fun buy<T: store + key, PAYMENT>(
    asset: &mut HarbergerAsset<T, PAYMENT>,
    payment: Coin<PAYMENT>,
    new_declared_price: u64,
    max_acceptable_price: u64,        // Safety check — reverts if declared_price > this
    config: &HarbergerConfig,
    clock: &Clock,
    ctx: &mut TxContext
): Coin<PAYMENT>                      // Net proceeds to previous owner
```

```move
/// Permissionless. Anyone can trigger if tax_owed >= declared_price.
public fun trigger_auction<T: store + key, PAYMENT>(
    asset: &mut HarbergerAsset<T, PAYMENT>,
    clock: &Clock,
    config: &HarbergerConfig,
)
```

```move
/// Purchases the asset during an active Dutch Auction.
public fun auction_buy<T: store + key, PAYMENT>(
    asset: &mut HarbergerAsset<T, PAYMENT>,
    payment: Coin<PAYMENT>,
    new_declared_price: u64,
    config: &HarbergerConfig,
    clock: &Clock,
    ctx: &mut TxContext
): Coin<PAYMENT>                      // Remainder to previous holder (may be zero)
```

```move
/// Unwraps the asset. Caller must pay the outstanding tax lien.
/// Returns the underlying asset and any change from tax_payment.
public fun unwrap<T: store + key, PAYMENT>(
    asset: HarbergerAsset<T, PAYMENT>,
    tax_payment: Coin<PAYMENT>,
    clock: &Clock,
    ctx: &mut TxContext
): (T, Coin<PAYMENT>)
```

```move
/// Resolves an expired auction (price reached zero, no buyer).
/// Only callable by the integrator. Returns the underlying asset.
/// The integrator decides the asset's fate: re-wrap, archive, destroy, etc.
public fun resolve_expired_auction<T: store + key, PAYMENT>(
    asset: HarbergerAsset<T, PAYMENT>,
    clock: &Clock,
    ctx: &mut TxContext
): T
```

### 4.2 View Functions

```move
/// Returns the current tax lien (accrued since last sale).
public fun pending_tax<T: store + key, PAYMENT>(
    asset: &HarbergerAsset<T, PAYMENT>,
    clock: &Clock,
    config: &HarbergerConfig,
): u64

/// Returns what the seller would receive if sold right now.
public fun net_proceeds<T: store + key, PAYMENT>(
    asset: &HarbergerAsset<T, PAYMENT>,
    clock: &Clock,
    config: &HarbergerConfig,
): u64  // declared_price - pending_tax (0 if in auction)

/// Returns the current auction price. Aborts if not in auction.
public fun current_auction_price<T: store + key, PAYMENT>(
    asset: &HarbergerAsset<T, PAYMENT>,
    clock: &Clock,
): u64

/// Returns whether the auction trigger condition is met.
public fun is_auctionable<T: store + key, PAYMENT>(
    asset: &HarbergerAsset<T, PAYMENT>,
    clock: &Clock,
    config: &HarbergerConfig,
): bool

/// Returns whether the auction has expired (price reached zero, no buyer).
public fun is_expired<T: store + key, PAYMENT>(
    asset: &HarbergerAsset<T, PAYMENT>,
    clock: &Clock,
): bool
```

---

## 5. Tax Engine

### 5.1 Deferred Lien Model

Tax accrues continuously while an asset is in Standard State, but is never collected in advance. It exists as an implicit lien — a debt that grows over time and is settled at the next sale or unwrap.

```
Lien grows in Standard State
          │
          ├── buy()            → lien deducted from declared_price, remainder to seller
          ├── auction_buy()    → lien deducted from auction price, remainder to seller
          └── unwrap()         → caller pays lien explicitly before asset is returned
```

There is no vault. There is no `collect_tax()`. There is no keeper network. There is no `set_price()`.

#### Why the Lien Is Not "Zero Cost"

The absence of upfront payment does not mean the absence of pressure. The growing lien exerts continuous force through three simultaneous channels:

1. **Reduced proceeds.** Every second that passes, the seller receives less if someone buys. The lien eats into the declared price in real time.

2. **Costly price adjustment.** There is no free way to change a declared price. The only mechanism is to repurchase the asset via `buy()`, which settles the accumulated lien. The longer the holder waits to adjust, the more expensive the adjustment becomes. This replaces the traditional cooldown with an economic cost that grows with time — a strictly superior anti-manipulation mechanism.

3. **Approaching auction threshold.** The lien moves monotonically toward the declared price. Once it reaches it, a Dutch Auction is triggered and the holder faces total capital loss. This deadline cannot be moved without paying the lien (via self-repurchase).

The combination of these three pressures is equivalent in effect — though not in form — to a prepaid vault. The vault makes the holder feel cost through balance depletion. The deferred lien makes the holder feel cost through shrinking proceeds, growing adjustment cost, and an approaching deadline.

#### Price Changes via Self-Repurchase

Since there is no `set_price()`, the only way to change a declared price is to buy the asset from yourself via `buy()`. This:

- Settles the full accumulated lien at the moment of repurchase.
- Resets `last_sale_at` to the current timestamp, starting a new lien cycle.
- Allows the buyer (the holder themselves) to declare a new price.

The cost of changing price is exactly the tax owed — not an arbitrary penalty, but the liquidation of real fiscal debt. This makes frequent adjustments expensive (lien accumulates between each) and infrequent adjustments cheap. The system self-regulates the frequency of price changes without any configurable cooldown parameter.

### 5.2 Settlement at Sale

```
Buyer pays: declared_price
  │
  ├── tax_owed         → integrator treasury
  ├── protocol_fee_bps → Harberger treasury
  └── remainder        → seller
```

`last_sale_at` is reset to the current timestamp. The new owner starts with a clean lien.

### 5.3 Settlement at Unwrap

The holder who wants to reclaim their underlying asset must pay the outstanding lien explicitly:

```
Caller provides: tax_payment
  │
  ├── tax_owed  → integrator treasury
  └── change    → returned to caller
```

### 5.4 TaxStrategy as Behavioral Design

The choice of tax curve is not merely a financial parameter — it is a behavioral design decision. Each curve shape penalizes a different type of holder behavior. The integrator should choose based on what conduct they want to discourage, not just what rate feels appropriate.

| Curve Shape | Behavior Penalized | Behavior Rewarded | Anti-Wash-Trading |
|---|---|---|---|
| **Linear** | Neutral — proportional cost over time | None specifically | Neutral — each reset costs the same per unit time |
| **Quadratic (escalating)** | Long-term holding / squatting | Short-term active trading | Weak — resets actually help the holder by restarting at the cheap part of the curve |
| **Logarithmic (decaying)** | Rotation / wash trading | Long-term committed holding | Strong — each reset restarts at the most expensive point of the curve |
| **Flat fee** | Holding regardless of declared price | None — pure time cost | Neutral — fixed cost per period regardless of behavior |

**The logarithmic curve and wash trading:** With a decaying tax curve, the effective rate is highest immediately after acquisition and decreases over time. A holder who self-repurchases to reset their price restarts at the peak of the curve every time. This creates a third layer of defense against self-dealing (in addition to the structural irrationality proven in section 6.5 and the lien settlement cost at each repurchase). A holder rotating the asset between their own wallets pays strictly more than one who simply holds without intervention.

The following are illustrative implementations. They live in the integrating protocol's module, not in Harberger. All examples use simplified arithmetic for clarity — production implementations must use checked arithmetic to prevent overflow (see section 9.5).

---

**Example A — Linear Monthly**

```move
public fun compute_tax(
    strategy: &TaxStrategy,
    declared_price: u64,
    last_sale_at: u64,
    clock: &Clock,
): u64 {
    let tax_rate_bps = decode_u16(strategy.params, 0);
    let now = clock::timestamp_ms(clock) / 1000;
    let elapsed = now - last_sale_at;
    let seconds_per_month: u64 = 2_592_000;
    declared_price * (tax_rate_bps as u64) * elapsed / 10_000 / seconds_per_month
}
```

Neutral on holding duration. Cost grows linearly with time. Best for general-purpose assets where no specific behavior needs to be penalized or rewarded.

---

**Example B — Epoch-Based**

```move
public fun compute_tax(
    strategy: &TaxStrategy,
    declared_price: u64,
    last_sale_at: u64,
    clock: &Clock,
): u64 {
    let tax_rate_bps = decode_u16(strategy.params, 0);
    let current_epoch = tx_context::epoch(ctx);
    let elapsed_epochs = current_epoch - last_sale_at;
    declared_price * (tax_rate_bps as u64) * elapsed_epochs / 10_000
}
```

Discrete-time variant of linear. Aligns tax cycles with on-chain governance epochs. Best for governance seats, staking positions, DAO-aligned assets.

---

**Example C — Quadratic Escalation**

```move
public fun compute_tax(
    strategy: &TaxStrategy,
    declared_price: u64,
    last_sale_at: u64,
    clock: &Clock,
): u64 {
    let base_rate_bps = decode_u16(strategy.params, 0);
    let now = clock::timestamp_ms(clock) / 1000;
    let days_elapsed = (now - last_sale_at) / 86_400;
    declared_price * (base_rate_bps as u64) * days_elapsed * days_elapsed / 10_000 / 86_400
}
```

Penalizes squatting aggressively — each additional day costs more than the previous one. Caution: self-repurchase resets the holder to the cheap part of the curve, so this shape weakly incentivizes wash trading. Appropriate only for assets where squatting is a bigger problem than rotation (e.g., domain names, usernames).

---

**Example D — Flat Daily Fee**

```move
public fun compute_tax(
    strategy: &TaxStrategy,
    declared_price: u64,
    last_sale_at: u64,
    clock: &Clock,
): u64 {
    let daily_fee = decode_u64(strategy.params, 0);
    let now = clock::timestamp_ms(clock) / 1000;
    daily_fee * (now - last_sale_at) / 86_400
}
```

Independent of declared price. Pure holding cost based on time. Best for assets where a minimum cost of occupation matters more than price-proportional pressure.

---

**Example E — Logarithmic Decay**

```move
public fun compute_tax(
    strategy: &TaxStrategy,
    declared_price: u64,
    last_sale_at: u64,
    clock: &Clock,
): u64 {
    let base_rate_bps = decode_u16(strategy.params, 0);
    let now = clock::timestamp_ms(clock) / 1000;
    let elapsed = now - last_sale_at;
    let holding_days = elapsed / 86_400 + 1;
    let adjusted_rate = (base_rate_bps as u64) / holding_days;
    declared_price * adjusted_rate * elapsed / 10_000 / 2_592_000
}
```

Rewards committed holders — the effective rate decreases over time. Strongly discourages wash trading because each self-repurchase resets the holder to peak cost. Best for assets where long-term commitment should be rewarded (IP licenses, community memberships).

---

## 6. Dutch Auction

### 6.1 Why It Is Necessary

In the deferred tax model, a holder can declare an inflated price and never sell. The tax lien grows but since the holder receives nothing on sale once the lien exceeds the declared price, there is no natural incentive to lower the price. The asset freezes — overpriced, unsellable, permanently stuck in Standard State.

The Dutch Auction breaks this deadlock. When the tax lien reaches the declared price, the asset is put up for sale at a descending price until a buyer appears. This guarantees that every asset will eventually confront the market, regardless of what the holder declared.

#### The Auction's Function Depends on Its Speed

The `AuctionStrategy` does not just control "how fast" — it determines what the auction fundamentally does:

- **Slow descent** (days to weeks): The auction becomes a genuine price discovery mechanism. The market has time to evaluate the asset. Buyers enter at the price that reflects their valuation. The resulting sale price is meaningful market information.

- **Fast descent** (minutes to hours): The auction becomes a liquidation mechanism. It clears abandoned or overpriced assets quickly. The resulting price is a distressed sale, not a market signal.

The integrator should choose auction speed based on whether the goal is to discover the asset's market price or to recycle it quickly. For most assets, slower is better — the auction is often the only moment where a true market price is expressed.

### 6.2 Trigger

```
tax_owed >= declared_price → Dutch Auction triggered
```

This is a permissionless check. Anyone can call `trigger_auction()` once the condition is met. The auction is irrevocable — the holder cannot cancel it by any means.

### 6.3 Mechanism

The auction starts at `declared_price` and descends according to the asset's `AuctionStrategy`.

**Linear descent:**
```move
public fun compute_auction_price(
    strategy: &AuctionStrategy,
    declared_price: u64,
    auction_start_time: u64,
    clock: &Clock,
): u64 {
    let duration = decode_u64(strategy.params, 0);
    let elapsed = clock::timestamp_ms(clock) / 1000 - auction_start_time;
    if (elapsed >= duration) return 0;
    declared_price * (duration - elapsed) / duration
}
```

**Stepped descent:**
```move
public fun compute_auction_price(
    strategy: &AuctionStrategy,
    declared_price: u64,
    auction_start_time: u64,
    clock: &Clock,
): u64 {
    let step_duration = decode_u64(strategy.params, 0);
    let step_pct = decode_u8(strategy.params, 8);
    let elapsed = clock::timestamp_ms(clock) / 1000 - auction_start_time;
    let steps = elapsed / step_duration;
    let discount = steps * (step_pct as u64);
    if (discount >= 100) return 0;
    declared_price * (100 - discount) / 100
}
```

### 6.4 Payment Flow

```
Buyer pays: current_price(t)
  │
  ├── tax_owed (up to current_price)  → integrator treasury
  ├── protocol_fee_bps                → Harberger treasury
  └── remainder                       → previous holder (may be zero)
```

Since the auction triggers at `tax_owed >= declared_price`, and starts at `declared_price`, the previous holder typically receives zero.

### 6.5 Why Second-Wallet Repurchase Is Always Irrational

A holder might consider using a second wallet to repurchase their asset during the auction at a discounted price. The following four cases prove this is never rational.

In all cases: `buy_price` = what the holder originally paid.

---

**Case 1 — declared_price < buy_price, tax_owed < declared_price (Standard State)**

```
buy_price: 100   declared_price: 80   tax_owed: 20

Second wallet buys at 80:
  → 20 to protocol, 60 to holder
Net: 100 + 80 − 60 = 120 USDC spent on a 100 USDC asset
```

---

**Case 2 — declared_price < buy_price, tax_owed >= declared_price (Auction)**

```
buy_price: 100   declared_price: 80   tax_owed: 90

Second wallet buys in auction at 50:
  → 50 to protocol (100%), 0 to holder
Net: 100 + 50 − 0 = 150 USDC
```

---

**Case 3 — declared_price >= buy_price, tax_owed < declared_price (Standard State)**

```
buy_price: 100   declared_price: 150   tax_owed: 30

Second wallet buys at 150:
  → 30 to protocol, 120 to holder
Net: 100 + 150 − 120 = 130 USDC
```

The holder paid exactly the tax owed. No gaming advantage — any legitimate buyer produces the same result.

---

**Case 4 — declared_price >= buy_price, tax_owed >= declared_price (Auction)**

```
buy_price: 100   declared_price: 150   tax_owed: 160

Second wallet buys in auction at 80:
  → 80 to protocol (100%), 0 to holder
Net: 100 + 80 − 0 = 180 USDC
```

The worst case. The holder spent 180 USDC on an asset that cost 100 USDC.

---

**Conclusion:** In every case, total cost = `buy_price + something`. The holder always pays more than they originally paid. The tax-first payment priority makes second-wallet repurchase structurally irrational.

### 6.6 When the Auction Reaches Zero With No Buyer

If the price descends to zero and no buyer appears, the auction enters **Expired State**. The tax debt goes uncollected. The previous holder receives nothing.

This is not a protocol failure — it confirms the asset has no market at any price. The protocol did its job: it offered the asset at continuously descending prices, giving every potential buyer full opportunity. The absence of buyers is information about the asset.

```move
/// Returns whether the auction has expired (price reached zero, no buyer).
public fun is_expired<T: store + key, PAYMENT>(
    asset: &HarbergerAsset<T, PAYMENT>,
    clock: &Clock,
): bool

/// Resolves an expired auction. Only callable by the integrator.
/// The integrator decides what happens to the asset: reclaim, archive, or destroy.
public fun resolve_expired_auction<T: store + key, PAYMENT>(
    asset: HarbergerAsset<T, PAYMENT>,
    clock: &Clock,
    ctx: &mut TxContext
): T                                   // Returns the underlying asset to the integrator
```

The integrator receives the underlying asset and decides its fate: archive it, allow the previous holder to reclaim it (possibly by paying the debt), destroy it, or re-wrap it under new terms. Harberger does not mandate the outcome — it returns control to the integrator. No protocol can create market interest where none exists.

### 6.7 The Incentive Field: Tax Speed × Auction Speed

The `TaxStrategy` controls how quickly the lien reaches the declared price (time to auction). The `AuctionStrategy` controls how quickly the price descends once the auction starts (severity of loss). These are not independent parameters — their interaction defines the incentive landscape the holder operates in.

| | Slow Auction | Fast Auction |
|---|---|---|
| **Fast Tax** | **Price discovery.** Holder confronts the market frequently. Slow auction gives the market time to find a real price. Produces the highest-quality price signals. Best for: assets where honest pricing is the primary goal. | **Maximum rotation.** Holder reaches the edge quickly and falls fast. Hostile to long-term holding. Best for: time-limited resources (bandwidth, ad slots, temporary access). |
| **Slow Tax** | **Maximum stability.** Long holding periods before the auction threshold. Slow descent if it arrives. Minimally disruptive. Best for: governance seats, assets where continuity has value. | **Deferred guillotine.** Long calm period, then sudden destruction. Rewards sophisticated holders who monitor their position. Punishes passive abandonment harshly. Best for: assets where neglect (not holding) is the problem. |

The integrator selects a position in this matrix — combined with the tax curve shape (section 5.4) — to construct a three-dimensional incentive system: **what behavior to penalize** (curve shape) × **when to penalize** (tax speed) × **how severely to penalize** (auction speed).

---

## 7. Configurable Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `protocol_fee_bps` | u16 | 50 | Fee on each `buy()` and `auction_buy()` (0.5%) |
| `min_declared_price` | u64 | 1 | Minimum declared price (prevents zero-price gaming) |

Note: The payment coin type is a generic type parameter (`PAYMENT`) on `HarbergerAsset`, not a config field. Tax formula lives in `TaxStrategy`. Auction descent lives in `AuctionStrategy`. Neither is a top-level config parameter — they are integrator decisions.

### 7.1 Parameter Constraints

- `protocol_fee_bps` must be in range [0, 500].

---

## 8. Game Theory Analysis

### 8.1 The Pricing Dilemma

Every holder faces a one-time, irreversible optimization problem at the moment of acquisition:

**Declare too low →** Tax lien grows slowly, but anyone can buy the asset cheaply. Risk of losing a valuable asset below its true value. Since the price cannot be raised afterward, the holder is permanently exposed.

**Declare too high →** Asset is protected from buyouts, but the lien grows faster. When sold, the holder receives less. If the lien reaches the declared price, a Dutch Auction is triggered and the holder faces total capital loss. Since the price cannot be lowered without self-repurchasing (which settles the lien), the holder is locked into the high-cost trajectory.

**Equilibrium:** Declare close to true private valuation. This is Harberger's fundamental insight — self-assessed taxation with forced sale creates an incentive-compatible mechanism where honest pricing is the optimal strategy. The irrevocability of the declared price strengthens this: with no ability to adjust costlessly, the holder's only rational anchor is their genuine valuation.

#### The Equilibrium Is Conditional

Honest pricing as the dominant strategy depends on market density — the presence of active buyers scanning for underpriced assets. In dense markets, sub-declaring is dangerous because a buyer will exploit the gap quickly. The equilibrium converges tightly to the true valuation.

In thin markets, the probability of a buyer appearing at any given price is low. The risk of sub-declaring is smaller and more probabilistic. The equilibrium still exists but converges to a wider range rather than a precise point. The Dutch Auction guarantees this range has an upper bound — no declared price can survive forever — but the lower bound depends on external market activity that the protocol cannot create.

This is not a weakness. No mechanism can produce precise price discovery without a market. Harberger guarantees the best possible outcome given the market that exists: tight prices in liquid markets, bounded prices in thin ones, and asset recycling when there is no market at all.

### 8.2 Ownership State vs Harberger State

For this core module, all wrapped assets are always in Harberger State. The holder's only choice is what price to declare at the moment of acquisition.

### 8.3 Why Tax Payment Is Structurally Unavoidable

Every exit from Harberger State settles the lien:

- **`buy()`** — lien deducted from proceeds automatically.
- **`auction_buy()`** — lien deducted from auction proceeds automatically.
- **`unwrap()`** — caller pays lien explicitly.

There is no exit that bypasses tax. The holder can delay settlement, but cannot avoid it.

### 8.4 On Assets With No Market

If no buyer ever appears, the protocol never collects. This is not a flaw. No protocol can manufacture genuine interest in an asset the market does not want. Harberger is designed for assets with real demand. When that demand exists, the mechanism guarantees honest pricing and continuous liquidity. When it does not, no mechanism can create it — that is a property of the asset, not the protocol.

### 8.5 Revenue Is Event-Driven

Tax revenue (for both the integrator and the Harberger treasury) is collected only at the moment of a transaction: `buy()`, `auction_buy()`, or `unwrap()`. There is no periodic collection, no streaming payment, no predictable revenue schedule.

If an asset is held indefinitely and eventually enters auction at zero with no buyer, all accumulated tax debt is lost. The integrator should not treat Harberger tax revenue as a reliable or continuous income stream. It is event-driven and depends entirely on market activity.

### 8.6 Equilibrium Summary

| Actor | Optimal Strategy | Protocol Benefit |
|---|---|---|
| **Holder** | Declare true valuation | Continuous honest price discovery |
| **Buyer** | Buy when declared_price < true value | Efficient resource allocation |
| **Speculator** | Buy underpriced assets, hold, resell | Market liquidity |
| **Auction participant** | Buy in auction at market-clearing price | Prevents assets from freezing |

---

## 9. Edge Cases & Attack Vectors

### 9.1 Self-Dealing via Secondary Wallet

**Attack:** Holder uses a second wallet to buy their own asset, resetting the lien and declaring a new price.

**Mitigation:** Self-dealing is structurally irrational. Every repurchase settles the full accumulated lien — the holder pays their tax debt regardless of which wallet buys. There is no economic shortcut. See section 6.5 for formal proof across all cases. Additionally, with a decaying tax curve (e.g., logarithmic), each reset restarts the holder at the most expensive point of the curve, making repeated self-dealing progressively more costly than simply holding.

### 9.2 Front-Running Buy Transactions

**Attack:** Holder sees a `buy()` in the mempool and raises the price before it executes.

**Mitigation:** This attack is structurally impossible. There is no `set_price()` function — the declared price is immutable once set. The holder cannot change their price between the buyer's submission and execution. The `max_acceptable_price` parameter on `buy()` remains as a safety check against user error, but is no longer a critical defense against manipulation.

### 9.3 Price Freezing via Inflated Declaration

**Attack:** Holder declares an unrealistically high price. No buyer materializes. Asset is effectively frozen.

**Mitigation:** This is exactly what the Dutch Auction solves. Once `tax_owed >= declared_price`, the auction triggers and the price descends until a buyer appears or it reaches zero.

### 9.4 Malicious TaxStrategy

**Attack:** Integrator deploys a `TaxStrategy` that always returns 0, disabling Harberger mechanics.

**Mitigation:** Harberger validates the TaxStrategy at `wrap()` time with a dry-run call. If `compute_tax()` returns 0 for non-zero price and elapsed time, the wrap is rejected.

### 9.5 Integer Overflow in TaxStrategy

**Risk:** Non-linear strategies (e.g., quadratic) can overflow u64 for large prices or long holding periods.

**Mitigation:** Integrators must use checked arithmetic throughout their `compute_tax()` implementation. Harberger cannot enforce this internally since the formula is external.

### 9.6 Price Oracle Misuse

**Risk:** Declared prices reflect holder self-assessment under tax pressure, not traditional market-clearing prices.

**Guidance:** Do not use declared prices as oracle inputs for lending protocols or other mechanisms that require objective price feeds.

---

## 10. Integration Guide

### 10.1 Minimal Integration

**Step 1 — Define the asset type.**

```move
public struct MyAsset has key, store {
    id: UID,
    name: String,
    // ... other fields
}
```

**Step 2 — Define the TaxStrategy.**

```move
let tax_strategy = TaxStrategy {
    strategy_type: LINEAR_MONTHLY,
    params: encode_u16(200),           // 200 bps = 2% monthly
};
```

**Step 3 — Define the AuctionStrategy.**

```move
let auction_strategy = AuctionStrategy {
    strategy_type: LINEAR_DESCENT,
    params: encode_u64(86_400),        // 24 hour linear descent
};
```

**Step 4 — Wrap the asset.**

```move
let harberger_asset = harberger::wrap<MyAsset, USDC>(
    my_asset,
    initial_declared_price,
    tax_strategy,
    auction_strategy,
    &config,
    &clock,
    ctx
);
transfer::transfer(harberger_asset, owner);
```

### 10.2 Configuration

```move
let config = harberger::new_config(
    protocol_fee_bps: 50,
    min_declared_price: 1_000_000,     // 1 USDC (6 decimals)
    ctx
);
```

### 10.3 Events

| Event | Fields | Emitted When |
|---|---|---|
| `AssetWrapped` | asset_id, asset_type, owner, declared_price | `wrap()` |
| `AssetPurchased` | asset_id, seller, buyer, price, tax_deducted, seller_proceeds, new_declared_price | `buy()` |
| `AuctionTriggered` | asset_id, declared_price, tax_owed, auction_start_time | `trigger_auction()` |
| `AuctionPurchased` | asset_id, buyer, price, tax_deducted, seller_proceeds, new_declared_price | `auction_buy()` |
| `AuctionExpired` | asset_id, declared_price, tax_owed_lost | Auction price reaches zero with no buyer |
| `AuctionResolved` | asset_id, integrator | `resolve_expired_auction()` |
| `AssetUnwrapped` | asset_id, owner, tax_paid | `unwrap()` |

### 10.4 Choosing Your Incentive Configuration

The integrator makes three decisions that together define the holder's incentive landscape:

1. **Tax curve shape** (section 5.4) — What behavior to penalize. Linear is neutral; quadratic punishes squatting; logarithmic rewards commitment and penalizes wash trading.

2. **Tax speed** — How quickly the lien reaches the declared price (time to auction). This is controlled by the rate parameters in the TaxStrategy. Fast tax means frequent confrontation with the market. Slow tax means long holding periods before consequences arrive.

3. **Auction speed** — How severely the holder loses when the auction triggers. This is controlled by the duration parameter in the AuctionStrategy. Slow descent produces price discovery. Fast descent produces liquidation.

See section 6.7 for the full interaction matrix between tax speed and auction speed.

**Example configurations:**

- **Domain names:** Quadratic tax (penalize squatting) + fast tax (months, not years) + slow auction (7-day descent for price discovery).
- **Governance seats:** Epoch-based linear tax + slow tax (aligned with governance cycles) + slow auction (orderly transition).
- **Ad slots / bandwidth:** Linear tax + fast tax + fast auction (maximize rotation).
- **IP licenses / community memberships:** Logarithmic tax (reward commitment, punish flipping) + slow tax + slow auction.

### 10.5 Revenue Model Warning

Harberger tax revenue is event-driven, not continuous. The integrator collects tax only when `buy()`, `auction_buy()`, or `unwrap()` is called. If an asset is held indefinitely and eventually auctions to zero, all accumulated tax debt is lost.

Do not design protocol economics that depend on Harberger tax as a predictable income stream. Treat it as a byproduct of market activity, not a revenue source.

---

## 11. Application Examples

Each example below describes the three-dimensional incentive configuration (see section 10.4): **curve shape** (what behavior to penalize) × **tax speed** (when consequences arrive) × **auction speed** (how severe the consequences are).

### 11.1 Domain Names

A naming service integrates Harberger to eliminate squatting:

- Each domain is wrapped as a `HarbergerAsset`.
- **Curve shape:** Quadratic escalation — penalizes long-term holding. A squatter accumulates a massive lien that grows faster each day, receiving near-nothing when forced out. Caution: quadratic curves weakly incentivize wash trading (see section 5.4). For domains, this is acceptable because the cost of self-repurchase still settles the full lien.
- **Tax speed:** Fast (months). Squatters should confront the market quickly.
- **Auction speed:** Slow (7-day linear descent). Domains are unique assets — slow descent gives the market time to discover the right price.
- Active users hold their domain at a fair declared price. If the market shifts, they can adjust via self-repurchase, paying exactly the lien accumulated since their last acquisition.

### 11.2 Governance Seats

A DAO wraps governance seats under Harberger mechanics:

- Each seat always has a declared price. Inactive governors face growing liens.
- **Curve shape:** Epoch-based linear — aligns tax cycles with DAO voting cycles. Neutral on holding duration.
- **Tax speed:** Slow (aligned with governance cycles). Continuity of governance has value; the mechanism should not disrupt active governors.
- **Auction speed:** Slow (multi-day descent). Orderly transition of governance power. Gives the DAO community time to identify and fund replacement candidates.
- If a governor becomes inactive and their lien reaches the seat price, anyone can trigger a Dutch Auction and acquire the seat, bringing active participation back.

### 11.3 NFT Collections

An NFT marketplace integrates Harberger for continuous price discovery:

- Each NFT is wrapped. Declared prices form a live floor price signal.
- **Curve shape:** Logarithmic decay — rewards committed collectors, penalizes flippers. Each resale restarts the holder at peak tax rate, making rapid flipping expensive.
- **Tax speed:** Slow (1% monthly linear equivalent). Light enough to not burden genuine collectors, meaningful enough to force honest pricing over time.
- **Auction speed:** Slow (7–14 day descent). NFTs are subjective assets — slow descent maximizes the chance of finding a buyer at a meaningful price rather than a distressed liquidation.
- Speculators holding NFTs they don't value pay a growing lien — creating natural sell pressure.

### 11.4 Intellectual Property Licenses

A music or software protocol wraps licenses under Harberger:

- Each license always has a declared price.
- **Curve shape:** Logarithmic decay — early holding is expensive (discourages flipping), long-term holding becomes cheaper (rewards commitment). Strongly discourages wash trading: each self-repurchase resets to peak cost.
- **Tax speed:** Moderate. Balances access (IP should be transferable) with stability (licensees need predictability to build on the IP).
- **Auction speed:** Slow. Licenses often have dependencies — slow descent gives existing licensees time to find replacement buyers or negotiate.
- Anyone can always acquire a license at its declared price, ensuring the IP is always accessible to those who value it most.

### 11.5 Virtual Real Estate

A metaverse or on-chain map wraps land parcels:

- **Curve shape:** Linear — neutral on holding duration. The goal is not to penalize long-term builders, but to ensure idle land can be acquired.
- **Tax speed:** Moderate, rate proportional to parcel size or location value. Prime locations face faster lien growth. Peripheral parcels are cheaper to hold.
- **Auction speed:** Fast (24–48 hour descent). Land is relatively fungible within zones — fast liquidation is acceptable and prevents permanently abandoned parcels from freezing the map.
- Active builders hold at a fair price. Idle land holders face continuous pressure proportional to the value of the location they occupy.

---

## 12. Fee Model

| Fee | Rate | Trigger | Recipient |
|---|---|---|---|
| **Wrap Fee** | 10 bps (0.1%) | Applied to `initial_declared_price` at `wrap()` | Harberger Treasury |
| **Buy Fee** | 50 bps (0.5%) | Applied to purchase price at `buy()`, after tax deduction | Harberger Treasury |
| **Auction Fee** | 50 bps (0.5%) | Applied to auction price at `auction_buy()`, after tax deduction | Harberger Treasury |

These fees are hardcoded and cannot be modified by integrating protocols.

**Treasury:** The Harberger Treasury is a shared object on Sui. Revenue distribution is governed by a separate module outside the scope of this specification.

---

## Appendix A — Glossary

| Term | Definition |
|---|---|
| **HarbergerAsset** | Any asset wrapped under Harberger mechanics |
| **HarbergerState** | Internal state tracking declared price, lien, and auction status |
| **Standard State** | Asset is held. Lien accrues. Always purchasable at declared price. |
| **Auction State** | Dutch Auction active. Price descending. Irrevocable. |
| **Expired State** | Auction reached zero with no buyer. Tax debt lost. Integrator resolves. |
| **Declared Price** | The self-assessed price at which the asset can be forcibly purchased. Set once at acquisition; can only be changed via self-repurchase. |
| **Tax Lien** | The accumulated tax debt, growing continuously, settled at sale or unwrap |
| **Deferred Tax** | Tax is not prepaid — it accrues as a lien and is settled at the moment of sale |
| **Self-Repurchase** | The only mechanism to change a declared price. The holder buys their own asset via `buy()`, settling the accumulated lien and declaring a new price. |
| **TaxStrategy** | Integrator-defined struct encoding the tax accrual formula. The curve shape determines which holder behavior is penalized (see section 5.4). |
| **AuctionStrategy** | Integrator-defined struct encoding the Dutch Auction price descent curve. The descent speed determines whether the auction functions as price discovery or liquidation (see section 6.1). |
| **compute_tax()** | Integrator-implemented function called by Harberger at settlement time |
| **compute_auction_price()** | Integrator-implemented function called by Harberger during an active auction |
| **resolve_expired_auction()** | Integrator-callable function to reclaim the underlying asset after an auction expires with no buyer |

---

## Appendix B — Security Considerations

1. **Reentrancy:** All state mutations complete before external Coin transfers. Sui's object model provides natural reentrancy protection.

2. **Integer Overflow:** `compute_tax()` and `compute_auction_price()` use u64 arithmetic. Integrators must use checked arithmetic, especially for non-linear strategies where large values overflow faster.

3. **Clock Manipulation:** The module depends on `sui::clock::Clock`, a system object updated by validators. It is resistant to manipulation but has consensus-round granularity.

4. **TaxStrategy Validation:** Harberger dry-runs `compute_tax()` at `wrap()` time. A strategy returning 0 for non-zero price and elapsed time is rejected. A panicking implementation causes `wrap()` to abort.

5. **AuctionStrategy Validation:** Harberger validates that `compute_auction_price()` returns `declared_price` at `t=0` and a strictly lower value at `t>0`. A strategy that never descends is rejected at wrap time.

6. **Tax Lien Transparency:** `pending_tax()` and `net_proceeds()` are public. Buyers are expected to inspect these before purchasing. Harberger does not abstract the lien — it is first-class information.

7. **Upgrade Safety:** The module should be published as an immutable package. If upgradability is desired, changes must be governed by a timelock DAO with a minimum 7-day delay.

---

*End of specification. For implementation details, test vectors, and reference code, see the companion repository.*
