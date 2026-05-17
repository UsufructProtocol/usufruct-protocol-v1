// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module usufruct::escrow_corpus;

// === Imports ===

use usufruct::{
    policy_ensemble::{Self, PolicyEnsemble},
    curve_shape_policy::{Self, CurveShapePolicy},
    auction_window_policy::{Self, AuctionWindowPolicy},
    handover_policy::{Self, HandoverPolicy},
    math,
    floor_price_policy,
    tenure_extend_policy::{Self, TenureExtendPolicy},
    tenure_duration_policy,
    monetary,
    phases,
    price_escalation_policy::{Self, PriceEscalationPolicy},
    commitment_policy::{Self, CommitmentPolicy},
};

// === Errors ===

const EAxisCOutOfRange: u64 = 0;
const EAxisDOutOfRange: u64 = 1;
const EAxisEOutOfRange: u64 = 2;
const EAxisHOutOfRange: u64 = 3;
const EAxisFOutOfRange: u64 = 4;
const EAxisMOutOfRange: u64 = 5;

// === Constants ===

const TENURE_CEILING:         u64 = 100_000;
const MIN_RENT_PRICE:         u64 = 10_000_000_000;
const HANDOVER_COUNTDOWN_C1:  u64 = 25_000;
const HANDOVER_RANDOM_MIN_C3: u64 = 10_000;
const HANDOVER_RANDOM_MAX_C3: u64 = 75_000;
const DESCENT_WINDOW_H1:      u64 = 100_000;
const DESCENT_RANDOM_MIN_H2:  u64 = 10_000;
const DESCENT_RANDOM_MAX_H2:  u64 = 90_000;
const RETIRE_DEFERRED_F1:     u64 = 10_000_000;
const FIXED_DELTA_VALUE:      u64 = 10_000_000_000;
const COMPOUND_DELTA_BPS:     u64 = 1_000;
const COMPOUND_DELTA_VALUE:   u64 = 1;

// === Structs ===

public struct CorpusEntry has copy, drop, store {
    ensemble: PolicyEnsemble,
    c:   u8,   // 0..3  HandoverPolicy
    d:   u8,   // 0..1  PriceEscalationPolicy
    e:   u8,   // 0..6  CurveShapePolicy pair
    h:   u8,   // 0..2  AuctionWindowPolicy
    f:   u8,   // 0..1  CommitmentPolicy
    m:   u8,   // 0..1  TenureExtendPolicy
    tag: u64,  // m·100_000 + c·10_000 + d·1_000 + e·100 + h·10 + f
}

// === Method Aliases ===

public use fun entry_cfg as CorpusEntry.ensemble;
public use fun entry_tag as CorpusEntry.tag;
public use fun entry_c   as CorpusEntry.c;
public use fun entry_d   as CorpusEntry.d;
public use fun entry_e   as CorpusEntry.e;
public use fun entry_h   as CorpusEntry.h;
public use fun entry_f   as CorpusEntry.f;
public use fun entry_m   as CorpusEntry.m;

// === Package Functions ===

/// Full deterministic corpus — 672 entries, one per (m,c,d,e,h,f) tuple.
///   m: 0..1  TenureExtendPolicy (Single, Multi)
///   c: 0..3  HandoverPolicy     (Instant, Countdown, FixedTime, RandomInRange)
///   d: 0..1  PriceEscalationPolicy      (FixedDelta, CompoundDelta)
///   e: 0..6  CurveShapePolicy pair    (Linear..Exponential)
///   h: 0..2  AuctionWindowPolicy      (Skipped, Window, RandomInRange)
///   f: 0..1  CommitmentPolicy       (Immediate, Deferred)
///
/// Requires --gas-limit ≥ 100_000_000.
/// Call once per test and bind to a local; never inside the iteration loop.
public(package) fun all(): vector<CorpusEntry> {
    let mut entries = make_full_slice(0);
    entries.append(make_full_slice(1));
    entries
}

/// 336 entries: Single cycle (m=0), full axis cross-product.
public(package) fun all_single(): vector<CorpusEntry> { make_full_slice(0) }

/// 336 entries: Multi cycle (m=1), full axis cross-product.
public(package) fun all_multi(): vector<CorpusEntry> { make_full_slice(1) }

