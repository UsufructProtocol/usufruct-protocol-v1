# `rental_escrow` — Test Corpus

> Companion to `specs/rental/rental_escrow.spec.md`.
> Cross-references of the form §N.M refer to that document.
> The corpus is materialized in `usufruct/tests/rental_escrow_corpus.move`;
> this file is its design contract.

---

## IntegrationConfig axes

The integration surface of `rental_escrow` is parameterized by
`IntegrationConfig`. A single instance covers one point in a
multi-dimensional space; testing on one point would codify it as
"the expected behavior" while the spec dictates behavior over the
whole space. The test suite therefore operates over a
**deterministic corpus** of configs constructed as the cross-product
of the orthogonal axes that produce **distinct observable behavior**,
holding constant only parameters that are *scales* (no boundary
across them).

The corpus is materialized in a dedicated test module
`tests/rental_escrow_corpus.move` and consumed by every row of
§10.1–§10.13 through named projections (see §Module API below).

**Constants — same value in every escrow.**

| Symbol | Value | Type | Rationale |
|---|---|---|---|
| `CoinType` | `sui::sui::SUI` | phantom type | Phantom: enforced at compile-time, no runtime branch on `CoinType`. Multi-coin smoke test (§10.11) is separate from the corpus. |
| `Asset` | `DemoAsset` | phantom type | Same argument as `CoinType`. |
| `integrated_at_ms` | scenario-chosen | u64 ms | Used only as `(clock − integrated_at_ms)` delta in the `retire_unlock` guard; absolute value irrelevant to behavior. |
| `tenure_ceiling` | `100_000` (100 s) | u64 ms | Scale, not boundary. The constructor forbids `= 0` (`ETenureCeilingZero`); arithmetic is proportional across magnitudes. Round number that simplifies clock-advance arithmetic in scenarios. |
| `min_rent_price` | `10_000_000_000` (10 SUI) | u64 mist | Scale, not boundary. Constructor forbids `= 0` (`EMinRentPriceZero`). 10 SUI keeps the 10% protocol-fee split divisible (`1 SUI` exact) and round arithmetic for compound growth. |

**Orthogonal axes — each value materializes a distinct observable behavior.**

| Axis | Field | Type | Indices | Behavioral split |
|---|---|---|---|---|
| `C` | `handover` | `HandoverPolicy` | `c ∈ {0,1,2}` | `c=0` (`Instant`) enables rent+borrow same-tx (no clock advance needed). `c=1` (`Countdown(tenure_ceiling/4)`) is the standard countdown mode. `c=2` (`FixedTime`) is **fixed-time rental**: `config::handover_expiry` saturates to `phase_start_ms + tenure_ceiling`, eliminating early handovers — a distinct protocol mode, not a magnitude variation. |
| `D` | `price_function` | `PriceFunction` | `d ∈ {0,1}` | `d=0` adds a fixed 10 SUI per re-price (pure additive). `d=1` adds 10% per re-price plus 1 mist (constructor forbids `delta=0`, so `δ=1` is the closest approximation to "pure compound"). The boundary is between additive and multiplicative price escalation. |
| `E` | `(credit_curve, descent_curve)` | `(CurveShape, CurveShape)` | `e ∈ {0..6}` | Distinct shape modes: linear, smoothstep (S-shape symmetric), logistic (S-shape pronounced), power_law concave (`α=1/2`), power_law convex (`α=2`), exp concave saturating (`α=2,neg`), exp convex explosive (`α=2,pos`). Curve pairs are diagonal (not cross-product) because `compute_used_credit` (§8.1) consumes only `credit_curve` and `compute_price_descent` (§8.2) consumes only `descent_curve` — no spec section correlates them. The diagonal ensures every shape plays both roles. |
| `H` | `descent` | `DescentPolicy` | `h ∈ {0,1}` | `h=0` (`Skipped`) makes `AtDutchAuction` structurally unobservable: `do_tenure_expiry` and `do_auction_expiry` co-emit at identical timestamps because `config::descent_boundary` collapses to `phase_start_ms` (M6b, Q11). `h=1` (`Window(tenure_ceiling)`) gives a full descent window; mid-descent assertions are observable via `clock = phase_start_AtDutchAuction + ceiling_ms/2` without introducing a third axis value. |
| `F` | `retire` | `RetirePolicy` | `f ∈ {0,1}` | `f=0` (`Immediate`) removes the time guard on `retire()` — `config::retire_unlock` returns `0`, any clock value passes. `f=1` (`Deferred(100×tenure_ceiling)`) places the threshold so far in the future that any scenario advancing the clock by ~`tenure_ceiling` units always aborts `E_RETIRE_FLOOR_NOT_ELAPSED` — separating tests that exercise the guard from tests that exercise the rest of the lifecycle. |

