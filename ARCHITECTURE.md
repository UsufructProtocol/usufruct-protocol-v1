# Architecture

Internal architecture of the `usufruct` Move package for contributors. Covers module layers, the two shared objects, the lifecycle state model, the FSM engine, and the policy and entity systems.

---

## What the protocol does

**usufruct** is an on-chain rental protocol for any Sui object with `key + store` abilities. An owner integrates their object into an `Escrow`, which manages the full rental lifecycle: listing at rest price, Dutch auction descent, tenant acquisition, handover under demand, and retirement. Tenants pay stake; stake is distributed to the owner and protocol as credit is consumed.

The protocol is generic over both the asset type and the payment coin: `Escrow<Asset: key + store, CoinType: phantom>`. It enforces custody and economics. What the tenant does with the asset between `borrow_asset` and `return_asset` is outside the protocol's concern.

---

## Module layers

Dependencies flow strictly downward. A module may only import modules in layers below it. The diagram is derived from actual import declarations.

```
┌────────────────────────────────────────────────────────┐
│                   LAYER 5 — PUBLIC API                 │
│                     api/escrow.move                    │
│          Escrow<Asset, CoinType>  (key, shared)        │
│   mutations · views · cap operations · integrations    │
└───────────────────────────┬────────────────────────────┘
                            │
┌───────────────────────────▼────────────────────────────┐
│                   LAYER 4 — FSM ENGINE                 │
│                 engine/asset_state.move                │
│   AssetState · EscrowCore · all transitions · events   │
└──────┬──────────────────┬─────────────────┬────────────┘
       │                  │                 │
┌──────▼──────┐  ┌────────▼───────┐  ┌─────▼──────────────┐
│  LAYER 3    │  │   LAYER 3      │  │    LAYER 3          │
│  engine/    │  │   fees/        │  │    policies/        │
│  refund_    │  │   fee_message  │  │    policy_ensemble  │
│  state.move │  │   protocol_    │  │    commitment_      │
│  asset_     │  │   fee_*.move   │  │    policy.move      │
│  custody    │  └────────────────┘  └─────────────────────┘
└─────────────┘
       │
┌──────▼──────────────────────────────────────────────────┐
│                   LAYER 2 — ENTITIES                    │
│  entities/cap/     owner_cap.move  tenant_cap.move      │
│  entities/seat/    owner_seat.move tenant_seat.move     │
│  entities/balances/ owner_earning  tenant_stake         │
│  entities/identities/ (5 modules)                      │
│  entities/address/  refund_address.move                 │
│  policies/ (8 individual policy modules)               │
│  fees/protocol_fee_ref.move  fees/protocol_fee_inbox   │
└──────┬──────────────────────────────────────────────────┘
       │
┌──────▼──────────────────────────────────────────────────┐
│                   LAYER 1 — DOMAIN                      │
│  domain/monetary.move   Price, Stake                    │
│  domain/phases.move     Timestamp, Duration, Boundary   │
│  domain/tenures.move    Tenures                         │
│  primitives/math.move   BasisPoints, CurveHeight        │
└──────┬──────────────────────────────────────────────────┘
       │
┌──────▼──────────────────────────────────────────────────┐
│               LAYER 0 — FRAMEWORK + OTW                 │
│  sui::*  ·  std::*  ·  package/usufruct.move            │
└─────────────────────────────────────────────────────────┘
```

**Layer 5 (api/)** — `escrow.move` is the sole public entry point. It owns the `Escrow` shared object and exposes every PTB-reachable function. No state machine logic lives here — it delegates entirely to `asset_state.move`.

**Layer 4 (engine/)** — `asset_state.move` is the FSM engine. Every state transition, all credit and pricing arithmetic, and all event emissions originate here. `EscrowCore` and `AssetState` are defined here and never appear in layer 5 except as `Option` fields.

**Layer 3** — Three sub-systems that compose entities and policies into protocol-level constructs: the refund routing engine (`refund_state`), the asset custody model (`asset_custody`), the fee routing system (`fee_message`, `protocol_fee_*`), and the policy bundle (`policy_ensemble`, `commitment_policy`).

