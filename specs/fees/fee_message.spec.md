FEE MESSAGE MODULE — SPECIFICATION
====================================

Module: `fee_message`
Design reference: design-compact.md §3 (fund flows — protocol fee)
Module map reference: module-map.spec.md §10
Depends on: `protocol_fee_inbox`, `sui::event`, `sui::object`


0. MODULE RESPONSIBILITY
------------------------

`fee_message` owns the `FeeMessage<C>` type and all fund-routing logic
for protocol fees at each boundary event.

**Owns:**
- `FeeMessage<phantom C>` — `key` only. Created at boundary events
  (handover, tenure expiry) to wrap a protocol fee balance. Transferred
  to `ProtocolFeeInbox` via transfer-to-object. Deleted at drain time.
- `post<C>(balance, escrow_id, tenant, fee_inbox_id, ctx)` —
  `public(package)`. Sole public entry point for fee posting: constructs
  a `FeeMessage<C>` inline, transfers it to `fee_inbox_id` via
  transfer-to-object, and emits `FeeMessageSent<C>`. Fused form — the
  `FeeMessage<C>` object never exists as a local in any caller, so no
  orphan-constructor surface is reachable from outside this module.
  `tenant` is the address whose stake produced the fee — metadata only,
  recorded on the `FeeMessageSent<C>` event row but not stored on the
  `FeeMessage<C>` struct. Routing target is `fee_inbox_id`, which sits
  in the recipient slot just before `ctx`; `tenant` cannot be mistaken
  for a transfer destination because the fused signature makes
  `fee_inbox_id`'s role unambiguous.
- `receive_message<C>(...)` — private. Receives one `FeeMessage<C>` from
  the inbox via `transfer::receive`. Single-object step.
- `consume_message<C>(msg, ctx)` — private. Destructures a
  `FeeMessage<C>`, deletes its `UID`, captures
  `tx_context::sender(ctx)` as `collector`, and returns its
  `Balance<C>`. The `collector` address is recorded on the
  `FeeMessageCollected<C>` event row.
- `collect_fee_messages<C>(...)` — `public`. Pipeline of
  `receive_message` + `consume_message` over a vector, with an internal
  `Balance<C>` accumulator. Single pass — O(n). Returns `Coin<C>`.
  Called by admin.
- Lifecycle events `FeeMessageSent<C>` (at post) and
  `FeeMessageCollected<C>` (at consume). Declared in this module per
  Sui Verifier constraint (emitted type must be internal to the
  emitting module).

**Does not own:**
- Inbox type or uid_mut — those live in `protocol_fee_inbox`.

**Key design properties:**
- `FeeMessage` is `key` only. `transfer::receive` is restricted to this
  module — no external code can receive these objects from the inbox.
- `key`-only combined with the fused `post` entry point means no caller
  ever holds a `FeeMessage<C>` as a local. There is no separable
  constructor; `FeeMessage<C>` is constructed, transferred, and logged
  in a single atomic step inside `post`. A future refactor cannot split
  construction from placement without modifying this module.
- The module makes no assumption about the wrapped balance. As a
  cleanliness convention, callers destroy empty balances with
  `balance::destroy_zero` before invoking `post`, but this is a caller
  concern — not enforced or required here. A `FeeMessage` with
  `balance == 0` is structurally valid; it flows through `post` and
  drains normally, with both lifecycle events reporting `amount: 0`.
- One `collect_fee_messages<C>` call handles one CoinType.
  Multiple calls for different types may be chained in a single PTB,
  all sharing one `&mut ProtocolFeeInbox` — fastpath, no consensus.
- The accumulator is `Balance<C>`, not `Coin<C>` — `ctx` is only used
  once at the end to wrap the total. No intermediate coins created.


1. ERROR CONSTANTS
------------------

None. No function in this module has a runtime-aborting precondition:
- `post<C>` wraps whatever balance it receives, including zero. A
  defensive `balance > 0` assert here would introduce an abort at a
  critical protocol path (boundary events) for a case that has a
  cleaner caller-side handling via `balance::destroy_zero`. The cost
  of an abort at handover or tenure expiry far exceeds the benefit of
  enforcing the invariant runtime-side.
