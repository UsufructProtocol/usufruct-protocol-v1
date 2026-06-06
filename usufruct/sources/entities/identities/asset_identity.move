// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

module usufruct::asset_identity;

// === Imports ===

// === Errors ===

// === Constants ===

// === Structs ===

public struct AssetIdentity has copy, drop, store { proj_id: ID }

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun proj_id(a: AssetIdentity): ID { a.proj_id }

// === Admin Functions ===

// === Package Functions ===

public(package) fun new(proj_id: ID): AssetIdentity { AssetIdentity { proj_id } }

// === Private Functions ===

// === Test Functions ===
