// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::descent_policy_state_tests;

use std::unit_test::assert_eq;
use usufruct::descent_policy_state::{Self, DescentPolicyState};
use usufruct::phases;

// ─── new_descent_window — abort ───────────────────────────────────────────────

#[test, expected_failure(abort_code = descent_policy_state::EDescentCeilingZero, location = usufruct::descent_policy_state)]
fun new_descent_window_rejects_zero() {
    // Window(0) is not allowed; the zero-ceiling mode is Skipped.
    descent_policy_state::new_descent_window(phases::duration(0));
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
        // phase_start itself, so Demand → Idle in one APT step
        // (spec M6b / Q11).
        HasExpiredCase { policy: descent_policy_state::new_descent_skipped(), phase_start: 100, now: 99,  expected: false }, // before phase
        HasExpiredCase { policy: descent_policy_state::new_descent_skipped(), phase_start: 100, now: 100, expected: true  }, // exact phase
        HasExpiredCase { policy: descent_policy_state::new_descent_skipped(), phase_start: 100, now: 101, expected: true  }, // after phase
        HasExpiredCase { policy: descent_policy_state::new_descent_skipped(), phase_start: 0,   now: 0,   expected: true  }, // zero anchor

        // Window — boundary triple at phase_start + ceiling = 150
        HasExpiredCase { policy: descent_policy_state::new_descent_window(phases::duration(50)), phase_start: 100, now: 149, expected: false }, // one before
        HasExpiredCase { policy: descent_policy_state::new_descent_window(phases::duration(50)), phase_start: 100, now: 150, expected: true  }, // exact
        HasExpiredCase { policy: descent_policy_state::new_descent_window(phases::duration(50)), phase_start: 100, now: 151, expected: true  }, // one after

        // Window with phase_start=0 (boundary == ceiling)
        HasExpiredCase { policy: descent_policy_state::new_descent_window(phases::duration(50)), phase_start: 0, now: 49, expected: false },
        HasExpiredCase { policy: descent_policy_state::new_descent_window(phases::duration(50)), phase_start: 0, now: 50, expected: true  },
    ];
    cases.do_ref!(|c| {
        let mut gen  = sui::random::new_generator_from_seed_for_testing(vector[0u8]);
        let resolved = descent_policy_state::resolve(&c.policy, &mut gen);
        assert_eq!(descent_policy_state::has_expired(resolved, phases::timestamp(c.phase_start), phases::timestamp(c.now)).is_crossed(), c.expected);
    });
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
        ExpiryAtCase { policy: descent_policy_state::new_descent_window(phases::duration(50)),    phase_start: 100, expected: 150 },
        ExpiryAtCase { policy: descent_policy_state::new_descent_window(phases::duration(1)),     phase_start: 0,   expected: 1   },
        ExpiryAtCase { policy: descent_policy_state::new_descent_window(phases::duration(9_999)), phase_start: 1,   expected: 10_000 },
    ];
    cases.do_ref!(|c| {
        let mut gen  = sui::random::new_generator_from_seed_for_testing(vector[0u8]);
        let resolved = descent_policy_state::resolve(&c.policy, &mut gen);
        assert_eq!(phases::timestamp_ms(descent_policy_state::expiry_at(resolved, phases::timestamp(c.phase_start))), c.expected);
    });
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
        let p = descent_policy_state::new_descent_window(phases::duration(c));
        assert_eq!(phases::duration_ms(descent_policy_state::window_ceiling(&p)), c);
        i = i + 1;
    };
}

#[test, expected_failure(abort_code = descent_policy_state::EDescentSkippedNoWindow, location = usufruct::descent_policy_state)]
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
        DeSisterCase { policy: descent_policy_state::new_descent_window(phases::duration(50)), phase_start: 100, now: 149 },
        DeSisterCase { policy: descent_policy_state::new_descent_window(phases::duration(50)), phase_start: 100, now: 150 },
        DeSisterCase { policy: descent_policy_state::new_descent_window(phases::duration(50)), phase_start: 100, now: 151 },

        // Window at zero anchor
        DeSisterCase { policy: descent_policy_state::new_descent_window(phases::duration(50)), phase_start: 0, now: 49 },
        DeSisterCase { policy: descent_policy_state::new_descent_window(phases::duration(50)), phase_start: 0, now: 50 },
    ];
    cases.do_ref!(|c| {
        let mut gen   = sui::random::new_generator_from_seed_for_testing(vector[0u8]);
        let resolved  = descent_policy_state::resolve(&c.policy, &mut gen);
        let bool_view = descent_policy_state::has_expired(resolved, phases::timestamp(c.phase_start), phases::timestamp(c.now)).is_crossed();
        let u64_view  = c.now >= phases::timestamp_ms(descent_policy_state::expiry_at(resolved, phases::timestamp(c.phase_start)));
        assert_eq!(bool_view, u64_view);
    });
}

