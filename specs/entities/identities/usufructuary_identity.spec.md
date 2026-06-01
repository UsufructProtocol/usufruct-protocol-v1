# usufructuary_identity

## § OVERVIEW

Encapsulates the full identity of a usufructuary: their capability reference and the address where unspent stake is returned. Combining both fields in one type means every operation that needs to identify a usufructuary or refund them receives a single, self-contained value — no separate address passing. Held inside `UsufructuarySeat`.

## § TYPES

```
UsufructuaryIdentity {
    cap_identity: UsufructCapIdentity,
    address:      RefundAddress,
}   has copy, drop, store
```

## § API

**Constructors** (package)
- `usufructuary_identity::new(cap_identity: UsufructCapIdentity, address: RefundAddress): UsufructuaryIdentity`

**Accessors** (package)
- `usufructuary_identity::proj_cap_identity(&UsufructuaryIdentity): UsufructCapIdentity`
- `usufructuary_identity::proj_address(&UsufructuaryIdentity): RefundAddress`

**Mutations** (package)
- `usufructuary_identity::set_address(&mut UsufructuaryIdentity, new: RefundAddress)` — redirects the refund destination.

## § INVARIANTS

- Created at `execute_rent` from the presented `UsufructCap` and the transaction sender's address.
- The `cap_identity` is fixed at creation. The `RefundAddress`, however, may be redirected via `set_address` while the seat is live — the cap holder repoints where the stake refund will land (backs `update_refund_address`).

## § EVENTS

None.
