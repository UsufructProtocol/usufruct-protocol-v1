# usufruct — Patterns

A field guide for integrators building on top of the **usufruct** protocol.

This document is not a tutorial. It is the *generative principle* behind every pattern that can be built on the protocol, and a forward-looking catalog of where that principle leads.

> The patterns below exist to **inspire**, not to enumerate. They make the design space visible — they do not bound it. **In practice, any logic that orbits a Sui `key + store` object will find a use case in usufruct.** The taxonomy, examples, and worked constructions are scaffolding; the design space itself is whatever an integrator can imagine.

---

## 0. What is usufruct

**usufruct** is an on-chain finite-state machine that governs time-bounded access to any Sui object with `key + store` abilities, with rent paid in any coin type the owner chooses at `integrate()`.

An owner integrates their object into an `Escrow<Asset: key + store, CoinType>`. The FSM takes over from there, managing the full lifecycle across five states:

- `Waiting::Idle` — price rests at its floor; no active tenant.
- `Waiting::AtDutch` — price self-regulates downward until a tenant bids.
- `Waiting::Retired` — owner has exercised the right to reclaim the asset.
- `Renting::Occupied` — asset is in use; `borrow_asset` is callable.
- `Renting::Demand` — asset is in use and price is escalating; a challenger has bid.

Transitions are governed by a `PolicyEnsemble` the owner configures at integration time — eight policies that set the terms under which tenants acquire, hold, and release the right of access: `rest_price`, `tenure_duration`, `tenure_extend`, `handover`, `auction_window`, `auction_shape`, `credit_shape`, and `price_escalation`.

The protocol enforces custody, economics, and lifecycle. What the tenant *does* with the asset during the rental window is outside the protocol's concern — it is defined entirely by the asset's own interface. That is the subject of this document.

---

## The Asset

The sections below describe the design space that opens at the asset level: what an owner integrates, how a tenant uses it, and how integrations compose with one another. The central axis is the pair `borrow_asset` / `return_asset` — two functions that open and close a runtime window inside which the tenant exercises the right they paid for.

---

### 1. The substrate, not the product

The usufruct protocol is a finite-state machine over time-bounded custody of opaque `key + store` objects, with built-in fee accrual, Dutch auctions, handovers, and tenure extension. That is the protocol's *surface*. The point of this document is what is deliberately *absent* from that surface:

- The protocol does not know what an "asset" is. Its generic bound `<Asset: key + store, CoinType>` accepts *any* wrapper an integrator chooses to define. It verifies only UID-identity at borrow and return.
- The protocol does not know what "use the asset" means. Between `borrow_asset` and `return_asset`, the asset is in the tenant's transactional possession — a Move value within the PTB body, not a persisted Sui object at any address; what the tenant does with it is opaque to the protocol.
- The protocol does not know about composition. Between borrow and return, arbitrary code can run — including borrows from other contracts, calls into other DeFi primitives, and other layers of the same protocol pattern.

These three not-knows are not omissions. They are *the abstraction*. Every pattern in this document blooms from the deliberate emptiness of those three slots. The protocol is the substrate; the patterns are what grows on top.

---

### 2. The two functions that create the runtime — `borrow_asset()` and `return_asset()`

The substrate property is not an emergent claim. It is created, concretely, by **two functions** in the protocol's public API:

```move
public fun borrow_asset<Asset: key + store, CoinType>(
    escrow:     &mut Escrow<Asset, CoinType>,
    tenant_cap: &TenantCap,
    random:     &Random,
    clock:      &Clock,
    ctx:        &mut TxContext,
): (Asset, AssetReceipt<Asset, CoinType>);

public fun return_asset<Asset: key + store, CoinType>(
    escrow:     &mut Escrow<Asset, CoinType>,
    asset:      Asset,
    receipt_in: AssetReceipt<Asset, CoinType>,
);
```

`borrow_asset()` **extracts** the asset from escrow. `return_asset()` **refills** it. By construction, the two functions form an *opening/closing pair* — one extracts, the other refills. The proof that a runtime window exists between them is purely structural: if one function extracts and the other refills, then between them there must be a code section in user-space. The protocol hands control back to the caller and waits for it to come back.

That code section is the runtime window.

### What lives in the window

usufruct enforces only two things across it — via the Move type system:

1. The same `Asset` (verified by UID, not by internal state) must reach `return_asset` before the TX ends.
2. The `AssetReceipt<Asset, CoinType>` — a hot-potato with no `drop`, no `store`, no `copy` — must be consumed by `return_asset` in the same TX.

Everything else is *open*. Inside the window, the tenant's PTB body may:

- Call any contract on Sui.
- Pass the borrowed asset to any function that accepts its type.
- Open hot-potatoes from arbitrary integrations layered on top of the asset (see §6).
- Nest into other instances of the protocol — rent another asset, recursively, in the same TX.
- Run any arithmetic, branching, or control flow that Move permits.

The borrowed asset is the **pivot** of the window. Everything in the runtime orbits around it: extractions *from* it, deposits *into* it, transformations that *use* it. When the asset returns to escrow, the window closes and the TX commits.

The remainder of this document maps the design space that lives in that window.

---

### 3. The asset is the interface between usufruct and the protocol that defines its use

usufruct accepts an `Asset: key + store` at `integrate()` and manages its custody. It does not know what the asset does, what functions operate on it, or what "using" it means.

That knowledge lives in the protocol that *issued* the asset. When a protocol issues a `key + store` object to represent a position, a right, or an authority in its own ecosystem, that object carries the protocol's interface: any function in that protocol that accepts `&Asset` or `&mut Asset` works exactly the same whether the caller holds the asset legitimately or obtained it via usufruct for a tenure.

