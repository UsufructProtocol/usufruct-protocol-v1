# tenant_seat

## § OVERVIEW

Combines a tenant's identity with their locked stake into a single value that travels through the state machine. Created at `execute_rent`, carried inside `OccupiedTerms` and `DemandTerms`, and consumed at settlement. The seat is the protocol's unit of tenant commitment: identity tells the system who the tenant is and where to refund them; stake is the collateral that backs the commitment. Keeping them together prevents partial application (stake without identity, or identity without stake).

## § TYPES

```
TenantSeat<CoinType: phantom> {
    identity: TenantIdentity,
    stake:    TenantStake<CoinType>,
}   has store
```
A tenant's identity and locked collateral for a given coin type. No `copy` or `drop`.

## § API

**Constructors** (package)
- `tenant_seat::new<C>(cap_identity: TenantCapIdentity, address: address, balance: Balance<C>): TenantSeat<C>`

**Accessors** (package)
- `tenant_seat::proj_identity<C>(&TenantSeat<C>): &TenantIdentity`
- `tenant_seat::proj_stake_value<C>(&TenantSeat<C>): Stake` — current locked stake amount.

**Mutations** (package)
- `tenant_seat::unbundle<C>(TenantSeat<C>): (TenantIdentity, TenantStake<C>)` — destructures the seat into its components; used by `refund_state::distribute` to route funds independently.
- `tenant_seat::take_fee_share<C>(&mut TenantSeat<C>, amount: Stake, escrow_identity: EscrowIdentity): FeeShare<C>` — splits `amount` mist from stake into a `FeeShare` tagged with the escrow; used during settlement.
- `tenant_seat::take_owner_earnings<C>(&mut TenantSeat<C>, amount: Stake): OwnerEarnings<C>` — splits `amount` mist from stake into owner earnings; used during settlement.

## § INVARIANTS

- `take_fee_share` and `take_owner_earnings` reduce `stake` by exactly `amount`; total conservation across both splits plus the eventual `liquidate` call is the caller's responsibility.
- `unbundle` is destructive; after it, neither component can be re-combined into a seat.
- The refund address is fixed at construction and never updated.

## § EVENTS

None.
