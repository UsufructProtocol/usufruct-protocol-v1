// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::descent_policy_tests;

use usufruct::descent_policy;

#[test]
#[expected_failure(abort_code = descent_policy::EDescentCeilingZero, location = usufruct::descent_policy)]
fun new_descent_window_rejects_zero() {
    // Window(0) is not allowed; the zero-ceiling mode is Skipped.
    descent_policy::new_descent_window(0);
}
