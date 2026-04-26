# Development Flow — usufruct package

## Core cycle

```
sui move build   # compiler is the first arbiter
sui move test    # suite is the second
```

No REPL, no hot-reload. If it compiles and tests pass, the module is correct
to the extent the specs and tests cover it.

## Strategy: TDD, bottom-up

Write tests first, implement second. The specs already enumerate test cases as
tables — TDD here is mechanical translation, not design.

Bottom-up order is **required by the compiler**: a test that imports a
non-existent module is a build error, not a red test. Implement dependencies
before their dependents.

Module order:

    math → curve_shape → price_function
                       → config
                       → owner_cap
                       → tenant_cap
                       → payment_receipt
                       → protocol_fee_inbox → fee_message
                       → rental_escrow
                       → usufruct (root)

## Move-specific TDD nuance

"Red" has two phases in Move:

1. Test references a non-existent function → **build error** (expected)
2. Write a stub signature → compiles → test **fails at runtime** (true red)
3. Implement → test passes

Phase 1 is normal. Don't be surprised by it.

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
