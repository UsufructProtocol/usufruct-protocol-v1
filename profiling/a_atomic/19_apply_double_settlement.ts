#!/usr/bin/env tsx
/**
 * Phase A / 19 — apply_* applying TWO settlements in one call.
 *
 * Sets up Occupied(t1) + pending bid(t2) [Demand], then waits past BOTH the
 * handover boundary (FullTenure → t1's tenure end) AND t2's subsequent tenure
 * ceiling, so a single apply_pending_transition_states chains:
 *   do_handover (t1 → t2)  +  do_tenure_expiry (t2 expires)
 * → 4 messages posted (2 FeeMessage + 2 EarningsMessage) in one tx.
 *
 * Measures that single apply. Verifies HandoverCompleted + TenureExpired both
 * fired in the same tx. Used to quantify the message-object storage saving when
 * two settlements coincide in one apply.
 */

import { resolve, dirname } from 'path';
import { fileURLToPath }  from 'url';
import { Transaction }    from '@mysten/sui/transactions';
import { writeFileSync }  from 'fs';
import {
  loadDeployment, loadKeypairs, makeClient,
  FLOOR_PRICE_MIST,
} from '../env.ts';
import { measure } from '../measure.ts';
import { buildIntegrate, buildFlowHandoverEnsemble, clock } from '../builders.ts';

const DIR = dirname(fileURLToPath(import.meta.url));

async function main() {
  const d      = loadDeployment();
  const client = makeClient();
  const kp     = loadKeypairs(d);

  const typeArgs = [
    `${d.dummyAssetPackageId}::dummy_asset::DummyAsset`,
    '0x2::sui::SUI',
  ];

  // 1. integrate (FullTenure handover, 10s tenure)
  process.stdout.write('integrate...');
  const tx1 = new Transaction();
  tx1.setSender(d.governor.address);
  const { governanceCap, inbox } = buildIntegrate(tx1, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId, buildFlowHandoverEnsemble);
  tx1.transferObjects([governanceCap, inbox], d.governor.address);
  const r1 = await measure(client, kp.governor, 'integrate', 0, tx1);
  console.log(` net=${r1.net}`);
  const c1 = (await client.getTransactionBlock({ digest: r1.digest, options: { showObjectChanges: true } })).objectChanges ?? [];
  const escrowId = (c1.find(c => c.type === 'created' && (c as any).objectType?.includes('Escrow')) as any).objectId;

  // 2. usufructuary1 rents (t1 → Occupied)
  process.stdout.write('rent(t1)...');
  const tx2 = new Transaction();
  tx2.setSender(d.usufructuary1.address);
  const [pay1] = tx2.splitCoins(tx2.gas, [tx2.pure.u64(FLOOR_PRICE_MIST)]);
  const cyc1  = tx2.moveCall({ target: `${d.usufructPackageId}::ensemble::tenures`, arguments: [tx2.pure.u64(1n)] });
  const cap1  = tx2.moveCall({ target: `${d.usufructPackageId}::escrow::rent`, typeArguments: typeArgs, arguments: [tx2.object(escrowId), pay1, cyc1, clock(tx2)] });
  tx2.transferObjects([cap1], d.usufructuary1.address);
  const r2 = await measure(client, kp.usufructuary1, 'rent_t1', 0, tx2);
  console.log(` net=${r2.net}`);

  // 3. usufructuary2 bids (→ Demand): a handover is now pending
  process.stdout.write('rent(t2 bid)...');
  const tx3 = new Transaction();
  tx3.setSender(d.usufructuary2.address);
  const [pay2] = tx3.splitCoins(tx3.gas, [tx3.pure.u64(FLOOR_PRICE_MIST * 2n)]);
  const cyc2  = tx3.moveCall({ target: `${d.usufructPackageId}::ensemble::tenures`, arguments: [tx3.pure.u64(1n)] });
  const cap2  = tx3.moveCall({ target: `${d.usufructPackageId}::escrow::rent`, typeArguments: typeArgs, arguments: [tx3.object(escrowId), pay2, cyc2, clock(tx3)] });
  tx3.transferObjects([cap2], d.usufructuary2.address);
  const r3 = await measure(client, kp.usufructuary2, 'rent_t2', 0, tx3);
  console.log(` net=${r3.net}`);

  // Wait past BOTH boundaries: handover (t1 end ~10s) + t2 ceiling (~20s).
  process.stdout.write('  waiting ~26s for handover + t2 expiry to both become pending...');
  await new Promise(r => setTimeout(r, 26000));
  console.log(' done');

  // 4. ONE apply → do_handover + do_tenure_expiry chained
  process.stdout.write('apply (double settlement)...');
  const txA = new Transaction();
  txA.setSender(d.governor.address);
  txA.moveCall({ target: `${d.usufructPackageId}::escrow::apply_pending_transition_states`, typeArguments: typeArgs, arguments: [txA.object(escrowId), clock(txA)] });
  const rA = await measure(client, kp.governor, 'apply_handover_plus_expiry', 0, txA);
  console.log(` net=${rA.net}`);

  // Verify both settlements fired in this single apply.
  const ev = (await client.getTransactionBlock({ digest: rA.digest, options: { showEvents: true, showObjectChanges: true } }));
  const evTypes = (ev.events ?? []).map(e => e.type.split('::').pop());
  const created = (ev.objectChanges ?? []).filter(c => c.type === 'created');
  const feeMsgs  = created.filter(c => (c as any).objectType?.includes('FeeMessage')).length;
  const earnMsgs = created.filter(c => (c as any).objectType?.includes('EarningsMessage')).length;
  const handover = evTypes.includes('HandoverCompleted');
  const expiry   = evTypes.includes('TenureExpired');
  console.log(`\n  events: HandoverCompleted=${handover}  TenureExpired=${expiry}`);
  console.log(`  messages created: FeeMessage=${feeMsgs}  EarningsMessage=${earnMsgs}  (objects created total=${created.length})`);
  console.log(`  >>> apply_handover_plus_expiry net = ${rA.net} MIST`);
  if (!handover || !expiry) {
    console.log('  WARNING: only one settlement fired — increase the wait and re-run.');
  }

  writeFileSync(
    resolve(DIR, '../results/a_19_apply_double_settlement.json'),
    JSON.stringify([{
      op: 'apply_handover_plus_expiry',
      net: rA.net.toString(),
      computation: rA.computation.toString(),
      storage: rA.storage.toString(),
      rebate: rA.rebate.toString(),
      handoverFired: handover, expiryFired: expiry,
      feeMessages: feeMsgs, earningsMessages: earnMsgs, objectsCreated: created.length,
    }], null, 2),
  );
}

main().catch(e => { console.error(e); process.exit(1); });
