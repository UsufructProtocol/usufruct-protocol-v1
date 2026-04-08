RENTAL ESCROW — SPECIFICATION
==============================

Module: `rental_escrow`
Design reference: design-compact.md §1–3, §7
Inventory reference: inventory-impl.txt §1, §3


1. OBJECTS
----------

### 1.1 RentalEscrow<Asset, CoinType>

Kind: shared object
Type constraints: Asset: key + store, CoinType: (Coin framework)

The central protocol object. Wraps the asset for its entire lifecycle.
Created by `integrate()`, destroyed by `retire()`.
One instance per integrated asset. ID is permanent and unique per asset.

**Fields:**

| Field | Type | Description |
|---|---|---|
| `id` | `UID` | Shared object identity. Unique per asset. |
| `asset` | `Asset` | The wrapped asset. Always present. Extracted only via hot-potato within a single PTB. |
| `config` | `IntegrationConfig` | Immutable parameters set at integration time. See spec §2. |
| `state` | `AssetState` | Current state of the asset. Encodes rent phase when Rented. |
| `last_rent_price` | `u64` | Price paid by the current (or most recent) tenant. Entry barrier for takeover. Initialized at first rent. |
| `phase_start_ms` | `u64` | Timestamp (ms) at which the current phase began. Semantics depend on state (see §4). |
| `current_tenant_cap_id` | `Option<ID>` | ID of the TenantCap held by the active tenant. `None` outside of Rented. |
| `pending_tenant_cap_id` | `Option<ID>` | ID of the TenantCap held by the incoming bidder. `Some` only in `Rented(HandoverConfirmed)`. |
| `handover_countdown_expiry` | `Option<u64>` | Timestamp (ms) at which access transfers to the pending tenant. `Some` only in `Rented(HandoverConfirmed)`. Sampled once from on-chain randomness, never resampled. |
| `tenant_stake` | `Balance<CoinType>` | Funds held for the current rental cycle. Equal to `last_rent_price` throughout Rented. Split at handover or consumed at tenure expiry. |
| `pending_bid` | `Balance<CoinType>` | Funds held for the incoming bidder. Non-zero only in `Rented(HandoverConfirmed)`. Becomes `tenant_stake` at handover. |
| `owner_earnings` | `Balance<CoinType>` | Accumulated `used_credit` across all completed cycles. Withdrawn by owner via `withdraw_earnings()`. |
| `to_retire` | `bool` | Deferred retirement flag. Set/unset by owner at any time. Executes at next Idle transition if `retire_floor` elapsed. |
| `force_retire` | `bool` | Emergency retirement flag. Set by `force_retire()`. Blocks new bids. Asset retires at next tenure expiry. |
| `integrated_at_ms` | `u64` | Timestamp (ms) at integration. Used to enforce `retire_floor`. |


### 1.2 IntegratorCap

Kind: owned object (transferable)

Capability proving authority over a specific `RentalEscrow`.
Minted once at `integrate()`, held by the owner.
Required for: `withdraw_earnings`, `set_to_retire`, `unset_to_retire`, `force_retire`, `retire`.
Authorization check: `cap.escrow_id == object::id(escrow)`.

**Fields:**

| Field | Type | Description |
|---|---|---|
| `id` | `UID` | Object identity. |
| `escrow_id` | `ID` | ID of the RentalEscrow this cap governs. |


### 1.3 TenantCap

Kind: owned object (transferable)

Capability proving tenancy over a specific `RentalEscrow`.
Minted on every valid bid (rent, takeover). One per payment.
Valid only if its ID matches `escrow.current_tenant_cap_id`.
Superseded caps remain in the holder's wallet but are inert — the escrow will not recognize them.

Required for: `borrow_asset`.
Authorization check: `object::id(cap) == escrow.current_tenant_cap_id`.

**Fields:**

| Field | Type | Description |
|---|---|---|
| `id` | `UID` | Object identity. The escrow stores this ID to recognize the active cap. |
| `escrow_id` | `ID` | ID of the RentalEscrow this cap is associated with. |


### 1.4 AssetReceipt

Kind: hot potato (no abilities: no copy, no drop, no store, no key)

Issued by `borrow_asset()`, consumed by `return_asset()`.
Enforces that the asset returns to the escrow within the same PTB.

**Fields:**

| Field | Type | Description |
|---|---|---|
| `escrow_id` | `ID` | Must match the escrow's ID on return. Prevents cross-escrow misuse. |


2. STATE ENCODING
-----------------

