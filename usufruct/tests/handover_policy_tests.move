// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::handover_policy_tests;

use usufruct::handover_policy;

#[test]
#[expected_failure(abort_code = handover_policy::EHandoverFloorZero, location = usufruct::handover_policy)]
fun new_handover_countdown_rejects_zero() {
    // Countdown(0) is not allowed; the zero-countdown mode is Instant.
    handover_policy::new_handover_countdown(0);
}
