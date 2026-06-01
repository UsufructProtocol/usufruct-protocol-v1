#!/usr/bin/env tsx
/**
 * Phase A / 05 — hard_burn_usufruct_cap
 * Measures: directly destroying a UsufructCap without handover protocol.
 * Precondition: occupied escrow with a valid UsufructCap.
 * Note: the escrow stays occupied but the cap is gone (stale usufructuary).
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

async function setupOccupied(
  client: SuiClient,
  governor: Ed25519Keypair,
  usufructuary1: Ed25519Keypair,
  d: ReturnType<typeof loadDeployment>,
): Promise<{ usufructCapId: string }> {
  const tx1 = new Transaction();
  tx1.setSender(d.governor.address);
  const { governanceCap, inbox } = buildIntegrate(tx1, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId);
  tx1.transferObjects([governanceCap, inbox], d.governor.address);

  const r1 = await execSetup(client, governor, tx1);
  const escrowObj = (r1.objectChanges ?? []).find(
    c => c.type === 'created' && (c as any).objectType?.includes('Escrow'),
  ) as any;

  const tx2 = new Transaction();
  tx2.setSender(d.usufructuary1.address);
  const usufructCap = buildRent(tx2, d.usufructPackageId, d.dummyAssetPackageId, escrowObj.objectId);
  tx2.transferObjects([usufructCap], d.usufructuary1.address);

  const r2 = await execSetup(client, usufructuary1, tx2);
  const capObj = (r2.objectChanges ?? []).find(
    c => c.type === 'created' && (c as any).objectType?.includes('UsufructCap'),
  ) as any;
  if (!capObj) throw new Error('setup: UsufructCap not found');

  return { usufructCapId: capObj.objectId };
}

async function main() {
  const d      = loadDeployment();
  const client = makeClient();
  const kp     = loadKeypairs(d);

  const records = [];
  for (let run = 0; run < RUNS; run++) {
    if (run > 0) await new Promise(r => setTimeout(r, 1000));
    process.stdout.write(`  run ${run + 1}/${RUNS} setup...`);
    const { usufructCapId } = await setupOccupied(client, kp.governor, kp.usufructuary1, d);

    process.stdout.write(' measuring...');
    const tx = new Transaction();
    tx.setSender(d.usufructuary1.address);

    tx.moveCall({
      target: `${d.usufructPackageId}::escrow::hard_burn_usufruct_cap`,
      arguments: [tx.object(usufructCapId)],
    });

    const rec = await measure(client, kp.usufructuary1, 'hard_burn', run, tx);
    records.push(rec);
    console.log(` net=${rec.net} MIST  -${rec.objectsDeleted}obj`);
  }

  const med = median(records);
  console.log(`\nMedian net: ${med.net} MIST`);
  saveRecords(resolve(DIR, '../results/a_05_hard_burn.json'), records);
}

main().catch(e => { console.error(e); process.exit(1); });
