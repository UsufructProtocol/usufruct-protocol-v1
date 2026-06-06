// Copyright (c) UsufructProtocol
// SPDX-License-Identifier: Apache-2.0

module usufruct::refund;

// === Imports ===

use usufruct::refund_address::{Self, RefundAddress};

// === Errors ===

// === Constants ===

// === Structs ===

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

public fun refund_address(addr: address): RefundAddress { refund_address::new(addr) }

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

// === Private Functions ===

// === Test Functions ===
