PROTOCOL FEE INBOX MODULE — SPECIFICATION
==========================================

Module: `protocol_fee_inbox`
Design reference: design-compact.md §3 (fund flows — protocol fee)
Module map reference: module-map.spec.md §9
Depends on: nothing (only `sui::object`, `sui::transfer`, `sui::tx_context`)


0. MODULE RESPONSIBILITY
------------------------

`protocol_fee_inbox` owns two types created together at publish time:
`ProtocolFeeInbox` and `ProtocolFeeRef`.

**Owns:**
- `ProtocolFeeInbox` — `key + store` singleton. Transfer-to-object target
  for all `FeeMessage<C>` objects created at each boundary event — the
  fee inbox is its sole role.
- `ProtocolFeeRef` — `key` only, frozen at init. Stores the ID of
  `ProtocolFeeInbox`. Passed to `integrate` by any integrator so the
  escrow can record where to route protocol fees. Immutable forever.
- `init(ctx)` — package initializer. Creates one `ProtocolFeeInbox`
  (transferred to deployer) and one `ProtocolFeeRef` (frozen).
- `uid_mut(inbox)` — `public(package)`. Exposes `&mut UID` of
  `ProtocolFeeInbox` so `fee_message` can call
  `transfer::receive` against it.
- `fee_ref_inbox_id(ref)` — `public`. Getter for `ProtocolFeeRef.inbox_id`.
  Used by `rental_escrow::integrate` to extract and store the fee inbox ID.

**Does not own:**
- Any balance or fund logic.
- Drain or receive logic — that lives in `fee_message`.

**Authorization model:** `ProtocolFeeInbox` conveys no Move-level capability.
Access to `collect_fee_messages` is enforced by Sui's ownership model —
only the holder of `ProtocolFeeInbox` can present `&mut ProtocolFeeInbox`
in a transaction. No explicit capability check is needed.

**Dependency direction:** `protocol_fee_inbox` calls no protocol module
functions. It is a leaf in the dependency graph.


1. ERROR CONSTANTS
------------------

None. `init` cannot fail — it creates both objects unconditionally.


2. TYPES
--------

### ProtocolFeeInbox — struct

Singleton fee inbox. Transfer-to-object target for all `FeeMessage<C>`
objects created at boundary events across all escrows.

```move
public struct ProtocolFeeInbox has key, store {
    id: UID,
}
```

**Abilities:** `key + store`.
- `key` — object identity. Lives in a wallet. Required for
  transfer-to-object (fee inbox role) and `transfer::receive` parent.
- `store` — transferable outside the defining module. Enables the inbox
  to be transferred to a new holder (e.g., multisig, DAO).

**Fields:**
- `id: UID` — object identity. No other data fields — child
  `FeeMessage<C>` objects accumulate here via transfer-to-object.

**Singleton guarantee:** `init` is the only creation site. Sui's package
initializer runs exactly once at publish time. No public constructor exists.
There is exactly one `ProtocolFeeInbox` per package deployment.

**Role:** The holder presents `&mut ProtocolFeeInbox` to `collect_fee_messages`.
Sui's ownership model enforces that only the holder can do so — no
Move-level capability check is required. Transferring `ProtocolFeeInbox`
atomically transfers both inbox ownership and drain authority.

---

### ProtocolFeeRef — struct

Frozen pointer to `ProtocolFeeInbox`. Created once at init and immediately
frozen. Accessible by any PTB without consensus overhead.

```move
public struct ProtocolFeeRef has key {
    id:       UID,
    inbox_id: ID,
}
```

**Abilities:** `key` only.
- `key` — object identity. Required to be frozen via `transfer::freeze_object`.
- No `store` — cannot be transferred or wrapped. Frozen status is permanent.

**Fields:**
- `id: UID` — object identity.
- `inbox_id: ID` — ID of the `ProtocolFeeInbox`. This is the address
  to which `send_fee` transfers `FeeMessage<C>` objects.

**Immutability:** frozen at init via `transfer::freeze_object`. The field
`inbox_id` never changes. Any PTB can reference `&ProtocolFeeRef`
without going through consensus — immutable objects bypass the sequencer.


3. FUNCTIONS
------------

### `init`

    fun init(ctx: &mut TxContext)

**Visibility:** private (package initializer — called by Sui runtime at publish).

**Behavior:**
1. Creates a `ProtocolFeeInbox` with a fresh `UID`. Stores its ID.
2. Transfers `ProtocolFeeInbox` to `ctx.sender()` (the deployer).
3. Creates a `ProtocolFeeRef` with `inbox_id` set to the stored ID.
4. Freezes `ProtocolFeeRef` via `transfer::freeze_object`.

