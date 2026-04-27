PAYMENT RECEIPT MODULE — SPECIFICATION
=======================================

Module: `payment_ticket`
Design reference: design-compact.md §1 (state machine — Rented branch of rent()),
  §2 (access model — delivery symmetry)
Module map reference: module-map.spec.md §7
Depends on: nothing (`sui::object`, `sui::transfer`, `std::ascii::String`,
  `std::type_name`)


0. MODULE RESPONSIBILITY
------------------------

`payment_ticket` owns the `PaymentTicket` object type and all operations on
it. The type is a purely symbolic, wallet-side receipt minted at bid time in
the `Rented` branch of `rental_escrow::rent`. It carries **no protocol
authority** and is invisible to every call site outside this module.

**Owns:**
- `PaymentTicket` — `key + store`. One minted per successful bid on an
  escrow in `Rented { HandoverOpen }` or `Rented { HandoverConfirmed }`.
  Holds the escrow identity, the amount paid, and the canonical type
  strings for coin and asset. Transferable by holder — symmetric with
  `TenantCap` and `OwnerCap`; the protocol does not police custody.
- `new<Asset, CoinType>(escrow_id, amount, ctx): PaymentTicket` —
  `public(package)`. Pure constructor. Builds the ticket inline —
  deriving `coin_type` and `asset_type` from the generic parameters via
  `type_name::get<T>().into_string()` — and returns it by value. No
  transfer, no event, no state mutation. Called by
  `rental_escrow::rent<Asset, CoinType>` in both Rented sub-branches,
  after the `E_INSUFFICIENT_PAYMENT` check passes; the bidder is the
  PTB caller (`tx_context::sender(ctx)`), present in the same
  transaction, so `rent` returns the ticket via its
  `Option<PaymentTicket>` slot — the caller decides delivery.
- `burn(receipt)` — `public`. Voluntary destroy by holder for gas recovery.
  No state mutation anywhere. The protocol never forces this.

**Does not own:**
- Any protocol authorization — the receipt is not checked by any call site.
- Any escrow state or fund flows — those live in `rental_escrow`.
- Any event stream — see §3.

**Owns the capture format for generic-type identity.** `new` takes
`<Asset, CoinType>` as generics and derives the canonical type strings
inline via `type_name::get<T>().into_string()`. The struct layout stores
the result, so the decision "how this protocol represents a generic
parameter in a ticket's fields" belongs to `payment_ticket`: any
future evolution of that encoding (hashed form, shortened form,
trailing-null stripping) is one edit here, not an adapter-code edit at
every caller. Generics cross the function boundary at compile time; the
struct itself stays non-generic (see §2).

**Key design properties:**

- **Purely symbolic — zero protocol power.** No `assert_*`, no ID check, no
  staleness, no getter required by any call site. The only way the ticket
  influences the protocol is by existing in a wallet (or in a PTB local)
  at the moment of bid settlement — which is precisely the UX it was
  created for.

- **UX symmetry with the other `rent()` branches.** `rent()` returns
  `(Option<TenantCap>, Option<PaymentTicket>)` in a single uniform
  signature; exactly one slot is `Some` in every non-`Retired` state.
  Every successful `rent()` call now hands the caller an object back —
  the cap when acquiring tenancy directly, the ticket when placing or
  superseding a bid — regardless of the pre-settlement state.

  | State at call | Returned in `rent()` tuple |
  |---|---|
  | `Idle` | `(Some(TenantCap), None)` |
  | `AtDutchAuction` | `(Some(TenantCap), None)` |
  | `Rented { HandoverOpen }` | `(None, Some(PaymentTicket))` |
  | `Rented { HandoverConfirmed }` | `(None, Some(PaymentTicket))` |

- **`key + store` — symmetric with `TenantCap` and `OwnerCap`.** The
  ticket is a first-class Sui object: holders may custody, multisig, or
  transfer it at will. The protocol does not police ownership and the
  ticket does not even *have* protocol authority to revoke. Closing
  transferability at the type level would have been paternalism without
  any defensive payoff — the ticket is never read by any protocol
  function — and would have broken composability for legitimate
  holders. The only protocol-side exit remains `burn`.

