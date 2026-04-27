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
- `inbox_id(fee_ref)` — `public`. Getter for `ProtocolFeeRef.inbox_id`.
  Used by `rental_escrow::integrate` to extract and store the fee inbox ID.
  Named after the field it returns — the `&ProtocolFeeRef` parameter
  disambiguates at the call site, matching the peer convention in
  `owner_cap::escrow_id`, `tenant_cap::escrow_id`, `payment_ticket::escrow_id`.

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
1. Constructs a `ProtocolFeeInbox` with a fresh `UID`.
2. Constructs a `ProtocolFeeRef` with `inbox_id: object::id(&inbox)` — read
   inline from the still-live `inbox` local, no bridging variable.
3. Transfers `ProtocolFeeInbox` to `ctx.sender()` (the deployer) via
   `transfer::public_transfer` — idiomatic for `key + store` types, which
   are already externally transferable by any holder.
4. Freezes `ProtocolFeeRef` via `transfer::freeze_object`.

Construction of both objects is grouped; dispatch of both (transfer, freeze)
is grouped after. The data flow `inbox → fee_ref` is expressed directly in
the constructor argument rather than via an intermediate `inbox_id: ID`
local.

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

### `inbox_id`

    public fun inbox_id(fee_ref: &ProtocolFeeRef): ID

**Visibility:** `public` — callable by any module, including `rental_escrow`.

**Purpose:** exposes `inbox_id` from a frozen `ProtocolFeeRef`. Used by
`rental_escrow::integrate` to read and store the fee inbox ID.

**Behavior:** returns `fee_ref.inbox_id`.

**Naming:** the function is named after the field it returns. At every
call site the `&ProtocolFeeRef` parameter type disambiguates the receiver,
so no `fee_ref_` prefix is needed. This mirrors the peer getters in
`owner_cap::escrow_id`, `tenant_cap::escrow_id`, and
`payment_ticket::escrow_id`.


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

### 5.0 Test strategy

Tests live in module `protocol_fee_inbox_tests`, driven by `sui::test_scenario`.
Canonical actors: `DEPLOYER = @0xD1`, `ALICE = @0xA1`, `BOB = @0xB0`.

Because `init` is a private package initializer, the module exposes a single
`#[test_only]` shim so tests can drive it deterministically:

```move
#[test_only] public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }
```

No other test-only helpers are needed:
- `ProtocolFeeInbox` is retrieved from the sender's inventory via
  `test_scenario::take_from_sender<ProtocolFeeInbox>`.
- `ProtocolFeeRef` is retrieved as an immutable global via
  `test_scenario::take_immutable<ProtocolFeeRef>` — this also asserts that it
  was frozen (frozen objects are the only ones available through `take_immutable`).
- `inbox_id` is a public getter, used directly.
- `uid_mut` is `public(package)`, so within this crate tests can call it
  directly to assert it returns the expected mutable reference without needing
  to route through `fee_message`.

**Axes:**
- I — Initialization (post-`init` shape of the world)
- B — ProtocolFeeRef frozenness / immutability
- T — Inbox transferability
- U — `uid_mut` contract
- P — Properties (P1–P5)

#### 5.1 Initialization (I)

Scenario: `DEPLOYER` calls `init_for_testing`.

| # | Assertion on next tx (as `DEPLOYER`) | Rationale |
|---|---|---|
| I1 | `take_from_sender<ProtocolFeeInbox>` succeeds exactly once | P1 singleton + deployer-owned — `init` transfers inbox to `ctx.sender()` |
| I2 | A second `take_from_sender<ProtocolFeeInbox>` in the same tx aborts | P1 singleton — no second inbox created |
| I3 | `take_immutable<ProtocolFeeRef>` succeeds exactly once | P4 frozen + singleton |
| I4 | `inbox_id(&fee_ref) == object::id(&inbox)` | §3 `init` wires `inbox_id` from the still-live `inbox` local |
| I5 | `inbox_id(&fee_ref)` returns the same value across repeated calls | Getter purity; `fee_ref` is frozen so the field cannot drift |
| I6 | `object::id(&inbox) != object::id(&fee_ref)` | Two distinct freshly-minted UIDs |
| I7 | No events emitted during `init` | §3 "No events emitted"; asserts `num_user_events == 0` at end of the tx following init |

#### 5.2 ProtocolFeeRef immutability (B)

