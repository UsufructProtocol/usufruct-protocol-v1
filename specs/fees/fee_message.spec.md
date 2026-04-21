FEE MESSAGE MODULE — SPECIFICATION
====================================

Module: `fee_message`
Design reference: design-compact.md §3 (fund flows — protocol fee)
Module map reference: module-map.spec.md §9
Depends on: `protocol_fee_inbox`, `sui::event`, `sui::object`


0. MODULE RESPONSIBILITY
------------------------

`fee_message` owns the `FeeMessage<C>` type and all fund-routing logic
for protocol fees at each boundary event.

**Owns:**
- `FeeMessage<phantom C>` — `key` only. Created at every boundary event
  (handover, tenure expiry) when a fee split occurs. Transferred to
  `ProtocolFeeInbox` via transfer-to-object. Deleted at drain time.
- `send_fee<C>(...)` — `public(package)`. Creates and transfers a
  `FeeMessage<C>` to `ProtocolFeeInbox` via transfer-to-object. Called
  by `do_handover` and `do_tenure_expiry` inside `rental_escrow`.
- `receive_message<C>(...)` — private. Receives one `FeeMessage<C>` from
  the inbox via `transfer::receive`. Single-object step.
- `consume_message<C>(...)` — private. Destructures a `FeeMessage<C>`,
  deletes its `UID`, and returns its `Balance<C>`.
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
- Zero balances are destroyed in `send_fee` without creating an object.
- One `collect_fee_messages<C>` call handles one CoinType.
  Multiple calls for different types may be chained in a single PTB,
  all sharing one `&mut ProtocolFeeInbox` — fastpath, no consensus.
- The accumulator is `Balance<C>`, not `Coin<C>` — `ctx` is only used
  once at the end to wrap the total. No intermediate coins created.


1. ERROR CONSTANTS
------------------

None. Neither `send_fee` nor `collect_fee_messages` have
validatable preconditions that require named abort codes. `send_fee`
handles zero balance as a no-op branch, not an error.
`collect_fee_messages` accepts an empty vector as a valid no-op.


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
| `balance` | `Balance<CoinType>` | Protocol fee amount. Always > 0 — zero-balance objects are never created. |

**Invariants:**
- `balance::value(&self.balance) > 0` for any live `FeeMessage`.
  Zero-balance instances are never created — `send_fee` destroys zero
  balances directly without constructing an object.
- `self.fee_inbox_id` equals the transfer-to-object parent of `self` (the
  inbox to which `send_fee` transferred it).
- `self.escrow_id` equals the ID of the escrow that called `send_fee`.


3. EVENTS
---------

The module records the lifecycle of each `FeeMessage<C>`: one event at
posting to the inbox, one event at consumption. Both events are
symmetric — they carry the same identity tuple so each can be read
standalone without joining against the other.

### FeeMessageSent — event

```move
public struct FeeMessageSent<phantom CoinType> has copy, drop {
    fee_message_id: ID,
    fee_inbox_id:   ID,
    escrow_id:      ID,
    amount:         u64,
}
```

**Fields:**

| Field | Type | Meaning |
|---|---|---|
| `fee_message_id` | `ID` | Identity of the newly created `FeeMessage<CoinType>`. |
| `fee_inbox_id` | `ID` | The `ProtocolFeeInbox` that received the message. |
| `escrow_id` | `ID` | The originating escrow whose boundary event produced this fee. |
| `amount` | `u64` | `balance::value(&balance)` at creation. Always > 0 — the zero-balance branch does not emit. |

**Emission site:** `send_fee<C>`, only in the `balance > 0` branch,
after `transfer::transfer(msg, fee_inbox_id.to_address())`. Exactly one
emission per created message.

**Zero-balance branch does not emit:** when `balance::value(&balance) == 0`,
`send_fee` calls `balance::destroy_zero` and returns without constructing
any object. There is no lifecycle to record.

### FeeMessageCollected — event

```move
public struct FeeMessageCollected<phantom CoinType> has copy, drop {
    fee_message_id: ID,
    fee_inbox_id:   ID,
    escrow_id:      ID,
    amount:         u64,
}
```

**Fields:**

| Field | Type | Meaning |
|---|---|---|
| `fee_message_id` | `ID` | Identity of the `FeeMessage<CoinType>` that was consumed. |
| `fee_inbox_id` | `ID` | The `ProtocolFeeInbox` the message was drained from. Copied from the consumed object's `fee_inbox_id` field. |
| `escrow_id` | `ID` | The originating escrow. Copied from the consumed object's `escrow_id` field. |
| `amount` | `u64` | `balance::value(&balance)` at the moment of consumption. |

**Emission site:** `consume_message<C>`, after `object::delete(id)`.
Exactly one emission per consumed message. Because
`collect_fee_messages<C>` invokes `consume_message` in a loop, a drain
of N messages produces N `FeeMessageCollected<C>` events in the same
transaction.

