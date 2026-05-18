# Code Principles

Design principles applied consistently across this codebase. The document is structured around two core principles from which everything else derives. Each derived consequence includes a real example from the source and a grep-based test for violations.

---

## Context — functional programming applied to Move

The two principles in this document are not invented for this codebase. They are the core insight of functional programming applied to a domain where correctness matters: rather than mutating shared state and trusting the programmer not to forget anything, make invalid states and invalid programs structurally impossible so the compiler does the checking.

Functional languages handle state by making it explicit in types. A function takes a state value and produces a new state value. Illegal intermediate states have no type representation. The compiler tracks what was consumed and what was produced.

**Sui Move 2024 opened the door to express this style in Move.** The 2024 edition introduced enums with exhaustive match — algebraic data types, the foundation of every ML-family type system (Haskell, OCaml, Rust). With enums, Move can represent sum types: `AssetState = Waiting | Renting`. With exhaustive match, the compiler rejects any function that does not handle every case. Before Move 2024, this style was not expressible.

The codebase applies four functional concepts concretely:

- **Sum types (enums)** for state — `WaitingState | RentingState` instead of boolean flags and nullable fields. Invalid combinations have no representation.
- **Linear types (hot-potato)** for resource discipline — a value that must be consumed exactly once. The compiler rejects any transaction that does not satisfy the constraint. This is the same guarantee Rust achieves with ownership and Haskell with linear types.
- **Value transformations** for state transitions — `execute_rent(AssetState, ...) → (RentingState, TenantCap)`. The old state is consumed; the new one is produced. There is no partial update, no field left in an inconsistent intermediate state.
- **Resolved configuration as pure values** — `CycleParams` carries resolved policy outputs as domain primitives passed to the engine. The engine is a pure function over its inputs; it never reads configuration directly.

The practical consequence is not academic elegance — it is an auditable security property. Imperative smart contracts depend on the programmer updating all related state consistently and remembering every invariant. Functional-style contracts depend on the compiler: the output type of a transition function cannot be satisfied without consuming the right inputs in the right order. The compiler is the auditor.

---

## 1. Make illegal states unrepresentable

**Level: data types**

A type that can represent an invalid state will eventually hold one. Encode validity into the type itself so the invalid state has no representation.

The clearest instance in this codebase is the `AssetState` hierarchy. Financial state (`CoinType`) only exists when the asset is rented — it is structurally absent from all waiting states. It is not possible to construct a `WaitingState` that holds tenant stake or a rent price, because the type does not have the field.

```move
// WaitingState: no CoinType — financial state structurally absent
public enum WaitingState<Asset: key + store> has store {
    Idle    { asset: AssetCustodyLocked<Asset>, cycle: CycleParams },
    AtDutch { asset: AssetCustodyLocked<Asset>, auction: AuctionTerms, cycle: CycleParams },
    Retired { asset: AssetCustodyLocked<Asset> },
}

// RentingState: carries CoinType — financial state structurally present
public enum RentingState<Asset: key + store, phantom CoinType> has store {
    Occupied { asset: AssetCustodyOpen<Asset>, terms: OccupiedTerms<CoinType>, cycle: CycleParams },
    Demand   { asset: AssetCustodyOpen<Asset>, terms: OccupiedTerms<CoinType>, bid: DemandTerms<CoinType>, cycle: CycleParams },
}

public enum AssetState<Asset: key + store, phantom CoinType> has store {
    Waiting(WaitingState<Asset>),
    Renting(RentingState<Asset, CoinType>),
}
```

The split is not organizational — it is a type-system guarantee. Functions operating only on waiting state carry no `CoinType` in their signature. Functions operating only on renting state carry it. The compiler enforces this at every call site.

---

### 1.1 One-way transitions are enum variants, not booleans

A bool field that is only ever set to `true` is a missing enum variant. One-way transitions encode as state machine states, not mutable flags.

```move
// A bool `is_retiring: bool` would allow the invalid combination
// "retiring=true while Waiting". The enum makes it structurally impossible.
public enum RetireCondition has store, drop {
    NotRetiring,
    Retiring,
}
```

`RetireCondition` lives inside `OccupiedTerms` — it only exists while renting. The combination "retiring while waiting" has no type representation.

The one-way nature of the transition is enforced by the function that sets it. There is no way to call `retire_condition_set` twice — the second call aborts. With a `bool` this would require an external guard; here the type itself is the guard:

```move
// asset_state.move
fun retire_condition_set(r: RetireCondition): RetireCondition {
    match (r) {
        RetireCondition::NotRetiring => RetireCondition::Retiring,
        RetireCondition::Retiring    => abort EAlreadyRetiring,
    }
}
```

The match is exhaustive over two variants. If a third variant were ever added, the compiler would require its handling here before the code could compile.

**Test:** `grep -r "retiring: bool\|is_retiring" sources/` returns zero results.

---

### 1.2 Cross-object invariants belong in the receipt type

When a protocol spans two object accesses (borrow and return), the compiler cannot verify cross-object invariants by observing a different object. The fix: carry the relevant state inside the hot-potato receipt. The return function then matches over a type that has only the valid variants — exhaustive by construction.

```move
// AssetReceipt carries the full RentingState extracted from the escrow.
// execute_return matches only over Occupied | Demand — no wildcard needed.
public struct AssetReceipt<Asset: key + store, phantom CoinType> {
    identity: EscrowedAssetIdentity,
    renting:  RentingState<Asset, CoinType>,
}
```

The side effect of carrying state in the receipt is that `escrow.state = None` while the asset is borrowed. No external transaction observes this intermediate state — Sui PTBs commit atomically. Any attempt to read or mutate the escrow state between borrow and return aborts with `EAssetBorrowed`.

**Diagnostic:** a `_ => abort` in the match on the *return* side of a borrow/return pair is the smell. It means a cross-object invariant has not been given a type yet.

---

### 1.3 Entity shape: Identity + Material

Every protocol entity that carries both an identity and a balance follows the same structural split. The two halves travel separately at settlement boundaries: identity routes the destination; material carries the funds.

```move
public struct TenantSeat<phantom CoinType> has store {
    identity: TenantIdentity,
    stake:    TenantStake<CoinType>,
}

public struct OwnerSeat<phantom CoinType> has store {
    identity: OwnerIdentity,
    earnings: OwnerEarnings<CoinType>,
}
```

Asymmetries between entities are preserved, not normalized. `OwnerIdentity` authorizes by cap_id only; `TenantIdentity` authorizes by cap_id and carries a `RefundAddress`. The difference is domain information, not an inconsistency.

---

### 1.4 Unreachable aborts are type holes — coverage is the oracle

*Don't lie with abort.*

A `_ => abort` or `abort 0` in a match on a protocol enum is a lie: the programmer knows the branch is unreachable, but the type still allows it to be constructed. The abort is not a legitimate runtime error — it is a confession that the type is not yet tight enough.

The proof that this codebase has no such holes is observable: every match arm across the FSM is reachable by a valid input, and the test suite achieves 100% coverage with no `#[allow(dead_code)]` suppressions and no test that exists only to force an abort arm. If a coverage gap appeared, the correct response would not be to write a test that forces the branch — it would be to eliminate the branch by strengthening the type.

**Coverage is the oracle.** In most codebases a coverage gap has two interpretations: a missing test, or dead code. In a codebase that applies this principle consistently there is a third interpretation — and it is the most valuable one: the type can still represent a state the protocol prohibits. That third interpretation points to a structurally different action. Not a test. Not a deletion. A new type.

This inverts the usual framing. Coverage normally measures whether the tests are exhaustive over the program. Here it measures whether the types are exhaustive over the domain. The program is already complete; the question is whether the type system has closed every hole the semantics require.

The compiler and the test runner are working together as design tools, not only as verification tools. The compiler signals when a type cannot guarantee something — an exhaustive match that needs a `_ =>` arm is the compiler saying "I can't prove this case is impossible." The test runner signals when something is unreachable — a branch with no covering test is the test runner saying "no valid input reaches here." The intersection of those two signals is where missing types live: the compiler can't prove it impossible, and no valid input can reach it. That combination means the type is too wide. Narrow it.

The canonical example in this codebase is `execute_return`. Before `RentingState` was introduced as a receipt-carried type, the function matched over the full `AssetState` — which includes waiting variants that are structurally impossible at return time. The compiler could not know this, so an abort was needed:

```move
// Before — AssetReceipt carries only identity; execute_return matches AssetState.
// The waiting variants are impossible at this point, but the type cannot say so.
public struct AssetReceipt { identity: EscrowedAssetIdentity }

fun execute_return(s: &mut AssetState<A, C>, receipt: AssetReceipt, asset: A) {
    match (s) {
        AssetState::Renting(RentingState::Occupied { .. }) => { /* re-insert */ },
        AssetState::Renting(RentingState::Demand   { .. }) => { /* re-insert */ },
        _ => abort EReceiptStateMismatch,   // unreachable in production — type hole
    }
}
```

Pursuing 100% coverage exposed this arm as untestable: no valid sequence of protocol operations can produce a `Waiting` state at return time. The fix was to carry `RentingState` inside `AssetReceipt`. The arm disappeared because the type now makes the impossible state unrepresentable:

```move
// After — AssetReceipt carries RentingState; execute_return is exhaustive with no abort.
public struct AssetReceipt<Asset: key + store, phantom CoinType> {
    identity: EscrowedAssetIdentity,
    renting:  RentingState<Asset, CoinType>,   // only Occupied | Demand exist
}

fun execute_return(receipt: AssetReceipt<A, C>, asset: A, ...) {
    let AssetReceipt { identity, renting } = receipt;
    match (renting) {
        RentingState::Occupied { .. } => { /* reconstruct AssetState::Waiting or Renting */ },
        RentingState::Demand   { .. } => { /* reconstruct */ },
        // No _ arm — RentingState has exactly these two variants; compiler verifies exhaustion
    }
}
```

The abort was not removed by adding a test. It was removed by making its branch unrepresentable. The coverage gap closed as a consequence.

**Test:** `grep -r "abort 0\|abort EUnreachable\|// unreachable" sources/` returns zero results.

---

### 1.5 Transition return types encode reachability — the signature is the invariant

The two-level state split (`WaitingState` / `RentingState`) propagates from the enum hierarchy into the return types of every transition function. The return type of a `do_*` function is not documentation — it is a compile-time proof of which states that transition can reach.

```move
// Transitions that always produce renting state — CoinType is present, a tenant exists
fun do_install<Asset, C>(...):        (RentingState<Asset, C>, TenantCap)
fun do_place_bid<Asset, C>(...):      (RentingState<Asset, C>, TenantCap)
fun do_supersede_bid<Asset, C>(...):  (RentingState<Asset, C>, TenantCap)
fun do_handover<Asset, C>(...):        RentingState<Asset, C>

// Transitions that always produce waiting state — no CoinType, no tenant
fun do_tenure_expiry<Asset, C>(...):   WaitingState<Asset>
fun do_auction_expiry<Asset>(...):     WaitingState<Asset>
fun do_retire_immediately<Asset>(...): WaitingState<Asset>
```

`do_tenure_expiry` returning `WaitingState<Asset>` makes it a compile error for that function to produce a `RentingState`. The code cannot construct the wrong type — the body must assemble a `WaitingState` variant or it does not compile. A change that accidentally tried to leave a tenant in place after tenure expiry would be rejected before it could run.

`step_*` functions sit one level above. They check whether a transition is fireable and delegate to `do_*` if so. Because a step may or may not fire, both outcomes are possible — the return type is `AssetState`:

```move
// Conditional steps — return AssetState because the transition may not fire
fun step_handover<Asset, C>(...):       AssetState<Asset, C>
fun step_tenure_expiry<Asset, C>(...):  AssetState<Asset, C>
fun step_auction_expiry<Asset, C>(...): AssetState<Asset, C>
```

The two-tier split is a direct consequence of P1 applied to functions: `do_*` expresses what a transition produces and the compiler enforces it; `step_*` expresses whether it fires and the logic enforces it. Illegal outcomes are unrepresentable at the type level, not just undocumented.

---

### 1.6 Option as mutual exclusion — simultaneous access is a type error

When an object can be in one of two mutually exclusive states, encoding the active state as `Option` makes simultaneous access structurally impossible. The `None` is not a sentinel value — it is the type-level proof that the state has been extracted and is live elsewhere.

```move
// escrow.move
public struct Escrow<Asset: key + store, phantom CoinType> has key {
    id:    UID,
    core:  Option<EscrowCore<CoinType>>,
    state: Option<AssetState<Asset, CoinType>>,
}
```

