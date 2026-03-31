# Harberger — Technical Specification

**Version:** 1.0.0-draft
**Target Runtime:** Sui Move
**Authors:** [Protocol Team]
**Status:** Draft — For Review

---

## Abstract

Harberger is a composable Sui Move module that places any asset under continuous Harberger taxation. Any asset wrapped by the module is always for sale at its declared price. Tax accrues silently as a lien on the asset and is settled automatically at the moment of sale. When the tax lien reaches the declared price, a Dutch Auction is triggered to guarantee the asset finds a new owner at market price.

The module is designed as a protocol-level primitive — not an application. It can be imported by any Sui protocol to bring Harberger market mechanics to its own assets. The integrating protocol defines its own tax formula and auction descent curve; Harberger handles everything else.

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

- The holder declares a price for their asset.
- They must pay a recurring tax proportional to that price.
- Anyone can buy the asset at the declared price at any time.

This creates a continuous dilemma: declare too low and risk losing the asset cheaply; declare too high and pay prohibitive tax. The Nash Equilibrium is honest pricing — the holder declares their true private valuation.

**Why existing solutions fall short:**

- **Traditional marketplaces** require the holder to actively list. There is no cost to holding an unlisted asset indefinitely.
- **Harberger with vaults** require the holder to prepay tax and manage a vault balance. If the vault empties, forced liquidation creates perverse incentives that can be gamed.
- **AMM-based pricing** requires liquidity pools and counterparties. Price discovery depends on active market making.

**What Harberger the module does differently:**

- **No vault, no prepayment.** Tax accrues as a deferred lien, settled at the moment of sale. The holder manages nothing.
- **Always for sale.** Every asset in Harberger State is permanently purchasable at its declared price. No listing required.
- **Dutch Auction as safety valve.** When the tax lien reaches the declared price, a Dutch Auction guarantees price discovery even for assets with inflated declared prices.
- **Genuine market only.** If an asset has no buyers at any price, the protocol acknowledges this honestly. No mechanism can manufacture interest where none exists — that is a property of the asset, not a limitation of the protocol.

---

## 2. Core Concepts

### 2.1 HarbergerAsset

A `HarbergerAsset<T>` is any asset of type `T` wrapped under Harberger mechanics. Wrapping transfers the asset into the module and attaches a `HarbergerState` to it.

```
HarbergerAsset<T> {
    id: UID,
    asset: T,                          // The underlying asset
    state: HarbergerState,             // Harberger mechanics
    tax_strategy: TaxStrategy,         // How tax is calculated (set by integrator)
    auction_strategy: AuctionStrategy, // How auction price descends (set by integrator)
    wrapped_at: u64,                   // Timestamp of wrapping
}
```

### 2.2 HarbergerState

The internal state tracking pricing, tax lien, and auction status.

```
HarbergerState {
    declared_price: u64,               // Self-assessed price in payment token
    last_sale_at: u64,                 // Timestamp of last sale (lien resets here)
    cooldown_until: u64,               // Timestamp until price can be changed again
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

HYS calls this at settlement time:

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

The protocol has exactly two states.

```
              ┌─────────────────────────────────────────────────┐
              │              STANDARD STATE                     │
              │                                                 │
              │  Asset is held. Tax lien accrues silently.      │
              │  Asset is always purchasable at declared_price. │
              │                                                 │
              │  The holder can:                                │
              │    • Hold indefinitely (lien grows)             │
              │    • Set a new declared price (cooldown applies)│
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
              │  If price reaches zero with no buyer:           │
              │    Asset stays at zero. No market exists.       │
              │    Integrator decides what happens next.        │
              │                                                 │
              └──────────────┬──────────────────────────────────┘
                             │
                      buyer acquires
                             │
                             ▼
                      STANDARD STATE
                    (new owner, lien reset)
