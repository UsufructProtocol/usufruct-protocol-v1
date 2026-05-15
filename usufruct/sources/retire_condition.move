// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

/// One-way retire flag embedded in Renting-phase tenancy variants.
/// NotRetiring → Retiring is the only legal transition; the reverse aborts.
module usufruct::retire_condition;

// === Imports ===

// === Errors ===

const EAlreadyRetiring: u64 = 0;

// === Constants ===

// === Structs ===

// === Enums ===

public enum RetireCondition has store, drop {
    NotRetiring,
    Retiring,
}

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

public(package) fun new(): RetireCondition { RetireCondition::NotRetiring }

public(package) fun proj_is_retiring(r: &RetireCondition): bool {
    match (r) { RetireCondition::Retiring => true, RetireCondition::NotRetiring => false }
}

public(package) fun set(r: RetireCondition): RetireCondition {
    match (r) {
        RetireCondition::NotRetiring => RetireCondition::Retiring,
        RetireCondition::Retiring    => abort EAlreadyRetiring,
    }
}

// === Private Functions ===

// === Test Functions ===

#[test_only]
public(package) fun set_for_testing(_r: RetireCondition): RetireCondition {
    RetireCondition::Retiring
}
