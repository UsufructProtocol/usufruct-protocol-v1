# escrow_corpus

## § OVERVIEW

The exhaustiveness foundation of the `escrow_tests` test suite. `escrow_corpus` encodes every valid `PolicyEnsemble` combination as a `CorpusEntry` in a deterministic 6-dimensional cross-product space. The 672 entries cover every tuple drawn from the product of the six configurable policy axes:

```
TenureExtendPolicy (2) × HandoverPolicy (4) × PriceEscalationPolicy (2)
    × CurveShapePolicy pair (7) × AuctionWindowPolicy (3) × CommitmentPolicy (2)
    = 672
```

The corpus serves three roles:

**Bulk parameterized testing** — `all()`, `all_single()`, `all_multi()` iterate over every combination. A test that asserts a property across all 672 entries has structural coverage of the full policy space with no manual enumeration.

**Targeted single-config lookup** — `by_tag(tag)` retrieves one specific combination by its τ2 tag. Scenario tests use this to pin a readable, stable config while still expressing which policy variant is under test.

**Filtered subsets** — `filter_*` primitives and named projections (`with_handover_countdown()`, `with_descent_skipped()`, etc.) allow tests to narrow to a single axis without rebuilding entries manually.

One structural asymmetry: the `f` axis (CommitmentPolicy) is tracked in `CorpusEntry` and encoded in the tag, but is **not embedded in the `PolicyEnsemble`** — the commitment policy is a separate concern passed at integration time. Callers retrieve it via `commitment_by_tag(tag)` alongside `by_tag(tag)`.

## § TYPES

```
CorpusEntry   has copy, drop, store {
    ensemble: PolicyEnsemble,
    c:   u8,    // HandoverPolicy axis       (0..3)
    d:   u8,    // PriceEscalationPolicy axis (0..1)
    e:   u8,    // CurveShapePolicy pair axis (0..6)
    h:   u8,    // AuctionWindowPolicy axis   (0..2)
    f:   u8,    // CommitmentPolicy axis      (0..1)
    m:   u8,    // TenureExtendPolicy axis    (0..1)
    tag: u64,   // τ2 positional decimal tag
}
```

## § AXIS TABLE

| Axis | Policy                | Range | Variants |
|------|-----------------------|-------|----------|
| `m`  | TenureExtendPolicy    | 0..1  | 0 = Single, 1 = Multi |
| `c`  | HandoverPolicy        | 0..3  | 0 = Instant, 1 = Countdown (25 000 ms), 2 = FullTenure, 3 = RandomInRange (10 000..75 000 ms) |
| `d`  | PriceEscalationPolicy | 0..1  | 0 = FixedDelta (10 000 000 000), 1 = CompoundDelta (1 000 bps + 1) |
| `e`  | CurveShapePolicy pair | 0..6  | 0 = Linear, 1 = Smoothstep, 2 = Logistic, 3 = PowerLaw(1,2), 4 = PowerLaw(2,1), 5 = Exponential(2,true), 6 = Exponential(2,false) |
| `h`  | AuctionWindowPolicy   | 0..2  | 0 = Skipped, 1 = Window (100 000 ms), 2 = RandomInRange (10 000..90 000 ms) |
| `f`  | CommitmentPolicy      | 0..1  | 0 = Immediate, 1 = Deferred (10 000 000 ms) |

`credit_shape` and `auction_shape` in every entry are always the same `CurveShapePolicy` (both derived from axis `e`). The corpus deliberately does not cross-product them independently.

## § TAG ENCODING (τ2)

The tag is a positional decimal integer that uniquely identifies a corpus entry:

```
tag = m·100_000 + c·10_000 + d·1_000 + e·100 + h·10 + f
```

Each axis is recoverable by positional extraction:

```
f = tag % 10
h = (tag / 10)      % 10
e = (tag / 100)     % 10
d = (tag / 1_000)   % 10
c = (tag / 10_000)  % 10
m = tag / 100_000
```

Example: `tag(1, 0, 0, 0, 0)` → `10_000` — Countdown handover, all other axes at default (Single, FixedDelta, Linear, Skipped, Immediate).

## § API

**Corpus constructors**
- `escrow_corpus::all(): vector<CorpusEntry>` — 672 entries: full (m,c,d,e,h,f) cross-product. Requires `--gas-limit ≥ 100_000_000`. Call once per test and bind to a local — never inside the iteration loop.
- `escrow_corpus::all_single(): vector<CorpusEntry>` — 336 entries: m=0 slice.
- `escrow_corpus::all_multi(): vector<CorpusEntry>` — 336 entries: m=1 slice.
- `escrow_corpus::all_random_handover(): vector<CorpusEntry>` — c=3 slice of `all_single()` (84 entries).
- `escrow_corpus::all_random_handover_multi(): vector<CorpusEntry>` — c=3 slice of `all_multi()` (84 entries).
- `escrow_corpus::all_random_descent(): vector<CorpusEntry>` — h=2 slice of `all_single()` (112 entries).
- `escrow_corpus::all_random_descent_multi(): vector<CorpusEntry>` — h=2 slice of `all_multi()` (112 entries).

