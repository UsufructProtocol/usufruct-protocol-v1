// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::refund_address_tests;

use std::unit_test::assert_eq;
use usufruct::refund_address;

// ─── §1. Round-trip ───────────────────────────────────────────────────────────

#[test]
fun new_addr_round_trip() {
    let ra = refund_address::new(@0xA1);
    assert_eq!(refund_address::addr(ra), @0xA1);
}

#[test]
fun two_distinct_addresses_are_distinct() {
    let ra_a = refund_address::new(@0xA1);
    let ra_b = refund_address::new(@0xB2);
    assert!(refund_address::addr(ra_a) != refund_address::addr(ra_b), 0);
}
