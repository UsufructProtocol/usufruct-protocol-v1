# Explore: new-abstractions branch — work context

Branch: `explore/new-abstractions` (worktree at `/home/aj/Project/sui/usufruct_worktrees/explore-new-abstractions`)
Base: `6591a04` (main)
HEAD: `f84dac1` (introduces `engine_state.move`)

This is an exploratory branch testing how malleable the protocol's
functional/declarative architecture is when introducing new abstractions.
The user is exploring three ideas in increasing order of refactor magnitude.
Idea 1 was tried and rejected mid-flight; Idea 2 is in progress; Idea 3
is the experimental one.

## Status snapshot

- 484/484 tests pass.
- `engine_state.move` exists as a structural addition (`f84dac1`) but is
  **not yet referenced** from `escrow_coordinator.move`. It compiles cleanly
  alongside the existing coordinator.
- Next concrete step: integrate `engine_state` into `escrow_coordinator`
  (replace `state: Option<LifecycleState>` + `StateReceipt` hot-potato with
  `state: Option<EngineState>`; rewrite entries as extract/execute_*/fill
  thin wrappers; remove the now-duplicate `do_*`/events/constants from
  `escrow_coordinator.move`).
- Final cleanup: rename `escrow_coordinator` → `escrow`,
  `EscrowCoordinator` → `Escrow` (commit B, mechanical).

## Idea 1 — RESOLVED & DROPPED

**Original proposal:** move `integrated_at_ms: u64` from a flat field on
`EscrowCoordinator` into the `AssetState` enum (in every non-Retired
variant). Rationale: the field exists *for* `retire()`'s policy floor
check; encode that locality in the type.

**Trajectory:**
1. First attempt: field added to 4 non-Retired variants; views became
   `Option<u64>`.
2. User pushed back: the `Option` introduces an asymmetry vs other
   immutable views (`asset_id`, `coin_type_name`, etc.). The data
   `integrated_at_ms` is true in *every* state including Retired —
   `Option<u64>` is dishonest.
3. Second attempt: added to all 5 variants including Retired; views
   return `u64`.
4. User raised the deeper issue: threading an *immutable* value through
   N transitions is a bug surface. Each match-arm reconstruction is a
   site where someone could mistakenly pass `0` or `now()`.
5. **Final verdict:** revert. `integrated_at_ms` stays as a flat field on
   `EscrowCoordinator`. The "u64 between typed fields" smell that motivated
   Idea 1 was a misjudgment — `id: UID` and `fee_inbox_id: ID` are equally
   primitive neighbors.

**Lesson preserved (commit history scrubbed via reset, but the lesson lives
here):** an immutable value should live at the level where it is written
once. Type-level encoding of "where the value is used" is a weak signal
when the safety cost (threading bugs) is real.

## Idea 2 — IN PROGRESS

**Goal:** move all coordination logic from `escrow_coordinator.move` into a
new `engine_state.move` module. Rename `EscrowCoordinator → Escrow`,
`escrow_coordinator → escrow`. The "engine" becomes a *subject* (a module
that conducts transitions), and `Escrow` becomes the public face.

### Design decisions reached (after long iteration)

#### `EngineState` enum — TWO variants, both meaningful

```move
public enum EngineState<Asset: key + store, phantom CoinType> has store {
    Active {
        l_state:          LifecycleState<Asset, CoinType>,
        owner:            Owner<CoinType>,
        config:           IntegrationConfig,
        escrow_id:        ID,
        fee_inbox_id:     ID,
        integrated_at_ms: u64,
    },
    Inactive {
        asset: Asset,
        owner: Owner<CoinType>,
    },
}
```

The Active variant aggregates everything the engine mutates or consults
(6 fields). Inactive carries only what survives retirement (asset waiting
to be claimed + residual owner earnings).

**Why both variants are real (not nominal):**
- `Active → Inactive` is a one-way transition fired at exactly two boundaries:
  `do_retire_immediately` (owner retires from Idle/AtDutch) and
  `do_tenure_expiry` (when the retiring flag was set during the rental).
- Inactive is terminal — only `unwrap_for_claim` consumes it.
- Type-level guarantee: matching on `Active` rules out the AlreadyRetired
  branch of the legacy `RetireRoute` dispatch. Active never contains a
  Retired lifecycle.

#### Where Option lives (canonical Sui Move pattern)

The `Option<EngineState>` take/put discipline lives at the **outer layer**
(`Escrow` shared object), not inside `engine_state`. Analogy:
`LifecycleState` doesn't have `Option<AssetState>` or `Option<TenantState>`
— those are direct fields. The take/put boundary is one layer above.

`engine_state.move` functions are value-typed (consume + return) or
reference-typed for views. **Never `&mut EngineState`.** No mem::replace
exists in Sui Move (verified — only `Option::extract`/`fill` via
`vector::pop_back`/`push_back` primitive). This is why take/put can only
live where Option lives.

#### Function signatures — clean

