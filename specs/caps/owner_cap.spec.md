OWNER CAP MODULE — SPECIFICATION
==================================

Module: `owner_cap`
Design reference: design-compact.md §2 (access model — OwnerCap)
Module map reference: module-map.spec.md §5
Depends on: nothing (`sui::object` only)


0. MODULE RESPONSIBILITY
------------------------

`owner_cap` owns the `OwnerCap` object type and all operations on it.

**Owns:**
- `OwnerCap` — `key + store`. One per integration instance. Proves
  authority for `retire()`, `claim_asset()`, and `withdraw_earnings()`
  in `rental_escrow`. Transferable — the protocol never tracks who holds
  the cap.
- `new(escrow_id, ctx): OwnerCap` — `public(package)`. Mint. Called
  only by `rental_escrow::integrate`.
- `burn(cap)` — `public(package)`. Destroy. Called only by
  `rental_escrow::claim_asset`.
- `escrow_id(cap): ID` — `public`. Getter.
- `assert_escrow(cap, escrow_id)` — `public(package)`. Aborts if
  `cap.escrow_id != escrow_id`. Used by `rental_escrow` to verify the
  presented cap belongs to the escrow being operated on.

**Does not own:**
- Any escrow state or fund balances — those live in `RentalEscrow`.
- Tracking of the cap holder — the protocol is cap-holder-agnostic.

**Key design properties:**
- `key + store`: transferable and composable. An `OwnerCap` satisfies
  the `Asset: key + store` bound of `RentalEscrow` and may itself be
  integrated as an asset into another escrow, granting that escrow's
  tenant temporary administrative authority over the wrapped escrow
  (including `retire()`). The protocol does not impose a nesting-depth
  limit.
- Mutual exclusivity: `OwnerCap` exists ↔ the underlying asset is held
  in its `RentalEscrow`. `burn` is called atomically with asset
  extraction in `claim_asset` — no `OwnerCap` outlives its escrow.
- Authorization is cap-based, not address-based. `rental_escrow` calls
  `assert_escrow` rather than checking `tx_context::sender`.


1. ERROR CONSTANTS
------------------

| Constant | Value | Abort site |
|---|---|---|
| `E_ESCROW_MISMATCH` | `0` | `assert_escrow` — presented cap does not belong to the target escrow |


2. TYPE
-------

### OwnerCap — struct

Authorization object for owner-privileged operations on a single
`RentalEscrow`. One minted per `integrate` call; burned at `claim_asset`.

```move
public struct OwnerCap has key, store {
    id:        UID,
    escrow_id: ID,
}
```

**Abilities:** `key + store`.
- `key` — object identity. Required for `transfer::transfer` at mint
  and for integration as an asset into another escrow.
- `store` — enables transfer and wrapping by external code. Together
  with `key`, satisfies the `Asset: key + store` bound of
  `RentalEscrow<Asset, _>`, so the cap itself can be rented.

**Fields:**

| Field | Type | Meaning |
|---|---|---|
| `id` | `UID` | Object identity. |
| `escrow_id` | `ID` | ID of the `RentalEscrow` this cap authorizes. |

**Invariant:** exactly one live `OwnerCap` with a given `escrow_id`
exists at any time. Enforced structurally — `new` is `public(package)`
and called only once per escrow (at `integrate`); `burn` is
`public(package)` and called only at `claim_asset` which deletes the
escrow in the same call.


3. FUNCTIONS
------------

### `new`

    public(package) fun new(escrow_id: ID, ctx: &mut TxContext): OwnerCap

**Visibility:** `public(package)` — callable only by `rental_escrow`.

**Purpose:** mints an `OwnerCap` bound to a specific escrow.

**Behavior:**
Creates `OwnerCap { id: object::new(ctx), escrow_id }` and returns it.
The caller (`rental_escrow::integrate`) is responsible for returning
it to the PTB — the PTB delivers it to the integrating owner.

**Call site:** `rental_escrow::integrate` — once per integration.

---

### `burn`

    public(package) fun burn(cap: OwnerCap)

**Visibility:** `public(package)` — callable only by `rental_escrow`.

**Purpose:** destroys an `OwnerCap` at retirement, preventing any
further owner-privileged operations on the (now-deleted) escrow.

**Behavior:**
1. Destructures: `OwnerCap { id, escrow_id: _ } = cap`
2. Calls `object::delete(id)`.

**Call site:** `rental_escrow::claim_asset` — once per escrow lifetime,
atomically with asset extraction and escrow deletion.

---

