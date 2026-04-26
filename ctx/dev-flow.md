# Development Flow — usufruct package

## Core cycle

```
sui move build   # compiler is the first arbiter
sui move test    # suite is the second
```

No REPL, no hot-reload. If it compiles and tests pass, the module is correct
to the extent the specs and tests cover it.

## Strategy: stubs-first TDD, bottom-up

The correct TDD cycle for Move is **stubs before tests**:

1. Write function stubs in `<module>.move` (`abort 0`, params prefixed `_`)
2. `sui move build` → compiles clean
3. Write tests in `<module>_tests.move`
4. `sui move test` → focused errors, all in the test code
5. Implement function by function
6. `sui move test` → green

**Why stubs first, not tests first:**
Writing tests before stubs produces errors mixing "unbound module member"
noise with actual test problems — impossible to act on. With stubs in place
the compiler only reports real test issues, and design problems surface as
single clear errors.

Bottom-up order is **required by the compiler**: a test that imports a
non-existent module is a build error. Implement dependencies before
their dependents.

Module order:

    math → curve_shape → price_function
                       → config
                       → owner_cap
                       → tenant_cap
                       → payment_receipt
                       → protocol_fee_inbox → fee_message
                       → rental_escrow
                       → usufruct (root)

## Move constants are module-internal

`const` in Move has no visibility modifier — constants cannot be accessed
from outside the declaring module. `public const` does not exist and does
not compile.

Specs that mark constants as `public` mean "externally visible" —
implement as getter functions in `=== View Functions ===`.

**Exception — test attributes:** constants from another module can be
referenced in `#[expected_failure(abort_code = ...)]` attributes. This is
a compiler convenience for tests only, not general cross-module access.

```move
#[expected_failure(abort_code = math::EMulDivOverflow, location = usufruct::math)]
fun my_test() { ... }
```

## Two kinds of tests

**Pure arithmetic** (e.g. `math`): no objects, no TxContext. Fast.

```move
#[test]
fun mul_div_exact() { assert!(math::mul_div(6, 7, 3) == 14); }
```

**Sui framework tests** (e.g. `fee_message`): use `test_scenario` to simulate
full transactions with objects, ownership, and events. Slower but required for
any module that touches Sui objects.

## Exception: `exp_scaled` golden vectors

`math::exp_scaled` has TBD golden vectors that cannot be known before running
the algorithm. For this function only:

1. Implement the algorithm first (spec → code)
2. Run it once to extract the 7 u128 literals
3. Fix those values as constants in the test
4. All future changes must reproduce them exactly

Every other function follows strict TDD.

## Filter for speed

```bash
sui move test --filter math        # only math tests
sui move test                      # full suite — run before advancing
```

Always run the full suite after completing a module. A new module can break
an existing one via signature changes.

## Publish (when ready)

```bash
sui client switch --env testnet
sui client publish                 # writes addresses to Published.toml
```

`Published.toml` is committed to git. `Pub.*.toml` (ephemeral nets) is
gitignored.
