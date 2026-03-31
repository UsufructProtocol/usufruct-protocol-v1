# Harberger Yield Splitter — Technical Specification

**Version:** 0.5.0-draft
**Target Runtime:** Sui Move
**Authors:** [Protocol Team]
**Status:** Draft — For Review

---

## Abstract

The Harberger Yield Splitter (HYS) is a composable Sui Move module that enables any yield-bearing asset to be decomposed into two independent financial instruments — a **Base Token** (the underlying asset) and a **Yield Right** (the claim on future yield) — governed by a Harberger taxation mechanism when separated.

The module introduces a dual-state system: **Ownership State**, where the bundle holder enjoys full ownership and tax immunity, and **Liquidity State**, where each separated component is subject to continuous self-assessed pricing and forced-sale mechanics. Either state can be entered or exited at any time, creating a perpetual game-theoretic equilibrium between holders, speculators, and yield seekers.

HYS uses a **deferred tax model**: no vault, no prepayment. Tax accrues silently as a lien on the asset and is deducted from the holder's proceeds at the moment of sale. When the tax lien reaches the declared price — meaning the holder would receive nothing on sale — a Dutch Auction is triggered automatically to guarantee the asset finds a new owner at market price. This makes paying tax structurally unavoidable while keeping the holder experience simple.

HYS is designed as a protocol-level primitive — not an application. It can be imported by any Sui protocol to add Harberger-governed yield splitting to its own assets. As a primitive, HYS does not impose a specific tax formula — the integrating protocol defines its own `TaxStrategy`, giving full flexibility over how tax accrual is calculated.

---

## Table of Contents

