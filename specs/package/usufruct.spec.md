# usufruct

## § OVERVIEW

Package marker module. Declares the one-time witness `USUFRUCT` that bootstraps the package at deployment: `init` claims a `Publisher` object via `sui::package::claim` and transfers it to the deployer. The `Publisher` is the on-chain proof of authorship for the `usufruct` package — it enables display registration, type introspection, and any future upgrade-authority operations that require package governorship. The module has no runtime logic beyond this single initialisation step.

## § TYPES

```
USUFRUCT   has drop
```
One-time witness. Consumed by `package::claim` in `init`; can never be instantiated again after deployment.

## § API

No public API. The sole entry point is the module initializer.

**Initialization**
- `init(otw: USUFRUCT, ctx: &mut TxContext)` — called once by the Sui runtime at publish time; claims the `Publisher` and transfers it to the transaction sender (the deployer).

## § INVARIANTS

- `USUFRUCT` can only be constructed by the Move runtime at publish time; no public constructor exists.
- Exactly one `Publisher` object is created per deployment.

## § EVENTS

None.