- `collect_fee_messages` accepts an empty vector as a valid no-op.


2. TYPE
-------

### FeeMessage — struct

Per-boundary-event fee message. Wraps the protocol fee balance from one
handover or tenure expiry. Transferred to `ProtocolFeeInbox` as a child
object via transfer-to-object immediately at the split. Deleted at drain time.

```move
public struct FeeMessage<phantom CoinType> has key {
    id:           UID,
    fee_inbox_id: ID,
    escrow_id:    ID,
    balance:      Balance<CoinType>,
}
```

**Abilities:** `key` only.
- `key` — object identity. Required for transfer-to-object and `transfer::receive`.
- No `store` — `transfer::receive` is restricted to `fee_message.move`.
  No external module can receive or move these objects.

**Fields:**

| Field | Type | Meaning |
|---|---|---|
| `id` | `UID` | Object identity. |
| `fee_inbox_id` | `ID` | The `ProtocolFeeInbox` this message was posted to. Set at creation; never mutated. Redundant with the transfer-to-object parent relation that Sui tracks, but carried in the struct so `consume_message` can emit it after `object::delete` without extra arguments. |
| `escrow_id` | `ID` | The originating `Escrow<T,C>` whose boundary event produced this fee. Set at creation; never mutated. Not recoverable from any other source at drain time, so carried in the struct. |
| `balance` | `Balance<CoinType>` | Protocol fee amount. Any value is structurally valid, including zero — the module makes no assumption. Callers typically ensure `> 0` by cleanliness convention, but no code here depends on it. |

**Invariants:**
- `self.fee_inbox_id` equals the transfer-to-object parent of `self` —
  the inbox to which `post` routed it.
- `self.escrow_id` equals the ID of the escrow that called `post`.

**No balance invariant.** A `FeeMessage` may carry any balance value.
A zero-balance message is structurally valid: `post` still transfers
it, `consume_message` still drains it, events still fire. See §1 for
the rationale against asserting `balance > 0`.


3. EVENTS
---------

The module records the lifecycle of each `FeeMessage<C>`: one event at
posting to the inbox, one event at consumption. The two events share
an identity pair (`fee_message_id`, `fee_inbox_id`, `escrow_id`,
`amount`) and each carries an address that is *first-observed at that
stage* — `tenant` on Sent, `collector` on Collected. Addresses do not
duplicate across the pair: the common `fee_message_id` acts as a
primary key for a Sent↔Collected JOIN.

### FeeMessageSent — event

```move
public struct FeeMessageSent<phantom CoinType> has copy, drop {
    fee_message_id: ID,
    fee_inbox_id:   ID,
    escrow_id:      ID,
    amount:         u64,
    tenant:         address,
}
```

**Fields:**

| Field | Type | Meaning |
|---|---|---|
| `fee_message_id` | `ID` | Identity of the newly created `FeeMessage<CoinType>`. Primary key for the Sent↔Collected JOIN. |
| `fee_inbox_id` | `ID` | The `ProtocolFeeInbox` that received the message. |
| `escrow_id` | `ID` | The originating escrow whose boundary event produced this fee. |
| `amount` | `u64` | `balance::value(&balance)` at creation. Any value including zero, mirroring the wrapped balance. |
| `tenant` | `address` | The tenant whose stake funded this fee. Passed by `rental_escrow`: `displaced_tenant` at handover, `current_tenant_address` at tenure expiry. Declarative — not stored on the `FeeMessage<C>` struct and not derivable elsewhere in this module. |

**Emission site:** `post<C>`, after
`transfer::transfer(msg, fee_inbox_id.to_address())` — emit-last,
inside the fused entry point. Exactly one emission per posted message.
No separable constructor exists; construction and placement are a
single atomic step.

### FeeMessageCollected — event

```move
public struct FeeMessageCollected<phantom CoinType> has copy, drop {
    fee_message_id: ID,
    fee_inbox_id:   ID,
    escrow_id:      ID,
    amount:         u64,
    collector:      address,
}
```

**Fields:**