/// Filtered views — derive from all() for full coverage.
public(package) fun all_random_handover():       vector<CorpusEntry> { filter_c(all_single(), 3) }
public(package) fun all_random_handover_multi(): vector<CorpusEntry> { filter_c(all_multi(),  3) }
public(package) fun all_random_descent():        vector<CorpusEntry> { filter_h(all_single(), 2) }
public(package) fun all_random_descent_multi():  vector<CorpusEntry> { filter_h(all_multi(),  2) }

/// Single-config lookup by τ2 tag. Validates each decoded axis and returns
/// PolicyEnsemble directly — the wrapper carries no new info when the
/// caller already holds the tag.
public(package) fun by_tag(tag: u64): PolicyEnsemble {
    let f = (tag % 10) as u8;
    let h = ((tag / 10) % 10) as u8;
    let e = ((tag / 100) % 10) as u8;
    let d = ((tag / 1_000) % 10) as u8;
    let c = ((tag / 10_000) % 10) as u8;
    let m = (tag / 100_000) as u8;
    assert!(m <= 1, EAxisMOutOfRange);
    assert!(c <= 3, EAxisCOutOfRange);
    assert!(d <= 1, EAxisDOutOfRange);
    assert!(e <= 6, EAxisEOutOfRange);
    assert!(h <= 2, EAxisHOutOfRange);
    assert!(f <= 1, EAxisFOutOfRange);
    build_config(c, d, e, h, f, m)
}

// --- Filter primitives ---

public(package) fun filter_c(es: vector<CorpusEntry>, c: u8): vector<CorpusEntry> {
    assert!(c <= 3, EAxisCOutOfRange);
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
    assert!(h <= 2, EAxisHOutOfRange);
    collect_matching_h(es, h)
}

public(package) fun filter_f(es: vector<CorpusEntry>, f: u8): vector<CorpusEntry> {
    assert!(f <= 1, EAxisFOutOfRange);
    collect_matching_f(es, f)
}

public(package) fun filter_m(es: vector<CorpusEntry>, m: u8): vector<CorpusEntry> {
    assert!(m <= 1, EAxisMOutOfRange);
    collect_matching_m(es, m)
}

// --- Named projections ---

public(package) fun with_handover_instant():    vector<CorpusEntry> { filter_c(all(), 0) }
public(package) fun with_handover_countdown():  vector<CorpusEntry> { filter_c(all(), 1) }
public(package) fun with_handover_fixed_time(): vector<CorpusEntry> { filter_c(all(), 2) }
public(package) fun with_handover_random():     vector<CorpusEntry> { all_random_handover() }
public(package) fun with_descent_skipped():     vector<CorpusEntry> { filter_h(all(), 0) }
public(package) fun with_descent_window():      vector<CorpusEntry> { filter_h(all(), 1) }
public(package) fun with_descent_random():      vector<CorpusEntry> { all_random_descent() }
public(package) fun with_retire_immediate():    vector<CorpusEntry> { filter_f(all(), 0) }
public(package) fun with_retire_deferred():     vector<CorpusEntry> { filter_f(all(), 1) }
public(package) fun with_fixed_pricing():       vector<CorpusEntry> { filter_d(all(), 0) }
public(package) fun with_compound_pricing():    vector<CorpusEntry> { filter_d(all(), 1) }
public(package) fun with_cycles_single():       vector<CorpusEntry> { all() }
public(package) fun with_cycles_multi():        vector<CorpusEntry> { all_multi() }

/// Rebuild `ensemble` with a different `min_rent_price` (Fixed policy). All other fields unchanged.
public(package) fun with_min_rent_price(ensemble: PolicyEnsemble, price_mist: u64): PolicyEnsemble {
    policy_ensemble::new_ensemble(
        floor_price_policy::new_fixed(monetary::price(price_mist)),
        *policy_ensemble::proj_tenure_duration(&ensemble),
        *policy_ensemble::proj_tenure_extend(&ensemble),
        *policy_ensemble::proj_handover(&ensemble),
        *policy_ensemble::proj_auction_window(&ensemble),
        *policy_ensemble::proj_credit_shape(&ensemble),
        *policy_ensemble::proj_auction_shape(&ensemble),
        *policy_ensemble::proj_price_escalation(&ensemble),
    )
}

