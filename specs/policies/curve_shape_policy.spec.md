# curve_shape_policy

## § OVERVIEW

A reusable rate function used in two independent contexts within the protocol. Every `PolicyEnsemble` carries two separate instances: `credit_shape`, which governs how fast a tenant's stake is considered consumed during their tenure, and `auction_shape`, which governs how fast the price descends during the dutch auction phase. These two roles are completely independent — they share the same policy type only because both reduce to the same mathematical question: given a position `t` within an interval `[0, t_max]`, what fraction of the total change has occurred? The answer to that question in the credit context is how much of the tenant's stake is locked in as "used"; in the auction context it is how far the price has descended toward the floor.

A critical protocol constraint shapes how `credit_shape` matters in practice: a tenant cannot voluntarily exit their tenure. The only way a tenure ends before its ceiling is displacement via a handover — a new tenant bids, the handover countdown fires, and the current tenant is replaced. The amount of stake the displaced tenant recovers is exactly the portion not yet consumed by `credit_shape` at the moment of displacement. The curve therefore encodes the owner's policy on how much refund a displaced tenant is entitled to as a function of how far into their tenure they were when another tenant arrived.

The choice of curve shape carries direct economic meaning and reshapes bidding strategy:

- **Linear** — the neutral baseline. Credit burns at constant rate; auction price descends steadily. No position in time carries any advantage; bidders have no incentive to time their entry strategically.

- **Smoothstep** — slow at both ends, fast in the middle. For credit: a tenant displaced in the first or last quarter of their tenure recovers most of their unused stake — credit has barely moved at the extremes, so displacement cost is soft at both ends. For auction: the price holds firm early in the window and near the floor, with the sharpest drop in the middle; bidders who wait for the midpoint get the steepest discounts, creating a concentration of rational bids around the halfway mark.

- **PowerLaw α < 1 (convex, front-loaded)** — most of the change happens in the first fraction of the interval. For credit: stake is consumed rapidly at the start of the tenure — a tenant displaced early has little unused stake to recover. This makes displacement cheap for incoming tenants and discourages bidders who plan only short occupancy, rewarding those who intend to hold the full tenure. For auction: the price collapses quickly at the opening of the descent window and then flattens near the floor — patient bidders who wait even briefly capture most of the discount, while first-movers pay a premium close to the last acquisition price.

- **PowerLaw α > 1 (concave, back-loaded)** — change is slow at first and accelerates near the end. For credit: a tenant displaced early in their tenure recovers most of their stake — displacement is cheap early, expensive late. This lowers the risk of bidding: incoming tenants know that displacing a recent occupant costs little of that occupant's stake, making aggressive bids more attractive. For auction: the price holds stubbornly close to the last acquisition price for most of the window and only collapses in the final stretch — bidders who time their entry to the very end capture steep discounts, but face pressure to act before the window closes.

- **Exponential (decay, alpha_neg=true)** — the sharpest front-loaded option. For credit: almost the entire stake is consumed in the first portion of the tenure; a displaced tenant has almost no refund claim after a short time in. For auction: near-instant price discovery — the price drops close to the floor within a small fraction of the window, and waiting offers little additional discount. Rational bidders enter immediately or not at all.

- **Exponential (growth, alpha_neg=false)** — the sharpest back-loaded option. For credit: stake barely burns until late in the tenure; displacing a recent tenant costs them almost nothing in lost stake. For auction: price barely moves until the final stretch of the window, then falls sharply — creates a cliff at the end that rewards the most patient bidders and punishes those who entered early at a premium.

- **Logistic (sigmoid)** — S-curve symmetric around the midpoint. Slow change at both extremes with the steepest rate at the midpoint. For credit: displacement cost is lowest at the beginning and end of a tenure, highest at the midpoint — a tenant halfway through their tenure has the most at stake if displaced. For auction: the price remains near the last acquisition price in the first third, drops most rapidly around the midpoint, and then slows near the floor — rational bidders cluster their entries around the inflection point, creating predictable mid-window demand.

## § TYPES

```
CurveShapePolicy   has copy, drop, store
  Linear
  Smoothstep
  PowerLaw   { alpha_num: u8, alpha_den: u8 }
  Exponential { alpha_abs: u8, alpha_neg: bool }
  Logistic
```

- `Linear` — height grows at constant rate: `h(t) = t / t_max`.
- `Smoothstep` — Hermite cubic `3x² − 2x³`; slow start and end, fast middle.
- `PowerLaw` — `h(t) = (t / t_max)^(alpha_num/alpha_den)`; `alpha < 1` is convex, `alpha > 1` is concave. Numerator ∈ [1,8], denominator ∈ [1,4], reduced to lowest terms.
- `Exponential` — normalised `e^(±α · t/t_max)`; `alpha_neg = true` gives decay (fast start), `false` gives growth (slow start). `alpha_abs ∈ [1,8]`.
- `Logistic` — sigmoid centred at `t_max/2`; slow at both ends, fast in the middle.

