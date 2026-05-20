#!/usr/bin/env tsx
/**
 * Phase A / 09 — withdraw_earnings
 * Measures: owner withdraws earnings after a completed tenure.
 *
 * Precondition: escrow in Idle state after one completed tenure.
 *   1. Integrate (tenure = 2s)
 *   2. Tenant1 rents → Occupied
 *   3. Wait 3s for tenure to expire
 *   4. apply_pending_transition_states → settles stake to owner earnings, returns to Idle
 *   Now the escrow has withdrawable earnings.
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
import { buildIntegrate, clock, random } from '../builders.ts';
import type { TransactionArgument } from '@mysten/sui/transactions';

const DIR = dirname(fileURLToPath(import.meta.url));

const SHORT_TENURE_MS = 2_000n;

function buildShortMinimalEnsemble(tx: Transaction, pkg: string): TransactionArgument {
  const price = (mist: bigint) =>
    tx.moveCall({ target: `${pkg}::monetary::price`, arguments: [tx.pure.u64(mist)] });
  const dur = (ms: bigint) =>
    tx.moveCall({ target: `${pkg}::phases::duration`, arguments: [tx.pure.u64(ms)] });

  const restPrice      = tx.moveCall({ target: `${pkg}::rest_price_policy::new_fixed`,          arguments: [price(1_000_000n)] });
  const tenureDuration = tx.moveCall({ target: `${pkg}::tenure_duration_policy::new_fixed`,     arguments: [dur(SHORT_TENURE_MS)] });
  const tenureExtend   = tx.moveCall({ target: `${pkg}::tenure_extend_policy::new_multi` });
  const handover       = tx.moveCall({ target: `${pkg}::handover_policy::new_handover_off` });
  const auctionWin     = tx.moveCall({ target: `${pkg}::auction_window_policy::new_descent_off` });
  const creditShape    = tx.moveCall({ target: `${pkg}::curve_shape_policy::new_linear` });
  const auctionShape   = tx.moveCall({ target: `${pkg}::curve_shape_policy::new_linear` });
  const escalation     = tx.moveCall({ target: `${pkg}::price_escalation_policy::new_fixed_delta`, arguments: [price(1n)] });
  return tx.moveCall({
    target: `${pkg}::policy_ensemble::new_ensemble`,
    arguments: [restPrice, tenureDuration, tenureExtend, handover, auctionWin, creditShape, auctionShape, escalation],
  });
}

async function setupWithEarnings(
  client: SuiClient,
  owner: Ed25519Keypair,
  tenant1: Ed25519Keypair,
  d: ReturnType<typeof loadDeployment>,
): Promise<{ escrowId: string; ownerCapId: string }> {
  const typeArgs = [
    `${d.dummyAssetPackageId}::dummy_asset::DummyAsset`,
    '0x2::sui::SUI',
  ];

  // 1. integrate with 2s tenure
  const tx1 = new Transaction();
  tx1.setSender(d.owner.address);
  const ownerCap = buildIntegrate(tx1, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId, buildShortMinimalEnsemble);
  tx1.transferObjects([ownerCap], d.owner.address);

  const r1 = await execSetup(client, owner, tx1);
  const escrowObj = (r1.objectChanges ?? []).find(
    c => c.type === 'created' && (c as any).objectType?.includes('Escrow'),
  ) as any;
  const capObj = (r1.objectChanges ?? []).find(
    c => c.type === 'created' && (c as any).objectType?.includes('OwnerCap'),
  ) as any;

  // 2. tenant1 rents
  const tx2 = new Transaction();
  tx2.setSender(d.tenant1.address);
  const [payment] = tx2.splitCoins(tx2.gas, [tx2.pure.u64(1_000_000n)]);
  const cycles    = tx2.moveCall({ target: `${d.usufructPackageId}::tenures::tenures`, arguments: [tx2.pure.u64(1n)] });
  const tenantCap = tx2.moveCall({
    target: `${d.usufructPackageId}::escrow::rent`,
    typeArguments: typeArgs,
    arguments: [tx2.object(escrowObj.objectId), payment, cycles, random(tx2), clock(tx2)],
  });
  tx2.transferObjects([tenantCap], d.tenant1.address);
  await execSetup(client, tenant1, tx2);

  // 3. wait for the 2s tenure to expire
  await new Promise(r => setTimeout(r, 3000));

  // 4. apply_pending — settles the tenure, releases earnings to owner
  const tx3 = new Transaction();
  tx3.setSender(d.owner.address);
  tx3.moveCall({
    target: `${d.usufructPackageId}::escrow::apply_pending_transition_states`,
    typeArguments: typeArgs,
    arguments: [tx3.object(escrowObj.objectId), random(tx3), clock(tx3)],
  });
  await execSetup(client, owner, tx3);

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
    const { escrowId, ownerCapId } = await setupWithEarnings(client, kp.owner, kp.tenant1, d);

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