1. [Motivation](#1-motivation)
2. [Core Concepts](#2-core-concepts)
3. [State Machine](#3-state-machine)
4. [Module Interface](#4-module-interface)
5. [Harberger Tax Engine](#5-harberger-tax-engine)
6. [Dutch Auction](#6-dutch-auction)
7. [Yield Distribution](#7-yield-distribution)
8. [Configurable Parameters](#8-configurable-parameters)
9. [Game Theory Analysis](#9-game-theory-analysis)
10. [Edge Cases & Attack Vectors](#10-edge-cases--attack-vectors)
11. [Integration Guide](#11-integration-guide)
12. [Application Examples](#12-application-examples)
13. [Fee Model for the Module](#13-fee-model-for-the-module)

---

## 1. Motivation

Yield-bearing assets (NFTs with royalties, staking positions, LP tokens, IP licenses, DNS domain names, governance seats with fees) share a structural problem: the value of the underlying asset and the value of its future yield are bundled together, making it impossible to price, trade, or speculate on them independently.

Pendle Finance solved this for DeFi tokens by separating Principal Tokens (PT) from Yield Tokens (YT) and creating AMM pools with fixed expiration dates. However, this approach requires deep liquidity pools, active market making, and imposes temporal limits (expiry dates) on yield rights.

The Harberger Yield Splitter takes a fundamentally different approach:

- **No liquidity pools required.** The Harberger mechanism creates unilateral liquidity — any asset in Liquidity State can be purchased at its declared price at any time, without a counterparty waiting on the other side.
- **No expiration dates.** Both Base Token and Yield Right are perpetual instruments. There is no maturity, no rollover, no time decay.
- **Self-regulating price discovery.** The Harberger tax creates an endogenous cost of holding that forces prices to reflect genuine valuations. Overpricing is punished by a larger tax debt deducted on sale. Underpricing is punished by forced acquisition at below-value price.
- **No vault, no prepayment.** Tax accrues as a lien and is settled at sale time. The holder never needs to manage a vault. If the lien reaches the declared price, a Dutch Auction ensures the asset finds a new owner rather than freezing permanently.
- **Composable and generic.** The module operates on any asset type that implements a simple yield trait. The integrating protocol defines what "yield" means and how tax is calculated; HYS handles everything else.

### A Note on Protocol Philosophy

HYS captures value when assets change hands. If an asset never sells, the protocol never collects tax. This is not a flaw — it is an honest reflection of reality.

No protocol can manufacture genuine interest in an asset that the market does not want. HYS is designed for assets that have real demand. When that demand exists, HYS ensures the asset is always priced honestly, always accessible to willing buyers, and always generating tax revenue proportional to the time it has been held. When demand does not exist, no mechanism — Harberger or otherwise — can create it.

The Dutch Auction handles the edge case where a holder declares an inflated price and the market disagrees: it forces a price discovery process that will find the true market-clearing price, even if that price is very low. But it cannot create buyers where none exist. That is a property of the asset, not a limitation of the protocol.

---

## 2. Core Concepts

### 2.1 The Bundle

A Bundle is a wrapped yield-bearing asset in its atomic form. It contains both the claim on the underlying asset and the claim on its yield. While bundled, the asset is in Ownership State.

```
Bundle<T> {
    id: UID,
    asset: T,                          // The underlying yield-bearing asset
    yield_config: YieldConfig,         // How yield is calculated (set by integrator)
    tax_strategy: TaxStrategy,         // How tax is calculated (set by integrator)
    created_at: u64,                   // Timestamp of wrapping
    original_wrap_price: u64,          // Price at time of wrapping (for reference)
}
```

### 2.2 Base Token

The Base Token represents ownership of the underlying asset without any claim on yield. It is minted when a Bundle is split, and destroyed when a merge occurs.

```
BaseToken<T> {
    id: UID,
    bundle_id: ID,                     // Reference to the original bundle
    asset: T,                          // The underlying asset
    liquidity: LiquidityState,         // Harberger state
}
```

### 2.3 Yield Right

The Yield Right represents a perpetual claim on the yield generated by the underlying asset, without ownership of the asset itself. It is a standalone financial instrument that can be held, traded, or speculated on independently.

```
YieldRight {
    id: UID,
    bundle_id: ID,                     // Reference to the original bundle
    yield_config: YieldConfig,         // Inherited yield parameters
    liquidity: LiquidityState,         // Harberger state
    accumulated_yield: u64,            // Unclaimed yield balance
}
```

### 2.4 LiquidityState

The internal state container attached to any asset in Liquidity State (either BaseToken or YieldRight). There is no vault — tax accrues as an implicit lien tracked by `entered_liquidity_at` and `last_sale_at`.

```
LiquidityState {
    declared_price: u64,               // Self-assessed price in payment token
    entered_liquidity_at: u64,         // Timestamp when asset entered Liquidity State
    last_sale_at: u64,                 // Timestamp of last sale (tax lien resets here)
    cooldown_until: u64,               // Timestamp until which price cannot be changed
    tax_strategy: TaxStrategy,         // Inherited from Bundle at split time
    auction_strategy: AuctionStrategy, // Inherited from Bundle at split time
    in_auction: bool,                  // Whether a Dutch Auction is currently active
    auction_start_time: u64,           // Timestamp when auction was triggered
}
```

### 2.5 TaxStrategy

The `TaxStrategy` is a struct defined and provided by the integrating protocol. It encodes all the logic needed to compute `tax_owed` given the current asset state and elapsed time. HYS does not provide a default implementation — the integrator is fully responsible for this.

```move
/// Defined by the integrating protocol. Stored inside LiquidityState.
public struct TaxStrategy has store, copy, drop {
    params: vector<u8>,                // Encoded parameters for the formula
    strategy_type: u8,                 // Identifier for the formula variant
}
```

HYS calls a single entry point to compute tax, which the integrating protocol must implement:

```move
/// The integrating protocol implements this function.
/// HYS calls it at the moment of sale to determine tax_owed.
public fun compute_tax(
    strategy: &TaxStrategy,
    declared_price: u64,
    last_sale_at: u64,
    clock: &Clock,
): u64  // Returns tax_owed
```

#### Invariants enforced by HYS

Regardless of the formula, HYS enforces the following invariants at the module level:

1. If `declared_price > 0` and `elapsed_time > 0`, then `compute_tax()` must return a value > 0. This is validated at split time with a dry-run check.
2. The function must be deterministic and depend only on on-chain state — no oracle inputs, no randomness.

These invariants preserve the core Harberger property: holding an asset in Liquidity State always has a real, ongoing cost — even if that cost is only realized at sale time.

### 2.6 AuctionStrategy

The `AuctionStrategy` is a struct defined and provided by the integrating protocol. It encodes the price descent curve of the Dutch Auction. HYS does not provide a default — the integrator defines it.

```move
public struct AuctionStrategy has store, copy, drop {
    params: vector<u8>,                // Encoded parameters for the descent curve
    strategy_type: u8,                 // Identifier for the curve variant
}
```

HYS calls this to compute the current auction price:

```move
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

The protocol has exactly two states and three transitions.

```
                    ┌─────────────────────────────────────────────┐
                    │              OWNERSHIP STATE                │
                    │                                             │
                    │  Bundle<T> held in a single wallet.         │
                    │  No tax. Not for sale. Full ownership.      │
                    │                                             │
                    │  The holder can:                            │
                    │    • Hold indefinitely at zero cost         │
                    │    • Voluntarily list on any marketplace    │
                    │    • Split into Base + YieldRight           │
                    │                                             │
                    └──────────────────┬──────────────────────────┘
                                       │
                                   split()
                                       │
                          ┌────────────┴────────────┐
                          ▼                         ▼
              ┌───────────────────┐     ┌───────────────────┐
              │   LIQUIDITY       │     │   LIQUIDITY       │
              │   (BaseToken)     │     │   (YieldRight)    │
              │                   │     │                   │
              │ • Declared price  │     │ • Declared price  │
              │ • Tax accrues     │     │ • Tax accrues     │
              │   as lien         │     │   as lien         │
              │ • Always for sale │     │ • Always for sale │
              │ • Tax deducted    │     │ • Tax deducted    │
              │   on sale         │     │   on sale         │
              └────────┬──────────┘     └────────┬──────────┘
                       │                         │
                       │    ┌────────────┐       │
                       └───►│  merge()   │◄──────┘
                            │            │
                            │ Both in    │
                            │ same wallet│
                            └─────┬──────┘
                                  │
                                  ▼
                          OWNERSHIP STATE (restored)
```

### 3.1 Transition Rules

| Transition | Trigger | Pre-condition | Post-condition |
|---|---|---|---|
| **Wrap** | `wrap()` called by asset owner | Caller owns a yield-bearing asset of type `T` | Bundle created in Ownership State |
| **Split** | `split()` called by bundle holder | Caller owns the Bundle | Bundle destroyed. BaseToken and YieldRight created, both in Liquidity State. Initial declared price required. |
| **Merge** | `merge()` called by holder of both | Caller owns BaseToken AND YieldRight with matching `bundle_id` | Both destroyed. Bundle recreated in Ownership State. Tax on both components settled from caller's payment before merge completes. |
| **Buy** | `buy()` called by any address | Target asset is in Liquidity State. Buyer sends ≥ declared price. | Tax deducted from proceeds. Remainder to seller. Ownership transfers. Buyer declares new price. |

---

## 4. Module Interface

### 4.1 Core Functions

```move
/// Wraps a yield-bearing asset into a Harberger Bundle (Ownership State).
/// The integrating protocol calls this when an asset is first registered.
public fun wrap<T: store + key>(
    asset: T,
    yield_config: YieldConfig,
    tax_strategy: TaxStrategy,
    initial_reference_price: u64,
    ctx: &mut TxContext
): Bundle<T>
```

```move
/// Splits a Bundle into BaseToken + YieldRight (both enter Liquidity State).
/// Caller must provide initial declared prices. No vault deposit required.
public fun split<T: store + key>(
    bundle: Bundle<T>,
    base_declared_price: u64,
    yield_declared_price: u64,
    config: &HarbergerConfig,
    clock: &Clock,
    ctx: &mut TxContext
): (BaseToken<T>, YieldRight)
```

```move
/// Merges BaseToken + YieldRight back into a Bundle (Ownership State restored).
/// Caller must provide payment to cover accumulated tax on both components.
/// Any excess payment is returned to the caller.
public fun merge<T: store + key>(
    base: BaseToken<T>,
    yield_right: YieldRight,
    tax_payment: Coin<PAYMENT>,
    clock: &Clock,
    ctx: &mut TxContext
): (Bundle<T>, Coin<PAYMENT>)  // Returns bundle + change
```

```move
/// Forced purchase at declared price. Works on BaseToken.
/// Tax is deducted from proceeds before the seller receives payment.
/// The buyer must declare a new price.
public fun buy_base<T: store + key>(
    base: &mut BaseToken<T>,
    payment: Coin<PAYMENT>,
    new_declared_price: u64,
    max_acceptable_price: u64,         // Reverts if current price > this
    config: &HarbergerConfig,
    clock: &Clock,
    ctx: &mut TxContext
): Coin<PAYMENT>  // Returns net proceeds to previous owner (after tax)
```

```move
/// Forced purchase at declared price. Works on YieldRight.
public fun buy_yield_right(
    yield_right: &mut YieldRight,
    payment: Coin<PAYMENT>,
    new_declared_price: u64,
    max_acceptable_price: u64,
    config: &HarbergerConfig,
    clock: &Clock,
    ctx: &mut TxContext
): Coin<PAYMENT>  // Returns net proceeds to previous owner (after tax)
```

```move
/// Updates the declared price. Subject to cooldown period.
/// Does not trigger tax settlement — tax is always deferred to sale.
public fun set_price_base<T: store + key>(
    base: &mut BaseToken<T>,
    new_price: u64,
    clock: &Clock,
    config: &HarbergerConfig,
)
```

```move
public fun set_price_yield_right(
    yield_right: &mut YieldRight,
    new_price: u64,
    clock: &Clock,
    config: &HarbergerConfig,
)
```

### 4.2 View Functions

```move
/// Returns the current tax accrued since last sale, not yet settled.
public fun pending_tax_base<T: store + key>(
    base: &BaseToken<T>,
    clock: &Clock,
    config: &HarbergerConfig,
): u64

public fun pending_tax_yield_right(
    yield_right: &YieldRight,
    clock: &Clock,
    config: &HarbergerConfig,
): u64

/// Returns the net proceeds the seller would receive if sold right now.
/// Useful for holders to understand their actual sale value.
public fun net_proceeds_base<T: store + key>(
    base: &BaseToken<T>,
    clock: &Clock,
    config: &HarbergerConfig,
): u64  // declared_price - pending_tax

/// Returns whether both components can be merged (same bundle_id).
public fun is_mergeable<T: store + key>(
    base: &BaseToken<T>,
    yield_right: &YieldRight,
): bool
```

---

## 5. Harberger Tax Engine

### 5.1 Tax Model — Deferred Lien

Tax accrues continuously from the moment an asset enters Liquidity State, but is **never collected in advance**. It exists as an implicit lien on the asset — a debt that grows silently and is settled in full at the next sale or merge.

There is no vault. There is no collect_tax(). The only trigger for forced liquidation is when the tax lien reaches the declared price — at that point a Dutch Auction is initiated (see section 6).

```
Tax lien grows silently while asset is held in Liquidity State
              │
              ├── buy() called                    → tax deducted from declared_price before seller is paid
              ├── merge() called                  → tax paid by caller before bundle is reconstructed
              └── tax_owed >= declared_price      → Dutch Auction triggered automatically
```

### 5.2 Tax Calculation

Tax is computed by calling `compute_tax()` on the asset's `TaxStrategy` at settlement time:

```move
// Internal call within HYS at the moment of sale or merge:
let tax_owed = integrator::compute_tax(
    &liquidity_state.tax_strategy,
    liquidity_state.declared_price,
    liquidity_state.last_sale_at,
    clock,
);
```

### 5.3 Settlement at Sale

When `buy()` is called, HYS settles the tax lien before distributing proceeds:

```
Buyer pays: declared_price
  │
  ├── tax_owed          → integrator treasury
  ├── protocol_fee_bps  → HYS treasury
  └── remainder         → seller
```

If `tax_owed >= declared_price`, the normal `buy()` path is no longer available — the asset has entered Dutch Auction (see section 6). The seller receives nothing from the auction proceeds since the full tax debt exceeds the declared price.

### 5.4 Settlement at Merge

When `merge()` is called, the caller must provide a `tax_payment` coin to cover the accumulated tax on both the BaseToken and the YieldRight. HYS computes both amounts, deducts them from `tax_payment`, and returns the change.

```
Caller provides: tax_payment (must cover tax_base + tax_yield_right)
  │
  ├── tax_base        → integrator treasury
  ├── tax_yield_right → integrator treasury
  └── change          → returned to caller
```

This ensures tax is always paid when components leave Liquidity State, regardless of whether a third-party buyer is involved.

### 5.5 TaxStrategy Examples

The following examples illustrate what an integrating protocol might implement. These are not part of HYS itself — they live in the integrating protocol's module.

---

#### Example A — Linear Monthly

The simplest strategy. Tax accrues at a fixed percentage per month, calculated in real seconds.

```move
public fun compute_tax(
    strategy: &TaxStrategy,
    declared_price: u64,
    last_sale_at: u64,
    clock: &Clock,
): u64 {
    let tax_rate_bps = decode_u16(strategy.params, 0);  // e.g. 200 = 2% monthly
    let now = clock::timestamp_ms(clock) / 1000;
    let elapsed = now - last_sale_at;
    let seconds_per_month: u64 = 2_592_000;

    declared_price * (tax_rate_bps as u64) * elapsed
        / 10_000
        / seconds_per_month
}
```

**Best for:** General-purpose protocols, NFT royalties, IP licenses.

---

#### Example B — Epoch-Based

Tax accrues per Sui epoch instead of per second.

```move
public fun compute_tax(
    strategy: &TaxStrategy,
    declared_price: u64,
    last_sale_at: u64,       // Epoch number at last sale
    clock: &Clock,
): u64 {
    let tax_rate_bps = decode_u16(strategy.params, 0);
    let current_epoch = tx_context::epoch(ctx);
    let elapsed_epochs = current_epoch - last_sale_at;

    declared_price * (tax_rate_bps as u64) * elapsed_epochs / 10_000
}
```

**Best for:** Staking protocols, DAO governance seats where epoch rhythm is natural.

---

#### Example C — Quadratic Escalation

Tax grows quadratically with time. Short-term holding is cheap; long-term holding becomes increasingly expensive.

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
    let days_elapsed = elapsed / 86_400;

    declared_price * (base_rate_bps as u64) * days_elapsed * days_elapsed
        / 10_000
        / 86_400
}
```

**Best for:** Domain names, governance seats where the protocol wants to strongly discourage long-term speculative holding.

---

#### Example D — Flat Daily Fee

Tax is a fixed daily fee regardless of declared price.

```move
public fun compute_tax(
    strategy: &TaxStrategy,
    declared_price: u64,
    last_sale_at: u64,
    clock: &Clock,
): u64 {
    let daily_fee = decode_u64(strategy.params, 0);
    let now = clock::timestamp_ms(clock) / 1000;
    let elapsed = now - last_sale_at;

    daily_fee * elapsed / 86_400
}
```

**Best for:** Protocols where a minimum holding cost is more important than price-proportional tax pressure.

---

#### Example E — Logarithmic Decay

Tax rate decreases logarithmically over time. Rewards long-term committed holders.

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

    declared_price * adjusted_rate * elapsed
        / 10_000
        / 2_592_000
}
```

**Best for:** Protocols that want to incentivize long-term holders while still maintaining Harberger pressure.

---

## 6. Dutch Auction

### 6.1 Why the Dutch Auction Is Necessary

In the deferred tax model, a holder can declare an inflated price and never sell. The tax lien grows but the asset stays frozen — no buyer will pay an above-market declared price, and the holder has no reason to lower it since they receive nothing on sale anyway once the lien is large enough.

Without a forced liquidation mechanism, overpriced assets become permanently stuck. The Dutch Auction solves this: when the tax lien reaches the declared price, the asset is automatically put up for sale at a descending price until a buyer appears. This guarantees that every asset in Liquidity State will eventually find a market-clearing price, regardless of what the holder declared.

### 6.2 Trigger

A Dutch Auction is triggered automatically when:

```
tax_owed >= declared_price
```

This is checked on every `buy()` and `set_price()` call, and can also be triggered permissionlessly by anyone calling `trigger_auction()` if the condition is met.

```move
/// Permissionless. Anyone can trigger an auction if tax_owed >= declared_price.
public fun trigger_auction_base<T: store + key>(
    base: &mut BaseToken<T>,
    clock: &Clock,
    config: &HarbergerConfig,
)

public fun trigger_auction_yield_right(
    yield_right: &mut YieldRight,
    clock: &Clock,
    config: &HarbergerConfig,
)
```

Once triggered, the auction is **irrevocable**. The holder cannot cancel it.

### 6.3 Mechanism

The auction starts at `declared_price` and descends according to the asset's `AuctionStrategy`. The integrator defines the speed and curve of descent.

```move
// Internal call within HYS to get the current auction price:
let current_price = integrator::compute_auction_price(
    &liquidity_state.auction_strategy,
    liquidity_state.declared_price,
    liquidity_state.auction_start_time,
    clock,
);
```

**AuctionStrategy examples:**

**Linear descent** — price drops at a constant rate:
```move
public fun compute_auction_price(
    strategy: &AuctionStrategy,
    declared_price: u64,
    auction_start_time: u64,
    clock: &Clock,
): u64 {
    let duration = decode_u64(strategy.params, 0);  // e.g. 86_400 = 24 hours
    let now = clock::timestamp_ms(clock) / 1000;
    let elapsed = now - auction_start_time;
    if (elapsed >= duration) return 0;
    declared_price * (duration - elapsed) / duration
}
```

**Stepped descent** — price drops in fixed intervals, more predictable for buyers:
```move
public fun compute_auction_price(
    strategy: &AuctionStrategy,
    declared_price: u64,
    auction_start_time: u64,
    clock: &Clock,
): u64 {
    let step_duration = decode_u64(strategy.params, 0);  // e.g. 3_600 = 1hr per step
    let step_pct = decode_u8(strategy.params, 8);        // e.g. 10 = drop 10% per step
    let now = clock::timestamp_ms(clock) / 1000;
    let steps_elapsed = (now - auction_start_time) / step_duration;
    let discount = steps_elapsed * (step_pct as u64);
    if (discount >= 100) return 0;
    declared_price * (100 - discount) / 100
}
```

### 6.4 Payment Flow on Acquisition

```
Buyer pays: current_price(t)
  │
  ├── tax_owed (up to current_price)  → integrator treasury
  ├── protocol_fee_bps                → HYS treasury
  └── remainder                       → seller (may be zero)
```

Since the auction is triggered precisely when `tax_owed >= declared_price`, and the auction starts at `declared_price`, the seller will receive zero or near-zero in most cases. The entire payment goes to settle the tax debt.

After acquisition, the buyer must declare a new price and the asset re-enters normal Liquidity State with `last_sale_at` reset.

### 6.5 Why Second-Wallet Repurchase Is Always Irrational

A holder might consider using a second wallet to repurchase their own asset during the auction at a lower price. The following four cases prove this is never rational.

In all cases: `buy_price` = what the holder originally paid for the asset.

---

**Case 1 — declared_price < buy_price, tax_owed < declared_price (normal sale)**

```
buy_price:       100 USDC
declared_price:   80 USDC
tax_owed:         20 USDC

Second wallet buys at 80 USDC:
  → 20 USDC to protocol
  → 60 USDC to holder

Total spent = 100 (original) + 80 (repurchase) − 60 (received) = 120 USDC
```

The holder already lost money declaring below buy_price. Repurchase makes it worse.

---

**Case 2 — declared_price < buy_price, tax_owed >= declared_price (auction)**

```
buy_price:       100 USDC
declared_price:   80 USDC
tax_owed:         90 USDC  → auction triggered

Second wallet buys in auction at 50 USDC:
  → 50 USDC to protocol (100%, tax_owed > auction_price)
  → 0 USDC to holder

Total spent = 100 + 50 − 0 = 150 USDC
```

Holder receives nothing and paid 50 USDC extra. Strictly worse than Case 1.

---

**Case 3 — declared_price >= buy_price, tax_owed < declared_price (normal sale)**

```
buy_price:       100 USDC
declared_price:  150 USDC
tax_owed:         30 USDC

Second wallet buys at 150 USDC:
  → 30 USDC to protocol
  → 120 USDC to holder

Total spent = 100 + 150 − 120 = 130 USDC
```

The holder paid exactly the tax they owed (30 USDC net). No gaming advantage — any legitimate buyer would produce the same outcome.

---

**Case 4 — declared_price >= buy_price, tax_owed >= declared_price (auction)**

```
buy_price:       100 USDC
declared_price:  150 USDC
tax_owed:        160 USDC  → auction triggered

Second wallet buys in auction at 80 USDC:
  → 80 USDC to protocol (100%)
  → 0 USDC to holder

Total spent = 100 + 80 − 0 = 180 USDC
```

The worst case. The holder spent 180 USDC on an asset that originally cost 100 USDC.

---

**Summary:** In every case, the total cost of repurchase equals `buy_price + something`. The holder always ends up paying more than they originally paid. Second-wallet repurchase is structurally irrational because the tax-first payment priority ensures the holder can never extract value from their own auction.

### 6.6 Yield Right During Auction

When a YieldRight enters Dutch Auction, yield accumulation continues normally. The new buyer acquires the YieldRight with its full accumulated yield intact. This is consistent with the deferred tax model — yield and tax are independent; the tax lien does not affect yield accumulation.

---

## 7. Yield Distribution

### 6.1 Yield Config

The integrating protocol must implement a yield source. The HYS module defines a generic interface:

```move
/// The integrating protocol implements this to define how yield is calculated.
public struct YieldConfig has store, copy, drop {
    yield_type: u8,                    // Protocol-defined yield type identifier
    yield_source_id: ID,               // Reference to the yield-generating object
    yield_rate_bps: u16,               // Basis points of each qualifying event
    custom_data: vector<u8>,           // Protocol-specific configuration
}
```

### 6.2 Yield Flow

```
Yield-Generating Event (sale, fee, distribution, etc.)
    │
    ├── Bundle exists (Ownership State)
    │       └── Yield accrues to Bundle holder
    │
    └── Split exists (Liquidity State)
            └── Yield accrues to YieldRight.accumulated_yield
                regardless of tax lien status
```

Note: In the deferred tax model, there is no default state and no yield suspension. The YieldRight always accumulates yield while in Liquidity State. Tax is settled when the YieldRight is sold or merged — not before.

### 6.3 Claiming Yield

```move
/// Claims accumulated yield from a YieldRight.
public fun claim_yield(
    yield_right: &mut YieldRight,
    clock: &Clock,
    ctx: &mut TxContext
): Coin<PAYMENT>
```

Yield can be claimed at any time. There is no lock-up or vesting period. The `accumulated_yield` counter resets to zero upon claim.

---

## 8. Configurable Parameters

The module is initialized with a `HarbergerConfig` object controlled by the integrating protocol's governance.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `price_cooldown_seconds` | u64 | 172,800 | Cooldown after price change or purchase (48 hours) |
| `protocol_fee_bps` | u16 | 50 | Fee on each `buy()` and auction acquisition (0.5%) |
| `min_declared_price` | u64 | 1 | Minimum declared price (prevents zero-price gaming) |
| `payment_type` | TypeName | — | The coin type used for payments (e.g., USDC, SUI) |

Note: `tax_rate_bps` lives inside `TaxStrategy`. Auction descent logic lives inside `AuctionStrategy`. Neither is a top-level config parameter.

The following parameters from previous versions have been removed:

| Removed Parameter | Reason |
|---|---|
| `tax_rate_bps` | Lives inside `TaxStrategy` |
| `vault_min_runway_seconds` | No vault in deferred tax model |
| `collector_reward_bps` | No tax collection function |
| `penalty_bps` | Tax-first priority replaces penalty as anti-abuse mechanism |
| `dutch_auction_duration_seconds` | Lives inside `AuctionStrategy` |
| `auction_premium_pct` | Auction starts at declared_price, no premium |

### 8.1 Parameter Constraints

- `price_cooldown_seconds` must be ≥ 3600 (1 hour minimum).
- `protocol_fee_bps` must be in range [0, 500].

---

## 9. Game Theory Analysis

### 9.1 The Pricing Dilemma (Core Mechanism)

Every holder in Liquidity State faces a continuous optimization problem:

**Declare too low →** The tax lien grows slowly, but anyone can buy the asset at the declared price. The holder risks losing a valuable asset for less than its true value.

**Declare too high →** The asset is protected from buyouts, but the tax lien grows faster. When the asset is eventually sold or merged, the holder receives less. The longer they hold at a high price, the larger the deduction.

**The Nash Equilibrium** is to declare a price close to the holder's true private valuation. This is the fundamental insight of Harberger taxation: it creates an incentive-compatible mechanism where truthful price revelation is the dominant strategy. This property holds regardless of the specific tax formula — as long as `compute_tax()` returns a positive value, the dilemma exists.

### 9.2 The Peace/Sovereign Dilemma

The bundle holder faces a second-order decision: split or hold?

**Hold (Ownership State):**
- Zero ongoing tax.
- No forced-sale risk.
- But: no liquidity, no yield separation, no ability to speculate independently on Base vs. Yield.

**Split (Liquidity State):**
- Immediate liquidity for one or both components.
- Ability to sell the YieldRight while keeping the Base (or vice versa).
- But: tax lien grows on both components, forced-sale exposure at declared price.

**Rational split occurs when:**
```
Value(Base alone) + Value(YieldRight alone) - PV(tax lien) > Value(Bundle)
```

### 9.3 The Merge Arbitrage

If the market separately prices BaseToken at P_b and YieldRight at P_y, but a Bundle in Ownership State is worth P_bundle > P_b + P_y + tax_savings, then an arbitrageur can:

1. Buy the BaseToken at P_b (tax deducted from seller's proceeds).
2. Buy the YieldRight at P_y (tax deducted from seller's proceeds).
3. Pay the merge tax to reconstruct the Bundle.
4. Hold in Ownership State (no further tax) or sell the Bundle at P_bundle.

This creates a price floor on the separated components.

### 9.4 Why Paying Tax Is Structurally Unavoidable

In the deferred tax model, a holder cannot evade tax by holding indefinitely. Every exit path from Liquidity State triggers tax settlement:

- **`buy()`** — tax deducted from proceeds automatically by HYS.
- **`merge()`** — caller must explicitly pay tax before bundle is reconstructed.

There is no path out of Liquidity State that bypasses tax. The holder can delay it, but cannot avoid it. The longer they delay, the larger the lien. The only choice is when to pay, not whether to pay.

### 9.5 Equilibrium Summary

| Actor | Optimal Strategy | Protocol Benefit |
|---|---|---|
| **Holder (Peace)** | Hold bundle, avoid tax lien | Asset removed from market → scarcity |
| **Holder (Sovereign)** | Declare true valuation, sell when ready | Continuous price discovery |
| **Yield Seeker** | Buy YieldRight, accumulate yield | Yield market exists independently |
| **Speculator** | Buy BaseToken, target appreciation | Liquidity in base asset market |
| **Arbitrageur** | Merge underpriced components | Price correction, market efficiency |

---

## 10. Edge Cases & Attack Vectors

### 9.1 Self-Dealing via Secondary Wallet

**Attack:** Holder declares low price, uses a second wallet to buy at that price, re-declares even lower, effectively washing out tax debt cheaply.

**Mitigation:** The 48-hour price cooldown means the new owner is exposed at the low price for 2 days. Any genuine interested buyer can purchase at that price during the cooldown window. The holder pays tax on the full elapsed period regardless — self-dealing does not reduce the tax owed.

### 9.2 Front-Running Buy Transactions

**Attack:** Holder sees a `buy()` transaction in the mempool and front-runs with a `set_price()` to increase the cost.

**Mitigation:** On Sui, transaction ordering is handled by the consensus mechanism (Narwhal/Bullshark), which provides more resistance to front-running than EVM chains. The `max_acceptable_price` parameter on `buy()` protects buyers from price manipulation between transaction submission and execution.

### 9.3 Tax Lien Overflow

**Attack/Risk:** An asset sits in Liquidity State for an extremely long time with a high declared price. The tax lien grows until it exceeds the declared price — the seller would receive nothing on sale.

**Mitigation:** This is not a protocol failure — it is the correct economic outcome. A holder who declares a high price and never sells accumulates a large lien. The protocol captures the full declared price on sale. The integrator should configure the `TaxStrategy` carefully to ensure the lien growth rate is reasonable relative to typical holding periods. A linear 2%/month strategy takes 50 months to consume the full declared price — well beyond typical market activity.

### 9.4 Yield Accumulation Without Tax Payment

**Attack:** YieldRight holder accumulates yield indefinitely while the tax lien grows, then sells the YieldRight after claiming all yield, leaving the buyer with a large tax lien.

**Mitigation:** The tax lien is transparent and visible via `pending_tax_yield_right()`. Any buyer can inspect the lien before purchasing. The `buy()` function deducts the tax from the seller's proceeds — the buyer pays `declared_price` and receives a clean asset with `last_sale_at` reset to now. The buyer is not burdened by the previous holder's lien.

### 9.5 Malicious TaxStrategy

**Attack:** An integrating protocol deploys a `TaxStrategy` that always returns 0, effectively disabling the Harberger mechanism.

**Mitigation:** HYS validates the TaxStrategy at `split()` time with a dry-run: it calls `compute_tax()` with a small simulated elapsed time and a non-zero declared price. If the result is 0, the split is rejected.

### 9.6 Price Oracle Manipulation

**Risk:** The module relies on self-assessed prices, not oracle prices. This is a feature, not a bug. However, integrating protocols should be aware that declared prices may not reflect market price in the traditional sense.

**Guidance:** Protocols that need oracle-based price feeds (e.g., for lending collateral) should not use Harberger declared prices as oracle inputs.

### 9.7 Grief Attack

**Attack:** A malicious actor wraps a worthless asset, splits it, and declares very low prices, forcing the protocol to process many cheap transactions.

**Mitigation:** The `min_declared_price` prevents zero-value declarations. The `protocol_fee_bps` on `buy()` means each cycle costs the attacker real money.

---

## 11. Integration Guide

### 10.1 Minimal Integration

A protocol needs to do five things to integrate HYS:

**Step 1 — Define the asset type.**

```move
public struct MyNFT has key, store {
    id: UID,
    name: String,
    image_url: Url,
}
```

**Step 2 — Define the TaxStrategy.**

```move
let tax_strategy = TaxStrategy {
    strategy_type: LINEAR_MONTHLY,
    params: encode_u16(200),           // 200 bps = 2% monthly
};
```

**Step 3 — Configure yield.**

```move
let yield_config = harberger::new_yield_config(
    yield_type: ROYALTY_TYPE,
    yield_source_id: marketplace_id,
    yield_rate_bps: 400,
    custom_data: vector::empty(),
);
```

**Step 4 — Wrap assets.**

```move
let bundle = harberger::wrap(
    my_nft,
    yield_config,
    tax_strategy,
    initial_price,
    ctx
);
transfer::transfer(bundle, owner);
```

**Step 5 — Route yield.**

```move
harberger::distribute_yield(
    yield_right_id,
    yield_amount,
    payment_coin,
    clock,
    ctx
);
```

### 10.2 Configuration

```move
let config = harberger::new_config(
    price_cooldown_seconds: 172_800,
    protocol_fee_bps: 50,
    min_declared_price: 1_000_000,     // e.g., 1 USDC (6 decimals)
    ctx
);
```

### 10.3 Events

| Event | Fields | Emitted When |
|---|---|---|
| `BundleCreated` | bundle_id, asset_type, owner, reference_price | `wrap()` |
| `BundleSplit` | bundle_id, base_token_id, yield_right_id, base_price, yield_price | `split()` |
| `BundleMerged` | bundle_id, base_token_id, yield_right_id, tax_paid | `merge()` |
| `AssetPurchased` | asset_id, asset_type, seller, buyer, price, tax_deducted, seller_proceeds, new_declared_price | `buy()` |
| `PriceUpdated` | asset_id, old_price, new_price, cooldown_until | `set_price()` |
| `YieldDistributed` | yield_right_id, amount | `distribute_yield()` |
| `YieldClaimed` | yield_right_id, amount, claimer | `claim_yield()` |

---

## 12. Application Examples

### 11.1 NFT Art with Royalties

- The NFT is wrapped as the Base asset.
- The royalty claim becomes the YieldRight.
- TaxStrategy: Linear monthly at 2% — simple and predictable.
- Collectors hold the Bundle (no tax). Yield speculators buy the YieldRight. When the YieldRight sells, accumulated tax is deducted from the seller's proceeds automatically.

### 11.2 Domain Names

- The domain is the Base asset.
- Revenue claim is the YieldRight.
- TaxStrategy: Quadratic escalation — a squatter who holds for years accumulates an enormous lien, receiving almost nothing when forced to sell.
- Active users keep the Bundle (no tax, no lien).

### 11.3 Governance Seats

- The seat is the Base asset.
- Treasury distribution claim is the YieldRight.
- TaxStrategy: Epoch-based — aligns with DAO voting cycles.
- Active governors keep the Bundle. Inactive governors who split face a growing lien on their seat.

### 11.4 Intellectual Property Licenses

- Master recording ownership is the Base asset.
- Streaming revenue claim is the YieldRight.
- TaxStrategy: Logarithmic decay — high initial pressure discourages flipping; committed holders pay less over time.

### 11.5 Staking Positions

- Staked SUI is the Base.
- Staking rewards claim is the YieldRight.
- TaxStrategy: Epoch-based, aligned with Sui's staking epoch rhythm.
- Unlike Pendle: no expiration, no AMM pool needed.

---

## 13. Fee Model for the Module

| Fee | Rate | Trigger | Recipient |
|---|---|---|---|
| **Split Fee** | 10 bps (0.1%) | Applied to `original_wrap_price` when `split()` is called | HYS Treasury |
| **Buy Fee** | 50 bps (0.5%) | Applied to purchase price on each `buy()`, after tax deduction | HYS Treasury |

These fees are hardcoded in the module and cannot be modified by integrating protocols.

**Revenue accrual model:** The HYS Treasury is a shared object on Sui. Revenue distribution is governed by a separate module outside the scope of this specification.

---

## Appendix A — Glossary

| Term | Definition |
|---|---|
| **Bundle** | An atomic wrapper containing both Base Token and Yield Right in Ownership State |
| **Base Token** | The ownership claim on the underlying asset, without yield rights |
| **Yield Right** | The perpetual claim on yield generated by the underlying asset |
| **Ownership State** | Bundle held together — no tax, no forced sale, full sovereignty |
| **Liquidity State** | Components separated — tax lien accrues, always for sale at declared price |
| **Declared Price** | The self-assessed price at which the asset can be forcibly purchased |
| **Tax Lien** | The accumulated tax debt that grows silently while an asset is in Liquidity State, settled at sale or merge |
| **Deferred Tax** | The model in which tax is not collected in advance but settled at the moment of sale or merge |
| **Cooldown** | Period after price change during which the price cannot be modified |
| **Merge Arbitrage** | Buying both components below bundle value and merging for profit |
| **TaxStrategy** | Integrator-defined struct that encodes the tax formula for a specific protocol |
| **compute_tax()** | The function the integrator implements; called by HYS at sale/merge time to determine tax owed |

---

## Appendix B — Security Considerations

1. **Reentrancy:** All state mutations must be completed before external calls (Coin transfers). Sui's object model provides natural reentrancy protection, but integrating protocols should be aware of cross-module interactions.

2. **Integer Overflow:** Tax calculations use u64 arithmetic. For assets with extremely high declared prices and long holding periods, overflow checks must be enforced. The module should use checked arithmetic throughout. This is especially important for non-linear TaxStrategy implementations (e.g., quadratic) where large values can overflow faster.

3. **Clock Manipulation:** The module depends on `sui::clock::Clock` for timestamps. On Sui, the clock is a system object updated by validators and is resistant to manipulation.

4. **TaxStrategy Validation:** HYS validates every TaxStrategy at `split()` time via a dry-run call to `compute_tax()`. Integrators must ensure their implementation does not panic on edge cases (e.g., zero elapsed time, minimum declared price). A panicking `compute_tax()` will cause `split()` to abort, rendering the Bundle unsplittable.

5. **Tax Lien Transparency:** The tax lien is always publicly readable via `pending_tax_base()` and `pending_tax_yield_right()`. Buyers are expected to inspect this before purchasing. HYS does not hide or abstract the lien — it is a first-class piece of information in the protocol.

6. **Upgrade Safety:** The module should be published as an immutable package (no upgrade capability) to guarantee that the rules cannot be changed post-deployment. Alternatively, if upgradability is desired, parameter changes should be governed by a timelock DAO with minimum delay of 7 days.

---

*End of specification. For implementation details, test vectors, and reference code, see the companion repository.*
