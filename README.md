<p align="center">
  <img src="media/github/usufruct-banner.png" alt="usufruct" width="100%" />
</p>

# usufruct

*A rental protocol for Sui objects — a new market layer for the right of use.*

When you rent something, the asset leaves the market.

An apartment listed for rent disappears from results the moment a guest checks in. A car on loan sits in one driveway. A reserved court cannot be booked by anyone else. The right to use the asset — the *usus* — belongs to one holder for the duration of the rental, and while it does, the market is closed.

**What if the rental right were always liquid — even while someone was using it?**

If someone is willing to pay more than the current tenant, why should the market stop them? If the asset has value, that value should be continuously discoverable. At the same time, displacing someone mid-use without guarantee is predatory — a tenant who entered in good faith needs to know what they signed up for.

**usufruct** is a rental protocol for Sui that answers that question. It makes the right of use continuously liquid while guaranteeing the current tenant's economics.

The asset never leaves the market. There is always a price at which the usus is acquirable. A challenger can bid at any moment, but the current tenant is guaranteed a window — the handover — before displacement executes. When no one wants the asset, the price descends automatically through a Dutch auction until someone does. The market never closes.

---

## How it works

An owner integrates any Sui object with `key + store` abilities into an `Escrow<Asset, CoinType>`. The protocol governs the full lifecycle from there.

**Always a price.** In every state there is a price at which the right of use can be acquired: the rest price at idle, a descending price during the Dutch auction, an escalated price while occupied.

**Always liquid.** A challenger can bid at any time. The current tenant keeps access for the handover window before the new tenant takes over. The window is configured by the owner; the guarantee is enforced by the protocol.

**Self-correcting.** Competition drives price up. Absence of demand drives it down through the Dutch auction. Both are governed by configurable curves.

**Tenant economics preserved.** A displaced tenant recovers the unused portion of their stake — the part not yet consumed by the credit curve. They paid for time; they recover what they didn't use.

**Price is discovered by competition.** Tenants bid against each other for the right of use. The current tenant's position is always contestable — anyone willing to pay more can challenge it. The owner earns the market rate, not a fixed floor.

**No keeper required.** State transitions execute lazily on the next transaction that touches the escrow. No off-chain coordinator, no cron job, no external dependency on liveness.

---

## What you integrate

The protocol is generic over asset and payment coin:

```move
Escrow<Asset: key + store, CoinType>
```

Any object your protocol already issues — a governance cap, an LP position, an access credential, a yield-bearing position — integrates directly. If it has `key + store`, it is compatible. No adapter code. No permission from the issuing protocol. The object is the interface; usufruct holds it; the market does the rest.

```move
let owner_cap = usufruct::integrate<MyAsset, SUI>(
    asset, ensemble, commitment, &fee_ref, &random, &clock, ctx
);
```

---

## The tenant's runtime

The right of use is exercised through one pair of functions:

```move
let (asset, receipt) =
    usufruct::borrow_asset(&mut escrow, &tenant_cap, &random, &clock, ctx);
// ── the tenant's execution space ─────────────────────────────────────────────
//   call any function on `asset`
//   compose with other protocols in the same PTB
//   open and close sub-runtimes using the asset's own hot-potato API
// ─────────────────────────────────────────────────────────────────────────────
usufruct::return_asset(&mut escrow, asset, receipt);
```

Between the two calls, the tenant holds the asset inside a Programmable Transaction Block. The `AssetReceipt` hot-potato forces return before the transaction closes. What happens in between is entirely up to the tenant and the asset's own interface — the protocol does not know and does not interfere.

---

## Configuration

Eight policies configure the market at integration time. They determine the terms; the state machine is invariant over them.

| Policy | Controls |
|--------|---------|
| `rest_price` | Floor price per idle cycle — fixed or random in range |
| `tenure_duration` | Maximum tenure length — fixed or random in range |
| `tenure_extend` | Single or multi-tenure commitment |
| `handover` | Handover variant — instant, fixed time, countdown, or random in range |
| `auction_window` | Dutch auction duration — fixed window, skipped, or random in range |
| `auction_shape` | Price descent curve |
| `credit_shape` | Credit consumption rate |
| `price_escalation` | Escalation function under demand |
| `commitment` | Owner exit lock — immediate or deferred with a minimum duration |

### Archetypes

The same asset under different configurations produces different markets:

- **Pay-per-call access** — millisecond tenures, instant handover. No queuing, no protection. Price resets to floor each cycle. Designed for AI agents and rate-limited APIs.
- **Protected rental** — day-long tenures, countdown handover. The current tenant has a guaranteed window before displacement. Designed for human users who need continuity.
- **Reservation system** — fixed-time handover tied to the tenure ceiling. Displacement is impossible before the tenure ends. Designed for time-slot bookings where partial occupancy has no value.
- **Yield position** — multi-tenure commitment, back-loaded credit shape, high price escalation. The tenant commits to multiple tenures upfront at a lower per-tenure rate. Displacement is cheap early in the tenure and expensive late — the incumbent's sunk credit grows over time, rewarding those who hold through volatility. Designed for LP positions, staking seats, or any asset where long-term commitment has compounding value.

