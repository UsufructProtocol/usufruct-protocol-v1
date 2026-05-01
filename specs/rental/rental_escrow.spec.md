RENTAL_ESCROW MODULE — SPECIFICATION
=====================================

Module: `rental_escrow`
Design reference: design-compact.md §1 (state machine), §2 (access model),
  §3 (fund flows), §4 (handover countdown), §6 (integration parameters / retire),
  §9 (lazy evaluation)
Module map reference: module-map.spec.md §10
Depends on: `math`, `curve_shape`, `price_function`, `config`, `owner_cap`,
  `tenant_cap`, `protocol_fee_inbox`, `fee_message`


0. MODULE RESPONSIBILITY
------------------------

`rental_escrow` owns the central `RentalEscrow<Asset, CoinType>` shared
object, the `EscrowState` enum (the single public state type that fuses
asset custody, tenant data, and phase metadata into one variant-typed
value), the protocol state machine, the lazy-settlement engine
(`apply_pending_transitions`), all public entry points, and the fund
distribution logic for every boundary event.

**Owns:**

- `RentalEscrow<phantom Asset, phantom CoinType>` — `key` only. One shared
  object per integrated asset. Holds the immutable `IntegrationConfig`,
  the inbox-id snapshot, integration timestamp, accumulated owner
  earnings, and a single `Option<EscrowState<Asset, CoinType>>` field
  carrying everything the state machine needs for the current variant.
- `EscrowState<Asset: key + store, phantom CoinType>` — public enum,
  five variants: `Idle | AtDutchAuction | HandoverOpen | HandoverConfirmed
  | Retired`. `store` only — variants embed linear payload (`Asset`,
  `Balance<CoinType>` via `Tenant`), so `copy` and `drop` cannot
  propagate. Always wrapped in `Option` at the struct level (see §2.4).
- `Tenant<phantom CoinType>` — public struct with `store`. Groups the
  three fields that always co-exist for a tenant slot: `cap_id: ID`,
  `address: address`, `stake: Balance<CoinType>`. Embedded inside the
  `HandoverOpen` and `HandoverConfirmed` variants of `EscrowState`.
- `EscrowStateTag` — public enum, `copy + drop + store`. A discriminator-
  only mirror of `EscrowState`'s five variants without the linear
  payload. Returned by `apply_pending_transitions` and `retire`, and
  used as the type of `from_state` / `next_state` / `state_at_set`
  fields in events. The state machine itself lives in `EscrowState`;
  `EscrowStateTag` exists because events must be `copy + drop` and
  cannot carry the linear payload.
- `AssetReceipt` — hot potato struct with no abilities. Created by
  `borrow_asset`, consumed by `return_asset` in the same PTB.
- `StateReceipt` — internal hot potato struct with no abilities.
  Private to the module. Produced by `take_state`, consumed by
  `put_state`. Enforces P13 (`Option<EscrowState>` is `Some` at every
  transaction boundary) at the type level — see §2.6.
- All public entry points: `integrate`, `rent`, `retire`, `claim_asset`,
  `withdraw_earnings`, `borrow_asset`, `return_asset`, `burn_tenant_cap`,
  `apply_pending_transitions`.
- Public read-only queries: `compute_used_credit`, `compute_floor_price`,
  `state_tag`.
- Private state-cell helpers: `take_state`, `put_state`, `read_state`
  (§2.6 — enforce P13 / P_READ).
- Private price helpers: `compute_price_descent`,
  `compute_next_rent_price` (backing `compute_floor_price`).
- Private transition helpers (P_DO flavor a — state-window owners,
  each owning a single take/put cycle): `do_auction_expiry`,
  `do_install_new_tenant`, `do_place_bid`, `do_supersede_bid`,
  `do_retire_immediately`, `do_set_retiring_flag`, `do_extract_asset`,
  `do_fill_asset`, `do_distribute_balance`, `do_rotate_for_handover`,
  `do_terminate_tenure`.
- Private transition orchestrators (P_DO flavor b — compose two
  sub-step `do_*` helpers): `do_handover` (= `do_distribute_balance` +
  `do_rotate_for_handover`), `do_tenure_expiry`
  (= `do_distribute_balance` + `do_terminate_tenure`).
- Private utility helpers (no take/put window): `split_fee`,
  `settle_tenant`, `pay_tenant_remain`, `pay_protocol_fee`,
  `register_pending_bid`.
- Protocol state-machine events: `AssetIntegrated`, `RentStarted`,
  `BidPlaced`, `BidSuperseded`, `HandoverCompleted`, `TenureExpired`,
  `AuctionExpired`, `RetireFlagSet`, `AssetRetired`, `AssetBorrowed`,
  `AssetReturned`, `AssetClaimed`, `EarningsWithdrawn`.

**Does not own:**

- `IntegrationConfig` construction or validation — lives in `config`.
- `CurveShape` / `PriceFunction` construction or evaluation — lives in
  `curve_shape` / `price_function`.
- `OwnerCap` / `TenantCap` struct definitions or mint/burn internals —
  live in `owner_cap` / `tenant_cap`. This module calls their constructors
  and destructors.
- `FeeMessage<C>` type or the drain path — lives in `fee_message`. This
  module only calls `fee_message::post` at boundary events where a
  non-zero protocol fee exists; construction, transfer-to-inbox and
  event emission are fused inside that call.
- `ProtocolFeeInbox` / `ProtocolFeeRef` — live in `protocol_fee_inbox`.
  This module reads `inbox_id(&fee_ref)` at `integrate` to store the
  inbox ID.
- Raw arithmetic (`mul_div`, roots, exp) — lives in `math`.

**Dependency direction:** every other module is independent of
`rental_escrow`. This module is the single integration point: it consumes
all others and is consumed by none.

**Key design properties:**

- **Single shared object per instance.** The only shared object on the
  critical path is `RentalEscrow` itself. `FeeMessage<C>` routing uses
  transfer-to-object (free) and the drain path uses the owned
  `ProtocolFeeInbox` (fastpath). No consensus cost beyond the escrow.
- **Lazy evaluation.** No keeper, no off-chain coordinator. All elapsed
  boundary events are resolved by `apply_pending_transitions`, which
  every public mutating function calls before its own logic. Making it
  public also lets keepers, frontends, and `devInspectTransactionBlock`
  settle state without performing a full protocol operation.
- **All tenant fund deliveries are pushes.** `remain_credit`, superseded
  bid refunds, and `TenantCap` are all pushed to the address registered
  at mint. Owner uses pull (`withdraw_earnings`, `claim_asset`).
- **Push-before-rotate invariant** (inside `do_handover`): balances and
  caps are pushed to the current/pending addresses before those address
  fields are overwritten.
- **Asset always present while escrow exists, custody encoded by
  variant.** Asset custody is structurally encoded by the active
  `EscrowState` variant. `Idle`, `AtDutchAuction`, and `Retired` carry
  `asset: Asset` directly — present unconditionally. `HandoverOpen` and
  `HandoverConfirmed` carry `asset: Option<Asset>` so `borrow_asset` can
  extract the asset for the PTB borrow window via `option::extract` and
  `return_asset` restores it via `option::fill`. The `None` window
  inside those variants exists only between `borrow_asset` and
  `return_asset` within a single PTB — never across transaction
  boundaries. The invariant is enforced by the hot-potato `AssetReceipt`,
  not by the type. The variants without tenants do not need `Option`
  because no `borrow_asset` path admits them — staleness rejects every
  cap before reaching the asset.
- **Type-level invariants for tenant data.** Tenant cap-id, address, and
  stake are grouped into a single `Tenant` struct embedded inside
  `HandoverOpen` (one tenant) and `HandoverConfirmed` (two tenants —
  current + pending). The variants without tenants (`Idle`,
  `AtDutchAuction`, `Retired`) cannot carry tenant data — there is no
  field to populate. The previous design's five `Option` fields and the
  `tenant_slot` enum are both gone; the variant of `EscrowState` IS the
  tenant-presence discriminator.
- **`Option<EscrowState>` at the struct level enables variant
  transitions, gated by a private hot-potato (`StateReceipt`).** A
  field accessed via `&mut` cannot have its variant changed in place —
  Move's borrow checker forbids it because variant transitions imply
  destruction of the old fields, which requires ownership.
  `Option<EscrowState>` provides the swap mechanism:
  `option::extract(&mut escrow.state)` takes ownership of the current
  variant, the function constructs the new variant, and
  `option::fill(&mut escrow.state, new_state)` puts it back. To
  prevent accidentally forgetting the `fill` (which would brick the
  escrow — see §2.6 / P13), every mutating site uses the private
  `take_state` / `put_state` helpers (§2.6) instead of the raw
  `option` API. `take_state` returns a `StateReceipt` hot potato that
  must be consumed by `put_state` or by `abort`, enforced by Move's
  linear type system. The `None` window exists only mid-function
  within a single Move call; no public function exposes it. The
  pattern is identical to the asset-borrow pattern (`Option<Asset>`
  inside Rented variants), just one level up.
- **Capability-based authorization.** `retire`, `claim_asset`, and
  `withdraw_earnings` take `&OwnerCap` and assert inline
  `owner_cap::escrow_id(cap) == object::id(escrow)` (aborts
  `E_WRONG_ESCROW_OWNER_CAP`). `borrow_asset` takes `&TenantCap` and
  checks both cap/escrow binding and `object::id(cap) ==
  state.HandoverOpen.current.cap_id` (or its `HandoverConfirmed`
  equivalent) inline. Cap modules expose only getters and lifecycle;
  the gating predicates and their abort codes live here, where the
  operation semantic lives. No address check is performed anywhere.

**Design philosophy — runtime invariants migrated to compile-time
invariants.** This module is governed by the principle commonly named
*"make illegal states unrepresentable"*: every invariant that the
type system can express is encoded structurally, so the compiler — not
the test suite, not the implementer's discipline — guarantees it. The
guiding rule is:

> Each runtime invariant is a latent bug. Each compile-time invariant
> is an impossible bug.

