PROTOCOL GLOBAL TREASURY MODULE — SPECIFICATION
================================================

Module: `protocol_global_treasury`
Design reference: design-compact.md §3 (fund flows — protocol fee)
Module map reference: module-map.spec.md §9
Depends on: nothing (only `sui::object`, `sui::transfer`, `sui::tx_context`)


0. MODULE RESPONSIBILITY
------------------------

`protocol_global_treasury` owns the `ProtocolGlobalTreasury` type.
`ProtocolGlobalTreasury` is a shared singleton that serves as the stable inbox
for all `ProtocolLocalTreasury<C>` objects created at escrow retirement.

**Owns:**
- `ProtocolGlobalTreasury` — `key` only shared object. A pure inbox: no balance,
  no phantom type. Contains only a `UID`.
- `init(ctx)` — package initializer. Creates exactly one `ProtocolGlobalTreasury`
  and shares it.
- `uid_mut(global: &mut ProtocolGlobalTreasury): &mut UID` — `public(package)`.
  Exposes the mutable UID reference required by `transfer::receive` in
  `protocol_local_treasury`.

**Does not own:**
- Any balance or fund logic. The inbox never holds funds — it holds child objects.
- Receive or drain logic — that lives in `protocol_local_treasury`.

**Why shared:** `integrate` is called by third-party integrators who do not own
`ProtocolGlobalTreasury`. Shared objects are the only objects accessible as
read-only references by non-owners in a PTB. The escrow registers the inbox ID
at integration time via `&ProtocolGlobalTreasury` (read-only, no contention).

**Why key-only:** `ProtocolGlobalTreasury` is a protocol singleton — it must never
be transferred or wrapped. `key` without `store` enforces this at the type level.


1. ERROR CONSTANTS
------------------

None. `init` cannot fail — it creates a single object unconditionally.


2. TYPE
-------

### ProtocolGlobalTreasury — struct

Shared singleton inbox. Serves as the stable transfer-to-object target for all
`ProtocolLocalTreasury<C>` objects created at escrow retirement.

```move
public struct ProtocolGlobalTreasury has key {
    id: UID,
}
```

**Abilities:** `key` only.
- `key` — shared object identity. Accessible by anyone in a PTB as `&` or `&mut`.
- No `store` — cannot be transferred or wrapped. Shared status is permanent.

**Fields:**
- `id: UID` — object identity. No other fields — the treasury is a pure routing
  object. All value lives in child `ProtocolLocalTreasury<C>` objects.

**Singleton guarantee:** `init` is the only creation site. No public constructor.
Exactly one `ProtocolGlobalTreasury` per package deployment.


3. FUNCTIONS
------------

### `init`

    fun init(ctx: &mut TxContext)

**Visibility:** private (package initializer — called by Sui runtime at publish).

**Behavior:**
1. Creates a `ProtocolGlobalTreasury` with a fresh `UID`.
2. Shares it via `transfer::share_object`.

**Side effects:** one shared `ProtocolGlobalTreasury` object on-chain.
No events emitted.

---

### `uid_mut`

    public(package) fun uid_mut(global: &mut ProtocolGlobalTreasury): &mut UID

**Visibility:** `public(package)` — callable only within this package.

**Purpose:** exposes `&mut UID` to `protocol_local_treasury` so it can call
`transfer::receive(&mut uid, receiving)`. In Sui Move, `transfer::receive`
requires `&mut UID` of the parent object. Since `id` is a private field,
the defining module must expose it explicitly.

**Behavior:** returns `&mut global.id`.

**Safety:** `public(package)` restricts callers to this package. Only
`protocol_local_treasury` calls this function — it is the sole module that
performs `transfer::receive` against `ProtocolGlobalTreasury`.
No external module can obtain `&mut UID` of `ProtocolGlobalTreasury`.


4. PROPERTIES
-------------

**P1 — Singleton shared object:**
    Exactly one `ProtocolGlobalTreasury` exists per package deployment.
    It is shared at creation and lives for the lifetime of the package.

**P2 — Pure inbox:**
    `ProtocolGlobalTreasury` never holds any balance.
    All value is in child `ProtocolLocalTreasury<C>` objects.

**P3 — Non-transferable:**
    `key` without `store` prevents wrapping or transferring.
    The object's shared status is permanent.

**P4 — Accessible by non-owners:**
    As a shared object, any PTB can reference it as `&ProtocolGlobalTreasury`
    (read-only, no contention) or `&mut ProtocolGlobalTreasury` (mutable,
    gated by `ProtocolAdminCap` in the consuming function).

**P5 — uid_mut is package-scoped:**
    Only modules within this package can call `uid_mut`.
    No external module can access `&mut UID` of `ProtocolGlobalTreasury`.


5. TEST CASES
-------------

### 5.1 Initialization

| # | Description | Expected |
|---|---|---|
| T1 | Publish package — `init` runs | Exactly one `ProtocolGlobalTreasury` shared object exists. |

### 5.2 `uid_mut`

Tested indirectly via `protocol_local_treasury::drain_local_treasuries`.

| # | Module | Gate |
|---|---|---|
| T2 | `protocol_local_treasury_tests` | `drain_local_treasuries` can receive child objects via `uid_mut` |


6. MODULE BOUNDARY
------------------

`protocol_global_treasury.move` exports:

| Symbol | Visibility | Notes |
|--------|------------|-------|
| `ProtocolGlobalTreasury` (type) | `public` | `key` only. Shared singleton. |
| `init(ctx)` | private | Package initializer. Runs once at publish. Not callable externally. |
| `uid_mut(global)` | `public(package)` | Returns `&mut UID`. Bridge for `transfer::receive` in `protocol_local_treasury`. |

No error constants.

**Depends on:** nothing (only `sui::object`, `sui::transfer`, `sui::tx_context`).