**Layer 2 (entities/, policies/)** — Protocol entities (caps, seats, balances, identities) and individual policy types. Each policy module owns a single policy enum and its `compute_*` resolution function.

**Layer 1 (domain/, primitives/)** — Domain primitives that wrap raw `u64` or `address` into typed values. No module except the owner operates on the naked primitive.

**Layer 0** — Sui framework and the package OTW (`usufruct.move`), which mints the `Publisher` at deploy time.

---

## The two objects

`Escrow<Asset, CoinType>` is the only shared object. `OwnerCap` and `TenantCap` are owned objects that authorize operations on the shared escrow.

### Escrow structure

```move
// api/escrow.move
public struct Escrow<Asset: key + store, phantom CoinType> has key {
    id:    UID,
    core:  Option<EscrowCore<CoinType>>,
    state: Option<AssetState<Asset, CoinType>>,
}
```

Both fields are `Option`. `state` is `None` while the asset is borrowed by a tenant — the `AssetState` is extracted into the `AssetReceipt` hot potato and re-inserted on return. `core` is extracted via `take` for any mutation and re-inserted via `put` after. This is the Option-as-mutual-exclusion pattern: the `None` encodes domain meaning (state is live elsewhere), not nullable convenience.

### EscrowCore structure

```move
// engine/asset_state.move
EscrowCore<CoinType> {
    owner:              OwnerSeat<CoinType>,
    ensemble:           EnsembleSlot,
    fee_inbox_identity: FeeInboxIdentity,
    integrated_at:      Timestamp,
    commitment:         CommitmentSlot,
    escrow_identity:    EscrowIdentity,
}
```

`EscrowCore` carries the financial and configuration context that persists across the full escrow lifetime. `EnsembleSlot` holds the active `PolicyEnsemble` and an optional staged pending update. `CommitmentSlot` holds the owner's commitment policy and its anchor timestamp.

---

## Lifecycle state model

`AssetState` is a two-level enum hierarchy. The outer split separates financial from non-financial state at the type level: `CoinType` is only present in `RentingState`.

```
AssetState<Asset, CoinType>
├── Waiting(WaitingState<Asset>)                    // no CoinType
│     ├── Idle    { asset: AssetCustodyLocked, cycle: CycleParams }
│     ├── AtDutch { asset: AssetCustodyLocked, auction: AuctionTerms, cycle: CycleParams }
│     └── Retired { asset: AssetCustodyLocked }
└── Renting(RentingState<Asset, CoinType>)          // carries CoinType
      ├── Occupied { asset: AssetCustodyOpen, terms: OccupiedTerms<C>, cycle: CycleParams }
      └── Demand   { asset: AssetCustodyOpen, terms: OccupiedTerms<C>, bid: DemandTerms<C>, cycle: CycleParams }
```

**WaitingState** — no tenant, no financial state. Asset is held in `AssetCustodyLocked`, which does not expose a borrow interface.

**RentingState** — active tenancy. Asset is held in `AssetCustodyOpen`, which exposes `take`/`put` and the `AssetReceipt` borrow protocol. `CoinType` is present because the tenant's stake and the owner's earnings live here.

**CycleParams** — resolved policy parameters for the current rental cycle: `floor: Price`, `ceiling: Duration`, `handover: Duration`, `descent: Duration`. Sampled once at cycle entry from the `PolicyEnsemble`. The engine never reads policy variants after this point.

**OccupiedTerms** — current tenant's full context: `TenancySchedule` (phase start, total ceiling, total handover, committed tenures), `TenantSeat<C>` (identity + stake), and `RetireCondition` (flag set by owner to retire after this tenure).

**DemandTerms** — pending tenant's bid: `TenantSeat<C>` + `HandoverTerms` (expiry timestamp, committed tenures).

### State transitions