The current shape of `EscrowState`, `Tenant`, `RentalEscrow`,
`AssetReceipt`, and `StateReceipt` is the result of repeatedly
applying that rule across the module's history. The design did not
arrive in one step; it accreted through a sequence of refactors,
each one identifying a runtime check (an `assert`, a "this is always
true" comment, an inline invariant comment) and asking *can the type
system express this?* When the answer was yes and the cost was
acceptable, the check moved out of the runtime and into the type
declaration.

**Catalog of migrations encoded in the current design:**

| Invariant | Before | After |
|---|---|---|
| Tenant `cap_id` and `address` always co-present | 2 separate `Option` fields with sync invariant | atomic fields inside `Tenant` struct (§2.2) |
| `handover_countdown_expiry` exists iff pending bid exists | `Option<u64>` + sync convention | plain `u64` field inside `HandoverConfirmed` variant only (§2.3) |
| No trapped balances in `Retired` (P2) | runtime `balance::destroy_zero` asserts on terminal sweep | `Retired { asset }` variant has no `stake` field — destruction unnecessary (§2.3, §4.3) |
| Tenancy ↔ Rented variant (P9) | `tenant_slot != Vacant ⇔ state == Rented(_)` runtime invariant | tenant fields exist only inside `HandoverOpen` and `HandoverConfirmed` variants (§2.3) |
| Pending bid ↔ HandoverConfirmed (P10) | `pending_bid > 0 ⇔ state == Rented(HandoverConfirmed)` runtime invariant | `pending: Tenant` exists only inside `HandoverConfirmed` variant (§2.3) |
| Retire flag scope | `bool` field permanent + runtime "only meaningful while tenant active" | `retiring: bool` exists only inside Rented variants; `Retired` is the terminal expression (§2.3) |
| `last_acquisition_price` only read in `AtDutchAuction` | permanent struct field + "inert in Rented" comment | field exists only inside `AtDutchAuction` variant (§2.3) |
| `phase_start_ms` only meaningful in 3 variants | permanent struct field | field exists only in variants that consume it (§2.3) |
| Asset always present except in PTB borrow window (P11) | `Option<Asset>` permanent + "None only inside PTB" prose | `Asset` directly in 3 variants; `Option<Asset>` only in the 2 variants where `borrow_asset` can extract (§2.3) |
| Borrow → return paired in same PTB | (preexisting) `AssetReceipt` hot potato (§2.5) — linear type forces consumption |
| `Option<EscrowState>` is `Some` at every tx boundary (P13) | convention enforced by inspection of every mutating function | `StateReceipt` hot potato + `take_state` / `put_state` helpers (§2.6) — linear type forces `put_state` or `abort` |

**What stays runtime, and why.** Type-level enforcement is not always
the right call; sometimes the cost of the encoding exceeds the cost
of the runtime check. Three categories of remaining runtime checks:

1. **Inherently runtime — depend on external input.**
   Payment amounts (`coin::value(&payment) >= floor`), wall-clock
   thresholds (`clock::timestamp_ms() >= integrated_at_ms +
   retire_floor`), and capability/escrow pairing
   (`owner_cap::escrow_id(cap) == object::id(escrow)`) cannot be
   type-level: the values come from outside the contract at call time
   and are first observable in the function body.

2. **Pragmatically runtime — encoding cost exceeds benefit.**
   `E_PENDING_TENANT_CAP` / `E_STALE_TENANT_CAP` (cap-id comparisons
   against the active variant's tenant fields) could in principle be
   type-level if `TenantCap` were phantom-typed by escrow-id, but
   that refactor would propagate generics through every cap-handling
   call site for marginal gain. `E_ASSET_ALREADY_BORROWED` (the
   `is_some` check on the variant's asset slot) could be eliminated
   with a session-typed borrow protocol, at the cost of a
   substantially more complex API. `E_ALREADY_RETIRED` (boolean
   check on `retiring`) could be a type-state, but escrow being a
   shared object makes type-state encoding awkward in Sui.

3. **Structurally unreachable but Move requires the abort
   (`E_INVARIANT_VIOLATION`).**
   Per-variant abort arms inside the `do_*` helpers (variants other
   than the helper's documented precondition) and inside `return_asset`'s
   dispatch (terminal variants, unreachable by PTB clock-fixity §6.1)
   are structurally unreachable along every public-API path —
   guaranteed by `apply_pending_transitions`'s dispatch ordering, by
   `read_state`-driven dispatch in the public functions that delegate
   to `do_*` helpers, and by PTB clock-fixity. Move's exhaustiveness
   check still requires the arm.

   These arms abort `E_INVARIANT_VIOLATION = 0xDEADC0DE` (category B,
   §1.1) — a single magic number that flags "programmer error, not
   user error" in any logging or indexing pipeline. Same magic number
   is used by `take_state` / `put_state` / `read_state` for the
   explicit `option::is_some` / `option::is_none` asserts that
   protect P13 (state cell `Some` at every tx boundary), so a P13
   violation surfaces as `E_INVARIANT_VIOLATION` rather than the
   generic `option::EOPTION_NOT_SET` (262145).

   Eliminating these arms would require a finer-grained dispatch
   type — a possible future refactor, deferred. Move 2024 requires
   explicit per-variant binding for non-`drop` fields, so the
   pseudocode in §7 spells out each unreachable arm individually
   (`EscrowState::Idle { asset: _a } => abort E_INVARIANT_VIOLATION`,
   etc.) rather than collapsing them with a wildcard `_` or
   `{ .. }` (both of which would discard the linear payload —
   rejected by the type system).

**Directional rule for future work.** Any future refactor of this
module — and, by extension, any new code added to it — should default
to the same direction:

1. Identify a runtime invariant. Look for `assert!` calls in private
   helpers, prose comments saying *"this is always X"* or *"X is
   present iff Y"*, and properties listed in §9 that are enforced by
   convention rather than by structure.
2. Ask whether the type system can express the invariant: a variant
   field, a struct grouping, a phantom type, a linear hot potato.
3. Estimate the migration cost: lines of code, ripple through call
   sites, generics propagation, API surface change.
4. If `migration cost < runtime-bug risk × likelihood`, migrate.
5. New mutating functions added to the module *must* use `take_state`
   / `put_state` (never raw `option::extract` / `option::fill` on
   `escrow.state`); new tenant-data flows *must* be expressed through
   variant fields, never through parallel struct-level fields with a
   sync invariant.

The pattern is self-reinforcing: each migration eliminates an
assertion, a comment, and a test branch — and exposes the next
candidate invariant by simplifying the code around it. `StateReceipt`
itself emerged this way: it became visible only after `EscrowState`
moved into `Option<EscrowState>` at the struct level, which made the
question *"who guarantees state is always Some?"* askable. Before the
aglutinador refactor, the question had no precise referent.

**Design conventions — runtime invariants the type system does not
encode.** Two protocol-level conventions, P_READ and P_DO, supplement
the structural invariants above. Both are author-discipline rules
(not compile-time guarantees), but each carries a runtime witness so
violations abort with `E_INVARIANT_VIOLATION` rather than silent
corruption. Their canonical statements live here in §0 because they
are module-wide and discussed in multiple sections (§2.6, §5–§7).

**P_READ — `read_state` is the sole reader of `escrow.state` and is
never called inside a take/put window.**

`read_state` (§2.6) is the only function in the module that calls
`option::borrow(&escrow.state)`. Every public dispatch (`rent`,
`retire`, `borrow_asset`, `return_asset`, `burn_tenant_cap`, APT)
and every read-only query (`compute_used_credit`,
`compute_floor_price`) goes through it. The function asserts
`option::is_some(&escrow.state)` first; a violation aborts
`E_INVARIANT_VIOLATION` rather than the generic
`option::EOPTION_NOT_SET`. The convention also forbids calling
`read_state` between a `take_state` and its matching `put_state` —
that window is the only time the cell is `None`, and reading it
there would trip the assert. Authors must verify on inspection that
no `do_*` helper reaches `read_state` while holding a live receipt.

| Guarantee                                         | Level         |
|---|---|
| `put_state` always follows `take_state` in same PTB (`StateReceipt` has no `drop` — hot potato) | compile-time |
| `read_state` not called while state is `None` (Move type system cannot track `Option` contents) | convention |
| No external code touches `escrow.state` directly (field is private; take/put/read are private) | compile-time |

**Required test.** To pin the runtime behaviour, the test suite
must include an `expected_failure` row that opens a take/put window
and calls `read_state` inside it:

```move
#[test, expected_failure(abort_code = usufruct::rental_escrow::E_INVARIANT_VIOLATION)]
fun test_read_state_aborts_inside_take_put_window() {
    // ... set up a minimal RentalEscrow in a test scenario ...
    let (state, receipt) = take_state(&mut escrow);
    let _ = read_state(&escrow);                      // P_READ violated — must abort
    put_state(&mut escrow, state, receipt);           // unreachable
}
```

**Maintenance rules:**

1. `read_state` is private — only module-internal code can introduce
   a violation; no external caller can trigger it.
2. Any new internal function that calls `read_state` must be audited
   to confirm it is never reachable from a call stack that holds a
   live `StateReceipt`.
3. Functions that call `take_state` must call `put_state` before any
   branch that could reach `read_state`. The compiler enforces that
   `put_state` is called before the end of the PTB; it does not
   enforce call ordering within the body — that ordering is the
   author's responsibility.

**P_DO — `do_*` prefix iff a function performs a state-machine
transition (single-step or composed).**

A private function in this module carries the `do_*` prefix iff its
body either (a) owns a `take_state` / `put_state` window directly,
or (b) orchestrates two or more `do_*` sub-steps in sequence. Every
state mutation is funneled through a `do_*`; no non-`do_*` function
owns a take/put window.

**Two flavors of `do_*`:**

| Flavor | Body shape | Examples |
|---|---|---|
| **(a) state-window owner** | contains `take_state` and `put_state` directly | `do_install_new_tenant`, `do_place_bid`, `do_supersede_bid`, `do_retire_immediately`, `do_set_retiring_flag`, `do_extract_asset`, `do_fill_asset`, `do_auction_expiry`, `do_distribute_balance`, `do_rotate_for_handover`, `do_terminate_tenure` |
| **(b) orchestrator** | no direct `take_state`; composes flavor-(a) `do_*` helpers back-to-back | `do_handover` (composes `do_distribute_balance` + `do_rotate_for_handover`), `do_tenure_expiry` (composes `do_distribute_balance` + `do_terminate_tenure`) |

| Guarantee                                                  | Level         |
|---|---|
| Every `do_*` function either owns a take/put window OR composes `do_*` sub-steps | convention |
| No non-`do_*` function owns a take/put window (public fns dispatch to `do_*` helpers instead) | convention |
| Every `take_state` pairs with a `put_state` in PTB (`StateReceipt` hot potato — see P_READ above) | compile-time |

**Why P_DO matters.** The state-mutating helpers form a category
with shared structural shape: `take_state` → match → mutation →
`put_state`. Marking them with a dedicated prefix makes the category
scannable and the contract auditable:

```
grep '^fun do_'                             # all state mutators (both flavors)
grep -B5 'take_state(escrow)' | grep '^fun' # state-window owners only (flavor a)
```

Window owners ⊆ `do_*` always. Orchestrators are `do_*` but not
window owners; they call window-owner `do_*` helpers instead.
Non-`do_*` functions never own a window. The convention encodes a
structural property — every state mutation is funneled through a
`do_*` — making the call graph self-documenting.

**Why orchestrators exist.** A transition may conceptually mutate
state more than once (e.g., handover redistributes the outgoing
tenant's balance, then rotates pending → current). Decomposing into
two `do_*` sub-steps, each with its own take/put, separates concerns
at the cost of one extra take/put cycle per transition. An
intermediate state value (e.g., `current.stake = balance::zero()`)
lives between the two sub-steps — transient and only observable
inside the orchestrator body, never at a transaction boundary
(P13).

**Maintenance rules:**

1. A new helper that calls `take_state` and `put_state` must be
   named `do_*` (flavor a).
2. A new public function that needs to mutate state must delegate to
   a `do_*` helper rather than open its own take/put window.
3. An orchestrator (flavor b) `do_*` that composes sub-step `do_*`
   helpers stays in the `do_*` family even though its body has no
   direct `take_state` call.
4. Sub-step `do_*` helpers may call each other only via the
   orchestrator; each link's receipt is consumed locally before the
   next sub-step takes state again. The intermediate state between
   sub-steps is structurally valid (a regular `EscrowState` variant)
   even if some inner field is in a transient sentinel state (e.g.,
   `current.stake = balance::zero()`).


1. CONSTANTS
------------

### 1.1 Error constants

All error constants are `public` so the SDK can map abort codes to
human-readable messages. All errors raised on the rental-flow paths —
including the cap-gating checks at `retire` / `claim_asset` /
`withdraw_earnings` / `borrow_asset` — live here. Cap modules
(`owner_cap`, `tenant_cap`) expose only lifecycle and getters; they
own no abort codes. The rationale: "wrong escrow", "stale tenant cap",
etc. are interpretations the consumer places on an ID mismatch — that
semantic belongs where the operation is being gated, not in the cap
type itself.

    public const E_NOT_RENTED:                  u64 = 0;   // compute_used_credit: state ∉ { HandoverOpen, HandoverConfirmed }
    public const E_INSUFFICIENT_PAYMENT:        u64 = 1;   // payment < floor price (all acquisition paths)
    public const E_RETIRE_FLAG_BLOCKS_BID:      u64 = 2;   // rent() during HandoverOpen with retiring flag set on the variant
    public const E_RETIRED_NO_BID:              u64 = 3;   // rent() / compute_floor_price: state is Retired (asset not rentable)
    public const E_RETIRE_FLOOR_NOT_ELAPSED:    u64 = 4;   // retire() before integrated_at_ms + retire_floor
    public const E_ALREADY_RETIRED:             u64 = 5;   // retire() when state is Retired or active variant has retiring=true
    public const E_NOT_RETIRED:                 u64 = 6;   // claim_asset() when state != Retired
    public const E_RECEIPT_ESCROW_MISMATCH:     u64 = 7;   // return_asset: receipt.escrow_id != object::id(escrow)
    public const E_RECEIPT_ASSET_MISMATCH:      u64 = 8;   // return_asset: receipt.asset_id != object::id(&asset)
    public const E_NO_EARNINGS:                 u64 = 9;   // withdraw_earnings: owner_earnings == 0 after settlement
    public const E_ASSET_ALREADY_BORROWED:      u64 = 10;  // borrow_asset: state.{HandoverOpen|HandoverConfirmed}.asset is None
    public const E_WRONG_ESCROW_OWNER_CAP:      u64 = 11;  // retire / claim_asset / withdraw_earnings: owner_cap::escrow_id(cap) != object::id(escrow)
    public const E_WRONG_ESCROW_TENANT_CAP:     u64 = 12;  // borrow_asset / burn_tenant_cap / return_asset: tenant_cap::escrow_id(cap) != object::id(escrow)
    public const E_PENDING_TENANT_CAP:          u64 = 13;  // borrow_asset: cap's ID matches state.HandoverConfirmed.pending.cap_id (handover not yet settled — caller should retry)
    public const E_STALE_TENANT_CAP:            u64 = 14;  // borrow_asset: cap's ID matches no live tenant (displaced or expired — caller should burn)
    public const E_TENANT_CAP_NOT_STALE:        u64 = 15;  // burn_tenant_cap: cap's ID matches a live current or pending tenant (still live — burning would orphan a state slot)
    public const E_INVARIANT_VIOLATION:         u64 = 0xDEADC0DE; // = 3_735_929_054 — programmer error, not user error. Raised in code paths that are structurally unreachable under the public API; protocol bugs distinguishable from user errors in logs and indexers.

**Two error categories.** The taxonomy above splits cleanly:

- **Category A — domain errors (codes 0–15).** Caller-visible
  conditions: precondition violations, payment shortfalls, capability
  mismatches, state-machine guards (`E_NOT_RENTED`, `E_RETIRED_NO_BID`,
  `E_NOT_RETIRED`, etc.). The SDK maps each to a user-facing message.
- **Category B — invariant violation (`0xDEADC0DE`).** Programmer
  error. Raised at code points the public API cannot reach: terminal
  match arms inside `do_*` helpers (variants other than the helper's
  precondition), the `option::is_some` / `option::is_none` asserts
  inside `take_state` / `put_state` / `read_state` (P13), the
  `MAX_APT_ITERATIONS` canary (§5.2), the unreachable `Retired` arm
  inside `rent()`'s dispatch (`compute_floor_price` aborts
  `E_RETIRED_NO_BID` first), and the unreachable terminal arms inside
  `return_asset` (PTB clock-fixity). A single magic number — no
  per-site discrimination — because every site is unreachable in
  correct operation; distinguishing them on-chain would suggest one
  could fire normally. Logs and indexers see the magic value and know
  to escalate, not to retry.

The previous design had `E_UNEXPECTED_STATE = 16` as a single
catch-all with two roles fused (a "category-A" precondition error for
some callers and a "category-B" structural assertion for others). The
new taxonomy is the result of splitting those roles: `E_RETIRED_NO_BID`
for the read query asking the floor on a retired escrow,
`E_NOT_RENTED` for `compute_used_credit` on a non-Rented variant,
`E_NOT_RETIRED` for `claim_asset` outside Retired — all category-A
domain errors with named user-facing semantics — and
`E_INVARIANT_VIOLATION` for the structural-assertion role.

### 1.2 Protocol constants

Named protocol parameters used by `split_fee` (§7.4). Internal — the SDK
reads the actual fee split via `HandoverCompleted.protocol_fee` /
`TenureExpired.protocol_fee` event fields, not by reading the constant.

    const PROTOCOL_FEE_BPS: u64 = 1_000;   // 10% of the stake-settlement base
    const BPS_PER_UNIT:     u64 = 10_000;  // basis-point denominator (100% == 10_000 bps)
    const MAX_APT_ITERATIONS: u64 = 4;     // canary upper bound on the APT match-while loop (§5.2)

`BPS_PER_UNIT` is spelled identically to `price_function::BPS_PER_UNIT`
by convention — the basis-point denominator is a module-scoped name in
each module that needs it; `math` is deliberately not burdened with a
protocol-policy constant.

`MAX_APT_ITERATIONS = 4` upper-bounds the APT loop (§5.2). The state
lattice `HandoverConfirmed → HandoverOpen → {Retired | AtDutchAuction
→ Idle}` admits at most 3 strictly progressive transitions plus one
terminal no-op iteration. A higher count signals a `do_*` bug producing
a non-progressive state; the loop aborts with `E_INVARIANT_VIOLATION`
instead of silently spinning to gas exhaustion. Pure runtime canary —
the compile-time termination argument is the lattice itself.


2. TYPES
--------

### 2.1 EscrowStateTag — public discriminator enum

```move
public enum EscrowStateTag has copy, drop, store {
    Idle,
    AtDutchAuction,
    HandoverOpen,
    HandoverConfirmed,
    Retired,
}
```

**Abilities:** `copy + drop + store`. All variants are payload-free, so
ability propagation is trivially satisfied.

**Purpose.** A discriminator-only mirror of `EscrowState`'s five
variants. Used in two places, both of which require `copy + drop`:

1. **Event field type.** `RentStarted.from_state`,
   `TenureExpired.next_state`, `RetireFlagSet.state_at_set`, and
   `AssetRetired.from_state` carry the state-machine context for the
   indexer. Events require `copy + drop`; `EscrowState` has neither
   (linear payload), so the tag is the only type that can ride on an
   event.
2. **Return type of `apply_pending_transitions` and `retire`.** Callers
   of these functions want to chain on the post-call state — "is the
   escrow now Retired? did the tenure expire?" — without pattern-matching
   the linear payload. Returning the tag gives them that signal as a
   plain copyable value.

**Mapping rule.** `state_tag(state: &EscrowState) → EscrowStateTag` is
the canonical projection — one variant per variant, names identical.
Defined in §8.7 as a `public` query so external callers can ask "what
variant is the escrow in?" without taking ownership of `EscrowState`.

**Why both types and not just one.** Collapsing into a single enum forces
an unpalatable trade. Either (a) the tag carries the linear payload —
losing `copy + drop` — and events break, or (b) the events carry only
discriminator info while the state machine fakes a wrapper around its
linear payload (the `Option<state> + auxiliary fields` pattern this
refactor specifically eliminates). Two types, one with payload and one
without, decouples the storage shape from the wire shape cleanly.

### 2.2 Tenant — public struct

```move
public struct Tenant<phantom CoinType> has store {
    cap_id:  ID,
    address: address,
    stake:   Balance<CoinType>,
}
```

**Abilities:** `store` only. `Balance<CoinType>` lacks `copy` and `drop`,
so neither propagates to `Tenant`.

**Purpose.** Cohesive grouping of the three fields that always co-exist
for a tenant slot: the `TenantCap`'s identity, the address-of-record
registered at mint time, and the stake balance the tenant funded. Under
the previous design these three fields lived as separate parallel
fields in `RentalEscrow` (`tenant_slot.X.cap_id`, `tenant_slot.X.address`,
`escrow.tenant_stake` for current; analogous trio for pending), with a
runtime-enforced invariant that they were always set or cleared together.
With `Tenant`, the invariant is type-level: the three fields share one
storage cell, and every operation that touches one touches all three by
construction.

**Field semantics:**

| Field | Meaning |
|---|---|
| `cap_id` | ID of the `TenantCap` minted for this tenant. The only ID that passes the `borrow_asset` identity check. |
| `address` | Address registered at mint time. Recipient of `remain_credit` pushes at handover, of refund pushes at supersede, and the protocol's address-of-record for this tenant. Independent of where the cap is currently held — the cap may have changed hands under `key + store` transferability, but the protocol commits only to the placer's recorded address. |
| `stake` | Balance the tenant funded. For `current`, this is the active tenancy's stake (consumed by `compute_used_credit` and split 90/10 at handover or tenure expiry). For `pending`, this is the bid amount — non-zero by construction (the variant exists only when a pending bid was accepted). |

**Why a struct, not an enum.** A tenant slot has exactly one shape —
all three fields are always present together. There is no NoBalances /
WithBid alternative, no transient state where one field is set without
the others. An enum would model variation that does not exist; a struct
captures the cohesion accurately.

**Two embedding sites:**

- `EscrowState::HandoverOpen.current: Tenant<CoinType>` — the active
  tenant only.
- `EscrowState::HandoverConfirmed.current: Tenant<CoinType>` and
  `EscrowState::HandoverConfirmed.pending: Tenant<CoinType>` — both
  tenants atomically.

### 2.3 EscrowState — public enum

```move
public enum EscrowState<Asset: key + store, phantom CoinType> has store {
    Idle {
        asset: Asset,
    },
    AtDutchAuction {
        asset:                  Asset,
        phase_start_ms:         u64,
        last_acquisition_price: u64,
    },
    HandoverOpen {
        asset:           Option<Asset>,
        phase_start_ms:  u64,
        current:         Tenant<CoinType>,
        retiring:        bool,
    },
    HandoverConfirmed {
        asset:                     Option<Asset>,
        phase_start_ms:            u64,
        current:                   Tenant<CoinType>,
        pending:                   Tenant<CoinType>,
        retiring:                  bool,
        handover_countdown_expiry: u64,
    },
    Retired {
        asset: Asset,
    },
}
```

**Abilities:** `store` only. Every variant embeds linear payload —
`Asset` (always; `key + store`, no `copy`/`drop`), `Tenant<CoinType>`
(in the two Rented variants; carries `Balance<CoinType>` which lacks
`copy`/`drop`), `Option<Asset>` (in the two Rented variants; carries
`Asset`). Any variant precludes `copy` and `drop`, so the enum has
neither.

**Variant semantics:**

| Variant | Meaning | Asset carrier | Tenant data |
|---|---|---|---|
| `Idle` | No tenant. Asset available at `min_rent_price`. Entry: `rent()`. | `asset: Asset` | none — the variant has no tenant fields, so no tenant can exist by construction |
| `AtDutchAuction` | Price descends from `last_acquisition_price` toward `min_rent_price`. See `compute_price_descent` (§8.2). | `asset: Asset` | none |
| `HandoverOpen` | Current tenant holds exclusive access. No pending bid. May be the entry state after `do_install_new_tenant` (Idle / AtDutchAuction → here) or after `do_handover` (HandoverConfirmed → here). | `asset: Option<Asset>` — `None` only inside a PTB borrow window | `current: Tenant` |
| `HandoverConfirmed` | Current tenant holds access until `handover_countdown_expiry`. A pending tenant has paid `>= next_rent_price`. | `asset: Option<Asset>` — `None` only inside a PTB borrow window | `current: Tenant` + `pending: Tenant` |
| `Retired` | Terminal. The state machine has reached a point where the asset is extractable via `claim_asset`. | `asset: Asset` | none |

**Variant fields:**

- **`asset`.** Carries the integrated asset. In the three states with no
  tenant (`Idle`, `AtDutchAuction`, `Retired`), `asset: Asset` directly
  — no `Option` because no public function reaches `asset` from these
  variants (`borrow_asset` aborts on staleness before touching the
  asset; `claim_asset` is the only consumer and only fires on `Retired`).
  In the two Rented variants, `asset: Option<Asset>` to support the PTB
  borrow window — `borrow_asset` extracts via `option::extract`,
  `return_asset` restores via `option::fill`, both within a single PTB.
- **`phase_start_ms`.** Timestamp at which the current phase began. Set
  by the transition that produced the variant (see §5 transition
  table). Read by `compute_used_credit` (Rented variants) and
  `compute_price_descent` (AtDutchAuction); APT (§5.2) and `do_place_bid`
  (§7.10) compute boundary timestamps as `phase_start_ms + tenure_ceiling`
  / `phase_start_ms + descent_ceiling` inline at the destructure site.
  Idle and Retired do not need it (no time-dependent semantics; descent
  starts only when the tenant exits via tenure expiry).
- **`last_acquisition_price`** (`AtDutchAuction` only). Frozen at the
  moment the prior tenant exited via `do_tenure_expiry` — equals the
  outgoing tenant's `current.stake.value()` before settlement. Used by
  `compute_price_descent` as the descent ceiling: `price_descent(t) =
  last_acquisition_price − (last_acquisition_price − min_rent_price) ·
  h(t)`. Not needed in any Rented state — the floor for takeover or
  supersede reads `current.stake` / `pending.stake` directly.
- **`current` / `pending`.** `Tenant<CoinType>` slots; see §2.2.
- **`retiring`** (`HandoverOpen` and `HandoverConfirmed` only). `true`
  iff `retire()` was called while a tenant was active. Causes `rent()`
  to abort `E_RETIRE_FLAG_BLOCKS_BID` when a new bid is attempted on
  `HandoverOpen` (the current tenant runs to expiry, then `Retired`
  fires via `do_tenure_expiry`). Inherited across `do_handover`: when
  `HandoverConfirmed` rotates to `HandoverOpen` for the new tenant,
  the boolean is preserved verbatim.
- **`handover_countdown_expiry`** (`HandoverConfirmed` only). Boundary
  timestamp at which `do_handover` fires. Set at the first bid that
  produced `HandoverConfirmed`; not altered by supersede.

**Type-level invariants (previously implicit, now structural):**

1. **Asset present iff escrow holds it.** Every variant carries the
   asset somewhere — directly (3 variants) or wrapped in `Option`
   (2 variants). The asset cannot be lost at the variant boundary.
2. **Tenant data exists iff there is a tenant.** Tenant fields appear
   only in `HandoverOpen` and `HandoverConfirmed`. The other three
   variants cannot carry tenant data — no field to populate.
3. **Pending tenant exists iff a pending bid was accepted.** The
   `pending` field appears only in `HandoverConfirmed`, atomically
   alongside `handover_countdown_expiry`. There is no representable
   state with a pending bid but no countdown, or vice versa.
4. **`retiring` flag exists only while a tenant is active.** Storing it
   inside the Rented variants makes "retire flag set on a state with no
   tenant" a non-representable state. The `Retired` variant is the
   terminal expression of "retire was set on Idle/AtDutchAuction" —
   the flag transitions directly into the variant rather than being
   carried as a separate boolean.
5. **`last_acquisition_price` exists only where it is read.** Only
   `AtDutchAuction` reads it (descent ceiling). The previous design
   stored it on every state and ignored it everywhere else; the new
   design places it where it is consumed.
6. **`phase_start_ms` exists only where it is read.** Only the three
   non-terminal variants with time-dependent semantics
   (`AtDutchAuction`, `HandoverOpen`, `HandoverConfirmed`) carry it.
7. **`handover_countdown_expiry` exists iff state is `HandoverConfirmed`.**
   Same structural argument as the previous `tenant_slot` design's
   countdown invariant, now lifted to the state enum directly.

**Transitions (single state-field assignment, atomic):**

| Operation | Before (variant of `EscrowState`) | After (variant of `EscrowState`) |
|---|---|---|
| `integrate` | (no escrow exists) | `Idle { asset }` |
| `do_install_new_tenant` from `Idle` (§7.5) | `Idle { asset }` | `HandoverOpen { asset: some(asset), phase_start_ms, current, retiring: false }` |
| `do_install_new_tenant` from `AtDutchAuction` (§7.5) | `AtDutchAuction { asset, .. }` | `HandoverOpen { asset: some(asset), phase_start_ms, current, retiring: false }` |
| `do_place_bid` (first bid) (§7.10) | `HandoverOpen { asset, phase_start_ms, current, retiring }` | `HandoverConfirmed { asset, phase_start_ms, current, pending, retiring, handover_countdown_expiry }` |
| `do_supersede_bid` (replace pending) (§7.11) | `HandoverConfirmed { ..., pending: old, .. }` | `HandoverConfirmed { ..., pending: new, .. }` (current, retiring, expiry preserved) |
| `do_handover` | `HandoverConfirmed { asset, ..., current: outgoing, pending: incoming, retiring, .. }` | `HandoverOpen { asset, phase_start_ms: boundary_ms, current: incoming-with-rotated-stake, retiring }` |
| `do_tenure_expiry` (no retire) | `HandoverOpen { asset, ..., retiring: false }` | `AtDutchAuction { asset, phase_start_ms: boundary_ms, last_acquisition_price: outgoing.stake.value() }` |
| `do_tenure_expiry` (retire) | `HandoverOpen { asset, ..., retiring: true }` | `Retired { asset }` |
| `do_auction_expiry` | `AtDutchAuction { asset, .. }` | `Idle { asset }` |
| `retire` (from Idle) | `Idle { asset }` | `Retired { asset }` |
| `retire` (from AtDutchAuction) | `AtDutchAuction { asset, .. }` | `Retired { asset }` |
| `retire` (from HandoverOpen) | `HandoverOpen { ..., retiring: false }` | `HandoverOpen { ..., retiring: true }` (variant unchanged; flag flipped) |
| `retire` (from HandoverConfirmed) | `HandoverConfirmed { ..., retiring: false }` | `HandoverConfirmed { ..., retiring: true }` |
| `claim_asset` (consumes the variant) | `Retired { asset }` | (escrow deleted) |

Every transition is implemented via the `take_state` / `put_state`
hot-potato pair (§2.6): `let (old, receipt) = take_state(escrow);`,
construct the new variant from `old`'s destructured fields,
`put_state(escrow, new, receipt)`. See §5–§7 for the per-function
pseudocode.

**Why `EscrowState` is `public`.** External callers may want to
pattern-match on the post-settlement state returned from
`apply_pending_transitions` / `retire` — but those return
`EscrowStateTag` (copyable). For deeper inspection (e.g., reading
`current.address` from `HandoverOpen`), a public read query
`state(escrow: &RentalEscrow): &EscrowState` is exposed (§8.7); the
`public` visibility on the enum is what makes the read query usable
at the call site.

### 2.4 RentalEscrow — shared struct

```move
public struct RentalEscrow<phantom Asset: key + store, phantom CoinType> has key {
    id:                UID,
    config:            IntegrationConfig,
    fee_inbox_id:      ID,
    integrated_at_ms:  u64,
    owner_earnings:    Balance<CoinType>,
    state:             Option<EscrowState<Asset, CoinType>>,
}
```

**Abilities:** `key` only.
- `key` — required for `transfer::share_object`. The escrow is shared
  so any participant may interact with it (rent, apply transitions,
  read state).
- No `store` — the shared object should never be wrapped by external
  code. `store` would allow an external module to include `RentalEscrow`
  as a field of another type, breaking the one-shared-object-per-instance
  invariant.

**Why `state: Option<EscrowState>`:** in Sui Move, the variant of an
enum stored inside a struct accessed via `&mut` cannot be changed in
place. Variant transition consumes the old variant's fields (linear
types: `Asset`, `Balance` inside `Tenant`), which requires ownership.
`Option<EscrowState>` enables the swap pattern: `option::extract`
takes the current variant by value, the function constructs the new
variant from the destructured pieces (rotating linear payload into
the new shape), and `option::fill` puts it back. The `None` window
exists only mid-function within a single Move call — never observable
from outside the module. This is the canonical Move pattern for
"swap a linear value through `&mut`," used internally by
`sui::borrow::Referent<T>` in the Sui framework
(https://docs.sui.io/guides/developer/objects/simulating-refs).

**Field semantics:**

| Field | Meaning |
|---|---|
| `id` | The shared object's UID. |
| `config` | Immutable `IntegrationConfig` — all protocol parameters. |
| `fee_inbox_id` | ID of `ProtocolFeeInbox`. Stored at integrate from `&ProtocolFeeRef`. Passed to `fee_message::post` at each boundary event so the resulting `FeeMessage<C>` carries its routing target. |
| `integrated_at_ms` | Timestamp at integration. Used to enforce `retire_floor`: `retire()` aborts if `clock.timestamp_ms() < integrated_at_ms + config.retire_floor`. |
| `owner_earnings` | Accumulated 90% share. Withdrawn via `withdraw_earnings` or swept at `claim_asset`. The only `Balance<CoinType>` field at the struct level — every other balance lives inside `EscrowState` variants (`Tenant.stake`). |
| `state` | The current `EscrowState` variant, wrapped in `Option` for the swap pattern. Carries the asset, the tenant data (if any), the phase timestamps, the retire flag, and `last_acquisition_price` / `handover_countdown_expiry` where they apply. `Some` at every transaction boundary; `None` only mid-function within a single Move call. |

**Fields removed compared to the previous design.** The following fields
no longer exist at the struct level — each is now placed inside the
`EscrowState` variant where it has meaning:

| Old field | Now lives in |
|---|---|
| `asset: Option<Asset>` | `EscrowState::*.asset` (5 variants — direct in 3, `Option` in 2) |
| `state: AssetState` | replaced by `EscrowState` discriminator (the variant itself) |
| `last_acquisition_price: u64` | `EscrowState::AtDutchAuction.last_acquisition_price` |
| `phase_start_ms: u64` | `EscrowState::AtDutchAuction.phase_start_ms`, `EscrowState::HandoverOpen.phase_start_ms`, `EscrowState::HandoverConfirmed.phase_start_ms` |
| `tenant_slot: TenantSlot` | replaced by `current` / `pending` fields in `HandoverOpen` / `HandoverConfirmed` variants |
| `tenant_stake: Balance<CoinType>` | `EscrowState::HandoverOpen.current.stake`, `EscrowState::HandoverConfirmed.current.stake` |
| `pending_bid: Balance<CoinType>` | `EscrowState::HandoverConfirmed.pending.stake` |
| `retire_flag: bool` | `EscrowState::HandoverOpen.retiring`, `EscrowState::HandoverConfirmed.retiring`. For Idle / AtDutchAuction, `retire()` transitions directly to `Retired` — the flag is realized as the variant. |

**Six fields, down from thirteen.** The state machine now lives
exclusively inside the `EscrowState` variant; the struct holds only
the configuration snapshot, the inbox-id snapshot, the integration
timestamp, the owner-earnings accumulator, and the variant-typed
state cell.

### 2.5 AssetReceipt — hot potato

```move
public struct AssetReceipt {
    escrow_id: ID,
    asset_id:  ID,
}
```

**Abilities:** none. Cannot be stored, transferred, dropped, or copied.
Must be consumed by `return_asset` in the same PTB that created it via
`borrow_asset`. The Move linear type system enforces this structurally
— a PTB that does not consume the receipt fails to type-check at the
transaction boundary.

**Fields:**

| Field | Meaning |
|---|---|
| `escrow_id` | ID of the escrow the asset was borrowed from. Enforces return to the correct escrow. |
| `asset_id` | `object::id(&asset)` captured at borrow. Enforces that the same asset — not a substitute — is returned. |

**Why both fields:** without `asset_id`, a malicious tenant with two
assets of the same type (from two different escrows) could borrow from
escrow A and return a different asset to close the receipt. `escrow_id`
alone does not prevent asset substitution. Capturing both makes return
structurally unambiguous.

### 2.6 StateReceipt — internal hot potato + take/put/read helpers

```move
public struct StateReceipt {}

fun take_state<Asset: key + store, CoinType>(
    escrow: &mut RentalEscrow<Asset, CoinType>,
): (EscrowState<Asset, CoinType>, StateReceipt) {
    assert!(option::is_some(&escrow.state), E_INVARIANT_VIOLATION);
    (option::extract(&mut escrow.state), StateReceipt {})
}

fun put_state<Asset: key + store, CoinType>(
    escrow:  &mut RentalEscrow<Asset, CoinType>,
    new:     EscrowState<Asset, CoinType>,
    receipt: StateReceipt,
) {
    let StateReceipt {} = receipt;
    assert!(option::is_none(&escrow.state), E_INVARIANT_VIOLATION);
    option::fill(&mut escrow.state, new);
}

fun read_state<Asset: key + store, CoinType>(
    escrow: &RentalEscrow<Asset, CoinType>,
): &EscrowState<Asset, CoinType> {
    assert!(option::is_some(&escrow.state), E_INVARIANT_VIOLATION);
    option::borrow(&escrow.state)
}
```

**Visibility:** `StateReceipt` and the three helpers are **private**
to `rental_escrow`. The receipt is not exported; `take_state` /
`put_state` / `read_state` are not callable from outside the module.
External callers never observe the receipt — only the public
functions (`rent`, `retire`, `borrow_asset`, `return_asset`,
`burn_tenant_cap`, `apply_pending_transitions`,
`withdraw_earnings`, `claim_asset`) appear in their PTBs.

**Why three helpers, not two.** `read_state` is the sole reader —
the only call site of `option::borrow(&escrow.state)` in the entire
module. Lifting it out of every dispatch site centralizes the P_READ
guarantee (§0 Design conventions): a single function holds the
"`escrow.state` is `Some`" assert; if the assert is reached when the
cell is `None` (i.e. inside an open take/put window), the abort code
is `E_INVARIANT_VIOLATION` rather than the generic
`option::EOPTION_NOT_SET`. Same applies to `take_state` (asserts
`is_some` before extracting) and `put_state` (asserts `is_none`
before filling): every site that touches `escrow.state` is guarded
with the protocol's own error code, so std::option's generic codes
never surface to callers.

**Abilities of `StateReceipt`:** none — no `key`, `store`, `copy`,
`drop`. The Move linear type system requires every code path to
either consume the receipt (via `put_state` destructure) or `abort`
(which discharges all in-scope linear values during transaction
rollback). A function that calls `take_state` and then `return`s
without calling `put_state` fails to compile.

**Purpose — type-level enforcement of P13.** The `Option<EscrowState>`
swap pattern (extract → reconstruct → fill) is the only way to
mutate the variant of `escrow.state` through `&mut`. Without
structural enforcement, a programmer could `option::extract` and
forget the matching `option::fill`, leaving `escrow.state` as
`None` after the transaction commits. The next transaction that
extracts would abort on `None`, and the escrow would be permanently
inaccessible — the asset and any accrued `owner_earnings` would be
unreachable forever (`claim_asset` itself also extracts state via
APT). The hot-potato receipt closes this failure mode at compile
time: `take_state` is the sole producer of `StateReceipt`,
`put_state` is the sole consumer, and the type system forbids any
path between them that does not end in either `put_state` or
`abort`.

**Symmetric with `AssetReceipt`.** The two receipts are dual
mechanisms at different scales:
- `AssetReceipt` (public, §2.5): enforces that an `Asset` extracted
  by `borrow_asset` is returned by `return_asset` in the same PTB.
- `StateReceipt` (private, §2.6): enforces that an `EscrowState`
  variant extracted by `take_state` is filled by `put_state` in the
  same Move call.

`AssetReceipt` is public because the contract is between the
protocol and the integrating PTB (the tenant must pair extract /
return across module boundaries). `StateReceipt` is private because
the contract is internal to `rental_escrow` (the swap is always
within a single function body — no cross-module flow). Visibility
matches the scope of the linear-types contract.

**Cleanup of abort paths.** Without the receipt, every dispatch
arm that aborts after extracting state needs to first `option::fill`
to restore the prior variant (a defensive measure: even though
`abort` rolls back the transaction, leaving `state` as `None`
mid-function is awkward). With the receipt, the `abort` discharges
the receipt directly — no manual restoration needed:

```move
// Without receipt:
let old = option::extract(&mut escrow.state);
match old {
    Idle | AtDutchAuction | Retired => {
        option::fill(&mut escrow.state, old);   // restore before aborting
        abort E_STALE_TENANT_CAP;
    },
    ...
}

// With receipt:
let (old, receipt) = take_state(escrow);
match old {
    EscrowState::Idle { .. } | EscrowState::AtDutchAuction { .. } | EscrowState::Retired { .. } =>
        abort E_STALE_TENANT_CAP,    // receipt discharged by abort; old's linear payload rolled back with the tx
    ...
}
```

Several call sites in §4–§7 simplify under this pattern; see those
sections for the post-receipt pseudocode.

**Read paths go through `read_state`.** `StateReceipt` is only
required for *mutating* extraction. Read paths use `read_state` to
inspect the variant by reference — no extraction, no receipt.
`apply_pending_transitions` (the dispatch arm of the match-while
loop), `rent` / `retire` / `borrow_asset` / `return_asset` (the
public dispatch arm before delegating to `do_*` helpers),
`compute_floor_price`, `compute_used_credit`,
`compute_price_descent`, and the liveness gate inside
`burn_tenant_cap` all read via `read_state` — none of them invoke
`take_state`. Mutating helpers (`do_*`) own their own take/put
window and never call `read_state` (P_READ, §0).


3. EVENTS
---------

All events are defined inline and emitted from this module. The Sui Move
event verifier requires the emitted type to be internal to the calling
module — this is why there is no standalone events module.

```move
public struct AssetIntegrated<phantom Asset, phantom CoinType> has copy, drop {
    escrow_id:        ID,
    owner_cap_id:     ID,
    asset_id:         ID,   // object::id(&asset) at integrate time
}

public struct RentStarted has copy, drop {
    escrow_id:        ID,
    tenant_cap_id:    ID,
    price_paid:       u64,            // stake amount transferred to escrow
    floor_price:      u64,            // minimum required at acquisition time
    from_state:       EscrowStateTag, // Idle or AtDutchAuction
}

public struct BidPlaced has copy, drop {
    escrow_id:                 ID,
    tenant_cap_id:             ID,    // cap minted for this bid (lives in state.HandoverConfirmed.pending.cap_id)
    pending_tenant:            address,
    bid_amount:                u64,
    floor_price:               u64,   // f_next_rent_price(value(state.HandoverOpen.current.stake)) at bid time
    handover_countdown_expiry: u64,
}

public struct BidSuperseded has copy, drop {
    escrow_id:                ID,
    displaced_tenant_cap_id:  ID,    // cap of the displaced bidder, now stale
    new_tenant_cap_id:        ID,    // cap of the new bidder, now in state.HandoverConfirmed.pending.cap_id
    displaced_bidder:         address,
    refunded_amount:          u64,
    new_bidder:               address,
    new_bid_amount:           u64,
    floor_price:              u64,   // f_next_rent_price(value(state.HandoverConfirmed.pending.stake)) at bid time — escalates with each supersede
}

public struct HandoverCompleted has copy, drop {
    escrow_id:         ID,
    displaced_tenant:  address,
    new_tenant_cap_id: ID,
    used_credit:       u64,   // amount consumed by owner (pre-fee split)
    owner_share:       u64,   // used_credit × 0.90
    protocol_fee:      u64,   // used_credit × 0.10
    remain_credit:     u64,   // refunded to displaced tenant
    new_rent_price:    u64,   // winning bid amount — equals incoming tenant's stake after rotation
    timestamp_ms:      u64,   // = state.HandoverConfirmed.handover_countdown_expiry (pre-handover)
}

public struct TenureExpired has copy, drop {
    escrow_id:               ID,
    tenant:                  address,
    owner_share:             u64,   // tenant_stake × 0.90
    protocol_fee:            u64,   // tenant_stake × 0.10
    last_acquisition_price:  u64,   // captured from outgoing current.stake.value() pre-settlement; anchor of Dutch descent if next_state=AtDutchAuction
    next_state:              EscrowStateTag,  // AtDutchAuction or Retired
    timestamp_ms:            u64,   // = phase_start_ms + tenure_ceiling
}

public struct AuctionExpired has copy, drop {
    escrow_id:        ID,
    timestamp_ms:     u64,   // = phase_start_ms + descent_ceiling, always
}

public struct RetireFlagSet has copy, drop {
    escrow_id:        ID,
    owner:            address,         // cap holder at retire time (first-observed)
    state_at_set:     EscrowStateTag,  // settled state when retire was called
}

public struct AssetRetired has copy, drop {
    escrow_id:        ID,
    from_state:       EscrowStateTag,  // Idle | AtDutchAuction | HandoverOpen
}

public struct AssetBorrowed has copy, drop {
    escrow_id:        ID,
    tenant_cap_id:    ID,
}

public struct AssetReturned has copy, drop {
    escrow_id:        ID,
    tenant_cap_id:    ID,
}

public struct AssetClaimed has copy, drop {
    escrow_id:        ID,
    owner_cap_id:     ID,
    swept_earnings:   u64,
}

public struct EarningsWithdrawn has copy, drop {
    escrow_id:        ID,
    owner_cap_id:     ID,
    owner:            address,   // cap holder at withdraw time (first-observed)
    amount:           u64,
}
```

**Sui Verifier constraint:** every event struct has `copy + drop` and is
internal to this module. `event::emit` requires these abilities.

**Discriminator type used in events.** `from_state`, `next_state`, and
`state_at_set` are typed as `EscrowStateTag` rather than `EscrowState`
because events must be `copy + drop` and `EscrowState` carries linear
payload (asset, balances) that cannot satisfy those abilities. The tag
preserves the variant identity — the only state-machine context the
indexer needs from these fields. Variant-specific payload that the
indexer does want (cap IDs, addresses, amounts) is carried by sibling
fields on the same event row (`tenant_cap_id`, `displaced_tenant`,
`new_rent_price`, etc.).

**`AssetIntegrated` is phantom-generic over the escrow's type
parameters.** The root-fact creation event carries `Asset` and
`CoinType` as phantom type parameters so the off-chain indexer recovers
both from the event type tag (`AssetIntegrated<0x...::game::Sword,
0x2::sui::SUI>`) without paying any on-chain bytes. This is the unique
entry point: downstream fact rows (`RentStarted`, `HandoverCompleted`,
etc.) are non-generic and recover `Asset` / `CoinType` by PK-JOIN on
`escrow_id` back to `AssetIntegrated`. Rationale: `Asset` and `CoinType`
are escrow-level configuration (generics of `RentalEscrow<Asset,
CoinType>`), not `IntegrationConfig`-level parameters —
`IntegrationConfig` is coin-agnostic and asset-agnostic.

**Cap-gated ops that do not co-emit a cap lifecycle event carry the
cap holder's address.** `RetireFlagSet` and `EarningsWithdrawn` both
take `&OwnerCap` — the cap is neither minted nor burned in these calls
— so no `OwnerCap*` event is co-emitted. `OwnerCap` has `key + store`,
so the caller address at retire-time / withdraw-time may differ from
`OwnerCapMinted.owner` (mint-time) and from every other cap-gated
call. It is **first-observed** and PK-unrecoverable per star-schema
invariant (c), so both events carry `owner: address =
tx_context::sender(ctx)`. The field name is `owner` — not `caller` —
because the protocol defines "owner" as whoever holds the cap at call
time (README, "The caps"), so this is protocol semantics, not
transaction metadata.

`AssetClaimed` does **not** carry `owner`: `claim_asset` consumes the
cap by value and calls `owner_cap::burn`, which emits
`OwnerCapBurned.owner` in the same transaction. The claim-time caller
address is therefore PK-recoverable by JOIN on `owner_cap_id` into
`owner_cap_burned` — duplicating it on `AssetClaimed` would violate
invariant (c).

**Timestamp convention:** only boundary events — `HandoverCompleted`,
`TenureExpired`, `AuctionExpired` — carry a `timestamp_ms` field. Its
value is the exact boundary timestamp (`state.HandoverConfirmed.
handover_countdown_expiry`, `phase_start_ms + tenure_ceiling`,
`phase_start_ms + descent_ceiling`) — not `clock.now()` — so the
event timeline stays aligned with the state machine even when
settlement is lazy and runs in a later checkpoint than the boundary
itself.

Immediate events (`AssetIntegrated`, `RentStarted`, `BidPlaced`,
`BidSuperseded`, `RetireFlagSet`, `AssetRetired`, `AssetBorrowed`,
`AssetReturned`, `AssetClaimed`, `EarningsWithdrawn`) do not carry a
`timestamp_ms` field. Consumers read the event-envelope timestamp
(`SuiEvent.timestampMs`, the checkpoint time of the emitting
transaction), which is authoritative for anything that happens at tx
time. Duplicating it in the event body would add no information and
would force `&Clock` into the signature of functions that otherwise
have no reason to read the clock.

**`AssetRetired` — timestamp recovery rule.** `AssetRetired` has two
disparate emission sites: immediate (from `retire()` when settled state
is `Idle` or `AtDutchAuction`) and deferred (from
`apply_pending_transitions` → `do_tenure_expiry` when the active
`HandoverOpen` variant has `retiring: true` and tenure expires,
`from_state = HandoverOpen`). The deferred case co-emits with
`TenureExpired` in the same transaction, so the authoritative boundary
time is recoverable by JOIN on `escrow_id` to `TenureExpired.timestamp_ms`
(= `phase_start_ms + tenure_ceiling`). The immediate case has no
boundary — tx time == semantic time — so the envelope is authoritative.
Carrying a `timestamp_ms` field on `AssetRetired` itself would give the
same field two different meanings depending on `from_state`; recovery
by JOIN is cheaper and structurally unambiguous.

**Price-anchor fields — `new_rent_price` on `HandoverCompleted`,
`last_acquisition_price` on `TenureExpired`.** These two amounts are
the "frozen acquisition price" that anchors downstream computations —
the takeover/supersede floor (`compute_next_rent_price` in the Rented
variants reads `current.stake` / `pending.stake` directly, equivalent
to the prior design's reads) and `compute_price_descent` (Dutch
descent, §8.2, which reads `state.AtDutchAuction.last_acquisition_price`).
Both events carry the value explicitly because it is **not**
PK-JOIN-recoverable via a single JOIN: recovering it off-chain requires
locating the most recent `HandoverCompleted.new_rent_price` or
`RentStarted.price_paid` for the escrow — an `ORDER BY ts DESC LIMIT 1`
walk, not a keyed JOIN — and is fragile under partial ingestion.
Emitting it at each transition that freezes it makes each fact row
self-describing for price-floor and Dutch-price analytics. Consistent
with invariant (c): the rule constrains redundant **addresses**
recoverable by PK-JOIN, not amounts recoverable only by chain-walk.
`AuctionExpired` does not need its own field — its anchor is the
directly preceding `TenureExpired`, PK-JOIN-recoverable 1:1 by
`escrow_id` and temporal order.

### Star schema — the protocol's event emission strategy

The full event surface of the protocol — this module plus the three
child-object modules (`owner_cap`, `tenant_cap`, `fee_message`) — is
shaped as a **SQL star schema** anchored on `escrow_id` as the root
foreign key. Every event emitted anywhere in the package carries
`escrow_id`, so an off-chain indexer can ingest them into a unified
view of per-escrow activity with zero envelope-metadata dependency.

Around that root, four satellite dimensions exist. Three are
protocol-internal child-object types (`owner_cap`, `tenant_cap`,
`fee_message`), each with its own natural primary key — the child
object's own ID — and a pair of lifecycle events (create / destroy,
send / collect) joined on that PK. Address fields are non-redundant
across each pair: they appear only on the event where they are
first-observed or where they diverge from their counterpart. The
fourth satellite is `config` — a 1:1 dimension keyed only by
`escrow_id`, with a single emission at integration time (configs are
immutable, so there is no update or burn event).

```
                    ┌──────────────────────────────────┐
                    │         escrows (root fact)      │
                    │           PK: escrow_id          │
                    │                                  │
                    │  AssetIntegrated  RentStarted    │
                    │  BidPlaced        BidSuperseded  │
                    │  HandoverCompleted               │
                    │  TenureExpired    AuctionExpired │
                    │  RetireFlagSet    AssetRetired   │
                    │  AssetBorrowed    AssetReturned  │
                    │  AssetClaimed     EarningsWithdrawn│
                    └──────────────┬───────────────────┘
                                   │  FK: escrow_id
                                   │  (on every row below)
     ┌──────────────┬──────────────┼──────────────┬─────────────────┐
     │              │              │              │                 │
     ▼              ▼              ▼              ▼                 ▼
┌──────────┐  ┌───────────┐  ┌────────────┐  ┌──────────────────────────┐
│  config  │  │ owner_cap │  │ tenant_cap │  │       fee_message        │
│ PK:      │  │ PK:       │  │ PK:        │  │ PK: fee_message_id       │
│ escrow_id│  │ owner_    │  │ tenant_    │  │                          │
│   (1:1)  │  │  cap_id   │  │  cap_id    │  │   FeeMessageSent         │
│          │  │           │  │            │  │     tenant               │
│ Integra- │  │ OwnerCap  │  │ TenantCap  │  │                          │
│ tionCfg  │  │  Minted   │  │  Minted    │  │   FeeMessageCollected    │
│ Regis-   │  │    owner  │  │    tenant  │  │     collector            │
│ tered    │  │           │  │            │  │                          │
│          │  │ OwnerCap  │  │ TenantCap  │  │                          │
│ (once)   │  │  Burned   │  │  Burned    │  │                          │
│          │  │    owner  │  │    tenant  │  │                          │
└──────────┘  └───────────┘  └────────────┘  └──────────────────────────┘
   no UID →    key + store →   key + store →    key only →
   immutable    owner may       tenant may       tenant first-observed
   snapshot     diverge across  diverge across   at send; collector
   at integrate mint/burn       mint/burn        first-observed at
                → kept on both  → kept on both   consume
                  events          events
```

**Star schema properties:**

| Property | Consequence |
|---|---|
| **`escrow_id` on every row.** | Any analytical question ("activity on escrow X") answers with a single `WHERE escrow_id = X`. No cross-table joins needed for scoping. |
| **Child PK pairs lifecycle.** | `owner_cap_id`, `tenant_cap_id`, `fee_message_id` each join their Minted↔Burned / Sent↔Collected pair. Full object history = one JOIN. |
| **1:1 config satellite.** | `IntegrationConfigRegistered` is emitted exactly once per escrow, at integration, from the `config` module. It has no child UID — the only key is `escrow_id`, the root FK itself. This lets analytical queries group escrows by any integration parameter (tenure, curve shapes, price function) with a single JOIN on `escrow_id`, without having to read the on-chain object. |
| **Addresses are first-observed, never duplicated.** | Redundancy recoverable by PK-JOIN is dropped; addresses that may diverge between paired events are kept on both. `TenantCapBurned` keeps `tenant` — `key + store` transferability means the burn-sender may differ from the mint-recipient and is genuinely new information (symmetric with `OwnerCapBurned.owner`). `FeeMessageCollected` has no `tenant` (JOIN on `fee_message_id` recovers it — `FeeMessage` is `key`-only and the tenant address from `FeeMessageSent` is unambiguous). `OwnerCapBurned` keeps `owner` — same reasoning as `TenantCapBurned`. Fact-table events comply: `AssetIntegrated` omits `integrator` (JOIN on `owner_cap_id` to `OwnerCapMinted`), `RentStarted` omits `tenant` (JOIN on `tenant_cap_id` to `TenantCapMinted`), `HandoverCompleted` omits `new_tenant` (JOIN on `new_tenant_cap_id`). `HandoverCompleted.displaced_tenant` is kept — no PK reaches the outgoing cap from this row. |
| **Fact-table rows carry child PK-FKs to dimensions they co-emit with.** | `AssetIntegrated.owner_cap_id`, `RentStarted.tenant_cap_id`, `BidPlaced.tenant_cap_id`, `BidSuperseded.{displaced_tenant_cap_id,new_tenant_cap_id}`, `HandoverCompleted.new_tenant_cap_id`, `AssetBorrowed.tenant_cap_id`, `AssetReturned.tenant_cap_id`, `AssetClaimed.owner_cap_id`, `EarningsWithdrawn.owner_cap_id` — every fact row whose semantics touch a child object exposes that child's PK so the indexer can JOIN into the dimension without envelope-timing. Under eager minting, every bid produces a cap and `BidPlaced` / `BidSuperseded` carry that cap's PK directly — the indexer has full lineage from "bid placed" to "cap created" in a single row. |
| **Borrow/return measure actual usage.** | `AssetBorrowed` / `AssetReturned` pair JOIN on `tenant_cap_id` within a single tenancy (multiple pairs possible — a tenant may borrow and return N times during their block). Provides the off-chain indexer a measurable signal of "did the tenant actually use the capability?" — the core liquid-renting demand metric, previously invisible (borrow was PTB-internal only). |
| **`AssetIntegrated` is the Asset/CoinType dictionary.** | `AssetIntegrated<Asset, CoinType>` is the only event phantom-generic on the escrow's type params. Any query that needs to group or filter by `Asset` or `CoinType` JOINs on `escrow_id` back to `asset_integrated` and reads the type tag — including queries over `IntegrationConfigRegistered` (min_rent_price, tenure_ceiling, curves) that want to bucket by coin. The `config` module stays coin-agnostic. |
| **`AssetIntegrated.asset_id` enables level-2 linkage and asset-instance tracing.** | The object ID of the wrapped asset at integrate time. Level-2 escrows (`Asset = rental_escrow::OwnerCap`) pair to their underlying level-1 escrow via `asset_id = level-1 OwnerCap ID` → JOIN on `owner_cap_id` to `OwnerCapMinted.escrow_id`. The same-asset-across-integrations thread (integrate → retire → re-integrate) becomes queryable with `GROUP BY asset_id`. Without this field the mapping is only reachable through Sui's object-state-changes layer, not through the protocol's event surface. |
| **Owner address on `&OwnerCap`-gated ops.** | `RetireFlagSet.owner` and `EarningsWithdrawn.owner` record the cap holder at call time. These ops take the cap by reference — no `OwnerCap*` lifecycle event is co-emitted — so the address is first-observed and PK-unrecoverable. `AssetClaimed` does not carry `owner` because it consumes the cap by value; `OwnerCapBurned.owner` co-emits the same address and is reachable by JOIN on `owner_cap_id` (invariant c). Enables per-human queries (withdraw frequency per owner, multi-cap operators). |
| **Intent vs settlement on retirement.** | `RetireFlagSet` records the owner's intent (when `retire()` was called, from which settled state). `AssetRetired` records the actual transition to `Retired` — immediate for `from_state ∈ {Idle, AtDutchAuction}`, deferred to the next tenure expiry for `from_state = HandoverOpen` (or rotated through a pending handover). Co-emission matrix: `TenureExpired.next_state = Retired` ⇔ `AssetRetired` with `from_state = HandoverOpen` is co-emitted. Both events are needed — `TenureExpired` carries the stake-settlement facts (`owner_share`, `protocol_fee`, tenant), `AssetRetired` carries the pure state-transition fact. |
| **Price-anchor fields on block-boundary events.** | `HandoverCompleted.new_rent_price` carries the winning bid amount (the new tenant's rotated `current.stake.value()`); `TenureExpired.last_acquisition_price` carries the outgoing tenant's `current.stake.value()` snapshot taken before settlement. Neither is PK-JOIN-recoverable via a single JOIN — recovering the value requires locating the most recent `HandoverCompleted.new_rent_price` or `RentStarted.price_paid` for the escrow (`ORDER BY ts DESC LIMIT 1`). Emitting them in-row makes (a) the takeover-floor query `floor = f_next_rent_price(last_acquisition_price)` answerable from `HandoverCompleted` alone, and (b) the Dutch current price `price(t) = last_acquisition_price − h(t)·(last_acquisition_price − min_rent_price)` answerable from `TenureExpired` + `IntegrationConfigRegistered` alone — no stateful replay in the indexer. Consistent with invariant (c). |
| **`floor_price` on acquisition and bid events.** | `RentStarted.floor_price`, `BidPlaced.floor_price`, `BidSuperseded.floor_price` carry the minimum required payment at call time. The voluntary premium `price_paid − floor_price` (or `bid_amount − floor_price`) is the core demand signal — invisible without this field. For `RentStarted{AtDutchAuction}` the floor is `compute_price_descent(now)`, which requires a timestamp and curve application to reconstruct off-chain. For `BidPlaced` it requires locating the most recent acquisition price and applying `f_next_rent_price`. For `BidSuperseded` it is `f_next_rent_price(refunded_amount)` — computable from the same row but only with function application. Emitting it directly makes the premium a single-column subtraction on any query engine. |
| **No envelope dependence.** | Events never require the indexer to join against `SuiEvent.timestampMs` or `SuiEvent.sender` to reconstruct meaning — except for pure wall-clock ordering of immediate events (which the envelope provides for free). |
| **Cross-module events are self-contained.** | An indexer ingesting only `fee_message` events can answer every fee-message-level question; likewise for each cap module. Cross-module JOINs are always on `escrow_id`, never on implicit co-emission. |
| **`tenant_cap` satellite is "cap creation lifecycle", not "tenancy lifecycle".** | Under eager minting, `TenantCapMinted` fires at every `rent` call (Idle, AtDutchAuction, both Rented sub-branches), which means bids that get superseded still produce a Minted row. To count effective tenancies, indexers pivot through the fact-table events that record actual acquisition or promotion: `RentStarted` (Idle / AtDutchAuction direct acquisition) and `HandoverCompleted.new_tenant_cap_id` (handover promotion). The `TenantCapMinted ↔ TenantCapBurned` pair on `tenant_cap_id` still describes object lifecycle (creation → destruction); both bid-only caps and tenancy caps share that lifecycle shape uniformly. |

**Strategy statement.** This star schema is the protocol's uniform
event-emission strategy. Every future event added to the package
anywhere **must**: (a) carry `escrow_id`, (b) if it concerns a
child object's lifecycle, carry that object's own ID as lifecycle PK,
and (c) carry address fields only where first-observed or divergent.
Deviations — co-emission dependencies, envelope-metadata reliance,
redundant addresses across a PK-joinable pair — degrade the schema
and are disallowed.


4. LIFECYCLE FUNCTIONS
-----------------------

### 4.1 `integrate`

    public fun integrate<Asset: key + store, CoinType>(
        asset:    Asset,
        config:   IntegrationConfig,
        fee_ref:  &ProtocolFeeRef,
        clock:    &Clock,
        ctx:      &mut TxContext,
    ): OwnerCap

**Visibility:** `public` — entry point for any integrator.

**Purpose:** wraps `asset` in a new `RentalEscrow<Asset, CoinType>`,
shares the escrow, mints one `OwnerCap`, and returns it to the PTB.

**Behavior:**
1. Allocate `uid = object::new(ctx)`. Compute
   `escrow_id = object::uid_to_inner(&uid)`.
2. Mint `OwnerCap` via `owner_cap::new(escrow_id, tx_context::sender(ctx),
   ctx)`. The sender is the default recipient; PTBs that wish to
   deliver the cap to a distinct address (custody, multisig) can
   transfer it further after `integrate` returns, but the
   `OwnerCapMinted.owner` field records the integrator at mint time.
3. Read `fee_inbox_id = protocol_fee_inbox::inbox_id(fee_ref)`.
4. Capture `asset_id = object::id(&asset)` — needed by the emit in
   step 7. Must be read before `asset` is moved into the `Idle` variant
   below, since after construction the asset is owned by the escrow
   and the escrow itself is consumed by `share_object` in step 6. Then
   construct the escrow with:
   - `id = uid`
   - `config = config`
   - `fee_inbox_id = fee_inbox_id`
   - `integrated_at_ms = clock::timestamp_ms(clock)`
   - `owner_earnings = balance::zero()`
   - `state = option::some(EscrowState::Idle { asset })`
5. Call `config::emit_registration(&escrow.config, escrow_id)` to emit
   `IntegrationConfigRegistered` carrying the full parameter snapshot
   keyed by `escrow_id`. Emitted from the `config` module per the
   module-ownership principle. Must happen *before* `share_object`
   consumes `escrow` by value; safe to borrow `&escrow.config` at this
   point because the escrow has already been constructed (step 4) and
   the config↔escrow_id binding is a realized semantic fact (emit-last).
6. `transfer::share_object(escrow)`.
7. Emit `AssetIntegrated<Asset, CoinType> { escrow_id, owner_cap_id,
   asset_id }`. Both type parameters are phantom — no on-chain payload
   — and are recovered by the indexer from the event type tag, making
   this event the root dictionary row for every downstream JOIN that
   needs `Asset` or `CoinType`. `asset_id` is the object ID of the
   wrapped asset at integrate time; it anchors (a) level-2 linkage
   when `Asset = rental_escrow::OwnerCap`, pairing the level-2 escrow
   to a specific level-1 `OwnerCap`, (b) cross-integration lifecycle
   tracing of the same asset instance (integrate → retire →
   re-integrate under a new escrow), and (c) integrator-catalog
   cross-reference queries without dropping to Sui's
   object-state-changes layer. The integrator address is not carried
   here — already recorded on the co-emitted `OwnerCapMinted.owner`
   row and recoverable by JOIN on `owner_cap_id` (star-schema
   invariant c: no PK-recoverable redundancy).
8. Return `OwnerCap`. The PTB routes it (typically via
   `transfer::public_transfer` to `tx_context::sender(ctx)`).

**Why return the cap instead of pushing it:** `OwnerCap` has `store`;
the PTB author may want to stash it in a multisig, a custody object,
or chain it as input to a subsequent PTB step. Returning gives the
PTB full control; pushing would force every integrator to issue a
second transfer.

**`Asset = OwnerCap` is permitted.** `OwnerCap` has `key + store` and
satisfies the `Asset` bound like any other integrable type. Renting an
`OwnerCap` is equivalent to renting administrative authority over the
wrapped escrow (including `retire()`) for the duration of the tenancy
— a mechanism for implicit sale of the underlying asset. The protocol
does not impose a nesting-depth limit: any type-level check would fail
to prevent deeper chains composed via external `key + store` wrappers,
so a self-imposed limit would be defense-in-type without real
guarantee. Integrators who want to limit exposure must do so outside
the protocol.

---

### 4.2 `retire`

    public fun retire<Asset: key + store, CoinType>(
        escrow:    &mut RentalEscrow<Asset, CoinType>,
        owner_cap: &OwnerCap,
        clock:     &Clock,
        ctx:       &mut TxContext,
    ): EscrowStateTag

**Visibility:** `public` — callable by the `OwnerCap` holder.

**Purpose:** initiate retirement. Either flips the `retiring` flag
inside the active Rented variant (deferred path) or transitions the
state to `Retired` directly (immediate path). Does not return the
asset. Does not mutate balances. Returns the post-call state tag so
the caller can branch on the outcome inside the same PTB without a
separate read — `Retired` if the transition fired immediately
(pre-call state was `Idle` or `AtDutchAuction`), or `HandoverOpen` /
`HandoverConfirmed` (with the `retiring` field now `true` on the
underlying variant) if the transition is deferred to the next tenure
expiry (pre-call state was Rented).

**Behavior — dispatch over `read_state(escrow)`** (P_DO, §0):

1. `assert!(owner_cap::escrow_id(owner_cap) == object::id(escrow),
   E_WRONG_ESCROW_OWNER_CAP);`
   — **security-critical** escrow-match gate (PTB-pairing attack;
   see `claim_asset` step 2 for the full threat model). Abort code is
   rental-local because the "wrong escrow" semantic is this module's
   interpretation of the cap/escrow ID mismatch.
2. `apply_pending_transitions(escrow, clock, ctx)` — settle all elapsed
   boundaries first.
3. Assert `clock::timestamp_ms(clock) >= escrow.integrated_at_ms +
   config::retire_floor(&escrow.config)`, abort
   `E_RETIRE_FLOOR_NOT_ELAPSED`.
4. **Dispatch via `read_state`** to either the immediate-retirement
   helper or the deferred-flag helper. Each `do_*` helper owns its own
   take/put window (P_DO) and emits its own events:

   ```move
   match (read_state(escrow)) {
       EscrowState::Idle { .. }
       | EscrowState::AtDutchAuction { .. } => do_retire_immediately(escrow, ctx),
       EscrowState::HandoverOpen { .. }
       | EscrowState::HandoverConfirmed { .. } => do_set_retiring_flag(escrow, ctx),
       EscrowState::Retired { .. } => abort E_ALREADY_RETIRED,
   }
   ```

   - `do_retire_immediately` (§7.8) — Idle | AtDutchAuction → Retired.
     Emits `RetireFlagSet` and `AssetRetired` co-emit. Returns
     `EscrowStateTag::Retired`.
   - `do_set_retiring_flag` (§7.9) — HandoverOpen | HandoverConfirmed
     → same variant with `retiring: true`. Asserts `!retiring`
     (aborts `E_ALREADY_RETIRED` on second call while a tenant is
     active). Emits `RetireFlagSet` only — `AssetRetired` is deferred
     to `do_tenure_expiry` (§7.2). Returns the (unchanged)
     `EscrowStateTag`.
   - `Retired` arm aborts `E_ALREADY_RETIRED` at the top-level
     match — second `retire` call after the escrow has already
     reached the terminal state.

5. Return the helper's `EscrowStateTag` directly — `do_retire_immediately`
   returns `Retired`; `do_set_retiring_flag` returns the variant tag
   that carried the (unchanged) variant. Callers branch on this without
   a separate state read.

**State after `retire` completes:**

| State at call | Underlying flag | State variant after = return tag |
|---|---|---|
| `Idle` | n/a | `Retired` (immediate) |
| `HandoverOpen` | `retiring` flipped to `true` | `HandoverOpen` — tenant runs to tenure_ceiling, then `Retired` via `do_tenure_expiry` |
| `HandoverConfirmed` | `retiring` flipped to `true` | `HandoverConfirmed` — handover fires normally, T(n+1) inherits the flag, runs to their tenure_ceiling, then `Retired` |
| `AtDutchAuction` | n/a | `Retired` (immediate) |
| `Retired` | already-retired path | aborts `E_ALREADY_RETIRED` |

**Idempotency:** not idempotent — second call aborts `E_ALREADY_RETIRED`,
caught either by the `Retired` arm or by the `assert!(!retiring, ...)`
guard in the Rented arms.

---

### 4.3 `claim_asset`

    public fun claim_asset<Asset: key + store, CoinType>(
        escrow:    RentalEscrow<Asset, CoinType>,
        owner_cap: OwnerCap,
        clock:     &Clock,
        ctx:       &mut TxContext,
    ): (Asset, Coin<CoinType>)

**Visibility:** `public`.

**Purpose:** finalize retirement. Sweeps `owner_earnings`, burns
`OwnerCap`, deletes the escrow, returns the asset and earnings.

**Preconditions:**
- `escrow.state` is `Some(EscrowState::Retired { .. })` after lazy
  settlement.

**Behavior:**
1. Consume both `escrow` and `owner_cap` by value.
2. `assert!(owner_cap::escrow_id(&owner_cap) == object::id(&escrow),
   E_WRONG_ESCROW_OWNER_CAP);`
   — **security-critical** escrow-match gate. PTBs can pair any
   `&OwnerCap` with any `RentalEscrow` passed as argument; the type
   system does not constrain that pairing. Without this assert, Alice
   could pass her own legitimate `OwnerCapA` alongside Bob's shared
   `EscrowB` and `claim_asset` would delete `EscrowB`, extract its
   asset, and burn `OwnerCapA` — Alice walks away with Bob's asset.
   The check is load-bearing, not a sanity check: the cap being
   honestly minted for `EscrowA` says nothing about which escrow was
   passed as the other argument at call time.
3. Call `apply_pending_transitions(&mut escrow, clock, ctx)` — settle
   any remaining elapsed boundaries.
4. Destructure the escrow:

        let RentalEscrow {
            id, config: _, fee_inbox_id: _, integrated_at_ms: _,
            owner_earnings, state,
        } = escrow;
        assert!(option::is_some(&state), E_INVARIANT_VIOLATION);
        let inner_state = option::destroy_some(state);

   The explicit `is_some` assert turns a P13 violation (`Option<state>`
   left `None` at a tx boundary) into `E_INVARIANT_VIOLATION` rather
   than the generic `option::EOPTION_NOT_SET`. Same convention every
   other state-cell access uses; `claim_asset` is the only consumer
   that destructures the escrow by value, so the helper layer
   (§2.6 `take_state`) does not apply here.
5. Match the variant — only `Retired` is acceptable; any other variant
   indicates the caller never called `retire()` first or called
   `claim_asset` during an active tenancy. Move 2024 requires explicit
   per-variant binding for non-`drop` fields (each non-Retired arm
   names its `asset` / `current` / `pending` fields with `: _a`,
   `: _c`, `: _p` placeholders to discharge the linear payload):

        let asset = match (inner_state) {
            EscrowState::Retired { asset } => asset,
            EscrowState::Idle              { asset: _a }                       => abort E_NOT_RETIRED,
            EscrowState::AtDutchAuction    { asset: _a, .. }                   => abort E_NOT_RETIRED,
            EscrowState::HandoverOpen      { asset: _a, current: _c, .. }      => abort E_NOT_RETIRED,
            EscrowState::HandoverConfirmed { asset: _a, current: _c, pending: _p, .. } => abort E_NOT_RETIRED,
        };

   Restoration unnecessary — the caller consumed the escrow by value,
   which the abort rolls back. The verbose per-variant arms exist
   because Move 2024's match cannot collapse non-`drop` variants into
   a single `_` arm or `{ .. }` pattern without explicit binding for
   the linear fields.

6. `let earnings = coin::from_balance(owner_earnings, ctx);`
7. **Pre-bind event locals** (emit-last: the destructive `burn` and
   `object::delete` consume identifiers needed by the event body —
   bind to locals first; also hoist the burn-time caller address):
   - `let escrow_id      = object::uid_to_inner(&id);`
   - `let owner_cap_id   = object::id(&owner_cap);`
   - `let swept_earnings = coin::value(&earnings);`
   - `let owner          = tx_context::sender(ctx);`
8. `owner_cap::burn(owner_cap, owner);` — `OwnerCapBurned.owner`
   records the claim-time caller passed in explicitly. This address is
   recoverable on `AssetClaimed` by JOIN on `owner_cap_id`, which is
   why `AssetClaimed` does not duplicate it (invariant c).
9. `object::delete(id);`
10. Emit `AssetClaimed { escrow_id, owner_cap_id, swept_earnings }` —
    emit-last, after the cap is burned and the escrow UID is deleted.
11. Return `(asset, earnings)`.

**Why no `balance::destroy_zero` calls.** The previous design carried
two separate `Balance` fields (`tenant_stake`, `pending_bid`) at the
struct level that had to be zero on `Retired` and required explicit
destruction. Both are gone — `Tenant.stake` lives inside the Rented
variants, and `Retired` carries only `asset`. There is no zero-balance
field to destroy at claim time; the variant structure makes the
"no trapped balances at terminal state" property a structural
guarantee (§9 P2), not a runtime assertion.

**Why both returned:** the owner gets everything they are owed
atomically in one call — the asset, the accumulated earnings. No
residual state, no locked balances.

---

### 4.4 `withdraw_earnings`

    public fun withdraw_earnings<Asset: key + store, CoinType>(
        escrow:    &mut RentalEscrow<Asset, CoinType>,
        owner_cap: &OwnerCap,
        clock:     &Clock,
        ctx:       &mut TxContext,
    ): Coin<CoinType>

**Visibility:** `public`.

**Purpose:** pull `owner_earnings` without exiting the protocol.

**Behavior:**
1. `assert!(owner_cap::escrow_id(owner_cap) == object::id(escrow),
   E_WRONG_ESCROW_OWNER_CAP);`
   — **security-critical** escrow-match gate (PTB-pairing attack;
   see `claim_asset` step 2 for the full threat model).
2. `apply_pending_transitions(escrow, clock, ctx)` — settle any
   elapsed boundaries first so the withdrawn amount includes all
   accrued earnings.
3. `let amount = balance::value(&escrow.owner_earnings);`
4. Assert `amount > 0`, abort `E_NO_EARNINGS`.
5. `let withdrawn = balance::withdraw_all(&mut escrow.owner_earnings);`
6. Emit `EarningsWithdrawn { escrow_id: object::id(escrow), owner_cap_id:
   object::id(owner_cap), owner: tx_context::sender(ctx), amount }`.
   `owner_cap_id` is the cap's identity PK. `owner` is the cap holder
   at this call — first-observed and PK-unrecoverable: `OwnerCap` is
   `key + store` and may have changed hands between `OwnerCapMinted`
   and now (or be held inside a level-2 tenant cap), and no `OwnerCap*`
   lifecycle event co-emits here. Without this field, per-owner queries
   (withdraw frequency per address, multi-cap operators) would have to
   rely on envelope `sender` — forbidden by invariant (d).
7. Return `coin::from_balance(withdrawn, ctx)`.

**No state extraction needed.** `owner_earnings` lives at the struct
level (§2.4) and is mutated through `&mut` directly — no
`option::extract` of `escrow.state` required. The `state` field is
read-only here (via APT in step 2).


5. RENTAL FUNCTIONS
--------------------

### 5.1 `rent`

    public fun rent<Asset: key + store, CoinType>(
        escrow:  &mut RentalEscrow<Asset, CoinType>,
        payment: Coin<CoinType>,
        clock:   &Clock,
        ctx:     &mut TxContext,
    ): TenantCap

**Visibility:** `public`. Single entry point to become a tenant or to
place a bid that will be promoted to tenancy at the next handover.

**Return shape — uniform `TenantCap`.** Under eager minting, every
non-`Retired` branch builds a fresh `TenantCap` and returns it by
value. The cap's ID lands in either `state.HandoverOpen.current.cap_id`
(immediate acquisition) or `state.HandoverConfirmed.pending.cap_id`
(bid awaiting handover); the difference is recorded in the escrow's
state variant, not in the return type. The caller is the bidder /
acquirer themselves and routes the returned cap (own wallet, multisig,
immediate `borrow_asset`, burn for a one-shot PTB, etc.). `borrow_asset`
aborts `E_PENDING_TENANT_CAP` while the cap is in pending state, so a
bidder in tenure-short regimes can poll `borrow_asset` until the
handover settles.

| Pre-rent state (post-settle) | Returned cap's ID lands in | `borrow_asset` succeeds when |
|---|---|---|
| `Idle` | `state.HandoverOpen.current.cap_id` | immediately |
| `AtDutchAuction` | `state.HandoverOpen.current.cap_id` | immediately |
| `HandoverOpen` | `state.HandoverConfirmed.pending.cap_id` (state → HandoverConfirmed) | after `do_handover` rotates pending → current |
| `HandoverConfirmed` | `state.HandoverConfirmed.pending.cap_id` (overwriting; previous cap goes stale) | after `do_handover` rotates pending → current |
| `Retired` | (aborts `E_RETIRED_NO_BID`) | (n/a) |

**Behavior — dispatch over `read_state(escrow)`** (P_DO, §0):

1. `apply_pending_transitions(escrow, clock, ctx)` — settle first, act
   on post-settlement state.
2. Let `now   = clock::timestamp_ms(clock)`,
       `floor = compute_floor_price(escrow, now)`
   — unified floor for all acquisition paths. `compute_floor_price`
   aborts `E_RETIRED_NO_BID` if state is `Retired`, so no `Retired`
   arm is reached in the dispatch below. Same function the SDK calls
   externally — internal and external floor computation share a single
   source of truth with no divergence possible.
3. Assert `coin::value(&payment) >= floor`, abort
   `E_INSUFFICIENT_PAYMENT`.
4. **Dispatch via `read_state`** to the appropriate transition helper.
   Each `do_*` helper owns its own take/put window (P_DO) and emits its
   own event:

   ```move
   match (read_state(escrow)) {
       EscrowState::Idle { .. }
       | EscrowState::AtDutchAuction { .. } =>
           do_install_new_tenant(escrow, payment, floor, now, ctx),
       EscrowState::HandoverOpen { .. } =>
           do_place_bid(escrow, payment, floor, now, ctx),
       EscrowState::HandoverConfirmed { .. } =>
           do_supersede_bid(escrow, payment, floor, ctx),
       EscrowState::Retired { .. } => abort E_INVARIANT_VIOLATION,
           // Unreachable: compute_floor_price (step 2) aborts
           // E_RETIRED_NO_BID before this match runs.
   }
   ```

   - `do_install_new_tenant` (§7.5) — Idle | AtDutchAuction →
     HandoverOpen with a fresh tenant. Mints `TenantCap`, emits
     `RentStarted` carrying the originating variant in `from_state`.
   - `do_place_bid` (§7.10) — HandoverOpen → HandoverConfirmed (initial
     pending bid). Anchors `handover_countdown_expiry`, mints
     `TenantCap`, emits `BidPlaced`. Asserts `!retiring` (aborts
     `E_RETIRE_FLAG_BLOCKS_BID` if the active variant has the flag
     set — blocking new bids is what "retire during HandoverOpen"
     means).
   - `do_supersede_bid` (§7.11) — HandoverConfirmed →
     HandoverConfirmed (replace pending bid). Refunds the displaced
     bidder via push-before-rotate, mints `TenantCap` for the new
     pending tenant, emits `BidSuperseded`. `retiring` is not
     checked — a pending bid was already accepted before retire could
     fire; the committed bid is honored.
   - `Retired` arm aborts `E_INVARIANT_VIOLATION` because step 2 has
     already filtered Retired. Move's exhaustiveness check still
     requires the arm; it is structurally unreachable and the magic
     code flags that to logs / indexers.

5. Return the helper's `TenantCap` directly. Each `do_*` helper's
   return type is `TenantCap`.

The `retiring` check in `do_place_bid` and the `compute_floor_price`
abort on `Retired` are the only state-machine guards — domain errors,
category A. Every other dispatch arm transitions deterministically
from variant to variant.

**Push targets in supersede** — `displaced_bidder` is the address
registered in the slot at prior bid time. Under `key + store` the
prior bidder's cap may have changed hands since, but that is
off-protocol — the protocol's commitment is to the placer's address,
recorded publicly on-chain at bid time. (Symmetric with all other
pushes to addresses-of-record.)

---

### 5.2 `apply_pending_transitions`

    public fun apply_pending_transitions<Asset: key + store, CoinType>(
        escrow: &mut RentalEscrow<Asset, CoinType>,
        clock:  &Clock,
        ctx:    &mut TxContext,
    ): EscrowStateTag

**Visibility:** `public`. Permissionless. Idempotent — a second call
with no elapsed time is a triple no-op.

**Purpose:** execute every elapsed lazy transition, in order. Returns
the settled `EscrowStateTag`.

**Algorithm — bounded match-while loop with iteration canary:**

```move
let now = clock::timestamp_ms(clock);
let mut keep_going = true;
let mut iterations: u64 = 0;
while (keep_going) {
    assert!(iterations < MAX_APT_ITERATIONS, E_INVARIANT_VIOLATION);
    iterations = iterations + 1;
    keep_going = match (read_state(escrow)) {
        EscrowState::HandoverConfirmed { handover_countdown_expiry, .. } => {
            let e = *handover_countdown_expiry;
            if (now >= e) { do_handover(escrow, e, ctx); true } else false
        },
        EscrowState::HandoverOpen { phase_start_ms, .. } => {
            let e = *phase_start_ms + config::tenure_ceiling(&escrow.config);
            if (now >= e) { do_tenure_expiry(escrow, e, ctx); true } else false
        },
        EscrowState::AtDutchAuction { phase_start_ms, .. } => {
            let e = *phase_start_ms + config::descent_ceiling(&escrow.config);
            if (now >= e) { do_auction_expiry(escrow, e); true } else false
        },
        EscrowState::Idle { .. } | EscrowState::Retired { .. } => false,
    };
};
state_tag(read_state(escrow))
```

**Read pattern.** The dispatch arm uses `read_state(escrow)`
(§2.6) to inspect the current variant by reference — no extraction,
no receipt. Only the `do_*` helpers extract by value (via
`take_state` inside the helper) when they need to mutate. P_READ
forbids `read_state` inside an open take/put window; the loop's
shape preserves that — the match arm `read_state` runs strictly
between calls to `do_*`, never inside one.

**Termination — structural argument plus runtime canary.**

- *Structural*: each iteration either fires a strictly progressive
  transition (Confirmed → Open → {Retired | AtDutchAuction → Idle},
  pure descent through the lattice) or returns `false` (terminal
  state or boundary not yet elapsed). The lattice has depth 3 plus
  one terminal no-op iteration that returns `false` and breaks the
  loop. So the loop terminates in at most 4 iterations.
- *Runtime canary*: `MAX_APT_ITERATIONS = 4` (§1.2). The assert at
  the top of each iteration aborts `E_INVARIANT_VIOLATION` if the
  loop reaches a fifth iteration — defending against a future `do_*`
  bug that might produce a non-progressive transition (cycle) and
  spin to gas exhaustion. Pure category-B canary: never reached
  under correct operation; if reached, signals a protocol bug.

**Properties:**
- At most 3 `do_*` calls per APT execution (structural — see
  §9 P4).
- Match-driven dispatch is mandatory: `do_tenure_expiry` would
  misfire on a stale `HandoverConfirmed` variant if the
  `HandoverConfirmed` arm did not fire first. The lattice ordering
  is encoded by the variant the match dispatches into, not by
  textual sequence — every iteration re-reads the current variant.
- `Idle` and `Retired` as starting variants are fast paths — the
  match arm returns `false` immediately. No operations, no events.
  Two iterations total (one match + canary, one terminal `false`).
- **`pending.stake` is never orphaned.** `rent()` clamps the
  handover countdown to `min(now + handover_floor, phase_start_ms +
  tenure_ceiling)`, so the handover boundary is always ≤ tenure
  boundary. The only case where both thresholds coincide
  (`remaining <= handover_floor`, producing
  `state.HandoverConfirmed.handover_countdown_expiry ==
  phase_start_ms + tenure_ceiling`) is resolved by the
  `HandoverConfirmed` arm firing first — by lattice order — leaving
  the variant `HandoverOpen` (with no `pending` field) before the
  next iteration evaluates the `HandoverOpen` arm.

**Emits one event per boundary fired** (`HandoverCompleted`,
`TenureExpired`, `AuctionExpired`) at the boundary's exact timestamp —
not `clock::timestamp_ms(clock)`. When the boundary fires in the same
call as a rent / retire, the caller observes the chain: e.g.
`apply_pending_transitions` fires `HandoverCompleted`, then `rent()`
fires `BidPlaced` on the settled state.


6. ACCESS FUNCTIONS
--------------------

### 6.1 `borrow_asset`

    public fun borrow_asset<Asset: key + store, CoinType>(
        escrow:     &mut RentalEscrow<Asset, CoinType>,
        tenant_cap: &TenantCap,
        clock:      &Clock,
        ctx:        &mut TxContext,
    ): (Asset, AssetReceipt)

**Visibility:** `public`. Single in/out door between the protocol and
the integrating ecosystem.

**Behavior:**
1. `apply_pending_transitions(escrow, clock, ctx)` — settle first. A
   handover that completes here will rotate the variant from
   `HandoverConfirmed` to `HandoverOpen` (with the new `current` cap
   replacing the prior one) before the gates below — a winner who
   polls right at the boundary is admitted; a displaced bidder
   correctly fails.
2. `let escrow_id = object::id(escrow);` — bound once and reused by
   the escrow-match assert (step 3) and the receipt construction (step
   8).
3. `assert!(tenant_cap::escrow_id(tenant_cap) == escrow_id,
   E_WRONG_ESCROW_TENANT_CAP);`
   — **security-critical** escrow-match gate. Same threat model as
   `claim_asset` step 2: PTBs can pair any `&TenantCap` with any
   `&mut RentalEscrow` argument, and the type system does not
   constrain that pairing. Without this assert, a tenant holding a
   legitimate cap for `EscrowA` could pair it with `EscrowB` (for
   which they are not the tenant) and extract `EscrowB`'s asset.
4. `let cap_id = object::id(tenant_cap);`
5. **Dispatch via `read_state`** (P_DO, §0). The active-variant arms
   delegate to `do_extract_asset` (§7.12); the no-tenant arms abort
   `E_STALE_TENANT_CAP` directly:

   ```move
   let asset = match (read_state(escrow)) {
       EscrowState::HandoverOpen { .. }
       | EscrowState::HandoverConfirmed { .. } => do_extract_asset(escrow, cap_id),
       EscrowState::Idle { .. }
       | EscrowState::AtDutchAuction { .. }
       | EscrowState::Retired { .. } => abort E_STALE_TENANT_CAP,
   };
   ```

   **`Idle` / `AtDutchAuction` / `Retired` arm rationale.** These three
   variants carry no tenant data — `do_tenure_expiry` cleared the
   prior tenant or the escrow has never been rented. The presented
   cap's identity cannot match anything in the variant; `E_STALE_TENANT_CAP`
   is the correct semantic remediation ("burn voluntarily"). Domain
   error (category A) — caller error, not invariant violation.

   **`HandoverOpen` / `HandoverConfirmed` arm rationale.** A live
   tenancy exists. `do_extract_asset` runs the cap-identity checks
   (`E_STALE_TENANT_CAP` for non-current cap; `E_PENDING_TENANT_CAP`
   for the pending cap's ID, distinguishing "retry shortly" from
   "burn voluntarily" — opposite remediation guidance, mapped to
   distinct user-facing messages by the SDK), the asset-presence
   check (`E_ASSET_ALREADY_BORROWED` if the variant's `Option<Asset>`
   is `None`, i.e. same-tenant double-borrow inside one PTB), and
   the asset extraction.

   **Defends against displaced-tenant retention.** After `do_handover`
   rotates the variant to `HandoverOpen` with a new `current.cap_id`,
   or after `do_tenure_expiry` clears the variant to `AtDutchAuction`,
   the evicted tenant (or any later holder of their cap, since
   `TenantCap : key + store` is transferable) still holds the old cap
   — `burn` is voluntary. Step 3 alone accepts that cap because
   `cap.escrow_id` still matches; only the variant comparison
   inside `do_extract_asset` exposes the displacement.

6. Construct
   `receipt = AssetReceipt { escrow_id, asset_id: object::id(&asset) }`.
7. Emit `AssetBorrowed { escrow_id, tenant_cap_id: cap_id }`.
   Emit-last: the extraction in step 5 has already succeeded and the
   receipt (step 6) witnesses the asset has left the escrow. The
   tenant's identity is recoverable by JOIN on `tenant_cap_id` to
   `TenantCapMinted` — not duplicated here.
8. Return `(asset, receipt)`.

**Why `return_asset` requires no cap re-verification:** `return_asset`
can only be called by a PTB that holds an `AssetReceipt`. An
`AssetReceipt` can only exist if `borrow_asset` was called and
succeeded in the same PTB — the hot-potato type makes it impossible
to store, transfer, or fabricate. And `borrow_asset` only succeeds
for the current tenant (steps 3, 6). The receipt is therefore
irrefutable proof that cap authorization was already verified. No
re-check is needed.

**PTB clock-fixity — supporting invariant:** Sui fixes
`clock::timestamp_ms(clock)` at checkpoint time; it does not advance
between PTB steps. Any handover due at that timestamp was already
resolved by `apply_pending_transitions` in step 1. No new transitions
can fire within the same transaction, so the `EscrowState` variant
cannot transition after the receipt is issued. This explains why no
state change can have occurred between the two calls — but the
primary authorization argument is the receipt itself.

**Event rationale.** `AssetBorrowed` is the first observable record
that the capability actually leaves custody to be used. The
hot-potato receipt guarantees the borrow is paired with a
`return_asset` in the same PTB, but it does not reach the off-chain
indexer — only emitted events do. Without `AssetBorrowed` /
`AssetReturned`, the indexer cannot distinguish a tenant who
actively uses the asset from one who merely holds the capability —
the core demand signal of liquid renting would be invisible.

---

**PTB borrow window — where the tenant actually uses the asset:**

This window is the core value exchange of the entire protocol. To
understand it, three actors and two protocols must be distinguished:

**Actors:**

- **Integrating protocol** — the protocol that issued the asset and
  defines what it does (a game, a marketplace, a DeFi app). Its
  functions take the asset as an argument and give it meaning. It has
  no knowledge of rental terms, tenants, or escrow state. It does not
  import `rental_escrow`.
- **Owner** — the current holder of the asset who placed it into the
  escrow via `integrate`. The owner may be the same entity as the
  integrating protocol (e.g. the game studio renting out its own
  items) or a completely independent actor (e.g. a user who bought
  the asset on a secondary market and now wants to rent it out). The
  two do not need to coincide.
- **Tenant** — the user who paid `rent()` and holds `TenantCap`. They
  acquire temporary access to use the asset through the integrating
  protocol's functions for the duration of their tenure.

**Protocols:**

- **`rental_escrow`** — the rental market layer. Generic over
  `Asset: key + store`. Owns custody, enforces payment and time bounds,
  manages the state machine. Has no knowledge of what the asset does.
- **Integrating protocol** — defines the asset's utility. Has no
  knowledge of rental terms or escrow state. Was not modified to
  support renting.

The owner bridges the two at setup time: they call `integrate`,
moving the asset out of their wallet and into `rental_escrow`. From
that point, `rental_escrow` holds custody and tenants can rent it.

The tenant bridges the two at use time — and this window is that
moment:

```
  ┌─ rental_escrow ──────────────────────────────────────────────────┐
  │                                                                  │
  │  PTB step N:  borrow_asset(escrow, tenant_cap, clock, ctx)       │
  │                   → (asset, receipt)                             │
  │                          │                                       │
  └──────────────────────────┼───────────────────────────────────────┘
                             │  asset crosses the protocol boundary
                             ▼
  ┌─ integrating protocol ───────────────────────────────────────────┐
  │                                                                  │
  │  PTB steps (N+1 … M-1)                                          │
  │                                                                  │
  │  The tenant — the person who paid `rent()` and holds            │
  │  `TenantCap` — calls the integrating protocol's own             │
  │  functions, passing `asset` by value. This is the actual        │
  │  use the tenant paid for: play with a game item, interact        │
  │  with a marketplace listing, exercise a DeFi position, etc.     │
  │                                                                  │
  │  `receipt` must be threaded through unconsumed.                  │
  │                                                                  │
  │  In practice, the integrating protocol's app constructs this     │
  │  PTB for the tenant — the tenant interacts with the app's UI,   │
  │  not with the raw PTB steps. The borrow/return wrapping is an   │
  │  implementation detail the integrating protocol abstracts away.  │
  │                                                                  │
  └──────────────────────────┬───────────────────────────────────────┘
                             │  asset crosses back
                             ▼
  ┌─ rental_escrow ──────────────────────────────────────────────────┐
  │                                                                  │
  │  PTB step M:  return_asset(escrow, asset, receipt)               │
  │                                                                  │
  └──────────────────────────────────────────────────────────────────┘
```

The hot-potato `AssetReceipt` structurally enforces this window: the
PTB cannot type-check unless `receipt` is consumed by `return_asset`
before the transaction boundary. The asset cannot be stored,
transferred, or dropped inside the window — it must be passed by
value and returned. The tenant cannot extend the window beyond a
single PTB.

This composition is zero-overhead for the integrating protocol: it
requires no changes, imports no `rental_escrow` types, and is
unaware that its asset is being rented. Any protocol that uses
`key + store` objects gains a rental market by integrating with
`rental_escrow`.

**Note on integration levels:** the integrating protocol never needs
to change any contract code. The decoupling is complete: the asset
is the only interface between the two protocols, and the integrating
protocol's functions work identically whether the asset comes from
an owner's wallet or from a liquid renting escrow. A power-user
tenant can always construct the PTB manually — `borrow_asset`, call
the integrating protocol's functions, `return_asset` — with zero
involvement from the integrating protocol.

For non-power-user tenants, the liquid renting SDK provides a tool
to construct this PTB without exposing the escrow mechanics. The SDK
operates exclusively at the frontend / backend layer — it generates
PTBs, never deploys or modifies blockchain code. An integrating
protocol that wants to surface liquid renting natively in its own
app can adopt the SDK optionally, abstracting the borrow window
entirely from its users. This is a UX choice, not a technical
requirement. A protocol that has never heard of liquid renting is
already compatible at the contract level.

---

### 6.2 `return_asset`

    public fun return_asset<Asset: key + store, CoinType>(
        escrow:  &mut RentalEscrow<Asset, CoinType>,
        asset:   Asset,
        receipt: AssetReceipt,
    )

**Visibility:** `public`. Consumes the hot-potato receipt.

**Behavior:**
1. Destructure `receipt`:
   `let AssetReceipt { escrow_id, asset_id } = receipt;`
2. Assert `escrow_id == object::id(escrow)`, abort
   `E_RECEIPT_ESCROW_MISMATCH`.
3. Assert `asset_id == object::id(&asset)`, abort
   `E_RECEIPT_ASSET_MISMATCH`.

**Together these encode: "the same asset returns to the same
escrow."**

- `asset_id` ties receipt to asset: prevents substitution
  (returning a type-compatible but different object — `Asset` is a
  generic `key + store` type, so two instances of `T` are
  structurally indistinguishable except by `object::id`).
- `escrow_id` ties receipt to destination: prevents cross-return
  (redirecting to a different escrow the caller happens to hold
  tenancy of, with compatible `Asset` type).

The hot-potato itself only forces *that* a return happens in the
same PTB; these two fields force *what* that return looks like.
Both asserts are independent — neither alone is sufficient.

4. **Dispatch via `read_state`** (P_DO, §0) and delegate the asset
   refill to `do_fill_asset` (§7.13). The active variant is guaranteed
   to be `HandoverOpen` or `HandoverConfirmed` — PTB clock-fixity
   (§6.1) guarantees the variant is the same one whose `borrow_asset`
   produced this receipt earlier in the same PTB. No transition could
   have fired since:

   ```move
   let tenant_cap_id = match (read_state(escrow)) {
       EscrowState::HandoverOpen { .. }
       | EscrowState::HandoverConfirmed { .. } => do_fill_asset(escrow, asset),
       EscrowState::Idle { .. }
       | EscrowState::AtDutchAuction { .. }
       | EscrowState::Retired { .. } => abort E_INVARIANT_VIOLATION,
           // Unreachable by PTB clock-fixity (§6.1).
   };
   ```

   `do_fill_asset` opens its own take/put window, fills the
   variant's `Option<Asset>` slot via `option::fill` (asserting
   `option::is_none` first with `E_INVARIANT_VIOLATION`, since fill
   on a `Some` would mean the asset was double-restored — a P11
   violation), and returns the active tenant's `cap_id` for the
   `AssetReturned` event.

   The terminal-variant arms abort `E_INVARIANT_VIOLATION` because
   they are unreachable: a valid `AssetReceipt` only exists if
   `borrow_asset` succeeded in the same PTB, which requires an
   active Rented variant; PTB clock-fixity prevents any state
   transition between borrow and return. Move's exhaustiveness
   check still requires the arms; the magic code flags the
   structural unreachability.

5. Emit `AssetReturned { escrow_id, tenant_cap_id }`. Emit-last: the
   asset has already been restored to the escrow (step 4) so the
   `AssetReturned` semantic is realized.
6. Does **not** call `apply_pending_transitions` — returning an asset
   never needs to resolve boundary events; no balance is touched, no
   state-machine field changes. The PTB clock-fixity invariant (§6.1)
   guarantees no new transition can have fired since `borrow_asset`
   ran in the same PTB.

**Event rationale.** See §6.1 — `AssetReturned` closes the borrow
pair the indexer needs to measure actual capability usage. JOIN on
`tenant_cap_id` to the preceding `AssetBorrowed` reconstructs the
full borrow window.


### 6.3 `burn_tenant_cap`

    public fun burn_tenant_cap<Asset: key + store, CoinType>(
        escrow: &mut RentalEscrow<Asset, CoinType>,
        cap:    TenantCap,
        clock:  &Clock,
        ctx:    &mut TxContext,
    )

**Visibility:** `public`. Sole entry point for destroying a `TenantCap`.

**Purpose:** wraps the `tenant_cap::burn` primitive with the
escrow-side gates that prevent a holder from accidentally destroying
their own active access (`current`) or their own pending bid's
promotion target (`pending`). Burning a stale cap is the only
legitimate path; this function aborts otherwise.

**Why the wrapper exists.** Under the eager-mint model, a cap's
relevance is determined entirely by whether its `ID` matches one of
the active variant's tenant fields (`HandoverOpen.current.cap_id` or
`HandoverConfirmed.current.cap_id` / `HandoverConfirmed.pending.cap_id`).
If a holder burned a cap that was still referenced by the variant,
the variant would point at a non-existent object — an "orphaned slot"
— and the asset would become inaccessible until the next state
transition cleared the reference:

- **Current cap burned:** `borrow_asset` aborts (cap doesn't exist
  to present). The asset is unreachable until `do_tenure_expiry`
  rotates the variant out of `HandoverOpen` and into `AtDutchAuction`
  / `Retired`. The holder also forfeits the option to use what they
  paid for; the `current.stake` settles to `owner_earnings` at tenure
  expiry as normal.
- **Pending cap burned:** when `do_handover` rotates the variant from
  `HandoverConfirmed` to `HandoverOpen`, the new `current.cap_id` is
  taken from `pending.cap_id` — which now points at the destroyed
  cap. The bidder's `pending.stake` rotates to `current.stake` and
  ultimately to `owner_earnings` without anyone ever using the asset.
  A pure loss for the bidder, no benefit elsewhere.

Neither failure mode is recoverable. Both are cheap to prevent with a
two-comparison check.

**Behavior:**
1. `apply_pending_transitions(escrow, clock, ctx)` — settle first. A
   cap that was current-but-tenure-expired becomes stale here (the
   variant is rotated out of `HandoverOpen` by `do_tenure_expiry`); a
   cap that was pending-and-ready-for-handover becomes current here
   (rotated by `do_handover`). Without settle, the gate below would
   reject caps that the state machine would otherwise consider stale.
2. `assert!(tenant_cap::escrow_id(&cap) == object::id(escrow),
   E_WRONG_ESCROW_TENANT_CAP);`
   — escrow-match gate. Same threat model as `borrow_asset` step 3:
   PTBs can pair any `TenantCap` with any `&mut RentalEscrow`. Without
   this assert, the wrapper would accept caps from another escrow,
   which would burn objects whose true escrow's variant remains
   unaffected — orphaned reference on a different escrow.
3. **Liveness gate** — single `match` on the active variant via
   `read_state` (§2.6):

   ```move
   let cap_id = object::id(&cap);
   match (read_state(escrow)) {
       EscrowState::HandoverOpen { current, .. } => {
           assert!(current.cap_id != cap_id, E_TENANT_CAP_NOT_STALE);
       },
       EscrowState::HandoverConfirmed { current, pending, .. } => {
           assert!(current.cap_id != cap_id, E_TENANT_CAP_NOT_STALE);
           assert!(pending.cap_id != cap_id, E_TENANT_CAP_NOT_STALE);
       },
       EscrowState::Idle { .. }
       | EscrowState::AtDutchAuction { .. }
       | EscrowState::Retired { .. } => {},
   };
   ```

   Both live cases (HandoverOpen current, HandoverConfirmed
   current-or-pending) surface the same abort code — the caller's
   remediation is identical ("don't burn yet; the cap is still live").
   The SDK distinguishes current vs pending by reading the variant,
   but the abort itself is uniform.

4. `tenant_cap::burn(cap, ctx)` — delegates to the package-private
   primitive, which destroys the cap and emits `TenantCapBurned`.

**Why no `E_LIVE_TENANT_CAP` distinction between current and pending.**
The wrapper's job is to prevent destruction of a live cap; from the
caller's perspective, "live" is binary. Splitting current vs pending
into two abort codes would force the SDK to map both to the same
user-facing message. Read the variant if you need to know which.

**Why call `apply_pending_transitions` first.** A cap whose owner's
tenure has just expired is still referenced by
`HandoverOpen.current.cap_id` until `do_tenure_expiry` rotates the
variant — but it should be burnable. Settling first makes the gate
decision against the post-settle truth, not the pre-settle staleness.
Symmetric with every other write entry point.

**Why no need to check the asset's `Option` slot or any other field.**
Burning a stale cap has no escrow side-effects. The asset's presence
in the escrow, the current variant of the state machine, the balance
fields — none are touched. The wrapper is a pure gating layer over
the destroy primitive.

**Caller composition.** The standard pattern for a former tenant or
displaced bidder cleaning up:
```
rental_escrow::burn_tenant_cap(&mut escrow, cap, &clock, ctx);
```
Single MoveCall in a PTB. No coordination with the escrow holder or
any settler required.


7. PRIVATE HELPERS
-------------------

All helpers are private (`fun`) — visible only within `rental_escrow`.

### 7.1 `do_handover`

    fun do_handover<Asset: key + store, CoinType>(
        escrow:       &mut RentalEscrow<Asset, CoinType>,
        boundary_ms:  u64,       // = state.HandoverConfirmed.handover_countdown_expiry
        ctx:          &mut TxContext,
    )

**Preconditions:** `escrow.state` is
`Some(EscrowState::HandoverConfirmed { .. })` and `boundary_ms`
equals the variant's `handover_countdown_expiry`.

**Convention:** P_DO flavor (b) — orchestrator. The body has no
direct `take_state` call; it composes two state-window owner
sub-steps in sequence, each owning its own take/put cycle.

**Algorithm:**

1. **Distribute the outgoing tenant's balance** by calling
   `do_distribute_balance` (§7.14). Sub-step 1 takes its own state
   window, settles the outgoing tenant 3-way (tenant remain →
   protocol fee → owner earnings), and leaves the state cell on the
   SAME variant (`HandoverConfirmed`) with `current.stake =
   balance::zero()`. The transient zero-stake `Tenant` lives only
   between sub-steps inside this orchestrator body, never at a tx
   boundary (P13). Returns `(displaced_tenant, owner_share,
   protocol_fee, remain_credit)` — the address-of-record and the
   three settlement amounts for the event emit at step 3.

2. **Rotate `pending` → new `current`** by calling
   `do_rotate_for_handover` (§7.15). Sub-step 2 takes its own state
   window, destroys the zero-stake outgoing `current` (with the
   `assert!(balance::value(&zero_stake) == 0, E_INVARIANT_VIOLATION)`
   guard before `balance::destroy_zero` — a P_DO-coherent invariant
   that an in-flight orchestrator cannot bypass), promotes
   `pending` to `current`, and transitions the variant to
   `HandoverOpen` with `phase_start_ms = boundary_ms`. Returns
   `(new_tenant_cap_id, new_rent_price)` for the event emit.

3. Emit `HandoverCompleted { escrow_id: object::id(escrow),
   displaced_tenant, new_tenant_cap_id, used_credit (= owner_share +
   protocol_fee), owner_share, protocol_fee, remain_credit,
   new_rent_price, timestamp_ms: boundary_ms }`. The new tenant's
   address is not carried — already on the co-emitted
   `TenantCapMinted.tenant` row (emitted at bid time; under eager
   minting `do_handover` does not mint) and recoverable by JOIN on
   `new_tenant_cap_id`. `displaced_tenant` *is* carried: no PK path
   reaches the outgoing cap from this row, so recovering it via JOIN
   would force envelope-timing reconstruction (violating star-schema
   invariant d).

**Why orchestrator + sub-steps (and not one fused helper).** Handover
conceptually mutates state twice — first redistributing the outgoing
tenant's balance (no variant change), then changing variant
HandoverConfirmed → HandoverOpen with the rotated tenant. Splitting
into two `do_*` sub-steps separates concerns:

- `do_distribute_balance` is reusable: `do_tenure_expiry` (§7.2)
  composes the same sub-step before its own variant change.
- Each sub-step is auditable in isolation: its take/put window has
  one focused purpose, its match arm has one concrete shape.
- The intermediate zero-stake `Tenant` is transient, only observable
  inside the orchestrator body (§0 P_DO). Two take/put cycles are
  field-level operations on the same shared object — negligible cost.

**Edge cases.** All curve-driven edge cases (`used_credit == 0`,
`used_credit == principal`) are absorbed by the sub-step pipeline
(§7.14). Both extremes fall out of the `if remain_amount > 0` guard
in `pay_tenant_remain` (§7.6) and the `if fee_amount > 0` gate in
`pay_protocol_fee` (§7.6); see §7.14's edge-case table for the
matrix.

---

### 7.2 `do_tenure_expiry`

    fun do_tenure_expiry<Asset: key + store, CoinType>(
        escrow:      &mut RentalEscrow<Asset, CoinType>,
        boundary_ms: u64,       // = phase_start_ms + tenure_ceiling
        ctx:         &mut TxContext,
    )

**Preconditions:** `escrow.state` is `Some(EscrowState::HandoverOpen
{ .. })`. Guaranteed by the lattice-driven dispatch in APT (§5.2):
the `HandoverConfirmed` arm always fires before the `HandoverOpen`
arm in the same loop run. The clamp in `do_place_bid` —
`countdown = min(handover_floor, remaining)` — ensures
`state.HandoverConfirmed.handover_countdown_expiry <= phase_start_ms +
tenure_ceiling`. Two cases:
- `remaining > handover_floor`: handover fires strictly before tenure
  expiry. The next iteration's `HandoverOpen` arm sees a fresh
  `phase_start_ms` (set by `do_handover`) and does not fire.
- `remaining <= handover_floor`: both boundaries coincide at
  `phase_start_ms + tenure_ceiling`. The `HandoverConfirmed` arm
  fires first, resetting the new variant's `phase_start_ms` to
  `boundary_ms`. The next iteration's `HandoverOpen` arm evaluates
  against the new `phase_start_ms + tenure_ceiling` — in the future
  — and does not fire. T(n+1) receives a full tenure.

**Invariant on entry.** The variant is `HandoverOpen` (single tenant,
no pending). The structural argument: only `do_install_new_tenant`
(direct acquisition: Idle / AtDutchAuction → HandoverOpen without a
pending phase) and `do_handover` (HandoverConfirmed → HandoverOpen)
can produce `HandoverOpen`. No code path can produce a
`HandoverConfirmed` variant after `HandoverOpen` was just settled by
the prior loop iteration; therefore the variant at this point is
`HandoverOpen`. The
type system enforces that no `pending` field exists to clear separately.

**Convention:** P_DO flavor (b) — orchestrator. The body has no
direct `take_state` call; it composes two state-window owner
sub-steps in sequence.

**Algorithm:**

1. **Distribute the outgoing tenant's balance** by calling
   `do_distribute_balance` (§7.14). Sub-step 1 takes its own state
   window, settles the outgoing tenant. At tenure expiry the
   curve-driven `used_credit` saturates to `principal` (curve at
   `elapsed = tenure_ceiling` returns `SCALE`; see §8.1). The 3-way
   split therefore degenerates: `remain_credit = 0` (tenant gets
   nothing back), the protocol-fee + owner-earnings legs absorb the
   full stake. The sub-step's HandoverOpen-arm asserts
   `remain_credit == 0` against `E_INVARIANT_VIOLATION` — a
   structural witness of the curve property; if the curve ever
   stopped saturating at the boundary, this assert catches it
   before any non-zero remain mis-routes to a fully-elapsed tenant.
   The state cell is left on the SAME variant (`HandoverOpen`)
   with `current.stake = balance::zero()`. Returns `(tenant,
   owner_share, protocol_fee, _remain == 0)`.

2. **`last_acquisition_price = owner_share + protocol_fee`** —
   recovered from the returned amounts. By the curve invariant
   (`remain_credit == 0`, asserted at step 1), `owner_share +
   protocol_fee = used_credit = principal`, so this equals the
   outgoing tenant's stake at tenure entry. Becomes the descent
   ceiling under the AtDutchAuction next-variant branch.

3. **Determine the next variant** by calling `do_terminate_tenure`
   (§7.16) with `boundary_ms` and `last_acquisition_price`.
   Sub-step 2 takes its own state window, destroys the zero-stake
   outgoing `current` (with the
   `assert!(balance::value(&zero_stake) == 0, E_INVARIANT_VIOLATION)`
   guard before `balance::destroy_zero`), unwraps the asset
   (`assert!(option::is_some(&asset_opt), E_INVARIANT_VIOLATION)`,
   guaranteed Some by P11), and branches on `retiring`:
     - if `retiring`: variant becomes `EscrowState::Retired { asset }`.
     - else: variant becomes `EscrowState::AtDutchAuction { asset,
       phase_start_ms: boundary_ms, last_acquisition_price }`.
   Returns the next-state tag for the event emit. `phase_start_ms`
   follows the convention that every transition site records the
   moment of transition — for AtDutchAuction it anchors descent;
   under Retired it is omitted (no field).

4. Emit `TenureExpired { escrow_id: object::id(escrow), tenant,
   owner_share, protocol_fee, last_acquisition_price (from step 2),
   next_state: next_tag, timestamp_ms: boundary_ms }`.
   `last_acquisition_price` is frozen into this row: it is the
   anchor of the subsequent Dutch descent (if `next_state =
   AtDutchAuction`) and makes the Dutch current-price computation a
   single-event query.

5. If `next_tag == EscrowStateTag::Retired` (the `retiring` branch of
   step 3), emit `AssetRetired { escrow_id, from_state:
   EscrowStateTag::HandoverOpen }` immediately after `TenureExpired`.
   Structural co-emission: the indexer recovers the authoritative
   transition timestamp by JOIN on `escrow_id` to the co-emitted
   `TenureExpired.timestamp_ms`. Emit order is `TenureExpired` first
   (stake settlement), `AssetRetired` second (state-machine
   transition); both belong to the same semantic moment.

**Why orchestrator + sub-steps share `do_distribute_balance`.** The
balance-distribution responsibility is identical between handover
and tenure expiry: split the outgoing tenant's stake 3-way, dispatch
to consumers (tenant remain / protocol fee / owner earnings),
return the amounts. Only the second-step "what variant comes next"
differs (handover rotates pending → current; tenure expiry
transitions to AtDutchAuction or Retired). Decomposing into a shared
sub-step + transition-specific terminator keeps each concern in
one place.

**Note:** the displaced tenant's `TenantCap` is not burned here. It
becomes stale (the new variant — `AtDutchAuction` or `Retired` —
carries no tenant data, so the cap's ID matches no live field) and
is inert. The holder may call `burn_tenant_cap` voluntarily for gas
recovery.

---

### 7.3 `do_auction_expiry`

    fun do_auction_expiry<Asset: key + store, CoinType>(
        escrow:      &mut RentalEscrow<Asset, CoinType>,
        boundary_ms: u64,       // = phase_start_ms + descent_ceiling
    )

**Preconditions:** `escrow.state` is
`Some(EscrowState::AtDutchAuction { .. })`.

**Algorithm:**

1. **Extract state via `take_state`** (§2.6) and dispatch on the
   variant; only `AtDutchAuction` is the precondition:

   ```move
   let (old, receipt) = take_state(escrow);
   let asset = match (old) {
       EscrowState::AtDutchAuction { asset, phase_start_ms: _, last_acquisition_price: _ } => asset,
       EscrowState::Idle              { asset: _a }                                            => abort E_INVARIANT_VIOLATION,
       EscrowState::HandoverOpen      { asset: _a, current: _c, .. }                           => abort E_INVARIANT_VIOLATION,
       EscrowState::HandoverConfirmed { asset: _a, current: _c, pending: _p, .. }              => abort E_INVARIANT_VIOLATION,
       EscrowState::Retired           { asset: _a }                                            => abort E_INVARIANT_VIOLATION,
   };
   ```

   `phase_start_ms` and `last_acquisition_price` are dropped — `Idle`
   carries no time-dependent fields.

2. **Discharge the receipt via `put_state` with `Idle`:**
   ```
   put_state(escrow, EscrowState::Idle { asset }, receipt);
   ```

3. Emit `AuctionExpired { escrow_id: object::id(escrow), timestamp_ms:
   boundary_ms }`. The transition is always `AtDutchAuction → Idle`;
   `do_auction_expiry` is the sole emission site (retire from
   AtDutchAuction takes a different path — §4.2 step 6). Unambiguous
   by construction, no `next_state` field.

**Note on `last_acquisition_price`:** dropped here. After auction
expiry, the escrow is `Idle` — no descent context to preserve. The
next `rent()` from `Idle` writes a fresh acquisition price into
`current.stake` via `do_install_new_tenant` (§7.5).

---

### 7.4 `split_fee`

    fun split_fee(amount: u64): (u64, u64)

**Purpose:** pure function that splits an amount into `(owner_share,
fee_share)` at 90 / 10.

**Algorithm:**

    let fee   = math::mul_div(amount, PROTOCOL_FEE_BPS, BPS_PER_UNIT);
    let owner = amount - fee;
    (owner, fee)

**Properties:**
- `owner + fee == amount` always (no rounding loss — subtraction is
  exact).
- `fee <= floor(amount * 0.10)` — floor rounding favors the owner by
  at most 1 base unit. Economically negligible; structurally simple.
- `split_fee(0) == (0, 0)`.
- `split_fee(n) == (n, 0)` for `n < 10` — fee floors to zero on
  amounts below 10 base units. Callers (`do_handover`,
  `do_tenure_expiry`, via `settle_stake_earnings`) gate on `protocol_fee >
  0` and skip the split + `fee_message::post` when it is zero, so no
  zero-balance `FeeMessage<C>` is ever constructed.

---

### 7.5 `do_install_new_tenant`

    fun do_install_new_tenant<Asset: key + store, CoinType>(
        escrow:  &mut RentalEscrow<Asset, CoinType>,
        payment: Coin<CoinType>,
        floor:   u64,
        now:     u64,
        ctx:     &mut TxContext,
    ): TenantCap

**Preconditions:** caller is `rent()` dispatching from `Idle` or
`AtDutchAuction`, with payment already validated against
`compute_floor_price` (unified floor check in §5.1 step 2). `now` is
`clock::timestamp_ms(clock)` from the caller — passed in because
PTB clock-fixity (§6.1) makes the value identical for the entire
PTB; no need to read the clock again inside the helper.

**Purpose:** Idle | AtDutchAuction → HandoverOpen with a fresh
tenant. Performs `take_state` / `put_state` internally (P_DO),
mints `TenantCap` via `tenant_cap::new`, emits `RentStarted` with
the originating variant in `from_state`. Returns the new
`TenantCap` for the caller to surface in its return.

**Algorithm:**

```move
let escrow_id  = object::id(escrow);
let price_paid = coin::value(&payment);
let (old, receipt) = take_state(escrow);
let (asset, from_state) = match (old) {
    EscrowState::Idle { asset } =>
        (asset, EscrowStateTag::Idle),
    EscrowState::AtDutchAuction { asset, phase_start_ms: _, last_acquisition_price: _ } =>
        (asset, EscrowStateTag::AtDutchAuction),
    EscrowState::HandoverOpen      { asset: _a, current: _c, .. }                           => abort E_INVARIANT_VIOLATION,
    EscrowState::HandoverConfirmed { asset: _a, current: _c, pending: _p, .. }              => abort E_INVARIANT_VIOLATION,
    EscrowState::Retired           { asset: _a }                                            => abort E_INVARIANT_VIOLATION,
};
let stake       = coin::into_balance(payment);
let tenant_addr = ctx.sender();
let (new_cap, new_cap_id) = tenant_cap::new(escrow_id, tenant_addr, ctx);
let current = Tenant { cap_id: new_cap_id, address: tenant_addr, stake };
put_state(escrow, EscrowState::HandoverOpen {
    asset:           option::some(asset),
    phase_start_ms:  now,
    current,
    retiring:        false,
}, receipt);
event::emit(RentStarted {
    escrow_id,
    tenant_cap_id: new_cap_id,
    price_paid,
    floor_price: floor,
    from_state,
});
new_cap
```

**Return value:** the new `TenantCap` by value. The caller
(`rent()`) surfaces it in its return.

**Why the helper emits `RentStarted` itself:** under the dispatch
pattern (§5.1), `rent()` is a pure dispatcher — it does not
participate in event emission. The `from_state` discriminator is
captured inside the helper from the variant arm at destructure
time, so the event remains accurate without re-reading state
afterward.

**Two call sites (both reached via `rent()` dispatch on §5.1):**

| Caller | Floor source | Event `from_state` |
|---|---|---|
| `rent()` Idle arm (§5.1) | `compute_floor_price` | `EscrowStateTag::Idle` |
| `rent()` AtDutchAuction arm (§5.1) | `compute_floor_price` | `EscrowStateTag::AtDutchAuction` |

**Not reused by `do_handover`:** `do_handover` also produces a
`HandoverOpen` variant, but the surrounding context differs
structurally — `pending.stake` rotates into `current.stake` (not a
fresh payment), the address is `pending.address` (not `sender(ctx)`),
no cap is minted (eager minting delivered it at `rent` time),
`phase_start_ms = boundary_ms` (not `now`), and `retiring` is
inherited from the prior `HandoverConfirmed` variant. Merging the
two would force context-dependent branching inside the helper and
obscure the distinct semantics of each rotation site.


### 7.6 Settlement primitives — `settle_tenant`, `pay_tenant_remain`, `pay_protocol_fee`

This section covers the three pipeline-style helpers used inside
`do_distribute_balance` (§7.14). Each step in the 3-way distribution
is its own helper consuming a balance and returning the leftover; the
settlement pipeline is materialized at the call site rather than
hidden inside a single fused helper.

**Pipeline shape inside `do_distribute_balance`:**

```move
let (zero_current, payer, leftover, remain_credit) = settle_tenant(current, used_credit, ctx);
let leftover                                       = pay_protocol_fee(leftover, protocol_fee, escrow_id, payer, fee_inbox_id, ctx);
balance::join(&mut escrow.owner_earnings, leftover);
```

Three lines, three actors: tenant (line 1), protocol (line 2), owner
(line 3 — `balance::join` is the third "consumer" but stays inline,
since it is one idiomatic Move call).

#### 7.6.a `settle_tenant`

    fun settle_tenant<CoinType>(
        tenant:      Tenant<CoinType>,
        used_credit: u64,
        ctx:         &mut TxContext,
    ): (Tenant<CoinType>, address, Balance<CoinType>, u64)

**Purpose:** consume the outgoing `Tenant<C>`, pay the tenant their
`remain_credit` (= `principal − used_credit`), return the leftover
`Balance<C>` (size = `used_credit`) for the caller to continue the
pipeline. Also returns a zero-stake `Tenant<C>` for state
reconstruction by the orchestrator, the payer address, and the
`remain_credit` u64 for events.

**Algorithm:**

    let Tenant { cap_id, address: payer, stake } = tenant;
    let principal     = balance::value(&stake);
    let remain_credit = principal - used_credit;
    let leftover      = pay_tenant_remain(stake, remain_credit, payer, ctx);
    let zero_tenant   = Tenant { cap_id, address: payer, stake: balance::zero() };
    (zero_tenant, payer, leftover, remain_credit)

**Why no `&mut RentalEscrow`:** the helper does not touch any escrow
field. The pre-split work (compute `principal`, derive `remain_credit`)
and the cap_id-preserving zero-`Tenant` construction are pure
operations on the consumed `Tenant<C>` value.

#### 7.6.b `pay_tenant_remain`

    fun pay_tenant_remain<CoinType>(
        mut balance:   Balance<CoinType>,
        remain_amount: u64,
        tenant:        address,
        ctx:           &mut TxContext,
    ): Balance<CoinType>

**Purpose:** split `remain_amount` off `balance` and refund it to
`tenant`; return the residual. Push-before-rotate (P3) primitive.

**Algorithm:**

    if remain_amount > 0 {
        let part = balance::split(&mut balance, remain_amount);
        transfer::public_transfer(coin::from_balance(part, ctx), tenant);
    };
    balance

**Why the `> 0` gate:** when `remain_amount == 0` the function
returns the full `balance` untouched without constructing a
zero-valued `Coin<C>` or invoking `transfer::public_transfer` —
saves a no-op transfer and avoids a useless coin object on chain.

#### 7.6.c `pay_protocol_fee`

    fun pay_protocol_fee<CoinType>(
        mut balance:  Balance<CoinType>,
        fee_amount:   u64,
        escrow_id:    ID,
        payer:        address,
        fee_inbox_id: ID,
        ctx:          &mut TxContext,
    ): Balance<CoinType>

**Purpose:** split `fee_amount` off `balance` and post it to the
protocol fee inbox via `fee_message::post`; return the residual
(= `owner_share` after settlement).

**Algorithm:**

    if fee_amount > 0 {
        let part = balance::split(&mut balance, fee_amount);
        fee_message::post<CoinType>(part, escrow_id, payer, fee_inbox_id, ctx);
    };
    balance

**Why the `> 0` gate:** §7.4 `split_fee` floors the protocol fee to
zero when `principal < BPS_PER_UNIT / PROTOCOL_FEE_BPS == 10`. The
gate prevents a zero-valued `FeeMessage<C>` child object from being
created — semantically noisy, indexer-aggregation-hostile, see §9
P12.

**Pipeline reuse.** The 3-way distribution composes the three
helpers in `do_distribute_balance` (§7.14). The pipeline runs
identically for both `HandoverConfirmed` (handover) and
`HandoverOpen` (tenure expiry) variants — only the variant
reconstruction differs. At tenure expiry the curve property
(used_credit == principal at elapsed = tenure_ceiling) makes the
tenant payment a no-op; the `assert!(remain_credit == 0,
E_INVARIANT_VIOLATION)` in `do_distribute_balance`'s HandoverOpen
arm makes that property a verifiable invariant rather than an
unstated assumption.


### 7.7 `register_pending_bid`

    fun register_pending_bid<CoinType>(
        escrow_id: ID,
        payment:   Coin<CoinType>,
        bidder:    address,
        ctx:       &mut TxContext,
    ): (TenantCap, Tenant<CoinType>)

**Purpose:** shared pending-bid construction tail for the two Rented
arms of `rent()` (§5.1). Absorbs `payment` into a fresh
`Tenant<CoinType>` value with `bidder` as the address and builds the
bidder's `TenantCap` via `tenant_cap::new`. Returns `(cap, pending)` —
the cap travels back through `rent` to the PTB caller; the caller
embeds `pending` into the new `HandoverConfirmed.pending` slot and
derives the event fields from the returned values: `tenant_cap_id =
object::id(&cap)` and `bid_amount = balance::value(&pending.stake)`.

**Why the minimal return.** The two derivable values (`tenant_cap_id`
and `bid_amount`) are explicit projections at the call site rather
than helper return values, mirroring the same redundancy-elimination
applied to `do_install_new_tenant`. The function returns only the
linear values it constructs; the caller's `object::id` /
`balance::value` calls make the projection explicit and obvious.

**Algorithm:**

    let stake = coin::into_balance(payment);
    let (cap, tenant_cap_id) = tenant_cap::new(escrow_id, bidder, ctx);
    let pending = Tenant { cap_id: tenant_cap_id, address: bidder, stake };
    (cap, pending)

**Caller pattern:**

```move
let (cap, pending) = register_pending_bid(escrow_id, payment, bidder, ctx);
let pending_cap_id = object::id(&cap);
let bid_amount     = balance::value(&pending.stake);   // before put_state moves pending
// ... put_state with HandoverConfirmed { ..., pending, ... } ...
// ... event::emit { ..., tenant_cap_id: pending_cap_id, bid_amount, ... } ...
```

The `bid_amount` read must precede the `put_state` that moves
`pending` into the variant.

**Preconditions:**
- Caller has already verified `coin::value(&payment) >= floor` (from
  `compute_floor_price`, step 2 of `rent()`).
- For the supersede path (`HandoverConfirmed` caller), the previous
  pending tenant has already been refunded and the prior `pending`
  Tenant value destructured (push-before-rotate invariant, §9 P3 —
  owned by the caller).

**Postconditions:**
- A new `TenantCap` exists with `escrow_id == escrow_id`.
  `TenantCapMinted` has been emitted by `tenant_cap::new`.
- The cap travels back through `rent`'s return to the PTB caller.
- The `Tenant<CoinType>` value carries the bidder's stake, cap_id,
  and address atomically — ready for the caller to embed in
  `HandoverConfirmed.pending`.

**Why no `recipient` parameter:** the bidder is, by construction, the
PTB caller of `rent` — `tx_context::sender(ctx)` — across both Rented
sub-branches. The caller passes it explicitly so the helper is total
on its own inputs (no `&mut TxContext` reach into the protocol's
sender at non-obvious moments). The cap is returned by value; the
helper does not perform a transfer and does not need to know the
recipient address. The mint-time address is recorded on
`TenantCapMinted.tenant` (= `bidder`); the address-of-record for
refund pushes lives in `Tenant.address` (set inside this helper,
populating the new pending slot).

**Why the helper does not emit `BidPlaced` / `BidSuperseded`:** the
two events differ structurally — `BidPlaced` carries `tenant_cap_id`,
`pending_tenant`, and `handover_countdown_expiry`; `BidSuperseded`
carries `displaced_tenant_cap_id`, `new_tenant_cap_id`,
`displaced_bidder`, `refunded_amount`, `new_bidder`, `new_bid_amount`.
Both carry `floor_price`, which is the `floor` local from `rent()`
step 2 — available at the caller, not inside the helper. Their
arm-specific pre-tail setup (variant destructure + countdown
computation for HandoverOpen; variant destructure + refund for
HandoverConfirmed) also differs. Emit-last at each caller keeps the
event semantic aligned with the full bid-placement transition, not
with the shared payment tail alone.

**Two call sites:**

| Caller | Pre-tail work | Emitted event |
|---|---|---|
| `do_place_bid` (§7.10) | retire-flag check, variant destructure, countdown computation, call helper, derive cap_id/bid_amount, fill new HandoverConfirmed variant | `BidPlaced` |
| `do_supersede_bid` (§7.11) | variant destructure (captures `current`, `displaced`, `retiring`, `handover_countdown_expiry`), refund displaced.stake to displaced.address, call helper, derive cap_id/bid_amount, fill new HandoverConfirmed variant with preserved `current`, `retiring`, `handover_countdown_expiry` | `BidSuperseded` |

Both arms share the same payment + cap-minting tail; the helper is
the single source of truth for that tail.


### 7.8 `do_retire_immediately`

    fun do_retire_immediately<Asset: key + store, CoinType>(
        escrow: &mut RentalEscrow<Asset, CoinType>,
        ctx:    &TxContext,
    ): EscrowStateTag

**Preconditions:** caller is `retire()` dispatching from `Idle` or
`AtDutchAuction` (§4.2 step 4). Owner-cap binding has already been
asserted, retire-floor has elapsed, and APT has run.

**Purpose:** Idle | AtDutchAuction → Retired (immediate retirement,
no deferral). Performs `take_state` / `put_state` internally (P_DO);
co-emits `RetireFlagSet` (records owner intent + originating state)
and `AssetRetired` (state transition realized). Returns the new
state tag (always `Retired`).

**Algorithm:**

```move
let escrow_id = object::id(escrow);
let (old, receipt) = take_state(escrow);
let (asset, prior_tag) = match (old) {
    EscrowState::Idle { asset } =>
        (asset, EscrowStateTag::Idle),
    EscrowState::AtDutchAuction { asset, phase_start_ms: _, last_acquisition_price: _ } =>
        (asset, EscrowStateTag::AtDutchAuction),
    EscrowState::HandoverOpen      { asset: _a, current: _c, .. }                           => abort E_INVARIANT_VIOLATION,
    EscrowState::HandoverConfirmed { asset: _a, current: _c, pending: _p, .. }              => abort E_INVARIANT_VIOLATION,
    EscrowState::Retired           { asset: _a }                                            => abort E_INVARIANT_VIOLATION,
};
put_state(escrow, EscrowState::Retired { asset }, receipt);
event::emit(RetireFlagSet { escrow_id, owner: ctx.sender(), state_at_set: prior_tag });
event::emit(AssetRetired { escrow_id, from_state: prior_tag });
EscrowStateTag::Retired
```

**Why no `&mut TxContext`:** the helper only reads `ctx.sender()` for
the `RetireFlagSet.owner` field. No object creation, no transfer.
Taking `&TxContext` flags this signal at the type-level and avoids
the `unused mutable reference` warning (W09014).

**Note on `AtDutchAuction` arm.** No `AuctionExpired` is emitted —
the auction was *interrupted*, not *expired*. Boundary-aligned
`phase_start_ms` and `last_acquisition_price` are dropped: Retired
carries no time-dependent data.


### 7.9 `do_set_retiring_flag`

    fun do_set_retiring_flag<Asset: key + store, CoinType>(
        escrow: &mut RentalEscrow<Asset, CoinType>,
        ctx:    &TxContext,
    ): EscrowStateTag

**Preconditions:** caller is `retire()` dispatching from
`HandoverOpen` or `HandoverConfirmed` (§4.2 step 4). Same outer
preconditions as `do_retire_immediately`.

**Purpose:** HandoverOpen | HandoverConfirmed → same variant with
`retiring: true` (deferred retirement). Performs `take_state` /
`put_state` internally (P_DO); emits `RetireFlagSet` only —
`AssetRetired` is emitted later by `do_tenure_expiry` (§7.2) when
the flag is honored. Returns the (unchanged) state tag.

**Algorithm:**

```move
let escrow_id = object::id(escrow);
let (old, receipt) = take_state(escrow);
let (new_state, prior_tag) = match (old) {
    EscrowState::HandoverOpen { asset, phase_start_ms, current, retiring } => {
        assert!(!retiring, E_ALREADY_RETIRED);
        let new = EscrowState::HandoverOpen {
            asset, phase_start_ms, current, retiring: true,
        };
        (new, EscrowStateTag::HandoverOpen)
    },
    EscrowState::HandoverConfirmed {
        asset, phase_start_ms, current, pending, retiring, handover_countdown_expiry,
    } => {
        assert!(!retiring, E_ALREADY_RETIRED);
        let new = EscrowState::HandoverConfirmed {
            asset, phase_start_ms, current, pending,
            retiring: true,
            handover_countdown_expiry,
        };
        (new, EscrowStateTag::HandoverConfirmed)
    },
    EscrowState::Idle           { asset: _a }                          => abort E_INVARIANT_VIOLATION,
    EscrowState::AtDutchAuction { asset: _a, .. }                      => abort E_INVARIANT_VIOLATION,
    EscrowState::Retired        { asset: _a }                          => abort E_INVARIANT_VIOLATION,
};
put_state(escrow, new_state, receipt);
event::emit(RetireFlagSet { escrow_id, owner: ctx.sender(), state_at_set: prior_tag });
prior_tag
```

The `assert!(!retiring, ...)` checks inside the Rented arms catch
the second-call case while a tenant is still active. `retiring` is
inherited verbatim across `do_handover` (§7.1 step 7), so the flag
applies to T(n+1)'s tenure once handover completes.


### 7.10 `do_place_bid`

    fun do_place_bid<Asset: key + store, CoinType>(
        escrow:  &mut RentalEscrow<Asset, CoinType>,
        payment: Coin<CoinType>,
        floor:   u64,
        now:     u64,
        ctx:     &mut TxContext,
    ): TenantCap

**Preconditions:** caller is `rent()` dispatching from
`HandoverOpen` (§5.1 step 4). Payment already validated against
floor; `now = clock::timestamp_ms(clock)` is from the caller.

**Purpose:** HandoverOpen → HandoverConfirmed (initial pending bid).
Performs `take_state` / `put_state` internally (P_DO), enforces
`!retiring` (aborts `E_RETIRE_FLAG_BLOCKS_BID` — domain error,
category A, the user-visible "retire blocks new bid" semantic),
anchors `handover_countdown_expiry`, mints `TenantCap` via
`register_pending_bid` (§7.7), emits `BidPlaced`. Returns the new
`TenantCap`.

**Algorithm:**

```move
let escrow_id      = object::id(escrow);
let pending_tenant = ctx.sender();
let (old, receipt) = take_state(escrow);
let (asset, phase_start_ms, current, retiring) = match (old) {
    EscrowState::HandoverOpen { asset, phase_start_ms, current, retiring } => {
        assert!(!retiring, E_RETIRE_FLAG_BLOCKS_BID);
        (asset, phase_start_ms, current, retiring)
    },
    EscrowState::Idle              { asset: _a }                                            => abort E_INVARIANT_VIOLATION,
    EscrowState::AtDutchAuction    { asset: _a, .. }                                        => abort E_INVARIANT_VIOLATION,
    EscrowState::HandoverConfirmed { asset: _a, current: _c, pending: _p, .. }              => abort E_INVARIANT_VIOLATION,
    EscrowState::Retired           { asset: _a }                                            => abort E_INVARIANT_VIOLATION,
};
let tenure_e                  = phase_start_ms + config::tenure_ceiling(&escrow.config);
let remaining                 = tenure_e - now;
let countdown                 = std::u64::min(config::handover_floor(&escrow.config), remaining);
let handover_countdown_expiry = now + countdown;
let (cap, pending_cap_id, bid_amount, pending) =
    register_pending_bid(escrow_id, payment, pending_tenant, ctx);
put_state(escrow, EscrowState::HandoverConfirmed {
    asset, phase_start_ms, current, pending,
    retiring,                     // false here, but preserved verbatim
    handover_countdown_expiry,
}, receipt);
event::emit(BidPlaced {
    escrow_id,
    tenant_cap_id: pending_cap_id,
    pending_tenant,
    bid_amount,
    floor_price: floor,
    handover_countdown_expiry,
});
cap
```

**Retire flag rationale:** blocking new bids is what "retire during
HandoverOpen" means — the current tenant completes their block
uncontested and the asset exits afterward. The assert is a domain
error (category A), not an invariant violation.


### 7.11 `do_supersede_bid`

    fun do_supersede_bid<Asset: key + store, CoinType>(
        escrow:  &mut RentalEscrow<Asset, CoinType>,
        payment: Coin<CoinType>,
        floor:   u64,
        ctx:     &mut TxContext,
    ): TenantCap

**Preconditions:** caller is `rent()` dispatching from
`HandoverConfirmed` (§5.1 step 4). Payment already validated against
floor.

**Purpose:** HandoverConfirmed → HandoverConfirmed (replace pending
bid). Refunds the displaced bidder via push-before-rotate (§9 P3),
mints `TenantCap` for the new pending tenant via `register_pending_bid`
(§7.7), preserves `current` / `retiring` / `handover_countdown_expiry`,
emits `BidSuperseded`. Returns the new `TenantCap`.

**`retiring` is NOT checked here** — a pending bid was already
accepted before retire could fire; the committed bid is honored, the
handover completes normally, and T(n+1) then enters `HandoverOpen`
with the flag still set (no further bids accepted there). Same
rationale as the prior in-line `rent()` HandoverConfirmed case.

**Algorithm:**

```move
let escrow_id  = object::id(escrow);
let new_bidder = ctx.sender();
let (old, receipt) = take_state(escrow);
let (asset, phase_start_ms, current, displaced, retiring, handover_countdown_expiry) = match (old) {
    EscrowState::HandoverConfirmed {
        asset, phase_start_ms, current, pending: displaced,
        retiring, handover_countdown_expiry,
    } => (asset, phase_start_ms, current, displaced, retiring, handover_countdown_expiry),
    EscrowState::Idle           { asset: _a }                          => abort E_INVARIANT_VIOLATION,
    EscrowState::AtDutchAuction { asset: _a, .. }                      => abort E_INVARIANT_VIOLATION,
    EscrowState::HandoverOpen   { asset: _a, current: _c, .. }         => abort E_INVARIANT_VIOLATION,
    EscrowState::Retired        { asset: _a }                          => abort E_INVARIANT_VIOLATION,
};
let Tenant {
    cap_id: displaced_cap_id, address: displaced_bidder, stake: refund_balance,
} = displaced;
let refunded_amount = balance::value(&refund_balance);
transfer::public_transfer(coin::from_balance(refund_balance, ctx), displaced_bidder);
let (cap, new_pending_cap_id, new_bid_amount, new_pending) =
    register_pending_bid(escrow_id, payment, new_bidder, ctx);
put_state(escrow, EscrowState::HandoverConfirmed {
    asset, phase_start_ms, current,
    pending: new_pending,
    retiring,
    handover_countdown_expiry,
}, receipt);
event::emit(BidSuperseded {
    escrow_id,
    displaced_tenant_cap_id: displaced_cap_id,
    new_tenant_cap_id: new_pending_cap_id,
    displaced_bidder,
    refunded_amount,
    new_bidder,
    new_bid_amount,
    floor_price: floor,
});
cap
```

The displaced cap whose ID is now bound to `displaced_cap_id` is
absent from the new variant and is thus stale (no protocol action
needed; the displaced bidder may `burn_tenant_cap` voluntarily).
`handover_countdown_expiry` is **not reset** on supersede
(design-compact §4) — the boundary remains anchored to the first
bid that opened the handover.


### 7.12 `do_extract_asset`

    fun do_extract_asset<Asset: key + store, CoinType>(
        escrow: &mut RentalEscrow<Asset, CoinType>,
        cap_id: ID,
    ): Asset

**Preconditions:** caller is `borrow_asset` dispatching from
`HandoverOpen` or `HandoverConfirmed` (§6.1 step 5). The terminal
variants are filtered by the public dispatch — never reached here.
`cap_id = object::id(tenant_cap)` from the caller.

**Purpose:** extract the asset from the active rented variant via
`option::extract`. Performs `take_state` / `put_state` internally
(P_DO). Validates the caller's `TenantCap` against `current.cap_id`
(rejects `pending.cap_id` on `HandoverConfirmed` with
`E_PENDING_TENANT_CAP` for the "retry" semantic). Asserts the
asset's `Option` slot is `Some` (aborts `E_ASSET_ALREADY_BORROWED`
on same-tenant double-borrow inside one PTB).

**Algorithm:**

```move
let (old, receipt) = take_state(escrow);
let (asset, new_state) = match (old) {
    EscrowState::HandoverOpen { asset, phase_start_ms, current, retiring } => {
        assert!(cap_id == current.cap_id, E_STALE_TENANT_CAP);
        let mut asset_opt = asset;
        assert!(option::is_some(&asset_opt), E_ASSET_ALREADY_BORROWED);
        let extracted = option::extract(&mut asset_opt);
        let new = EscrowState::HandoverOpen {
            asset: asset_opt, phase_start_ms, current, retiring,
        };
        (extracted, new)
    },
    EscrowState::HandoverConfirmed {
        asset, phase_start_ms, current, pending, retiring, handover_countdown_expiry,
    } => {
        assert!(cap_id != pending.cap_id, E_PENDING_TENANT_CAP);
        assert!(cap_id == current.cap_id, E_STALE_TENANT_CAP);
        let mut asset_opt = asset;
        assert!(option::is_some(&asset_opt), E_ASSET_ALREADY_BORROWED);
        let extracted = option::extract(&mut asset_opt);
        let new = EscrowState::HandoverConfirmed {
            asset: asset_opt, phase_start_ms, current, pending, retiring,
            handover_countdown_expiry,
        };
        (extracted, new)
    },
    EscrowState::Idle           { asset: _a }     => abort E_INVARIANT_VIOLATION,
    EscrowState::AtDutchAuction { asset: _a, .. } => abort E_INVARIANT_VIOLATION,
    EscrowState::Retired        { asset: _a }     => abort E_INVARIANT_VIOLATION,
};
put_state(escrow, new_state, receipt);
asset
```

**`HandoverConfirmed` arm rationale.** Pending check runs first.
`E_PENDING_TENANT_CAP` signals "retry shortly" — the cap is the
bidder's just-minted pending cap and will be promoted to `current`
when `do_handover` fires. `E_STALE_TENANT_CAP` after the pending
check signals "burn voluntarily" — the cap is from a prior tenancy
or a displaced bid.

**Terminal arms abort `E_INVARIANT_VIOLATION`** because they are
filtered by the public dispatch in `borrow_asset` (which aborts
`E_STALE_TENANT_CAP` for terminal variants before calling). Move's
exhaustiveness check still requires the arms; the magic code flags
the structural unreachability.

**`E_ASSET_ALREADY_BORROWED` only fires from same-tenant double-borrow
in one PTB.** PTB clock-fixity guarantees no transition can fire
between borrow and return; the only way the active variant's
`Option<Asset>` is `None` at extract time is a prior `borrow_asset`
within the same PTB whose `AssetReceipt` is still live.


### 7.13 `do_fill_asset`

    fun do_fill_asset<Asset: key + store, CoinType>(
        escrow: &mut RentalEscrow<Asset, CoinType>,
        asset:  Asset,
    ): ID

**Preconditions:** caller is `return_asset` dispatching from
`HandoverOpen` or `HandoverConfirmed` (§6.2 step 4). The terminal
variants are filtered by the public dispatch — never reached here
(unreachable by PTB clock-fixity §6.1).

**Purpose:** fill the asset back into the active rented variant via
`option::fill`. Performs `take_state` / `put_state` internally
(P_DO). Asserts the asset's `Option` slot is `None` (aborts
`E_INVARIANT_VIOLATION` on a P11 violation — fill on a `Some` would
mean the asset was double-restored).

Returns the active tenant's `cap_id` for the `AssetReturned` event
that the caller emits.

**Algorithm:**

```move
let (old, receipt) = take_state(escrow);
let (new_state, tenant_cap_id) = match (old) {
    EscrowState::HandoverOpen { asset: asset_slot, phase_start_ms, current, retiring } => {
        let cap_id = current.cap_id;
        let mut slot = asset_slot;
        assert!(option::is_none(&slot), E_INVARIANT_VIOLATION);
        option::fill(&mut slot, asset);
        let new = EscrowState::HandoverOpen {
            asset: slot, phase_start_ms, current, retiring,
        };
        (new, cap_id)
    },
    EscrowState::HandoverConfirmed {
        asset: asset_slot, phase_start_ms, current, pending, retiring, handover_countdown_expiry,
    } => {
        let cap_id = current.cap_id;
        let mut slot = asset_slot;
        assert!(option::is_none(&slot), E_INVARIANT_VIOLATION);
        option::fill(&mut slot, asset);
        let new = EscrowState::HandoverConfirmed {
            asset: slot, phase_start_ms, current, pending, retiring,
            handover_countdown_expiry,
        };
        (new, cap_id)
    },
    EscrowState::Idle           { asset: _a }     => abort E_INVARIANT_VIOLATION,
    EscrowState::AtDutchAuction { asset: _a, .. } => abort E_INVARIANT_VIOLATION,
    EscrowState::Retired        { asset: _a }     => abort E_INVARIANT_VIOLATION,
};
put_state(escrow, new_state, receipt);
tenant_cap_id
```

**Why the `is_none` assert.** Theorem (P11 corollary): under the
public API, the active variant's `Option<Asset>` is `Some` between
`return_asset` calls, `None` only between a `borrow_asset` and its
matching `return_asset`. A valid `AssetReceipt` reaches
`do_fill_asset` only via that paired `return_asset`, so the slot is
guaranteed `None` here. The assert turns a P11 violation
(programmer-induced double-fill) into `E_INVARIANT_VIOLATION` rather
than `option::EOPTION_IS_SET`. Symmetric with the `is_some` assert
in `do_extract_asset`.


### 7.14 `do_distribute_balance`

    fun do_distribute_balance<Asset: key + store, CoinType>(
        escrow:      &mut RentalEscrow<Asset, CoinType>,
        boundary_ms: u64,
        ctx:         &mut TxContext,
    ): (address, u64, u64, u64)   // (payer, owner_share, protocol_fee, remain_credit)

**Convention:** P_DO flavor (a) — state-window owner. Sub-step 1 of
both `do_handover` (§7.1) and `do_tenure_expiry` (§7.2).

**Preconditions:** `escrow.state` is `Some(EscrowState::HandoverConfirmed
{ .. })` or `Some(EscrowState::HandoverOpen { .. })` — i.e. an active
tenancy with an outgoing tenant whose stake must be settled.

**Algorithm:**

1. **Compute curve-driven `used_credit` BEFORE `take_state`** (the
   public view §8.1 reads `escrow.state`, so it must be called while
   the cell is still `Some`):
   ```move
   let used_credit                 = compute_used_credit(escrow, boundary_ms);
   let (owner_share, protocol_fee) = split_fee(used_credit);
   let escrow_id                   = object::id(escrow);
   let fee_inbox_id                = escrow.fee_inbox_id;
   ```

2. **Take state and dispatch on the variant**:
   ```move
   let (old, receipt) = take_state(escrow);
   let (next, payer, remain_credit) = match (old) {
       EscrowState::HandoverConfirmed {
           asset, phase_start_ms, current, pending,
           retiring, handover_countdown_expiry,
       } => {
           let (zero_current, payer, leftover, remain_credit) = settle_tenant(current, used_credit, ctx);
           let leftover                                       = pay_protocol_fee(leftover, protocol_fee, escrow_id, payer, fee_inbox_id, ctx);
           balance::join(&mut escrow.owner_earnings, leftover);
           let next = EscrowState::HandoverConfirmed {
               asset, phase_start_ms, current: zero_current, pending,
               retiring, handover_countdown_expiry,
           };
           (next, payer, remain_credit)
       },
       EscrowState::HandoverOpen { asset, phase_start_ms, current, retiring } => {
           let (zero_current, payer, leftover, remain_credit) = settle_tenant(current, used_credit, ctx);
           assert!(remain_credit == 0, E_INVARIANT_VIOLATION);
           let leftover                                       = pay_protocol_fee(leftover, protocol_fee, escrow_id, payer, fee_inbox_id, ctx);
           balance::join(&mut escrow.owner_earnings, leftover);
           let next = EscrowState::HandoverOpen {
               asset, phase_start_ms, current: zero_current, retiring,
           };
           (next, payer, remain_credit)
       },
       EscrowState::Idle           { asset: _a }     => abort E_INVARIANT_VIOLATION,
       EscrowState::AtDutchAuction { asset: _a, .. } => abort E_INVARIANT_VIOLATION,
       EscrowState::Retired        { asset: _a }     => abort E_INVARIANT_VIOLATION,
   };
   put_state(escrow, next, receipt);
   (payer, owner_share, protocol_fee, remain_credit)
   ```

   Both arms run the same 3-step pipeline (settle_tenant →
   pay_protocol_fee → balance::join, see §7.6). Each arm reconstructs
   its variant with `current.stake = balance::zero()` — a transient
   sentinel consumed by the orchestrator's sub-step 2
   (`do_rotate_for_handover` §7.15 or `do_terminate_tenure` §7.16).

**Why `compute_used_credit` is called before `take_state`.** The
public view reads the state cell; calling it after `take_state`
would see `None` and abort `E_INVARIANT_VIOLATION` (P_READ §0).
The u64 result is computed eagerly while the cell is `Some`, then
threaded through `settle_tenant` after the cell becomes `None`.
Move 2024 NLL releases the immutable borrow at last-use, allowing
the subsequent `take_state(&mut escrow)` to succeed.

**Why the HandoverOpen-arm `assert!(remain_credit == 0)`.** At
tenure expiry, `boundary_ms == phase_start_ms + tenure_ceiling`,
so `elapsed = tenure_ceiling`. Per §8.1 the curve at
`elapsed >= tenure_ceiling` returns `SCALE` exactly, hence
`used_credit = mul_div(principal, SCALE, SCALE) = principal` and
`remain_credit = 0`. The assert is a runtime witness of this curve
property: if the curve ever stopped saturating at the boundary
(e.g. a curve_shape regression), this assert catches it before any
non-zero remain mis-routes to a fully-elapsed tenant.

**Why the same pipeline serves both transitions.** Handover and
tenure expiry both settle the outgoing tenant's stake the same way
— 3-way split, same recipients, same percentages. Only the variant
that comes back differs: handover preserves `HandoverConfirmed` for
sub-step 2 to rotate; tenure expiry preserves `HandoverOpen` for
sub-step 2 to terminate. Sharing `do_distribute_balance` keeps the
settlement logic in one place.

**Postconditions:**
- A `FeeMessage<C>` carrying `protocol_fee` was routed to
  `fee_inbox_id` iff `protocol_fee > 0`.
- A `Coin<C>` carrying `remain_credit` was transferred to `payer`
  iff `remain_credit > 0` (HandoverConfirmed only; HandoverOpen
  always has `remain_credit == 0`).
- `escrow.owner_earnings` grew by `owner_share`.
- `escrow.state` is `Some` of the same variant as on entry, with
  `current.stake = balance::zero()`.


### 7.15 `do_rotate_for_handover`

    fun do_rotate_for_handover<Asset: key + store, CoinType>(
        escrow:      &mut RentalEscrow<Asset, CoinType>,
        boundary_ms: u64,
    ): (ID, u64)   // (new_tenant_cap_id, new_rent_price)

**Convention:** P_DO flavor (a) — state-window owner. Sub-step 2 of
`do_handover` (§7.1).

**Preconditions:** `escrow.state` is `Some(EscrowState::HandoverConfirmed
{ .. })` with `current.stake = balance::zero()` (the post-distribute
intermediate state produced by §7.14). Reachable only via
`do_handover` orchestrating §7.14 then §7.15 in sequence.

**Algorithm:**

    let (old, receipt) = take_state(escrow);
    let (next, new_cap_id, new_rent_price) = match (old) {
        EscrowState::HandoverConfirmed {
            asset, phase_start_ms: _, current, pending,
            retiring, handover_countdown_expiry: _,
        } => {
            // Destroy zero-stake outgoing current.
            let Tenant { cap_id: _, address: _, stake: zero_stake } = current;
            assert!(balance::value(&zero_stake) == 0, E_INVARIANT_VIOLATION);
            balance::destroy_zero(zero_stake);

            // Rotate pending → new current.
            let Tenant { cap_id: new_cap_id, address: new_address, stake: new_stake } = pending;
            let new_rent_price = balance::value(&new_stake);
            let new_current = Tenant { cap_id: new_cap_id, address: new_address, stake: new_stake };

            let next = EscrowState::HandoverOpen {
                asset, phase_start_ms: boundary_ms, current: new_current, retiring,
            };
            (next, new_cap_id, new_rent_price)
        },
        EscrowState::Idle           { asset: _a }                  => abort E_INVARIANT_VIOLATION,
        EscrowState::AtDutchAuction { asset: _a, .. }              => abort E_INVARIANT_VIOLATION,
        EscrowState::HandoverOpen   { asset: _a, current: _c, .. } => abort E_INVARIANT_VIOLATION,
        EscrowState::Retired        { asset: _a }                  => abort E_INVARIANT_VIOLATION,
    };
    put_state(escrow, next, receipt);
    (new_cap_id, new_rent_price)

**Why the `is_zero` assert before `destroy_zero`.** The orchestrator
contract is that sub-step 1 leaves `current.stake = balance::zero()`.
The assert turns a contract violation into `E_INVARIANT_VIOLATION`
rather than the generic `balance::ENonZero`. Same convention as the
`option::is_some` / `is_none` asserts before `destroy_some` /
`destroy_none` calls (§0 P_READ rationale).

**Why no `tenant_cap::new`, no `transfer::public_transfer`.** Under
eager minting, the bidder's `TenantCap` was constructed at `rent`
time (§5.1) and now lives inside `pending.cap_id`. Rotation is a
pure variant transition: the cap (already in the bidder's wallet)
becomes live (`E_PENDING_TENANT_CAP` no longer triggers) the moment
this `put_state` lands.

**Postconditions:**
- The zero-stake outgoing `Tenant` is destructured and its empty
  `Balance` destroyed via `destroy_zero`.
- `escrow.state` is `Some(EscrowState::HandoverOpen { .. })` with
  `phase_start_ms = boundary_ms`, `current` populated from the
  rotated `pending`, and `retiring` inherited from the prior
  `HandoverConfirmed`.


### 7.16 `do_terminate_tenure`

    fun do_terminate_tenure<Asset: key + store, CoinType>(
        escrow:                 &mut RentalEscrow<Asset, CoinType>,
        boundary_ms:            u64,
        last_acquisition_price: u64,
    ): EscrowStateTag

**Convention:** P_DO flavor (a) — state-window owner. Sub-step 2 of
`do_tenure_expiry` (§7.2).

**Preconditions:** `escrow.state` is `Some(EscrowState::HandoverOpen
{ .. })` with `current.stake = balance::zero()` (the post-distribute
intermediate state produced by §7.14). Reachable only via
`do_tenure_expiry` orchestrating §7.14 then §7.16 in sequence.

**Algorithm:**

    let (old, receipt) = take_state(escrow);
    let (next, tag) = match (old) {
        EscrowState::HandoverOpen { asset: asset_opt, phase_start_ms: _, current, retiring } => {
            // Destroy zero-stake outgoing current.
            let Tenant { cap_id: _, address: _, stake: zero_stake } = current;
            assert!(balance::value(&zero_stake) == 0, E_INVARIANT_VIOLATION);
            balance::destroy_zero(zero_stake);

            // Unwrap Option<Asset> — guaranteed Some by P11 (no borrow
            // can be open at tenure expiry; PTB clock-fixity §6.1).
            assert!(option::is_some(&asset_opt), E_INVARIANT_VIOLATION);
            let asset = option::destroy_some(asset_opt);

            let next: EscrowState<Asset, CoinType> = if retiring {
                EscrowState::Retired { asset }
            } else {
                EscrowState::AtDutchAuction {
                    asset, phase_start_ms: boundary_ms, last_acquisition_price,
                }
            };
            let tag = state_tag(&next);
            (next, tag)
        },
        EscrowState::Idle              { asset: _a }                                 => abort E_INVARIANT_VIOLATION,
        EscrowState::AtDutchAuction    { asset: _a, .. }                             => abort E_INVARIANT_VIOLATION,
        EscrowState::HandoverConfirmed { asset: _a, current: _c, pending: _p, .. }   => abort E_INVARIANT_VIOLATION,
        EscrowState::Retired           { asset: _a }                                 => abort E_INVARIANT_VIOLATION,
    };
    put_state(escrow, next, receipt);
    tag

**Why two asserts before consuming linear values.** Symmetric with
§7.15: `is_zero` on the zero-stake `Balance` before `destroy_zero`,
and `is_some` on the `Option<Asset>` before `destroy_some`. Both
turn structural-invariant violations into `E_INVARIANT_VIOLATION`
rather than std-library generic codes.

**Why `last_acquisition_price` is a parameter, not recomputed.** The
orchestrator (`do_tenure_expiry` §7.2) recovered it from the
amounts returned by §7.14 (`owner_share + protocol_fee`, by the
curve invariant `used_credit == principal`). Passing it explicitly
keeps `do_terminate_tenure` independent of the curve property and
of which exact upstream sub-step computed the principal — its only
job is the variant transition.

**Postconditions:**
- The zero-stake outgoing `Tenant` is destructured and its empty
  `Balance` destroyed via `destroy_zero`.
- The `Option<Asset>` is unwrapped to a bare `Asset`.
- `escrow.state` is `Some(EscrowState::Retired { asset })` if
  `retiring` was true, else `Some(EscrowState::AtDutchAuction { asset,
  phase_start_ms: boundary_ms, last_acquisition_price })`.
- The returned `EscrowStateTag` mirrors which branch was taken,
  consumed by the orchestrator's `TenureExpired` event emit.


8. READ-ONLY QUERIES
---------------------

Read-only functions do not mutate the escrow. Via
`devInspectTransactionBlock` they execute for free with no consensus
involvement. In a regular PTB, taking `&RentalEscrow` (shared object)
still requires consensus, but read-only transactions on the same
object can execute in parallel without ordering between them —
reducing contention compared to mutable access.

**Reading settled state:** use `apply_pending_transitions` via
`devInspectTransactionBlock`. It resolves all pending transitions and
returns the settled `EscrowStateTag` without committing the
transaction — free, no consensus. This is more correct than a
dedicated read-only query because it reflects the actual settled
state, not a speculative computation.

**Public API surface — three queries:**

| Function | Visibility | Returns |
|---|---|---|
| `compute_used_credit(escrow, timestamp_ms)` (§8.1) | `public` | credit consumed by the current tenant at `timestamp_ms` |
| `compute_floor_price(escrow, timestamp_ms)` (§8.4) | `public` | minimum payment required to acquire the asset in the current state |
| `state_tag(state)` (§8.7) | `public` | `EscrowStateTag` — discriminator for the supplied state value |

These three cover every externally observable read: "how much has my
tenancy consumed", "what would it cost to become tenant right now",
"what variant is the escrow in". The first two can abort on
precondition violation — a deliberate choice. Abort codes carry
named semantic load (§1.1 is `public` for exactly this reason); an
SDK receiving `E_NOT_RENTED` or `E_RETIRED_NO_BID` maps it to a
user-facing condition directly. A sentinel return (`Option<u64>`,
magic `0`) would collapse that information and force the caller
into a secondary state fetch.

**No `state()` projection.** External callers do **not** receive a
`&EscrowState` reference. The state cell is accessed exclusively
through the private `read_state` (P_READ, §0 / §2.6). External
inspection of variant payload (current tenant address, descent
anchor, retire flag) goes through targeted query functions or
through event payloads (§3 star schema). Removing the public
projection enforces P_READ at the visibility layer — no caller can
hold a `&EscrowState` long enough to violate the convention.

**Per-arm price helpers — private:**

The price dispatched by `compute_floor_price` is computed by two
arm-specific helpers, both **private** to the module:

| Helper | Visibility | Arms served |
|---|---|---|
| `compute_price_descent(escrow, timestamp_ms)` (§8.2) | private | `AtDutchAuction` |
| `compute_next_rent_price(config, price)` (§8.3) | private | `HandoverOpen`, `HandoverConfirmed` |

Both are called from exactly one site: `compute_floor_price` (§8.4),
which dispatches by variant before calling. `rent()` (§5.1) reaches
both through `compute_floor_price` — keeping internal and external
floor computations in lockstep with no divergence possible. Neither
helper carries a state guard — it would be structurally unreachable,
defensive against nothing. Private visibility makes that guarantee a
visibility-level fact rather than a prose claim.

**Naming convention — `compute_*`:**

All read-only queries that produce a derived value use the `compute_*`
prefix uniformly. `compute_X(...)` reads as "compute the value of X
from the supplied inputs" — an honest description regardless of
whether a timestamp is passed:

- `compute_used_credit(escrow, timestamp_ms)` (§8.1),
  `compute_price_descent(escrow, timestamp_ms)` (§8.2), and
  `compute_floor_price(escrow, timestamp_ms)` (§8.4) take an
  arbitrary timestamp and evaluate at that instant — not necessarily
  `clock.now()`. External callers typically pass
  `clock::timestamp_ms(clock)` for "live" reads, but internal callers
  (e.g. `do_handover` passing `boundary_ms`) evaluate at past or
  boundary timestamps.
- `compute_next_rent_price(config, price)` (§8.3) depends only on the
  competitive price passed by the caller, so it needs no timestamp.

The `current_*` prefix is deliberately not used: it implies "now",
and a function accepting an arbitrary timestamp — or that any
external caller may inspect at an arbitrary point in a PTB — lies
under that prefix. Uniform `compute_*` keeps one convention for four
functions that all do the same thing semantically: produce a value
from escrow / state / config inputs.

`state_tag(state)` uses the bare topic noun (no `compute_` prefix)
because it is a projection, not a derivation — it folds an
existing variant identity into a copyable discriminator rather than
computing a value.

### 8.1 `compute_used_credit`

    public fun compute_used_credit<Asset: key + store, CoinType>(
        escrow:       &RentalEscrow<Asset, CoinType>,
        timestamp_ms: u64,
    ): u64

**Algorithm:**

    // 1. State guard + per-variant field reads via read_state (§2.6).
    //    `compute_used_credit` is only meaningful when a tenant exists.
    let (phase_start_ms, principal, effective_ts) = match (read_state(escrow)) {
        EscrowState::HandoverOpen { phase_start_ms, current, .. } =>
            // No clamp needed — evaluate_curve saturates at tenure_ceiling.
            (*phase_start_ms, balance::value(&current.stake), timestamp_ms),
        EscrowState::HandoverConfirmed {
            phase_start_ms, current, handover_countdown_expiry, ..
        } => {
            // Past handover boundary the current tenant's stake is no longer
            // growing — clamp.
            let eff = std::u64::min(timestamp_ms, *handover_countdown_expiry);
            (*phase_start_ms, balance::value(&current.stake), eff)
        },
        _ => abort E_NOT_RENTED,
    };

    // 2. Elapsed time since the current phase started.
    //    If effective_ts < phase_start_ms (caller passed a timestamp before
    //    the phase began), return 0 — no credit consumed yet.
    if (effective_ts < phase_start_ms) { return 0 };
    let elapsed_ms = effective_ts - phase_start_ms;

    // 3. Evaluate the normalized credit curve.
    let g = curve_shape::evaluate_curve(
        config::credit_curve(&escrow.config),
        elapsed_ms,
        config::tenure_ceiling(&escrow.config),
    );

    // 4. Scale by the current tenant's principal.
    //    Principal is balance::value(&current.stake): the current tenant's
    //    payment. evaluate_curve returns SCALE when elapsed >= tenure_ceiling,
    //    so the scaled result saturates at principal.
    math::mul_div(principal, g, SCALE)

**Two call sites:**

| Caller | `timestamp_ms` passed | Purpose |
|---|---|---|
| `do_handover` (internal, §7.1 step 3) | `handover_countdown_expiry` | used_credit at the exact boundary — clamp is a no-op (state is `HandoverConfirmed`, so the clamp triggers but `timestamp_ms == handover_countdown_expiry` makes it identity); state guard is structurally satisfied. *Note: in practice §7.1 inlines the curve evaluation against the owned outgoing stake — it does not call this query through `&escrow`, since the variant has already been extracted by value. The shared math (curve evaluation + clamp + saturation) is the same.* |
| Frontend / read query (external) | `clock::timestamp_ms(clock)` | live display of accrued credit |

The state guard and the `HandoverConfirmed` clamp are defensive —
they protect against wrong-state external calls and unsettled
boundaries.

---

### 8.2 `compute_price_descent`

    fun compute_price_descent<Asset: key + store, CoinType>(
        escrow:       &RentalEscrow<Asset, CoinType>,
        timestamp_ms: u64,
    ): u64

**Visibility:** **private** to the module. The previous design
exposed it `public(package)`; collapsed to private because the only
caller is `compute_floor_price` (§8.4), which dispatches by variant
before calling.

**Precondition:** `escrow.state` is
`Some(EscrowState::AtDutchAuction { .. })`. Structurally guaranteed
by the call site (`compute_floor_price` dispatch) — no runtime guard.
Returns `min_rent_price` once the descent saturates.

**Algorithm:**

    let (phase_start_ms, last_acquisition_price) = match (read_state(escrow)) {
        EscrowState::AtDutchAuction { phase_start_ms, last_acquisition_price, .. } =>
            (*phase_start_ms, *last_acquisition_price),
        _ => abort E_INVARIANT_VIOLATION,
    };

    // 1. Elapsed time since the auction started.
    //    phase_start_ms is set to the tenure-expiry boundary when AtDutchAuction begins.
    //    If timestamp_ms < phase_start_ms, return last_acquisition_price — auction has not started yet.
    if (timestamp_ms < phase_start_ms) { return last_acquisition_price };
    let elapsed_ms = timestamp_ms - phase_start_ms;

    // 2. Evaluate the normalized descent curve.
    let h = curve_shape::evaluate_curve(
        config::descent_curve(&escrow.config),
        elapsed_ms,
        config::descent_ceiling(&escrow.config),
    );

    // 3. Scale by the spread, then descend from last_acquisition_price.
    //    evaluate_curve returns SCALE when elapsed >= descent_ceiling, so
    //    consumed == spread and the result saturates at min_rent_price.
    //    Precondition last_acquisition_price >= min_rent_price is guaranteed
    //    by the protocol — every acquisition asserts payment >= compute_floor_price,
    //    and all floors (min_rent_price, compute_price_descent, compute_next_rent_price)
    //    are themselves >= min_rent_price. Note last_acquisition_price does NOT
    //    monotonically increase: a rent from AtDutchAuction can write a value
    //    below the previous last_acquisition_price (but still >= min_rent_price).
    let spread   = last_acquisition_price - config::min_rent_price(&escrow.config);
    let consumed = math::mul_div(spread, h, SCALE);
    last_acquisition_price - consumed

`last_acquisition_price` is the starting price of the descent — set
by `do_tenure_expiry` from the outgoing tenant's stake snapshot
(§7.2 step 2) and carried inside the `AtDutchAuction` variant.

**One call site (dispatches by variant before calling, so precondition
holds):**

| Caller | Purpose |
|---|---|
| `compute_floor_price` (§8.4), `AtDutchAuction` arm | floor at `timestamp_ms` — used by both `rent()` and SDK / frontend via the public entry point |

**Why no state guard:** with private visibility, every caller is
inside this module and has already dispatched on the active variant.
A guard here would be defensive against a call path that cannot
exist. See §8 preamble, "Per-arm price helpers". The
`_ => abort E_INVARIANT_VIOLATION` arm on the match is structural
(unreachable), not defensive — the magic code flags this as
programmer error, not user error.

---

### 8.3 `compute_next_rent_price`

    fun compute_next_rent_price(
        config: &IntegrationConfig,
        price:  u64,
    ): u64

**Visibility:** **private** to the module (was `public(package)` in
the previous design; same rationale as §8.2 — single in-module
caller).

**Precondition:** caller has dispatched by variant. No `timestamp_ms`
parameter — `f_next_rent_price` depends only on the current
competitive price, not on elapsed time. The caller passes the correct
price based on variant.

**Algorithm:**

    price_function::evaluate_price_fn(
        config::price_function(config),
        price,
    )

**Signature change.** The helper now takes `&IntegrationConfig`
directly instead of `&RentalEscrow<Asset, CoinType>` because nothing
else inside the function reads from the escrow — only the price
function. Decoupling the helper from the escrow type also lets it
serve `compute_floor_price` arms cleanly without pulling in the
`Asset` / `CoinType` generics for a function that does not use them.

**One call site (dispatches by variant before calling):**

| Caller | Purpose |
|---|---|
| `compute_floor_price` (§8.4), `HandoverOpen` arm | floor = `compute_next_rent_price(&escrow.config, balance::value(&current.stake))` |
| `compute_floor_price` (§8.4), `HandoverConfirmed` arm | floor = `compute_next_rent_price(&escrow.config, balance::value(&pending.stake))` |

**Why no state guard:** see §8.2 and §8 preamble. Same structural
argument — `public(package)` + pre-dispatched callers = guard
unreachable.

---

### 8.4 `compute_floor_price`

    public fun compute_floor_price<Asset: key + store, CoinType>(
        escrow:       &RentalEscrow<Asset, CoinType>,
        timestamp_ms: u64,
    ): u64

Single public entry point for "minimum payment required to acquire
the asset at `timestamp_ms`". Dispatches by the active variant of
`escrow.state` to the arm-specific helper.

**Algorithm:**

    match (read_state(escrow)) {
        EscrowState::Idle { .. } => config::min_rent_price(&escrow.config),
        EscrowState::HandoverOpen { current, .. } =>
            compute_next_rent_price(&escrow.config, balance::value(&current.stake)),
        EscrowState::HandoverConfirmed { pending, .. } =>
            compute_next_rent_price(&escrow.config, balance::value(&pending.stake)),
        EscrowState::AtDutchAuction { .. } =>
            compute_price_descent(escrow, timestamp_ms),
        EscrowState::Retired { .. } => abort E_RETIRED_NO_BID,
    }

**Dispatch table:**

| Variant | Returns | Rationale |
|---|---|---|
| `Idle` | `config.min_rent_price` | floor is the configured minimum; time-invariant — `timestamp_ms` unused |
| `HandoverOpen` | `compute_next_rent_price(config, current.stake.value)` | takeover floor — current tenant's stake is the competitive bar; time-invariant — `timestamp_ms` unused |
| `HandoverConfirmed` | `compute_next_rent_price(config, pending.stake.value)` | supersede floor — pending bid escalates with each supersede; time-invariant — `timestamp_ms` unused |
| `AtDutchAuction` | `compute_price_descent(escrow, timestamp_ms)` | current Dutch price at `timestamp_ms`; time-varying |
| `Retired` | aborts `E_RETIRED_NO_BID` | asset is not rentable — same abort code that `rent()` raises on the same state |

**Why abort on `Retired` (not `Option<u64>` / sentinel):**

The error constants in §1.1 are `public` so the SDK can map abort
codes to human-readable messages — abort codes are the protocol's
semantic signalling channel between contract and client.
`E_RETIRED_NO_BID` names the exact condition ("asset retired, no
acquisition possible"). Collapsing that to `None` forces the SDK
into a secondary `state_tag` read to reconstruct the reason —
information already present on the abort path is lost in the type.
Aborting also keeps `compute_floor_price` symmetric with every other
public function on the protocol (`rent`, `borrow_asset`, `retire`,
`claim_asset`, `withdraw_earnings`, `compute_used_credit`), all of
which abort on precondition violation.

**Reuse of `E_RETIRED_NO_BID`:** the condition — "caller asks to
acquire a Retired escrow" — is semantically identical whether the
caller is `rent()` (write path) or `compute_floor_price` (read path).
One named condition, one constant.

**Why `timestamp_ms` is always taken, even when unused:** the
parameter signals "this function accepts a point in time", and is
honest for the only arm that reads it (`AtDutchAuction`). The four
time-invariant arms ignore it rather than overloading the function
with a second signature. External callers that want a live read pass
`clock::timestamp_ms(clock)`; frontends painting the descent curve
pass hypothetical future timestamps; both are first-class uses.

**`rent()` is also an internal caller.** `rent()` calls
`compute_floor_price` at step 2 before the state dispatch — the same
function external callers use. This guarantees that the floor
enforced on-chain and the floor the SDK queries are always identical.
`compute_floor_price` is therefore both the internal enforcement gate
and the external read-only query.

**UX note — lifecycle price chart:** a frontend graphing "price to
acquire" across the full escrow lifecycle calls `compute_floor_price(
escrow, clock.now())` whenever the variant is in
{`Idle`, `HandoverOpen`, `HandoverConfirmed`, `AtDutchAuction`}, and
renders a "not rentable" marker on catching `E_RETIRED_NO_BID`. The
same function also answers hypothetical "what would I pay at t = T"
queries by passing any `timestamp_ms` — critical for rendering the
Dutch descent curve ahead of time.

---

### 8.5 (removed) — boundary-timestamp helpers

The previous design exposed `tenure_expiry_ms` and `descent_expiry_ms`
as `public(package)` one-liners that named the boundary arithmetic
`phase_start_ms + ceiling`. Both have been **removed**: every call
site (§5.1 dispatch, §5.2 APT loop) already destructures
`phase_start_ms` inside its own match arm and computes the boundary
inline; the helpers had zero callers (W09008 dead code) and added
visibility surface for no semantic gain.

External callers wanting these boundaries read them off the
corresponding event rows (`HandoverCompleted.timestamp_ms`,
`TenureExpired.timestamp_ms`, `AuctionExpired.timestamp_ms`) — all
already in the event surface (§3).

---

### 8.6 (removed) — `state` projection

The previous design exposed a `public fun state(escrow):
&EscrowState` projection so external SDK code could pattern-match on
the active variant. The function has been **removed**: the state
cell is now accessed exclusively through the private `read_state`
helper (P_READ, §0 / §2.6). External inspection of variant payload
goes through targeted query functions (`compute_used_credit`,
`compute_floor_price`, `state_tag`) and event payloads (§3 star
schema). Removing the public projection enforces P_READ at the
visibility layer — no caller can hold a `&EscrowState` long enough
to violate the convention.

Frontends needing variant payload (current tenant address, descent
anchor, retire flag) read the corresponding event row from the
indexed event stream — same source of truth, with no extra RPC
round-trip per field.

---

### 8.7 `state_tag` — public discriminator projection

    public fun state_tag<Asset: key + store, CoinType>(
        state: &EscrowState<Asset, CoinType>,
    ): EscrowStateTag

**Algorithm:**

    match state {
        EscrowState::Idle              { .. } => EscrowStateTag::Idle,
        EscrowState::AtDutchAuction    { .. } => EscrowStateTag::AtDutchAuction,
        EscrowState::HandoverOpen      { .. } => EscrowStateTag::HandoverOpen,
        EscrowState::HandoverConfirmed { .. } => EscrowStateTag::HandoverConfirmed,
        EscrowState::Retired           { .. } => EscrowStateTag::Retired,
    }

**Purpose.** The canonical projection from `EscrowState` (variant
with linear payload) to `EscrowStateTag` (copyable discriminator).
Used internally by `apply_pending_transitions` and `retire` to
compute return values, and by any function that needs to embed a
copyable state discriminator in an event without consuming the state.

**External access — no public `state()` projection.** External
callers cannot invoke `state_tag` against `&escrow.state` directly
because the state cell is read exclusively through the private
`read_state` (§8.6 — public projection removed to enforce P_READ at
the visibility layer). External `EscrowStateTag` values are
obtained via the `apply_pending_transitions` and `retire` return
values — both produce a `EscrowStateTag` against the post-call
state without exposing the underlying variant. The `state_tag`
function itself remains `public` because callers inside this module
need it on values they hold by reference (e.g. inside `do_*`
helpers that already hold the destructured variant).

**Why no state guard:** the function is total over all five variants.
The match is exhaustive; no precondition can fail.


9. PROPERTIES
-------------

The following hold for any `RentalEscrow` whose lifecycle flows
exclusively through the public API.

**P1 — Fund conservation at every boundary:**
For every `do_handover` call: `used_credit + remain_credit ==
balance::value(&outgoing.stake)` (the current tenant's payment), and
`owner_share + protocol_fee == used_credit` (`split_fee` is exact).
For every `do_tenure_expiry` call: `owner_share + protocol_fee ==
balance::value(&outgoing.stake)` at expiry.

**P2 — No trapped balances at terminal state (structural):**
When `state` is `EscrowState::Retired`, the variant carries only
`asset` — no `stake` field exists in the variant by construction.
The previous design's `tenant_stake == 0 ∧ pending_bid == 0` runtime
invariant is now type-level: there is no place to store a non-zero
balance under `Retired`. `claim_asset` requires no
`balance::destroy_zero` call.

**P3 — Push-before-rotate:**
Inside `do_handover`, every push (`remain_credit` →
`current.address`) and the supersede refund (`pending.stake` →
`pending.address` in `rent()` Case `HandoverConfirmed`) occur before
the variant is filled with the new shape. No loss of delivery target
across the handover or supersede window — the destructured `Tenant`
fields are captured as locals before the new variant is constructed.

**P4 — At most three lazy transitions per call:**
`apply_pending_transitions` executes at most `do_handover` +
`do_tenure_expiry` + `do_auction_expiry` in a single call. Bounded gas.

**P5 — Lattice ordering is a safety invariant:**
APT's match dispatches in lattice order — `HandoverConfirmed` before
`HandoverOpen` before `AtDutchAuction` — implicitly via the variant
the loop reads. Reordering (e.g., reading `HandoverOpen` before
resolving a pending `HandoverConfirmed`) would create `pending.stake`
orphan windows or miss intermediate earnings splits.

**P6 — Retire flag is monotonic:**
Once `retiring: true` is set on an active Rented variant by `retire()`,
it stays set across `do_handover` (inherited verbatim into the new
`HandoverOpen` variant) and triggers `Retired` at the next
`do_tenure_expiry`. No function clears it. No code path can transition
from `Retired` back to a non-terminal variant (the `Retired` arm of
every match aborts or destructures-to-claim).

**P7 — OwnerCap uniqueness:**
Exactly one live `OwnerCap` per escrow at any time. Minted once in
`integrate`, burned once in `claim_asset`. Enforced by visibility of
`owner_cap::new(escrow_id, owner, ctx)` / `owner_cap::burn(cap, owner)`
(both `public(package)` with a single call site each). The recipient
and burner addresses are recorded in `OwnerCapMinted` /
`OwnerCapBurned` respectively so the cap's full lifecycle is
reconstructible from the event stream alone.

**P8 — TenantCap staleness is inert:**
Displaced tenants' `TenantCap` objects remain in their wallets but
fail the variant-identity check in `borrow_asset` — their `cap_id`
matches no field of the active `EscrowState` variant. No protocol
state is corrupted by the presence of stale caps.

**P9 — Tenancy ↔ Rented variant (structural):**
Active tenant ⇔ `escrow.state` is `Some(HandoverOpen { .. })` or
`Some(HandoverConfirmed { .. })`. Encoded directly: only these two
variants carry `current: Tenant`. No `Idle` / `AtDutchAuction` /
`Retired` variant has any field able to hold tenant data. The
previous design's `tenant_slot != Vacant ⇔ state == Rented(_)`
runtime invariant is now a type-level fact.

**P10 — Pending bid ↔ HandoverConfirmed (structural):**
`pending` field exists ⇔ `escrow.state` is
`Some(HandoverConfirmed { .. })`. Only this variant carries
`pending: Tenant`. No other variant can hold a pending bid — the
field does not exist elsewhere. Both set together in `rent()`
(takeover path) and cleared together (rotated into `current` and
then settled) in `do_handover`.

**P11 — Asset present while escrow exists:**
A protocol guarantee, structurally enforced per variant. `Idle`,
`AtDutchAuction`, and `Retired` carry `asset: Asset` directly —
present unconditionally. `HandoverOpen` and `HandoverConfirmed`
carry `asset: Option<Asset>`; `None` exists only within a PTB borrow
window (`borrow_asset` → `return_asset`), never across transaction
boundaries. Enforced by the hot-potato `AssetReceipt`.

**P12 — Fee routing is idempotent at zero:**
`do_handover` with `used_credit == 0` (e.g. handover at t =
phase_start_ms, pathological edge case) and `do_tenure_expiry` with
zero stake produce `protocol_fee == 0`. `settle_stake_earnings`
gates the `fee_message::post` call behind `if protocol_fee > 0`, so
no `FeeMessage<C>` is constructed on the zero path. The escrow
balances settle to their normal post-condition via the owner-share
branch alone.

**P13 — `Option<EscrowState>` is `Some` at every transaction
boundary (structural, type-enforced):**
The `state` field is `None` only mid-function within a single Move
call (between `take_state` at the start of a mutating helper and
`put_state` at the end). The hot-potato `StateReceipt` (§2.6) makes
this a compile-time invariant: `take_state` is the sole producer of
`StateReceipt`, `put_state` is the sole consumer, and Move's linear
type system requires every code path between them to either consume
the receipt or `abort`. A function that calls `take_state` and
returns without `put_state` fails to compile; a function that
aborts has the receipt discharged automatically by transaction
rollback (which restores `escrow.state` to the prior `Some` value).
External callers (which only observe transaction boundaries)
therefore observe `Some` always — a property the type system
guarantees, not a discipline the implementer must follow. This is
what makes `option::destroy_some` in `claim_asset` (§4.3 step 4)
and `read_state` (the sole reader, §2.6 — sites: §5.1 / §5.2 /
§6.1 / §6.2 / §6.3 / §8.1 / §8.2 / §8.4) safe.

The asserts inside `take_state` / `put_state` / `read_state`
(`option::is_some` / `is_none`) turn a P13 violation into
`E_INVARIANT_VIOLATION` rather than `option::EOPTION_NOT_SET` /
`option::EOPTION_IS_SET` — protocol bug distinguishable from user
error in logs and indexers.

The closed failure mode: without the receipt, a programmer could
`option::extract` and forget the matching `option::fill`, leaving
`escrow.state` as `None` after the transaction commits. The next
transaction that extracts would abort on `None`, and the escrow
(plus its asset and any accrued `owner_earnings`) would be
permanently inaccessible — `claim_asset` itself extracts state via
APT, so even the owner could not exit. The receipt closes this
failure mode at compile time.


10. TEST CASES
--------------

### 10.0 Test strategy

Tests live in module `rental_escrow_tests`, driven by
`sui::test_scenario` plus explicit `sui::clock::Clock` manipulation.
`rental_escrow` is the integration point of every other module in
the package; the test surface is correspondingly broad and must
balance **full-state-machine rows** (drive the public API
end-to-end) with **unit rows** (isolate pure helpers with
declarative inputs).

#### Canonical actors

| Alias | Address | Role |
|---|---|---|
| `OWNER` | `@0x0A` | Integrator / `OwnerCap` holder |
| `OWNER2` | `@0x0B` | Second owner address for cap-transfer rows (W2a) |
| `TENANT_A` | `@0xA1` | First tenant (T1) |
| `TENANT_B` | `@0xA2` | Second tenant (T2), pending bidder, displaced tenant |
| `BIDDER` | `@0xA3` | Third bidder for supersede rows |
| `KEEPER` | `@0x5E` | Permissionless `apply_pending_transitions` caller |
| `ADMIN` | `@0xAD` | `ProtocolFeeInbox` holder / fee collector |
| `ZERO` | `@0x0` | Negative-space rows |

The distinction between `TENANT_A` / `TENANT_B` / `BIDDER` and
`KEEPER` is load-bearing for several rows — e.g.,
`TenantCapMinted.tenant` inside `register_pending_bid` (called from
`rent()`) must equal the bidder, not the keeper; exercising that
assertion requires `KEEPER` to call `apply_pending_transitions` on
unrelated paths separately.

#### Test fixtures

- **Asset witness.** A canonical `#[test_only]` type is declared in
  the test module so generics can be instantiated without dragging a
  real third-party asset crate:
  ```move
  #[test_only] public struct DemoAsset has key, store { id: UID }
  ```
  Rows that cover level-2 integration (T2, L3) use
  `rental_escrow::OwnerCap` directly as the `Asset` type parameter —
  no new witness needed.
- **CoinType witness.** `sui::sui::SUI` is the default;
  `balance::create_for_testing<SUI>(amount)` and
  `coin::mint_for_testing<SUI>(amount, ctx)` are the sole sources of
  funds. A second witness `#[test_only] public struct FAKE_USDC has drop {}`
  covers multi-coin rows in §10.11.
- **`ProtocolFeeInbox`.** Instantiated via
  `protocol_fee_inbox::init_for_testing` under `ADMIN`; the
  `ProtocolFeeRef` is retrieved with `take_immutable`.
- **`IntegrationConfig`.** Not constructed inline per row. Every test
  draws from a fixed **deterministic corpus** of 168 configs, enumerated
  in the next subsection ("Test corpus — `IntegrationConfig` axes").
  Each row of §10.1–§10.13 specifies which projection of the corpus it
  iterates over.
- **Clock.** `sui::clock::create_for_testing(ctx)` plus
  `clock::set_for_testing(&mut clock, ms)` to advance
  deterministically. Scenario epoch helpers are **avoided** —
  `scenario.later_epoch(...)` does not map to `clock::timestamp_ms()`
  with guaranteed millisecond granularity, and every boundary in the
  spec is expressed in ms.

#### Test corpus — `IntegrationConfig` axes

The integration surface of `rental_escrow` is parameterized by
`IntegrationConfig`. A single instance covers one point in a
multi-dimensional space; testing on one point would codify it as
"the expected behavior" while the spec dictates behavior over the
whole space. The test suite therefore operates over a
**deterministic corpus** of configs constructed as the cross-product
of the orthogonal axes that produce **distinct observable behavior**,
holding constant only parameters that are *scales* (no boundary
across them).

The corpus is materialized in a dedicated test module
`tests/rental_escrow_corpus.move` and consumed by every row of
§10.1–§10.13 through named projections (forthcoming subsection).

**Constants — same value in every escrow.**

| Symbol | Value | Type | Rationale |
|---|---|---|---|
| `CoinType` | `sui::sui::SUI` | phantom type | Phantom: enforced at compile-time, no runtime branch on `CoinType`. Multi-coin smoke test (§10.11) is separate from the corpus. |
| `Asset` | `DemoAsset` | phantom type | Same argument as `CoinType`. |
| `integrated_at_ms` | scenario-chosen | u64 ms | Used only as `(clock − integrated_at_ms)` delta in the `retire_floor` guard; absolute value irrelevant to behavior. |
| `tenure_ceiling` | `100_000` (100s) | u64 ms | Scale, not boundary. The constructor forbids `= 0` (`ETenureCeilingZero`); arithmetic is proportional across magnitudes. Round number that simplifies clock-advance arithmetic in scenarios. |
| `min_rent_price` | `10_000_000_000` (10 SUI) | u64 mist | Scale, not boundary. Constructor forbids `= 0` (`EMinRentPriceZero`). 10 SUI keeps the 10% protocol-fee split divisible (`1 SUI` exact) and round arithmetic for compound growth. |

**Orthogonal axes — each value materializes a distinct observable behavior.**

| Axis | Field | Values | Indices | Behavioral split |
|---|---|---|---|---|
| `C` | `handover_floor` | `{0, 25_000, 100_000}` ms | `c ∈ {0,1,2}` | `c=0` enables rent+borrow same-tx (no clock advance needed). `c=1` (= `tenure_ceiling/4`) is the standard countdown mode. `c=2` (= `tenure_ceiling`) is **fixed-time rental**: the saturation in §5.1 (`min(now + handover_floor, phase_start_ms + tenure_ceiling)`) clamps the countdown to the tenure boundary, eliminating early handovers — a distinct protocol mode, not a magnitude variation. |
| `D` | `price_fn` | `{ FixedDelta(δ=10¹⁰), CompoundDelta(bps=1000, δ=1) }` | `d ∈ {0,1}` | `d=0` adds a fixed 10 SUI per re-price (pure additive). `d=1` adds 10% per re-price plus 1 mist (constructor forbids `delta=0`, so `δ=1` is the closest approximation to "pure compound"). The boundary is between additive and multiplicative price escalation. |
| `E` | `(credit_curve, descent_curve)` | 7 diagonal pairs (table below) | `e ∈ {0..6}` | Distinct shape modes: linear, smoothstep (S-shape symmetric), logistic (S-shape pronounced), power_law concave (`α=1/2`), power_law convex (`α=2`), exp concave saturating (`α=2,neg`), exp convex explosive (`α=2,pos`). Curve pairs are diagonal (not cross-product) because `compute_used_credit` (§8.1) consumes only `credit_curve` and `compute_price_descent` (§8.2) consumes only `descent_curve` — no spec section correlates them. The diagonal ensures every shape plays both roles. |
| `H` | `descent_ceiling` | `{0, 100_000}` ms | `h ∈ {0,1}` | `h=0` makes `AtDutchAuction` structurally unobservable: `do_tenure_expiry` and `do_auction_expiry` co-emit at identical timestamps (M6b, Q11). `h=1` (= `tenure_ceiling`) gives a full descent window; mid-descent assertions are observable via `clock = phase_start_AtDutchAuction + descent_ceiling/2` without introducing a third axis value. |
| `F` | `retire_floor` | `{0, 10_000_000}` ms | `f ∈ {0,1}` | `f=0` removes the time guard on `retire()` — any clock value passes. `f=1` (= `100×tenure_ceiling`) places the threshold so far in the future that any scenario advancing the clock by ~`tenure_ceiling` units always aborts `E_RETIRE_FLOOR_NOT_ELAPSED` — separating tests that exercise the guard from tests that exercise the rest of the lifecycle. |

**Axis `E` — curve pair table.**

| `e` | label | constructor | concavity / role |
|---|---|---|---|
| 0 | `linear` | `curve_shape::new_linear()` | linear (baseline) |
| 1 | `smoothstep` | `curve_shape::new_smoothstep()` | S-shape symmetric |
| 2 | `logistic` | `curve_shape::new_logistic()` | S-shape pronounced |
| 3 | `power_concave` | `curve_shape::new_power_law(1, 2)` | x^(1/2), concave |
| 4 | `power_convex` | `curve_shape::new_power_law(2, 1)` | x², convex |
| 5 | `exp_concave` | `curve_shape::new_exponential(2, true)` | saturating concave |
| 6 | `exp_convex` | `curve_shape::new_exponential(2, false)` | explosive convex |

`α=2` is the minimal magnitude that distinguishes concave/convex from
linear. Internal-branch coverage in `curve_shape`:

- `eval_power_law`: `e=4` exercises the `if (alpha_den == 1) return acc`
  shortcut; `e=3` exercises the `nth_root_u128` branch (`SCALE_U128`).
- `eval_exponential`: `e=5` exercises `TAYLOR_SCALE − exp_ax`
  (alpha_neg=true); `e=6` exercises `exp_ax − TAYLOR_SCALE`
  (alpha_neg=false). Both branches share `EXP_A_NORM_2_{NEG,POS}`.

Both internal branches of each curve type are reached by the
diagonal — additional `α` magnitudes do not expose new branches at
the `rental_escrow` integration layer.

**Cardinal.**

```
|Corpus| = |C| × |D| × |E| × |H| × |F| = 3 × 2 × 7 × 2 × 2 = 168
```

**Tag scheme (τ2).**

Each escrow is identified by a single `u64` tag built from axis
indices in positional decimal:

```
tag(c, d, e, h, f) = c · 10_000 + d · 1_000 + e · 100 + h · 10 + f
```

Padded to 5 digits, the tag reads left-to-right as `C-D-E-H-F`.
Decoding:

```
f = tag mod 10
h = (tag /     10) mod 10
e = (tag /    100) mod 10
d = (tag /  1_000) mod 10
c =  tag / 10_000
```

Constraints: `c ∈ [0,2]`, `d ∈ [0,1]`, `e ∈ [0,6]`,
`h ∈ [0,1]`, `f ∈ [0,1]`. A digit out of range is a
corpus-construction bug, not a regression.

**Use as failure breadcrumb.** The Move test framework does not
propagate strings through assertion failures — only the `u64`
abort code. The tag is therefore passed as the `abort_code`
argument to `assert!`, so a failure code is itself the breadcrumb
to the offending config:

```move
let tag = corpus::tag(c, d, e, h, f);
assert!(rental_escrow::state_tag(read_state(&escrow))
        == EscrowStateTag::Idle, tag);
```

A failure with abort code `10610` decodes to `c=1, d=0, e=6, h=1, f=0`:
`handover_floor = 25_000ms`, `fixed_delta(10 SUI)`, `exp_convex`,
`descent_ceiling = 100_000ms`, `retire_floor = 0`.

**Time arithmetic derivable from the corpus.**

With `t0 = integrated_at_ms` and the constants above:

| Quantity | Value | Conditions |
|---|---|---|
| `phase_start_HandoverOpen` | `t0` | first rent into Idle at `clock=t0` |
| `phase_start_AtDutchAuction` | `t0 + 100_000` | reached via `do_tenure_expiry`; phase_start is fresh = boundary_ms (§7.2) |
| clock for tenure boundary | `t0 + 100_000` | exact-boundary inclusivity row |
| clock for descent boundary | `t0 + 200_000` | only meaningful when `h=1` |
| clock for mid-descent | `t0 + 150_000` | only meaningful when `h=1`; samples at `descent_ceiling/2` |
| clock past `retire_floor` | `t0 + 10_000_000` | only meaningful when `f=1`; under `f=0` any clock value passes |

Under `c=2` (fixed-time mode) the same relationships hold:
`handover_countdown_expiry` saturates to `phase_start_ms +
tenure_ceiling`, indistinguishable from the tenure boundary itself.

**Audit — explicit omissions from the corpus.**

The corpus is not exhaustive over the value space of
`IntegrationConfig`; it is exhaustive over **observable boundaries
from `rental_escrow`'s perspective**. The following are deliberately
out of corpus:

1. **`curve_shape` internal branches with `alpha_den ∈ {3, 4}` (cube /
   quartic root)** and exponential with `alpha_abs ∈ {1, 3..8}`. These
   are arithmetic branches inside `curve_shape` whose coverage is the
   responsibility of `curve_shape_tests` (already green). For
   `rental_escrow`'s integration the qualitative shape (concave /
   convex / S / linear) is what selects downstream behavior in
   `compute_used_credit` / `compute_price_descent`; magnitude is not.
2. **`descent_ceiling > tenure_ceiling`.** Allowed by the constructor
   (no asserted ordering between the two), but no code path branches
   on the sign of `(descent_ceiling − tenure_ceiling)` — both are
   independent additions onto `phase_start_ms`. Adds no new boundary.
3. **`min_rent_price` and `tenure_ceiling` magnitudes other than the
   canonical values.** Both are scales without boundary semantics
   (the constructor forbids only `= 0`).

**Out-of-corpus obligations — observable in tests, not via corpus.**

The corpus parameterizes config but not state or scenario timing.
Three classes of obligations remain on individual rows of §10:

- **Boundary inclusivity (`>=` vs `>`).** Every transition guard
  expressed as `now >= boundary_ms` (§4.2 step 3 for `retire_floor`;
  `do_tenure_expiry`; `do_auction_expiry`; `do_handover`'s
  `handover_countdown_expiry`) requires a row that fires the action
  with `clock == boundary_ms` exactly. Cross-references: C1a (already
  in §10.8); analogous "exact-boundary" rows must exist for tenure /
  descent / handover transitions.
- **Zero-spread descent.** When the first tenant rents at exactly
  `min_rent_price`, lets tenure expire without a successor, and the
  auction starts with `last_acquisition_price = min_rent_price`,
  `compute_price_descent` operates on a zero-width spread
  `[min_rent_price, min_rent_price]` and saturates from `t=0`. State-level
  scenario reachable under any config; must be enumerated as an
  explicit row in §10.10 (cross-reference: complements Q7/Q8).
- **APT cascade combinations.** The cross-product of the corpus
  produces config combinations that drive multi-step cascades inside
  a single APT call. M6b is already catalogued (`HandoverOpen →
  AtDutchAuction → Idle` under `h=0`). Add **M6c**: `HandoverConfirmed →
  HandoverOpen → AtDutchAuction-skipped → Idle` in one APT under
  `(c=2, h=0)`. Other cascade combinations fall out of the matrix and
  should be named explicitly when their config triple uniquely
  produces them.

**Corpus is config; state is per-test.**

The corpus is orthogonal to `EscrowState`. Each test scenario starts
at `Idle` and drives transitions to reach the variant under test.
The full meaningful coverage matrix is:

```
{ EscrowState variants } × { corpus configs } = 5 × 168 = 840
```

This is the upper bound of meaningful (state, config) tuples, not the
number of tests. Each row of §10.1–§10.13 declares which projection
of the corpus it iterates over (typically a slice fixing one or two
axes — e.g., "all configs with `h=0`", "all configs with `c=2`"); the
projection set will be specified after corpus materialization in
`tests/rental_escrow_corpus.move`.

**Operational rules for using the corpus.**

The corpus is a defense against codifying single-config assumptions
as protocol behavior, not a mandatory iteration target. Three rules
keep its cost-to-value ratio honest:

1. **Default to the minimum projection, not `all_configs()`.** Every
   row of §10 declares which subset of the corpus it iterates over
   and why. The full corpus is used only when the asserted property
   is genuinely cross-axis — typically §10.1 (`integrate` happy
   path), §10.11 (fee routing), §10.12 (full lifecycle). All other
   rows project to the axes they actually exercise (e.g., M6b uses
   `with_descent_zero()`, ~84 configs; C1 uses
   `with_retire_floor_nonzero()`, ~84 configs). Treating
   "`all_configs()`" as a lazy default inflates suite runtime and
   obscures which property the row actually verifies.

2. **Assert properties, not config-indexed values.** A row written
   as `assert!(value == expected_for_this_cfg, ...)` forces the
   author to compute `expected_for_this_cfg` per config — that
   computation almost always requires reading the implementation,
   which is impl-mirroring (Form A in
   `ctx/rental-escrow-tests.note`), not spec-driven testing.
   Prefer formulations that hold across the projection: invariants,
   inequalities, structural shape (`state_tag == X`,
   `events.length == N`, `cap_id` triple-JOIN across event pairs).
   When the spec mandates an exact numeric value derivable from the
   config (rare), call the public helper that computes it
   (`compute_floor_price`, `compute_used_credit`) — never duplicate
   the formula in the test body.

3. **Single-config rows are legitimate and expected.** Not every row
   benefits from the corpus:
   - **§10.14 unit rows on pure helpers**: no `IntegrationConfig`
     dependency.
   - **Structural abort guards**: P_READ (§10.14.5),
     `E_WRONG_ESCROW_OWNER_CAP`, `E_RECEIPT_ESCROW_MISMATCH`,
     `E_RETIRED_NO_BID` — abort regardless of config.
   - **Sender / actor identity rows** (e.g., `KEEPER ≠ TENANT_A`
     §10.16): the property is about which address is captured, not
     about config.

   Rough working partition: ~30–40 % of §10 rows benefit from the
   full corpus; ~30 % from a small projection (2–10 configs
   targeting one or two axes); ~30 % are single-config. The split
   is descriptive, not prescriptive — the rule is to justify the
   projection per row, not to hit a percentage.

#### Test-only shims on private helpers

The private helpers (§7) are exercised indirectly through the state
machine for most rows. Only `split_fee` needs direct unit coverage
because its zero / fee-flooring branches are only reachable through
integration paths that mask the edge cases:

```move
#[test_only] public fun split_fee_for_testing(amount: u64): (u64, u64)
    { split_fee(amount) }
```

`do_handover`, `do_tenure_expiry`, `do_auction_expiry`,
`do_install_new_tenant`, `do_place_bid`, `do_supersede_bid`,
`do_retire_immediately`, `do_set_retiring_flag`, `do_extract_asset`,
`do_fill_asset`, `settle_stake_earnings`, `register_pending_bid`
are **not** shimmed: they have preconditions on the active variant
of `escrow.state` and on owned-Balance arguments that only the
state machine can establish cleanly, and exposing them would invite
tests that contradict real call-site invariants. They are covered
through the public API (`rent`, `retire`, `apply_pending_transitions`,
`borrow_asset`, `return_asset`, `claim_asset`).

**P_READ test row (required, §0).** The convention "`read_state`
must never be called inside a take/put window" is pinned by an
`expected_failure` test that opens a take/put window and calls
`read_state` inside it. Listed in §10.14.5; the test exercises a
private path that requires temporarily exposing `take_state` /
`put_state` / `read_state` as `#[test_only]` shims, or running the
test inside the `rental_escrow` module itself.

#### Event inspection

All rows that assert "N events emitted" use `test_scenario::next_tx`'s
`TransactionEffects` plus `event::events_by_type<T>()` — one call
per event type yields the typed vector, and row asserts check
`length` + field contents. The star-schema JOIN rows (B2, W2a)
assert identity triples across event pairs (`tenant_cap_id` across
AssetBorrowed↔AssetReturned, `owner_cap_id` across
EarningsWithdrawn repetitions) rather than relying on tx-envelope
data.

#### State-inspection pattern

`rental_escrow` no longer exposes a public `state()` projection (§8.6 —
the previous `&EscrowState` accessor was removed to enforce P_READ at
the visibility layer). Rows that need to assert "state variant is X
with payload Y" must therefore choose one of three patterns:

1. **Co-located test (preferred).** Place the row inside the
   `rental_escrow` module under `#[test]`; it can call the private
   `read_state` directly:

   ```move
   match (read_state(&escrow)) {
       EscrowState::HandoverConfirmed { current, pending, handover_countdown_expiry, .. } => {
           assert!(current.cap_id == expected_current_cap_id, 0);
           assert!(pending.cap_id == expected_pending_cap_id, 1);
           assert!(*handover_countdown_expiry == expected_expiry, 2);
       },
       _ => assert!(false, 99),
   }
   ```

2. **`#[test_only]` projection shim.** Add a temporary
   `#[test_only] public fun state_for_testing<A,C>(escrow:
   &RentalEscrow<A,C>): &EscrowState<A,C> { read_state(escrow) }`
   inside `rental_escrow` so external test modules can pattern-match
   on the variant. The shim is gated by `#[test_only]` and never
   exists in production builds — P_READ remains visibility-protected
   on the SDK surface.

3. **Read via events.** When the assertion target is recoverable
   from the most recent emitted event (`HandoverCompleted.new_rent_price`,
   `BidPlaced.handover_countdown_expiry`, etc.), prefer that path —
   it doubles as a smoke test for the indexer schema.

Discriminator-only assertions use `state_tag` against the result of
the chosen projection (`state_tag(read_state(&escrow))` for pattern 1;
`state_tag(state_for_testing(&escrow))` for pattern 2):

```move
assert!(rental_escrow::state_tag(read_state(&escrow)) == EscrowStateTag::HandoverOpen, 0);
```

Discriminator assertions are also reachable directly via the public
`apply_pending_transitions` / `retire` return values (both produce
`EscrowStateTag`) without any projection — preferred when the row's
intent is "what variant does the escrow settle to".

#### Abort-row split-tx pattern

Already documented in §10.13. Lifted to this section so rows in
§10.8 (C10–C13), §10.9 (W4–W5), §10.7 (B9–B10) can reference it by
name: an abort row that also needs to assert APT's work splits into
two transactions — tx1 calls `apply_pending_transitions` standalone
(asserts settled state + events + balances before the abort), tx2
calls the aborting function. This applies anywhere an
`#[expected_failure]` row needs observable APT effects, not just in
§10.13.

A secondary invariant for this pattern: **tx1 must fully succeed.**
If tx1 itself aborts (e.g., a bug makes APT read a `None` field),
the framework's abort catcher at tx2 sees no tx, and
`expected_failure` still matches by abort_code — masking the tx1
regression. Every tx1 in a split-tx abort row therefore asserts at
least one concrete postcondition (an event count or a balance
delta) before the `next_tx` boundary.

#### Axes (row prefixes already in §10.1–10.13 — retained)

- T — Integration
- R — `rent()` per-state paths
- A — `apply_pending_transitions`
- B — `borrow_asset` / `return_asset`
- C — `retire` / `claim_asset`
- W — `withdraw_earnings`
- Q — read-only queries
- F — fee routing
- L — full lifecycle
- M — APT + `rent()` composite matrix

New prefixes introduced in this audit:

- U — unit rows on pure helpers (§10.14)
- P — property mapping (§10.15)

### 10.1 Integration

| # | Description | Expected |
|---|---|---|
| T1 | `integrate<DemoAsset, C>` with a valid config and fee_ref | Returns `OwnerCap`. `RentalEscrow` shared. Variant inspection (per §10.0 state-inspection pattern) confirms `EscrowState::Idle { asset }`. `integrated_at_ms == clock::timestamp_ms(clock)`. `fee_inbox_id == object::id(&protocol_fee_inbox)`. `IntegrationConfigRegistered` and `AssetIntegrated<DemoAsset, C>` events emitted (config first, then asset). Event type tag of `AssetIntegrated` carries both phantom type params — asserts the indexer can recover Asset and CoinType without reading the on-chain object. `AssetIntegrated.asset_id == object::id(&input_asset)` — asserts the wrapped instance is identifiable. |
| T2 | `integrate<OwnerCap, C>` (deposit an existing escrow's cap) | Succeeds. Returns a second `OwnerCap` for the wrapping escrow. The wrapped cap becomes the wrapping escrow's `Idle.asset`. `AssetIntegrated.asset_id == object::id(&input_owner_cap)` — this is the level-1 `OwnerCap`'s ID; JOINing on `owner_cap_id` in `OwnerCapMinted` recovers the level-1 escrow, closing the level-2 → level-1 linkage from events alone. No depth check. |

### 10.2 `rent` — Idle path

| # | Description | Expected |
|---|---|---|
| R1 | Pay exactly `min_rent_price` | State variant → `HandoverOpen { asset: Some(_), current: Tenant { stake.value == min_rent_price, .. }, retiring: false, .. }`. `TenantCap` returned to sender. `RentStarted{from_state: Idle}` event. |
| R2 | Pay less than `min_rent_price` | Aborts `E_INSUFFICIENT_PAYMENT`. |
| R3 | Overpay from Idle | Accepted. `current.stake.value == full payment`. State → `HandoverOpen`. |
| R4 | Rent when prior `retire()` from Idle settled to Retired | State was moved to `Retired` by the prior `retire()` call (§4.2 step 6 Idle arm); APT is a no-op. `compute_floor_price` (rent step 2) hits the `Retired` arm → aborts `E_RETIRED_NO_BID`. |

### 10.3 `rent` — AtDutchAuction path

| # | Description | Expected |
|---|---|---|
| R5 | Pay exactly `compute_price_descent(now)` | State → `HandoverOpen`. `current.stake.value == payment`. `RentStarted{from_state: AtDutchAuction}`. |
| R6 | Overpay (e.g. PTB latency) | Accepted. `current.stake.value == full payment`. No refund. |
| R7 | Underpay | Aborts `E_INSUFFICIENT_PAYMENT`. |
| R8 | Descent fully elapsed, pay `min_rent_price` | State → `HandoverOpen`. |

### 10.4 `rent` — HandoverOpen takeover path

| # | Description | Expected |
|---|---|---|
| R9 | Pay exactly `next_rent_price` | State variant → `HandoverConfirmed { ..., pending: Tenant { .. }, handover_countdown_expiry: set, .. }`. `BidPlaced` event. |
| R10 | Overpay above `next_rent_price` | Accepted. `pending.stake.value == full payment`. `BidPlaced` event. |
| R11 | Bid with prior variant `HandoverOpen { retiring: true }` | Aborts `E_RETIRE_FLAG_BLOCKS_BID`. |
| R12 | Remaining rent time <= `handover_floor` (Dutch auction bypass) | `state.HandoverConfirmed.handover_countdown_expiry == phase_start_ms + tenure_ceiling`. |

### 10.5 `rent` — HandoverConfirmed supersede path

| # | Description | Expected |
|---|---|---|
| R13 | New bid supersedes pending | Previous pending refunded to previous address. `pending.stake.value == new bid`. `pending.address == new bidder`. `handover_countdown_expiry` unchanged. `current` and `retiring` preserved. `BidSuperseded` event. |
| R14 | Supersede with `retiring: true` on the prior variant | Allowed — flag was set after this pending bid committed; the bid is honored. The new variant preserves `retiring: true`. |
| R15 | Supersede with insufficient amount | Aborts `E_INSUFFICIENT_PAYMENT`. |

### 10.6 `apply_pending_transitions`

| # | Description | Expected |
|---|---|---|
| A1 | Called on Idle, no time elapsed | No-op. Returns `EscrowStateTag::Idle`. No events. |
| A2 | Called on `HandoverConfirmed`, handover expiry reached | `do_handover` fires. Returns `EscrowStateTag::HandoverOpen`. `HandoverCompleted` emitted with `timestamp_ms == boundary`. |
| A3 | Called on `HandoverOpen`, tenure expiry reached | `do_tenure_expiry` fires. Returns `EscrowStateTag::AtDutchAuction`. `TenureExpired` emitted. |
| A4 | Called on `AtDutchAuction`, descent expiry reached | `do_auction_expiry` fires. Returns `EscrowStateTag::Idle`. `AuctionExpired` emitted. |
| A5 | Called after long inactivity: handover + tenure + auction all due | All three fire in order. Returns `EscrowStateTag::Idle`. Three events emitted. |
| A6 | Called with `retiring: true` on the active `HandoverOpen` variant, tenure expired | `do_tenure_expiry` fires with `next_state: EscrowStateTag::Retired`. Returns `EscrowStateTag::Retired`. |
| A7 | `do_handover` with `used_credit == 0` (very convex PowerLaw curve, handover fires immediately after bid) | `remain_credit == outgoing.stake.value`. Full stake pushed to displaced tenant as `Coin<C>`. `owner_earnings` unchanged. No `FeeMessage<C>` constructed (the `if protocol_fee > 0` guard skips `fee_message::post`). `HandoverCompleted` emitted with `used_credit: 0`, `owner_share: 0`, `protocol_fee: 0`. |
| A8 | `do_handover` with `used_credit == outgoing.stake.value` (Dutch Auction bypass — `remain_credit == 0`) | No coin pushed to displaced tenant. Full stake split 90/10 into `owner_earnings` and `FeeMessage`. `HandoverCompleted` emitted with `remain_credit: 0`. |

### 10.7 `borrow_asset` / `return_asset`

| # | Description | Expected |
|---|---|---|
| B1 | Borrow with valid current cap | Returns `(asset, receipt)`. `AssetBorrowed { escrow_id, tenant_cap_id }` event where `tenant_cap_id == object::id(tenant_cap)`. After call (via §10.0 state-inspection pattern), variant is `HandoverOpen { asset: None, .. }`. |
| B2 | Return via correct receipt + same asset | Asset back in escrow (variant inspection confirms `HandoverOpen { asset: Some(_), .. }` again). Receipt consumed. `AssetReturned { escrow_id, tenant_cap_id }` event where `tenant_cap_id` matches the B1 borrow — JOIN on `tenant_cap_id` reconstructs the borrow window. |
| B2a | Multiple borrow/return pairs in the same tenancy | Each pair emits its own `AssetBorrowed` / `AssetReturned` on the same `tenant_cap_id`; indexer can count usage frequency per tenant. |
| B3 | Borrow with a stale cap (previous tenant after handover) | Aborts `E_STALE_TENANT_CAP`. |
| B4 | Borrow with cap for a different escrow | Aborts `E_WRONG_ESCROW_TENANT_CAP`. |
| B5 | Return with receipt for a different escrow | Aborts `E_RECEIPT_ESCROW_MISMATCH`. |
| B6 | Return a different asset (substitution attempt) | Aborts `E_RECEIPT_ASSET_MISMATCH`. |
| B7 | Forget to return (receipt unconsumed) | PTB fails to type-check — hot potato must be consumed. |
| B8 | `borrow_asset` called twice in the same PTB | Second call aborts `E_ASSET_ALREADY_BORROWED` — variant's `asset` field is `None` after the first extraction. |
| B9 | `borrow_asset` called by T(n) with T(n)'s cap when pre-APT state is `HandoverConfirmed` and handover has expired — APT fires C1 rotating the variant to `HandoverOpen` with T(n+1)'s cap as new `current.cap_id` before the staleness check | Split-tx per §10.0 abort-row strategy. **tx1** (standalone APT): fires `do_handover` — variant rotates to `HandoverOpen { current: { cap_id: T(n+1)_cap_id, .. }, .. }`, `HandoverCompleted` emitted, `owner_earnings` credited. **tx2** (`borrow_asset` with T(n)'s cap): §6.1 step 3 passes (cap belongs to this escrow), step 6 fails — `state.HandoverOpen.current.cap_id` now holds T(n+1)'s ID, not T(n)'s — aborts `E_STALE_TENANT_CAP` at the identity compare. Distinct from B3 (cap that was already stale pre-call): here the cap becomes stale **during** the call via APT's own work. Asserts §6.1 step 1 runs before step 6. |
| B10 | `borrow_asset` called by T(n) with T(n)'s cap when pre-APT state is `HandoverOpen` and tenure has expired (no handover pending) — APT fires C2 transitioning to `AtDutchAuction` before the staleness check | Split-tx per §10.0 abort-row strategy. **tx1** (standalone APT): fires `do_tenure_expiry` — `outgoing.stake × 0.90` → `owner_earnings`, `FeeMessage<C>` routed, variant → `AtDutchAuction`, `TenureExpired` emitted. **tx2** (`borrow_asset` with T(n)'s cap): step 6 hits the `Idle | AtDutchAuction | Retired` arm — variant carries no `current` field — aborts `E_STALE_TENANT_CAP`. Complements B9: same abort code, different APT transition (C2 → no-tenant variant; C1 → tenant variant with different cap_id). |

**`burn_tenant_cap` rows (§6.3):**

| # | Description | Expected |
|---|---|---|
| BTC1 | Burn a stale cap (cap from a previous tenancy whose ID is absent from the active variant — variant rotated by `do_tenure_expiry` to `AtDutchAuction` / `Retired` / `Idle`, or rotated out by `do_handover` to a new `current.cap_id`) | Cap UID deleted. `TenantCapBurned { tenant_cap_id, escrow_id, tenant: tx_context::sender(ctx) }` emitted. No escrow state mutation (no variant field referenced this cap). |
| BTC2 | Burn the current cap (cap ID matches `state.HandoverOpen.current.cap_id`) | Aborts `E_TENANT_CAP_NOT_STALE`. Cap not destroyed; escrow variant unchanged. Asserts the wrapper rejects accidental destruction of the holder's own active access. |
| BTC3 | Burn the pending cap (cap ID matches `state.HandoverConfirmed.pending.cap_id`) | Aborts `E_TENANT_CAP_NOT_STALE`. Cap not destroyed; escrow variant unchanged. Asserts the wrapper rejects destruction of a bidder's pending promotion target. |
| BTC4 | Burn a cap for a different escrow (`tenant_cap::escrow_id(cap) != object::id(escrow)`) | Aborts `E_WRONG_ESCROW_TENANT_CAP`. Same threat model as `borrow_asset` row B4 — PTB-pairing defense. |
| BTC5 | Burn a cap that **becomes stale during the call** via the wrapper's internal `apply_pending_transitions`. Setup: cap is current, but tenure expired before this call. | APT fires `do_tenure_expiry` (variant rotates to `AtDutchAuction` / `Retired`); the liveness gate sees a non-Rented variant and proceeds to burn. Cap destroyed; `TenureExpired` and `TenantCapBurned` co-emitted in the same tx. Asserts the wrapper's settle-first ordering — without it, a holder couldn't burn a cap whose escrow has just expired. |
| BTC6 | Burn a cap that **becomes current during the call** via APT's `do_handover`. Setup: cap is pending, handover countdown has elapsed before this call. | APT fires `do_handover` (rotates pending → current); the gate then sees the cap as current and aborts `E_TENANT_CAP_NOT_STALE`. The settle did happen (escrow variant mutated, `HandoverCompleted` emitted) but the cap survives. Asserts the wrapper does not "swallow" a settle that produces an abort — the state machine's work persists, only the burn is rejected. |

### 10.8 `retire` / `claim_asset`

| # | Description | Expected |
|---|---|---|
| C0 | `retire(escrowA, capB)` where `capB` is a legitimate `OwnerCap` for a different escrow B | Aborts `E_WRONG_ESCROW_OWNER_CAP` at §4.2 step 1. Same PTB-pairing defense as `claim_asset` (C8) and `withdraw_earnings` (W3). |
| C1 | `retire` before `retire_floor` elapsed | Aborts `E_RETIRE_FLOOR_NOT_ELAPSED`. |
| C1a | `retire` at exactly `integrated_at_ms + retire_floor` | Succeeds — boundary is inclusive per §4.2 step 3 (`>=`). |
| C2 | `retire` from Idle (after `retire_floor`) | State variant → `Retired { asset }`. Events in order: `RetireFlagSet(owner, state_at_set: EscrowStateTag::Idle)` with `owner == tx_context::sender(ctx)`, `AssetRetired(from_state: EscrowStateTag::Idle)`. Returns `EscrowStateTag::Retired`. |
| C3 | `retire` from AtDutchAuction | State variant → `Retired { asset }` (immediate; `phase_start_ms` and `last_acquisition_price` from prior variant dropped). Events in order: `RetireFlagSet(owner, state_at_set: AtDutchAuction)`, `AssetRetired(from_state: AtDutchAuction)`. No `AuctionExpired` — the auction was interrupted, not expired. |
| C4 | `retire` from `HandoverOpen` | Active variant rotated to `HandoverOpen { ..., retiring: true }` (other fields preserved). Subsequent `rent()` aborts `E_RETIRE_FLAG_BLOCKS_BID`. |
| C5 | `retire` from `HandoverConfirmed` | Active variant rotated to `HandoverConfirmed { ..., retiring: true }`. Handover completes normally; new tenant enters `HandoverOpen { ..., retiring: true }` with flag inherited. |
| C6 | Second `retire` call | Aborts `E_ALREADY_RETIRED` (caught either at the `Retired` arm or by the `assert!(!retiring, ...)` guard inside the Rented arms). |
| C7 | `claim_asset` when state variant != `Retired` | Aborts `E_NOT_RETIRED`. |
| C8 | `claim_asset` with non-matching `OwnerCap` | Aborts `E_WRONG_ESCROW_OWNER_CAP`. |
| C9 | `claim_asset` on `Retired` with accumulated earnings | Returns `(asset, coin == owner_earnings)`. OwnerCap burned. Escrow deleted. `AssetClaimed` event. |
| C10 | Full retire-then-claim flow from `HandoverOpen` | `retire` (tx1) emits `RetireFlagSet(state_at_set: HandoverOpen)` only — no `AssetRetired` yet (deferred). Tenure expiry resolved in tx2 by APT: variant → `Retired`, events in order `TenureExpired(next_state: Retired)`, `AssetRetired(from_state: HandoverOpen)`. `claim_asset` (tx3) succeeds. |
| C11 | `claim_asset` with `retiring: true` already on the active variant, pre-APT state `HandoverConfirmed`, both handover and T(n+1)'s tenure expired — APT chains C1 → C2(→Retired) before claim's own logic | APT fires `do_handover`: T(n+1) installed (variant rotates to `HandoverOpen { ..., retiring: true }` — flag preserved), `owner_earnings += used_credit × 0.90`, `remain_credit` pushed to T(n). APT then fires `do_tenure_expiry` with `retiring: true`: `owner_earnings += T(n+1)_stake × 0.90`, variant → `Retired`. Claim asserts `Retired` ✓ and returns `(asset, Coin == accumulated owner_earnings)`. Events in order: `HandoverCompleted`, `TenureExpired(next_state: Retired)`, `AssetRetired(from_state: HandoverOpen)`, `AssetClaimed`. |
| C12 | `retire` called when pre-APT state is `HandoverOpen` and tenure has expired (no prior `retiring`) — APT fires C2 moving variant to `AtDutchAuction` before retire's own logic | APT fires `do_tenure_expiry` (flag was unset in the prior `HandoverOpen` variant): variant → `AtDutchAuction`, `TenureExpired` emitted. Retire body then matches the `AtDutchAuction` arm: variant → `Retired { asset }`. Events in order: `TenureExpired`, `RetireFlagSet(state_at_set: AtDutchAuction)`, `AssetRetired(from_state: AtDutchAuction)`. No `AuctionExpired` — interrupted. Asserts retire's dispatch is driven by the post-APT variant. |
| C13 | `retire` called when pre-APT state is `HandoverConfirmed` and handover has expired (no prior `retiring`) — APT fires C1 moving variant to `HandoverOpen` with T(n+1) installed before retire's own logic | APT fires `do_handover`: T(n+1) installed in `HandoverOpen { ..., retiring: false }`, `HandoverCompleted` emitted. Retire body then matches the `HandoverOpen` arm: variant rotated to `HandoverOpen { ..., retiring: true }`. Emits `RetireFlagSet(state_at_set: HandoverOpen)`. Flag now applies to T(n+1)'s tenure. |

### 10.9 `withdraw_earnings`

| # | Description | Expected |
|---|---|---|
| W1 | Withdraw with zero earnings | Aborts `E_NO_EARNINGS`. |
| W2 | Withdraw with positive earnings | Returns Coin of exact balance. `owner_earnings == 0` after. `EarningsWithdrawn { escrow_id, owner_cap_id, owner, amount }` event with `owner_cap_id == object::id(owner_cap)` and `owner == tx_context::sender(ctx)`. |
| W2a | Same cap transferred between two distinct addresses, each withdraws once | Two `EarningsWithdrawn` rows sharing `owner_cap_id` but with different `owner` values. Confirms `owner` is first-observed per call — not cached from mint-time. |
| W3 | Withdraw with wrong cap | Aborts `E_WRONG_ESCROW_OWNER_CAP`. |
| W4 | Withdraw when pre-call state is `HandoverOpen` and tenure has expired — APT fires `do_tenure_expiry` before drain | APT credits `owner_earnings += outgoing.stake × 0.90`, routes `outgoing.stake × 0.10` as `FeeMessage<C>` to `fee_inbox_id`, variant → `AtDutchAuction`. Withdraw returns `Coin == (pre_earnings + stake × 0.90)`; `owner_earnings == 0` after. Events in order: `TenureExpired`, then `EarningsWithdrawn`. |
| W5 | Withdraw when pre-call state is `HandoverConfirmed` and handover has expired — APT fires `do_handover` before drain | APT credits `owner_earnings += used_credit × 0.90`, pushes `remain_credit` to displaced tenant, rotates `pending → current`, variant → `HandoverOpen` with T(n+1) installed. Withdraw returns `Coin == (pre_earnings + used_credit × 0.90)`. Events in order: `HandoverCompleted`, then `EarningsWithdrawn`. |

### 10.10 Read-only queries

| # | Description | Expected |
|---|---|---|
| Q1 | `compute_used_credit` called when state variant is `Idle` | Aborts `E_NOT_RENTED`. |
| Q2 | `compute_used_credit` called when state variant is `AtDutchAuction` | Aborts `E_NOT_RENTED`. |
| Q3 | `compute_used_credit` called when state variant is `Retired` | Aborts `E_NOT_RENTED`. |
| Q4 | `compute_floor_price` called when state variant is `Idle` | Returns `config.min_rent_price`. |
| Q5 | `compute_floor_price` called when state variant is `HandoverOpen` | Returns `compute_next_rent_price(&config, balance::value(&current.stake))`. |
| Q6 | `compute_floor_price` called when state variant is `HandoverConfirmed` | Returns `compute_next_rent_price(&config, balance::value(&pending.stake))` — the supersede floor, driven by the pending bid. |
| Q7 | `compute_floor_price` called when state variant is `AtDutchAuction` and `timestamp_ms` within descent window | Returns `compute_price_descent(escrow, timestamp_ms)` — non-abortive, time-dependent. |
| Q8 | `compute_floor_price` called when state variant is `AtDutchAuction` after `descent_ceiling` elapsed | Returns `config.min_rent_price` (saturation point). |
| Q9 | `compute_floor_price` called when state variant is `Retired` | Aborts `E_RETIRED_NO_BID`. |
| Q10 | `compute_floor_price` value equals the floor actually enforced by `rent()` | For any variant in which `rent()` does not abort on state, the value returned by `compute_floor_price(escrow, clock.now())` is exactly the threshold against which `rent()` asserts `coin::value(&payment) >= ...` (modulo the `retiring` check in `HandoverOpen`, which is a separate precondition). |
| Q11 | `compute_floor_price` after a settle with `descent_ceiling = 0`. Setup: install a tenant with a config where `descent_ceiling = 0`; advance the clock past `tenure_ceiling`; call APT. | Post-settle: state variant == `Idle` (NOT `AtDutchAuction`). `compute_floor_price(escrow, clock.now())` returns `config.min_rent_price`, **not** `compute_price_descent`. Co-emitted events: `TenureExpired` and `AuctionExpired` with identical `timestamp_ms == boundary_ms`. Asserts the structural invariant that AtDutchAuction is unobservable post-settle under `descent_ceiling = 0`. |

**Note on `compute_price_descent` and `compute_next_rent_price`:**
these are `public(package)` helpers (§8.2, §8.3) with no state guard.
They are not reachable from outside the package, so no state-guard
test is applicable — their correctness is covered by the
`compute_floor_price` dispatch tests above and by the `rent()`
acquisition tests (R5–R8 for `compute_price_descent`, R9–R15 for
`compute_next_rent_price`).

### 10.11 Fee routing

| # | Description | Expected |
|---|---|---|
| F1 | `do_handover` with non-zero `used_credit` | `owner_earnings += 0.90 × used_credit`. One `FeeMessage<C>` posted via `fee_message::post<CoinType>(fee_balance, object::id(escrow), displaced_tenant, escrow.fee_inbox_id, ctx)`, with balance `0.10 × used_credit` and `escrow_id == object::id(escrow)`. `HandoverCompleted` event includes both shares. |
| F2 | `do_handover` at Dutch Auction bypass (`used_credit == outgoing.stake.value`) | `remain_credit == 0`, zero push to displaced tenant. Fee and owner share computed on full stake. Fee path as in F1. |
| F3 | `do_tenure_expiry` | `owner_earnings += 0.90 × stake`. One `FeeMessage<C>` of `0.10 × stake` constructed + sent as in F1. |
| F4 | Fee on tiny `used_credit` (`split_fee` floors fee to zero) | `if protocol_fee > 0` guard short-circuits: no split, no `fee_message::post` call, no `FeeMessage<C>` constructed. `owner_share == used_credit`. |

### 10.12 Full lifecycle

| # | Description | Expected |
|---|---|---|
| L1 | integrate → rent (Idle) → borrow → return → (time passes) → tenure expiry → auction expiry → rent (Idle) → retire → claim | All transitions fire correctly. Owner receives asset + earnings. Protocol fees accumulated in `ProtocolFeeInbox`. No orphaned balances (structurally — Retired variant carries no `stake` field). |
| L2 | integrate → rent → takeover bid → handover → (new tenant active) → retire → tenure expiry → claim | `retiring` flag inherited by the new tenant via the rotated variant. Claim succeeds after their tenure ends. |
| L3 | integrate an inner escrow → deposit its `OwnerCap` via `integrate` into an outer escrow → outer tenant borrows the cap and calls `retire` on the inner escrow | Inner escrow enters the retire flow. Outer escrow unaffected (its asset is the cap, which is now "pointing at a retiring escrow"). |

### 10.13 APT + `rent()` composite matrix

Every `rent()` call chains `apply_pending_transitions` (APT) before
dispatching on the settled state. This matrix enumerates the
reachable combinations of (pre-APT variant × APT outcome × `rent()`
branch) so the settlement-then-dispatch flow is exercised on every
path the state machine admits.

**Test structure under Move's test framework.** Move's `#[test]`
fns take no parameters, `#[expected_failure]` is strictly
function-level, and there is no try / catch or abort-catching
primitive — an abort inside a looped test terminates the whole test.
Success and abort rows therefore cannot share a single parametric
loop. The matrix maps to two clusters:

1. **Success cluster (11 rows: M1–M6, M8–M11, M15)** — one `#[test]`
   fn iterates a `vector<Case>` of records and calls a `#[test_only]`
   helper `check_case((pre_variant, elapsed_ms, retiring, payment),
   expected(post_variant, events, balances))`. Each iteration opens
   a fresh `test_scenario`, builds the pre-APT variant via a setup
   helper, advances the clock, calls `rent()`, and asserts the
   post-state / emitted events / balance deltas.
2. **Abort cluster (4 rows: M7, M12, M13, M14)** — one `#[test,
   expected_failure(abort_code = E_...)]` fn per row. For the
   abort-row testing strategy (M7, M12, M13), the fn runs two
   transactions via `test_scenario::next_tx`: tx1 calls APT
   standalone, tx2 calls `rent()`. M14 is a pure rent-abort.

The golden-path standalone cases (R1 for Idle entry, R13 for
HandoverConfirmed supersede) remain separate from the
success-cluster loop — they stay readable even if the parametric
helper regresses.

| # | Pre-APT variant | Elapsed conditions | APT fires | Post-APT variant | `rent()` branch | Expected |
|---|---|---|---|---|---|---|
| M1 | Idle | — | none | Idle | Idle | Cross-ref R1–R3. APT no-op, `do_install_new_tenant` writes on empty escrow. |
| M2 | AtDutchAuction | `now < phase_start + descent_ceiling` | none | AtDutchAuction | AtDutchAuction | Cross-ref R5–R7. APT no-op, `compute_price_descent(now)` against preserved `phase_start_ms`. |
| M3 | AtDutchAuction | `now ≥ phase_start + descent_ceiling` | C3 | Idle | Idle | `AuctionExpired` then `RentStarted(from_state: Idle)`. |
| M4 | HandoverOpen, `retiring: false` | tenure not expired | none | HandoverOpen | HandoverOpen | Cross-ref R9, R10, R12. The subtraction `phase_start + tenure_ceiling - now` is u64-safe exactly because C2 did not fire. |
| M5 | HandoverOpen | tenure expired, `retiring: false` | C2 | AtDutchAuction | AtDutchAuction | `TenureExpired(AtDutchAuction)` then `RentStarted(from_state: AtDutchAuction)`. `owner_earnings += stake × 0.90`; one `FeeMessage<C>` created and transferred to `fee_inbox_id`. |
| M6 | HandoverOpen | tenure + descent expired, `retiring: false` | C2 → C3 | Idle | Idle | `TenureExpired` + `AuctionExpired` + `RentStarted(from_state: Idle)`. |
| M6b | HandoverOpen, config has `descent_ceiling = 0` | tenure expired (descent expiry coincides) | C2 → C3 (atomic, same APT call) | Idle | Idle | Same shape as M6 reached via `descent_ceiling = 0`. AtDutchAuction never observable. `TenureExpired` and `AuctionExpired` co-emit with identical `timestamp_ms == boundary_ms`, then `RentStarted(from_state: Idle)`. Pairs with Q11. |
| M7 | HandoverOpen | tenure expired, `retiring: true` | C2 | Retired | — | `rent()` aborts `E_RETIRED_NO_BID`. The abort rolls back the whole transaction — APT's variant change and `TenureExpired(Retired)` event do not persist. See abort-row note. |
| M8 | HandoverConfirmed, `retiring: false` | handover not expired | none | HandoverConfirmed | HandoverConfirmed | Cross-ref R13, R15. APT no-op; supersede refund + push-before-rotate exercised. |
| M9 | HandoverConfirmed | handover expired, new tenure still active, `retiring: false` | C1 | HandoverOpen | HandoverOpen | `HandoverCompleted` (push `remain_credit`, rotate `pending → current`) then `BidPlaced` on the fresh open variant. |
| M10 | HandoverConfirmed | handover + new tenure expired, `retiring: false` | C1 → C2 | AtDutchAuction | AtDutchAuction | `HandoverCompleted` + `TenureExpired(AtDutchAuction)` + `RentStarted(from_state: AtDutchAuction)`. The stake consumed by C2 is the rotated pending stake, not the original tenant's. |
| M11 | HandoverConfirmed | all three boundaries expired, `retiring: false` | C1 → C2 → C3 | Idle | Idle | Upper bound of the lazy chain (P4 §9). Four events: `HandoverCompleted`, `TenureExpired`, `AuctionExpired`, `RentStarted(from_state: Idle)`. |
| M12 | HandoverConfirmed | handover + new tenure expired, `retiring: true` | C1 → C2 (→ Retired) | Retired | — | `rent()` aborts `E_RETIRED_NO_BID`. APT would execute `do_handover` (flag preserved by `do_handover` step 7) then `do_tenure_expiry` (routes to Retired because of flag), but the abort rolls them back. |
| M13 | HandoverConfirmed | handover expired, new tenure still active, `retiring: true` | C1 | HandoverOpen | — | `rent()` aborts `E_RETIRE_FLAG_BLOCKS_BID`. APT would complete the handover with flag preserved, but the abort rolls it back. |
| M14 | HandoverOpen, `retiring: true` | tenure not expired | none | HandoverOpen | — | `rent()` aborts `E_RETIRE_FLAG_BLOCKS_BID`. APT is a no-op. Equivalent to R11 as a direct test. |
| M15 | HandoverConfirmed, `retiring: true` | handover not expired | none | HandoverConfirmed | HandoverConfirmed | Supersede succeeds — `rent()` HandoverConfirmed branch does not check `retiring`. APT no-op. Equivalent to R14. |

**Novel coverage:** M3, M5–M7, M9–M13 exercise paths where APT
changes the variant before dispatch — not reachable from the
single-state tables §10.2–10.5. M1 / M2 / M4 / M8 / M14 / M15 are
matrix anchors where APT is a no-op.

**Abort-row testing strategy (M7, M12, M13):** when `rent()` aborts,
Sui Move rolls back the whole transaction. To assert APT's work
independently, split the test into two transactions: tx1 calls APT
standalone (observe settled variant, events, balances); tx2 calls
`rent()` (observe the expected abort code).

**Phase-anchor correctness:** every row implicitly asserts that
`phase_start_ms` (read inside the active variant via the §10.0
state-inspection pattern) equals the value assigned by the last
transition fired before `rent()` body runs. After M10 it equals the
new tenure's start (= the handover boundary from
`state.HandoverConfirmed.handover_countdown_expiry`) at APT exit,
then gets rewritten by `do_install_new_tenant` inside the rent body.

**Retire flag coverage closure:**
- HandoverOpen block on live bid: M14 (no APT transition, ≡ R11) + M13 (via APT).
- HandoverConfirmed tolerates `retiring` on supersede: M15 (≡ R14).
- Retired dispatch abort via APT: M7, M12.
- Idle / AtDutchAuction immediate retire: C2, C3 (§10.8).

### 10.14 Unit rows on pure helpers

Direct tests via the `#[test_only]` shims in §10.0.

#### 10.14.1 `split_fee`

`split_fee` is pure (§7.4). Parametric `#[test]` over a
`vector<Case>`:

| # | `amount` | Expected `(owner, fee)` | Property anchored |
|---|---|---|---|
| U1 | `0` | `(0, 0)` | P12 zero-path identity |
| U2 | `1` | `(1, 0)` | Fee flooring — `mul_div(1, 1000, 10000) = 0` |
| U3 | `9` | `(9, 0)` | Still below threshold |
| U4 | `10` | `(9, 1)` | Smallest non-zero fee |
| U5 | `100` | `(90, 10)` | Round numbers — 90 / 10 exact |
| U6 | `1_000` | `(900, 100)` | Canonical scale |
| U7 | `999` | `(900, 99)` | Flooring favors owner by 1 base unit |
| U8 | `u64::MAX / 10` | `((u64::MAX / 10) - fee, fee)` with `fee = mul_div(u64::MAX / 10, 1000, 10000)` | Upper bound — no overflow under `math::mul_div` |
| U9 | `u64::MAX` | `(u64::MAX - fee, fee)` | Overflow-free at the u64 ceiling |

Assertion: for every row, `owner + fee == amount` (P1 fund
conservation).

#### 10.14.2 (removed) — `tenure_expiry_ms` / `descent_expiry_ms`

Both helpers were removed (W09008 dead code; §8.5). No unit rows
remain — the boundary arithmetic is exercised inline by the dispatch
match arms covered in §10.6 (APT) and §10.4 / §10.5 (`rent` cases).

#### 10.14.3 `compute_used_credit` boundary guards

Rows extending §10.10:

| # | Scenario | Expected |
|---|---|---|
| Q11 | `HandoverConfirmed`, `timestamp_ms > handover_countdown_expiry` | Returns the value at exactly `handover_countdown_expiry` — not `timestamp_ms`; the post-handover-boundary clamp is observable |
| Q12 | `HandoverConfirmed`, `timestamp_ms == handover_countdown_expiry` | Same value as Q11 — clamp at equality is the fixed point |
| Q13 | `HandoverOpen`, `timestamp_ms < phase_start_ms` | Returns `0` — the pre-phase guard fires before `evaluate_curve` is called |
| Q14 | `HandoverOpen`, `timestamp_ms == phase_start_ms` | Returns `0` — `elapsed == 0`, curve returns 0 |
| Q15 | `HandoverOpen`, `timestamp_ms == phase_start_ms + tenure_ceiling` | Saturates to `current.stake.value` — curve returns `SCALE` |
| Q16 | `HandoverOpen`, `timestamp_ms >> phase_start_ms + tenure_ceiling` | Still saturates to `current.stake.value` |

#### 10.14.4 `compute_price_descent` pre-phase guard

| # | Scenario | Expected |
|---|---|---|
| Q17 | `AtDutchAuction`, `timestamp_ms < phase_start_ms` | Returns `last_acquisition_price`, not `min_rent_price` |
| Q18 | `AtDutchAuction`, `timestamp_ms == phase_start_ms` | `elapsed == 0`, `h == 0`, result `== last_acquisition_price` |
| Q19 | `AtDutchAuction`, `timestamp_ms == phase_start_ms + descent_ceiling` | Curve saturates, result `== min_rent_price` |

#### 10.14.5 P_READ convention test (required)

Pins the runtime witness for P_READ (§0). Single
`#[expected_failure]` row that opens a take/put window via
`take_state` and immediately calls `read_state` — must abort
`E_INVARIANT_VIOLATION` (since the cell is `None` between
`take_state` and the matching `put_state`):

| # | Description | Expected |
|---|---|---|
| U10 | Build minimal `RentalEscrow` (Idle), then call `take_state` followed by `read_state` inside the same Move call | Aborts `E_INVARIANT_VIOLATION = 0xDEADC0DE`. The `put_state` after the read is unreachable; the receipt is discharged by the abort. |

The row exercises private helpers (`take_state` / `put_state` /
`read_state`); the test is therefore written inside the
`rental_escrow_tests` module with `#[test_only]` shims, or directly
inside the `rental_escrow` module under `#[test]`.

### 10.15 Property → row mapping

| Prop | Anchored rows |
|------|---|
| P1 Fund conservation at every boundary | A7, A8, F1–F4, L1; U1–U9 |
| P2 No trapped balances at terminal state (structural) | C9, C10, C11, L1 — variant has no `stake` field; type-level guarantee |
| P3 Push-before-rotate | A2, A7, R13, W5 |
| P4 At most three lazy transitions per call | A5, M11 |
| P5 Check order is a safety invariant | A5, A6, M6, M10, M11 |
| P6 Retire flag is monotonic | C4, C5, C6, C10, C11, L2, M7, M12, M13 |
| P7 OwnerCap uniqueness | T1 (mint), C9 (burn) |
| P8 TenantCap staleness is inert | B3, B9, B10 |
| P9 Tenancy ↔ Rented variant (structural) | R1 (set together), A3 / A6 (cleared together) |
| P10 Pending bid ↔ HandoverConfirmed (structural) | R9, R13, A2 (cleared by do_handover) |
| P11 Asset present while escrow exists | B1–B2, B7 (hot potato enforces), B8 (double-borrow abort) |
| P12 Fee routing is idempotent at zero | F4, A7, U1–U3 |
| P13 `Option<EscrowState>` is `Some` at every transaction boundary | T1 (post-integrate `Some(Idle)`), every row that successfully reads via `compute_floor_price` / `compute_used_credit` / `state_tag` |
| P_READ (convention, §0) — `read_state` not called inside take/put window | U10 (required `expected_failure` row, §10.14.5) |
| P_DO (convention, §0) — `do_*` ↔ owns one take/put window | grep parity at code-review time; no row encodes it directly (every successful state transition exercises one `do_*` + its take/put window) |

### 10.16 Open questions

- **Corpus drift.** The 168-element corpus is shared across every
  row of §10.1–§10.13. A parameter addition to `IntegrationConfig`
  will break the corpus constructor in one place, which is desirable;
  but changing a canonical value (e.g., bumping `tenure_ceiling` or
  the `δ` of `FixedDelta`) silently shifts every assertion that
  hardcoded a derived timestamp or price. Rule: every numeric value
  in the corpus is declared as a named `const` in
  `tests/rental_escrow_corpus.move` and referenced (not duplicated)
  in row assertions. Time-arithmetic derivations
  (`t0 + 150_000` etc.) are written as explicit
  `t0 + corpus::tenure_ceiling() + corpus::descent_ceiling_h1() / 2`
  to fail loudly at compile time on canonical-value changes.
- **Clock primitive choice.** `clock::set_for_testing` sets absolute
  ms; `clock::increment_for_testing` moves it forward. Rows that
  test pre-phase guards (Q13, Q17) need absolute-set semantics.
- **Level-2 integration rows (T2, L3).** `Asset =
  rental_escrow::OwnerCap` is a structural test that exercises the
  generic bound but not the state machine of the inner escrow in a
  single row. A full L3 run is ~40 lines; marked as a single
  integration-style test.
- **Abort-row split-tx spurious pass.** Documented in §10.0; every
  tx1 in a §10.13 abort row asserts at least one concrete
  postcondition before `next_tx`.
- **`KEEPER`-driven APT rows.** Several rows require `KEEPER ≠
  TENANT_A` to assert that `register_pending_bid` reads the bidder
  from the `bidder` parameter, not from a stale `tx_context::sender`.
  Rule: KEEPER is always disjoint from every tenant / bidder alias
  in setup.
- **Private helpers without shims.** All `do_*` helpers
  (`do_handover`, `do_tenure_expiry`, `do_auction_expiry`,
  `do_install_new_tenant`, `do_place_bid`, `do_supersede_bid`,
  `do_retire_immediately`, `do_set_retiring_flag`, `do_extract_asset`,
  `do_fill_asset`) plus `settle_stake_earnings` and
  `register_pending_bid` are covered only via public API.
- **State-projection assertions.** With `state(escrow)` removed
  (§8.6), rows that need to inspect variant payload (e.g., R9
  asserting `pending.stake.value`) must use a `#[test_only]`
  state-projection shim inside the test module, or co-locate the
  test inside `rental_escrow` so it can call private `read_state`
  directly. Fixture setup helpers can also assert on the destructured
  variant they construct, side-stepping the projection question for
  setup-phase asserts.


11. MODULE BOUNDARY
--------------------

`rental_escrow.move` exports:

| Symbol | Visibility | Notes |
|---|---|---|
| `E_NOT_RENTED` | `public` | `compute_used_credit`: state ∉ Rented variants. |
| `E_INSUFFICIENT_PAYMENT` | `public` | rent — payment below floor (all paths). |
| `E_RETIRE_FLAG_BLOCKS_BID` | `public` | rent (HandoverOpen with `retiring: true`). |
| `E_RETIRED_NO_BID` | `public` | rent / compute_floor_price: state is Retired. |
| `E_RETIRE_FLOOR_NOT_ELAPSED` | `public` | retire. |
| `E_ALREADY_RETIRED` | `public` | retire. |
| `E_NOT_RETIRED` | `public` | claim_asset. |
| `E_RECEIPT_ESCROW_MISMATCH` | `public` | return_asset. |
| `E_RECEIPT_ASSET_MISMATCH` | `public` | return_asset. |
| `E_NO_EARNINGS` | `public` | withdraw_earnings. |
| `E_ASSET_ALREADY_BORROWED` | `public` | borrow_asset called while variant's `Option<Asset>` is None. |
| `E_WRONG_ESCROW_OWNER_CAP` | `public` | retire / claim_asset / withdraw_earnings: escrow-match gate. |
| `E_WRONG_ESCROW_TENANT_CAP` | `public` | borrow_asset / burn_tenant_cap: escrow-match gate. |
| `E_PENDING_TENANT_CAP` | `public` | borrow_asset: cap matches `state.HandoverConfirmed.pending.cap_id`. |
| `E_STALE_TENANT_CAP` | `public` | borrow_asset: cap matches no live tenant. |
| `E_TENANT_CAP_NOT_STALE` | `public` | burn_tenant_cap: cap matches a live tenant. |
| `E_INVARIANT_VIOLATION` | `public` | `0xDEADC0DE`. Structural assertion in private helpers — unreachable along the public API. Programmer error, category B (§1.1). |
| `MAX_APT_ITERATIONS` | private const | `4`. APT loop canary (§1.2 / §5.2). |
| `RentalEscrow<Asset, CoinType>` (type) | `public` | `key` only. Shared. Six fields including `state: Option<EscrowState>`. |
| `EscrowState<Asset, CoinType>` (type) | `public` | `store` only — variants embed linear payload (`Asset`, `Tenant<CoinType>`, `Option<Asset>`). Five variants: `Idle`, `AtDutchAuction`, `HandoverOpen`, `HandoverConfirmed`, `Retired`. The type is `public` so `EscrowStateTag` (a `copy + drop + store` mirror) can be projected from it via `state_tag`. External callers do **not** receive a `&EscrowState` — read-only access goes through `state_tag` and the dedicated query functions (`compute_used_credit`, `compute_floor_price`); P_READ enforced at the visibility layer (§0 / §2.6). |
| `EscrowStateTag` (type) | `public` | `copy + drop + store`. Discriminator-only mirror of `EscrowState`. Five payload-free variants. Returned by `apply_pending_transitions`, `retire`, `state_tag`. Used in event field types (`from_state`, `next_state`, `state_at_set`). |
| `Tenant<CoinType>` (type) | `public` | `store` only. Three fields: `cap_id: ID`, `address: address`, `stake: Balance<CoinType>`. Embedded inside `HandoverOpen.current` and `HandoverConfirmed.{current, pending}`. |
| `AssetReceipt` (type) | `public` | Hot potato (no abilities). |
| All event structs | `public` | `copy + drop`. |
| `integrate(...)` | `public` | Generic entry. Accepts any `Asset: key + store`, including `OwnerCap`. |
| `rent(...)` | `public` | Single entry for tenancy. |
| `retire(...)` | `public` | Sets `retiring: true` on active variant or transitions to `Retired`. Returns `EscrowStateTag`. Never returns asset. |
| `claim_asset(...)` | `public` | Returns `(Asset, Coin<CoinType>)`. Deletes escrow. Requires variant `Retired`. |
| `withdraw_earnings(...)` | `public` | Pull owner share. |
| `borrow_asset(...)` | `public` | Returns `(Asset, AssetReceipt)`. Extracts `Option<Asset>` inside the active Rented variant. |
| `return_asset(...)` | `public` | Consumes `AssetReceipt`. Restores `Option<Asset>` inside the active Rented variant. |
| `burn_tenant_cap(...)` | `public` | Wraps `tenant_cap::burn` with liveness gate against current / pending fields. |
| `apply_pending_transitions(...)` | `public` | Permissionless settlement. Returns `EscrowStateTag`. |
| `apply_pending_transitions(...)` via `devInspectTransactionBlock` | — | Free settled-state read. No consensus, no commit. |
| `compute_used_credit(...)` | `public` | Read-only. Aborts `E_NOT_RENTED` if active variant is not `HandoverOpen` or `HandoverConfirmed`. |
| `compute_floor_price(...)` | `public` | Read-only. Dispatches by variant — returns `min_rent_price` (Idle), `compute_next_rent_price` (Rented), `compute_price_descent` (AtDutchAuction). Aborts `E_RETIRED_NO_BID` on Retired. |
| `state_tag(...)` | `public` | Projects `&EscrowState` → `EscrowStateTag`. Used internally by `do_*` helpers on a local variant they hold before `put_state` (`state_tag(&new_state)` pattern). External callers do not invoke `state_tag` directly — they obtain `EscrowStateTag` values from the return types of `apply_pending_transitions` and `retire`, which compute the tag internally and surface it without exposing the underlying variant. The function is `public` (rather than `public(package)`) for symmetry with the `EscrowState` / `EscrowStateTag` public type pair. |
| `StateReceipt` (type) | `public` | §2.6 — internal hot potato (no abilities). Public visibility required by Move 2024 (no internal struct definitions inside the module's public surface), but the receipt is only producible / consumable by private functions. Not constructible from outside the module. |
| `take_state(...)` | private | §2.6 — produces `(EscrowState, StateReceipt)`. Sole producer of `StateReceipt`. Asserts `is_some(&escrow.state)` first; aborts `E_INVARIANT_VIOLATION` on P13 violation. |
| `put_state(...)` | private | §2.6 — consumes `StateReceipt`, refills `escrow.state` with the new variant. Sole consumer of `StateReceipt`. Asserts `is_none(&escrow.state)` first; aborts `E_INVARIANT_VIOLATION` on P13 violation. |
| `read_state(...)` | private | §2.6 — sole reader. Asserts `is_some(&escrow.state)` first; aborts `E_INVARIANT_VIOLATION` on P_READ violation. Used by every dispatch arm in §5–§6 and every read query in §8. |
| `do_handover(...)` | private | §7.1 — HandoverConfirmed → HandoverOpen at `handover_countdown_expiry`. Owns take/put window. |
| `do_tenure_expiry(...)` | private | §7.2 — HandoverOpen → {AtDutchAuction \| Retired} at tenure expiry. Owns take/put window. |
| `do_auction_expiry(...)` | private | §7.3 — AtDutchAuction → Idle at descent expiry. Owns take/put window. |
| `split_fee(...)` | private | §7.4 — pure 90/10 split. |
| `do_install_new_tenant(...)` | private | §7.5 — Idle \| AtDutchAuction → HandoverOpen with fresh tenant. Owns take/put window. Mints `TenantCap`. |
| `settle_stake_earnings(...)` | private | §7.6 — shared stake-settlement tail. Operates on owned `Balance` and `&mut owner_earnings`. |
| `register_pending_bid(...)` | private | §7.7 — shared pending-bid construction tail. Returns `(TenantCap, ID, u64, Tenant<CoinType>)` for the caller to embed in `HandoverConfirmed.pending`. |
| `do_retire_immediately(...)` | private | §7.8 — Idle \| AtDutchAuction → Retired (immediate). Owns take/put window. Co-emits `RetireFlagSet` and `AssetRetired`. |
| `do_set_retiring_flag(...)` | private | §7.9 — HandoverOpen \| HandoverConfirmed → same variant with `retiring: true`. Owns take/put window. Emits `RetireFlagSet`. |
| `do_place_bid(...)` | private | §7.10 — HandoverOpen → HandoverConfirmed. Owns take/put window. Mints `TenantCap`, emits `BidPlaced`. |
| `do_supersede_bid(...)` | private | §7.11 — HandoverConfirmed → HandoverConfirmed. Owns take/put window. Refunds displaced bidder, mints `TenantCap`, emits `BidSuperseded`. |
| `do_extract_asset(...)` | private | §7.12 — extract `Option<Asset>` slot inside Rented variant. Owns take/put window. Returns the extracted `Asset`. |
| `do_fill_asset(...)` | private | §7.13 — fill `Option<Asset>` slot inside Rented variant. Owns take/put window. Returns the active tenant's `cap_id`. |
| `compute_price_descent(...)` | private | §8.2 — read-only helper backing `compute_floor_price` (AtDutchAuction arm). |
| `compute_next_rent_price(...)` | private | §8.3 — read-only helper backing `compute_floor_price` (Rented arms). Takes `&IntegrationConfig` + explicit `price: u64`. |

**Depends on:**
- `math` — `mul_div` via `split_fee`, `compute_used_credit`, and
  `compute_price_descent`.
- `curve_shape` — `CurveShape`, `evaluate_curve`.
- `price_function` — `PriceFunction`, `evaluate_price_fn`.
- `config` — `IntegrationConfig` and `public(package)` getters.
- `owner_cap` — `OwnerCap`, `new`, `burn`, `escrow_id`.
- `tenant_cap` — `TenantCap`, `new`, `burn`, `escrow_id`.
- `protocol_fee_inbox` — `ProtocolFeeRef`, `inbox_id`.
- `fee_message` — `post`.

**Integration flow for a third-party integrator:**

1. Build `CurveShape` values via `curve_shape::new_*`.
2. Build `PriceFunction` value via `price_function::new_*`.
3. Build `IntegrationConfig` via `config::new_config(...)`.
4. Call `rental_escrow::integrate(asset, config, fee_ref, clock,
   ctx)` → receive `OwnerCap`.
5. The escrow is now shared and addressable. Any participant may
   `apply_pending_transitions`, read `state` / `state_tag`, or
   `rent`.
6. The owner may `withdraw_earnings` at any time; `retire` when
   ready; and `claim_asset` once the active variant has resolved to
   `Retired`.

All four layers (`curve_shape`, `price_function`, `config`,
`rental_escrow`) are composable from a single PTB. No off-chain
coordinator or keeper is required — the protocol is fully lazy and
permissionlessly settleable.
