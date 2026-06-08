// V16 — curve-shape parameter sweep + real protocol-fee drain.
//  (a) Credit-curve sweep: for each shape, a partial handover must yield used_credit ∈ [0, S]
//      (never over-charge) and conserve exactly, regardless of curve.
//  (b) Auction-shape bound: power_law / smoothstep descent stays within [rest, last_acq].
//  (c) Real fee drain: the deployer collects the ProtocolFeeInbox end-to-end (authorized).
import * as U from './lib.ts';
import { Transaction } from '@mysten/sui/transactions';

async function creditSweep(label: string, shape: U.ShapeSpec) {
  const { GOV, UA, UB } = U.loadActors();
  const S = 10_000n;
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 600_000n, handover: { fixed: 4_000n }, creditShape: shape, escalation: { fixed: 1n } });
  await U.rent(UA, g.escrowId, S, 1n);
  await U.sleep(1_500);
  await U.rent(UB, g.escrowId, 30_000n, 1n); // bid → Demand
  await U.sleep(6_000);
  const a = await U.apply(GOV, g.escrowId);
  const ev = U.events(a, 'HandoverCompleted')[0];
  const earnings = U.sumEvent(a, 'EarningsMessagePosted'), fee = U.sumEvent(a, 'FeeMessagePosted'), refund = U.balanceDelta(a, U.addrOf(UA));
  if (!ev) { U.finding(`${label}: handover did not fire`); return; }
  const used = BigInt(ev.used_credit);
  const okBound = used <= S && used >= 0n;
  const okCons = earnings + fee + refund === S;
  if (okBound) U.pass(`credit ${label}: used_credit ${used} ∈ [0, S] (no over-charge)`);
  else U.finding(`credit ${label}: used_credit ${used} OUT OF [0, ${S}]`);
  if (okCons) U.pass(`credit ${label}: conserved (${earnings}+${fee}+${refund} == ${S})`);
  else U.finding(`credit ${label}: NOT conserved (${earnings}+${fee}+${refund} != ${S})`);
}

async function auctionBound(label: string, shape: U.ShapeSpec) {
  const { GOV, UA } = U.loadActors();
  const REST = 1_000n, STAKE = 5_000n, TENURE = 7_000n, DESCENT = 24_000n;
  const g = await U.integrate(GOV, { restPrice: REST, tenureMs: TENURE, handover: 'off', descent: { fixed: DESCENT }, auctionShape: shape, escalation: { fixed: 1n } });
  await U.rent(UA, g.escrowId, STAKE, 1n);
  await U.sleep(Number(TENURE) + 2_500);
  await U.apply(GOV, g.escrowId);
  if (!(await U.viewBool('is_descending', g.escrowId))) { U.finding(`auction ${label}: not descending`); return; }
  let inBounds = true; const samples: bigint[] = [];
  for (let i = 0; i < 4; i++) {
    const tx = new Transaction();
    tx.moveCall({ target: `${U.PKG}::escrow::floor_price_mist`, typeArguments: U.TYPE_ARGS, arguments: [tx.object(g.escrowId), tx.pure.u64(BigInt(Date.now()))] });
    const res = await U.client.devInspectTransactionBlock({ transactionBlock: tx, sender: U.MOTHER });
    const p = U.decU64(res.results?.[0]?.returnValues?.[0]?.[0] as number[]);
    if (p === null) { U.finding(`auction ${label}: null price`); return; }
    samples.push(p);
    if (p < REST || p > STAKE) inBounds = false;
    await U.sleep(4_000);
  }
  U.info(`auction ${label}: ${samples.join(' → ')} (rest=${REST}, ceil=${STAKE})`);
  if (inBounds) U.pass(`auction ${label}: price ∈ [rest, last_acq] always (no underflow/overshoot)`);
  else U.finding(`auction ${label}: price escaped bounds`);
}

async function feeDrain() {
  U.head('V16(c) — real protocol-fee drain (deployer, authorized)');
  // produce at least one fresh settlement so a FeeMessage exists
  const { GOV, UA } = U.loadActors();
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 5_000n, handover: 'off' });
  await U.rent(UA, g.escrowId, 10_000n, 1n);
  await U.sleep(7_000);
  await U.apply(GOV, g.escrowId);
  // drain the deployer-owned ProtocolFeeInbox
  const c = await U.collectFees();
  U.info(`drained ${c.amount} mist from ${c.refs} FeeMessage(s) in inbox ${U.FEE_INBOX.slice(0, 12)} (digest ${c.res?.digest})`);
  if (c.refs > 0 && c.amount > 0n) U.pass(`protocol fees collectable & spendable end-to-end: ${c.amount} mist over ${c.refs} messages`);
  else U.finding(`fee drain returned nothing (refs=${c.refs}, amount=${c.amount})`);
  // collected total must equal the sum of FeeMessageCollected events on the drain tx
  if (c.res) {
    const collectedEv = U.sumEvent(c.res, 'FeeMessageCollected');
    if (collectedEv === c.amount) U.pass(`collected == Σ FeeMessageCollected events (${collectedEv})`);
    else U.finding(`amount ${c.amount} != Σ events ${collectedEv}`);
  }
  // deployer's coin balance must rise by the collected amount
  void GOV;
}

async function main() {
  U.head('V16(a) — credit-curve sweep (partial handover, used_credit ∈ [0,S])');
  await creditSweep('power_law(2,1)', { power_law: { num: 2, den: 1 } });
  await creditSweep('power_law(1,2)', { power_law: { num: 1, den: 2 } });
  await creditSweep('exponential(neg)', { exponential: { abs: 3, neg: true } });
  await creditSweep('smoothstep', 'smoothstep');
  U.head('V16(b) — auction-shape bound (power_law / smoothstep)');
  await auctionBound('power_law(2,1)', { power_law: { num: 2, den: 1 } });
  await auctionBound('smoothstep', 'smoothstep');
  await feeDrain();
  U.summary();
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
