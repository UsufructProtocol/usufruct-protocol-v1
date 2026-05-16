// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::tenant_identity_tests;

use std::unit_test::assert_eq;
use usufruct::{
    refund_address,
    tenant_cap,
    tenant_identity,
};

// ─── Fixtures ──────────────────────────────────────────────────────────────────

const ADDR: address = @0xA1;

fun cap_id(): tenant_cap::TenantCapIdentity { tenant_cap::from_id(object::id_from_address(@0xCA1)) }
fun ra(addr: address): refund_address::RefundAddress { refund_address::new(addr) }

// ─── §1. Constructor and accessors ───────────────────────────────────────────

#[test]
fun new_proj_cap_identity_round_trip() {
    let ci = cap_id();
    let ti = tenant_identity::new(ci, ra(ADDR));
    assert_eq!(tenant_identity::proj_cap_identity(&ti), ci);
}

#[test]
fun new_proj_address_round_trip() {
    let ti = tenant_identity::new(cap_id(), ra(ADDR));
    assert_eq!(tenant_identity::proj_address(&ti), ra(ADDR));
}

#[test]
fun two_addresses_stored_independently() {
    let ti_a = tenant_identity::new(cap_id(), ra(@0xA1));
    let ti_b = tenant_identity::new(cap_id(), ra(@0xB2));
    assert!(tenant_identity::proj_address(&ti_a) != tenant_identity::proj_address(&ti_b), 0);
}

#[test]
fun two_cap_ids_stored_independently() {
    let ci_a = tenant_cap::from_id(object::id_from_address(@0xCA1));
    let ci_b = tenant_cap::from_id(object::id_from_address(@0xCA2));
    let ti_a = tenant_identity::new(ci_a, ra(ADDR));
    let ti_b = tenant_identity::new(ci_b, ra(ADDR));
    assert!(tenant_identity::proj_cap_identity(&ti_a) != tenant_identity::proj_cap_identity(&ti_b), 0);
}
