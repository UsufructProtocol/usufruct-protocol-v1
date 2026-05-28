#!/usr/bin/env tsx
/**
 * Phase A / 14 — update_tenant_refund_address
 * Measures: tenant redirects the refund destination on the active seat.
 *
 * Precondition: escrow Occupied with tenant1 holding the TenantCap.
 *   1. Integrate (minimal ensemble, 60s tenure)
 *   2. tenant1 rents → Occupied
 *   Now the cap holder can call update_tenant_refund_address with a
 *   RefundAddress constructed via the public api wrapper refund::refund_address.
 *
 * What the measured tx does:
 *   - refund::refund_address(new_addr) → RefundAddress
 *   - escrow::update_tenant_refund_address(escrow, &cap, refund, clock)
 *
 * Authority is the cap reference; the call's sender (tenant1) is not
 * consulted by the dispatch. The measurement therefore reflects the
 * Occupied → terms.active branch with no escrow-state churn (no objects
 * created or deleted, just a storage rewrite of the seat's address field).
 */

import { resolve, dirname } from 'path';
import { fileURLToPath }    from 'url';
import { Transaction }      from '@mysten/sui/transactions';
import { SuiClient }        from '@mysten/sui/client';
import { Ed25519Keypair }   from '@mysten/sui/keypairs/ed25519';
import {
  loadDeployment, loadKeypairs, makeClient, RUNS, FLOOR_PRICE_MIST,
} from '../env.ts';
import { measure, saveRecords, median, execSetup } from '../measure.ts';
import { buildIntegrate, buildRent, clock } from '../builders.ts';

const DIR = dirname(fileURLToPath(import.meta.url));

// Arbitrary synthetic destination. The protocol routes refunds here on
// future handover/supersede; this script only measures the redirect call.
const NEW_REFUND_ADDR = '0x00000000000000000000000000000000000000000000000000000000cafe0001';

async function setupOccupied(
  client:  SuiClient,
  owner:   Ed25519Keypair,
  tenant1: Ed25519Keypair,
  d:       ReturnType<typeof loadDeployment>,
): Promise<{ escrowId: string; tenantCapId: string }> {
  // 1. integrate (minimal ensemble, default 60s tenure)
  const tx1 = new Transaction();
  tx1.setSender(d.owner.address);
  const ownerCap = buildIntegrate(tx1, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId);
  tx1.transferObjects([ownerCap], d.owner.address);

  const r1 = await execSetup(client, owner, tx1);
  const escrowObj = (r1.objectChanges ?? []).find(
    c => c.type === 'created' && (c as any).objectType?.includes('Escrow'),
  ) as any;

  // 2. tenant1 rents → Occupied, cap held by tenant1
  const tx2 = new Transaction();
  tx2.setSender(d.tenant1.address);
  const tenantCap = buildRent(tx2, d.usufructPackageId, d.dummyAssetPackageId, escrowObj.objectId);
  tx2.transferObjects([tenantCap], d.tenant1.address);
  const r2 = await execSetup(client, tenant1, tx2);
  const capObj = (r2.objectChanges ?? []).find(
    c => c.type === 'created' && (c as any).objectType?.includes('TenantCap'),
  ) as any;

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
    if (run > 0) await new Promise(r => setTimeout(r, 1000));
    process.stdout.write(`  run ${run + 1}/${RUNS} setup...`);
    const { escrowId, tenantCapId } = await setupOccupied(client, kp.owner, kp.tenant1, d);

    process.stdout.write(' measuring...');
    const tx = new Transaction();
    tx.setSender(d.tenant1.address);

    const refund = tx.moveCall({
      target:    `${d.usufructPackageId}::refund::refund_address`,
      arguments: [tx.pure.address(NEW_REFUND_ADDR)],
    });
    tx.moveCall({
      target:        `${d.usufructPackageId}::escrow::update_tenant_refund_address`,
      typeArguments: typeArgs,
      arguments:     [tx.object(escrowId), tx.object(tenantCapId), refund, clock(tx)],
    });

    const rec = await measure(client, kp.tenant1, 'update_tenant_refund_address', run, tx);
    records.push(rec);
    console.log(` net=${rec.net} MIST`);
  }

  const med = median(records);
  console.log(`\nMedian net: ${med.net} MIST`);
  saveRecords(resolve(DIR, '../results/a_14_update_tenant_refund_address.json'), records);
}

main().catch(e => { console.error(e); process.exit(1); });
