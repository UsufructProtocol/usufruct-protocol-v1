#!/usr/bin/env tsx
/**
 * Phase A / 04 — soft_burn_tenant_cap
 * Measures: occupied → demand transition (tenant requests handover).
 * Precondition: escrow occupied, ensemble uses HandoverPolicy::Fixed.
 */

import { resolve, dirname } from 'path';
import { fileURLToPath }  from 'url';
import { Transaction }    from '@mysten/sui/transactions';
import { SuiClient }      from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import {
  loadDeployment, loadKeypairs, makeClient, RUNS,
} from '../env.ts';
import { measure, saveRecords, median } from '../measure.ts';
import { buildIntegrate, buildRent, buildHandoverEnsemble, clock, random } from '../builders.ts';

const DIR = dirname(fileURLToPath(import.meta.url));

async function setupOccupiedWithHandover(
  client: SuiClient,
  owner: Ed25519Keypair,
  tenant1: Ed25519Keypair,
  d: ReturnType<typeof loadDeployment>,
): Promise<{ escrowId: string; tenantCapId: string }> {
  const tx1 = new Transaction();
  tx1.setSender(d.owner.address);
  // Use handover ensemble so soft_burn is allowed
  const ownerCap = buildIntegrate(
    tx1, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId,
    buildHandoverEnsemble,
  );
  tx1.transferObjects([ownerCap], d.owner.address);

  const r1 = await client.signAndExecuteTransaction({
    transaction: tx1, signer: owner, options: { showObjectChanges: true },
  });
  const escrowObj = (r1.objectChanges ?? []).find(
    c => c.type === 'created' && (c as any).objectType?.includes('Escrow'),
  ) as any;
  if (!escrowObj) throw new Error('setup: Escrow not found');

  const tx2 = new Transaction();
  tx2.setSender(d.tenant1.address);
  const tenantCap = buildRent(tx2, d.usufructPackageId, d.dummyAssetPackageId, escrowObj.objectId);
  tx2.transferObjects([tenantCap], d.tenant1.address);

  const r2 = await client.signAndExecuteTransaction({
    transaction: tx2, signer: tenant1, options: { showObjectChanges: true },
  });
  const capObj = (r2.objectChanges ?? []).find(
    c => c.type === 'created' && (c as any).objectType?.includes('TenantCap'),
  ) as any;
  if (!capObj) throw new Error('setup: TenantCap not found');

  return { escrowId: escrowObj.objectId, tenantCapId: capObj.objectId };
}

async function main() {
  const d      = loadDeployment();
  const client = makeClient();
  const kp     = loadKeypairs(d);

  const typeArgs = [
    `${d.dummyAssetPackageId}::dummy_asset::DummyAsset`,
    '0x2::sui::SUI',
  ];

  const records = [];
  for (let run = 0; run < RUNS; run++) {
    process.stdout.write(`  run ${run + 1}/${RUNS} setup...`);
    const { escrowId, tenantCapId } = await setupOccupiedWithHandover(
      client, kp.owner, kp.tenant1, d,
    );

    process.stdout.write(' measuring...');
    const tx = new Transaction();
    tx.setSender(d.tenant1.address);

    tx.moveCall({
      target: `${d.usufructPackageId}::escrow::soft_burn_tenant_cap`,
      typeArguments: typeArgs,
      arguments: [tx.object(escrowId), tx.object(tenantCapId), random(tx), clock(tx)],
    });

    const rec = await measure(client, kp.tenant1, 'soft_burn', run, tx);
    records.push(rec);
    console.log(` net=${rec.net} MIST  -${rec.objectsDeleted}obj`);
  }

  const med = median(records);
  console.log(`\nMedian net: ${med.net} MIST`);
  saveRecords(resolve(DIR, '../results/a_04_soft_burn.json'), records);
}

main().catch(e => { console.error(e); process.exit(1); });
