// V19 — the cross-escrow borrow/return swap (prompted by review).
// In ONE PTB, borrow from two escrows A and B (same <Asset,CoinType>, both rented by us) and
// try to cross the returns. Two crossing axes, each must abort:
//   (1) full cross:  return(A, assetB, receiptB) + return(B, assetA, receiptA)  → EReceiptEscrowMismatch
//   (2) asset swap:  return(A, assetB, receiptA) + return(B, assetA, receiptB)  → EReturnedDifferentAsset
//   control:         return(A, assetA, receiptA) + return(B, assetB, receiptB)  → ok
import * as U from './lib.ts';
import { Transaction } from '@mysten/sui/transactions';

// borrow both escrows in one tx, then apply a return-pairing callback
function attempt(eA: string, capA: string, eB: string, capB: string,
  pairing: (t: Transaction, aA: any, rA: any, aB: any, rB: any) => void) {
  const t = new Transaction();
  const [aA, rA] = t.moveCall({ target: `${U.PKG}::escrow::borrow_asset`, typeArguments: U.TYPE_ARGS, arguments: [t.object(eA), t.object(capA), t.object(U.CLOCK)] });
  const [aB, rB] = t.moveCall({ target: `${U.PKG}::escrow::borrow_asset`, typeArguments: U.TYPE_ARGS, arguments: [t.object(eB), t.object(capB), t.object(U.CLOCK)] });
  pairing(t, aA, rA, aB, rB);
  return t;
}
const ret = (t: Transaction, e: string, asset: any, receipt: any) =>
  t.moveCall({ target: `${U.PKG}::escrow::return_asset`, typeArguments: U.TYPE_ARGS, arguments: [t.object(e), asset, receipt] });

async function main() {
  U.head('V19 — cross-escrow borrow/return swap');
  const { GOV } = U.loadActors();
  // two escrows of identical <DummyAsset, DUMMY_COIN>, both rented by the same wallet (mother)
  const A = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 600_000n, handover: 'off' });
  const B = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 600_000n, handover: 'off' });
  const rA = await U.rent(U.mother, A.escrowId, 1_000n, 1n);
  const rB = await U.rent(U.mother, B.escrowId, 1_000n, 1n);
  U.info(`A=${A.escrowId.slice(0, 10)} capA=${rA.capId.slice(0, 10)}`);
  U.info(`B=${B.escrowId.slice(0, 10)} capB=${rB.capId.slice(0, 10)}`);

  // (1) full cross: receipt of B returned to escrow A (and vice versa)
  {
    const t = attempt(A.escrowId, rA.capId, B.escrowId, rB.capId, (t, aA, rAr, aB, rBr) => {
      ret(t, A.escrowId, aB, rBr); // receiptB → escrowA
      ret(t, B.escrowId, aA, rAr); // receiptA → escrowB
    });
    U.expectAbort(await U.trySend(t, U.mother), 'EReceiptEscrowMismatch', 'full cross return(A,assetB,receiptB)+return(B,assetA,receiptA)');
  }
  // (2) asset swap only: correct receipt↔escrow, but assets swapped
  {
    const t = attempt(A.escrowId, rA.capId, B.escrowId, rB.capId, (t, aA, rAr, aB, rBr) => {
      ret(t, A.escrowId, aB, rAr); // escrowA + receiptA + assetB
      ret(t, B.escrowId, aA, rBr); // escrowB + receiptB + assetA
    });
    U.expectAbort(await U.trySend(t, U.mother), 'EReturnedDifferentAsset', 'asset swap return(A,assetB,receiptA)+return(B,assetA,receiptB)');
  }
  // control: the only pairing that satisfies BOTH checks
  {
    const t = attempt(A.escrowId, rA.capId, B.escrowId, rB.capId, (t, aA, rAr, aB, rBr) => {
      ret(t, A.escrowId, aA, rAr);
      ret(t, B.escrowId, aB, rBr);
    });
    const r = await U.trySend(t, U.mother);
    if (r.ok) U.pass('control: genuine return(A,assetA,receiptA)+return(B,assetB,receiptB) succeeds');
    else U.finding(`control failed: ${U.truncErr(r.error)}`);
  }
  U.summary();
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
