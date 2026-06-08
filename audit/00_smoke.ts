// Smoke test: full pipeline + V1(a) tenure-expiry conservation in DUMMY_COIN.
import * as U from './lib.ts';

async function main() {
  U.head('00 — smoke / pipeline + tenure-expiry conservation');
  const suiBal = BigInt((await U.client.getBalance({ owner: U.MOTHER })).totalBalance);
  U.info(`mother ${U.MOTHER}`);
  U.info(`SUI gas balance: ${Number(suiBal) / 1e9}`);

  // integrate with a short tenure so expiry comes quickly
  const TEN_MS = 8000n;
  const g = await U.integrate(U.mother, { restPrice: 1_000n, tenureMs: TEN_MS, handover: 'off', descent: 'off' });
  U.info(`integrated escrow ${g.escrowId} (digest ${g.digest})`);
  U.info(`is_idle=${await U.viewBool('is_idle', g.escrowId)}`);

  // rent: stake = 1000, n = 1
  const STAKE = 1_000n;
  const r = await U.rent(U.mother, g.escrowId, STAKE, 1n);
  U.info(`rented stake=${STAKE} cap=${r.capId} (digest ${r.digest})`);
  const occ = await U.viewBool('is_occupied', g.escrowId);
  if (occ) U.pass('is_occupied=true after rent'); else U.finding('not occupied after rent');

  // wait for tenure expiry then settle
  U.info('waiting for tenure expiry…');
  await U.sleep(10_000);
  const a = await U.apply(U.mother, g.escrowId);
  const earningsPosted = U.sumEvent(a, 'EarningsMessagePosted');
  const feePosted = U.sumEvent(a, 'FeeMessagePosted');
  U.info(`settle digest ${a.digest}`);
  U.info(`EarningsMessagePosted=${earningsPosted}  FeeMessagePosted=${feePosted}`);

  // conservation: earnings + fee == stake (no refund on tenure expiry); fee == 10%
  const conserved = earningsPosted + feePosted === STAKE;
  if (conserved) U.pass(`conservation: earnings(${earningsPosted}) + fee(${feePosted}) == stake(${STAKE})`);
  else U.finding(`conservation BROKEN: ${earningsPosted}+${feePosted} != ${STAKE}`);
  if (feePosted === STAKE / 10n) U.pass(`protocol fee == 10% (${feePosted})`);
  else U.finding(`fee != 10%: ${feePosted}`);

  // collect earnings — prove the income is real & spendable
  const c = await U.collectEarnings(U.mother, g.inboxId);
  U.info(`collected ${c.amount} from ${c.refs} message(s) (digest ${c.res?.digest})`);
  if (c.amount === earningsPosted) U.pass(`collected == posted (${c.amount})`);
  else U.finding(`collected(${c.amount}) != posted(${earningsPosted})`);

  U.summary();
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
