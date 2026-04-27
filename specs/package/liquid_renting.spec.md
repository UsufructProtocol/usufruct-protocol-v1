LIQUID RENTING MODULE — SPECIFICATION
======================================

Module: `liquid_renting`
Design reference: n/a (package-level infrastructure, not a design concept)
Module map reference: module-map.spec.md (pending entry)
Depends on: `sui::package`, `sui::transfer`, `sui::tx_context`


0. MODULE RESPONSIBILITY
------------------------

`liquid_renting` is the package's root module. Its only responsibility is to
claim the package's `Publisher` at publish time and deliver it to the deployer.
It owns no domain state and defines no business logic.

**Owns:**
- `LIQUID_RENTING` — the package's One-Time Witness (OTW). `drop`-only,
  no fields. Its sole instance is synthesized by the Sui runtime and
  handed to `init`, which consumes it via `sui::package::claim`.
- `init(otw, ctx)` — package initializer. Runs exactly once at publish.
  Claims the `Publisher` and transfers it to `ctx.sender()`.

**Does not own:**
- Any domain object — caps, escrows, fee inboxes, receipts all live in
  their respective modules with their own constructors. `protocol_fee_inbox`
  has its own `init(ctx)` that creates the fee inbox singleton
  independently of this module.
- Display registration. Display v2 requires `&mut DisplayRegistry` — a
  shared object — which Sui's `init` signature forbids as a parameter.
  All `Display<T>` registration happens in a post-deployment PTB (see §8).
- Any `Display<T>` or `DisplayCap<T>` object. Those are created
  post-deployment from this module's `Publisher`, but never minted here.

**Key design properties:**

- **One Publisher per package deployment.** The OTW-based claim pattern is
  structurally limited to a single success per publish: Sui's runtime
  instantiates exactly one `LIQUID_RENTING` witness, and
  `sui::package::claim` consumes it by value. No runtime check required.

- **Publisher authority is package-scoped, not module-scoped.**
  `Publisher::from_package<T>()` checks the package ID. A `Publisher`
  claimed from the `LIQUID_RENTING` OTW therefore authorizes operations
  on every type defined in the package — `OwnerCap`, `TenantCap`,
  `ProtocolFeeInbox`, and any future type that needs Publisher proof
  (e.g., `TransferPolicy<T>`, Kiosk rules). A single OTW at the package
  root is sufficient; per-module OTWs would be redundant and would
  fragment authority.

- **Coexists with `protocol_fee_inbox::init`.** A Sui package may declare
  multiple `init` functions — one per module — and all run in the publish
  transaction. This module's `init` handles the `Publisher`;
  `protocol_fee_inbox::init` creates the fee inbox singleton. The two
  are independent: neither reads nor writes the other's output. Execution
  order between multiple `init`s is unspecified and does not matter here.

