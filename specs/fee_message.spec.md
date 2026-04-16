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
- `drain_fee_messages<C>(...)` — `public`. Receives and drains all
  `FeeMessage<C>` objects from the inbox in one call. Called by admin.

**Does not own:**
- Inbox type or uid_mut — those live in `protocol_fee_inbox`.

**Key design properties:**
- `FeeMessage` is `key` only. `transfer::receive` is restricted to this
  module — no external code can receive these objects from the inbox.
- Zero balances are destroyed in `send_fee` without creating an object.
- One `drain_fee_messages<C>` call handles one CoinType. Multiple calls
  for different types may be chained in a single PTB, all sharing one
  `&mut ProtocolFeeInbox` — a single owned object mutation, fastpath,
  no consensus.


1. ERROR CONSTANTS
------------------

None. Neither `send_fee` nor `drain_fee_messages` have validatable
preconditions that require named abort codes. `send_fee` handles zero
balance as a no-op branch, not an error. `drain_fee_messages` accepts
an empty vector as a valid no-op.


2. TYPE
-------

### FeeMessage — struct

Per-boundary-event fee message. Wraps the protocol fee balance from one
handover or tenure expiry. Transferred to `ProtocolFeeInbox` as a child
object via transfer-to-object immediately at the split. Deleted at drain time.

