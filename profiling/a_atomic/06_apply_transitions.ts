#!/usr/bin/env tsx
/**
 * Phase A / 06 — apply_pending_transition_states
 * Measures: cost of calling apply_pending when nothing is pending (baseline).
 * For the non-trivial case (with pending transitions), see b_flows/03_handover.ts.
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
import { buildIntegrate, buildRent, clock, random } from '../builders.ts';

const DIR = dirname(fileURLToPath(import.meta.url));

async function setupOccupied(
  client: SuiClient,
  owner: Ed25519Keypair,
  tenant1: Ed25519Keypair,
  d: ReturnType<typeof loadDeployment>,
): Promise<{ escrowId: string }> {
  const tx1 = new Transaction();
  tx1.setSender(d.owner.address);
  const ownerCap = buildIntegrate(tx1, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId);
  tx1.transferObjects([ownerCap], d.owner.address);

  const r1 = await execSetup(client, owner, tx1);
  const escrowObj = (r1.objectChanges ?? []).find(
    c => c.type === 'created' && (c as any).objectType?.includes('Escrow'),
  ) as any;

  const tx2 = new Transaction();
  tx2.setSender(d.tenant1.address);
  const tenantCap = buildRent(tx2, d.usufructPackageId, d.dummyAssetPackageId, escrowObj.objectId);
  tx2.transferObjects([tenantCap], d.tenant1.address);

  await execSetup(client, tenant1, tx2);
  return { escrowId: escrowObj.objectId };
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
    if (run > 0) await new Promise(r => setTimeout(r, 1000)); // let fullnode stabilize
    process.stdout.write(`  run ${run + 1}/${RUNS} setup...`);
    const { escrowId } = await setupOccupied(client, kp.owner, kp.tenant1, d);

    process.stdout.write(' measuring...');
    const tx = new Transaction();
    tx.setSender(d.owner.address);

    tx.moveCall({
      target: `${d.usufructPackageId}::escrow::apply_pending_transition_states`,
      typeArguments: typeArgs,
      arguments: [tx.object(escrowId), random(tx), clock(tx)],
    });

    const rec = await measure(client, kp.owner, 'apply_transitions_noop', run, tx);
    records.push(rec);
    console.log(` net=${rec.net} MIST`);
  }

  const med = median(records);
  console.log(`\nMedian net (no-op baseline): ${med.net} MIST`);
  saveRecords(resolve(DIR, '../results/a_06_apply_transitions.json'), records);
}

main().catch(e => { console.error(e); process.exit(1); });
