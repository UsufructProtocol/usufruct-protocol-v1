PROTOCOL LOCAL TREASURY MODULE — SPECIFICATION
===============================================

Module: `protocol_local_treasury`
Design reference: design-compact.md §3 (fund flows — protocol fee)
Module map reference: module-map.spec.md §9
Depends on: `protocol_admin_cap`


0. MODULE RESPONSIBILITY
------------------------

`protocol_local_treasury` owns the `ProtocolLocalTreasury<C>` type and all
fund-routing logic for protocol fees at escrow retirement.

**Owns:**
- `ProtocolLocalTreasury<phantom C>` — `key` only. Created once per `claim_asset`
  call when protocol fees are non-zero. Transferred to `ProtocolAdminCap`
  via transfer-to-object. Deleted at drain time.
- `route_fee<C>(...)` — `public(package)`. Creates and routes a `ProtocolLocalTreasury`
  to `ProtocolAdminCap` via transfer-to-object. Called only by `rental_escrow::claim_asset`.
- `drain_local_treasuries<C>(...)` — `public`. Receives and drains all
  `ProtocolLocalTreasury<C>` objects from the inbox in one call. Called by admin.

**Does not own:**
- Cap validation logic — accepts `&mut ProtocolAdminCap` as proof and inbox;
  `protocol_admin_cap` owns the type.

**Key design properties:**
- `ProtocolLocalTreasury` is `key` only. `transfer::receive` is restricted to this
  module — no external code can receive these objects from the inbox.
- Zero balances are destroyed in `route_fee` without creating an object.
- One `drain_local_treasuries<C>` call handles one CoinType. Multiple calls
  for different types may be chained in a single PTB, all sharing one
  `&mut ProtocolAdminCap` — a single owned object mutation, fastpath, no consensus.


1. ERROR CONSTANTS
------------------

None. Neither `route_fee` nor `drain_local_treasuries` have validatable preconditions
that require named abort codes. `route_fee` handles zero balance as a no-op branch,
not an error. `drain_local_treasuries` accepts an empty vector as a valid no-op.


2. TYPE
-------

### ProtocolLocalTreasury — struct

Per-retirement fee payload. Wraps the protocol fee balance from one escrow
retirement. Transferred to `ProtocolAdminCap` as a child object via
transfer-to-object. Deleted at drain time.

```move
public struct ProtocolLocalTreasury<phantom CoinType> has key {
    id:        UID,
    balance:   Balance<CoinType>,
    escrow_id: ID,
    asset_id:  ID,
}
```

**Abilities:** `key` only.
- `key` — object identity. Required for transfer-to-object and `transfer::receive`.
- No `store` — `transfer::receive` is restricted to `protocol_local_treasury.move`.
  No external module can receive or move these objects.

**Fields:**

| Field | Type | Meaning |
|---|---|---|
| `id` | `UID` | Object identity. |
| `balance` | `Balance<CoinType>` | Protocol fee amount. Always > 0 — zero-balance objects are never created. |
| `escrow_id` | `ID` | ID of the `RentalEscrow` that generated this fee. For off-chain traceability. |
| `asset_id` | `ID` | ID of the integrated asset. For off-chain traceability. |

**Invariant:** `balance::value(&self.balance) > 0` for any live `ProtocolLocalTreasury`.
Zero-balance instances are never created — `route_fee` destroys zero balances directly
without constructing an object.


3. FUNCTIONS
------------

### `route_fee`

    public(package) fun route_fee<C>(
        balance:      Balance<C>,
        fee_inbox_id: ID,
        escrow_id:    ID,
        asset_id:     ID,
        ctx:          &mut TxContext,
    )

**Visibility:** `public(package)` — callable only by `rental_escrow`.

**Purpose:** routes the protocol fee balance from a retiring escrow to
`ProtocolAdminCap` via transfer-to-object.

**Behavior:**
- If `balance::value(&balance) == 0`:
  calls `balance::destroy_zero(balance)`. No object created. Returns.
- If `balance::value(&balance) > 0`:
  creates `ProtocolLocalTreasury<C>` with the balance, `escrow_id`, and `asset_id`,
  then calls `transfer::transfer(local, fee_inbox_id.to_address())`.

**Why `fee_inbox_id` not `&mut ProtocolAdminCap`:** `claim_asset` already has
`fee_inbox_id` stored in the escrow (registered at `integrate` time via
`ProtocolFeeRef`). Passing the ID directly avoids requiring `ProtocolAdminCap`
as an extra argument to `claim_asset`, keeping its public signature clean.
`ProtocolAdminCap` does not need to be in the `claim_asset` transaction at all.

**Transfer-to-object:** `transfer::transfer` to an object ID is a free operation —
it does not mutate `ProtocolAdminCap`. No contention on the inbox at retirement time.

**No events emitted.** The `AssetRetired` event in `rental_escrow` covers
the retirement; per-fee events would be redundant at this granularity.

---

### `drain_local_treasuries`

    public fun drain_local_treasuries<C>(
        cap:    &mut ProtocolAdminCap,
        locals: vector<Receiving<ProtocolLocalTreasury<C>>>,
        ctx:    &mut TxContext,
    ): Coin<C>

**Visibility:** `public` — callable by the admin from a PTB.

**Purpose:** receives all `ProtocolLocalTreasury<C>` objects from the inbox for
one CoinType, accumulates their balances, deletes the objects, and returns a
single `Coin<C>` to the caller.

