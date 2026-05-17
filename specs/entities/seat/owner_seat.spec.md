# owner_seat

## § OVERVIEW

Combines the owner's identity with their accumulated earnings into a single value that lives inside `EscrowCore`. The seat is the owner's financial position within a specific escrow: it accumulates proceeds across tenure settlements and allows the owner to withdraw at any time by presenting their `OwnerCap`. Binding the cap check to the `withdraw` operation means the identity never needs to be re-validated elsewhere.

## § TYPES

```
OwnerSeat<CoinType: phantom> {
    identity: OwnerIdentity,
    earnings: OwnerEarnings<CoinType>,
}   has store
```
The owner's identity and accumulated balance for a given coin type. No `copy` or `drop`.

## § API

**Constructors** (package)
- `owner_seat::new<C>(cap_identity: OwnerCapIdentity): OwnerSeat<C>` — initialises with zero earnings.

**Accessors** (package)
- `owner_seat::proj_identity<C>(&OwnerSeat<C>): &OwnerIdentity`
- `owner_seat::proj_value<C>(&OwnerSeat<C>): Stake` — current accumulated balance.

**Mutations** (package)
- `owner_seat::deposit<C>(&mut OwnerSeat<C>, OwnerEarnings<C>)` — merges incoming earnings into the seat.
- `owner_seat::withdraw<C>(&mut OwnerSeat<C>, cap: &OwnerCap, ctx: &mut TxContext): Coin<C>` — drains the full balance to a `Coin<C>`; aborts if `cap` does not match `identity.cap_identity`.

**Destruction** (package)
- `owner_seat::destroy_empty<C>(OwnerSeat<C>)` — asserts earnings are zero before dropping; used at `claim_asset`.

## § INVARIANTS

- Cap binding is validated inside `withdraw`: `cap.identity == seat.identity.cap_identity`; a mismatch aborts.
- `destroy_empty` aborts if any earnings remain, ensuring funds are never silently discarded.

## § EVENTS

None.