- **Self-describing in wallets.** The ticket carries `amount`, `coin_type`
  and `asset_type` as fields so that a wallet or explorer can render it
  fully without consulting an off-chain indexer. `Display<PaymentTicket>`
  interpolates these fields at render time.

- **Non-generic type despite generic origin.** `RentalEscrow<Asset,
  CoinType>` is generic, but `PaymentTicket` is a single concrete type for
  every `(Asset, CoinType)` instantiation. The coin and asset types are
  carried as `String` fields (derived at mint from `type_name::get<T>`) so
  one `Display<PaymentTicket>` registration covers all present and future
  coin/asset combinations — essential for a permissionless protocol where
  integrators choose their own types.

- **Outside the star schema.** The protocol's event layer is a SQL star
  schema anchored on `escrow_id` with paired lifecycle events for every
  child object (`TenantCap*`, `OwnerCap*`, `FeeMessage*`). `PaymentTicket`
  deliberately breaks that pattern — it emits no events. Justification and
  off-chain linkage strategy are detailed in §3.


1. ERROR CONSTANTS
------------------

None. No function in this module has validatable preconditions that require
named abort codes. `new` is a pure constructor with no runtime checks (all
validation — sufficient payment, correct state — happens at the call site
in `rental_escrow::rent`). `burn` is unconditional.


2. TYPE
-------

### PaymentTicket — struct

Symbolic ticket of a rental bid payment. Minted once per successful bid in
a `Rented` state of `rental_escrow::rent`, returned by value to the bidder
in the same transaction via `rent`'s `Option<PaymentTicket>` slot.

```move
use std::ascii::String;

public struct PaymentTicket has key, store {
    id:         UID,
    escrow_id:  ID,
    amount:     u64,
    coin_type:  String,
    asset_type: String,
}
```

**Abilities:** `key + store`.
- `key` — object identity.
- `store` — first-class composability. Enables return-by-value from
  `rental_escrow::rent`, custody, multisig, and any other downstream
  PTB composition. Symmetric with `TenantCap` and `OwnerCap`. The
  ticket carries no protocol authority (no function reads it), so
  making it transferable adds no risk surface to the protocol. The
  only protocol-side exit remains `burn`; movement between addresses
  is off-protocol.

**Fields:**

| Field | Type | Meaning |
|---|---|---|
| `id` | `UID` | Object identity. |
| `escrow_id` | `ID` | ID of the `RentalEscrow` the bid was placed on. |
| `amount` | `u64` | Payment amount in base units of `CoinType`, captured at mint. Equal to `coin::value(&payment)` at the call site. |
| `coin_type` | `String` | Canonical type string of `CoinType`, derived inside `new` via `type_name::get<CoinType>().into_string()`. Example: `"0000…0002::sui::SUI"`. |
| `asset_type` | `String` | Canonical type string of `Asset`, derived inside `new` via `type_name::get<Asset>().into_string()`. |

**Why non-generic despite generic origin:**

A generic `PaymentTicket<phantom Asset, phantom CoinType>` would encode the
types in the object's type tag at zero on-chain cost — but it would force
one `Display<PaymentTicket<A, C>>` registration per `(Asset, CoinType)`
pair. The protocol is permissionless: any integrator chooses their own
`Asset` and `CoinType` at `integrate` time, so the set of live
instantiations is unbounded and not known post-deployment. Pre-registering
Display for every possible combination is infeasible.

Storing the canonical type strings as fields shifts a few dozen bytes
on-chain per object in exchange for a **single `Display<PaymentTicket>`
registration** that covers every present and future instantiation via
template field interpolation. This is the scalable trade-off.