**Behavior:**
1. Initializes `total: Balance<C> = balance::zero()`.
2. For each `receiving` in `locals`:
   a. `let local = transfer::receive(protocol_admin_cap::uid_mut(cap), receiving)`
   b. Destructure: `ProtocolLocalTreasury { id, balance, .. } = local`
   c. `object::delete(id)`
   d. `balance::join(&mut total, balance)`
3. Returns `coin::from_balance(total, ctx)`.

**Empty vector:** if `locals` is empty, returns a zero-value `Coin<C>`. Valid no-op.

**Authorization — dual enforcement:**
- **Structural (compiler):** `ProtocolLocalTreasury` is `key` only →
  `transfer::receive` compiles only inside `protocol_local_treasury.move`.
  No external module can execute step 2a, regardless of the arguments it passes.
- **Capability (runtime):** `cap: &mut ProtocolAdminCap` forces the PTB to include
  the owned `ProtocolAdminCap`. Only the holder can present it as mutable.
  `&mut` simultaneously gates access and provides `uid_mut` for the receive.

**Fastpath:** `drain_local_treasuries` touches only owned objects — `ProtocolAdminCap`
and the `Receiving` tickets. No shared objects in the transaction. Sui routes this
through the owned-object fastpath — no consensus overhead.

**One call per CoinType:** `Receiving<ProtocolLocalTreasury<C>>` is typed over `C`.
The admin's off-chain indexer queries `suix_getOwnedObjects` for
`ProtocolLocalTreasury<C>` children of `ProtocolAdminCap`, groups them by
`CoinType`, and builds one `vector<Receiving<...>>` per type.
Multiple calls may be chained in a single PTB — each handles one `CoinType`
and shares the same `&mut ProtocolAdminCap`.


4. PROPERTIES
-------------

**P1 — No zero-balance objects:**
    `route_fee` with `balance == 0` destroys the balance without creating an object.
    Every live `ProtocolLocalTreasury` has `balance > 0`.

**P2 — Receive restricted to this module:**
    `ProtocolLocalTreasury` has `key` only. `transfer::receive` is only callable
    from `protocol_local_treasury.move`. No external module can drain the inbox.

**P3 — Objects deleted at drain:**
    Every `ProtocolLocalTreasury` received in `drain_local_treasuries` is
    destructured and its `UID` deleted. No orphaned objects remain after draining.

**P4 — Traceability:**
    `escrow_id` and `asset_id` fields allow off-chain attribution of each fee
    amount to its source escrow and asset.

**P5 — Coin accumulation:**
    All balances from one `drain_local_treasuries<C>` call are joined into a
    single `Coin<C>`. The caller receives one coin regardless of how many
    locals were drained.

**P6 — No contention at retirement:**
    `route_fee` uses transfer-to-object: `ProtocolAdminCap` is not mutated
    at `claim_asset` time. The drain is a separate admin operation on an owned
    object — fastpath, no consensus, no contention with active escrows.


5. TEST CASES
-------------

### 5.1 `route_fee`

| # | Description | Expected |
|---|---|---|
| F1 | `route_fee<C>` with `balance > 0` | `ProtocolLocalTreasury<C>` created. Owned by `global_id`. `balance::value == input`. `escrow_id` and `asset_id` match inputs. |
| F2 | `route_fee<C>` with `balance == 0` | No object created. Zero balance destroyed cleanly. No abort. |
| F3 | `route_fee<C>` called twice with same `global_id` | Two distinct `ProtocolLocalTreasury<C>` objects exist as children of `global_id`. |
| F4 | `route_fee<SUI>` and `route_fee<USDC>` with same `global_id` | Two objects of distinct types exist as children. No conflict. |

### 5.2 `drain_local_treasuries`

| # | Description | Expected |
|---|---|---|
| D1 | Drain empty vector | Returns `Coin<C>` with value 0. No state change. |
| D2 | Drain one local with balance `B` | Returns `Coin<C>` with value `B`. Object deleted. |
| D3 | Drain N locals with balances `B1..BN` | Returns `Coin<C>` with value `B1+..+BN`. All N objects deleted. |
| D4 | Drain `<SUI>` and `<USDC>` in same PTB (two calls) | Each call returns `Coin` of its type. All objects deleted. One `&mut ProtocolAdminCap` shared across both calls. |

### 5.3 Balance invariant

| # | Description | Expected |
|---|---|---|
| I1 | Total drained equals total routed | For all non-zero `route_fee` calls, `sum(coin values drained) == sum(balances routed)`. |


6. MODULE BOUNDARY
------------------

`protocol_local_treasury.move` exports:

| Symbol | Visibility | Notes |
|--------|------------|-------|
| `ProtocolLocalTreasury<C>` (type) | `public` | `key` only. Per-retirement fee payload. |
| `route_fee<C>(balance, fee_inbox_id, escrow_id, asset_id, ctx)` | `public(package)` | Creates and routes to `ProtocolAdminCap` inbox. Called by `rental_escrow`. |
| `drain_local_treasuries<C>(cap, locals, ctx)` | `public` | Drains inbox for one CoinType. Returns `Coin<C>`. Called by admin PTB. |

No error constants.

**Depends on:** `protocol_admin_cap` (`uid_mut` for `transfer::receive`, type import).
