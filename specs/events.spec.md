EVENTS MODULE — SPECIFICATION
==============================

Module: `events`
Design reference: design-compact.md §1 (state machine), §3 (fund flows)
Module map reference: module-map.spec.md §7
Depends on: nothing (`sui::event` only)


0. MODULE RESPONSIBILITY
------------------------

`events` owns all protocol event struct definitions and their
package-scoped emit helpers. No logic, no state, no objects.
Pure data carriers.

**Owns:**
- One event struct per protocol boundary event (11 total).
- One `emit_*` function per event (`public(package)`).

**Does not own:**
- Any decision about when to emit — that logic lives exclusively in
  `rental_escrow`. `events` only defines what and how.
- Any state or object types.

**Key design properties:**
- All event structs have `copy, drop` abilities — required by
  `sui::event::emit`.
- All `emit_*` functions are `public(package)` — only `rental_escrow`
  can fire them. This enforces that events are only emitted at the
  correct call sites and prevents external modules from injecting
  spurious events.
- Centralizing emission in `events.move` makes struct definitions
  discoverable and testable in isolation from `rental_escrow`.
- Events are the audit log for fund flows. `HandoverCompleted` and
  `TenureExpired` include `owner_earned` and `protocol_fee` fields —
  the sole traceability mechanism for fee splits (no fields on
  `FeeMessage` for this purpose).

**Open question — `RentalStarted` vs `DutchAuctionEntry`:**
The module-map lists both as emitted at `rent (AtDutchAuction)`.
Emitting both for the same call is redundant — they carry equivalent
information (`tenant_cap_id`, price). Proposed resolution: emit
`RentalStarted` only from Idle, `DutchAuctionEntry` only from
AtDutchAuction. To iterate.


1. ERROR CONSTANTS
------------------

None. Emit helpers have no validatable preconditions.


2. TYPES
--------

All event structs have abilities `copy, drop`.

---

### `AssetIntegrated`

Emitted by `integrate`. Marks the birth of a `RentalEscrow` instance.
Primary discovery mechanism: off-chain consumers index this event to
track all escrow instances by `escrow_id`.

```move
public struct AssetIntegrated has copy, drop {
    escrow_id:      ID,
    owner_cap_id:   ID,
    min_rent_price: u64,
    tenure_ceiling: u64,
}
```

| Field | Meaning |
|---|---|
| `escrow_id` | ID of the newly created `RentalEscrow`. |
| `owner_cap_id` | ID of the `OwnerCap` minted and delivered to the integrator. |
| `min_rent_price` | Floor price. Entry barrier from Idle. |
| `tenure_ceiling` | Duration of each rental block in ms. |

---

### `RentalStarted`

Emitted by `rent` when the asset transitions from **Idle** to Rented.

```move
public struct RentalStarted has copy, drop {
    escrow_id:     ID,
    tenant_cap_id: ID,
    price:         u64,
}
```

| Field | Meaning |
|---|---|
| `escrow_id` | Target escrow. |
| `tenant_cap_id` | ID of the `TenantCap` minted and pushed to the new tenant. |
| `price` | `min_rent_price` paid. |

---

### `TakeoverInitiated`

Emitted by `rent` when the asset is in **Rented(HandoverOpen)** and a
new bid arrives, opening the handover countdown.

```move
public struct TakeoverInitiated has copy, drop {
    escrow_id:              ID,
    outgoing_cap_id:        ID,
    pending_tenant_address: address,
    new_price:              u64,
    handover_expiry:        u64,
}
```

| Field | Meaning |
|---|---|
| `escrow_id` | Target escrow. |
| `outgoing_cap_id` | ID of the current tenant's `TenantCap` — will become stale at handover. |
| `pending_tenant_address` | Address of the new bidder. Will receive `TenantCap` at handover. |
| `new_price` | `next_rent_price` paid. Becomes `tenant_stake` at handover. |
| `handover_expiry` | `handover_countdown_expiry` timestamp in ms. Fixed from this point. |

---

### `BidSuperseded`

Emitted by `rent` when the asset is in **Rented(HandoverConfirmed)**
and a new bid arrives, refunding the previous pending bidder.

```move
public struct BidSuperseded has copy, drop {
    escrow_id:        ID,
    refunded_address: address,
    refunded_amount:  u64,
}
```

| Field | Meaning |
|---|---|
| `escrow_id` | Target escrow. |
| `refunded_address` | Address that received the refund push. |
| `refunded_amount` | Amount refunded (full `pending_bid`). |

---

### `HandoverCompleted`

Emitted by `do_handover` (called lazily from `apply_pending_transitions`).
Primary audit record for handover fund distribution.

```move
public struct HandoverCompleted has copy, drop {
    escrow_id:              ID,
    from_cap_id:            ID,
    to_cap_id:              ID,
    remain_credit_returned: u64,
    owner_earned:           u64,
    protocol_fee:           u64,
}
```