This means: **any protocol that already issues `key + store` objects to govern use in its ecosystem is automatically compatible with usufruct**. No adapter code. No permission from the issuing protocol. The object is the interface; usufruct holds it; the tenant pays for use it.

```move
// Protocol X issues this object to its users.
public struct Position has key, store {
    id: UID,
    // ... fields ...
}

// Protocol X's functions accept &Position to authenticate the caller.
public fun claim_rewards(pos: &Position, ctx: &mut TxContext): Coin<X> { ... }
public fun cast_vote(pos: &Position, proposal: ID, support: bool) { ... }
public fun execute_privileged(pos: &mut Position, params: Params) { ... }
```

The owner integrates the `Position` into usufruct. A tenant rents it. During the borrow window the tenant calls protocol X's functions exactly as any legitimate holder would — protocol X sees no difference.

```move
let (position, asset_receipt) =
    usufruct::borrow_asset(&mut escrow, &tenant_cap, &random, &clock, ctx);
// ── runtime window ─────────────────────────────────────────────────────────
    let rewards = protocol_x::claim_rewards(&position, ctx);
    protocol_x::cast_vote(&position, proposal_id, true);
// ── end of runtime ──────────────────────────────────────────────────────────
usufruct::return_asset(&mut escrow, position, asset_receipt);
```

**The wrapper only appears when the underlying material is not yet a `key + store` object.** A `Balance<C>` has no `key`; to integrate it into usufruct, the integrator defines a thin carrier:

```move
public struct Vault<phantom C> has key, store {
    id: UID,
    balance: Balance<C>,
}
```

The wrapper gives `Balance<C>` an identity (a UID) that usufruct can track, and a surface (functions like `take`/`put`) that defines what "using" the balance means. That surface is the integrator's design problem, not usufruct's.

Two cases, one principle: *the asset is the interface*. When the interface already exists, the integration is free. When it does not, the integrator writes it.

---

### 4. The taxonomy of "use"

Four structural categories describe what the tenant does during the borrow window. In most cases, the issuing protocol already defined this pattern through the functions it exposes on its `key + store` object — the tenant calls them directly, no wrapper needed.

#### A) Extract-return loops, intra-TX

The tenant extracts material from the asset, uses it, and returns it — all within a single TX. **This is the case where a wrapper is typically needed**: when the underlying material (e.g., `Balance<C>`) has no `key` and cannot be integrated into usufruct directly. The wrapper creates the identity and the extract-return interface.

```move
// Balance<C> has no `key` — it cannot be integrated directly.
// The wrapper gives it a UID and an extract-return interface.
public struct Vault<phantom C> has key, store { id: UID, balance: Balance<C> }
public struct VaultBorrow { vault_id: ID, amount_owed: u64 } // no abilities → hot-potato

public fun take(v: &mut Vault<C>, amount: u64, ctx: &mut TxContext): (Coin<C>, VaultBorrow)
public fun put(v: &mut Vault<C>, repayment: Coin<C>, receipt: VaultBorrow)
```

```move
let (vault, asset_receipt) =
    usufruct::borrow_asset(&mut escrow, &tenant_cap, &random, &clock, ctx);
// ── runtime window ─────────────────────────────────────────────────────────
    let (coin, borrow_receipt) = vault::take(&mut vault, 1_000_000, ctx);
    let coin = some_dex::swap(coin, ...);   // arbitrage, MEV, anything
    vault::put(&mut vault, coin, borrow_receipt);
// ── end of runtime ──────────────────────────────────────────────────────────
usufruct::return_asset(&mut escrow, vault, asset_receipt);
```

The vault comes back with the same balance or more. Everything between the two usufruct calls is the runtime.

Other examples:
- Lending backstop vault — wraps a `Balance<USDC>` insurance reserve; tenant flash-borrows it to execute liquidations and returns it whole.
- Paired AMM reserve vault — wraps two correlated `Balance` types (`Balance<A>` + `Balance<B>`); tenant flash-borrows both for atomic cross-pool arbitrage.
- Quota vault — wraps a numeric spending limit or rate-limit counter; tenant consumes the allowance across operations in the TX and must return the remainder.

#### B) Held with passive accrual

Something accrues into the asset on its own while held. The tenant decides when to collect. No wrapper needed — the issuing protocol already emitted the position as a `key + store` object with its own collection functions.

```move
// some_dex already issued Position<A, B> has key, store.
// The owner integrates it into usufruct directly — no wrapper needed.

let (position, asset_receipt) =
    usufruct::borrow_asset(&mut escrow, &tenant_cap, &random, &clock, ctx);
// ── runtime window ─────────────────────────────────────────────────────────
    some_dex::collect_fees(&mut position, ctx); // fees come out
// ── end of runtime ──────────────────────────────────────────────────────────
usufruct::return_asset(&mut escrow, position, asset_receipt);
```

The DEX does not know or care that usufruct is holding the position. The position returns to escrow and keeps accumulating until the tenant opens the next runtime window.

- LP position — trading fees stream while held.
- Staking position — staking rewards accrue.
- Bonding curve seat — fees from buys and sells.
- Vesting position — time accrues toward unlock; tenant uses pre-unlock rights.
- RWA yield-bearing object — interest or coupon accrues.

Variants: *yield-to-tenant* (the rent price prices in the expected yield) vs *yield-to-owner* (fees stay in the position for the owner to collect on reclaim).

#### C) Held with active rights — actions persist post-return

The tenant invokes rights that have permanent on-chain effects. No wrapper needed — the issuing protocol already exposed the functions the tenant needs on its `key + store` object.