**Symmetry with `FeeMessageSent`:** the two events carry the same
identity tuple (`fee_message_id`, `fee_inbox_id`, `escrow_id`, `amount`).
Off-chain indexers can group by `escrow_id` (per-asset fee history), by
`fee_inbox_id` (global drain reconciliation), or join Sent↔Collected by
`fee_message_id` — each event is self-describing and can be queried
without cross-event joins.

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
time to report: `send_fee` may be reached from a lazy-settlement path
whose logical moment is in the past, so neither the tx envelope
timestamp nor `clock.now()` corresponds to the logical moment the event
belongs to. The module emits identity and amount only.

### Emit-last convention

At both emission sites, `event::emit` runs *after* the state-changing
operation that the event describes (transfer in `send_fee`,
`object::delete` in `consume_message`). Values needed in the event body
are bound to locals before the consuming call so they remain available
at emit time.


4. FUNCTIONS
------------

### `send_fee`

    public(package) fun send_fee<C>(
        balance:      Balance<C>,
        fee_inbox_id: ID,
        escrow_id:    ID,
        ctx:          &mut TxContext,
    )

**Visibility:** `public(package)` — callable only by `rental_escrow`.

**Purpose:** routes the protocol fee balance from a boundary event to
`ProtocolFeeInbox` via transfer-to-object.

**Behavior:**
- If `balance::value(&balance) == 0`:
  calls `balance::destroy_zero(balance)`. No object created, no event
  emitted. Returns. The `fee_inbox_id` and `escrow_id` arguments are
  ignored in this branch.
- If `balance::value(&balance) > 0`:
  1. `let amount = balance::value(&balance);`
  2. Construct `msg: FeeMessage<C>` with
     `{ id: object::new(ctx), fee_inbox_id, escrow_id, balance }`.
  3. `let fee_message_id = object::uid_to_inner(&msg.id);` — captured
     before the transfer consumes `msg`.
  4. `transfer::transfer(msg, fee_inbox_id.to_address());`
  5. `event::emit(FeeMessageSent<C> { fee_message_id, fee_inbox_id, escrow_id, amount });`

**Sole creation site:** `send_fee` is the only function that constructs
a `FeeMessage`. No public or private constructor exists separately —
struct literal creation within `fee_message.move` is the mechanism, and
it is inaccessible to any external module.

**Call sites:** called by `do_handover` and `do_tenure_expiry` inside
`rental_escrow` — once per boundary event where a fee split occurs.
Not called at `claim_asset`. Callers supply `escrow_id` from the
escrow they are mutating.

**Why `fee_inbox_id` not `&mut ProtocolFeeInbox`:** `ProtocolFeeInbox` is
an owned object. In Sui, owned objects can only be included in a transaction
by their owner. Boundary events are triggered by tenants, bots, or any
permissionless caller — none of whom own `ProtocolFeeInbox`. Passing the ID
(stored in the escrow at `integrate` time) is the only viable design.

**Transfer-to-object:** `transfer::transfer` to an object ID is a free
operation — it does not mutate `ProtocolFeeInbox`. No contention on the
inbox at boundary event time.

**Events:** emits `FeeMessageSent<C>` once in the `balance > 0` branch,
after the transfer (emit-last). The zero-balance branch does not emit.
See §3.

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

    fun consume_message<C>(msg: FeeMessage<C>): Balance<C>

**Visibility:** private — called only by `collect_fee_messages`.

**Purpose:** destructs a `FeeMessage<C>`, deletes its object identity,
and returns its balance.

**Behavior:**
1. Destructure: `FeeMessage { id, fee_inbox_id, escrow_id, balance } = msg`.
2. Capture `let fee_message_id = object::uid_to_inner(&id);` and
   `let amount = balance::value(&balance);` — bound before
   `object::delete(id)` consumes the `UID`.
3. `object::delete(id);`
4. `event::emit(FeeMessageCollected<C> { fee_message_id, fee_inbox_id, escrow_id, amount });`
5. Returns `balance`.

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
   b. `balance::join(&mut total, consume_message(msg))`
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

**P1 — No zero-balance objects:**
    `send_fee` with `balance == 0` destroys the balance without creating
    an object. Every live `FeeMessage` has `balance > 0`.

**P2 — Receive restricted to this module:**
    `FeeMessage` has `key` only. `transfer::receive` is only callable
    from `fee_message.move`. No external module can drain the inbox.

**P3 — Objects deleted at drain:**
    Every `FeeMessage` passed to `consume_message` is destructured and its
    `UID` deleted. No orphaned objects remain after draining.

**P4 — Lifecycle events:**
    Each `FeeMessage<C>` produces two module-local events:
    `FeeMessageSent<C>` at posting (emitted in `send_fee`'s `balance > 0`
    branch after the transfer) and `FeeMessageCollected<C>` at
    consumption (emitted in `consume_message` after `object::delete`).
    Both carry the same identity tuple: `fee_message_id`, `fee_inbox_id`,
    `escrow_id`, and `amount`. Consumers can group by any of these
    dimensions — per-escrow fee history, per-inbox drain reconciliation,
    or Sent↔Collected pairing by `fee_message_id` — without joining
    against external state.

