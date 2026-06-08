# usufruct v1.4.2 — Adversarial Live Audit (Sui testnet)

**Date:** 2026-06-07 · **Auditor:** in-repo adversarial harness (`audit/`) · **Network:** Sui
testnet (chain `4c78adac`)

> ### ⚠️ About this audit — conducted by an AI agent
>
> This audit was performed by an **AI coding agent** (Anthropic's Claude, via Claude Code), not a
> human security firm. It is offered as a rigorous, fully **reproducible** first pass — every
> claim below is backed by a script in `audit/` and a real testnet transaction you can re-run and
> verify — **not** as a substitute for a professional human review or formal verification before
> any mainnet deployment with real value at stake.
>
> **What this delivers — and where a firm picks up.** This is a substantive security baseline, not
> a formality: 18 adversarial vectors run live against verified bytecode, fund conservation proven
> to the mist, capability and governance binding exercised on every entrypoint, 0 findings — each
> backed by a reproducible script and a real transaction. For a mainnet deployment with real value,
> it should be *complemented* by a professional firm's depth — formal reasoning and the untested
> areas in *Scope & limitations*. This pass makes that engagement faster and cheaper, not
> redundant: it hands a firm a verified-bytecode target, a mapped attack surface, a prioritized
> vector matrix, a runnable harness, and a baseline of invariants already confirmed live, so their
> reviewers start from solid ground rather than reconnaissance.
>
> **How it was carried out (so you can judge its credibility):**
> 1. **Source study.** The agent read the Move source under `usufruct/sources/` (engine, policies,
>    entities, api, …) to map the real attack surface: where value is split/joined, where state
>    transitions and the handover window are gated, how capabilities are bound, and where the
>    money math rounds. Several speculative concerns from a first static read were **discarded**
>    after reading the code (e.g. the "stale-state restore on return" idea is impossible — the
>    `AssetReceipt` is an abilityless hot potato, so borrow+return are atomic within one PTB).
> 2. **Target integrity first.** Before trusting any result, `./verify.sh v1.4.2` reproduced the
>    on-chain bytecode from source (`Source verification succeeded!`). This is what makes an abort
>    *mean something*: it is the deployed contract's behavior, not a local build's.
> 3. **A prioritized vector matrix.** Ten adversarial vectors (V1–V10) were defined, ranked by
>    severity × plausibility, with fund conservation (V1) as the master invariant.
> 4. **Live execution, chain as arbiter.** For each vector the agent built its own PTBs with
>    `@mysten/sui` and submitted them to the live testnet package from distinct adversarial
>    accounts (governor / incumbent / challenger). A transaction that *succeeds where it must not*
>    is an exploit; one that *aborts with the expected error constant* is a confirmed defense.
>    Measurements come from on-chain effects — event amounts, signed balance changes, `devInspect`
>    views, and parsed `MoveAbort` codes mapped to `asset_state.move` constants.
>
> **The point of the exercise** is to test the code **on testnet, in an adversarial
> environment** — exercising the deployed, immutable package the way a hostile, economically
> motivated participant would, rather than reasoning about it in the abstract. Everything is
> reproducible: `./verify.sh v1.4.2`, then `cd audit && npm install && npx tsx
> 01_setup_actors.ts && npx tsx 00_smoke.ts …`. The total cost was ≈ 0.56 testnet SUI.

This is not a coverage report — the suite already has 802 green tests. This is an **offensive
security pass**: economically-motivated actors building their own PTBs against the **deployed,
immutable bytecode on testnet**, trying to break fund conservation, bypass the handover
guarantee, act on stale state, manipulate the auction, forge/misuse capabilities, and abuse the
asset-composition boundary. The chain is the arbiter — a transaction that succeeds where it
should not is a confirmed exploit; one that aborts with the expected error is a confirmed defense.

---

## Verdict

**No vulnerabilities found.** Every adversarial transaction either aborted with the exact
expected protocol error or produced an exactly-conserved settlement. Fund conservation holds to
the **mist** across all three settlement paths. The handover guarantee, capability binding, and
asset-return linearity are enforced by the contract (and, where applicable, by Move's type system
itself).

| Vector | Surface | Severity if broken | Result |
|---|---|---|---|
| **V1** | Fund conservation (tenure expiry / handover / supersede) | Critical | ✅ exact to the mist |
| **V2** | Cross-escrow capability confusion | High | ✅ all rejected |
| **V3** | Pending / stale cap borrow gating | High | ✅ all rejected |
| **V4** | Handover window guarantee | High | ✅ honored, uncblockable, credit capped |
| **V5** | Borrow-as-DoS / asset lock | Medium | ✅ rejected by linearity |
| **V6** | Dutch-auction price integrity | Medium/High | ✅ bounded, no underflow |
| **V7** | Bid / supersede economics | Medium | ✅ no lowball, retire-blocks-bids |
| **V8** | Rounding dust direction | Low | ✅ conserved, dust → governor |
| **V9** | Governance edge cases | Low/Medium | ✅ all enforced |
| **V10** | Asset / coin composition | Medium | ✅ swap rejected, return forced |
| **V11** | Multi-tenure (N>1) arithmetic | High | ✅ exact; floor(stake/N) safe |
| **V12** | Handover cross-N rescaling | Medium/High | ✅ windows sane, conserved |
| **V13** | Deferred `update_ensemble` | Medium | ✅ applies only at Idle |
| **V14** | Commitment floors + stale-cap | Low/Medium | ✅ all enforced |
| **V15** | Fleet portfolio + 1-PTB collect | Medium | ✅ conserved, owner-gated |
| **V16** | Curve sweep + real fee drain | Medium | ✅ bounded; fees drained |
| **V17** | Refund-address authorization | High | ✅ no cross-seat reroute |
| **V18** | Governance-cap binding (full surface) | High | ✅ no cross-escrow governance |

~125 adversarial assertions across **18 vectors (two waves)**, **0 findings**. Wave 1 (V1–V10)
covered the core surface; Wave 2 (V11–V16) closed the gaps stated below, led by the **multi-tenure
(N>1) arithmetic** — the area the protocol's own docs flag as most error-prone. Total gas spent
across both waves stayed well within budget; the 20 USDC was untouched (stakes paid in free-mint
`DUMMY_COIN`); the protocol-fee inbox was drained once with the deployer key (authorized) to prove
fees are collectable end-to-end.

---

## Target integrity (this is what makes the aborts meaningful)

```
$ ./verify.sh v1.4.2
Verifying usufruct v1.4.2
  package: 0x415c4372bb9db5affe2ab2bf6d72a6a667ed3178a61d6201e9ff26dc76380e5d
  commit:  0bd8e53
BUILDING usufruct
Source verification succeeded!
```

`sui client verify-source` compiled the working tree and matched it module-by-module against the
on-chain bytecode. The deployed package **is** this source, and its upgrade cap was burned at
deploy — so every abort observed below is the real contract's behavior, not a local build.

## Method

- **Live, testnet-only.** Explicit testnet RPC (`https://fullnode.testnet.sui.io:443`); no
  mainnet/devnet client is ever constructed. The user-provisioned `audit-v1-4-2` key was used
  (the `llms.txt` "ephemeral keypair" rule was intentionally overridden, per the user).
- **Actors.** Three distinct adversarial accounts — `GOV` (governor), `UA` (incumbent
  usufructuary), `UB` (challenger) — funded with gas from the mother account, so the split of
  rights (govern / use / income) is real across separate addresses, not simulated.
- **Coin axis = `DUMMY_COIN`.** Rent was priced in the free-mint test coin (`TreasuryCap` is
  shared) rather than SUI. Two reasons: (1) stakes cost zero real budget — only gas is SUI; (2)
  protocol coin flows appear in `balanceChanges` with **zero gas noise**, so conservation is
  measurable exactly to the mist. (V6/V10 also exercise the SUI path implicitly; the protocol
  privileges neither coin.)
- **Measurement.** Settlements were measured from on-chain effects: governor income and protocol
  fee from `EarningsMessagePosted` / `FeeMessagePosted` event amounts; refunds from signed
  `balanceChanges` to the departing tenant's address; state from `devInspect` views; aborts from
  parsed `MoveAbort` codes mapped to `asset_state.move` error constants.
- **Harness.** `audit/lib.ts` + one script per vector (`audit/v*.ts`). Re-running any script
  prints fresh transaction digests verifiable at `https://suiscan.xyz/testnet/tx/<digest>`.

---

## Findings by vector

### V1 — Fund conservation *(CRITICAL invariant)* ✅
The master invariant: across every settlement, `Σ outputs == Σ inputs`, no value created or
destroyed.

- **(a) Tenure expiry** — stake 1000 → governor 900 + protocol fee 100, no refund.
  `900 + 100 == 1000`; fee == 10%; collected income == posted income.
  (e.g. settle `FKNePCFu6pCCtK73dGMWhdxTPbU5gSq1pVZUcgqqZxZT`)
- **(b) Handover with partial credit** — incumbent stake `S1 = 10000`. Settlement yielded
  `earnings 436 + fee 48 + refund 9516 == 10000`. The on-chain `HandoverCompleted` event matched
  the actual coin flows exactly: `used_credit 484 = earnings + fee`, `fee = floor(used/10) = 48`,
  `refund = remain_credit = 9516`. `used_credit ≤ S1` and `refund ≤ S1` (no over-extraction). The
  incoming tenant became active with its full stake intact.
  (settle `EHZzSqxrV7xLotexxc5b1HHqGz9pt9kHvvco4PkLtZt2`)
- **(c) Supersede** — a superseded *pending* bidder was refunded **in full** (30000 → 30000,
  confirmed both by `balanceChange` and by the wallet balance delta); they never used the asset,
  so they lose nothing. (`HK5ouwm5PM8WqLearSbJTvknazXdzGaiVbY2d2bUQnS`)

There is no path by which a participant withdraws more than they contributed.

### V2 — Cross-escrow capability confusion *(HIGH)* ✅
With two independent escrows A and B, every cross-use aborted with the precise error:

| Attempt | Abort |
|---|---|
| `GovernanceCap_A` → `retire(B)` | `EWrongEscrowGovernanceCap` (11) |
| `GovernanceCap_A` → `update_ensemble(B)` | `EWrongEscrowGovernanceCap` (11) |
| `UsufructCap_A` → `borrow(B)` | `EWrongEscrowUsufructCap` (6) |
| `UsufructCap_A` → `update_refund(B)` | `EWrongEscrowUsufructCap` (6) |
| `receipt_A` → `return_asset(B)` | `EReceiptEscrowMismatch` (10) |

Cap forgery/duplication is impossible by construction (Move `key`-only structs cannot be copied;
caps are minted only inside `execute_integrate` / `execute_rent`).

### V3 — Pending / stale cap borrow gating *(HIGH)* ✅
Only the **active** usufruct cap may borrow.
- Active cap borrows (baseline). ✅
- **Pending** cap → `borrow` aborts `EPendingUsufructCap` (7). ✅
- The incumbent's active cap **still borrows** during the Demand window (use is preserved until
  handover). ✅
