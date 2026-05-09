// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::retire_policy_state_tests;

use std::unit_test::assert_eq;
use usufruct::retire_policy_state::{Self, RetirePolicyState};
use usufruct::phases;

// ─── new_retire_deferred — abort ──────────────────────────────────────────────

#[test]
#[expected_failure(abort_code = retire_policy_state::ERetireFloorZero, location = usufruct::retire_policy_state)]
fun new_retire_deferred_rejects_zero() {
    // Deferred(0) is not allowed; the zero-floor mode is Immediate.
    retire_policy_state::new_retire_deferred(phases::duration(0));
}

// ─── is_unlocked ──────────────────────────────────────────────────────────────

#[test_only]
public struct IsUnlockedCase has drop {
    policy:        RetirePolicyState,
    integrated_at: u64,
    now:           u64,
    expected:      bool,
}

#[test]
fun is_unlocked_table() {
    let cases = vector[
        // Immediate — unlocks from `integrated_at` onward (defensively
        // monotone). Boundary triple at integration time. floor_ms is
        // implicitly 0 — the gate opens at integration, not before.
        IsUnlockedCase { policy: retire_policy_state::new_retire_immediate(), integrated_at: 100, now: 99,  expected: false }, // before integration
        IsUnlockedCase { policy: retire_policy_state::new_retire_immediate(), integrated_at: 100, now: 100, expected: true  }, // exact
        IsUnlockedCase { policy: retire_policy_state::new_retire_immediate(), integrated_at: 100, now: 101, expected: true  }, // after
        IsUnlockedCase { policy: retire_policy_state::new_retire_immediate(), integrated_at: 0,   now: 0,   expected: true  }, // zero anchor

        // Deferred — boundary triple at integrated_at + floor_ms = 150
        IsUnlockedCase { policy: retire_policy_state::new_retire_deferred(phases::duration(50)), integrated_at: 100, now: 149, expected: false }, // one before
        IsUnlockedCase { policy: retire_policy_state::new_retire_deferred(phases::duration(50)), integrated_at: 100, now: 150, expected: true  }, // exact
        IsUnlockedCase { policy: retire_policy_state::new_retire_deferred(phases::duration(50)), integrated_at: 100, now: 151, expected: true  }, // one after

        // Deferred at zero anchor (boundary == floor)
        IsUnlockedCase { policy: retire_policy_state::new_retire_deferred(phases::duration(50)), integrated_at: 0, now: 49, expected: false },
        IsUnlockedCase { policy: retire_policy_state::new_retire_deferred(phases::duration(50)), integrated_at: 0, now: 50, expected: true  },

        // Deferred with large floor — sanity that the dispatcher doesn't
        // truncate or underflow on realistic protocol values
        IsUnlockedCase { policy: retire_policy_state::new_retire_deferred(phases::duration(7_200_000)), integrated_at: 1_000_000, now: 8_199_999, expected: false },
        IsUnlockedCase { policy: retire_policy_state::new_retire_deferred(phases::duration(7_200_000)), integrated_at: 1_000_000, now: 8_200_000, expected: true  },
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let c = &cases[i];
        assert_eq!(retire_policy_state::is_unlocked(&c.policy, phases::timestamp(c.integrated_at), phases::timestamp(c.now)).is_crossed(), c.expected);
        i = i + 1;
    };
}

// ─── monotonicity ─────────────────────────────────────────────────────────────

#[test]
fun is_unlocked_monotone_in_now_under_deferred() {
    // After the vacuous-variant refactor, both Immediate and Deferred
    // gate through phases::has_passed → both monotone in `now`. Sweep
    // 0..200 around the boundary 150 (integrated=100, floor=50) catches
    // a comparator inversion. Deferred is the variant with non-trivial
    // duration; Immediate's monotonicity is covered by the table.
    let p = retire_policy_state::new_retire_deferred(phases::duration(50));
    let integrated_at: u64 = 100;
    let mut n: u64 = 0;
    let mut crossed = false;
    while (n <= 200) {
        let cur = retire_policy_state::is_unlocked(&p, phases::timestamp(integrated_at), phases::timestamp(n)).is_crossed();
        if (crossed) assert!(cur, 0);
        if (cur) crossed = true;
        n = n + 1;
    };
}