**P5 — Coin accumulation:**
    All balances from one `collect_fee_messages<C>` call are
    joined into a single `Coin<C>` via a `Balance<C>` accumulator.
    The caller receives one coin regardless of how many messages were drained.
    No intermediate coins are created.

**P6 — No contention at boundary events:**
    `send_fee` uses transfer-to-object: `ProtocolFeeInbox` is not mutated
    when a boundary event fires. The drain is a separate admin operation
    on an owned object — fastpath, no consensus, no contention with
    active escrows.


6. TEST CASES
-------------

### 6.1 `send_fee`

| # | Description | Expected |
|---|---|---|
| S1 | `send_fee<C>` with `balance > 0` | `FeeMessage<C>` created. Owned by `fee_inbox_id`. `balance::value == input`. |
| S2 | `send_fee<C>` with `balance == 0` | No object created. Zero balance destroyed cleanly. No abort. |
| S3 | `send_fee<C>` called twice with same `fee_inbox_id` | Two distinct `FeeMessage<C>` objects exist as children of `fee_inbox_id`. |
| S4 | `send_fee<SUI>` and `send_fee<USDC>` with same `fee_inbox_id` | Two objects of distinct types exist as children. No conflict. |

### 6.2 `receive_message` and `consume_message`

Private functions — tested directly from `#[test]` functions within the module.

| # | Description | Expected |
|---|---|---|
| R1 | `receive_message` on a valid ticket | Returns `FeeMessage<C>` with correct `balance`. Object no longer owned by inbox. |
| C1 | `consume_message` on a received `FeeMessage` | Returns `Balance<C>` equal to original fee. Object's `UID` deleted. |

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
| I1 | Total drained equals total sent | For all non-zero `send_fee` calls, `sum(coin values drained) == sum(balances sent)`. |

### 6.5 Events

| # | Description | Expected |
|---|---|---|
| E1 | `send_fee<C>` with `balance > 0` | Exactly one `FeeMessageSent<C>` emitted with `fee_message_id` equal to the created object's ID, `fee_inbox_id` and `escrow_id` equal to the arguments, and `amount` equal to `balance::value(&balance)`. |
| E2 | `send_fee<C>` with `balance == 0` | No event emitted. |
| E3 | `consume_message<C>` on a received message with balance `B` | Exactly one `FeeMessageCollected<C>` emitted with `fee_message_id`, `fee_inbox_id`, and `escrow_id` equal to the values carried by the consumed object, and `amount == B`. Emission occurs after `object::delete`. |
| E4 | `collect_fee_messages<C>` over N tickets with balances `B1..BN` | Exactly N `FeeMessageCollected<C>` events emitted in the tx, one per consumed message. Each event's `fee_inbox_id` and `escrow_id` match the consumed object. `sum(amounts in events) == B1+..+BN`. `FeeMessageSent<C>` events of the prior sends are not re-emitted. |
| E5 | `collect_fee_messages<C>` over an empty vector | No `FeeMessageCollected<C>` events emitted. |
| E6 | Sent↔Collected symmetry | For any `FeeMessage<C>` whose `FeeMessageSent<C>` was observed at send time, its `FeeMessageCollected<C>` at drain carries identical `fee_message_id`, `fee_inbox_id`, `escrow_id`, and `amount`. |
| E7 | Emit-last ordering | In a single tx where `send_fee` produces a `FeeMessageSent<C>`, the event's `fee_message_id` matches an object that is owned by `fee_inbox_id` at end-of-tx. In a single tx where `consume_message` produces a `FeeMessageCollected<C>`, the referenced object no longer exists at end-of-tx. |


7. MODULE BOUNDARY
------------------

`fee_message.move` exports:

| Symbol | Visibility | Notes |
|--------|------------|-------|
| `FeeMessage<C>` (type) | `public` | `key` only. Per-boundary-event fee message. |
| `FeeMessageSent<C>` (event) | `public` | Emitted in `send_fee`, `balance > 0` branch, after transfer. |
| `FeeMessageCollected<C>` (event) | `public` | Emitted in `consume_message`, after `object::delete`. |
| `send_fee<C>(balance, fee_inbox_id, escrow_id, ctx)` | `public(package)` | Creates and transfers to `ProtocolFeeInbox`; emits `FeeMessageSent<C>` when `balance > 0`. Called by `do_handover` and `do_tenure_expiry` in `rental_escrow`. |
| `receive_message<C>(inbox, ticket)` | private | Receives one `FeeMessage<C>` from inbox via `transfer::receive`. |
| `consume_message<C>(msg)` | private | Destructures `FeeMessage<C>`, deletes UID, emits `FeeMessageCollected<C>`, returns `Balance<C>`. |
| `collect_fee_messages<C>(inbox, tickets, ctx)` | `public` | Pipeline of receive + consume over all tickets. Returns `Coin<C>`. Emits one `FeeMessageCollected<C>` per consumed message (via `consume_message`); no aggregate event. Called by admin PTB. |

No error constants.

**Depends on:** `protocol_fee_inbox` (`uid_mut` for `transfer::receive`,
type import), `sui::object` (`new`, `uid_to_inner`, `delete`),
`sui::event` (`emit`).
