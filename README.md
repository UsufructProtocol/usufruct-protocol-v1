<p align="center">
  <img src="media/usufruct-banner.png" alt="usufruct" width="100%" />
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

The same asset under different configurations produces different markets. A machine-oriented configuration (millisecond tenures, instant handover) produces a pay-per-call access market. A user-oriented configuration (day-long tenures, countdown handover) produces a protected rental. A fixed-time configuration produces a reservation system. Same protocol code; different economic products.

**1 FSM engine. 672 verified configurations. Unbounded parameter space.**

usufruct is rental market as a primitive — integrate your asset once and get the full market mechanics: price discovery, Dutch auctions, handovers, credit curves, and retirement. No custom auction logic to write, no handover code to maintain, no credit model to design. The market is infrastructure; your asset is the product.

---

## Simulator

Before reading specs or code, build intuition interactively. The [usufruct simulator](https://github.com/0xkurious/usufruct-simulator) is a playground that lets you configure policies, run rental scenarios, and observe how price, credit, and handover mechanics interact — without deploying anything.

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
