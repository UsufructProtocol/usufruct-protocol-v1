// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::phases_tests;

use std::u64;
use std::unit_test::assert_eq;
use usufruct::phases;

// ─── has_passed ───────────────────────────────────────────────────────────────

#[test_only]
public struct HasPassedCase has drop {
    anchor:   u64,
    duration: u64,
    now:      u64,
    expected: bool,
}

#[test]
fun has_passed_table_and_monotone_in_now() {
    let max = u64::max_value!();
    let cases = vector[
        // Boundary triple at (anchor=100, duration=50) → boundary=150
        HasPassedCase { anchor: 100, duration: 50, now: 149, expected: false }, // one before
        HasPassedCase { anchor: 100, duration: 50, now: 150, expected: true  }, // exact
        HasPassedCase { anchor: 100, duration: 50, now: 151, expected: true  }, // one after
        // Zero-duration collapse (boundary == anchor)
        HasPassedCase { anchor: 100, duration: 0,  now: 99,  expected: false },
        HasPassedCase { anchor: 100, duration: 0,  now: 100, expected: true  },
        // Zero-anchor: boundary == duration
        HasPassedCase { anchor: 0,   duration: 50, now: 49,  expected: false },
        HasPassedCase { anchor: 0,   duration: 50, now: 50,  expected: true  },
        // u64::MAX as clock dominates any safe boundary
        HasPassedCase { anchor: 100, duration: 50, now: max, expected: true  },
        // Boundary at u64::MAX exactly (anchor + duration must not overflow)
        HasPassedCase { anchor: max - 1, duration: 1, now: max - 1, expected: false },
        HasPassedCase { anchor: max - 1, duration: 1, now: max,     expected: true  },
    ];
    cases.do_ref!(|c| {
        let result = phases::check_boundary(
            phases::timestamp(c.anchor),
            phases::duration(c.duration),
            phases::timestamp(c.now),
        ).is_crossed();
        assert_eq!(result, c.expected);
    });

    // Invariant: monotone in `now`. The clock-non-decreasing precondition
    // only strengthens the predicate, so once has_passed flips true, it
    // must stay true. Sweep around boundary 150 catches an inverted
    // comparator (`<=` instead of `>=`).
    let mut n: u64 = 100;
    let mut crossed = false;
    while (n <= 200) {
        let cur = phases::check_boundary(
            phases::timestamp(100),
            phases::duration(50),
            phases::timestamp(n),
        ).is_crossed();
        if (crossed) assert!(cur, 0);
        if (cur) crossed = true;
        n = n + 1;
    };
}

#[test, expected_failure(arithmetic_error, location = usufruct::phases)]
fun has_passed_overflow_in_anchor_plus_duration_aborts() {
    // anchor + duration overflows u64 → Move aborts arithmetic.
    phases::check_boundary(
        phases::timestamp(u64::max_value!()),
        phases::duration(1),
        phases::timestamp(u64::max_value!()),
    );
}

// ─── elapsed_since ────────────────────────────────────────────────────────────

#[test_only]
public struct ElapsedSinceCase has drop {
    start:    u64,
    now:      u64,
    expected: u64,
}

#[test]
fun elapsed_since_table_and_reciprocal_when_after_start() {
    let max = u64::max_value!();
    let cases = vector[
        // Saturation: now < start → 0
        ElapsedSinceCase { start: 100, now: 50,  expected: 0   },
        ElapsedSinceCase { start: 100, now: 99,  expected: 0   }, // one before
        // Boundary
        ElapsedSinceCase { start: 100, now: 100, expected: 0   }, // exact
        ElapsedSinceCase { start: 100, now: 101, expected: 1   }, // one after
        // Linear range
        ElapsedSinceCase { start: 100, now: 200, expected: 100 },
        // u64::MAX from origin (full range, no overflow)
        ElapsedSinceCase { start: 0,   now: max, expected: max },
        // Both at MAX
        ElapsedSinceCase { start: max, now: max, expected: 0   },
        // Saturation at MAX (now far below start)
        ElapsedSinceCase { start: max, now: 0,   expected: 0   },
    ];
    cases.do_ref!(|c| {
        let r = phases::duration_ms(phases::elapsed_since(
            phases::timestamp(c.start),
            phases::timestamp(c.now),
        ));
        assert_eq!(r, c.expected);
        // Reciprocal invariant: when no saturation occurs (now >= start),
        // r + start == now — elapsed_since is information-preserving in
        // the non-saturated regime. Catches off-by-one in the subtraction.
        if (c.now >= c.start) assert_eq!(r + c.start, c.now);
    });
}

// ─── boundary_at ──────────────────────────────────────────────────────────────

#[test_only]
public struct BoundaryAtCase has drop {
    anchor:   u64,
    duration: u64,
    expected: u64,
}