**Generic function, non-generic struct.** `new<Asset, CoinType>`
takes the two generics at its boundary and derives the canonical strings
inline (see §4); the struct itself carries no type parameters. Generics
live at the function boundary — compile-time, monomorphized away — while
concrete `String` fields live on the object, supporting the single
global `Display<PaymentTicket>` registration above.

**No identity check anywhere.** Unlike `TenantCap`, which is compared by ID
against `escrow.current_tenant_cap_id` to enforce staleness, a
`PaymentTicket` is never presented back to the protocol. The only consumer
is the wallet / explorer displaying the object.


3. EVENTS
---------

**This module emits no events.** The decision is deliberate — not an
omission — and is documented here so that a reader familiar with the
protocol's star-schema convention does not interpret the absence as a bug.

**Why no `PaymentTicketMinted` event:**

Every `PaymentTicket` mint happens inside `rental_escrow::rent` in a
`Rented` sub-branch, in 1:1 correspondence with exactly one of two existing
state-machine events:

| Sub-branch | Co-emitted event (already specified in `rental_escrow`) |
|---|---|
| `Rented { HandoverOpen }` (first bid, opens `HandoverConfirmed`) | `BidPlaced { escrow_id, pending_tenant, bid_amount, handover_countdown_expiry }` |
| `Rented { HandoverConfirmed }` (supersede) | `BidSuperseded { escrow_id, displaced_bidder, refunded_amount, new_bidder, new_bid_amount }` |

Both events already carry `escrow_id` and the bidder's address, in the same
transaction as the receipt's mint. An off-chain indexer watching Sui's
object-creation envelope sees the new `PaymentTicket` object and can link
it back to its originating bid by the tuple `(escrow_id, bidder_address,
tx_sequence)` — unambiguous per transaction. No extra Move-level event is
needed to preserve this linkage.

**Why no `PaymentTicketBurned` event:**

`burn` is voluntary, driven entirely by the holder's gas-recovery decision.
The protocol does not depend on burn timing, and the receipt carries no
authority whose revocation could be meaningful. A `PaymentTicketBurned`
row would contribute zero analytical value — the burn is purely a wallet
hygiene event, equivalent to deleting any other owned object in the user's
wallet.

**Deliberate exclusion from the star schema:**

The star schema's invariant — every child-object type has paired
create/destroy events joined on the object's own ID — applies to dimensions
that the indexer materializes as first-class analytical tables
(`owner_cap`, `tenant_cap`, `fee_message`). `PaymentTicket` is **not** a
dimension in that schema: it is a client-side collectible whose purpose is
the wallet UX of the bidder, not the accountant's ledger. Treating it as a
schema dimension would add storage and indexing overhead for a table whose
rows replicate information already present in `BidPlaced` /
`BidSuperseded`.

Any indexer that still wishes to track receipts per wallet can do so by
reading Sui's object-creation envelope filtered by the
`PaymentTicket` type tag — no protocol-level event support required.


4. FUNCTIONS
------------

### `new`

    public(package) fun new<Asset, CoinType>(
        escrow_id: ID,
        amount:    u64,
        ctx:       &mut TxContext,
    ): PaymentTicket

**Visibility:** `public(package)` — callable only by `rental_escrow`.

**Purpose:** pure constructor. Derives the two canonical type strings
from the generics in scope, constructs a `PaymentTicket`, returns it by
value. No transfer, no event, no state mutation. The caller has
validated the payment (`E_INSUFFICIENT_PAYMENT`) and captured `amount =
coin::value(&payment)` before consuming the coin; the two generics
propagate from the surrounding `rental_escrow::rent<Asset, CoinType>`
call.

**Behavior:**
1. Construct inline, deriving the two type strings from the generics:
   ```
   let ticket = PaymentTicket {
       id: object::new(ctx),
       escrow_id,
       amount,
       coin_type:  type_name::get<CoinType>().into_string(),
       asset_type: type_name::get<Asset>().into_string(),
   };
   ```
2. Return `ticket`.

That is the entire body. No events, no transfer, no mutation of any
shared state.