| Field | Meaning |
|---|---|
| `escrow_id` | Target escrow. |
| `from_cap_id` | Displaced tenant's `TenantCap` ID (now stale). |
| `to_cap_id` | New tenant's `TenantCap` ID (just minted). |
| `remain_credit_returned` | Amount pushed to displaced tenant (`remain_credit`). |
| `owner_earned` | Amount credited to `owner_earnings` (`used_credit × 0.95`). |
| `protocol_fee` | Amount routed to `ProtocolFeeInbox` (`used_credit × 0.05`). |

**Invariant:** `remain_credit_returned + owner_earned + protocol_fee == last_rent_price`
(prior to this event).

---

### `TenureExpired`

Emitted by `do_tenure_expiry` (called lazily from
`apply_pending_transitions`). Primary audit record for end-of-tenure
fund distribution.

```move
public struct TenureExpired has copy, drop {
    escrow_id:    ID,
    cap_id:       ID,
    owner_earned: u64,
    protocol_fee: u64,
}
```

| Field | Meaning |
|---|---|
| `escrow_id` | Target escrow. |
| `cap_id` | The expiring tenant's `TenantCap` ID (now stale). |
| `owner_earned` | Amount credited to `owner_earnings` (`tenant_stake × 0.95`). |
| `protocol_fee` | Amount routed to `ProtocolFeeInbox` (`tenant_stake × 0.05`). |

**Invariant:** `owner_earned + protocol_fee == tenant_stake` (prior to
this event).

---

### `DutchAuctionStarted`

Emitted by `do_tenure_expiry` immediately after `TenureExpired` when
the asset transitions to **AtDutchAuction** (i.e. `retire_flag` is
not set).

```move
public struct DutchAuctionStarted has copy, drop {
    escrow_id:   ID,
    start_price: u64,
    floor_price: u64,
}
```

| Field | Meaning |
|---|---|
| `escrow_id` | Target escrow. |
| `start_price` | `last_rent_price` — top of the descent. |
| `floor_price` | `min_rent_price` — bottom of the descent. |

---

### `DutchAuctionEntry`

Emitted by `rent` when the asset is in **AtDutchAuction** and a buyer
enters at the current descent price.

```move
public struct DutchAuctionEntry has copy, drop {
    escrow_id:     ID,
    tenant_cap_id: ID,
    entry_price:   u64,
}
```

| Field | Meaning |
|---|---|
| `escrow_id` | Target escrow. |
| `tenant_cap_id` | ID of the `TenantCap` minted and pushed to the new tenant. |
| `entry_price` | Price paid at auction entry (`price_descent` at `clock.now()`). Becomes `last_rent_price` for the new cycle. |

---

### `AssetIdled`

Emitted by `do_auction_expiry` (called lazily from
`apply_pending_transitions`) when the Dutch Auction expires with no
buyer and the asset transitions to **Idle**.

```move
public struct AssetIdled has copy, drop {
    escrow_id: ID,
}
```

| Field | Meaning |
|---|---|
| `escrow_id` | Target escrow. |

---

### `RetireInitiated`

Emitted by `retire`. Signals that the owner has initiated retirement.
The asset may not be immediately in `Retired` state — it depends on
the prior state (see §6 of design-compact).

```move
public struct RetireInitiated has copy, drop {
    escrow_id:     ID,
    current_state: u8,
}
```

| Field | Meaning |
|---|---|
| `escrow_id` | Target escrow. |
| `current_state` | U8 encoding of `AssetState` at the moment `retire` was called, after `apply_pending_transitions`. Allows off-chain consumers to determine whether retirement is immediate or deferred. |

**Note:** the exact u8 encoding of `AssetState` variants is defined in
`rental_escrow`. To document there.

---

### `AssetRetired`

Emitted by `claim_asset`. Final event for an escrow — the escrow
object is deleted in the same call.

```move
public struct AssetRetired has copy, drop {
    escrow_id: ID,
}
```

| Field | Meaning |
|---|---|
| `escrow_id` | Target escrow (now deleted). |


3. FUNCTIONS
------------

One `emit_*` function per event. All are `public(package)` and follow
the same pattern: accept the event fields as arguments, construct the
struct, call `sui::event::emit`.

| Function | Arguments |
|---|---|
| `emit_asset_integrated` | `escrow_id, owner_cap_id, min_rent_price, tenure_ceiling` |
| `emit_rental_started` | `escrow_id, tenant_cap_id, price` |
| `emit_takeover_initiated` | `escrow_id, outgoing_cap_id, pending_tenant_address, new_price, handover_expiry` |
| `emit_bid_superseded` | `escrow_id, refunded_address, refunded_amount` |
| `emit_handover_completed` | `escrow_id, from_cap_id, to_cap_id, remain_credit_returned, owner_earned, protocol_fee` |
| `emit_tenure_expired` | `escrow_id, cap_id, owner_earned, protocol_fee` |
| `emit_dutch_auction_started` | `escrow_id, start_price, floor_price` |
| `emit_dutch_auction_entry` | `escrow_id, tenant_cap_id, entry_price` |
| `emit_asset_idled` | `escrow_id` |
| `emit_retire_initiated` | `escrow_id, current_state` |
| `emit_asset_retired` | `escrow_id` |

