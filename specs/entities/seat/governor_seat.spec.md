# governor_seat

## § OVERVIEW

The governor's record inside an escrow. **Holds no balance**: governor earnings are settled directly to the `EarningsInbox` as `EarningsMessage` objects, never accumulated in the seat. It carries two immutable identities, both set once at `integrate`: `identity` records the governing `GovernanceCap` (so the escrow can authorize governance operations by matching a presented cap), and `inbox` records the permanent earnings destination. The seat is coin-agnostic — no phantom `CoinType`, because it stores no funds.

## § TYPES

```
GovernorSeat {
    identity: GovernorIdentity,
    inbox:    EarningsInboxIdentity,
}   has store
```
The governor's identity plus the earnings-inbox destination. No coin type (it holds no balance). No `copy`/`drop`.

## § API

**Constructors** (package)
- `governor_seat::new(cap_identity: GovernanceCapIdentity, inbox: EarningsInboxIdentity): GovernorSeat` — records the governing cap identity and the permanent earnings destination.

**Accessors** (package)
- `governor_seat::proj_identity(&GovernorSeat): &GovernorIdentity` — the governor's identity (wraps the cap identity).
- `governor_seat::proj_inbox(&GovernorSeat): EarningsInboxIdentity` — the earnings destination; settlement posts `EarningsMessage`s here.

**Destruction** (package)
- `governor_seat::destroy(GovernorSeat)` — drops the seat (no balance to reconcile); called at `claim_asset`.

## § INVARIANTS

- The seat never holds funds. Every governor settlement produces an `EarningsBalance` that is posted as an `EarningsMessage` to `inbox` — the seat is a pair of identities, not an accumulator.
- Both identities are set once at `integrate` and never mutated.
- Authorization: an escrow validates a presented `GovernanceCap` by matching `identity(cap)` against the cap identity recorded in `proj_identity(seat)`.

## § EVENTS

None.
