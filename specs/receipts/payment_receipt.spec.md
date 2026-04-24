PAYMENT RECEIPT MODULE — SPECIFICATION
=======================================

Module: `payment_receipt`
Design reference: design-compact.md §1 (state machine — Rented branch of rent()),
  §2 (access model — delivery symmetry)
Module map reference: module-map.spec.md §7
Depends on: nothing (`sui::object`, `sui::transfer`, `std::ascii::String`,
  `std::type_name`)


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
- `mint_to<Asset, CoinType>(escrow_id, amount, recipient, ctx)` —
  `public(package)`. Fused mint + delivery. Constructs the receipt
  inline — deriving `coin_type` and `asset_type` from the generic
  parameters via `type_name::get<T>().into_string()` — and transfers it
  to `recipient`. No return value — the caller (`rental_escrow`) has no
  use for the receipt's `ID`. The transfer lives inside this module:
  `transfer::transfer<PaymentReceipt>` only compiles here (Sui verifier
  rejects it for a `key`-only foreign type). Called by
  `rental_escrow::rent<Asset, CoinType>` in both Rented sub-branches,
  after the `E_INSUFFICIENT_PAYMENT` check passes.
- `burn(receipt)` — `public`. Voluntary destroy by holder for gas recovery.
  No state mutation anywhere. The protocol never forces this.

**Does not own:**
- Any protocol authorization — the receipt is not checked by any call site.
- Any escrow state or fund flows — those live in `rental_escrow`.
- Any event stream — see §3.

**Owns the capture format for generic-type identity.** `mint_to` takes
`<Asset, CoinType>` as generics and derives the canonical type strings
inline via `type_name::get<T>().into_string()`. The struct layout stores
the result, so the decision "how this protocol represents a generic
parameter in a receipt's fields" belongs to `payment_receipt`: any
future evolution of that encoding (hashed form, shortened form,
trailing-null stripping) is one edit here, not an adapter-code edit at
every caller. Generics cross the function boundary at compile time; the
struct itself stays non-generic (see §2).

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
named abort codes. `mint_to` is a pure constructor-plus-transfer with no
runtime checks (all validation — sufficient payment, correct state —
happens at the call site in `rental_escrow::rent`). `burn` is
unconditional.


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
- `key` — object identity. Required for `transfer::transfer` inside
  `mint_to` (same module; the verifier rejects `transfer::transfer` of a
  `key`-only type from any other module).
- No `store` — non-transferable. Cannot be wrapped or moved by external
  code. The holder's only exit is `burn`.

**Fields:**

| Field | Type | Meaning |
|---|---|---|
| `id` | `UID` | Object identity. |
| `escrow_id` | `ID` | ID of the `RentalEscrow` the bid was placed on. |
| `amount` | `u64` | Payment amount in base units of `CoinType`, captured at mint. Equal to `coin::value(&payment)` at the call site. |
| `coin_type` | `String` | Canonical type string of `CoinType`, derived inside `mint_to` via `type_name::get<CoinType>().into_string()`. Example: `"0000…0002::sui::SUI"`. |
| `asset_type` | `String` | Canonical type string of `Asset`, derived inside `mint_to` via `type_name::get<Asset>().into_string()`. |

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

**Generic function, non-generic struct.** `mint_to<Asset, CoinType>`
takes the two generics at its boundary and derives the canonical strings
inline (see §4); the struct itself carries no type parameters. Generics
live at the function boundary — compile-time, monomorphized away — while
concrete `String` fields live on the object, supporting the single
global `Display<PaymentReceipt>` registration above.

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

### `mint_to`

    public(package) fun mint_to<Asset, CoinType>(
        escrow_id: ID,
        amount:    u64,
        recipient: address,
        ctx:       &mut TxContext,
    )

**Visibility:** `public(package)` — callable only by `rental_escrow`.