**Why no transfer here:** the bidder is the PTB caller of `rent` —
present in the same transaction. `rent` returns the ticket via its
`Option<PaymentTicket>` slot and the PTB caller routes it to its
destination (own wallet, multisig, immediate burn, further
composition). Under `key + store` the type-system constraint that
forced a fused mint+push in the previous design no longer applies:
`transfer::public_transfer` works from any module, and in this
specific case no push is needed at all because the recipient is the
caller.

**Call sites:** `rental_escrow::rent<Asset, CoinType>`, in both
`Rented { HandoverOpen }` and `Rented { HandoverConfirmed }`
sub-branches, after the `E_INSUFFICIENT_PAYMENT` check. The two
generics forward from `rent`'s own parameters; `rent` then surfaces
the ticket in the second slot of its `(Option<TenantCap>,
Option<PaymentTicket>)` return tuple. No other call site exists or
will exist.

---

### `burn`

    public fun burn(receipt: PaymentTicket)

**Visibility:** `public` — callable by any holder.

**Purpose:** voluntary destruction of a `PaymentTicket` for gas recovery.
No effect on any escrow, any cap, or any fund balance.

**Behavior:**
1. Destructure: `let PaymentTicket { id, escrow_id: _, amount: _,
   coin_type: _, asset_type: _ } = receipt;`
2. `object::delete(id);`

No `ctx` argument — there is no event to emit and the module has no need
to read `tx_context::sender`.

**No state mutation anywhere.** The escrow is not notified, no cap becomes
stale, no fund moves. The object simply ceases to exist.


5. PROPERTIES
-------------

**P1 — Minted only at successful bids in Rented states:**
    `new` is `public(package)` and called exclusively from
    `rental_escrow::rent` in the two `Rented` sub-branches, after
    `E_INSUFFICIENT_PAYMENT` has passed. No other path creates a
    `PaymentTicket`. 1:1 correspondence with `BidPlaced` /
    `BidSuperseded`.

**P2 — Transferable by holder, no protocol-side restriction:**
    `key + store`. Holders may custody, multisig, or transfer the
    ticket at will. The protocol does not police ownership and the
    ticket carries no protocol authority that would be sensitive to
    transfer (no function reads it). The only protocol-side exit is
    `burn`. Symmetric with `TenantCap` and `OwnerCap`.

**P3 — Zero protocol power:**
    No function in any module of the protocol reads, mutates, or checks a
    `PaymentTicket`. Presenting one has no effect. Losing one has no
    effect. The object exists solely for the wallet-side UX of the
    bidder.

**P4 — Self-describing in wallets:**
    Every `PaymentTicket` carries `amount`, `coin_type` and `asset_type`
    as fields. `Display<PaymentTicket>` renders them via template
    interpolation. A wallet or explorer can present the receipt fully
    without consulting any indexer.

**P5 — One `Display` registration covers all instantiations:**
    The type is non-generic, so a single post-deployment PTB presenting
    `&Publisher` and `&mut DisplayRegistry` registers
    `Display<PaymentTicket>` for every present and future `(Asset,
    CoinType)` pair.

**P6 — `burn` has no side-effects anywhere:**
    Destroying a receipt affects only the receipt itself. No escrow field
    changes, no cap becomes stale, no fund moves.


6. TEST CASES
-------------

### 6.0 Test strategy

**Test module.** `#[test_only] module liquid_renting::payment_ticket_tests`.
Function names describe the asserted behaviour (e.g.
`new_derives_canonical_type_strings`,
`new_emits_no_events`, `burn_leaves_no_trace`).

**Idioms.**

- `new` is a pure constructor: it allocates a `UID` (via `object::new`)
  and returns the ticket by value. Tests can keep the returned ticket
  as a local and inspect it directly, or call
  `transfer::public_transfer(ticket, addr)` from the test body to
  exercise the downstream custody flow. Both forms run in
  `sui::test_scenario` because `object::new` requires a real
  `TxContext` and tx effects.