- After handover fires, the displaced cap is **stale** → `borrow` aborts `EStaleUsufructCap`
  (8); the promoted tenant's cap borrows. ✅

*Note:* an early run surfaced an apparent anomaly that turned out to be a **test artifact**, not a
bug — with a 3-second handover window, the reconciliation that runs *first* inside `borrow_asset`
(`asset_state.move:1025`) settled the handover mid-test, so the "pending" cap had already been
promoted. Re-tested with a window held open long enough to observe the true Demand state. This is
correct lazy-settlement behavior.

### V4 — Handover window guarantee *(HIGH)* ✅
- **Honored:** reconciling *before* expiry (even by the incumbent) keeps the escrow in Demand
  with the incumbent active — the window cannot be cut short.
- **Unblockable:** after expiry, a **neutral third party** (the mother account) settled the
  handover — the incumbent cannot stall it.
- **Credit capped at the boundary, not at settlement time:** settling ~12 s *after* the window
  expired did not over-charge the incumbent. `used_credit = 302 = S1 · (boundary − phase_start)
  / ceiling` exactly (linear), anchored to the bid+window boundary, not to "now". A late settler
  cannot inflate the departing tenant's consumed credit.

### V5 — Borrow-as-DoS / asset lock *(MEDIUM)* ✅
- A PTB that borrows and never returns is rejected by **Sui's linearity check**
  (`UnusedValueWithoutDrop`) — the abilityless `AssetReceipt` cannot be dropped, stored, or
  escape the transaction. The asset cannot be walked off with.