**Purpose:** fused mint + delivery. Derives the two canonical type
strings from the generics in scope, constructs a `PaymentReceipt`, and
transfers it to `recipient`. The caller has validated the payment
(`E_INSUFFICIENT_PAYMENT`) and captured `amount = coin::value(&payment)`
before consuming the coin; the two generics propagate from the
surrounding `rental_escrow::rent<Asset, CoinType>` call.

**Behavior:**
1. Construct inline, deriving the two type strings from the generics:
   ```
   let receipt = PaymentReceipt {
       id: object::new(ctx),
       escrow_id,
       amount,
       coin_type:  type_name::get<CoinType>().into_string(),
       asset_type: type_name::get<Asset>().into_string(),
   };
   ```
2. `transfer::transfer(receipt, recipient);`

That is the entire body. No events, no mutation of any shared state, no
return value. The caller never holds a `PaymentReceipt` as a local.

**Why the transfer lives here, not in the caller:** the Sui bytecode
verifier enforces that `transfer::transfer<T>` for a `key`-only type `T`
can only appear inside the module that defines `T`. A
`rental_escrow`-side `transfer::transfer(receipt, recipient)` would fail
to compile. The fused form is the only working shape.

**Call sites:** `rental_escrow::rent<Asset, CoinType>`, in both
`Rented { HandoverOpen }` and `Rented { HandoverConfirmed }`
sub-branches, after the `E_INSUFFICIENT_PAYMENT` check. Passes
`tx_context::sender(ctx)` as `recipient`; the two generics forward from
`rent`'s own parameters. No other call site exists or will exist.

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
    `mint_to` is `public(package)` and called exclusively from
    `rental_escrow::rent` in the two `Rented` sub-branches, after
    `E_INSUFFICIENT_PAYMENT` has passed. No other path creates a
    `PaymentReceipt`. 1:1 correspondence with `BidPlaced` /
    `BidSuperseded`.

**P2 — Non-transferable by type, single delivery channel:**
    `key` only, no `store`. The only `transfer::transfer<PaymentReceipt>`
    call in the entire protocol lives inside `mint_to` of this module;
    the Sui bytecode verifier rejects it at any other call site. No
    external code can move the receipt between addresses after mint.
    Mint-recipient ≡ burn-tx sender (when `burn` is eventually called).

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

### 6.0 Test strategy

**Test module.** `#[test_only] module liquid_renting::payment_receipt_tests`.
Function names describe the asserted behaviour (e.g.
`mint_to_derives_canonical_type_strings`,
`mint_to_emits_no_events`, `burn_leaves_no_trace`).

**Idioms.**

- `payment_receipt` creates real Sui objects (UIDs), transfers them,
  and operates over generic parameters. Every test runs in
  `sui::test_scenario` — `mint_to` calls `transfer::transfer`, and
  generic instantiation requires monomorphized test entry points.
- Each row translates to one `#[test]` function. `payment_receipt`
  has **no abort sites** (§1), so no `#[expected_failure]` rows.
  `burn`'s by-value consumption is compile-time.
- Every row additionally asserts
  `test_scenario::num_user_events(&effects) == 0` — absence of events
  is a protocol contract (§3), not an accidental omission.

**Fixtures.** Canonical addresses and test-only generic witnesses:

```
const ALICE: address = @0xA11CE;   // typical sender / recipient
const BOB:   address = @0xB0B;     // custody / distinct-recipient test
const ZERO:  address = @0x0;       // zero-address boundary

#[test_only] public struct TestAssetA has store {}
#[test_only] public struct TestAssetB has store {}
#[test_only] public struct TestCoinA has store {}
#[test_only] public struct TestCoinB has store {}
```

The test-only structs are the generic witnesses passed to
`mint_to<Asset, CoinType>` — they exist solely so `type_name::get<T>`
has concrete types to resolve. Their fully-qualified strings are fixed
at compile time and used as expected values. Escrow IDs use
`object::id_from_address(@0xE5C1)` / `@0xE5C2` literals.

**Test-only helpers.**

```
#[test_only] public fun receipt_fields_for_testing(
    receipt: &PaymentReceipt): (ID, u64, String, String)
```