**Axis `C` — `HandoverPolicy` constructor table.**

| `c` | label | constructor |
|---|---|---|
| 0 | `instant` | `handover_policy::new_handover_instant()` |
| 1 | `countdown` | `handover_policy::new_handover_countdown(25_000)` |
| 2 | `fixed_time` | `handover_policy::new_handover_fixed_time()` |

`Countdown.floor_ms = 25_000 = tenure_ceiling / 4`. The
`config::new_config` cross-field guard (`countdown_floor_lt`) is
satisfied because `25_000 < 100_000`; `FixedTime` passes vacuously.

**Axis `D` — `PriceFunction` constructor table.**

| `d` | label | constructor |
|---|---|---|
| 0 | `fixed_delta` | `price_function::new_fixed_delta(10_000_000_000)` |
| 1 | `compound_delta` | `price_function::new_compound_delta(1_000, 1)` |

`d=0`: δ = 10 SUI flat per re-price.
`d=1`: 10% bps + 1 mist; `new_compound_delta` requires `delta > 0`,
so 1 mist is the minimum value that approximates "pure compound".

**Axis `E` — `CurveShape` constructor table (diagonal pair).**

| `e` | label | constructor | concavity / role |
|---|---|---|---|
| 0 | `linear` | `curve_shape::new_linear()` | linear (baseline) |
| 1 | `smoothstep` | `curve_shape::new_smoothstep()` | S-shape symmetric |
| 2 | `logistic` | `curve_shape::new_logistic()` | S-shape pronounced |
| 3 | `power_concave` | `curve_shape::new_power_law(1, 2)` | x^(1/2), concave |
| 4 | `power_convex` | `curve_shape::new_power_law(2, 1)` | x², convex |
| 5 | `exp_concave` | `curve_shape::new_exponential(2, true)` | saturating concave |
| 6 | `exp_convex` | `curve_shape::new_exponential(2, false)` | explosive convex |

`α=2` is the minimal magnitude that distinguishes concave/convex from
linear. Internal-branch coverage in `curve_shape`:

- `eval_power_law`: `e=4` exercises the `if (alpha_den == 1) return acc`
  shortcut; `e=3` exercises the `nth_root_u128` branch (`SCALE_U128`).
- `eval_exponential`: `e=5` exercises `TAYLOR_SCALE − exp_ax`
  (alpha_neg=true); `e=6` exercises `exp_ax − TAYLOR_SCALE`
  (alpha_neg=false). Both branches share `EXP_A_NORM_2_{NEG,POS}`.

Both internal branches of each curve type are reached by the
diagonal — additional `α` magnitudes do not expose new branches at
the `rental_escrow` integration layer.

The same `CurveShape` value is used for both `credit_curve` and
`descent_curve` in each entry (diagonal: `cfg.credit_curve == cfg.descent_curve`).

**Axis `H` — `DescentPolicy` constructor table.**

| `h` | label | constructor |
|---|---|---|
| 0 | `skipped` | `descent_policy::new_descent_skipped()` |
| 1 | `window` | `descent_policy::new_descent_window(100_000)` |

`Window.ceiling_ms = 100_000 = tenure_ceiling`. The constructor
requires `ceiling_ms > 0`; no cross-field constraint between
`descent_ceiling` and `tenure_ceiling` is asserted by `config::new_config`
— both are independent additions onto `phase_start_ms`.

**Axis `F` — `RetirePolicy` constructor table.**

