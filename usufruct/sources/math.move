// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::math;

// === Imports ===

use std::u64;

// === Errors ===

const EMulDivOverflow: u64 = 0;

// === Constants ===

// === Structs ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

public(package) fun mul_div(a: u64, b: u64, c: u64): u64 {
    let num: u128 = (a as u128) * (b as u128);
    let res: u128 = num / (c as u128);
    assert!(res <= (u64::max_value!() as u128), EMulDivOverflow);
    res as u64
}

public(package) fun nth_root_u128(n: u128, d: u32): u128 {
    if (n == 0) return 0;
    if (n == 1) return 1;

    let bits = bit_length(n);
    let shift = (bits + d - 1) / d;
    let mut x: u128 = 1u128 << (shift as u8);

    let d_128: u128 = d as u128;
    let d_minus_one: u128 = d_128 - 1;

    loop {
        let x_pow: u128 = match (d) {
            2 => x,
            3 => x * x,
            _ => x * x * x,
        };
        let x_new = (d_minus_one * x + n / x_pow) / d_128;
        if (x_new >= x) return x;
        x = x_new;
    }
}

// === Private Functions ===

// Number of bits needed to represent x (= floor(log2(x)) + 1 for x >= 1).
// Only called for x >= 2; the +1 at the end is always valid.
fun bit_length(x: u128): u32 {
    let mut len: u32 = 0;
    let mut v = x;
    if (v >> 64 != 0) { len = len + 64; v = v >> 64; };
    if (v >> 32 != 0) { len = len + 32; v = v >> 32; };
    if (v >> 16 != 0) { len = len + 16; v = v >> 16; };
    if (v >> 8  != 0) { len = len + 8;  v = v >> 8;  };
    if (v >> 4  != 0) { len = len + 4;  v = v >> 4;  };
    if (v >> 2  != 0) { len = len + 2;  v = v >> 2;  };
    if (v >> 1  != 0) { len = len + 1;              };
    len + 1
}

// === Test Functions ===
