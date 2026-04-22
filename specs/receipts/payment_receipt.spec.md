PAYMENT RECEIPT MODULE — SPECIFICATION
=======================================

Module: `payment_receipt`
Design reference: design-compact.md §1 (state machine — Rented branch of rent()),
  §2 (access model — delivery symmetry)
Module map reference: module-map.spec.md §7
Depends on: nothing (`sui::object`, `sui::transfer`, `std::ascii::String`)


0. MODULE RESPONSIBILITY
------------------------

`payment_receipt` owns the `PaymentReceipt` object type and all operations on
it. The type is a purely symbolic, wallet-side receipt minted at bid time in
the `Rented` branch of `rental_escrow::rent`. It carries **no protocol
authority** and is invisible to every call site outside this module.

**Owns:**
- `PaymentReceipt` — `key` only. One minted per successful bid on an escrow
  in `Rented { HandoverOpen }` or `Rented { HandoverConfirmed }`. Holds the
  escrow identity, the amount paid, and the canonical type strings for coin
  and asset.
- `new(escrow_id, amount, coin_type, asset_type, ctx): PaymentReceipt` —
  `public(package)`. Mint. Called by `rental_escrow::rent` in both Rented
  sub-branches, after the `E_INSUFFICIENT_PAYMENT` check passes.
- `burn(receipt)` — `public`. Voluntary destroy by holder for gas recovery.
  No state mutation anywhere. The protocol never forces this.

**Does not own:**
- Any protocol authorization — the receipt is not checked by any call site.
- Any escrow state or fund flows — those live in `rental_escrow`.
- Any event stream — see §3.
- Type-parameter plumbing — `rental_escrow::rent` already has `<Asset,
  CoinType>` in scope and derives the canonical strings via
  `type_name::get<T>().into_string()` before calling `new`. This module is a
  passive data container.

**Key design properties:**

- **Purely symbolic — zero protocol power.** No `assert_*`, no ID check, no
  staleness, no getter required by any call site. The only way the receipt
  influences the protocol is by existing in a wallet at the moment of bid
  settlement — which is precisely the UX it was created for.

- **UX symmetry with the other `rent()` branches.** Before this module
  existed, `rent()` from `Idle` / `AtDutchAuction` returned a `TenantCap` to
  the sender in the same transaction (direct exchange), while `rent()` from
  `Rented` returned nothing — the tenant cap is minted lazily at
  `do_handover`. The bidder signed a tx that sent coins and received no
  object, producing a one-sided feel in wallets. `PaymentReceipt` closes
  this gap: every successful `rent()` call now delivers an object to the
  sender in the same transaction, regardless of the pre-settlement state.

  | State at call | Delivered in same tx |
  |---|---|
  | `Idle` | `TenantCap` |
  | `AtDutchAuction` | `TenantCap` |
  | `Rented { HandoverOpen }` | `PaymentReceipt` |
  | `Rented { HandoverConfirmed }` | `PaymentReceipt` |

- **`key` only — non-transferable by type.** Same rationale as `TenantCap`:
  no transfer function exists, the object can never leave the holder's
  wallet except via `burn`. Rules out a secondary market in receipts (which
  would have no meaningful use) and keeps the mint-recipient address
  inequivocal — anyone wanting a `PaymentReceipt` on a given escrow must
  bid themselves.

- **Self-describing in wallets.** The receipt carries `amount`, `coin_type`
  and `asset_type` as fields so that a wallet or explorer can render it
  fully without consulting an off-chain indexer. `Display<PaymentReceipt>`
  interpolates these fields at render time.

- **Non-generic type despite generic origin.** `RentalEscrow<Asset,
  CoinType>` is generic, but `PaymentReceipt` is a single concrete type for
  every `(Asset, CoinType)` instantiation. The coin and asset types are
  carried as `String` fields (derived at mint from `type_name::get<T>`) so
  one `Display<PaymentReceipt>` registration covers all present and future
  coin/asset combinations — essential for a permissionless protocol where
  integrators choose their own types.

- **Outside the star schema.** The protocol's event layer is a SQL star
  schema anchored on `escrow_id` with paired lifecycle events for every
  child object (`TenantCap*`, `OwnerCap*`, `FeeMessage*`). `PaymentReceipt`
  deliberately breaks that pattern — it emits no events. Justification and
  off-chain linkage strategy are detailed in §3.


