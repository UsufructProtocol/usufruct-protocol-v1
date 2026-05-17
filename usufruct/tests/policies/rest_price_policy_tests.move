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
    assert!(!p.proj_is_random_in_range());
    assert_eq!(monetary::price_mist(p.proj_fixed_price().destroy_some()), 100);
    assert!(p.proj_range_min().is_none());
    assert!(p.proj_range_max().is_none());
}

// ─── projectors — RandomInRange variant ──────────────────────────────────────

#[test]
fun projectors_random_in_range_variant() {
    let p = rest_price_policy::new_random_in_range(monetary::price(50), monetary::price(200));
    assert!(!p.proj_is_fixed());
    assert!(p.proj_is_random_in_range());
    assert!(p.proj_fixed_price().is_none());
    assert_eq!(monetary::price_mist(p.proj_range_min().destroy_some()), 50);
    assert_eq!(monetary::price_mist(p.proj_range_max().destroy_some()), 200);
}
