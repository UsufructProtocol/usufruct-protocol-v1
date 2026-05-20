#!/usr/bin/env tsx
/**
 * Phase B / 01 — Minimal lifecycle
 * Flow: integrate → rent → retire → claim_asset
 * Measures cumulative gas per step. Runs once (not 10x — each step is sequential).
 */

import { resolve, dirname } from 'path';
import { fileURLToPath }  from 'url';
import { Transaction }    from '@mysten/sui/transactions';
import { writeFileSync }  from 'fs';
import {
  loadDeployment, loadKeypairs, makeClient,
} from '../env.ts';
import { measure } from '../measure.ts';
import { buildIntegrate, buildRent, clock, random } from '../builders.ts';

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

  // Step 1: integrate
  process.stdout.write('Step 1 integrate...');
  const tx1 = new Transaction();
  tx1.setSender(d.owner.address);
  const ownerCap = buildIntegrate(tx1, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId);
  tx1.transferObjects([ownerCap], d.owner.address);

  const r1 = await measure(client, kp.owner, 'integrate', 0, tx1);
  steps.push(r1);
  console.log(` net=${r1.net} MIST  +${r1.objectsCreated}obj`);

  const changes1 = (await client.getTransactionBlock({
    digest: r1.digest, options: { showObjectChanges: true },
  })).objectChanges ?? [];
  const escrowId  = (changes1.find(c => c.type === 'created' && (c as any).objectType?.includes('Escrow')) as any).objectId;
  const ownerCapId = (changes1.find(c => c.type === 'created' && (c as any).objectType?.includes('OwnerCap')) as any).objectId;

  // Step 2: rent
  process.stdout.write('Step 2 rent...');
  const tx2 = new Transaction();
  tx2.setSender(d.tenant1.address);
  const tenantCap = buildRent(tx2, d.usufructPackageId, d.dummyAssetPackageId, escrowId);
  tx2.transferObjects([tenantCap], d.tenant1.address);

  const r2 = await measure(client, kp.tenant1, 'rent', 0, tx2);
  steps.push(r2);
  console.log(` net=${r2.net} MIST`);

  // Step 3: retire
  process.stdout.write('Step 3 retire...');
  const tx3 = new Transaction();
  tx3.setSender(d.owner.address);
  tx3.moveCall({
    target: `${d.usufructPackageId}::escrow::retire`,
    typeArguments: typeArgs,
    arguments: [tx3.object(escrowId), tx3.object(ownerCapId), random(tx3), clock(tx3)],
  });

  const r3 = await measure(client, kp.owner, 'retire', 0, tx3);
  steps.push(r3);
  console.log(` net=${r3.net} MIST`);

  // Step 3b: apply pending (finalize retire)
  process.stdout.write('Step 3b apply_transitions...');
  const tx3b = new Transaction();
  tx3b.setSender(d.owner.address);
  tx3b.moveCall({
    target: `${d.usufructPackageId}::escrow::apply_pending_transition_states`,
    typeArguments: typeArgs,
    arguments: [tx3b.object(escrowId), random(tx3b), clock(tx3b)],
  });
  const r3b = await measure(client, kp.owner, 'apply_transitions', 0, tx3b);
  steps.push(r3b);
  console.log(` net=${r3b.net} MIST`);

  // Step 4: claim_asset
  process.stdout.write('Step 4 claim_asset...');
  const tx4 = new Transaction();
  tx4.setSender(d.owner.address);
  const [asset, earnings] = tx4.moveCall({
    target: `${d.usufructPackageId}::escrow::claim_asset`,
    typeArguments: typeArgs,
    arguments: [tx4.object(escrowId), tx4.object(ownerCapId), random(tx4), clock(tx4)],
  }) as any[];
  tx4.transferObjects([asset, earnings], d.owner.address);

  const r4 = await measure(client, kp.owner, 'claim_asset', 0, tx4);
  steps.push(r4);
  console.log(` net=${r4.net} MIST  -${r4.objectsDeleted}obj`);

  const totalNet = steps.reduce((acc, s) => acc + s.net, 0n);
  console.log(`\nTotal net cost: ${totalNet} MIST`);

  const out = steps.map(s => ({
    ...s,
    computation: s.computation.toString(),
    storage:     s.storage.toString(),
    rebate:      s.rebate.toString(),
    nonRefundable: s.nonRefundable.toString(),
    net:         s.net.toString(),
  }));
  writeFileSync(resolve(DIR, '../results/b_01_minimal.json'), JSON.stringify(out, null, 2));
}

main().catch(e => { console.error(e); process.exit(1); });