1. ERROR CONSTANTS
------------------

None. No function in this module has validatable preconditions that require
named abort codes. `new` is a pure constructor with no runtime checks (all
validation — sufficient payment, correct state — happens at the call site in
`rental_escrow::rent`). `burn` is unconditional.


2. TYPE
-------

### PaymentReceipt — struct

Symbolic receipt of a rental bid payment. Minted once per successful bid in
a `Rented` state of `rental_escrow::rent`, pushed to the sender in the same
transaction.

```move
use std::ascii::String;

public struct PaymentReceipt has key {
    id:         UID,
    escrow_id:  ID,
    amount:     u64,
    coin_type:  String,
    asset_type: String,
}
```

**Abilities:** `key` only.
- `key` — object identity. Required for `transfer::transfer` (push to
  sender in `rental_escrow::rent`).
- No `store` — non-transferable. Cannot be wrapped or moved by external
  code. The holder's only exit is `burn`.

**Fields:**

| Field | Type | Meaning |
|---|---|---|
| `id` | `UID` | Object identity. |
| `escrow_id` | `ID` | ID of the `RentalEscrow` the bid was placed on. |
| `amount` | `u64` | Payment amount in base units of `CoinType`, captured at mint. Equal to `coin::value(&payment)` at the call site. |
| `coin_type` | `String` | Canonical type string of `CoinType`, derived by `type_name::get<CoinType>().into_string()` at the call site. Example: `"0000…0002::sui::SUI"`. |
| `asset_type` | `String` | Canonical type string of `Asset`, derived by `type_name::get<Asset>().into_string()` at the call site. |

**Why non-generic despite generic origin:**

A generic `PaymentReceipt<phantom Asset, phantom CoinType>` would encode the
types in the object's type tag at zero on-chain cost — but it would force
one `Display<PaymentReceipt<A, C>>` registration per `(Asset, CoinType)`
pair. The protocol is permissionless: any integrator chooses their own
`Asset` and `CoinType` at `integrate` time, so the set of live
instantiations is unbounded and not known post-deployment. Pre-registering
Display for every possible combination is infeasible.

Storing the canonical type strings as fields shifts a few dozen bytes
on-chain per object in exchange for a **single `Display<PaymentReceipt>`
registration** that covers every present and future instantiation via
template field interpolation. This is the scalable trade-off.

**No identity check anywhere.** Unlike `TenantCap`, which is compared by ID
against `escrow.current_tenant_cap_id` to enforce staleness, a
`PaymentReceipt` is never presented back to the protocol. The only consumer
is the wallet / explorer displaying the object.


3. EVENTS
---------

**This module emits no events.** The decision is deliberate — not an
omission — and is documented here so that a reader familiar with the
protocol's star-schema convention does not interpret the absence as a bug.

**Why no `PaymentReceiptMinted` event:**

Every `PaymentReceipt` mint happens inside `rental_escrow::rent` in a
`Rented` sub-branch, in 1:1 correspondence with exactly one of two existing
state-machine events:

| Sub-branch | Co-emitted event (already specified in `rental_escrow`) |
|---|---|
| `Rented { HandoverOpen }` (first bid, opens `HandoverConfirmed`) | `BidPlaced { escrow_id, pending_tenant, bid_amount, handover_countdown_expiry }` |
| `Rented { HandoverConfirmed }` (supersede) | `BidSuperseded { escrow_id, displaced_bidder, refunded_amount, new_bidder, new_bid_amount }` |

Both events already carry `escrow_id` and the bidder's address, in the same
transaction as the receipt's mint. An off-chain indexer watching Sui's
object-creation envelope sees the new `PaymentReceipt` object and can link
it back to its originating bid by the tuple `(escrow_id, bidder_address,
tx_sequence)` — unambiguous per transaction. No extra Move-level event is
needed to preserve this linkage.

**Why no `PaymentReceiptBurned` event:**

`burn` is voluntary, driven entirely by the holder's gas-recovery decision.
The protocol does not depend on burn timing, and the receipt carries no
authority whose revocation could be meaningful. A `PaymentReceiptBurned`
row would contribute zero analytical value — the burn is purely a wallet
hygiene event, equivalent to deleting any other owned object in the user's
wallet.