**Side effects:** one `ProtocolFeeInbox` transferred to deployer; one
`ProtocolFeeRef` frozen on-chain. No shared objects created. No events emitted.

---

### `uid_mut`

    public(package) fun uid_mut(inbox: &mut ProtocolFeeInbox): &mut UID

**Visibility:** `public(package)` — callable only within this package.

**Purpose:** exposes `&mut UID` to `fee_message` so it can call
`transfer::receive(&mut uid, receiving)`. In Sui Move, `transfer::receive`
requires `&mut UID` of the parent object. Since `id` is a private field,
the defining module must expose it explicitly.

**Behavior:** returns `&mut inbox.id`.

**Safety:** `public(package)` restricts callers to this package. Only
`fee_message` calls this function — it is the sole module that
performs `transfer::receive` against `ProtocolFeeInbox`.
No external module can obtain `&mut UID` of `ProtocolFeeInbox`.

---

### `fee_ref_inbox_id`

    public fun fee_ref_inbox_id(fee_ref: &ProtocolFeeRef): ID

**Visibility:** `public` — callable by any module, including `rental_escrow`.

**Purpose:** exposes `inbox_id` from a frozen `ProtocolFeeRef`. Used by
`rental_escrow::integrate` to read and store the fee inbox ID.

**Behavior:** returns `fee_ref.inbox_id`.


4. PROPERTIES
-------------

**P1 — Singleton:**
    Exactly one `ProtocolFeeInbox` exists per package deployment.
    No public constructor. `init` is the only creation site.

**P2 — Transferable:**
    `ProtocolFeeInbox` has `store`. The holder may transfer it to any address.
    After transfer, the new holder has full drain access.

**P3 — Fee inbox:**
    `FeeMessage<C>` objects are transferred to `ProtocolFeeInbox`'s
    address via transfer-to-object at each boundary event. Draining them
    requires presenting `&mut ProtocolFeeInbox` — only the holder can do so.
    Losing the inbox permanently locks access to accumulated fee objects.

**P4 — ProtocolFeeRef is immutable:**
    Frozen at init. `inbox_id` never changes. Accessible by any PTB
    without consensus overhead. One per package deployment.

**P5 — uid_mut is package-scoped:**
    Only modules within this package can call `uid_mut`.
    No external module can access `&mut UID` of `ProtocolFeeInbox`.


5. TEST CASES
-------------

### 5.1 Initialization

| # | Description | Expected |
|---|---|---|
| T1 | Publish package — `init` runs | One `ProtocolFeeInbox` owned by deployer. One `ProtocolFeeRef` frozen on-chain. |
| T2 | `fee_ref_inbox_id` on `ProtocolFeeRef` | Returns ID equal to `object::id(&fee_inbox)`. |
| T3 | Transfer `ProtocolFeeInbox` to a new address | New holder can present `&mut ProtocolFeeInbox` to drain-gated functions. |

### 5.2 Authorization gate

The inbox itself has no logic to test beyond creation and transfer.
Authorization is enforced by the type system — `collect_fee_messages` requires
`&mut ProtocolFeeInbox` as a parameter, so a call without the object does not
compile. There is no runtime abort to test; the guarantee is structural.

Correct behavior is verified where the gate is exercised:

| # | Module | What is verified |
|---|---|---|
| T4 | `fee_message_tests` | `collect_fee_messages` successfully drains when `&mut ProtocolFeeInbox` is presented — confirming the structural gate works end-to-end |

### 5.3 uid_mut

Tested indirectly via `fee_message::collect_fee_messages`.

| # | Module | Gate |
|---|---|---|
| T5 | `fee_message_tests` | `collect_fee_messages` can receive child objects via `uid_mut` |


6. MODULE BOUNDARY
------------------

`protocol_fee_inbox.move` exports:

| Symbol | Visibility | Notes |
|--------|------------|-------|
| `ProtocolFeeInbox` (type) | `public` | `key + store`. Singleton. Fee inbox. |
| `ProtocolFeeRef` (type) | `public` | `key` only. Frozen. Immutable pointer to `ProtocolFeeInbox`. |
| `init(ctx)` | private | Package initializer. Creates both objects. Runs once at publish. |
| `uid_mut(inbox)` | `public(package)` | Returns `&mut UID`. Bridge for `transfer::receive` in `fee_message`. |
| `fee_ref_inbox_id(fee_ref)` | `public` | Returns `inbox_id`. Used by `rental_escrow::integrate`. |

No error constants.

**Depends on:** nothing (only `sui::object`, `sui::transfer`, `sui::tx_context`).


7. RATIONALE — ProtocolFeeInbox AS INBOX
-----------------------------------------

### Why an owned object instead of a shared inbox?

A shared singleton inbox would require consensus for every transaction
that touches it. This imposes a cost on two operations:

- `integrate` — reads the inbox ID to register it in the escrow.
- `collect_fee_messages` — mutates the inbox to receive child objects.

`collect_fee_messages` is the critical path. It fires every time the
protocol collects fees — a recurrent admin operation. At a 5% fee rate,
consensus overhead on the drain path directly erodes protocol revenue.

`ProtocolFeeInbox` as an owned object eliminates both costs. Transfer-to-object
does not mutate the parent — `FeeMessage<C>` objects accumulate as children
for free, with no contention on the inbox. The drain operation touches only
owned objects (`ProtocolFeeInbox` and the `Receiving` tickets), so Sui routes
it through the fastpath with no consensus overhead.

Transferring `ProtocolFeeInbox` to a multisig or DAO transfers inbox ownership
and drain authority atomically. No partial transfer risk.

### Why ProtocolFeeRef (frozen) instead of passing the ID directly?

`integrate` needs the fee inbox ID to store in each `RentalEscrow`.
The alternatives:

1. **Pass raw `ID`** — no type safety. Any integrator could pass an arbitrary ID,
   routing fees to a dead address. Fees would be permanently lost.
2. **Pass `&ProtocolFeeInbox`** — requires the inbox holder to co-sign every
   `integrate` transaction. Integrators are third parties; requiring holder
   presence breaks permissionless integration.
3. **Pass `&ProtocolFeeRef`** (chosen) — a frozen object is immutable and
   accessible by any PTB without consensus. It carries a typed guarantee:
   the ID inside was set by the protocol's own `init` and can never be
   changed. Type safety is preserved; the inbox holder is not needed at
   integration time.

`ProtocolFeeRef` is the minimal object that makes permissionless, type-safe,
consensus-free registration of the fee inbox ID possible.


8. OBJECT DISPLAY
-----------------

![ProtocolFeeInbox](../../media/object-display/protocol-fee-inbox.png)

`Display<ProtocolFeeInbox>` gives the singleton inbox a visual identity in the
deployer's wallet. Unlike `OwnerCap` and `TenantCap`, this is a protocol-level
object — not a per-user capability. Its Display reflects that: no dynamic field
references, purely descriptive.

Created once post-deployment via a PTB presenting `&mut Publisher` for the
package and `&mut DisplayRegistry` (Sui framework shared object at `0xd`).

### Fields

| Key | Value | Notes |
|---|---|---|
| `name` | `Protocol Fee Inbox` | Static. |
| `description` | `Singleton fee inbox for the Liquid Renting Protocol. Accumulates FeeMessage objects transferred at each boundary event across all escrows.` | Static. |
| `image_url` | `{IMAGE_BASE_URL}/protocol-fee-inbox.png` | Hosted URL. Source: `media/object-display/protocol-fee-inbox.png`. |
| `project_url` | `https://liquidrenting.com` | Static. |
| `creator` | `Liquid Renting Protocol` | Static. |

`{IMAGE_BASE_URL}` is set at deployment time to the protocol's media hosting base URL.

### Creation

```move
use sui::display_registry;

let (mut display, cap) = display_registry::new_with_publisher<ProtocolFeeInbox>(
    registry,   // &mut DisplayRegistry (shared object 0xd)
    publisher,  // &mut Publisher
    ctx,
);
display_registry::set(&mut display, &cap, b"name".to_string(),        b"Protocol Fee Inbox".to_string());
display_registry::set(&mut display, &cap, b"description".to_string(), b"Singleton fee inbox for the Liquid Renting Protocol. Accumulates FeeMessage objects transferred at each boundary event across all escrows.".to_string());
display_registry::set(&mut display, &cap, b"image_url".to_string(),   b"{IMAGE_BASE_URL}/protocol-fee-inbox.png".to_string());
display_registry::set(&mut display, &cap, b"project_url".to_string(), b"https://liquidrenting.com".to_string());
display_registry::set(&mut display, &cap, b"creator".to_string(),     b"Liquid Renting Protocol".to_string());
display_registry::share(display);
transfer::public_transfer(cap, ctx.sender());  // cap retained by deployer for future edits
```

One `Display<ProtocolFeeInbox>` per package deployment — enforced by
`DisplayRegistry`. ID is deterministic from `DisplayRegistry` + type — no event
scanning required. The returned `DisplayCap<ProtocolFeeInbox>` is required to
call `set` / `unset` / `clear` later; keeping it with the deployer preserves the
ability to edit the Display post-deployment.

**Note:** `ProtocolFeeRef` has no Display — it is a frozen infrastructure pointer,
never held in a user wallet and not intended for human-facing rendering.

**Status:** [ ] `Display<ProtocolFeeInbox>` created and committed.
