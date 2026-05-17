# asset_identity

## § OVERVIEW

A typed wrapper around the `ID` of the integrated asset object. Gives asset references a named type that cannot be confused with other object IDs (escrow ID, cap IDs) in function signatures. Produced when an asset enters custody and carried in `EscrowedAssetIdentity` and `AssetCustodyOpen` for the lifetime of the escrow.

## § TYPES

```
AssetIdentity { proj_id: ID }   has copy, drop, store
```
The on-chain object ID of the asset under management.

## § API

**Constructors** (package)
- `asset_identity::new(id: ID): AssetIdentity`
- `asset_identity::proj_id(AssetIdentity): ID`

## § INVARIANTS

- Identity is set once at custody creation from `object::id(&asset)` and never mutated.

## § EVENTS

None.
