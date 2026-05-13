// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::handover_policy_state_tests;

use std::unit_test::assert_eq;
use usufruct::handover_policy_state::{Self, HandoverPolicyState};
use usufruct::phases;

// ─── constructors — abort guards ──────────────────────────────────────────────

#[test, expected_failure(abort_code = handover_policy_state::EHandoverFloorZero, location = usufruct::handover_policy_state)]
fun new_handover_countdown_rejects_zero() {
    handover_policy_state::new_handover_countdown(phases::duration(0));
}

#[test, expected_failure(abort_code = handover_policy_state::EHandoverFloorZero, location = usufruct::handover_policy_state)]
fun new_handover_random_in_range_rejects_zero_min() {
    handover_policy_state::new_handover_random_in_range(phases::duration(0), phases::duration(100));
}

#[test, expected_failure(abort_code = handover_policy_state::EMinNotLtMax, location = usufruct::handover_policy_state)]
fun new_handover_random_in_range_rejects_min_eq_max() {
    handover_policy_state::new_handover_random_in_range(phases::duration(50), phases::duration(50));
}

#[test, expected_failure(abort_code = handover_policy_state::EMinNotLtMax, location = usufruct::handover_policy_state)]
fun new_handover_random_in_range_rejects_min_gt_max() {
    handover_policy_state::new_handover_random_in_range(phases::duration(100), phases::duration(50));
}

// ─── resolve — deterministic variants ────────────────────────────────────────

#[test]
fun resolve_instant_returns_zero() {
    let mut gen = sui::random::new_generator_from_seed_for_testing(vector[0u8]);
    let result = handover_policy_state::resolve(
        &handover_policy_state::new_handover_instant(),
        phases::duration(100),
        &mut gen,
    );
    assert_eq!(phases::duration_ms(result), 0);
}

#[test]
fun resolve_fixed_time_returns_ceiling() {
    let mut gen = sui::random::new_generator_from_seed_for_testing(vector[0u8]);
    let ceiling = phases::duration(200);
    let result = handover_policy_state::resolve(
        &handover_policy_state::new_handover_fixed_time(),
        ceiling,
        &mut gen,
    );
    assert_eq!(phases::duration_ms(result), 200);
}

#[test]
fun resolve_countdown_returns_floor() {
    let mut gen = sui::random::new_generator_from_seed_for_testing(vector[0u8]);
    let result = handover_policy_state::resolve(
        &handover_policy_state::new_handover_countdown(phases::duration(42)),
        phases::duration(100),
        &mut gen,
    );
    assert_eq!(phases::duration_ms(result), 42);
}

#[test]
fun resolve_random_in_range_draws_in_bounds() {
    let min: u64 = 10;
    let max: u64 = 50;
    let policy = handover_policy_state::new_handover_random_in_range(
        phases::duration(min),
        phases::duration(max),
    );
    let seeds = vector[
        vector[0u8], vector[1u8], vector[2u8], vector[3u8], vector[7u8],
    ];
    let mut i = 0;
    while (i < seeds.length()) {
        let mut gen = sui::random::new_generator_from_seed_for_testing(*seeds.borrow(i));
        let result = handover_policy_state::resolve(&policy, phases::duration(200), &mut gen);
        let ms = phases::duration_ms(result);
        assert!(ms >= min && ms <= max, 0);
        i = i + 1;
    };
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
        CountdownFloorLtCase { policy: handover_policy_state::new_handover_instant(),     ceiling: 100, expected: true  },
        CountdownFloorLtCase { policy: handover_policy_state::new_handover_instant(),     ceiling: 0,   expected: true  },
        CountdownFloorLtCase { policy: handover_policy_state::new_handover_fixed_time(),  ceiling: 100, expected: true  },
        CountdownFloorLtCase { policy: handover_policy_state::new_handover_fixed_time(),  ceiling: 0,   expected: true  },
        CountdownFloorLtCase { policy: handover_policy_state::new_handover_countdown(phases::duration(50)),  ceiling: 100, expected: true  },
        CountdownFloorLtCase { policy: handover_policy_state::new_handover_countdown(phases::duration(99)),  ceiling: 100, expected: true  },
        CountdownFloorLtCase { policy: handover_policy_state::new_handover_countdown(phases::duration(100)), ceiling: 100, expected: false },
        CountdownFloorLtCase { policy: handover_policy_state::new_handover_countdown(phases::duration(101)), ceiling: 100, expected: false },
        // RandomInRange — uses max for conservative validation
        CountdownFloorLtCase { policy: handover_policy_state::new_handover_random_in_range(phases::duration(10), phases::duration(50)), ceiling: 100, expected: true  },
        CountdownFloorLtCase { policy: handover_policy_state::new_handover_random_in_range(phases::duration(10), phases::duration(99)), ceiling: 100, expected: true  },
        CountdownFloorLtCase { policy: handover_policy_state::new_handover_random_in_range(phases::duration(10), phases::duration(100)), ceiling: 100, expected: false },
    ];
    cases.do_ref!(|c| {
        assert_eq!(handover_policy_state::countdown_floor_lt(&c.policy, phases::duration(c.ceiling)), c.expected);
    });
}

