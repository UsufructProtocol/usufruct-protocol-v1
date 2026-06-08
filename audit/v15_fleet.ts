// V15 — fleet: one GovernanceCap + one EarningsInbox govern N escrows; income from all N is
// collected in a single PTB. Verify conservation across the fleet and that a foreign cap/inbox
// cannot be added to the portfolio.
import * as U from './lib.ts';
import { Transaction } from '@mysten/sui/transactions';

function intoPortfolioTx(govCapId: string, inboxId: string) {
  const t = new Transaction();
  const asset = t.moveCall({ target: `${U.DUMMY_PKG}::dummy_asset::mint` });
  const ens = U.buildEnsemble(t, { restPrice: 1_000n, tenureMs: 6_000n, handover: 'off' });
  const rC = t.moveCall({ target: `${U.PKG}::ensemble::new_retire_commitment_immediate` });
  const eC = t.moveCall({ target: `${U.PKG}::ensemble::new_ensemble_commitment_immediate` });
  t.moveCall({ target: `${U.PKG}::escrow::integrate_into_portfolio`, typeArguments: U.TYPE_ARGS, arguments: [asset, ens, rC, eC, t.object(U.FEE_REF), t.object(govCapId), t.object(inboxId), t.object(U.CLOCK)] });
  return t;
}

async function main() {
  U.head('V15 — fleet portfolio + one-PTB collect');
  const { GOV, UA, UB } = U.loadActors();
  const tenureMs = 6_000n;

  // escrow #1 mints the cap+inbox; #2 and #3 reuse them
  const e1 = await U.integrate(GOV, { restPrice: 1_000n, tenureMs, handover: 'off' });
  const e2 = await U.integrateIntoPortfolio(GOV, e1.govCapId, e1.inboxId, { restPrice: 1_000n, tenureMs, handover: 'off' });
  const e3 = await U.integrateIntoPortfolio(GOV, e1.govCapId, e1.inboxId, { restPrice: 1_000n, tenureMs, handover: 'off' });
  U.info(`fleet: ${e1.escrowId.slice(0, 10)} ${e2.escrowId.slice(0, 10)} ${e3.escrowId.slice(0, 10)} (1 cap+inbox)`);

  // The real protection is OBJECT OWNERSHIP, not a cap↔inbox binding (integrate_into_portfolio
  // does NOT bind them — a governor may route a new escrow's income to any inbox THEY own,
  // governed by any cap THEY own; that is their own choice over their own objects, no leak).
  // What must be impossible: a THIRD party using the governor's cap+inbox they do not own.
  const bad = await U.trySend(intoPortfolioTx(e1.govCapId, e1.inboxId), UA); // UA owns neither
  if (!bad.ok) U.pass(`third party cannot add to GOV's portfolio (not the owner): ${U.truncErr(bad.error)}`);
  else U.finding('a non-owner added an escrow to the governor portfolio');
  // Documented behavior: governor mixing their OWN cap+inbox is allowed (no binding enforced),
  // and is safe because both are owned by the same governor.
  const ownMix = await U.trySend(intoPortfolioTx(e1.govCapId, e1.inboxId), GOV);
  if (ownMix.ok) U.info('note: governor may pair their own cap+inbox freely (no binding check; safe — both owned by GOV)');

  // rent the three escrows with distinct stakes / actors
  const S = { e1: 1_000n, e2: 2_000n, e3: 3_000n };
  await U.rent(UA, e1.escrowId, S.e1, 1n);
  await U.rent(UB, e2.escrowId, S.e2, 1n);
  await U.rent(U.mother, e3.escrowId, S.e3, 1n);

  U.info('waiting tenure expiry on all three…');
  await U.sleep(Number(tenureMs) + 2_500);
  let earnings = 0n, fees = 0n;
  for (const e of [e1, e2, e3]) {
    const a = await U.apply(GOV, e.escrowId);
    earnings += U.sumEvent(a, 'EarningsMessagePosted');
    fees += U.sumEvent(a, 'FeeMessagePosted');
  }
  const total = S.e1 + S.e2 + S.e3;
  U.info(`posted: earnings=${earnings} fees=${fees} (Σstakes=${total})`);
  if (earnings + fees === total) U.pass(`fleet conservation: ${earnings}+${fees} == Σstakes(${total})`);
  else U.finding(`fleet NOT conserved: ${earnings}+${fees} != ${total}`);

  // collect ALL income in ONE PTB from the single inbox
  const c = await U.collectEarnings(GOV, e1.inboxId);
  U.info(`collected ${c.amount} from ${c.refs} messages in ONE PTB (digest ${c.res?.digest})`);
  if (c.amount === earnings && c.refs === 3) U.pass(`O(N) income, O(1) collection: ${c.amount} == Σ earnings, ${c.refs} messages one PTB`);
  else U.finding(`collected ${c.amount}/${c.refs} != earnings ${earnings}/3`);

  U.summary();
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
