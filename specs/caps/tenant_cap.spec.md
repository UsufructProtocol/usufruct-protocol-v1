TENANT CAP MODULE — SPECIFICATION
===================================

Module: `tenant_cap`
Design reference: design-compact.md §2 (access model — TenantCap)
Module map reference: module-map.spec.md §6
Depends on: nothing (`sui::object` only)


0. MODULE RESPONSIBILITY
------------------------

`tenant_cap` owns the `TenantCap` object type and all operations on it.

**Owns:**
- `TenantCap` — `key` only. One minted per tenant transition event
  (not per bid). Non-transferable by type. Can become stale after
  displacement — inert, failing the ID check in `rental_escrow`.
- `mint_to(escrow_id, tenant, ctx): ID` — `public(package)`. Fused
  mint + delivery. Constructs the cap, emits `TenantCapMinted`,
  transfers the cap to `tenant`, and returns its `ID` to the caller
  (needed by `rental_escrow` to update `current_tenant_cap_id`).
  Called by `rental_escrow::rent` (from Idle, AtDutchAuction) and by
  `rental_escrow::do_handover` (handover completion). The transfer
  lives inside this module — `rental_escrow` never performs
  `transfer::transfer<TenantCap>`, which the Sui bytecode verifier
  would reject for a `key`-only foreign type.
- `burn(cap)` — `public`. Voluntary destroy by cap holder for gas
  recovery. No state mutation. The protocol never forces this.
  `TenantCapBurned` carries only the cap/escrow identity pair — the
  holder address is recoverable by joining on `tenant_cap_id` against
  the `TenantCapMinted` row (non-transferable by type ⇒ mint-tenant ≡
  burn-tenant).
- `escrow_id(cap): ID` — `public`. Getter. Read by
  `rental_escrow::borrow_asset` to compare inline against the target
  escrow's ID (escrow-match gating). The abort on mismatch
  (`E_WRONG_ESCROW_TENANT_CAP`) and the staleness abort
  (`E_STALE_TENANT_CAP`) both live in `rental_escrow` — "wrong
  escrow" and "stale" are the consumer's semantic interpretations
  of ID mismatches, not cap-intrinsic properties.
- Lifecycle events: `TenantCapMinted`, `TenantCapBurned`. Emitted from
  inside this module (Sui Verifier requires the emitted type to be
  internal to the emitting module).

**Does not own:**
- Staleness enforcement — a stale cap is inert because its ID no longer
  matches `escrow.current_tenant_cap_id`. That check lives in
  `rental_escrow::borrow_asset`, not here.
- Asset access or fund flows — those live in `rental_escrow`.
- `AssetReceipt` — hot potato defined inline in `rental_escrow`.

**Key design properties:**
- `key` only, no `store`: non-transferable at the type level. No
  module-level transfer function exists. The cap can never leave the
  holder's wallet except via `burn`.
  **Deliberate asymmetry with `OwnerCap` (`key + store`):**
  `OwnerCap` is `key + store` because owners need operational
  composability — custody, multisig, secondary markets — and selling
  ownership is a first-class feature.
  `TenantCap` is non-transferable for two compounding reasons:
  1. `current_tenant_address` is registered at mint and has no update
     mechanism. If the cap were transferred externally, `remain_credit`
     would be pushed to the original address — not the new holder.
     Fund flows would be broken by design.
  2. `key + store` would enable a secondary market for caps, including
     stale ones. A seller could list a stale cap as valid; the buyer
     would not discover it until `borrow_asset` rejects it. `key` only
     closes this attack surface at the type level — no secondary market
     is possible. The only path to tenancy is through the protocol:
     paying `next_rent_price` and displacing the current tenant.
- **Lazy minting:** a bid during a Rented state does not mint a cap.
  `rental_escrow` stores `pending_tenant_address` and mints the cap
  only when the bidder actually becomes the current tenant — either at
  `rent()` (Idle, AtDutchAuction) or at handover completion inside
  `do_handover()`.
  This avoids creating an object for every bid: in a competitive
  handover window multiple bidders may supersede each other in rapid
  succession. Minting a cap per bid would produce many short-lived
  objects, each paying creation gas and leaving an orphaned stale cap
  in a wallet that never held actual tenancy. Lazy minting ensures that
  in practice only identities that were current tenant ever hold a cap
  — one object, one tenure, no pollution.
