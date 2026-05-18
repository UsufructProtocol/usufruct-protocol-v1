# refund_state

## § OVERVIEW

Manages how tenant stake is routed across the three state transitions that produce a financial settlement. Each transition has a different economic meaning, and `RefundState` encodes exactly which funds go where in each case.

**Tenure expiry** (`do_tenure_expiry`) — the tenure ceiling is crossed and the tenant's occupancy ends naturally. The full principal is consumed as credit: 90% goes to the owner, 10% to the protocol fee. Nothing remains for the tenant. This always produces `Nothing`.

**Handover** (`do_handover`) — the handover countdown fires while the asset is in `Demand`. Credit is computed only up to the handover boundary — the current tenant may not have consumed their full stake. The used portion is split 90/10; any remaining stake is liquidated to the tenant's refund address. This produces `Parcial` if stake remains, `Nothing` if it is fully consumed.

**Bid superseded** (`do_supersede_bid`) — a pending tenant is displaced by a newer bid before the handover fires and before any credit accrual begins. The full stake is returned to the superseded tenant with no protocol fee and no owner earnings. This always produces `Total`.

The `distribute` function consumes the `RefundState` and routes every balance to its correct destination atomically, making it impossible to partially settle a transition.

## § TYPES

```
RefundState<CoinType: phantom>   (no abilities — hot potato)
  Nothing { fee_share: FeeShare<CoinType>, owner_earnings: OwnerEarnings<CoinType> }
  Parcial { seat: TenantSeat<CoinType>, fee_share: FeeShare<CoinType>, owner_earnings: OwnerEarnings<CoinType> }
  Total   { seat: TenantSeat<CoinType> }
```

- `Nothing` — full credit consumed; fee and owner earnings are distributed, tenant receives nothing.
- `Parcial` — partial credit consumed; remaining stake in `seat` is liquidated to the tenant's refund address after fee and earnings are routed.
- `Total` — tenant is superseded before any credit; full stake returned, no protocol fee, no owner earnings.

## § API

**Constructors** (package)
- `refund_state::nothing<C>(fee_share, owner_earnings): RefundState<C>`
- `refund_state::parcial<C>(seat, fee_share, owner_earnings): RefundState<C>`
- `refund_state::total<C>(seat): RefundState<C>`
- `refund_state::from_superseded<C>(pending: TenantSeat<C>): RefundState<C>` — always produces `Total`; used when a pending bid is replaced by a newer bid via `do_supersede_bid`.
- `refund_state::from_departing<C>(departing: TenantSeat<C>, fee_share, owner_earnings): RefundState<C>` — produces `Parcial` if the seat has remaining stake, `Nothing` otherwise; used when a current tenant's tenure ends normally.

**Consumption** (package)
- `refund_state::distribute<C>(RefundState<C>, owner: &mut OwnerSeat<C>, fee_inbox_identity: FeeInboxIdentity, ctx: &mut TxContext)` — routes all funds to their destinations:
  - Deposits `owner_earnings` into `owner` via `owner_seat::deposit`.
  - Posts `fee_share` to the fee inbox via `fee_message::post`.
  - Liquidates remaining `seat` stake to the tenant's refund address via `tenant_stake::liquidate`.

## § INVARIANTS

- `RefundState` has no abilities; it is a hot potato — it must be consumed via `distribute` in the same transaction it is created.
- `distribute` is exhaustive and total: every variant accounts for every balance; no funds are silently discarded.
- `from_departing` selects `Parcial` vs `Nothing` based on whether remaining stake > 0; zero-stake seats produce `Nothing`.

## § EVENTS

None.
