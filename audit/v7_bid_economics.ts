// V7 — bid + supersede economics.
// - You cannot lowball: a bid below the ascending floor aborts EInsufficientPayment.
// - retire flag blocks new bids (ERetireFlagBlocksBid).
// - DESIGN characterization: supersede REUSES the original handover_expiry (the incumbent's
//   guaranteed window is anchored to the FIRST challenge, not reset by later bids).
import * as U from './lib.ts';
import { Transaction } from '@mysten/sui/transactions';

async function bid(escrowId: string, signer: any, total: bigint) {
  const t = new Transaction();
  const payment = U.mintDummy(t, total);
  const tn = t.moveCall({ target: `${U.PKG}::ensemble::tenures`, arguments: [t.pure.u64(1n)] });
  const cap = t.moveCall({ target: `${U.PKG}::escrow::rent`, typeArguments: U.TYPE_ARGS, arguments: [t.object(escrowId), payment, tn, t.object(U.CLOCK)] });
  t.transferObjects([cap], U.addrOf(signer));
  return await U.trySend(t, signer);
}

async function lowball() {
  U.head('V7(a) — lowball bid rejected');
  const { GOV, UA, UB } = U.loadActors();
  const S1 = 10_000n;
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 600_000n, handover: { fixed: 60_000n }, escalation: { fixed: 1n }, creditShape: 'linear' });
  await U.rent(UA, g.escrowId, S1, 1n); // incumbent; per-tenure = S1, ascending floor = S1+1
  // bid exactly S1 (below floor S1+1) → abort
  U.expectAbort(await bid(g.escrowId, UB, S1), 'EInsufficientPayment', `bid ${S1} < ascending floor (${S1 + 1n})`);
  // bid at exactly the floor → succeeds
  const r = await bid(g.escrowId, UB, S1 + 1n);
  if (r.ok) U.pass(`bid at exact floor (${S1 + 1n}) succeeds → Demand`);
  else U.finding(`bid at floor failed: ${U.truncErr(r.error)}`);
}

async function retireBlocks() {
  U.head('V7(b) — retire flag blocks bids');
  const { GOV, UA, UB } = U.loadActors();
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 600_000n, handover: { fixed: 60_000n }, escalation: { fixed: 1n } });
  await U.rent(UA, g.escrowId, 10_000n, 1n);
  // governor retires the occupied escrow → sets retire flag
  const t = new Transaction();
  t.moveCall({ target: `${U.PKG}::escrow::retire`, typeArguments: U.TYPE_ARGS, arguments: [t.object(g.escrowId), t.object(g.govCapId), t.object(U.CLOCK)] });
  const rr = await U.trySend(t, GOV);
  if (rr.ok) U.pass('retire flag set on occupied escrow'); else { U.finding(`retire failed: ${U.truncErr(rr.error)}`); return; }
  // now any new bid must be blocked
  U.expectAbort(await bid(g.escrowId, UB, 50_000n), 'ERetireFlagBlocksBid', 'bid after retire flag');
}

async function supersedeWindow() {
  U.head('V7(c) — supersede reuses the original handover window (design characterization)');
  const { GOV, UA, UB } = U.loadActors();
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 600_000n, handover: { fixed: 120_000n }, escalation: { fixed: 1n }, creditShape: 'linear' });
  await U.rent(UA, g.escrowId, 10_000n, 1n);
  await bid(g.escrowId, UB, 30_000n); // first challenge → starts the countdown
  const exp1 = await U.viewOptU64('handover_expiry_ms', g.escrowId);
  U.info(`after first bid: handover_expiry_ms=${exp1}`);
  await U.sleep(5_000);
  await bid(g.escrowId, U.mother, 90_000n); // supersede
  const exp2 = await U.viewOptU64('handover_expiry_ms', g.escrowId);
  U.info(`after supersede:  handover_expiry_ms=${exp2}`);
  if (exp1 !== null && exp1 === exp2) U.pass(`handover window UNCHANGED by supersede (anchored to first challenge) — incumbent's guarantee not shortened/extended`);
  else U.finding(`handover window changed by supersede: ${exp1} → ${exp2}`);
}

async function main() {
  await lowball();
  await retireBlocks();
  await supersedeWindow();
  U.summary();
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