```

### 3.1 Transition Rules

| Transition | Trigger | Pre-condition | Post-condition |
|---|---|---|---|
| **Wrap** | `wrap()` | Caller owns asset of type `T` | HarbergerAsset created in Standard State |
| **Buy** | `buy()` | Asset in Standard State. Buyer pays ≥ declared_price. | Tax lien settled. Ownership transfers. Lien resets. |
| **Set Price** | `set_price()` | Not in auction. Cooldown expired. | declared_price updated. Cooldown restarted. |
| **Trigger Auction** | `trigger_auction()` | `tax_owed >= declared_price` | Asset enters Auction State. Irrevocable. |
| **Auction Buy** | `auction_buy()` | Asset in Auction State. Buyer pays ≥ current_price(t). | Tax settled. Ownership transfers. Back to Standard State. |
| **Unwrap** | `unwrap()` | Caller owns asset. Tax lien paid by caller. | HarbergerAsset destroyed. Underlying asset returned. |

---

## 4. Module Interface

### 4.1 Core Functions

```move
/// Wraps an asset under Harberger mechanics.
/// The integrator provides TaxStrategy, AuctionStrategy, and initial declared price.
public fun wrap<T: store + key>(
    asset: T,
    declared_price: u64,
    tax_strategy: TaxStrategy,
    auction_strategy: AuctionStrategy,
    config: &HarbergerConfig,
    clock: &Clock,
    ctx: &mut TxContext
): HarbergerAsset<T>
```

```move
/// Purchases the asset at its declared price.
/// Tax lien is deducted from proceeds before seller receives payment.
public fun buy<T: store + key>(
    asset: &mut HarbergerAsset<T>,
    payment: Coin<PAYMENT>,
    new_declared_price: u64,
    max_acceptable_price: u64,        // Reverts if declared_price > this
    config: &HarbergerConfig,
    clock: &Clock,
    ctx: &mut TxContext
): Coin<PAYMENT>                      // Net proceeds to previous owner
```

```move
/// Updates the declared price. Subject to cooldown.
/// Cannot be called while asset is in Auction State.
public fun set_price<T: store + key>(
    asset: &mut HarbergerAsset<T>,
    new_price: u64,
    clock: &Clock,
    config: &HarbergerConfig,
)
```

```move
/// Permissionless. Anyone can trigger if tax_owed >= declared_price.
public fun trigger_auction<T: store + key>(
    asset: &mut HarbergerAsset<T>,
    clock: &Clock,
    config: &HarbergerConfig,
)
```

```move
/// Purchases the asset during an active Dutch Auction.
public fun auction_buy<T: store + key>(
    asset: &mut HarbergerAsset<T>,
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
public fun unwrap<T: store + key>(
    asset: HarbergerAsset<T>,
    tax_payment: Coin<PAYMENT>,
    clock: &Clock,
    ctx: &mut TxContext
): (T, Coin<PAYMENT>)
```

### 4.2 View Functions

```move
/// Returns the current tax lien (accrued since last sale).
public fun pending_tax<T: store + key>(
    asset: &HarbergerAsset<T>,
    clock: &Clock,
    config: &HarbergerConfig,
): u64

/// Returns what the seller would receive if sold right now.
public fun net_proceeds<T: store + key>(
    asset: &HarbergerAsset<T>,
    clock: &Clock,
    config: &HarbergerConfig,
): u64  // declared_price - pending_tax (0 if in auction)

/// Returns the current auction price. Aborts if not in auction.
public fun current_auction_price<T: store + key>(
    asset: &HarbergerAsset<T>,
    clock: &Clock,
): u64

/// Returns whether the auction trigger condition is met.
public fun is_auctionable<T: store + key>(
    asset: &HarbergerAsset<T>,
    clock: &Clock,
    config: &HarbergerConfig,
): bool
```

---

## 5. Tax Engine

### 5.1 Deferred Lien Model

Tax accrues continuously while an asset is in Standard State, but is never collected in advance. It exists as an implicit lien — a debt that grows silently and is settled at the next sale or unwrap.

```
Lien grows silently in Standard State
          │
          ├── buy()            → lien deducted from declared_price, remainder to seller
          ├── auction_buy()    → lien deducted from auction price, remainder to seller
          └── unwrap()         → caller pays lien explicitly before asset is returned
```

There is no vault. There is no collect_tax(). There is no keeper network.

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

### 5.4 TaxStrategy Examples

These are illustrative implementations. They live in the integrating protocol's module, not in Harberger.

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

Best for: General-purpose assets, NFTs, IP licenses.

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

Best for: Governance seats, staking positions, DAO-aligned assets.

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

Best for: Domain names, usernames — where long-term squatting should be increasingly expensive.

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

Best for: Assets where a minimum holding cost matters more than price-proportional pressure.

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

Best for: Assets where long-term committed holders should pay progressively less.

---

## 6. Dutch Auction

### 6.1 Why It Is Necessary

In the deferred tax model, a holder can declare an inflated price and never sell. The tax lien grows but since the holder receives nothing on sale once the lien exceeds the declared price, there is no natural incentive to lower the price. The asset freezes — overpriced, unsellable, permanently stuck in Standard State.

The Dutch Auction is the safety valve. When the tax lien reaches the declared price, the asset is automatically put up for sale at a descending price until a buyer appears. This guarantees that every asset will eventually find a market-clearing price, regardless of what the holder declared.

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

If the price descends to zero and no buyer appears, the asset remains at zero. The tax debt goes uncollected. The previous holder receives nothing.

This is not a protocol failure — it confirms the asset has no market at any price. The protocol did its job: it offered the asset at continuously descending prices, giving every potential buyer full opportunity. The absence of buyers is information about the asset.

What happens next is the integrator's decision. HYS exposes the state — price at zero, tax debt outstanding — and does not mandate the outcome. The integrator may archive the asset, allow the holder to reclaim it by paying the debt, or leave it indefinitely. No protocol can create market interest where none exists.

---

## 7. Configurable Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `price_cooldown_seconds` | u64 | 172,800 | Cooldown after price change or purchase (48 hours) |
| `protocol_fee_bps` | u16 | 50 | Fee on each `buy()` and `auction_buy()` (0.5%) |
| `min_declared_price` | u64 | 1 | Minimum declared price (prevents zero-price gaming) |
| `payment_type` | TypeName | — | Coin type for payments (e.g., USDC, SUI) |

Note: Tax formula lives in `TaxStrategy`. Auction descent lives in `AuctionStrategy`. Neither is a top-level config parameter — they are integrator decisions.

### 7.1 Parameter Constraints

- `price_cooldown_seconds` must be ≥ 3600 (1 hour minimum).
- `protocol_fee_bps` must be in range [0, 500].

---

## 8. Game Theory Analysis

### 8.1 The Pricing Dilemma

Every holder faces a continuous optimization problem:

**Declare too low →** Tax lien grows slowly, but anyone can buy the asset cheaply. Risk of losing a valuable asset below its true value.

**Declare too high →** Asset is protected from buyouts, but the lien grows faster. When sold, the holder receives less. If the lien reaches the declared price, a Dutch Auction is triggered.

**Nash Equilibrium:** Declare close to true private valuation. This is Harberger's fundamental insight — self-assessed taxation with forced sale creates an incentive-compatible mechanism where honest pricing is the dominant strategy.

### 8.2 Ownership State vs Harberger State

Some protocols may allow holders to hold assets outside Harberger mechanics (e.g., in a bundled form as in the HYS Split module). For this core module, all wrapped assets are always in Harberger State. The holder's only choice is what price to declare.

### 8.3 Why Tax Payment Is Structurally Unavoidable

Every exit from Harberger State settles the lien:

- **`buy()`** — lien deducted from proceeds automatically.
- **`auction_buy()`** — lien deducted from auction proceeds automatically.
- **`unwrap()`** — caller pays lien explicitly.

There is no exit that bypasses tax. The holder can delay settlement, but cannot avoid it.

### 8.4 On Assets With No Market

If no buyer ever appears, the protocol never collects. This is not a flaw. No protocol can manufacture genuine interest in an asset the market does not want. Harberger is designed for assets with real demand. When that demand exists, the mechanism guarantees honest pricing and continuous liquidity. When it does not, no mechanism can create it — that is a property of the asset, not the protocol.

### 8.5 Equilibrium Summary

| Actor | Optimal Strategy | Protocol Benefit |
|---|---|---|
| **Holder** | Declare true valuation | Continuous honest price discovery |
| **Buyer** | Buy when declared_price < true value | Efficient resource allocation |
| **Speculator** | Buy underpriced assets, hold, resell | Market liquidity |
| **Auction participant** | Buy in auction at market-clearing price | Prevents assets from freezing |

---

## 9. Edge Cases & Attack Vectors

### 9.1 Self-Dealing via Secondary Wallet

**Attack:** Holder uses a second wallet to buy at a low declared price, then re-declares even lower.

**Mitigation:** The 48-hour cooldown means the new owner is exposed at the low price for 2 days — any genuine buyer can front-run. The holder pays the full tax lien regardless of who buys. See section 6.5 for proof that self-dealing is never economically rational.

### 9.2 Front-Running Buy Transactions

**Attack:** Holder sees a `buy()` in the mempool and raises the price before it executes.

**Mitigation:** Sui's consensus mechanism (Narwhal/Bullshark) is more resistant to front-running than EVM. The `max_acceptable_price` parameter on `buy()` protects buyers from price manipulation between submission and execution.

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
let harberger_asset = harberger::wrap(
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
    price_cooldown_seconds: 172_800,
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
| `PriceUpdated` | asset_id, old_price, new_price, cooldown_until | `set_price()` |
| `AuctionTriggered` | asset_id, declared_price, tax_owed, auction_start_time | `trigger_auction()` |
| `AuctionPurchased` | asset_id, buyer, price, tax_deducted, seller_proceeds, new_declared_price | `auction_buy()` |
| `AssetUnwrapped` | asset_id, owner, tax_paid | `unwrap()` |

---

## 11. Application Examples

### 11.1 Domain Names

A naming service integrates Harberger to eliminate squatting:

- Each domain is wrapped as a `HarbergerAsset`.
- TaxStrategy: Quadratic escalation — a squatter holding a domain for years accumulates a massive lien, receiving near-nothing when forced out.
- AuctionStrategy: Linear descent over 7 days — gives ample time for interested buyers to appear.
- Active users hold their domain at a fair declared price — the tax is proportional and predictable.

### 11.2 Governance Seats

A DAO wraps governance seats under Harberger mechanics:

- Each seat always has a declared price. Inactive governors face growing liens.
- TaxStrategy: Epoch-based — aligns with DAO voting cycles.
- If a governor becomes inactive and their lien reaches the seat price, anyone can trigger a Dutch Auction and acquire the seat, bringing active participation back.

### 11.3 NFT Collections

An NFT marketplace integrates Harberger for continuous price discovery:

- Each NFT is wrapped. Declared prices form a live floor price signal.
- TaxStrategy: Linear monthly at 1% — light enough to not burden collectors, meaningful enough to force honest pricing.
- Speculators holding NFTs they don't value pay a growing lien — creating natural sell pressure.

### 11.4 Intellectual Property Licenses

A music or software protocol wraps licenses under Harberger:

- Each license always has a declared price.
- TaxStrategy: Logarithmic decay — early holding is expensive (discourages flipping), long-term holding becomes cheaper (rewards commitment).
- Anyone can always acquire a license at its declared price, ensuring the IP is always accessible to those who value it most.

### 11.5 Virtual Real Estate

A metaverse or on-chain map wraps land parcels:

- TaxStrategy: Linear monthly, rate proportional to parcel size or location value.
- Idle land holders pay continuously. Active builders hold at a fair price.
- Dutch Auction prevents permanently abandoned parcels from freezing the map.

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
| **Declared Price** | The self-assessed price at which the asset can be forcibly purchased |
| **Tax Lien** | The accumulated tax debt, growing silently, settled at sale or unwrap |
| **Deferred Tax** | Tax is not prepaid — it accrues as a lien and is settled at the moment of sale |
| **Cooldown** | Period after a price change during which the price cannot be modified again |
| **TaxStrategy** | Integrator-defined struct encoding the tax accrual formula |
| **AuctionStrategy** | Integrator-defined struct encoding the Dutch Auction price descent curve |
| **compute_tax()** | Integrator-implemented function called by Harberger at settlement time |
| **compute_auction_price()** | Integrator-implemented function called by Harberger during an active auction |

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