- Double-borrow in one PTB aborts (the asset is already taken; state guard).
- After both failed attacks the escrow is **healthy** — a legitimate borrow+return still works
  (failed transactions revert atomically).

### V6 — Dutch-auction price integrity *(MEDIUM/HIGH)* ✅
Drove an escrow to Descent (last-acquisition 5000 descending to rest 1000) under three auction
curve shapes and sampled `floor_price_mist` across the window:

| Shape | Price samples (mist) |
|---|---|
| linear | 2359 → 1769 → 1083 → 1000 → 1000 → 1000 |
| exponential(abs=5) | 4283 → 3466 → 1476 → 1000 → 1000 → 1000 |
| logistic | 1516 → 1089 → 1006 → 1000 → 1000 → 1000 |

In every case the price stayed within `[rest, last_acq]`, was monotonically non-increasing, and
**never underflowed below the floor** — including the aggressive exponential shape, which is the
candidate for curve-height overshoot (`consumed > spread` → `price_sub` underflow). No abort, no
sub-floor price. Acquiring at the quoted descending price succeeds.

### V7 — Bid / supersede economics *(MEDIUM)* ✅
- **No lowball:** a bid of `S1` against an incumbent whose ascending floor is `S1+1` aborts
  `EInsufficientPayment` (1); a bid at exactly the floor succeeds.
