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
    assert_eq!(phases::duration_ms(p.proj_fixed_ceiling().destroy_some()), 100);
}