- Each row translates to one `#[test]` function. `payment_ticket`
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
`new<Asset, CoinType>` — they exist solely so `type_name::get<T>`
has concrete types to resolve. Their fully-qualified strings are fixed
at compile time and used as expected values. Escrow IDs use
`object::id_from_address(@0xE5C1)` / `@0xE5C2` literals.

**Test-only helpers.**

```
#[test_only] public fun ticket_fields_for_testing(
    ticket: &PaymentTicket): (ID, u64, String, String)
```

Exposes the private struct fields (escrow_id, amount, coin_type,
asset_type) so rows can assert each individually. `new` is
`public(package)`; `burn` is `public`; no wrappers needed for them.

**Expected type-string form.** `type_name::get<T>().into_string()`
yields `"<pkg_address>::<module>::<type_name>"` with full hex-padded
package address (64 hex chars). Rows express expected values as the
literal string for the test module's package. The helper
`expected_type_string<T>()` wraps the Sui framework call so tests do
not duplicate the exact literal — `assert_eq!(receipt.coin_type,
expected_type_string<TestCoinA>())`.


### 6.1 `new`

| # | Description | Expected |
|---|---|---|
| N1 | `let ticket = new<TestAssetA, TestCoinA>(escrow_id = @0xE5C1, amount = 1_000, ctx)`; inspect locally without transferring | `ticket_fields_for_testing(&ticket) == (@0xE5C1, 1_000, expected_type_string<TestCoinA>(), expected_type_string<TestAssetA>())`. Fresh UID (non-zero). `num_user_events == 0`. The ticket is consumed by an in-test `burn(ticket)` to satisfy the `key`-without-`drop` consume requirement. |
| N2 | Two `new<TestAssetA, TestCoinA>` calls with identical inputs in one tx | Two distinct ticket locals with distinct UIDs. All non-UID fields identical between the two. `num_user_events == 0`. |
| N3 | `new<TestAssetA, TestCoinA>(@0xE5C1, 100, ctx)` and `new<TestAssetB, TestCoinB>(@0xE5C2, 200, ctx)` in one tx | Two locals. ticket0: `(escrow_id=@0xE5C1, amount=100, coin_type=type_str<TestCoinA>, asset_type=type_str<TestAssetA>)`. ticket1: `(@0xE5C2, 200, type_str<TestCoinB>, type_str<TestAssetB>)`. Asserts type strings are **derived inside `new` from the generic parameters**, not supplied by the caller — the module owns the capture format. |
| N4 | `let ticket = new<TestAssetA, TestCoinA>(escrow_id, amount, ctx); transfer::public_transfer(ticket, BOB)` from the test body | Next tx retrieves the ticket from BOB's account. Asserts the ticket is `store`-transferable from outside this module — the same capability `rent`'s caller exercises if it wants to deliver the ticket somewhere other than its own wallet. |
| N5 | `new<TestAssetA, TestCoinA>(escrow_id, amount = 0, ctx)` | Local ticket with `amount == 0`. No abort. Documents that `payment_ticket` does not filter zero amounts — the `E_INSUFFICIENT_PAYMENT` check lives in `rental_escrow::rent` upstream. Under the current rental_escrow contract this path is unreachable in production (the gate ensures `amount > 0` before the call), but the module's own contract is permissive. |
| N6 | `new<TestAssetA, TestCoinA>(escrow_id, amount = u64::MAX, ctx)` | Local ticket with `amount == u64::MAX`. No overflow — the field is a plain u64 assignment. Asserts the boundary at u64 max. |
| N7 | `new<TestAssetA, TestCoinA>(escrow_id = @0x0, amount = 1, ctx)` | Local ticket with `escrow_id == @0x0`. No abort. Symmetric with `tenant_cap` N6 — tickets carry whatever ID the caller passes; rental_escrow is the source of non-zero live IDs. |
| N8 | **Type-string derivation fidelity.** `new<TestAssetA, TestCoinA>` then `new<TestCoinA, TestAssetA>` (generics swapped) | Both tickets created. ticket0.asset_type = type_str<TestAssetA>, ticket0.coin_type = type_str<TestCoinA>. ticket1.asset_type = type_str<TestCoinA>, ticket1.coin_type = type_str<TestAssetA>. Asserts the two generic slots are wired to the correct fields — not swapped in the constructor body. |
| N9 | **No-event invariant.** `new` emits nothing; the test body verifies `num_user_events == 0` directly after the call. | Distinguishes payment_ticket from cap modules: §3's "outside the star schema" is a testable invariant, not just a design note. The co-emission with `BidPlaced` / `BidSuperseded` happens at the `rental_escrow` call site, verified in rental_escrow tests. |
| **[new] N10** | **One-shot lifecycle.** Single call: `let ticket = new(...); burn(ticket);` in the same tx, no transfer in between | Mirrors the "tenant-as-code" PTB pattern where `rent` returns the ticket and the same PTB consumes it (e.g., to ignore the ticket entirely and free the gas immediately). `num_user_events == 0`. Documents return-by-value composition at the module level. |