```move
// some_gov already issued VotingPower has key, store.
// No wrapper needed.

let (voting_power, asset_receipt) =
    usufruct::borrow_asset(&mut escrow, &tenant_cap, &random, &clock, ctx);
// ── runtime window ─────────────────────────────────────────────────────────
    some_gov::cast_vote(&voting_power, proposal_id, /* support */ true, ctx);
    some_gov::claim_distribution(&mut voting_power, ctx);
// ── end of runtime ──────────────────────────────────────────────────────────
usufruct::return_asset(&mut escrow, voting_power, asset_receipt);
```

The asset returns intact. The *effect* — the vote recorded in `some_gov`'s state — persists indefinitely regardless.

- veToken / governance vote rental — votes cast during the tenure remain counted.
- AccountCap / AdminCap — authority over a contract (treasurer, moderator, oracle-updater).
- Multisig seat — temporary delegation of a signer's voting power.
- Identity attestation object (non-soulbound) — KYC-checked identity used for a single operation.

#### D) Single-shot consumption

The asset is spent by use. The issuing protocol defines the consumption logic; the tenant calls the redemption function; usufruct verifies only the UID on return, not the internal state.

```move
// some_mint already issued MintTicket has key, store.
// MintTicket carries its own one-time-use logic internally. No wrapper needed.

let (ticket, asset_receipt) =
    usufruct::borrow_asset(&mut escrow, &tenant_cap, &random, &clock, ctx);
// ── runtime window ─────────────────────────────────────────────────────────
    let nft = some_mint::redeem(&mut ticket, ctx); // ticket is now spent
// ── end of runtime ──────────────────────────────────────────────────────────
usufruct::return_asset(&mut escrow, ticket, asset_receipt);
// usufruct verifies only the UID on return — not the internal state.
```

The owner reclaims a spent ticket — that is the intended design. If the tenant returns without redeeming, the ticket comes back unused and the next tenant can try.

- Allowlist / IDO slot — one mint per slot, slot is then dead.
- Lottery ticket / mystery box — opened once.
- Event ticket — admit once.
- Voucher / discount code — one redemption.

The four categories are not features of the *protocol*. They describe what the issuing protocol's interface allows the tenant to do. usufruct sees all four identically — a `key + store` object that enters escrow and returns with the same UID.

---

### 5. The direct case — when the asset IS the access

When the underlying material already exists as a `key + store` object — a capability issued by another protocol to govern access in its own ecosystem — no wrapper is needed. The object is the interface; usufruct holds it; the tenant uses it.

Many protocols on Sui mint `key + store` capability objects:

- A **vote-escrow cap** (veToken-style) grants voting weight and gauge-boost in the issuing protocol.
- A **market-maker cap** grants fee discounts or priority routing on a DEX.
- A **subscription cap** grants access to gated functions, paid APIs, or premium tiers.
- A **validator / operator cap** grants staking or operational privileges.
- A **DAO membership cap** grants voting and claim rights in a governance system.
- A **whitelist or KYC cap** grants verified-user access to constrained mints, sales, or operations.
- An **oracle access cap** grants the right to read premium price feeds — pay per read, rate-limited inside the tenure window.
- An **AI inference cap** grants the right to query a model object — pay per query, the model remains untouched.
- A **priority route cap** grants preferential routing or fee discounts on a specific AMM pool during the tenure.

Each is already `key + store`. The owner integrates it into an escrow as-is.

#### The flow

```move
let (cap, asset_receipt) =
    usufruct::borrow_asset(&mut escrow, &tenant_cap, &random, &clock, ctx);
// ── runtime window ─────────────────────────────────────────────────────────
    issuer::cast_vote(&cap, proposal_id, /* support */ true);
    issuer::claim_rewards(&mut cap, ctx);
    issuer::priority_swap(&cap, &mut pool, amount_in, ctx);
// ── end of runtime ──────────────────────────────────────────────────────────
usufruct::return_asset(&mut escrow, cap, asset_receipt);
```

No `take` / `put`. No integrator module. No second hot-potato beyond usufruct's own `AssetReceipt`.

#### Why the wrapper collapses

The wrapper collapses to identity because **the issuing protocol's own API already enforces every invariant that matters**. The cap's state either does not change with use, or whatever change matters lives in the issuer's storage, not in the cap object. The cap returns to escrow byte-identical to how it left.

The structural consequence is that **every cap-issuing protocol on Sui is integrable with usufruct for free**, with no code on the integrator's side:

1. Hold the cap.
2. Call `usufruct::integrate(cap, ...)` with tenure price and policy.

That is the entire integration. The cap-issuing protocol does not need to know that its caps are being rented. It does not need to ship special code. It does not have to opt in.

#### Where this fits in the taxonomy

This is a degenerate case of **category C** (§4) — held with active rights. What's different is that the *integration cost is zero*.

When the cap also accrues something passively while held (vote rewards, fee shares, time-weighted boosts), the pattern blends into **category B**. At that point, the integrator may want a wrapper to split the accrual between owner and tenant — which puts them back in the §6 wrapper pattern.

#### What this says about the protocol

> usufruct turns any `key + store` capability into a rentable, time-bounded right of access — without requiring the cap-issuer's cooperation.

This is usufruct's place in the ecosystem: a **meta-market over Sui's capability surface**, available to every protocol whether or not they participate.

---

### 6. Composition is monoidal — layers stack

For integration layers to compose, each must express its own hot-potato discipline — a receipt struct with no abilities that the Move drop-checker forces to consume before the TX ends.

Here is the canonical shape for a category A layer (a wrapper that extracts material and requires its return within the same TX):