- **Staleness:** at handover, the displaced tenant's cap becomes stale
  — its object ID no longer matches `escrow.current_tenant_cap_id`.
  Stale caps are inert: `borrow_asset` rejects them via the ID check.
  `burn` is the sole exit path, available at the holder's discretion.
- **All TenantCap deliveries are pushes — performed by this module:**
  `rent()` has a single signature across all states. In Rented states
  no cap is minted — returning `Option<TenantCap>` would be required
  for a return-based design, which is inconsistent and awkward.
  Instead, all deliveries happen inside `mint_to`, which internally
  calls `transfer::transfer(cap, tenant)`:
  - `rental_escrow::rent` from Idle/AtDutchAuction calls
    `mint_to(escrow_id, tx_context::sender(ctx), ctx)`.
  - `rental_escrow::do_handover` calls
    `mint_to(escrow_id, pending_tenant_address, ctx)`.
  The caller never holds a `TenantCap` as a local — which is what
  makes the pattern type-safe. `transfer::transfer<TenantCap>` only
  compiles inside this module (the verifier forbids it in any other),
  so `mint_to` is the single physically possible delivery channel.
- **TenantCap as signal:** the cap appearing in the wallet is the
  clearest notification of tenancy. No indexer query or event
  subscription needed.


1. ERROR CONSTANTS
------------------

None. `tenant_cap` has no abort sites: `mint_to` and `burn` are
unconditional, `escrow_id` is a pure getter. The two gating checks
that used to abort here (`assert_escrow`, `assert_current`) lived
only to serve `rental_escrow::borrow_asset`; both have moved to the
call site as inline asserts with rental-local constants
(`E_WRONG_ESCROW_TENANT_CAP`, `E_STALE_TENANT_CAP`). The rationale:
"wrong escrow" and "stale" are the consumer's interpretations of ID
mismatches, not cap-intrinsic properties.


2. TYPE
-------

### TenantCap — struct

Authorization object for tenant-privileged operations (`borrow_asset`)
on a single `RentalEscrow`. Minted at each tenant transition event.
Becomes stale (inert) when the holder is displaced.

```move
public struct TenantCap has key {
    id:        UID,
    escrow_id: ID,
}
```

**Abilities:** `key` only.
- `key` — object identity. Required for `transfer::transfer` inside
  `mint_to` (same module; the verifier rejects `transfer::transfer` of
  a `key`-only type from any other module) and for the ID-based
  staleness check in `rental_escrow`.
- No `store` — non-transferable. Cannot be wrapped or moved by external
  code. The holder's only exit is `burn`.

**Fields:**

| Field | Type | Meaning |
|---|---|---|
| `id` | `UID` | Object identity. Used by `rental_escrow` to check `object::id(cap) == escrow.current_tenant_cap_id`. |
| `escrow_id` | `ID` | ID of the `RentalEscrow` this cap was minted for. |

**Staleness:** a `TenantCap` becomes stale when a handover completes
and `escrow.current_tenant_cap_id` is updated to the new tenant's cap.
The stale cap is not destroyed by the protocol — it remains in the
displaced tenant's wallet, inert. `borrow_asset` rejects it via:
```
object::id(cap) == escrow.current_tenant_cap_id   // fails for stale cap
```

**Multiple live caps per escrow:** at any moment, one current cap
exists plus zero or more stale caps from prior tenants. Only the
current one passes the ID check.


3. EVENTS
---------

All events are defined inline and emitted from this module. The Sui
Move event verifier requires the emitted type to be internal to the
calling module — this is why the cap lifecycle events live here.

```move
public struct TenantCapMinted has copy, drop {
    tenant_cap_id: ID,
    escrow_id:     ID,
    tenant:        address,
}

public struct TenantCapBurned has copy, drop {
    tenant_cap_id: ID,
    escrow_id:     ID,
}
```

**Sui Verifier constraint:** every event struct has `copy + drop` and
is internal to this module. `event::emit` requires these abilities.

**Field selection:**
- `tenant_cap_id` — the `ID` of the cap itself. Primary key for any
  consumer indexing cap objects by identity.
