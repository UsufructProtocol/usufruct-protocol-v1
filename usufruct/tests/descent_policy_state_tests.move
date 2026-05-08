// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::descent_policy_state_tests;

use std::unit_test::assert_eq;
use usufruct::descent_policy_state::{Self, DescentPolicyState};
use usufruct::phases;

// ─── new_descent_window — abort ───────────────────────────────────────────────

#[test]
#[expected_failure(abort_code = descent_policy_state::EDescentCeilingZero, location = usufruct::descent_policy_state)]
fun new_descent_window_rejects_zero() {
    // Window(0) is not allowed; the zero-ceiling mode is Skipped.
    descent_policy_state::new_descent_window(0);
}

// ─── has_expired ──────────────────────────────────────────────────────────────

#[test_only]
public struct HasExpiredCase has drop {
    policy:      DescentPolicyState,
    phase_start: u64,
    now:         u64,
    expected:    bool,
}

#[test]
fun has_expired_table() {
    let cases = vector[
        // Skipped — fires from `phase_start` onward (defensively monotone).
        // The auction never has a real window: the boundary collapses to
        // phase_start itself, so HandoverConfirmed → Idle in one APT step
        // (spec M6b / Q11).
        HasExpiredCase { policy: descent_policy_state::new_descent_skipped(), phase_start: 100, now: 99,  expected: false }, // before phase
        HasExpiredCase { policy: descent_policy_state::new_descent_skipped(), phase_start: 100, now: 100, expected: true  }, // exact phase
        HasExpiredCase { policy: descent_policy_state::new_descent_skipped(), phase_start: 100, now: 101, expected: true  }, // after phase
        HasExpiredCase { policy: descent_policy_state::new_descent_skipped(), phase_start: 0,   now: 0,   expected: true  }, // zero anchor

        // Window — boundary triple at phase_start + ceiling = 150
        HasExpiredCase { policy: descent_policy_state::new_descent_window(50), phase_start: 100, now: 149, expected: false }, // one before
        HasExpiredCase { policy: descent_policy_state::new_descent_window(50), phase_start: 100, now: 150, expected: true  }, // exact
        HasExpiredCase { policy: descent_policy_state::new_descent_window(50), phase_start: 100, now: 151, expected: true  }, // one after

        // Window with phase_start=0 (boundary == ceiling)
        HasExpiredCase { policy: descent_policy_state::new_descent_window(50), phase_start: 0, now: 49, expected: false },
        HasExpiredCase { policy: descent_policy_state::new_descent_window(50), phase_start: 0, now: 50, expected: true  },
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let c = &cases[i];
        assert_eq!(descent_policy_state::has_expired(&c.policy, phases::timestamp(c.phase_start), phases::timestamp(c.now)).is_crossed(), c.expected);
        i = i + 1;
    };
}

// ─── expiry_at ────────────────────────────────────────────────────────────────

#[test_only]
public struct ExpiryAtCase has drop {
    policy:      DescentPolicyState,
    phase_start: u64,
    expected:    u64,
}

#[test]
fun expiry_at_table() {
    let cases = vector[
        // Skipped — returns phase_start itself (boundary collapses)
        ExpiryAtCase { policy: descent_policy_state::new_descent_skipped(), phase_start: 0,   expected: 0   },
        ExpiryAtCase { policy: descent_policy_state::new_descent_skipped(), phase_start: 100, expected: 100 },

        // Window — returns phase_start + ceiling
        ExpiryAtCase { policy: descent_policy_state::new_descent_window(50),    phase_start: 100, expected: 150 },
        ExpiryAtCase { policy: descent_policy_state::new_descent_window(1),     phase_start: 0,   expected: 1   },
        ExpiryAtCase { policy: descent_policy_state::new_descent_window(9_999), phase_start: 1,   expected: 10_000 },
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let c = &cases[i];
        assert_eq!(phases::timestamp_ms(descent_policy_state::expiry_at(&c.policy, phases::timestamp(c.phase_start))), c.expected);
        i = i + 1;
    };
}

// ─── window_ceiling ───────────────────────────────────────────────────────────

#[test]
fun window_ceiling_returns_ceiling_for_window() {
    // Identity property: ceiling out == ceiling in.
    let ceilings: vector<u64> = vector[1, 50, 9_999, 1_000_000_000];
    let mut i = 0;
    let len = ceilings.length();
    while (i < len) {
        let c = ceilings[i];
        let p = descent_policy_state::new_descent_window(c);
        assert_eq!(phases::duration_ms(descent_policy_state::window_ceiling(&p)), c);
        i = i + 1;
    };
}

#[test]
#[expected_failure(abort_code = descent_policy_state::EDescentSkippedNoWindow, location = usufruct::descent_policy_state)]
fun window_ceiling_aborts_on_skipped() {
    // window_ceiling on Skipped is unreachable in production
    // (compute_price_descent only fires from AtDutchAuction, structurally
    // unobservable under Skipped). This pins the abort code as the
    // contract — anyone calling it directly gets a deterministic failure.
    let p = descent_policy_state::new_descent_skipped();
    descent_policy_state::window_ceiling(&p);
}

// ─── sister identity: has_expired ⇔ now >= expiry_at ──────────────────────────

#[test_only]
public struct DeSisterCase has drop {
    policy:      DescentPolicyState,
    phase_start: u64,
    now:         u64,
}

// Architectural invariant: bool view (has_expired) and u64 view (expiry_at)
// agree on every (variant, input) combination. After the vacuous-variant
// refactor (Skipped now gates via phases::has_passed), the identity holds
// unconditionally — no clock-monotone precondition needed.
#[test]
fun has_expired_iff_now_ge_expiry_at() {
    let cases = vector[
        // Skipped — boundary triple at phase_start
        DeSisterCase { policy: descent_policy_state::new_descent_skipped(), phase_start: 100, now: 99  },
        DeSisterCase { policy: descent_policy_state::new_descent_skipped(), phase_start: 100, now: 100 },
        DeSisterCase { policy: descent_policy_state::new_descent_skipped(), phase_start: 100, now: 101 },
        DeSisterCase { policy: descent_policy_state::new_descent_skipped(), phase_start: 0,   now: 0   },

        // Window — boundary triple at phase_start + ceiling = 150
        DeSisterCase { policy: descent_policy_state::new_descent_window(50), phase_start: 100, now: 149 },
        DeSisterCase { policy: descent_policy_state::new_descent_window(50), phase_start: 100, now: 150 },
        DeSisterCase { policy: descent_policy_state::new_descent_window(50), phase_start: 100, now: 151 },

        // Window at zero anchor
        DeSisterCase { policy: descent_policy_state::new_descent_window(50), phase_start: 0, now: 49 },
        DeSisterCase { policy: descent_policy_state::new_descent_window(50), phase_start: 0, now: 50 },
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let c = &cases[i];
        let bool_view = descent_policy_state::has_expired(&c.policy, phases::timestamp(c.phase_start), phases::timestamp(c.now)).is_crossed();
        let u64_view  = c.now >= phases::timestamp_ms(descent_policy_state::expiry_at(&c.policy, phases::timestamp(c.phase_start)));
        assert_eq!(bool_view, u64_view);
        i = i + 1;
    };
}
