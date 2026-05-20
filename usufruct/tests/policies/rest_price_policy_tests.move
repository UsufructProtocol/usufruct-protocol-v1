// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::rest_price_policy_tests;

use std::unit_test::assert_eq;
use usufruct::rest_price_policy;
use usufruct::monetary;

// ─── projectors — Fixed variant ──────────────────────────────────────────────

#[test]
fun projectors_fixed_variant() {
    let p = rest_price_policy::new_fixed(monetary::price(100));
    assert!(p.proj_is_fixed());
    assert_eq!(monetary::price_mist(p.proj_fixed_price().destroy_some()), 100);
}