| `f` | label | constructor |
|---|---|---|
| 0 | `immediate` | `retire_policy::new_retire_immediate()` |
| 1 | `deferred` | `retire_policy::new_retire_deferred(10_000_000)` |

`Deferred.floor_ms = 10_000_000 = 100 × tenure_ceiling`. The
constructor requires `floor_ms > 0`. The large separation ensures
that any scenario that advances the clock by ~`tenure_ceiling` units
to drive lifecycle transitions still falls short of the retire
threshold — keeping the guard temporally active throughout the entire
scenario without requiring the test to advance the clock further.

**Cardinal.**

```
|Corpus| = |C| × |D| × |E| × |H| × |F| = 3 × 2 × 7 × 2 × 2 = 168
```

**Tag scheme (τ2).**

Each escrow is identified by a single `u64` tag built from axis
indices in positional decimal:

```
tag(c, d, e, h, f) = c · 10_000 + d · 1_000 + e · 100 + h · 10 + f
```

Padded to 5 digits, the tag reads left-to-right as `C-D-E-H-F`.
Decoding:

```
f = tag mod 10
h = (tag /     10) mod 10
e = (tag /    100) mod 10
d = (tag /  1_000) mod 10
c =  tag / 10_000
```

Constraints: `c ∈ [0,2]`, `d ∈ [0,1]`, `e ∈ [0,6]`,
`h ∈ [0,1]`, `f ∈ [0,1]`. A digit out of range is a
corpus-construction bug, not a regression.

**Use as failure breadcrumb.** The Move test framework does not
propagate strings through assertion failures — only the `u64`
abort code. The tag is therefore passed as the `abort_code`
argument to `assert!`, so a failure code is itself the breadcrumb
to the offending config:

```move
let tag = corpus::tag(c, d, e, h, f);
assert!(rental_escrow::state_tag(read_state(&escrow))
        == EscrowStateTag::Idle, tag);
```

A failure with abort code `10610` decodes to `c=1, d=0, e=6, h=1, f=0`:
`Countdown(25_000)`, `fixed_delta(10 SUI)`, `exp_convex`,
`Window(100_000)`, `Immediate`.

**Time arithmetic derivable from the corpus.**

With `t0 = integrated_at_ms` and the constants above:

| Quantity | Value | Conditions |
|---|---|---|
| `phase_start_HandoverOpen` | `t0` | first rent into Idle at `clock=t0` |
| `phase_start_AtDutchAuction` | `t0 + 100_000` | reached via `do_tenure_expiry`; phase_start is fresh = boundary_ms (§7.2) |
| clock for tenure boundary | `t0 + 100_000` | exact-boundary inclusivity row |
| clock for descent boundary | `t0 + 200_000` | only meaningful when `h=1` |
| clock for mid-descent | `t0 + 150_000` | only meaningful when `h=1`; samples at `Window.ceiling_ms/2` |
| clock past `retire_unlock` | `t0 + 10_000_000` | only meaningful when `f=1` (Deferred); under `f=0` (Immediate) any clock value passes |

Under `c=2` (fixed-time mode) the same relationships hold:
`handover_countdown_expiry` saturates to `phase_start_ms +
tenure_ceiling`, indistinguishable from the tenure boundary itself.

**Audit — explicit omissions from the corpus.**

The corpus is not exhaustive over the value space of
`IntegrationConfig`; it is exhaustive over **observable boundaries
from `rental_escrow`'s perspective**. The following are deliberately
out of corpus:

1. **`curve_shape` internal branches with `alpha_den ∈ {3, 4}` (cube /
   quartic root)** and exponential with `alpha_abs ∈ {1, 3..8}`. These
   are arithmetic branches inside `curve_shape` whose coverage is the
   responsibility of `curve_shape_tests` (already green). For
   `rental_escrow`'s integration the qualitative shape (concave /
   convex / S / linear) is what selects downstream behavior in
   `compute_used_credit` / `compute_price_descent`; magnitude is not.
