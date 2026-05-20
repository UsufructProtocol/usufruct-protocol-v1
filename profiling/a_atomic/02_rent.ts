#!/usr/bin/env tsx
/**
 * Phase A / 02 — rent
 * Measures: escrow::rent (idle → occupied, returns TenantCap)
 * Precondition: escrow in Idle state (created by integrate, not measured)
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
import { buildIntegrate, buildRent } from '../builders.ts';

const DIR = dirname(fileURLToPath(import.meta.url));

async function setupIdleEscrow(
  client: SuiClient,
  owner: Ed25519Keypair,
  d: ReturnType<typeof loadDeployment>,
): Promise<{ escrowId: string; ownerCapId: string }> {
  const tx = new Transaction();
  tx.setSender(d.owner.address);

  const ownerCap = buildIntegrate(tx, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId);
  tx.transferObjects([ownerCap], d.owner.address);

  const result = await client.signAndExecuteTransaction({
    transaction: tx, signer: owner,
    options: { showObjectChanges: true },
  });

  const changes = result.objectChanges ?? [];
  const escrow  = changes.find(c => c.type === 'created' && (c as any).objectType?.includes('Escrow'));
  const cap     = changes.find(c => c.type === 'created' && (c as any).objectType?.includes('OwnerCap'));

  if (!escrow || !cap) throw new Error('setup: Escrow or OwnerCap not found in tx output');
  return { escrowId: (escrow as any).objectId, ownerCapId: (cap as any).objectId };
}

async function main() {
  const d      = loadDeployment();
  const client = makeClient();
  const kp     = loadKeypairs(d);

  const records = [];
  for (let run = 0; run < RUNS; run++) {
    process.stdout.write(`  run ${run + 1}/${RUNS} setup...`);
    const { escrowId } = await setupIdleEscrow(client, kp.owner, d);

    process.stdout.write(' measuring...');
    const tx = new Transaction();
    tx.setSender(d.tenant1.address);

    const tenantCap = buildRent(tx, d.usufructPackageId, d.dummyAssetPackageId, escrowId);
    tx.transferObjects([tenantCap], d.tenant1.address);

    const rec = await measure(client, kp.tenant1, 'rent', run, tx);
    records.push(rec);
    console.log(` net=${rec.net} MIST`);
  }

  const med = median(records);
  console.log(`\nMedian net: ${med.net} MIST`);
  saveRecords(resolve(DIR, '../results/a_02_rent.json'), records);
}

main().catch(e => { console.error(e); process.exit(1); });