Exposes the private struct fields (escrow_id, amount, coin_type,
asset_type) so rows can assert each individually. `mint_to` is
`public(package)`; `burn` is `public`; no wrappers needed for them.

**Expected type-string form.** `type_name::get<T>().into_string()`
yields `"<pkg_address>::<module>::<type_name>"` with full hex-padded
package address (64 hex chars). Rows express expected values as the
literal string for the test module's package. The helper
`expected_type_string<T>()` wraps the Sui framework call so tests do
not duplicate the exact literal — `assert_eq!(receipt.coin_type,
expected_type_string<TestCoinA>())`.


### 6.1 `mint_to`

| # | Description | Expected |
|---|---|---|
| N1 | Sender ALICE calls `mint_to<TestAssetA, TestCoinA>(escrow_id = @0xE5C1, amount = 1_000, recipient = ALICE, ctx)` | Next tx as ALICE: `take_from_address<PaymentReceipt>` yields a receipt. `receipt_fields_for_testing(&receipt) == (@0xE5C1, 1_000, expected_type_string<TestCoinA>(), expected_type_string<TestAssetA>())`. Fresh UID (non-zero). `num_user_events == 0`. |
| N2 | Two `mint_to<TestAssetA, TestCoinA>` calls with identical inputs in one tx | Two distinct receipts in ALICE's account with distinct UIDs. All non-UID fields identical between the two. `num_user_events == 0`. |
| N3 | `mint_to<TestAssetA, TestCoinA>(@0xE5C1, 100, ALICE, ctx)` and `mint_to<TestAssetB, TestCoinB>(@0xE5C2, 200, ALICE, ctx)` in one tx | Two receipts. receipt0: `(escrow_id=@0xE5C1, amount=100, coin_type=type_str<TestCoinA>, asset_type=type_str<TestAssetA>)`. receipt1: `(@0xE5C2, 200, type_str<TestCoinB>, type_str<TestAssetB>)`. Asserts type strings are **derived inside `mint_to` from the generic parameters**, not supplied by the caller — the module owns the capture format. |
| N4 | Sender ALICE calls `mint_to<TestAssetA, TestCoinA>(escrow_id, amount, recipient = BOB, ctx)` | Receipt retrievable via `take_from_address(scenario, BOB)`, **not** ALICE. Assert `has_most_recent_for_address<PaymentReceipt>(ALICE) == false`. Delivery routes through the `recipient` argument, not through `tx_context::sender(ctx)`. |
| **[new] N5** | `mint_to<TestAssetA, TestCoinA>(escrow_id, amount = 0, recipient = ALICE, ctx)` | Receipt stored with `amount == 0`. No abort. Documents that `payment_receipt` does not filter zero amounts — the `E_INSUFFICIENT_PAYMENT` check lives in `rental_escrow::rent` upstream. Under the current rental_escrow contract this path is unreachable in production (the gate ensures `amount > 0` before the call), but the module's own contract is permissive. |
| **[new] N6** | `mint_to<TestAssetA, TestCoinA>(escrow_id, amount = u64::MAX, recipient = ALICE, ctx)` | Receipt stored with `amount == u64::MAX`. No overflow — the field is a plain u64 assignment. Asserts the boundary at u64 max. |
| **[new] N7** | `mint_to<TestAssetA, TestCoinA>(escrow_id = @0x0, amount = 1, recipient = ALICE, ctx)` | Receipt stored with `escrow_id == @0x0`. No abort. Symmetric with `tenant_cap` N6 — receipts carry whatever ID the caller passes; rental_escrow is the source of non-zero live IDs. |
| **[new] N8** | `mint_to<TestAssetA, TestCoinA>(escrow_id, amount = 1, recipient = ZERO, ctx)` | Receipt transferred to `@0x0` — technically executes at the Sui framework layer, becomes permanently inaccessible. `num_user_events == 0`. Documents the same policy as `tenant_cap` N5: module is permissive; rental_escrow must guarantee non-zero `recipient` in production. |
| **[new] N9** | **Type-string derivation fidelity.** `mint_to<TestAssetA, TestCoinA>` then `mint_to<TestCoinA, TestAssetA>` (generics swapped) | Both receipts minted. receipt0.asset_type = type_str<TestAssetA>, receipt0.coin_type = type_str<TestCoinA>. receipt1.asset_type = type_str<TestCoinA>, receipt1.coin_type = type_str<TestAssetA>. Asserts the two generic slots are wired to the correct fields — not swapped in the constructor body. |
| **[new] N10** | **P1 co-emission pattern check.** `mint_to` emits nothing; the test body verifies `num_user_events == 0` directly after the call. | Distinguishes payment_receipt from cap modules: §3's "outside the star schema" is a testable invariant, not just a design note. The co-emission with `BidPlaced` / `BidSuperseded` happens at the `rental_escrow` call site, verified in rental_escrow tests. |

