// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::unreachable;

// === Imports ===

// === Errors ===

const EInvariantViolation: u64 = 0xDEADC0DE; // 3_735_929_054

// === Constants ===

// === Structs ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

/// Returns the invariant-violation abort code.
///
/// Usage in impossible match arms: `abort unreachable::unreachable()`
/// Usage in internal assertions:   `assert!(cond, unreachable::unreachable())`
///
/// Observable off-chain via `SuiMoveAbort.error_code` in
/// `TransactionBlockEffects` — no event emission is needed.
public(package) fun unreachable(): u64 { EInvariantViolation }

// === Private Functions ===

// === Test Functions ===