### `escrow_id`

    public fun escrow_id(cap: &OwnerCap): ID

**Visibility:** `public` — readable by any caller, including external
integrations that need to know which escrow a cap authorizes.

**Purpose:** returns the `ID` of the `RentalEscrow` this cap was minted
for.

**Behavior:** returns `cap.escrow_id`.

---

### `assert_escrow`

    public(package) fun assert_escrow(cap: &OwnerCap, escrow_id: ID)

**Visibility:** `public(package)` — called only by `rental_escrow`.

**Purpose:** asserts the presented cap belongs to the target escrow.
Aborts with `E_ESCROW_MISMATCH` if it does not.

**Behavior:**
```
assert!(cap.escrow_id == escrow_id, E_ESCROW_MISMATCH)
```

**Call sites:** `rental_escrow::retire`, `rental_escrow::claim_asset`,
`rental_escrow::withdraw_earnings` — once per call, immediately after
the cap is presented.


4. PROPERTIES
-------------

**P1 — One cap per escrow:**
    `new` is `public(package)` and called exactly once per escrow at
    `integrate`. No other creation path exists. Structural guarantee,
    not a runtime check.

**P2 — Cap lifetime bounded by escrow lifetime:**
    `burn` is called atomically with `object::delete` on the escrow UID
    inside `claim_asset`. No `OwnerCap` with escrow_id `X` can exist
    after the escrow `X` is deleted.

**P3 — Authorization is cap-bound, not address-bound:**
    `assert_escrow` checks `cap.escrow_id`. The protocol does not record
    or check the address of whoever holds the cap. Transferring the cap
    transfers authority unconditionally.

**P4 — Recursive integrability:**
    `key + store` allows `OwnerCap` to satisfy the `Asset: key + store`
    bound of `RentalEscrow<Asset, _>`. The cap can itself be deposited
    into a new escrow as the asset. `rental_escrow::integrate` imposes
    no depth restriction on this composition.

**P5 — No zero-state objects:**
    Every `OwnerCap` has a non-zero `escrow_id` (set at mint from a
    live `RentalEscrow` UID). `burn` deletes the object entirely —
    no inert shells remain.


5. TEST CASES
-------------

### 5.1 `new`

| # | Description | Expected |
|---|---|---|
| N1 | `new(escrow_id, ctx)` | Returns `OwnerCap` with `cap.escrow_id == escrow_id`. Object has a fresh UID. |
| N2 | Two calls with distinct `escrow_id`s | Two distinct `OwnerCap` objects, each bound to its own escrow_id. |

### 5.2 `burn`

| # | Description | Expected |
|---|---|---|
| B1 | `burn(cap)` | Cap's UID deleted. No abort. |
| B2 | `burn` consumes the cap (by value) | Compiler enforces — no double-burn possible. |

### 5.3 `escrow_id`

| # | Description | Expected |
|---|---|---|
| G1 | `escrow_id(&cap)` after `new(id, ctx)` | Returns `id`. |

### 5.4 `assert_escrow`

| # | Description | Expected |
|---|---|---|
| A1 | `assert_escrow(&cap, cap.escrow_id)` | No abort. |
| A2 | `assert_escrow(&cap, different_id)` | Aborts with `E_ESCROW_MISMATCH`. |
| A3 | Cap minted for escrow A, asserted against escrow B | Aborts with `E_ESCROW_MISMATCH`. |

### 5.5 Lifecycle

| # | Description | Expected |
|---|---|---|
| L1 | `new` → `assert_escrow` (matching) → `burn` | Full lifecycle completes. No abort. |
| L2 | `new` → `assert_escrow` (mismatched) | Aborts before burn. Cap not consumed. |


6. MODULE BOUNDARY
------------------

`owner_cap.move` exports:

| Symbol | Visibility | Notes |
|---|---|---|
| `OwnerCap` (type) | `public` | `key + store`. One per escrow. Transferable. |
| `E_ESCROW_MISMATCH` | `public` | Abort code for cap/escrow mismatch in `assert_escrow`. |
| `new(escrow_id, ctx): OwnerCap` | `public(package)` | Mint. Called only by `rental_escrow::integrate`. |
| `burn(cap)` | `public(package)` | Destroy. Called only by `rental_escrow::claim_asset`. |
| `escrow_id(cap): ID` | `public` | Getter. |
| `assert_escrow(cap, escrow_id)` | `public(package)` | Aborts with `E_ESCROW_MISMATCH` if mismatch. |

**Depends on:** nothing (`sui::object` only).
