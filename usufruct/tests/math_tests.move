// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::math_tests;

use std::u64;
use std::u128;
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
    let u64_max = u64::max_value!();
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
        let result = math::mul_div(case.a, case.b, case.c);
        assert_eq!(result, case.expected);
        // Invariant: result*c ≤ a*b < (result+1)*c
        // For u64 inputs, (result+1)*c ≤ 2^64 * (2^64-1) < u128::MAX — no overflow.
        let ab = (case.a as u128) * (case.b as u128);
        let r = result as u128;
        let c = case.c as u128;
        assert!(r * c <= ab, 0);
        assert!(ab < (r + 1) * c, 1);
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
    math::mul_div(u64::max_value!(), 2, 1);
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
    math::mul_div(u64::max_value!(), u64::max_value!(), 1);
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
        NthRootCase { n: (u64::max_value!() as u128),              d: 2, expected: 4294967295  }, // 2^64-1, floor=2^32-1
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
        NthRootCase { n: u128::max_value!(),                       d: 2, expected: (u64::max_value!() as u128) }, // u128::MAX, floor=2^64-1
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

#[test]
fun nth_root_u128_largest_perfect_powers() {
    // For each d, exercise the largest perfect d-th power representable in u128
    // and its floor neighbor. The table only goes up to 2^96 for d∈{3,4} and
    // covers u128::MAX (a non-power) for d=2; this fills the perfect-power
    // ceiling for all three degrees.

    // d = 2: (u64::MAX)^2 = 2^128 - 2^65 + 1, just under u128::MAX.
    // (k+1)^2 mathematically exceeds u128, so floor remains k for k_sq + 1.
    let k: u128 = u64::max_value!() as u128;
    let k_sq = k * k;
    assert_eq!(math::nth_root_u128(k_sq, 2), k);
    assert_eq!(math::nth_root_u128(k_sq - 1, 2), k - 1);
    assert_eq!(math::nth_root_u128(k_sq + 1, 2), k);

    // d = 3: (2^42)^3 = 2^126.
    let cube_base: u128 = 1u128 << 42;
    let cube_n = pow_u128(cube_base, 3);
    assert_eq!(math::nth_root_u128(cube_n, 3), cube_base);
    assert_eq!(math::nth_root_u128(cube_n - 1, 3), cube_base - 1);

    // d = 4: (2^31)^4 = 2^124.
    let q_base: u128 = 1u128 << 31;
    let q_n = pow_u128(q_base, 4);
    assert_eq!(math::nth_root_u128(q_n, 4), q_base);
    assert_eq!(math::nth_root_u128(q_n - 1, 4), q_base - 1);
}

#[test]
fun nth_root_u128_non_power_of_2_roundtrip() {
    // All large boundary cases in the table use 2^k bases; this guards against
    // Newton convergence bugs that hide behind power-of-2 alignment.
    let bases: vector<u128> = vector[7, 13, 100, 1000];
    let ds: vector<u32> = vector[2, 3, 4];
    let mut bi = 0;
    let blen = bases.length();
    while (bi < blen) {
        let k = bases[bi];
        let mut di = 0;
        let dlen = ds.length();
        while (di < dlen) {
            let d = ds[di];
            let kd = pow_u128(k, d);
            assert_eq!(math::nth_root_u128(kd, d), k);
            assert_eq!(math::nth_root_u128(kd - 1, d), k - 1);
            di = di + 1;
        };
        bi = bi + 1;
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
        let u128_max = u128::max_value!();
        if (r1 > u128_max / r1) true
        else n < r1 * r1
    } else if (d == 3) {
        n < r1 * r1 * r1
    } else {
        n < r1 * r1 * r1 * r1
    }
}
