# refund_state

## § OVERVIEW

Manages how usufructuary stake is routed across the three state transitions that produce a financial settlement. Each transition has a different economic meaning, and `RefundState` encodes exactly which funds go where in each case.

**Tenure expiry** (`do_tenure_expiry`) — the tenure ceiling is crossed and the usufructuary's occupancy ends naturally. The full principal is consumed as credit: 90% goes to the governor, 10% to the protocol fee. Nothing remains for the usufructuary. This always produces `Nothing`.

**Handover** (`do_handover`) — the handover countdown fires while the asset is in `Demand`. Credit is computed only up to the handover boundary — the current usufructuary may not have consumed their full stake. The used portion is split 90/10; any remaining stake is liquidated to the usufructuary's refund address. This produces `Parcial` if stake remains, `Nothing` if it is fully consumed.

**Bid superseded** (`do_supersede_bid`) — a pending usufructuary is displaced by a newer bid before the handover fires and before any credit accrual begins. The full stake is returned to the superseded usufructuary with no protocol fee and no governor earnings. This always produces `Total`.

The `distribute` function consumes the `RefundState` and routes every balance to its correct destination atomically, making it impossible to partially settle a transition.

## § TYPES

```
RefundState<CoinType: phantom>   (no abilities — hot potato)
  Nothing { fee_share: FeeShare<CoinType>, earnings: EarningsBalance<CoinType> }
  Parcial { usufructuary_seat: UsufructuarySeat<CoinType>, fee_share: FeeShare<CoinType>, earnings: EarningsBalance<CoinType> }
  Total   { usufructuary_seat: UsufructuarySeat<CoinType> }
```

- `Nothing` — full credit consumed; fee and governor earnings are distributed, usufructuary receives nothing.
- `Parcial` — partial credit consumed; remaining stake in `usufructuary_seat` is liquidated to the usufructuary's refund address after fee and earnings are routed.
- `Total` — usufructuary is superseded before any credit; full stake returned, no protocol fee, no governor earnings.

## § API

**Constructors** (package)
- `refund_state::nothing<C>(fee_share, earnings): RefundState<C>` — full credit consumed; no usufructuary seat.
- `refund_state::parcial<C>(usufructuary_seat, fee_share, earnings): RefundState<C>` — partial credit; the seat's remaining stake will be refunded.
- `refund_state::total<C>(usufructuary_seat): RefundState<C>` — superseded before any credit; full stake refunded.

**Consumption** (package)
- `refund_state::distribute<C>(RefundState<C>, governor_seat: &GovernorSeat, fee_inbox_identity: FeeInboxIdentity, escrow_identity: EscrowIdentity, ctx: &mut TxContext)` — routes all funds to their destinations:
  - Posts `earnings` to the governor's `EarningsInbox` via `earnings_message::post` (using `governor_seat::proj_inbox`) — **not** accumulated in the seat.
  - Posts `fee_share` to the protocol fee inbox via `fee_message::post`.
  - Liquidates remaining `usufructuary_seat` stake to the usufructuary's refund address via `stake_balance::liquidate`.

## § INVARIANTS

- `RefundState` has no abilities; it is a hot potato — it must be consumed via `distribute` in the same transaction it is created.
- `distribute` is exhaustive and total: every variant accounts for every balance; no funds are silently discarded.
- `from_departing` selects `Parcial` vs `Nothing` based on whether remaining stake > 0; zero-stake seats produce `Nothing`.

## § EVENTS

None.
