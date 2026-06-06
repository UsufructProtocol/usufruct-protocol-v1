// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

/// A minimal `key + store` asset for demonstrating usufruct. It carries its own
/// tiny "ecosystem": holding it lets you `use_asset` to mint a `Coupon` — value
/// extracted from *using* the asset, without owning it. usufruct stores the asset
/// opaquely and never touches these internals; this is the integrator's side.
module dummy_asset::dummy_asset;

use sui::event;

public struct DummyAsset has key, store {
    id:   UID,
    uses: u64,
}

/// The artifact produced by using the asset — a renter keeps these.
public struct Coupon has key, store {
    id:     UID,
    source: ID,
    serial: u64,
}

public struct AssetUsed has copy, drop {
    asset: ID,
    uses:  u64,
}

public fun mint(ctx: &mut TxContext): DummyAsset {
    DummyAsset { id: object::new(ctx), uses: 0 }
}

/// Use the asset while you hold it: bumps its usage counter and mints a `Coupon`
/// you keep. Callable on a borrowed asset inside a single PTB (between
/// `escrow::borrow_asset` and `escrow::return_asset`).
public fun use_asset(asset: &mut DummyAsset, ctx: &mut TxContext): Coupon {
    asset.uses = asset.uses + 1;
    let source = object::id(asset);
    event::emit(AssetUsed { asset: source, uses: asset.uses });
    Coupon { id: object::new(ctx), source, serial: asset.uses }
}

public fun uses(asset: &DummyAsset): u64 { asset.uses }

public fun coupon_source(coupon: &Coupon): ID { coupon.source }

public fun coupon_serial(coupon: &Coupon): u64 { coupon.serial }

public fun burn(asset: DummyAsset) {
    let DummyAsset { id, .. } = asset;
    id.delete();
}

public fun burn_coupon(coupon: Coupon) {
    let Coupon { id, .. } = coupon;
    id.delete();
}
