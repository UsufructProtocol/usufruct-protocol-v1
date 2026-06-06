// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

module usufruct::usufructuary_identity;

// === Imports ===

use usufruct::{
    refund_address::{Self, RefundAddress},
    usufruct_cap::UsufructCapIdentity,
};

// === Errors ===

// === Constants ===

// === Structs ===

public struct UsufructuaryIdentity has copy, drop, store {
    cap_identity: UsufructCapIdentity,
    address:      RefundAddress,
}

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_cap_identity(id: &UsufructuaryIdentity): UsufructCapIdentity { id.cap_identity }
public(package) fun proj_address(id: &UsufructuaryIdentity):      RefundAddress      { id.address }

// === Admin Functions ===

// === Package Functions ===

public(package) fun new(cap_identity: UsufructCapIdentity, address: RefundAddress): UsufructuaryIdentity {
    UsufructuaryIdentity { cap_identity, address }
}

public(package) fun set_address(id: &mut UsufructuaryIdentity, new: RefundAddress) {
    refund_address::set(&mut id.address, new);
}

// === Private Functions ===

// === Test Functions ===
