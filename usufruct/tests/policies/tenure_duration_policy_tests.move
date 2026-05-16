// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::tenure_duration_policy_tests;

use std::unit_test::assert_eq;
use usufruct::tenure_duration_policy;
use usufruct::phases;

// ─── projectors — Fixed variant ──────────────────────────────────────────────

#[test]
fun projectors_fixed_variant() {
    let p = tenure_duration_policy::new_fixed(phases::duration(100));
    assert!(p.proj_is_fixed());
    assert!(!p.proj_is_random_in_range());
    assert_eq!(phases::duration_ms(p.proj_fixed_ceiling().destroy_some()), 100);
    assert!(p.proj_range_min().is_none());
    assert!(p.proj_range_max().is_none());
}

// ─── projectors — RandomInRange variant ──────────────────────────────────────

#[test]
fun projectors_random_in_range_variant() {
    let p = tenure_duration_policy::new_random_in_range(phases::duration(50), phases::duration(200));
    assert!(!p.proj_is_fixed());
    assert!(p.proj_is_random_in_range());
    assert!(p.proj_fixed_ceiling().is_none());
    assert_eq!(phases::duration_ms(p.proj_range_min().destroy_some()), 50);
    assert_eq!(phases::duration_ms(p.proj_range_max().destroy_some()), 200);
}
