// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::rental_escrow_corpus;

// === Imports ===

use usufruct::{
    config::{Self, IntegrationConfig},
    curve_shape_state::{Self, CurveShapeState},
    descent_policy_state::{Self, DescentPolicyState},
    handover_policy_state::{Self, HandoverPolicyState},
    phases,
    price_function_state::{Self, PriceFunctionState},
    retire_policy_state::{Self, RetirePolicyState},
};

// === Errors ===

const EAxisCOutOfRange: u64 = 0;
const EAxisDOutOfRange: u64 = 1;
const EAxisEOutOfRange: u64 = 2;
const EAxisHOutOfRange: u64 = 3;
const EAxisFOutOfRange: u64 = 4;

// === Constants ===

const TENURE_CEILING:        u64 = 100_000;
const MIN_RENT_PRICE:        u64 = 10_000_000_000;
const HANDOVER_COUNTDOWN_C1: u64 = 25_000;
const DESCENT_WINDOW_H1:     u64 = 100_000;
const RETIRE_DEFERRED_F1:    u64 = 10_000_000;
const FIXED_DELTA_VALUE:     u64 = 10_000_000_000;
const COMPOUND_DELTA_BPS:    u64 = 1_000;
const COMPOUND_DELTA_VALUE:  u64 = 1;

// === Structs ===

public struct CorpusEntry has copy, drop, store {
    cfg: IntegrationConfig,
    c:   u8,   // 0..2  HandoverPolicyState
    d:   u8,   // 0..1  PriceFunctionState
    e:   u8,   // 0..6  CurveShapeState pair
    h:   u8,   // 0..1  DescentPolicyState
    f:   u8,   // 0..1  RetirePolicyState
    tag: u64,  // c·10_000 + d·1_000 + e·100 + h·10 + f
}

// === Method Aliases ===

public use fun entry_cfg as CorpusEntry.cfg;
public use fun entry_tag as CorpusEntry.tag;
public use fun entry_c   as CorpusEntry.c;
public use fun entry_d   as CorpusEntry.d;
public use fun entry_e   as CorpusEntry.e;
public use fun entry_h   as CorpusEntry.h;
public use fun entry_f   as CorpusEntry.f;

// === Package Functions ===

/// Full deterministic corpus — 168 entries, one per (c,d,e,h,f) tuple.
/// Call once per test and bind to a local; never inside the iteration loop.
public(package) fun all(): vector<CorpusEntry> {
    let mut entries = vector[];
    let mut c = 0u8;
    while (c <= 2) {
        let mut d = 0u8;
        while (d <= 1) {
            let mut e = 0u8;
            while (e <= 6) {
                let mut h = 0u8;
                while (h <= 1) {
                    let mut f = 0u8;
                    while (f <= 1) {
                        entries.push_back(make_entry(c, d, e, h, f));
                        f = f + 1;
                    };
                    h = h + 1;
                };
                e = e + 1;
            };
            d = d + 1;
        };
        c = c + 1;
    };
    entries
}

/// Single-config lookup by τ2 tag. Validates each decoded axis and returns
/// IntegrationConfig directly — the wrapper carries no new info when the
/// caller already holds the tag.
public(package) fun by_tag(tag: u64): IntegrationConfig {
    let f = (tag % 10) as u8;
    let h = ((tag / 10) % 10) as u8;
    let e = ((tag / 100) % 10) as u8;
    let d = ((tag / 1_000) % 10) as u8;
    let c = (tag / 10_000) as u8;
    assert!(c <= 2, EAxisCOutOfRange);
    assert!(d <= 1, EAxisDOutOfRange);
    assert!(e <= 6, EAxisEOutOfRange);
    assert!(h <= 1, EAxisHOutOfRange);
    assert!(f <= 1, EAxisFOutOfRange);
    build_config(c, d, e, h, f)
}

// --- Filter primitives ---

public(package) fun filter_c(es: vector<CorpusEntry>, c: u8): vector<CorpusEntry> {
    assert!(c <= 2, EAxisCOutOfRange);
    collect_matching_c(es, c)
}

public(package) fun filter_d(es: vector<CorpusEntry>, d: u8): vector<CorpusEntry> {
    assert!(d <= 1, EAxisDOutOfRange);
    collect_matching_d(es, d)
}

public(package) fun filter_e(es: vector<CorpusEntry>, e: u8): vector<CorpusEntry> {
    assert!(e <= 6, EAxisEOutOfRange);
    collect_matching_e(es, e)
}

