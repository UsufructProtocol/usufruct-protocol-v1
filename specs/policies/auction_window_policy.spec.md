# auction_window_policy

## § OVERVIEW

Defines the time window within which `auction_shape` expresses the price descent after a tenure expires without a waiting usufructuary. Because `PriceEscalationPolicy` is monotonically increasing, the acquisition price can drift upward across successive tenancies until it finds no new bids. This policy sets the duration of the correction: exactly how long the market has to re-enter at a descending price. At `t = 0` the price equals the last acquisition price; at `t = ceiling` it reaches the rest floor. The rate of descent within that window is entirely determined by `auction_shape` (`CurveShapePolicy`) — a convex curve drops the price quickly at first then slows near the floor; a concave curve holds the price high and drops sharply at the end. A bid placed at any point in between pays the price at that moment along the descent curve. `Off` means no window is opened — the escrow returns directly to idle at the rest price, discarding the escalated price immediately. A longer window gives the market more time to re-enter at a discount; a shorter window accepts idle sooner.

## § TYPES

```
AuctionWindowPolicy   has copy, drop, store
  Off
  Fixed { ceiling: Duration }
```

- `Off` — no descent phase; on tenure expiry the escrow transitions directly to `Idle` at the floor price.
- `Fixed` — a fixed-length descent phase; price falls along the configured `auction_shape` curve from last acquisition price to floor over `ceiling` milliseconds.

## § API

**Constructors** (package)
- `auction_window_policy::new_descent_off(): AuctionWindowPolicy`
- `auction_window_policy::new_descent_fixed(ceiling: Duration): AuctionWindowPolicy` — asserts `ceiling > 0`.

**Projections** (package)
- `auction_window_policy::proj_is_off`, `proj_is_fixed`
- `auction_window_policy::proj_fixed_ceiling(&AuctionWindowPolicy): Option<Duration>`
- `auction_window_policy::proj_auction_window_policy(&AuctionWindowPolicy): String` — the variant kind string (`"Off"` / `"Fixed"`).
- `auction_window_policy::proj_auction_window_ceiling_ms(&AuctionWindowPolicy): Option<u64>`

**Computations** (package)
- `auction_window_policy::compute_duration(&AuctionWindowPolicy): Duration` — resolves the descent duration (`Duration(0)` for `Off`). Deterministic — no randomness.
- `auction_window_policy::compute_expiry_boundary(resolved: Duration, phase_start: Timestamp, now: Timestamp): Boundary` — whether the descent window has elapsed.
- `auction_window_policy::compute_expiry_at(resolved: Duration, phase_start: Timestamp): Timestamp` — the absolute end of the descent window.

## § INVARIANTS

- `ceiling > 0` enforced at construction; zero-length descent windows are invalid.
- For `Off`, `compute_duration` returns `Duration(0)`; the auction phase is never entered.

## § EVENTS

None.
