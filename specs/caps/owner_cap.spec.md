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
- `new(escrow_id, owner, ctx): OwnerCap` — `public(package)`. Mint.
  Called only by `rental_escrow::integrate`. `owner` is the recipient
  address, recorded in the `OwnerCapMinted` event.
- `burn(cap, owner)` — `public(package)`. Destroy. Called only by
  `rental_escrow::claim_asset`. `owner` is the cap holder at burn time
  (typically `tx_context::sender(ctx)` hoisted at the call site),
  recorded in the `OwnerCapBurned` event.
- `escrow_id(cap): ID` — `public`. Getter. Used by `rental_escrow`
  to read the cap's bound escrow and compare inline against the
  target escrow's ID (escrow-match gating for `retire`,
  `claim_asset`, `withdraw_earnings`). The abort on mismatch lives
  in `rental_escrow` — that is where the gate's semantic
  interpretation ("this cap does not authorize operations on this
  escrow") belongs.
- Lifecycle events: `OwnerCapMinted`, `OwnerCapBurned`. Emitted from
  inside this module (Sui Verifier requires the emitted type to be
  internal to the emitting module).

**Does not own:**
- Any escrow state or fund balances — those live in `RentalEscrow`.
- Tracking of the cap holder — the protocol is cap-holder-agnostic.

**Key design properties:**
- `key + store`: transferable and composable. `store` is chosen for
  operational composability — custody, multisig, secondary markets —
  all of which require wrapping the cap inside external objects.
  Integrability as an `Asset` in another escrow is an emergent
  consequence of the same abilities, not an independent goal. The
  ownership-chain opacity this introduces is inherent to any
  `key + store` object in Sui and is no worse than the opacity of
  the rented asset itself.
- Mutual exclusivity: `OwnerCap` exists ↔ the underlying asset is held
  in its `RentalEscrow`. `burn` is called atomically with asset
  extraction in `claim_asset` — no `OwnerCap` outlives its escrow.
- Authorization is cap-based, not address-based. `rental_escrow`
  compares `cap.escrow_id` (via the public getter) to the target
  escrow's ID rather than checking `tx_context::sender`. The
  abort code for the mismatch lives in `rental_escrow`, not here —
  this module exposes the binding as data and lets the consumer
  define what "wrong escrow" means for its own operations.


1. ERROR CONSTANTS
------------------

None. `owner_cap` has no abort sites: `new` and `burn` are
unconditional, `escrow_id` is a pure getter. The escrow-match check
that used to abort here lives in `rental_escrow` as an inline
assert with a rental-side constant (`E_WRONG_ESCROW_OWNER_CAP`),
because the semantic of "wrong escrow" is the consumer's
interpretation of an ID mismatch, not a cap-intrinsic property.


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
- `key` — object identity. Required for `transfer::transfer` at mint.
- `store` — composability with external objects: custody, multisig,
  secondary markets. As a side effect, satisfies the `Asset: key +
  store` bound of `RentalEscrow<Asset, _>` and lets the cap itself
  be rented.

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


3. EVENTS
---------

All events are defined inline and emitted from this module. The Sui
Move event verifier requires the emitted type to be internal to the
calling module — this is why the cap lifecycle events live here rather
than in `rental_escrow`.

```move
public struct OwnerCapMinted has copy, drop {
    owner_cap_id: ID,
    escrow_id:    ID,
    owner:        address,
}

public struct OwnerCapBurned has copy, drop {
    owner_cap_id: ID,
    escrow_id:    ID,
    owner:        address,
}
```

**Sui Verifier constraint:** every event struct has `copy + drop` and
is internal to this module. `event::emit` requires these abilities.

**Field selection:**
- `owner_cap_id` — the `ID` of the cap itself. Primary key for any
  consumer indexing cap objects by identity.
- `escrow_id` — the `ID` of the `RentalEscrow` the cap authorizes. A
  cap has no meaning independent of its escrow; every cap-level
  consumer needs the pair.
- `owner` — the recipient of the cap at mint (passed in by
  `rental_escrow::integrate`, typically `tx_context::sender(ctx)`) and
  the holder presenting the cap at burn (`tx_context::sender(ctx)` in
  `rental_escrow::claim_asset`). Distinct semantics per event but the
  same column name so an indexer can treat the two tables uniformly.

**Design intent — events as SQL rows keyed by `escrow_id`:** the
protocol's event layer is meant to be ingested by an off-chain
indexer into a relational database where `escrow_id` is the natural
primary / foreign key joining cap lifecycle, fee movement, and
escrow state-machine events into a single schema. Each event is a
flat row that must answer natural analytical questions on its own —
*"how many times has address X been owner of escrow Y?"*, *"who held
cap C at burn time?"* — without joining against other modules'
events or against Sui envelope metadata (transfer events, tx
sender). Including `owner` in both Minted and Burned honors this:
`OwnerCap` has `key + store` (it can be wrapped, composed, embedded
as a recursive asset), so the holder at burn may differ from the
recipient at mint — the Burned event captures that distinct fact
rather than forcing the indexer to guess from a chain of transfers.
Downstream, this lets off-chain tooling learn ownership patterns
from the event stream alone.

**No `timestamp_ms` field.** The module has no authoritative time to
report: the call-site wall-clock is not necessarily the logical moment
the event belongs to, and threading `&Clock` would only record call
time. Consumers order events by checkpoint timestamp + tx position,
both of which Sui attaches to the event envelope for free. The module
emits identity and the holder address only.


4. FUNCTIONS
------------

### `new`

    public(package) fun new(
        escrow_id: ID,
        owner:     address,
        ctx:       &mut TxContext,
    ): OwnerCap

**Visibility:** `public(package)` — callable only by `rental_escrow`.

**Purpose:** mints an `OwnerCap` bound to a specific escrow and records
the intended recipient in the event stream.

**Behavior:**
1. Construct `cap = OwnerCap { id: object::new(ctx), escrow_id }`.
2. `let owner_cap_id = object::uid_to_inner(&cap.id);`
3. Emit `OwnerCapMinted { owner_cap_id, escrow_id, owner }`.
4. Return `cap`. The caller (`rental_escrow::integrate`) is responsible
   for delivering it to `owner` — typically via `transfer::transfer(cap,
   owner)` in the same call or further up the PTB. The module does not
   perform the transfer itself; the `owner` argument is a declarative
   annotation for the indexer, not a runtime check.

**Call site:** `rental_escrow::integrate` — once per integration.
Passes `tx_context::sender(ctx)` as `owner` in the typical flow;
custody integrations pass the final beneficiary address.

---

### `burn`

    public(package) fun burn(cap: OwnerCap, owner: address)

**Visibility:** `public(package)` — callable only by `rental_escrow`.

**Purpose:** destroys an `OwnerCap` at retirement, preventing any
further owner-privileged operations on the (now-deleted) escrow.
Records the `owner` argument in the event stream as the holder at burn
time — declarative, like `owner` in `new`.

**Behavior:**
1. Destructure: `let OwnerCap { id, escrow_id } = cap;`.
2. Capture `owner_cap_id = object::uid_to_inner(&id);` — must be read
   before `object::delete` consumes the `UID`.
3. Call `object::delete(id);`.
4. Emit `OwnerCapBurned { owner_cap_id, escrow_id, owner }` — emission
   runs last, after the cap is actually destroyed.

**Signature rationale:** `owner: address` is passed in rather than
derived from `&TxContext` inside the body. The signature advertises
the exact datum the function records — parallel to
`new(escrow_id, owner, ctx)` which also takes `owner` declaratively.
`burn` no longer needs `&TxContext` at all: all it does is consume the
cap, destroy the `UID`, and emit.

**Call site:** `rental_escrow::claim_asset` — once per escrow lifetime,
atomically with asset extraction and escrow deletion. `claim_asset`
gates inline on `owner_cap::escrow_id(&cap) == object::id(&escrow)`
(aborting `rental_escrow::E_WRONG_ESCROW_OWNER_CAP` on mismatch) and
then binds `let owner = tx_context::sender(ctx);` once, passing it
to `burn`. Since the cap is presented by value and the escrow is
deleted in the same call, `owner` at this boundary is the legitimate
holder at burn time; since `OwnerCap` has `key + store`, that may
differ from the mint-time recipient recorded in `OwnerCapMinted`.

---

### `escrow_id`

    public fun escrow_id(cap: &OwnerCap): ID

**Visibility:** `public` — readable by any caller, including external
integrations that need to know which escrow a cap authorizes.

**Purpose:** returns the `ID` of the `RentalEscrow` this cap was minted
for.

**Behavior:** returns `cap.escrow_id`.

---

5. PROPERTIES
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
    `rental_escrow` gates owner ops on
    `owner_cap::escrow_id(&cap) == object::id(&escrow)` — a pure
    cap-field read compared to the target escrow's ID. The protocol
    does not record or check the address of whoever holds the cap.
    Transferring the cap transfers authority unconditionally.

**P4 — Composability with operational intent:**
    `store` is chosen for custody, multisig, and secondary-market
    composition. Recursive integration as an `Asset` in another escrow
    is an emergent consequence of `key + store`, not an independent
    goal. `rental_escrow::integrate` imposes no restriction on this
    composition.

**P5 — No zero-state objects:**
    Every `OwnerCap` has a non-zero `escrow_id` (set at mint from a
    live `RentalEscrow` UID). `burn` deletes the object entirely —
    no inert shells remain.


6. TEST CASES
-------------

### 6.0 Test strategy

**Test module.** `#[test_only] module liquid_renting::owner_cap_tests`.
Function names describe the asserted behaviour (e.g.
`new_emits_minted_with_declared_owner`,
`burn_emits_burned_with_holder_address`).

**Idioms.**

- `owner_cap` creates real Sui objects (UIDs) and emits events, so every
  test runs in `sui::test_scenario`. No `tx_context::dummy()` path.
- Each row translates to one `#[test]` function. `owner_cap` has **no
  abort sites** (§1), so no `#[expected_failure]` rows. `burn`'s
  by-value consumption is verified at compile time by the successful
  build of the lifecycle test — no runtime assertion exists.
- Event-count assertions use `test_scenario::num_user_events(&effects)`;
  payload assertions use a typed capture helper (below).

**Fixtures.** Canonical actor addresses:

```
const ALICE: address = @0xA11CE;   // typical minter / sender
const BOB:   address = @0xB0B;     // custody / burn-time holder
const ZERO:  address = @0x0;       // zero-address boundary
```

Every row names the address it uses rather than relying on a default
sender. Escrow IDs come from `object::id_from_address(@0xE5C1)` and
`@0xE5C2` — literal placeholders that bind a cap to a non-zero but
non-live ID (sufficient for this module, since `owner_cap` never
dereferences the escrow).

**Test-only helpers.** The test module declares the roster:

```
#[test_only] public fun capture_minted(
    effects: &TransactionEffects): vector<OwnerCapMinted>
#[test_only] public fun capture_burned(
    effects: &TransactionEffects): vector<OwnerCapBurned>
```

Both wrap `event::events_by_type<T>()`. No `#[test_only]` wrappers over
`new`/`burn` are needed: both are `public(package)`, and the test module
lives in the same package.

**Star-schema assertion shape.** Per the project-wide convention (memory
`feedback_events_self_describing`), every event row additionally
asserts:
1. `escrow_id` is present and equals the value passed to `new` / the
   value stored in the cap at `burn`.
2. `owner_cap_id` equals `object::id(&cap)` — child PK.
3. `owner` equals the argument passed (declarative field, not a runtime
   derivation from sender).
These three checks are bundled into a `#[test_only]` predicate
`assert_star_schema_minted(&event, expected_cap_id, expected_escrow_id,
expected_owner)` and mirrored for burned.


### 6.1 `new`

| # | Description | Expected |
|---|---|---|
| N1 | `new(escrow_id = @0xE5C1, owner = ALICE, ctx)` in tx by ALICE | Returns `OwnerCap` with `cap.escrow_id == @0xE5C1`. Object has a fresh UID. `num_user_events == 1`. One `OwnerCapMinted { owner_cap_id, escrow_id, owner }` event: `owner_cap_id == object::id(&cap)`, `escrow_id == @0xE5C1`, `owner == ALICE`. Star-schema predicate passes. |
| N2 | Two calls within one tx with distinct `escrow_id`s (`@0xE5C1`, `@0xE5C2`) and distinct owners (ALICE, BOB) | Two distinct `OwnerCap` objects with distinct UIDs, each bound to its own `escrow_id`. `num_user_events == 2`. The two `OwnerCapMinted` events appear in call order; event[0] carries (`cap0.id`, `@0xE5C1`, ALICE), event[1] carries (`cap1.id`, `@0xE5C2`, BOB). |
| N3 | `new` called by sender ALICE passing `owner = BOB` (custody integration) | Event `owner == BOB`, not ALICE. Asserts the field is declarative, not a runtime echo of `tx_context::sender(ctx)`. |
| **[new] N4** | `new(escrow_id = @0xE5C1, owner = ZERO, ctx)` | Event `owner == @0x0`. `owner_cap` imposes no non-zero-address constraint — zero address is legal at this layer (policy lives upstream in `rental_escrow::integrate` if needed). Documents current behaviour; flag in Open questions if a future zero-address filter is desired. |
| **[new] N5** | `new` called with `escrow_id == @0x0` (zero ID) | Event `escrow_id == @0x0`. Asserts **P5** violation is the caller's problem — `owner_cap::new` does not validate the ID is non-zero (per §0 "cap-holder-agnostic", the cap is a passive container). Document in Open questions; `rental_escrow::integrate` is the site that sources non-zero IDs from `object::uid_to_inner`. |
| **[new] N6** | Three consecutive `new` calls in one tx with (`@0xE5C1`, ALICE), (`@0xE5C2`, ALICE), (`@0xE5C1`, BOB) — note the first and third share `escrow_id` | `num_user_events == 3`. Caps have three distinct UIDs. Asserts **P1** is a *structural* guarantee at the `rental_escrow::integrate` call site, not a runtime check here: this module accepts two `new` calls for the same `escrow_id` without aborting. Cross-references §5 P1 note. |

### 6.2 `burn`

| # | Description | Expected |
|---|---|---|
| B1 | Mint cap with `owner = ALICE`; in next tx call `burn(cap, ALICE)` | Cap's UID deleted (`test_scenario::has_most_recent_for_address<OwnerCap>(ALICE) == false` after the burn tx). `num_user_events == 1` in the burn tx. One `OwnerCapBurned { owner_cap_id, escrow_id, owner }` with `(owner_cap_id, escrow_id)` the cap carried and `owner == ALICE`. |
| B2 | `burn` consumes the cap (by value) | Compile-time enforcement — a double-`burn(cap, ALICE)` call would fail to compile. Not a runtime row; verified by the successful build of L1. Listed for completeness. |
| B3 | Cap minted with `owner = ALICE`, transferred to BOB, burned with `burn(cap, BOB)` in BOB's tx | Event's `owner == BOB`, not ALICE. Asserts Burned captures the **burn-time** declared holder, distinct from Minted's recipient. Combined with N1 (mint event for the same cap earlier in the scenario), the indexer can reconstruct the (minter, burner) pair by joining on `owner_cap_id`. |
| **[new] B4** | Burn called by sender ALICE passing `owner = BOB` (caller lies about the holder) | Event `owner == BOB`. Asserts the field is declarative — `owner_cap::burn` does not derive or check against `tx_context::sender(ctx)` (the signature no longer takes `ctx` at all, per refactor 1 in the .note). This is the legitimate mechanism that enables custody patterns; it is also the reason `owner` in Burned is "the holder as declared by the caller", not "the holder as proven on-chain". Document in Open questions. |
| **[new] B5** | Burn a cap whose `escrow_id` is `@0x0` (constructed via N5 fixture) | Event `escrow_id == @0x0`. Symmetric with N5 — the burn path makes no stronger claim about `escrow_id` validity than the mint path. |

### 6.3 `escrow_id`

| # | Description | Expected |
|---|---|---|
| G1 | `escrow_id(&cap)` after `new(@0xE5C1, ALICE, ctx)` | Returns `@0xE5C1`. |
| **[new] G2** | Call `escrow_id(&cap)` five times in a row on the same cap | All five calls return the same `ID`. Asserts the getter is pure (no mutation, no side effect, no event emission). Encoded as a loop predicate inside one `#[test]`. |
| **[new] G3** | `escrow_id(&cap)` where `cap.escrow_id == @0x0` (via N5) | Returns `@0x0`. The getter does not filter zero IDs; P5 is a construction-side guarantee in `rental_escrow::integrate`, not a getter contract. |

### 6.4 Lifecycle

| # | Description | Expected |
|---|---|---|
| L1 | `new(@0xE5C1, ALICE, ctx)` (tx1) → `burn(cap, ALICE)` (tx2) | Full lifecycle completes. `tx1.num_user_events == 1`, `tx2.num_user_events == 1`. `OwnerCapMinted` in tx1 and `OwnerCapBurned` in tx2 both carry the same `(owner_cap_id, escrow_id)` pair. `owner` fields reflect the declared mint recipient (ALICE) and the burn-time argument (ALICE). |
| **[new] L2** | `new(@0xE5C1, ALICE, ctx)` → transfer cap to BOB → `burn(cap, BOB)` in BOB's tx | Three txs. Events: one `OwnerCapMinted` with `owner == ALICE` and one `OwnerCapBurned` with `owner == BOB`. Both carry the same `(owner_cap_id, @0xE5C1)`. Asserts the full custody-handoff pattern end-to-end — the PK-JOIN path `OwnerCapMinted.owner_cap_id = OwnerCapBurned.owner_cap_id` recovers the mint/burn pair for an indexer. |
| **[new] L3** | Mint two caps for different escrows in one tx; burn them both in the next tx in reversed order | tx1 emits two Minted events in mint order; tx2 emits two Burned events in burn order. The cap1-mint/cap1-burn and cap2-mint/cap2-burn pairs each share `owner_cap_id`, proving the cap lifecycle is independent per object even when batched. |

**[new] [property] P-SE — star-schema envelope invariants.** For every
row above that asserts an event:
1. `escrow_id` field is present in the payload and equal to the value
   recorded at mint (Minted) or stored in the cap at burn (Burned).
2. `owner_cap_id` field is present and equal to `object::id(&cap)` —
   the child PK that lets an indexer PK-JOIN Minted and Burned rows.
3. No Sui envelope metadata is relied upon for identity (no use of
   `tx_digest`, sender-of-tx, or transfer events to reconstruct the
   cap lineage). The pair `(owner_cap_id, escrow_id)` alone is
   sufficient to locate the cap across its lifecycle.

Escrow-mismatch abort paths are tested in `rental_escrow` at each call
site (`retire`, `claim_asset`, `withdraw_earnings`) — the predicate is
a one-line inline assert and the abort constant is rental-side;
`owner_cap` itself has no abort to test.


### 6.5 Open questions

- **Zero-address / zero-ID tolerance (N4, N5, B4, B5, G3).** This module
  accepts `owner == @0x0` and `escrow_id == @0x0` without validation.
  The test rows above document current behaviour; if the protocol
  decides zero values should be rejected (either at the cap layer or
  upstream in `rental_escrow::integrate`), revisit these rows and
  consider whether the rejection belongs here (adds an error constant,
  violating §1's "no aborts" posture) or stays at the integration call
  site. Current stance: keep the cap permissive; integration upstream
  only ever passes non-zero live IDs.
- **Custody vs caller-truth in Burned (B4).** The caller-declared
  `owner` field in `OwnerCapBurned` can diverge from the transaction
  sender. This is intentional for custody patterns but means an
  indexer cannot treat `owner` as a cryptographically proven
  address — only as the holder as declared by a trusted call site.
  `rental_escrow::claim_asset` hoists `tx_context::sender(ctx)`
  before calling `burn`, so production rows see the true sender; test
  row B4 exercises the escape hatch for documentation. Flag if the SDK
  ever needs a second, sender-proven column.
- **P1 runtime non-enforcement (N6).** `owner_cap::new` does not check
  that an earlier cap with the same `escrow_id` does not already
  exist. `rental_escrow::integrate` is the structural gate (called
  once per escrow construction). Verify during `rental_escrow` audit
  that no path exists to call `owner_cap::new` twice for the same
  escrow; if one does, this module needs a runtime guard and §1 must
  gain an error constant.


7. MODULE BOUNDARY
------------------

`owner_cap.move` exports:

| Symbol | Visibility | Notes |
|---|---|---|
| `OwnerCap` (type) | `public` | `key + store`. One per escrow. Transferable. |
| `OwnerCapMinted` (event) | `public` | `copy + drop`. Emitted by `new`. |
| `OwnerCapBurned` (event) | `public` | `copy + drop`. Emitted by `burn`. |
| `new(escrow_id, owner, ctx): OwnerCap` | `public(package)` | Mint. Called only by `rental_escrow::integrate`. Emits `OwnerCapMinted { owner_cap_id, escrow_id, owner }`. |
| `burn(cap, owner)` | `public(package)` | Destroy. Called only by `rental_escrow::claim_asset`. Emits `OwnerCapBurned { owner_cap_id, escrow_id, owner }` with `owner` from the caller (the binding of `tx_context::sender(ctx)` hoisted at the call site). |
| `escrow_id(cap): ID` | `public` | Getter. Read by `rental_escrow` at each owner-gated entry to compare against the target escrow's ID inline (abort constant lives there). |

**No abort codes exported.** The escrow-match check that used to
live here as `assert_escrow` has moved to `rental_escrow` as an
inline assert with a rental-side constant — the semantic of
"wrong escrow" is the consumer's, not the cap's.

**Depends on:** `sui::object`, `sui::event`.


8. OBJECT DISPLAY
-----------------

![OwnerCap](../../media/object-display/owner-cap.png)

`Display<OwnerCap>` gives every cap a visual identity in wallets and explorers.
Created once post-deployment via a PTB presenting `&mut Publisher` for the
package and `&mut DisplayRegistry` (Sui framework shared object at `0xd`).

### Fields

| Key | Value | Notes |
|---|---|---|
| `name` | `Owner Cap` | Static. |
| `description` | `Grants owner authority over a RentalEscrow. Authorizes withdraw_earnings, retire, and claim_asset. Transferable — whoever holds this cap holds full ownership authority.` | Static. |
| `image_url` | `{IMAGE_BASE_URL}/owner-cap.png` | Hosted URL. Source: `media/object-display/owner-cap.png`. |
| `project_url` | `https://liquidrenting.com` | Static. |
| `creator` | `Liquid Renting Protocol` | Static. |

`{IMAGE_BASE_URL}` is set at deployment time to the protocol's media hosting base URL.

### Creation

```move
use sui::display_registry;

let (mut display, cap) = display_registry::new_with_publisher<OwnerCap>(
    registry,   // &mut DisplayRegistry (shared object 0xd)
    publisher,  // &mut Publisher
    ctx,
);
display_registry::set(&mut display, &cap, b"name".to_string(),        b"Owner Cap".to_string());
display_registry::set(&mut display, &cap, b"description".to_string(), b"Grants owner authority over a RentalEscrow. Authorizes withdraw_earnings, retire, and claim_asset. Transferable — whoever holds this cap holds full ownership authority.".to_string());
display_registry::set(&mut display, &cap, b"image_url".to_string(),   b"{IMAGE_BASE_URL}/owner-cap.png".to_string());
display_registry::set(&mut display, &cap, b"project_url".to_string(), b"https://liquidrenting.com".to_string());
display_registry::set(&mut display, &cap, b"creator".to_string(),     b"Liquid Renting Protocol".to_string());
display_registry::share(display);
transfer::public_transfer(cap, ctx.sender());  // cap retained by deployer for future edits
```

One `Display<OwnerCap>` per package deployment — enforced by `DisplayRegistry`.
ID is deterministic from `DisplayRegistry` + type — no event scanning required.
The returned `DisplayCap<OwnerCap>` is required to call `set` / `unset` / `clear`
later; keeping it with the deployer preserves the ability to edit the Display
post-deployment.

**Status:** [ ] `Display<OwnerCap>` created and committed.