**Single-config lookup**
- `escrow_corpus::by_tag(tag: u64): PolicyEnsemble` — decodes tag and returns the corresponding ensemble. Validates all axis bounds; aborts on any out-of-range value.
- `escrow_corpus::commitment_by_tag(tag: u64): CommitmentPolicy` — extracts the `f` axis and returns the corresponding `CommitmentPolicy`. Used alongside `by_tag` at integration time since the commitment is not embedded in the ensemble.

**Tag constructors**
- `escrow_corpus::tag(c, d, e, h, f): u64` — builds a τ2 tag with m=0. Validates all axis bounds.
- `escrow_corpus::tag_with_cycles(c, d, e, h, f, m): u64` — builds a τ2 tag with explicit m. Validates all axis bounds.

**Filter primitives**
- `escrow_corpus::filter_c`, `filter_d`, `filter_e`, `filter_h`, `filter_f`, `filter_m` — each takes a `vector<CorpusEntry>` and an axis value; returns the matching subset. Validates the axis bound before filtering.

**Named projections** (convenience wrappers over filter primitives; all derive from `all()`)
- `with_handover_instant()`, `with_handover_countdown()`, `with_handover_full_tenure()`, `with_handover_random()`
- `with_descent_skipped()`, `with_descent_window()`, `with_descent_random()`
- `with_retire_immediate()`, `with_retire_deferred()`
- `with_fixed_pricing()`, `with_compound_pricing()`
- `with_cycles_single()`, `with_cycles_multi()`

**Ensemble rebuilders** (surgical overrides — replace one policy field, preserve the rest)
- `escrow_corpus::with_min_rent_price(ensemble, price_mist): PolicyEnsemble` — replaces `rest_price` with a fixed value.
- `escrow_corpus::with_random_min_rent_price(ensemble, min_mist, max_mist): PolicyEnsemble` — replaces `rest_price` with a random-in-range value.
- `escrow_corpus::with_tenure_ceiling(ensemble, ceiling_ms): PolicyEnsemble` — replaces `tenure_duration` with a fixed ceiling.
- `escrow_corpus::with_random_tenure_ceiling(ensemble, min_ms, max_ms): PolicyEnsemble` — replaces `tenure_duration` with a random-in-range ceiling.
- `escrow_corpus::with_tenure_cycles(ensemble, policy): PolicyEnsemble` — replaces `tenure_extend`.

**Constant getters**
Named accessors for every pinned corpus constant — used in test assertions to avoid magic literals.

| Getter | Value | Axis |
|--------|-------|------|
| `tenure_ceiling_const()` | 100 000 ms | fixed across all entries |
| `min_rent_price_const()` | 10 000 000 000 | fixed across all entries |
| `handover_countdown_c1_const()` | 25 000 ms | c=1 |
| `handover_random_min_c3_const()` | 10 000 ms | c=3 |
| `handover_random_max_c3_const()` | 75 000 ms | c=3 |
| `descent_window_h1_const()` | 100 000 ms | h=1 |
| `descent_random_min_h2_const()` | 10 000 ms | h=2 |
| `descent_random_max_h2_const()` | 90 000 ms | h=2 |
| `retire_deferred_f1_const()` | 10 000 000 ms | f=1 |
| `fixed_delta_value_const()` | 10 000 000 000 | d=0 |
| `compound_delta_bps_const()` | 1 000 bps | d=1 |
| `compound_delta_value_const()` | 1 | d=1 |

## § INVARIANTS

- `all()` has exactly 672 entries: 2 × 4 × 2 × 7 × 3 × 2 = 672.
- `all_single()` and `all_multi()` each have exactly 336 entries: 4 × 2 × 7 × 3 × 2 = 336.
- Tag consistency: for every entry, `entry.tag == m·100_000 + c·10_000 + d·1_000 + e·100 + h·10 + f`. Verified by `assert_tags_consistent` in the corpus self-tests.
- Tag roundtrip: for every entry, `by_tag(entry.tag) == entry.ensemble`. Verified by `assert_by_tag_roundtrips` in the corpus self-tests.
- `credit_shape` and `auction_shape` are always equal within any corpus entry — the `e` axis produces both from the same `make_curve(e)` call.
- The `f` axis (CommitmentPolicy) is NOT part of the `PolicyEnsemble`. It is tracked in the tag for navigability but must be retrieved separately via `commitment_by_tag(tag)`.

## § EVENTS

None (test-only module).