- **Retire blocks bids:** once the governor sets the retire flag on an occupied escrow, a new bid
  aborts `ERetireFlagBlocksBid` (2).
- **Design characterization (not a flaw):** supersede **reuses the original handover expiry** —
  the window is anchored to the *first* challenge and is neither shortened nor extended by later
  superseding bids (`handover_expiry_ms` unchanged across a supersede). This is the correct
  reading of "the incumbent gets one guaranteed window from the first challenge"; see *Design
  observations*.

### V8 — Rounding dust direction *(LOW)* ✅
With deliberately indivisible stakes:

| Stake | Earnings (gov) | Fee (protocol) | Σ | fee = floor(stake/10)? |
|---|---|---|---|---|
| 10007 | 9007 | 1000 | 10007 ✓ | ✓ (dust 7 → governor) |
| 99991 | 89992 | 9999 | 99991 ✓ | ✓ (dust 1 → governor) |
| 7 (rest=1) | 7 | 0 | 7 ✓ | ✓ (whole 7 → governor) |

The protocol fee always rounds **down** (floor), so the sub-mist remainder accrues to the
**governor**, never to a third party or attacker, and conservation is exact. There is no
dust-skimming vector.

### V9 — Governance edge cases *(LOW/MEDIUM)* ✅
- `claim_asset` on a non-retired (idle) escrow aborts `ENotRetired` (12).
- `retire` before a deferred retire-commitment elapses aborts `ERetireCommitmentFloorNotElapsed`
  (4).