| Field | Type | Meaning |
|---|---|---|
| `fee_message_id` | `ID` | Identity of the `FeeMessage<CoinType>` that was consumed. Joinable to `FeeMessageSent.fee_message_id`. |
| `fee_inbox_id` | `ID` | The `ProtocolFeeInbox` the message was drained from. Copied from the consumed object's `fee_inbox_id` field. |
| `escrow_id` | `ID` | The originating escrow. Copied from the consumed object's `escrow_id` field. |
| `amount` | `u64` | `balance::value(&balance)` at the moment of consumption. |
| `collector` | `address` | `tx_context::sender(ctx)` at consume time — the admin who drained the message. First-observed at this stage; not available at mint or post. |

**Emission site:** `consume_message<C>`, after `object::delete(id)`.
Exactly one emission per consumed message. Because
`collect_fee_messages<C>` invokes `consume_message` in a loop, a drain
of N messages produces N `FeeMessageCollected<C>` events in the same
transaction.

**Design intent — events as SQL rows keyed by natural PKs:** the
protocol's event layer feeds an off-chain indexer whose schema is
anchored on `escrow_id` as the root foreign key and on
`fee_message_id` as the primary key that pairs Sent and Collected.
Address data lives only where it is first-observed: `tenant` (the
stake funder) is known at post time and is recorded on Sent only;
`collector` (the drainer) is known at consume time and is recorded
on Collected only. The shared `fee_message_id` is the JOIN key — an
indexer answers *"who drained the fee produced by tenant X on escrow
Y?"* with a single Sent↔Collected JOIN, without either row carrying
both addresses. Same discipline as cap lifecycle events
(`TenantCapMinted` / `TenantCapBurned`, `OwnerCapMinted` /
`OwnerCapBurned`), where the cap's own ID is the PK and addresses
only appear on events where they are first-observed or diverge.

**No aggregate drain event:** `collect_fee_messages<C>` does not emit a
summary event. Total amount and message count are reconstructible
off-chain from the set of `FeeMessageCollected<C>` events of the tx;
an aggregate would duplicate information while losing per-object
correlation.

### Sui Verifier constraint

`event::emit<T>` requires `T` to be defined in the emitting module, so
`FeeMessageSent<C>` and `FeeMessageCollected<C>` are declared here in
`fee_message.move`.

### No `timestamp_ms` field

Both events omit an explicit timestamp. The module has no authoritative
time to report: `post` may be reached from a lazy-settlement path whose
logical moment is in the past, so neither the tx envelope
timestamp nor `clock.now()` corresponds to the logical moment the event
belongs to. The module emits identity and amount only.

### Emit-last convention

At both emission sites, `event::emit` runs *after* the state-changing
operation that the event describes (transfer in `post`, `object::delete`
in `consume_message`). Values needed in the event body are bound to
locals before the consuming call so they remain available at emit
time.


4. FUNCTIONS
------------

### `post`

    public(package) fun post<C>(
        balance:      Balance<C>,
        escrow_id:    ID,
        tenant:       address,
        fee_inbox_id: ID,
        ctx:          &mut TxContext,
    )

**Visibility:** `public(package)` — callable only by `rental_escrow`.

**Purpose:** sole public entry point for posting a protocol fee to the
inbox. Constructs a `FeeMessage<C>` inline, transfers it to
`fee_inbox_id` via transfer-to-object, and emits
`FeeMessageSent<C> { ..., tenant }`. Fused form — no intermediate
`FeeMessage<C>` ever escapes this function.

**Behavior:**
1. Bind identity locals from the constructor inputs and the wrapped
   balance — these survive past the transfer that consumes the
   object:
   - `let amount = balance::value(&balance);`
2. Construct inline:
   ```
   let msg = FeeMessage<C> {
       id: object::new(ctx),
       fee_inbox_id,
       escrow_id,
       balance,
   };
   let fee_message_id = object::uid_to_inner(&msg.id);
   ```
3. `transfer::transfer(msg, fee_inbox_id.to_address());`
4. `event::emit(FeeMessageSent<C> { fee_message_id, fee_inbox_id, escrow_id, amount, tenant });`

