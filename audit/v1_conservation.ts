// V1 — fund conservation end-to-end (CRITICAL invariant).
// (a) tenure expiry: covered in 00_smoke (earnings+fee==stake, no refund).
// (b) handover: partial credit → refund(departing) + earnings(gov) + fee == departing stake.
// (c) supersede: superseded pending bidder fully refunded.
import * as U from './lib.ts';

const UA_ADDR = () => U.addrOf(U.loadActors().UA);
const UB_ADDR = () => U.addrOf(U.loadActors().UB);

async function handover() {
  U.head('V1(b) — handover conservation (partial credit)');
  const { GOV, UA, UB } = U.loadActors();
  // long tenure, short handover countdown → partial credit at handover boundary
  const g = await U.integrate(GOV, {
    restPrice: 1_000n, tenureMs: 120_000n, handover: { fixed: 3_000n },
    descent: 'off', creditShape: 'linear', escalation: { fixed: 1n },
  });
  const S1 = 10_000n;
  const r1 = await U.rent(UA, g.escrowId, S1, 1n);
  U.info(`UA rented S1=${S1} (cap ${r1.capId})`);
  await U.sleep(2_000);
  // UB bids into Occupied → Demand. Overpay (free DUMMY_COIN) to clear the ascending floor.
  const S2 = 30_000n;
  const r2 = await U.rent(UB, g.escrowId, S2, 1n);
  U.info(`UB bid S2=${S2} → is_demand=${await U.viewBool('is_demand', g.escrowId)}`);

  U.info('waiting past handover countdown…');
  await U.sleep(4_000);
  const a = await U.apply(GOV, g.escrowId); // anyone can settle
  const earnings = U.sumEvent(a, 'EarningsMessagePosted');
  const fee = U.sumEvent(a, 'FeeMessagePosted');
  const refund = U.balanceDelta(a, U.addrOf(UA)); // liquidated stake coin to UA
  const ev = U.events(a, 'HandoverCompleted')[0];
  U.info(`settle digest ${a.digest}`);
  U.info(`earnings=${earnings} fee=${fee} refund(UA)=${refund}`);
  if (ev) U.info(`event: used_credit=${ev.used_credit} remain_credit=${ev.remain_credit} gov_share=${ev.governor_share} fee=${ev.protocol_fee} refund=${ev.departing_refund_amount}`);

  const sum = earnings + fee + refund;
  if (sum === S1) U.pass(`conservation: earnings(${earnings})+fee(${fee})+refund(${refund}) == S1(${S1})`);
  else U.finding(`conservation BROKEN: ${earnings}+${fee}+${refund}=${sum} != ${S1}`);

  // cross-checks against the event
  if (ev) {
    if (BigInt(ev.governor_share) === earnings && BigInt(ev.protocol_fee) === fee && BigInt(ev.departing_refund_amount) === refund)
      U.pass('event fields match on-chain coin flows (gov_share/fee/refund)');
    else U.finding('event fields diverge from coin flows');
    if (BigInt(ev.used_credit) === earnings + fee) U.pass(`used_credit == earnings+fee (${ev.used_credit})`);
    else U.finding(`used_credit(${ev.used_credit}) != earnings+fee(${earnings + fee})`);
    if (BigInt(ev.protocol_fee) === BigInt(ev.used_credit) / 10n) U.pass(`fee == 10% of used (floor)`);
    else U.finding(`fee(${ev.protocol_fee}) != used/10(${BigInt(ev.used_credit) / 10n})`);
    // refund never exceeds stake; used never exceeds stake
    if (BigInt(ev.used_credit) <= S1 && refund <= S1) U.pass('used_credit ≤ S1 and refund ≤ S1 (no over-extraction)');
    else U.finding('used or refund EXCEEDS stake');
  }

  // UB must now be the active tenant with its full stake intact
  const activeStake = await U.viewOptU64('active_stake_balance_mist', g.escrowId);
  if (activeStake === S2) U.pass(`incoming UB active with full stake (${activeStake})`);
  else U.finding(`UB active stake=${activeStake} != S2(${S2})`);
  return { escrowId: g.escrowId };
}

async function supersede() {
  U.head('V1(c) — supersede: pending bidder fully refunded');
  const { GOV, UA, UB } = U.loadActors();
  const g = await U.integrate(GOV, {
    restPrice: 1_000n, tenureMs: 120_000n, handover: { fixed: 30_000n },
    descent: 'off', creditShape: 'linear', escalation: { fixed: 1n },
  });
  await U.rent(UA, g.escrowId, 10_000n, 1n);       // incumbent
  const S2 = 30_000n;
  await U.rent(UB, g.escrowId, S2, 1n);            // UB pending
  U.info(`UB pending stake=${await U.viewOptU64('pending_stake_balance_mist', g.escrowId)}`);
  // mother supersedes UB → UB must be refunded S2 in full
  const before = BigInt((await U.client.getBalance({ owner: U.addrOf(UB), coinType: U.COIN_T })).totalBalance);
  const S3 = 90_000n;
  const tx = (await import('@mysten/sui/transactions')).Transaction;
  const t = new tx();
  const payment = U.mintDummy(t, S3);
  const tn = t.moveCall({ target: `${U.PKG}::ensemble::tenures`, arguments: [t.pure.u64(1n)] });
  const cap = t.moveCall({ target: `${U.PKG}::escrow::rent`, typeArguments: U.TYPE_ARGS, arguments: [t.object(g.escrowId), payment, tn, t.object(U.CLOCK)] });
  t.transferObjects([cap], U.MOTHER);
  const res = await U.send(t, U.mother);
  const refundUB = U.balanceDelta(res, U.addrOf(UB));
  const ev = U.events(res, 'BidSuperseded')[0];
  U.info(`supersede digest ${res.digest}`);
  U.info(`UB refund(balanceChange)=${refundUB}  event.refunded_amount=${ev?.refunded_amount}`);
  if (refundUB === S2) U.pass(`superseded UB fully refunded S2 (${S2}) — no loss`);
  else U.finding(`UB refund=${refundUB} != S2(${S2})`);
  const after = BigInt((await U.client.getBalance({ owner: U.addrOf(UB), coinType: U.COIN_T })).totalBalance);
  if (after - before === S2) U.pass(`UB wallet balance rose by exactly S2 (${after - before})`);
  else U.finding(`UB wallet delta=${after - before} != S2`);
  // new pending = mother with S3
  const pend = await U.viewOptU64('pending_stake_balance_mist', g.escrowId);
  if (pend === S3) U.pass(`mother now pending with S3 (${pend})`);
  else U.finding(`pending=${pend} != S3(${S3})`);
}

async function main() {
  await handover();
  await supersede();
  U.summary();
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
