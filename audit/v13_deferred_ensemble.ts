// V13 — update_ensemble on a live (non-Idle) escrow only SCHEDULES a pending ensemble; it must
// not change the live terms mid-tenancy. The pending ensemble applies when the escrow next
// returns to Idle (Descent→Idle via do_auction_expiry). Verify the rest price flips only then.
import * as U from './lib.ts';

async function main() {
  U.head('V13 — deferred update_ensemble application');
  const { GOV, UA } = U.loadActors();
  const tenureMs = 5_000n, descentMs = 14_000n; // long descent so we can observe it before it expires
  const A_REST = 1_000n, B_REST = 5_000n;
  const g = await U.integrate(GOV, { restPrice: A_REST, tenureMs, handover: 'off', descent: { fixed: descentMs } });

  await U.rent(UA, g.escrowId, A_REST, 1n); // occupied under ensemble A
  const before = await U.viewU64('rest_price_floor_fixed_mist', g.escrowId);
  U.info(`live rest price (occupied, ensemble A) = ${before}`);

  // update_ensemble → B while occupied: must be scheduled, not applied
  const r = await U.trySend(U.updateEnsembleTx(g.escrowId, g.govCapId, { restPrice: B_REST, tenureMs, handover: 'off', descent: { fixed: descentMs } }), GOV);
  if (r.ok) U.pass('update_ensemble accepted (scheduled) on occupied escrow'); else { U.finding(`update_ensemble failed: ${U.truncErr(r.error)}`); return; }
  const mid = await U.viewU64('rest_price_floor_fixed_mist', g.escrowId);
  if (mid === A_REST) U.pass(`live rest price UNCHANGED mid-tenancy (${mid}) — B is only pending, not applied`);
  else U.finding(`live rest price changed mid-tenancy to ${mid} (expected ${A_REST})`);

  // tenure expiry → Descent (still ensemble A's resolved cycle)
  U.info('waiting tenure expiry → Descent…');
  await U.sleep(Number(tenureMs) + 2_500);
  await U.apply(GOV, g.escrowId);
  if (await U.viewBool('is_descending', g.escrowId)) U.pass('reached Descent'); else U.finding('expected Descent (timing)');
  const during = await U.viewU64('rest_price_floor_fixed_mist', g.escrowId);
  if (during === A_REST) U.pass(`rest price still A (${during}) during Descent (pending not yet applied)`);
  else U.finding(`rest price during descent = ${during} (expected A=${A_REST})`);

  // auction expiry → Idle → pending B applied
  U.info('waiting auction expiry → Idle (pending applies here)…');
  await U.sleep(Number(descentMs) + 2_500);
  await U.apply(GOV, g.escrowId);
  const idle = await U.viewBool('is_idle', g.escrowId);
  const after = await U.viewU64('rest_price_floor_fixed_mist', g.escrowId);
  U.info(`is_idle=${idle}; rest price now = ${after}`);
  if (idle && after === B_REST) U.pass(`pending ensemble B applied at Idle: rest price ${A_REST} → ${after}`);
  else U.finding(`expected rest ${B_REST} at Idle, got ${after} (idle=${idle})`);

  U.summary();
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
