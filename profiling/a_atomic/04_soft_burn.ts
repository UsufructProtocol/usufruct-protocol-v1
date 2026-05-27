#!/usr/bin/env tsx
/**
 * Phase A / 04 — soft_burn_tenant_cap
 * Measures: burning a STALE TenantCap (previous tenant's cap after new tenant bid).
 *
 * Correct precondition:
 *   1. Escrow created with HandoverPolicy::FullTenure (bidding open from start)
 *   2. Tenant1 rents → Occupied, cap_t1 = current
 *   3. Tenant2 bids (rent) → Demand, cap_t1 becomes STALE, cap_t2 = pending
 *   4. soft_burn_tenant_cap(escrow, cap_t1) — burns the stale cap
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
import { buildIntegrate, buildRent, clock } from '../builders.ts';
import type { TransactionArgument } from '@mysten/sui/transactions';

const DIR = dirname(fileURLToPath(import.meta.url));

// Very short tenure (2s) + FullTenure handover so the countdown expires quickly.
// This allows the soft_burn precondition (stale cap) without a long wait.
const SHORT_TENURE_MS = 2_000n;

function buildShortTenureEnsemble(tx: Transaction, pkg: string): TransactionArgument {
  const price = (mist: bigint) =>
    tx.moveCall({ target: `${pkg}::ensemble::price`, arguments: [tx.pure.u64(mist)] });
  const dur = (ms: bigint) =>
    tx.moveCall({ target: `${pkg}::ensemble::duration`, arguments: [tx.pure.u64(ms)] });

  const restPrice      = tx.moveCall({ target: `${pkg}::ensemble::new_rest_price_fixed`,          arguments: [price(FLOOR_PRICE_MIST)] });
  const tenureDuration = tx.moveCall({ target: `${pkg}::ensemble::new_tenure_duration_fixed`,     arguments: [dur(SHORT_TENURE_MS)] });
  const tenureExtend   = tx.moveCall({ target: `${pkg}::ensemble::new_tenure_multi` });
  const handover       = tx.moveCall({ target: `${pkg}::ensemble::new_handover_full_tenure` });
  const auctionWin     = tx.moveCall({ target: `${pkg}::ensemble::new_descent_off` });
  const creditShape    = tx.moveCall({ target: `${pkg}::ensemble::new_linear` });
  const auctionShape   = tx.moveCall({ target: `${pkg}::ensemble::new_linear` });
  const escalation     = tx.moveCall({ target: `${pkg}::ensemble::new_price_fixed_delta`, arguments: [price(1n)] });
  return tx.moveCall({
    target: `${pkg}::ensemble::new_ensemble`,
    arguments: [restPrice, tenureDuration, tenureExtend, handover, auctionWin, creditShape, auctionShape, escalation],
  });
}

async function setupDemandState(
  client: SuiClient,
  owner: Ed25519Keypair,
  tenant1: Ed25519Keypair,
  tenant2: Ed25519Keypair,
  d: ReturnType<typeof loadDeployment>,
): Promise<{ escrowId: string; staleCapId: string }> {
  // 1. integrate
  const tx1 = new Transaction();
  tx1.setSender(d.owner.address);
  const ownerCap = buildIntegrate(tx1, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId, buildShortTenureEnsemble);
  tx1.transferObjects([ownerCap], d.owner.address);

  const r1 = await execSetup(client, owner, tx1);
  const escrowObj = (r1.objectChanges ?? []).find(
    c => c.type === 'created' && (c as any).objectType?.includes('Escrow'),
  ) as any;
  if (!escrowObj) throw new Error('setup: Escrow not found');

  // 2. tenant1 rents → Occupied, cap_t1 = current
  const tx2 = new Transaction();
  tx2.setSender(d.tenant1.address);
  const cap1 = buildRent(tx2, d.usufructPackageId, d.dummyAssetPackageId, escrowObj.objectId);
  tx2.transferObjects([cap1], d.tenant1.address);

  const r2 = await execSetup(client, tenant1, tx2);
  const cap1Obj = (r2.objectChanges ?? []).find(
    c => c.type === 'created' && (c as any).objectType?.includes('TenantCap'),
  ) as any;
  if (!cap1Obj) throw new Error('setup: TenantCap t1 not found');

  // 3. tenant2 bids → Demand, cap_t1 becomes stale
  // Payment is 2x floor to cover price escalation (exact floor is computable
  // on-chain via next_floor_price_mist; excess becomes stake, returned on exit)
  const tx3 = new Transaction();
  tx3.setSender(d.tenant2.address);
  const [payment2] = tx3.splitCoins(tx3.gas, [tx3.pure.u64(FLOOR_PRICE_MIST * 2n)]);
  const cycles2 = tx3.moveCall({
    target: `${d.usufructPackageId}::ensemble::tenures`,
    arguments: [tx3.pure.u64(1n)],
  });
  const cap2 = tx3.moveCall({
    target: `${d.usufructPackageId}::escrow::rent`,
    typeArguments: [`${d.dummyAssetPackageId}::dummy_asset::DummyAsset`, '0x2::sui::SUI'],
    arguments: [tx3.object(escrowObj.objectId), payment2, cycles2, clock(tx3)],
  });
  tx3.transferObjects([cap2], d.tenant2.address);

  await execSetup(client, tenant2, tx3);

  // Wait for the 2s handover countdown to expire, then apply pending transitions
  // so t2 becomes current and t1's cap becomes stale.
  await new Promise(r => setTimeout(r, 3000));

  const typeArgs = [
    `${d.dummyAssetPackageId}::dummy_asset::DummyAsset`,
    '0x2::sui::SUI',
  ];
  const txApply = new Transaction();
  txApply.setSender(d.owner.address);
  txApply.moveCall({
    target: `${d.usufructPackageId}::escrow::apply_pending_transition_states`,
    typeArguments: typeArgs,
    arguments: [txApply.object(escrowObj.objectId), clock(txApply)],
  });
  await execSetup(client, owner, txApply);

  return { escrowId: escrowObj.objectId, staleCapId: cap1Obj.objectId };
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
    const { escrowId, staleCapId } = await setupDemandState(
      client, kp.owner, kp.tenant1, kp.tenant2, d,
    );

    process.stdout.write(' measuring...');
    const tx = new Transaction();
    tx.setSender(d.tenant1.address);

    // Burns the stale cap_t1 (tenant1's cap, now stale after tenant2 bid)
    tx.moveCall({
      target: `${d.usufructPackageId}::escrow::soft_burn_tenant_cap`,
      typeArguments: typeArgs,
      arguments: [tx.object(escrowId), tx.object(staleCapId), clock(tx)],
    });

    const rec = await measure(client, kp.tenant1, 'soft_burn', run, tx);
    records.push(rec);
    console.log(` net=${rec.net} MIST  -${rec.objectsDeleted}obj`);
  }

  const med = median(records);
  console.log(`\nMedian net: ${med.net} MIST`);
  saveRecords(resolve(DIR, '../results/a_04_soft_burn.json'), records);
}

main().catch(e => { console.error(e); process.exit(1); });
