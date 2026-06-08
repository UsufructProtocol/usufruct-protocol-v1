// V2 — cross-escrow capability confusion. A cap/receipt minted for escrow A must be
// rejected against escrow B. Every attempt must ABORT.
import * as U from './lib.ts';
import { Transaction } from '@mysten/sui/transactions';

async function main() {
  U.head('V2 — cross-escrow capability confusion');
  const { GOV, UA, UB } = U.loadActors();

  // two independent escrows under the SAME governor cap-family? No — independent integrate
  // gives distinct GovernanceCaps. Make A and B fully independent.
  const A = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 120_000n, handover: 'off' });
  const B = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 120_000n, handover: 'off' });
  U.info(`A=${A.escrowId} (govCap ${A.govCapId})`);
  U.info(`B=${B.escrowId} (govCap ${B.govCapId})`);

  // UA rents A → capA (active in A)
  const rA = await U.rent(UA, A.escrowId, 5_000n, 1n);
  U.info(`UA capA=${rA.capId} active in A`);

  // 1) GovernanceCap_A used to retire B
  {
    const t = new Transaction();
    t.moveCall({ target: `${U.PKG}::escrow::retire`, typeArguments: U.TYPE_ARGS, arguments: [t.object(B.escrowId), t.object(A.govCapId), t.object(U.CLOCK)] });
    const r = await U.trySend(t, GOV);
    U.expectAbort(r, 'EWrongEscrowGovernanceCap', 'govCap_A → retire(B)');
  }
  // 2) GovernanceCap_A used to update_ensemble on B
  {
    const t = new Transaction();
    const ens = U.buildEnsemble(t, {});
    t.moveCall({ target: `${U.PKG}::escrow::update_ensemble`, typeArguments: U.TYPE_ARGS, arguments: [t.object(B.escrowId), t.object(A.govCapId), ens, t.object(U.CLOCK)] });
    const r = await U.trySend(t, GOV);
    U.expectAbort(r, 'EWrongEscrowGovernanceCap', 'govCap_A → update_ensemble(B)');
  }
  // 3) UsufructCap_A used to borrow B's asset
  {
    const t = new Transaction();
    const [asset, receipt] = t.moveCall({ target: `${U.PKG}::escrow::borrow_asset`, typeArguments: U.TYPE_ARGS, arguments: [t.object(B.escrowId), t.object(rA.capId), t.object(U.CLOCK)] });
    t.moveCall({ target: `${U.PKG}::escrow::return_asset`, typeArguments: U.TYPE_ARGS, arguments: [t.object(B.escrowId), asset, receipt] });
    const r = await U.trySend(t, UA);
    U.expectAbort(r, 'EWrongEscrowUsufructCap', 'usufructCap_A → borrow(B)');
  }
  // 4) UsufructCap_A used to update refund address on B
  {
    const t = new Transaction();
    const ra = t.moveCall({ target: `${U.PKG}::refund::refund_address`, arguments: [t.pure.address(U.addrOf(UA))] });
    t.moveCall({ target: `${U.PKG}::escrow::update_usufructuary_refund_address`, typeArguments: U.TYPE_ARGS, arguments: [t.object(B.escrowId), t.object(rA.capId), ra, t.object(U.CLOCK)] });
    const r = await U.trySend(t, UA);
    U.expectAbort(r, 'EWrongEscrowUsufructCap', 'usufructCap_A → update_refund(B)');
  }
  // 5) Borrow asset from A but return it to B (receipt mismatch). UA borrows A legitimately,
  //    then tries to consume the receipt against B in the same PTB.
  {
    const rB = await U.rent(UB, B.escrowId, 5_000n, 1n); // make B occupied so a parallel borrow could exist
    const t = new Transaction();
    const [assetA, receiptA] = t.moveCall({ target: `${U.PKG}::escrow::borrow_asset`, typeArguments: U.TYPE_ARGS, arguments: [t.object(A.escrowId), t.object(rA.capId), t.object(U.CLOCK)] });
    // return A's asset+receipt to escrow B → must abort
    t.moveCall({ target: `${U.PKG}::escrow::return_asset`, typeArguments: U.TYPE_ARGS, arguments: [t.object(B.escrowId), assetA, receiptA] });
    const r = await U.trySend(t, UA);
    U.expectAbort(r, 'EReceiptEscrowMismatch', 'receipt_A → return(B)');
    void rB;
  }

  U.summary();
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
