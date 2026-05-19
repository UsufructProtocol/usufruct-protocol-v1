// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::auction_window_policy_tests;

use std::unit_test::assert_eq;
use usufruct::auction_window_policy::{Self, AuctionWindowPolicy};
use usufruct::phases;

// ─── new_descent_fixed — abort ───────────────────────────────────────────────

#[test, expected_failure(abort_code = auction_window_policy::EDescentCeilingZero, location = usufruct::auction_window_policy)]
fun new_descent_fixed_rejects_zero() {
    // Window(0) is not allowed; the zero-ceiling mode is Skipped.
    auction_window_policy::new_descent_fixed(phases::duration(0));
}

// ─── compute_expiry_boundary ──────────────────────────────────────────────────────────────

#[test_only]
public struct HasExpiredCase has drop {
    policy:      AuctionWindowPolicy,
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
        HasExpiredCase { policy: auction_window_policy::new_descent_off(), phase_start: 100, now: 99,  expected: false }, // before phase
        HasExpiredCase { policy: auction_window_policy::new_descent_off(), phase_start: 100, now: 100, expected: true  }, // exact phase
        HasExpiredCase { policy: auction_window_policy::new_descent_off(), phase_start: 100, now: 101, expected: true  }, // after phase
        HasExpiredCase { policy: auction_window_policy::new_descent_off(), phase_start: 0,   now: 0,   expected: true  }, // zero anchor

        // Fixed — boundary triple at phase_start + ceiling = 150
        HasExpiredCase { policy: auction_window_policy::new_descent_fixed(phases::duration(50)), phase_start: 100, now: 149, expected: false }, // one before
        HasExpiredCase { policy: auction_window_policy::new_descent_fixed(phases::duration(50)), phase_start: 100, now: 150, expected: true  }, // exact
        HasExpiredCase { policy: auction_window_policy::new_descent_fixed(phases::duration(50)), phase_start: 100, now: 151, expected: true  }, // one after

        // Window with phase_start=0 (boundary == ceiling)
        HasExpiredCase { policy: auction_window_policy::new_descent_fixed(phases::duration(50)), phase_start: 0, now: 49, expected: false },
        HasExpiredCase { policy: auction_window_policy::new_descent_fixed(phases::duration(50)), phase_start: 0, now: 50, expected: true  },
    ];
    cases.do_ref!(|c| {
        let mut gen  = sui::random::new_generator_from_seed_for_testing(vector[0u8]);
        let resolved = auction_window_policy::compute_duration(&c.policy, &mut gen);
        assert_eq!(auction_window_policy::compute_expiry_boundary(resolved, phases::timestamp(c.phase_start), phases::timestamp(c.now)).proj_is_crossed(), c.expected);
    });
}

// ─── compute_expiry_at ────────────────────────────────────────────────────────────────

#[test_only]
public struct ExpiryAtCase has drop {
    policy:      AuctionWindowPolicy,
    phase_start: u64,
    expected:    u64,
}

#[test]
fun expiry_at_table() {
    let cases = vector[
        // Skipped — returns phase_start itself (boundary collapses)
        ExpiryAtCase { policy: auction_window_policy::new_descent_off(), phase_start: 0,   expected: 0   },
        ExpiryAtCase { policy: auction_window_policy::new_descent_off(), phase_start: 100, expected: 100 },

        // Fixed — returns phase_start + ceiling
        ExpiryAtCase { policy: auction_window_policy::new_descent_fixed(phases::duration(50)),    phase_start: 100, expected: 150 },
        ExpiryAtCase { policy: auction_window_policy::new_descent_fixed(phases::duration(1)),     phase_start: 0,   expected: 1   },
        ExpiryAtCase { policy: auction_window_policy::new_descent_fixed(phases::duration(9_999)), phase_start: 1,   expected: 10_000 },
    ];
    cases.do_ref!(|c| {
        let mut gen  = sui::random::new_generator_from_seed_for_testing(vector[0u8]);
        let resolved = auction_window_policy::compute_duration(&c.policy, &mut gen);
        assert_eq!(phases::timestamp_ms(auction_window_policy::compute_expiry_at(resolved, phases::timestamp(c.phase_start))), c.expected);
    });
}

