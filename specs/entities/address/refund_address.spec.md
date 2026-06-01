# refund_address

## § OVERVIEW

A typed wrapper around the raw `address` primitive, used exclusively to record where a usufructuary's stake should be returned if the rental ends with unspent collateral. Wrapping prevents `address` values from being passed to functions that expect other address roles (governor, protocol, etc.) without an explicit conversion. Stored inside `UsufructuaryIdentity`.

## § TYPES

```
RefundAddress { addr: address }   has copy, drop, store
```
The address to which a usufructuary's remaining stake is liquidated at rental end.

## § API

**Constructors** (package)
- `refund_address::new(addr: address): RefundAddress`

**Accessors** (package)
- `refund_address::addr(RefundAddress): address`

**Mutations** (package)
- `refund_address::set(&mut RefundAddress, new: RefundAddress)` — overwrites the wrapped address in place; backs the seat-level refund redirect.

## § INVARIANTS

- No validation is applied to the address at construction; the caller is responsible for correctness.

## § EVENTS

None.