```
             rent (do_install)          rent (do_install)
   Idle ─────────────────────► Occupied ◄──────────────── AtDutch
    ▲                              │  │
    │ step_auction_expiry          │  │ rent (do_place_bid)
    │ (do_auction_expiry)          │  ▼
    └──────────────────────── AtDutch   Demand ──────────────────► Occupied
                                    ▲   │  ▲                    (do_handover)
                                    │   │  └── rent (do_supersede_bid, self-loop)
                              tenure│   │
                              expiry│   │ tenure expiry [retire flag]
                                    │   ▼
                                 AtDutch  Retired

   Idle, AtDutch ──► Retired     execute_retire (immediate)
   Occupied, Demand ──► Retired  tenure expiry with RetireCondition::Retiring

   Retired ──► (consumed)        execute_claim
```

Transitions are **lazy**: `execute_apply_pending_transition_states` evaluates all fireable transitions in fixed order (`step_handover` → `step_tenure_expiry` → `step_auction_expiry`) and is called at the start of every mutating operation. No external keeper is required.

---

## The FSM engine — `asset_state.move`

`asset_state.move` is the largest module and the protocol's core. It owns:

- The `AssetState`, `WaitingState`, `RentingState` enum hierarchy
- `EscrowCore` and all its sub-types (`EnsembleSlot`, `CommitmentSlot`, `CycleParams`, `OccupiedTerms`, `DemandTerms`, `AuctionTerms`, `TenancySchedule`, `HandoverTerms`)
- `AssetReceipt` — the hot-potato receipt that carries `RentingState` during borrow
- `RetireCondition` — one-way transition flag as an enum variant, not a boolean
- All `execute_*` transition functions
- All `proj_*` view functions
- All event type definitions and `event::emit` calls

Every other module in the protocol is a building block that `asset_state` composes. The engine contains no `match` expressions over policy variants — it receives resolved `CycleParams` primitives and operates uniformly regardless of which policy combination produced them.

---

## Policy layer

Eight policies parameterize the escrow at integration time. Seven are bundled in `PolicyEnsemble`; one (`CommitmentPolicy`) is stored separately in `EscrowCore` because it governs the owner, not the rental market.

```
PolicyEnsemble {
    rest_price:         RestPricePolicy         // floor price per idle cycle
    tenure_duration:    TenureDurationPolicy    // max tenure length
    tenure_extend:      TenureExtendPolicy      // Single | Multi tenure commitment
    handover:           HandoverPolicy          // handover countdown variant
    auction_window:     AuctionWindowPolicy     // Dutch auction duration variant
    credit_shape:       CurveShapePolicy        // credit consumption curve
    auction_shape:      CurveShapePolicy        // price descent curve
    price_escalation:   PriceEscalationPolicy   // price escalation under demand
}

CommitmentPolicy    // Immediate | Deferred — owner's exit lock
```

Each policy module owns a single enum and a `compute_*` function that resolves the policy to a domain primitive (`Price`, `Duration`). After resolution, the engine sees only domain primitives. Policy variants are an extension point; the engine is invariant over them.

`EnsembleSlot` holds the active ensemble and an optional pending update. Pending updates are staged when the escrow is occupied and applied only at the `AtDutch → Idle` transition — never mid-tenure.

---

## Entity layer

Every protocol entity follows the **Identity + Material** split:

```
Cap (key + store)          — owned object; authorizes escrow operations
  OwnerCap  { id, escrow_identity }
  TenantCap { id, escrow_identity, refund_address, cap_identity }

Identity (copy + drop + store)  — who the entity is
  OwnerIdentity   { cap_identity: OwnerCapIdentity }
  TenantIdentity  { cap_identity: TenantCapIdentity, refund_address: RefundAddress }

Seat (store, CoinType)     — entity in flight: identity + material together
  OwnerSeat<C>   { identity: OwnerIdentity,  earnings: OwnerEarnings<C> }
  TenantSeat<C>  { identity: TenantIdentity, stake:    TenantStake<C>   }

Balance (store, CoinType)  — typed wrapper over sui::Balance
  OwnerEarnings<C>  { balance: Balance<C> }    → owner_seat::deposit
  TenantStake<C>    { balance: Balance<C> }    → refund or split
  FeeShare<C>       { balance, escrow_identity } → fee_message::post
```

`OwnerCap` and `TenantCap` are `key + store` — they are transferable owned objects. Whoever holds the cap holds the rights it represents. The protocol validates only `cap.escrow_identity == escrow.escrow_identity`; it does not validate the holder's address.

