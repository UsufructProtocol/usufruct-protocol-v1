# PR Draft: Make illegal states unrepresentable at function boundaries — and what Move's type system still cannot enforce

Branch: `explore/policy-duration-types`

---

## What this branch does

Extends the core design principle from data-at-rest (struct/enum shapes) to data-in-motion (function signatures). Every semantic domain that crossed module boundaries as raw `u64` now has a named type:

| Type | Module | Encodes |
|---|---|---|
| `Timestamp` | `phases` | Absolute point in time (ms since epoch) |
| `Duration` | `phases` | Relative span of time (ms) |
| `Boundary` | `phases` | Deadline result: `Pending { remaining }` or `Crossed { overdue }` |
| `CurveHeight` | `curve_shape_state` | Normalised curve evaluation — the module's contract with `math` |
| `BasisPoints` | `math` | Rate in 1/10_000 units, pre-validated |
| `Price` | `monetary` | Monetary value not yet paid — reference price, floor, configured delta |
| `Stake` | `monetary` | Monetary value already paid — collateral held by a tenant |

The compiler now rejects passing a `Stake` where a `Price` is expected, a `Duration` where a `Timestamp` is expected, and so on. No tests added, no runtime assertions — the type checker absorbs the verification.

---

## The hidden transition this made visible

`Price` and `Stake` both wrap `u64` MIST. They are structurally identical. The distinction is semantic: a `Stake` is a `Price` that a payment event has actualised.

Before this branch, `do_tenure_expiry` silently reused `principal: u64` as `last_acq_price: u64`. The protocol invariant — *the last tenant's stake seeds the Dutch auction descent price* — was a comment at best. Now it is a compiler-verified operation:

```move
public(package) fun as_reference_price(s: Stake): Price { ... }
```

You cannot pass a `Stake` to a function expecting a `Price` without calling `as_reference_price`. The transition is no longer invisible.

---

## Overflow acquires a name and a location

`eval_fixed_delta` previously trapped with an anonymous `arithmetic_error` inside `price_function_state`. After introducing `monetary::price_add` with u128 promotion:

```move
public(package) fun price_add(a: Price, b: Price): Price {
    let sum: u128 = (a.mist as u128) + (b.mist as u128);
    assert!(sum <= (u64::max_value!() as u128), EPriceAddOverflow);
    Price { mist: sum as u64 }
}
```

The abort is now `EPriceAddOverflow` in `usufruct::monetary`. The Sui explorer shows the error by name. The SDK can distinguish it from any other abort. The test `location` annotation had to change from `price_function_state` to `monetary` — the compiler confirming that responsibility migrated to the correct module.

---

## The constraint this branch cannot solve: cross-module enum matching

This branch also surfaces a structural limitation of Move that is worth documenting with precision.

**The restriction.** Move prohibits pattern matching on an enum outside the module that defines it. Even `public` enums are opaque to external callers — you cannot write `match x { Enum::Variant => ... }` from another module. The canonical workaround, documented in the Move Book and used throughout this codebase, is projector functions:

```move
public(package) fun proj_is_fixed_delta(p: &PriceFunctionState): bool { ... }
public(package) fun proj_is_compound_delta(p: &PriceFunctionState): bool { ... }
```

External callers reconstruct the decision:

```move
if (proj_is_fixed_delta(p))         { handle_fixed(...)    }
else if (proj_is_compound_delta(p)) { handle_compound(...) }
// new variant CubicDelta added → compiler says nothing
```

**The official rationale.** API stability: if external modules match exhaustively, adding a new variant breaks all callers. For on-chain contracts this is framed as an upgrade safety concern — a deployed package that matches exhaustively on another package's enum would receive an unknown variant tag at runtime if the dependency is upgraded.

**Why the rationale fails.**

First, the team that built the restriction documented its own failure mode. From MystenLabs GitHub issue #15653, the official Move 2024 enum design spec:

> "you will not be notified of an error if you later-on add a new variant to the enum and forget to extend the pattern match"

This is the exact failure mode the projector pattern produces for every external caller. The restriction does not solve the problem of unhandled variants — it moves that problem out of the compiler and into silent runtime behaviour.

Second, the Aptos team, running the same Move VM, converted this into an explicit development rule:

> "Always use exhaustive match — never use a wildcard `_` arm to silence new enum variants"

Rules that must be written down exist because the failure happened without them. The pattern the Move restriction forces on external callers — `if proj_is_X ... else if proj_is_Y ...` — is exactly the construction Aptos prohibits internally.

Third, the upgrade concern is real but the response is disproportionate. Aptos's upgrade documentation explicitly permits adding variants to the end of an enum under a compatible upgrade policy. The scenario is not hypothetical: a dependency can acquire new variants. When it does, every external caller using the projector pattern silently takes the wrong branch. In a financial protocol, a silent wrong branch is the category of failure that causes fund loss — what smart contract auditors classify as a logic error, the same category responsible for hundreds of millions in losses across the ecosystem.

**What Rust understood.** Rust allows cross-crate pattern matching on public enums. For the specific case where a library needs to evolve without forcing downstream recompilation, `#[non_exhaustive]` requires external callers to include a wildcard arm:

```rust
match x {
    Enum::KnownA => handle_a(),
    Enum::KnownB => handle_b(),
    _ => abort_gracefully(), // required by compiler
}
```

At runtime, a new variant hits the wildcard and fails explicitly with a named error. The transaction aborts cleanly. The operator knows exactly what happened and that the caller needs to be updated.

Move had two tools available to solve the legitimate upgrade concern:

1. The upgrade system itself — already forbids changing public function signatures. It could equally forbid adding variants to public enums with external dependents that match exhaustively.
2. A `#[non_exhaustive]`-equivalent — require a wildcard arm for cross-package matches, preserving exhaustiveness verification while handling the upgrade case gracefully.

Instead it chose a third option: prohibit external matching entirely. This eliminates the upgrade concern but replaces it with something worse — callers that believe they handle all cases but do not, and a compiler that cannot tell them otherwise.

**Aborting with a named error is safer than continuing silently.** Move's restriction produces the second outcome and calls it stability.

**The restriction does not destroy expressiveness — it collapses locality.** The proof is `asset_context_state.move` itself, which documents its own reason for existing on line 4:

```move
/// All nested enum types must co-reside: Move 2024 restricts pattern access to the
/// defining module.
```

Inside that module the code is fully expressive. Transitions read naturally, the compiler verifies exhaustiveness, and adding a new variant breaks the match in compilation:

```move
match (state) {
    TenancyState::Demand { current, pending, .. } =>
        RentingFireResultState::Handover { tenancy: do_handover(...) },
    TenancyState::Occupied { tenant } =>
        RentingFireResultState::TenureExpired { ..., last_acq_price, retiring },
}
```

The guarantee works. It simply cannot be distributed. External modules can observe state through projectors but cannot participate in the match. All polymorphic behaviour over the protocol's enums must co-reside where the enums are defined, rather than living where it semantically belongs.

The cost is not expressiveness. It is **locality**: `asset_context_state.move` at 1700+ lines is not a design failure — it is the forced concentration of every exhaustive decision the protocol makes. The size of that file is the legible cost of the language constraint, and it is the correct response to it.

---

## PTB boundary discipline

Public functions in `escrow.move` remain `u64` in and out — PTBs work with primitives. Every typed value is unwrapped at that boundary with an explicit extractor. The internal package works in the typed domain; the SDK boundary is the only place raw primitives appear.