public(package) fun filter_h(es: vector<CorpusEntry>, h: u8): vector<CorpusEntry> {
    assert!(h <= 1, EAxisHOutOfRange);
    collect_matching_h(es, h)
}

public(package) fun filter_f(es: vector<CorpusEntry>, f: u8): vector<CorpusEntry> {
    assert!(f <= 1, EAxisFOutOfRange);
    collect_matching_f(es, f)
}

// --- Named projections ---

public(package) fun with_handover_instant():    vector<CorpusEntry> { filter_c(all(), 0) }
public(package) fun with_handover_countdown():  vector<CorpusEntry> { filter_c(all(), 1) }
public(package) fun with_handover_fixed_time(): vector<CorpusEntry> { filter_c(all(), 2) }
public(package) fun with_descent_skipped():     vector<CorpusEntry> { filter_h(all(), 0) }
public(package) fun with_descent_window():      vector<CorpusEntry> { filter_h(all(), 1) }
public(package) fun with_retire_immediate():    vector<CorpusEntry> { filter_f(all(), 0) }
public(package) fun with_retire_deferred():     vector<CorpusEntry> { filter_f(all(), 1) }
public(package) fun with_fixed_pricing():       vector<CorpusEntry> { filter_d(all(), 0) }
public(package) fun with_compound_pricing():    vector<CorpusEntry> { filter_d(all(), 1) }

// --- Tag constructor ---

/// Validated τ2 tag. Aborts per-axis if any index is out of range.
public(package) fun tag(c: u8, d: u8, e: u8, h: u8, f: u8): u64 {
    assert!(c <= 2, EAxisCOutOfRange);
    assert!(d <= 1, EAxisDOutOfRange);
    assert!(e <= 6, EAxisEOutOfRange);
    assert!(h <= 1, EAxisHOutOfRange);
    assert!(f <= 1, EAxisFOutOfRange);
    build_tag(c, d, e, h, f)
}

// --- Constant getters ---

public(package) fun tenure_ceiling_const():        u64 { TENURE_CEILING }
public(package) fun min_rent_price_const():        u64 { MIN_RENT_PRICE }
public(package) fun handover_countdown_c1_const(): u64 { HANDOVER_COUNTDOWN_C1 }
public(package) fun descent_window_h1_const():     u64 { DESCENT_WINDOW_H1 }
public(package) fun retire_deferred_f1_const():    u64 { RETIRE_DEFERRED_F1 }
public(package) fun fixed_delta_value_const():     u64 { FIXED_DELTA_VALUE }
public(package) fun compound_delta_bps_const():    u64 { COMPOUND_DELTA_BPS }
public(package) fun compound_delta_value_const():  u64 { COMPOUND_DELTA_VALUE }

// === Private Functions ===

// --- Method alias backing functions ---

public(package) fun entry_cfg(entry: &CorpusEntry): &IntegrationConfig { &entry.cfg }
public(package) fun entry_tag(entry: &CorpusEntry): u64                { entry.tag }
public(package) fun entry_c(entry: &CorpusEntry):   u8                 { entry.c }
public(package) fun entry_d(entry: &CorpusEntry):   u8                 { entry.d }
public(package) fun entry_e(entry: &CorpusEntry):   u8                 { entry.e }
public(package) fun entry_h(entry: &CorpusEntry):   u8                 { entry.h }
public(package) fun entry_f(entry: &CorpusEntry):   u8                 { entry.f }

// --- Construction helpers ---

fun make_entry(c: u8, d: u8, e: u8, h: u8, f: u8): CorpusEntry {
    CorpusEntry {
        cfg: build_config(c, d, e, h, f),
        c,
        d,
        e,
        h,
        f,
        tag: build_tag(c, d, e, h, f),
    }
}

fun build_config(c: u8, d: u8, e: u8, h: u8, f: u8): IntegrationConfig {
    let curve = make_curve(e);
    config::new_config(
        MIN_RENT_PRICE,
        phases::duration(TENURE_CEILING),
        make_handover(c),
        make_descent(h),
        make_retire(f),
        curve,
        curve,
        make_price_function_state(d),
    )
}

fun build_tag(c: u8, d: u8, e: u8, h: u8, f: u8): u64 {
    (c as u64) * 10_000 +
    (d as u64) * 1_000  +
    (e as u64) * 100    +
    (h as u64) * 10     +
    (f as u64)
}

fun make_handover(c: u8): HandoverPolicyState {
    if (c == 0)      { handover_policy_state::new_handover_instant() }
    else if (c == 1) { handover_policy_state::new_handover_countdown(phases::duration(HANDOVER_COUNTDOWN_C1)) }
    else             { handover_policy_state::new_handover_fixed_time() }
}