2. **`Window { ceiling_ms } > tenure_ceiling`.** Allowed by the
   constructor (no asserted ordering between the two), but no code
   path branches on the sign of `(ceiling_ms − tenure_ceiling)` —
   both are independent additions onto `phase_start_ms`. Adds no new
   boundary.
3. **`min_rent_price` and `tenure_ceiling` magnitudes other than the
   canonical values.** Both are scales without boundary semantics
   (the constructor forbids only `= 0`).

**Out-of-corpus obligations — observable in tests, not via corpus.**

The corpus parameterizes config but not state or scenario timing.
Three classes of obligations remain on individual rows of §10:

- **Boundary inclusivity (`>=` vs `>`).** Every transition guard
  expressed as `now >= boundary_ms` (§4.2 step 3 for `retire_unlock`;
  `do_tenure_expiry`; `do_auction_expiry`; `do_handover`'s
  `handover_countdown_expiry`) requires a row that fires the action
  with `clock == boundary_ms` exactly. Cross-references: C1a (already
  in §10.8); analogous "exact-boundary" rows must exist for tenure /
  descent / handover transitions.
- **Zero-spread descent.** When the first tenant rents at exactly
  `min_rent_price`, lets tenure expire without a successor, and the
  auction starts with `last_acquisition_price = min_rent_price`,
  `compute_price_descent` operates on a zero-width spread
  `[min_rent_price, min_rent_price]` and saturates from `t=0`. State-level
  scenario reachable under any config; must be enumerated as an
  explicit row in §10.10 (cross-reference: complements Q7/Q8).
- **APT cascade combinations.** The cross-product of the corpus
  produces config combinations that drive multi-step cascades inside
  a single APT call. M6b is already catalogued (`HandoverOpen →
  AtDutchAuction → Idle` under `h=0`). Add **M6c**: `HandoverConfirmed →
  HandoverOpen → AtDutchAuction-skipped → Idle` in one APT under
  `(c=2, h=0)`. Other cascade combinations fall out of the matrix and
  should be named explicitly when their config triple uniquely
  produces them.

**Corpus is config; state is per-test.**

The corpus is orthogonal to `EscrowState`. Each test scenario starts
at `Idle` and drives transitions to reach the variant under test.
The full meaningful coverage matrix is:

```
{ EscrowState variants } × { corpus configs } = 5 × 168 = 840
```

This is the upper bound of meaningful (state, config) tuples, not the
number of tests. Each row of §10.1–§10.13 declares which projection
of the corpus it iterates over (typically a slice fixing one or two
axes — e.g., "all configs with `h=0`", "all configs with `c=2`"); the
projection set is specified in the module API section below.

**Operational rules for using the corpus.**

The corpus is a defense against codifying single-config assumptions
as protocol behavior, not a mandatory iteration target. Three rules
keep its cost-to-value ratio honest:

1. **Default to the minimum projection, not `all_configs()`.** Every
   row of §10 declares which subset of the corpus it iterates over
   and why. The full corpus is used only when the asserted property
   is genuinely cross-axis — typically §10.1 (`integrate` happy
   path), §10.11 (fee routing), §10.12 (full lifecycle). All other
   rows project to the axes they actually exercise (e.g., M6b uses
   `with_descent_skipped()`, ~84 configs; C1 uses
   `with_retire_deferred()`, ~84 configs). Treating
   "`all_configs()`" as a lazy default inflates suite runtime and
   obscures which property the row actually verifies.

2. **Assert properties, not config-indexed values.** A row written
   as `assert!(value == expected_for_this_cfg, ...)` forces the
   author to compute `expected_for_this_cfg` per config — that
   computation almost always requires reading the implementation,
   which is impl-mirroring (Form A in
   `ctx/rental-escrow-tests.note`), not spec-driven testing.
   Prefer formulations that hold across the projection: invariants,
   inequalities, structural shape (`state_tag == X`,
   `events.length == N`, `cap_id` triple-JOIN across event pairs).
   When the spec mandates an exact numeric value derivable from the
   config (rare), call the public helper that computes it
   (`compute_floor_price`, `compute_used_credit`) — never duplicate
   the formula in the test body.

