// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::handover_policy_tests;

use std::unit_test::assert_eq;
use usufruct::handover_policy::{Self, HandoverPolicy};
use usufruct::phases;

// ─── constructors — abort guards ──────────────────────────────────────────────

#[test, expected_failure(abort_code = handover_policy::EHandoverFloorZero, location = usufruct::handover_policy)]
fun new_handover_fixed_rejects_zero() {
    handover_policy::new_handover_fixed(phases::duration(0));
}

// ─── resolve — deterministic variants ────────────────────────────────────────

#[test]
fun resolve_off_returns_zero() {
    let result = handover_policy::compute_duration(
        &handover_policy::new_handover_off(),
        phases::duration(100),
    );
    assert_eq!(phases::duration_ms(result), 0);
}

#[test]
fun resolve_full_tenure_returns_ceiling() {
    let ceiling = phases::duration(200);
    let result = handover_policy::compute_duration(
        &handover_policy::new_handover_full_tenure(),
        ceiling,
    );
    assert_eq!(phases::duration_ms(result), 200);
}

#[test]
fun resolve_fixed_returns_floor() {
    let result = handover_policy::compute_duration(
        &handover_policy::new_handover_fixed(phases::duration(42)),
        phases::duration(100),
    );
    assert_eq!(phases::duration_ms(result), 42);
}

// ─── compute_countdown_floor_lt ───────────────────────────────────────────────────────

#[test_only]
public struct FixedFloorLtCase has drop {
    policy:   HandoverPolicy,
    ceiling:  u64,
    expected: bool,
}

#[test]
fun fixed_floor_lt_table() {
    let cases = vector[
        FixedFloorLtCase { policy: handover_policy::new_handover_off(),     ceiling: 100, expected: true  },
        FixedFloorLtCase { policy: handover_policy::new_handover_off(),     ceiling: 0,   expected: true  },
        FixedFloorLtCase { policy: handover_policy::new_handover_full_tenure(),  ceiling: 100, expected: true  },
        FixedFloorLtCase { policy: handover_policy::new_handover_full_tenure(),  ceiling: 0,   expected: true  },
        FixedFloorLtCase { policy: handover_policy::new_handover_fixed(phases::duration(50)),  ceiling: 100, expected: true  },
        FixedFloorLtCase { policy: handover_policy::new_handover_fixed(phases::duration(99)),  ceiling: 100, expected: true  },
        FixedFloorLtCase { policy: handover_policy::new_handover_fixed(phases::duration(100)), ceiling: 100, expected: false },
        FixedFloorLtCase { policy: handover_policy::new_handover_fixed(phases::duration(101)), ceiling: 100, expected: false },
    ];
    cases.do_ref!(|c| {
        assert_eq!(handover_policy::compute_countdown_floor_lt(&c.policy, phases::duration(c.ceiling)), c.expected);
    });
}

// ─── compute_expiry_boundary — takes resolved_floor: Duration ────────────────────────────

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

        // FullTenure (floor=ceiling=50): expiry = min(bid+50, phase+50). With bid>phase, bid+50>phase+50, so expiry=phase+50=150
        HasExpiredCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 110, phase_start: 100, now: 149, expected: false },
        HasExpiredCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 110, phase_start: 100, now: 150, expected: true  },
        HasExpiredCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 140, phase_start: 100, now: 150, expected: true  }, // different bid, same boundary

        // Fixed (resolved_floor=20) — countdown wins: min(bid+20, phase+50) = min(30, 150) = 30
        HasExpiredCase { resolved_floor: 20, resolved_ceiling: 50, bid_time: 10, phase_start: 100, now: 29,  expected: false },
        HasExpiredCase { resolved_floor: 20, resolved_ceiling: 50, bid_time: 10, phase_start: 100, now: 30,  expected: true  },
        HasExpiredCase { resolved_floor: 20, resolved_ceiling: 50, bid_time: 10, phase_start: 100, now: 31,  expected: true  },

        // Fixed (resolved_floor=200) — tenure wins: min(bid+200=210, phase+50=150) = 150
        HasExpiredCase { resolved_floor: 200, resolved_ceiling: 50, bid_time: 10, phase_start: 100, now: 149, expected: false },
        HasExpiredCase { resolved_floor: 200, resolved_ceiling: 50, bid_time: 10, phase_start: 100, now: 150, expected: true  },

        // Equality: min(bid+50=150, phase+50=150) = 150
        HasExpiredCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 100, phase_start: 100, now: 149, expected: false },
        HasExpiredCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 100, phase_start: 100, now: 150, expected: true  },
    ];
    cases.do_ref!(|c| {
        assert_eq!(
            handover_policy::compute_expiry_boundary(
                phases::duration(c.resolved_floor),
                phases::duration(c.resolved_ceiling),
                phases::timestamp(c.bid_time),
                phases::timestamp(c.phase_start),
                phases::timestamp(c.now),
            ).proj_is_crossed(),
            c.expected,
        );
    });
}