**No preconditions enforced.** By convention:
- `fee_inbox_id` is the ID of the `ProtocolFeeInbox` singleton (as
  stored in the escrow at `integrate` time).
- `escrow_id` is the ID of the `Escrow<T,C>` currently being mutated
  by the caller.
- `balance` is typically non-zero — callers destroy empty balances
  with `balance::destroy_zero` before calling `post` as a cleanliness
  practice, not because this module requires it.

**Argument roles:**
- `balance`, `escrow_id`, `fee_inbox_id` — constructor inputs; become
  fields of the `FeeMessage<C>` object.
- `tenant` — metadata for the event row only. Routing target is
  `fee_inbox_id` (not `tenant`); `tenant` is never used as a transfer
  destination. The `FeeMessage<C>` struct intentionally does not
  store it — it is first-observed at post time and recorded on the
  `FeeMessageSent<C>` event under the canonical `tenant` field
  (star-schema dimension name).
- `fee_inbox_id` is placed just before `ctx` per the protocol-wide
  convention that transfer-target arguments sit in the recipient
  position, even when the target is an object ID rather than a raw
  address. The fused signature makes the routing role of
  `fee_inbox_id` unambiguous, which is why `tenant` can sit mid-list
  as pure metadata without confusing a reader into thinking it is a
  destination.

**`tenant` is declarative:** this module performs no runtime check
against it. The caller (`rental_escrow`) is authoritative: at
`do_handover` it passes `displaced_tenant`; at `do_tenure_expiry` it
passes the current tenant's address. The field is the sole record of
"who funded this fee" in the event stream.

**Linearity — single public sink:** `FeeMessage<C>` has `key` only and
no separable constructor is exposed. The object is created, transferred
and logged inside `post` — no caller can observe it as a local, store
it, wrap it, or re-route it. A future change that wanted to split
construction from placement would have to modify this module; no
caller-side refactor can introduce an orphan `FeeMessage<C>`.

**Call sites:** called by `do_handover` and `do_tenure_expiry` inside
`rental_escrow` — once per boundary event where the caller elects to
post a fee message. Not called at `claim_asset`.

**Why transfer-to-object, not `&mut ProtocolFeeInbox`:**
`ProtocolFeeInbox` is an owned object. In Sui, owned objects can only
be included in a transaction by their owner. Boundary events are
triggered by tenants, bots, or any permissionless caller — none of
whom own `ProtocolFeeInbox`. Transferring to the inbox's address is
the only viable path.

**Transfer-to-object is free:** `transfer::transfer` to an object ID
does not mutate `ProtocolFeeInbox`. No contention on the inbox at
boundary event time.

**Events:** emits `FeeMessageSent<C>` once per call, after the
transfer (emit-last). See §3.

---

### `receive_message`

    fun receive_message<C>(
        inbox:  &mut ProtocolFeeInbox,
        ticket: Receiving<FeeMessage<C>>,
    ): FeeMessage<C>

**Visibility:** private — called only by `collect_fee_messages`.

**Purpose:** receives one `FeeMessage<C>` from the inbox.

**Behavior:** calls `transfer::receive(protocol_fee_inbox::uid_mut(inbox), ticket)`
and returns the `FeeMessage<C>`.

**Why `transfer::receive` compiles here:** `FeeMessage` is `key` only.
The Sui Move bytecode verifier enforces that `transfer::receive` may only
be called in the module that defines the child type — here, `fee_message.move`.

---

### `consume_message`

    fun consume_message<C>(msg: FeeMessage<C>, ctx: &TxContext): Balance<C>

**Visibility:** private — called only by `collect_fee_messages`.

**Purpose:** destructs a `FeeMessage<C>`, deletes its object identity,
captures the draining caller as `collector`, and returns its balance.

**Behavior:**
1. Destructure: `FeeMessage { id, fee_inbox_id, escrow_id, balance } = msg`.
2. Capture `let fee_message_id = object::uid_to_inner(&id);` and
   `let amount = balance::value(&balance);` — bound before
   `object::delete(id)` consumes the `UID`.
3. `let collector = tx_context::sender(ctx);` — the admin presenting
   the inbox and its receive tickets.
