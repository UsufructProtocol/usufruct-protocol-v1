// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::retire_commitment_policy_tests;

use std::unit_test::assert_eq;
use usufruct::retire_commitment_policy::{Self, RetireCommitmentPolicy};
use usufruct::phases;

// ─── new_deferred — abort ──────────────────────────────────────────────

#[test, expected_failure(abort_code = retire_commitment_policy::ERetireCommitmentFloorZero, location = usufruct::retire_commitment_policy)]
fun new_deferred_rejects_zero() {
    // Deferred(0) is not allowed; the zero-floor mode is Immediate.
    retire_commitment_policy::new_deferred(phases::duration(0));
}

// ─── compute_unlock_boundary ──────────────────────────────────────────────────────────────

#[test_only]
public struct IsUnlockedCase has drop {
    policy:        RetireCommitmentPolicy,
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
        IsUnlockedCase { policy: retire_commitment_policy::new_immediate(), integrated_at: 100, now: 99,  expected: false }, // before integration
        IsUnlockedCase { policy: retire_commitment_policy::new_immediate(), integrated_at: 100, now: 100, expected: true  }, // exact
        IsUnlockedCase { policy: retire_commitment_policy::new_immediate(), integrated_at: 100, now: 101, expected: true  }, // after
        IsUnlockedCase { policy: retire_commitment_policy::new_immediate(), integrated_at: 0,   now: 0,   expected: true  }, // zero anchor

        // Deferred — boundary triple at integrated_at + floor_ms = 150
        IsUnlockedCase { policy: retire_commitment_policy::new_deferred(phases::duration(50)), integrated_at: 100, now: 149, expected: false }, // one before
        IsUnlockedCase { policy: retire_commitment_policy::new_deferred(phases::duration(50)), integrated_at: 100, now: 150, expected: true  }, // exact
        IsUnlockedCase { policy: retire_commitment_policy::new_deferred(phases::duration(50)), integrated_at: 100, now: 151, expected: true  }, // one after

        // Deferred at zero anchor (boundary == floor)
        IsUnlockedCase { policy: retire_commitment_policy::new_deferred(phases::duration(50)), integrated_at: 0, now: 49, expected: false },
        IsUnlockedCase { policy: retire_commitment_policy::new_deferred(phases::duration(50)), integrated_at: 0, now: 50, expected: true  },

        // Deferred with large floor — sanity that the dispatcher doesn't
        // truncate or underflow on realistic protocol values
        IsUnlockedCase { policy: retire_commitment_policy::new_deferred(phases::duration(7_200_000)), integrated_at: 1_000_000, now: 8_199_999, expected: false },
        IsUnlockedCase { policy: retire_commitment_policy::new_deferred(phases::duration(7_200_000)), integrated_at: 1_000_000, now: 8_200_000, expected: true  },
    ];
    cases.do_ref!(|c| {
        let resolved = retire_commitment_policy::compute_duration(&c.policy);
        assert_eq!(retire_commitment_policy::compute_unlock_boundary(resolved, phases::timestamp(c.integrated_at), phases::timestamp(c.now)).proj_is_crossed(), c.expected);
    });
}

// ─── monotonicity ─────────────────────────────────────────────────────────────

#[test]
fun is_unlocked_monotone_in_now_under_deferred() {
    // After the vacuous-variant refactor, both Immediate and Deferred
    // gate through phases::has_passed → both monotone in `now`. Sweep
    // 0..200 around the boundary 150 (integrated=100, floor=50) catches
    // a comparator inversion. Deferred is the variant with non-trivial
    // duration; Immediate's monotonicity is covered by the table.
    let p = retire_commitment_policy::new_deferred(phases::duration(50));
    let integrated_at: u64 = 100;
    let mut n: u64 = 0;
    let mut crossed = false;
    while (n <= 200) {
        let resolved = retire_commitment_policy::compute_duration(&p);
        let cur = retire_commitment_policy::compute_unlock_boundary(resolved, phases::timestamp(integrated_at), phases::timestamp(n)).proj_is_crossed();
        if (crossed) assert!(cur, 0);
        if (cur) crossed = true;
        n = n + 1;
    };
}

// ─── projectors ──────────────────────────────────────────────────────────────

#[test]
fun projectors_immediate_variant() {
    let p = retire_commitment_policy::new_immediate();
    assert!(p.proj_is_immediate());
    assert!(!p.proj_is_deferred());
    assert!(p.proj_floor_ms().is_none());
}

#[test]
fun projectors_deferred_variant() {
    let p = retire_commitment_policy::new_deferred(phases::duration(50));
    assert!(!p.proj_is_immediate());
    assert!(p.proj_is_deferred());
    assert_eq!(phases::duration_ms(p.proj_floor_ms().destroy_some()), 50);
}

// ─── proj_retire_commitment_policy ───────────────────────────────────────────────────

#[test]
fun proj_commitment_policy_immediate() {
    let p = retire_commitment_policy::new_immediate();
    assert_eq!(retire_commitment_policy::proj_retire_commitment_policy(&p), b"Immediate".to_string());
}

#[test]
fun proj_commitment_policy_deferred() {
    let p = retire_commitment_policy::new_deferred(phases::duration(50));
    assert_eq!(retire_commitment_policy::proj_retire_commitment_policy(&p), b"Deferred".to_string());
}

// ─── proj_retire_commitment_floor_ms ────────────────────────────────────────────────

#[test]
fun proj_commitment_floor_ms_immediate_is_none() {
    assert!(retire_commitment_policy::proj_retire_commitment_floor_ms(&retire_commitment_policy::new_immediate()).is_none(), 0);
}

#[test]
fun proj_commitment_floor_ms_deferred_is_some() {
    assert_eq!(retire_commitment_policy::proj_retire_commitment_floor_ms(&retire_commitment_policy::new_deferred(phases::duration(50))), option::some(50));
}