### 6.2 `burn`

| # | Description | Expected |
|---|---|---|
| B1 | `burn(receipt)` on a receipt from scenario setup | UID deleted (`has_most_recent_for_address<PaymentReceipt>(holder) == false` after). No abort. `num_user_events == 0` in the burn tx. No escrow or cap state change anywhere (not checkable at this module level — no escrow in scope; **P6** is structural). |
| B2 | `burn` consumes by value | Compile-time enforcement — a second `burn(receipt)` would fail to compile. Not a runtime row; verified by the successful build of L1. Listed for completeness. |
| **[new] B3** | `burn` on a receipt minted with distinct generics (`<TestAssetB, TestCoinB>`) | Identical behaviour to B1. Asserts burn is generic-agnostic — the struct is non-generic and burn takes no type parameters. `num_user_events == 0`. |
| **[new] B4** | `burn` on a receipt with `amount == 0` (via N5 setup) | Identical behaviour. Burn does not inspect field values. |
| **[new] B5** | `burn` on a receipt with `escrow_id == @0x0` (via N7 setup) | Identical behaviour. Symmetric with N7. |

### 6.3 Lifecycle

| # | Description | Expected |
|---|---|---|
| L1 | `mint_to` (tx1 by ALICE) → take from ALICE (tx2) → `burn` (tx2) | Full lifecycle. `tx1.num_user_events == 0`, `tx2.num_user_events == 0`. Receipt gone after tx2. |
| **[new] L2** | Mint three receipts for ALICE in tx1 with varying generics (`<AssetA,CoinA>`, `<AssetA,CoinB>`, `<AssetB,CoinA>`); burn all three in tx2 | tx1: three distinct receipts in ALICE's account. tx2: three `burn` calls succeed; all receipts gone. `num_user_events == 0` across both txs. Asserts lifecycle independence across generic instantiations — each receipt tracks its own `(asset_type, coin_type)` pair and burns independently. |
| **[new] L3** | Mint receipt; in next tx, call `receipt_fields_for_testing(&receipt)` five times; then `burn` | All five getter calls return the same tuple. `burn` succeeds. Asserts the receipt is inspectable without mutation (no field is consumed by reading) — the wallet/explorer Display rendering pattern. |

**[new] [property] P-NE — no-event invariant.** Every row above
asserts `num_user_events == 0` on every tx that calls `mint_to` or
`burn`. The test suite aggregates this into a standalone property
test: for an arbitrary mix of mints and burns in a single tx, total
user-event count is zero. Guards §3's deliberate exclusion from the
star schema against regressions.

**[new] [property] P-ND — non-generic dispatch.** Mint two receipts
with opposing generic orders (`<A,B>` and `<B,A>`) and assert their
`coin_type` / `asset_type` fields are swapped exactly. Encoded in N9
above; lifted here as a property so a test writer sees it as a
cross-cutting obligation distinct from the individual row.


### 6.4 Open questions