// ─── has_expired — takes resolved_floor: Duration ────────────────────────────

#[test_only]
public struct HasExpiredCase has drop {
    resolved_floor:   u64,
    resolved_ceiling: u64,
    bid_time:         u64,
    phase_start:      u64,
    now:              u64,
    expected:         bool,
}

#[test]
fun has_expired_table() {
    let cases = vector[
        // Instant (resolved_floor=0): expiry = min(bid+0, phase+ceil) = bid_time when bid < phase+ceil
        HasExpiredCase { resolved_floor: 0, resolved_ceiling: 500, bid_time: 0,   phase_start: 0,   now: 0,   expected: true  },
        HasExpiredCase { resolved_floor: 0, resolved_ceiling: 500, bid_time: 100, phase_start: 0,   now: 99,  expected: false },
        HasExpiredCase { resolved_floor: 0, resolved_ceiling: 500, bid_time: 100, phase_start: 0,   now: 100, expected: true  },
        HasExpiredCase { resolved_floor: 0, resolved_ceiling: 500, bid_time: 100, phase_start: 0,   now: 999, expected: true  },

        // FixedTime (floor=ceiling=50): expiry = min(bid+50, phase+50). With bid>phase, bid+50>phase+50, so expiry=phase+50=150
        HasExpiredCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 110, phase_start: 100, now: 149, expected: false },
        HasExpiredCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 110, phase_start: 100, now: 150, expected: true  },
        HasExpiredCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 140, phase_start: 100, now: 150, expected: true  }, // different bid, same boundary

        // Countdown (resolved_floor=20) — countdown wins: min(bid+20, phase+50) = min(30, 150) = 30
        HasExpiredCase { resolved_floor: 20, resolved_ceiling: 50, bid_time: 10, phase_start: 100, now: 29,  expected: false },
        HasExpiredCase { resolved_floor: 20, resolved_ceiling: 50, bid_time: 10, phase_start: 100, now: 30,  expected: true  },
        HasExpiredCase { resolved_floor: 20, resolved_ceiling: 50, bid_time: 10, phase_start: 100, now: 31,  expected: true  },

        // Countdown (resolved_floor=200) — tenure wins: min(bid+200=210, phase+50=150) = 150
        HasExpiredCase { resolved_floor: 200, resolved_ceiling: 50, bid_time: 10, phase_start: 100, now: 149, expected: false },
        HasExpiredCase { resolved_floor: 200, resolved_ceiling: 50, bid_time: 10, phase_start: 100, now: 150, expected: true  },

        // Equality: min(bid+50=150, phase+50=150) = 150
        HasExpiredCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 100, phase_start: 100, now: 149, expected: false },
        HasExpiredCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 100, phase_start: 100, now: 150, expected: true  },
    ];
    cases.do_ref!(|c| {
        assert_eq!(
            handover_policy_state::has_expired(
                phases::duration(c.resolved_floor),
                phases::duration(c.resolved_ceiling),
                phases::timestamp(c.bid_time),
                phases::timestamp(c.phase_start),
                phases::timestamp(c.now),
            ).is_crossed(),
            c.expected,
        );
    });
}

