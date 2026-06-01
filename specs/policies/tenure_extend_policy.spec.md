# tenure_extend_policy

## § OVERVIEW

Controls whether a usufructuary can purchase multiple consecutive tenures in a single `rent` call. A tenure is the time window during which a usufructuary holds the right to borrow the asset — it begins when they enter `Occupied` and expires at the tenure ceiling. A `Single` policy means each `rent` purchases exactly one such window — usufructuaries must return and re-rent to extend their right, giving the governor and market a natural repricing opportunity at every expiry. A `Multi` policy allows bulk purchase of `N` tenures upfront: the usufructuary pays total stake immediately and receives an uninterrupted borrow right spanning `N × tenure ceiling`. This is the governor's lever for controlling how often the asset returns to market: high-frequency repricing (Single) vs. stable long-term tenancy (Multi).

## § TYPES

```
TenureExtendPolicy   has copy, drop, store
  Single
  Multi
```

- `Single` — only one tenure per `rent` call; `tenures` argument must be exactly 1.
- `Multi` — any number of tenures per `rent` call; `tenures` argument may be ≥ 1.

## § API

**Constructors** (public)
- `tenure_extend_policy::new_single(): TenureExtendPolicy`
- `tenure_extend_policy::new_multi(): TenureExtendPolicy`

**Projections** (package)
- `tenure_extend_policy::proj_is_single`, `proj_is_multi`

**Validation** (package)
- `tenure_extend_policy::validate(&TenureExtendPolicy, tenures: Tenures)` — aborts if policy is `Single` and `tenures.count > 1`.

## § INVARIANTS

- `validate` is called inside `execute_rent` before any state mutation; a multi-tenure payment against a Single policy is rejected atomically.

## § EVENTS

None.