- `escrow_id` — the `ID` of the `RentalEscrow` this cap was minted
  for. A cap has no meaning independent of its escrow; every
  cap-level consumer needs the pair.
- `tenant` — present on `TenantCapMinted` only. Passed by
  `rental_escrow::rent` (= `tx_context::sender(ctx)`) or by
  `do_handover` (= `pending_tenant_address`). Absent on
  `TenantCapBurned`: `TenantCap` is non-transferable (`key` only, no
  `store`), so the burning address equals the mint recipient — fully
  recoverable by joining `TenantCapBurned.tenant_cap_id ↔
  TenantCapMinted.tenant_cap_id`. Storing it twice would duplicate
  information already expressible as a single JOIN.

**Design intent — events as SQL rows keyed by natural PKs:** the
protocol's event layer feeds an off-chain indexer whose schema is
anchored on `escrow_id` as the root foreign key and on each child
object's ID (`tenant_cap_id`, `owner_cap_id`, `fee_message_id`) as a
lifecycle-pair primary key. `TenantCapMinted` and `TenantCapBurned`
share `tenant_cap_id`, so address data lives only where it is
first-observed or where it diverges across events. Here, mint-tenant
≡ burn-tenant by non-transferability, so `tenant` lives on Minted
only. Contrast with `OwnerCap` (`key + store`, transferable): there
the burn-sender may differ from the mint-recipient, so `owner`
appears on both events because each row carries genuinely new
information.

**No `timestamp_ms` field.** The module has no authoritative time to
report: `mint_to` may be called from a lazy-settlement path whose logical
moment is in the past, so `clock.now()` would record settlement time,
not logical time. Consumers order by checkpoint timestamp + tx
position (attached by Sui to the envelope for free). The module emits
identity and the holder address only.


4. FUNCTIONS
------------

### `mint_to`

    public(package) fun mint_to(
        escrow_id: ID,
        tenant:    address,
        ctx:       &mut TxContext,
    ): ID

**Visibility:** `public(package)` — callable only by `rental_escrow`.

**Purpose:** fused mint + delivery. Constructs a `TenantCap` bound to
the given escrow, emits `TenantCapMinted`, transfers the cap to
`tenant`, and returns its `ID` to the caller. The returned `ID` is
consumed by `rental_escrow` to update `escrow.current_tenant_cap_id`;
no caller ever holds the cap itself.

**Behavior:**
1. Construct `let cap = TenantCap { id: object::new(ctx), escrow_id };`.
2. `let tenant_cap_id = object::uid_to_inner(&cap.id);` — bound before
   the transfer consumes `cap`.
3. `transfer::transfer(cap, tenant);`
4. `event::emit(TenantCapMinted { tenant_cap_id, escrow_id, tenant });`
   — emit-last, after the cap has both been constructed and delivered.
5. Return `tenant_cap_id`.

The `tenant` field is not stored on the `TenantCap` struct — the cap
is non-transferable by type so a stored field would be redundant; the
event row is the sole record of the mint recipient.

**Why the transfer lives here, not in the caller:** the Sui bytecode
verifier enforces that `transfer::transfer<T>` for a `key`-only type
`T` can only appear inside the module that defines `T`. A
`rental_escrow`-side `transfer::transfer(cap, tenant)` would fail to
compile. The fused form is the only working shape; any future call
site must route through `mint_to`.

**Call sites:**
- `rental_escrow::rent` (from Idle, AtDutchAuction) — passes
  `tx_context::sender(ctx)` as `tenant`; `mint_to` transfers the cap
  internally. Caller stores the returned `ID` in
  `escrow.current_tenant_cap_id`.
- `rental_escrow::do_handover` — passes `pending_tenant_address` as
  `tenant`; `mint_to` transfers the cap internally. Caller stores the
  returned `ID` in `escrow.current_tenant_cap_id`.

---

### `burn`

    public fun burn(cap: TenantCap)

**Visibility:** `public` — callable by any holder (current or displaced
tenant).

**Purpose:** voluntary destruction of a `TenantCap` for gas recovery.
Serves both current tenants (end of use) and displaced tenants (stale
cap cleanup). Has no effect on escrow state.

**Behavior:**
1. Destructure: `let TenantCap { id, escrow_id } = cap;`.
2. Capture `tenant_cap_id = object::uid_to_inner(&id);` — must be read
   before `object::delete` consumes the `UID`.