```move
module integrator::balance_vault;

public struct Vault<phantom C> has key, store {
    id: UID,
    balance: Balance<C>,
}

// Receipt: zero abilities. The Move drop-checker forces consumption by put()
// in the same TX. No drop, no store, no copy, no key.
public struct VaultBorrow {
    vault_id: ID,
    amount_owed: u64,
}

public fun take(
    vault: &mut Vault<C>,
    amount: u64,
    ctx: &mut TxContext,
): (Coin<C>, VaultBorrow) {
    let funds = vault.balance.split(amount);
    let receipt = VaultBorrow {
        vault_id: object::id(vault),
        amount_owed: amount,
    };
    (coin::from_balance(funds, ctx), receipt)
}

public fun put(vault: &mut Vault<C>, repayment: Coin<C>, receipt: VaultBorrow) {
    let VaultBorrow { vault_id, amount_owed } = receipt;
    assert!(object::id(vault) == vault_id, EWrongVault);
    assert!(repayment.value() >= amount_owed, EInsufficientReturn);
    vault.balance.join(repayment.into_balance());
}
```

Four properties of the receipt, each enforced by the Move VM:

| Ability stripped     | What it prevents                                              |
|----------------------|---------------------------------------------------------------|
| no `drop`            | receipt cannot vanish silently                                |
| no `store`           | receipt cannot persist past TX boundary                       |
| no `copy`            | receipt cannot be duplicated to "settle twice" from one take  |
| `vault_id` embedded  | receipt cannot be settled against a different vault           |

There is no runtime check. The entire discipline is enforced at bytecode-verifier time. **Zero runtime cost; total structural correctness.**

Once each layer has a receipt, the protocol's own `AssetReceipt` and the integration's `VaultBorrow` compose by nesting:

```
usufruct::borrow_asset
  ├─ AssetReceipt             (layer 0)
  │
  ├─ flash_loan::take                          ← layer 1
  │    ├─ VaultBorrow         (layer 1)
  │    │
  │    ├─ ... arbitrary user PTB body ...
  │    │      DEX swaps, lending repays, MEV bundles,
  │    │      or another_integration::take      ← layer 2
  │    │        ├─ AnotherReceipt (layer 2)
  │    │        └─ ...
  │    │
  │    └─ flash_loan::put                      ← closes layer 1
  │
  └─ usufruct::return_asset                    ← closes layer 0
```

#### Why composition is safe by construction

- **Stack discipline (LIFO) is structural, not conventional.** You cannot return the wrapper to escrow without first returning the funds to the wrapper. `usufruct::return_asset` consumes the wrapper by *move*; `vault::put` needs it by `&mut`. The compiler rejects any non-nested ordering.
- **Atomic rollback.** If any `assert!` at any level fails, the entire TX reverts — including all side effects on other protocols (DEXes, lending markets, perps) called inside the stack.
- **Isolation.** Each receipt is private to its emitting module. Outer layers cannot inspect inner state; inner layers cannot escape upward. Move's linear typing keeps every layer's invariants local.

#### Every hot potato is a runtime router

`VaultBorrow` is a canonical instance of a more general pattern. A hot potato — any struct with no abilities — is structurally a **router**: the Move drop-checker forces execution to reach the function that consumes it before the TX ends. The space between the emitting call and the consuming call is a runtime window, indistinguishable in kind from the outer window that `borrow_asset` / `return_asset` creates.

`vault::take` opens a window. `vault::put` closes it. Between them, arbitrary code runs. This is precisely the structure of the protocol's outer pair — only at a different level.

This is not a property usufruct designs into the integration. It is a property of the **asset's own API**: any function on the asset that emits a hot potato creates a nested runtime window within the outer borrow / return bracket. The protocol provides the outer container; the asset determines how many sub-windows are available inside it.

The practical consequence: `borrow_asset` does not give the tenant a single runtime slot. It gives them access to a **FIFO of runtimes** — as many sequential windows as the asset's API can generate. Each `take` / `put` cycle is one entry in that FIFO: independent, atomic, and fully closed before the next opens. The length of the queue is bounded only by PTB gas limits.

```
borrow_asset()
  │
  ├─ take() ──────────────────┐
  │                            │  VaultBorrow  (hot potato → router → put())
  │   [ runtime window #1 ]   │
  │   arbitrary PTB code      │
  ├─ put()  ◄──────────────────┘
  │
  ├─ take() ──────────────────┐
  │                            │  VaultBorrow  (hot potato → router → put())
  │   [ runtime window #2 ]   │
  │   arbitrary PTB code      │
  ├─ put()  ◄──────────────────┘
  │
  ├─ take() ──────────────────┐
  │                            │  VaultBorrow  (hot potato → router → put())
  │   [ runtime window #n ]   │
  │   arbitrary PTB code      │
  ├─ put()  ◄──────────────────┘
  │
return_asset()
```

`Vault` is the canonical instance. The pattern is not. Any asset whose API emits a hot potato participates in this structure — the depth of its FIFO is determined entirely by how many such emissions its API allows within a single borrow window.

#### Why composition is economically natural

Each layer charges its own fee, independently:

| Layer                 | Charges for             | Cadence       |
|-----------------------|-------------------------|---------------|
| 0 — usufruct          | tenure (time window)    | per rent      |
| 1 — vault             | per loop (use of value) | per take/put  |
| 2 — leveraged vault   | per leverage step       | per take      |
| ...                   | ...                     | ...           |

The tenant pays a *stack of fees* that settles atomically. No integrator coordinates with another. The protocol does not aggregate or route fees — each layer collects its own. The composition is associative; the fee structure is the natural monoid.

#### Composition turns integrations into a DAG, not a list

