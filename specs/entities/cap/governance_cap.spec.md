# governance_cap

## § OVERVIEW

Pure governance token — the *principal strip*. Holding a `GovernanceCap` authorizes the governance operations (`retire`, `update_ensemble`, `claim_asset`) over the escrow(s) whose `GovernorSeat` records its identity. The cap carries **no escrow binding of its own**: a single cap can govern many escrows (one-pair-to-many via `escrow::integrate_into_portfolio`). It is born paired with an `EarningsInbox` at `escrow::integrate`; after birth the two are **independent objects** — the cap (governance) and the inbox (income) move and transfer separately.

Because the cap is a Sui object (`key, store`), governance transfers by transferring the object — no protocol field update. `GovernanceCapIdentity` is the copy-safe handle recorded in the `GovernorSeat` and matched against the presented cap at every governance operation.

## § TYPES

```
GovernanceCap { id: UID }   has key, store
```
The governance token. No escrow field — it governs every escrow whose `GovernorSeat` recorded its identity.

```
GovernanceCapIdentity { id: ID }   has copy, drop, store
```
Copy-safe reference to a `GovernanceCap` (its object id). Stored inside `GovernorIdentity`; an operation validates a presented cap by matching `identity(cap)` against the seat's recorded identity, not by an escrow field on the cap.

## § API

**Constructors** (package)
- `governance_cap::new(escrow_identity, governor_address, ctx): GovernanceCap` — mints a cap; emits `GovernanceCapMinted` recording the birth escrow as provenance. The cap does not store the escrow; the event does.

**Accessors** (package)
- `governance_cap::identity(&GovernanceCap): GovernanceCapIdentity` — the cap's identity handle.
- `governance_cap::proj_id(GovernanceCapIdentity): ID` — the underlying object id.

**Mutations** (package)
- `governance_cap::burn(GovernanceCap, ctx)` — destroys the cap; emits `GovernanceCapBurned`. Mechanism only — the public semantic (`renounce_governance`) lives in `api/cap`.

## § INVARIANTS

- A cap is minted per `integrate` (born with an `EarningsInbox`). It is **not** one-per-escrow: `integrate_into_portfolio` binds further escrows to the same cap, so one cap may govern N escrows.
- Governance binding lives in the `GovernorSeat`, which records the `GovernanceCapIdentity`. An operation authorizes by identity match against the seat — there is no escrow field on the cap to compare.
- Burn is irreversible and terminal: once burned, no cap can ever again satisfy the seat bind of the escrows it governed, so `retire` / `update_ensemble` / `claim_asset` become permanently unreachable for all of them — the escrows are **sealed**. Income is unaffected: the `EarningsInbox` is a separate object and keeps receiving and collecting.

## § EVENTS

```
GovernanceCapMinted { governance_cap_id: ID, escrow_id: ID, governor_address: address }
```
Emitted when a cap is minted. The cap stores no escrow, but the event records the birth escrow — star-schema provenance ("this governance cap was born from escrow X"). `governor_address` is the declared governor at integration time.

```
GovernanceCapBurned { governance_cap_id: ID, governor_address: address }
```
Emitted when the cap is permanently burned (governance renounced). Carries **no** escrow id — the cap governs many escrows; the set it sealed is recovered by joining `governance_cap_id` against the `AssetIntegrated` star schema. `governor_address` is the transaction sender.
