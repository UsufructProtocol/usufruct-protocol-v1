// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::escrow_identity;

// === Imports ===

// === Errors ===

// === Constants ===

// === Structs ===

public struct EscrowIdentity has copy, drop, store { id: ID }

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

public(package) fun new(id: ID): EscrowIdentity { EscrowIdentity { id } }

public(package) fun escrow_id(e: EscrowIdentity): ID { e.id }

// === Private Functions ===

// === Test Functions ===

