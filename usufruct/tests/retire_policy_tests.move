// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::retire_policy_tests;

use usufruct::retire_policy;

#[test]
#[expected_failure(abort_code = retire_policy::ERetireFloorZero, location = usufruct::retire_policy)]
fun new_retire_deferred_rejects_zero() {
    // Deferred(0) is not allowed; the zero-floor mode is Immediate.
    retire_policy::new_retire_deferred(0);
}
