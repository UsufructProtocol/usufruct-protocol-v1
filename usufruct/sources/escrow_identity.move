// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

/// Typed identity of an `Escrow` on-chain object.
///
/// Wraps the raw `ID` so the compiler distinguishes it from
/// `protocol_fee_ref::FeeInboxIdentity` — making it impossible to route an
/// `EscrowIdentity` to `fee_message::post` or vice versa.
///
/// Lives in its own leaf module (no usufruct imports) so any module in
/// the package can import it without creating dependency cycles.
module usufruct::escrow_identity;

// === Imports ===

// === Structs ===

public struct EscrowIdentity has copy, drop, store { id: ID }

// === Package Functions ===

/// Construct an `EscrowIdentity` from the raw `ID` of an `Escrow` object.
public(package) fun new(id: ID): EscrowIdentity { EscrowIdentity { id } }

/// Extract the raw `ID` from an `EscrowIdentity`.
public(package) fun escrow_id(e: EscrowIdentity): ID { e.id }
