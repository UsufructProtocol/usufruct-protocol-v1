# rest_price_policy

## § OVERVIEW

The price of the asset at rest. When the asset is `Idle` — no active usufructuary and no prior acquisition price in memory — this policy defines the exact price a usufructuary must pay. It is the only price that governs entry from `Idle`; nothing else contributes to or overrides it in that state.

Outside of `Idle`, `RestPricePolicy` plays one secondary role: it is the saturation point of the dutch auction. When the `Descent` phase runs, the price descends from the last acquisition price toward the rest price; no bid can be placed below it.

A fixed rest price gives usufructuaries a predictable minimum cost of entry from idle.

## § TYPES

```
RestPricePolicy   has copy, drop, store
  Fixed { price: Price }
```

- `Fixed` — every tenure starts from the same minimum price.

## § API

**Constructors** (package)
- `rest_price_policy::new_fixed(price: Price): RestPricePolicy` — asserts `price > 0`.

**Projections** (package)
- `rest_price_policy::proj_is_fixed`
- `rest_price_policy::proj_fixed_price(&RestPricePolicy): Option<Price>`
- `rest_price_policy::proj_rest_price_policy(&RestPricePolicy): String` — the variant kind string.
- `rest_price_policy::proj_rest_price_mist(&RestPricePolicy): Option<u64>`

**Computations** (package)
- `rest_price_policy::compute_floor_price(&RestPricePolicy): Price` — the lower bound used in bounds checks.
- `rest_price_policy::compute_price(&RestPricePolicy): Price` — resolves the floor price (deterministic — equals the fixed price).

## § INVARIANTS

- `price > 0` enforced at construction; a zero-price tenure is not representable.
- Resolution is deterministic; `compute_price` is safe to call in view contexts.

## § EVENTS

None.
