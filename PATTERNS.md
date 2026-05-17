# usufruct — Patterns

A field guide for integrators building on top of the **usufruct** protocol.

This document is not a tutorial. It is the *generative principle* behind every pattern that can be built on the protocol, and a forward-looking catalog of where that principle leads.

> The patterns below exist to **inspire**, not to enumerate. They make the design space visible — they do not bound it. **In practice, any logic that orbits a Sui `key + store` object will find a use case in usufruct.** The taxonomy, examples, and worked constructions are scaffolding; the design space itself is whatever an integrator can imagine.

---

## 1. The substrate, not the product

The usufruct protocol is a finite-state machine over time-bounded custody of opaque `key + store` objects, with built-in fee accrual, Dutch auctions, handovers, and tenure extension. That is the protocol's *surface*. The point of this document is what is deliberately *absent* from that surface:

- The protocol does not know what an "asset" is. Its generic bound `<Asset: key + store, CoinType>` accepts *any* wrapper an integrator chooses to define. It verifies only UID-identity at borrow and return.
- The protocol does not know what "use the asset" means. Between `borrow_asset` and `return_asset`, the asset is in the tenant's address; what the tenant does with it is opaque to the protocol.
- The protocol does not know about composition. Between borrow and return, arbitrary code can run — including borrows from other contracts, calls into other DeFi primitives, and other layers of the same protocol pattern.

These three not-knows are not omissions. They are *the abstraction*. Every pattern in this document blooms from the deliberate emptiness of those three slots. The protocol is the substrate; the patterns are what grows on top.

---

## 2. The two functions that create the runtime — `borrow_asset()` and `return_asset()`

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

`borrow_asset()` **extracts** the asset from escrow. `return_asset()` **refills** it. By construction, the two functions form an *opening/closing pair* — one removes state, the other restores it. The proof that a runtime window exists between them is purely structural: if one function extracts and the other refills, then between them there must be a code section in user-space. The protocol hands control back to the caller and waits for it to come back.

That code section is the runtime window.

### What lives in the window

The Move type system enforces only two things across it:

1. The same `Asset` (verified by UID, not by internal state) must reach `return_asset` before the TX ends.
2. The `AssetReceipt<Asset, CoinType>` — a hot-potato with no `drop`, no `store`, no `copy` — must be consumed by `return_asset` in the same TX.

Everything else is *open*. Inside the window, the tenant's PTB body may:

- Call any contract on Sui.
- Pass the borrowed asset to any function that accepts its type.
- Open hot-potatoes from arbitrary integrations layered on top of the asset (see §5).
- Nest into other instances of the protocol — rent another asset, recursively, in the same TX.
- Run any arithmetic, branching, or control flow that Move permits.

The borrowed asset is the **pivot** of the window. Everything in the runtime orbits around it: extractions *from* it, deposits *into* it, transformations that *use* it. When the asset returns to escrow, the window closes and the TX commits.

The remainder of this document maps the design space that lives in that window.

---

## 3. The asset is whatever you wrap as `key + store`

The protocol accepts an `Asset: key + store` at `integrate()`. Anything that satisfies that bound is a valid asset. The structure of the wrapper is the integrator's territory.

For NFTs, the wrapper *is* the NFT — the abstraction collapses to identity. For everything else, the integrator defines a thin wrapper that holds the underlying material:

```move
public struct Vault<phantom C> has key, store {
    id: UID,
    balance: Balance<C>,
}
```

To the protocol, a `Vault<USDC>` is indistinguishable from any NFT. It enters escrow, traverses the lifecycle FSM, is handed to a tenant at borrow, and returns at return — same code, same guarantees, same fee accrual.

What the wrapper *lets the tenant do* — that is where the design space opens.

---

## 4. The taxonomy of "use"

Four structural categories cover every wrapper imaginable. Each one drives a different shape of internal API.

### A) Extract-return loops, intra-TX

The asset does not change between TXs. The tenant runs N atomic operations, each one extract → use → return inside a single TX.

Canonical example: **flash-loanable balance vault** (§5).

Other examples:
- Oracle access cap — pay per read, rate-limited inside the tenure window.
- AI model inference cap — pay per query, model NFT remains untouched.
- Privileged AMM route — priority access to a liquidity pool during the tenure.

### B) Held with passive accrual

The tenant holds the wrapper; something accrues on its own while held. The wrapper decides who keeps the accrual.

- LP position — trading fees stream while held.
- Staking position — staking rewards accrue.
- Bonding curve seat — fees from buys and sells.
- Vesting position — time accrues toward unlock; tenant uses pre-unlock rights.
- RWA yield-bearing NFT — interest or coupon accrues.

