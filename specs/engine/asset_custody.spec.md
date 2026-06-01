# asset_custody

## § OVERVIEW

Manages physical possession of the integrated asset at the boundary between the protocol and the integrator. The asset exists in one of two custody states at all times — and the choice of internal representation for each is deliberate, not arbitrary.

`AssetCustodyLocked` wraps the asset directly as a plain field. There is no `Option`, no extraction path, no way to reach the asset without consuming the entire `Locked` value and converting it to something else. This makes the asset structurally irremovable during the waiting phase: `Locked` custody is a sealed container.

`AssetCustodyOpen` wraps the asset in an `Option<Asset>`. The `Option` is the protocol's model for the borrow/return cycle: `Some` means the asset is inside the escrow, `None` means the usufructuary currently holds it. The asset can enter and exit, but only through the typed `take` and `put` operations — and only one at a time. The compiler guarantees that an `Open` custody value always accounts for the asset, whether it is inside or outside.

## § TYPES

```
AssetCustodyOpen<U: key+store> {
    identity:  EscrowedAssetIdentity,
    available: Option<U>,
}   has store
```
Asset in the renting phase. `identity` carries the paired asset+escrow IDs for return validation. `available` is `Some` when the asset is inside the escrow and `None` while the usufructuary holds it via `borrow_asset`.

```
AssetCustodyLocked<U: key+store> { asset: U }   has store
```
Asset in the waiting phase (Idle, Descent, or Retired). No identity field — there is no active usufructuary to validate against.

## § API

**Constructors** (package)
- `asset_custody::new<U>(asset: U, escrow_identity: EscrowIdentity): AssetCustodyOpen<U>` — creates an `Open` custody; captures `AssetIdentity` from `object::id(&asset)` and pairs it with `escrow_identity`.
- `asset_custody::lock<U>(asset: U): AssetCustodyLocked<U>` — wraps a raw asset into `Locked`; used on transitions into the waiting phase.
- `asset_custody::unlock<U>(AssetCustodyLocked<U>): U` — unwraps back to the raw asset; used before re-wrapping into `Open` on a new renting phase.

**Accessors** (package)
- `asset_custody::proj_asset_id<U>(&AssetCustodyOpen<U>): AssetIdentity`
- `asset_custody::proj_locked_id<U>(&AssetCustodyLocked<U>): ID`
- `asset_custody::proj_is_available<U>(&AssetCustodyOpen<U>): bool`

**Borrow discipline** (package)
- `asset_custody::take<U>(&mut AssetCustodyOpen<U>): U` — extracts the asset (`Option::extract`); aborts if already taken.
- `asset_custody::put<U>(&mut AssetCustodyOpen<U>, asset: U)` — re-inserts the asset (`Option::fill`); aborts if already present.

**Phase transitions** (package)
- `asset_custody::close_tenancy<U>(AssetCustodyOpen<U>): AssetCustodyLocked<U>` — transitions from renting to waiting; extracts the asset from `Option` and wraps it into `Locked`.
- `asset_custody::open_tenancy<U>(AssetCustodyLocked<U>, escrow_identity: EscrowIdentity): AssetCustodyOpen<U>` — transitions from waiting to renting; unlocks the asset and wraps it into a new `Open` custody with a fresh identity pair.
- `asset_custody::unbundle<U>(AssetCustodyOpen<U>): U` — destructures `Open` custody and returns the raw asset; used on `claim_asset` when the escrow is retired.

## § INVARIANTS

- `take` and `put` are mutually exclusive on the same custody value; the `Option` enforces single-holder discipline at runtime.
- `close_tenancy` aborts if the asset is currently borrowed (option is None); the usufructuary must return the asset before the tenure can end.
- The asset's `AssetIdentity` is captured once at `new` and never updated; it is the ground truth for return validation.

## § EVENTS

None.
