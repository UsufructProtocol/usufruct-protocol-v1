// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

module usufruct::governor_identity;

// === Imports ===

use usufruct::governance_cap::GovernanceCapIdentity;

// === Errors ===

// === Constants ===

// === Structs ===

public struct GovernorIdentity has copy, drop, store {
    cap_identity: GovernanceCapIdentity,
}

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_cap_identity(id: &GovernorIdentity): GovernanceCapIdentity { id.cap_identity }

// === Admin Functions ===

// === Package Functions ===

public(package) fun new(cap_identity: GovernanceCapIdentity): GovernorIdentity {
    GovernorIdentity { cap_identity }
}

// === Private Functions ===

// === Test Functions ===