Variants of the wrapper: *yield-to-tenant* (the rent price already prices it in) vs *yield-to-owner* (the tenant has use, not flow).

### C) Held with active rights — actions persist post-return

The tenant invokes rights that have permanent on-chain effects. The wrapper returns intact; what the tenant did with it remains done.

- veToken / governance vote rental — votes cast during the tenure remain counted.
- AccountCap / AdminCap — authority over a contract (treasurer, moderator, oracle-updater).
- Multisig seat — temporary delegation of a signer's voting power.
- Identity attestation NFT (non-soulbound) — KYC-checked identity used for a single operation.

### D) Single-shot consumption

The wrapper is *spent* by use. The protocol verifies UID-identity at return; the wrapper internally expresses the state change (armed → consumed). The owner reclaims an empty wrapper, by design.

- Allowlist / IDO slot — one mint per slot, slot is then dead.
- Lottery ticket / mystery box — opened once.
- Event ticket — admit once.
- Voucher / discount code — one redemption.

The four categories are not features of the *protocol*. They are properties of the *wrapper*. The protocol sees all four identically — a `key + store` object that enters escrow and returns intact (by UID, not by state).

---

## 5. The canonical pattern: two-layer hot-potato

For materials that do not themselves satisfy `key + store` — most prominently `Balance<C>`, but also raw amounts, ephemeral capabilities, and any non-object resource — the wrapper exposes its material through a hot-potato discipline that mirrors the protocol's own.

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

This pattern works for any extract-return loop in category A. Substitute the field types and the conservation predicate; the *shape* is invariant.

---

## 6. The direct case — when the asset IS the access

The wrapper pattern of §5 covers any non-`key` resource (Balance, LP positions, raw amounts) that needs to be lifted into a `key + store` carrier. A second, simpler case requires no wrapper at all: the asset itself is a **capability object** that another protocol has issued to its users to grant access to its own ecosystem.

Many protocols on Sui mint `key + store` capability objects:

- A **vote-escrow cap** (veToken-style) grants voting weight and gauge-boost in the issuing protocol.
- A **market-maker cap** grants fee discounts or priority routing on a DEX.
- A **subscription cap** grants access to gated functions, paid APIs, or premium tiers.
- A **validator / operator cap** grants staking or operational privileges.
- A **DAO membership cap** grants voting and claim rights in a governance system.
- A **whitelist or KYC cap** grants verified-user access to constrained mints, sales, or operations.

Each of these is already `key + store`. They satisfy usufruct's generic bound directly. The owner integrates the cap into an escrow as-is.

### The flow

```move
// Layer 0 — usufruct
let (cap, asset_receipt) =
    usufruct::borrow_asset(&mut escrow, &tenant_cap, &random, &clock, ctx);

// The tenant now holds the cap. They call the issuing protocol directly,
// passing the cap by reference. The issuer recognizes them as a legitimate holder.
issuer::cast_vote(&cap, proposal_id, /* support */ true);
issuer::claim_rewards(&mut cap, ctx);
issuer::priority_swap(&cap, &mut pool, amount_in, ctx);
// ... whatever the cap unlocks in the issuer's ecosystem ...

// Layer 0 close — the cap returns intact.
usufruct::return_asset(&mut escrow, cap, asset_receipt);
```

No `take` / `put`. No integrator module. No second hot-potato beyond usufruct's own `AssetReceipt`. The tenant rents the cap from usufruct and *de facto* rents the access the cap grants, exercises it, returns the cap.

### Why the wrapper collapses

The wrapper collapses to identity because **the issuing protocol's own API already enforces every invariant that matters**. The cap's state either does not change with use, or whatever change matters lives in the issuer's storage, not in the cap object. The cap returns to escrow byte-identical to how it left.

The structural consequence is that **every cap-issuing protocol on Sui is integrable with usufruct for free**, with no code on the integrator's side. The integration is the cap holder's decision alone:

1. Hold the cap.
2. Call `usufruct::integrate(cap, ...)` with tenure price and policy.

That is the entire integration. The cap-issuing protocol does not need to know that its caps are being rented. It does not need to ship special code. It does not have to opt in.

### Where this fits in the taxonomy

This is a degenerate case of **category C** (§4) — held with active rights. Actions taken with the cap have permanent effects in the issuer's ecosystem; the cap returns intact. What's different is that the *integration cost is zero*.

When the cap also accrues something passively while held (vote rewards, fee shares, time-weighted boosts), the pattern blends into **category B**. At that point, the integrator may want a wrapper after all — to split passive accrual between owner and tenant — which puts them back in the §5 wrapper pattern.

