// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::pending_transition_state_tests;

use std::unit_test::assert_eq;
use usufruct::pending_transition_state;
use usufruct::phases;

// ─── projectors ──────────────────────────────────────────────────────────────

#[test]
fun projectors_handover_variant() {
    let t = pending_transition_state::handover(phases::timestamp(100));
    assert!(t.proj_is_handover());
    assert!(!t.proj_is_tenure_expiry());
    assert!(!t.proj_is_auction_expiry());
    assert_eq!(phases::timestamp_ms(t.proj_boundary()), 100);
}

#[test]
fun projectors_tenure_variant() {
    let t = pending_transition_state::tenure(phases::timestamp(200));
    assert!(!t.proj_is_handover());
    assert!(t.proj_is_tenure_expiry());
    assert!(!t.proj_is_auction_expiry());
    assert_eq!(phases::timestamp_ms(t.proj_boundary()), 200);
}

#[test]
fun projectors_auction_variant() {
    let t = pending_transition_state::auction(phases::timestamp(300));
    assert!(!t.proj_is_handover());
    assert!(!t.proj_is_tenure_expiry());
    assert!(t.proj_is_auction_expiry());
    assert_eq!(phases::timestamp_ms(t.proj_boundary()), 300);
}