// ─── compute_expiry_at ────────────────────────────────────────────────────────────────

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

        // FullTenure (floor=ceiling=50): expiry = min(bid+50, phase+50). With bid>phase → expiry=phase+50=150
        ExpiryAtCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 110,   phase_start: 100, expected: 150 },
        ExpiryAtCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 140,   phase_start: 100, expected: 150 },

        // Fixed floor wins: min(bid+20=30, phase+50=150) = 30
        ExpiryAtCase { resolved_floor: 20, resolved_ceiling: 50, bid_time: 10, phase_start: 100, expected: 30  },
        // Fixed tenure wins: min(bid+200=210, phase+50=150) = 150
        ExpiryAtCase { resolved_floor: 200, resolved_ceiling: 50, bid_time: 10, phase_start: 100, expected: 150 },
        // Fixed equality: min(150, 150) = 150
        ExpiryAtCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 100, phase_start: 100, expected: 150 },
    ];
    cases.do_ref!(|c| {
        assert_eq!(
            phases::timestamp_ms(handover_policy::compute_expiry_at(
                phases::duration(c.resolved_floor),
                phases::duration(c.resolved_ceiling),
                phases::timestamp(c.bid_time),
                phases::timestamp(c.phase_start),
            )),
            c.expected,
        );
    });
}

// ─── sister identity: compute_expiry_boundary ⇔ now >= compute_expiry_at ─────────────────────────

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
        // FullTenure (bid > phase so expiry=phase+ceil=150)
        HoSisterCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 110, phase_start: 100, now: 149 },
        HoSisterCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 110, phase_start: 100, now: 150 },
        HoSisterCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 110, phase_start: 100, now: 151 },
        // Fixed countdown-wins
        HoSisterCase { resolved_floor: 20, resolved_ceiling: 50, bid_time: 10, phase_start: 100, now: 29 },
        HoSisterCase { resolved_floor: 20, resolved_ceiling: 50, bid_time: 10, phase_start: 100, now: 30 },
        HoSisterCase { resolved_floor: 20, resolved_ceiling: 50, bid_time: 10, phase_start: 100, now: 31 },
        // Fixed tenure-wins
        HoSisterCase { resolved_floor: 200, resolved_ceiling: 50, bid_time: 10, phase_start: 100, now: 149 },
        HoSisterCase { resolved_floor: 200, resolved_ceiling: 50, bid_time: 10, phase_start: 100, now: 150 },
        HoSisterCase { resolved_floor: 200, resolved_ceiling: 50, bid_time: 10, phase_start: 100, now: 151 },
        // Fixed equality
        HoSisterCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 100, phase_start: 100, now: 149 },
        HoSisterCase { resolved_floor: 50, resolved_ceiling: 50, bid_time: 100, phase_start: 100, now: 150 },
    ];
    cases.do_ref!(|c| {
        let bool_view = handover_policy::compute_expiry_boundary(
            phases::duration(c.resolved_floor),
            phases::duration(c.resolved_ceiling),
            phases::timestamp(c.bid_time),
            phases::timestamp(c.phase_start),
            phases::timestamp(c.now),
        ).proj_is_crossed();
        let u64_view = c.now >= phases::timestamp_ms(handover_policy::compute_expiry_at(
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
        let cur = handover_policy::compute_expiry_boundary(
            phases::duration(resolved_floor),
            phases::duration(resolved_ceiling),
            phases::timestamp(bid_time),
            phases::timestamp(phase_start),
            phases::timestamp(n),
        ).proj_is_crossed();
        if (crossed) assert!(cur, 0);
        if (cur) crossed = true;
        n = n + 1;
    };
}

// ─── projectors ──────────────────────────────────────────────────────────────

#[test]
fun projectors_off_variant() {
    let p = handover_policy::new_handover_off();
    assert!(p.proj_is_off());
    assert!(!p.proj_is_full_tenure());
    assert!(!p.proj_is_fixed());
    assert!(p.proj_fixed_floor_ms().is_none());
}

#[test]
fun projectors_full_tenure_variant() {
    let p = handover_policy::new_handover_full_tenure();
    assert!(!p.proj_is_off());
    assert!(p.proj_is_full_tenure());
    assert!(!p.proj_is_fixed());
    assert!(p.proj_fixed_floor_ms().is_none());
}

#[test]
fun projectors_fixed_variant() {
    let p = handover_policy::new_handover_fixed(phases::duration(42));
    assert!(!p.proj_is_off());
    assert!(!p.proj_is_full_tenure());
    assert!(p.proj_is_fixed());
    assert_eq!(phases::duration_ms(p.proj_fixed_floor_ms().destroy_some()), 42);
}
