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
- `TenantCap` — `key + store`. One minted per tenant transition event
  (not per bid). Transferable by holder — symmetric with `OwnerCap`;
  the protocol does not police custody. Can become stale after
  displacement — inert, failing the ID check in `rental_escrow`.
- `new(escrow_id, tenant, ctx): (TenantCap, ID)` — `public(package)`.
  Pure constructor. Builds the cap, emits `TenantCapMinted`, returns
  `(cap, cap_id)` by value. The caller decides delivery:
  `rental_escrow::rent` (from Idle, AtDutchAuction) threads the cap
  out of `rent`'s return tuple (`Option<TenantCap>`) into the PTB —
  return-by-value composition, the incoming tenant is the present
  caller; `rental_escrow::do_handover` calls
  `transfer::public_transfer(cap, pending_tenant_address)` inline —
  legal because `TenantCap` has `store` and the recipient is absent
  from the settlement transaction. The `tenant` argument is recorded
  on `TenantCapMinted.tenant` as a first-observed address — under
  `store` the cap may change hands later, so this address is the
  mint-time placer, not necessarily the current holder.
- `burn(cap, ctx)` — `public`. Voluntary destroy by current holder for
  gas recovery. No state mutation. The protocol never forces this.
  Emits `TenantCapBurned { tenant_cap_id, escrow_id, tenant }` where
  `tenant` is `tx_context::sender(ctx)` — under `key + store` the cap
  may have changed hands between mint and burn, so the burning address
  is genuinely new information and is **not** PK-recoverable by JOIN
  on `tenant_cap_id` to `TenantCapMinted`. Symmetric with
  `OwnerCapBurned.owner`.
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
- **`key + store` — symmetric with `OwnerCap`.** Both caps are first-class
  Sui objects: holders may custody, multisig, or transfer them at will.
  The protocol does not police ownership. Two consequences flow from this:
  1. **Address-targeted pushes commit to the placer, not the bearer.**
     `current_tenant_address` is registered at mint and never updated.
     Pushes that target it (e.g. `remain_credit` at handover) reach
     the address that placed the cap — not necessarily the current
     holder if the cap was transferred. The placer and the current
     holder coordinate off-protocol; their arrangement is not the
     protocol's concern. (Symmetric with `OwnerCap` and any other
     transferable cap.)
  2. **Secondary markets for stale caps are permitted but not
     supported.** The protocol's only invariant is the staleness
     check in `borrow_asset`: a stale cap fails the ID match and is
     inert. What a third party pays for an inert cap is a private
     transaction between buyer and seller; the protocol does not
     block it at the type level — closing it there would be
     paternalistic, would break composability and custody for
     legitimate holders, and would defend against fraud the protocol
     has no role in adjudicating.
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
- **Two delivery channels — return-by-value (default) and push (only
  when the recipient is absent).** `new` always returns `(TenantCap,
  ID)` by value. Two consumers route the cap differently:
  - `rental_escrow::rent` (Idle, AtDutchAuction) — the caller is the
    incoming tenant, present in the same transaction. The cap is
    threaded out of `rent`'s return tuple (`Option<TenantCap>`) into
    the PTB. The PTB caller decides where it lands (own wallet,
    multisig, immediate burn after a one-shot
    borrow→use→return→burn, further composition).
  - `rental_escrow::do_handover` — the incoming tenant is the
    `pending_tenant_address` registered at bid time. They are not in
    the settlement transaction (any permissionless settler can fire
    it). The settler must push:
    `transfer::public_transfer(cap, pending_tenant_address)`. Legal
    at any call site because `TenantCap : store`.
  This module no longer carries any transfer logic — `new` is a pure
  constructor + emitter. The verifier-driven argument that previously
  forced a fused `mint_to` here ("`transfer::transfer<TenantCap>` only
  compiles inside the owning module") no longer applies under `store`:
  `transfer::public_transfer` works from any module for `key + store`
  types.
- **TenantCap as signal:** the cap appearing in the wallet is the
  clearest notification of tenancy. No indexer query or event
  subscription needed.


1. ERROR CONSTANTS
------------------

None. `tenant_cap` has no abort sites: `new` and `burn` are
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
public struct TenantCap has key, store {
    id:        UID,
    escrow_id: ID,
}
```

**Abilities:** `key + store`.
- `key` — object identity. Required for the ID-based staleness check
  in `rental_escrow` (`object::id(cap) == escrow.current_tenant_cap_id`).
- `store` — first-class composability. Enables custody, multisig, and
  return-by-value from `rental_escrow::rent`. Also lifts the verifier's
  same-module restriction on `transfer::transfer`: `transfer::public_transfer`
  works from any module for `key + store` types, so `do_handover` can push
  the cap to the absent recipient inline without routing through this
  module. Symmetric with `OwnerCap`. Holders' only protocol-side exit
  remains `burn`; transfers between addresses are off-protocol.

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
    tenant:        address,
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
- `tenant` on `TenantCapMinted` — passed by `rental_escrow::rent`
  (= `tx_context::sender(ctx)`) or by `do_handover` (= the
  `pending_tenant_address` registered at bid time). Mint-time
  first-observed address.
- `tenant` on `TenantCapBurned` — `tx_context::sender(ctx)` at burn
  time. Under `key + store` the cap may have been transferred between
  mint and burn (custody handoff, multisig delegation), so the burning
  address is **not** PK-recoverable from `TenantCapMinted`. Carrying
  it explicitly is required information, not duplication.

**Design intent — events as SQL rows keyed by natural PKs:** the
protocol's event layer feeds an off-chain indexer whose schema is
anchored on `escrow_id` as the root foreign key and on each child
object's ID (`tenant_cap_id`, `owner_cap_id`, `fee_message_id`) as a
lifecycle-pair primary key. Address data lives only where it is
first-observed or where it diverges across events. `TenantCap` is
`key + store` — symmetric with `OwnerCap` — so mint-tenant and
burn-tenant may differ; both events carry `tenant` because each row
records genuinely new information. (Contrast with the previous
`key`-only design, where non-transferability collapsed the two
addresses into one and `tenant` appeared on Minted only.)

**No `timestamp_ms` field.** The module has no authoritative time to
report: `new` may be called from a lazy-settlement path whose logical
moment is in the past (`do_handover` fires at the stored boundary,
not at `clock.now()`), so wall-clock time would diverge from logical
event time. Consumers order by checkpoint timestamp + tx position
(attached by Sui to the envelope for free). The module emits identity
and address fields only.


4. FUNCTIONS
------------

### `new`

    public(package) fun new(
        escrow_id: ID,
        tenant:    address,
        ctx:       &mut TxContext,
    ): (TenantCap, ID)

**Visibility:** `public(package)` — callable only by `rental_escrow`.

**Purpose:** pure constructor. Constructs a `TenantCap` bound to the
given escrow, emits `TenantCapMinted { tenant_cap_id, escrow_id,
tenant }`, returns the cap and its `ID` by value. No transfer, no
state mutation. The caller decides delivery.

**Behavior:**
1. Construct `let cap = TenantCap { id: object::new(ctx), escrow_id };`.
2. `let tenant_cap_id = object::uid_to_inner(&cap.id);`.
3. `event::emit(TenantCapMinted { tenant_cap_id, escrow_id, tenant });`
   — emit-last, after the cap has been constructed; the cap exists
   semantically when the event fires.
4. Return `(cap, tenant_cap_id)`.

The `tenant` argument is recorded on the event but **not** stored on
the `TenantCap` struct: under `key + store` the holder may change at
any time, so a stored mint-recipient field would be misleading and
redundant with `TenantCapMinted.tenant`.

**Why no transfer here:** under `key + store`, both delivery channels
needed by the protocol are physically expressible without an
in-module transfer:

- **Return-by-value** (Idle, AtDutchAuction acquisition paths) — the
  caller is the incoming tenant, present in the same transaction. The
  cap is threaded out of `rent`'s return tuple
  (`Option<TenantCap>`) into the PTB. The PTB caller decides the
  destination — wallet, multisig, immediate burn, further composition.
- **Push from the call site** (`do_handover` settlement) — the
  recipient is absent. The settler calls
  `transfer::public_transfer(cap, pending_tenant_address)` directly
  from `rental_escrow`. Legal under `store` — the verifier's
  same-module restriction on `transfer::transfer<T>` does not apply
  to `transfer::public_transfer` for `key + store` types.

The previous `mint_to` design fused these two channels because
`key`-only forced every transfer through this module. With `store`
that constraint is lifted; the constructor stays single-purpose and
delivery is the caller's concern.

**Call sites:**
- `rental_escrow::rent` (from Idle, AtDutchAuction) — passes
  `tx_context::sender(ctx)` as `tenant` (the incoming tenant is the
  PTB caller). Stores the returned `ID` in
  `escrow.current_tenant_cap_id`; surfaces the cap in the
  `Option<TenantCap>` slot of `rent`'s return.
- `rental_escrow::do_handover` — passes `pending_tenant_address` as
  `tenant` (the incoming tenant is the bid placer, absent from the
  settlement tx). Stores the returned `ID` in
  `escrow.current_tenant_cap_id`; pushes the cap with
  `transfer::public_transfer(cap, pending_tenant_address)`.

---

### `burn`

    public fun burn(cap: TenantCap, ctx: &TxContext)

**Visibility:** `public` — callable by any holder (current or displaced
tenant).

**Purpose:** voluntary destruction of a `TenantCap` for gas recovery.
Serves current tenants (end of use, including the one-shot
borrow→use→return→burn pattern in a single PTB), displaced tenants
(stale cap cleanup), and any later holder under custody/multisig
arrangements. Has no effect on escrow state.

**Behavior:**
1. Destructure: `let TenantCap { id, escrow_id } = cap;`.
2. Capture `tenant_cap_id = object::uid_to_inner(&id);` — must be read
   before `object::delete` consumes the `UID`.
3. Capture `tenant = tx_context::sender(ctx);` — the burning address.
4. Call `object::delete(id);`.
5. Emit `TenantCapBurned { tenant_cap_id, escrow_id, tenant }` —
   emission runs last, after the cap is actually destroyed.

**Why `ctx` is required:** under `key + store` the cap may have been
transferred between mint and burn, so the burning address is genuinely
new information that is not PK-recoverable from `TenantCapMinted`.
`burn` reads `tx_context::sender(ctx)` to record it on the event.
(Compare with the previous `key`-only design, where non-transferability
collapsed the two addresses and `ctx` was not needed.)

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
    `new` is `public(package)` and called only at `rent()` (Idle,
    AtDutchAuction) and `do_handover()`. Bids during Rented states do
    not mint a cap. No orphaned caps from superseded bidders.

**P2 — Transferable by holder, no protocol-side restriction:**
    `key + store`. Holders may custody, multisig, or transfer the cap
    at will. The protocol does not police ownership. The only
    protocol-side exit is `burn`. Symmetric with `OwnerCap`.

**P3 — Staleness is inert, not destructive:**
    A displaced tenant's cap remains in their wallet but fails the ID
    check in `borrow_asset`. The protocol never forcibly burns it.
    `burn` is the holder's opt-in exit for gas recovery. Staleness
    cannot be revoked or undone — it is a property of `escrow.current_tenant_cap_id`,
    not of the cap itself.

**P4 — `burn` has no escrow side-effects:**
    Burning a cap does not update any escrow field. The escrow is
    unaware. The only consequence is that the object ceases to exist —
    it can no longer be presented to `borrow_asset`.

**P5 — Two delivery channels, neither inside this module:**
    `new` is a pure constructor returning `(TenantCap, ID)` by value.
    Delivery happens at the call site in `rental_escrow`:
    - **Return-by-value** — `rent()` from Idle/AtDutchAuction threads
      the cap out of its `Option<TenantCap>` return slot to the PTB
      caller. The caller is the incoming tenant, present in the same
      transaction. The PTB decides where the cap lands.
    - **Push** — `do_handover()` calls
      `transfer::public_transfer(cap, pending_tenant_address)` inline.
      The recipient is absent (any permissionless settler may fire
      `apply_pending_transitions`); push is the only physical option.
      Legal because `TenantCap : store`.
    No `transfer::transfer<TenantCap>` exists anywhere in the
    protocol; under `store` the verifier permits `public_transfer`
    from any module, so the previous "fused mint+push" pattern is no
    longer required.


6. TEST CASES
-------------

### 6.0 Test strategy

**Test module.** `#[test_only] module liquid_renting::tenant_cap_tests`.
Function names describe the asserted behaviour (e.g.
`new_returns_cap_and_id_by_value`,
`burn_records_sender_when_holder_changed`).

**Idioms.**

- `new` is a pure constructor: it allocates a `UID` (via `object::new`)
  and emits an event, but performs no transfer. Tests can either keep
  the returned cap as a local and inspect it directly, or call
  `transfer::public_transfer(cap, addr)` from the test body to simulate
  the `do_handover` push flow. Both forms run in `sui::test_scenario`
  because `object::new` and `event::emit` require a real `TxContext`
  and tx effects.
- Each row translates to one `#[test]` function. `tenant_cap` has **no
  abort sites** (§1), so no `#[expected_failure]` rows. `burn`'s
  by-value consumption is compile-time.

**Fixtures.** Canonical actor addresses:

```
const ALICE:   address = @0xA11CE;   // typical mint recipient / first tenant
const BOB:     address = @0xB0B;     // handover recipient / transferee
const CAROL:   address = @0xCA401;   // third-party holder (custody / multisig)
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

Both wrap `event::events_by_type<T>()`. No wrappers over `new` /
`burn` are needed: `new` is `public(package)` (test module is in the
same package); `burn` is `public`.

**Two retrieval patterns.** `new` returns the cap by value, so most
inspection happens directly on the local. When a row also exercises
the push path or the holder-rotation flow, the test body itself
calls `transfer::public_transfer(cap, addr)` (legal under `store`
from any module) and a subsequent tx retrieves the cap with
`test_scenario::take_from_address<TenantCap>(&scenario, addr)`.

**Star-schema assertion shape.** Per the project-wide convention (memory
`feedback_events_self_describing`), every `TenantCapMinted` row asserts
`(tenant_cap_id, escrow_id, tenant)` exactly; every `TenantCapBurned`
row asserts `(tenant_cap_id, escrow_id, tenant)` exactly — under
`key + store` the burning address is genuinely new information and
must be present. These checks bundle into predicates
`assert_star_schema_minted(...)` and `assert_star_schema_burned(...)`.


### 6.1 `new`

| # | Description | Expected |
|---|---|---|
| N1 | `let (cap, id) = new(escrow_id = @0xE5C1, tenant = ALICE, ctx)`; inspect locally without transferring | `cap.escrow_id == @0xE5C1`, `object::id(&cap) == id`. `num_user_events == 1`. Event `TenantCapMinted { tenant_cap_id: id, escrow_id: @0xE5C1, tenant: ALICE }`. Star-schema predicate passes. The cap is consumed by an in-test `burn(cap, ctx)` to satisfy the `key`-without-`drop` consume requirement. |
| N2 | Two `new` calls in one tx with same `(escrow_id = @0xE5C1, tenant = ALICE)` | Two distinct `TenantCap` locals with distinct UIDs and distinct returned IDs. `num_user_events == 2`. Two Minted events with distinct `tenant_cap_id` and identical `(escrow_id, tenant)`. Asserts **P1** is structural (§5): this module permits duplicate mints; the "one cap per tenant transition" guarantee lives at `rental_escrow` call sites. |
| N3 | Two `new` calls with distinct escrow_ids (`@0xE5C1`, `@0xE5C2`) and distinct tenants (ALICE, BOB) | Two locals with the corresponding fields. Two Minted events with matching triples in call order. |
| N4 | `let (cap, id) = new(@0xE5C1, BOB, ctx)` while sender is ALICE (the `do_handover` case where `tenant != tx_context::sender`) | Event `tenant == BOB` regardless of `tx_context::sender(ctx) == ALICE`. Asserts the `tenant` field is the function argument, not the sender. The cap is then `transfer::public_transfer(cap, BOB)` from the test body to mirror the real `do_handover` flow; next tx retrieves it from BOB's account. |
| N5 | `new(escrow_id = @0xE5C1, tenant = ZERO, ctx)` (no transfer) | Event `tenant == @0x0`. Cap is a local — never delivered. Documents that `new` does not filter zero addresses; policy lives at `rental_escrow::rent` / `do_handover`. Flag in Open questions. |
| N6 | `new(escrow_id = @0x0, tenant = ALICE, ctx)` (no transfer) | Local cap with `cap.escrow_id == @0x0`. Event `escrow_id == @0x0`. Asserts `new` imposes no non-zero-ID constraint — integration-time guarantees live at `rental_escrow`. |
| N7 | Emit-last ordering: `new` → inspect effects in same test | `TenantCapMinted` present in tx effects (emit precedes tx commit). Asserts the spec's step 3 (emit after construction) is honored. Encoded by capturing effects and asserting `num_user_events == 1` immediately after the `new` call. |
| **[new] N8** | `let (cap, id) = new(@0xE5C1, ALICE, ctx); transfer::public_transfer(cap, BOB)` from the test body — exercises the push channel directly | Asserts the cap is `store`-transferable from outside this module. Next tx retrieves the cap from BOB's account; `cap.escrow_id == @0xE5C1`. Documents **P5** push channel: `do_handover` does this exact pattern in production. |

### 6.2 `burn`

| # | Description | Expected |
|---|---|---|
| B1 | `let (cap, _) = new(@0xE5C1, ALICE, ctx); burn(cap, ctx)` in same tx (sender = ALICE) | UID deleted. No abort. No escrow state change (not checkable here — no escrow in scope; **P4** deferred to lifecycle rows in `rental_escrow`-side tests). `num_user_events` over the tx includes one `TenantCapMinted` and one `TenantCapBurned`. Burned event: `TenantCapBurned { tenant_cap_id, escrow_id: @0xE5C1, tenant: ALICE }`. Star-schema predicate passes. |
| B2 | Stale cap: tx1 mints cap A to ALICE, tx2 mints cap B to BOB (same escrow), tx3 ALICE calls `burn(cap_A, ctx)` | Identical behaviour to B1; `TenantCapBurned` for cap_A with `tenant: ALICE`. Documents **P3** from this module's perspective: staleness is inert; `burn` does not inspect current-cap state. |
| B3 | `burn` consumes by value | Compile-time enforcement — a second `burn(cap, ctx)` would fail to compile. Not a runtime row; verified by the successful build of B1/L1. Listed for completeness. |
| **[new] B4** | **Burner ≠ mint recipient.** tx1: `let (cap, _) = new(@0xE5C1, ALICE, ctx); transfer::public_transfer(cap, BOB);` (sender = ALICE; cap now in BOB's account). tx2: BOB takes the cap, calls `burn(cap, ctx)` (sender = BOB). | `TenantCapMinted.tenant == ALICE` (mint recipient). `TenantCapBurned.tenant == BOB` (burning sender). The two are distinct, asserting that under `key + store` the burner address is **not** PK-recoverable from Minted and is genuinely new information. This is the load-bearing test for the §3 schema change. |
| **[new] B5** | **Multi-hop custody chain.** tx1: mint to ALICE. tx2: ALICE transfers to BOB. tx3: BOB transfers to CAROL. tx4: CAROL burns. | `TenantCapBurned.tenant == CAROL`. The intermediate transfer (ALICE→BOB→CAROL) is invisible to the protocol; only the burn-time sender is recorded. Documents **P2** under multi-hop transfers: the protocol does not track custody, only mint-time and burn-time. |
| **[new] B6** | `burn(cap, ctx)` on a cap whose `escrow_id == @0x0` (via N6 setup) | Event `escrow_id == @0x0`, `tenant == sender`. Symmetric with N6 — burn path makes no stronger claim than mint path. |

### 6.3 `escrow_id`

| # | Description | Expected |
|---|---|---|
| G1 | `escrow_id(&cap)` on a freshly-minted cap with `escrow_id = @0xE5C1` | Returns `@0xE5C1`. |
| G2 | Call `escrow_id(&cap)` five times in a row on the same cap | All five calls return the same `ID`. Asserts the getter is pure (no mutation, no event emission). Encoded as a loop predicate inside one `#[test]`. |
| G3 | `escrow_id(&cap)` where `cap.escrow_id == @0x0` (via N6) | Returns `@0x0`. The getter does not filter zero IDs. |

### 6.4 Lifecycle

| # | Description | Expected |
|---|---|---|
| L1 | tx1: `let (cap, id) = new(@0xE5C1, ALICE, ctx); transfer::public_transfer(cap, ALICE);` (sender = ALICE). tx2: ALICE retrieves cap, asserts `escrow_id(&cap) == @0xE5C1`, calls `burn(cap, ctx)`. | Full lifecycle. tx1: 1 Minted event. tx2: 1 Burned event. Both events share `(tenant_cap_id, escrow_id)`. Mint `tenant == ALICE`, Burn `tenant == ALICE`. |
| L2 | tx1: mint cap A to ALICE (push). tx2: mint cap B to BOB (push, same escrow). | Staleness mechanic relies on distinct IDs. Two Minted events with distinct `tenant_cap_id`, identical `escrow_id`, distinct `tenant`. cap A is stale from the indexer's perspective the moment cap B is minted (though neither cap knows it — staleness is a rental_escrow-side state read). |
| L3 | After L2 setup, tx3: ALICE retrieves cap_A and calls `burn(cap_A, ctx)`. | Holder cleans up regardless of any escrow state. `TenantCapBurned { tenant_cap_id = id_A, escrow_id = @0xE5C1, tenant: ALICE }` emitted. cap B remains in BOB's wallet untouched. |
| L4 | Multi-stale cleanup: extend L2 so three caps are minted (and pushed) for the same escrow to (ALICE, BOB, ALICE) across three txs, then ALICE burns both of her caps in a fourth tx. | Four txs total: three Minted events with matching `escrow_id` and distinct `tenant_cap_id`; the burn tx emits two `TenantCapBurned` events in burn order, each carrying its cap's `(tenant_cap_id, escrow_id, tenant: ALICE)`. Asserts lifecycle independence of multiple stale caps held by the same address. |
| L5 | Mint two caps for **different** escrows (`@0xE5C1` to ALICE, `@0xE5C2` to ALICE; pushed). Next tx: ALICE burns them both in reverse order. | tx1: two Minted events in mint order. tx2: two Burned events in burn order. The PK-JOIN path `TenantCapMinted.tenant_cap_id = TenantCapBurned.tenant_cap_id` recovers the mint/burn pair for each cap independently — the two lifecycles do not cross. |
| **[new] L6** | **One-shot PTB lifecycle (return-by-value).** tx1: a single function `mint_then_burn_for_testing(escrow_id, tenant, ctx)` calls `let (cap, _) = new(escrow_id, tenant, ctx); burn(cap, ctx);` — no transfer in between. | Mirrors the production "tenant-as-code" pattern where `rent()` returns the cap and the same PTB consumes it without ever touching a wallet. tx1: 1 Minted + 1 Burned event in the same tx. Both `tenant` fields equal `tx_context::sender(ctx)` (= the mint argument). Documents **P5** return-by-value channel: the cap can live entirely as a PTB local. |

**[property] P-SE — star-schema envelope invariants.** For every
row above that asserts an event:
1. `tenant_cap_id` field is present and equal to `object::id(&cap)` —
   child PK that lets an indexer PK-JOIN Minted and Burned rows.
2. `escrow_id` field is present and equal to the value recorded at
   mint.
3. `tenant` field is present on **both** Minted and Burned events.
   On Minted: the mint-time argument (first-observed). On Burned:
   `tx_context::sender(ctx)` at burn time (potentially distinct under
   `key + store` — see B4, B5). Both are first-observed, neither is
   PK-recoverable from the other.
4. No Sui envelope metadata (tx_digest, tx sender at the envelope
   layer, transfer events) is relied on for identity. The pair
   `(tenant_cap_id, escrow_id)` alone is sufficient to locate the cap
   across its lifecycle; `tenant` on each row is the address actor
   for that specific event.

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
- **Transfer to `@0x0`.** `transfer::public_transfer(cap, @0x0)` executes
  at the Sui framework layer; the cap becomes irretrievable.
  `tenant_cap` does not guard against this. If any rental_escrow call
  site could route a zero address into the push channel, it would
  create an uncollectable cap and a zombie `current_tenant_cap_id`.
  Verify during `rental_escrow` audit that `do_handover` guarantees
  non-zero `pending_tenant_address`.
- **Emit-last assertion granularity (N7).** Rows above assert the event
  is present in tx effects but do not assert the *intra-tx ordering*
  of `event::emit` vs the surrounding return-by-value or downstream
  push. Sui's tx effects do not expose fine-grained intra-tx ordering
  through `test_scenario`; the §4 `new` step order is a source-level
  invariant verified by code review, not by runtime tests.
- **Double-mint structural note (N2).** This module allows two `new`
  calls for the same `(escrow_id, tenant)` pair. Verify during
  `rental_escrow` audit that no path invokes `new` twice for the
  same logical transition; if one does, this module needs a runtime
  guard and §1 gains an error constant.


7. MODULE BOUNDARY
------------------

`tenant_cap.move` exports:

| Symbol | Visibility | Notes |
|---|---|---|
| `TenantCap` (type) | `public` | `key + store`. Symmetric with `OwnerCap`. One per tenant transition event. Two delivery channels (return-by-value from `rent`, push from `do_handover`); neither inside this module. |
| `TenantCapMinted` (event) | `public` | `copy + drop`. Emitted by `new`. Carries `(tenant_cap_id, escrow_id, tenant)` — `tenant` is the mint-time first-observed address. |
| `TenantCapBurned` (event) | `public` | `copy + drop`. Emitted by `burn`. Carries `(tenant_cap_id, escrow_id, tenant)` — `tenant` is the burn-time `tx_context::sender(ctx)`. Under `key + store` it may differ from `TenantCapMinted.tenant`. |
| `new(escrow_id, tenant, ctx): (TenantCap, ID)` | `public(package)` | Pure constructor + emitter. Builds the cap, emits `TenantCapMinted`, returns `(cap, cap_id)` by value. No transfer. Called by `rental_escrow::rent` (return-by-value path) and `rental_escrow::do_handover` (which then pushes via `transfer::public_transfer`). |
| `burn(cap, ctx)` | `public` | Voluntary destroy for gas recovery. No state mutation. Emits `TenantCapBurned { tenant_cap_id, escrow_id, tenant: tx_context::sender(ctx) }`. The burning address is genuinely new information under `key + store` and is not PK-recoverable from `TenantCapMinted`. |
| `escrow_id(cap): ID` | `public` | Getter. Read by `rental_escrow` at `borrow_asset` to compare against the target escrow's ID inline (abort constants `E_WRONG_ESCROW_TENANT_CAP` and `E_STALE_TENANT_CAP` live in rental_escrow). |

**No abort codes exported.** The two gating checks that used to
live here as `assert_escrow` / `assert_current` have moved to
`rental_escrow::borrow_asset` as inline asserts with rental-side
constants — "wrong escrow" and "stale" are the consumer's
semantics, not the cap's.

**Depends on:** `sui::object`, `sui::event`. (No `sui::transfer`
dependency — `new` does not transfer; pushes happen at the call site
in `rental_escrow` via `transfer::public_transfer`.)


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
