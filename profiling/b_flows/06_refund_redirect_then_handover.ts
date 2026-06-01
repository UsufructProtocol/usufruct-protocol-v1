#!/usr/bin/env tsx
/**
 * Phase B / 06 — Refund redirect → handover round-trip
 *
 * Commercial scenario mirroring the e2e Move test
 * update_tenant_refund_address_e2e_active_then_handover_routes_to_new
 * but exercised against a live chain with real-time waits.
 *
 * Flow (9 measured steps):
 *   1. integrate (FlowHandover ensemble, 10s tenure)
 *   2. tenant1 rents → Occupied, cap_t1
 *   3. tenant1 redirects refund via refund::refund_address(new_addr)
 *   4. tenant2 rents → bid → Demand
 *   5. wait 12s → apply_pending fires handover; refund coin routed to new_addr
 *   6. soft_burn stale cap_t1
 *   7. retire
 *   8. wait 12s → apply_pending fires tenure expiry on t2
 *   9. claim_asset
 *
 * Beyond what 03_handover already measures: step 3 inserts the new feature
 * inside a realistic commercial cycle. The diff between this flow and
 * 03_handover quantifies the gas footprint of the redirect — the cost
 * a cap buyer pays once to make the cap economically self-contained.
 */

import { resolve, dirname } from 'path';
import { fileURLToPath }    from 'url';
import { Transaction }      from '@mysten/sui/transactions';
import { writeFileSync }    from 'fs';
import {
  loadDeployment, loadKeypairs, makeClient,
  FLOOR_PRICE_MIST,
} from '../env.ts';
import { measure } from '../measure.ts';
import { buildIntegrate, buildFlowHandoverEnsemble, clock } from '../builders.ts';

const DIR = dirname(fileURLToPath(import.meta.url));

// Arbitrary synthetic destination — receives the refund on handover (step 5).
const NEW_REFUND_ADDR = '0x00000000000000000000000000000000000000000000000000000000cafe0006';

