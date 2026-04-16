FEE MESSAGE MODULE — SPECIFICATION
====================================

Module: `fee_message`
Design reference: design-compact.md §3 (fund flows — protocol fee)
Module map reference: module-map.spec.md §9
Depends on: `protocol_fee_inbox`


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
    id:      UID,
    balance: Balance<CoinType>,
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
| `balance` | `Balance<CoinType>` | Protocol fee amount. Always > 0 — zero-balance objects are never created. |

**Invariant:** `balance::value(&self.balance) > 0` for any live `FeeMessage`.
Zero-balance instances are never created — `send_fee` destroys zero balances
directly without constructing an object.


3. FUNCTIONS
------------

### `send_fee`

    public(package) fun send_fee<C>(
        balance:      Balance<C>,
        fee_inbox_id: ID,
        ctx:          &mut TxContext,
    )

**Visibility:** `public(package)` — callable only by `rental_escrow`.

**Purpose:** routes the protocol fee balance from a boundary event to
`ProtocolFeeInbox` via transfer-to-object.

**Behavior:**
- If `balance::value(&balance) == 0`:
  calls `balance::destroy_zero(balance)`. No object created. Returns.
- If `balance::value(&balance) > 0`:
  creates `FeeMessage<C>` with the balance,
  then calls `transfer::transfer(msg, fee_inbox_id.to_address())`.

**Call sites:** called by `do_handover` and `do_tenure_expiry` inside
`rental_escrow` — once per boundary event where a fee split occurs.
Not called at `claim_asset`.

**Why `fee_inbox_id` not `&mut ProtocolFeeInbox`:** `ProtocolFeeInbox` is
an owned object. In Sui, owned objects can only be included in a transaction
by their owner. Boundary events are triggered by tenants, bots, or any
permissionless caller — none of whom own `ProtocolFeeInbox`. Passing the ID
(stored in the escrow at `integrate` time) is the only viable design.

**Transfer-to-object:** `transfer::transfer` to an object ID is a free
operation — it does not mutate `ProtocolFeeInbox`. No contention on the
inbox at boundary event time.

**No events emitted.** The boundary events (`HandoverCompleted`,
`TenureExpired`) in `rental_escrow` cover the fee splits at the
appropriate granularity.

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
1. Destructures: `FeeMessage { id, balance } = msg`
2. Calls `object::delete(id)`.
3. Returns `balance`.

**No `inbox` argument:** deletion requires only the object itself.
`&mut ProtocolFeeInbox` is not needed here — it was only required for
`transfer::receive` in `receive_message`.

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


4. PROPERTIES
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

**P4 — Traceability via events:**
    `FeeMessage` carries no traceability fields. Trazability is handled by
    `HandoverCompleted` and `TenureExpired` events in `rental_escrow`, which
    include `escrow_id` and `protocol_fee` at the moment the fee is created.
    Events are the audit log — the struct only carries what the code uses.

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


5. TEST CASES
-------------

### 5.1 `send_fee`

| # | Description | Expected |
|---|---|---|
| S1 | `send_fee<C>` with `balance > 0` | `FeeMessage<C>` created. Owned by `fee_inbox_id`. `balance::value == input`. |
| S2 | `send_fee<C>` with `balance == 0` | No object created. Zero balance destroyed cleanly. No abort. |
| S3 | `send_fee<C>` called twice with same `fee_inbox_id` | Two distinct `FeeMessage<C>` objects exist as children of `fee_inbox_id`. |
| S4 | `send_fee<SUI>` and `send_fee<USDC>` with same `fee_inbox_id` | Two objects of distinct types exist as children. No conflict. |

### 5.2 `receive_message` and `consume_message`

Private functions — tested directly from `#[test]` functions within the module.

| # | Description | Expected |
|---|---|---|
| R1 | `receive_message` on a valid ticket | Returns `FeeMessage<C>` with correct `balance` and `escrow_id`. Object no longer owned by inbox. |
| C1 | `consume_message` on a received `FeeMessage` | Returns `Balance<C>` equal to original fee. Object's `UID` deleted. |

### 5.3 `collect_fee_messages`

| # | Description | Expected |
|---|---|---|
| D1 | Empty vector | Returns `Coin<C>` with value 0. No state change. |
| D2 | One ticket with balance `B` | Returns `Coin<C>` with value `B`. Object deleted. |
| D3 | N tickets with balances `B1..BN` | Returns `Coin<C>` with value `B1+..+BN`. All N objects deleted. |
| D4 | `<SUI>` and `<USDC>` in same PTB (two calls) | Each call returns `Coin` of its type. All objects deleted. One `&mut ProtocolFeeInbox` shared across both calls. |

### 5.4 Balance invariant

| # | Description | Expected |
|---|---|---|
| I1 | Total drained equals total sent | For all non-zero `send_fee` calls, `sum(coin values drained) == sum(balances sent)`. |


6. MODULE BOUNDARY
------------------

`fee_message.move` exports:

| Symbol | Visibility | Notes |
|--------|------------|-------|
| `FeeMessage<C>` (type) | `public` | `key` only. Per-boundary-event fee message. |
| `send_fee<C>(balance, fee_inbox_id, ctx)` | `public(package)` | Creates and transfers to `ProtocolFeeInbox` inbox. Called by `do_handover` and `do_tenure_expiry` in `rental_escrow`. |
| `receive_message<C>(inbox, ticket)` | private | Receives one `FeeMessage<C>` from inbox via `transfer::receive`. |
| `consume_message<C>(msg)` | private | Destructures `FeeMessage<C>`, deletes UID, returns `Balance<C>`. |
| `collect_fee_messages<C>(inbox, tickets, ctx)` | `public` | Pipeline of receive + consume over all tickets. Returns `Coin<C>`. Called by admin PTB. |

No error constants.

**Depends on:** `protocol_fee_inbox` (`uid_mut` for `transfer::receive`, type import).
