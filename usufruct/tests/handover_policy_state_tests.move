// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::handover_policy_state_tests;

use std::unit_test::assert_eq;
use usufruct::handover_policy_state::{Self, HandoverPolicyState};
use usufruct::phases;

// ─── new_handover_countdown — abort ───────────────────────────────────────────

#[test]
#[expected_failure(abort_code = handover_policy_state::EHandoverFloorZero, location = usufruct::handover_policy_state)]
fun new_handover_countdown_rejects_zero() {
    // Countdown(0) is not allowed; the zero-countdown mode is Instant.
    handover_policy_state::new_handover_countdown(0);
}

// ─── countdown_floor_lt ───────────────────────────────────────────────────────

#[test_only]
public struct CountdownFloorLtCase has drop {
    policy:   HandoverPolicyState,
    ceiling:  u64,
    expected: bool,
}

#[test]
fun countdown_floor_lt_table() {
    let cases = vector[
        // Instant / FixedTime — vacuously true (no countdown floor exists)
        CountdownFloorLtCase { policy: handover_policy_state::new_handover_instant(),     ceiling: 100, expected: true  },
        CountdownFloorLtCase { policy: handover_policy_state::new_handover_instant(),     ceiling: 0,   expected: true  },
        CountdownFloorLtCase { policy: handover_policy_state::new_handover_fixed_time(),  ceiling: 100, expected: true  },
        CountdownFloorLtCase { policy: handover_policy_state::new_handover_fixed_time(),  ceiling: 0,   expected: true  },
        // Countdown — strict less-than triple at ceiling=100
        CountdownFloorLtCase { policy: handover_policy_state::new_handover_countdown(50),  ceiling: 100, expected: true  },
        CountdownFloorLtCase { policy: handover_policy_state::new_handover_countdown(99),  ceiling: 100, expected: true  }, // one below
        // Countdown — equality is FixedTime, not the upper edge of Countdown:
        // countdown_floor_lt is strict, so floor==ceiling returns false.
        CountdownFloorLtCase { policy: handover_policy_state::new_handover_countdown(100), ceiling: 100, expected: false },
        CountdownFloorLtCase { policy: handover_policy_state::new_handover_countdown(101), ceiling: 100, expected: false }, // one above
        CountdownFloorLtCase { policy: handover_policy_state::new_handover_countdown(150), ceiling: 100, expected: false },
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let c = &cases[i];
        assert_eq!(handover_policy_state::countdown_floor_lt(&c.policy, c.ceiling), c.expected);
        i = i + 1;
    };
}

// ─── has_expired ──────────────────────────────────────────────────────────────

#[test_only]
public struct HasExpiredCase has drop {
    policy:         HandoverPolicyState,
    bid_time:       u64,
    phase_start:    u64,
    tenure_ceiling: u64,
    now:            u64,
    expected:       bool,
}

