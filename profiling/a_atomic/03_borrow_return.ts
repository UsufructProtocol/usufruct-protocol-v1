#!/usr/bin/env tsx
/**
 * Phase A / 03 — borrow_asset + return_asset
 * Measures: escrow::borrow_asset + escrow::return_asset in a single PTB.
 *
 * Previously unmeasurable: borrow_asset took &Random, which blocked any
 * subsequent MoveCall (including return_asset) in the same PTB. With Random
 * removed from all public signatures, borrow + return compose freely.
 *
 * Precondition: escrow in Occupied state (integrate + rent, not measured).
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
import { buildIntegrate, buildRent, clock } from '../builders.ts';

const DIR = dirname(fileURLToPath(import.meta.url));

const typeArgs = (d: ReturnType<typeof loadDeployment>) => [
  `${d.dummyAssetPackageId}::dummy_asset::DummyAsset`,
  '0x2::sui::SUI',
];

async function setupOccupiedEscrow(
  client: SuiClient,
  owner:   Ed25519Keypair,
  tenant1: Ed25519Keypair,
  d: ReturnType<typeof loadDeployment>,
): Promise<{ escrowId: string; tenantCapId: string }> {
  // Step 1: integrate
  const tx1 = new Transaction();
  tx1.setSender(d.owner.address);
  const ownerCap = buildIntegrate(tx1, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId);
  tx1.transferObjects([ownerCap], d.owner.address);
  const r1 = await execSetup(client, owner, tx1);

  const escrow = r1.objectChanges?.find(c => c.type === 'created' && (c as any).objectType?.includes('Escrow'));
  if (!escrow) throw new Error('setup: Escrow not found');
  const escrowId = (escrow as any).objectId;

  // Step 2: rent
  const tx2 = new Transaction();
  tx2.setSender(d.tenant1.address);
  const tenantCap = buildRent(tx2, d.usufructPackageId, d.dummyAssetPackageId, escrowId);
  tx2.transferObjects([tenantCap], d.tenant1.address);
  const r2 = await execSetup(client, tenant1, tx2);

  const cap = r2.objectChanges?.find(c => c.type === 'created' && (c as any).objectType?.includes('TenantCap'));
  if (!cap) throw new Error('setup: TenantCap not found');
  return { escrowId, tenantCapId: (cap as any).objectId };
}

async function main() {
  const d      = loadDeployment();
  const client = makeClient();
  const kp     = loadKeypairs(d);
  const ta     = typeArgs(d);

  const records = [];
  for (let run = 0; run < RUNS; run++) {
    if (run > 0) await new Promise(r => setTimeout(r, 1000));
    process.stdout.write(`  run ${run + 1}/${RUNS} setup...`);
    const { escrowId, tenantCapId } = await setupOccupiedEscrow(client, kp.owner, kp.tenant1, d);

    process.stdout.write(' measuring...');
    const tx = new Transaction();
    tx.setSender(d.tenant1.address);

    // borrow_asset → return_asset in a single PTB (now possible without Random)
    const [asset, receipt] = tx.moveCall({
      target: `${d.usufructPackageId}::escrow::borrow_asset`,
      typeArguments: ta,
      arguments: [tx.object(escrowId), tx.object(tenantCapId), clock(tx)],
    }) as any[];

    tx.moveCall({
      target: `${d.usufructPackageId}::escrow::return_asset`,
      typeArguments: ta,
      arguments: [tx.object(escrowId), asset, receipt],
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