Integrations may stack on the protocol or on each other. A `leveraged_balance_vault` is a layer on a `balance_vault` is a layer on usufruct. The catalog of integrations is a directed acyclic graph of capabilities, and liquidity routes itself through the stacks that offer the best fee/utility combinations. Integrators are not isolated competitors. They are composable layers in an open catalog.

---

### 7. Worked example — flash loans with horizon

The construction that justifies calling the protocol a *substrate* is also the simplest concrete instance of the composition principle. **Flash loans with horizon** — a primitive that did not exist anywhere before usufruct — emerge by composing a small integration module on top of the protocol, without modifying the protocol itself.

#### 7.1 The actors and their interfaces

- **Protocol team** ships `usufruct`. Untouched.
- **Integrator** ships a `flash_loan` module — concretely, the `balance_vault` of §6 deployed to mainnet. Imports the `usufruct` package as a Move dependency.
- **Asset owner** wraps N units of USDC in a `Vault<USDC>` and integrates it into a usufruct `Escrow`, setting tenure price and lifecycle policy.
- **Tenant** rents the vault from usufruct, paying the tenure fee. Now holds the *option* to flash-loan the vault for the next T seconds, across as many TXs as desired.

No actor needs to know any other's internals. The interfaces:

- usufruct ↔ integrator: the `<Asset: key + store>` bound.
- integrator ↔ tenant: the `take` / `put` API and the `VaultBorrow` receipt.
- owner ↔ tenant: indirect, mediated by usufruct's lifecycle FSM.

#### 7.2 A single TX inside the tenure window

```move
let (vault, asset_receipt) =
    usufruct::borrow_asset(&mut escrow, &tenant_cap, &random, &clock, ctx);
// ── runtime window ─────────────────────────────────────────────────────────
    let (coin, vault_borrow) = flash_loan::take(&mut vault, 1_000_000, ctx);

    let coin = deepbook::swap(coin, ...);   // USDC → SUI on pool A
    let coin = cetus::swap(coin, ...);      // SUI → USDC on pool B

    flash_loan::put(&mut vault, coin, vault_borrow);
// ── end of runtime ──────────────────────────────────────────────────────────
usufruct::return_asset(&mut escrow, vault, asset_receipt);
```

What the bytecode verifier checks at TX end, all at once:

- `asset_receipt` consumed by `usufruct::return_asset`. ✓
- `vault_borrow` consumed by `flash_loan::put`. ✓
- Vault returned has the same UID as the one borrowed. ✓
- Funds returned to the vault are ≥ `amount_owed`. ✓
- All side effects on DeepBook and Cetus commit *only* if every check above passes.

If any check fails, the entire TX reverts. The owner's vault is untouched; the tenant's tenure is preserved; no partial state is possible.

#### 7.3 The horizon

In the next TX, the tenant repeats — new atomic stack, new opportunity, fresh PTB body. They may do this until the tenure expires. Each TX is independent and atomic; together, they constitute a **multi-TX flash-loan facility** over a window of time.

The protocol enforces the *window*. The integrator's module enforces *conservation per TX*. The composition delivers the new primitive, with neither layer knowing the other exists.

#### 7.4 Nesting deeper — integrations on integrations

A second integrator may write a `leveraged_loan` module that uses `flash_loan::take` internally:

```move
let (vault, asset_receipt) =
    usufruct::borrow_asset(&mut escrow, &tenant_cap, &random, &clock, ctx);
// ── runtime window ─────────────────────────────────────────────────────────
    let (coin, vault_borrow) = flash_loan::take(&mut vault, 1_000_000, ctx);

    let (lev_coin, lev_receipt) =
        leveraged_loan::take(&mut pool, coin, /* 5x */ 5, ctx);

    // ... arbitrage with `lev_coin` ...

    let coin = leveraged_loan::put(&mut pool, lev_coin, lev_receipt);
    flash_loan::put(&mut vault, coin, vault_borrow);
// ── end of runtime ──────────────────────────────────────────────────────────
usufruct::return_asset(&mut escrow, vault, asset_receipt);
```

Three receipts. Three conservation predicates. Three independent fee streams (tenure, flash-loan loop, leverage step). All settled at the same TX boundary, by the same drop-checker. None of the three layers knows about the other two.

This is the **substrate property**: an open catalog of layers, each composable with everything that comes before and after it, settled atomically by Move's type system.

---

### 8. The FSM and policies that orbit `borrow_asset` and `return_asset`

Calling usufruct "a multi-TX option on atomic hot-potato stacks" undersells what the protocol provides. That framing captures only one *consequence* — that the runtime window of §2 reopens across many TXs. The *mechanism* is richer.

usufruct is two things working in concert.

#### A. A finite-state machine over the asset's lifecycle

The escrow holds the asset across a sequence of states. At every moment, the asset is either *Waiting* (custody locked in escrow) or *Renting* (custody surrendered to a tenant for a borrow window):

- `Waiting::Idle` — no tenant, no auction.
- `Waiting::AtDutch` — a Dutch auction is open to find the next tenant.
- `Waiting::Retired` — the owner has terminated the rental; only `claim_asset` remains.
- `Renting::Occupied` — a tenant holds the right; `borrow_asset` is callable.
- `Renting::Demand` — a challenger has placed a bid against the current tenant.

Transitions between states are driven by events (time elapsed, bids placed, tenures expired) and gated by the policies below. The FSM determines **which operations the protocol exposes at each moment**. In particular, `borrow_asset` and `return_asset` are callable only from `Renting::Occupied` or `Renting::Demand` — every other state aborts the borrow path.

#### B. A policy ensemble that orbits the conditions of every transition

The protocol does not hardcode *when* a tenant may rent, *at what price*, *for how long*, *under what extension rules*, or *how the asset transfers between tenants*. It externalizes these into a `PolicyEnsemble` — eight policies the owner configures at integration time:

