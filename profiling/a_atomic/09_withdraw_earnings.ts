#!/usr/bin/env tsx
/**
 * Phase A / 09 — withdraw_earnings
 * Measures: owner withdraws accumulated rent earnings.
 * Precondition: escrow occupied (tenant has paid floor price).
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
import { buildIntegrate, buildRent, clock, random } from '../builders.ts';

const DIR = dirname(fileURLToPath(import.meta.url));

async function setupOccupied(
  client: SuiClient,
  owner: Ed25519Keypair,
  tenant1: Ed25519Keypair,
  d: ReturnType<typeof loadDeployment>,
): Promise<{ escrowId: string; ownerCapId: string }> {
  const tx1 = new Transaction();
  tx1.setSender(d.owner.address);
  const ownerCap = buildIntegrate(tx1, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId);
  tx1.transferObjects([ownerCap], d.owner.address);

  const r1 = await client.signAndExecuteTransaction({
    transaction: tx1, signer: owner, options: { showObjectChanges: true },
  });
  const escrowObj = (r1.objectChanges ?? []).find(
    c => c.type === 'created' && (c as any).objectType?.includes('Escrow'),
  ) as any;
  const capObj = (r1.objectChanges ?? []).find(
    c => c.type === 'created' && (c as any).objectType?.includes('OwnerCap'),
  ) as any;

  const tx2 = new Transaction();
  tx2.setSender(d.tenant1.address);
  const tenantCap = buildRent(tx2, d.usufructPackageId, d.dummyAssetPackageId, escrowObj.objectId);
  tx2.transferObjects([tenantCap], d.tenant1.address);
  await client.signAndExecuteTransaction({ transaction: tx2, signer: tenant1 });

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
    process.stdout.write(`  run ${run + 1}/${RUNS} setup...`);
    const { escrowId, ownerCapId } = await setupOccupied(client, kp.owner, kp.tenant1, d);

    process.stdout.write(' measuring...');
    const tx = new Transaction();
    tx.setSender(d.owner.address);

    const earnings = tx.moveCall({
      target: `${d.usufructPackageId}::escrow::withdraw_earnings`,
      typeArguments: typeArgs,
      arguments: [tx.object(escrowId), tx.object(ownerCapId), random(tx), clock(tx)],
    });
    tx.transferObjects([earnings], d.owner.address);

    const rec = await measure(client, kp.owner, 'withdraw_earnings', run, tx);
    records.push(rec);
    console.log(` net=${rec.net} MIST`);
  }

  const med = median(records);
  console.log(`\nMedian net: ${med.net} MIST`);
  saveRecords(resolve(DIR, '../results/a_09_withdraw_earnings.json'), records);
}

main().catch(e => { console.error(e); process.exit(1); });
