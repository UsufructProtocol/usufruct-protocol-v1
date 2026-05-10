# Code Principles

Design principles applied consistently across this codebase. Each principle has a reason, a form, and a test: if you can't grep for a violation, the principle isn't enforced.

---

## 1. Make illegal states unrepresentable

**Level: data types**

A type that can represent an invalid state will eventually hold one. Encode validity into the type itself so the invalid state has no representation.

```move
// Before — retiring is orthogonal to the state machine; retiring=true on Waiting is "impossible"
struct TenancyContext { retiring: bool, state: TenancyState }

// After — the impossible combination cannot be constructed
enum TenancyState {
    Occupied { tenant },
    OccupiedRetiring { tenant },   // retiring encoded in the variant
    Demand { current, pending, expiry },
    DemandRetiring { current, pending, expiry },
}
```

Corollary: one-way transitions (flags that are set but never cleared) are state machine transitions, not booleans. A bool field that is only ever set to `true` is a missing enum variant.

---

## 2. Make illegal programs unrepresentable

**Level: function signatures**

A primitive in a function signature lies about its meaning. `u64` says "I am a number"; it doesn't say "I am a price" or "I am a timestamp." Two functions taking `(u64, u64)` can have their arguments silently swapped.

Replace primitives with domain types at every internal function boundary:

```move
// Before — can pass duration where timestamp is expected
fun process(start: u64, ceiling: u64): u64

// After — wrong type is a compile error
fun process(start: Timestamp, ceiling: Duration): Price
```

**Rule:** outside `math.move`, no function signature contains a raw `u64`, `bool`, or tuple where a domain type exists or could exist. The extraction to `u64` happens exactly once, at the PTB/SDK boundary.

---

## 3. Parse, don't validate

**Level: system boundaries**

Validate and convert at the entry point. Once inside the system, trust the type. Never re-validate what the type already guarantees.

```move
// Boundary (escrow PTB):
public fun tenure_ceiling_ms(escrow): u64 {
    phases::duration_ms(asset_context_state::proj_tenure_ceiling(escrow))
}

// Internal — no re-validation, no extraction:
fun do_handover(boundary: Timestamp, ceiling: Duration): TenancyContext { ... }
```

Extraction sites (`monetary::stake_mist(x)`, `phases::timestamp_ms(t)`) are the "parse" step. After that step, the value carries its invariants in the type.

---

## 4. Layer ownership — a domain owns its primitive

**Level: module architecture**

Each domain layer owns the type that wraps its primitive. No module except the owner should operate on the naked primitive.

| Domain | Owner module | Type | Primitive |
|---|---|---|---|
| Time | `phases.move` | `Timestamp`, `Duration`, `Boundary` | `u64 ms` |
| Money | `monetary.move` | `Price`, `Stake` | `u64 mist` |
| Math | `math.move` | `BasisPoints`, `CurveHeight` | `u64` |

**Test:** `grep -r ": u64" sources/` returns zero results in internal functions (excluding events, error constants, and `math.move`). If a grep hit exists, the refactor is not complete.

---

## 5. Extraction is a deliberate domain crossing

**Level: code readability**

When a typed value must cross into a math or framework operation, the extraction is made visible by calling a named extractor. It is not implicit.

```move
// Math domain crossing — visible, named:
math::mul_div(monetary::stake_mist(ctx.stake), h, SCALE)

// Framework crossing — visible:
balance::split(&mut balance, monetary::stake_mist(amount))
```

This makes "I am leaving the typed domain here" a statement in the code, not a hidden operation.

---

## 6. Constructors construct; callers observe

**Level: API design**

A constructor should return exactly the value it created. If the caller needs additional information (e.g., the ID of the new object), the caller derives it.

```move
// Before — ID is derivable; returning it implies the caller can't derive it
public(package) fun new(escrow_id, tenant, ctx): (TenantCap, ID)

// After — caller calls object::id(&cap) when needed
public(package) fun new(escrow_id, tenant, ctx): TenantCap
```

---

## 7. Exhaustive match over boolean guards

**Level: state machine correctness**

When a function branches on state, use a match expression rather than a sequence of `if (is_X)` checks. Exhaustive match forces the compiler to require coverage of every state.

```move
// Before — silent if a new variant is added
assert!(!is_retiring(&tenancy), EAlreadyRetiring);
set_retiring_flag(tenancy)  // sets bool

// After — new variant = compile error at every match site
match (state) {
    Occupied { tenant }   => TenancyState::OccupiedRetiring { tenant },
    Demand { c, p, exp }  => TenancyState::DemandRetiring { c, p, exp },
    OccupiedRetiring {..} | DemandRetiring {..} => abort EAlreadyRetiring,
}
```