/// Rebuild `ensemble` with a random-in-range `min_rent_price`. All other fields unchanged.
public(package) fun with_random_min_rent_price(ensemble: PolicyEnsemble, min_mist: u64, max_mist: u64): PolicyEnsemble {
    policy_ensemble::new_ensemble(
        floor_price_policy::new_random_in_range(monetary::price(min_mist), monetary::price(max_mist)),
        *policy_ensemble::proj_tenure_duration(&ensemble),
        *policy_ensemble::proj_tenure_extend(&ensemble),
        *policy_ensemble::proj_handover(&ensemble),
        *policy_ensemble::proj_auction_window(&ensemble),
        *policy_ensemble::proj_credit_shape(&ensemble),
        *policy_ensemble::proj_auction_shape(&ensemble),
        *policy_ensemble::proj_price_escalation(&ensemble),
    )
}

/// Rebuild `ensemble` with a different `tenure_ceiling` (Fixed policy). All other fields unchanged.
public(package) fun with_tenure_ceiling(ensemble: PolicyEnsemble, ceiling_ms: u64): PolicyEnsemble {
    policy_ensemble::new_ensemble(
        *policy_ensemble::proj_floor_price(&ensemble),
        tenure_duration_policy::new_fixed(phases::duration(ceiling_ms)),
        *policy_ensemble::proj_tenure_extend(&ensemble),
        *policy_ensemble::proj_handover(&ensemble),
        *policy_ensemble::proj_auction_window(&ensemble),
        *policy_ensemble::proj_credit_shape(&ensemble),
        *policy_ensemble::proj_auction_shape(&ensemble),
        *policy_ensemble::proj_price_escalation(&ensemble),
    )
}

/// Rebuild `ensemble` with a random-in-range `tenure_ceiling`. All other fields unchanged.
public(package) fun with_random_tenure_ceiling(ensemble: PolicyEnsemble, min_ms: u64, max_ms: u64): PolicyEnsemble {
    policy_ensemble::new_ensemble(
        *policy_ensemble::proj_floor_price(&ensemble),
        tenure_duration_policy::new_random_in_range(phases::duration(min_ms), phases::duration(max_ms)),
        *policy_ensemble::proj_tenure_extend(&ensemble),
        *policy_ensemble::proj_handover(&ensemble),
        *policy_ensemble::proj_auction_window(&ensemble),
        *policy_ensemble::proj_credit_shape(&ensemble),
        *policy_ensemble::proj_auction_shape(&ensemble),
        *policy_ensemble::proj_price_escalation(&ensemble),
    )
}

/// Rebuild `ensemble` with a different `tenure_cycles` policy. All other fields unchanged.
public(package) fun with_tenure_cycles(ensemble: PolicyEnsemble, policy: TenureExtendPolicy): PolicyEnsemble {
    policy_ensemble::new_ensemble(
        *policy_ensemble::proj_floor_price(&ensemble),
        *policy_ensemble::proj_tenure_duration(&ensemble),
        policy,
        *policy_ensemble::proj_handover(&ensemble),
        *policy_ensemble::proj_auction_window(&ensemble),
        *policy_ensemble::proj_credit_shape(&ensemble),
        *policy_ensemble::proj_auction_shape(&ensemble),
        *policy_ensemble::proj_price_escalation(&ensemble),
    )
}

// --- Tag constructor ---

/// Validated τ2 tag — m=0 (Single cycles). Backward compatible with all existing callers.
public(package) fun tag(c: u8, d: u8, e: u8, h: u8, f: u8): u64 {
    assert!(c <= 3, EAxisCOutOfRange);
    assert!(d <= 1, EAxisDOutOfRange);
    assert!(e <= 6, EAxisEOutOfRange);
    assert!(h <= 2, EAxisHOutOfRange);
    assert!(f <= 1, EAxisFOutOfRange);
    build_tag(c, d, e, h, f, 0)
}

/// Validated τ2 tag with explicit tenure-cycles axis.
public(package) fun tag_with_cycles(c: u8, d: u8, e: u8, h: u8, f: u8, m: u8): u64 {
    assert!(m <= 1, EAxisMOutOfRange);
    assert!(c <= 3, EAxisCOutOfRange);
    assert!(d <= 1, EAxisDOutOfRange);
    assert!(e <= 6, EAxisEOutOfRange);
    assert!(h <= 2, EAxisHOutOfRange);
    assert!(f <= 1, EAxisFOutOfRange);
    build_tag(c, d, e, h, f, m)
}

// --- Constant getters ---