During `borrow_asset`, `state` is extracted into the `AssetReceipt` hot-potato and the field becomes `None`. Any operation that calls `escrow.state.extract()` or reads from `state` while the receipt is live aborts with `EAssetBorrowed`. There is no way to hold both `AssetState` and a valid `AssetReceipt` at the same time — the type system prevents it by construction. The escrow is effectively frozen at the type level for the duration of the borrow.

This is distinct from `Option` used as a nullable field for convenience. Here the `None` state has a precise domain meaning: the asset is currently in the tenant's possession. The `Some`/`None` transition mirrors the `borrow`/`return` lifecycle exactly.

**Test:** every read of `escrow.state` inside the package goes through `take_state` or `read_state`, both of which abort on `None` with `EAssetBorrowed` — the invariant is centralized, never scattered across call sites.

---

## 2. Make illegal programs unrepresentable

**Level: function signatures and module architecture**

A primitive in a function signature lies about its meaning. `u64` says "I am a number" — it does not say "I am a price" or "I am a timestamp in milliseconds." Two arguments of the same raw type can be silently swapped; the compiler has no basis to reject the mistake.

Replace primitives with domain types at every internal function boundary. The compiler then rejects incorrect argument order, incorrect unit, and incorrect domain — all at compile time.

```move
// Before — can pass duration where price is expected; compiler cannot help
fun ascending_floor_price(stake: u64, ...): u64

// After — wrong domain is a compile error
fun ascending_floor_price(stake: Stake, ensemble: &PolicyEnsemble): Price {
    price_escalation_policy::compute_next_price(
        policy_ensemble::proj_price_escalation(ensemble),
        monetary::as_reference_price(stake),
    )
}
```

**Rule:** outside `math.move`, no internal function signature contains a raw `u64` where a domain type exists. The extraction to `u64` happens exactly once, at the event emission or SDK boundary.

**Test:** `grep -r "fun.*: u64" sources/` excluding `math.move`, `events`, and error constants returns zero results.

---

### 2.1 Layer ownership — a domain owns its primitive

Each domain layer owns exactly one module that wraps its primitive. No module except the owner operates on the naked value.

```move
// monetary.move — owns the money domain
public struct Price has copy, drop, store { mist: u64 }
public struct Stake has copy, drop, store { mist: u64 }

// phases.move — owns the time domain
public struct Timestamp has copy, drop, store { ms: u64 }
public struct Duration  has copy, drop, store { ms: u64 }

// tenures.move — owns the tenure-count domain; enforces count > 0 at construction
public struct Tenures has copy, drop, store { count: u64 }

public fun tenures(n: u64): Tenures {
    assert!(n > 0, ETenuresZero);
    Tenures { count: n }
}

// math.move — owns the math primitives
public struct BasisPoints has copy, drop, store { bps: u64 }
public struct CurveHeight has copy, drop  { h:   u64 }
```

| Domain | Owner | Types |
|--------|-------|-------|
| Money  | `monetary.move` | `Price`, `Stake` |
| Time   | `phases.move`   | `Timestamp`, `Duration`, `Boundary` |
| Count  | `tenures.move`  | `Tenures` |
| Math   | `math.move`     | `BasisPoints`, `CurveHeight` |

**Test:** `grep -r ": u64" sources/` in internal functions (excluding events, errors, `math.move`) returns zero results.

---

### 2.2 Policy resolves to domain primitive — computation never sees the policy

A policy type encodes a *choice* about how to derive a value. A computation function uses the *derived value*. These are different things and must not share a type.

Policy variants resolve to domain primitives at the cycle-entry boundary. Everything downstream receives only the resolved primitive.

```move
// rest_price_policy.move — resolves at the boundary, returns Price
public(package) fun compute_price(policy: &RestPricePolicy, generator: &mut RandomGenerator): Price {
    match (policy) {
        RestPricePolicy::Fixed { price }            => *price,
        RestPricePolicy::RandomInRange { min, max } => {
            monetary::price(generator.generate_u64_in_range(
                monetary::price_mist(*min),
                monetary::price_mist(*max),
            ))
        },
    }
}
```

After `compute_price` returns, the engine sees `Price`. Whether the policy was `Fixed` or `RandomInRange` is invisible by design.

**This principle is what makes the FSM engine polymorphic over configuration.** `asset_state.move` contains no match expression over any policy variant. The engine receives `CycleParams` — a record of already-resolved primitives (`floor: Price`, `ceiling: Duration`, `handover: Duration`, `descent: Duration`) — computed once at cycle entry. From that point forward, the engine does not know and does not care which policy variant produced each value. The same transition logic, the same credit arithmetic, the same settlement code executes for every one of the 672 policy combinations in the test corpus.