- `renounce_governance` is irreversible and burns the cap: afterward the **asset is permanently
  unclaimable** (claim fails — the cap object is deleted), yet **income keeps flowing and stays
  collectable** from the inbox the governor still holds (collected 9000 from a 10000 stake after
  renouncing). Governance and income are genuinely separate objects.
- Double `renounce` is rejected (the cap no longer exists).

### V10 — Asset / coin composition *(MEDIUM)* ✅
- Returning a **different** object (same type, freshly minted, different id) aborts
  `EReturnedDifferentAsset` (15) — a renter cannot swap the escrowed asset for another.
- A legitimate `borrow → use_asset → return` cycle works; the renter keeps the `Coupon` minted by
  *using* the asset (value from use without ownership) while the exact borrowed object is returned.
- **CoinType surface is minimal:** the protocol calls `coin::into_balance` once at rent and then
  operates only on the balance (a number); it never invokes arbitrary coin methods, so a hostile
  `CoinType` has no behavioral surface to exploit.

---

## Wave 2 — gap coverage (V11–V16) ✅

Wave 2 attacks the areas Wave 1 left untested, same verified bytecode, same harness.

### V11 — Multi-tenure (N>1) arithmetic *(HIGH — the main gap)*
The protocol's own docs call N-scaling the most error-prone surface. All exact on-chain:
- `tenure_single` rejects `rent(N=3)` (`EMultiCycleNotAllowed`); `tenure_multi` allows it.
- Payment due is `floor · N` exact: paying 2999 for N=3 (due 3000) aborts `EInsufficientPayment`;
  3000 succeeds.
- The next-bid floor is `escalate(floor(stake/N))` — incumbent S=10000, N=3 → per-tenure
  `floor(10000/3)=3333`, floor `3334`: a bid of 3333 aborts, 3334 succeeds. The flooring is
  per-tenure pricing semantics (loses `≤ N−1` mist on the *reference*, not on conservation), not
  an extraction vector.
- **Conservation with N>1, non-divisible stakes** (credit integrated on the *full* stake):
  tenure-expiry `9000+1000==10000` (N=3) and `89992+9999==99991` (N=7), `fee=floor(stake/10)`;
  descent ceiling = `floor(stake/N)` (3333; 14284). Handover with N=3: `295+32+9673==10000`.
- Overpay raises the descent ceiling to `floor(stake/N)`.

### V12 — Handover cross-N rescaling *(MEDIUM/HIGH)*
Handover between tenants with different N rescales the windows by
`floor(old · incoming/committed)`. Verified 4→1 (ceiling 40000→10000, handover 12000→3000) and
1→4 (10000→40000, 3000→12000): new windows equal `per-tenure · incoming`, always `>0` (no
zero/instant-expiry), `committed_tenures == incoming`, and the departing stake conserves exactly.

### V13 — Deferred `update_ensemble` *(MEDIUM)*
`update_ensemble` on a live escrow only **schedules** a pending ensemble; the live rest price is
unchanged through Occupied **and** Descent, and the pending ensemble applies **only** when the
escrow returns to Idle (`do_auction_expiry`). Verified live: rest price stayed 1000 mid-tenancy
and during descent, then flipped to 5000 at Idle.

### V14 — Commitment floors + stale-cap *(LOW/MEDIUM)*
- `extend_ensemble_commitment` then `update_ensemble` before the floor → `EEnsembleCommitmentFloorNotElapsed` (18).
- `extend_retire_commitment` then `retire` before the floor → `ERetireCommitmentFloorNotElapsed` (4).
- `burn_stale_usufruct_cap` succeeds on a displaced (stale) cap and aborts `EUsufructCapNotStale`
  (9) on a live cap (both active and just-promoted).