#[test]
fun has_expired_table() {
    let cases = vector[
        // Instant — fires from `bid_time` onward (defensively monotone in `now`).
        // Boundary triple at bid_time = 1000 demonstrates the gate is at bid,
        // not vacuously before. phase_start / tenure_ceiling are irrelevant.
        HasExpiredCase { policy: handover_policy_state::new_handover_instant(), bid_time: 0,    phase_start: 0,   tenure_ceiling: 1,  now: 0,    expected: true  }, // bid=0, now=0
        HasExpiredCase { policy: handover_policy_state::new_handover_instant(), bid_time: 1000, phase_start: 100, tenure_ceiling: 50, now: 999,  expected: false }, // before bid (gate closed)
        HasExpiredCase { policy: handover_policy_state::new_handover_instant(), bid_time: 1000, phase_start: 100, tenure_ceiling: 50, now: 1000, expected: true  }, // exact bid (gate opens)
        HasExpiredCase { policy: handover_policy_state::new_handover_instant(), bid_time: 1000, phase_start: 100, tenure_ceiling: 50, now: 9999, expected: true  }, // well after bid

        // FixedTime — boundary at phase_start + tenure_ceiling = 150
        // Boundary triple. bid_time variation should be ignored.
        HasExpiredCase { policy: handover_policy_state::new_handover_fixed_time(), bid_time: 0,    phase_start: 100, tenure_ceiling: 50, now: 149, expected: false },
        HasExpiredCase { policy: handover_policy_state::new_handover_fixed_time(), bid_time: 0,    phase_start: 100, tenure_ceiling: 50, now: 150, expected: true  },
        HasExpiredCase { policy: handover_policy_state::new_handover_fixed_time(), bid_time: 0,    phase_start: 100, tenure_ceiling: 50, now: 151, expected: true  },
        // bid_time variation — must not change FixedTime's verdict
        HasExpiredCase { policy: handover_policy_state::new_handover_fixed_time(), bid_time: 999, phase_start: 100, tenure_ceiling: 50, now: 150, expected: true  },

        // Countdown — countdown branch wins: bid=10, floor=20 → countdown boundary=30
        // (phase+tenure=150 is later, so the saturation never engages)
        HasExpiredCase { policy: handover_policy_state::new_handover_countdown(20), bid_time: 10, phase_start: 100, tenure_ceiling: 50, now: 29, expected: false },
        HasExpiredCase { policy: handover_policy_state::new_handover_countdown(20), bid_time: 10, phase_start: 100, tenure_ceiling: 50, now: 30, expected: true  },
        HasExpiredCase { policy: handover_policy_state::new_handover_countdown(20), bid_time: 10, phase_start: 100, tenure_ceiling: 50, now: 31, expected: true  },

        // Countdown — tenure branch wins: bid=10, floor=200 → countdown=210
        // (phase+tenure=150 is earlier, saturation engages)
        HasExpiredCase { policy: handover_policy_state::new_handover_countdown(200), bid_time: 10, phase_start: 100, tenure_ceiling: 50, now: 149, expected: false },
        HasExpiredCase { policy: handover_policy_state::new_handover_countdown(200), bid_time: 10, phase_start: 100, tenure_ceiling: 50, now: 150, expected: true  },

        // Countdown — both branches collide at the same instant: bid=100, floor=50 → 150
        // = phase+tenure → either branch fires
        HasExpiredCase { policy: handover_policy_state::new_handover_countdown(50), bid_time: 100, phase_start: 100, tenure_ceiling: 50, now: 149, expected: false },
        HasExpiredCase { policy: handover_policy_state::new_handover_countdown(50), bid_time: 100, phase_start: 100, tenure_ceiling: 50, now: 150, expected: true  },
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let c = &cases[i];
        assert_eq!(
            handover_policy_state::has_expired(
                &c.policy,
                phases::timestamp(c.bid_time),
                phases::timestamp(c.phase_start),
                phases::duration(c.tenure_ceiling),
                phases::timestamp(c.now),
            ).is_crossed(),
            c.expected,
        );
        i = i + 1;
    };
}

// ─── expiry_at ────────────────────────────────────────────────────────────────

#[test_only]
public struct ExpiryAtCase has drop {
    policy:         HandoverPolicyState,
    bid_time:       u64,
    phase_start:    u64,
    tenure_ceiling: u64,
    expected:       u64,
}

#[test]
fun expiry_at_table() {
    let cases = vector[
        // Instant — returns bid_time directly (independent of phase/tenure).
        // Used downstream so that the gate `now >= expiry_at` fires on the
        // next APT iteration since clock-monotone implies now >= bid_time.
        ExpiryAtCase { policy: handover_policy_state::new_handover_instant(), bid_time: 0,    phase_start: 100, tenure_ceiling: 50, expected: 0    },
        ExpiryAtCase { policy: handover_policy_state::new_handover_instant(), bid_time: 1000, phase_start: 0,   tenure_ceiling: 0,  expected: 1000 },

        // FixedTime — returns phase + tenure (independent of bid_time)
        ExpiryAtCase { policy: handover_policy_state::new_handover_fixed_time(), bid_time: 0,     phase_start: 100, tenure_ceiling: 50, expected: 150 },
        ExpiryAtCase { policy: handover_policy_state::new_handover_fixed_time(), bid_time: 99999, phase_start: 100, tenure_ceiling: 50, expected: 150 }, // bid_time irrelevant

        // Countdown — countdown wins: min(bid+floor=30, phase+tenure=150) = 30
        ExpiryAtCase { policy: handover_policy_state::new_handover_countdown(20),  bid_time: 10,  phase_start: 100, tenure_ceiling: 50, expected: 30  },
        // Countdown — tenure wins: min(bid+floor=210, phase+tenure=150) = 150
        ExpiryAtCase { policy: handover_policy_state::new_handover_countdown(200), bid_time: 10,  phase_start: 100, tenure_ceiling: 50, expected: 150 },
        // Countdown — equality: min(150, 150) = 150 (both branches resolve identically)
        ExpiryAtCase { policy: handover_policy_state::new_handover_countdown(50),  bid_time: 100, phase_start: 100, tenure_ceiling: 50, expected: 150 },
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let c = &cases[i];
        assert_eq!(
            phases::timestamp_ms(handover_policy_state::expiry_at(
                &c.policy,
                phases::timestamp(c.bid_time),
                phases::timestamp(c.phase_start),
                phases::duration(c.tenure_ceiling),
            )),
            c.expected,
        );
        i = i + 1;
    };
}

// ─── sister identity: has_expired ⇔ now >= expiry_at ──────────────────────────

#[test_only]
public struct HoSisterCase has drop {
    policy:         HandoverPolicyState,
    bid_time:       u64,
    phase_start:    u64,
    tenure_ceiling: u64,
    now:            u64,
}