// ─── fixed_ceiling ───────────────────────────────────────────────────────────

#[test]
fun fixed_ceiling_returns_ceiling_for_window() {
    // Identity property: ceiling out == ceiling in.
    let ceilings: vector<u64> = vector[1, 50, 9_999, 1_000_000_000];
    let mut i = 0;
    let len = ceilings.length();
    while (i < len) {
        let c = ceilings[i];
        let p = auction_window_policy::new_descent_fixed(phases::duration(c));
        assert_eq!(phases::duration_ms(auction_window_policy::fixed_ceiling(&p)), c);
        i = i + 1;
    };
}

#[test, expected_failure(abort_code = auction_window_policy::EDescentOffNoFixed, location = usufruct::auction_window_policy)]
fun fixed_ceiling_aborts_on_skipped() {
    // fixed_ceiling on Skipped is unreachable in production
    // (compute_price_descent only fires from AtDutchAuction, structurally
    // unobservable under Skipped). This pins the abort code as the
    // contract — anyone calling it directly gets a deterministic failure.
    let p = auction_window_policy::new_descent_off();
    auction_window_policy::fixed_ceiling(&p);
}

// ─── sister identity: compute_expiry_boundary ⇔ now >= compute_expiry_at ──────────────────────────

#[test_only]
public struct DeSisterCase has drop {
    policy:      AuctionWindowPolicy,
    phase_start: u64,
    now:         u64,
}

// Architectural invariant: bool view (compute_expiry_boundary) and u64 view (compute_expiry_at)
// agree on every (variant, input) combination. After the vacuous-variant
// refactor (Skipped now gates via phases::has_passed), the identity holds
// unconditionally — no clock-monotone precondition needed.
#[test]
fun has_expired_iff_now_ge_expiry_at() {
    let cases = vector[
        // Skipped — boundary triple at phase_start
        DeSisterCase { policy: auction_window_policy::new_descent_off(), phase_start: 100, now: 99  },
        DeSisterCase { policy: auction_window_policy::new_descent_off(), phase_start: 100, now: 100 },
        DeSisterCase { policy: auction_window_policy::new_descent_off(), phase_start: 100, now: 101 },
        DeSisterCase { policy: auction_window_policy::new_descent_off(), phase_start: 0,   now: 0   },

        // Fixed — boundary triple at phase_start + ceiling = 150
        DeSisterCase { policy: auction_window_policy::new_descent_fixed(phases::duration(50)), phase_start: 100, now: 149 },
        DeSisterCase { policy: auction_window_policy::new_descent_fixed(phases::duration(50)), phase_start: 100, now: 150 },
        DeSisterCase { policy: auction_window_policy::new_descent_fixed(phases::duration(50)), phase_start: 100, now: 151 },

        // Window at zero anchor
        DeSisterCase { policy: auction_window_policy::new_descent_fixed(phases::duration(50)), phase_start: 0, now: 49 },
        DeSisterCase { policy: auction_window_policy::new_descent_fixed(phases::duration(50)), phase_start: 0, now: 50 },
    ];
    cases.do_ref!(|c| {
        let mut gen   = sui::random::new_generator_from_seed_for_testing(vector[0u8]);
        let resolved  = auction_window_policy::compute_duration(&c.policy, &mut gen);
        let bool_view = auction_window_policy::compute_expiry_boundary(resolved, phases::timestamp(c.phase_start), phases::timestamp(c.now)).proj_is_crossed();
        let u64_view  = c.now >= phases::timestamp_ms(auction_window_policy::compute_expiry_at(resolved, phases::timestamp(c.phase_start)));
        assert_eq!(bool_view, u64_view);
    });
}

// ─── RandomInRange — constructors ─────────────────────────────────────────────

