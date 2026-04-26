// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::math_tests;

use std::unit_test::assert_eq;
use usufruct::math;

// ─── mul_div ───────────────────────────────────────────────────────────────

#[test_only]
public struct MulDivCase has drop {
    a: u64,
    b: u64,
    c: u64,
    expected: u64,
}

#[test]
fun mul_div_table() {
    let u64_max: u64 = 18446744073709551615;
    let cases = vector[
        MulDivCase { a: 0,              b: 5,              c: 3,              expected: 0           },
        MulDivCase { a: 5,              b: 0,              c: 3,              expected: 0           },
        MulDivCase { a: 6,              b: 7,              c: 3,              expected: 14          },
        MulDivCase { a: 1,              b: 1,              c: 3,              expected: 0           },
        MulDivCase { a: 2,              b: 1,              c: 3,              expected: 0           },
        MulDivCase { a: 3,              b: 1,              c: 3,              expected: 1           },
        MulDivCase { a: 5,              b: 1,              c: 3,              expected: 1           },
        MulDivCase { a: 6,              b: 1,              c: 3,              expected: 2           },
        MulDivCase { a: 1_000_000_000, b: 1_000_000_000, c: 1_000_000_000, expected: 1_000_000_000 },
        MulDivCase { a: 5_000_000_000, b: 5_000_000_000, c: 5_000_000_000, expected: 5_000_000_000 },
        MulDivCase { a: u64_max,       b: 1,              c: 1,              expected: u64_max     },
        MulDivCase { a: u64_max,       b: u64_max,        c: u64_max,        expected: u64_max     },
        MulDivCase { a: u64_max,       b: 1,              c: 2,              expected: u64_max / 2 },
        // 2^63: intermediate = 2^64 > u64::MAX; final = 2^63 fits
        MulDivCase { a: 9223372036854775808, b: 2, c: 2, expected: 9223372036854775808 },
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let case = &cases[i];
        assert_eq!(math::mul_div(case.a, case.b, case.c), case.expected);
        i = i + 1;
    };
}

#[test]
#[expected_failure(arithmetic_error, location = usufruct::math)]
fun mul_div_c_zero_aborts() {
    math::mul_div(1, 1, 0);
}

#[test]
#[expected_failure(arithmetic_error, location = usufruct::math)]
fun mul_div_all_zero_aborts() {
    math::mul_div(0, 0, 0);
}

#[test]
#[expected_failure(abort_code = math::EMulDivOverflow, location = usufruct::math)]
fun mul_div_overflow_max_times_2() {
    math::mul_div(18446744073709551615, 2, 1);
}

#[test]
#[expected_failure(abort_code = math::EMulDivOverflow, location = usufruct::math)]
fun mul_div_overflow_exact_u64_boundary() {
    // 2^32 * 2^32 = 2^64 = u64::MAX + 1
    math::mul_div(4294967296, 4294967296, 1);
}

#[test]
#[expected_failure(abort_code = math::EMulDivOverflow, location = usufruct::math)]
fun mul_div_overflow_max_times_max() {
    math::mul_div(18446744073709551615, 18446744073709551615, 1);
}

// ─── nth_root_u128 ─────────────────────────────────────────────────────────

#[test_only]
public struct NthRootCase has drop {
    n: u128,
    d: u32,
    expected: u128,
}

#[test]
fun nth_root_u128_table() {
    let cases = vector[
        // d = 2
        NthRootCase { n: 0,                                        d: 2, expected: 0           },
        NthRootCase { n: 1,                                        d: 2, expected: 1           },
        NthRootCase { n: 2,                                        d: 2, expected: 1           },
        NthRootCase { n: 3,                                        d: 2, expected: 1           },
        NthRootCase { n: 4,                                        d: 2, expected: 2           },
        NthRootCase { n: 9,                                        d: 2, expected: 3           },
        NthRootCase { n: 10,                                       d: 2, expected: 3           },
        NthRootCase { n: 15,                                       d: 2, expected: 3           },
        NthRootCase { n: 16,                                       d: 2, expected: 4           },
        NthRootCase { n: 18446744073709551616,                     d: 2, expected: 4294967296  }, // 2^64, sqrt=2^32
        NthRootCase { n: 18446744073709551615,                     d: 2, expected: 4294967295  }, // 2^64-1, floor=2^32-1
        // d = 3
        NthRootCase { n: 0,                                        d: 3, expected: 0           },
        NthRootCase { n: 1,                                        d: 3, expected: 1           },
        NthRootCase { n: 7,                                        d: 3, expected: 1           },
        NthRootCase { n: 8,                                        d: 3, expected: 2           },
        NthRootCase { n: 26,                                       d: 3, expected: 2           },
        NthRootCase { n: 27,                                       d: 3, expected: 3           },
        // d = 4
        NthRootCase { n: 0,                                        d: 4, expected: 0           },
        NthRootCase { n: 1,                                        d: 4, expected: 1           },
        NthRootCase { n: 15,                                       d: 4, expected: 1           },
        NthRootCase { n: 16,                                       d: 4, expected: 2           },
        NthRootCase { n: 80,                                       d: 4, expected: 2           },
        NthRootCase { n: 81,                                       d: 4, expected: 3           },
        // large values
        NthRootCase { n: 340282366920938463463374607431768211455, d: 2, expected: 18446744073709551615 }, // u128::MAX
        NthRootCase { n: 79228162514264337593543950336,           d: 3, expected: 4294967296  }, // 2^96, cbrt=2^32
        NthRootCase { n: 79228162514264337593543950335,           d: 3, expected: 4294967295  }, // 2^96-1
        NthRootCase { n: 79228162514264337593543950336,           d: 4, expected: 16777216    }, // 2^96, 4rt=2^24
        NthRootCase { n: 79228162514264337593543950335,           d: 4, expected: 16777215    }, // 2^96-1
    ];
    let mut i = 0;
    let len = cases.length();
    while (i < len) {
        let case = &cases[i];
        let result = math::nth_root_u128(case.n, case.d);
        assert_eq!(result, case.expected);
        // Invariant: result^d ≤ n < (result+1)^d
        assert!(pow_u128(result, case.d) <= case.n, 0);
        assert!(upper_bound_holds(case.n, result, case.d), 1);
        i = i + 1;
    };
}

// result^d, valid for d in {2,3,4} and result in range safe per spec §3
fun pow_u128(base: u128, d: u32): u128 {
    if (d == 2) base * base
    else if (d == 3) base * base * base
    else base * base * base * base
}

// Returns true if n < (result+1)^d.
// For d=2 and result=2^64-1, (result+1)^2=2^128 overflows u128 — detected via
// division and treated as trivially satisfied (any u128 n < true mathematical value).
fun upper_bound_holds(n: u128, result: u128, d: u32): bool {
    let r1 = result + 1;
    if (d == 2) {
        let u128_max: u128 = 340282366920938463463374607431768211455;
        if (r1 > u128_max / r1) true
        else n < r1 * r1
    } else if (d == 3) {
        n < r1 * r1 * r1
    } else {
        n < r1 * r1 * r1 * r1
    }
}
