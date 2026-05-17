// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::owner_identity;

// === Imports ===

use usufruct::owner_cap::OwnerCapIdentity;

// === Errors ===

// === Constants ===

// === Structs ===

public struct OwnerIdentity has copy, drop, store {
    cap_identity: OwnerCapIdentity,
}

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_cap_identity(id: &OwnerIdentity): OwnerCapIdentity { id.cap_identity }

// === Admin Functions ===

// === Package Functions ===

public(package) fun new(cap_identity: OwnerCapIdentity): OwnerIdentity {
    OwnerIdentity { cap_identity }
}

// === Private Functions ===

// === Test Functions ===
