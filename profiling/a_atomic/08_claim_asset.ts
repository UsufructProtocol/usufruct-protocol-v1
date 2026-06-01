#!/usr/bin/env tsx
/**
 * Phase A / 08 — claim_asset
 * Measures: escrow::claim_asset (destroys escrow, returns the Asset only — governor
 *           income was settled to the inbox throughout, never accumulated here).
 *           Cap is passed by reference and SURVIVES (it may govern other escrows),
 *           so claim deletes only the Escrow now (−1 obj, was −2 with cap burn).
 * Precondition: escrow in Retired state (idle → retire → apply transitions).
 *
 * Note: claim requires the escrow to have fully transitioned to Retired.
 * After retire() on an idle escrow with CommitmentPolicy::Immediate, the
 * apply_pending call should finalize the state in the same or next block.
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

const DIR = dirname(fileURLToPath(import.meta.url));

async function setupRetiredEscrow(
  client: SuiClient,
  governor: Ed25519Keypair,
  d: ReturnType<typeof loadDeployment>,
): Promise<{ escrowId: string; governanceCapId: string }> {
  const typeArgs = [
    `${d.dummyAssetPackageId}::dummy_asset::DummyAsset`,
    '0x2::sui::SUI',
  ];

  // integrate
  const tx1 = new Transaction();
  tx1.setSender(d.governor.address);
  const { governanceCap, inbox } = buildIntegrate(tx1, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId);
  tx1.transferObjects([governanceCap, inbox], d.governor.address);

  const r1 = await execSetup(client, governor, tx1);
  const escrowObj = (r1.objectChanges ?? []).find(
    c => c.type === 'created' && (c as any).objectType?.includes('Escrow'),
  ) as any;
  const capObj = (r1.objectChanges ?? []).find(
    c => c.type === 'created' && (c as any).objectType?.includes('GovernanceCap'),
  ) as any;

  // retire
  const tx2 = new Transaction();
  tx2.setSender(d.governor.address);
  tx2.moveCall({
    target: `${d.usufructPackageId}::escrow::retire`,
    typeArguments: typeArgs,
    arguments: [tx2.object(escrowObj.objectId), tx2.object(capObj.objectId), clock(tx2)],
  });
  await execSetup(client, governor, tx2);

  return { escrowId: escrowObj.objectId, governanceCapId: capObj.objectId };
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
    const { escrowId, governanceCapId } = await setupRetiredEscrow(client, kp.governor, d);

    process.stdout.write(' measuring...');
    const tx = new Transaction();
    tx.setSender(d.governor.address);

    const asset = tx.moveCall({
      target: `${d.usufructPackageId}::escrow::claim_asset`,
      typeArguments: typeArgs,
      arguments: [tx.object(escrowId), tx.object(governanceCapId), clock(tx)],
    });

    tx.transferObjects([asset], d.governor.address);

    const rec = await measure(client, kp.governor, 'claim_asset', run, tx);
    records.push(rec);
    console.log(` net=${rec.net} MIST  -${rec.objectsDeleted}obj`);
  }

  const med = median(records);
  console.log(`\nMedian net: ${med.net} MIST`);
  saveRecords(resolve(DIR, '../results/a_08_claim_asset.json'), records);
}

main().catch(e => { console.error(e); process.exit(1); });
