# governor_seat

## § OVERVIEW

Combines the governor's identity with their accumulated earnings into a single value that lives inside `EscrowCore`. The seat is the governor's financial position within a specific escrow: it accumulates proceeds across tenure settlements and allows the governor to withdraw at any time by presenting their `GovernanceCap`. Binding the cap check to the `withdraw` operation means the identity never needs to be re-validated elsewhere.

## § TYPES

```
GovernorSeat<CoinType: phantom> {
    identity: GovernorIdentity,
    earnings: EarningsBalance<CoinType>,
}   has store
```
The governor's identity and accumulated balance for a given coin type. No `copy` or `drop`.

## § API

**Constructors** (package)
- `governor_seat::new<C>(cap_identity: GovernanceCapIdentity): GovernorSeat<C>` — initialises with zero earnings.

**Accessors** (package)
- `governor_seat::proj_identity<C>(&GovernorSeat<C>): &GovernorIdentity`
- `governor_seat::proj_value<C>(&GovernorSeat<C>): Stake` — current accumulated balance.

**Mutations** (package)
- `governor_seat::deposit<C>(&mut GovernorSeat<C>, EarningsBalance<C>)` — merges incoming earnings into the seat.
- `governor_seat::withdraw<C>(&mut GovernorSeat<C>, cap: &GovernanceCap, ctx: &mut TxContext): Coin<C>` — drains the full balance to a `Coin<C>`; aborts if `cap` does not match `identity.cap_identity`.

**Destruction** (package)
- `governor_seat::destroy_empty<C>(GovernorSeat<C>)` — asserts earnings are zero before dropping; used at `claim_asset`.

## § INVARIANTS

- Cap binding is validated inside `withdraw`: `cap.identity == seat.identity.cap_identity`; a mismatch aborts.
- `destroy_empty` aborts if any earnings remain, ensuring funds are never silently discarded.

## § EVENTS

None.
