PROTOCOL ADMIN CAP MODULE — SPECIFICATION
==========================================

Module: `protocol_admin_cap`
Design reference: design-compact.md §3 (fund flows — protocol fee)
Module map reference: module-map.spec.md §8
Depends on: nothing (only `sui::object`, `sui::transfer`, `sui::tx_context`)


0. MODULE RESPONSIBILITY
------------------------

`protocol_admin_cap` owns two types created together at publish time:
`ProtocolAdminCap` and `ProtocolFeeRef`.

**Owns:**
- `ProtocolAdminCap` — `key + store` singleton. Proof of protocol-level
  administrative authority. Also the transfer-to-object target for all
  `ProtocolLocalTreasury<C>` objects created at escrow retirement — the
  fee inbox and the auth proof are unified in one object.
- `ProtocolFeeRef` — `key` only, frozen at init. Stores the ID of
  `ProtocolAdminCap`. Passed to `integrate` by any integrator so the
  escrow can record where to route protocol fees. Immutable forever.
- `init(ctx)` — package initializer. Creates one `ProtocolAdminCap`
  (transferred to deployer) and one `ProtocolFeeRef` (frozen).
- `uid_mut(cap)` — `public(package)`. Exposes `&mut UID` of
  `ProtocolAdminCap` so `protocol_local_treasury` can call
  `transfer::receive` against it.
- `fee_ref_cap_id(ref)` — `public`. Getter for `ProtocolFeeRef.admin_cap_id`.
  Used by `rental_escrow::integrate` to extract and store the fee inbox ID.

**Does not own:**
- Any balance or fund logic.
- Drain or receive logic — that lives in `protocol_local_treasury`.
- Enforcement logic — other modules gate their functions by requiring
  `&ProtocolAdminCap` as an argument. This module provides the type;
  callers perform the gate.

**Dependency direction:** `protocol_admin_cap` calls no protocol module
functions. It is a leaf in the dependency graph.


1. ERROR CONSTANTS
------------------

None. `init` cannot fail — it creates both objects unconditionally.


2. TYPES
--------

### ProtocolAdminCap — struct

Singleton capability. Proof of protocol-level administrative authority
and transfer-to-object target for protocol fee objects.

```move
public struct ProtocolAdminCap has key, store {
    id: UID,
}
```

**Abilities:** `key + store`.
- `key` — object identity. Lives in a wallet. Can be passed as a
  reference in PTBs. Required for transfer-to-object (fee inbox role).
- `store` — transferable outside the defining module. Enables the admin
  role to be transferred to a new holder (e.g., multisig, DAO).

**Fields:**
- `id: UID` — object identity. No other data fields — the cap conveys
  authority by its existence, not by any stored value. Child
  `ProtocolLocalTreasury<C>` objects accumulate here via transfer-to-object.

**Singleton guarantee:** `init` is the only creation site. Sui's package
initializer runs exactly once at publish time. No public constructor exists.
There is exactly one `ProtocolAdminCap` per package deployment.

**Dual role — auth + inbox:**
- As `&ProtocolAdminCap`: proof of admin authority for `withdraw_treasury`
  and `drain_local_treasuries`.
- As `&mut ProtocolAdminCap`: parent object for `transfer::receive` in
  `drain_local_treasuries`. The mutable reference gates access — only the
  holder can present it.

---

### ProtocolFeeRef — struct

Frozen pointer to `ProtocolAdminCap`. Created once at init and immediately
frozen. Accessible by any PTB without consensus overhead.

```move
public struct ProtocolFeeRef has key {
    id:           UID,
    admin_cap_id: ID,
}
```

**Abilities:** `key` only.
- `key` — object identity. Required to be frozen via `transfer::freeze_object`.
- No `store` — cannot be transferred or wrapped. Frozen status is permanent.

**Fields:**
- `id: UID` — object identity.
- `admin_cap_id: ID` — ID of the `ProtocolAdminCap`. This is the address
  to which `route_fee` sends `ProtocolLocalTreasury<C>` objects.

