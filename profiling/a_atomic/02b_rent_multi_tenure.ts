#!/usr/bin/env tsx
/**
 * Phase A / 02b — rent(tenures(N))
 * Measures: escrow::rent with N tenures locked in a single call.
 *
 * Hypothesis: cost is O(1) in N — tenures(N) only stores a multiplied
 * duration in TenancySchedule; computation and object count are identical
 * to rent(tenures(1)).
 *
 * Compare with b_flows/04_sequential_rents.ts which measures N separate
 * rent(1) cycles and costs O(N).
 *
 * Usage: tsx a_atomic/02b_rent_multi_tenure.ts [N]   (default N=10)
 */

import { resolve, dirname } from 'path';
import { fileURLToPath }  from 'url';
import { Transaction }    from '@mysten/sui/transactions';
import { SuiClient }      from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import {
  loadDeployment, loadKeypairs, makeClient, RUNS, FLOOR_PRICE_MIST,
} from '../env.ts';
import { measure, saveRecords, median, execSetup } from '../measure.ts';
import { buildIntegrate, clock } from '../builders.ts';

const DIR  = dirname(fileURLToPath(import.meta.url));
const N    = parseInt(process.argv[2] ?? '10', 10);

async function setupIdleEscrow(
  client: SuiClient,
  owner:  Ed25519Keypair,
  d: ReturnType<typeof loadDeployment>,
): Promise<string> {
  const tx = new Transaction();
  tx.setSender(d.owner.address);
  const ownerCap = buildIntegrate(tx, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId);
  tx.transferObjects([ownerCap], d.owner.address);
  const result = await execSetup(client, owner, tx);
  const escrow = result.objectChanges?.find(c => c.type === 'created' && (c as any).objectType?.includes('Escrow'));
  if (!escrow) throw new Error('setup: Escrow not found');
  return (escrow as any).objectId;
}

async function main() {
  const d      = loadDeployment();
  const client = makeClient();
  const kp     = loadKeypairs(d);
  const ta     = [`${d.dummyAssetPackageId}::dummy_asset::DummyAsset`, '0x2::sui::SUI'];

  console.log(`rent(tenures(N)) — N=${N} (single call)`);

  const records = [];
  for (let run = 0; run < RUNS; run++) {
    if (run > 0) await new Promise(r => setTimeout(r, 1000));
    process.stdout.write(`  run ${run + 1}/${RUNS} setup...`);
    const escrowId = await setupIdleEscrow(client, kp.owner, d);

    process.stdout.write(' measuring...');
    const tx = new Transaction();
    tx.setSender(d.tenant1.address);

    const [payment] = tx.splitCoins(tx.gas, [tx.pure.u64(FLOOR_PRICE_MIST * BigInt(N))]);
    const cycles = tx.moveCall({
      target: `${d.usufructPackageId}::ensemble::tenures`,
      arguments: [tx.pure.u64(N)],
    });
    const tenantCap = tx.moveCall({
      target: `${d.usufructPackageId}::escrow::rent`,
      typeArguments: ta,
      arguments: [tx.object(escrowId), payment, cycles, clock(tx)],
    });
    tx.transferObjects([tenantCap], d.tenant1.address);

    const rec = await measure(client, kp.tenant1, `rent_N${N}`, run, tx);
    records.push(rec);
    console.log(` net=${rec.net} MIST`);
  }

  const med = median(records);
  console.log(`\nN=${N}  median net: ${med.net} MIST`);
  console.log(`Compare: rent(1) baseline ≈ 3,939,920 MIST`);

  saveRecords(resolve(DIR, `../results/a_02b_rent_N${N}.json`), records);
}

main().catch(e => { console.error(e); process.exit(1); });