| # | Scenario | Expected |
|---|---|---|
| B1 | After init, any later tx calls `take_immutable<ProtocolFeeRef>` from an arbitrary sender (e.g., `ALICE`) | Succeeds — frozen objects are globally readable without ownership |
| B2 | Attempt `take_from_sender<ProtocolFeeRef>` by `DEPLOYER` | Aborts — `ProtocolFeeRef` is frozen, not owned |
| B3 | Attempt `take_shared<ProtocolFeeRef>` | Aborts — not shared |

B2 and B3 are sanity checks on the frozen classification; together with B1 they
pin the ability set `key`-only + frozen declared in §2.

#### 5.3 Inbox transferability (T)

| # | Scenario | Expected |
|---|---|---|
| T1 | `DEPLOYER` calls `transfer::public_transfer(inbox, ALICE)` | Next tx: `ALICE` can `take_from_sender<ProtocolFeeInbox>` |
| T2 | After T1, `DEPLOYER` cannot `take_from_sender<ProtocolFeeInbox>` | Confirms transfer moved custody, not cloned it |
| T3 | After T1, `ALICE` transfers to `BOB`; `BOB` then calls `uid_mut(&mut inbox)` | Returns a `&mut UID` without abort — drain authority follows custody (P2) |
| T4 | Transfer `ProtocolFeeInbox` to `@0x0` | Succeeds structurally (no runtime check), but the object becomes unrecoverable — documents the permissiveness of `public_transfer` |

T4 is a negative-space row: the type system does not prevent it, and the module
does no defensive check. Documented here so that the production rule "do not
send the inbox to `@0x0`" lives outside the code (in ops docs), not as a
runtime abort.

#### 5.4 uid_mut contract (U)

| # | Scenario | Expected |
|---|---|---|
| U1 | Call `uid_mut(&mut inbox)` and compare against `object::id(&inbox)` | Returned `&mut UID` corresponds to the same object (cast via `object::uid_to_inner`) |
| U2 | Call `uid_mut` twice in sequence | Both calls succeed; no internal state mutated by the call itself |
| U3 | Integration: `fee_message_tests::collect_fee_messages` drains a child `FeeMessage<C>` transferred to `ProtocolFeeInbox` | End-to-end proof that `uid_mut` correctly enables `transfer::receive` in the sibling module (cross-ref to `fee_message.spec.md` §TESTS) |

`public(package)` scoping is a compile-time guarantee (external modules cannot
name the symbol), so no runtime row is needed. U1/U2 verify the contract's
shape; U3 anchors it to the single real caller.

#### 5.5 Properties

| Prop | Mapped to |
|------|---|
| P1 Singleton | I1 + I2 + I3 |
| P2 Transferable (custody = drain authority) | T1 + T3 |
| P3 Fee inbox role (transfer-to-object + drain gate) | U3 (cross-module) |
| P4 `ProtocolFeeRef` immutable | B1 + B2 + B3 + I5 |
| P5 `uid_mut` package-scoped | Compile-time; not runtime-testable |

#### 5.6 Open questions

- **`init_for_testing` exposure.** The shim is the minimum surface that makes
  `init` exercisable from tests. It is the only test-only symbol this module
  exports — documented here so later cleanups do not delete it as "unused".
- **`@0x0` transfer (T4).** Recorded as a negative-space test, not an abort.
  Revisit if a protocol-level invariant ever mandates rejecting `@0x0`
  recipients structurally (would require a runtime check inside a wrapper,
  since `public_transfer` itself cannot be overridden).
- **`P5` is untestable at runtime.** Package-scoped visibility is enforced by
  the Move compiler. A would-be test of "external module cannot call
  `uid_mut`" is a compile-error test, which `test_scenario` does not support.
  Recorded as a known gap.


6. MODULE BOUNDARY
------------------

`protocol_fee_inbox.move` exports:

| Symbol | Visibility | Notes |
|--------|------------|-------|
| `ProtocolFeeInbox` (type) | `public` | `key + store`. Singleton. Fee inbox. |
| `ProtocolFeeRef` (type) | `public` | `key` only. Frozen. Immutable pointer to `ProtocolFeeInbox`. |
| `init(ctx)` | private | Package initializer. Creates both objects. Runs once at publish. |
| `uid_mut(inbox)` | `public(package)` | Returns `&mut UID`. Bridge for `transfer::receive` in `fee_message`. |
| `inbox_id(fee_ref)` | `public` | Returns `inbox_id`. Used by `rental_escrow::integrate`. |

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