#[test, expected_failure(abort_code = auction_window_policy::EDescentCeilingZero, location = usufruct::auction_window_policy)]
fun new_descent_random_in_range_rejects_zero_min() {
    auction_window_policy::new_descent_random_in_range(phases::duration(0), phases::duration(100));
}

#[test, expected_failure(abort_code = auction_window_policy::EMinNotLtMax, location = usufruct::auction_window_policy)]
fun new_descent_random_in_range_rejects_min_eq_max() {
    auction_window_policy::new_descent_random_in_range(phases::duration(50), phases::duration(50));
}

#[test, expected_failure(abort_code = auction_window_policy::EMinNotLtMax, location = usufruct::auction_window_policy)]
fun new_descent_random_in_range_rejects_min_gt_max() {
    auction_window_policy::new_descent_random_in_range(phases::duration(100), phases::duration(50));
}

// ─── RandomInRange — resolve draws in bounds ──────────────────────────────────

#[test]
fun resolve_random_in_range_draws_in_bounds() {
    let min: u64 = 10;
    let max: u64 = 50;
    let policy = auction_window_policy::new_descent_random_in_range(
        phases::duration(min),
        phases::duration(max),
    );
    let seeds = vector[vector[0u8], vector[1u8], vector[2u8], vector[3u8], vector[7u8]];
    let mut i = 0;
    while (i < seeds.length()) {
        let mut gen = sui::random::new_generator_from_seed_for_testing(*seeds.borrow(i));
        let result  = auction_window_policy::compute_duration(&policy, &mut gen);
        let ms      = phases::duration_ms(result);
        assert!(ms >= min && ms <= max, 0);
        i = i + 1;
    };
}

// ─── RandomInRange — compute_expiry_at is in [phase+min, phase+max] ──────────────────

#[test]
fun random_in_range_expiry_at_within_bounds() {
    let min: u64 = 10;
    let max: u64 = 100;
    let phase_start: u64 = 500;
    let policy = auction_window_policy::new_descent_random_in_range(
        phases::duration(min),
        phases::duration(max),
    );
    let seeds = vector[vector[0u8], vector[1u8], vector[4u8], vector[9u8]];
    let mut i = 0;
    while (i < seeds.length()) {
        let mut gen  = sui::random::new_generator_from_seed_for_testing(*seeds.borrow(i));
        let resolved = auction_window_policy::compute_duration(&policy, &mut gen);
        let expiry   = phases::timestamp_ms(auction_window_policy::compute_expiry_at(resolved, phases::timestamp(phase_start)));
        assert!(expiry >= phase_start + min, 0);
        assert!(expiry <= phase_start + max, 1);
        i = i + 1;
    };
}

// ─── projectors ──────────────────────────────────────────────────────────────

#[test]
fun projectors_skipped_variant() {
    let p = auction_window_policy::new_descent_off();
    assert!(p.proj_is_off());
    assert!(!p.proj_is_fixed());
    assert!(!p.proj_is_random_in_range());
    assert!(p.proj_fixed_ceiling().is_none());
    assert!(p.proj_range_min().is_none());
    assert!(p.proj_range_max().is_none());
}

#[test]
fun projectors_window_variant() {
    let p = auction_window_policy::new_descent_fixed(phases::duration(75));
    assert!(!p.proj_is_off());
    assert!(p.proj_is_fixed());
    assert!(!p.proj_is_random_in_range());
    assert_eq!(phases::duration_ms(p.proj_fixed_ceiling().destroy_some()), 75);
    assert!(p.proj_range_min().is_none());
    assert!(p.proj_range_max().is_none());
}

#[test]
fun projectors_random_in_range_variant() {
    let p = auction_window_policy::new_descent_random_in_range(phases::duration(20), phases::duration(80));
    assert!(!p.proj_is_off());
    assert!(!p.proj_is_fixed());
    assert!(p.proj_is_random_in_range());
    assert!(p.proj_fixed_ceiling().is_none());
    assert_eq!(phases::duration_ms(p.proj_range_min().destroy_some()), 20);
    assert_eq!(phases::duration_ms(p.proj_range_max().destroy_some()), 80);
}