3. Call `object::delete(id);`.
4. Emit `TenantCapBurned { tenant_cap_id, escrow_id }` — emission runs
   last, after the cap is actually destroyed.

**No `ctx` argument:** `TenantCapBurned` does not carry a holder
address — `TenantCap` is non-transferable, so the burning address is
trivially recoverable by JOIN on `tenant_cap_id` against the
`TenantCapMinted` row that logged the mint recipient. `burn` therefore
has no need to read `tx_context::sender` and keeps its signature
minimal.

**No state mutation:** burning a cap does not affect
`escrow.current_tenant_cap_id`. The escrow is not notified. A burned
current cap does not revoke access — but `borrow_asset` would then
fail because the cap no longer exists to be presented.

---

### `escrow_id`

    public fun escrow_id(cap: &TenantCap): ID

**Visibility:** `public` — readable by any caller. Useful for
off-chain code and for `rental_escrow`'s first-pass escrow check.

**Purpose:** returns the `ID` of the `RentalEscrow` this cap was
minted for.

**Behavior:** returns `cap.escrow_id`.

**Note:** `rental_escrow::borrow_asset` performs two gating checks
inline at the call site:
```
assert!(tenant_cap::escrow_id(cap) == object::id(escrow), E_WRONG_ESCROW_TENANT_CAP);
assert!(escrow.current_tenant_cap_id.is_some(), E_STALE_TENANT_CAP);
assert!(object::id(cap) == *escrow.current_tenant_cap_id.borrow(), E_STALE_TENANT_CAP);
```
Both abort constants live in `rental_escrow` — the cap module
exposes only the binding (via `escrow_id`) and lets the consumer
define what "wrong escrow" and "stale" mean for its own operations.


5. PROPERTIES
-------------

**P1 — Minted only at tenant transition:**
    `mint_to` is `public(package)` and called only at `rent()` (Idle,
    AtDutchAuction) and `do_handover()`. Bids during Rented states do
    not mint a cap. No orphaned caps from superseded bidders.

**P2 — Non-transferable by type:**
    `key` only, no `store`. No transfer function exists in this module.
    The Sui type system enforces this — no external code can move the
    cap between addresses.

**P3 — Staleness is inert, not destructive:**
    A displaced tenant's cap remains in their wallet but fails the ID
    check in `borrow_asset`. The protocol never forcibly burns it.
    `burn` is the holder's opt-in exit for gas recovery.

**P4 — burn has no escrow side-effects:**
    Burning a cap does not update any escrow field. The escrow is
    unaware. The only consequence is that the object ceases to exist —
    it can no longer be presented to `borrow_asset`.

**P5 — All deliveries are pushes, performed by `mint_to`:**
    `rent()` has a single signature and does not mint a cap in Rented
    states. A return-based design would require `Option<TenantCap>`,
    which is inconsistent. All mint sites route through
    `mint_to(escrow_id, recipient, ctx)`, which internally performs
    `transfer::transfer(cap, recipient)`: `rental_escrow::rent` passes
    `tx_context::sender(ctx)` as the recipient; `do_handover` passes
    `pending_tenant_address`. **Enforced by the type system:**
    `transfer::transfer<TenantCap>` only compiles inside this module,
    so `mint_to` is the only physically possible delivery channel — no
    external call site can bypass it even by accident.


6. TEST CASES
-------------

### 6.0 Test strategy

**Test module.** `#[test_only] module liquid_renting::tenant_cap_tests`.
Function names describe the asserted behaviour (e.g.
`mint_to_transfers_to_declared_tenant_not_sender`,
`burn_emits_without_tenant_field`).

**Idioms.**

- `tenant_cap` creates real Sui objects (UIDs), transfers them, and
  emits events. Every test runs in `sui::test_scenario`. No
  `tx_context::dummy()` path — `mint_to` calls `transfer::transfer`
  which requires a real `TxContext` threaded through a scenario.
- Each row translates to one `#[test]` function. `tenant_cap` has **no
  abort sites** (§1), so no `#[expected_failure]` rows. `burn`'s
  by-value consumption is compile-time.

**Fixtures.** Canonical actor addresses:

```
const ALICE:   address = @0xA11CE;   // typical sender / first tenant
const BOB:     address = @0xB0B;     // handover recipient / second tenant
const ZERO:    address = @0x0;       // zero-address boundary
```

Escrow IDs: literal `object::id_from_address(@0xE5C1)` and `@0xE5C2`.
Sufficient for this module — `tenant_cap` never dereferences the escrow.

**Test-only helpers.**

```
#[test_only] public fun capture_minted(
    effects: &TransactionEffects): vector<TenantCapMinted>
#[test_only] public fun capture_burned(
    effects: &TransactionEffects): vector<TenantCapBurned>
```

Both wrap `event::events_by_type<T>()`. No wrappers over `mint_to` /
`burn` are needed: `mint_to` is `public(package)` (test module is in the
same package); `burn` is `public`.

**Retrieval convention.** After a `mint_to(..., tenant, ...)` call in
tx_k, the subsequent tx does:

```
test_scenario::next_tx(&mut scenario, tenant);
let cap = test_scenario::take_from_address<TenantCap>(&scenario, tenant);
```

Rows that assert "delivered to tenant, not sender" additionally call
`assert!(!test_scenario::has_most_recent_for_address<TenantCap>(sender))`.

**Star-schema assertion shape.** Per the project-wide convention (memory
`feedback_events_self_describing`), every `TenantCapMinted` row asserts
`(tenant_cap_id, escrow_id, tenant)` exactly; every `TenantCapBurned`
row asserts `(tenant_cap_id, escrow_id)` only. The deliberate absence
of `tenant` on Burned is itself a test obligation — see row B4. These
checks bundle into predicates `assert_star_schema_minted(...)` and
`assert_star_schema_burned(...)`.


### 6.1 `mint_to`

| # | Description | Expected |
|---|---|---|
| N1 | Sender ALICE calls `mint_to(escrow_id = @0xE5C1, tenant = ALICE, ctx)` (the `rent()`-from-Idle case) | Returns an `ID`. Next tx as ALICE: `take_from_address<TenantCap>(scenario, ALICE)` yields a cap with `cap.escrow_id == @0xE5C1` and `object::id(&cap) == returned_id`. `num_user_events == 1`. Event `TenantCapMinted { tenant_cap_id: returned_id, escrow_id: @0xE5C1, tenant: ALICE }`. Star-schema predicate passes. |
| N2 | Two `mint_to` calls in one tx with same `escrow_id = @0xE5C1` and same `tenant = ALICE` | Two distinct `TenantCap` objects (distinct UIDs) land in ALICE's account. `num_user_events == 2`. Two Minted events with distinct `tenant_cap_id` and identical `(escrow_id, tenant)`. Two distinct `ID`s returned. Asserts **P1** is structural (§5): this module permits duplicate mints; the "one cap per tenant transition" guarantee lives at `rental_escrow` call sites. |
| N3 | Two `mint_to` calls with distinct `escrow_id`s (`@0xE5C1`, `@0xE5C2`) and distinct `tenant`s (ALICE, BOB) | cap0 lands in ALICE's account, cap1 in BOB's. Two Minted events with matching triples in call order. |
| N4 | Sender ALICE calls `mint_to(escrow_id = @0xE5C1, tenant = BOB, ctx)` (the `do_handover` case where `tenant == pending_tenant_address`) | Cap retrievable via `take_from_address(scenario, BOB)`, **not** `ALICE`. Assert `has_most_recent_for_address<TenantCap>(ALICE) == false`. Event `tenant == BOB`. Asserts delivery routes through the argument, not through `tx_context::sender(ctx)`. |
| **[new] N5** | `mint_to(escrow_id = @0xE5C1, tenant = ZERO, ctx)` | `transfer::transfer(cap, @0x0)` executes — Sui permits transfer to the zero address at the framework layer. The cap becomes permanently inaccessible (`take_from_address(scenario, @0x0)` succeeds technically but no account can sign for `@0x0`). Event `tenant == @0x0`. Documents that `tenant_cap` does not filter zero addresses — policy lives in `rental_escrow::rent` / `do_handover`. Flag in Open questions. |
| **[new] N6** | `mint_to(escrow_id = @0x0, tenant = ALICE, ctx)` | Cap stored in ALICE's account with `cap.escrow_id == @0x0`. Event `escrow_id == @0x0`. Asserts `tenant_cap` imposes no non-zero-ID constraint — integration-time guarantees live at `rental_escrow`. |
| **[new] N7** | Emit-last ordering: `mint_to` → immediately inside same tx inspect effects | The `TenantCapMinted` event is present in tx effects (emit happens before tx commit). Asserts the spec's step 4 (emit after transfer) did not accidentally move emit to before transfer. Encoded by capturing effects and asserting both `num_user_events == 1` and `has_most_recent_for_address<TenantCap>(tenant) == true` in the same post-tx snapshot. |

