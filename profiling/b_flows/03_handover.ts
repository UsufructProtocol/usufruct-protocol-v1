#!/usr/bin/env tsx
/**
 * Phase B / 03 — Tenant rotation via handover
 * Flow: integrate → rent(t1) → soft_burn(t1) → rent(t2) → retire → claim
 * Shows the cost of a full tenant rotation through the demand/handover protocol.
 */

import { resolve, dirname } from 'path';
import { fileURLToPath }  from 'url';
import { Transaction }    from '@mysten/sui/transactions';
import { writeFileSync }  from 'fs';
import {
  loadDeployment, loadKeypairs, makeClient,
} from '../env.ts';
import { measure } from '../measure.ts';
import { buildIntegrate, buildRent, buildHandoverEnsemble, clock, random } from '../builders.ts';

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

  // 1. integrate (with handover ensemble)
  process.stdout.write('Step 1 integrate...');
  const tx1 = new Transaction();
  tx1.setSender(d.owner.address);
  const ownerCap = buildIntegrate(
    tx1, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId,
    buildHandoverEnsemble,
  );
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
  const cap1 = buildRent(tx2, d.usufructPackageId, d.dummyAssetPackageId, escrowId);
  tx2.transferObjects([cap1], d.tenant1.address);
  const r2 = await measure(client, kp.tenant1, 'rent_t1', 0, tx2);
  steps.push(r2);
  console.log(` net=${r2.net}`);

  const c2 = (await client.getTransactionBlock({ digest: r2.digest, options: { showObjectChanges: true } })).objectChanges ?? [];
  const tenantCap1Id = (c2.find(c => c.type === 'created' && (c as any).objectType?.includes('TenantCap')) as any).objectId;

  // 3. tenant1 soft_burns (→ demand)
  process.stdout.write('Step 3 soft_burn(t1)...');
  const tx3 = new Transaction();
  tx3.setSender(d.tenant1.address);
  tx3.moveCall({
    target: `${d.usufructPackageId}::escrow::soft_burn_tenant_cap`,
    typeArguments: typeArgs,
    arguments: [tx3.object(escrowId), tx3.object(tenantCap1Id), random(tx3), clock(tx3)],
  });
  const r3 = await measure(client, kp.tenant1, 'soft_burn', 0, tx3);
  steps.push(r3);
  console.log(` net=${r3.net}`);

  // 4. tenant2 rents (filling the demand slot)
  process.stdout.write('Step 4 rent(t2)...');
  const tx4 = new Transaction();
  tx4.setSender(d.tenant2.address);
  const cap2 = buildRent(tx4, d.usufructPackageId, d.dummyAssetPackageId, escrowId);
  tx4.transferObjects([cap2], d.tenant2.address);
  const r4 = await measure(client, kp.tenant2, 'rent_t2', 0, tx4);
  steps.push(r4);
  console.log(` net=${r4.net}`);

  const c4 = (await client.getTransactionBlock({ digest: r4.digest, options: { showObjectChanges: true } })).objectChanges ?? [];
  const tenantCap2Id = (c4.find(c => c.type === 'created' && (c as any).objectType?.includes('TenantCap')) as any).objectId;

  // 5. owner retires
  process.stdout.write('Step 5 retire...');
  const tx5 = new Transaction();
  tx5.setSender(d.owner.address);
  tx5.moveCall({
    target: `${d.usufructPackageId}::escrow::retire`,
    typeArguments: typeArgs,
    arguments: [tx5.object(escrowId), tx5.object(ownerCapId), random(tx5), clock(tx5)],
  });
  const r5 = await measure(client, kp.owner, 'retire', 0, tx5);
  steps.push(r5);
  console.log(` net=${r5.net}`);

  // 5b. apply
  const tx5b = new Transaction();
  tx5b.setSender(d.owner.address);
  tx5b.moveCall({
    target: `${d.usufructPackageId}::escrow::apply_pending_transition_states`,
    typeArguments: typeArgs,
    arguments: [tx5b.object(escrowId), random(tx5b), clock(tx5b)],
  });
  const r5b = await measure(client, kp.owner, 'apply_transitions', 0, tx5b);
  steps.push(r5b);

  // 6. claim
  process.stdout.write('Step 6 claim...');
  const tx6 = new Transaction();
  tx6.setSender(d.owner.address);
  const [asset, earnings] = tx6.moveCall({
    target: `${d.usufructPackageId}::escrow::claim_asset`,
    typeArguments: typeArgs,
    arguments: [tx6.object(escrowId), tx6.object(ownerCapId), random(tx6), clock(tx6)],
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