4. `object::delete(id);`
5. `event::emit(FeeMessageCollected<C> { fee_message_id, fee_inbox_id, escrow_id, amount, collector });`
6. Returns `balance`.

**Why `ctx: &TxContext` (not `&mut`):** only a read of
`tx_context::sender(ctx)` is needed — no new objects are created in
this function. `collect_fee_messages` already holds `&mut TxContext`
and can pass it as `&` to `consume_message`.

**No `inbox` argument:** deletion requires only the object itself.
`&mut ProtocolFeeInbox` is not needed here — it was only required for
`transfer::receive` in `receive_message`.

**Events:** emits `FeeMessageCollected<C>` once per call, after
`object::delete` (emit-last). See §3.

---

### `collect_fee_messages`

    public fun collect_fee_messages<C>(
        inbox:   &mut ProtocolFeeInbox,
        tickets: vector<Receiving<FeeMessage<C>>>,
        ctx:     &mut TxContext,
    ): Coin<C>

**Visibility:** `public` — callable by the admin from a PTB.

**Purpose:** pipeline of `receive_message` + `consume_message` over all
tickets for one CoinType. Accumulates balances, deletes objects, returns
a single `Coin<C>`.

**Behavior:**
1. Initializes `total: Balance<C> = balance::zero()`.
2. For each `ticket` in `tickets`:
   a. `let msg = receive_message(inbox, ticket)`
   b. `balance::join(&mut total, consume_message(msg, ctx))`
3. Returns `coin::from_balance(total, ctx)`.

**Single pass — O(n):** each `FeeMessage` is received and consumed in
one iteration. The `Balance<C>` accumulator avoids intermediate coins —
`ctx` is used only once at step 3.

**Empty vector:** if `tickets` is empty, returns a zero-value `Coin<C>`.
Valid no-op.

**Authorization — dual enforcement:**
- **Structural (compiler):** `FeeMessage` is `key` only →
  `transfer::receive` compiles only inside `fee_message.move`.
  No external module can call `receive_message`.
- **Ownership (runtime):** `inbox: &mut ProtocolFeeInbox` forces the PTB
  to include the owned `ProtocolFeeInbox`. Only the holder can present it
  as mutable.

**Fastpath:** touches only owned objects — `ProtocolFeeInbox` and the
`Receiving` tickets. No shared objects. Sui routes through the
owned-object fastpath — no consensus overhead.

**One call per CoinType:** `Receiving<FeeMessage<C>>` is typed over `C`.
The admin's off-chain indexer queries `suix_getOwnedObjects` for
`FeeMessage<C>` children of `ProtocolFeeInbox`, groups them by CoinType,
and builds one `vector<Receiving<...>>` per type. Multiple calls may be
chained in a single PTB, all sharing the same `&mut ProtocolFeeInbox`.

**Events:** this function emits no event directly. Each inner
`consume_message` call emits one `FeeMessageCollected<C>`, so a drain
of N messages produces N events in the same transaction. See §3.


5. PROPERTIES
-------------

**P1 — Balance-agnostic wrapper:**
    The module makes no assumption about the wrapped balance. A
    `FeeMessage` with `balance == 0` is structurally valid: it
    transfers, drains, and emits events like any other. The cleanliness
    of avoiding zero-balance messages is the caller's responsibility —
    `rental_escrow` destroys empty balances with `balance::destroy_zero`
    before calling `post` — but no code here depends on it.

**P2 — Receive restricted to this module:**
    `FeeMessage` has `key` only. `transfer::receive` is only callable
    from `fee_message.move`. No external module can drain the inbox.

**P2b — Single public sink, no orphan construction:**
    `FeeMessage<C>` has no separable constructor. The only
    `public(package)` entry point, `post<C>`, fuses construction,
    transfer-to-object, and event emission in a single atomic body.
    No caller can hold a `FeeMessage<C>` as a local, wrap it, or route
    it elsewhere. Stronger than a mere linearity argument: there is
    no handle on which linearity could apply.

**P3 — Objects deleted at drain:**
    Every `FeeMessage` passed to `consume_message` is destructured and its
    `UID` deleted. No orphaned objects remain after draining.