### 6.2 `burn`

| # | Description | Expected |
|---|---|---|
| B1 | `burn(cap)` on a current cap (minted in a prior tx by the same scenario) | UID deleted (`has_most_recent_for_address<TenantCap>(holder) == false` after). No abort. No escrow state change (not checkable here — no escrow in scope; **P4** deferred to lifecycle row L4 in `rental_escrow`-side tests). `num_user_events == 1`. One `TenantCapBurned { tenant_cap_id, escrow_id }` with the pair the cap carried at mint. **No `tenant` field on the event** — asserted structurally via the capture helper's return type. |
| B2 | `burn(cap)` on a stale cap (a cap superseded by a later `mint_to` on the same escrow_id in scenario setup) | Identical behaviour to B1. `TenantCapBurned` emitted with the stale cap's `(tenant_cap_id, escrow_id)`. Documents **P3** from this module's perspective: staleness is inert; `burn` does not inspect current-cap state. |
| B3 | `burn` consumes by value | Compile-time enforcement — a second `burn(cap)` would fail to compile. Not a runtime row; verified by the successful build of L1. Listed for completeness. |
| B4 | **JOIN recoverability of holder.** Scenario: `mint_to(@0xE5C1, ALICE, ctx)` in tx1, then in tx2 ALICE calls `burn(cap)`. | `TenantCapBurned { tenant_cap_id = X, escrow_id = @0xE5C1 }` in tx2; no `tenant` field. Asserts: looking up `TenantCapMinted` by `tenant_cap_id == X` returns a single row with `tenant == ALICE`. Composed test: `capture_minted(&tx1_effects)` + `capture_burned(&tx2_effects)` joined in the test body. Documents the star-schema invariant that omitting `tenant` from Burned is lossless under non-transferability (**P2**). |
| **[new] B5** | `burn(cap)` by the **mint recipient** — sender of the burn tx equals `tenant` from Minted | Asserted implicitly by `key`-only: only the holder can sign a tx that owns the cap. `test_scenario::next_tx(&mut scenario, ALICE)` is the legal sender; any other sender cannot take the cap. Encodes **P2** enforcement at the Move type level by constructing a scenario where tx2 is signed by `BOB` but the cap is in ALICE's account — `take_from_address<TenantCap>(&scenario, ALICE)` succeeds, but `burn(cap)` in that tx is legal for anyone who can obtain the cap by ref (they cannot; cap is in ALICE's account). Net assertion: no non-ALICE tx can reach `burn` without compile-time type violation; documented here, not executed. |
| **[new] B6** | `burn(cap)` on a cap whose `escrow_id == @0x0` (via N6 setup) | Event `escrow_id == @0x0`. Symmetric with N6 — burn path makes no stronger claim than mint path. |

### 6.3 `escrow_id`

| # | Description | Expected |
|---|---|---|
| G1 | `escrow_id(&cap)` on a cap retrieved from `ALICE`'s account after `mint_to(@0xE5C1, ALICE, ctx)` | Returns `@0xE5C1`. |
| **[new] G2** | Call `escrow_id(&cap)` five times in a row on the same cap | All five calls return the same `ID`. Asserts the getter is pure (no mutation, no event emission). Encoded as a loop predicate inside one `#[test]`. |
| **[new] G3** | `escrow_id(&cap)` where `cap.escrow_id == @0x0` (via N6) | Returns `@0x0`. The getter does not filter zero IDs. |

### 6.4 Lifecycle