### What this says about the protocol

> usufruct turns any `key + store` capability into a rentable, time-bounded right of access — without requiring the cap-issuer's cooperation.

The issuer does not have to opt in. They do not have to be aware. Any `key + store` object whose value is "the right to call certain functions" becomes a tradeable, time-bounded right the moment its holder integrates it into an escrow.

This is usufruct's place in the ecosystem: a **meta-market over Sui's capability surface**, available to every protocol whether or not they participate.

---

## 7. Composition is monoidal — layers stack

The protocol's own hot-potato (the receipt from `borrow_asset` consumed by `return_asset`) and an integration's hot-potato (e.g., `VaultBorrow`) compose without coordination. They simply nest.

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

### Why composition is safe by construction

- **Stack discipline (LIFO) is structural, not conventional.** You cannot return the wrapper to escrow without first returning the funds to the wrapper. `usufruct::return_asset` consumes the wrapper by *move*; `vault::put` needs it by `&mut`. The compiler rejects any non-nested ordering.
- **Atomic rollback.** If any `assert!` at any level fails, the entire TX reverts — including all side effects on other protocols (DEXes, lending markets, perps) called inside the stack.
- **Isolation.** Each receipt is private to its emitting module. Outer layers cannot inspect inner state; inner layers cannot escape upward. Move's linear typing keeps every layer's invariants local.

### Why composition is economically natural

Each layer charges its own fee, independently:

| Layer                 | Charges for             | Cadence       |
|-----------------------|-------------------------|---------------|
| 0 — usufruct          | tenure (time window)    | per rent      |
| 1 — vault             | per loop (use of value) | per take/put  |
| 2 — leveraged vault   | per leverage step       | per take      |
| ...                   | ...                     | ...           |

The tenant pays a *stack of fees* that settles atomically. No integrator coordinates with another. The protocol does not aggregate or route fees — each layer collects its own. The composition is associative; the fee structure is the natural monoid.

### Composition turns integrations into a DAG, not a list

Integrations may stack on the protocol or on each other. A `leveraged_balance_vault` is a layer on a `balance_vault` is a layer on usufruct. The catalog of integrations is a directed acyclic graph of capabilities, and liquidity routes itself through the stacks that offer the best fee/utility combinations. Integrators are not isolated competitors. They are composable layers in an open catalog.

---

## 8. Worked example — flash loans with horizon

The construction that justifies calling the protocol a *substrate* is also the simplest concrete instance of the composition principle. **Flash loans with horizon** — a primitive that did not exist anywhere before usufruct — emerge by composing a small integration module on top of the protocol, without modifying the protocol itself.

### 8.1 The actors and their interfaces

- **Protocol team** ships `usufruct`. Untouched.
- **Integrator** ships a `flash_loan` module — concretely, the `balance_vault` of §5 deployed to mainnet. Imports the `usufruct` package as a Move dependency.
- **Asset owner** wraps N units of USDC in a `Vault<USDC>` and integrates it into a usufruct `Escrow`, setting tenure price and lifecycle policy.
- **Tenant** rents the vault from usufruct, paying the tenure fee. Now holds the *option* to flash-loan the vault for the next T seconds, across as many TXs as desired.

No actor needs to know any other's internals. The interfaces:

- usufruct ↔ integrator: the `<Asset: key + store>` bound.
- integrator ↔ tenant: the `take` / `put` API and the `VaultBorrow` receipt.
- owner ↔ tenant: indirect, mediated by usufruct's lifecycle FSM.

### 8.2 A single TX inside the tenure window

```move
// Layer 0 — open the protocol's borrow window
let (vault, asset_receipt) =
    usufruct::borrow_asset(&mut escrow, &tenant_cap, &random, &clock, ctx);

// Layer 1 — open a flash loan against the vault
let (coin, vault_borrow) =
    flash_loan::take(&mut vault, 1_000_000, ctx);

// Layer N — arbitrary user PTB body
let coin = deepbook::swap(coin, ...);   // USDC → SUI on pool A
let coin = cetus::swap(coin, ...);      // SUI → USDC on pool B
// `coin` now holds the swap's exit value

// Layer 1 close — return funds to the vault
flash_loan::put(&mut vault, coin, vault_borrow);

// Layer 0 close — return wrapper to escrow
usufruct::return_asset(&mut escrow, vault, asset_receipt);
```

What the bytecode verifier checks at TX end, all at once:

- `asset_receipt` consumed by `usufruct::return_asset`. ✓
- `vault_borrow` consumed by `flash_loan::put`. ✓
- Vault returned has the same UID as the one borrowed. ✓
- Funds returned to the vault are ≥ `amount_owed`. ✓
- All side effects on DeepBook and Cetus commit *only* if every check above passes.

If any check fails, the entire TX reverts. The owner's vault is untouched; the tenant's tenure is preserved; no partial state is possible.

### 8.3 The horizon

In the next TX, the tenant repeats — new atomic stack, new opportunity, fresh PTB body. They may do this until the tenure expires. Each TX is independent and atomic; together, they constitute a **multi-TX flash-loan facility** over a window of time.

The protocol enforces the *window*. The integrator's module enforces *conservation per TX*. The composition delivers the new primitive, with neither layer knowing the other exists.

### 8.4 Nesting deeper — integrations on integrations

A second integrator may write a `leveraged_loan` module that uses `flash_loan::take` internally:

```move
// Layer 0 — usufruct
let (vault, asset_receipt) =
    usufruct::borrow_asset(&mut escrow, &tenant_cap, &random, &clock, ctx);

// Layer 1 — flash_loan against the vault
let (coin, vault_borrow) = flash_loan::take(&mut vault, 1_000_000, ctx);

// Layer 2 — leveraged_loan wraps the flash-loan output
let (lev_coin, lev_receipt) =
    leveraged_loan::take(&mut pool, coin, /* 5x */ 5, ctx);

// Layer N — user PTB with leveraged_coin
// ... arbitrage with `lev_coin` ...

// Layer 2 close
let coin = leveraged_loan::put(&mut pool, lev_coin, lev_receipt);

// Layer 1 close
flash_loan::put(&mut vault, coin, vault_borrow);

// Layer 0 close
usufruct::return_asset(&mut escrow, vault, asset_receipt);
```

Three receipts. Three conservation predicates. Three independent fee streams (tenure, flash-loan loop, leverage step). All settled at the same TX boundary, by the same drop-checker. None of the three layers knows about the other two.

This is the **substrate property**: an open catalog of layers, each composable with everything that comes before and after it, settled atomically by Move's type system.

---

## 9. usufruct is an FSM plus policies that orbit `borrow_asset` and `return_asset`

Calling usufruct "a multi-TX option on atomic hot-potato stacks" undersells what the protocol provides. That framing captures only one *consequence* — that the runtime window of §2 reopens across many TXs. The *mechanism* is richer.

usufruct is two things working in concert.

### A. A finite-state machine over the asset's lifecycle

The escrow holds the asset across a sequence of states. At every moment, the asset is either *Waiting* (custody locked in escrow) or *Renting* (custody surrendered to a tenant for a borrow window):

- `Waiting::Idle` — no tenant, no auction.
- `Waiting::AtDutch` — a Dutch auction is open to find the next tenant.
- `Waiting::Retired` — the owner has terminated the rental; only `claim_asset` remains.
- `Renting::Occupied` — a tenant holds the right; `borrow_asset` is callable.
- `Renting::Demand` — a challenger has placed a bid against the current tenant.

Transitions between states are driven by events (time elapsed, bids placed, tenures expired) and gated by the policies below. The FSM determines **which operations the protocol exposes at each moment**. In particular, `borrow_asset` and `return_asset` are callable only from `Renting::Occupied` or `Renting::Demand` — every other state aborts the borrow path.

### B. A policy ensemble that orbits the conditions of every transition

The protocol does not hardcode *when* a tenant may rent, *at what price*, *for how long*, *under what extension rules*, or *how the asset transfers between tenants*. It externalizes these into a `PolicyEnsemble` — eight policies the owner configures at integration time:

| Policy             | Conditions...                                                            |
|--------------------|--------------------------------------------------------------------------|
| `floor_price`      | minimum rent price; fixed or randomly drawn per cycle                    |
| `tenure_duration`  | how long the tenant's right persists after winning                       |
| `tenure_extend`    | whether and how the tenant may extend; multi-cycle commitments           |
| `handover`         | how the asset transfers from old tenant to new (instant, fixed, countdown) |
| `auction_window`   | duration of the Dutch auction itself                                     |
| `auction_shape`    | how the Dutch auction price descends across the window                   |
| `credit_shape`     | how the tenant's stake is consumed into owner earnings over the tenure   |
| `price_escalation` | how the ceiling escalates after handover                                 |

Each policy is *external configuration* the owner chooses. The same FSM operates uniformly regardless of which variants are picked. The policies do not change what the protocol *does* — they change **the conditions under which each transition is permitted, and the terms it carries**.

### The picture

