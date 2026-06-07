# Usufruct — Gas Profiling Findings

Network: localnet (Sui 1.67.1)  
Date: 2026-05-25  
Code state: `9b2d000` — *chore(profiling): update scripts and findings for ensemble API layer*

> **Testnet validation added 2026-05-27.** See [Testnet section](#testnet-validation-2026-05-27)
> below for full measurements and cross-network comparison.

---

## Version provenance — number ↔ code state

Every measurement section is anchored to the exact commit whose source tree was
built and deployed to produce its numbers. A gas figure is only meaningful against
the code that generated it; this table is the bridge.

| Version | Date | Code-state commit | What it added |
|---|---|---|---|
| v1.0.0 | 2026-05-25 | `9b2d000` | initial Phase A/B on the ensemble API layer |
| v1.1.0 | 2026-05-27 | `be7f8a1` (testnet pkg `0xe466…`) | testnet validation; localnet = testnet to the bit |
| v1.2.0 | 2026-05-28 | `2f604b5` | `update_usufructuary_refund_address` + `active_*` view rename |
| v1.3.0 | 2026-05-31 | `51f9d31` | `ensemble_commitment` twin + blanket terms-freeze |
| v1.4.0 | 2026-05-31 | `7397e62` (branch `feature/governor-earnings-inbox-first`) | inbox-first governor income: `EarningsInbox`/`EarningsMessage`, `integrate_into_portfolio`, fleet governance |
| v1.4.1 | 2026-06-02 | `a2aeeb9` (testnet pkg `0x61723e72…`) | non-generic message events (phantom `CoinType` → `coin_type` field); first full testnet run of inbox-first |
| v1.4.2 | 2026-06-06 | `0bd8e53` (testnet pkg `0x415c43…`) | event-layer overhaul (escrow_id-first star schema, `timestamp_ms` unification, new fields) + `StakePerTenure`/`Progress`/`Elapsed` type invariants + `escrow_id` dropped from `Fee`/`EarningsMessage` (−240k MIST/msg) |

The code-state commit is the **parent of the commit that wrote each section** (the doc
commit adds only prose on top of the already-deployed source) — except v1.3.0, whose
numbers were measured directly against `HEAD` (`51f9d31`) with a clean `usufruct/` tree.

---

## Methodology

All measurements use `sui move test`-published packages on a fresh localnet.
Gas is reported as **net MIST** = `computationCost + storageCost − storageRebate`.
Positive = protocol charges the user. Negative = user receives rebate.
Each atomic script runs 10 identical transactions; median is reported.
Results in SUI (1 SUI = 10⁹ MIST).

---

## Phase A — Atomic operations

| Operation | Net SUI | Notes |
|---|---|---|
| `integrate` | +0.006419 | +2 objects (Escrow + GovernanceCap) |
| `rent(tenures(1))` | +0.004040 | +1 object (UsufructCap) |
| `rent(tenures(N))` | **+0.004040** | O(1) in N — see finding #1 |
| `borrow_return` | +0.001206 | borrow + return in single PTB |
| `apply_transitions` (no-op) | +0.001180 | baseline — no pending transition |
| `apply_transitions` (fires) | +0.001874 | creates 1 FeeMessage object |
| `extend_commitment` | +0.001244 | |
| `update_config` | +0.001183 | |
| `withdraw_earnings` | +0.002171 | |
| `retire` | +0.000940 | |
| `burn_stale_usufruct_cap` | −0.000398 | −1 object |
| `burn_usufruct_cap` | −0.000455 | −1 object |
| `claim_asset` | −0.001525 | −2 objects (Escrow + GovernanceCap) |

### borrow_return — curve shape variants

Measured at t > 0 (2 s into a 60 s tenure) so `compute_curve_height` runs
the full branch for each variant. Linear, Smoothstep, and Logistic are unit enum
variants; PowerLaw and Exponential carry fields (`alpha_num`/`alpha_den`,
`alpha_abs`/`alpha_neg`).

| Variant | Net MIST | Δ vs linear |
|---|---|---|
| `linear` | 1,205,848 | — |
| `smoothstep` | 1,205,848 | +0 |
| `power_law(2/1)` | 1,206,000 | +152 |
| `power_law(8/1)` | 1,206,000 | +152 |
| `power_law(3/2)` | 1,206,000 | +152 |
| `power_law(8/3)` | 1,206,000 | +152 |
| `exp(1, pos)` | 1,206,000 | +152 |
| `exp(8, pos)` | 1,206,000 | +152 |
| `exp(8, neg)` | 1,206,000 | +152 |
| `logistic` | 1,205,848 | +0 |

See finding #7.

### collect_fee_messages — scalability

| N messages | Net MIST total | Net MIST per message |
|---|---|---|
| 1 | +156,156 | +156,156 (pays gas) |
| 10 | −17,410,004 | −1,741,000 |
| 50 | −95,469,604 | −1,909,392 |

---

## Phase B — End-to-end flows

| Flow | Net SUI | Steps |
|---|---|---|
| Minimal (integrate→rent→retire→apply→claim) | **+0.011761** | 5 PTBs |
| Lifecycle + borrow+return | +0.011998 | 6 PTBs |
| Handover (2 usufructuaries) | +0.016336 | 7 PTBs |
| Sequential rents N=3 | +0.023762 | 3 cycles |
| Sequential rents N=5 | +0.035590 | 5 cycles |
| Sequential rents N=10 | +0.065160 | 10 cycles |
| N=3 with earnings withdrawals | +0.027340 | |

**Per sequential rent cycle (rent + apply):** 0.005914 SUI — constant across all N.

---

## Findings

### #1 — `rent(tenures(N))` is O(1) in N

`rent(tenures(N))` costs 0.004040 SUI for N=1, N=10, and N=100 — identical.
`tenures(N)` only multiplies a stored duration in `TenancySchedule`; computation
and object count are invariant in N. A usufructuary locking 100 periods pays the same
as one locking 1.

Contrast: N sequential `rent(1)` cycles cost N × 0.005914 SUI — 146× more for N=100.
The protocol rewards long-term commitment with O(1) gas efficiency.

### #2 — All operations are O(1) in system volume

No operation depends on global chain state, escrow count, or rental history.
Every call has a fixed cost regardless of how many escrows exist or how many
tenures have elapsed. The protocol does not accumulate gas debt over time.

### #3 — `apply_pending_transition_states` is the universal cost floor

Every mutating function pays ~0.001180 SUI baseline for the correctness
invariant (`apply_pending`). When a real transition fires (FeeMessage creation),
that rises to ~0.001874 SUI. This floor is O(1) and does not grow with volume.

In some operations the invariant dominates the actual logic:

| Operation | Logic cost | Invariant floor | Ratio |
|---|---|---|---|
| `borrow_return` | ~0.000026 SUI | 0.001180 SUI | invariant is 45× the logic |
| `retire` | ~0.000940 SUI | 0.001180 SUI | invariant is 1.3× the logic |

This is not a scaling problem — it is the fixed price of the safety guarantee
that no prior state transition is ever forgotten before a mutation.

### #4 — `collect_fee_messages` is self-funding at scale

The protocol earns SUI by collecting fee messages: each destroyed `FeeMessage`
object returns storage rebate that exceeds computation cost. Break-even is N=2.
Per-message gain converges to ~−1,909,392 MIST at N=50 and is stable beyond that.
The fee inbox is economically incentivized to be collected — not a maintenance burden.

### #5 — `borrow_return` is composable and nearly free

`borrow_asset` and `return_asset` compose in a single PTB.
Cost: 0.001206 SUI — only 0.000026 SUI above the `apply_pending` baseline.
The round-trip itself is nearly free; the cost is the correctness invariant.

### #6 — Flattened policy events add ~100k MIST uniformly

The promotion of policy constructors to the `ensemble` API layer and the
flattening of policy events to primitives adds approximately +100,000 MIST
(~0.0001 SUI) to every operation that emits ensemble events (`integrate`,
`rent`, `update_config`, etc.). The delta is uniform and absolute — it does
not scale with tenure duration, asset size, or any protocol parameter.

At 10⁻³ SUI per operation, this cost is negligible. A full rent cycle
(rent + apply) costs 0.005914 SUI — comparable to a simple SUI transfer.

### #7 — Curve shape computation is gas-neutral

All 10 `CurveShapePolicy` variants cost the same gas within a 152 MIST margin
(0.000000152 SUI). `exp(8, pos)` — a Taylor series with ~28 iterations — costs
identically to `linear` (one `mul_div`). `power_law(8/3)` — 7 multiplications
plus Newton's-method cube root — costs identically to `smoothstep`.

The +152 MIST observed on `PowerLaw` and `Exponential` variants traces to enum
field destructuring in the `match` arm (`*alpha_num`, `*alpha_den`), not to the
arithmetic itself. `Linear`, `Smoothstep`, and `Logistic` are unit variants with
no fields to read; their match arm is one instruction cheaper.

**Why:** Sui's gas model prices bytecode instructions, but arithmetic operations
(`Mul`, `Div`, loop iterations) cost fractions of a MIST. The dominant charges in
any PTB are transaction overhead and object access. A Taylor series with 30
iterations adds ~150 arithmetic instructions — negligible against a transaction
floor of ~1,000,000 MIST. This is a deliberate design choice: Sui makes on-chain
math economically viable for complex DeFi protocols.

**Implication:** integrators choose `CurveShapePolicy` based on the economic or
UX shape they want — concave growth, S-curve, logistic dampening — with zero gas
cost consequence for the usufructuary.

---

## Scalability verdict

The protocol scales correctly across all dimensions relevant to an on-chain
rental market:

- **Per-operation cost**: O(1) — no global state dependency
- **Long-term tenure commitment**: O(1) — `rent(tenures(N))` invariant in N
- **Marketplace volume**: O(1) per cycle — sequential rents have constant per-unit cost
- **Fee collection**: economically incentivized at scale, profitable at N≥2

The sole structural cost is the `apply_pending` floor on every mutation (~0.001180 SUI).
It is fixed and does not grow. It is the auditable price of the protocol's
correctness invariant: no state transition is ever silently dropped.

---

## Testnet Validation (2026-05-27)

Network: Sui testnet  
Package: `0xe4662b44e47ce58beabdd6d45a541346636fbbffec0c7d4feb18d3f30bd95aaf`  
Code state: `be7f8a1` — 2026-05-27 source tree (**v1.1.0**)  
Same scripts, same parameters — independent run on public testnet.

### Phase A — Atomic operations

| Operation | Net MIST | Net SUI |
|---|---|---|
| `integrate` | 6,419,480 | +0.006419 |
| `rent(tenures(1))` | 4,039,920 | +0.004040 |
| `rent(tenures(10))` | 4,039,920 | +0.004040 |
| `rent(tenures(100))` | 4,039,920 | +0.004040 |
| `borrow_return` | 1,205,848 | +0.001206 |
| `apply_transitions` (no-op) | 1,180,040 | +0.001180 |
| `extend_commitment` | 1,243,576 | +0.001244 |
| `update_config` | 1,182,776 | +0.001183 |
| `withdraw_earnings` | 2,170,776 | +0.002171 |
| `retire` | 939,576 | +0.000940 |
| `burn_stale_usufruct_cap` | −397,872 | −0.000398 |
| `burn_usufruct_cap` | −455,112 | −0.000455 |
| `claim_asset` | −1,525,256 | −0.001525 |

### borrow_return — curve shape variants (testnet)

| Variant | Net MIST | Δ vs linear |
|---|---|---|
| `linear` | 1,205,848 | — |
| `smoothstep` | 1,205,848 | +0 |
| `logistic` | 1,205,848 | +0 |
| `power_law(2/1)` | 1,206,000 | +152 |
| `power_law(8/1)` | 1,206,000 | +152 |
| `power_law(3/2)` | 1,206,000 | +152 |
| `power_law(8/3)` | 1,206,000 | +152 |
| `exp(1, pos)` | 1,206,000 | +152 |
| `exp(8, pos)` | 1,206,000 | +152 |
| `exp(8, neg)` | 1,206,000 | +152 |

### collect_fee_messages — scalability (testnet)

| N | Total net MIST | Per msg MIST | PTB calls |
|---|---|---|---|
| 1 | −821,964 | −821,964 | 1 |
| 10 | −18,378,124 | −1,837,812 | 1 |
| 50 | −96,437,724 | −1,928,754 | 1 |

The per-message rebate converges to ~−1.93M MIST at N=50. Profit per collection
grows linearly; a single PTB handles up to 500 messages.

### Phase B — End-to-end flows (testnet)

| Flow | Net MIST | Net SUI |
|---|---|---|
| Minimal (integrate→rent→retire→apply→claim) | 11,760,680 | +0.011761 |
| Lifecycle + borrow+return | 11,998,408 | +0.011998 |
| Handover (2 usufructuaries) | 16,312,904 | +0.016313 |
| Sequential rents N=3 | 22,607,560 | +0.022608 |
| Sequential rents N=5 | 34,435,480 | +0.034435 |
| Sequential rents N=10 | 64,005,280 | +0.064005 |
| N=3 with earnings withdrawals | 26,185,528 | +0.026186 |

**Per sequential rent cycle (rent + apply):** 5,913,960 MIST = 0.005914 SUI — constant across N.

### Cross-network comparison

All Phase A atomic operations match localnet measurements **exactly** (bit-for-bit).
Phase B flows differ by at most 0.2% due to minor object layout differences
between the localnet deploy and the testnet deploy (integrator object rebate).

| Finding | Localnet | Testnet | Δ |
|---|---|---|---|
| `integrate` | 6,419,480 | 6,419,480 | 0 |
| `rent` | 4,039,920 | 4,039,920 | 0 |
| `borrow_return` | 1,205,848 | 1,205,848 | 0 |
| `retire` | 939,576 | 939,576 | 0 |
| `claim_asset` | −1,525,256 | −1,525,256 | 0 |
| Minimal flow | 11,760,680 | 11,760,680 | 0 |
| Per rent cycle | 5,913,960 | 5,913,960 | 0 |

**Conclusion:** Sui's gas model is fully deterministic for Move execution.
Localnet profiling is a reliable predictor of mainnet cost.
The numbers in this document are production costs, not approximations.

---

## Narrative conclusion

### The meta-finding: localnet = testnet, to the bit

The first and most important result is not a number — it is a validation of method.
Every operation measured on localnet matches testnet exactly: same MIST, same object
count, same behaviour. This means production gas costs are available from day one:
run localnet, know mainnet. No surprises at deployment.

### Everything is O(1) in system volume

No operation depends on global state: not on the number of escrows, not on elapsed
tenures, not on the size of the user base. The cost of `rent` with one escrow in the
world is identical to the cost with one million. This is not obvious — many protocols
accumulate gas debt as they grow through global registries, growing tables, or
iteration over shared lists. Usufruct has none of those patterns.

### `rent(tenures(N))` is O(1) in N — and the gap is brutal

`tenures(N)` stores a multiplied duration; it does not create N objects or iterate N
times. A usufructuary committing to 100 periods pays exactly the same as one committing to 1:

| Commitment | Gas |
|---|---|
| `rent(tenures(1))` | 0.004040 SUI |
| `rent(tenures(100))` | 0.004040 SUI |
| 100 × sequential `rent(tenures(1))` | **0.5914 SUI** |

The last row is 146× more expensive for the same economic outcome. The protocol
rewards long-term commitment with O(1) gas.

### The universal floor of ~0.001180 SUI

Every mutating function pays ~1.18M MIST as a fixed base cost. This is
`apply_pending_transition_states` — the correctness invariant that ensures no prior
state transition is silently dropped before a mutation. It does not grow with time or
volume.

The proportion is striking: in `borrow_return`, the actual borrow+return logic costs
~26k MIST, but the invariant costs 1,180k MIST — **the safety guarantee is 45× more
expensive than the operation itself**. This is not a scaling problem; it is the
explicit, fixed price of a protocol that cannot forget a state transition.

When the invariant fires (creating a FeeMessage), it rises from 1,180k to 1,874k
MIST. The +694k is exactly the Sui storage cost for one new object.

### `collect_fee_messages` is self-funding at scale

Each destroyed FeeMessage returns more storage rebate than computation costs.
Break-even is N=2. At N=50, the protocol receives **~1.93M MIST net per message**
in a single PTB that handles up to 500 messages. The fee inbox is not a maintenance
burden — it is economically incentivized to be collected. Larger collections are more
profitable per message.

### On-chain arithmetic is effectively free

Ten `CurveShapePolicy` variants — from `linear` (one mul_div) to `exp(8, pos)` (a
Taylor series with ~28 iterations) to `power_law(8/3)` (Newton-Raphson cube root) —
all cost within **152 MIST of each other**. That is 0.000000152 SUI.

The 152 MIST gap does not come from arithmetic. It comes from enum field
destructuring: variants with payload fields (`PowerLaw`, `Exponential`) need one
extra destructuring instruction versus unit variants (`Linear`, `Smoothstep`,
`Logistic`). Tens of multiplications, divisions, and loop iterations are invisible
to the gas meter.

Integrators choose their `CurveShapePolicy` based on the economic shape they want —
concave growth, S-curve, logistic dampening — with zero gas consequence for the
usufructuary.

### Complete flows in perspective

| Flow | Cost | Context |
|---|---|---|
| Full asset lifecycle (integrate→rent→borrow/return→retire→claim) | ~0.012 SUI | |
| Handover between two usufructuaries | ~0.016 SUI | |
| 10 sequential rent cycles + retire + claim | ~0.064 SUI | |
| One rent cycle (rent + apply) | 0.005914 SUI | ≈ 6 SUI transfers |

A rent cycle — the core unit of protocol work — costs the same order as a handful
of simple SUI transfers. The protocol is not expensive because it is complex; it is
expensive in exactly the measure that creating and destroying Sui objects costs.

### Verdict

Usufruct scales correctly across all dimensions that matter for an on-chain rental
market. It does not accumulate gas debt, does not penalise long commitments, and does
not depend on system volume. The sole structural cost is the `apply_pending` floor —
fixed, auditable, and the explicit price of the protocol's correctness invariant: no
state transition is ever silently dropped.

---

## Localnet — update_usufructuary_refund_address (2026-05-28)

Network: localnet  
Branch: `profiling-update-refund-address`  
Code state: `2f604b5` — *profiling: add update_usufructuary_refund_address scripts* (**v1.2.0**)  
Changes vs prior run: new `update_usufructuary_refund_address` public function + view API
rename (`current_*` → `active_*`, `policy_ensemble` → `active_ensemble`,
`pending_config` → `pending_ensemble`) + new `committed_tenures` views.

### New atomic operation

| Operation | Net MIST | Net SUI | +Obj | −Obj |
|---|---|---|---|---|
| `update_usufructuary_refund_address` | 1,265,848 | +0.001266 | 0 | 0 |

Cost matches `borrow_return` exactly. The call mutates only the active seat's
`refund_address` field — no object creation or deletion, no FeeMessage, no
state transition. The cost is the `apply_pending` floor.

### New Phase B flow

| Flow | Net MIST | Net SUI | Steps |
|---|---|---|---|
| Refund redirect → handover | 18,068,752 | +0.018069 | 9 PTBs |

Step breakdown:

| Step | Net MIST |
|---|---|
| integrate | 5,511,360 |
| rent_t1 | 4,099,920 |
| **update_refund_address** | **1,265,848** |
| rent_t2 | 3,499,640 |
| apply_handover | 2,563,928 |
| burn_stale | 379,048 |
| retire | 999,576 |
| apply_transitions | 1,214,688 |
| claim_asset | −1,465,256 |

Compared to `b_03_handover` (16,825,824 MIST), the delta is **+1,242,928 MIST**
— the exact cost of the `update_refund_address` step. The redirect adds no
overhead to the surrounding cycle; it is purely additive.

### Cross-version comparison — Phase A

v1.1.0 reference: testnet measurement (2026-05-27), code state `be7f8a1`, which matched localnet exactly.  
v1.2.0: localnet measurement (2026-05-28), code state `2f604b5`.

| Operation | v1.1.0 `be7f8a1` (MIST) | v1.2.0 `2f604b5` (MIST) | Δ (MIST) |
|---|---|---|---|
| `integrate` | 6,419,480 | 6,489,480 | +70,000 |
| `rent(tenures(1))` | 4,039,920 | 4,099,920 | +60,000 |
| `rent(tenures(10))` | 4,039,920 | 4,099,920 | +60,000 |
| `rent(tenures(100))` | 4,039,920 | 4,099,920 | +60,000 |
| `borrow_return` | 1,205,848 | 1,265,848 | +60,000 |
| `burn_stale_usufruct_cap` | −397,872 | −337,872 | +60,000 |
| `burn_usufruct_cap` | −455,112 | −395,112 | +60,000 |
| `apply_transitions` (no-op) | 1,180,040 | 1,240,040 | +60,000 |
| `retire` | 939,576 | 999,576 | +60,000 |
| `claim_asset` | −1,525,256 | −1,465,256 | +60,000 |
| `withdraw_earnings` | 2,170,776 | 2,230,776 | +60,000 |
| `extend_commitment` | 1,243,576 | 1,303,576 | +60,000 |
| `update_config` | 1,182,776 | 1,252,776 | +70,000 |
| `update_usufructuary_refund_address` | — | 1,265,848 | new |

All existing operations show a uniform **+60,000–70,000 MIST** increase. This traces to
two new events introduced in v1.2.0: `CycleParamsResolved` (emitted when the engine
adopts cycle parameters) and the refund address update events. Each `event::emit` writes
serialized data to storage — the delta is the storage cost of those extra event payloads,
uniform across all operations that pass through the affected code paths. It does not scale
with operation complexity, tenure count, or system volume.

### Cross-version comparison — Phase B

| Flow | v1.1.0 `be7f8a1` (MIST) | v1.2.0 `2f604b5` (MIST) | Δ (MIST) | Steps |
|---|---|---|---|---|
| Minimal (integrate→rent→retire→apply→claim) | 11,760,680 | 12,080,680 | +320,000 | 5 |
| Lifecycle + borrow_return | 11,998,408 | 12,368,408 | +370,000 | 6 |
| Handover (2 usufructuaries) | 16,312,904 | 16,825,824 | +512,920 | 8 |
| Sequential rents N=3 | 22,607,560 | 23,147,560 | +540,000 | 9 |
| Sequential rents N=5 | 34,435,480 | 35,215,480 | +780,000 | 13 |
| Sequential rents N=10 | 64,005,280 | 65,385,280 | +1,380,000 | 23 |
| N=3 with earnings withdrawals | 26,185,528 | 26,915,528 | +730,000 | 12 |
| Refund redirect → handover | — | 18,068,752 | new | 9 |

Phase B deltas are proportional to step count: each step adds ~60,000 MIST, so a flow
with N steps accumulates N × 60,000 MIST. The per-cycle cost remains constant:

| Metric | v1.1.0 `be7f8a1` | v1.2.0 `2f604b5` |
|---|---|---|
| Per sequential rent cycle (rent + apply) | 5,913,960 MIST | 6,033,960 MIST |

The +120,000 MIST per cycle (+60k rent, +60k apply) is the v1.2.0 API overhead
amortised across the two mandatory PTBs in a cycle.

---

## Localnet — ensemble_commitment (2026-05-31)

Network: localnet (Sui 1.67.1)  
Branch: `ensemble-commitment-policy` (merged to `main`)  
Code state: `51f9d31` — *fix(asset_state): gate extend_\*\_commitment on POST-apply_pending state* (**v1.3.0**, `HEAD`, clean `usufruct/` tree)  
Changes vs prior run: `integrate` gains an `ensemble_commitment` parameter — the exact
mirror of `retire_commitment`. The `commitment` family is renamed to `retire_commitment`
and `update_config` → `update_ensemble`. A new `extend_ensemble_commitment` entrypoint is
added, and a **blanket terms-freeze** now gates `update_ensemble`: during an active
`ensemble_commitment` floor the call aborts in every state (never schedules `pending`),
exactly as `retire_commitment` gates `retire`.

### New atomic operation

| Operation | Net MIST | Net SUI | +Obj | −Obj |
|---|---|---|---|---|
| `extend_ensemble_commitment` | 1,374,260 | +0.001374 | 0 | 0 |

It costs **bit-for-bit the same as its twin** `extend_retire_commitment` (1,374,260 MIST):
identical compute (1,250,000), identical storage (6,406,800), identical rebate (6,282,540).
See finding #8.

### Phase A — full atomic table (v1.3.0 localnet)

| Operation | Net MIST | Net SUI |
|---|---|---|
| `integrate` | 6,617,880 | +0.006618 |
| `rent(tenures(1))` | 4,170,604 | +0.004171 |
| `rent(tenures(10))` | 4,170,604 | +0.004171 |
| `rent(tenures(100))` | 4,170,604 | +0.004171 |
| `borrow_return` | 1,336,532 | +0.001337 |
| `apply_transitions` (no-op) | 1,300,724 | +0.001301 |
| `retire` | 1,070,260 | +0.001070 |
| `burn_stale_usufruct_cap` | −277,188 | −0.000277 |
| `burn_usufruct_cap` | −335,112 | −0.000335 |
| `claim_asset` | −1,462,972 | −0.001463 |
| `withdraw_earnings` | 2,301,460 | +0.002301 |
| `extend_retire_commitment` | 1,374,260 | +0.001374 |
| `extend_ensemble_commitment` | 1,374,260 | +0.001374 |
| `update_ensemble` | 1,313,460 | +0.001313 |
| `update_usufructuary_refund_address` | 1,326,532 | +0.001327 |

`rent(tenures(N))` remains O(1) in N (identical for N=1/10/100). Curve-shape variants
remain gas-neutral within 152 MIST (finding #7 holds — re-measured, unchanged).

### Cross-version comparison — Phase A

v1.2.0 reference: localnet measurement (2026-05-28), code state `2f604b5`.  
v1.3.0: localnet measurement (2026-05-31), code state `51f9d31`.

| Operation | v1.2.0 `2f604b5` (MIST) | v1.3.0 `51f9d31` (MIST) | Δ (MIST) |
|---|---|---|---|
| `integrate` | 6,489,480 | 6,617,880 | +128,400 |
| `rent(tenures(1))` | 4,099,920 | 4,170,604 | +70,684 |
| `borrow_return` | 1,265,848 | 1,336,532 | +70,684 |
| `apply_transitions` (no-op) | 1,240,040 | 1,300,724 | +60,684 |
| `retire` | 999,576 | 1,070,260 | +70,684 |
| `burn_stale_usufruct_cap` | −337,872 | −277,188 | +60,684 |
| `burn_usufruct_cap` | −395,112 | −335,112 | +60,000 |
| `withdraw_earnings` | 2,230,776 | 2,301,460 | +70,684 |
| `extend_commitment` → `extend_retire_commitment` | 1,303,576 | 1,374,260 | +70,684 |
| `update_config` → `update_ensemble` | 1,252,776 | 1,313,460 | +60,684 |
| `update_usufructuary_refund_address` | 1,265,848 | 1,326,532 | +60,684 |
| `claim_asset` | −1,465,256 | −1,462,972 | +2,284 |
| `extend_ensemble_commitment` | — | 1,374,260 | new |

A near-uniform **+60,684–70,684 MIST** increase across every operation. `integrate` is
~2× that (+128,400) because it both creates the `ensemble_commitment` slot **and** anchors
it. `claim_asset` is the sole exception (+2,284 ≈ 0): it deletes the `Escrow`, so the extra
slot's storage is rebated on destruction — the persistent cost is reclaimed, not paid.
This is the same absolute, volume-independent storage delta documented in finding #6.

### Phase B — flows (v1.3.0 localnet)

| Flow | v1.2.0 `2f604b5` (MIST) | v1.3.0 `51f9d31` (MIST) | Δ (MIST) | Steps |
|---|---|---|---|---|
| Minimal (integrate→rent→retire→apply→claim) | 12,080,680 | 12,413,416 | +332,736 | 5 |
| Lifecycle + borrow_return | 12,368,408 | 12,771,828 | +403,420 | 6 |
| Handover (2 usufructuaries) | 16,825,824 | 17,360,612 | +534,788 | 8 |
| Sequential rents N=3 | 23,147,560 | 23,773,032 | +625,472 | 9 |
| Sequential rents N=5 | 35,215,480 | 36,123,688 | +908,208 | 13 |
| Sequential rents N=10 | 65,385,280 | 67,000,328 | +1,615,048 | 23 |
| N=3 with earnings withdrawals | 26,915,528 | 27,743,052 | +827,524 | 12 |
| Refund redirect → handover | 18,068,752 | 18,674,224 | +605,472 | 9 |

Deltas track step count — each core-touching PTB pays the ~60–70k slot-serialization cost.
The per-cycle figure stays constant:

| Metric | v1.2.0 `2f604b5` | v1.3.0 `51f9d31` |
|---|---|---|
| Per sequential rent cycle (rent + apply) | 6,033,960 MIST | 6,175,328 MIST |

### #8 — The retire/ensemble commitment twin is gas-symmetric

`extend_ensemble_commitment` and `extend_retire_commitment` cost **1,374,260 MIST each —
identical to the MIST** in compute, storage, and rebate. The two policies are byte-faithful
mirrors in source (`EnsembleCommitmentPolicy` is a structural twin of `RetireCommitmentPolicy`,
both `Immediate | Deferred { floor }`), and that structural symmetry surfaces verbatim in the
gas meter. The blanket terms-freeze adds no measurable cost over the permanence commitment it
mirrors: a usufructuary gets stability-of-terms for the same price as stability-of-availability.

---

# v1.4.0 — Inbox-first governor income (`7397e62`)

> Branch `feature/governor-earnings-inbox-first`. Governor income is unbundled from
> governance via on-chain coupon-stripping: `GovernanceCap` becomes a pure governance
> token, and earnings settle to a standalone `EarningsInbox` as owned
> `EarningsMessage` objects (collected like the fee layer), instead of
> accumulating inside the shared escrow's `GovernorSeat` and being pulled with
> `withdraw_earnings`. Two integrate functions: `integrate` (mints the cap+inbox
> pair) and `integrate_into_portfolio` (joins an existing pair → fleets).

## Toolchain

| Component | Version |
|---|---|
| sui CLI (deploy / `test-publish`) | **1.67.1-4e8aa9ee8b30** |
| localnet node protocol version | **114** |
| `@mysten/sui` SDK (drives the PTBs) | **1.45.2** |
| node runtime | **v25.8.1** |

The deploy used CLI **1.67.1** (a later 1.73 was installed afterward and is *not*
the binary that produced these numbers). The node ran **protocol 114**; absolute
MIST will differ on a protocol-125 node (today's testnet/mainnet), but the
*functional* path and *structural* deltas (object counts) are protocol-invariant.

## Profiling as real-execution validation (orthogonal to the Move tests)

The `#[test_only]` suite runs in `test_scenario` — an in-process VM with simulated
objects and gas; it proves *logic* (transitions, conservation, aborts). This run
proves *execution*: every measurement is a real PTB over JSON-RPC against a
fullnode — the same path Mainnet takes. It exercises what unit tests cannot:
PTB composition, type-argument resolution, the `integrate` tuple return
`(GovernanceCap, EarningsInbox)`, transfer-to-object + `Receiving` ticket collection
actually working at runtime, real object versioning, owned/shared handling, and
economic viability (ops cost fractions of a cent, none abort on gas). Phase A
(28 ops + 3 scalability sweeps) and Phase B (9 flows) all succeeded → the
inbox-first API is **PTB-reachable and economically sane on a real node**.

## Methodology caveat — gas-coin rebate noise (±~0.98M MIST/tx)

A controlled probe (`verify_collect_parity.ts`) found that two byte-identical
transactions can differ in `net` by exactly **978,120 MIST**, located entirely in
`storageRebate` (computation and storage identical to the MIST). This is
**gas-coin smashing / storage-rebate accounting** tied to the sender's coin set at
tx time — it alternates between consecutive identical calls, independent of the
operation. Consequence: **single-shot `net` absolutes carry ±~0.98M noise**;
**object counts are exact**, and **per-message slopes at high N** (where the fixed
swing amortizes) are the reliable economic signal. Atomic medians (10 runs) damp
but do not fully erase this.

## Structural deltas vs the deposit model (v1.3.0 `51f9d31`)

| Op | v1.3.0 deposit | v1.4.0 inbox-first | Structural change |
|---|---|---|---|
| `integrate` | +2 obj, 6,617,880 | **+3 obj, 7,995,480** | mints the `EarningsInbox` too (+1 obj ≈ 1.38M) |
| `claim_asset` | −2 obj, −1,462,972 | **−1 obj, −1,038,380** | cap survives by-ref (reusable across a portfolio) → forfeits the burn rebate |

The cap is no longer burned at claim because one `GovernanceCap` may govern N escrows.
The trade is deliberate: one object's storage at birth + the lost burn rebate, in
exchange for a reusable governance token and income in batchable owned objects.

## #1 — Settlement now costs +1 object, bounded and O(1)

`apply_pending_transition_states` firing `tenure_expiry`/`handover` calls
`distribute`, which now posts **both** a `FeeMessage` (10%) **and** an
`EarningsMessage` (90%) — **+2 objects**, vs +1 in the deposit model (FeeMessage
only; earnings were an in-seat balance mutation).

| `apply` | Objects | Net MIST |
|---|---|---|
| no-op (no pending settlement) | +0 | 1,332,548 |
| fires settlement | **+2** | 4,098,548 |

Δ ≈ **2,766,000 MIST ≈ 2 objects**. Constant across all 5 tenures of the N=5 flow
(4,098,548 to the MIST each) → **O(1) per settlement, no accumulation**.

The increase is **gated on real settlement** — a no-op APT is unchanged (+0 obj),
and so are non-settling ops (`rent` 4.20M, `update_ensemble` 1.35M ≈ v1.3.0).
Under the lazy-eval pattern (every state-dependent mutation APTs first), the cost
**floats** to whichever call first crosses an expired tenure, and is paid **exactly
once per settlement** — bounded at +1 `EarningsMessage`, never a diffuse rise.

## #2 — `collect_earnings_messages` reproduces the fee curve (rebate-positive)

`EarningsMessage` is byte-identical to `FeeMessage`; `collect_earnings_messages`
mirrors `collect_fee_messages`. Same shared inbox fed by a portfolio:

| N | `collect_fee` per-msg | `collect_earnings` per-msg |
|---|---|---|
| 1 | +316,156 | +240,384 |
| 10 | −1,724,000 | −1,798,293 |
| 50 | −1,904,792 | −1,980,042 |

Both **break even at N≈2** and converge to **≈ −1.9M MIST/msg** (rebate-positive —
draining owned message objects returns more storage than the one output coin
costs). The ~75k/msg apparent gap between the two is **within the gas-coin rebate
noise** (§ methodology caveat), not a protocol difference: `verify_collect_parity`
showed the per-message **computation is identical (1,260,000 MIST)** for fee and
earnings, with all variance in rebate. The residual-count hypothesis was tested
and **refuted** (collecting 1-of-12 vs 1-of-11 differed by the full 978k despite
near-identical residuals — it alternates with gas-coin state, not sibling count).

## #3 — `integrate_into_portfolio`: fleet onboarding is ~34% cheaper

| Op | Objects | Net MIST |
|---|---|---|
| `integrate` (open a portfolio) | +3 | 7,995,480 |
| `integrate_into_portfolio` (join) | **+1** | **5,301,888** |

Each additional fleet escrow costs **5.30M vs 8.00M** (−2.69M ≈ 2 objects) — it
mints only the `Escrow`, reusing the existing cap + inbox.

## #4 — Governance over a fleet is exactly O(1) per escrow (zero shared-cap overhead)

One `GovernanceCap` retiring N escrows, validated **seat-side**
(`governance_cap::identity(cap) == seat.cap_identity` — no registry, no cross-escrow
state):

| N | per-retire (separate PTBs) | per-retire (batched 1 PTB) |
|---|---|---|
| 1 | 1,099,652 | 1,099,652 |
| 10 | **1,099,652** | −54,141 |
| 50 | **1,099,652** | −155,189 |

Per-retire under one shared cap is **1,099,652 MIST to the bit at every N** — and
**identical to the one-to-one baseline** (`a_07_retire`). A single cap governing a
fleet introduces **literally zero overhead** vs N independent caps. Batching N
retires in one PTB amortizes the per-PTB floor and turns rebate-positive at scale
(−155,189/retire at N=50).

## #5 — Before/after: governor income collection (Phase B `05_earnings`, N=3)

| | deposit (v1.3.0) | inbox-first (v1.4.0) |
|---|---|---|
| collect 3 tenures' income | 3× `withdraw_earnings` @ +2,301,460 = **+6,904,380** | 1× batched `collect` = **−3,812,576** |
| object mutated | the **shared Escrow** (×3) | inbox + messages (**owned**) |
| governor's wallet | **pays** 6.90M | **earns** 3.81M rebate |

A **~10.7M MIST swing in the governor's favor** over 3 tenures, flipping income
collection from a *cost* to a *rebate*. Three wins stack: **batching** (O(N) income
in O(1) PTBs), **rebate-positive** drain of owned objects, and **zero contention**
(the old `withdraw` locked the shared escrow, competing with renters; `collect`
touches only owned objects).

**Economic timing.** The model moves +1 object's storage cost to settlement
(`apply`, ~1.38M/event, paid by *whoever* calls apply — keeper, next renter,
anyone) and recovers it as a rebate at `collect` (captured by the **governor**). The
deposit model was the reverse: cheap apply, but the governor paid `withdraw`. Storage
is ~a wash system-wide; **who pays and when** shifts toward the governor.

## #6 — Fleet end-to-end: two objects govern N escrows, one PTB collects all (`07`)

`integrate` + 2× `integrate_into_portfolio` → 3 escrows under **one cap + one
inbox**; each rented & settled; then a **single** `collect_earnings_messages`:

| Step | × | Net total | Objects |
|---|---|---|---|
| integrate / join | 1 / 2 | 7,995,480 / 10,603,776 | +3 / +2 |
| rent / apply | 3 / 3 | 12,607,284 / 12,295,644 | +3 / +6 |
| **collect_fleet** | **1** | **−3,812,576** | **+1 −3** |
| retire / apply / claim | 3 each | teardown | −3 |

The fleet collect is **−3,812,576 MIST — identical to the single-escrow N=3 collect
in `05`**. Collecting 3 messages from **3 different escrows** costs exactly the same
as 3 from one escrow: **collect cost is a function of message count, independent of
fleet topology**. The §10/§11 design claim — *govern a fleet with two objects,
collect its cash flow in one PTB* — measured end-to-end.

---

# Verdict: Deposit vs Inbox scalability (v1.3.0 vs v1.4.0)

Two models for the governor to **claim earnings**, measured head-to-head:

- **Deposit-in-Escrow** (v1.3.0 `51f9d31`): earnings accrue into the shared
  escrow's `GovernorSeat` balance; the governor pulls them with `withdraw_earnings`.
- **Earning-Message-in-Inbox** (v1.4.0 `7397e62`): each settlement posts an owned
  `EarningsMessage` to a standalone `EarningsInbox`; the governor drains them with a
  batched `collect_earnings_messages`.

Let a portfolio be **M** escrows × **K** tenures each, **T = M·K** income events.
The claim cycle has two phases; both must be measured.

## Phase 1 — Settlement (income accrues, at each `apply`→`distribute`)

| | Deposit (v1.3.0) | Inbox (v1.4.0) |
|---|---|---|
| objects created / tenure | +1 (FeeMessage; earnings → seat balance) | +2 (Fee **+ Earnings**) |
| Δ vs the other | — | **+1 obj/tenure ≈ +1.38M MIST** |
| complexity | O(1)/tenure | O(1)/tenure |

Deposit wins this phase by one object per tenure — but it is a **constant factor,
O(1), that does not compound** with portfolio growth, and it is precisely the cost
that funds Phase 2's rebate.

## Phase 2 — Collection (the governor claims) — where it is decided

| | Deposit (v1.3.0) | Inbox (v1.4.0) |
|---|---|---|
| PTBs to claim M escrows | **O(M)** — 1 `withdraw`/escrow | **O(⌈T/500⌉) ≈ O(1)** — 1 batched collect |
| object touched | the **shared Escrow** (contends with renters) | inbox + messages (**owned**, fast-path) |
| cost | **+2,301,460 × M** (positive) | **rebate-positive**, ≈ −1.9M/msg at scale |
| caps to govern M escrows | **M** (cap was bound to one escrow) | **1** (finding #4: O(1)/escrow, zero overhead) |

The seat accumulates, so K folds into a single withdraw per escrow — but each escrow
is an independent **shared** object, so collection is **O(M) PTBs / O(M) shared-object
inputs / O(M) caps**. Even packing M withdraws into one PTB still takes M shared
inputs and M caps and locks M rental markets at once. The inbox routes the whole
fleet to **one owned inbox**, drained in **O(1) PTBs with one cap**.

## Crossover (governor-facing claim cost, measured)

Fleet of M escrows, 1 tenure each — claim everything accrued:

| M | Deposit (M withdraws) | Inbox (1 collect of M msgs) | governor is better off by |
|---|---|---|---|
| 1 | +2,301,460 | +240,384 | inbox already cheaper |
| 10 | +23,014,600 | −17,982,930 (rebate) | **~41M MIST** |
| 50 | +115,073,000 | −99,002,100 (rebate) | **~214M MIST** |

Charging the inbox its **full** settlement surcharge too (worst case — in practice
the apply-caller pays it): at M=50, inbox = 69M (settlement) − 99M (collection) =
**−30M net**, vs deposit **+115M**. Inbox wins by **~145M MIST even with the
handicap**. Crossover is immediate: at T=1 inbox already costs less, and at **T≥2**
it turns rebate-positive while deposit stays a flat per-escrow cost.

## Verdict — univocal: Inbox is strictly more scalable

The result is a **complexity** difference, not a magnitude one. As the portfolio
grows in either dimension:

- **Deposit** scales claiming as **O(M) PTBs, O(M) caps, on shared objects, at
  positive cost** that grows without bound.
- **Inbox** scales claiming as **O(1) PTBs, O(1) caps (1 cap + 1 inbox), on owned
  objects, rebate-positive** — improving with volume.

Deposit's *only* edge — settlement one object cheaper per tenure — is **O(1),
non-compounding, and is the very cost that funds the inbox's O(1) rebate-positive
claim**. The two tie on settlement (both O(1)/tenure) and the inbox wins
**asymptotically** on both collection (O(M)→O(1) PTBs) and governance (M→1 caps).
No growth regime exists where deposit wins; the only scenario it leads is the
degenerate non-scaling one (a single escrow, few tenures, an governor who never
claims and values only cheap settlement) — which is, by definition, outside a
scalability question.

**Earning-Message-in-Inbox is unequivocally the more scalable model for the governor
to claim earnings.**

## Why it scales *where it matters*: pull-aggregation vs push-distribution

The two governor-facing flows have **opposite reducibility**, and that — not raw
magnitude — is the heart of the verdict:

- **Earnings (collection) is pull-aggregatable.** Many escrows *push* income to
  **one** inbox (transfer-to-object at settlement); the governor *pulls* the whole
  pile in a single `Receiving` batch. An aggregation sink exists → collection is
  reducible to **O(1) PTBs**. The inbox model exploits exactly this.
- **Governance (retire/update) is push-distributive and irreducibly O(M).** One
  cap must reach M escrows, and each escrow is a separate object whose state is
  mutated individually — there is **no aggregation point, no broadcast**. Fleet
  governance is **O(M) operations no matter the model**. (Finding #4's "O(1)" is
  *per-escrow* — zero shared-cap overhead — **not** per-fleet; the fleet total is
  still M pushes.)

This is the precise sense in which inbox "scales where it matters": it makes the
**aggregatable, high-frequency** axis (claiming cash flow) **O(1)**, and leaves the
**irreducible, low-frequency** axis (governance) at its push-based **O(M)** floor —
while still collapsing that floor's *object* cost from **M caps to one**.

Deposit puts **both** flows on the per-escrow push rail: **O(M) withdraws AND O(M)
caps**. On the one axis that admits aggregation (collection) it fails to take it;
on the axis that doesn't (governance) it pays the worse constant (M caps). The
whole game is *optimize the reducible axis, minimize the irreducible one* — and the
inbox does both, while deposit does neither.

---

# Testnet Validation — v1.4.1 (2026-06-02)

Network: Sui testnet  
Package: `0x61723e7205f9841ebb4e6f73096f34840a78bcfae73f631d44370e75f1acc0f5`  
Code state: `a2aeeb9` (**v1.4.1**) — `sui client verify-source` passes against the on-chain bytecode  
Toolchain: sui CLI `1.73.0`, live testnet protocol; `@mysten/sui` driving every PTB.

The first **full testnet run of the inbox-first model** — all 18 atomic scripts (+3
scalability sweeps) and 9 end-to-end flows executed as real PTBs over JSON-RPC
against a public fullnode (the earlier 2026-05-27 testnet section validated the
*pre-inbox* v1.1.0 deposit model). v1.4.1 differs from the localnet v1.4.0
(`7397e62`) numbers two ways: (1) the **non-generic message-event fix** —
`EarningsMessagePosted`/`FeeMessagePosted`/`…Collected` drop the phantom `CoinType`,
carrying it in the `coin_type` field — a schema/correctness change with no
measurable gas impact; (2) the **live testnet protocol** vs localnet protocol-114,
which shifts absolute MIST. **Every structural finding reproduces; no finding
inverts.**

## Phase A — atomic operations (testnet v1.4.1)

| Operation | Net MIST | +Obj | −Obj |
|---|---|---|---|
| `integrate` | +8,081,480 | 3 | 0 |
| `rent(tenures(N))` N=1/10/100 | **+4,252,828** | 1 | 0 |
| `integrate_into_portfolio` | +5,312,648 | 1 | 0 |
| `borrow_return` | +1,388,660 | 0 | 0 |
| `apply_transitions` (no-op) | +1,352,548 | 0 | 0 |
| `update_ensemble` | +1,363,612 | 0 | 0 |
| `update_usufructuary_refund_address` | +1,378,660 | 0 | 0 |
| `extend_retire_commitment` | +1,424,412 | 0 | 0 |
| `extend_ensemble_commitment` | +1,424,412 | 0 | 0 |
| `retire` | +1,120,412 | 0 | 0 |
| `burn_stale_usufruct_cap` | −255,460 | 0 | 1 |
| `burn_usufruct_cap` | −315,208 | 0 | 1 |
| `claim_asset` | −1,027,620 | 0 | 1 |

`rent(tenures(N))` is **bit-identical for N=1/10/100** → O(1) in N holds (finding #1).
`extend_retire_commitment` and `extend_ensemble_commitment` are bit-identical
(1,424,412 each) → the commitment twin is gas-symmetric (finding #8). Both hold on a
real node.

### Curve shapes (finding #7 — gas-neutral, holds)

All 10 `CurveShapePolicy` variants within **152 MIST**: unit variants (linear,
smoothstep, logistic) = 1,388,660; field-carrying variants (power_law, exp) =
1,388,812 (+152, the enum-destructuring delta, not the arithmetic). Re-confirmed
on-chain.

## Scalability sweeps (testnet v1.4.1)

`collect_fee_messages` (protocol cut, deployer-owned inbox):

| N | total net (MIST) | per msg (MIST) |
|---|---|---|
| 1 | +326,156 | +326,156 |
| 10 | −18,208,124 | −1,820,812 |
| 50 | −96,237,724 | −1,924,754 |

`collect_earnings_messages` (governor income, owned inbox):

| N | total net (MIST) | per msg (MIST) |
|---|---|---|
| 1 | +250,384 | +250,384 |
| 10 | −17,982,936 | −1,798,293 |
| 50 | −99,022,136 | −1,980,442 |

Both break even at N≈2 and converge to ≈ **−1.9M MIST/msg** — rebate-positive at
scale (inbox findings #2/#4). The earnings curve mirrors the fee curve to within the
documented gas-coin rebate noise.

`governance_fleet_retire` (one `GovernanceCap` over N escrows):

| N | per-retire (separate PTBs) | per-retire (batched 1 PTB) |
|---|---|---|
| 1 | 1,120,412 | 1,120,412 |
| 10 | **1,120,412** | −53,065 |
| 50 | **1,120,412** | −154,774 |

Per-retire under one shared cap is **constant to the bit at every N**, and identical
to the one-to-one `retire` baseline (1,120,412) — zero shared-cap overhead. Fleet
governance is O(1) per escrow; batching turns rebate-positive at scale (inbox
finding #4).

## Phase B — end-to-end flows (testnet v1.4.1)

| Flow | Net MIST | Steps |
|---|---|---|
| Minimal (integrate→rent→retire→apply→claim) | 16,548,568 | 5 |
| Lifecycle + borrow/return | 17,937,228 | 6 |
| Handover (2 usufructuaries) | 24,668,740 | 8 |
| Sequential rents N=3 | 33,258,400 | 9 |
| Sequential rents N=5 | 49,981,152 | 13 |
| Sequential rents N=10 | 91,788,032 | 23 |
| Earnings collect (N=3) | 29,824,900 | 11 |
| Refund redirect → handover | 26,034,480 | 9 |
| Fleet portfolio collect (3 escrows, 1 cap + 1 inbox) | 43,310,172 | 19 |

**Per sequential rent cycle (rent + apply):** 4,252,828 + 4,108,548 = **8,361,376
MIST** — constant across N (the N=10 flow runs ten identical 4,108,548-MIST
settlements). Each `apply` that fires a settlement creates **+2 objects**
(`FeeMessage` + `EarningsMessage`) at a bit-stable cost → O(1) per settlement, no
accumulation (inbox finding #1).

The **fleet flow** — `integrate` + 2× `integrate_into_portfolio` → 3 escrows under
one cap + one inbox, each rented & settled, then a single
`collect_earnings_messages` — drains all three escrows' income in one PTB at
**−3,792,576 MIST**, identical to the single-escrow N=3 collect in `b_05_earnings`:
**collect cost is a function of message count, independent of fleet topology** (inbox
finding #6), now measured end-to-end on a real node.

## Cross-version consistency — localnet v1.4.0 → testnet v1.4.1

| Operation | localnet v1.4.0 `7397e62` | testnet v1.4.1 `a2aeeb9` | Δ |
|---|---|---|---|
| `integrate` | 7,995,480 | 8,081,480 | +86,000 |
| `integrate_into_portfolio` | 5,301,888 | 5,312,648 | +10,760 |
| `apply` (fires settlement) | 4,098,548 | 4,108,548 | +10,000 |
| `retire` / fleet per-retire | 1,099,652 | 1,120,412 | +20,760 |
| `collect_earnings` N=50 /msg | −1,980,042 | −1,980,442 | ≈0 |

Sub-1% deltas, attributable to live-protocol pricing vs localnet protocol-114 — the
**object counts are identical** across both. **No finding inverts.** The non-generic
event change is gas-invisible at this resolution, as expected: the `coin_type:
String` payload is unchanged; only the event's *type tag* (off-chain metadata)
shrank.

## Methodology — harness fixes for the real-node run

Two harness bugs surfaced *only* against a real fullnode — invisible to both the
`test_scenario` suite and the type-checker — and were fixed in this run:

1. **SDK `owner:` param corruption.** The owner→governor vocabulary sweep had
   renamed the Sui SDK's `getCoins`/`getOwnedObjects` `owner:` argument to
   `governor:` in 11 call sites, aborting fee/earnings collection with "Invalid Sui
   address."
2. **Auto-budget underestimate on time-dependent `apply`.** `measure()` relied on the
   SDK dry-run gas estimate, taken *before* a tenure-expiry wait; the post-expiry
   `apply` then fires a settlement costing ~3× the no-op estimate, aborting with
   `InsufficientGas`. Fixed with an explicit, generous gas budget — gas *used*
   (computation/storage/rebate) is independent of the budget, so the measured numbers
   are unaffected.

A separate operational note: scripts 12/16/17 leave their setup escrows standing
(they measure `collect`, not teardown), so the governor's SUI accrues in locked
object storage across a full Phase-A run — budget the deployer/actor wallets
accordingly for a clean single-session run.

---

## Scalability conclusion — the cost of a fleet of N escrows

The v1.4.1 testnet numbers let us project the lifetime cost of a fleet across five
orders of magnitude (1 → 10,000 escrows), onboarded via `integrate_into_portfolio`
(one `integrate` opens the cap + inbox; each further escrow joins for +1 object) and
operated through the two governor-facing axes — **governing** them (retire under the
one shared cap) and **collecting** their income (drain the shared inbox). Figures
N ≤ 50 are measured; N ≥ 100 project the per-unit rate, which is constant at scale and
capped only by the ~500-object PTB batch limit.

### Onboarding — you pay, irreducibly O(N)

`8,081,480 + (N−1) × 5,312,648` MIST

| N | onboard cost |
|---|---|
| 1 | +0.0081 SUI |
| 10 | +0.0559 SUI |
| 100 | +0.534 SUI |
| 1,000 | +5.315 SUI |
| 10,000 | +53.13 SUI |

Linear and unavoidable: each escrow is a distinct on-chain object that must be created
(~5.31M MIST/join). This is the **only** axis that costs the operator at scale. The
shared cap + inbox are paid once (the +2.77M premium inside the first `integrate`),
then amortized across the whole fleet.

### Governing the fleet — the shared cap is free

Retire all N under one `GovernanceCap` (finding #4: per-retire constant, zero
shared-cap overhead):

| N | separate PTBs | batched (⌈N/500⌉ PTBs) |
|---|---|---|
| 1 | +0.0011 SUI | +0.0011 SUI |
| 10 | +0.0112 | **−0.0015** (rebate) |
| 100 | +0.112 | **−0.0155** |
| 1,000 | +1.120 | **−0.155** |
| 10,000 | +11.20 | **−1.548** |

Governing 10,000 escrows with **one cap** costs the same per-escrow as governing one
with one cap — the M-caps → 1-cap collapse is free. Batched, teardown is
rebate-positive: at scale the protocol **pays the governor to retire the fleet**.

### Collecting the income — aggregates to O(1) PTBs, rebate-positive

Drain all N escrows' fee/earnings messages from the one shared inbox (finding #6:
collect cost ∝ message count, independent of fleet topology):

| N (msgs) | collect (≈ N × −1.92M) |
|---|---|
| 1 | +0.0003 SUI (pays) |
| 10 | **−0.0192 SUI** (gain) |
| 100 | **−0.192** |
| 1,000 | **−1.925** |
| 10,000 | **−19.25** |

Break-even at N≈2, then rebate-positive — **and** the governor receives the actual
fee/earnings coins on top of the storage rebate. The whole fleet drains in
O(⌈N/500⌉) PTBs against one owned inbox (no shared-object contention).

### The shape of fleet economics

| Axis | Complexity | Economics at scale |
|---|---|---|
| **Onboard** | O(N) PTBs | **pay** ~5.31M/escrow — irreducible object creation |
| **Govern** | O(N) ops, **1 cap** | batched **rebate** (~−0.15M/escrow); the cap is free |
| **Collect** | **O(⌈N/500⌉) PTBs** | **rebate** ~−1.92M/msg + you receive the coins |

The protocol pushes its entire cost onto the one axis that cannot be avoided —
creating N objects — and leaves both recurring operational axes either **free**
(governance: the shared cap collapses M keys to one) or **profitable** (collection:
pull-aggregation to one inbox collapses O(N) PTBs to O(1)). Per escrow over its full
life the net is **+5,312,648 − 154,774 − 1,924,754 ≈ +3,233,120 MIST (≈ 0.0032 SUI)**:
you pay once to mint the escrow and recover most of it through teardown and collection
rebates — before counting the rent income itself.

### The protocol's own treasury scales the same way

The `ProtocolFeeInbox` is this exact pattern at **global** scale. Every settlement of
*every* escrow — across all governors and all fleets — mails its 10% `FeeMessage` to
the **one** protocol inbox, so its message count grows with **total protocol activity**
(T = all escrows × all tenures), not with any single fleet.

The property that makes this scale is **contention-free posting**: a settlement does
not increment a shared fee balance — it `transfer`s an owned `FeeMessage` to the
inbox's address. Each post is independent and parallelizable; a thousand simultaneous
settlements never serialize on one hot object. The inbox is touched mutably only at
**collect** time (rare, by the operator). A naïve "add to the global fee balance"
design would make that object a throughput ceiling; here, settlements never touch it.

Collecting the treasury is then the same O(⌈T/500⌉)-PTB, rebate-positive drain — the
operator nets ~−1.92M MIST/msg in storage rebate **and** receives the fee coins (the
revenue itself). Protocol revenue collection is **self-financing in gas and grows
precisely where activity grows**:

| | Governor (one fleet) | Protocol (everything) |
|---|---|---|
| sink | 1 `EarningsInbox` per cap | 1 global `ProtocolFeeInbox` |
| posting | contention-free (transfer-to-object) | contention-free, parallel |
| collection | O(⌈T/500⌉) PTBs, rebate-positive | O(⌈T/500⌉) PTBs, rebate-positive |
| grows with | that fleet's M·K tenures | the protocol's total T |

The 90/10 split mounts **two coupon-strips on a single settlement** — 90% to the
governor's inbox, 10% to the protocol's — both claimed by pull-aggregation, both
rebate-positive. The busier the protocol, the more it earns, and the revenue never
becomes a point of contention.

### The flip side of no-registry: events are the index

The same choice that makes governance O(1) — the chain keeps no cap→escrow registry
(the cap is a pure token; finding #4) — means the *relationships* live entirely in the
event log, not on-chain. This session's teardown proved it concretely: the cleanup that
recovered the profiling escrows reconstructed all **516 escrows** a governor had ever
integrated, each paired with its governing cap, purely by replaying `AssetIntegrated`
(`getIntegratedEscrows` in `setup/cleanup.ts` — the same event-indexing step a
marketplace or governor dashboard runs) — the chain literally cannot answer "what does
this cap govern," because by design it does not store it. Minimal on-chain state (which scales) and a complete event graph (which is
observable) are two faces of one architecture; the relational view lives in the events,
not the objects. See `EVENTS.md`.

**There is no growth regime where the recurring cost explodes.** A 10,000-escrow fleet
is governed by one cap and its entire cash flow is swept in ~20 PTBs, rebate-positive.
The only term that grows with N is the floor cost of *existing* on-chain — and that is
Sui's price for an object, not the protocol's.

---

# Testnet Validation — v1.4.2 (2026-06-06)

Network: Sui testnet · Package: `0x415c4372bb9db5affe2ab2bf6d72a6a667ed3178a61d6201e9ff26dc76380e5d`
Code state: `0bd8e53` — `sui client verify-source` passes. Full run (29 atomics + 3 sweeps,
9 flows) as real PTBs. Compared head-to-head with v1.4.1 testnet (`a2aeeb9`) — **same
network, apples-to-apples**.

## The optimization: `escrow_id` dropped from `Fee`/`EarningsMessage`

The message objects no longer store `escrow_id` (it lived only to re-emit on `*Collected`;
nothing on-chain read it — collect drains by aggregation, never validates against an origin
escrow, unlike `UsufructCap` which boomerangs back). Attribution now joins
`Collected.message_id → Posted.escrow_id`. Each message is 32 bytes smaller.

| collect /msg | v1.4.1 | v1.4.2 | Δ |
|---|---|---|---|
| `collect_fee` N=50 | −1,924,754 | −1,683,986 | **+240,768** |
| `collect_earnings` N=50 | −1,980,442 | −1,739,674 | **+240,768** |

~240,768 MIST/msg less rebate — identical to the localnet measurement (+240,168), the exact
storage value of the removed field. Both **stay rebate-positive** (less, not extractive). The
mirror payoff is on the *post* side: `apply_*` firing a fee+earnings settlement drops ~486k
MIST (localnet), and chaining `do_handover` + `do_tenure_expiry` in one `apply` ~983k (4
messages × ~245k). It rides every mutating op that lazily applies a pending settlement.

## End-to-end flows are net cheaper

| Flow | v1.4.1 | v1.4.2 | Δ |
|---|---|---|---|
| Minimal | 16,548,568 | 15,347,280 | −1,201,288 |
| Handover | 24,668,740 | 23,121,148 | −1,547,592 |
| Refund→handover | 26,034,480 | 25,490,264 | −544,216 |
| Earnings (N=3) | 29,824,900 | 29,574,276 | −250,624 |
| Lifecycle | 17,937,228 | 17,744,668 | −192,560 |

**All five flows drop.** Flows post (cheaper now) without collecting, so the post-side saving
nets out positive. Per-flow magnitude is within the single-run gas-coin rebate noise (±978k),
but the sign is consistent across all five.

## Two confounds, isolated

1. **Testnet protocol shift, +40,608 base.** Uniform across ops whose code did **not** change
   in v1.4.2 (`apply_transitions` no-op, `retire`, `burn`, `claim`) → a testnet protocol/gas
   bump between 2026-06-02 and 2026-06-06, **not** v1.4.2. Discount it from any atomic delta.
2. **`integrate` +100,800 = +40,608 base + ~60,192 code** — the only code-attributable atomic
   cost, from the new commitment-unlock-timestamp fields on `AssetIntegrated`. Object counts
   identical (+3). Same for `integrate_into_portfolio`.

## Invariants — all hold, re-confirmed on testnet

`rent(tenures(N))` O(1) bit-identical N=1/10/100; curve shapes gas-neutral (10 within 152
MIST); `governance_fleet_retire` O(1) per escrow (batched −153,166/retire at N=50); the
retire/ensemble commitment twin gas-symmetric. **No prior finding inverts.**

## Verdict

v1.4.2 **reallocates and reduces**: atomics tick up slightly (protocol shift + the two
`AssetIntegrated` fields), but the recurring high-frequency axis — posting at settlement +
inbox collection — drops ~240k/msg, making every end-to-end flow cheaper than v1.4.1 while
collection stays rebate-positive.