```
CurveHeight { h: u64 }   has copy, drop
```
A normalised height value scaled by `SCALE = 1_000_000_000`. Ranges from 0 to SCALE, representing the fraction of the maximum at a given time position.

## § API

**Constructors** (public)
- `curve_shape_policy::new_linear(): CurveShapePolicy`
- `curve_shape_policy::new_smoothstep(): CurveShapePolicy`
- `curve_shape_policy::new_logistic(): CurveShapePolicy`
- `curve_shape_policy::new_power_law(alpha_num: u8, alpha_den: u8): CurveShapePolicy` — validates ranges and reduces to lowest terms via GCD.
- `curve_shape_policy::new_exponential(alpha_abs: u8, alpha_neg: bool): CurveShapePolicy` — validates `alpha_abs ∈ [1,8]`.

**Projections** (package)
- `curve_shape_policy::proj_is_linear`, `proj_is_smoothstep`, `proj_is_logistic`, `proj_is_power_law`, `proj_is_exponential`
- `curve_shape_policy::proj_power_law_alpha_num`, `proj_power_law_alpha_den`, `proj_exponential_alpha_abs`, `proj_exponential_alpha_neg` — each returns `Option<T>`.
- `curve_shape_policy::proj_value(CurveHeight): u64`

**Computations** (package)
- `curve_shape_policy::compute_curve_height(&CurveShapePolicy, t: u64, t_max: u64): CurveHeight` — evaluates the curve at relative position `t / t_max`; returns a value in `[0, SCALE]`.
- `curve_shape_policy::compute_scaled_value(amount: u64, CurveHeight): u64` — multiplies `amount` by `height / SCALE`; applies the curve output to a concrete quantity.

## § INVARIANTS

- All curve evaluations are bounded: `compute_curve_height` always returns a value in `[0, SCALE]`; downstream price and credit values therefore stay within their declared bounds.
- `PowerLaw` parameters are reduced to lowest terms at construction; `(2,4)` and `(1,2)` are the same curve.
- Exponential evaluation uses a pre-computed Taylor series with fixed-point normalisation constants; precision is bounded by the series truncation.

## § NUMERIC CONSTANTS

The `Exponential` and `Logistic` evaluators rely on algorithm-derived constants that are pre-computed and pinned to avoid runtime `exp` calls in fixed-point arithmetic. Two families exist:

**Logistic normalisation** (`LOGISTIC_DENOM`, `LOGISTIC_SIGMA_FLOOR`)  
`eval_logistic` maps `t ∈ [0, t_max]` to a sigmoid argument `y ∈ [−K/2, +K/2]` (with `K = LOGISTIC_K = 12`, the range is `[−6, 6]`). The constants capture the sigmoid's value at the two boundaries so the output can be re-normalised to `[0, SCALE]`:

```
ey        = exp_scaled_pos(LOGISTIC_K, 2)          // e^(K/2) · TAYLOR_SCALE
sigma_max = ey · SCALE / (ey + TAYLOR_SCALE)       // σ(+K/2) · SCALE
sigma_min = SCALE − sigma_max                      // σ(−K/2) · SCALE  (by symmetry)

LOGISTIC_DENOM       = sigma_max − sigma_min       // range of σ over the window
LOGISTIC_SIGMA_FLOOR = sigma_min                   // = (SCALE − LOGISTIC_DENOM) / 2
```

Pinned via the `bootstrap_constants_match_pinned` regression test in `curve_shape_policy_tests`. Re-derive whenever the Taylor series parameters (truncation depth K, rounding mode) change.

**Exponential normalisation** (`EXP_A_NORM_{1..8}_{POS,NEG}`)  
Sixteen pre-computed normalisation denominators — one per `(alpha_abs, alpha_neg)` pair in `[1,8] × {false,true}`. Derivation:
- `EXP_A_NORM_{a}_POS = exp_scaled(a, 1, false) − TAYLOR_SCALE`
- `EXP_A_NORM_{a}_NEG = TAYLOR_SCALE − exp_scaled(a, 1, true)`

Pinned via the same bootstrap as the logistic constants. Re-derive whenever the Taylor series parameters change; the regression test guards against silent drift.

**Taylor series** (`exp_scaled_pos`)  
Computes `e^(y_num/y_den) · TAYLOR_SCALE` via a 32-term Taylor expansion in fixed-point arithmetic. Truncation at K = 32 is sufficient for all `alpha_abs ∈ [1,8]` and all `t ∈ [0, t_max]` inputs the protocol generates. `y_den > 0` is a caller pre-condition; the function does not validate it.

## § EVENTS

None.
