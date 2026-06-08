// V3 — only the ACTIVE usufruct cap may borrow. Pending and stale caps must abort.
// NOTE: borrow_asset reconciles FIRST (asset_state.move:1025), so a too-short handover
// window would settle the handover mid-test. We use TWO escrows with windows sized to the
// state we want to observe: a LONG window to keep Demand open (pending test), a SHORT
// window + explicit wait to reach the stale state (stale test).
import * as U from './lib.ts';
import { Transaction } from '@mysten/sui/transactions';

function borrowReturnTx(escrowId: string, capId: string) {
  const t = new Transaction();
  const [asset, receipt] = t.moveCall({ target: `${U.PKG}::escrow::borrow_asset`, typeArguments: U.TYPE_ARGS, arguments: [t.object(escrowId), t.object(capId), t.object(U.CLOCK)] });
  t.moveCall({ target: `${U.PKG}::escrow::return_asset`, typeArguments: U.TYPE_ARGS, arguments: [t.object(escrowId), asset, receipt] });
  return t;
}

async function pendingTest() {
  U.head('V3(a) — pending cap cannot borrow (Demand kept open, long window)');
  const { GOV, UA, UB } = U.loadActors();
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 600_000n, handover: { fixed: 300_000n }, creditShape: 'linear', escalation: { fixed: 1n } });
  const rA = await U.rent(UA, g.escrowId, 10_000n, 1n);
  {
    const r = await U.trySend(borrowReturnTx(g.escrowId, rA.capId), UA);
    if (r.ok) U.pass('active cap borrows (baseline)'); else U.finding(`baseline borrow failed: ${U.truncErr(r.error)}`);
  }
  const rB = await U.rent(UB, g.escrowId, 30_000n, 1n);
  if (await U.viewBool('is_demand', g.escrowId)) U.pass('escrow in Demand (window still open)');
  else U.finding('expected Demand state');
  // pending cap (UB) must abort EPendingUsufructCap
  U.expectAbort(await U.trySend(borrowReturnTx(g.escrowId, rB.capId), UB), 'EPendingUsufructCap', 'pending cap → borrow');
  // incumbent (UA) must STILL be able to borrow during the handover window
  {
    const r = await U.trySend(borrowReturnTx(g.escrowId, rA.capId), UA);
    if (r.ok) U.pass('incumbent active cap still borrows during Demand');
    else U.finding(`incumbent borrow during Demand failed: ${U.truncErr(r.error)}`);
  }
}

async function staleTest() {
  U.head('V3(b) — stale cap cannot borrow (after handover fires)');
  const { GOV, UA, UB } = U.loadActors();
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 600_000n, handover: { fixed: 3_000n }, creditShape: 'linear', escalation: { fixed: 1n } });
  const rA = await U.rent(UA, g.escrowId, 10_000n, 1n);
  const rB = await U.rent(UB, g.escrowId, 30_000n, 1n);
  U.info('waiting past handover countdown…');
  await U.sleep(5_000);
  await U.apply(GOV, g.escrowId); // fire handover: UA stale, UB active
  if (await U.viewBool('is_occupied', g.escrowId)) U.pass('handover settled → Occupied');
  else U.finding('expected Occupied after handover');
  // UA cap is now stale → EStaleUsufructCap
  U.expectAbort(await U.trySend(borrowReturnTx(g.escrowId, rA.capId), UA), 'EStaleUsufructCap', 'stale cap → borrow');
  // UB is the new active tenant → can borrow
  {
    const r = await U.trySend(borrowReturnTx(g.escrowId, rB.capId), UB);
    if (r.ok) U.pass('promoted UB cap borrows successfully'); else U.finding(`promoted borrow failed: ${U.truncErr(r.error)}`);
  }
}

async function main() {
  await pendingTest();
  await staleTest();
  U.summary();
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