---

## 8. Impossible invariants become abort, not silent routing

**Level: correctness under future change**

When a code path is provably unreachable (e.g., a balance is always zero at a specific point), use an assertion rather than a general branch that silently handles the "impossible" case.

```move
// Before — from_departing() branches on remain_credit > 0
// If a future bug leaves 1 mist, it silently routes funds to the tenant.
let refund = refund_state::from_departing(departing, fee_share, owner_earnings);

// After — asserts the invariant; any discrepancy aborts, never routes silently
let (_, stake) = tenant::unbundle(departing);
tenant::destroy_empty_stake(stake);   // aborts if balance != 0
refund_state::distribute(refund_state::nothing(fee_share, owner_earnings), ...);
```

---

## 9. Encapsulation closes at the module, not the function

**Level: module boundaries**

If two operations always travel together (identity + stake, producer + consumer), they belong in a single function in the owning module. Don't expose the mechanism; expose the operation.

```move
// Before — caller must know to unbundle and then call total
let (identity, stake) = tenant::unbundle(pending);
let refund = refund_state::total(identity, stake);

// After — the operation is named at the right abstraction level
let refund = refund_state::from_superseded(pending);
```

---

## 10. Co-residence: enums and their match sites

**Level: Move language constraint**

Move restricts `match` on enum variants to the module that defines the enum. Place an enum in the module that needs to branch on its variants.

```move
// CapAuthorizationState must co-reside with asset_context_state
// because take_asset and execute_burn_tenant_cap match on its variants.
// Defining it in a separate module would require moving the match logic
// — which would then need access to TenancyContext internals.
```

When a new variant is added to a co-resident enum, the compiler requires coverage at every `match` site in the defining module. External callers (SDK, escrow) receive the enum as an opaque value and query it via `proj_is_*` functions.

---

## 11. Raw Balance never crosses module borders

**Level: fund safety**

Every `Balance<C>` produced inside the package wraps immediately into a typed share destined for a single consumer (`FeeShare`, `OwnerEarnings`, `TenantStake`). The naked `Balance` is internal plumbing only.

```
tenant::take_fee_share   → FeeShare<C>       → fee_message::post → fee inbox
tenant::take_owner_earnings → OwnerEarnings<C> → owner::deposit   → owner balance
```

No function signature accepts or returns `Balance<C>` except within its defining module.

---

## 12. Entity shape: Identity + Material

**Level: domain modeling**

Every protocol entity follows the same structural pattern:

```
Entity { identity: EntityIdentity, material: EntityMaterial<C> }
```

- `Identity` holds the cap_id and address — who the entity is.
- `Material` holds the balance — what the entity holds.

These two halves travel separately at departure boundaries: `identity` routes the refund; `material` carries the funds.

---

## 13. Types-first refactor

**Level: refactoring strategy**

When refactoring, strengthen the types before moving logic. A `u64 → Domain` change often reveals the correct module boundary for free.

Sequence: **types → structure**, not the reverse. Moving code before the types are correct relocates the smell without eliminating it.

---

## 14. SDK projection: extract at the boundary, nowhere else

**Level: API surface**

`runtime_projection.move` and `escrow.move` PTB functions are the only places where domain types are extracted to `u64`. Every `proj_*` function inside the package returns a domain type.

```move
// Internal projector — domain type:
public(package) fun proj_current_stake(e: &AssetContext): Option<Stake>

// SDK boundary — extracts at the last moment:
public fun asset_current_stake(e: &AssetContext): Option<u64> {
    let opt = acs::proj_current_stake(e);
    if (option::is_some(&opt)) option::some(monetary::stake_mist(option::destroy_some(opt)))
    else option::none()
}
```

---

## 15. Event fields are JSON — primitives are intentional there

**Level: exceptions**

Event struct fields are serialized to JSON for off-chain consumers. `u64` in event fields is correct and intentional. Events are the one place where domain values are extracted unconditionally.

This is not an exception to the other principles — it is the terminal extraction point, analogous to the SDK boundary.

---

## 16. Visibility: public(package) for helpers, public for PTB constructors

**Level: API design**

- `public`: PTB-reachable constructors (IntegrationConfig chain, policy enums, `new_config`, `integrate`)
- `public(package)`: within-package helpers and projectors
- `private + #[test_only]`: implementation details accessible only from tests