**Immutability:** frozen at init via `transfer::freeze_object`. The field
`admin_cap_id` never changes. Any PTB can reference `&ProtocolFeeRef`
without going through consensus — immutable objects bypass the sequencer.


3. FUNCTIONS
------------

### `init`

    fun init(ctx: &mut TxContext)

**Visibility:** private (package initializer — called by Sui runtime at publish).

**Behavior:**
1. Creates a `ProtocolAdminCap` with a fresh `UID`. Stores its ID.
2. Transfers `ProtocolAdminCap` to `ctx.sender()` (the deployer).
3. Creates a `ProtocolFeeRef` with `admin_cap_id` set to the stored ID.
4. Freezes `ProtocolFeeRef` via `transfer::freeze_object`.

**Side effects:** one `ProtocolAdminCap` transferred to deployer; one
`ProtocolFeeRef` frozen on-chain. No shared objects created. No events emitted.

---

### `uid_mut`

    public(package) fun uid_mut(cap: &mut ProtocolAdminCap): &mut UID

**Visibility:** `public(package)` — callable only within this package.

**Purpose:** exposes `&mut UID` to `protocol_local_treasury` so it can call
`transfer::receive(&mut uid, receiving)`. In Sui Move, `transfer::receive`
requires `&mut UID` of the parent object. Since `id` is a private field,
the defining module must expose it explicitly.

**Behavior:** returns `&mut cap.id`.

**Safety:** `public(package)` restricts callers to this package. Only
`protocol_local_treasury` calls this function — it is the sole module that
performs `transfer::receive` against `ProtocolAdminCap`.
No external module can obtain `&mut UID` of `ProtocolAdminCap`.

---

### `fee_ref_cap_id`

    public fun fee_ref_cap_id(fee_ref: &ProtocolFeeRef): ID

**Visibility:** `public` — callable by any module, including `rental_escrow`.

**Purpose:** exposes `admin_cap_id` from a frozen `ProtocolFeeRef`. Used by
`rental_escrow::integrate` to read and store the fee inbox ID.

**Behavior:** returns `fee_ref.admin_cap_id`.


4. PROPERTIES
-------------

**P1 — Singleton:**
    Exactly one `ProtocolAdminCap` exists per package deployment.
    No public constructor. `init` is the only creation site.

**P2 — Transferable:**
    `ProtocolAdminCap` has `store`. The holder may transfer it to any address.
    After transfer, the new holder has full admin authority and drain access.

**P3 — Authorization by reference:**
    Functions that require admin authority accept `&ProtocolAdminCap`.
    The type system enforces that the argument exists; no ID check is needed.
    The cap carries no data — its presence is the proof.

**P4 — Fee inbox:**
    `ProtocolLocalTreasury<C>` objects are transferred to `ProtocolAdminCap`'s
    address via transfer-to-object at each `claim_asset`. Draining them
    requires presenting `&mut ProtocolAdminCap` — only the holder can do so.
    Losing the cap permanently locks access to accumulated fee objects.

**P5 — ProtocolFeeRef is immutable:**
    Frozen at init. `admin_cap_id` never changes. Accessible by any PTB
    without consensus overhead. One per package deployment.

**P6 — uid_mut is package-scoped:**
    Only modules within this package can call `uid_mut`.
    No external module can access `&mut UID` of `ProtocolAdminCap`.


5. TEST CASES
-------------

### 5.1 Initialization

| # | Description | Expected |
|---|---|---|
| T1 | Publish package — `init` runs | One `ProtocolAdminCap` owned by deployer. One `ProtocolFeeRef` frozen on-chain. |
| T2 | `fee_ref_cap_id` on `ProtocolFeeRef` | Returns ID equal to `object::id(&admin_cap)`. |
| T3 | Transfer `ProtocolAdminCap` to a new address | New holder can pass `&ProtocolAdminCap` to admin-gated functions. |

### 5.2 Authorization gate

The cap itself has no logic to test beyond creation and transfer.
Authorization enforcement is tested where each gate lives:

