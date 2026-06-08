// V10 — asset/coin composition boundary.
//  - Returning a DIFFERENT object (same type, different id) aborts EReturnedDifferentAsset.
//  - A legit borrow → use_asset (mutates + mints a Coupon) → return cycle works; the protocol
//    enforces the return of the exact borrowed object regardless of what the asset's code does.
import * as U from './lib.ts';
import { Transaction } from '@mysten/sui/transactions';

async function returnDifferent() {
  U.head('V10(a) — returning a different object aborts');
  const { GOV, UA } = U.loadActors();
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 600_000n, handover: 'off' });
  const rA = await U.rent(UA, g.escrowId, 5_000n, 1n);
  const t = new Transaction();
  const [borrowed, receipt] = t.moveCall({ target: `${U.PKG}::escrow::borrow_asset`, typeArguments: U.TYPE_ARGS, arguments: [t.object(g.escrowId), t.object(rA.capId), t.object(U.CLOCK)] });
  // mint a FRESH dummy_asset of the same type, different id
  const fake = t.moveCall({ target: `${U.DUMMY_PKG}::dummy_asset::mint` });
  // try to return the fake, keep the real one
  t.moveCall({ target: `${U.PKG}::escrow::return_asset`, typeArguments: U.TYPE_ARGS, arguments: [t.object(g.escrowId), fake, receipt] });
  t.transferObjects([borrowed], U.addrOf(UA)); // would keep the real asset
  U.expectAbort(await U.trySend(t, UA), 'EReturnedDifferentAsset', 'return a different object (asset swap)');
}

async function legitUse() {
  U.head('V10(b) — borrow → use_asset → return works (composition holds)');
  const { GOV, UA } = U.loadActors();
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 600_000n, handover: 'off' });
  const rA = await U.rent(UA, g.escrowId, 5_000n, 1n);
  const t = new Transaction();
  const [borrowed, receipt] = t.moveCall({ target: `${U.PKG}::escrow::borrow_asset`, typeArguments: U.TYPE_ARGS, arguments: [t.object(g.escrowId), t.object(rA.capId), t.object(U.CLOCK)] });
  const coupon = t.moveCall({ target: `${U.DUMMY_PKG}::dummy_asset::use_asset`, arguments: [borrowed] });
  t.transferObjects([coupon], U.addrOf(UA));
  t.moveCall({ target: `${U.PKG}::escrow::return_asset`, typeArguments: U.TYPE_ARGS, arguments: [t.object(g.escrowId), borrowed, receipt] });
  const r = await U.trySend(t, UA);
  if (r.ok) {
    const coupons = U.createdIds(r.res, '::dummy_asset::Coupon');
    U.pass(`borrow+use+return works; renter kept ${coupons.length} Coupon (value from use, no ownership)`);
  } else U.finding(`legit use cycle failed: ${U.truncErr(r.error)}`);
}

async function main() {
  await returnDifferent();
  await legitUse();
  U.info('CoinType axis: protocol only calls coin::into_balance once at rent; no arbitrary coin');
  U.info('methods are invoked → balance-level arithmetic only. Surface is minimal (see report).');
  U.summary();
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