### 6.2 `burn`

| # | Description | Expected |
|---|---|---|
| B1 | `let ticket = new(...); burn(ticket);` in the same tx | UID deleted. No abort. `num_user_events == 0` over the tx. No escrow or cap state change anywhere (not checkable at this module level — no escrow in scope; **P6** is structural). |
| B2 | `burn` consumes by value | Compile-time enforcement — a second `burn(ticket)` would fail to compile. Not a runtime row; verified by the successful build of L1. Listed for completeness. |
| B3 | `burn` on a ticket minted with distinct generics (`<TestAssetB, TestCoinB>`) | Identical behaviour to B1. Asserts burn is generic-agnostic — the struct is non-generic and `burn` takes no type parameters. `num_user_events == 0`. |
| B4 | `burn` on a ticket with `amount == 0` (via N5 setup) | Identical behaviour. Burn does not inspect field values. |
| B5 | `burn` on a ticket with `escrow_id == @0x0` (via N7 setup) | Identical behaviour. Symmetric with N7. |
| **[new] B6** | `burn` on a ticket that has been transferred between addresses (mint as local → `public_transfer` to BOB → next tx BOB takes and burns) | Identical behaviour. Burn does not inspect provenance — any holder can call it. Documents **P2** under transfers: ownership flow is invisible to the protocol. |

### 6.3 Lifecycle

| # | Description | Expected |
|---|---|---|
| L1 | tx1: `let ticket = new(...); transfer::public_transfer(ticket, ALICE);`. tx2: ALICE retrieves ticket and calls `burn(ticket)`. | Full multi-tx lifecycle (mirrors the production flow where `rent` returns the ticket and the PTB caller routes it to its own wallet for later burn). `tx1.num_user_events == 0`, `tx2.num_user_events == 0`. Ticket gone after tx2. |
| L2 | tx1: three `new` calls with varying generics (`<AssetA,CoinA>`, `<AssetA,CoinB>`, `<AssetB,CoinA>`); push all three to ALICE. tx2: ALICE burns all three. | tx1: three distinct tickets in ALICE's account. tx2: three `burn` calls succeed; all tickets gone. `num_user_events == 0` across both txs. Asserts lifecycle independence across generic instantiations — each ticket tracks its own `(asset_type, coin_type)` pair and burns independently. |
| L3 | `let ticket = new(...);` then call `ticket_fields_for_testing(&ticket)` five times; then `burn(ticket)` — all in one tx | All five getter calls return the same tuple. `burn` succeeds. Asserts the ticket is inspectable without mutation (no field is consumed by reading) — the wallet/explorer Display rendering pattern. |
| **[new] L4** | **Return-by-value composition.** A test wrapper function returns a `PaymentTicket` produced by `new` (proves the type can cross function boundaries by value). Caller test then burns it. | Compiles and runs. Documents that `PaymentTicket : store` allows the value to be threaded through arbitrary call frames — the same guarantee `rental_escrow::rent` relies on to surface the ticket through its `Option<PaymentTicket>` slot. |

