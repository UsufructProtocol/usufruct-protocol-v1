# rest_price_policy

## § OVERVIEW

The price of the asset at rest. When the asset is `Idle` — no active usufructuary and no prior acquisition price in memory — this policy defines the exact price a usufructuary must pay. It is the only price that governs entry from `Idle`; nothing else contributes to or overrides it in that state.

Outside of `Idle`, `RestPricePolicy` plays one secondary role: it is the saturation point of the dutch auction. When the `Descent` phase runs, the price descends from the last acquisition price toward the rest price; no bid can be placed below it.

A fixed rest price gives usufructuaries a predictable minimum cost of entry from idle; a random range introduces variability that can discourage systematic underbidding against a known target.

## § TYPES

```
RestPricePolicy   has copy, drop, store
  Fixed         { price: Price }
  RandomInRange { min: Price, max: Price }
```

- `Fixed` — every tenure starts at the same minimum price.
- `RandomInRange` — the floor is sampled uniformly from `[min, max)` at resolution time; not revealed in advance.

## § API

**Constructors** (public)
- `rest_price_policy::new_fixed(price: Price): RestPricePolicy` — asserts `price > 0`.
- `rest_price_policy::new_random_in_range(min: Price, max: Price): RestPricePolicy` — asserts `min > 0` and `min < max`.

**Projections** (package)
- `rest_price_policy::proj_is_fixed`, `proj_is_random_in_range`
- `rest_price_policy::proj_fixed_price`, `proj_range_min`, `proj_range_max` — each returns `Option<Price>`.

**Computations** (package)
- `rest_price_policy::compute_floor_price(&RestPricePolicy): Price` — returns the deterministic lower bound: fixed price or range min; used in bounds checks without consuming randomness.
- `rest_price_policy::compute_price(&RestPricePolicy, rng: &mut RandomGenerator): Price` — resolves the actual floor; samples from range if `RandomInRange`.

## § INVARIANTS

- `price > 0` and `min > 0` enforced at construction; a zero-price tenure is not representable.
- `compute_floor_price` never consumes randomness; safe to call in view contexts.

## § EVENTS

None.
