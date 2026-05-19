# auction_window_policy

## § OVERVIEW

Defines the time window within which `auction_shape` expresses the price descent after a tenure expires without a waiting tenant. Because `PriceEscalationPolicy` is monotonically increasing, the acquisition price can drift upward across successive tenancies until it finds no new bids. This policy sets the duration of the correction: exactly how long the market has to re-enter at a descending price. At `t = 0` the price equals the last acquisition price; at `t = ceiling` it reaches the rest floor. The rate of descent within that window is entirely determined by `auction_shape` (`CurveShapePolicy`) — a convex curve drops the price quickly at first then slows near the floor; a concave curve holds the price high and drops sharply at the end. A bid placed at any point in between pays the price at that moment along the descent curve. `Skipped` means no window is opened — the escrow returns directly to idle at the rest price, discarding the escalated price immediately. A longer window gives the market more time to re-enter at a discount; a shorter window accepts idle sooner.

## § TYPES

```
AuctionWindowPolicy   has copy, drop, store
  Skipped
  Fixed         { ceiling: Duration }
  RandomInRange { min: Duration, max: Duration }
```

- `Skipped` — no descent phase; on tenure expiry the escrow transitions directly to `Idle` at the floor price.
- `Fixed` — a fixed-length descent phase; price falls linearly (or along the configured `auction_shape` curve) from last acquisition price to floor over `ceiling` milliseconds.
- `RandomInRange` — descent duration is sampled uniformly from `[min, max)` at transition time; the resolved duration is not revealed in advance.

## § API

**Constructors** (public)
- `auction_window_policy::new_descent_skipped(): AuctionWindowPolicy`
- `auction_window_policy::new_descent_fixed(ceiling: Duration): AuctionWindowPolicy` — asserts `ceiling > 0`.
- `auction_window_policy::new_descent_random_in_range(min: Duration, max: Duration): AuctionWindowPolicy` — asserts `min > 0` and `min < max`.

**Projections** (package)
- `auction_window_policy::proj_is_skipped`, `proj_is_fixed`, `proj_is_random_in_range`
- `auction_window_policy::proj_fixed_ceiling`, `proj_range_min`, `proj_range_max` — each returns `Option<Duration>`.

**Computations** (package)
- `auction_window_policy::compute_duration(&AuctionWindowPolicy, rng: &mut RandomGenerator): Duration` — resolves the descent duration; samples from range if `RandomInRange`.
- `auction_window_policy::compute_expiry_boundary(resolved: Duration, phase_start: Timestamp, now: Timestamp): Boundary` — whether the descent window has elapsed.
- `auction_window_policy::compute_expiry_at(resolved: Duration, phase_start: Timestamp): Timestamp` — the absolute end of the descent window.

## § INVARIANTS

- `ceiling > 0` and `min < max` enforced at construction; zero-length or inverted ranges are invalid.
- For `Skipped`, `compute_duration` returns `Duration(0)`; the auction phase is never entered.

## § EVENTS

None.
