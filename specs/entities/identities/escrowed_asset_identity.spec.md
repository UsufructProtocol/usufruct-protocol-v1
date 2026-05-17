# escrowed_asset_identity

## § OVERVIEW

A composite identity that pairs an asset with its escrow context. Carried in `AssetCustodyOpen` and `AssetReceipt` to enable two independent checks: that the asset being returned is the same object that was borrowed (`AssetIdentity`), and that it belongs to the correct escrow (`EscrowIdentity`). Neither component alone is sufficient for both checks.

## § TYPES

```
EscrowedAssetIdentity {
    asset_id:        AssetIdentity,
    escrow_identity: EscrowIdentity,
}   has copy, drop, store
```

## § API

**Constructors** (package)
- `escrowed_asset_identity::new(asset_id: AssetIdentity, escrow_identity: EscrowIdentity): EscrowedAssetIdentity`

**Accessors** (package)
- `escrowed_asset_identity::asset_id(&EscrowedAssetIdentity): AssetIdentity`
- `escrowed_asset_identity::escrow_identity(&EscrowedAssetIdentity): EscrowIdentity`

## § INVARIANTS

- Constructed once at `asset_custody::new` by pairing `asset_identity::new(object::id(&asset))` with the escrow's `EscrowIdentity`.
- Both components must match on `execute_return`; a mismatch aborts the transaction.

## § EVENTS

None.
