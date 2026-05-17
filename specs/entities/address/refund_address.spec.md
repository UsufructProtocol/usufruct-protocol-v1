# refund_address

## § OVERVIEW

A typed wrapper around the raw `address` primitive, used exclusively to record where a tenant's stake should be returned if the rental ends with unspent collateral. Wrapping prevents `address` values from being passed to functions that expect other address roles (owner, protocol, etc.) without an explicit conversion. Stored inside `TenantIdentity`.

## § TYPES

```
RefundAddress { addr: address }   has copy, drop, store
```
The address to which a tenant's remaining stake is liquidated at rental end.

## § API

**Constructors** (package)
- `refund_address::new(addr: address): RefundAddress`
- `refund_address::addr(RefundAddress): address`

## § INVARIANTS

- No validation is applied to the address at construction; the caller is responsible for correctness.

## § EVENTS

None.