3. **Single-config rows are legitimate and expected.** Not every row
   benefits from the corpus:
   - **§10.14 unit rows on pure helpers**: no `IntegrationConfig`
     dependency.
   - **Structural abort guards**: P_READ (§10.14.5),
     `E_WRONG_ESCROW_OWNER_CAP`, `E_RECEIPT_ESCROW_MISMATCH`,
     `E_RETIRED_NO_BID` — abort regardless of config.
   - **Sender / actor identity rows** (e.g., `KEEPER ≠ TENANT_A`
     §10.16): the property is about which address is captured, not
     about config.

   Rough working partition: ~30–40 % of §10 rows benefit from the
   full corpus; ~30 % from a small projection (2–10 configs
   targeting one or two axes); ~30 % are single-config. The split
   is descriptive, not prescriptive — the rule is to justify the
   projection per row, not to hit a percentage.

---

## `rental_escrow_corpus` module API

The previous section defined the corpus as a *design space* —
axes, cardinality, tag scheme. This section specifies the
**module API** that materializes that space and is consumed by
every row of §10.1–§10.13.

A dedicated module (rather than inline construction in each test
row) exists because:

- The 168 configs need a **single source of construction**. Spreading
  the constructor across rows guarantees drift on the first
  parameter change; centralizing keeps every row consuming the same
  physical configs and enforces the §10.16 "Corpus drift" rule
  mechanically.
- **Filter and projection logic is non-trivial enough to deserve
  reuse.** Reimplementing the per-axis predicate per row multiplies
  the surface for bugs.
- The module **hosts its own self-integrity tests** (corpus
  cardinality, tag uniqueness, `by_tag ↔ tag` inversion) that no
  individual row could enforce in isolation — without them, a
  generator regression would surface as a confusing failure in a
  random downstream row instead of a clear corpus bug.

The API is documented at the spec level (rather than left as an
implementation detail) because:

- **It is the contract between the corpus and the §10 row catalog.**
  Every row names a projection or filter (`with_descent_skipped()`,
  `filter_c(..., 2)`, `by_tag(10010)`); a silent rename invalidates
  downstream rows. Pinning the surface here makes refactor blast
  radius visible.
