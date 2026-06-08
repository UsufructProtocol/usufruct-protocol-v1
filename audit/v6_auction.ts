// V6 — Dutch auction (Descent) price integrity.
// - The descending price is always within [rest, last_acq]; never below the floor (no underflow).
// - Probe curve-height overshoot with aggressive auction_shapes (exponential/logistic): the
//   price function must not abort and must stay bounded.
// - You cannot acquire below the current descending price (EInsufficientPayment).
import * as U from './lib.ts';
import { Transaction } from '@mysten/sui/transactions';

const REST = 1_000n;
const DESCENT = 30_000n;
const TENURE = 7_000n;
const STAKE = 5_000n; // per-tenure acquisition price → Descent ceiling (last_acq)

async function toDescent(shape: U.ShapeSpec) {
  const { GOV, UA } = U.loadActors();
  const g = await U.integrate(GOV, { restPrice: REST, tenureMs: TENURE, handover: 'off', descent: { fixed: DESCENT }, auctionShape: shape, creditShape: 'linear', escalation: { fixed: 1n } });
  await U.rent(UA, g.escrowId, STAKE, 1n);
  await U.sleep(Number(TENURE) + 2_500);
  await U.apply(GOV, g.escrowId); // tenure expiry → Descent
  return g;
}

async function priceAt(escrowId: string, nowMs: number): Promise<bigint | null> {
  const tx = new Transaction();
  tx.moveCall({ target: `${U.PKG}::escrow::floor_price_mist`, typeArguments: U.TYPE_ARGS, arguments: [tx.object(escrowId), tx.pure.u64(BigInt(nowMs))] });
  const res = await U.client.devInspectTransactionBlock({ transactionBlock: tx, sender: U.MOTHER });
  return U.decU64(res.results?.[0]?.returnValues?.[0]?.[0] as number[] | undefined);
}

async function rentAtPrice(escrowId: string, totalMist: bigint) {
  const { UB } = U.loadActors();
  const t = new Transaction();
  const payment = U.mintDummy(t, totalMist);
  const tn = t.moveCall({ target: `${U.PKG}::ensemble::tenures`, arguments: [t.pure.u64(1n)] });
  const cap = t.moveCall({ target: `${U.PKG}::escrow::rent`, typeArguments: U.TYPE_ARGS, arguments: [t.object(escrowId), payment, tn, t.object(U.CLOCK)] });
  t.transferObjects([cap], U.addrOf(UB));
  return await U.trySend(t, UB);
}

async function run(label: string, shape: U.ShapeSpec) {
  U.head(`V6 — descending price integrity (auction_shape=${label})`);
  const g = await toDescent(shape);
  if (!(await U.viewBool('is_descending', g.escrowId))) { U.finding('expected Descent state'); return; }

  const samples: bigint[] = [];
  let monotone = true, inBounds = true;
  for (let i = 0; i < 6; i++) {
    const p = await priceAt(g.escrowId, Date.now());
    if (p === null) { U.finding('floor_price_mist returned null in Descent'); return; }
    samples.push(p);
    if (p < REST || p > STAKE) inBounds = false;
    if (samples.length > 1 && p > samples[samples.length - 2]) monotone = false;
    await U.sleep(4_000);
  }
  U.info(`price samples: ${samples.join(' → ')} (rest=${REST}, ceiling=${STAKE})`);
  if (inBounds) U.pass('price always within [rest, last_acq] — never below floor, no overshoot/underflow');
  else U.finding(`price escaped bounds: ${samples.join(',')}`);
  if (monotone) U.pass('price monotonically non-increasing (proper descent)');
  else U.finding('price non-monotone during descent');

  // underpay vs current price → abort
  const cur = await priceAt(g.escrowId, Date.now());
  if (cur !== null && cur > REST + 50n) {
    U.expectAbort(await rentAtPrice(g.escrowId, cur - 50n), 'EInsufficientPayment', `underpay (${cur - 50n} < price ${cur})`);
  } else U.info(`price ${cur} ~at rest; underpay test skipped`);
  // acquire at quoted price (+margin for elapsed ms) → succeed
  const cur2 = await priceAt(g.escrowId, Date.now());
  if (cur2 !== null) {
    const r = await rentAtPrice(g.escrowId, cur2 + 200n);
    if (r.ok) U.pass(`acquire at descending price (~${cur2}) succeeds`);
    else U.finding(`acquire at descending price failed: ${U.truncErr(r.error)}`);
  }
}

async function main() {
  await run('linear', 'linear');
  await run('exponential(abs=5)', { exponential: { abs: 5, neg: false } });
  await run('logistic', 'logistic');
  U.summary();
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
