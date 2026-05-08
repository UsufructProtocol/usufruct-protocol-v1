# Architecture

This document describes the internal architecture of the `usufruct` Move package for contributors. It covers module layers, the lifecycle state model, design patterns, and the SDK projection system.

---

## What the protocol does

Liquid Renting is an on-chain rental protocol for Sui objects. An asset owner integrates their object into an `Escrow`, which manages the full rental lifecycle: listing, bidding, handover, Dutch auction, and retirement. Tenants pay stake to rent; stake is distributed to the owner and protocol as rent is consumed.

---

## Module layers

Dependencies flow strictly downward. A module may only call modules in layers below it.

```
╔══════════════════════════════════════════════════════════╗
║                   PTB / SDK BOUNDARY                     ║
║                                                          ║
║   escrow.move (key, shared)    runtime_projection.move   ║
║   ── mutations / actions ──    ── reads / projections ── ║
╚═══════════════════════╤══════════════════════════════════╝
                        │  owns + orchestrates
╔═══════════════════════▼══════════════════════════════════╗
║                   ORCHESTRATION                          ║
║              asset_context_state.move                    ║
║                                                          ║
║   AssetContext { AssetState, Owner, IntegrationConfig }  ║
║   lifecycle transitions · pricing · cap auth · events   ║
╚══════╤══════════════╤══════════════╤════════════════╤════╝
       │              │              │                │
╔══════▼═════╗  ╔═════▼═════╗  ╔════▼════╗  ╔════════▼═══╗
║  ENTITY    ║  ║  POLICY   ║  ║ COMPUTE ║  ║  CAP/AUTH  ║
║            ║  ║           ║  ║         ║  ║            ║
║ tenant     ║  ║ config    ║  ║ price_  ║  ║ tenant_cap ║
║ owner      ║  ║  ↳curve   ║  ║  state  ║  ║ owner_cap  ║
║ asset      ║  ║  ↳descent ║  ║ credit_ ║  ║ cap_auth_  ║
║            ║  ║  ↳handov  ║  ║  ctx    ║  ║  state     ║
║            ║  ║  ↳retire  ║  ║ refund_ ║  ║            ║
║            ║  ║  ↳price_fn║  ║  state  ║  ║            ║
╚════════════╝  ╚═══════════╝  ╚═════════╝  ╚════════════╝
╔══════════════════════════════════════════════════════════╗
║  PRIMITIVES              math.move    phases.move        ║
╚══════════════════════════════════════════════════════════╝
```

**PTB boundary** — `escrow.move` is the only `key` object and the sole entry point for mutations. `runtime_projection.move` is the sole entry point for reads from external packages. Both are `public`; everything else is `public(package)`.

**Orchestration** — `asset_context_state.move` owns the lifecycle state machine. It composes all entity, policy, and compute types into a single `AssetContext` and implements every transition.

**Entity** — `tenant`, `owner`, `asset` are value types (`store` only) that carry identity and material (balance or custody). Each follows the `Entity { Identity, Material }` shape.

**Policy** — `config` bundles the six policy enums that parameterize the escrow at integration time. Policy types are `copy + drop + store` — they live inside `IntegrationConfig` and never change after creation.

**Compute** — derived types that are calculated on demand and never stored. `PriceState`, `CreditContext`, `RefundState`, `PendingTransitionState` are all `drop`-only (or no abilities). They express a computation result, not persistent state.

**Cap/Auth** — capability objects (`key + store`) that authorize tenant and owner actions. `CapAuthorizationState` is a derived enum that classifies a cap as current, pending, or stale.

**Primitives** — `math` provides `mul_div` and `nth_root_u128`; `phases` owns all timestamp arithmetic. No other module performs raw `+` on timestamps.

---

## Lifecycle state model

The full state is stored inside `AssetContext`, which uses the Context-State pattern at three nested levels.

```
AssetContext
├── asset_state: AssetState
│     ├── Waiting
│     │     └── WaitingContext
│     │           ├── asset: AssetCustodyLocked<U>   (asset held, no borrow)
│     │           └── state: WaitingState
│     │                 ├── Idle
│     │                 ├── AtDutch { last_acq_price, phase_start_ms }
│     │                 └── Retired
│     └── Renting
│           └── TenancyContext
│                 ├── asset: AssetCustodyOpen<U>      (asset borrowable)
│                 ├── phase_start_ms
│                 ├── retiring: bool
│                 └── state: TenancyState
│                       ├── Occupied { tenant: Tenant<C> }
│                       └── Demand   { current, pending, handover_expiry }
├── owner: Owner<C>
│     └── OwnerIdentity { cap_id }  +  OwnerEarnings { balance }
└── config: IntegrationConfig
      ├── HandoverPolicyState  (Instant | Countdown | FixedTime)
      ├── DescentPolicyState   (Skipped | Window)
      ├── RetirePolicyState    (Immediate | Deferred)
      ├── CurveShapeState      (credit curve)
      ├── CurveShapeState      (descent curve)
      └── PriceFunctionState   (FixedDelta | CompoundDelta)
```