**[new] [property] P-NE — no-event invariant.** Every row above
asserts `num_user_events == 0` on every tx that calls `new` or
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

- **Zero-amount / zero-ID tolerance (N5, N7).** Module is permissive.
  If policy later requires rejection, decide whether guards live here
  (costs §1's "no aborts" posture, breaks §3's "no events" via abort
  codes) or stay at `rental_escrow::rent`. Current stance: keep the
  ticket permissive; upstream guarantees non-zero values.
- **Type-string literal form (N1, N8).** The exact string returned by
  `type_name::get<T>().into_string()` depends on the Sui framework
  version's formatting (leading `0x`, hex padding, generic parameter
  encoding). Rows reference `expected_type_string<T>()` helper to
  avoid pinning to a literal that could drift. Confirm the helper's
  semantics match framework behaviour at implementation time.
- **Transfer to `@0x0` (downstream of `new`).** `new` no longer
  performs any transfer — under `key + store` the ticket is returned
  by value and the caller decides delivery. A caller could still call
  `transfer::public_transfer(ticket, @0x0)` and create an
  inaccessible object. `payment_ticket` does not guard against this;
  the ticket carries no protocol authority, so a lost ticket is a
  lost UX artifact, not a protocol-state risk. Flag during
  `rental_escrow` audit that `rent`'s receiver is always
  `tx_context::sender(ctx)`, validated non-zero at the VM level.
- **Fidelity of `ticket_fields_for_testing`.** This `#[test_only]`
  helper exposes private fields. Its signature must stay in sync with
  the struct definition — if a future field is added to
  `PaymentTicket`, update the helper return type and every row that
  destructures its output. Flag as a maintenance obligation on the
  Display-adding PR, not a current gap.


7. MODULE BOUNDARY
------------------

`payment_ticket.move` exports:

| Symbol | Visibility | Notes |
|---|---|---|
| `PaymentTicket` (type) | `public` | `key + store`. Symmetric with `TenantCap` and `OwnerCap`. Symbolic — carries no protocol authority. |
| `new<Asset, CoinType>(escrow_id, amount, ctx): PaymentTicket` | `public(package)` | Pure constructor. Derives `coin_type` / `asset_type` from the generics via `type_name::get<T>().into_string()`, constructs the ticket, returns it by value. No transfer, no event, no state mutation. Called only by `rental_escrow::rent<Asset, CoinType>` in the Rented sub-branches; the ticket is surfaced to the bidder through `rent`'s `Option<PaymentTicket>` return slot. |
| `burn(ticket)` | `public` | Voluntary destroy for gas recovery. No state mutation. No event emitted. |

No error constants. No events.

**Depends on:** `sui::object`, `std::ascii::String`, `std::type_name`.
(No `sui::transfer` dependency — `new` does not transfer; downstream
delivery happens at the call site in `rental_escrow` or in the PTB
caller.)


8. OBJECT DISPLAY
-----------------

![PaymentTicket](../../media/object-display/payment-receipt.png)

`Display<PaymentTicket>` gives every receipt a visual identity in wallets and
explorers. Created once post-deployment via a PTB presenting `&mut Publisher`
for the package and `&mut DisplayRegistry` (Sui framework shared object at `0xd`).

**One registration covers all instantiations.** Because `PaymentTicket` is
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

let (mut display, cap) = display_registry::new_with_publisher<PaymentTicket>(
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

One `Display<PaymentTicket>` per package deployment — enforced by
`DisplayRegistry`. ID is deterministic from `DisplayRegistry` + type — no event
scanning required. The returned `DisplayCap<PaymentTicket>` is required to
call `set` / `unset` / `clear` later; keeping it with the deployer preserves the
ability to edit the Display post-deployment.

**Status:** [ ] `Display<PaymentTicket>` created and committed.