// ─── RandomInRange — constructors ─────────────────────────────────────────────

#[test, expected_failure(abort_code = descent_policy_state::EDescentCeilingZero, location = usufruct::descent_policy_state)]
fun new_descent_random_in_range_rejects_zero_min() {
    descent_policy_state::new_descent_random_in_range(phases::duration(0), phases::duration(100));
}

#[test, expected_failure(abort_code = descent_policy_state::EMinNotLtMax, location = usufruct::descent_policy_state)]
fun new_descent_random_in_range_rejects_min_eq_max() {
    descent_policy_state::new_descent_random_in_range(phases::duration(50), phases::duration(50));
}

#[test, expected_failure(abort_code = descent_policy_state::EMinNotLtMax, location = usufruct::descent_policy_state)]
fun new_descent_random_in_range_rejects_min_gt_max() {
    descent_policy_state::new_descent_random_in_range(phases::duration(100), phases::duration(50));
}

// ─── RandomInRange — resolve draws in bounds ──────────────────────────────────

#[test]
fun resolve_random_in_range_draws_in_bounds() {
    let min: u64 = 10;
    let max: u64 = 50;
    let policy = descent_policy_state::new_descent_random_in_range(
        phases::duration(min),
        phases::duration(max),
    );
    let seeds = vector[vector[0u8], vector[1u8], vector[2u8], vector[3u8], vector[7u8]];
    let mut i = 0;
    while (i < seeds.length()) {
        let mut gen = sui::random::new_generator_from_seed_for_testing(*seeds.borrow(i));
        let result  = descent_policy_state::resolve(&policy, &mut gen);
        let ms      = phases::duration_ms(result);
        assert!(ms >= min && ms <= max, 0);
        i = i + 1;
    };
}

// ─── RandomInRange — expiry_at is in [phase+min, phase+max] ──────────────────

#[test]
fun random_in_range_expiry_at_within_bounds() {
    let min: u64 = 10;
    let max: u64 = 100;
    let phase_start: u64 = 500;
    let policy = descent_policy_state::new_descent_random_in_range(
        phases::duration(min),
        phases::duration(max),
    );
    let seeds = vector[vector[0u8], vector[1u8], vector[4u8], vector[9u8]];
    let mut i = 0;
    while (i < seeds.length()) {
        let mut gen  = sui::random::new_generator_from_seed_for_testing(*seeds.borrow(i));
        let resolved = descent_policy_state::resolve(&policy, &mut gen);
        let expiry   = phases::timestamp_ms(descent_policy_state::expiry_at(resolved, phases::timestamp(phase_start)));
        assert!(expiry >= phase_start + min, 0);
        assert!(expiry <= phase_start + max, 1);
        i = i + 1;
    };
}

// ─── projectors ──────────────────────────────────────────────────────────────

#[test]
fun projectors_skipped_variant() {
    let p = descent_policy_state::new_descent_skipped();
    assert!(p.proj_is_skipped());
    assert!(!p.proj_is_window());
    assert!(!p.proj_is_random_in_range());
    assert!(p.proj_window_ceiling().is_none());
    assert!(p.proj_range_min().is_none());
    assert!(p.proj_range_max().is_none());
}

#[test]
fun projectors_window_variant() {
    let p = descent_policy_state::new_descent_window(phases::duration(75));
    assert!(!p.proj_is_skipped());
    assert!(p.proj_is_window());
    assert!(!p.proj_is_random_in_range());
    assert_eq!(phases::duration_ms(p.proj_window_ceiling().destroy_some()), 75);
    assert!(p.proj_range_min().is_none());
    assert!(p.proj_range_max().is_none());
}

#[test]
fun projectors_random_in_range_variant() {
    let p = descent_policy_state::new_descent_random_in_range(phases::duration(20), phases::duration(80));
    assert!(!p.proj_is_skipped());
    assert!(!p.proj_is_window());
    assert!(p.proj_is_random_in_range());
    assert!(p.proj_window_ceiling().is_none());
    assert_eq!(phases::duration_ms(p.proj_range_min().destroy_some()), 20);
    assert_eq!(phases::duration_ms(p.proj_range_max().destroy_some()), 80);
}