// ─── expiry_at ────────────────────────────────────────────────────────────────

#[test_only]
public struct ExpiryAtCase has drop {
    resolved_floor:   u64,
    resolved_ceiling: u64,
    bid_time:         u64,
    phase_start:      u64,
    expected:         u64,
}

#[test]
fun expiry_at_table() {
    let cases = vector[
        // Instant (floor=0): expiry = min(bid+0, phase+ceil) = bid when bid < phase+ceil
        ExpiryAtCase { resolved_floor: 0, resolved_ceiling: 500, bid_time: 0,   phase_start: 0,   expected: 0   },
        ExpiryAtCase { resolved_floor: 0, resolved_ceiling: 500, bid_time: 100, phase_start: 0,   expected: 100 },
        ExpiryAtCase { resolved_floor: 0, resolved_ceiling: 500, bid_time: 200, phase_start: 100, expected: 200 },

        // FixedTime (floor=ceiling=50): expiry = min(bid+50, phase+50). With bid>phase → expiry=phase+50=150
        ExpiryAtCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 110,   phase_start: 100, expected: 150 },
        ExpiryAtCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 140,   phase_start: 100, expected: 150 },

        // Countdown floor wins: min(bid+20=30, phase+50=150) = 30
        ExpiryAtCase { resolved_floor: 20, resolved_ceiling: 50, bid_time: 10, phase_start: 100, expected: 30  },
        // Countdown tenure wins: min(bid+200=210, phase+50=150) = 150
        ExpiryAtCase { resolved_floor: 200, resolved_ceiling: 50, bid_time: 10, phase_start: 100, expected: 150 },
        // Countdown equality: min(150, 150) = 150
        ExpiryAtCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 100, phase_start: 100, expected: 150 },
    ];
    cases.do_ref!(|c| {
        assert_eq!(
            phases::timestamp_ms(handover_policy_state::expiry_at(
                phases::duration(c.resolved_floor),
                phases::duration(c.resolved_ceiling),
                phases::timestamp(c.bid_time),
                phases::timestamp(c.phase_start),
            )),
            c.expected,
        );
    });
}

// ─── sister identity: has_expired ⇔ now >= expiry_at ─────────────────────────

#[test_only]
public struct HoSisterCase has drop {
    resolved_floor:   u64,
    resolved_ceiling: u64,
    bid_time:         u64,
    phase_start:      u64,
    now:              u64,
}

#[test]
fun has_expired_iff_now_ge_expiry_at() {
    let cases = vector[
        // Instant (bid < phase+ceil so expiry=bid)
        HoSisterCase { resolved_floor: 0, resolved_ceiling: 500, bid_time: 0,   phase_start: 0,   now: 0    },
        HoSisterCase { resolved_floor: 0, resolved_ceiling: 500, bid_time: 100, phase_start: 0,   now: 99   },
        HoSisterCase { resolved_floor: 0, resolved_ceiling: 500, bid_time: 100, phase_start: 0,   now: 100  },
        // FixedTime (bid > phase so expiry=phase+ceil=150)
        HoSisterCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 110, phase_start: 100, now: 149 },
        HoSisterCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 110, phase_start: 100, now: 150 },
        HoSisterCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 110, phase_start: 100, now: 151 },
        // Countdown countdown-wins
        HoSisterCase { resolved_floor: 20, resolved_ceiling: 50, bid_time: 10, phase_start: 100, now: 29 },
        HoSisterCase { resolved_floor: 20, resolved_ceiling: 50, bid_time: 10, phase_start: 100, now: 30 },
        HoSisterCase { resolved_floor: 20, resolved_ceiling: 50, bid_time: 10, phase_start: 100, now: 31 },
        // Countdown tenure-wins
        HoSisterCase { resolved_floor: 200, resolved_ceiling: 50, bid_time: 10, phase_start: 100, now: 149 },
        HoSisterCase { resolved_floor: 200, resolved_ceiling: 50, bid_time: 10, phase_start: 100, now: 150 },
        HoSisterCase { resolved_floor: 200, resolved_ceiling: 50, bid_time: 10, phase_start: 100, now: 151 },
        // Countdown equality
        HoSisterCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 100, phase_start: 100, now: 149 },
        HoSisterCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 100, phase_start: 100, now: 150 },
    ];
    cases.do_ref!(|c| {
        let bool_view = handover_policy_state::has_expired(
            phases::duration(c.resolved_floor),
            phases::duration(c.resolved_ceiling),
            phases::timestamp(c.bid_time),
            phases::timestamp(c.phase_start),
            phases::timestamp(c.now),
        ).is_crossed();
        let u64_view = c.now >= phases::timestamp_ms(handover_policy_state::expiry_at(
            phases::duration(c.resolved_floor),
            phases::duration(c.resolved_ceiling),
            phases::timestamp(c.bid_time),
            phases::timestamp(c.phase_start),
        ));
        assert_eq!(bool_view, u64_view);
    });
}

