// V5 — borrow cannot be weaponized. The AssetReceipt is a hot potato (no abilities):
// a PTB that borrows must return in the same PTB, else it cannot execute. A reverted
// borrow leaves the escrow untouched (atomic).
import * as U from './lib.ts';
import { Transaction } from '@mysten/sui/transactions';

async function main() {
  U.head('V5 — borrow-as-DoS / asset lock');
  const { GOV, UA } = U.loadActors();
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 600_000n, handover: 'off' });
  const rA = await U.rent(UA, g.escrowId, 5_000n, 1n);

  // 1) borrow and walk away (transfer asset to self, drop receipt) → must fail to execute
  {
    const t = new Transaction();
    const [asset, _receipt] = t.moveCall({ target: `${U.PKG}::escrow::borrow_asset`, typeArguments: U.TYPE_ARGS, arguments: [t.object(g.escrowId), t.object(rA.capId), t.object(U.CLOCK)] });
    t.transferObjects([asset], U.addrOf(UA)); // keep the asset, never return; receipt left dangling
    const r = await U.trySend(t, UA);
    if (!r.ok) U.pass(`borrow-without-return rejected (hot-potato receipt): ${U.truncErr(r.error)}`);
    else U.finding('borrow-without-return EXECUTED — asset can be stolen');
  }

  // 2) borrow twice in one PTB without returning the first → must fail
  {
    const t = new Transaction();
    const [a1, r1] = t.moveCall({ target: `${U.PKG}::escrow::borrow_asset`, typeArguments: U.TYPE_ARGS, arguments: [t.object(g.escrowId), t.object(rA.capId), t.object(U.CLOCK)] });
    const [a2, r2] = t.moveCall({ target: `${U.PKG}::escrow::borrow_asset`, typeArguments: U.TYPE_ARGS, arguments: [t.object(g.escrowId), t.object(rA.capId), t.object(U.CLOCK)] });
    // try to return both (the escrow only held one asset)
    t.moveCall({ target: `${U.PKG}::escrow::return_asset`, typeArguments: U.TYPE_ARGS, arguments: [t.object(g.escrowId), a1, r1] });
    t.moveCall({ target: `${U.PKG}::escrow::return_asset`, typeArguments: U.TYPE_ARGS, arguments: [t.object(g.escrowId), a2, r2] });
    const r = await U.trySend(t, UA);
    if (!r.ok) U.pass(`double-borrow in one PTB rejected: ${U.truncErr(r.error)}`);
    else U.finding('double-borrow EXECUTED — asset duplicated/escrow desynced');
  }

  // 3) after the failed attempts, the escrow is still healthy (atomic revert) and borrowable
  {
    const t = new Transaction();
    const [asset, receipt] = t.moveCall({ target: `${U.PKG}::escrow::borrow_asset`, typeArguments: U.TYPE_ARGS, arguments: [t.object(g.escrowId), t.object(rA.capId), t.object(U.CLOCK)] });
    t.moveCall({ target: `${U.PKG}::escrow::return_asset`, typeArguments: U.TYPE_ARGS, arguments: [t.object(g.escrowId), asset, receipt] });
    const r = await U.trySend(t, UA);
    if (r.ok) U.pass('escrow still healthy: legit borrow+return works after failed attacks');
    else U.finding(`escrow bricked after failed borrow attempts: ${U.truncErr(r.error)}`);
  }
  U.summary();
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