The aggregation pays off. Engine signatures are 3-4 args max:

```move
public(package) fun execute_rent<...>(
    state: EngineState<...>,
    payment: Coin<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
): (EngineState<...>, TenantCap)
```

Compare to the alternative I rejected (passing all 6 fields individually) —
those were 7-8 arg signatures.

#### Events live with the verb

All 11 events that fire from coordination logic moved to `engine_state.move`:
`RentStarted`, `BidPlaced`, `BidSuperseded`, `HandoverCompleted`,
`TenureExpired`, `AuctionExpired`, `AssetRetired`, `RetireFlagSet`,
`AssetBorrowed`, `AssetReturned`, `EarningsWithdrawn`.

`AssetIntegrated` and `AssetClaimed` will remain in `escrow.move` (escrow
object lifecycle events: creation, destruction).

Off-chain consumers will need to update event paths from
`usufruct::escrow_coordinator::*` to `usufruct::engine_state::*` for the
moved events.

### Move 2024 / Sui Move gotchas hit during writing

Documented because they recur:

1. **No `let else` for enums.** `let EngineState::Active { ... } = state else
   abort ...` doesn't compile. Use exhaustive `match` and put body in the
   intended arm; abort in the rejected arm.

2. **`{ .. }` pattern doesn't work for non-drop fields when consuming.**
   In `match (state)` with owned `state`, fields without `drop` (Asset,
   Owner) must be bound explicitly with `_a`, `_o`, etc. so abort can
   consume them via divergence. `{ .. }` works on `&` borrows because
   references have drop, but not on owned non-drop enums.

3. **`abort` is divergent — handles unconsumed non-drop values.** No need
   for helper functions like `consume_aborting_with_payment`. Just
   `abort err_code` directly. Move's checker accepts unconsumed parameters
   because abort is a "never returns" expression.

4. **Module/parameter name shadowing.** `owner_cap: &OwnerCap` parameter
   shadows the `owner_cap` module. To call `owner_cap::escrow_id(cap)`
   from a function with that parameter, either rename the parameter or
   import `owner_cap::{Self, OwnerCap}` and use a different parameter
   name like `cap`.

5. **`std::mem::replace` does not exist** in Sui Move stdlib. The only
   "swap value through a `&mut`" primitive is `Option::extract` + `fill`,
   implemented internally via `vector::pop_back`/`push_back` (since
   `Option<T>` is `vector<T>` with at most 1 element). This is why
   take/put discipline lives at the Option layer.

### What's done (committed)

- `f84dac1`: `engine_state.move` introduced. Compiles. Untested directly
  (no `engine_state_tests.move` yet). 484/484 existing tests still pass
  because nothing references it.

### What's pending

**Commit A (integration):**
1. Rewrite `escrow_coordinator.move`:
   - `state: Option<LifecycleState<...>>` → `state: Option<EngineState<...>>`
   - Remove `StateReceipt` hot-potato.
   - Remove `take_state` / `put_state` / `read_state` private helpers
     (replaced by direct `option::extract` / `option::fill` and
     `engine_state::lifecycle(...)` for views).
   - Each public entry (`integrate`, `rent`, `retire`, `borrow_asset`,
     `return_asset`, `claim_asset`, `withdraw_earnings`, `burn_tenant_cap`,
     `apply_pending_transitions`) becomes a thin wrapper:
     ```
     let state = escrow.state.extract();
     let (new_state, ...) = engine_state::execute_*(state, ...);
     escrow.state.fill(new_state);
     ```
   - Delete the now-duplicate `do_*` handlers, APT, `fire`, `next_pending`,
     `floor_price_at`, `used_credit_at`, `split_fee`, the 11 moved events,
     and PROTOCOL_FEE_BPS / BPS_PER_UNIT constants.
   - Keep `AssetIntegrated`, `AssetClaimed` events.
   - Keep all ~60 view functions but rewrite them to delegate via
     `engine_state::*` accessors instead of reading lifecycle directly.
   - Keep test_only helpers but rewrite to use engine_state's
     drive_to_*_for_testing where appropriate.

2. Update test imports: events that moved (`HandoverCompleted`,
   `RentStarted`, etc.) need import path change from
   `escrow_coordinator::HandoverCompleted` to
   `engine_state::HandoverCompleted`. ~990 usages of `escrow_coordinator::`
   in test file, but only ~30-40 are event types — the rest are entry
   functions that stay in escrow_coordinator (later renamed to escrow).

3. Verify all 484 tests still pass.

**Commit B (rename — mechanical):**
- File: `escrow_coordinator.move` → `escrow.move`
- Module: `usufruct::escrow_coordinator` → `usufruct::escrow`
- Struct: `EscrowCoordinator` → `Escrow`
- Test file: `escrow_coordinator_tests.move` → `escrow_tests.move`
- Bulk replace all `escrow_coordinator::` → `escrow::` in tests.
- Bulk replace all `EscrowCoordinator` → `Escrow` in tests.

