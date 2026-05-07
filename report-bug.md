# Bug Report: Move Compiler Internal Panic on Deeply Nested Struct-in-Enum Match Patterns

## Summary

The `sui move build` compiler crashes with an internal Rust panic when a match arm
contains a struct-in-enum pattern where a field of the inner struct is a **generic type
parameter constrained to `key + store`**. The compiler does not produce a diagnostic —
it simply terminates abnormally.

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
    asset: Asset,           // ← generic key type
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
parameter `U: key + store`. The `key` ability on the field type is the likely trigger.

## Compiler Output

```
thread 'main' panicked at
external-crates/move/crates/move-compiler/src/hlir/match_compilation.rs:173:56:
called `Option::unwrap()` on a `None` value
```

No bytecode is emitted. Build fails completely.

## Root Cause Analysis

The panic originates in the `compile_match` function in `hlir/match_compilation.rs`.
The relevant code path (around line 173):

```rust
} else if let Some(tyargs) = subject.ty.value.type_arguments() {
    let tyargs = tyargs.clone();

    let (mident, datatype_name) = subject
        .ty
        .value
        .unfold_to_type_name()
        .and_then(|sp!(_, name)| name.datatype_name())
        .expect("ICE non-datatype type in head constructor fringe position");  // ← panics
```

When the compiler builds the decision tree for a deeply nested pattern, it places each
field type into the "fringe" (the queue of sub-patterns to compile). When it reaches a
field of type `Asset: key + store` — a generic type parameter, not a concrete named
datatype — `unfold_to_type_name()` returns `None`. The `.expect()` call then panics
with `"ICE non-datatype type in head constructor fringe position"`.

The compiler does not guard against generic type parameters appearing in fringe position
during deep struct destructuring.

## Related Issues

Issue [#25457](https://github.com/MystenLabs/sui/issues/25457) ("Compiler panic in HLIR
match compilation: `unwrap()` on `None` for unexpected `match` argument") hits the same
`.expect()` but via a different code path: matching on an `abort` expression. That issue
was fixed by PR [#25475](https://github.com/MystenLabs/sui/pull/25475). **Our trigger is
distinct**: a generic `key` type parameter as a struct field in fringe position during
deep pattern compilation.

## Classification

This is a **compiler bug**, not a language restriction:

- No diagnostic is produced — a restriction would yield a proper `error[EXXXXX]` message.
- The same logical pattern compiles correctly at shallower nesting or with a concrete
  (non-generic) field type.
- A Rust `unwrap()` panic with message `"ICE ..."` (Internal Compiler Error) is by
  definition a bug — the compiler itself labels it as such.

## Security Impact

None beyond local Denial-of-Service against the compiler process. The panic produces no
output, so no malformed bytecode can reach the chain. Rust's memory safety prevents any
deeper exploitation (no undefined behavior, no memory corruption).

## Code as It Should Look (Post-Fix)

If the bug were fixed, the two-level workaround could collapse into a single arm:

```move
match (context) {
    AssetContext {
        asset_state: AssetState::Renting { tenancy: TenancyContext { asset, phase_start_ms, retiring, state: TenancyState::Occupied { tenant } } },
        ...
    } => { ... },
    AssetContext {
        asset_state: AssetState::Waiting { waiting: WaitingContext { asset, state: WaitingState::AtDutch { last_acq_price, phase_start_ms } } },
        ...
    } => { ... },
}
```

This would be fully symmetric with how `TenancyContext` patterns are already written
today, completing the Context-State pattern without any workarounds.

## Workaround

Replace the single deep arm with a two-level match — extract the inner struct first,
then match on its state separately:

```move
AssetContext { asset_state: AssetState::Waiting { waiting }, owner, config, .. } => {
    let WaitingContext { asset, state } = waiting;
    match (state) {
        WaitingState::AtDutch { last_acq_price, phase_start_ms } => { ... },
        _ => abort E_NOT_AT_DUTCH,
    }
},
```

This pattern is used throughout `usufruct/sources/asset_context_state.move`; each
workaround site is annotated with a comment referencing this report.
