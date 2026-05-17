// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::asset_identity;

// === Imports ===

// === Errors ===

// === Constants ===

// === Structs ===

public struct AssetIdentity has copy, drop, store { id: ID }

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun id(a: AssetIdentity): ID { a.id }

// === Admin Functions ===

// === Package Functions ===

public(package) fun new(id: ID): AssetIdentity { AssetIdentity { id } }

// === Private Functions ===

// === Test Functions ===