**P4 — Lifecycle events:**
    Each `FeeMessage<C>` produces two module-local events:
    `FeeMessageSent<C>` at posting (emitted in `post` after the
    transfer) and `FeeMessageCollected<C>` at consumption
    (emitted in `consume_message` after `object::delete`). Both
    carry the shared identity tuple `(fee_message_id, fee_inbox_id,
    escrow_id, amount)`; `fee_message_id` is the primary key pairing
    the two. Address data is non-redundant across the pair: `tenant`
    appears on Sent only (first-observed at post time, supplied by
    `rental_escrow`); `collector` appears on Collected only
    (first-observed at consume time, captured as
    `tx_context::sender(ctx)`). Indexers recover the full
    per-fee-message history — *"who funded, who drained"* — with a
    single Sent↔Collected JOIN on `fee_message_id`.

**P5 — Coin accumulation:**
    All balances from one `collect_fee_messages<C>` call are
    joined into a single `Coin<C>` via a `Balance<C>` accumulator.
    The caller receives one coin regardless of how many messages were drained.
    No intermediate coins are created.

**P6 — No contention at boundary events:**
    `post` uses transfer-to-object: `ProtocolFeeInbox` is not mutated
    when a boundary event fires. The drain is a separate admin
    operation on an owned object — fastpath, no consensus, no
    contention with active escrows.


6. TEST CASES
-------------

### 6.1 `post`

| # | Description | Expected |
|---|---|---|
| S1 | `post<C>(balance, escrow_id, tenant, fee_inbox_id, ctx)` with `balance > 0` | A `FeeMessage<C>` exists as a child of `fee_inbox_id` with matching `fee_inbox_id`, `escrow_id`, and `balance::value` equal to the input. `tenant` is not a struct field. One `FeeMessageSent<C>` event emitted with the `tenant` argument on the event's `tenant` field. |
| S2 | `post<C>` with `balance == 0` | `FeeMessage<C>` created and transferred to `fee_inbox_id` with `balance::value == 0`. No abort. (Not the recommended caller pattern — callers normally `balance::destroy_zero` instead — but structurally valid.) Event emitted with `amount == 0`. |
| S3 | `post` called twice with the same `fee_inbox_id`, possibly distinct `tenant`s | Two distinct `FeeMessage<C>` objects exist as children of `fee_inbox_id`. Two `FeeMessageSent<C>` events with distinct `fee_message_id` and their respective `tenant` values. |
| S4 | `post` in `<SUI>` and `<USDC>` with the same `fee_inbox_id` | Two objects of distinct types exist as children. No conflict. |
| S5 | `tenant` argument distinct from `tx_context::sender(ctx)` | Event `tenant` equals the argument — asserts the field is declarative, not a runtime echo of sender. Matches the `do_handover` case where the tx sender is permissionless, not the fee-funding tenant. |

### 6.2 `receive_message` and `consume_message`

Private functions — tested directly from `#[test]` functions within the module.

| # | Description | Expected |
|---|---|---|
| R1 | `receive_message` on a valid ticket | Returns `FeeMessage<C>` with correct `balance`. Object no longer owned by inbox. |
| C1 | `consume_message(msg, ctx)` on a received `FeeMessage` | Returns `Balance<C>` equal to original fee. Object's `UID` deleted. `collector` captured as `tx_context::sender(ctx)`. |

### 6.3 `collect_fee_messages`

| # | Description | Expected |
|---|---|---|
| D1 | Empty vector | Returns `Coin<C>` with value 0. No state change. |
| D2 | One ticket with balance `B` | Returns `Coin<C>` with value `B`. Object deleted. |
| D3 | N tickets with balances `B1..BN` | Returns `Coin<C>` with value `B1+..+BN`. All N objects deleted. |
| D4 | `<SUI>` and `<USDC>` in same PTB (two calls) | Each call returns `Coin` of its type. All objects deleted. One `&mut ProtocolFeeInbox` shared across both calls. |

### 6.4 Balance invariant

| # | Description | Expected |
|---|---|---|
| I1 | Total drained equals total sent | For all non-zero posts, `sum(coin values drained) == sum(balances posted via post)`. |

### 6.5 Events