| # | Description | Expected |
|---|---|---|
| L1 | `mint_to(@0xE5C1, ALICE)` (tx1) → take from ALICE → `escrow_id(&cap) == @0xE5C1` → `burn(cap)` (tx2 by ALICE) | Full lifecycle. `tx1.num_user_events == 1` (Minted), `tx2.num_user_events == 1` (Burned). Both events share `(tenant_cap_id, escrow_id)`. `tenant` present on Minted only. |
| L2 | `mint_to` (cap A, ALICE) → `mint_to` (cap B, same escrow, BOB) → both returned `ID`s distinct | Staleness mechanic relies on distinct IDs. Two Minted events with distinct `tenant_cap_id`, identical `escrow_id`, distinct `tenant`. cap A is stale from the indexer's perspective the moment cap B is minted (though neither cap knows it — staleness is a rental_escrow-side state read). |
| L3 | Stale cap: after L2 setup, ALICE calls `burn(cap_A)` | Holder cleans up regardless of any escrow state. `TenantCapBurned { tenant_cap_id = id_A, escrow_id = @0xE5C1 }` emitted. cap B remains in BOB's wallet untouched. |
| **[new] L4** | Multi-stale cleanup: L2 setup extended so three caps are minted for the same escrow to (ALICE, BOB, ALICE) across three txs, then ALICE burns both of her caps in a fourth tx | Four txs total: three Minted events with matching `escrow_id` and distinct `tenant_cap_id`; the burn tx emits two `TenantCapBurned` events in burn order, each carrying its cap's `(tenant_cap_id, escrow_id)`. Asserts lifecycle independence of multiple stale caps held by the same address. |
| **[new] L5** | Mint two caps for **different** escrows (`@0xE5C1` to ALICE, `@0xE5C2` to ALICE) in one tx; burn them both in the next tx in reverse order | tx1: two Minted events in mint order. tx2: two Burned events in burn order. The PK-JOIN path `TenantCapMinted.tenant_cap_id = TenantCapBurned.tenant_cap_id` recovers the mint/burn pair for each cap independently — the two lifecycles do not cross. |

**[new] [property] P-SE — star-schema envelope invariants.** For every
row above that asserts an event:
1. `tenant_cap_id` field is present and equal to `object::id(&cap)` —
   child PK that lets an indexer PK-JOIN Minted and Burned rows.
2. `escrow_id` field is present and equal to the value recorded at
   mint.
3. On Minted: `tenant` is present as a first-observed address. On
   Burned: `tenant` is **absent by design** — attempting to read it
   at the Move level is a compile error; the indexer recovers it via
   JOIN (B4).
4. No Sui envelope metadata (tx_digest, tx sender, transfer events)
   is relied on for identity. The pair `(tenant_cap_id, escrow_id)`
   alone is sufficient to locate the cap across its lifecycle.

Escrow-mismatch and staleness abort paths are tested in `rental_escrow`
at `borrow_asset` — the predicates are inline asserts at the call site
and the abort constants are rental-side; `tenant_cap` itself has no
abort to test.


### 6.5 Open questions