The PTB surface is the narrowest possible set of functions that SDK users need to build transactions.

---

## 17. Asymmetries between entities are information, not defects

**Level: domain modeling**

When two entities are structurally different, preserve the difference. Don't normalize to a common shape.

Example: `Owner` authorizes by cap_id; tenants authorize by cap_id AND have a role (Current/Pending/Stale). `CapAuthorizationState` exists only for tenants because the concept doesn't apply to owners. Symmetry for its own sake erases domain information.

---

## 18. Tests express invariants, not just happy paths

**Level: test design**

Tests should document what is provably impossible, not just what the nominal path produces.

```move
// Not just "owner gets earnings":
assert_eq!(owner_share + protocol_fee, principal);

// Also "tenant receives nothing":
sc.next_tx(TENANT_ADDR_1);
assert!(!sc.has_most_recent_for_sender<Coin<SUI>>(), 0);
```

An invariant that is only implied by the math, but never explicitly asserted, will silently break if the math changes.

---

## 19. Policy types resolve to domain primitives — computation never sees the policy

**Level: module architecture**

A policy type encodes a *choice* about how to derive a value. A computation function uses the *derived value*. These are different things and must not share a type.

If a computation function takes `&PolicyState`, it is leaking configuration past the resolution boundary. The correct form: `resolve(&PolicyState) → DomainPrimitive` at the cycle-entry boundary; computation functions take only the resolved primitive.

```move
// Before — policy crosses into the computation layer; abort 0 needed for variants
// that "shouldn't exist here"
fun has_expired(policy: &HandoverPolicyState, bid_time, phase_start, ceiling, now): Boundary {
    match (policy) {
        HandoverPolicyState::RandomInRange { .. } => abort 0, // unreachable after resolve()
        ...
    }
}

// After — policy stops at resolve(); computation is uniform across all variants
public(package) fun resolve(policy: &HandoverPolicyState, ceiling: Duration, gen: &mut RandomGenerator): Duration { ... }
public(package) fun has_expired(resolved_floor: Duration, resolved_ceiling: Duration, bid_time: Timestamp, phase_start: Timestamp, now: Timestamp): Boundary {
    phases::check_boundary(phases::earliest(...), phases::zero(), now)
}
```

**Diagnostic:** an `abort 0` (or any abort) in a match arm annotated `// unreachable after resolve()` is the smell. It means the policy type crossed the boundary. The fix is always the same: extract the resolved primitive, shrink the parameter to a domain type.

**Test:** no computation function (`has_expired`, `expiry_at`, `is_unlocked`, `unlock_at`) accepts a `&*PolicyState` parameter. The policy type stops at `resolve()`.

This principle is a corollary of Principle 2 applied to the configuration–computation boundary: once a value is resolved, passing the unresolved policy makes the illegal state (e.g., `RandomInRange` at computation time) representable.

**How `RandomInRange` reveals latent coupling:**

Projections over deterministic variants always produce a value — `Instant`, `FixedTime`, `Countdown` each have a concrete answer in any match arm. The coupling is invisible because no arm fails. `RandomInRange` is the variant that cannot produce a value at computation time, forcing `abort 0`. That abort is not a missing case — it is the signature of the coupling. The fix is not to handle the case; it is to move the resolution to the correct boundary so the case never reaches computation.

After the fix, `RandomInRange` is just another way to produce a `Duration`. The engine sees one type. The cycle that resolves via `Fixed(7d)`, `Window(14d)`, or `RandomInRange(3d, 14d)` is indistinguishable at the computation layer — all three become a `Duration` at Idle entry. The policy that produced it is invisible by design.

---

## Applied checklist

When writing or reviewing code in this codebase:

- [ ] Do any internal function signatures contain `u64`, `bool`, or anonymous tuples where a domain type exists?
- [ ] Does any projector return `Option<u64>` for a temporal or monetary value?
- [ ] Does any constructor return a tuple where one element is derivable from another?
- [ ] Is any `from_general_function()` used where `nothing()` or a specific variant is always correct?
- [ ] Does any module call `tenant::unbundle()` or similar decompositions that should be encapsulated?
- [ ] Does any state machine use a `bool` for a one-way transition?
- [ ] Are all match sites exhaustive — would adding a new variant cause a compile error at every branch?
- [ ] Does any computation function accept `&*PolicyState`? If so, `resolve()` is missing and the policy crossed the resolution boundary.
- [ ] Does any `proj_*` that returns a policy type appear outside a `resolve()` call site? Policy projectors must flow directly into `resolve()` — never into computation functions.