```move
public struct FeeMessage<phantom CoinType> has key {
    id:        UID,
    balance:   Balance<CoinType>,
    escrow_id: ID,
    asset_id:  ID,
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
| `escrow_id` | `ID` | ID of the `RentalEscrow` that generated this fee. For off-chain traceability. |
| `asset_id` | `ID` | ID of the integrated asset. For off-chain traceability. |

**Invariant:** `balance::value(&self.balance) > 0` for any live `FeeMessage`.
Zero-balance instances are never created — `send_fee` destroys zero balances
directly without constructing an object.


3. FUNCTIONS
------------

### `send_fee`

    public(package) fun send_fee<C>(
        balance:      Balance<C>,
        fee_inbox_id: ID,
        escrow_id:    ID,
        asset_id:     ID,
        ctx:          &mut TxContext,
    )

**Visibility:** `public(package)` — callable only by `rental_escrow`.

**Purpose:** routes the protocol fee balance from a boundary event to
`ProtocolFeeInbox` via transfer-to-object.

**Behavior:**
- If `balance::value(&balance) == 0`:
  calls `balance::destroy_zero(balance)`. No object created. Returns.
- If `balance::value(&balance) > 0`:
  creates `FeeMessage<C>` with the balance, `escrow_id`, and `asset_id`,
  then calls `transfer::transfer(msg, fee_inbox_id.to_address())`.

**Call sites:** called by `do_handover` and `do_tenure_expiry` inside
`rental_escrow` — once per boundary event where a fee split occurs.
Not called at `claim_asset`.

**Why `fee_inbox_id` not `&mut ProtocolFeeInbox`:** `do_handover` and
`do_tenure_expiry` already have `fee_inbox_id` available from the escrow
(registered at `integrate` time via `ProtocolFeeRef`). Passing the ID
directly avoids requiring `ProtocolFeeInbox` as an extra argument in
any transaction that triggers a boundary event. `ProtocolFeeInbox` does
not need to be in those transactions at all.

**Transfer-to-object:** `transfer::transfer` to an object ID is a free
operation — it does not mutate `ProtocolFeeInbox`. No contention on the
inbox at boundary event time.

**No events emitted.** The boundary events (`HandoverCompleted`,
`TenureExpired`) in `rental_escrow` cover the fee splits at the
appropriate granularity.

---

### `drain_fee_messages`

    public fun drain_fee_messages<C>(
        inbox:    &mut ProtocolFeeInbox,
        messages: vector<Receiving<FeeMessage<C>>>,
        ctx:      &mut TxContext,
    ): Coin<C>

**Visibility:** `public` — callable by the admin from a PTB.

**Purpose:** receives all `FeeMessage<C>` objects from the inbox for
one CoinType, accumulates their balances, deletes the objects, and
returns a single `Coin<C>` to the caller.

**Behavior:**
1. Initializes `total: Balance<C> = balance::zero()`.
2. For each `receiving` in `messages`:
   a. `let msg = transfer::receive(protocol_fee_inbox::uid_mut(inbox), receiving)`
   b. Destructure: `FeeMessage { id, balance, .. } = msg`
   c. `object::delete(id)`
   d. `balance::join(&mut total, balance)`
3. Returns `coin::from_balance(total, ctx)`.

**Empty vector:** if `messages` is empty, returns a zero-value `Coin<C>`.
Valid no-op.

**Authorization — dual enforcement:**
- **Structural (compiler):** `FeeMessage` is `key` only →
  `transfer::receive` compiles only inside `fee_message.move`.
  No external module can execute step 2a, regardless of the arguments
  it passes.
- **Ownership (runtime):** `inbox: &mut ProtocolFeeInbox` forces the PTB
  to include the owned `ProtocolFeeInbox`. Only the holder can present it
  as mutable. `&mut` simultaneously gates access and provides `uid_mut`
  for the receive.

**Fastpath:** `drain_fee_messages` touches only owned objects —
`ProtocolFeeInbox` and the `Receiving` tickets. No shared objects in the
transaction. Sui routes this through the owned-object fastpath — no
consensus overhead.

**One call per CoinType:** `Receiving<FeeMessage<C>>` is typed over `C`.
The admin's off-chain indexer queries `suix_getOwnedObjects` for
`FeeMessage<C>` children of `ProtocolFeeInbox`, groups them by
`CoinType`, and builds one `vector<Receiving<...>>` per type.
Multiple calls may be chained in a single PTB — each handles one
`CoinType` and shares the same `&mut ProtocolFeeInbox`.


4. PROPERTIES
-------------

**P1 — No zero-balance objects:**
    `send_fee` with `balance == 0` destroys the balance without creating
    an object. Every live `FeeMessage` has `balance > 0`.

**P2 — Receive restricted to this module:**
    `FeeMessage` has `key` only. `transfer::receive` is only callable
    from `fee_message.move`. No external module can drain the inbox.

**P3 — Objects deleted at drain:**
    Every `FeeMessage` received in `drain_fee_messages` is destructured
    and its `UID` deleted. No orphaned objects remain after draining.

**P4 — Traceability:**
    `escrow_id` and `asset_id` fields allow off-chain attribution of each
    fee amount to its source escrow and asset.

**P5 — Coin accumulation:**
    All balances from one `drain_fee_messages<C>` call are joined into a
    single `Coin<C>`. The caller receives one coin regardless of how many
    messages were drained.

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
| S1 | `send_fee<C>` with `balance > 0` | `FeeMessage<C>` created. Owned by `fee_inbox_id`. `balance::value == input`. `escrow_id` and `asset_id` match inputs. |
| S2 | `send_fee<C>` with `balance == 0` | No object created. Zero balance destroyed cleanly. No abort. |
| S3 | `send_fee<C>` called twice with same `fee_inbox_id` | Two distinct `FeeMessage<C>` objects exist as children of `fee_inbox_id`. |
| S4 | `send_fee<SUI>` and `send_fee<USDC>` with same `fee_inbox_id` | Two objects of distinct types exist as children. No conflict. |

### 5.2 `drain_fee_messages`

| # | Description | Expected |
|---|---|---|
| D1 | Drain empty vector | Returns `Coin<C>` with value 0. No state change. |
| D2 | Drain one message with balance `B` | Returns `Coin<C>` with value `B`. Object deleted. |
| D3 | Drain N messages with balances `B1..BN` | Returns `Coin<C>` with value `B1+..+BN`. All N objects deleted. |
| D4 | Drain `<SUI>` and `<USDC>` in same PTB (two calls) | Each call returns `Coin` of its type. All objects deleted. One `&mut ProtocolFeeInbox` shared across both calls. |

### 5.3 Balance invariant

| # | Description | Expected |
|---|---|---|
| I1 | Total drained equals total sent | For all non-zero `send_fee` calls, `sum(coin values drained) == sum(balances sent)`. |


6. MODULE BOUNDARY
------------------

`fee_message.move` exports:

| Symbol | Visibility | Notes |
|--------|------------|-------|
| `FeeMessage<C>` (type) | `public` | `key` only. Per-boundary-event fee message. |
| `send_fee<C>(balance, fee_inbox_id, escrow_id, asset_id, ctx)` | `public(package)` | Creates and transfers to `ProtocolFeeInbox` inbox. Called by `do_handover` and `do_tenure_expiry` in `rental_escrow`. |
| `drain_fee_messages<C>(inbox, messages, ctx)` | `public` | Drains inbox for one CoinType. Returns `Coin<C>`. Called by admin PTB. |

No error constants.

**Depends on:** `protocol_fee_inbox` (`uid_mut` for `transfer::receive`, type import).