```
                ┌──────────────────────────────────────┐
                │  floor_price       tenure_duration   │
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

### Why this matters for integrators

When an integrator builds a market on usufruct, they pick **two orthogonal things**:

1. **The wrapper** — what asset (§3) and what use-semantics (§4–§6). Determines *what* is being rented.
2. **The policy ensemble** — the configuration of the eight policies above. Determines *the terms* under which it is rented.

The same wrapper under different ensembles produces different markets. A `balance_vault` with a low floor, slow Dutch curve, long tenure, and free extension is a different financial instrument than the same vault with a high floor, fast curve, short tenure, and locked commitment. Same code; different contract.

### The temporal axis as one consequence among many

What was framed earlier as the *temporal axis* — multi-TX option on atomic stacks — is one consequence of this machinery, not the whole of it. The tenure is created by `tenure_duration`; the auction by `auction_window` and `auction_shape`; the price floor by `floor_price`; the multi-tenant rotation by `handover`. Together they yield a tenant-held option at owner-chosen terms.

| Capability                           | Atomic stack? | Multi-TX horizon? | Owner-configurable terms? |
|--------------------------------------|---------------|-------------------|---------------------------|
| Move type system (per-TX hot-potato) | yes           | no                | no                        |
| Aave-style flash loan                | yes           | no                | no                        |
| **usufruct + integrations**          | yes           | **yes**           | **yes**                   |

Hot-potato discipline existed before usufruct. Tenure-bounded rights at owner-configured terms did not.

---

## 10. Forward-looking catalog

The patterns below are not all implemented. They are the design space the abstraction opens. Each is one wrapper away from being a usable rental market.

| Category | Pattern                       | Wrapper exposes                              | Renter pays for                  |
|----------|-------------------------------|----------------------------------------------|----------------------------------|
| A        | `balance_vault<C>`            | flash-loanable balance                       | flash-loan window                |
| A        | `oracle_access_cap`           | rate-limited reads of a premium feed         | premium access for T             |
| A        | `inference_cap`               | rate-limited model queries                   | AI inference budget for T        |
| A        | `priority_route_cap`          | priority routing on an AMM                   | priority access for T            |
| B        | `lp_position_wrapper`         | LP token with optional fee retention split   | use rights + fees split          |
| B        | `staking_position_wrapper`    | active stake (use without unstaking)         | staking yield during T           |
| B        | `vesting_wrapper`             | unlock-tracking position                     | pre-unlock rights for T          |
| B        | `rwa_yield_wrapper`           | yield-bearing RWA                            | use + yield arrangement for T    |
| C        | `ve_token_rental`             | veToken with delegated voting                | vote rights for T                |
| C        | `multisig_seat`               | delegated signer                             | signing authority for T          |
| C        | `role_cap_rental`             | admin / treasurer / oracle role              | privileged actions for T         |
| C        | `identity_attestation`        | KYC-passed identity (non-soulbound)          | one-off compliant operations     |
| D        | `allowlist_slot`              | one-time mint right                          | the slot, atomically             |
| D        | `event_ticket_wrapper`        | one-time admission                           | the entry, atomically            |
| D        | `voucher_wrapper`             | redemption right                             | the redemption, atomically       |
| meta     | `composite_portfolio`         | basket of N wrappers, rented as a unit       | the basket as a single asset     |
| meta     | `leveraged_*`                 | meta-wrapper over another integration        | leverage on top of any pattern   |

The last two rows demonstrate the DAG structure. `composite_portfolio` and `leveraged_*` are *meta-integrations* that wrap other integrations and are themselves rentable. The catalog composes onto itself.

---

## 11. The integrator's mental model

If you are building on usufruct, the question to ask is not "is my asset rentable?" but the following four:

1. **What is my `key + store` wrapper?** What carries the underlying material as a Sui object that the protocol can hold.
2. **What does "use" mean?** Which of the four categories (A/B/C/D) fits, and what API does the wrapper expose to make it usable.
3. **What is the hot-potato discipline?** What receipt the wrapper issues (if any), what conservation it enforces, what fee it charges per use.
4. **What does my wrapper compose with?** Whether it is a base layer, sits atop another integration, or is designed to be stacked under future ones.

If those four questions have answers, you have an integration. The protocol takes care of the rest — lifecycle, time, fees, auctions, retirement — uniformly.

---

## 12. References

- `balance_vault/` — reference implementation of pattern (A), with end-to-end tests demonstrating the multi-TX flash-loan loop. *(Pending in this repo.)*
- The usufruct protocol — the substrate this catalog grows on. *(Separate repository.)*
- usufruct's `ARCHITECTURE.md` — protocol internals. Read after this document, not before.
