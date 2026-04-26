# Code Style — usufruct package

Source: https://docs.sui.io/develop/write-move/move-best-practices

## File structure

Every source file follows this section order, using `===` markers:

```move
// Copyright (c) 2026 Antonio Jiménez
// SPDX-License-Identifier: Apache-2.0

module usufruct::module_name;

// === Imports ===

// === Errors ===

// === Constants ===

// === Structs ===

// === Events ===

// === Method Aliases ===

// === Public Functions ===

// === View Functions ===

// === Admin Functions ===

// === Package Functions ===

// === Private Functions ===

// === Test Functions ===
```

All sections are always present, even if empty. An empty section makes it
explicit that the module has nothing there — it is not an oversight.

`init` goes first inside `Public Functions` if it exists.

## Imports

Group by dependency, one blank line between groups:

```move
use std::option::Option;
use sui::{
    balance::Balance,
    coin::Coin,
    event,
};
use usufruct::math;
```

Order: `std` → `sui` → internal (`usufruct::*`).

## Errors

PascalCase, `E` prefix, descriptive subject noun — maps spec `E_UPPER_SNAKE`
names at implementation time:

```move
const EMulDivOverflow: u64 = 0;         // spec: E_MUL_DIV_OVERFLOW
const EWrongEscrowTenantCap: u64 = 1;   // spec: E_TENANT_CAP_WRONG_ESCROW
```

The subject noun is preserved so the constant is self-describing in error
maps, logs, and explorer UIs without the module qualifier.

## Constants

UPPER_SNAKE_CASE. Separated from error constants by the `=== Constants ===`
section marker.

```move
const TAYLOR_SCALE: u128 = 1_000_000_000_000_000_000;
```

## Structs

Declare abilities in this fixed order: `key`, `copy`, `drop`, `store`.

```move
public struct FeeMessage<phantom C> has key { ... }
public struct FeeMessageSent<phantom C> has copy, drop { ... }
```

Event structs go in `=== Events ===`, not in `=== Structs ===`.
Use the `Event` suffix for event struct names (already the spec convention).

## Comments

`///` for doc comments on `public` and `public(package)` functions and structs.
`//` only where the WHY is non-obvious: a hidden constraint, an invariant,
a workaround, behavior that would surprise a reader.

Field comments: `//` inline on the field, only for non-obvious semantics.

Do not replicate spec content in comments. The spec is the source of truth;
comments capture what the spec cannot — implementation-level constraints.

Exception: algorithm-derived golden vectors in `math::exp_scaled` must
carry a short comment explaining they are fixed outputs of the K=32 Taylor
algorithm, not mathematical floor values.

## Function visibility order

`public` → `public(package)` → `private`

Within each group, order by user flow (constructor → mutator → query).

## Admin functions

Admin-gated functions (those whose access control is enforced by an
owned capability or object ownership) go in `=== Admin Functions ===`,
not in `=== Public Functions ===`.

## Capabilities as second parameter

In admin-gated functions, the capability goes second:

```move
public fun set(account: &mut Account, _: &AdminCap, value: u64) { ... }
```

## Test Functions section (in source files)

`#[test_only]` wrappers that expose private functions live at the end of
the source file, not in the test file. Move visibility rules require them
to be in the declaring module.

```move
// === Test Functions ===

#[test_only]
public fun exp_scaled_pos_for_testing(y_num: u64, y_den: u64): u128 {
    exp_scaled_pos(y_num, y_den)
}
```

The actual test logic (`#[test]` functions) lives in `tests/`.
