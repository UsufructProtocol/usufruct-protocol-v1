// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::refund_address;

// === Imports ===

// === Errors ===

// === Constants ===

// === Structs ===

public struct RefundAddress has copy, drop, store { addr: address }

// === Enums ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

public(package) fun addr(r: RefundAddress): address { r.addr }

// === Admin Functions ===

// === Package Functions ===

public(package) fun new(addr: address): RefundAddress { RefundAddress { addr } }

// === Private Functions ===

// === Test Functions ===