If the engine had to branch on policy variants, every new variant added to the ensemble would require touching the engine. The `resolve()` boundary cuts that coupling: the ensemble can grow without the engine changing. Policy variants are an extension point; the engine is invariant.

**Diagnostic:** an `abort 0` (or any abort) in a match arm annotated "unreachable after resolve()" is the smell. It means a policy type crossed the resolution boundary into a computation function.

**Test:** no computation function (`has_expired`, `compute_floor_price`, `compute_used_credit`) accepts a `&*Policy` parameter.

---

### 2.3 Raw Balance never crosses module borders

Every `Balance<C>` produced inside the package wraps immediately into a typed share destined for a single consumer. The naked `Balance` is internal plumbing only.

```move
public struct TenantStake<phantom CoinType> has store {
    balance: Balance<CoinType>,          // internal — never returned directly
}

public struct FeeShare<phantom CoinType> has store {
    balance:         Balance<CoinType>,  // internal — posted as FeeMessage
    escrow_identity: EscrowIdentity,
}
```

The routing chain is:
```
tenant_seat::take_fee_share      → FeeShare<C>       → fee_message::post → fee inbox
tenant_seat::take_owner_earnings → OwnerEarnings<C>  → owner_seat::deposit → owner balance
tenant_stake::liquidate          → transfer to refund address
```

No function signature outside its defining module accepts or returns `Balance<C>`.

**The compiler enforces what naming convention alone cannot.** Before this principle was applied fully, the fee split was computed into `FeeAllocation { owner_share: Stake, protocol_fee: Stake }` — both fields the same type. The field names communicated intent, but a developer could write `let FeeAllocation { owner_share: fee, protocol_fee: owner } = alloc` and the compiler would not protest: same type, valid destructure, silent swap. The fix was to eliminate `FeeAllocation` entirely and produce `OwnerEarnings<C>` and `FeeShare<C>` directly at the split site:

```move
// do_handover / do_tenure_expiry — owner_earnings and fee_share cannot be swapped.
// owner_seat::deposit accepts OwnerEarnings<C>; fee_message::post accepts FeeShare<C>.
// Passing one where the other is expected is a compile error.
let owner_earnings = tenant_seat::take_owner_earnings(&mut departing, monetary::stake(used_mist - fee_mist));
let fee_share      = tenant_seat::take_fee_share(&mut departing, monetary::stake(fee_mist), escrow_identity);
```

The downstream consumers have incompatible types. Routing is not a convention the programmer must remember — it is a constraint the compiler checks at every call site:

```move
// owner_seat.move
public(package) fun deposit<C>(self: &mut OwnerSeat<C>, incoming: OwnerEarnings<C>) { ... }

// fee_message.move
public(package) fun post<C>(share: FeeShare<C>, fee_inbox_identity: FeeInboxIdentity, ctx: &mut TxContext) { ... }

// With the typed shares in hand, the swap is a compile error:
owner_seat::deposit(owner, fee_share);      // ERROR — expected OwnerEarnings<C>, got FeeShare<C>
fee_message::post(owner_earnings, ...);     // ERROR — expected FeeShare<C>, got OwnerEarnings<C>
```

The strongest expression of this principle is `RefundState<CoinType>` — a hot-potato enum with no abilities that carries all three typed shares simultaneously and forces their complete distribution before the transaction ends:

```move
// refund_state.move
public enum RefundState<phantom CoinType> {            // no abilities — hot potato
    Nothing { fee_share: FeeShare<C>, owner_earnings: OwnerEarnings<C> },
    Parcial { seat: TenantSeat<C>, fee_share: FeeShare<C>, owner_earnings: OwnerEarnings<C> },
    Total   { seat: TenantSeat<C> },
}
```

Each variant encodes exactly which consumers receive funds for a given settlement context — tenure expiry, handover, or superseded bid. The hot-potato constraint means `distribute` must be called in the same transaction that creates the `RefundState`. Partial settlement — routing fee and owner earnings but forgetting the tenant refund — is structurally impossible: the compiler rejects any transaction that does not consume every field. Raw `Balance` never appears; every balance travels wrapped in a typed share destined for exactly one consumer.

---

