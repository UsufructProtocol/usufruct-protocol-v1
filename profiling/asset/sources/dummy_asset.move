// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module dummy_asset::dummy_asset;

public struct DummyAsset has key, store {
    id: UID,
}

public fun mint(ctx: &mut TxContext): DummyAsset {
    DummyAsset { id: object::new(ctx) }
}

public fun burn(asset: DummyAsset) {
    let DummyAsset { id } = asset;
    id.delete();
}