async function main() {
  const d      = loadDeployment();
  const client = makeClient();
  const kp     = loadKeypairs(d);

  const typeArgs = [
    `${d.dummyAssetPackageId}::dummy_asset::DummyAsset`,
    '0x2::sui::SUI',
  ];

  const steps: any[] = [];

  // 1. integrate
  process.stdout.write('Step 1 integrate...');
  const tx1 = new Transaction();
  tx1.setSender(d.owner.address);
  const { ownerCap, inbox } = buildIntegrate(tx1, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId, buildFlowHandoverEnsemble);
  tx1.transferObjects([ownerCap, inbox], d.owner.address);
  const r1 = await measure(client, kp.owner, 'integrate', 0, tx1);
  steps.push(r1);
  console.log(` net=${r1.net}`);

  const c1 = (await client.getTransactionBlock({ digest: r1.digest, options: { showObjectChanges: true } })).objectChanges ?? [];
  const escrowId   = (c1.find(c => c.type === 'created' && (c as any).objectType?.includes('Escrow'))   as any).objectId;
  const ownerCapId = (c1.find(c => c.type === 'created' && (c as any).objectType?.includes('OwnerCap')) as any).objectId;

  // 2. tenant1 rents
  process.stdout.write('Step 2 rent(t1)...');
  const tx2 = new Transaction();
  tx2.setSender(d.tenant1.address);
  const [pay1] = tx2.splitCoins(tx2.gas, [tx2.pure.u64(FLOOR_PRICE_MIST)]);
  const cyc1   = tx2.moveCall({ target: `${d.usufructPackageId}::ensemble::tenures`, arguments: [tx2.pure.u64(1n)] });
  const cap1   = tx2.moveCall({
    target:        `${d.usufructPackageId}::escrow::rent`,
    typeArguments: typeArgs,
    arguments:     [tx2.object(escrowId), pay1, cyc1, clock(tx2)],
  });
  tx2.transferObjects([cap1], d.tenant1.address);
  const r2 = await measure(client, kp.tenant1, 'rent_t1', 0, tx2);
  steps.push(r2);
  console.log(` net=${r2.net}`);

  const c2 = (await client.getTransactionBlock({ digest: r2.digest, options: { showObjectChanges: true } })).objectChanges ?? [];
  const cap1Id = (c2.find(c => c.type === 'created' && (c as any).objectType?.includes('TenantCap')) as any).objectId;

  // 3. tenant1 redirects refund — the feature step.
  process.stdout.write('Step 3 update_refund_address...');
  const tx3 = new Transaction();
  tx3.setSender(d.tenant1.address);
  const refund = tx3.moveCall({
    target:    `${d.usufructPackageId}::refund::refund_address`,
    arguments: [tx3.pure.address(NEW_REFUND_ADDR)],
  });
  tx3.moveCall({
    target:        `${d.usufructPackageId}::escrow::update_tenant_refund_address`,
    typeArguments: typeArgs,
    arguments:     [tx3.object(escrowId), tx3.object(cap1Id), refund, clock(tx3)],
  });
  const r3 = await measure(client, kp.tenant1, 'update_refund_address', 0, tx3);
  steps.push(r3);
  console.log(` net=${r3.net}`);

  // 4. tenant2 bids → Demand
  process.stdout.write('Step 4 rent(t2)...');
  const tx4 = new Transaction();
  tx4.setSender(d.tenant2.address);
  const [pay2] = tx4.splitCoins(tx4.gas, [tx4.pure.u64(FLOOR_PRICE_MIST * 2n)]); // 2x for escalation
  const cyc2   = tx4.moveCall({ target: `${d.usufructPackageId}::ensemble::tenures`, arguments: [tx4.pure.u64(1n)] });
  const cap2   = tx4.moveCall({
    target:        `${d.usufructPackageId}::escrow::rent`,
    typeArguments: typeArgs,
    arguments:     [tx4.object(escrowId), pay2, cyc2, clock(tx4)],
  });
  tx4.transferObjects([cap2], d.tenant2.address);
  const r4 = await measure(client, kp.tenant2, 'rent_t2', 0, tx4);
  steps.push(r4);
  console.log(` net=${r4.net}`);

  // 5. wait for tenure expiry → apply_pending fires handover, refund to NEW_REFUND_ADDR.
  process.stdout.write('  waiting for tenure expiry + apply...');
  await new Promise(r => setTimeout(r, 12000));
  const tx5 = new Transaction();
  tx5.setSender(d.owner.address);
  tx5.moveCall({
    target:        `${d.usufructPackageId}::escrow::apply_pending_transition_states`,
    typeArguments: typeArgs,
    arguments:     [tx5.object(escrowId), clock(tx5)],
  });
  const r5 = await measure(client, kp.owner, 'apply_handover', 0, tx5);
  steps.push(r5);
  console.log(` net=${r5.net}`);

  // 6. soft_burn the stale cap_t1.
  process.stdout.write('Step 6 soft_burn(stale t1)...');
  const tx6 = new Transaction();
  tx6.setSender(d.tenant1.address);
  tx6.moveCall({
    target:        `${d.usufructPackageId}::escrow::soft_burn_tenant_cap`,
    typeArguments: typeArgs,
    arguments:     [tx6.object(escrowId), tx6.object(cap1Id), clock(tx6)],
  });
  const r6 = await measure(client, kp.tenant1, 'soft_burn', 0, tx6);
  steps.push(r6);
  console.log(` net=${r6.net}`);

  // 7. retire.
  process.stdout.write('Step 7 retire...');
  const tx7 = new Transaction();
  tx7.setSender(d.owner.address);
  tx7.moveCall({
    target:        `${d.usufructPackageId}::escrow::retire`,
    typeArguments: typeArgs,
    arguments:     [tx7.object(escrowId), tx7.object(ownerCapId), clock(tx7)],
  });
  const r7 = await measure(client, kp.owner, 'retire', 0, tx7);
  steps.push(r7);
  console.log(` net=${r7.net}`);

  // 8. wait for t2 tenure expiry + apply.
  process.stdout.write('  waiting for t2 tenure expiry...');
  await new Promise(r => setTimeout(r, 12000));
  console.log(' done');

  const tx8 = new Transaction();
  tx8.setSender(d.owner.address);
  tx8.moveCall({
    target:        `${d.usufructPackageId}::escrow::apply_pending_transition_states`,
    typeArguments: typeArgs,
    arguments:     [tx8.object(escrowId), clock(tx8)],
  });
  const r8 = await measure(client, kp.owner, 'apply_transitions', 0, tx8);
  steps.push(r8);

  // 9. claim.
  process.stdout.write('Step 9 claim...');
  const tx9 = new Transaction();
  tx9.setSender(d.owner.address);
  const asset = tx9.moveCall({
    target:        `${d.usufructPackageId}::escrow::claim_asset`,
    typeArguments: typeArgs,
    arguments:     [tx9.object(escrowId), tx9.object(ownerCapId), clock(tx9)],
  });
  tx9.transferObjects([asset], d.owner.address);
  const r9 = await measure(client, kp.owner, 'claim_asset', 0, tx9);
  steps.push(r9);
  console.log(` net=${r9.net}`);

  const totalNet = steps.reduce((acc, s) => acc + s.net, 0n);
  console.log(`\nTotal net cost: ${totalNet} MIST`);

  writeFileSync(
    resolve(DIR, '../results/b_06_refund_redirect_then_handover.json'),
    JSON.stringify(
      steps.map(s => ({
        ...s,
        computation:   s.computation.toString(),
        storage:       s.storage.toString(),
        rebate:        s.rebate.toString(),
        nonRefundable: s.nonRefundable.toString(),
        net:           s.net.toString(),
      })),
      null, 2,
    ),
  );
}

main().catch(e => { console.error(e); process.exit(1); });