- **The three-layer split (filter primitives / named projections /
  single-config helper) encodes the operational rules in code
  shape.** Named projections make the common case readable
  (rule #1); filter primitives keep arbitrary intersections
  composable without inflating the namespace; `by_tag` is the
  explicit escape hatch for single-config rows (rule #3). The API
  itself is a defense against the lazy default.
- **Constant getters close the §10.16 "Corpus drift" loop.** Time
  arithmetic in §10 rows (`t0 + 150_000`, `t0 + 10_000_000`) derives
  from the getters listed below; specifying them here makes the
  single source of truth visible at the same level as the rows that
  consume it.

**Materialization.**

```
module:     usufruct::rental_escrow_corpus     (#[test_only])
location:   usufruct/tests/rental_escrow_corpus.move
visibility: public(package)  — symbols never cross the package boundary
section:    === Package Functions === per code-style convention
```

Visibility is `public(package)` rather than `public` even though
`#[test_only]` already prevents the module from appearing in
production builds. The narrower modifier declares the symbolic
intent ("does not leave the package") and matches the protocol-wide
default for utility modules.

**Imports.**

The module depends on the five policy modules that parameterize
`IntegrationConfig`. Each axis constructor routes through the
corresponding module; no `u64` raw values are passed directly to
`config::new_config` for typed fields:

```move
use usufruct::{
    config::{Self, IntegrationConfig},
    curve_shape,
    descent_policy,
    handover_policy,
    price_function,
    retire_policy,
};
```

**`CorpusEntry` — config + axis indices + tag.**

```move
public struct CorpusEntry has copy, drop, store {
    cfg: IntegrationConfig,
    c:   u8,   // 0..2
    d:   u8,   // 0..1
    e:   u8,   // 0..6
    h:   u8,   // 0..1
    f:   u8,   // 0..1
    tag: u64,  // c·10_000 + d·1_000 + e·100 + h·10 + f
}
```

Coupling cfg, axes and tag in one struct keeps the breadcrumb
travelling alongside the config through filter chains and into
`assert!` calls.

**Accessors via method aliases.**

```move
public use fun entry_cfg as CorpusEntry.cfg;
public use fun entry_tag as CorpusEntry.tag;
public use fun entry_c   as CorpusEntry.c;
public use fun entry_d   as CorpusEntry.d;
public use fun entry_e   as CorpusEntry.e;
public use fun entry_h   as CorpusEntry.h;
public use fun entry_f   as CorpusEntry.f;
```

In test code the aliases read like methods:

```move
let cfg: &IntegrationConfig = entry.cfg();
let tag: u64                = entry.tag();
let c:   u8                 = entry.c();
```

The standalone constructor `tag(c, d, e, h, f) -> u64` (below) does
not conflict — it lives in the module function namespace, while the
alias lives in the type method namespace of `CorpusEntry`.

**Sources.**

```move
public(package) fun all(): vector<CorpusEntry>           // 168 entries (eager)
public(package) fun by_tag(tag: u64): IntegrationConfig  // single-config lookup
```

`all()` reconstructs the 168-entry corpus on each call (eager,
~µs cost). Convention: each test calls `all()` (or one of the
named projections) once at the top of the test body and binds
to a local; never inside the iteration loop.

`by_tag(tag)` decodes the tag into axis indices, validates each
against its range, and returns the corresponding `IntegrationConfig`
**directly** (without the wrapper). Asymmetric on purpose: when the
caller already has the tag, the wrapper carries no new information,
and returning `IntegrationConfig` is what single-config rows
actually consume.

**Filter primitives — composable.**

```move
public(package) fun filter_c(es: vector<CorpusEntry>, c: u8): vector<CorpusEntry>
public(package) fun filter_d(es: vector<CorpusEntry>, d: u8): vector<CorpusEntry>
public(package) fun filter_e(es: vector<CorpusEntry>, e: u8): vector<CorpusEntry>
public(package) fun filter_h(es: vector<CorpusEntry>, h: u8): vector<CorpusEntry>
public(package) fun filter_f(es: vector<CorpusEntry>, f: u8): vector<CorpusEntry>
```

Each validates its axis argument in range. Multi-axis intersections
compose by chaining; named projections are reserved for combinations
that the spec recognizes as protocol modes:

```move
// M6c: HandoverConfirmed → Idle in one APT — c=2 ∧ h=0 (28 configs)
let es = corpus::filter_h(corpus::filter_c(corpus::all(), 2), 0);
```

**Named projections — protocol modes.**

Only modes that the spec recognizes by name (axis values that
correspond to qualitatively distinct protocol behavior) earn a named
projection. Unnamed combinations compose via filter primitives.

| Projection | Axis fix | `|·|` | Mode in spec |
|---|---|---|---|
| `with_handover_instant()` | c=0 | 56 | `HandoverPolicy::Instant` — rent+borrow same-tx |
| `with_handover_countdown()` | c=1 | 56 | `HandoverPolicy::Countdown(...)` — standard countdown |
| `with_handover_fixed_time()` | c=2 | 56 | `HandoverPolicy::FixedTime` — fixed-time rental |
| `with_descent_skipped()` | h=0 | 84 | `DescentPolicy::Skipped` — AtDutchAuction unobservable (M6b / Q11) |
| `with_descent_window()` | h=1 | 84 | `DescentPolicy::Window(...)` — full descent window |
| `with_retire_deferred()` | f=1 | 84 | `RetirePolicy::Deferred(...)` — guard temporally active (C1) |
| `with_retire_immediate()` | f=0 | 84 | `RetirePolicy::Immediate` — no guard |
| `with_fixed_pricing()` | d=0 | 84 | `PriceFunction::FixedDelta` — additive escalation |
| `with_compound_pricing()` | d=1 | 84 | `PriceFunction::CompoundDelta` — multiplicative escalation |

Axis `E` has no named projections: the curve dimension is swept
as a whole when shape matters, and filtered via `filter_e` (with
`e ∈ [0, 6]`) for curve-insensitive rows that need to fix one
specific shape.

**Tag constructor.**

```move
public(package) fun tag(c: u8, d: u8, e: u8, h: u8, f: u8): u64
```

Validates each axis in range, then returns the τ2 tag value. Used
internally by the corpus generator and externally by tests that
compute tags indirectly (rare).

**Constant getters — single source of truth for time arithmetic.**

The pinned canonical values are exposed as getters so test rows
reference them in derivations without duplicating literals (per
§10.16 "Corpus drift" rule):

```move
public(package) fun tenure_ceiling_const():            u64    // 100_000
public(package) fun min_rent_price_const():            u64    // 10_000_000_000
public(package) fun handover_countdown_c1_const():     u64    // 25_000  (Countdown.floor_ms at c=1)
public(package) fun descent_window_h1_const():         u64    // 100_000 (Window.ceiling_ms at h=1)
public(package) fun retire_deferred_f1_const():        u64    // 10_000_000 (Deferred.floor_ms at f=1)
public(package) fun fixed_delta_value_const():         u64    // 10_000_000_000
public(package) fun compound_delta_bps_const():        u64    // 1_000
public(package) fun compound_delta_value_const():      u64    // 1
```

A test asserting "clock at mid-descent" writes the derivation in
terms of these getters:

```move
let t_mid = t0
          + corpus::tenure_ceiling_const()
          + corpus::descent_window_h1_const() / 2;
```

Changing a canonical value requires editing one place; rows that
hardcode `150_000` would silently desync. The compiler does not
enforce this — it is a discipline anchored in §10.16 and reviewed
at code-review time.

**Errors — per-axis granularity.**

```move
const EAxisCOutOfRange: u64 = 0;
const EAxisDOutOfRange: u64 = 1;
const EAxisEOutOfRange: u64 = 2;
const EAxisHOutOfRange: u64 = 3;
const EAxisFOutOfRange: u64 = 4;
```

Per-axis codes give diagnostic precision: a tag with a malformed
digit aborts with the specific axis code, not a generic "invalid
input". Validation is enforced at every input boundary
(`tag(c,d,e,h,f)`, `by_tag(tag)`, `filter_*(es, val)`). The corpus
generator (`all()`) cannot produce invalid entries by construction
— its loop bounds match the per-axis ranges.

**Self-integrity tests.**

The module hosts its own `#[test]` functions guarding generator
invariants. A failure in any of these is a corpus-construction bug,
not a protocol regression:

| Test | Property |
|---|---|
| `all_has_168_entries` | `all().length() == 168` |
| `all_tags_consistent_with_axes` | for every entry `e` in `all()`, `e.tag == build_tag(e.c, e.d, e.e, e.h, e.f)`. Uniqueness of tags follows structurally: the 5 nested loops in `all()` generate each `(c,d,e,h,f)` tuple exactly once, so 168 entries implies 168 distinct tuples; `all_tags_consistent_with_axes` confirms the tag formula is correctly applied to each. An O(n²) uniqueness check is equivalent but exceeds the Move test framework's default gas budget at n=168. |
| `by_tag_inverts_tag_constructor` | for every valid `(c,d,e,h,f)`, `by_tag(build_tag(c,d,e,h,f)) == build_config(c,d,e,h,f)` |

**Standard iteration idiom.**

Move has no closures — each test writes the loop explicitly. The tag
goes into `assert!` as the abort code so a failure self-identifies
the offending config:

```move
let entries = corpus::with_descent_skipped();
let mut i = 0;
let n = entries.length();
while (i < n) {
    let entry = entries.borrow(i);
    let cfg = *entry.cfg();    // copy out — IntegrationConfig has `copy`
    let tag =  entry.tag();

    // ts::begin(OWNER) ... clock ... fee_inbox ...
    // let owner_cap = rental_escrow::integrate(asset, cfg, &fee_ref, &clk, scn.ctx());
    // drive transitions, observe events
    // assert!(<spec-derived property>, tag);

    i = i + 1;
};
```

The dereference on `entry.cfg()` (which returns `&IntegrationConfig`)
is the standard pattern: `IntegrationConfig` has `copy`, so dereferencing
is free, and consuming functions like `integrate` take it by value.
