# Extracted Comments

Source: usufruct/sources/*.move  |  Phase 2 purge scratch

---

## asset.move

<!-- line 16 -->
```
/// Composite identity of an asset within the protocol. Pairs the asset's
/// own UID with the escrow that holds it. Used by `AssetReceipt` in
/// `asset_state` to verify returns against the issuing borrow.
```

<!-- line 24 -->
```
/// Wrapper around an external `U` during active tenancy (Occupied / Demand).
/// `available` is `Some` when the asset is in escrow custody and `None`
/// while it is on loan to the tenant. `asset_id` is stamped at wrap-time
/// so projectors can identify the asset even while the slot is empty.
```

<!-- line 33 -->
```
/// Wrapper around an external `U` while no tenancy is active (Idle, AtDutch,
/// Retired). No borrow protocol — the asset is simply held in custody.
/// Distinct from `AssetCustodyOpen` so that `WaitingContext` fields are a
/// concrete named type (`TypeInner::Apply`) rather than a raw type parameter,
/// enabling deep nested match patterns without hitting the compiler limitation
/// described in BUG_REPORT.md.
```

<!-- line 51 -->
```
// ### RUNTIME PROJECTION FOR SDK ###
```

<!-- line 70 -->
```
/// Wrap a `U` for borrow-capable custody. Called when entering Renting state.
```

<!-- line 75 -->
```
/// Wrap a `U` for locked custody (no borrow protocol). Called when entering
/// Waiting state (Idle, AtDutch, Retired).
```

<!-- line 81 -->
```
/// Unwrap a locked custody, returning the raw `U`. Called when transitioning
/// from Waiting to Renting (before `new` wraps it as open custody).
```

<!-- line 88 -->
```
/// Borrow path: extract the inner `U`. The slot is left `None`. The caller
/// (`asset_state::execute_borrow`) is responsible for minting the `AssetReceipt`
/// hot-potato — receipt creation is a protocol concern, not a custody concern.
```

<!-- line 95 -->
```
/// Return path: refill the slot. All receipt verification is the caller's
/// responsibility (`asset_state::execute_return`) — the custody module
/// only performs the mechanical fill.
```

<!-- line 102 -->
```
/// Unwrap an open custody asset, returning the raw `U`. Purely mechanical —
/// callers in `asset_state` are responsible for asserting availability
/// before calling this.
```

<!-- line 110 -->
```
/// Renting → Waiting: tenure has ended. Encapsulates `unbundle + lock` so
/// callers express the domain transition in one step. The `unbundle` assert
/// is preserved (aborts if asset is still on loan).
```

<!-- line 117 -->
```
/// Waiting → Renting: a new tenancy is starting. Encapsulates `unlock + new`
/// so callers express the domain transition in one step.
```

## asset_state.move

<!-- line 4 -->
```
/// Lifecycle FSM for an integrated escrow.
///
/// `AssetState` is a 5-variant enum (`Idle` / `AtDutch` / `Retired` /
/// `Occupied` / `Demand`) carrying exactly the fields each state needs —
/// "make illegal states unrepresentable" at the storage layer. `EscrowCore`
/// holds everything orthogonal to the lifecycle: owner ledger, policies,
/// identities, integration metadata. Together they form the on-disk shape
/// of a shared `Escrow`.
///
/// `RentingState` narrows `AssetState` to the `Occupied | Demand` subset
/// where borrowing is valid. It travels inside `AssetReceipt` between
/// `execute_borrow` and `execute_return`, so the compiler can guarantee
/// the return match is exhaustive — no `_ => abort` needed.
/// The non-drop fields (`Tenant<C>`, `AssetCustody*`) give hot-potato
/// discipline for free — no separate operation-time enum is needed.
///
/// All nested enum types must co-reside: Move 2024 restricts pattern
/// access to the defining module.
```

<!-- line 84 -->
```
/// Proof of borrow — hot-potato, no abilities. Minted by `execute_borrow`
/// and consumed by `execute_return`. Carries:
///   · `identity`  — escrow + asset IDs for cross-object verification
///   · `renting`   — the `Occupied | Demand` state extracted from the escrow,
///                   so `execute_return` is exhaustively typed; no `_ => abort`.
/// Receipt creation and verification are protocol concerns; `asset.move`
/// (pure custody) is unaware of them.
```

<!-- line 96 -->
```
/// Result of splitting a credit amount into owner earnings and protocol fee.
/// Named fields prevent positional swap between the two semantically distinct
/// monetary roles.
```

<!-- line 104 -->
```
/// The 4 resolved parameters drawn at Idle entry. Travel as an immutable
/// unit through the cycle until the next Idle entry re-draws them.
```

<!-- line 113 -->
```
/// Scheduled time allocation for the active tenancy.
/// ceiling_total and handover_total are cycle.ceiling/handover × committed_cycles.
```

<!-- line 122 -->
```
/// Handover window terms for a pending bid.
```

<!-- line 128 -->
```
/// Dutch-auction context: the price the last tenant paid and when the
/// auction started. Together they drive the descending price curve and
/// the expiry boundary.
```

<!-- line 136 -->
```
/// Active integration config plus any pending replacement scheduled for
/// the next Idle entry. Pending is applied and cleared in do_auction_expiry.
```

<!-- line 143 -->
```
/// Commitment policy bound to its anchor timestamp. Both fields are
/// required to evaluate whether the commitment floor has elapsed.
```

<!-- line 150 -->
```
/// Active tenancy data: who is renting, on what schedule, and whether retire is pending.
/// Exists only when there is an active tenant (Occupied / Demand states).
```

<!-- line 158 -->
```
/// Pending bid data: who is bidding and when they take over.
```

<!-- line 175 -->
```
/// The `Occupied | Demand` slice of `AssetState`. Travels inside
/// `AssetReceipt` so that `execute_return` can match exhaustively —
/// no `_ => abort` is needed. Hot-potato-like: no abilities.
```

<!-- line 239 -->
```
/// Boundary lifecycle events: `AssetIntegrated` marks Bootstrap → Idle
/// (one-shot, fired by `execute_integrate`); `AssetClaimed` marks
/// Retired → Destroyed (terminal, fired by `execute_claim`'s Retired
/// arm). They bracket the on-chain lifetime of the shared `Escrow`
/// object.
```

<!-- line 542 -->
```
/// Returns the total (scaled) ceiling duration for the active tenancy.
```

<!-- line 553 -->
```
/// Returns the total (scaled) handover duration for the active tenancy.
```

<!-- line 705 -->
```
/// Typed settlement for a handover boundary: (remaining_credit, owner_share, protocol_fee).
```

<!-- line 721 -->
```
/// Typed settlement for a tenure expiry: (owner_share, protocol_fee).
```

<!-- line 760 -->
```
/// Read-only peek: does the on-disk state have a transition due at `now`?
/// Idle and Retired never produce a pending — they sit outside the APT
/// machinery by construction. Used for the SDK view in escrow.move which
/// only borrows the state.
```

<!-- line 801 -->
```
/// Bootstrap → Idle: the integration action. Mints the `OwnerCap`,
/// builds the two on-disk slots (`EscrowCore` + `AssetState::Idle`),
/// resolves the initial policy values, and emits both
/// `IntegrationConfigRegistered` and `AssetIntegrated`. The caller
/// (`escrow::integrate`) is left with the Sui-imposed boundary: create
/// the `UID`, wrap the slots in the `Escrow` struct, and share it.
```

<!-- line 850 -->
```
/// Applies every APT transition whose boundary has been crossed,
/// following the fixed acyclic chain:
///
///   Demand → Occupied → AtDutch | Retired → Idle
///
/// Each step fires at most once; at most three transitions execute per
/// call. Termination is structural: the chain has no cycles and each
/// step recognises only its own source variant, passing all others
/// through unchanged.
```

<!-- line 872 -->
```
/// Entry-point dispatcher for rent. Five arms, all reachable from the
/// public API:
///   · Retired → abort `ERetiredNoBid` (was structurally unreachable in
///     the legacy form because `floor_price_at` aborted first; now floor
///     is computed per-arm and the abort is the genuine consequence of
///     calling rent on a retired escrow).
///   · Idle    → install (`do_install`) → Occupied.
///   · AtDutch → install (`do_install`) → Occupied. Floor is the
///     descending Dutch price at `now`.
///   · Occupied → place bid (`do_place_bid`) → Demand. Aborts
///     `ERetireFlagBlocksBid` if the tenancy is flagged for retirement.
///   · Demand   → supersede bid (`do_supersede_bid`) → Demand. Mutates
///     `core.owner` to distribute the displaced bidder's refund.
///
/// Cycle validation against the integration config is the first check —
/// it does not depend on lifecycle state.
```

<!-- line 936 -->
```
/// Entry-point dispatcher for retire. Five arms, all reachable from the
/// public API:
///   · Retired  → abort `EAlreadyRetired`.
///   · Idle     → `do_retire_immediately` on the locked custody → Retired.
///   · AtDutch  → `do_retire_immediately` on the locked custody → Retired.
///                The descending-auction parameters are dropped — they
///                belong to a tenancy cycle that ends with this action.
///   · Occupied → set retiring flag → Occupied. The asset can still be
///                borrowed/returned during the grace period; the flag
///                prevents new bids and triggers Retired at the next
///                tenure expiry.
///   · Demand   → set retiring flag → Demand. Same semantics; the
///                active handover countdown is unaffected.
///
/// Owner-cap binding is checked first. The commitment policy must be
/// unlocked (`ECommitmentFloorNotElapsed`) regardless of state — it is a
/// property of the owner's permanence commitment, not the lifecycle.
///
/// `pending_config` is cleared unconditionally: any scheduled config
/// change is abandoned by the decision to retire.
```

<!-- line 991 -->
```
/// Entry-point dispatcher for update_config. Five arms, all reachable
/// from the public API:
///   · Retired  → abort `EAlreadyRetired`.
///   · Idle     → apply the new config immediately: re-resolve floor /
///                ceiling / handover with fresh randomness and replace
///                the Idle resolutions. Emits `ConfigUpdated`.
///   · AtDutch  → schedule the new config (`pending_config`); the
///                descending auction in flight is allowed to complete
///                under the old parameters. Emits `ConfigUpdateScheduled`.
///   · Occupied → schedule the new config. Aborts
///                `ERetireAlreadyScheduled` if the retire flag is set —
///                a pending retire takes precedence over a pending
///                config change.
///   · Demand   → schedule the new config. Same retire-flag guard.
///
/// `random` is only consumed in the Idle arm (the only place that
/// re-resolves policy values immediately).
```

<!-- line 1053 -->
```
/// Tenant-gated asset borrow. Auth and action fused into a single match:
/// each renting arm authorizes via `assert_borrow_authorized` then takes
/// the asset. The `_s` arm covers Idle / AtDutch / Retired — states that
/// carry no open custody and therefore have no cap to match.
/// Extract the `RentingState` into the receipt so `execute_return`
/// can match exhaustively. `escrow.state` is left `None` by the
/// caller (`escrow::borrow_asset`) until `execute_return` fills it back;
/// the gap is invisible to external observers because borrow+return are
/// atomic within a single PTB.
```

<!-- line 1107 -->
```
/// Reconstruct `AssetState` from the receipt's `RentingState`. The match
/// is exhaustive — no `_ => abort`. The compiler guarantees that if the
/// caller holds an `AssetReceipt<Asset, CoinType>`, the renting state is
/// either `Occupied` or `Demand`; no other branch is representable.
```

<!-- line 1144 -->
```
/// Entry-point dispatcher for burning a stale TenantCap (gas recovery).
///
/// Two invariants are enforced together — neither alone is sufficient:
///
///   1. The cap must have been issued by THIS escrow
///      (`EWrongEscrowTenantCap`). Without this guard, a Retired escrow
///      could be used as a "burn machine" for caps issued by other
///      escrows, including caps that are still `current`/`pending`
///      there — silently breaking invariant 2 on a foreign escrow.
///
///   2. The cap must not be `current` or `pending` of an active tenancy
///      (`ETenantCapNotStale`). Only stale caps may be burned, so that
///      live tenancy references are never destroyed.
///
/// In Idle/AtDutch/Retired the second guard is satisfied structurally —
/// Tenant-cap gas-recovery burn. Active caps (current or pending) abort
/// `ETenantCapNotStale`; stale caps burn unconditionally.
```

<!-- line 1188 -->
```
/// Owner-gated earnings withdrawal. Operates on the core handoff
/// (owner + envelope) — orthogonal to the lifecycle state, so no
/// dispatch match is needed. The caller is responsible for routing
/// `core` from the dispatch boundary.
```

<!-- line 1210 -->
```
/// Extend the owner's permanence commitment. The new expiry must be ≥ the
/// current expiry — the commitment can only grow, never shrink.
///
/// Operates on the core handoff: commitment_policy + commitment_anchor
/// live in the envelope, orthogonal to the lifecycle state.
```

<!-- line 1245 -->
```
/// Retired → Destroyed: the terminal claim action. The Retired arm
/// unwraps the locked asset and the swept owner earnings, emits
/// `AssetClaimed`, and returns. The other four arms abort `ENotRetired`
/// after consuming the hot-potatoes inline — the abort is reachable
/// from the public API (caller invoked claim while the escrow was in
/// the wrong lifecycle state) and is what `expected_failure` tests
/// exercise.
///
/// Lives here (not in escrow.move) because Move 2024 restricts pattern
/// access to the defining module — the wrong-state arms have to
/// destructure `AssetState` and `EscrowCore` before aborting, and that
/// destructure must happen inside this module.
```

<!-- line 1322 -->
```
/// `pending` distinguishes a pending-bidder cap (EPendingTenantCap) from
/// any other non-matching cap (EStaleTenantCap).
```

<!-- line 1334 -->
```
/// Two independent receipt checks — two distinct attacks:
///   1. cross-escrow:  receipt issued by escrow A, presented to escrow B
///   2. asset-swap:    correct receipt but a different physical object returned
```

<!-- line 1355 -->
```
/// Demand → Occupied: fire the handover transition at `boundary_ms`.
/// Distributes used credit to owner; retiring flag propagates to new Occupied.
```

<!-- line 1427 -->
```
/// Consume an Occupied tenancy at tenure expiry. Distributes full stake
/// to owner/protocol and decides the outcome from the retire condition:
///   · flag set   → `Retired` (the locked asset is all the caller needs).
///   · flag unset → `AtDutch` (cycle params carried unchanged; no rescaling
///     needed since cycle.ceiling/handover are already per-cycle base values).
```

<!-- line 1482 -->
```
/// Occupied → Demand.
```

<!-- line 1531 -->
```
/// Demand → Demand: displace the existing pending bidder.
```

<!-- line 1607 -->
```
/// Step 1 of 3: Demand → Occupied if the handover countdown has elapsed.
/// Every other variant passes through unchanged.
```

<!-- line 1633 -->
```
/// Step 2 of 3: Occupied → AtDutch | Retired if the tenure ceiling has elapsed.
/// Every other variant passes through unchanged.
```

<!-- line 1658 -->
```
/// Step 3 of 3: AtDutch → Idle if the descent window has elapsed.
/// Every other variant passes through unchanged.
```

<!-- line 1730 -->
```
/// AtDutch → Idle. The lifecycle invariant says all `resolved_*` are
/// drawn at Idle entry; this is the auction-expiry instance of that
/// rule. If `pending_config` was scheduled during the previous cycle it
/// is applied now (emit `ConfigUpdated` → assign → clear) BEFORE the
/// four resolves, so the new Idle reflects the new config.
```

<!-- line 1908 -->
```
            // tenant_in is consumed only on the happy path; the abort arms
            // below leave it to drop with the divergent abort.
```

<!-- line 2009 -->
```
/// Test-only accessors: the four cycle-resident `resolved_*` values
/// read from any non-Retired variant. The SDK views deliberately
/// expose only the phase-appropriate readings (e.g.
/// `proj_waiting_resolved_descent` returns Some only on Idle/AtDutch —
/// the auction-descent semantic); these helpers exist so invariant
/// tests can verify the four flow unchanged through Occupied/Demand.
/// In Occupied/Demand the ceiling/handover values are read from
/// `cycle` (per-cycle base). Tests that compare across Idle ↔ Renting
/// use `cycles::cycles(1)` so the scaled total equals the base.
```

## commitment_policy_state.move

<!-- line 38 -->
```
// ### RUNTIME PROJECTION FOR SDK ###
```

<!-- line 57 -->
```
/// Resolve the policy to a concrete Duration (the unlock floor).
///   Immediate → Duration(0)    available from integration time
///   Deferred  → floor          available at anchor + floor
```

<!-- line 67 -->
```
/// Absolute timestamp at which `retire()` becomes available.
```

<!-- line 72 -->
```
/// Whether `retire()` may proceed.
```

## config.move

<!-- line 21 -->
```
  [const EHandoverFloorExceedsTenure: u64 = 2;]  // Countdown.floor_ms >= tenure_ceiling
```

<!-- line 59 -->
```
    // Cross-field validation: Countdown.floor_ms < tenure_ceiling.
    // Equality is the FixedTime variant. Intra-variant invariants
    // (e.g. floor_ms > 0) are owned by the policy module's
    // constructors. The variant-level check is encapsulated in
    // `handover_policy_state::countdown_floor_lt` since pattern-matching
    // on an enum variant is restricted to the defining module.
```

<!-- line 83 -->
```
// ### RUNTIME PROJECTION FOR SDK ###
```

## credit_context_state.move

<!-- line 21 -->
```
/// Variant-specific data for the credit sub-machine.
/// Shared fields (stake, phase_start_ms) live in CreditContext.
```

<!-- line 28 -->
```
/// Context-State carrier for credit consumption.
///
///   · `Accruing` — Occupied: credit accumulates freely against
///                  `credit_curve` over the full tenure window.
///   · `Capped`   — Demand: accrual freezes at `expiry`;
///                  the remainder stays with the departing tenant.
///
/// Derived by the coordinator from `LifecycleState` accessors; never
/// stored inside `TenantState` or `LifecycleState`.
```

<!-- line 51 -->
```
// ### RUNTIME PROJECTION FOR SDK ###
```

<!-- line 75 -->
```
/// Construct `Accruing` — Occupied, no countdown in progress.
```

<!-- line 80 -->
```
/// Construct `Capped` — Demand, credit freezes at `expiry`.
```

<!-- line 85 -->
```
/// Credit consumed from the tenant's stake up to `now`.
///
/// Both variants evaluate `credit_curve(elapsed / tenure_ceiling)`
/// scaled by `stake`; they differ only in the effective timestamp:
/// `Accruing` uses `now` directly, `Capped` saturates at `expiry`
/// so accrual freezes when the countdown boundary passes.
///
/// Returns 0 when elapsed == 0; returns `stake` when elapsed >=
/// `tenure_ceiling` (curve short-circuit at SCALE).
```

<!-- line 107 -->
```
  [phases::duration_ms(elapsed),]  // ← temporal → math domain
```

<!-- line 108 -->
```
  [phases::duration_ms(resolved_ceiling),]  // ← temporal → math domain
```

## curve_shape_state.move

<!-- line 29 -->
```
// Algorithm-derived (§9). Pinned via the bootstrap procedure documented in the
// `bootstrap_constants_match_pinned` regression test in `curve_shape_state_tests`:
// run `exp_scaled_pos` over the inputs the spec specifies, fix the outputs as
// these literals. Re-derive whenever §7 (Taylor K, rounding) changes.
```

<!-- line 36 -->
```
// Algorithm-derived (§8). Pinned via the same bootstrap as LOGISTIC_DENOM:
// EXP_A_NORM_{a}_POS = exp_scaled(a, 1, false) − TAYLOR_SCALE
// EXP_A_NORM_{a}_NEG = TAYLOR_SCALE − exp_scaled(a, 1, true)
// Re-derive whenever §7 changes; the regression test in curve_shape_state_tests
// guards against silent drift.
```

<!-- line 60 -->
```
/// A normalized curve output in `[0, SCALE]`.
/// Only constructable by `evaluate_curve` — callers receive it and apply
/// it to an amount via `apply`, never manipulate the raw value directly.
```

<!-- line 109 -->
```
// ### RUNTIME PROJECTION FOR SDK ###
```

<!-- line 134 -->
```
/// Raw `u64` value of a `CurveHeight`. For SDK projection and test
/// assertions — domain code should use `apply` instead.
```

<!-- line 138 -->
```
/// Evaluate the curve at progress `t` out of `t_max`.
/// Returns a `CurveHeight` in `[0, SCALE]`.
/// `t` and `t_max` are generic progress values (e.g. elapsed ms and
/// window ceiling ms) — this module does not know their domain.
```

<!-- line 155 -->
```
/// Apply a curve height to an amount: `amount × h / SCALE`.
/// This is the only correct way to use a `CurveHeight` against a value —
/// it keeps the SCALE denominator encapsulated here where it belongs.
```

<!-- line 223 -->
```
// Taylor series for e^(y_num/y_den) · TAYLOR_SCALE, K=32 terms.
// Caller guarantees y_den > 0; division by zero would otherwise abort.
```

<!-- line 240 -->
```
// Pure dispatcher over the 16 EXP_A_NORM_{1..8}_{POS,NEG} module constants.
```

<!-- line 266 -->
```
// Iterative Euclidean gcd. Move has no recursion.
```

<!-- line 335 -->
```
// Destructure helper for new_power_law tests — only way to verify gcd
// normalization without leaking enum field access publicly.
```

## cycles.move

<!-- line 33 -->
```
/// Extractor — SDK boundary only.
```

<!-- line 44 -->
```
/// Total payment required: floor_price × cycles.
```

<!-- line 49 -->
```
/// Per-cycle stake rate: total_stake / cycles.
/// Used by floor_price_at_for_tenancy — the market competes on rate, not total.
```

<!-- line 55 -->
```
/// Scale a Duration by cycles — analogous to total_price.
/// do_install: extended = base × cycles.
```

<!-- line 61 -->
```
/// Re-scale a Duration from one cycle count to another.
/// do_handover: new = old × (bidding / committed), via mul_div for precision.
```

## descent_policy_state.move

<!-- line 51 -->
```
// ### RUNTIME PROJECTION FOR SDK ###
```

<!-- line 85 -->
```
/// Resolve the policy to a concrete Duration (the descent window).
///   Skipped         → Duration(0)      collapses immediately at phase_start
///   Window          → ceiling          collapses at phase_start + ceiling
///   RandomInRange   → draw[min, max]   collapses at phase_start + draw
```

<!-- line 99 -->
```
/// Whether the descent window has expired — called with the resolved window Duration.
```

<!-- line 108 -->
```
/// Canonical auction-collapse boundary — called with the resolved window Duration.
```

<!-- line 126 -->
```
/// Width of the descent window. Aborts on Skipped and RandomInRange —
/// only valid for the Window variant. Test-only; production uses
/// `proj_window_ceiling` which returns `Option<Duration>` instead.
```

## escrow.move

<!-- line 50 -->
```
/// Central shared object. One per integrated asset.
///
/// Storage is split into two `Option` slots:
///   · `core`  — owner ledger + protocol envelope, orthogonal to lifecycle
///     state. Ortho actions (withdraw_earnings, extend_commitment) only
///     touch this slot.
///   · `state` — the lifecycle-state variant (Idle / AtDutch / Retired /
///     Occupied / Demand). APT and state transitions consume only this
///     slot.
///
/// The two `Option`s let entry functions extract `state` by value (for
/// the `execute_*` call) while keeping a `&mut` borrow into `core` —
/// physically disjoint borrows that the type system enforces.
```

<!-- line 71 -->
```
/// Create and share an `Escrow`. Mints the `OwnerCap` and returns it to
/// the caller. The lifecycle work (resolving policy values, building the
/// core, minting the cap, emitting events) lives in
/// `asset_state::execute_integrate`; this entry only handles the Sui
/// boundary that the `Escrow`-defining module must own: minting the
/// `UID` and sharing the wrapping struct.
```

<!-- line 104 -->
```
/// Owner-gated earnings withdrawal.
```

<!-- line 119 -->
```
/// Owner-gated terminal claim. Consumes the escrow by value. The
/// lifecycle work (APT settle, asset unlock, earnings withdrawal,
/// `AssetClaimed` emission) lives in `asset_state::execute_claim`; this
/// entry only handles the Sui boundary: unwrapping the `Escrow`,
/// burning the `OwnerCap`, deleting the `UID`.
```

<!-- line 139 -->
```
/// Owner-gated retire entry.
```

<!-- line 153 -->
```
/// Owner-gated commitment extension. New expiry must be ≥ current expiry.
```

<!-- line 163 -->
```
/// Owner-gated operational parameter reset.
```

<!-- line 178 -->
```
/// Single entry point to become tenant or place a bid.
```

<!-- line 194 -->
```
/// Tenant-side asset borrow.
///
/// `escrow.state` is left `None` after this call — the `RentingState`
/// travels inside the returned `AssetReceipt` until `return_asset` puts
/// it back. The gap is invisible to external observers: borrow + return
/// are atomic within a single PTB (hot-potato discipline).
```

<!-- line 212 -->
```
/// Tenant-side asset return. Reconstructs `AssetState` from the receipt's
/// `RentingState` and fills `escrow.state` back to `Some`.
```

<!-- line 224 -->
```
/// Checked burn: cap must belong to this escrow and must be stale (not
/// current or pending). Use for gas recovery while the escrow still exists.
```

<!-- line 239 -->
```
/// Unconditional burn. No escrow needed — use for gas recovery after
/// `claim_asset` destroys the escrow, leaving caps orphaned.
```

<!-- line 245 -->
```
/// Permissionless settler.
```

<!-- line 258 -->
```
/// Detect the single transition that is due at `now`, if any.
```

<!-- line 268 -->
```
// ─── State predicates ────────────────────────────────────────────────────────
```

<!-- line 360 -->
```
// ─── Identity views ──────────────────────────────────────────────────────────
```

<!-- line 410 -->
```
// ─── Stake views ─────────────────────────────────────────────────────────────
```

<!-- line 424 -->
```
// ─── Temporal views ───────────────────────────────────────────────────────────
```

<!-- line 536 -->
```
// ─── Cap views ───────────────────────────────────────────────────────────────
```

<!-- line 567 -->
```
// ─── Timing views ────────────────────────────────────────────────────────────
```

<!-- line 583 -->
```
// ─── Pricing views ───────────────────────────────────────────────────────────
```

<!-- line 626 -->
```
// ─── Credit context views ─────────────────────────────────────────────────────
```

<!-- line 658 -->
```
// ─── Settlement views ────────────────────────────────────────────────────────
```

<!-- line 677 -->
```
// ─── Earnings views ──────────────────────────────────────────────────────────
```

<!-- line 685 -->
```
// ─── Config views ────────────────────────────────────────────────────────────
```

<!-- line 750 -->
```
// ─── Tenure policy views ──────────────────────────────────────────────────────
```

<!-- line 772 -->
```
// ─── Floor price policy views ─────────────────────────────────────────────────
```

<!-- line 794 -->
```
// ─── Credit curve views ───────────────────────────────────────────────────────
```

<!-- line 832 -->
```
// ─── Descent curve views ──────────────────────────────────────────────────────
```

<!-- line 870 -->
```
// ─── Price function views ─────────────────────────────────────────────────────
```

<!-- line 898 -->
```
/// Extract the lifecycle state for mutation. Aborts `EAssetBorrowed`
/// if the state is `None` (i.e. the asset is currently on loan), giving a
/// meaningful error instead of an opaque `EOPTION_NOT_SET` abort.
```

<!-- line 915 -->
```
/// Borrow the lifecycle state for reading. Same guard as `take_state`.
```

## escrow_identity.move

<!-- line 4 -->
```
/// Typed identity of an `Escrow` on-chain object.
///
/// Wraps the raw `ID` so the compiler distinguishes it from
/// `protocol_fee_ref::FeeInboxIdentity` — making it impossible to route an
/// `EscrowIdentity` to `fee_message::post` or vice versa.
///
/// Lives in its own leaf module (no usufruct imports) so any module in
/// the package can import it without creating dependency cycles.
```

<!-- line 38 -->
```
/// Construct an `EscrowIdentity` from the raw `ID` of an `Escrow` object.
```

<!-- line 41 -->
```
/// Extract the raw `ID` from an `EscrowIdentity`.
```

## fee_message.move

<!-- line 27 -->
```
/// Pre-message wrapper carrying the balance + escrow identity for a
/// fee transfer. Constructed by the producer (e.g. tenant draining a
/// fee share off its stake) and consumed by `post`, which mints the
/// on-chain `FeeMessage<C>` object and ships it to the inbox. The
/// share never reaches on-chain storage — it lives only in PTB scope
/// between the split site and the post site.
```

<!-- line 65 -->
```
/// Pipeline of receive + consume over all tickets for one CoinType. Returns a
/// single `Coin<C>` accumulating all drained balances.
```

<!-- line 84 -->
```
// ### RUNTIME PROJECTION FOR SDK ###
```

<!-- line 94 -->
```
/// Construct a `FeeShare<C>` carrying `balance` destined for the fee
/// flow of `escrow_identity`. Pre-message form — no UID minted yet; the
/// on-chain `FeeMessage<C>` is built inside `post`.
```

<!-- line 101 -->
```
/// Mint a `FeeMessage<C>` from `share`, transfer it to the inbox via
/// transfer-to-object, and emit `FeeMessageSent<C>`. Fused — no
/// caller ever holds a `FeeMessage<C>` as a local.
```

<!-- line 166 -->
```
// FeeShare field accessors (struct fields are module-private)
```

<!-- line 175 -->
```
// FeeMessageSent field accessors (struct fields are module-private)
```

<!-- line 185 -->
```
// FeeMessageCollected field accessors
```

## floor_price_policy_state.move

<!-- line 47 -->
```
// ### RUNTIME PROJECTION FOR SDK ###
```

<!-- line 82 -->
```
/// Returns the floor price for SDK views and Dutch auction descent bottom.
/// Fixed: the fixed price. RandomInRange: the minimum of the range (conservative).
```

<!-- line 91 -->
```
/// Resolves the policy to a concrete Price.
/// Fixed: returns the fixed price (generator unused).
/// RandomInRange: draws uniformly from [min, max].
```

## handover_policy_state.move

<!-- line 52 -->
```
// ### RUNTIME PROJECTION FOR SDK ###
```

<!-- line 89 -->
```
/// Cross-field guard: the maximum possible handover floor must be < tenure ceiling,
/// so the constraint holds for every possible draw.
```

<!-- line 99 -->
```
/// Resolve the policy to a concrete Duration (the effective handover floor).
/// Stored once per Idle cycle in TenancyContext; never re-read from config during a tenancy.
///
///   Instant          → Duration(0)   expiry = min(bid + 0,       ...) = bid_time
///   FixedTime        → ceiling       expiry = min(bid + C, t₀ + C) = t₀ + C
///   Countdown(f)     → f             expiry = min(bid + f, t₀ + C)
///   RandomInRange    → draw[min,max] expiry = min(bid + draw, t₀ + C)
```

<!-- line 124 -->
```
/// Whether the handover countdown has expired — called with the resolved floor
/// drawn at Idle entry. Uniform formula across all policy variants:
///   expiry = min(bid_time + resolved_floor, phase_start + resolved_ceiling)
```

<!-- line 144 -->
```
/// Canonical handover boundary timestamp — called with the resolved floor.
```

## math.move

<!-- line 21 -->
```
/// A rate expressed in basis points (1/10_000 units).
/// Generic mathematical concept — one basis point = 0.01%.
/// Domain modules validate their own invariants before constructing.
```

<!-- line 38 -->
```
/// Construct a `BasisPoints` from a raw value. No range validation —
/// domain modules assert their own invariants before constructing.
```

<!-- line 42 -->
```
/// Raw basis point value — for SDK projection and test assertions.
```

<!-- line 45 -->
```
/// The fixed denominator for all basis point calculations.
```

<!-- line 48 -->
```
/// Apply a basis point rate to an amount: `amount × rate / 10_000`.
```

<!-- line 61 -->
```
    // Overflow analysis covers d ∈ {2,3,4} only; d ≥ 5 silently returns floor(n^(1/4)).
```

<!-- line 87 -->
```
// Number of bits needed to represent x (= floor(log2(x)) + 1 for x >= 1).
// Only called for x >= 2; the +1 at the end is always valid.
```

## monetary.move

<!-- line 18 -->
```
/// A monetary value not yet paid — a reference price, floor, or configured increment.
```

<!-- line 21 -->
```
/// A monetary value already paid — collateral held by a tenant.
/// Semantically distinct from Price: a Stake is a Price that has been actualized.
```

<!-- line 43 -->
```
/// Tenure expiry: the Stake paid by the last tenant becomes the acquisition
/// reference price for the Dutch auction descent.
```

## owner.move

<!-- line 16 -->
```
/// Withdraw was presented a cap whose object id does not match the
/// `cap_identity` recorded in `OwnerIdentity`. Indicates a mis-routed cap
/// or a coding bug at the call site.
```

<!-- line 25 -->
```
/// Identity half of an `Owner`. Single-component because the owner's
/// authority over the escrow is the cap_identity, and the destination of
/// withdrawals is the cap-bearer at withdraw-time (`tx_context::sender`),
/// not a pre-registered address. Asymmetric with `TenantIdentity` — and
/// the asymmetry is structural, not accidental.
```

<!-- line 34 -->
```
/// Material half of an `Owner`. Wraps the accumulated earnings; the
/// same wrapper is also used as the in-transit type when shares flow
/// from a tenant's stake into the owner via `deposit` — collapse of
/// the in-storage and in-flight types, since both are just "balance
/// destined for the owner".
```

<!-- line 43 -->
```
/// Entity = identity + material. Lives at the rental-escrow layer (one
/// per escrow); withdraw is gated by `OwnerCap` matching the bound
/// `cap_identity`. Has no per-owner state machine — orthogonal to the
/// rental lifecycle by design.
```

<!-- line 60 -->
```
// ### RUNTIME PROJECTION FOR SDK ###
```

<!-- line 71 -->
```
/// Construct an `Owner` bound to `cap_identity` with zero earnings. Sole
/// construction site — the cap-layer supplies the cap_identity at escrow
/// creation time.
```

<!-- line 81 -->
```
/// Construct an `OwnerEarnings<C>` carrying `balance`. Used by upstream
/// producers (e.g. `tenant::take_owner_earnings`) that drain a portion
/// of stake destined for the owner.
```

<!-- line 88 -->
```
/// Join an in-transit `OwnerEarnings<C>` into the long-lived earnings
/// of this `Owner`. Symmetric counterpart to `tenant::liquidate` (sends
/// to address) and `fee_message::post` (sends to inbox) — each
/// material-bearing wrapper has its own consumer in its owning module.
```

<!-- line 97 -->
```
/// Drain all earnings as a `Coin<C>`, gated by the matching `OwnerCap`.
/// Aborts if the cap's object id does not match the cap_identity recorded
/// at construction. The earnings field is replaced with a fresh zero
/// balance — `Owner` lives on for further deposits.
```

<!-- line 111 -->
```
/// Tear down an `Owner<C>` known to hold zero earnings. Aborts via
/// `balance::destroy_zero` if the inner balance is non-zero — guards
/// the invariant at the consumption site rather than relying on caller
/// arithmetic. Symmetric with `tenant::destroy_empty_stake`. Used at
/// escrow-deletion time after `withdraw` has drained the earnings.
```

## owner_cap.move

<!-- line 22 -->
```
/// Typed identity of an `OwnerCap` object — wraps its on-chain `ID`.
```

<!-- line 45 -->
```
/// Returns the ID of the `RentalEscrow` this cap authorizes (SDK boundary).
```

<!-- line 54 -->
```
/// Produce a typed `OwnerCapIdentity` from a live cap reference.
```

<!-- line 59 -->
```
/// Extract the raw `ID` from an `OwnerCapIdentity`.
```

<!-- line 62 -->
```
/// Package-internal: return the `EscrowIdentity` this cap is bound to.
```

<!-- line 67 -->
```
/// Mints an `OwnerCap` bound to `escrow_identity`.
```

<!-- line 79 -->
```
/// Destroys `cap` and emits `OwnerCapBurned`.
```

## pending_transition_state.move

<!-- line 16 -->
```
/// Which kind of lazy transition is pending.
/// Unit enum — carries no per-variant data; boundary_ms lives in the
/// Context-State wrapper PendingTransitionState.
```

<!-- line 25 -->
```
/// Lazy transition due at a given timestamp. The coordinator's APT
/// loop separates *detection* (which transition is due, if any) from
/// *firing* (apply the corresponding boundary handler).
///
///   · `Handover` — handover-countdown expired in Demand.
///                  `boundary_ms` is the stored countdown expiry.
///   · `Tenure`   — tenure ceiling elapsed in Occupied.
///                  `boundary_ms` is `phase_start_ms + tenure_ceiling`.
///   · `Auction`  — descent window elapsed in AtDutch.
///                  `boundary_ms` is `descent_policy_state::expiry_at`.
///
/// Constructed by `next_pending_from_tenancy` / `next_pending_from_state`
/// and consumed by `fire`. Not stored — derived from AssetContext on
/// demand. `drop` only; ephemeral derived value.
```

<!-- line 52 -->
```
// ### RUNTIME PROJECTION FOR SDK ###
```

<!-- line 54 -->
```
/// True iff this transition is the handover variant.
```

<!-- line 59 -->
```
/// True iff this transition is the tenure-expiry variant.
```

<!-- line 64 -->
```
/// True iff this transition is the auction-expiry variant.
```

<!-- line 69 -->
```
/// Boundary timestamp the firing handler will stamp on the resulting state and event.
```

<!-- line 78 -->
```
/// Construct a `Handover` pending transition at `boundary`.
```

<!-- line 83 -->
```
/// Construct a `Tenure` pending transition at `boundary`.
```

<!-- line 88 -->
```
/// Construct an `AuctionExpiry` pending transition at `boundary`.
```

## phases.move

<!-- line 17 -->
```
/// An absolute point in time (milliseconds since Unix epoch).
```

<!-- line 20 -->
```
/// A relative span of time (milliseconds offset — never an absolute point).
```

<!-- line 25 -->
```
/// Result of a boundary check.
///
///   · Pending — boundary not yet reached; `remaining` is time left.
///   · Crossed — boundary has been passed; `overdue` is time since crossing.
```

<!-- line 40 -->
```
/// Construct a `Timestamp` representing the current clock time.
```

<!-- line 51 -->
```
/// Construct a `Timestamp` from a stored millisecond value.
```

<!-- line 54 -->
```
/// Construct a `Duration` from a millisecond offset.
```

<!-- line 57 -->
```
/// Zero duration — used for instant boundaries.
```

<!-- line 60 -->
```
/// Raw millisecond value of a `Timestamp`.
```

<!-- line 63 -->
```
/// Raw millisecond value of a `Duration`.
```

<!-- line 66 -->
```
/// True iff the boundary has been crossed.
```

<!-- line 71 -->
```
/// Check whether phase boundary `anchor + d` has been crossed at `now`.
```

<!-- line 81 -->
```
/// Elapsed time since `start`. Saturates to zero if `now` is before `start`.
```

<!-- line 86 -->
```
/// The boundary timestamp `anchor + d`.
```

<!-- line 91 -->
```
/// Earlier of two timestamps.
```

## price_function_state.move

<!-- line 55 -->
```
// ### RUNTIME PROJECTION FOR SDK ###
```

<!-- line 92 -->
```
/// Guards against EMulDivOverflow: mul_div(price, denom + bps, denom) overflows
/// when price = u64::MAX and bps ≥ 1. Upper bound = u64::MAX − BPS_DENOMINATOR.
```

<!-- line 100 -->
```
/// price × (1 + bps/10_000) + delta  =  mul_div(price, 10_000 + bps, 10_000) + delta
///
/// Uses mul_div so that overflow detection happens inside math (EMulDivOverflow) rather
/// than as an arithmetic trap in this module. The overflow site must be in math for the
/// test contract to hold — math::mul_div asserts res ≤ u64::MAX before casting.
```

## price_state.move

<!-- line 23 -->
```
/// Pricing regime of the asset — encodes which function answers
/// "¿cuánto cuesta acceder al asset ahora mismo?".
///
///   · `Rest`       — asset idle; any renter pays `min_rent_price`.
///   · `Ascending`  — asset rented; next bidder pays
///                    `price_function_state(current_stake)` (or pending stake
///                    when a handover is already in progress).
///   · `Descending` — asset in Dutch auction; price falls from
///                    `last_acq_price` toward `min_rent_price` along
///                    `descent_curve` over the descent window.
///
/// Derived by the coordinator from `LifecycleState` accessors; never
/// stored inside `AssetState` or `LifecycleState`.
```

<!-- line 50 -->
```
// ### RUNTIME PROJECTION FOR SDK ###
```

<!-- line 60 -->
```
/// Construct `Rest` — asset idle.
```

<!-- line 63 -->
```
/// Construct `Ascending` — asset rented; `stake` is the amount the
/// current (or pending) tenant paid, used as the base for the next
/// price step.
```

<!-- line 70 -->
```
/// Construct `Descending` — Dutch auction in progress.
/// `last_acq_price` seeds the descent; `phase_start` anchors the temporal decay;
/// `resolved_floor` anchors the descent bottom; `resolved_descent` is the window duration.
```

<!-- line 77 -->
```
/// Floor price a bidder must meet given the current pricing regime.
///
///   · Rest       — `min_rent_price` (config scalar, time-independent)
///   · Ascending  — `price_function_state(stake)` (time-independent)
///   · Descending — price falls from `last_acq_price` to `min_rent_price`
///                  along `descent_curve` over the descent window;
///                  saturates at `min_rent_price` when window elapses.
///
/// `now` is consumed only in the `Descending` branch.
```

<!-- line 102 -->
```
  [phases::duration_ms(elapsed),]  // ← temporal → math domain
```

<!-- line 103 -->
```
  [phases::duration_ms(*resolved_descent),]  // ← temporal → math domain
```

<!-- line 106 -->
```
  [let consumed = curve_shape_state::apply(spread, h);]  // ← monetary → math domain
```

## protocol_fee_inbox.move

<!-- line 32 -->
```
/// Exposes `&mut UID` of `ProtocolFeeInbox` so `fee_message` can call
/// `transfer::receive` against it.
```

## protocol_fee_ref.move

<!-- line 14 -->
```
/// Typed identity of the `ProtocolFeeInbox`.
/// Produced once from `ProtocolFeeRef` at integrate time and carried
/// throughout the fee-distribution path.
```

<!-- line 19 -->
```
/// Immutable pointer to the `ProtocolFeeInbox`. Frozen at deploy time;
/// no fields are ever mutated after creation. Any caller can read it
/// as `&ProtocolFeeRef` to obtain the fee inbox address.
```

<!-- line 35 -->
```
/// Returns the ID of the `ProtocolFeeInbox` this ref points to (SDK boundary).
```

<!-- line 40 -->
```
/// Package-internal: produce a `FeeInboxIdentity` from this ref.
```

<!-- line 45 -->
```
/// Construct a `FeeInboxIdentity` from a raw inbox object `ID`.
```

<!-- line 48 -->
```
/// Extract the raw `ID` from a `FeeInboxIdentity`.
```

<!-- line 55 -->
```
/// Constructs and freezes the ref stamped with `inbox_id`. Called once
/// from `protocol_fee_inbox::init`, which supplies `object::id(&inbox)`.
/// `ProtocolFeeRef` is `key`-only so freeze must happen within this module.
```

## refund_state.move

<!-- line 24 -->
```
/// Transition residue produced by a lifecycle boundary that touches a
/// tenant's stake. Three variants encode the legal distribution shapes
/// of the departing tenant's funds:
///
///   · `Nothing`  — full stake consumed by owner+fee; tenant receives
///                   nothing back. No identity: there is no recipient,
///                   so carrying one would be a lie.
///   · `Parcial`  — stake split: owner + fee + remainder refunded to
///                   the tenant. Carries `identity` — the remainder has
///                   a recipient and the type must name them.
///   · `Total`    — full stake refunded to the tenant; no owner share,
///                   no fee. Carries `identity` — same reason as Parcial.
///
/// Hot potato: no abilities. Must be consumed in the same PTB it is
/// produced — by a `match` at the boundary, never stored. This makes
/// the legal-distribution shape unforgettable at the type level: a
/// caller cannot accidentally drop fees, lose a refund, or forget to
/// route the owner's share, because the enum cannot be discarded.
```

<!-- line 67 -->
```
// ### RUNTIME PROJECTION FOR SDK ###
```

<!-- line 83 -->
```
/// Construct `Nothing` — fee and owner shares routed to their consumers;
/// no remainder, no recipient.
```

<!-- line 92 -->
```
/// Construct `Parcial` — three-way split. The carried `stake` holds
/// the remainder destined for the tenant via `tenant::liquidate`.
```

<!-- line 103 -->
```
/// Construct `Total` — full stake returns to the tenant; no owner or
/// fee involvement (e.g. displaced bid in `supersede_bid`).
```

<!-- line 112 -->
```
/// Construct `Total` from a superseded bidder whose full stake is
/// returned with no owner or fee involvement.
```

<!-- line 119 -->
```
/// Construct `Parcial` or `Nothing` from a departing `Tenant` whose
/// owner and fee shares have already been extracted. If the remaining
/// stake is non-zero the tenant gets a partial refund (`Parcial`);
/// otherwise the stake is empty and destroyed (`Nothing`). The
/// classification belongs here — the defining module — rather than at
/// every call site that produces a boundary refund.
```

<!-- line 140 -->
```
/// Route all three terminal operations for the departing tenant's
/// funds. Exhaustive match over the three variants; lives here (the
/// defining module) so it can see variant internals directly.
///
///   Nothing — no recipient; deposit owner share, post fee.
///   Parcial — split stake; deposit + post + liquidate remainder to identity.
///   Total   — full stake refunded to identity; no owner/fee.
```

<!-- line 173 -->
```
/// Consume a `RefundState` in tests, destroying any inner balance via
/// the test_only destructors of each component module. State-agnostic.
```

## retire_condition.move

<!-- line 4 -->
```
/// One-way retire flag embedded in Renting-phase tenancy variants.
/// NotRetiring → Retiring is the only legal transition; the reverse aborts.
```

## tenant.move

<!-- line 23 -->
```
/// Identity half of a `Tenant`. Two-component because the tenant's
/// authority over the slot is the cap_identity, while its destination for
/// payments (refunds, liquidate) is the address. Both irreducible.
```

<!-- line 31 -->
```
/// Material half of a `Tenant`. Wraps the tenant's collateral so raw
/// `Balance<C>` never crosses module borders — splits return typed
/// shares destined for specific consumers (FeeShare for fees,
/// OwnerEarnings later for owner). The internal raw Balance is reached
/// only inside this module.
```

<!-- line 40 -->
```
/// Entity = identity + material. Lives in `TenantState` slots; on
/// departure it is decomposed via `unbundle` (or consumed directly by
/// `liquidate`) at the lifecycle/refund boundary.
```

<!-- line 56 -->
```
// ### RUNTIME PROJECTION FOR SDK ###
```

<!-- line 67 -->
```
/// Bundle raw tenant data into a `Tenant`. Sole construction site —
/// the cap-layer (or a test) supplies the three components and the
/// nested wrappers are built internally.
```

<!-- line 81 -->
```
/// Decompose a `Tenant` into its two halves. Identity is needed for
/// events; stake travels onward (liquidate, destroy_empty, …).
```

<!-- line 88 -->
```
/// Drop a stake known to be empty. Aborts if non-zero — guards the
/// invariant at the consumption site rather than relying on caller
/// arithmetic.
```

<!-- line 96 -->
```
/// Drain `amount` off the tenant's stake as a `FeeShare<C>` destined
/// for `escrow_identity`. Aborts via `balance::split` if `amount > stake`.
```

<!-- line 107 -->
```
/// Drain `amount` off the tenant's stake as an `OwnerEarnings<C>`
/// ready to be `deposit`-ed into an `Owner`. Aborts via `balance::split`
/// if `amount > stake`.
```

<!-- line 118 -->
```
/// Consume a `TenantStake<C>` and send its balance to `to` as a
/// `Coin<C>`. Symmetric counterpart to `fee_message::post` (sends to
/// inbox) and `owner_earning::deposit` (joins into earning) — each
/// material-bearing wrapper has its own terminal operation in its
/// owning module.
```

<!-- line 136 -->
```
/// Borrow the inner `TenantStake`. Test-only — production code uses
/// `proj_stake_value` to skip the intermediate borrow.
```

<!-- line 141 -->
```
/// Stake value via a `&TenantStake` borrow. Test-only counterpart of
/// `proj_stake_value(&Tenant)` for the unbundled half.
```

<!-- line 148 -->
```
/// Destroy a `Tenant` regardless of stake — releases the inner balance
/// via `balance::destroy_for_testing`.
```

<!-- line 157 -->
```
/// Destroy a `TenantStake` regardless of value — releases the inner
/// balance via `balance::destroy_for_testing`.
```

## tenant_cap.move

<!-- line 22 -->
```
/// Typed identity of a `TenantCap` object — wraps its on-chain `ID`.
```

<!-- line 45 -->
```
/// Returns the ID of the `RentalEscrow` this cap was minted for (SDK boundary).
```

<!-- line 54 -->
```
/// Produce a typed `TenantCapIdentity` from a live cap reference.
```

<!-- line 59 -->
```
/// Extract the raw `ID` from a `TenantCapIdentity`.
```

<!-- line 62 -->
```
/// Wrap a raw `ID` known to belong to a `TenantCap` into a typed identity.
/// Used at SDK boundary entry points that receive raw IDs from callers.
```

<!-- line 66 -->
```
/// Package-internal: return the `EscrowIdentity` this cap is bound to.
```

<!-- line 71 -->
```
/// Pure constructor. Builds the cap, emits `TenantCapMinted`, returns cap by value.
```

<!-- line 83 -->
```
/// Destroys `cap` by value and emits `TenantCapBurned`.
```

## tenure_cycles_policy_state.move

<!-- line 36 -->
```
// ### RUNTIME PROJECTION FOR SDK ###
```

<!-- line 50 -->
```
/// Aborts if the owner only allows single-cycle tenancy and `cycles` > 1.
```

## tenure_policy_state.move

<!-- line 47 -->
```
// ### RUNTIME PROJECTION FOR SDK ###
```

<!-- line 82 -->
```
/// Returns the minimum possible ceiling for SDK views and cross-field validation.
/// Fixed: the fixed ceiling. RandomInRange: the minimum of the range (conservative).
/// Countdown handover floor must be < min_ceiling to hold for all draws.
```

<!-- line 92 -->
```
/// Resolves the policy to a concrete Duration.
/// Fixed: returns the fixed ceiling (generator unused).
/// RandomInRange: draws uniformly from [min, max].
```