| # | Module | Gate |
|---|---|---|
| T4 | `protocol_local_treasury_tests` | `drain_local_treasuries` aborts without `ProtocolAdminCap` |
| T5 | `rental_escrow_tests` | `withdraw_treasury` aborts without `ProtocolAdminCap` |

### 5.3 uid_mut

Tested indirectly via `protocol_local_treasury::drain_local_treasuries`.

| # | Module | Gate |
|---|---|---|
| T6 | `protocol_local_treasury_tests` | `drain_local_treasuries` can receive child objects via `uid_mut` |


6. MODULE BOUNDARY
------------------

`protocol_admin_cap.move` exports:

| Symbol | Visibility | Notes |
|--------|------------|-------|
| `ProtocolAdminCap` (type) | `public` | `key + store`. Singleton. Auth proof and fee inbox. |
| `ProtocolFeeRef` (type) | `public` | `key` only. Frozen. Immutable pointer to `ProtocolAdminCap`. |
| `init(ctx)` | private | Package initializer. Creates both objects. Runs once at publish. |
| `uid_mut(cap)` | `public(package)` | Returns `&mut UID`. Bridge for `transfer::receive` in `protocol_local_treasury`. |
| `fee_ref_cap_id(fee_ref)` | `public` | Returns `admin_cap_id`. Used by `rental_escrow::integrate`. |

No error constants.

**Depends on:** nothing (only `sui::object`, `sui::transfer`, `sui::tx_context`).


7. RATIONALE — DUAL ROLE OF ProtocolAdminCap
---------------------------------------------

### Why not a dedicated shared inbox (ProtocolGlobalTreasury)?

The original design used a separate `ProtocolGlobalTreasury` shared singleton as the
fee inbox. Shared objects in Sui require consensus for every transaction that touches
them — even read-only access. This imposed a consensus cost on two operations:

- `integrate` — reads the shared treasury to register its ID in the escrow.
- `drain_local_treasuries` — mutates the shared treasury to receive child objects.

Both are admin or integrator paths, not user-facing. But `drain` is recurrent — it
fires every time the protocol collects accumulated fees. At a 5% fee rate, the admin's
operational cost directly erodes protocol revenue. Eliminating consensus from the drain
path is not premature optimization; it is proportional to the protocol's margin.

### Why AdminCap as the inbox?

The key insight is that losing `ProtocolAdminCap` already locked access to all admin
functions — including any drain operation. A separate shared treasury would have been
accessible to everyone on-chain but inaccessible to the admin without the cap.
The shared object provided no additional recoverability.

Unifying the inbox into the cap collapses two objects that were always used together
into one. The consequences:

- **Gas**: `drain_local_treasuries` now touches only owned objects — fastpath, no consensus.
- **API**: the drain signature drops one argument. `&mut ProtocolAdminCap` simultaneously
  gates access (capability check) and provides `uid_mut` for `transfer::receive`.
- **Transfer semantics**: transferring `ProtocolAdminCap` to a multisig or DAO transfers
  both admin authority and inbox ownership atomically. With a separate treasury, the
  admin risked partial transfer — cap in one wallet, uncollected fees in another.

### Why ProtocolFeeRef (frozen) instead of passing the ID directly?

`integrate` needs the fee inbox ID to store in each `RentalEscrow`. The alternatives:

1. **Pass raw `ID`** — no type safety. Any integrator could pass an arbitrary ID,
   routing fees to a dead address. Fees would be permanently lost.
2. **Pass `&ProtocolAdminCap`** — requires the admin to co-sign every `integrate`
   transaction. Integrators are third parties; requiring admin presence breaks
   permissionless integration.
3. **Pass `&ProtocolFeeRef`** (chosen) — a frozen object is immutable and accessible
   by any PTB without consensus. It carries a typed guarantee: the ID inside was set
   by the protocol's own `init` and can never be changed. Type safety is preserved;
   the admin is not needed at integration time.

`ProtocolFeeRef` is the minimal object that makes permissionless, type-safe,
consensus-free registration of the fee inbox ID possible.
