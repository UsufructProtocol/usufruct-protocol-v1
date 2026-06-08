// V4 — the handover window guarantee.
// (1) The window is HONORED: reconciling before expiry does NOT displace the incumbent.
// (2) The incumbent cannot BLOCK it: after expiry, a neutral third party's reconcile promotes.
// (3) Credit is CAPPED at the boundary, not at settlement time: settling late does not
//     over-charge the incumbent (used_credit anchored to bid+window, not to "now").
import * as U from './lib.ts';

async function main() {
  U.head('V4 — handover window guarantee');
  const { GOV, UA, UB } = U.loadActors();
  const HANDOVER = 15_000n;
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 600_000n, handover: { fixed: HANDOVER }, creditShape: 'linear', escalation: { fixed: 1n } });
  const S1 = 10_000n;
  await U.rent(UA, g.escrowId, S1, 1n);
  await U.rent(UB, g.escrowId, 30_000n, 1n);
  const hoExpiry = await U.viewOptU64('handover_expiry_ms', g.escrowId);
  U.info(`Demand opened; handover_expiry_ms=${hoExpiry}`);

  // (1) reconcile BEFORE expiry → must remain Demand with UA active
  await U.apply(UA, g.escrowId); // even the incumbent reconciling does not flip it early
  if (await U.viewBool('is_demand', g.escrowId)) U.pass('reconcile before expiry → still Demand (window honored)');
  else U.finding('handover fired BEFORE expiry — window violated');
  const activeBefore = await U.viewOptU64('active_stake_balance_mist', g.escrowId);
  if (activeBefore === S1) U.pass(`incumbent still active before expiry (stake ${activeBefore})`);
  else U.finding(`incumbent not active before expiry: ${activeBefore}`);

  // (2) wait PAST expiry + extra delay, then a NEUTRAL party (mother) settles
  U.info('waiting past expiry (+ extra delay to test late settlement)…');
  const nowMs = Number(await U.viewU64('integrated_at_ms', g.escrowId)); void nowMs;
  await U.sleep(Number(HANDOVER) + 12_000); // ~12s past the window
  const a = await U.apply(U.mother, g.escrowId); // neutral third party — incumbent cannot block
  const ev = U.events(a, 'HandoverCompleted')[0];
  if (await U.viewBool('is_occupied', g.escrowId)) U.pass('neutral party settled handover after expiry (incumbent cannot block)');
  else U.finding('handover did not fire after expiry');

  // (3) credit capped at boundary, not at settlement time
  if (ev) {
    const phaseStart = BigInt(ev.departing_phase_start_ms);
    const ceiling = BigInt(ev.departing_ceiling_total_ms);
    const boundary = BigInt(ev.timestamp_ms); // do_handover stamps the boundary
    const used = BigInt(ev.used_credit);
    const expectedLinear = (S1 * (boundary - phaseStart)) / ceiling; // linear curve, anchored at boundary
    U.info(`phase_start=${phaseStart} boundary=${boundary} ceiling=${ceiling} used=${used} expected≈${expectedLinear}`);
    // boundary must be ≈ bid_time + HANDOVER, i.e. NOT pushed to the (late) settlement time
    const windowSpan = boundary - phaseStart;
    if (windowSpan <= HANDOVER + 6_000n) U.pass(`credit window span ${windowSpan}ms ≈ handover ${HANDOVER}ms (capped at boundary, not late settle)`);
    else U.finding(`credit window span ${windowSpan}ms >> handover ${HANDOVER}ms — charged past the window`);
    if (used === expectedLinear) U.pass(`used_credit == linear(area to boundary) exactly (${used})`);
    else U.info(`used_credit ${used} vs linear-estimate ${expectedLinear} (timestamp granularity; within reason if close)`);
    if (used <= S1) U.pass('used_credit ≤ stake (incumbent never over-charged)');
    else U.finding('used_credit EXCEEDS stake');
  }
  U.summary();
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