| Policy             | Conditions...                                                            |
|--------------------|--------------------------------------------------------------------------|
| `rest_price`       | minimum rent price; fixed or randomly drawn per idle cycle               |
| `tenure_duration`  | how long the tenant's right persists after winning                       |
| `tenure_extend`    | whether and how the tenant may extend; multi-tenure commitments          |
| `handover`         | how the asset transfers from old tenant to new (instant, fixed, countdown) |
| `auction_window`   | duration of the Dutch auction itself                                     |
| `auction_shape`    | how the price descends across the Dutch auction window                   |
| `credit_shape`     | how the tenant's stake is consumed into owner earnings over the tenure   |
| `price_escalation` | how the price escalates after a bid                                      |

Each policy is *external configuration* the owner chooses. The same FSM operates uniformly regardless of which variants are picked. The policies do not change what the protocol *does* — they change **the conditions under which each transition is permitted, and the terms it carries**.

#### The picture

```
                ┌──────────────────────────────────────┐
                │  rest_price        tenure_duration   │
                │  auction_window    tenure_extend     │  ← PolicyEnsemble
                │  auction_shape     handover          │     (orbits the FSM)
                │  credit_shape      price_escalation  │
                └─────────────────┬────────────────────┘
                                  │ conditions
                                  ▼
                       ┌──────────────────────┐
                       │      AssetState      │
                       │  Waiting │ Renting   │  ← FSM
                       │  Idle    │ Occupied  │
                       │  AtDutch │ Demand    │
                       │  Retired │           │
                       └──────────┬───────────┘
                                  │ gates
                                  ▼
                  borrow_asset   ⇄   return_asset       ← runtime pivots (§2)
```

#### Why this matters for integrators

When an integrator builds a market on usufruct, they pick **two orthogonal things**:

1. **The wrapper** — what asset (§3) and what use-semantics (§4–§6). Determines *what* is being rented.
2. **The policy ensemble** — the configuration of the eight policies above. Determines *the terms* under which it is rented.

The same wrapper under different ensembles produces different markets. A `balance_vault` with a low floor, slow Dutch curve, long tenure, and free extension is a different financial instrument than the same vault with a high floor, fast curve, short tenure, and locked commitment. Same code; different contract.

#### The temporal axis as one consequence among many

What was framed earlier as the *temporal axis* — multi-TX option on atomic stacks — is one consequence of this machinery, not the whole of it. The tenure is created by `tenure_duration`; the auction by `auction_window` and `auction_shape`; the price floor by `rest_price`; the multi-tenant rotation by `handover`. Together they yield a tenant-held option at owner-chosen terms.

| Capability                           | Atomic stack? | Multi-TX horizon? | Owner-configurable terms? |
|--------------------------------------|---------------|-------------------|---------------------------|
| Move type system (per-TX hot-potato) | yes           | no                | no                        |
| Aave-style flash loan                | yes           | no                | no                        |
| **usufruct + integrations**          | yes           | **yes**           | **yes**                   |

Hot-potato discipline existed before usufruct. Tenure-bounded rights at owner-configured terms did not.

#### Configuration archetypes

The same FSM produces radically different financial instruments depending on how the `PolicyEnsemble` is configured. Three canonical archetypes emerge. This is a direct consequence of the engine's polymorphic property: the state machine is fully decoupled from the ensemble. The engine does not branch on policy variants — it calls a uniform interface and receives resolved values (price, duration, shape). The ensemble is external configuration; the engine is invariant. The same transitions, the same credit logic, the same settlement arithmetic execute regardless of which variant is active.

**Machine-oriented — pay-per-API.** Tenure ceiling in milliseconds to seconds, `handover = Instant`, `auction_window = Skipped`. No queuing, no handover protection. A new bidder displaces the current tenant immediately; price resets to floor on each idle cycle. Designed for machine clients accessing a rate-limited resource at high frequency — the "tenant" is a bot, not a person.

**User-oriented — protected renting.** Tenure ceiling in minutes to days, `handover = Countdown`, meaningful `auction_window`. A bidder must wait out the handover countdown before displacing the current tenant. The tenant has a guaranteed window to use the rental before being displaced. Designed for human users renting time-bounded access to something they interact with over a session.

**Full-tenure reservation.** `handover = FullTenure`, which ties the handover expiry to the tenure ceiling, making displacement impossible before the tenure ends. The tenant's occupancy is fully guaranteed for its stated duration. Designed for time-slot reservations — conference rooms, event slots, scheduled access windows — where partial occupancy has no value.

Same protocol code. Entirely different economic products.

#### No external coordinators — lazy evaluation

State transitions — tenure expiry, handover countdown firing, auction window closing — are not executed by an external keeper. They are evaluated lazily: the FSM checks whether any pending transition is fireable at the start of every operation and fires it before proceeding. The next transaction to touch the escrow performs any overdue transitions as a side effect.

The consequence for integrators: no off-chain bot to run, no keeper to fund, no cron job to maintain. A transition that becomes fireable at time T will execute the next time anyone interacts with the escrow, whether that is T+1ms or T+1 hour. The escrow is always correct relative to the clock at the time of the transaction, and its economic guarantees are not dependent on the liveness of any external party.

#### The incumbent advantage

The current tenant holds a structural advantage at renewal time. A new challenger entering from outside must pay the full escalated floor price for a fresh tenure. The current tenant bidding to extend from `Occupied` pays the same escalated floor — but their already-consumed credit is sunk into the owner's balance. The challenger's cost is the full floor; the incumbent's effective cost is the floor minus what they have already paid for. The further into a tenure the current tenant is, the greater this asymmetry.

