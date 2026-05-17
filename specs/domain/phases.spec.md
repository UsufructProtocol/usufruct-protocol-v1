# phases

## § OVERVIEW

Provides the time primitives used throughout the protocol: `Timestamp` (wall-clock position in milliseconds) and `Duration` (elapsed interval). Also defines `Boundary` — a discriminated union that describes whether a deadline has been crossed — enabling stateless deadline evaluation given any `now`. The single public function `phases::now(clock)` is the protocol's only point of contact with the Sui clock; all other deadline logic is pure given a `Timestamp`.

## § TYPES

```
Timestamp { ms: u64 }   has copy, drop, store
```
Absolute position on the millisecond wall clock. Produced by `now(clock)` or recovered from stored anchor fields.

```
Duration { ms: u64 }   has copy, drop, store
```
A non-negative interval in milliseconds. Expresses tenure ceilings, handover countdowns, and auction windows.

```
Boundary   has copy, drop
  Pending { remaining: Duration }
  Crossed { overdue: Duration }
```
Result of comparing `anchor + duration` against `now`. `Pending` means the deadline is still in the future; `Crossed` means it has passed by `overdue` milliseconds. Callers use this to decide whether to trigger a state transition.

## § API

**Public**
- `phases::now(clock: &Clock): Timestamp` — reads current time from the Sui clock; the sole clock access point in the protocol.

**Constructors** (package)
- `phases::timestamp(ms: u64): Timestamp`
- `phases::duration(ms: u64): Duration`
- `phases::zero(): Duration`

**Accessors** (package)
- `phases::timestamp_ms(Timestamp): u64`
- `phases::duration_ms(Duration): u64`
- `phases::proj_is_crossed(&Boundary): bool`

**Computations** (package)
- `phases::compute_boundary(anchor: Timestamp, d: Duration, now: Timestamp): Boundary` — compares `anchor + d` to `now`; produces `Pending` or `Crossed`.
- `phases::compute_elapsed(start: Timestamp, now: Timestamp): Duration` — `now − start`; saturates at zero if `start > now`.
- `phases::compute_boundary_at(anchor: Timestamp, d: Duration): Timestamp` — `anchor + d`; the deadline as an absolute point.
- `phases::compute_earliest(Timestamp, Timestamp): Timestamp` — minimum of two timestamps.

## § INVARIANTS

- `now()` is the only function that reads the Sui clock; all deadline logic downstream is deterministic given a `Timestamp`.
- `compute_elapsed` saturates at zero rather than aborting when `start > now`.
- No wrap-around protection on u64 timestamp arithmetic beyond standard Move overflow abort.

## § EVENTS

None.
