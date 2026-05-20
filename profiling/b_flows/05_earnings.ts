#!/usr/bin/env tsx
/**
 * Phase B / 05 — Earnings withdrawal per tenure
 * Flow: integrate → N × (rent → withdraw_earnings → soft_burn) → retire → claim
 * Shows the overhead of owner collecting earnings after every tenure.
 */

import { resolve, dirname } from 'path';
import { fileURLToPath }  from 'url';
import { Transaction }    from '@mysten/sui/transactions';
import { writeFileSync }  from 'fs';
import {
  loadDeployment, loadKeypairs, makeClient,
} from '../env.ts';
import { measure } from '../measure.ts';
import { buildIntegrate, buildRent, buildHandoverEnsemble, clock, random } from '../builders.ts';

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
  const ownerCap = buildIntegrate(
    tx1, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId,
    buildHandoverEnsemble,
  );
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

    // rent
    const txRent = new Transaction();
    txRent.setSender(addr);
    const cap = buildRent(txRent, d.usufructPackageId, d.dummyAssetPackageId, escrowId);
    txRent.transferObjects([cap], addr);
    const rRent = await measure(client, kpT, `rent_${i}`, 0, txRent);
    steps.push(rRent);

    const cRent = (await client.getTransactionBlock({ digest: rRent.digest, options: { showObjectChanges: true } })).objectChanges ?? [];
    const capId = (cRent.find(c => c.type === 'created' && (c as any).objectType?.includes('TenantCap')) as any).objectId;

    // withdraw earnings
    const txW = new Transaction();
    txW.setSender(d.owner.address);
    const earnings = txW.moveCall({
      target: `${d.usufructPackageId}::escrow::withdraw_earnings`,
      typeArguments: typeArgs,
      arguments: [txW.object(escrowId), txW.object(ownerCapId), random(txW), clock(txW)],
    });
    txW.transferObjects([earnings], d.owner.address);
    const rW = await measure(client, kp.owner, `withdraw_${i}`, 0, txW);
    steps.push(rW);

    console.log(`  tenure ${i + 1}: rent=${rRent.net}  withdraw=${rW.net}`);

    if (i < N - 1) {
      const txB = new Transaction();
      txB.setSender(addr);
      txB.moveCall({
        target: `${d.usufructPackageId}::escrow::soft_burn_tenant_cap`,
        typeArguments: typeArgs,
        arguments: [txB.object(escrowId), txB.object(capId), random(txB), clock(txB)],
      });
      const rB = await measure(client, kpT, `soft_burn_${i}`, 0, txB);
      steps.push(rB);
      console.log(`           soft_burn=${rB.net}`);
    }
  }

  // retire + apply + claim
  const txRet = new Transaction();
  txRet.setSender(d.owner.address);
  txRet.moveCall({
    target: `${d.usufructPackageId}::escrow::retire`,
    typeArguments: typeArgs,
    arguments: [txRet.object(escrowId), txRet.object(ownerCapId), random(txRet), clock(txRet)],
  });
  steps.push(await measure(client, kp.owner, 'retire', 0, txRet));

  const txApp = new Transaction();
  txApp.setSender(d.owner.address);
  txApp.moveCall({
    target: `${d.usufructPackageId}::escrow::apply_pending_transition_states`,
    typeArguments: typeArgs,
    arguments: [txApp.object(escrowId), random(txApp), clock(txApp)],
  });
  steps.push(await measure(client, kp.owner, 'apply_transitions', 0, txApp));

  const txC = new Transaction();
  txC.setSender(d.owner.address);
  const [asset, finalEarnings] = txC.moveCall({
    target: `${d.usufructPackageId}::escrow::claim_asset`,
    typeArguments: typeArgs,
    arguments: [txC.object(escrowId), txC.object(ownerCapId), random(txC), clock(txC)],
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