// Architectural invariant: the bool view (has_expired) and the u64 view
// (expiry_at) must agree on every input. This is THE test the policy
// layer rests on — if anyone changes the saturation rule in expiry_at
// without updating has_expired (or vice versa), this fires. Time-layer
// analogue of curve_shape_state_tests' P-D1 dispatch equivalence.
#[test]
fun has_expired_iff_now_ge_expiry_at() {
    let cases = vector[
        // Instant — boundary is bid_time itself
        HoSisterCase { policy: handover_policy_state::new_handover_instant(), bid_time: 0,    phase_start: 100, tenure_ceiling: 50, now: 0    },
        HoSisterCase { policy: handover_policy_state::new_handover_instant(), bid_time: 1000, phase_start: 100, tenure_ceiling: 50, now: 999  }, // before bid (degenerate but consistent)
        HoSisterCase { policy: handover_policy_state::new_handover_instant(), bid_time: 1000, phase_start: 100, tenure_ceiling: 50, now: 1000 },

        // FixedTime — boundary triple at 150
        HoSisterCase { policy: handover_policy_state::new_handover_fixed_time(), bid_time: 0, phase_start: 100, tenure_ceiling: 50, now: 149 },
        HoSisterCase { policy: handover_policy_state::new_handover_fixed_time(), bid_time: 0, phase_start: 100, tenure_ceiling: 50, now: 150 },
        HoSisterCase { policy: handover_policy_state::new_handover_fixed_time(), bid_time: 0, phase_start: 100, tenure_ceiling: 50, now: 151 },

        // Countdown countdown-wins — boundary triple at 30
        HoSisterCase { policy: handover_policy_state::new_handover_countdown(20), bid_time: 10, phase_start: 100, tenure_ceiling: 50, now: 29 },
        HoSisterCase { policy: handover_policy_state::new_handover_countdown(20), bid_time: 10, phase_start: 100, tenure_ceiling: 50, now: 30 },
        HoSisterCase { policy: handover_policy_state::new_handover_countdown(20), bid_time: 10, phase_start: 100, tenure_ceiling: 50, now: 31 },

        // Countdown tenure-wins — boundary triple at 150
        HoSisterCase { policy: handover_policy_state::new_handover_countdown(200), bid_time: 10, phase_start: 100, tenure_ceiling: 50, now: 149 },
        HoSisterCase { policy: handover_policy_state::new_handover_countdown(200), bid_time: 10, phase_start: 100, tenure_ceiling: 50, now: 150 },
        HoSisterCase { policy: handover_policy_state::new_handover_countdown(200), bid_time: 10, phase_start: 100, tenure_ceiling: 50, now: 151 },

        // Countdown equality — boundary at 150 (both sub-boundaries collide)
        HoSisterCase { policy: handover_policy_state::new_handover_countdown(50), bid_time: 100, phase_start: 100, tenure_ceiling: 50, now: 149 },
        HoSisterCase { policy: handover_policy_state::new_handover_countdown(50), bid_time: 100, phase_start: 100, tenure_ceiling: 50, now: 150 },
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let c = &cases[i];
        let bool_view = handover_policy_state::has_expired(
            &c.policy,
            phases::timestamp(c.bid_time),
            phases::timestamp(c.phase_start),
            phases::duration(c.tenure_ceiling),
            phases::timestamp(c.now),
        ).is_crossed();
        let u64_view  = c.now >= phases::timestamp_ms(handover_policy_state::expiry_at(
            &c.policy,
            phases::timestamp(c.bid_time),
            phases::timestamp(c.phase_start),
            phases::duration(c.tenure_ceiling),
        ));
        assert_eq!(bool_view, u64_view);
        i = i + 1;
    };
}

// ─── monotonicity ─────────────────────────────────────────────────────────────

#[test]
fun has_expired_monotone_in_now_under_countdown() {
    // Countdown is the only variant with compound bool logic (||). The
    // disjunction of two monotone-in-`now` predicates must itself be
    // monotone — once it crosses, it stays crossed. Sweep 0..200 covers
    // both sub-boundaries (countdown=30, tenure=150). Catches comparator
    // inversion and the rare bug where the disjunction is mis-encoded
    // (e.g., `&&` instead of `||`).
    let p = handover_policy_state::new_handover_countdown(20);
    let bid_time:    u64 = 10;
    let phase_start: u64 = 100;
    let tenure:      u64 = 50;
    let mut n: u64 = 0;
    let mut crossed = false;
    while (n <= 200) {
        let cur = handover_policy_state::has_expired(
            &p,
            phases::timestamp(bid_time),
            phases::timestamp(phase_start),
            phases::duration(tenure),
            phases::timestamp(n),
        ).is_crossed();
        if (crossed) assert!(cur, 0);
        if (cur) crossed = true;
        n = n + 1;
    };
}
