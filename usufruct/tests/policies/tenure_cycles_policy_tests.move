// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::tenure_cycles_policy_tests;

use usufruct::{
    cycles,
    tenure_cycles_policy,
};

// ─── Single — validate ────────────────────────────────────────────────────────

#[test]
fun single_allows_cycles_one() {
    tenure_cycles_policy::validate(&tenure_cycles_policy::new_single(), cycles::cycles(1));
}

#[test, expected_failure(abort_code = tenure_cycles_policy::EMultiCycleNotAllowed, location = usufruct::tenure_cycles_policy)]
fun single_rejects_cycles_two() {
    tenure_cycles_policy::validate(&tenure_cycles_policy::new_single(), cycles::cycles(2));
}

#[test, expected_failure(abort_code = tenure_cycles_policy::EMultiCycleNotAllowed, location = usufruct::tenure_cycles_policy)]
fun single_rejects_cycles_large() {
    tenure_cycles_policy::validate(&tenure_cycles_policy::new_single(), cycles::cycles(100));
}

// ─── Multi — validate ─────────────────────────────────────────────────────────

#[test]
fun multi_allows_cycles_one() {
    tenure_cycles_policy::validate(&tenure_cycles_policy::new_multi(), cycles::cycles(1));
}

#[test]
fun multi_allows_cycles_two() {
    tenure_cycles_policy::validate(&tenure_cycles_policy::new_multi(), cycles::cycles(2));
}

#[test]
fun multi_allows_cycles_large() {
    tenure_cycles_policy::validate(&tenure_cycles_policy::new_multi(), cycles::cycles(100));
}

// ─── Projectors ───────────────────────────────────────────────────────────────

#[test]
fun proj_single() {
    let p = tenure_cycles_policy::new_single();
    assert!(tenure_cycles_policy::proj_is_single(&p),  0);
    assert!(!tenure_cycles_policy::proj_is_multi(&p),  1);
}

#[test]
fun proj_multi() {
    let p = tenure_cycles_policy::new_multi();
    assert!(!tenure_cycles_policy::proj_is_single(&p), 0);
    assert!(tenure_cycles_policy::proj_is_multi(&p),   1);
}