- **Zero-address / zero-ID tolerance (N5, N6, B6, G3).** This module
  accepts `tenant == @0x0` and `escrow_id == @0x0` without validation.
  Rows document current behaviour; if policy later requires rejection,
  decide whether it lives here (costs §1's "no aborts" posture) or
  stays at `rental_escrow::rent` / `do_handover` / `integrate`.
  Current stance: keep the cap permissive.
- **Transfer to `@0x0` (N5).** `transfer::transfer(cap, @0x0)` executes
  at the Sui framework layer; the cap becomes irretrievable. `tenant_cap`
  does not guard against this. If any rental_escrow call site could
  route a zero address into `mint_to`, it would create an uncollectable
  cap and a zombie `current_tenant_cap_id`. Verify during `rental_escrow`
  audit that both call sites (`rent`, `do_handover`) guarantee
  non-zero `tenant`.
- **Emit-last assertion granularity (N7).** Rows above assert the event
  is present in tx effects but do not assert the *intra-tx ordering*
  of `transfer::transfer` vs `event::emit`. Sui's tx effects do not
  expose fine-grained intra-tx ordering through `test_scenario`; the
  §4 mint_to step order is a source-level invariant verified by code
  review, not by runtime tests.
- **Double-mint structural note (N2).** This module allows two `mint_to`
  calls for the same `(escrow_id, tenant)` pair. Verify during
  `rental_escrow` audit that no path invokes `mint_to` twice for the
  same logical transition; if one does, this module needs a runtime
  guard and §1 gains an error constant.


7. MODULE BOUNDARY
------------------

`tenant_cap.move` exports:

| Symbol | Visibility | Notes |
|---|---|---|
| `TenantCap` (type) | `public` | `key` only. Non-transferable by type; single delivery channel (`mint_to`). One per tenant transition event. |
| `TenantCapMinted` (event) | `public` | `copy + drop`. Emitted by `mint_to`. |
| `TenantCapBurned` (event) | `public` | `copy + drop`. Emitted by `burn`. |
| `mint_to(escrow_id, tenant, ctx): ID` | `public(package)` | Fused mint + delivery. Constructs the cap, transfers it to `tenant`, emits `TenantCapMinted { tenant_cap_id, escrow_id, tenant }`, returns `tenant_cap_id`. Called by `rental_escrow::rent` and `rental_escrow::do_handover`. The transfer lives here (required: `transfer::transfer<TenantCap>` only compiles in this module). |
| `burn(cap)` | `public` | Voluntary destroy for gas recovery. No state mutation. Emits `TenantCapBurned { tenant_cap_id, escrow_id }`. Holder address recoverable by JOIN on `tenant_cap_id` against `TenantCapMinted`. |
| `escrow_id(cap): ID` | `public` | Getter. Read by `rental_escrow` at `borrow_asset` to compare against the target escrow's ID inline (abort constants `E_WRONG_ESCROW_TENANT_CAP` and `E_STALE_TENANT_CAP` live in rental_escrow). |

**No abort codes exported.** The two gating checks that used to
live here as `assert_escrow` / `assert_current` have moved to
`rental_escrow::borrow_asset` as inline asserts with rental-side
constants — "wrong escrow" and "stale" are the consumer's
semantics, not the cap's.

**Depends on:** `sui::object`, `sui::event`.


8. OBJECT DISPLAY
-----------------

![TenantCap](../../media/object-display/tenant-cap.png)

`Display<TenantCap>` gives every cap a visual identity in wallets and explorers.
Created once post-deployment via a PTB presenting `&mut Publisher` for the
package and `&mut DisplayRegistry` (Sui framework shared object at `0xd`).

### Fields

| Key | Value | Notes |
|---|---|---|
| `name` | `Tenant Cap` | Static. |
| `description` | `Grants temporary access to a rented asset in the Liquid Renting Protocol. Becomes stale when displaced by a new tenant.` | Static. |
| `image_url` | `{IMAGE_BASE_URL}/tenant-cap.png` | Hosted URL. Source: `media/object-display/tenant-cap.png`. |
| `project_url` | `https://liquidrenting.com` | Static. |
| `creator` | `Liquid Renting Protocol` | Static. |

`{IMAGE_BASE_URL}` is set at deployment time to the protocol's media hosting base URL.

### Creation

```move
use sui::display_registry;

let (mut display, cap) = display_registry::new_with_publisher<TenantCap>(
    registry,   // &mut DisplayRegistry (shared object 0xd)
    publisher,  // &mut Publisher
    ctx,
);
display_registry::set(&mut display, &cap, b"name".to_string(),        b"Tenant Cap".to_string());
display_registry::set(&mut display, &cap, b"description".to_string(), b"Grants temporary access to a rented asset in the Liquid Renting Protocol. Becomes stale when displaced by a new tenant.".to_string());
display_registry::set(&mut display, &cap, b"image_url".to_string(),   b"{IMAGE_BASE_URL}/tenant-cap.png".to_string());
display_registry::set(&mut display, &cap, b"project_url".to_string(), b"https://liquidrenting.com".to_string());
display_registry::set(&mut display, &cap, b"creator".to_string(),     b"Liquid Renting Protocol".to_string());
display_registry::share(display);
transfer::public_transfer(cap, ctx.sender());  // cap retained by deployer for future edits
```

One `Display<TenantCap>` per package deployment — enforced by `DisplayRegistry`.
ID is deterministic from `DisplayRegistry` + type — no event scanning required.
The returned `DisplayCap<TenantCap>` is required to call `set` / `unset` / `clear`
later; keeping it with the deployer preserves the ability to edit the Display
post-deployment.

**Status:** [ ] `Display<TenantCap>` created and committed.
