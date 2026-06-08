// V12 — handover between tenants with DIFFERENT tenure counts. The new schedule's windows are
// rescaled: new_ceiling = floor(old_ceiling · incoming / committed) = tenureMs · incoming, and
// new_handover likewise. Verify the rescaled windows are sane (>0), match per-tenure × incoming,
// and that conservation still holds. Probe degenerate ratios (4→1, 1→4).
import * as U from './lib.ts';

// incumbent commits M tenures; challenger bids N tenures; check the post-handover schedule.
async function crossN(M: bigint, N: bigint) {
  U.head(`V12 — handover ${M}→${N} tenures (rescale)`);
  const { GOV, UA, UB } = U.loadActors();
  const tenureMs = 10_000n, handMs = 3_000n;
  const S1 = 12_000n;
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs, handover: { fixed: handMs }, multi: true, creditShape: 'linear', escalation: { fixed: 1n } });
  await U.rent(UA, g.escrowId, S1, M); // incumbent: old ceiling = tenureMs·M, old handover_total = handMs·M
  await U.sleep(1_500);
  // challenger bids N tenures; pay floor·N generously (free DUMMY_COIN)
  await U.rent(UB, g.escrowId, 60_000n, N);
  // handover boundary = bid + handover_total(incumbent) = handMs·M; wait past it
  const waitMs = Number(handMs * M) + 4_000;
  U.info(`waiting ${waitMs}ms past handover_total = handMs·M = ${handMs * M}ms…`);
  await U.sleep(waitMs);
  const a = await U.apply(GOV, g.escrowId);
  const ev = U.events(a, 'HandoverCompleted')[0];
  if (!ev) { U.finding('handover did not fire'); return; }
  const newCeiling = BigInt(ev.ceiling_total_ms), newHandover = BigInt(ev.handover_total_ms), committed = BigInt(ev.committed_tenures);
  U.info(`new ceiling_total=${newCeiling}ms handover_total=${newHandover}ms committed_tenures=${committed}`);

  // expected: rescaled = per-tenure × incoming  →  tenureMs·N and handMs·N
  if (newCeiling === tenureMs * N) U.pass(`new ceiling == tenureMs·N (${tenureMs * N}) — rescaled ${M}→${N} correctly`);
  else U.finding(`new ceiling ${newCeiling} != tenureMs·N ${tenureMs * N}`);
  if (newHandover === handMs * N) U.pass(`new handover == handMs·N (${handMs * N})`);
  else U.finding(`new handover ${newHandover} != handMs·N ${handMs * N}`);
  if (committed === N) U.pass(`committed_tenures == incoming N (${N})`);
  else U.finding(`committed ${committed} != N ${N}`);
  if (newCeiling > 0n && newHandover > 0n) U.pass('rescaled windows are sane (>0) — no zero/instant-expiry');
  else U.finding('rescaled window collapsed to 0');

  // conservation of the departing incumbent's stake
  const earnings = U.sumEvent(a, 'EarningsMessagePosted'), fee = U.sumEvent(a, 'FeeMessagePosted'), refund = U.balanceDelta(a, U.addrOf(UA));
  if (earnings + fee + refund === S1) U.pass(`conserved: ${earnings}+${fee}+${refund} == S1(${S1})`);
  else U.finding(`NOT conserved: ${earnings}+${fee}+${refund} != ${S1}`);
}

async function main() {
  await crossN(4n, 1n); // high → 1
  await crossN(1n, 4n); // 1 → high
  U.summary();
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
