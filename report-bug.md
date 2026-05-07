# Bug Report: Move Compiler — Generic `key` Type Parameter in Fringe Position During Deep Match Compilation

## Summary

The `sui move build` compiler crashes with an internal Rust panic when a match arm
contains a deeply nested struct-in-enum pattern where a field of the inner struct is a
**generic type parameter constrained to `key + store`**. The compiler does not produce a
diagnostic — it simply terminates abnormally.

A related panic at the same location was fixed by PR
[#25475](https://github.com/MystenLabs/sui/pull/25475), but that fix does not fully
resolve this case — it trades a panic for silently incorrect behavior (the arm becomes
unreachable dead code). A proper fix requires distinct handling of generic type parameters
in fringe position.

## Environment

- Tool: `sui move build` (Move compiler bundled with the Sui CLI)
- Language: Move 2024

## Reproducer

Given these types:

```move
public enum AssetState<Asset: key + store, phantom CoinType> has store {
    Waiting { waiting: WaitingContext<Asset> },
    // ...
}

public struct WaitingContext<Asset: key + store> has store {
    asset: Asset,           // ← generic key type, no concrete datatype name
    state: WaitingState,
}

public enum WaitingState has store, drop {
    Idle,
    AtDutch { last_acq_price: u64, phase_start_ms: u64 },
    Retired,
}
```

The following match arm triggers the panic:

```move
match (context) {
    AssetContext {
        asset_state: AssetState::Waiting {
            waiting: WaitingContext {
                asset,
                state: WaitingState::AtDutch { last_acq_price, phase_start_ms }
            }
        },
        owner, config, ..
    } => { ... },
}
```

The nesting is: `AssetContext` (struct) → `AssetState::Waiting` (enum) →
`WaitingContext` (struct) → `WaitingState::AtDutch` (enum) → `{ u64, u64 }`.

The same nesting depth **does not panic** when the inner struct field is a concrete
wrapper type (`asset::Asset<U> has store`, no `key`) instead of the raw generic
parameter `U: key + store`. The `key` ability on the field type is the distinguishing
factor.

## Compiler Output (pre-fix)

```
thread 'main' panicked at
external-crates/move/crates/move-compiler/src/hlir/match_compilation.rs:173:56:
called `Option::unwrap()` on a `None` value
```

No bytecode is emitted. Build fails completely.

## Root Cause Analysis

The panic originates in `compile_match` in `hlir/match_compilation.rs`. The code path:

```rust
// Path 1: builtin type → compile_match_literal
if subject.ty.value.unfold_to_builtin_type_name().is_some() {
    compile_match_literal(context, subject, fringe, matrix)

// Path 2: type has type_arguments → resolve concrete datatype name
} else if let Some(tyargs) = subject.ty.value.type_arguments() {
    let (mident, datatype_name) = subject
        .ty
        .value
        .unfold_to_type_name()
        .and_then(|sp!(_, name)| name.datatype_name())
        .expect("ICE non-datatype type in head constructor fringe position");
    // ...

// Path 3 (pre-fix): .unwrap() on None → panic
// Path 3 (post-fix #25475): returns MatchTree::Failure → silent wrong behavior
} else {
    // ...
}
```

A generic type parameter `Asset: key + store` is:
- Not a builtin type → skips Path 1
- Not a type *with* type arguments (it IS a type argument itself) → `type_arguments()` returns `None` → skips Path 2
- Falls into Path 3

**Pre-fix (#25475):** Path 3 called `.unwrap()` on `None` → panic.

**Post-fix (#25475):** Path 3 returns `MatchTree::Failure`. This was the correct fix
for the `abort` expression case (which is genuinely unreachable dead code). But for a
generic `key` type parameter it is **wrong**: `MatchTree::Failure` causes the arm to be
treated as unreachable, so the pattern never matches at runtime even when it should.

The correct fix for our case is different: a generic type parameter in fringe position
should be treated as an **opaque wildcard** — the compiler cannot (and does not need to)
inspect its internal structure, so it should bind the value and proceed.

## Relationship to Existing Issues

| Issue / PR | Trigger | Same panic location | Covered by #25475 fix? |
|---|---|---|---|
| [#25457](https://github.com/MystenLabs/sui/issues/25457) | `abort` expression as match scrutinee (type "Nothing") | Yes | Yes — `MatchTree::Failure` is correct for dead code |
| **This report** | Generic `key` type parameter as struct field in fringe | Yes | No — `MatchTree::Failure` is incorrect; arm should compile and match |

## Classification

This is a **compiler bug**, not a language restriction:

- No diagnostic is produced — a restriction would yield a proper `error[EXXXXX]` message.
- The same logical pattern compiles correctly with a concrete (non-generic) field type.
- The compiler's own message labels it `"ICE ..."` (Internal Compiler Error).
- The `key` + `store` abilities are valid and well-defined; nothing in the language spec
  prohibits generic `key` types as struct fields or as match subjects.

## Security Impact

None beyond local Denial-of-Service against the compiler process. The panic produces no
output, so no malformed bytecode can reach the chain. Rust's memory safety prevents any
deeper exploitation (no undefined behavior, no memory corruption).

## Code as It Should Look (Post-Fix)

If the bug were properly fixed, the two-level workaround could collapse into a single
arm, achieving full symmetry with `TenancyContext` patterns already used in the same
codebase:

```move
// Renting arm — works today
AssetContext {
    asset_state: AssetState::Renting {
        tenancy: TenancyContext { asset, phase_start_ms, retiring, state: TenancyState::Occupied { tenant } }
    }, ...
} => { ... },

// Waiting arm — requires workaround today, should work symmetrically post-fix
AssetContext {
    asset_state: AssetState::Waiting {
        waiting: WaitingContext { asset, state: WaitingState::AtDutch { last_acq_price, phase_start_ms } }
    }, ...
} => { ... },
```

## Proposed Fix (Rust patch to `match_compilation.rs`)

The fix requires three changes to `hlir/match_compilation.rs`.

**1. Add a new `MatchTree` variant** for opaque type parameter bindings:

```rust
enum MatchTree {
    Leaf(Vec<ArmResult>),
    Failure,
    // ... existing variants ...
    /// A generic type parameter in fringe position — opaque, treated as a wildcard binding.
    TypeParamBind {
        subject:         FringeEntry,
        subject_binders: Vec<(Mutability, Var)>,
        next:            Box<MatchTree>,
    },
}
```

**2. In `build_match_tree`**, add a guard for `BaseType_::Param` before the `ice_assert!`
catch-all in the `else` branch:

```rust
// existing:
} else if let Some(tyargs) = subject.ty.value.type_arguments() {
    // ... resolve concrete struct/enum, compile ...

// new guard — insert before the existing else:
} else if matches!(
    subject.ty.value,
    Type_::Single(sp!(_, SingleType_::Base(sp!(_, BaseType_::Param(_)))))
) {
    // Generic type parameter (`T: key + store`, etc.) in fringe position.
    // The compiler cannot inspect its internal structure; any pattern on it
    // must be a Binder or Wildcard. Specialize as default and recurse.
    let (subject_binders, default_matrix) = matrix.specialize_default(context);
    let next = build_match_tree(context, fringe, default_matrix);
    MatchTree::TypeParamBind {
        subject,
        subject_binders,
        next: Box::new(next),
    }

// existing else (Unreachable / abort case, already fixed by #25475):
} else {
    ice_assert!(
        context.reporter,
        context.env.has_errors(),
        subject.var.loc,
        "Non-datatype and non-builtin type reached match compilation without a prior error"
    );
    MatchTree::Failure
}
```

**3. In `match_tree_to_exp`**, handle the new variant — bind the subject to any
pattern variables, then evaluate the rest of the tree:

```rust
MatchTree::TypeParamBind { subject, subject_binders, next } => {
    // Bind the opaque value to any Binder-pattern variables, then proceed.
    let bindings = subject_binders
        .into_iter()
        .map(|(_, binder)| (binder, (Mutability::Imm, subject.clone())))
        .collect();
    let next_exp = match_tree_to_exp(context, init_subject, *next);
    make_copy_bindings(context, bindings, next_exp)
}
```

This is the minimal change: one new variant, one new guard in `build_match_tree`,
one new arm in `match_tree_to_exp`. No existing paths are modified.

## Workaround

Extract the inner struct before matching on its state:

```move
AssetContext { asset_state: AssetState::Waiting { waiting }, owner, config, .. } => {
    let WaitingContext { asset, state } = waiting;   // ← forced two-level split
    match (state) {
        WaitingState::AtDutch { last_acq_price, phase_start_ms } => { ... },
        _ => abort E_NOT_AT_DUTCH,
    }
},
```

This pattern is used throughout `usufruct/sources/asset_context_state.move`; each
workaround site is annotated with a comment referencing this report.
