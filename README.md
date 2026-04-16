# Liquid Renting Protocol

A market layer that makes the usage rights of any on-chain asset continuously liquid — built on two Move primitives: the Capability pattern and the Hot Potato pattern.

---

## The two primitives

**Capability.** The asset you integrate into LRP is a capability: possessing it grants the right to call functions in your ecosystem. LRP never modifies your asset or your protocol — it governs who holds that capability at any given moment.

**Hot Potato.** LRP gives tenants access to the capability without transferring ownership. The escrow releases the asset by value inside a Programmable Transaction Block; the Move type system guarantees its return before the transaction closes. This is how *usus* (the right to use) is separated from *abusus* (the right to own) at the type level — not by contract, but by construction.

---

## What LRP adds

Given that the two patterns already solve the mechanism, LRP provides the market coordination layer on top.

- **The asset is always rentable.** In every protocol state there is a price at which the usus is accessible. While rented, any actor can displace the current tenant by paying `next_rent_price`. While idle, anyone can enter at `min_rent_price`. During a Dutch Auction, the price descends until the market finds a buyer. The protocol never closes — the usus is always acquirable at some price.

- **The price self-regulates, and that regulation is configurable.** While the asset is rented, price can only move upward — each displacement requires `next_rent_price > last_rent_price`, defined by `f_next_rent_price`. When the market stops validating the current price and the active block expires, a Dutch Auction corrects it downward via `f_price_descent`. Both curves are configured by the integrator. Price ascends by competition, descends by abandonment — the direction is asymmetric by design.

- **The integrator earns the time-consumed value of each tenant.** At every displacement or block expiry, `used_credit` — the portion of the tenant's stake consumed by elapsed time — flows to the integrator's balance inside the escrow. It accumulates passively with no action required; the `OwnerCap` holder withdraws it at any time. The rate at which it accrues is shaped by `f_credit_ascent` — another configurable parameter.

- **A displaced tenant always recovers their unused value.** When a new tenant displaces the current one, `remain_credit` — the unconsumed portion of the outgoing tenant's stake — is returned to them immediately and automatically. A tenant's capital is never trapped: whatever time they did not use is always recoverable. The exact amount depends on how much of the block has elapsed, shaped by `f_credit_ascent`.

- **A displaced tenant keeps access for a guaranteed window.** Displacement is not immediate. When a new tenant pays, the current tenant retains full access to the asset for `handover_floor` — a fixed, publicly known duration — before the handover executes. During this window, multiple actors may compete for the position; the last valid bid wins. Financial compensation (`remain_credit`) and operational continuity (`handover_floor`) are two independent guarantees that together make rational entry possible at any point in the rental cycle.

- **Identity-agnosticism makes renewal an emergent property.** LRP evaluates `f_next_rent_price` against a price, never against an address. The protocol cannot distinguish a self-renewal from a competitive takeover — both are valid bids at `next_rent_price`. As a consequence, the current tenant can renew their own position by bidding against themselves: they pay `next_rent_price` and simultaneously receive `remain_credit` as the displaced party. Their net cost is `increment + used_credit` — always strictly less than the full price any external competitor must pay. A renewal system, a right of first refusal, and a structural cost advantage for the incumbent all emerge from this single property without the protocol encoding any of them.

- **The integrator decides the currency.** Any `Coin<T>` is valid as `payment_token` — all prices, tenant stakes, and earnings are denominated and settled in that single type. If the integrating protocol uses its own native token, the rental market becomes an organic demand source for it: every actor competing for the usus must first acquire the token. Demand for the asset's usage rights converts directly into buy pressure on the coin — not through speculation, but through participation.

- **The rules cannot change while your position is active.** All integration parameters are set once and are permanently immutable for the lifetime of that instance. No integrator can alter the economics, the curve shapes, or the timing parameters while a tenant holds a position — or at any point during the integration. Tenants know exactly what they entered into, and that cannot change.

- **Custody and lazy state transitions** — the escrow holds the asset for its entire lifecycle; only the designated tenant can borrow it. The state machine is keeper-free: every transition is derived from on-chain timestamps and immutable parameters, resolved lazily by the next transaction that touches the escrow. The integrator retains full sovereignty through the `OwnerCap`: at any time, the cap holder can withdraw accumulated earnings or retire the asset from the escrow entirely.

Neither the asset protocol nor the tenant needs to build or reason about any of this infrastructure.

---

## Design philosophy

LRP is infrastructure. The package has no external dependencies — only the Sui standard library. Any protocol that issues a capability can integrate without taking a dependency on a third-party ecosystem.

---

## State machine

```
integrate
    └─► Idle ──────────────────────────────────────────────► Retired
           │                                                      ▲
           ▼                                                      │
        Rented (rent_handover_open)  ──── retire() ──────────────┤
           │                                                      │
           ├─► Rented (rent_handover_confirmed)                   │
           │        │                                             │
           │        └─► Rented (rent_handover_open) ─────────────┤
           │                                                      │
           └─► At Dutch Auction ──── retire() ───────────────────┘
                    │
                    └─► Idle
```

