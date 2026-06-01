# escrow_corpus

## § OVERVIEW

The exhaustiveness foundation of the `escrow_tests` test suite. `escrow_corpus` encodes every valid `PolicyEnsemble` combination as a `CorpusEntry` in a deterministic 6-dimensional cross-product space. The 336 entries cover every tuple drawn from the product of the six configurable policy axes:

```
TenureExtendPolicy (2) × HandoverPolicy (3) × PriceEscalationPolicy (2)
    × CurveShapePolicy pair (7) × AuctionWindowPolicy (2) × RetireCommitmentPolicy (2)
    = 336
```

The corpus serves three roles:

**Bulk parameterized testing** — `all()`, `all_single()`, `all_multi()` iterate over every combination. A test that asserts a property across all 336 entries has structural coverage of the full policy space with no manual enumeration.

**Targeted single-config lookup** — `by_tag(tag)` retrieves one specific combination by its τ2 tag. Scenario tests use this to pin a readable, stable config while still expressing which policy variant is under test.

**Filtered subsets** — `filter_*` primitives and named projections (`with_handover_fixed()`, `with_descent_skipped()`, etc.) allow tests to narrow to a single axis without rebuilding entries manually.

One structural asymmetry: the `f` axis (RetireCommitmentPolicy) is tracked in `CorpusEntry` and encoded in the tag, but is **not embedded in the `PolicyEnsemble`** — the commitment policy is a separate concern passed at integration time. Callers retrieve it via `retire_commitment_by_tag(tag)` alongside `by_tag(tag)`.

## § TYPES

```
CorpusEntry   has copy, drop, store {
    ensemble: PolicyEnsemble,
    c:   u8,    // HandoverPolicy axis       (0..2)
    d:   u8,    // PriceEscalationPolicy axis (0..1)
    e:   u8,    // CurveShapePolicy pair axis (0..6)
    h:   u8,    // AuctionWindowPolicy axis   (0..1)
    f:   u8,    // RetireCommitmentPolicy axis (0..1)
    m:   u8,    // TenureExtendPolicy axis    (0..1)
    tag: u64,   // τ2 positional decimal tag
}
```

## § AXIS TABLE

| Axis | Policy                | Range | Variants |
|------|-----------------------|-------|----------|
| `m`  | TenureExtendPolicy    | 0..1  | 0 = Single, 1 = Multi |
| `c`  | HandoverPolicy        | 0..2  | 0 = Off, 1 = Fixed (25 000 ms), 2 = FullTenure |
| `d`  | PriceEscalationPolicy | 0..1  | 0 = FixedDelta (10 000 000 000), 1 = CompoundDelta (1 000 bps + 1) |
| `e`  | CurveShapePolicy pair | 0..6  | 0 = Linear, 1 = Smoothstep, 2 = Logistic, 3 = PowerLaw(1,2), 4 = PowerLaw(2,1), 5 = Exponential(2,true), 6 = Exponential(2,false) |
| `h`  | AuctionWindowPolicy   | 0..1  | 0 = Off (descent skipped), 1 = Fixed (100 000 ms) |
| `f`  | RetireCommitmentPolicy | 0..1 | 0 = Immediate, 1 = Deferred (10 000 000 ms) |

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

Example: `tag(1, 0, 0, 0, 0)` → `10_000` — Fixed handover, all other axes at default (Single, FixedDelta, Linear, Skipped, Immediate).

## § API

**Corpus constructors**
- `escrow_corpus::all(): vector<CorpusEntry>` — 336 entries: full (m,c,d,e,h,f) cross-product. Requires `--gas-limit ≥ 100_000_000`. Call once per test and bind to a local — never inside the iteration loop.
- `escrow_corpus::all_single(): vector<CorpusEntry>` — 168 entries: m=0 slice.
- `escrow_corpus::all_multi(): vector<CorpusEntry>` — 168 entries: m=1 slice.

**Single-config lookup**
- `escrow_corpus::by_tag(tag: u64): PolicyEnsemble` — decodes tag and returns the corresponding ensemble. Validates all axis bounds; aborts on any out-of-range value.
- `escrow_corpus::retire_commitment_by_tag(tag: u64): RetireCommitmentPolicy` — extracts the `f` axis and returns the corresponding `RetireCommitmentPolicy`. Used alongside `by_tag` at integration time since the commitment is not embedded in the ensemble.

**Tag constructors**
- `escrow_corpus::tag(c, d, e, h, f): u64` — builds a τ2 tag with m=0. Validates all axis bounds.
- `escrow_corpus::tag_with_cycles(c, d, e, h, f, m): u64` — builds a τ2 tag with explicit m. Validates all axis bounds.

**Filter primitives**
- `escrow_corpus::filter_c`, `filter_d`, `filter_e`, `filter_h`, `filter_f`, `filter_m` — each takes a `vector<CorpusEntry>` and an axis value; returns the matching subset. Validates the axis bound before filtering.

**Named projections** (convenience wrappers over filter primitives; all derive from `all()`)
- `with_handover_instant()`, `with_handover_fixed()`, `with_handover_full_tenure()`
- `with_descent_skipped()`, `with_descent_window()`
- `with_retire_immediate()`, `with_retire_deferred()`
- `with_fixed_pricing()`, `with_compound_pricing()`
- `with_cycles_single()`, `with_cycles_multi()`

**Ensemble rebuilders** (surgical overrides — replace one policy field, preserve the rest)
- `escrow_corpus::with_min_rent_price(ensemble, price_mist): PolicyEnsemble` — replaces `rest_price` with a fixed value.
- `escrow_corpus::with_tenure_ceiling(ensemble, ceiling_ms): PolicyEnsemble` — replaces `tenure_duration` with a fixed ceiling.
- `escrow_corpus::with_tenure_cycles(ensemble, policy): PolicyEnsemble` — replaces `tenure_extend`.

**Constant getters**
Named accessors for every pinned corpus constant — used in test assertions to avoid magic literals.

| Getter | Value | Axis |
|--------|-------|------|
| `tenure_ceiling_const()` | 100 000 ms | fixed across all entries |
| `min_rent_price_const()` | 10 000 000 000 | fixed across all entries |
| `handover_countdown_c(c)` | 25 000 ms at c=1 | c |
| `descent_window_h(h)` | 100 000 ms at h=1 | h |
| `retire_deferred_f(f)` | 10 000 000 ms at f=1 | f |
| `fixed_delta_value_const()` | 10 000 000 000 | d=0 |
| `compound_delta_bps_const()` | 1 000 bps | d=1 |
| `compound_delta_value_const()` | 1 | d=1 |

## § INVARIANTS

- `all()` has exactly 336 entries: 2 × 3 × 2 × 7 × 2 × 2 = 336.
- `all_single()` and `all_multi()` each have exactly 168 entries: 3 × 2 × 7 × 2 × 2 = 168.
- Tag consistency: for every entry, `entry.tag == m·100_000 + c·10_000 + d·1_000 + e·100 + h·10 + f`. Verified by `assert_tags_consistent` in the corpus self-tests.
- Tag roundtrip: for every entry, `by_tag(entry.tag) == entry.ensemble`. Verified by `assert_by_tag_roundtrips` in the corpus self-tests.
- `credit_shape` and `auction_shape` are always equal within any corpus entry — the `e` axis produces both from the same `make_curve(e)` call.
- The `f` axis (RetireCommitmentPolicy) is NOT part of the `PolicyEnsemble`. It is tracked in the tag for navigability but must be retrieved separately via `retire_commitment_by_tag(tag)`.

## § EVENTS

None (test-only module).