public(package) fun tenure_ceiling_const():           u64 { TENURE_CEILING }
public(package) fun min_rent_price_const():           u64 { MIN_RENT_PRICE }
public(package) fun handover_countdown_c1_const():    u64 { HANDOVER_COUNTDOWN_C1 }
public(package) fun handover_random_min_c3_const():   u64 { HANDOVER_RANDOM_MIN_C3 }
public(package) fun handover_random_max_c3_const():   u64 { HANDOVER_RANDOM_MAX_C3 }
public(package) fun descent_window_h1_const():        u64 { DESCENT_WINDOW_H1 }
public(package) fun descent_random_min_h2_const():    u64 { DESCENT_RANDOM_MIN_H2 }
public(package) fun descent_random_max_h2_const():    u64 { DESCENT_RANDOM_MAX_H2 }
public(package) fun retire_deferred_f1_const():       u64 { RETIRE_DEFERRED_F1 }
public(package) fun fixed_delta_value_const():        u64 { FIXED_DELTA_VALUE }
public(package) fun compound_delta_bps_const():       u64 { COMPOUND_DELTA_BPS }
public(package) fun compound_delta_value_const():     u64 { COMPOUND_DELTA_VALUE }

// === Private Functions ===

// --- Method alias backing functions ---

public(package) fun entry_cfg(entry: &CorpusEntry): &PolicyEnsemble { &entry.ensemble }
public(package) fun entry_tag(entry: &CorpusEntry): u64                { entry.tag }
public(package) fun entry_c(entry: &CorpusEntry):   u8                 { entry.c }
public(package) fun entry_d(entry: &CorpusEntry):   u8                 { entry.d }
public(package) fun entry_e(entry: &CorpusEntry):   u8                 { entry.e }
public(package) fun entry_h(entry: &CorpusEntry):   u8                 { entry.h }
public(package) fun entry_f(entry: &CorpusEntry):   u8                 { entry.f }
public(package) fun entry_m(entry: &CorpusEntry):   u8                 { entry.m }

// --- Construction helpers ---

fun assert_tags_consistent(entries: vector<CorpusEntry>) {
    let n = entries.length();
    let mut i = 0;
    while (i < n) {
        let entry = entries.borrow(i);
        let expected = build_tag(entry.c, entry.d, entry.e, entry.h, entry.f, entry.m);
        assert!(entry.tag == expected, entry.tag);
        i = i + 1;
    };
}

fun assert_by_tag_roundtrips(entries: vector<CorpusEntry>) {
    let n = entries.length();
    let mut i = 0;
    while (i < n) {
        let entry = entries.borrow(i);
        assert!(by_tag(entry.tag) == *entry.ensemble(), entry.tag);
        i = i + 1;
    };
}

