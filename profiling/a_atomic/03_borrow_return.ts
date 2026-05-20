#!/usr/bin/env tsx
/**
 * Phase A / 03 — borrow_asset + return_asset (round trip)
 * Measures both in a single PTB because AssetReceipt is a hot potato.
 * Precondition: escrow in Occupied state (tenant has rented)
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
): Promise<{ escrowId: string; tenantCapId: string }> {
  // Step 1: integrate
  const tx1 = new Transaction();
  tx1.setSender(d.owner.address);
  const ownerCap = buildIntegrate(tx1, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId);
  tx1.transferObjects([ownerCap], d.owner.address);

  const r1 = await execSetup(client, owner, tx1);
  const escrowId = (r1.objectChanges ?? []).find(
    c => c.type === 'created' && (c as any).objectType?.includes('Escrow'),
  ) as any;
  if (!escrowId) throw new Error('setup: Escrow not found');

  // Step 2: rent
  const tx2 = new Transaction();
  tx2.setSender(d.tenant1.address);
  const tenantCap = buildRent(tx2, d.usufructPackageId, d.dummyAssetPackageId, escrowId.objectId);
  tx2.transferObjects([tenantCap], d.tenant1.address);

  const r2 = await execSetup(client, tenant1, tx2);
  const capObj = (r2.objectChanges ?? []).find(
    c => c.type === 'created' && (c as any).objectType?.includes('TenantCap'),
  ) as any;
  if (!capObj) throw new Error('setup: TenantCap not found');

  return { escrowId: escrowId.objectId, tenantCapId: capObj.objectId };
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
    const { escrowId, tenantCapId } = await setupOccupied(client, kp.owner, kp.tenant1, d);

    process.stdout.write(' measuring...');
    const tx = new Transaction();
    tx.setSender(d.tenant1.address);

    // borrow_and_return is a single Move call that wraps both operations.
    // Needed because Sui forbids MoveCall commands after any command that uses
    // the Random object — making borrow_asset + return_asset impossible in one PTB.
    // Uses profiling_helpers (in usufruct package, profiling branch only)
    // to wrap borrow+return in a single Move call — required because Sui
    // forbids MoveCall commands after any command that uses Random.
    tx.moveCall({
      target: `${d.usufructPackageId}::profiling_helpers::borrow_and_return`,
      typeArguments: [
        `${d.dummyAssetPackageId}::dummy_asset::DummyAsset`,
        '0x2::sui::SUI',
      ],
      arguments: [tx.object(escrowId), tx.object(tenantCapId), random(tx), clock(tx)],
    });

    const rec = await measure(client, kp.tenant1, 'borrow_return', run, tx);
    records.push(rec);
    console.log(` net=${rec.net} MIST`);
  }

  const med = median(records);
  console.log(`\nMedian net: ${med.net} MIST`);
  saveRecords(resolve(DIR, '../results/a_03_borrow_return.json'), records);
}

main().catch(e => { console.error(e); process.exit(1); });