### One engine, many markets

The state machine is invariant. The eight policies are external configuration that the engine resolves at runtime — it never branches on policy variants, only on resolved values. The same transition logic, the same credit arithmetic, the same settlement code runs regardless of which policy combination is active.

Each policy axis adds a dimension to the space of expressible markets: a different `credit_shape` changes the cost of displacement at any point in the tenure; a different `handover` changes the competitive dynamics; a different `auction_shape` changes how price descends when demand stalls; a different `price_escalation` changes the incumbent's cost of renewal relative to an external challenger.

**672 discrete policy combinations are verified by the test corpus. The continuous parameter space — price floors, duration ranges, curve parameters — is unbounded.**

usufruct is rental market as a primitive — integrate your asset once and get price discovery, Dutch auctions, handovers, credit curves, and retirement. No custom auction logic to write, no handover code to maintain, no credit model to design. The market is infrastructure; your asset is the product.

---

## Economics

**How the owner earns.** When a tenant enters, they lock a stake. As time passes, that stake is consumed by the credit curve — value flows from the tenant's locked position to the owner's accumulated balance. At settlement (displacement, tenure expiry, or handover), the consumed portion is distributed and the unconsumed portion is returned to the tenant. The owner withdraws accumulated earnings at any time via the `OwnerCap` with no action required from anyone else.

**The split.** Of the consumed credit, **90% goes to the owner** and **10% is the protocol fee**. The fee is never charged on locked stake or gross payment — only on value that has already been earned.

**Aligned incentives.** The more tenants compete for the asset, the higher the price, the more credit accrues, and the more both owner and protocol earn. Neither benefits from low activity. The payment coin is chosen by the owner at integration time — it is the coin tenants pay with, the coin the owner earns, and the coin the protocol collects its fee in. There is no protocol token, no wrapping, no conversion.

> **Note for protocols with native tokens.** If you denominate rentals in your own coin, every tenant competing for the asset must acquire it first. Demand for the right of use converts directly into demand for your token — not through speculation, but through participation. The rental market becomes an organic demand circuit for your coin, grounded in the utility of the asset itself.

---

## Retiring the asset

The owner reclaims the asset in two steps: `retire()` then `claim_asset()`.

**`retire()`** signals the owner's intent to exit. Its effect depends on the current state:
- From `Idle` or `AtDutch` — the asset transitions to `Retired` immediately.
- From `Occupied` or `Demand` — a retire flag is set. The current tenant completes their tenure normally; the asset moves to `Retired` when it ends.

In both cases, the current tenant's economics are preserved — there is no forced eviction.

**`claim_asset()`** is called once the escrow is in `Retired` state. It consumes the escrow, returns the asset and all accumulated earnings, and burns the `OwnerCap`. The escrow object is deleted permanently.

**The commitment policy** governs when `retire()` becomes callable. Set to `Immediate`, the owner can retire at any time. Set to `Deferred`, retirement is locked until the commitment window has elapsed — an on-chain credibility signal to tenants that the market will remain open for a minimum duration.

---

## Simulator

Before reading specs or code, build intuition interactively. The [usufruct simulator](https://github.com/0xkurious/usufruct-simulator) is a playground that lets you configure policies, run rental scenarios, and observe how price, credit, and handover mechanics interact — without deploying anything.

---

## Built with functional style on Sui Move 2024

The codebase applies functional programming consistently throughout: sum types for state, linear types for resource discipline, value transformations for transitions, resolved configuration as pure values. Sui Move 2024's enums with exhaustive match made this style expressible in Move for the first time.

The result is a state machine where illegal states have no type representation and illegal programs cannot be constructed. For a deeper look at the principles behind these decisions, see [`CODE_PRINCIPLES.md`](./CODE_PRINCIPLES.md).

---

## Zero external dependencies

The package imports only the Sui standard library. No oracle, no AMM, no third-party protocol. Any Sui object integrates without taking a dependency on an external ecosystem, and the protocol itself carries no upgrade or governance risk from outside parties.

usufruct is a primitive — composable with anything, dependent on nothing.

---

## Further reading

- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — module layers, state hierarchy, FSM engine
- [`PATTERNS.md`](./PATTERNS.md) — integration patterns and the design space they open
- [`CODE_PRINCIPLES.md`](./CODE_PRINCIPLES.md) — design principles applied across the codebase
- [`specs/`](./specs/) — full technical specification per module
