#!/usr/bin/env tsx
/**
 * Phase B / 04 — Multi-tenure scaling
 * Flow: integrate → N × (rent → wait → apply) → retire → apply → claim
 * Run with N=3, N=5, N=10 to verify linear vs super-linear gas scaling.
 * Uses 2s tenure so N cycles complete in N*3 seconds.
 *
 * Usage: tsx b_flows/04_multi_tenure.ts [N]   (default N=3)
 */

import { resolve, dirname } from 'path';
import { fileURLToPath }  from 'url';
import { Transaction }    from '@mysten/sui/transactions';
import { writeFileSync }  from 'fs';
import {
  loadDeployment, loadKeypairs, makeClient, FLOOR_PRICE_MIST,
} from '../env.ts';
import { measure } from '../measure.ts';
import { buildIntegrate, buildFlowEnsemble, clock, random } from '../builders.ts';

const DIR = dirname(fileURLToPath(import.meta.url));
const N   = parseInt(process.argv[2] ?? '3', 10);

async function main() {
  const d      = loadDeployment();
  const client = makeClient();
  const kp     = loadKeypairs(d);
  const tenants    = [kp.tenant1, kp.tenant2];
  const tenantAddrs = [d.tenant1.address, d.tenant2.address];

  const typeArgs = [
    `${d.dummyAssetPackageId}::dummy_asset::DummyAsset`,
    '0x2::sui::SUI',
  ];

  console.log(`Running multi-tenure flow with N=${N}`);
  const steps: any[] = [];

  // integrate
  const tx1 = new Transaction();
  tx1.setSender(d.owner.address);
  const ownerCap = buildIntegrate(tx1, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId, buildFlowEnsemble);
  tx1.transferObjects([ownerCap], d.owner.address);
  const r1 = await measure(client, kp.owner, 'integrate', 0, tx1);
  steps.push(r1);
  console.log(`  integrate: net=${r1.net}`);

  const c1 = (await client.getTransactionBlock({ digest: r1.digest, options: { showObjectChanges: true } })).objectChanges ?? [];
  const escrowId   = (c1.find(c => c.type === 'created' && (c as any).objectType?.includes('Escrow')) as any).objectId;
  const ownerCapId = (c1.find(c => c.type === 'created' && (c as any).objectType?.includes('OwnerCap')) as any).objectId;

  let paymentMultiplier = 1n; // escalation: each tenure costs 1 MIST more

  for (let i = 0; i < N; i++) {
    const kpT = tenants[i % 2];
    const addrT = tenantAddrs[i % 2];
    const payAmt = FLOOR_PRICE_MIST + BigInt(i); // floor + delta*i

    const txRent = new Transaction();
    txRent.setSender(addrT);
    const [pay] = txRent.splitCoins(txRent.gas, [txRent.pure.u64(payAmt)]);
    const cyc  = txRent.moveCall({ target: `${d.usufructPackageId}::tenures::tenures`, arguments: [txRent.pure.u64(1n)] });
    const cap  = txRent.moveCall({
      target: `${d.usufructPackageId}::escrow::rent`,
      typeArguments: typeArgs,
      arguments: [txRent.object(escrowId), pay, cyc, random(txRent), clock(txRent)],
    });
    txRent.transferObjects([cap], addrT);
    const rRent = await measure(client, kpT, `rent_${i}`, 0, txRent);
    steps.push(rRent);
    console.log(`  tenure ${i + 1}: rent net=${rRent.net}`);

    // Wait for tenure to expire, then apply transitions (settles to Idle for next rent)
    await new Promise(r => setTimeout(r, 12000));

    const txApp = new Transaction();
    txApp.setSender(d.owner.address);
    txApp.moveCall({
      target: `${d.usufructPackageId}::escrow::apply_pending_transition_states`,
      typeArguments: typeArgs,
      arguments: [txApp.object(escrowId), random(txApp), clock(txApp)],
    });
    const rApp = await measure(client, kp.owner, `apply_${i}`, 0, txApp);
    steps.push(rApp);
    console.log(`           apply  net=${rApp.net}`);
  }

  // retire + apply + claim
  const txRet = new Transaction();
  txRet.setSender(d.owner.address);
  txRet.moveCall({
    target: `${d.usufructPackageId}::escrow::retire`,
    typeArguments: typeArgs,
    arguments: [txRet.object(escrowId), txRet.object(ownerCapId), random(txRet), clock(txRet)],
  });
  const rRet = await measure(client, kp.owner, 'retire', 0, txRet);
  steps.push(rRet);

  const txA = new Transaction();
  txA.setSender(d.owner.address);
  txA.moveCall({
    target: `${d.usufructPackageId}::escrow::apply_pending_transition_states`,
    typeArguments: typeArgs,
    arguments: [txA.object(escrowId), random(txA), clock(txA)],
  });
  const rA = await measure(client, kp.owner, 'apply_final', 0, txA);
  steps.push(rA);

  const txC = new Transaction();
  txC.setSender(d.owner.address);
  const [asset, earnings] = txC.moveCall({
    target: `${d.usufructPackageId}::escrow::claim_asset`,
    typeArguments: typeArgs,
    arguments: [txC.object(escrowId), txC.object(ownerCapId), random(txC), clock(txC)],
  }) as any[];
  txC.transferObjects([asset, earnings], d.owner.address);
  const rC = await measure(client, kp.owner, 'claim_asset', 0, txC);
  steps.push(rC);

  const totalNet = steps.reduce((acc, s) => acc + s.net, 0n);
  console.log(`\nN=${N} total net: ${totalNet} MIST`);

  writeFileSync(
    resolve(DIR, `../results/b_04_multi_tenure_N${N}.json`),
    JSON.stringify(steps.map(s => ({ ...s, computation: s.computation.toString(), storage: s.storage.toString(), rebate: s.rebate.toString(), nonRefundable: s.nonRefundable.toString(), net: s.net.toString() })), null, 2),
  );
}

main().catch(e => { console.error(e); process.exit(1); });
