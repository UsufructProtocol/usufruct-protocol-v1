#!/usr/bin/env tsx
/**
 * Phase B / 05 — Earnings withdrawal per tenure
 * Flow: integrate → N × (rent → wait → apply → withdraw) → retire → apply → claim
 * Shows overhead of collecting earnings after each tenure.
 */

import { resolve, dirname } from 'path';
import { fileURLToPath }  from 'url';
import { Transaction }    from '@mysten/sui/transactions';
import { writeFileSync }  from 'fs';
import {
  loadDeployment, loadKeypairs, makeClient, FLOOR_PRICE_MIST,
} from '../env.ts';
import { measure } from '../measure.ts';
import { buildIntegrate, buildFlowEnsemble, clock } from '../builders.ts';

const DIR = dirname(fileURLToPath(import.meta.url));
const N   = 3;

async function main() {
  const d      = loadDeployment();
  const client = makeClient();
  const kp     = loadKeypairs(d);

  const typeArgs = [
    `${d.dummyAssetPackageId}::dummy_asset::DummyAsset`,
    '0x2::sui::SUI',
  ];

  const steps: any[] = [];

  // integrate
  const tx1 = new Transaction();
  tx1.setSender(d.owner.address);
  const ownerCap = buildIntegrate(tx1, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId, buildFlowEnsemble);
  tx1.transferObjects([ownerCap], d.owner.address);
  const r1 = await measure(client, kp.owner, 'integrate', 0, tx1);
  steps.push(r1);
  console.log(`integrate: net=${r1.net}`);

  const c1 = (await client.getTransactionBlock({ digest: r1.digest, options: { showObjectChanges: true } })).objectChanges ?? [];
  const escrowId   = (c1.find(c => c.type === 'created' && (c as any).objectType?.includes('Escrow')) as any).objectId;
  const ownerCapId = (c1.find(c => c.type === 'created' && (c as any).objectType?.includes('OwnerCap')) as any).objectId;

  for (let i = 0; i < N; i++) {
    const kpT  = i % 2 === 0 ? kp.tenant1 : kp.tenant2;
    const addr = i % 2 === 0 ? d.tenant1.address : d.tenant2.address;
    const payAmt = FLOOR_PRICE_MIST + BigInt(i);

    // rent
    const txRent = new Transaction();
    txRent.setSender(addr);
    const [pay] = txRent.splitCoins(txRent.gas, [txRent.pure.u64(payAmt)]);
    const tenures  = txRent.moveCall({ target: `${d.usufructPackageId}::ensemble::tenures`, arguments: [txRent.pure.u64(1n)] });
    const cap  = txRent.moveCall({
      target: `${d.usufructPackageId}::escrow::rent`,
      typeArguments: typeArgs,
      arguments: [txRent.object(escrowId), pay, tenures, clock(txRent)],
    });
    txRent.transferObjects([cap], addr);
    const rRent = await measure(client, kpT, `rent_${i}`, 0, txRent);
    steps.push(rRent);

    // wait for tenure to expire
    await new Promise(r => setTimeout(r, 12000));

    // apply (settles tenure, releases earnings)
    const txApp = new Transaction();
    txApp.setSender(d.owner.address);
    txApp.moveCall({
      target: `${d.usufructPackageId}::escrow::apply_pending_transition_states`,
      typeArguments: typeArgs,
      arguments: [txApp.object(escrowId), clock(txApp)],
    });
    const rApp = await measure(client, kp.owner, `apply_${i}`, 0, txApp);
    steps.push(rApp);

    // withdraw earnings
    const txW = new Transaction();
    txW.setSender(d.owner.address);
    const earnings = txW.moveCall({
      target: `${d.usufructPackageId}::escrow::withdraw_earnings`,
      typeArguments: typeArgs,
      arguments: [txW.object(escrowId), txW.object(ownerCapId), clock(txW)],
    });
    txW.transferObjects([earnings], d.owner.address);
    const rW = await measure(client, kp.owner, `withdraw_${i}`, 0, txW);
    steps.push(rW);
    console.log(`  tenure ${i + 1}: rent=${rRent.net}  apply=${rApp.net}  withdraw=${rW.net}`);
  }

  // retire + apply + claim
  const txRet = new Transaction();
  txRet.setSender(d.owner.address);
  txRet.moveCall({
    target: `${d.usufructPackageId}::escrow::retire`,
    typeArguments: typeArgs,
    arguments: [txRet.object(escrowId), txRet.object(ownerCapId), clock(txRet)],
  });
  steps.push(await measure(client, kp.owner, 'retire', 0, txRet));

  const txApp = new Transaction();
  txApp.setSender(d.owner.address);
  txApp.moveCall({
    target: `${d.usufructPackageId}::escrow::apply_pending_transition_states`,
    typeArguments: typeArgs,
    arguments: [txApp.object(escrowId), clock(txApp)],
  });
  steps.push(await measure(client, kp.owner, 'apply_final', 0, txApp));

  const txC = new Transaction();
  txC.setSender(d.owner.address);
  const [asset, finalEarnings] = txC.moveCall({
    target: `${d.usufructPackageId}::escrow::claim_asset`,
    typeArguments: typeArgs,
    arguments: [txC.object(escrowId), txC.object(ownerCapId), clock(txC)],
  }) as any[];
  txC.transferObjects([asset, finalEarnings], d.owner.address);
  steps.push(await measure(client, kp.owner, 'claim_asset', 0, txC));

  const totalNet = steps.reduce((acc, s) => acc + s.net, 0n);
  console.log(`\nN=${N} with earnings withdrawal. Total net: ${totalNet} MIST`);

  writeFileSync(
    resolve(DIR, '../results/b_05_earnings.json'),
    JSON.stringify(steps.map(s => ({ ...s, computation: s.computation.toString(), storage: s.storage.toString(), rebate: s.rebate.toString(), nonRefundable: s.nonRefundable.toString(), net: s.net.toString() })), null, 2),
  );
}

main().catch(e => { console.error(e); process.exit(1); });