#[test]
fun boundary_at_table() {
    let max = u64::max_value!();
    let cases = vector[
        BoundaryAtCase { anchor: 100,     duration: 50,  expected: 150 },
        // duration = 0 returns anchor (boundary collapses)
        BoundaryAtCase { anchor: 100,     duration: 0,   expected: 100 },
        // anchor = 0 returns duration
        BoundaryAtCase { anchor: 0,       duration: 50,  expected: 50  },
        BoundaryAtCase { anchor: 0,       duration: 0,   expected: 0   },
        // Edge: sum exactly at u64::MAX (last representable boundary)
        BoundaryAtCase { anchor: max - 1, duration: 1,   expected: max },
        BoundaryAtCase { anchor: 1,       duration: max - 1, expected: max },
    ];
    cases.do_ref!(|c| {
        let result = phases::timestamp_ms(phases::boundary_at(
            phases::timestamp(c.anchor),
            phases::duration(c.duration),
        ));
        assert_eq!(result, c.expected);
    });
}

#[test, expected_failure(arithmetic_error, location = usufruct::phases)]
fun boundary_at_overflow_aborts() {
    // u64::MAX + 1 overflows. Pinned: Move's `+` aborts on overflow rather
    // than wrapping; this is the contract `boundary_at` inherits.
    phases::boundary_at(phases::timestamp(u64::max_value!()), phases::duration(1));
}

// ─── earliest ─────────────────────────────────────────────────────────────────

#[test_only]
public struct EarliestCase has drop {
    a:        u64,
    b:        u64,
    expected: u64,
}

#[test]
fun earliest_table_and_commutative() {
    let max = u64::max_value!();
    let cases = vector[
        EarliestCase { a: 100, b: 200, expected: 100 }, // a < b
        EarliestCase { a: 200, b: 100, expected: 100 }, // a > b
        EarliestCase { a: 100, b: 100, expected: 100 }, // a == b (idempotent)
        // Extremes: 0 always wins, MAX always loses (as long as the other isn't MAX)
        EarliestCase { a: 0,   b: max, expected: 0   },
        EarliestCase { a: max, b: 0,   expected: 0   },
        EarliestCase { a: 0,   b: 0,   expected: 0   },
        EarliestCase { a: max, b: max, expected: max },
    ];
    cases.do_ref!(|c| {
        let result   = phases::timestamp_ms(phases::earliest(phases::timestamp(c.a), phases::timestamp(c.b)));
        let result_r = phases::timestamp_ms(phases::earliest(phases::timestamp(c.b), phases::timestamp(c.a)));
        assert_eq!(result, c.expected);
        // Commutativity invariant: earliest is symmetric in its arguments.
        // Catches accidentally swapping `min` for a non-symmetric op.
        assert_eq!(result_r, c.expected);
    });
}

// ─── sister identity: has_passed ⇔ now >= boundary_at ─────────────────────────

#[test_only]
public struct SisterIdentityCase has drop {
    anchor:   u64,
    duration: u64,
    now:      u64,
}

// Architectural invariant: the bool view (has_passed) and the u64 view
// (boundary_at) must agree on every input. If anyone changes one without
// updating the other — or introduces a comparator drift — this test
// catches it. This is the time-layer analogue of curve_shape_state_tests'
// "P-D1 dispatch equivalence" (lines 178-256): the layer promises
// two views of the same concept; the test pins them to one truth.
#[test]
fun has_passed_iff_now_ge_boundary_at() {
    let cases = vector[
        // Boundary triple at (anchor=100, duration=50)
        SisterIdentityCase { anchor: 100, duration: 50, now: 100 }, // pre-boundary
        SisterIdentityCase { anchor: 100, duration: 50, now: 149 }, // one before
        SisterIdentityCase { anchor: 100, duration: 50, now: 150 }, // exact
        SisterIdentityCase { anchor: 100, duration: 50, now: 151 }, // one after
        SisterIdentityCase { anchor: 100, duration: 50, now: 200 }, // well after
        // Zero-duration collapse
        SisterIdentityCase { anchor: 100, duration: 0,  now: 99  },
        SisterIdentityCase { anchor: 100, duration: 0,  now: 100 },
        SisterIdentityCase { anchor: 100, duration: 0,  now: 101 },
        // Zero everywhere
        SisterIdentityCase { anchor: 0,   duration: 0,  now: 0   },
        SisterIdentityCase { anchor: 0,   duration: 50, now: 49  },
        SisterIdentityCase { anchor: 0,   duration: 50, now: 50  },
    ];
    cases.do_ref!(|c| {
        let bool_view = phases::check_boundary(
            phases::timestamp(c.anchor),
            phases::duration(c.duration),
            phases::timestamp(c.now),
        ).is_crossed();
        let u64_view  = c.now >= phases::timestamp_ms(phases::boundary_at(
            phases::timestamp(c.anchor),
            phases::duration(c.duration),
        ));
        assert_eq!(bool_view, u64_view);
    });
}