| Transition | Trigger |
|---|---|
| `Idle → Rented` | A user pays exactly `min_rent_price` |
| `Rented → Rented` (takeover) | A new user pays `next_rent_price`; displaced tenant receives `remain_credit` |
| `Rented → At Dutch Auction` | Tenant's time expires with no successor |
| `At Dutch Auction → Rented` | A buyer accepts the current descending price |
| `At Dutch Auction → Idle` | Price descends to `min_rent_price` with no buyer |
| `Any → Retired` | Owner calls `retire()` — immediate from `Idle` or `At Dutch Auction`; deferred until the active block ends from `Rented` |

---

## The caps

**`OwnerCap`** (`key + store`) — minted at integration, freely transferable. Possession is the sole authorization mechanism for owner operations: withdrawing accumulated earnings and calling `retire()`. The protocol never needs to know the owner's address — whoever holds the cap at call time is the legitimate owner.

**`TenantCap`** (`key` only, no `store`) — minted at bid time, soul-bound to the bidder's address. Used by the tenant to borrow the asset from the escrow. Non-transferable by construction: the type system forecloses sub-leasing without any additional check.

---

## The implicit sale

Because `OwnerCap` has `key + store`, it satisfies the asset integration requirements of the protocol — it is a freely transferable object with an exercisable usus. This means an `OwnerCap` can itself be deposited into a new (level 2) escrow instance.

A level 2 tenant who holds `OwnerCap_1` during their rental block has full administrative access to the level 1 escrow: they can withdraw accumulated earnings and call `retire()`. `retire()` is only available once `retire_floor` has elapsed since level 1 integration — an on-chain commitment the integrator made to tenants at integration time. Once callable, if the level 1 asset is in `Idle` or `At Dutch Auction`, the asset exits immediately. If it is in `Rented`, retirement is deferred: the flag is set but the asset does not exit until the active block concludes. In that case, whoever holds `OwnerCap_1` at the moment the level 1 block expires — not necessarily the tenant who called `retire()` — is the one who receives the underlying asset. The level 2 state machine runs independently: if the level 2 `handover_countdown` expires before the level 1 block ends, a new level 2 tenant may take over `OwnerCap_1` and claim the asset on retirement. What has occurred is an ownership transfer, mediated entirely by the rental market. The protocol did not design for sale — it discovered that ownership transfer is a special case of capability transfer.

The depth limit is two. An `OwnerCap` whose underlying escrow holds a real asset is valid. An `OwnerCap` whose underlying escrow holds another `OwnerCap` is rejected at integration time. At depth 3, the chain of value becomes unobservable: the outer escrow makes claims about an asset it cannot directly verify. The restriction is not a constraint against composability — it is a guarantee that every escrow in the protocol is always one level of indirection from a real asset.

---

## Integration interface

### Requirements

- An asset with `key + store` abilities
- A payment token issued as `Coin<T>`
- The integration parameters below

### Parameters

| Parameter | Description | Constraint |
|---|---|---|
| `min_rent_price` | Price floor. Lowest valid rental price and lower bound of the Dutch Auction. | `> 0` |
| `tenure_ceiling` | Maximum duration of a single rental block. | `> 0`; `≥ handover_floor` |
| `handover_floor` | Duration of the competitive bidding window after a takeover is initiated. The current tenant retains access for exactly this duration (bounded by remaining time). | `0 < x ≤ tenure_ceiling` |
| `descent_ceiling` | Maximum duration of a Dutch Auction before price reaches `min_rent_price` and the asset returns to `Idle`. | `> 0` |
| `retire_floor` | Minimum time since integration before `retire()` may execute. An on-chain commitment to tenants: the asset cannot exit during this window. | `≥ 0` |
| `f_credit_ascent` | Normalized shape `g : [0,1] → [0,1]`. Defines how the tenant's credit is consumed over the rental block. | `g(0)=0`, `g(1)=1`, bounded, strictly increasing |
| `f_price_descent` | Normalized shape `h : [0,1] → [0,1]`. Defines how the auction discount deepens during a Dutch Auction. | `h(0)=0`, `h(1)=1`, bounded, strictly increasing |
| `f_next_rent_price` | Maps `last_rent_price → next_rent_price`. The minimum price required to displace the current tenant. | `f(p) > p` |
| `payment_token` | The currency in which all prices, stakes, and earnings are denominated and settled. | Any `Coin<T>` |

All parameters are set once at integration time and are **permanently immutable**. To change them, retire the asset and re-integrate under the new configuration.

### The three incentive functions

**`f_credit_ascent(t)`** — active during `Rented`. Controls the rate at which a tenant's stake is consumed over time. A concave curve penalizes early displacement; a convex curve lowers the cost of entry by keeping `remain_credit` high early in the block.

**`f_price_descent(t)`** — active during `At Dutch Auction`. Controls how fast the auction price descends from `last_rent_price` to `min_rent_price`. A concave curve rewards acting early; a convex curve rewards patience.

**`f_next_rent_price(p)`** — active during `Rented`. Sets the takeover premium. The size of the increment is the direct cost of griefing and the direct component of the incumbent's renewal cost — size it deliberately.

### Protocol fee

5%, hardcoded. Charged on `used_credit` at the moment it flows — never on locked stake or gross payment.

---

## Examples

<!-- TODO -->

---

## Further reading

The full protocol specification — covering the formal constraints of the incentive functions, attack vector analysis, and the complete economic model — is in [`liquid-renting-protocol-design.md`](./liquid-renting-protocol-design.md).