### 2.4 Extraction is a deliberate domain crossing

When a typed value must cross into a math or framework operation, the extraction is made visible by calling a named extractor. This makes "I am leaving the typed domain here" a statement in the code, not a hidden operation.

```move
fun split_fee_amounts(amount: Stake): (Stake, Stake) {
    let mist     = monetary::stake_mist(amount);          // deliberate crossing
    let fee_mist = math::compute_apply_bps(mist, math::bps(PROTOCOL_FEE_BPS));
    (monetary::stake(mist - fee_mist), monetary::stake(fee_mist))
}
```

Event fields are the terminal extraction point — `u64` in event structs is correct and intentional. Events are serialized for off-chain consumers; domain types stop at the event boundary.

---

### 2.5 Exhaustive match over boolean guards

When a function branches on state, use a match expression over boolean guards. Exhaustive match forces the compiler to require coverage of every variant. Adding a new variant to an enum becomes a compile error at every match site.

```move
// proj_asset_id matches all variants of AssetState explicitly — no wildcard
public(package) fun proj_asset_id<Asset: key + store, CoinType>(
    s: &AssetState<Asset, CoinType>,
): ID {
    match (s) {
        AssetState::Waiting(WaitingState::Idle    { asset, .. } |
                            WaitingState::AtDutch { asset, .. } |
                            WaitingState::Retired { asset })     =>
            asset_custody::proj_locked_id(asset),
        AssetState::Renting(RentingState::Occupied { asset, .. } |
                            RentingState::Demand   { asset, .. }) =>
            asset_identity::proj_id(asset_custody::proj_asset_id(asset)),
    }
}
```

A `_ =>` wildcard in a match on a protocol enum is the smell. It means a new variant can be added without the compiler requiring its handling.

---

### 2.6 Typed identity wrappers — address routing is reified as a type

Raw `address` and `ID` fields invite silent routing errors: the same primitive type can represent a fee inbox, a refund destination, a cap identity, or an escrow anchor. Wrapping each in a named domain type makes the compiler reject routing to the wrong consumer.

```move
// refund_address.move
public struct RefundAddress    has copy, drop, store { addr: address }

// escrow_identity.move
public struct EscrowIdentity   has copy, drop, store { id: ID }

// owner_cap.move / tenant_cap.move
public struct OwnerCapIdentity has copy, drop, store { id: ID }
public struct TenantCapIdentity has copy, drop, store { id: ID }

// protocol_fee_ref.move
public struct FeeInboxIdentity has copy, drop, store { id: ID }
```

Each type seals its value against accidental use in the wrong context. A `RefundAddress` can only reach `tenant_stake::liquidate`; a `FeeInboxIdentity` can only reach `fee_message::post`. The compiler rejects any attempt to pass one where the other is expected — even though both wrap the same `address` primitive.

The extraction to raw `address` or `ID` is deliberate and visible (`refund_address::addr(r)`, `escrow_identity::escrow_id(e)`), consistent with §2.4. The typed wrapper is the domain type; the extractor is the explicit crossing.

**Test:** `grep -r ": address\b" sources/` in internal function signatures returns zero results outside constructors and event fields.

---

## Applied checklist

When writing or reviewing code in this codebase:

**From Principle 1:**
- [ ] Does any state machine use a `bool` field for a one-way transition? If so, it is a missing enum variant.
- [ ] Does any borrow/return pair have a `_ => abort` on the return side? If so, a cross-object invariant is missing a type.
- [ ] Does any entity carry both identity and balance fields directly, without the Identity + Material split?
- [ ] Is any mutually exclusive state encoded as a nullable field for convenience rather than as a structural `Option` with a precise domain meaning?

**From Principle 2:**
- [ ] Do any internal function signatures contain raw `u64`, `bool`, or anonymous tuples where a domain type exists?
- [ ] Does any module operate on a naked `u64` primitive that belongs to another domain's owner module?
- [ ] Does any computation function accept a `&*Policy` parameter? If so, `resolve()` is missing.
- [ ] Does any function return or accept a raw `Balance<C>` outside its defining module?
- [ ] Is any domain crossing implicit — a `u64` value used directly in arithmetic without a named extractor call?
- [ ] Does any match expression use `_ =>` on a protocol enum variant?
- [ ] Does any internal function signature accept a raw `address` or `ID` where a typed identity wrapper exists?