- **Root module by naming convention.** The module name (`liquid_renting`)
  matches the package name (`LiquidRenting` in `Move.toml`, address alias
  `liquid_renting`). This mirrors the idiomatic Sui Move convention for
  modules that host the package-level OTW (as seen in `nft_marketplace`,
  DeepBook's `registry`, etc.).


1. ERROR CONSTANTS
------------------

None. `init` cannot fail — the runtime guarantees the OTW argument and
`sui::package::claim` is infallible given a valid OTW.


2. TYPE
-------

### LIQUID_RENTING — OTW

The package's One-Time Witness. Sui's bytecode verifier enforces the OTW
contract structurally:

- Struct name must match the module name in ALL_CAPS.
- Only `drop` ability permitted.
- No fields.
- No public constructor. The sole instance is synthesized by the runtime
  and passed to `init`.

```move
public struct LIQUID_RENTING has drop {}
```

**Lifecycle:** created by the runtime at package publish, handed to `init`
as its first argument, consumed by `sui::package::claim(otw, ctx)` which
returns a `Publisher`. The OTW never exists as a value anywhere else in
the codebase.

**No fields, no invariants to state.** The OTW carries identity by type,
not by data.


3. EVENTS
---------

**This module emits no events.** Package publication is already observable
via Sui's envelope metadata — the chain records a `PublishedObject` effect
for every published package. Adding a Move-level event would duplicate
information already present in the transaction envelope.


4. FUNCTIONS
------------

### `init`

    fun init(otw: LIQUID_RENTING, ctx: &mut TxContext)

**Visibility:** private (package initializer — invoked by the Sui runtime
at publish, never callable afterwards).

**Purpose:** claims the package's `Publisher` and delivers it to the
deployer.

**Behavior:**
1. `let publisher = sui::package::claim(otw, ctx);` — consumes the OTW
   and mints a `Publisher` whose package/module metadata is derived from
   the OTW's origin module.
2. `transfer::public_transfer(publisher, ctx.sender());` — delivers the
   `Publisher` to the deployer address.

**Side effects:** one `Publisher` object owned by `ctx.sender()`. No
shared objects created. No events emitted.

**Why `public_transfer` rather than `transfer::transfer`:** `Publisher` is
defined in `sui::package` with abilities `key + store`. The Sui bytecode
verifier restricts `transfer::transfer<T>` to types whose defining module
equals the calling module; for foreign `key + store` types, the external
form `transfer::public_transfer` is mandatory. Any other shape fails
verification.

**Alternative considered — `sui::package::claim_and_keep(otw, ctx)`:**
this helper fuses `claim` + `public_transfer` into one call. Semantically
equivalent here. The explicit two-step form is chosen to make the
delivery step visible at the spec level and to leave an obvious seam if
the destination ever needs to change (e.g., transfer to a multisig address
rather than the deployer).


5. PROPERTIES
-------------

**P1 — Exactly one Publisher per package deployment:**
    The OTW is instantiated once by the runtime; `package::claim` consumes
    it by value. No second claim is physically possible. Structural
    guarantee, not a runtime check.

**P2 — Publisher authority covers all types in the package:**
    A `Publisher` claimed from `LIQUID_RENTING` passes
    `Publisher::from_package<T>()` for every type `T` defined in this
    package. The four post-deployment `Display<T>` registrations and any
    future Publisher-gated operation draw authority from this single
    object.

**P3 — No domain state created here:**
    The module constructs no domain object. Burning the `Publisher`
    (via `sui::package::burn_publisher`, should the holder ever choose)
    revokes the ability to register new `Display<T>` or `TransferPolicy<T>`
    but has no effect on escrows, caps, receipts, or the fee inbox.

**P4 — Independent of other `init` functions:**
    `protocol_fee_inbox::init` runs in the same publish transaction but
    reads no state from this module and writes none here. The two
    initializers are commutative — execution order is not observable.


6. TEST CASES
-------------

`init` cannot be invoked directly from a test harness (OTW values cannot
be constructed outside the runtime). The test surface is the behavior
observable after publish. Sui's standard idiom is a `#[test_only]`
helper in this module that mirrors `init` for `test_scenario`:

```move
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(LIQUID_RENTING {}, ctx)
}
```

Tests invoke `init_for_testing` at the start of a scenario and then
inspect the resulting state.

### 6.1 `init`

| # | Description | Expected |
|---|---|---|
| I1 | `test_scenario::begin(sender)` → `init_for_testing(ctx)` → `next_tx(sender)` | `test_scenario::take_from_address<Publisher>(scenario, sender)` yields exactly one `Publisher` object. |
| I2 | On the taken `Publisher`, assert `sui::package::from_package<T>(&publisher)` for every protocol type | Returns `true` for `OwnerCap`, `TenantCap`, `ProtocolFeeInbox`, `ProtocolFeeRef`, and `RentalEscrow<A, C>` (any instantiation). Asserts single-Publisher authority covers the full package surface. |
| I3 | Invoke `init_for_testing` twice in the same scenario | Second call produces a second `Publisher`. This is the expected test-helper behavior and does not reflect production: in production, the OTW contract caps claims at one. Property P1 is a structural property of the OTW, not a runtime assertion — documented here to prevent misreading. |

### 6.2 Publisher usage

| # | Description | Expected |
|---|---|---|
| P1 | Use the claimed `Publisher` to call `display_registry::new_with_publisher<OwnerCap>(&mut registry, &mut publisher, ctx)` | Returns `(Display<OwnerCap>, DisplayCap<OwnerCap>)`. Asserts end-to-end Publisher ↔ Display v2 plumbing works. |
| P2 | Repeat P1 for each of the other two types (`TenantCap`, `ProtocolFeeInbox`) | All three registrations succeed with the same `Publisher`. Confirms P2 (package-scoped authority) empirically. |


7. MODULE BOUNDARY
------------------

`liquid_renting.move` exports:

| Symbol | Visibility | Notes |
|---|---|---|
| `LIQUID_RENTING` (type) | `public` | OTW. `drop`-only. Sole instance consumed at `init`. |
| `init(otw, ctx)` | private | Package initializer. Claims `Publisher`, transfers to deployer. Runs once at publish. |
| `init_for_testing(ctx)` | `#[test_only] public` | Test harness helper. Mirrors `init` without requiring a runtime-synthesized OTW. Not present in production bytecode. |

No error constants. No events. No public functions beyond the OTW type.

**Depends on:** `sui::package`, `sui::transfer`, `sui::tx_context`.


8. POST-DEPLOYMENT SETUP
------------------------

After the package is published, the deployer must run a PTB to register
the four `Display<T>` objects. This PTB is not part of the package — it
is tooling code (TypeScript + Sui SDK, or a Move script) executed once
by the deployer. It is documented here because the `Publisher` minted in
§4 is its sole input from this module.

**Required inputs to the PTB:**
- `&mut Publisher` — the object transferred to the deployer by `init`.
- `&mut DisplayRegistry` — the Sui framework shared object at `0xd`.
- `ctx` — transaction context of the deployer's PTB.

**Operations (one per type, independent, any order):**

| Type | Spec | Display fields |
|---|---|---|
| `OwnerCap` | `caps/owner_cap.spec.md` §8 | static |
| `TenantCap` | `caps/tenant_cap.spec.md` §8 | static |
| `ProtocolFeeInbox` | `fees/protocol_fee_inbox.spec.md` §8 | static |

Each registration returns a `DisplayCap<T>`. All three are transferred to
the deployer, preserving the ability to edit the corresponding
`Display<T>` fields post-deployment (e.g., updating `image_url` when the
media hosting base URL changes).

The four registrations are independent — order does not matter, and they
can be bundled into a single PTB or split across multiple. After this
step, the package is fully operational: escrows can be integrated, caps
minted, receipts issued, fees collected, and every object that appears
in a user wallet renders with its registered Display.

**Status:** [ ] `Publisher` claimed and delivered to deployer.
[ ] Four `Display<T>` objects registered via post-deployment PTB.
