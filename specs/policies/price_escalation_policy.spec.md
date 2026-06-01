# price_escalation_policy

## § OVERVIEW

The policy that configures how price scales with demand across successive tenancies. Instead of the governor setting an explicit price, the market sets it: each usufructuary's committed stake becomes the reference point for the next usufructuary's minimum floor. The protocol reads the reference stake from the most recent bid — in `Occupied` state this is the current usufructuary's stake; in `Demand` state it is the pending (latest) bid's stake, reflecting the most recent signal of market willingness to pay. `FixedDelta` adds a constant increment on top of that reference, creating a simple linear ratchet. `CompoundDelta` applies a percentage growth plus a fixed minimum increment, enabling compounding trajectories for high-demand assets where each successive usufructuary signals stronger conviction.

Its counterpart is `AuctionWindowPolicy` with `auction_shape`: after a tenure expires without a waiting usufructuary, the escalated price could otherwise sit frozen at a level the market can no longer reach. The auction descent window is what corrects this — it brings the price back down to the rest floor over a configurable time and at a rate shaped by `auction_shape`. Together, escalation and descent form the protocol's full price discovery loop: up with demand, down when demand stalls.

## § TYPES

```
PriceEscalationPolicy   has copy, drop, store
  FixedDelta   { delta: Price }
  CompoundDelta { bps: BasisPoints, delta: Price }
```

- `FixedDelta` — next price = `previous_stake + delta`; linear growth per tenure.
- `CompoundDelta` — next price = `previous_stake × (1 + bps/10_000) + delta`; percentage growth plus a fixed floor increment.

## § API

**Constructors** (public)
- `price_escalation_policy::new_fixed_delta(delta: Price): PriceEscalationPolicy` — asserts `delta > 0`.
- `price_escalation_policy::new_compound_delta(bps: BasisPoints, delta: Price): PriceEscalationPolicy` — asserts `bps ∈ [1, u64::MAX − 10_000]` and `delta > 0`.

**Projections** (package)
- `price_escalation_policy::proj_is_fixed_delta`, `proj_is_compound_delta`
- `price_escalation_policy::proj_fixed_delta`, `proj_compound_delta_bps`, `proj_compound_delta_delta` — each returns `Option<T>`.

**Computations** (package)
- `price_escalation_policy::compute_next_price(&PriceEscalationPolicy, price: Price): Price` — applies the escalation formula to `price` (the previous usufructuary's stake reinterpreted as a reference price) and returns the escalated floor.

## § INVARIANTS

- `delta > 0` enforced at construction; price must strictly increase each tenure.
- The `bps` upper bound prevents the compound multiplier from overflowing u64 arithmetic.
- `compute_next_price` does not apply the floor price cap; that comparison happens in `asset_state` after this call.

## § EVENTS

None.
