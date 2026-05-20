#!/usr/bin/env tsx
/**
 * Phase B / 02 — Asset lifecycle (with borrow/return)
 * Flow: integrate → rent → borrow+return → [wait tenure] → retire → apply → claim
 */

import { resolve, dirname } from 'path';
import { fileURLToPath }  from 'url';
import { Transaction }    from '@mysten/sui/transactions';
import { writeFileSync }  from 'fs';
import {
  loadDeployment, loadKeypairs, makeClient,
} from '../env.ts';
import { measure } from '../measure.ts';
import { buildIntegrate, buildRent, buildFlowEnsemble, clock, random } from '../builders.ts';

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

  // 1. integrate
  process.stdout.write('Step 1 integrate...');
  const tx1 = new Transaction();
  tx1.setSender(d.owner.address);
  const ownerCap = buildIntegrate(tx1, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId, buildFlowEnsemble);
  tx1.transferObjects([ownerCap], d.owner.address);
  const r1 = await measure(client, kp.owner, 'integrate', 0, tx1);
  steps.push(r1);
  console.log(` net=${r1.net}`);

  const c1 = (await client.getTransactionBlock({ digest: r1.digest, options: { showObjectChanges: true } })).objectChanges ?? [];
  const escrowId   = (c1.find(c => c.type === 'created' && (c as any).objectType?.includes('Escrow')) as any).objectId;
  const ownerCapId = (c1.find(c => c.type === 'created' && (c as any).objectType?.includes('OwnerCap')) as any).objectId;

  // 2. rent
  process.stdout.write('Step 2 rent...');
  const tx2 = new Transaction();
  tx2.setSender(d.tenant1.address);
  const cap = buildRent(tx2, d.usufructPackageId, d.dummyAssetPackageId, escrowId);
  tx2.transferObjects([cap], d.tenant1.address);
  const r2 = await measure(client, kp.tenant1, 'rent', 0, tx2);
  steps.push(r2);
  console.log(` net=${r2.net}`);

  const c2 = (await client.getTransactionBlock({ digest: r2.digest, options: { showObjectChanges: true } })).objectChanges ?? [];
  const tenantCapId = (c2.find(c => c.type === 'created' && (c as any).objectType?.includes('TenantCap')) as any).objectId;

  // 3. borrow + return (single PTB via profiling_helpers)
  process.stdout.write('Step 3 borrow+return...');
  const tx3 = new Transaction();
  tx3.setSender(d.tenant1.address);
  tx3.moveCall({
    target: `${d.usufructPackageId}::profiling_helpers::borrow_and_return`,
    typeArguments: typeArgs,
    arguments: [tx3.object(escrowId), tx3.object(tenantCapId), random(tx3), clock(tx3)],
  });
  const r3 = await measure(client, kp.tenant1, 'borrow_return', 0, tx3);
  steps.push(r3);
  console.log(` net=${r3.net}`);

  // 4. retire
  process.stdout.write('Step 4 retire...');
  const tx4 = new Transaction();
  tx4.setSender(d.owner.address);
  tx4.moveCall({
    target: `${d.usufructPackageId}::escrow::retire`,
    typeArguments: typeArgs,
    arguments: [tx4.object(escrowId), tx4.object(ownerCapId), random(tx4), clock(tx4)],
  });
  const r4 = await measure(client, kp.owner, 'retire', 0, tx4);
  steps.push(r4);
  console.log(` net=${r4.net}`);

  // Wait for tenure expiry
  process.stdout.write('  waiting for tenure expiry...');
  await new Promise(r => setTimeout(r, 12000));
  console.log(' done');

  // 4b. apply
  const tx4b = new Transaction();
  tx4b.setSender(d.owner.address);
  tx4b.moveCall({
    target: `${d.usufructPackageId}::escrow::apply_pending_transition_states`,
    typeArguments: typeArgs,
    arguments: [tx4b.object(escrowId), random(tx4b), clock(tx4b)],
  });
  const r4b = await measure(client, kp.owner, 'apply_transitions', 0, tx4b);
  steps.push(r4b);

  // 5. claim
  process.stdout.write('Step 5 claim...');
  const tx5 = new Transaction();
  tx5.setSender(d.owner.address);
  const [claimedAsset, earnings] = tx5.moveCall({
    target: `${d.usufructPackageId}::escrow::claim_asset`,
    typeArguments: typeArgs,
    arguments: [tx5.object(escrowId), tx5.object(ownerCapId), random(tx5), clock(tx5)],
  }) as any[];
  tx5.transferObjects([claimedAsset, earnings], d.owner.address);
  const r5 = await measure(client, kp.owner, 'claim_asset', 0, tx5);
  steps.push(r5);
  console.log(` net=${r5.net}`);

  const totalNet = steps.reduce((acc, s) => acc + s.net, 0n);
  console.log(`\nTotal net cost: ${totalNet} MIST`);

  writeFileSync(
    resolve(DIR, '../results/b_02_asset_lifecycle.json'),
    JSON.stringify(steps.map(s => ({ ...s, computation: s.computation.toString(), storage: s.storage.toString(), rebate: s.rebate.toString(), nonRefundable: s.nonRefundable.toString(), net: s.net.toString() })), null, 2),
  );
}

main().catch(e => { console.error(e); process.exit(1); });