**Context-State pattern**: shared fields live in the context struct; variant-specific fields live in the state enum. This avoids repeating fields across variants. Example: `phase_start_ms` is shared across `Occupied` and `Demand`, so it lives in `TenancyContext`, not in each `TenancyState` variant.

**Binary split at the top**: `AssetState` is binary — `Renting` (active tenancy) or `Waiting` (no tenant). This split removes the compiler bug triggered by deeply nested generic type params in enum fringe positions (`TypeInner::Param` vs `TypeInner::Apply` in `hlir/match_compilation.rs`). See `BUG_REPORT.md`.

**Asset custody**: `AssetCustodyLocked` holds the asset when no tenancy is active (no borrow protocol needed). `AssetCustodyOpen` holds it during tenancy and exposes `take`/`put`/`AssetReceipt` — a hot-potato borrow protocol that prevents asset swaps and cross-escrow attacks.

---

## Ephemeral types (never stored)

These types cross module boundaries within a PTB but are never written to the object store.

```
   borrow_asset()
        │
   AssetReceipt ── hot potato (no abilities) ──► return_asset()
   Proves the borrowed U came from this escrow; three-assertion put()
   guards cross-escrow, receipt-swap, and asset-swap attacks.

   lifecycle boundary
        │
   RefundState ── hot potato ──┬──► owner::deposit()    (owner share)
   (Nothing|Parcial|Total)     ├──► fee_message::post() (fee share)
                                └──► tenant::liquidate() (tenant refund)
   Encodes the legal distribution shape; cannot be dropped, so the
   compiler enforces that every exit route is handled.

        FeeShare ──► FeeMessage (key) ──► ProtocolFeeInbox
        (store only)  minted by post()    collected by protocol

   asset_context_state::next_pending()
        │
   PendingTransitionState ── drop only ──► fire() ──► state transition
   Lazy APT loop: detect then fire. Never stored.

   credit_context_state::build()
        │
   CreditContext ── drop only ──► used_credit() ──► u64
   Snapshot of credit state at a point in time. Computed on demand.
```

---

## Design patterns

### Entity = Identity + Material

Every protocol entity follows the same shape:

```
struct Entity {
    identity: EntityIdentity,   // who + authority (IDs, addresses)
    material: EntityMaterial,   // what they hold (balance, custody)
}
```

`Tenant { TenantIdentity { cap_id, address }, TenantStake { balance } }`  
`Owner  { OwnerIdentity  { cap_id },          OwnerEarnings { balance } }`

Identity never carries balance; material never carries authority. The split makes routing unambiguous and prevents confused deputy mistakes.

### Hot potato as contract enforcement

`RefundState` has no abilities. The compiler guarantees that every lifecycle exit path distributes all funds — you cannot drop a `RefundState` without destructuring it, so you cannot forget the owner share, the fee, or the tenant refund. The enum shape encodes which distribution applies; the type system enforces that it is consumed.

### Lazy evaluation (APT loop)

State transitions are not triggered immediately by clock. `next_pending()` detects the single due transition given the current time. `apply_pending_transition_states()` loops until none remain. This decouples detection from firing and makes each boundary handler independently testable.

### `proj_*` convention and SDK projection

All `public(package)` view functions carry a `proj_` prefix. `runtime_projection.move` wraps every `proj_*` function as `public`, making it the single read-access point for external packages.

The design follows two rules:

1. **Eager**: every piece of runtime state gets a `proj_*` function regardless of whether its type is directly observable by the SDK. Curation is handled by the type system — if a type has no `key` ability, no external package can construct a value to pass to the wrapper, making it unreachable by construction.

2. **One direction**: `proj_*` calls flow strictly downward in the dependency graph. `asset_context_state` reads `tenant`, `owner`, `asset`, `config`. Nothing reads upward. This makes the impact of any field change traceable to a single layer.

---

## The SDK boundary in detail

`Escrow<Asset, CoinType>` is the only `key` object. External packages interact exclusively through it.

```
External package
      │
      ├── mutations  ──►  escrow.move  (public fns)
      │                       │
      │                       └── asset_context_state (public(package))
      │                               └── tenant / owner / asset / ...
      │
      └── reads  ──►  runtime_projection.move  (public fns)
                          │
                          └── module::proj_*  (public(package))
```

`escrow.move` is a thin wrapper: it extracts `AssetContext` from the `Option`, delegates to `asset_context_state`, and refills the slot. It has no state of its own. This concentrates the public API in a single module while keeping the state machine in `asset_context_state`, where it belongs.

`runtime_projection.move` is a pure read layer: one `public` wrapper per `proj_*` function, no logic. Any external package that needs to inspect protocol state imports this module.