**Deliberate exclusion from the star schema:**

The star schema's invariant — every child-object type has paired
create/destroy events joined on the object's own ID — applies to dimensions
that the indexer materializes as first-class analytical tables
(`owner_cap`, `tenant_cap`, `fee_message`). `PaymentReceipt` is **not** a
dimension in that schema: it is a client-side collectible whose purpose is
the wallet UX of the bidder, not the accountant's ledger. Treating it as a
schema dimension would add storage and indexing overhead for a table whose
rows replicate information already present in `BidPlaced` /
`BidSuperseded`.

Any indexer that still wishes to track receipts per wallet can do so by
reading Sui's object-creation envelope filtered by the
`PaymentReceipt` type tag — no protocol-level event support required.


4. FUNCTIONS
------------

### `new`

    public(package) fun new(
        escrow_id:  ID,
        amount:     u64,
        coin_type:  String,
        asset_type: String,
        ctx:        &mut TxContext,
    ): PaymentReceipt

**Visibility:** `public(package)` — callable only by `rental_escrow`.

**Purpose:** constructs a `PaymentReceipt` from already-derived inputs. The
caller has validated the payment (`E_INSUFFICIENT_PAYMENT`), captured
`amount = coin::value(&payment)` before consuming the coin, and derived the
two type strings from the generic parameters of the surrounding
`rental_escrow::rent<Asset, CoinType>` call.

**Behavior:**
1. Construct and return
   ```
   PaymentReceipt {
       id: object::new(ctx),
       escrow_id,
       amount,
       coin_type,
       asset_type,
   }
   ```

That is the entire body. No events, no mutation of any shared state, no
additional derivation — the caller owns all of that.

**Delivery:** `rental_escrow::rent` calls `transfer::transfer(receipt,
tx_context::sender(ctx))` immediately after `new` returns, pushing the
receipt to the bidder. This module does not perform the transfer.

**Call sites:** `rental_escrow::rent`, in both `Rented { HandoverOpen }`
and `Rented { HandoverConfirmed }` sub-branches, after the
`E_INSUFFICIENT_PAYMENT` check. No other call site exists or will exist.

---

### `burn`

    public fun burn(receipt: PaymentReceipt)

**Visibility:** `public` — callable by any holder.

**Purpose:** voluntary destruction of a `PaymentReceipt` for gas recovery.
No effect on any escrow, any cap, or any fund balance.

**Behavior:**
1. Destructure: `let PaymentReceipt { id, escrow_id: _, amount: _,
   coin_type: _, asset_type: _ } = receipt;`
2. `object::delete(id);`

No `ctx` argument — there is no event to emit and the module has no need
to read `tx_context::sender`.

**No state mutation anywhere.** The escrow is not notified, no cap becomes
stale, no fund moves. The object simply ceases to exist.


5. PROPERTIES
-------------

**P1 — Minted only at successful bids in Rented states:**
    `new` is `public(package)` and called exclusively from `rental_escrow::
    rent` in the two `Rented` sub-branches, after
    `E_INSUFFICIENT_PAYMENT` has passed. No other path creates a
    `PaymentReceipt`. 1:1 correspondence with `BidPlaced` /
    `BidSuperseded`.

**P2 — Non-transferable by type:**
    `key` only, no `store`. No transfer function exists in this module.
    The Sui type system enforces this — no external code can move the
    receipt between addresses. Mint-recipient ≡ burn-tx sender (when
    `burn` is eventually called).

**P3 — Zero protocol power:**
    No function in any module of the protocol reads, mutates, or checks a
    `PaymentReceipt`. Presenting one has no effect. Losing one has no
    effect. The object exists solely for the wallet-side UX of the
    bidder.

**P4 — Self-describing in wallets:**
    Every `PaymentReceipt` carries `amount`, `coin_type` and `asset_type`
    as fields. `Display<PaymentReceipt>` renders them via template
    interpolation. A wallet or explorer can present the receipt fully
    without consulting any indexer.

**P5 — One `Display` registration covers all instantiations:**
    The type is non-generic, so a single post-deployment PTB presenting
    `&Publisher` and `&mut DisplayRegistry` registers
    `Display<PaymentReceipt>` for every present and future `(Asset,
    CoinType)` pair.