// Full cross-product: c=0..3, d=0..1, e=0..6, h=0..2, f=0..1 → 4×2×7×3×2 = 336 entries.
fun make_full_slice(m: u8): vector<CorpusEntry> {
    let mut entries = vector[];
    let mut c = 0u8;
    while (c <= 3) {
        let mut d = 0u8;
        while (d <= 1) {
            let mut e = 0u8;
            while (e <= 6) {
                let mut h = 0u8;
                while (h <= 2) {
                    let mut f = 0u8;
                    while (f <= 1) {
                        entries.push_back(make_entry(c, d, e, h, f, m));
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

fun make_entry(c: u8, d: u8, e: u8, h: u8, f: u8, m: u8): CorpusEntry {
    CorpusEntry {
        ensemble: build_config(c, d, e, h, f, m),
        c,
        d,
        e,
        h,
        f,
        m,
        tag: build_tag(c, d, e, h, f, m),
    }
}

/// CommitmentPolicy for the given tag (f axis: 0=Immediate, 1=Deferred).
public(package) fun commitment_by_tag(tag: u64): CommitmentPolicy {
    make_commitment((tag % 10) as u8)
}

fun build_config(c: u8, d: u8, e: u8, h: u8, _f: u8, m: u8): PolicyEnsemble {
    let curve = make_curve(e);
    policy_ensemble::new_ensemble(
        floor_price_policy::new_fixed(monetary::price(MIN_RENT_PRICE)),
        tenure_duration_policy::new_fixed(phases::duration(TENURE_CEILING)),
        make_tenure_cycles(m),
        make_handover(c),
        make_descent(h),
        curve,
        curve,
        make_price_function_state(d),
    )
}

fun build_tag(c: u8, d: u8, e: u8, h: u8, f: u8, m: u8): u64 {
    (m as u64) * 100_000 +
    (c as u64) * 10_000  +
    (d as u64) * 1_000   +
    (e as u64) * 100     +
    (h as u64) * 10      +
    (f as u64)
}

fun make_handover(c: u8): HandoverPolicy {
    if (c == 0)      { handover_policy::new_handover_instant() }
    else if (c == 1) { handover_policy::new_handover_countdown(phases::duration(HANDOVER_COUNTDOWN_C1)) }
    else if (c == 2) { handover_policy::new_handover_fixed_time() }
    else             { handover_policy::new_handover_random_in_range(phases::duration(HANDOVER_RANDOM_MIN_C3), phases::duration(HANDOVER_RANDOM_MAX_C3)) }
}

fun make_price_function_state(d: u8): PriceEscalationPolicy {
    if (d == 0) { price_escalation_policy::new_fixed_delta(monetary::price(FIXED_DELTA_VALUE)) }
    else        { price_escalation_policy::new_compound_delta(math::bps(COMPOUND_DELTA_BPS), monetary::price(COMPOUND_DELTA_VALUE)) }
}

fun make_curve(e: u8): CurveShapePolicy {
    if (e == 0)      { curve_shape_policy::new_linear() }
    else if (e == 1) { curve_shape_policy::new_smoothstep() }
    else if (e == 2) { curve_shape_policy::new_logistic() }
    else if (e == 3) { curve_shape_policy::new_power_law(1, 2) }
    else if (e == 4) { curve_shape_policy::new_power_law(2, 1) }
    else if (e == 5) { curve_shape_policy::new_exponential(2, true) }
    else             { curve_shape_policy::new_exponential(2, false) }
}

fun make_descent(h: u8): AuctionWindowPolicy {
    if (h == 0)      { auction_window_policy::new_descent_skipped() }
    else if (h == 1) { auction_window_policy::new_descent_window(phases::duration(DESCENT_WINDOW_H1)) }
    else             { auction_window_policy::new_descent_random_in_range(phases::duration(DESCENT_RANDOM_MIN_H2), phases::duration(DESCENT_RANDOM_MAX_H2)) }
}

fun make_tenure_cycles(m: u8): TenureExtendPolicy {
    if (m == 0) { tenure_extend_policy::new_single() }
    else        { tenure_extend_policy::new_multi() }
}

fun make_commitment(f: u8): CommitmentPolicy {
    if (f == 0) { commitment_policy::new_immediate() }
    else        { commitment_policy::new_deferred(phases::duration(RETIRE_DEFERRED_F1)) }
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

fun collect_matching_m(es: vector<CorpusEntry>, m: u8): vector<CorpusEntry> {
    let mut result = vector[];
    let mut i = 0;
    let n = es.length();
    while (i < n) {
        let entry = es.borrow(i);
        if (entry.m == m) { result.push_back(*entry); };
        i = i + 1;
    };
    result
}

// === Test Functions ===

// Self-tests — require --gas-limit ≥ 100_000_000 for the full-corpus tests.

#[test]
fun all_has_672_entries() { assert!(all().length() == 672, 0); }

#[test]
fun all_single_has_336_entries() { assert!(all_single().length() == 336, 0); }

#[test]
fun all_multi_has_336_entries() { assert!(all_multi().length() == 336, 0); }

#[test]
fun all_random_handover_has_84_entries() { assert!(all_random_handover().length() == 84, 0); }

#[test]
fun all_random_descent_has_112_entries() { assert!(all_random_descent().length() == 112, 0); }

#[test]
fun all_tags_consistent_single() { assert_tags_consistent(all_single()); }

#[test]
fun all_tags_consistent_multi() { assert_tags_consistent(all_multi()); }

#[test]
fun all_tags_consistent_random_handover() { assert_tags_consistent(all_random_handover()); }

#[test]
fun all_tags_consistent_random_descent() { assert_tags_consistent(all_random_descent()); }

#[test]
fun by_tag_roundtrips_single() { assert_by_tag_roundtrips(all_single()); }

#[test]
fun by_tag_roundtrips_multi() { assert_by_tag_roundtrips(all_multi()); }

#[test]
fun by_tag_roundtrips_random_handover() { assert_by_tag_roundtrips(all_random_handover()); }

#[test]
fun by_tag_roundtrips_random_descent() { assert_by_tag_roundtrips(all_random_descent()); }
