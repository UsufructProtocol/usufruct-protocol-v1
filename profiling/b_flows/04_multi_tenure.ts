#!/usr/bin/env tsx
/**
 * Phase B / 04 — Multi-tenure scaling
 * Flow: integrate → N × (rent → soft_burn) → retire → claim
 * Run with N=3, N=5, N=10 to verify linear vs super-linear gas scaling.
 *
 * Usage: tsx b_flows/04_multi_tenure.ts [N]   (default N=3)
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
const N   = parseInt(process.argv[2] ?? '3', 10);

async function main() {
  const d      = loadDeployment();
  const client = makeClient();
  const kp     = loadKeypairs(d);
  const tenants = [kp.tenant1, kp.tenant2, kp.tenant1, kp.tenant2, kp.tenant1,
                   kp.tenant2, kp.tenant1, kp.tenant2, kp.tenant1, kp.tenant2];
  const tenantAddrs = [d.tenant1.address, d.tenant2.address, d.tenant1.address, d.tenant2.address,
                       d.tenant1.address, d.tenant2.address, d.tenant1.address, d.tenant2.address,
                       d.tenant1.address, d.tenant2.address];

  const typeArgs = [
    `${d.dummyAssetPackageId}::dummy_asset::DummyAsset`,
    '0x2::sui::SUI',
  ];

  console.log(`Running multi-tenure flow with N=${N}`);
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
  console.log(`  integrate: net=${r1.net}`);

  const c1 = (await client.getTransactionBlock({ digest: r1.digest, options: { showObjectChanges: true } })).objectChanges ?? [];
  const escrowId   = (c1.find(c => c.type === 'created' && (c as any).objectType?.includes('Escrow')) as any).objectId;
  const ownerCapId = (c1.find(c => c.type === 'created' && (c as any).objectType?.includes('OwnerCap')) as any).objectId;

  // N tenure cycles: rent → soft_burn
  for (let i = 0; i < N; i++) {
    const kpTenant = tenants[i % 2];
    const addrTenant = tenantAddrs[i % 2];

    const txRent = new Transaction();
    txRent.setSender(addrTenant);
    const cap = buildRent(txRent, d.usufructPackageId, d.dummyAssetPackageId, escrowId);
    txRent.transferObjects([cap], addrTenant);
    const rRent = await measure(client, kpTenant, `rent_${i}`, 0, txRent);
    steps.push(rRent);

    const cRent = (await client.getTransactionBlock({ digest: rRent.digest, options: { showObjectChanges: true } })).objectChanges ?? [];
    const capId = (cRent.find(c => c.type === 'created' && (c as any).objectType?.includes('TenantCap')) as any).objectId;

    // Don't soft_burn on last tenure — owner retires instead
    if (i < N - 1) {
      const txBurn = new Transaction();
      txBurn.setSender(addrTenant);
      txBurn.moveCall({
        target: `${d.usufructPackageId}::escrow::soft_burn_tenant_cap`,
        typeArguments: typeArgs,
        arguments: [txBurn.object(escrowId), txBurn.object(capId), random(txBurn), clock(txBurn)],
      });
      const rBurn = await measure(client, kpTenant, `soft_burn_${i}`, 0, txBurn);
      steps.push(rBurn);
      console.log(`  tenure ${i + 1}: rent=${rRent.net} + soft_burn=${rBurn.net}`);
    } else {
      console.log(`  tenure ${i + 1} (last): rent=${rRent.net}`);
    }
  }

  // retire
  const txR = new Transaction();
  txR.setSender(d.owner.address);
  txR.moveCall({
    target: `${d.usufructPackageId}::escrow::retire`,
    typeArguments: typeArgs,
    arguments: [txR.object(escrowId), txR.object(ownerCapId), random(txR), clock(txR)],
  });
  const rR = await measure(client, kp.owner, 'retire', 0, txR);
  steps.push(rR);

  const txA = new Transaction();
  txA.setSender(d.owner.address);
  txA.moveCall({
    target: `${d.usufructPackageId}::escrow::apply_pending_transition_states`,
    typeArguments: typeArgs,
    arguments: [txA.object(escrowId), random(txA), clock(txA)],
  });
  const rA = await measure(client, kp.owner, 'apply_transitions', 0, txA);
  steps.push(rA);

  // claim
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
