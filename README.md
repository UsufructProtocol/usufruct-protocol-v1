<p align="center">
  <img src="media/github/usufruct-banner.png" alt="usufruct" width="100%" />
</p>

# usufruct

*A rental protocol for Sui objects — a new market layer for the right of use.*

When you rent something, the asset leaves the market.

An apartment listed for rent disappears from results the moment a guest checks in. A car on loan sits in one driveway. A reserved court cannot be booked by anyone else. The right to use the asset — the *usus* — belongs to one holder for the duration of the rental, and while it does, the market is closed.

**What if the rental right were always liquid — even while someone was using it?**

If someone is willing to pay more than the current usufructuary, why should the market stop them? If the asset has value, that value should be continuously discoverable. At the same time, displacing someone mid-use without guarantee is predatory — a usufructuary who entered in good faith needs to know what they signed up for.

**usufruct** is a rental protocol for Sui that answers that question. It makes the right of use continuously liquid while guaranteeing the current usufructuary's economics.

The asset never leaves the market. There is always a price at which the usus is acquirable. A challenger can bid at any moment, but the current usufructuary is guaranteed a window — the handover — before displacement executes. When no one wants the asset, the price descends automatically through a Dutch auction until someone does. The market never closes.

---

## Usufruct Playground: Learn How the Protocol Works by Playing

