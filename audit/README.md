# audit/ — adversarial live-audit harness

Offensive security pass against the **deployed** usufruct v1.4.2 package on Sui **testnet**.
See [`../AUDIT.md`](../AUDIT.md) for the full report and verdict (no vulnerabilities found).

- `lib.ts` — harness: testnet client, PTB builders, view decoders, event/ledger helpers,
  abort-code → error-constant mapping, PASS/FINDING runner.
- `00_smoke.ts` — pipeline check + V1(a) tenure-expiry conservation.
- `01_setup_actors.ts` — create/fund GOV, UA, UB (idempotent; persists to `actors.json`).
- `v1_conservation.ts` … `v10_composition.ts` — one script per adversarial vector.
- `balances.ts` — remaining SUI across all audit accounts.

**Testnet only.** Explicit testnet RPC; never mainnet. Stakes are paid in free-mint
`DUMMY_COIN` so only gas costs SUI. `.env` (audit key) and `actors.json` are gitignored.

```bash
npm install
npx tsx 01_setup_actors.ts
npx tsx 00_smoke.ts && npx tsx v1_conservation.ts   # … etc
```