All functions: visibility `public(package)`, return `()`.


4. PROPERTIES
-------------

**P1 — Emit-only, no state:**
    No function mutates any object or reads any escrow field.
    All functions are pure constructors + emit calls.

**P2 — Package-gated emission:**
    All `emit_*` are `public(package)`. Only `rental_escrow` can fire
    them. No external module can inject protocol events.

**P3 — Fund flow auditability:**
    Every boundary event that distributes funds (`HandoverCompleted`,
    `TenureExpired`) records the full split: `owner_earned`,
    `protocol_fee`, and the returned/consumed amounts. The event log
    is the sole audit trail for fee accounting — `FeeMessage` carries
    no traceability fields by design.

**P4 — Escrow lifecycle completeness:**
    Every state transition in the protocol emits at least one event.
    The sequence `AssetIntegrated → ... → AssetRetired` provides a
    complete off-chain history of any escrow instance from its `escrow_id`.

**P5 — Lazy transition observability:**
    `HandoverCompleted`, `TenureExpired`, `DutchAuctionStarted`, and
    `AssetIdled` are emitted during `apply_pending_transitions` — which
    may fire lazily, triggered by any caller (tenant, bot, owner).
    The event timestamp reflects when the transition was executed
    on-chain, not when it logically occurred. Off-chain consumers must
    use `handover_expiry` / `phase_start_ms` from prior events to
    reconstruct the logical timeline.


5. TEST CASES
-------------

### 5.1 Struct construction

| # | Description | Expected |
|---|---|---|
| E1 | Construct each event struct with valid fields | No abort. Fields accessible. |
| E2 | All structs satisfy `copy, drop` | Compiler-verified. |

### 5.2 Emit helpers

| # | Description | Expected |
|---|---|---|
| F1 | Call each `emit_*` function | No abort. Event emitted (verifiable via `test_scenario` event inspection). |
| F2 | `emit_handover_completed` with `remain_credit_returned + owner_earned + protocol_fee == last_rent_price` | Event fields sum correctly — verified at call site in `rental_escrow` tests, not here. |

### 5.3 Fund flow invariants (cross-reference)

| # | Description | Expected |
|---|---|---|
| I1 | `HandoverCompleted`: `remain + owner_earned + protocol_fee == last_rent_price` | Verified in `rental_escrow` tests at call site. |
| I2 | `TenureExpired`: `owner_earned + protocol_fee == tenant_stake` | Verified in `rental_escrow` tests at call site. |


6. MODULE BOUNDARY
------------------

`events.move` exports:

| Symbol | Visibility | Notes |
|---|---|---|
| `AssetIntegrated` | `public` | `copy, drop`. |
| `RentalStarted` | `public` | `copy, drop`. |
| `TakeoverInitiated` | `public` | `copy, drop`. |
| `BidSuperseded` | `public` | `copy, drop`. |
| `HandoverCompleted` | `public` | `copy, drop`. |
| `TenureExpired` | `public` | `copy, drop`. |
| `DutchAuctionStarted` | `public` | `copy, drop`. |
| `DutchAuctionEntry` | `public` | `copy, drop`. |
| `AssetIdled` | `public` | `copy, drop`. |
| `RetireInitiated` | `public` | `copy, drop`. |
| `AssetRetired` | `public` | `copy, drop`. |
| `emit_asset_integrated(...)` | `public(package)` | Called by `rental_escrow::integrate`. |
| `emit_rental_started(...)` | `public(package)` | Called by `rental_escrow::rent` (Idle). |
| `emit_takeover_initiated(...)` | `public(package)` | Called by `rental_escrow::rent` (HandoverOpen). |
| `emit_bid_superseded(...)` | `public(package)` | Called by `rental_escrow::rent` (HandoverConfirmed). |
| `emit_handover_completed(...)` | `public(package)` | Called by `rental_escrow::do_handover`. |
| `emit_tenure_expired(...)` | `public(package)` | Called by `rental_escrow::do_tenure_expiry`. |
| `emit_dutch_auction_started(...)` | `public(package)` | Called by `rental_escrow::do_tenure_expiry`. |
| `emit_dutch_auction_entry(...)` | `public(package)` | Called by `rental_escrow::rent` (AtDutchAuction). |
| `emit_asset_idled(...)` | `public(package)` | Called by `rental_escrow::do_auction_expiry`. |
| `emit_retire_initiated(...)` | `public(package)` | Called by `rental_escrow::retire`. |
| `emit_asset_retired(...)` | `public(package)` | Called by `rental_escrow::claim_asset`. |

No error constants.

**Depends on:** nothing (`sui::event` only).