```
enum AssetState {
    Idle,
    Rented { phase: RentPhase },
    AtDutchAuction,
    Retired,
}

enum RentPhase {
    HandoverOpen,
    HandoverConfirmed,
}
```

`AssetState` is stored directly in `RentalEscrow.state`.
`RentPhase` is nested inside the `Rented` variant — no separate field needed.


3. FIELD INVARIANTS
--------------------

These invariants hold at every quiet point (before and after any public function call).
`resolve_state` is responsible for restoring them when clock advances.

| Field | Idle | Rented(HandoverOpen) | Rented(HandoverConfirmed) | AtDutchAuction | Retired |
|---|---|---|---|---|---|
| `asset` | present | present (or borrowed in-PTB) | present (or borrowed in-PTB) | present | — (escrow deleted) |
| `current_tenant_cap_id` | None | Some | Some | None | — |
| `pending_tenant_cap_id` | None | None | Some | None | — |
| `handover_countdown_expiry` | None | None | Some | None | — |
| `tenant_stake` | 0 | == last_rent_price | == last_rent_price | 0 | — |
| `pending_bid` | 0 | 0 | == pending bid amount | 0 | — |
| `to_retire` | any | any | any | any | — |
| `force_retire` | false | any | any | false | — |


4. PHASE_START_MS SEMANTICS
----------------------------

`phase_start_ms` is a single anchor reused across states:

| State | Meaning |
|---|---|
| Rented | Timestamp at which the current tenant's block started. Used to compute `used_credit` and detect tenure expiry. |
| AtDutchAuction | Timestamp at which the auction started. Used to compute `price_descent` and detect auction expiry. |
| Idle | Undefined (retains last value — not read). |

Update rules:
- At `rent()`: `phase_start_ms = clock.now()`
- At handover execution (in `resolve_state`): `phase_start_ms = handover_countdown_expiry`
- At tenure expiry → AtDutchAuction: `phase_start_ms = phase_start_ms + tenure_ceiling` (exact boundary, not clock.now())
- At auction entry (`rent()` from auction): `phase_start_ms = clock.now()`
- At auction expiry → Idle: `phase_start_ms` not updated (undefined in Idle)


5. FUND FLOW INVARIANT
-----------------------

During Rented (both phases):

```
balance(tenant_stake) == last_rent_price     [always]
used_credit(t) + remain_credit(t) == last_rent_price   [logical, computed from clock]
```

`used_credit` is never stored — always derived:

```
used_credit(t) = last_rent_price · g((t - phase_start_ms) / tenure_ceiling)
remain_credit(t) = last_rent_price - used_credit(t)
```

The split materializes only at transition boundaries:
- **Handover**: `remain_credit → current tenant (Coin)`, `used_credit → owner_earnings`
- **Tenure expiry**: full `tenant_stake → owner_earnings` (remain_credit = 0)

`pending_bid` flows directly into `tenant_stake` at handover — no intermediate accounting.


6. OBJECT LIFECYCLE
--------------------

```
integrate()  →  RentalEscrow created (shared), IntegratorCap minted (owned)
rent()       →  TenantCap minted, current_tenant_cap_id set
takeover()   →  TenantCap minted for incoming bidder, pending_tenant_cap_id set
             →  (if HandoverConfirmed: previous pending cap ID overwritten, previous bid refunded)
handover()   →  pending_tenant_cap_id → current_tenant_cap_id (old cap inert)
retire()     →  asset extracted, RentalEscrow deleted, IntegratorCap consumed
```

TenantCap invalidation is implicit: the escrow overwrites the stored ID.
Holders of superseded TenantCaps retain inert objects in their wallets.
No burn mechanism is needed or provided.


7. OPEN QUESTIONS
------------------

[ ] 7.1  When `force_retire` is set during `Rented(HandoverConfirmed)`, the design says
         handover completes normally and T(n+1) gets a full block before retiring.
         Does `pending_tenant_cap_id` / the incoming TenantCap holder need to be notified
         at bid time that a force_retire flag is active? Or is this intentionally silent
         (they discover it when their block ends)?

[ ] 7.2  `last_rent_price` initial value before first rent: 0 or min_rent_price?
         Matters for `compute_next_rent_price` if called before first tenant.
         (Likely not reachable, but worth making the invariant explicit.)

[ ] ] 7.3  Are `IntegratorCap` and `TenantCap` intended to be composable with other
          protocols (e.g., stored inside another object)? If so, they need `store` ability.
          If personal-only, `key` alone suffices. Default assumption: transferable + storable.