### Open complexity to watch during integration

- **Borrowing rules in entries.** `escrow.state.extract()` consumes from
  `&mut escrow.state`. The engine call passes `state` by value plus
  references like `&mut escrow.owner`, `&escrow.config`. With Move 2024 NLL
  and field-level borrows this should work, but capture immutable bits
  (escrow_id, fee_inbox_id) BEFORE the field-level mutable borrows to
  avoid whole-struct borrow conflicts.

- **Owner field migration.** Currently `owner: Owner<CoinType>` lives on
  `EscrowCoordinator`. In the new design, owner moves *into* `EngineState`
  (both Active and Inactive variants). This means `Escrow` no longer has
  a top-level `owner` field — it's accessed via `engine_state::owner_balance(...)`
  for the public view, and consumed at decompose time during `claim_asset`.

- **`config` migration.** Same — moves into Active variant of EngineState.
  Views that read config (`min_rent_price`, `tenure_ceiling_ms`, policy
  predicates, `credit_curve`, `descent_curve`, `ascending_price_function`,
  `dutch_auction_ceiling_ms`, `handover_countdown_floor_ms`,
  `retire_floor_ms`, `integration_config`, `fee_inbox_id`) read from
  EngineState's Active variant via `engine_state::config(&state)` accessor.

- **`integrate` flow.** Constructor now calls `engine_state::new(...)`
  passing asset + config + fee_inbox_id + owner_cap_id + integrated_at_ms +
  escrow_id. Returns EngineState (Active). Wraps in `Some(...)` and stores
  in `Escrow.state`. `AssetIntegrated` event fires from escrow.move (not
  engine_state) since it's the escrow object's birth event.

- **`claim_asset` flow.** Consumes the Escrow by value. Calls
  `engine_state::apply_pending_transitions(...)` first (might transition
  Active → Inactive if a retiring tenure expires). Then asserts state is
  Inactive (`engine_state::is_inactive(&state)`). Then calls
  `engine_state::unwrap_for_claim(state, &owner_cap, ctx)` which destructures
  Inactive and returns `(Asset, Coin<CoinType>)`. Escrow.move emits
  `AssetClaimed`, burns owner_cap, deletes UID.

## Idea 3 — DEFERRED (experiment)

Multi-tenure as a `TenurePolicy::{UniTenure, MultiTenure { ceiling }}`.
Stress-test of the architecture's malleability when adding a new policy
dimension. Treated as an exploration experiment with kill criterion: if
forces if-special-cases or breaks abstractions, abort and document
findings. Should NOT be tackled until Idea 2 is fully landed.

Design agreed on:
- `Tenant<C>` carries `(stake: Balance<C>, n_tenures: u64)`. `per_tenure_stake`
  is computed (`stake.value() / n_tenures`), never stored.
- Used credit prorates over `N × tenure_ceiling`.
- Refund at supersede/expiry: `total_stake - used_credit_at(t)`.
- Lockeo 1..n-1: `handover_countdown_expiry = max(bid_time + floor, start_of_n_th)`,
  clamped to horizon end.
- Floor is per-tenure: `compute_floor_price` returns per-tenure value;
  K-bidder pays total `≥ K × floor`.
- Bid superseding during 1..n-1 follows existing `BidPlaced`/`BidSuperseded`
  mechanics (refund displaced bidder fully, no effect on incumbent).
- Correctness criterion: under `n_tenures = 1`, every formula collapses
  to the current uni-tenure code — zero special cases.
- Pure exploration. User explicitly stated: not driven by a real
  application demand. Goal is to validate that the architecture doesn't
  resist generalization.

## How to resume

If picking up cold:
1. Read this file + `usufruct/sources/engine_state.move` to understand
   the engine module structure.
2. Read `usufruct/sources/escrow_coordinator.move` (current ~1900 LOC) to
   see what needs to be cut/replaced.
3. Read `usufruct/sources/lifecycle_state.move` for the canonical pattern
   that engine_state mirrors (value-typed transitions, no Option wrapping).
4. Start Commit A: rewrite escrow_coordinator's struct + entries.
5. Watch for the Move 2024 gotchas listed above.

If picking up warm: jump straight to refactoring `escrow_coordinator.move`.
The engine_state module is ready to be consumed.

## Memory references (auto-memory in `~/.claude/projects/.../memory/`)

Relevant entries from past sessions that informed this work:
- `feedback_emit_after_semantic.md` — events emit-last after the semantic
  operation completes.
- `feedback_events_self_describing.md` — events form a SQL star schema on
  `escrow_id`.
- `feedback_entity_identity_material_pattern.md` — Entity = Identity + Material.
- `feedback_layer_ownership_grep_invariant.md` — when a layer owns a
  domain, the invariant is a single grep.
- `feedback_no_coauthor_commits.md` — no Co-Authored-By trailer.
- `project_compiler_safety_analysis.md` — functional style as auditor
  replacement.