**P6 — `burn` has no side-effects anywhere:**
    Destroying a receipt affects only the receipt itself. No escrow field
    changes, no cap becomes stale, no fund moves.


6. TEST CASES
-------------

### 6.1 `new`

| # | Description | Expected |
|---|---|---|
| N1 | `new(escrow_id, amount, coin_type, asset_type, ctx)` | Returns `PaymentReceipt` with the four input fields exactly as passed. Object has a fresh UID. **No event emitted.** |
| N2 | Two calls with same inputs in the same tx | Two distinct `PaymentReceipt` objects (distinct UIDs), identical content in all other fields. |
| N3 | Two calls with distinct amounts / types | Two receipts with matching fields per call. Asserts fields are copied verbatim from arguments, not derived internally. |

### 6.2 `burn`

| # | Description | Expected |
|---|---|---|
| B1 | `burn(receipt)` on any receipt | UID deleted. No abort. No event emitted. No escrow or cap state change anywhere. |
| B2 | `burn` consumes by value | Compiler enforces — no double-burn. |

### 6.3 Lifecycle

| # | Description | Expected |
|---|---|---|
| L1 | `new` → `burn` | Full lifecycle. No abort. No events emitted in either step. |


7. MODULE BOUNDARY
------------------

`payment_receipt.move` exports:

| Symbol | Visibility | Notes |
|---|---|---|
| `PaymentReceipt` (type) | `public` | `key` only. Non-transferable. Symbolic — no protocol authority. |
| `new(escrow_id, amount, coin_type, asset_type, ctx): PaymentReceipt` | `public(package)` | Mint. Called only by `rental_escrow::rent` in the Rented sub-branches. No event emitted. |
| `burn(receipt)` | `public` | Voluntary destroy for gas recovery. No state mutation. No event emitted. |

No error constants. No events.

**Depends on:** `sui::object`, `sui::transfer`, `std::ascii::String`.


8. OBJECT DISPLAY
-----------------

![PaymentReceipt](../../media/object-display/payment-receipt.png)

`Display<PaymentReceipt>` gives every receipt a visual identity in wallets and
explorers. Created once post-deployment via a PTB presenting `&Publisher`
for the package and `&mut DisplayRegistry` (Sui framework shared object).

**One registration covers all instantiations.** Because `PaymentReceipt` is
a single concrete type (non-generic), the registered template applies to
every receipt regardless of which `Asset` or `CoinType` the originating
escrow was parameterized over. Templates interpolate the `amount`,
`coin_type` and `asset_type` fields at render time.

### Fields

| Key | Value | Notes |
|---|---|---|
| `name` | `Payment Receipt` | Static. |
| `description` | `Receipt of a rental bid payment of {amount} {coin_type} on asset type {asset_type}. Symbolic — carries no protocol authority.` | Template. Interpolates per-instance field values. |
| `image_url` | `{IMAGE_BASE_URL}/payment-receipt.png` | Hosted URL. Source: `media/object-display/payment-receipt.png`. |
| `project_url` | `https://liquidrenting.com` | Static. |
| `creator` | `Liquid Renting Protocol` | Static. |

`{IMAGE_BASE_URL}` is set at deployment time to the protocol's media hosting base URL.
`{amount}`, `{coin_type}`, `{asset_type}` are Sui Display field-interpolation tokens
resolved from each object's own fields at render time.

### Creation

```move
use sui::display_registry;

let mut display = display_registry::new<PaymentReceipt>(&publisher, registry);
display.add(b"name".to_string(),        b"Payment Receipt".to_string());
display.add(b"description".to_string(), b"Receipt of a rental bid payment of {amount} {coin_type} on asset type {asset_type}. Symbolic — carries no protocol authority.".to_string());
display.add(b"image_url".to_string(),   b"{IMAGE_BASE_URL}/payment-receipt.png".to_string());
display.add(b"project_url".to_string(), b"https://liquidrenting.com".to_string());
display.add(b"creator".to_string(),     b"Liquid Renting Protocol".to_string());
display_registry::commit(display);
```

One `Display<PaymentReceipt>` per package deployment. ID is deterministic from
`DisplayRegistry` + type — no event scanning required.

**Status:** [ ] `Display<PaymentReceipt>` created and committed.