### V15 — Fleet portfolio + one-PTB collect *(MEDIUM)*
One cap + one inbox govern three escrows (`integrate_into_portfolio`); income from all three
settles to the single inbox and is drained in **one** PTB (5400 = Σ stakes × 0.9 over 3 messages),
fleet conservation exact (`5400+600==6000`). A **third party cannot** add to the governor's
portfolio — Sui rejects the tx because they do not own the cap/inbox.
**Correction to a static-analysis claim:** an earlier read claimed `integrate_into_portfolio`
verifies a cap↔inbox binding. It does **not** (`asset_state.move:858-875`) — and need not: the cap
and inbox are passed as **owned objects**, so only their owner can supply them. A governor pairing
their *own* cap with their *own* inbox for a new escrow is their choice over their own objects, with
no leak. Ownership, enforced by Sui's object model, is the real gate.

### V16 — Curve sweep + real fee drain *(MEDIUM)*
- **Credit-curve sweep** (`power_law(2,1)`, `power_law(1,2)`, `exponential(neg)`, `smoothstep`):
  every partial handover yields `used_credit ∈ [0, S]` (never over-charges) and conserves exactly,
  regardless of curve shape.
- **Auction-shape bound** (`power_law`, `smoothstep`): descending price stays within
  `[rest, last_acq]` — no underflow/overshoot (complements V6's linear/exp/logistic).
- **Real fee drain (authorized):** the deployer collected the `ProtocolFeeInbox` end-to-end —
  52807 mist over 39 `FeeMessage`s accumulated across the audit's settlements; collected total ==
  Σ `FeeMessageCollected` events. Protocol fees are real, collectable, and spendable.

### V17 — Refund-address authorization (refund-theft prevention) *(HIGH)*
`update_usufructuary_refund_address` lets a cap set **only its own seat's** refund address —
there is no parameter to target another seat (`asset_state.move:1141-1192`: the cap identity is
matched against the active/pending seat; anything else aborts). Proven live:
- **(a)** The active cap redirects its **own** refund and the funds follow it: a displaced
  incumbent's refund of 9242 landed at the chosen address X, and the incumbent's own address
  received 0.
- **(b)** A **pending** cap **cannot reroute the active seat's** refund. Even after the pending
  bidder pointed *its own* seat at an attacker address, the displaced active's refund (9659) went
  to the active usufructuary; the attacker received **0**.
- **(c)** A **stale** (displaced) cap calling it aborts `EUsufructCapStale` (17).

Combined with V2 (a cap from another escrow aborts `EWrongEscrowUsufructCap`), **no `UsufructCap`
can be used to route another usufructuary's funds** — a cap controls only its own seat's refund
destination.

### V18 — Governance-cap binding across the full surface *(HIGH)*
Can another `GovernanceCap` govern a different escrow? **No.** Each escrow stores the governor
identity it was created (or `integrate_into_portfolio`'d) with, and `assert_governance_cap_binds`
checks the caller's cap against it on every entrypoint. Proven live with two independent governors:
- A foreign cap (`cap_G`) on a different governor's escrow aborts `EWrongEscrowGovernanceCap` (11)
  on **all** of `retire`, `claim_asset`, `update_ensemble`, `extend_retire_commitment`, and
  `extend_ensemble_commitment`.
- **Portfolio nuance:** one cap legitimately governs its **whole fleet** — `update_ensemble`
  succeeded on all three escrows of a portfolio with the single shared cap — yet a *different*
  governor's cap reaches **none** of them, and the fleet cap cannot govern an outsider's escrow.
  The cap→escrow binding is per-escrow and exact; portfolio membership does not blur it.

### Concurrency note
Sui consensus **serializes** mutations of a shared object, and the protocol has no callbacks (PTB
linearity), so classic reentrancy/same-checkpoint races do not apply; competing bids resolve to a
deterministic place/supersede sequence with conservation intact.

---

## Design observations (intentional behaviors, not vulnerabilities)

These are worth a governor/integrator understanding, but none is a security defect:

1. **Supersede inherits the first challenger's handover window.** The incumbent's guaranteed
   grace runs from the *first* bid; superseders step into the remaining countdown rather than
   resetting it. Consequence: a challenger can place an early bid to *start* the incumbent's
   countdown, then supersede later to inherit a shorter remaining window. This does not shorten
   the incumbent's guarantee below what the first bid already set, and the incumbent's consumed
   credit is always capped at the boundary (V4) — so it is an economic timing property, not a
   fund or guarantee violation. Governors who want a longer guarantee should size
   `handover_fixed` accordingly.
2. **`renounce_governance` is a one-way trap by design.** It permanently strands the asset while
   keeping income flowing. This is the intended maximum-commitment signal; integrators should
   surface it as irreversible in any UI.
3. **Rounding dust accrues to the governor.** The 10% fee floors, so ≤ 1 mist per settlement
   flows to the governor rather than the protocol. Immaterial and non-attacker-favoring.
4. **Lazy settlement "floats" to the first toucher.** A due transition (tenure expiry, handover,
   auction) settles on the next mutating call from *anyone*. Every mutator reconciles first, so
   there is no cross-transaction stale-state window for mutations; only read-only views can lag,
   which is informational by design.

## Transparency: two false alarms during testing

All were defects in the *test* (or a stale static-analysis claim), corrected and re-run — none was
protocol behavior:
- **V3 timing:** a too-short (3 s) handover window let the in-`borrow` reconciliation settle the
  handover mid-test, making a "pending" cap appear to borrow. Fixed by holding the window open.
- **V9 expected value:** the income assertion expected 900 for a 10000-mist stake; the correct
  figure is 9000 (stake − 10% fee). The protocol was correct; the assertion was wrong.
- **V11 timing:** durations scale ×N, so an N=3 tenure with a 6 s base did not expire within an
  8 s wait — the settlement simply had not fired yet. Fixed by waiting the full `base · N` ceiling.
- **V15 binding:** the test expected `integrate_into_portfolio` to enforce a cap↔inbox binding; it
  does not (and need not — see V15). The real gate is object ownership; the test was corrected to
  assert that, and the no-binding behavior is documented as a design observation.

---

## Reproduction

```bash
./verify.sh v1.4.2                     # confirm testnet bytecode == source
cd audit && npm install               # @mysten/sui v2 + bip39
npx tsx 01_setup_actors.ts            # create/fund GOV, UA, UB (idempotent)
npx tsx 00_smoke.ts                   # pipeline + V1(a)
npx tsx v1_conservation.ts            # V1(b),(c)
npx tsx v2_cross_escrow.ts            # Wave 1: … through v10_composition.ts
npx tsx v11_multitenure.ts            # Wave 2: … through v18_governance_cap_binding.ts
npx tsx balances.ts                   # remaining budget
```
Wave 2 (`v16_curves_fees.ts`) also drains the deployer-owned fee inbox; `DEPLOYER_KEY` lives in
`audit/.env` (gitignored) alongside `MOTHER_KEY`.

Each script prints `PASS` / `FINDING` lines and transaction digests (verifiable on SuiScan). The
audit account private key lives in `audit/.env` (gitignored); actor keypairs persist in
`audit/actors.json` (gitignored) so re-runs reuse funded addresses.

## Scope & limitations

- Adversarial **transaction** testing against the live contract, not a line-by-line formal
  review; the functional Move style means the compiler already enforces fund conservation and
  state-machine consistency structurally (which V1 confirms empirically).
- Curve-shape overshoot was probed at representative aggressive parameters (exponential abs=5,
  logistic), not exhaustively across the full `(num, den)` / `abs` parameter space.
- Time-dependent assertions use wall-clock sleeps against the chain Clock; observed credit/price
  values matched the deterministic formulas exactly, so timing granularity did not affect the
  verdicts.