| # | Description | Expected |
|---|---|---|
| E1 | `post<C>(balance, escrow_id, tenant, fee_inbox_id, ctx)` with any balance | Exactly one `FeeMessageSent<C>` emitted with `fee_message_id` equal to the created object's ID, `fee_inbox_id` and `escrow_id` equal to the arguments, `amount` equal to `balance::value(&balance)`, and event `tenant` equal to the `tenant` argument. |
| E2 | Caller handles zero balance out-of-module (`balance::destroy_zero` without calling `post`) | No `FeeMessageSent<C>` event emitted. (This module is not involved.) |
| E3 | `consume_message<C>(msg, ctx)` on a received message with balance `B` | Exactly one `FeeMessageCollected<C>` emitted with `fee_message_id`, `fee_inbox_id`, and `escrow_id` equal to the values carried by the consumed object, `amount == B`, and `collector == tx_context::sender(ctx)`. Emission occurs after `object::delete`. |
| E4 | `collect_fee_messages<C>` over N tickets with balances `B1..BN` | Exactly N `FeeMessageCollected<C>` events emitted in the tx, one per consumed message. Each event's `fee_inbox_id` and `escrow_id` match the consumed object; each event's `collector` equals the single `tx_context::sender(ctx)` of the drain tx. `sum(amounts in events) == B1+..+BN`. `FeeMessageSent<C>` events of the prior posts are not re-emitted. |
| E5 | `collect_fee_messages<C>` over an empty vector | No `FeeMessageCollected<C>` events emitted. |
| E6 | Sent↔Collected JOIN on `fee_message_id` | For any `FeeMessage<C>` whose `FeeMessageSent<C>` was observed at post time, its `FeeMessageCollected<C>` at drain shares identical `fee_message_id`, `fee_inbox_id`, `escrow_id`, and `amount`. Address fields do not overlap: `tenant` on Sent, `collector` on Collected — joining by `fee_message_id` recovers both without duplication. |
| E7 | Emit-last ordering | In a single tx where `post` produces a `FeeMessageSent<C>`, the event's `fee_message_id` matches an object that is owned by `fee_inbox_id` at end-of-tx. In a single tx where `consume_message` produces a `FeeMessageCollected<C>`, the referenced object no longer exists at end-of-tx. |


7. MODULE BOUNDARY
------------------

`fee_message.move` exports:

| Symbol | Visibility | Notes |
|--------|------------|-------|
| `FeeMessage<C>` (type) | `public` | `key` only. Per-boundary-event fee message. No separable public constructor. |
| `FeeMessageSent<C>` (event) | `public` | Emitted in `post`, after transfer. |
| `FeeMessageCollected<C>` (event) | `public` | Emitted in `consume_message`, after `object::delete`. |
| `post<C>(balance, escrow_id, tenant, fee_inbox_id, ctx)` | `public(package)` | Sole public entry point. Constructs a `FeeMessage<C>` inline, transfers it to `fee_inbox_id` via transfer-to-object, and emits `FeeMessageSent<C> { ..., tenant }`. Makes no assumption about the wrapped balance. Called by `do_handover` and `do_tenure_expiry` in `rental_escrow` — `tenant` is `displaced_tenant` at handover or the outgoing tenant's address at tenure expiry. |
| `receive_message<C>(inbox, ticket)` | private | Receives one `FeeMessage<C>` from inbox via `transfer::receive`. |
| `consume_message<C>(msg, ctx)` | private | Destructures `FeeMessage<C>`, deletes UID, captures `collector = tx_context::sender(ctx)`, emits `FeeMessageCollected<C> { ..., collector }`, returns `Balance<C>`. |
| `collect_fee_messages<C>(inbox, tickets, ctx)` | `public` | Pipeline of receive + consume over all tickets. Returns `Coin<C>`. Emits one `FeeMessageCollected<C>` per consumed message (via `consume_message`); no aggregate event. Called by admin PTB. |

No error constants.

**Depends on:** `protocol_fee_inbox` (`uid_mut` for `transfer::receive`,
type import), `sui::object` (`new`, `uid_to_inner`, `delete`),
`sui::event` (`emit`).
