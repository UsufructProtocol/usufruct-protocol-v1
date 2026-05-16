// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::tenures_policy_tests;

use usufruct::{
    tenures,
    tenures_policy,
};

// ─── Single — validate ────────────────────────────────────────────────────────

#[test]
fun single_allows_cycles_one() {
    tenures_policy::validate(&tenures_policy::new_single(), tenures::tenures(1));
}

#[test, expected_failure(abort_code = tenures_policy::EMultiCycleNotAllowed, location = usufruct::tenures_policy)]
fun single_rejects_cycles_two() {
    tenures_policy::validate(&tenures_policy::new_single(), tenures::tenures(2));
}

#[test, expected_failure(abort_code = tenures_policy::EMultiCycleNotAllowed, location = usufruct::tenures_policy)]
fun single_rejects_cycles_large() {
    tenures_policy::validate(&tenures_policy::new_single(), tenures::tenures(100));
}

// ─── Multi — validate ─────────────────────────────────────────────────────────

#[test]
fun multi_allows_cycles_one() {
    tenures_policy::validate(&tenures_policy::new_multi(), tenures::tenures(1));
}

#[test]
fun multi_allows_cycles_two() {
    tenures_policy::validate(&tenures_policy::new_multi(), tenures::tenures(2));
}

#[test]
fun multi_allows_cycles_large() {
    tenures_policy::validate(&tenures_policy::new_multi(), tenures::tenures(100));
}

// ─── Projectors ───────────────────────────────────────────────────────────────

#[test]
fun proj_single() {
    let p = tenures_policy::new_single();
    assert!(tenures_policy::proj_is_single(&p),  0);
    assert!(!tenures_policy::proj_is_multi(&p),  1);
}

#[test]
fun proj_multi() {
    let p = tenures_policy::new_multi();
    assert!(!tenures_policy::proj_is_single(&p), 0);
    assert!(tenures_policy::proj_is_multi(&p),   1);
}