The result is a natural continuity incentive built into the economics: the protocol structurally favors the existing occupant at renewal time without any explicit loyalty mechanism. Integrators targeting stable long-term tenants over churn can amplify this effect through a front-loaded `credit_shape`, which consumes most of the stake early and leaves the incumbent with maximum sunk credit relative to a new entrant.

#### Self-renewal as an emergent property of identity-agnosticism

The protocol evaluates bids against a price, never against an address. `do_place_bid` does not check whether the bidder is the current tenant — it processes the payment and installs the bidder as the pending tenant in `Demand` state. This means the current tenant can call `rent()` on their own escrow while still occupying it.

If no one outbids them before the handover countdown fires, the handover executes normally: the current tenant is "displaced", receives their own `remain_credit`, and the pending tenant — also themselves — becomes the new current occupant with a fresh tenure. Their net cost is `escalated_floor − remain_credit` — always strictly less than what any external competitor must pay for the same position.

Three market properties emerge from this single design choice, without the protocol encoding any of them:

- **Self-renewal.** The current tenant can extend their position by bidding against themselves.
- **Right of first refusal.** If a challenger bids, the current tenant can supersede them before the handover fires, reclaiming the pending slot at the same or higher price.
- **Structural cost advantage.** The incumbent's renewal cost is always lower than a new entrant's entry cost, by exactly the amount of credit already sunk.

These are not features. They are consequences of the FSM being identity-agnostic — a protocol that sees prices, not participants.

---

### 9. Forward-looking catalog

The patterns below are not all implemented. They are the design space the abstraction opens. Category A entries require a wrapper — the underlying material has no `key`. Categories B–D are typically direct protocol objects: no wrapper needed.

| Cat | Pattern                 | What the tenant gets during the window        | Tenant pays for              |
|-----|-------------------------|-----------------------------------------------|------------------------------|
| A   | `balance_vault<C>`      | flash-loanable coin reserve                   | flash-loan window            |
| A   | `lending_backstop`      | flash reserve for liquidations                | liquidation window           |
| A   | `paired_reserve<A,B>`   | two correlated balances for atomic arb        | cross-pool arb window        |
| B   | `lp_position`           | LP fees stream while held                     | use rights + yield split     |
| B   | `staking_position`      | staking rewards accrue while held             | staking yield during T       |
| B   | `vesting_position`      | time accrues toward unlock                    | pre-unlock rights for T      |
| B   | `rwa_bond`              | interest or coupon accrues                    | yield arrangement for T      |
| C   | `ve_token`              | voting weight and gauge-boost                 | vote rights for T            |
| C   | `multisig_seat`         | signing authority in a multisig               | signing authority for T      |
| C   | `role_cap`              | admin / treasurer / oracle privileges         | privileged actions for T     |
| C   | `oracle_access_cap`     | rate-limited reads of a premium price feed    | premium reads for T          |
| C   | `inference_cap`         | rate-limited queries to a model object        | AI inference budget for T    |
| C   | `priority_route_cap`    | priority routing or fee discount on an AMM    | priority access for T        |
| D   | `allowlist_slot`        | one-time mint right                           | the slot, atomically         |
| D   | `event_ticket`          | one-time admission                            | the entry, atomically        |
| D   | `voucher`               | one-time redemption right                     | the redemption, atomically   |
| meta| `composite_portfolio`   | basket of N objects, rented as a unit         | the basket as a single asset |
| meta| `leveraged_*`           | meta-layer over another integration           | leverage on any pattern      |

The last two rows demonstrate the DAG structure: `composite_portfolio` and `leveraged_*` are meta-integrations that stack on other integrations and are themselves rentable. The catalog composes onto itself.

#### The native token demand circuit

When the owner denominates rental prices in an integrator-issued token (`CoinType = MyToken`), the rental market becomes an organic demand driver for that token. Every tenant must acquire `MyToken` to pay rent. Competitive pressure for a desirable asset drives up the price paid per tenure, which increases operational demand for `MyToken` in circulation.

This feedback loop is grounded in utility: demand is functional, not speculative — tenants need the token to access the asset. The stronger the underlying asset's utility, the stronger and more stable the demand signal. For integrators with an existing token economy, choosing their own token as `CoinType` converts the rental market into a demand mechanism that requires no separate incentive design — it is a direct consequence of the asset being worth competing for.

---

## The TenantCap

The previous sections describe the design space that opens at the asset level. There is a second surface the protocol exposes without having designed for it explicitly: **the `TenantCap` itself as a transferable object**. Everything above assumed the address that paid `rent()` is the one that exercises the borrow right. That assumption is not enforced by the protocol.

---

### 10. The rental right is itself transferable

`TenantCap` has `key + store` abilities:

```move
public struct TenantCap has key, store {
    id:              UID,
    escrow_identity: EscrowIdentity,
    refund_address:  RefundAddress,
    cap_identity:    TenantCapIdentity,
}
```

`key` makes it an owned Sui object with a stable on-chain address. `store` makes `transfer::public_transfer` callable on it. A tenant can transfer their `TenantCap` to any address with no protocol interaction — the protocol has no hook on transfers. Whoever holds the cap can call `borrow_asset`. The protocol validates only that the cap is the **current** cap for the escrow, not the identity of the holder.

This makes subleasing a structural emergent property. A tenant who holds a current cap with significant tenure remaining — in particular, a long handover window that guarantees their occupancy will not end immediately — can transfer the cap to a sublessee. The sublessee acquires the borrow right directly; no on-protocol step is needed. Anyone can verify on-chain that a cap is current before acquiring it by reading the escrow's `current_tenant_cap_id`.

#### The asymmetry to understand before subleasing

