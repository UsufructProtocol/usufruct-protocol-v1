#!/usr/bin/env tsx
/**
 * Phase A / 02 — rent
 * Measures: escrow::rent (idle → occupied, returns UsufructCap)
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
import { measure, saveRecords, median, execSetup } from '../measure.ts';
import { buildIntegrate, buildRent } from '../builders.ts';

const DIR = dirname(fileURLToPath(import.meta.url));

async function setupIdleEscrow(
  client: SuiClient,
  governor: Ed25519Keypair,
  d: ReturnType<typeof loadDeployment>,
): Promise<{ escrowId: string; governanceCapId: string }> {
  const tx = new Transaction();
  tx.setSender(d.governor.address);

  const { governanceCap, inbox } = buildIntegrate(tx, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId);
  tx.transferObjects([governanceCap, inbox], d.governor.address);

  const result = await execSetup(client, governor, tx);

  const changes = result.objectChanges ?? [];
  const escrow  = changes.find(c => c.type === 'created' && (c as any).objectType?.includes('Escrow'));
  const cap     = changes.find(c => c.type === 'created' && (c as any).objectType?.includes('GovernanceCap'));

  if (!escrow || !cap) throw new Error('setup: Escrow or GovernanceCap not found in tx output');
  return { escrowId: (escrow as any).objectId, governanceCapId: (cap as any).objectId };
}

async function main() {
  const d      = loadDeployment();
  const client = makeClient();
  const kp     = loadKeypairs(d);

  const records = [];
  for (let run = 0; run < RUNS; run++) {
    if (run > 0) await new Promise(r => setTimeout(r, 1000));
    process.stdout.write(`  run ${run + 1}/${RUNS} setup...`);
    const { escrowId } = await setupIdleEscrow(client, kp.governor, d);

    process.stdout.write(' measuring...');
    const tx = new Transaction();
    tx.setSender(d.usufructuary1.address);

    const usufructCap = buildRent(tx, d.usufructPackageId, d.dummyAssetPackageId, escrowId);
    tx.transferObjects([usufructCap], d.usufructuary1.address);

    const rec = await measure(client, kp.usufructuary1, 'rent', run, tx);
    records.push(rec);
    console.log(` net=${rec.net} MIST`);
  }

  const med = median(records);
  console.log(`\nMedian net: ${med.net} MIST`);
  saveRecords(resolve(DIR, '../results/a_02_rent.json'), records);
}

main().catch(e => { console.error(e); process.exit(1); });
