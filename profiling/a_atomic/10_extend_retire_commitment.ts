#!/usr/bin/env tsx
/**
 * Phase A / 10 — extend_retire_commitment
 * Measures: owner extends the retire-commitment period on an idle escrow.
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
import { buildIntegrate, clock } from '../builders.ts';
import { TENURE_DURATION_MS } from '../env.ts';

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

  const r = await execSetup(client, owner, tx);
  const escrowObj = (r.objectChanges ?? []).find(
    c => c.type === 'created' && (c as any).objectType?.includes('Escrow'),
  ) as any;
  const capObj = (r.objectChanges ?? []).find(
    c => c.type === 'created' && (c as any).objectType?.includes('OwnerCap'),
  ) as any;
  return { escrowId: escrowObj.objectId, ownerCapId: capObj.objectId };
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
    if (run > 0) await new Promise(r => setTimeout(r, 1000));
    process.stdout.write(`  run ${run + 1}/${RUNS} setup...`);
    const { escrowId, ownerCapId } = await setupIdleEscrow(client, kp.owner, d);

    process.stdout.write(' measuring...');
    const tx = new Transaction();
    tx.setSender(d.owner.address);

    const dur = tx.moveCall({
      target: `${d.usufructPackageId}::ensemble::duration`,
      arguments: [tx.pure.u64(TENURE_DURATION_MS)],
    });
    const newCommitment = tx.moveCall({
      target: `${d.usufructPackageId}::ensemble::new_retire_commitment_deferred`,
      arguments: [dur],
    });
    tx.moveCall({
      target: `${d.usufructPackageId}::escrow::extend_retire_commitment`,
      typeArguments: typeArgs,
      arguments: [tx.object(escrowId), tx.object(ownerCapId), newCommitment, clock(tx)],
    });

    const rec = await measure(client, kp.owner, 'extend_retire_commitment', run, tx);
    records.push(rec);
    console.log(` net=${rec.net} MIST`);
  }

  const med = median(records);
  console.log(`\nMedian net: ${med.net} MIST`);
  saveRecords(resolve(DIR, '../results/a_10_extend_retire_commitment.json'), records);
}

main().catch(e => { console.error(e); process.exit(1); });
