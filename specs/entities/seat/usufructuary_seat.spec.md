# usufructuary_seat

## § OVERVIEW

Combines a usufructuary's identity with their locked stake into a single value that travels through the state machine. Created at `execute_rent`, carried inside `OccupiedTerms` and `DemandTerms`, and consumed at settlement. The seat is the protocol's unit of usufructuary commitment: identity tells the system who the usufructuary is and where to refund them; stake is the collateral that backs the commitment. Keeping them together prevents partial application (stake without identity, or identity without stake).

## § TYPES

```
UsufructuarySeat<CoinType: phantom> {
    identity: UsufructuaryIdentity,
    stake:    StakeBalance<CoinType>,
}   has store
```
A usufructuary's identity and locked collateral for a given coin type. No `copy` or `drop`.

## § API

**Constructors** (package)
- `usufructuary_seat::new<C>(cap_identity: UsufructCapIdentity, refund: RefundAddress, balance: Balance<C>): UsufructuarySeat<C>`

**Accessors** (package)
- `usufructuary_seat::proj_identity<C>(&UsufructuarySeat<C>): &UsufructuaryIdentity`
- `usufructuary_seat::proj_stake_value<C>(&UsufructuarySeat<C>): Stake` — current locked stake amount.

**Mutations** (package)
- `usufructuary_seat::unbundle<C>(UsufructuarySeat<C>): (UsufructuaryIdentity, StakeBalance<C>)` — destructures the seat into its components; used by `refund_state::distribute` to route funds independently.
- `usufructuary_seat::set_refund_address<C>(&mut UsufructuarySeat<C>, new: RefundAddress)` — redirects where the stake refund will be sent; backs `update_refund_address`.
- `usufructuary_seat::take_fee_share<C>(&mut UsufructuarySeat<C>, amount: Stake, escrow_identity: EscrowIdentity): FeeShare<C>` — splits `amount` mist from stake into a `FeeShare` tagged with the escrow; used during settlement.
- `usufructuary_seat::take_earnings<C>(&mut UsufructuarySeat<C>, amount: Stake): EarningsBalance<C>` — splits `amount` mist from stake into an `EarningsBalance` (the governor's settled share); used during settlement.

## § INVARIANTS

- `take_fee_share` and `take_earnings` reduce `stake` by exactly `amount`; total conservation across both splits plus the eventual `liquidate` call is the caller's responsibility.
- `unbundle` is destructive; after it, neither component can be re-combined into a seat.
- The refund address starts at construction and may be redirected by `set_refund_address` while the seat is live (active or pending).

## § EVENTS

None.
