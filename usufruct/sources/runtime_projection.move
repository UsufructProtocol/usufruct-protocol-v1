// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::runtime_projection;

// === Imports ===

use usufruct::{
    asset::{Self, Asset},
    cap_authorization_state::{Self as cap_auth, CapAuthorizationState},
};

// === cap_authorization_state ===

public fun cap_auth_is_current(a: &CapAuthorizationState): bool { cap_auth::proj_is_current(a) }
public fun cap_auth_is_pending(a: &CapAuthorizationState): bool { cap_auth::proj_is_pending(a) }
public fun cap_auth_is_stale(a: &CapAuthorizationState):   bool { cap_auth::proj_is_stale(a)   }

// === asset ===

public fun asset_asset_id<U: key + store>(self: &Asset<U>): ID {
    asset::proj_asset_id(self)
}

public fun asset_escrow_id<U: key + store>(self: &Asset<U>): ID {
    asset::proj_escrow_id(self)
}

public fun asset_is_available<U: key + store>(self: &Asset<U>): bool {
    asset::proj_is_available(self)
}


