// V9 — governance edge cases.
//  - claim_asset on a non-retired escrow → ENotRetired.
//  - retire before a deferred retire-commitment elapses → ERetireCommitmentFloorNotElapsed.
//  - renounce_governance: irreversible; asset becomes permanently unclaimable, BUT income
//    keeps flowing and stays collectable (governance vs income are separate).
//  - double renounce → the cap is gone (input-object error, not a Move abort).
import * as U from './lib.ts';
import { Transaction } from '@mysten/sui/transactions';

async function claimNotRetired() {
  U.head('V9(a) — claim on non-retired escrow aborts');
  const { GOV } = U.loadActors();
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 600_000n, handover: 'off' });
  const t = new Transaction();
  const asset = t.moveCall({ target: `${U.PKG}::escrow::claim_asset`, typeArguments: U.TYPE_ARGS, arguments: [t.object(g.escrowId), t.object(g.govCapId), t.object(U.CLOCK)] });
  t.transferObjects([asset], U.addrOf(GOV));
  U.expectAbort(await U.trySend(t, GOV), 'ENotRetired', 'claim without retire (idle escrow)');
}

async function retireCommitment() {
  U.head('V9(b) — retire blocked by deferred commitment floor');
  const { GOV } = U.loadActors();
  // integrate with a deferred retire commitment far in the future
  const tx = new Transaction();
  const asset = tx.moveCall({ target: `${U.DUMMY_PKG}::dummy_asset::mint` });
  const ensemble = U.buildEnsemble(tx, { restPrice: 1_000n, tenureMs: 600_000n, handover: 'off' });
  const dur = tx.moveCall({ target: `${U.PKG}::ensemble::duration`, arguments: [tx.pure.u64(3_600_000n)] }); // 1h
  const retireC = tx.moveCall({ target: `${U.PKG}::ensemble::new_retire_commitment_deferred`, arguments: [dur] });
  const ensembleC = tx.moveCall({ target: `${U.PKG}::ensemble::new_ensemble_commitment_immediate` });
  const [govCap, inbox] = tx.moveCall({ target: `${U.PKG}::escrow::integrate`, typeArguments: U.TYPE_ARGS, arguments: [asset, ensemble, retireC, ensembleC, tx.object(U.FEE_REF), tx.object(U.CLOCK)] });
  tx.transferObjects([govCap, inbox], U.addrOf(GOV));
  const res = await U.send(tx, GOV);
  const escrowId = U.createdId(res, '::escrow::Escrow');
  const govCapId = U.createdId(res, '::governance_cap::GovernanceCap');
  // retire now → commitment floor not elapsed
  const t = new Transaction();
  t.moveCall({ target: `${U.PKG}::escrow::retire`, typeArguments: U.TYPE_ARGS, arguments: [t.object(escrowId), t.object(govCapId), t.object(U.CLOCK)] });
  U.expectAbort(await U.trySend(t, GOV), 'ERetireCommitmentFloorNotElapsed', 'retire before deferred commitment elapses');
}

async function renounceTrap() {
  U.head('V9(c) — renounce_governance: irreversible trap, income survives');
  const { GOV, UA } = U.loadActors();
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 6_000n, handover: 'off' });
  // renounce immediately
  {
    const t = new Transaction();
    t.moveCall({ target: `${U.PKG}::cap::renounce_governance`, arguments: [t.object(g.govCapId)] });
    const r = await U.trySend(t, GOV);
    if (r.ok) U.pass('renounce_governance succeeded (cap burned)'); else { U.finding(`renounce failed: ${U.truncErr(r.error)}`); return; }
  }
  // income still flows: rent → expire → collect from the inbox GOV still holds
  await U.rent(UA, g.escrowId, 10_000n, 1n);
  await U.sleep(8_000);
  await U.apply(UA, g.escrowId); // anyone settles
  const c = await U.collectEarnings(GOV, g.inboxId);
  if (c.amount === 9_000n) U.pass(`income still flows after renounce: collected ${c.amount} (stake 10000 − 10% fee; governance ≠ income)`);
  else U.finding(`post-renounce income collect = ${c.amount} (expected 9000)`);
  // asset is now permanently unclaimable: claim with a (gone) cap fails
  {
    const t = new Transaction();
    const asset = t.moveCall({ target: `${U.PKG}::escrow::claim_asset`, typeArguments: U.TYPE_ARGS, arguments: [t.object(g.escrowId), t.object(g.govCapId), t.object(U.CLOCK)] });
    t.transferObjects([asset], U.addrOf(GOV));
    const r = await U.trySend(t, GOV);
    if (!r.ok) U.pass(`asset permanently unclaimable after renounce (cap gone): ${U.truncErr(r.error)}`);
    else U.finding('claim succeeded after renounce — asset NOT locked');
  }
  // double renounce → cap object no longer exists
  {
    const t = new Transaction();
    t.moveCall({ target: `${U.PKG}::cap::renounce_governance`, arguments: [t.object(g.govCapId)] });
    const r = await U.trySend(t, GOV);
    if (!r.ok) U.pass(`double renounce rejected (cap already burned): ${U.truncErr(r.error)}`);
    else U.finding('double renounce succeeded');
  }
}

async function main() {
  await claimNotRetired();
  await retireCommitment();
  await renounceTrap();
  U.summary();
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
