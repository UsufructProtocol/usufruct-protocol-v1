// V11 — multi-tenure (N>1) arithmetic: pricing, conservation, and the floor(stake/N) asymmetry.
// The protocol's own docs call N-scaling "the most numerically error-prone area".
//   payment due      = floor · N          (exact)
//   next-bid floor   = escalate(floor(stake/N))   (per-tenure, truncated DOWN)
//   used credit      = on the FULL stake, vs the ×N ceiling
//   descent ceiling  = floor(stake/N)
import * as U from './lib.ts';
import { Transaction } from '@mysten/sui/transactions';

async function tenureSingleRejectsMulti() {
  U.head('V11(a) — tenure_single rejects N>1');
  const { GOV, UA } = U.loadActors();
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 600_000n, handover: 'off', multi: false });
  const r = await U.rent(UA, g.escrowId, 3_000n, 3n).then(() => ({ ok: true } as any)).catch((e) => ({ ok: false, error: String(e.message ?? e) }));
  if (!r.ok && (r.error.includes('tenure_extend_policy') || r.error.includes('EMultiCycleNotAllowed') || /\},\s*0\s*\)/.test(r.error)))
    U.pass(`rent(N=3) on tenure_single rejected (EMultiCycleNotAllowed): ${U.truncErr(r.error)}`);
  else if (!r.ok) U.pass(`rent(N=3) aborted: ${U.truncErr(r.error)}`);
  else U.finding('rent(N=3) on tenure_single SUCCEEDED');
  // N=1 must work on single
  const ok = await U.rent(UA, g.escrowId, 1_000n, 1n).then(() => true).catch(() => false);
  if (ok) U.pass('rent(N=1) on tenure_single works'); else U.finding('rent(N=1) on single failed');
}

async function paymentExactN() {
  U.head('V11(b) — payment due = floor · N (exact)');
  const { GOV, UA, UB } = U.loadActors();
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 600_000n, handover: 'off', multi: true });
  // N=3 → due = 3000; pay 2999 → abort; pay 3000 → ok
  U.expectAbort(await U.rent(UA, g.escrowId, 2_999n, 3n).then((x) => ({ ok: true, res: x } as any)).catch((e) => ({ ok: false, error: String(e.message ?? e) })), 'EInsufficientPayment', 'pay 2999 for N=3 (due 3000)');
  const ok = await U.rent(UB, g.escrowId, 3_000n, 3n).then(() => true).catch(() => false);
  if (ok) U.pass('pay exactly 3000 for N=3 succeeds'); else U.finding('exact N=3 payment failed');
}

async function bidFloorFromPerTenure() {
  U.head('V11(c) — next-bid floor = escalate(floor(stake/N)), truncated down');
  const { GOV, UA, UB } = U.loadActors();
  const S = 10_000n, N = 3n;
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 600_000n, handover: { fixed: 60_000n }, multi: true, escalation: { fixed: 1n } });
  await U.rent(UA, g.escrowId, S, N); // incumbent: per-tenure = floor(10000/3) = 3333
  const perTenure = S / N; // 3333
  const floor = perTenure + 1n; // escalate fixed +1 → 3334
  U.info(`incumbent S=${S} N=${N} → per-tenure floor(S/N)=${perTenure}; ascending floor=${floor}`);
  // bid one tenure below floor → abort
  U.expectAbort(await U.rent(UB, g.escrowId, floor - 1n, 1n).then((x) => ({ ok: true, res: x } as any)).catch((e) => ({ ok: false, error: String(e.message ?? e) })), 'EInsufficientPayment', `bid ${floor - 1n} < floor ${floor}`);
  // bid at floor → ok
  const ok = await U.rent(UB, g.escrowId, floor, 1n).then(() => true).catch(() => false);
  if (ok) U.pass(`bid at escalate(floor(S/N)) = ${floor} succeeds (truncation is per-tenure semantics, ≤${N - 1n} mist, not extraction)`);
  else U.finding(`bid at computed floor ${floor} failed`);
}

async function conservationN(stake: bigint, n: bigint) {
  const { GOV, UA } = U.loadActors();
  const tenureMs = 3_000n; // ceiling_total = tenureMs · N (durations scale ×N)
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs, handover: 'off', multi: true });
  await U.rent(UA, g.escrowId, stake, n);
  await U.sleep(Number(tenureMs * n) + 3_000); // wait the full ×N ceiling
  const a = await U.apply(GOV, g.escrowId);
  const earnings = U.sumEvent(a, 'EarningsMessagePosted'), fee = U.sumEvent(a, 'FeeMessagePosted');
  const ev = U.events(a, 'TenureExpired')[0];
  U.info(`stake=${stake} N=${n}: earnings=${earnings} fee=${fee} last_acq(per-tenure)=${ev?.last_acquisition_price}`);
  if (earnings + fee === stake) U.pass(`conserved with N=${n}: ${earnings}+${fee} == ${stake} (credit on full stake)`);
  else U.finding(`NOT conserved N=${n}: ${earnings}+${fee} != ${stake}`);
  if (fee === stake / 10n) U.pass(`fee == floor(stake/10) = ${stake / 10n}`); else U.finding(`fee ${fee} != ${stake / 10n}`);
  if (ev && BigInt(ev.last_acquisition_price) === stake / n) U.pass(`descent ceiling = floor(stake/N) = ${stake / n}`);
  else if (ev) U.finding(`last_acq ${ev.last_acquisition_price} != floor(stake/N) ${stake / n}`);
}

async function handoverN() {
  U.head('V11(e) — handover conservation with N>1 (credit on full stake)');
  const { GOV, UA, UB } = U.loadActors();
  const S1 = 10_000n, N = 3n;
  // handover_total = handoverMs · N = 3000·3 = 9000ms; ceiling = 120000·3 (won't expire)
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 120_000n, handover: { fixed: 3_000n }, multi: true, creditShape: 'linear', escalation: { fixed: 1n } });
  await U.rent(UA, g.escrowId, S1, N);
  await U.sleep(2_000);
  await U.rent(UB, g.escrowId, 30_000n, 1n); // bid (N=1) → Demand; boundary = bid + 9000ms
  await U.sleep(11_000);                       // wait past the ×N handover_total
  const a = await U.apply(GOV, g.escrowId);
  const earnings = U.sumEvent(a, 'EarningsMessagePosted'), fee = U.sumEvent(a, 'FeeMessagePosted'), refund = U.balanceDelta(a, U.addrOf(UA));
  const ev = U.events(a, 'HandoverCompleted')[0];
  U.info(`N=${N} S1=${S1}: earnings=${earnings} fee=${fee} refund=${refund} used=${ev?.used_credit}`);
  if (earnings + fee + refund === S1) U.pass(`handover conserved with N=${N}: ${earnings}+${fee}+${refund} == ${S1}`);
  else U.finding(`handover NOT conserved N=${N}: sum != ${S1}`);
  if (ev && BigInt(ev.used_credit) <= S1) U.pass(`used_credit ${ev.used_credit} ≤ full stake (integrated on full stake, not per-tenure)`);
}

async function main() {
  await tenureSingleRejectsMulti();
  await paymentExactN();
  await bidFloorFromPerTenure();
  U.head('V11(d) — conservation at tenure expiry with N>1, non-divisible stakes');
  await conservationN(10_000n, 3n);  // 10000/3 not integer
  await conservationN(99_991n, 7n);  // prime-ish / N
  await handoverN();
  U.summary();
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