The `RefundAddress` embedded in the cap is set at `rent()` time and never changes. It is the address that receives any remaining stake if the current tenant is displaced by a handover before their tenure expires. When the cap is transferred, the **borrow right** moves to the new holder but the **refund destination** does not — it remains pointed at the original payer.

If the sublessee is displaced while holding the cap, the partial refund goes to the original tenant, not to the sublessee. The sublessee bears the execution-window risk; the original tenant retains the financial exposure to displacement. This is not a flaw — it is the protocol correctly anchoring financial obligations to the address that made them.

#### What the protocol does and does not control

The protocol cannot prevent subleasing and does not try to. It exposes the information needed for any participant to reason about cap validity on-chain:

- `escrow::current_tenant_cap_id()` — whether a given cap is still current.
- `escrow::tenure_expiry_ms()` — how much tenure remains.
- `escrow::handover_countdown_expiry_ms()` — when a pending bid's handover can fire.

What market structures emerge from this — sublease agreements, secondary cap auctions, time-sliced access markets — is outside the protocol's scope. The protocol makes it structurally possible and auditably transparent. The rest is up to the market.

---

## The OwnerCap

`OwnerCap` also has `key + store` abilities. Whoever holds it holds **full authority** over the escrow: retire, withdraw earnings, claim the asset, update the policy configuration, and extend the commitment. The protocol validates only that the cap matches the escrow's registered `owner_cap_id` — not the holder's address. Transfer of the `OwnerCap` is transfer of ownership, with no caveats.

---

### 11. Protocol-owned escrows and governance

Because `OwnerCap` is an ordinary owned Sui object, it can be held by any address — including a smart contract module, a DAO treasury, or a multisig. This makes the escrow's lifecycle fully programmable without any modification to the protocol.

**DAO-governed escrow.** Integrate an asset, then transfer the `OwnerCap` to a DAO governance object or shared treasury. From that point, owner operations (retire, update config, withdraw earnings) are gated by the DAO's own proposal and voting mechanism. The protocol does not know or care — it validates the cap, not the caller.

**Protocol-owned escrow.** A smart contract module can hold the `OwnerCap` and govern the escrow programmatically: auto-retire after a fixed number of tenures, route withdrawn earnings to a yield-sharing pool, update policy configuration in response to on-chain signals. The escrow becomes a component in a larger protocol rather than an independently owned object.

**Multisig ownership.** Transfer the `OwnerCap` to a multisig cap from another protocol. Owner operations then require the configured threshold of signers. Useful for shared assets or treasury-managed integrations where no single address should have unilateral control.

**Delegated management.** Transfer the `OwnerCap` temporarily to a manager address — a keeper bot, an operations wallet, or a third-party service — while retaining the intent to reclaim it later. Since `OwnerCap` is transferable, this is a first-class pattern with no protocol friction.

#### The difference from TenantCap

With `TenantCap`, only the borrow right transfers — financial exposure to displacement (the `RefundAddress`) stays anchored to the original payer. With `OwnerCap`, there is no such split: economic rights and operational authority are unified. Whoever holds the cap can withdraw accumulated earnings, claim the underlying asset, and modify the escrow's terms. Transfer of `OwnerCap` is full transfer of ownership with no residual exposure retained by the prior holder.

---

### 12. The OwnerCap as a rentable asset — level-2 rental

`OwnerCap` has `key + store`, which means it can itself be integrated into a usufruct escrow. The result is a two-level rental market: the level-1 escrow holds the underlying asset; a level-2 escrow holds the `OwnerCap` of the level-1 escrow. Whoever rents the `OwnerCap` from the level-2 escrow temporarily holds full owner authority over the level-1 escrow.

During their level-2 tenure, the meta-tenant can call any owner-gated operation on level-1: `update_config` to change rental policy, `retire` to initiate asset reclaim, `withdraw_earnings` to extract accumulated owner balance, or `extend_commitment`. The level-1 escrow is governed by whoever holds the `OwnerCap` at the time, not by the original integrator.

This creates **market-mediated transfer of escrow control** without explicit sale semantics. Set a level-2 tenure long enough to cover a full level-1 retirement cycle, and the highest bidder at level-2 wins temporary ownership of the underlying asset's lifecycle — including the right to reclaim it. The asset goes to whoever holds the `OwnerCap` when `claim_asset` is called, which may be different from whoever called `retire`, depending on when each level-2 tenure ends.

At the extreme, a level-2 escrow with `FullTenure` handover and a tenure sized to match a level-1 retirement horizon becomes an ownership auction: one bidder wins per cycle, exercises full owner rights, and the level-1 asset exits to them.

---

## 13. The integrator's mental model

If you are building on usufruct, the question to ask is not "is my asset rentable?" but the following four:

1. **What is the `key + store` object?** Either an existing object your protocol already issues, or a thin carrier you write to give non-`key` material an identity.
2. **What does "use" mean?** Which of the four categories (A/B/C/D) fits. For most protocols the answer is already expressed by the functions they expose on the object — no extra code needed.
3. **Is a hot-potato needed?** Only if the tenant extracts material from the object (category A). If the tenant calls existing protocol functions that return data or record effects (B/C/D), there is nothing to enforce beyond usufruct's own `AssetReceipt`.
4. **What does this layer compose with?** Whether it stands alone, sits atop another integration, or is designed to be stacked under future ones.

If those four questions have answers, you have an integration. The protocol takes care of the rest — lifecycle, time, fees, auctions, retirement — uniformly.

---

## 14. References

- The usufruct protocol — the substrate this catalog grows on. *(Separate repository.)*
- usufruct's `ARCHITECTURE.md` — protocol internals. Read after this document, not before.