---

## Fee layer

### The problem

Every mutating operation on `Escrow` (a shared object) may produce a protocol fee. The
naive solution — a shared `ProtocolFeeInbox` that receives a balance transfer on each
operation — creates a write-contention bottleneck: every `rent`, `apply_transitions`,
`retire`, etc. would need to acquire a write lock on the same shared object, serializing
all fee-producing operations across the entire protocol.

Making the inbox an **owned object** eliminates that bottleneck, but introduces a
different constraint: Sui's PTB execution model does not allow an owned object and a
shared object to be accessed by the same transaction. Passing the inbox directly into
every escrow operation is therefore not possible.

### The solution: frozen pointer + transfer-to-object

The fee system resolves this with three decoupled phases and five types:

```
ProtocolFeeRef   (frozen)      — immutable pointer to the inbox; readable in any PTB
FeeInboxIdentity (copy+drop)   — the inbox's object ID, carried inside every EscrowCore
FeeShare<C>      (store)       — typed balance computed during settlement; no object overhead
FeeMessage<C>    (key+store)   — FeeShare wrapped as a Sui object; mailed to the inbox address
ProtocolFeeInbox (key+store)   — owned object; collects FeeMessages via transfer::receive
```

**Phase 1 — bootstrap (once at deploy).**
`ProtocolFeeInbox` is created and transferred to the protocol owner's address.
`ProtocolFeeRef` is created as a frozen (immutable) object holding only the inbox's
object ID. Because it is immutable, it can be passed as `&ProtocolFeeRef` in any PTB
regardless of what other objects are present — including the shared `Escrow`.

**Phase 2 — fee posting (every fee-producing operation, in the user's PTB).**
`integrate` reads `&ProtocolFeeRef`, extracts the inbox's ID as a `FeeInboxIdentity`
(`copy + drop` value), and stores it inside `EscrowCore`. From that point on, no
protocol object touches the inbox during any user operation. When `apply_transitions`
settles a state transition that carries a fee, it calls `fee_message::post`:

```
FeeShare<C>  →  wrap into FeeMessage<C>  →  transfer::transfer(msg, inbox_id.to_address())
```

The `FeeMessage` becomes an owned object at the inbox's address. The user's PTB is
complete — it touched only the shared `Escrow` and created one new owned object. The
inbox itself was never an input. Zero write contention on any accumulator.

**Phase 3 — collection (protocol owner, any time).**
The protocol owner constructs a PTB passing `&mut ProtocolFeeInbox` and one or more
`Receiving<FeeMessage<C>>` tickets. `fee_message::collect` calls
`transfer::receive(&mut inbox.id, ticket)` for each ticket, draining the balance into
the inbox. The `FeeMessage` objects are destroyed; their storage rebate exceeds the
computation cost, making collection self-funding at N ≥ 2 messages (see FINDINGS.md §4).
This PTB involves no shared objects — collection runs at owned-object speed.

### Contention profile

| Phase | Shared objects touched | Owned objects touched | Contention |
|---|---|---|---|
| User operation (rent / apply / retire) | `Escrow` | none (FeeMessage created fresh) | per-escrow only |
| Collection | none | `ProtocolFeeInbox` | none |

No two user transactions contend on the fee layer. Each `FeeMessage` is an independent
object; parallel operations on different escrows never conflict at the accumulator level.

---

## Ephemeral types

Types that cross module boundaries within a PTB but are never written to the object store.

```
AssetReceipt<Asset, CoinType>   — no abilities (hot potato)
  Carries RentingState while asset is borrowed.
  Forces borrow and return into the same PTB.
  escrow.state = None while active.

RefundState<CoinType>           — no abilities (hot potato)
  Nothing  { fee_share, owner_earnings }
  Parcial  { seat, fee_share, owner_earnings }
  Total    { seat }
  Encodes the settlement shape for each transition context.
  Must be consumed by distribute() in the same transaction.
  Partial settlement is structurally impossible.

FeeShare<CoinType>              — store only
  Intermediate typed balance between split and post.
  Cannot persist beyond its producing transaction without
  being wrapped into a FeeMessage.
```
