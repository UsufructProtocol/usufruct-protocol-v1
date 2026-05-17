# tenant_identity

## § OVERVIEW

Encapsulates the full identity of a tenant: their capability reference and the address where unspent stake is returned. Combining both fields in one type means every operation that needs to identify a tenant or refund them receives a single, self-contained value — no separate address passing. Held inside `TenantSeat`.

## § TYPES

```
TenantIdentity {
    cap_identity: TenantCapIdentity,
    address:      RefundAddress,
}   has copy, drop, store
```

## § API

**Constructors** (package)
- `tenant_identity::new(cap_identity: TenantCapIdentity, address: RefundAddress): TenantIdentity`

**Accessors** (package)
- `tenant_identity::proj_cap_identity(&TenantIdentity): TenantCapIdentity`
- `tenant_identity::proj_address(&TenantIdentity): RefundAddress`

## § INVARIANTS

- Created at `execute_rent` from the presented `TenantCap` and the transaction sender's address.
- `RefundAddress` is never updated after creation; stake is always returned to the address recorded at rent time.

## § EVENTS

None.
