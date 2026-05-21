#!/usr/bin/env tsx
/**
 * Phase B / 03 — Tenant rotation via handover
 * Flow: integrate → rent(t1) → [wait tenure] → rent(t2) → retire → apply → claim
 * HandoverPolicy::FullTenure allows t2 to bid at any point during t1's tenure.
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

  const steps: any[] = [];

  // 1. integrate (2s tenure, FullTenure handover)
  process.stdout.write('Step 1 integrate...');
  const tx1 = new Transaction();
  tx1.setSender(d.owner.address);
  const ownerCap = buildIntegrate(tx1, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId, buildFlowHandoverEnsemble);
  tx1.transferObjects([ownerCap], d.owner.address);
  const r1 = await measure(client, kp.owner, 'integrate', 0, tx1);
  steps.push(r1);
  console.log(` net=${r1.net}`);

  const c1 = (await client.getTransactionBlock({ digest: r1.digest, options: { showObjectChanges: true } })).objectChanges ?? [];
  const escrowId   = (c1.find(c => c.type === 'created' && (c as any).objectType?.includes('Escrow')) as any).objectId;
  const ownerCapId = (c1.find(c => c.type === 'created' && (c as any).objectType?.includes('OwnerCap')) as any).objectId;

  // 2. tenant1 rents
  process.stdout.write('Step 2 rent(t1)...');
  const tx2 = new Transaction();
  tx2.setSender(d.tenant1.address);
  const [pay1] = tx2.splitCoins(tx2.gas, [tx2.pure.u64(FLOOR_PRICE_MIST)]);
  const cyc1  = tx2.moveCall({ target: `${d.usufructPackageId}::tenures::tenures`, arguments: [tx2.pure.u64(1n)] });
  const cap1  = tx2.moveCall({
    target: `${d.usufructPackageId}::escrow::rent`,
    typeArguments: typeArgs,
    arguments: [tx2.object(escrowId), pay1, cyc1, clock(tx2)],
  });
  tx2.transferObjects([cap1], d.tenant1.address);
  const r2 = await measure(client, kp.tenant1, 'rent_t1', 0, tx2);
  steps.push(r2);
  console.log(` net=${r2.net}`);

  const c2 = (await client.getTransactionBlock({ digest: r2.digest, options: { showObjectChanges: true } })).objectChanges ?? [];
  const cap1Id = (c2.find(c => c.type === 'created' && (c as any).objectType?.includes('TenantCap')) as any).objectId;

  // 3. tenant2 bids (→ Demand, cap1 becomes stale)
  process.stdout.write('Step 3 rent(t2)...');
  const tx3 = new Transaction();
  tx3.setSender(d.tenant2.address);
  const [pay2] = tx3.splitCoins(tx3.gas, [tx3.pure.u64(FLOOR_PRICE_MIST * 2n)]); // 2x for escalation
  const cyc2  = tx3.moveCall({ target: `${d.usufructPackageId}::tenures::tenures`, arguments: [tx3.pure.u64(1n)] });
  const cap2  = tx3.moveCall({
    target: `${d.usufructPackageId}::escrow::rent`,
    typeArguments: typeArgs,
    arguments: [tx3.object(escrowId), pay2, cyc2, clock(tx3)],
  });
  tx3.transferObjects([cap2], d.tenant2.address);
  const r3 = await measure(client, kp.tenant2, 'rent_t2', 0, tx3);
  steps.push(r3);
  console.log(` net=${r3.net}`);

  // 4. soft_burn stale cap1
  process.stdout.write('  waiting for tenure expiry + apply...');
  await new Promise(r => setTimeout(r, 12000));
  const txApp = new Transaction();
  txApp.setSender(d.owner.address);
  txApp.moveCall({
    target: `${d.usufructPackageId}::escrow::apply_pending_transition_states`,
    typeArguments: typeArgs,
    arguments: [txApp.object(escrowId), clock(txApp)],
  });
  const rApp = await measure(client, kp.owner, 'apply_handover', 0, txApp);
  steps.push(rApp);
  console.log(` net=${rApp.net}`);

  // Burn stale cap1
  process.stdout.write('Step 4 soft_burn(stale t1)...');
  const tx4 = new Transaction();
  tx4.setSender(d.tenant1.address);
  tx4.moveCall({
    target: `${d.usufructPackageId}::escrow::soft_burn_tenant_cap`,
    typeArguments: typeArgs,
    arguments: [tx4.object(escrowId), tx4.object(cap1Id), clock(tx4)],
  });
  const r4 = await measure(client, kp.tenant1, 'soft_burn', 0, tx4);
  steps.push(r4);
  console.log(` net=${r4.net}`);

  // 5. retire
  process.stdout.write('Step 5 retire...');
  const tx5 = new Transaction();
  tx5.setSender(d.owner.address);
  tx5.moveCall({
    target: `${d.usufructPackageId}::escrow::retire`,
    typeArguments: typeArgs,
    arguments: [tx5.object(escrowId), tx5.object(ownerCapId), clock(tx5)],
  });
  const r5 = await measure(client, kp.owner, 'retire', 0, tx5);
  steps.push(r5);
  console.log(` net=${r5.net}`);

  // Wait for t2's tenure to expire, then apply+claim
  process.stdout.write('  waiting for t2 tenure expiry...');
  await new Promise(r => setTimeout(r, 12000));
  console.log(' done');

  const txApp2 = new Transaction();
  txApp2.setSender(d.owner.address);
  txApp2.moveCall({
    target: `${d.usufructPackageId}::escrow::apply_pending_transition_states`,
    typeArguments: typeArgs,
    arguments: [txApp2.object(escrowId), clock(txApp2)],
  });
  const rApp2 = await measure(client, kp.owner, 'apply_transitions', 0, txApp2);
  steps.push(rApp2);

  // 6. claim
  process.stdout.write('Step 6 claim...');
  const tx6 = new Transaction();
  tx6.setSender(d.owner.address);
  const [asset, earnings] = tx6.moveCall({
    target: `${d.usufructPackageId}::escrow::claim_asset`,
    typeArguments: typeArgs,
    arguments: [tx6.object(escrowId), tx6.object(ownerCapId), clock(tx6)],
  }) as any[];
  tx6.transferObjects([asset, earnings], d.owner.address);
  const r6 = await measure(client, kp.owner, 'claim_asset', 0, tx6);
  steps.push(r6);
  console.log(` net=${r6.net}`);

  const totalNet = steps.reduce((acc, s) => acc + s.net, 0n);
  console.log(`\nTotal net cost: ${totalNet} MIST`);

  writeFileSync(
    resolve(DIR, '../results/b_03_handover.json'),
    JSON.stringify(steps.map(s => ({ ...s, computation: s.computation.toString(), storage: s.storage.toString(), rebate: s.rebate.toString(), nonRefundable: s.nonRefundable.toString(), net: s.net.toString() })), null, 2),
  );
}

main().catch(e => { console.error(e); process.exit(1); });
