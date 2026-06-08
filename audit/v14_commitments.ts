// V14 — commitment-extension floors and stale-cap burning.
//  - extend_ensemble_commitment pushes a floor; update_ensemble before it elapses aborts (18).
//  - extend_retire_commitment pushes a floor; retire before it elapses aborts (4).
//  - burn_stale_usufruct_cap: works on a displaced (stale) cap; aborts EUsufructCapNotStale (9)
//    on a live (active) cap.
import * as U from './lib.ts';
import { Transaction } from '@mysten/sui/transactions';

function retireTx(escrowId: string, govCapId: string) {
  const t = new Transaction();
  t.moveCall({ target: `${U.PKG}::escrow::retire`, typeArguments: U.TYPE_ARGS, arguments: [t.object(escrowId), t.object(govCapId), t.object(U.CLOCK)] });
  return t;
}

async function ensembleCommitment() {
  U.head('V14(a) — extend_ensemble_commitment blocks update');
  const { GOV } = U.loadActors();
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 600_000n, handover: 'off' });
  // extend the ensemble-commitment floor 1h into the future
  const e = await U.trySend(U.extendEnsembleCommitmentTx(g.escrowId, g.govCapId, 3_600_000n), GOV);
  if (e.ok) U.pass('extend_ensemble_commitment accepted'); else { U.finding(`extend failed: ${U.truncErr(e.error)}`); return; }
  // update_ensemble now must abort — floor not elapsed
  U.expectAbort(await U.trySend(U.updateEnsembleTx(g.escrowId, g.govCapId, { restPrice: 9_000n }), GOV), 'EEnsembleCommitmentFloorNotElapsed', 'update_ensemble before commitment floor');
}

async function retireCommitment() {
  U.head('V14(b) — extend_retire_commitment blocks retire');
  const { GOV } = U.loadActors();
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 600_000n, handover: 'off' });
  const e = await U.trySend(U.extendRetireCommitmentTx(g.escrowId, g.govCapId, 3_600_000n), GOV);
  if (e.ok) U.pass('extend_retire_commitment accepted'); else { U.finding(`extend failed: ${U.truncErr(e.error)}`); return; }
  U.expectAbort(await U.trySend(retireTx(g.escrowId, g.govCapId), GOV), 'ERetireCommitmentFloorNotElapsed', 'retire before commitment floor');
}

async function staleCap() {
  U.head('V14(c) — burn_stale_usufruct_cap: stale ok, live aborts');
  const { GOV, UA, UB } = U.loadActors();
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 600_000n, handover: { fixed: 3_000n }, multi: true, escalation: { fixed: 1n } });
  const rA = await U.rent(UA, g.escrowId, 10_000n, 1n);
  // burning a LIVE active cap must abort EUsufructCapNotStale
  U.expectAbort(await U.trySend(U.burnStaleCapTx(g.escrowId, rA.capId), UA), 'EUsufructCapNotStale', 'burn live (active) cap');
  // displace UA: UB bids, wait, settle → UA stale
  const rB = await U.rent(UB, g.escrowId, 30_000n, 1n);
  await U.sleep(5_000);
  await U.apply(GOV, g.escrowId);
  // now UA's cap is stale → burn succeeds
  const r = await U.trySend(U.burnStaleCapTx(g.escrowId, rA.capId), UA);
  if (r.ok) U.pass('burn_stale on displaced (stale) cap succeeds'); else U.finding(`burn stale failed: ${U.truncErr(r.error)}`);
  // and burning the now-active UB cap aborts
  U.expectAbort(await U.trySend(U.burnStaleCapTx(g.escrowId, rB.capId), UB), 'EUsufructCapNotStale', 'burn live (promoted) cap');
}

async function main() {
  await ensembleCommitment();
  await retireCommitment();
  await staleCap();
  U.summary();
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
