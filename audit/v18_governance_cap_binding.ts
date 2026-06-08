// V18 — can a GovernanceCap govern an escrow it does not own?
// A cap is bound to the governor identity each escrow stores; one cap legitimately governs its
// whole portfolio, but a FOREIGN cap must be rejected on every governance entrypoint.
//  (a) cap_G on a different governor's escrow → EWrongEscrowGovernanceCap on retire / claim_asset /
//      update_ensemble / extend_retire_commitment / extend_ensemble_commitment.
//  (b) positive: GOV's single cap governs all escrows in ITS fleet; a different governor's cap
//      reaches none of them.
import * as U from './lib.ts';
import { Transaction } from '@mysten/sui/transactions';

const retireTx = (e: string, cap: string) => {
  const t = new Transaction();
  t.moveCall({ target: `${U.PKG}::escrow::retire`, typeArguments: U.TYPE_ARGS, arguments: [t.object(e), t.object(cap), t.object(U.CLOCK)] });
  return t;
};
const claimTx = (e: string, cap: string, to: string) => {
  const t = new Transaction();
  const a = t.moveCall({ target: `${U.PKG}::escrow::claim_asset`, typeArguments: U.TYPE_ARGS, arguments: [t.object(e), t.object(cap), t.object(U.CLOCK)] });
  t.transferObjects([a], to);
  return t;
};

async function foreignCapRejected() {
  U.head('V18(a) — foreign GovernanceCap rejected on every governance entrypoint');
  const { GOV } = U.loadActors();
  const eG = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 600_000n, handover: 'off' });       // GOV's escrow + cap_G
  const eM = await U.integrate(U.mother, { restPrice: 1_000n, tenureMs: 600_000n, handover: 'off' });    // mother's escrow + cap_M
  U.info(`cap_G governs ${eG.escrowId.slice(0, 10)}; target = mother's escrow ${eM.escrowId.slice(0, 10)}`);
  const capG = eG.govCapId;

  // GOV owns cap_G; eM is a shared object. Try cap_G against eM on each gov function.
  U.expectAbort(await U.trySend(retireTx(eM.escrowId, capG), GOV), 'EWrongEscrowGovernanceCap', 'cap_G → retire(eM)');
  U.expectAbort(await U.trySend(claimTx(eM.escrowId, capG, U.addrOf(GOV)), GOV), 'EWrongEscrowGovernanceCap', 'cap_G → claim_asset(eM)');
  U.expectAbort(await U.trySend(U.updateEnsembleTx(eM.escrowId, capG, { restPrice: 9_000n }), GOV), 'EWrongEscrowGovernanceCap', 'cap_G → update_ensemble(eM)');
  U.expectAbort(await U.trySend(U.extendRetireCommitmentTx(eM.escrowId, capG, 3_600_000n), GOV), 'EWrongEscrowGovernanceCap', 'cap_G → extend_retire_commitment(eM)');
  U.expectAbort(await U.trySend(U.extendEnsembleCommitmentTx(eM.escrowId, capG, 3_600_000n), GOV), 'EWrongEscrowGovernanceCap', 'cap_G → extend_ensemble_commitment(eM)');
}

async function portfolioBinding() {
  U.head('V18(b) — one cap governs its whole fleet; a foreign cap reaches none');
  const { GOV } = U.loadActors();
  const e1 = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 600_000n, handover: 'off' });
  const e2 = await U.integrateIntoPortfolio(GOV, e1.govCapId, e1.inboxId, { restPrice: 1_000n, tenureMs: 600_000n, handover: 'off' });
  const e3 = await U.integrateIntoPortfolio(GOV, e1.govCapId, e1.inboxId, { restPrice: 1_000n, tenureMs: 600_000n, handover: 'off' });
  // a second governor's cap (mother)
  const eM = await U.integrate(U.mother, { restPrice: 1_000n, tenureMs: 600_000n, handover: 'off' });

  // positive: cap_1 (=fleet cap) governs each member — update_ensemble succeeds on all three
  for (const [i, e] of [e1, e2, e3].entries()) {
    const r = await U.trySend(U.updateEnsembleTx(e.escrowId, e1.govCapId, { restPrice: BigInt(2000 + i) }), GOV);
    if (r.ok) U.pass(`fleet cap governs escrow #${i + 1} (update_ensemble ok)`);
    else U.finding(`fleet cap failed on escrow #${i + 1}: ${U.truncErr(r.error)}`);
  }
  // negative: mother's cap_M cannot govern any fleet member
  U.expectAbort(await U.trySend(U.updateEnsembleTx(e1.escrowId, eM.govCapId, { restPrice: 7_000n }), U.mother), 'EWrongEscrowGovernanceCap', 'cap_M → update_ensemble(fleet #1)');
  U.expectAbort(await U.trySend(retireTx(e3.escrowId, eM.govCapId), U.mother), 'EWrongEscrowGovernanceCap', 'cap_M → retire(fleet #3)');
  // and GOV's fleet cap cannot govern mother's escrow
  U.expectAbort(await U.trySend(U.updateEnsembleTx(eM.escrowId, e1.govCapId, { restPrice: 7_000n }), GOV), 'EWrongEscrowGovernanceCap', 'fleet cap → update_ensemble(eM)');
}

async function main() {
  await foreignCapRejected();
  await portfolioBinding();
  U.summary();
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
