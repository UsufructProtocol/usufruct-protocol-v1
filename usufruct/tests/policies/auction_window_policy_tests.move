// Copyright (c) UsufructProtocol
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
        let resolved = auction_window_policy::compute_duration(&c.policy);
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
        let resolved = auction_window_policy::compute_duration(&c.policy);
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
fun fixed_ceiling_aborts_on_off() {
    // fixed_ceiling on Skipped is unreachable in production
    // (compute_price_descent only fires from DescentAuction, structurally
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
        let resolved  = auction_window_policy::compute_duration(&c.policy);
        let bool_view = auction_window_policy::compute_expiry_boundary(resolved, phases::timestamp(c.phase_start), phases::timestamp(c.now)).proj_is_crossed();
        let u64_view  = c.now >= phases::timestamp_ms(auction_window_policy::compute_expiry_at(resolved, phases::timestamp(c.phase_start)));
        assert_eq!(bool_view, u64_view);
    });
}

