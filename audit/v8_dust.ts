// V8 — rounding dust direction. With awkward (indivisible) amounts, confirm:
//  - conservation still holds exactly (no value created/destroyed),
//  - the protocol fee rounds DOWN (floor), so dust accrues to the governor — never to a
//    third party / attacker.
import * as U from './lib.ts';

async function tenureExpiryDust(stake: bigint, rest = 1_000n) {
  const { GOV, UA } = U.loadActors();
  const g = await U.integrate(GOV, { restPrice: rest, tenureMs: 6_000n, handover: 'off', escalation: { fixed: 1n } });
  await U.rent(UA, g.escrowId, stake, 1n);
  await U.sleep(8_000);
  const a = await U.apply(GOV, g.escrowId);
  const earnings = U.sumEvent(a, 'EarningsMessagePosted');
  const fee = U.sumEvent(a, 'FeeMessagePosted');
  const expectedFee = stake / 10n; // floor(stake/10)
  U.info(`stake=${stake}: earnings=${earnings} fee=${fee} (expected fee floor=${expectedFee})`);
  if (earnings + fee === stake) U.pass(`conserved: ${earnings}+${fee} == ${stake}`);
  else U.finding(`NOT conserved: ${earnings}+${fee} != ${stake}`);
  if (fee === expectedFee) U.pass(`fee == floor(stake/10) = ${expectedFee} (rounds down)`);
  else U.finding(`fee ${fee} != floor(stake/10) ${expectedFee}`);
  const dust = stake * 1n - (expectedFee * 10n); // remainder of stake mod 10
  if (earnings === stake - expectedFee) U.pass(`governor gets principal-fee (${earnings}); dust (${stake % 10n}) accrues to governor, not lost/attacker`);
  else U.finding(`earnings ${earnings} != ${stake - expectedFee}`);
}

async function main() {
  U.head('V8 — rounding dust direction (tenure expiry, awkward stakes)');
  await tenureExpiryDust(10_007n);   // 10007/10 = 1000.7 → fee 1000
  await tenureExpiryDust(99_991n);   // prime-ish
  await tenureExpiryDust(7n, 1n);    // tiny (rest=1): fee floor(7/10)=0 → governor gets all 7
  U.summary();
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