fun make_price_function_state(d: u8): PriceFunctionState {
    if (d == 0) { price_function_state::new_fixed_delta(FIXED_DELTA_VALUE) }
    else        { price_function_state::new_compound_delta(COMPOUND_DELTA_BPS, COMPOUND_DELTA_VALUE) }
}

fun make_curve(e: u8): CurveShapeState {
    if (e == 0)      { curve_shape_state::new_linear() }
    else if (e == 1) { curve_shape_state::new_smoothstep() }
    else if (e == 2) { curve_shape_state::new_logistic() }
    else if (e == 3) { curve_shape_state::new_power_law(1, 2) }
    else if (e == 4) { curve_shape_state::new_power_law(2, 1) }
    else if (e == 5) { curve_shape_state::new_exponential(2, true) }
    else             { curve_shape_state::new_exponential(2, false) }
}

fun make_descent(h: u8): DescentPolicyState {
    if (h == 0) { descent_policy_state::new_descent_skipped() }
    else        { descent_policy_state::new_descent_window(phases::duration(DESCENT_WINDOW_H1)) }
}

fun make_retire(f: u8): RetirePolicyState {
    if (f == 0) { retire_policy_state::new_retire_immediate() }
    else        { retire_policy_state::new_retire_deferred(phases::duration(RETIRE_DEFERRED_F1)) }
}

// --- Filter helpers (called after axis validation in filter_*) ---

fun collect_matching_c(es: vector<CorpusEntry>, c: u8): vector<CorpusEntry> {
    let mut result = vector[];
    let mut i = 0;
    let n = es.length();
    while (i < n) {
        let entry = es.borrow(i);
        if (entry.c == c) { result.push_back(*entry); };
        i = i + 1;
    };
    result
}

fun collect_matching_d(es: vector<CorpusEntry>, d: u8): vector<CorpusEntry> {
    let mut result = vector[];
    let mut i = 0;
    let n = es.length();
    while (i < n) {
        let entry = es.borrow(i);
        if (entry.d == d) { result.push_back(*entry); };
        i = i + 1;
    };
    result
}

fun collect_matching_e(es: vector<CorpusEntry>, e: u8): vector<CorpusEntry> {
    let mut result = vector[];
    let mut i = 0;
    let n = es.length();
    while (i < n) {
        let entry = es.borrow(i);
        if (entry.e == e) { result.push_back(*entry); };
        i = i + 1;
    };
    result
}

fun collect_matching_h(es: vector<CorpusEntry>, h: u8): vector<CorpusEntry> {
    let mut result = vector[];
    let mut i = 0;
    let n = es.length();
    while (i < n) {
        let entry = es.borrow(i);
        if (entry.h == h) { result.push_back(*entry); };
        i = i + 1;
    };
    result
}

fun collect_matching_f(es: vector<CorpusEntry>, f: u8): vector<CorpusEntry> {
    let mut result = vector[];
    let mut i = 0;
    let n = es.length();
    while (i < n) {
        let entry = es.borrow(i);
        if (entry.f == f) { result.push_back(*entry); };
        i = i + 1;
    };
    result
}

// === Test Functions ===

#[test]
fun all_has_168_entries() {
    assert!(all().length() == 168, 0);
}

#[test]
fun all_tags_consistent_with_axes() {
    // Uniqueness follows structurally: the 5 nested loops in all() generate
    // each (c,d,e,h,f) tuple exactly once, so 168 entries implies 168 distinct
    // tuples. This test verifies the tag stored in each entry equals the formula,
    // completing the proof that tags are unique.
    let entries = all();
    let n = entries.length();
    let mut i = 0;
    while (i < n) {
        let entry = entries.borrow(i);
        let expected = build_tag(entry.c, entry.d, entry.e, entry.h, entry.f);
        assert!(entry.tag == expected, entry.tag);
        i = i + 1;
    };
}

#[test]
fun by_tag_inverts_tag_constructor() {
    let mut c = 0u8;
    while (c <= 2) {
        let mut d = 0u8;
        while (d <= 1) {
            let mut e = 0u8;
            while (e <= 6) {
                let mut h = 0u8;
                while (h <= 1) {
                    let mut f = 0u8;
                    while (f <= 1) {
                        let t = build_tag(c, d, e, h, f);
                        assert!(by_tag(t) == build_config(c, d, e, h, f), t);
                        f = f + 1;
                    };
                    h = h + 1;
                };
                e = e + 1;
            };
            d = d + 1;
        };
        c = c + 1;
    };
}