- **Zero-amount / zero-ID / zero-recipient tolerance (N5, N7, N8).**
  Module is permissive. If policy later requires rejection, decide
  whether guards live here (costs §1's "no aborts" posture, breaks
  §3's "no events" via abort codes) or stay at `rental_escrow::rent`.
  Current stance: keep the receipt permissive; upstream guarantees
  non-zero values.
- **Type-string literal form (N1, N9).** The exact string returned by
  `type_name::get<T>().into_string()` depends on the Sui framework
  version's formatting (leading `0x`, hex padding, generic parameter
  encoding). Rows reference `expected_type_string<T>()` helper to
  avoid pinning to a literal that could drift. Confirm the helper's
  semantics match framework behaviour at implementation time.
- **Transfer to `@0x0` (N8).** `transfer::transfer(receipt, @0x0)`
  creates an inaccessible object. payment_receipt does not guard
  against this; flag during `rental_escrow` audit that `rent`'s
  `tx_context::sender(ctx)` is always non-zero on Sui (signer address
  is validated at the VM level), so this path is unreachable in
  production.
- **Fidelity of `receipt_fields_for_testing`.** This `#[test_only]`
  helper exposes private fields. Its signature must stay in sync with
  the struct definition — if a future field is added to
  `PaymentReceipt`, update the helper return type and every row that
  destructures its output. Flag as a maintenance obligation on the
  Display-adding PR, not a current gap.


7. MODULE BOUNDARY
------------------

`payment_receipt.move` exports:

| Symbol | Visibility | Notes |
|---|---|---|
| `PaymentReceipt` (type) | `public` | `key` only. Non-transferable by type; single delivery channel (`mint_to`). Symbolic — no protocol authority. |
| `mint_to<Asset, CoinType>(escrow_id, amount, recipient, ctx)` | `public(package)` | Fused mint + delivery. Derives `coin_type` / `asset_type` from the generics via `type_name::get<T>().into_string()`, constructs the receipt, and transfers it to `recipient`. No return value. Called only by `rental_escrow::rent<Asset, CoinType>` in the Rented sub-branches, with `recipient == tx_context::sender(ctx)`. No event emitted. |
| `burn(receipt)` | `public` | Voluntary destroy for gas recovery. No state mutation. No event emitted. |

No error constants. No events.

**Depends on:** `sui::object`, `sui::transfer`, `std::ascii::String`,
`std::type_name`.


8. OBJECT DISPLAY
-----------------

![PaymentReceipt](../../media/object-display/payment-receipt.png)

`Display<PaymentReceipt>` gives every receipt a visual identity in wallets and
explorers. Created once post-deployment via a PTB presenting `&mut Publisher`
for the package and `&mut DisplayRegistry` (Sui framework shared object at `0xd`).

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

let (mut display, cap) = display_registry::new_with_publisher<PaymentReceipt>(
    registry,   // &mut DisplayRegistry (shared object 0xd)
    publisher,  // &mut Publisher
    ctx,
);
display_registry::set(&mut display, &cap, b"name".to_string(),        b"Payment Receipt".to_string());
display_registry::set(&mut display, &cap, b"description".to_string(), b"Receipt of a rental bid payment of {amount} {coin_type} on asset type {asset_type}. Symbolic — carries no protocol authority.".to_string());
display_registry::set(&mut display, &cap, b"image_url".to_string(),   b"{IMAGE_BASE_URL}/payment-receipt.png".to_string());
display_registry::set(&mut display, &cap, b"project_url".to_string(), b"https://liquidrenting.com".to_string());
display_registry::set(&mut display, &cap, b"creator".to_string(),     b"Liquid Renting Protocol".to_string());
display_registry::share(display);
transfer::public_transfer(cap, ctx.sender());  // cap retained by deployer for future edits
```

One `Display<PaymentReceipt>` per package deployment — enforced by
`DisplayRegistry`. ID is deterministic from `DisplayRegistry` + type — no event
scanning required. The returned `DisplayCap<PaymentReceipt>` is required to
call `set` / `unset` / `clear` later; keeping it with the deployer preserves the
ability to edit the Display post-deployment.

**Status:** [ ] `Display<PaymentReceipt>` created and committed.
