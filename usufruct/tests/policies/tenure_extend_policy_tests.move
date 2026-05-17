// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::tenure_extend_policy_tests;

use usufruct::{
    tenures,
    tenure_extend_policy,
};

// ─── Single — validate ────────────────────────────────────────────────────────

#[test]
fun single_allows_cycles_one() {
    tenure_extend_policy::validate(&tenure_extend_policy::new_single(), tenures::tenures(1));
}

#[test, expected_failure(abort_code = tenure_extend_policy::EMultiCycleNotAllowed, location = usufruct::tenure_extend_policy)]
fun single_rejects_cycles_two() {
    tenure_extend_policy::validate(&tenure_extend_policy::new_single(), tenures::tenures(2));
}

#[test, expected_failure(abort_code = tenure_extend_policy::EMultiCycleNotAllowed, location = usufruct::tenure_extend_policy)]
fun single_rejects_cycles_large() {
    tenure_extend_policy::validate(&tenure_extend_policy::new_single(), tenures::tenures(100));
}

// ─── Multi — validate ─────────────────────────────────────────────────────────

#[test]
fun multi_allows_cycles_one() {
    tenure_extend_policy::validate(&tenure_extend_policy::new_multi(), tenures::tenures(1));
}

#[test]
fun multi_allows_cycles_two() {
    tenure_extend_policy::validate(&tenure_extend_policy::new_multi(), tenures::tenures(2));
}

#[test]
fun multi_allows_cycles_large() {
    tenure_extend_policy::validate(&tenure_extend_policy::new_multi(), tenures::tenures(100));
}

// ─── Projectors ───────────────────────────────────────────────────────────────

#[test]
fun proj_single() {
    let p = tenure_extend_policy::new_single();
    assert!(tenure_extend_policy::proj_is_single(&p),  0);
    assert!(!tenure_extend_policy::proj_is_multi(&p),  1);
}

#[test]
fun proj_multi() {
    let p = tenure_extend_policy::new_multi();
    assert!(!tenure_extend_policy::proj_is_single(&p), 0);
    assert!(tenure_extend_policy::proj_is_multi(&p),   1);
}
