PROTOCOL ADMIN CAP MODULE — SPECIFICATION
==========================================

Module: `protocol_admin_cap`
Design reference: design-compact.md (governance)
Module map reference: module-map.spec.md §7
Depends on: nothing (only `sui::object`, `sui::transfer`, `sui::tx_context`)


0. MODULE RESPONSIBILITY
------------------------

`protocol_admin_cap` owns the `ProtocolAdminCap` type and its creation.
`ProtocolAdminCap` is the sole proof of protocol-level administrative authority.
It is minted once at package publish time and transferred to the deployer.

**Owns:**
- `ProtocolAdminCap` — `key + store` capability object. No data fields beyond `id`.
- `init(ctx)` — package initializer. Creates exactly one `ProtocolAdminCap` and
  transfers it to the transaction sender (deployer).

**Does not own:**
- Any treasury logic, fund flows, or escrow state.
- Enforcement logic — other modules gate their functions by requiring
  `&ProtocolAdminCap` as an argument. This module provides the type; callers
  perform the gate.

**Dependency direction:** `protocol_admin_cap` calls no protocol module functions.
It is a leaf in the dependency graph. All other modules that need admin
authorization import only the type.


1. ERROR CONSTANTS
------------------

None. `init` cannot fail — it creates a single object unconditionally.


2. TYPE
-------

### ProtocolAdminCap — struct

Singleton capability. Proves the holder has protocol-level administrative authority.

```move
public struct ProtocolAdminCap has key, store {
    id: UID,
}
```

**Abilities:** `key + store`.
- `key` — object identity. Lives in a wallet. Can be passed as a reference in PTBs.
- `store` — transferable outside the defining module. Enables the admin role to be
  transferred to a new holder (e.g., multisig, DAO).

**Fields:**
- `id: UID` — object identity. No other data fields — the cap conveys authority
  by its existence, not by any stored value.

**Singleton guarantee:** `init` is the only creation site. Sui's package initializer
runs exactly once at publish time. No public constructor exists. There is exactly one
`ProtocolAdminCap` per package deployment.


3. FUNCTIONS
------------

### `init`

    fun init(ctx: &mut TxContext)

**Visibility:** private (package initializer — called by Sui runtime at publish).

**Behavior:**
1. Creates a `ProtocolAdminCap` with a fresh `UID`.
2. Transfers it to `ctx.sender()` (the deployer).

**Side effects:** one `ProtocolAdminCap` object transferred to deployer address.
No shared objects created. No events emitted.


4. PROPERTIES
-------------

**P1 — Singleton:**
    Exactly one `ProtocolAdminCap` exists per package deployment.
    No public constructor. `init` is the only creation site.

**P2 — Transferable:**
    `ProtocolAdminCap` has `store`. The holder may transfer it to any address.
    After transfer, the new holder has full admin authority.

**P3 — Authorization by reference:**
    Functions that require admin authority accept `&ProtocolAdminCap`.
    The type system enforces that the argument exists; no ID check is needed.
    The cap carries no data — its presence is the proof.


5. TEST CASES
-------------

### 5.1 Initialization

| # | Description | Expected |
|---|---|---|
| T1 | Publish package — `init` runs | Exactly one `ProtocolAdminCap` exists. Owned by deployer address. |
| T2 | Transfer `ProtocolAdminCap` to a new address | New holder can pass `&ProtocolAdminCap` to admin-gated functions. |

### 5.2 Authorization gate

The cap itself has no logic to test beyond creation and transfer.
Authorization enforcement is tested in `protocol_local_treasury`
(drain gate) and `rental_escrow` (withdraw_treasury gate).


6. MODULE BOUNDARY
------------------

`protocol_admin_cap.move` exports:

| Symbol | Visibility | Notes |
|--------|------------|-------|
| `ProtocolAdminCap` (type) | `public` | `key + store`. Singleton. |

No error constants. No public functions beyond `init` (private).
No getters — `id` is not exposed; the cap is passed by reference for authorization only.

**Depends on:** nothing (only `sui::object`, `sui::transfer`, `sui::tx_context`).
