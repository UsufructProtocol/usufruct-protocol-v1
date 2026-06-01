# cap (api)

## § OVERVIEW

The public facade over the two capability types. Exposes the irreversible governance-renunciation entry and a usufruct-cap projector. The cap types themselves and their minting/burning live in `governance_cap` and `usufruct_cap`; this module is the PTB-reachable surface.

## § API

**Public**
- `cap::renounce_governance(cap: GovernanceCap, ctx)` — permanently and irreversibly renounce ALL governance over every escrow the cap governs (`retire`, `update_ensemble`, `claim_asset`). Burns the cap (`governance_cap::burn`). The underlying asset(s) can NEVER be reclaimed — they stay in perpetual usufruct at frozen terms; the escrows are **sealed**. Income is unaffected: the `EarningsInbox` keeps receiving and remains collectable. The supremum of the commitment ladder; there is no undo.
- `cap::usufruct_cap_escrow_id(cap: &UsufructCap): ID` — the escrow a usufruct cap is bound to (delegates to `usufruct_cap::proj_escrow_id`).

## § INVARIANTS

- `renounce_governance` is terminal: once called, no governance operation on the sealed escrows is ever reachable again (the `GovernorSeat` bind can never be satisfied by any cap).

## § EVENTS

None directly. *(`renounce_governance` → `GovernanceCapBurned` in `governance_cap`.)*
