# Bug Report: Move Compiler Internal Panic on Deeply Nested Struct-in-Enum Match Patterns

## Summary

The `sui move build` compiler crashes with an internal Rust panic when a match arm
contains a struct-in-enum pattern nested beyond approximately 5 levels deep. The
compiler does not produce a diagnostic — it simply terminates abnormally.

## Environment

- Tool: `sui move build` (Move compiler bundled with the Sui CLI)
- Language: Move 2024

## Reproducer

The following match pattern triggers the panic:

```move
match (context) {
    // This arm causes the compiler to panic:
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

The nesting depth is: `AssetContext` (struct) → `AssetState::Waiting` (enum) →
`WaitingContext` (struct) → `WaitingState::AtDutch` (enum) → `{ u64, u64 }` (struct).

## Compiler Output

```
thread 'main' panicked at
external-crates/move/crates/move-compiler/src/hlir/match_compilation.rs:173:56:
called `Option::unwrap()` on a `None` value
```

No bytecode is emitted. Build fails completely.

## Classification

This is a **compiler bug**, not a language restriction. Evidence:

- No diagnostic is produced — a restriction would yield a proper `error[EXXXXX]` message.
- The same nesting depth compiles successfully when the innermost enum variant carries a
  wrapped type (`asset::Asset<Asset>`) instead of a plain struct (`{ u64, u64 }`),
  suggesting the panic is sensitive to a specific type-shape combination rather than depth
  alone.
- A Rust `unwrap()` panic indicates an unhandled internal state, not an enforced limit.

## Security Impact

None beyond local Denial-of-Service against the compiler process. The panic produces no
output, so no malformed bytecode can reach the chain. Rust's memory safety prevents any
deeper exploitation (no undefined behavior, no memory corruption).

## Workaround

Replace the single deep arm with a two-level match:

```move
// Instead of one deeply nested arm, extract WaitingContext first:
AssetContext {
    asset_state: AssetState::Waiting { waiting },
    owner, config, ..
} => {
    let WaitingContext { asset, state } = waiting;
    match (state) {
        WaitingState::AtDutch { last_acq_price, phase_start_ms } => { ... },
        _ => abort E_NOT_AT_DUTCH,
    }
},
```

This pattern is used throughout `usufruct/sources/asset_context_state.move`; each
workaround site is annotated with a comment referencing this report.