// ─── monotonicity ─────────────────────────────────────────────────────────────

#[test]
fun has_expired_monotone_in_now() {
    // resolved_floor=20, bid=10 → countdown boundary=30; resolved_ceiling=50, phase=100 → tenure=150.
    // Sweep covers both sub-boundaries. Once crossed, stays crossed.
    let resolved_floor:   u64 = 20;
    let resolved_ceiling: u64 = 50;
    let bid_time:         u64 = 10;
    let phase_start:      u64 = 100;
    let mut n: u64 = 0;
    let mut crossed = false;
    while (n <= 200) {
        let cur = handover_policy_state::has_expired(
            phases::duration(resolved_floor),
            phases::duration(resolved_ceiling),
            phases::timestamp(bid_time),
            phases::timestamp(phase_start),
            phases::timestamp(n),
        ).is_crossed();
        if (crossed) assert!(cur, 0);
        if (cur) crossed = true;
        n = n + 1;
    };
}

// ─── projectors ──────────────────────────────────────────────────────────────

#[test]
fun projectors_instant_variant() {
    let p = handover_policy_state::new_handover_instant();
    assert!(p.proj_is_instant());
    assert!(!p.proj_is_fixed_time());
    assert!(!p.proj_is_countdown());
    assert!(!p.proj_is_random_in_range());
    assert!(p.proj_countdown_floor_ms().is_none());
    assert!(p.proj_range_min().is_none());
    assert!(p.proj_range_max().is_none());
}

#[test]
fun projectors_fixed_time_variant() {
    let p = handover_policy_state::new_handover_fixed_time();
    assert!(!p.proj_is_instant());
    assert!(p.proj_is_fixed_time());
    assert!(!p.proj_is_countdown());
    assert!(!p.proj_is_random_in_range());
    assert!(p.proj_countdown_floor_ms().is_none());
    assert!(p.proj_range_min().is_none());
    assert!(p.proj_range_max().is_none());
}

#[test]
fun projectors_countdown_variant() {
    let p = handover_policy_state::new_handover_countdown(phases::duration(42));
    assert!(!p.proj_is_instant());
    assert!(!p.proj_is_fixed_time());
    assert!(p.proj_is_countdown());
    assert!(!p.proj_is_random_in_range());
    assert_eq!(phases::duration_ms(p.proj_countdown_floor_ms().destroy_some()), 42);
    assert!(p.proj_range_min().is_none());
    assert!(p.proj_range_max().is_none());
}

#[test]
fun projectors_random_in_range_variant() {
    let p = handover_policy_state::new_handover_random_in_range(phases::duration(10), phases::duration(100));
    assert!(!p.proj_is_instant());
    assert!(!p.proj_is_fixed_time());
    assert!(!p.proj_is_countdown());
    assert!(p.proj_is_random_in_range());
    assert!(p.proj_countdown_floor_ms().is_none());
    assert_eq!(phases::duration_ms(p.proj_range_min().destroy_some()), 10);
    assert_eq!(phases::duration_ms(p.proj_range_max().destroy_some()), 100);
}