Before reading specs or code, build intuition interactively. The [usufruct playground](https://playground.usufruct.io/) lets you configure policies, run rental scenarios, and observe how price, credit, and handover mechanics interact — without deploying anything.

---

## Test the Protocol with an AI Agent — `llms.txt`

[`llms.txt`](./llms.txt) is a self-contained guide for LLM agents. Load it and the agent will build real PTBs against the testnet deployment — wallet, funding, integrate, rent, collect, handover — without reading any Move source.

### With Claude Code

```bash
claude   # from the repo root
```

```
@llms.txt  Set up a wallet, integrate the dummy asset, and rent it for one tenure.
           Show the escrow ID once the asset is occupied.
```

Session state persists to `.usufruct-demo.json` — every follow-up prompt resumes where the last one left off.

**Be curious.** Let the agent walk you through the built-in scenarios, then push further. Ask it to swap ensembles, change the credit shape, reshape the auction curve, crank up the price escalation until a challenger is forced out, or spin up a fleet of escrows under a single cap. Ask what a usufructuary can actually do with the asset once they hold the cap — what PTBs are legal inside a borrow, what other protocols compose. Ask it to pay rent in a different coin, or integrate your own asset instead of the dummy. The guide is the map; the agent drives; the protocol surprises.

---

## Why usufruct is different

Most rental markets close when someone checks in. usufruct doesn't.

**Always a price.** In every state there is a price at which the right of use can be acquired: the rest price at idle, a descending price during the Dutch auction, an escalated price while occupied.

**Always liquid.** A challenger can bid at any time. The current usufructuary keeps access for the handover window before the new usufructuary takes over. The window is configured by the governor; the guarantee is enforced by the protocol.

**Self-correcting.** Competition drives price up. Absence of demand drives it down through the Dutch auction. Both are governed by configurable curves.

**Usufructuary economics preserved.** A displaced usufructuary recovers the unused portion of their stake — the part not yet consumed by the credit curve. They paid for time; they recover what they didn't use.

**Price is discovered by competition.** Usufructuaries bid against each other for the right of use. The current usufructuary's position is always contestable — anyone willing to pay more can challenge it. The governor earns the market rate, not a fixed floor.

**No keeper required.** State transitions execute lazily on the next transaction that touches the escrow. No off-chain coordinator, no cron job, no external dependency on liveness.

**Protocol revenue scales without contention.** Settled fees never touch a shared accumulator. Each transition posts an independent `FeeMessage` object to the protocol inbox's address; the inbox is never an input in any user PTB. User throughput is never gated by fee collection, at any escrow count.

**Zero external dependencies.** The package imports only the Sui standard library. No oracle, no AMM, no third-party protocol. Any Sui object integrates without taking a dependency on an external ecosystem, and the protocol itself carries no upgrade or governance risk from outside parties.

**The asset is the interface.** Any object your protocol already issues integrates directly — no adapter code, no permission required, no contract rewrite. If your object has `key + store`, your protocol is already compatible with usufruct.

---

## How it works

An governor wraps any Sui object into an escrow and configures the market — price floor, tenure length, handover rules, auction behavior. From that point, the protocol governs the full lifecycle autonomously.

A usufructuary pays to acquire the right of use. They receive a `UsufructCap` — a capability that proves their current right. With it, they can borrow the asset into any Programmable Transaction Block, use it however the asset's own interface allows, and return it before the transaction closes. The protocol does not inspect what happens in between.

If a challenger bids while the asset is occupied, the current usufructuary keeps their right for the handover window before displacement executes. When no one wants the asset, the price descends through a Dutch auction until someone does. When the governor is ready to exit, they retire the escrow and claim the asset back — income having been collected separately, all along, from their `EarningsInbox`.

Every transition executes lazily on the next transaction that touches the escrow.

---

## The usufructuary's runtime

The right of use is exercised through one pair of functions:

```move
let (asset, receipt) =
    usufruct::borrow_asset(&mut escrow, &usufruct_cap, &clock, ctx);
// ── the usufructuary's execution space ─────────────────────────────────────────────
//   call any function on `asset`
//   compose with other protocols in the same PTB
//   open and close sub-runtimes using the asset's own hot-potato API
// ─────────────────────────────────────────────────────────────────────────────
usufruct::return_asset(&mut escrow, asset, receipt);
```

Between the two calls, the usufructuary holds the asset inside a Programmable Transaction Block. The `AssetReceipt` hot-potato forces return before the transaction closes. What happens in between is entirely up to the usufructuary and the asset's own interface — the protocol does not know and does not interfere.

---

## Configuration

Eight policies configure the market at integration time. They determine the terms; the state machine is invariant over them.

| Policy | Controls |
|--------|---------|
| `rest_price` | Floor price per idle cycle |
| `tenure_duration` | Maximum tenure length |
| `tenure_extend` | Single or multi-tenure commitment |
| `handover` | Handover variant — off, full-tenure, or countdown |
| `auction_window` | Dutch auction duration — fixed window or skipped |
| `auction_shape` | Price descent curve |
| `credit_shape` | Credit consumption rate |
| `price_escalation` | Escalation function under demand |
| `commitment` | Governor exit lock — immediate or deferred with a minimum duration |

### Archetypes

The same asset under different configurations produces different markets:

- **Pay-per-call access** — millisecond tenures, instant handover. No queuing, no protection. Price resets to floor each cycle. Designed for AI agents and rate-limited APIs.
- **Protected rental** — day-long tenures, countdown handover. The current usufructuary has a guaranteed window before displacement. Designed for human users who need continuity.
- **Reservation system** — full-tenure handover tied to the tenure ceiling. Displacement is impossible before the tenure ends. Designed for time-slot bookings where partial occupancy has no value.
- **Yield position** — multi-tenure commitment, back-loaded credit shape, high price escalation. The usufructuary commits to multiple tenures upfront at a lower per-tenure rate. Displacement is cheap early in the tenure and expensive late — the incumbent's sunk credit grows over time, rewarding those who hold through volatility. Designed for LP positions, staking seats, or any asset where long-term commitment has compounding value.

### One engine, many markets

The state machine is invariant. The eight policies are external configuration that the engine resolves at runtime — it never branches on policy variants, only on resolved values. The same transition logic, the same credit arithmetic, the same settlement code runs regardless of which policy combination is active.

Each policy axis adds a dimension to the space of expressible markets: a different `credit_shape` changes the cost of displacement at any point in the tenure; a different `handover` changes the competitive dynamics; a different `auction_shape` changes how price descends when demand stalls; a different `price_escalation` changes the incumbent's cost of renewal relative to an external challenger.

**336 discrete policy combinations are verified by the test corpus. The continuous parameter space — price floors, duration ceilings, curve parameters — is unbounded.**

usufruct is rental market as a primitive — integrate your asset once and get price discovery, Dutch auctions, handovers, credit curves, and retirement. No custom auction logic to write, no handover code to maintain, no credit model to design. The market is infrastructure; your asset is the product.

---

## Economics

**How the governor earns.** When a usufructuary enters, they lock a stake. As time passes, that stake is consumed by the credit curve — value flows from the usufructuary's locked position to the governor. At settlement (displacement, tenure expiry, or handover), the consumed portion is split off as the governor's share and the unconsumed portion is returned to the usufructuary. The governor's share is not held in the escrow: it is mailed to a standalone `EarningsInbox` as an `EarningsMessage`. The governor (or whoever holds the inbox) drains accumulated messages into a coin with `collect_earnings_messages` — an owned-object operation that never touches the shared escrow, so it batches across a whole portfolio. Income and governance are separate objects: the `EarningsInbox` is born paired with the `GovernanceCap` at `integrate` but can be held, sold, or rented independently.

**The split.** Of the consumed credit, **90% goes to the governor** and **10% is the protocol fee**. The fee is never charged on locked stake or gross payment — only on value that has already been earned.

**Aligned incentives.** The more usufructuaries compete for the asset, the higher the price, the more credit accrues, and the more both governor and protocol earn. Neither benefits from low activity. The payment coin is chosen by the governor at integration time — it is the coin usufructuaries pay with, the coin the governor earns, and the coin the protocol collects its fee in. There is no protocol token, no wrapping, no conversion.

> **Note for protocols with native tokens.** If you denominate rentals in your own coin, every usufructuary competing for the asset must acquire it first. Demand for the right of use converts directly into demand for your token — not through speculation, but through participation. The rental market becomes an organic demand circuit for your coin, grounded in the utility of the asset itself.

---

## Retiring the asset

The governor reclaims the asset in two steps: `retire()` then `claim_asset()`.

**`retire()`** signals the governor's intent to exit. Its effect depends on the current state:
- From `Idle` or `Descent` — the asset transitions to `Retired` immediately.
- From `Occupied` or `Demand` — a retire flag is set. The current usufructuary completes their tenure normally; the asset moves to `Retired` when it ends.

In both cases, the current usufructuary's economics are preserved — there is no forced eviction.

**`claim_asset()`** is called once the escrow is in `Retired` state. It consumes the escrow and returns the asset — only the asset; income was settled to the `EarningsInbox` throughout, so there is nothing to sweep. It takes the `GovernanceCap` by reference (the cap may govern other escrows, so it is not consumed) and deletes the escrow object permanently.

**`renounce_governance()`** is the opposite of claiming: instead of reclaiming the asset, the governor burns the `GovernanceCap` to give up control forever. Every escrow the cap governed is **sealed** — `retire`, `update_config`, and `claim_asset` become permanently unreachable, so the asset can never be pulled back and the terms can never change. The income is untouched: the `EarningsInbox` keeps receiving and stays collectable. It is the strongest commitment a governor can make — a credibly permanent market — and because income is a separate object, making that commitment costs no future earnings.

**The commitment policy** governs when `retire()` becomes callable. Set to `Immediate`, the governor can retire at any time. Set to `Deferred`, retirement is locked until the commitment window has elapsed — an on-chain credibility signal to usufructuaries that the market will remain open for a minimum duration.

---

## Built with functional style on Sui Move 2024

The codebase applies functional programming consistently throughout: sum types for state, linear types for resource discipline, value transformations for transitions, resolved configuration as pure values. Sui Move 2024's enums with exhaustive match made this style expressible in Move for the first time.

The result is a state machine where illegal states have no type representation and illegal programs cannot be constructed. For a deeper look at the principles behind these decisions, see [`CODE_PRINCIPLES.md`](./CODE_PRINCIPLES.md).

---

## Further reading

- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — module layers, state hierarchy, FSM engine, fee layer
- [`PATTERNS.md`](./PATTERNS.md) — integration patterns and the design space they open
- [`CODE_PRINCIPLES.md`](./CODE_PRINCIPLES.md) — design principles applied across the codebase
- [`UPGRADE_STRATEGY.md`](./UPGRADE_STRATEGY.md) — why usufruct versions instead of upgrading, and what that means for integrators
- [`specs/`](./specs/) — full technical specification per module
