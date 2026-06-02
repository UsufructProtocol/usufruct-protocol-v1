#!/usr/bin/env tsx
/**
 * Phase B / 07 — Fleet portfolio: two objects govern N escrows, one PTB collects all
 *
 * The §10/§11 claim, measured end-to-end. A fleet of N escrows is governed by a
 * SINGLE GovernanceCap and routes all its governor income to a SINGLE EarningsInbox:
 *   integrate (mint the pair) → integrate_into_portfolio ×(N−1) →
 *   N × rent → wait → N × apply (each posts 1 EarningsMessage to the shared inbox) →
 *   ONE collect_earnings_messages draining all N → N × (retire → apply → claim)
 *
 * The headline is the single collect step: O(N) income consolidated in O(1) PTBs,
 * rebate-positive. Governance (retire/claim) is per-escrow but uses the one shared
 * cap — no per-N governance state.
 *
 * Usage: tsx b_flows/07_fleet_portfolio_collect.ts [N]   (default N=3)
 */

import { resolve, dirname } from 'path';
import { fileURLToPath }  from 'url';
import { Transaction }    from '@mysten/sui/transactions';
import { SuiClient }      from '@mysten/sui/client';
import { writeFileSync }  from 'fs';
import {
  loadDeployment, loadKeypairs, makeClient, FLOOR_PRICE_MIST,
} from '../env.ts';
import { measure } from '../measure.ts';
import { buildIntegrate, buildIntegrateIntoPortfolio, buildFlowEnsemble, clock } from '../builders.ts';

const DIR = dirname(fileURLToPath(import.meta.url));
const N   = parseInt(process.argv[2] ?? '3', 10);
const SUI = '0x2::sui::SUI';

type Ref = { objectId: string; version: string; digest: string };

async function getEarningsMessageRefs(client: SuiClient, inboxId: string): Promise<Ref[]> {
  const refs: Ref[] = [];
  let cursor: string | null | undefined = undefined;
  do {
    const page = await client.getOwnedObjects({ owner: inboxId, cursor, options: { showType: true }, limit: 50 });
    for (const obj of page.data) {
      if ((obj.data?.type ?? '').includes('earnings_message::EarningsMessage')) {
        refs.push({ objectId: obj.data!.objectId, version: obj.data!.version, digest: obj.data!.digest });
      }
    }
    cursor = page.hasNextPage ? page.nextCursor : null;
  } while (cursor);
  return refs;
}

async function main() {
  const d      = loadDeployment();
  const client = makeClient();
  const kp     = loadKeypairs(d);

  const typeArgs = [`${d.dummyAssetPackageId}::dummy_asset::DummyAsset`, SUI];

  console.log(`Fleet portfolio flow with N=${N} (one cap, one inbox)`);
  const steps: any[] = [];
  const escrows: string[] = [];
  let governanceCapId = '';
  let inboxId    = '';

  // 1. integrate (mint pair) + (N−1) portfolio joins.
  for (let i = 0; i < N; i++) {
    const tx = new Transaction();
    tx.setSender(d.governor.address);
    if (i === 0) {
      const { governanceCap, inbox } = buildIntegrate(tx, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId, buildFlowEnsemble);
      tx.transferObjects([governanceCap, inbox], d.governor.address);
    } else {
      buildIntegrateIntoPortfolio(tx, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId, governanceCapId, inboxId, buildFlowEnsemble);
    }
    const rec = await measure(client, kp.governor, i === 0 ? 'integrate' : `join_${i}`, 0, tx);
    steps.push(rec);
    const changes = (await client.getTransactionBlock({ digest: rec.digest, options: { showObjectChanges: true } })).objectChanges ?? [];
    escrows.push((changes.find(c => c.type === 'created' && (c as any).objectType?.includes('::escrow::Escrow')) as any).objectId);
    if (i === 0) {
      governanceCapId = (changes.find(c => c.type === 'created' && (c as any).objectType?.includes('GovernanceCap')) as any).objectId;
      inboxId    = (changes.find(c => c.type === 'created' && (c as any).objectType?.includes('EarningsInbox')) as any).objectId;
    }
    console.log(`  ${i === 0 ? 'integrate' : `join ${i}`}: net=${rec.net}`);
  }

  // 2. rent each escrow.
  for (let i = 0; i < N; i++) {
    const kpT  = i % 2 === 0 ? kp.usufructuary1 : kp.usufructuary2;
    const addr = i % 2 === 0 ? d.usufructuary1.address : d.usufructuary2.address;
    const tx = new Transaction();
    tx.setSender(addr);
    const [pay] = tx.splitCoins(tx.gas, [tx.pure.u64(FLOOR_PRICE_MIST)]);
    const tenures = tx.moveCall({ target: `${d.usufructPackageId}::ensemble::tenures`, arguments: [tx.pure.u64(1n)] });
    const cap = tx.moveCall({ target: `${d.usufructPackageId}::escrow::rent`, typeArguments: typeArgs,
      arguments: [tx.object(escrows[i]), pay, tenures, clock(tx)] });
    tx.transferObjects([cap], addr);
    steps.push(await measure(client, kpT, `rent_${i}`, 0, tx));
  }

  // 3. wait for all tenures to expire, then apply each (posts EarningsMessage).
  console.log('  waiting for tenure expiry...');
  await new Promise(r => setTimeout(r, 12000));
  for (let i = 0; i < N; i++) {
    const tx = new Transaction();
    tx.setSender(d.governor.address);
    tx.moveCall({ target: `${d.usufructPackageId}::escrow::apply_pending_transition_states`, typeArguments: typeArgs,
      arguments: [tx.object(escrows[i]), clock(tx)] });
    steps.push(await measure(client, kp.governor, `apply_${i}`, 0, tx));
  }

  // 4. THE HEADLINE — one collect drains the whole fleet's income from one inbox.
  await new Promise(r => setTimeout(r, 1000));
  const refs = await getEarningsMessageRefs(client, inboxId);
  console.log(`  inbox holds ${refs.length} EarningsMessage(s) from ${N} escrows → single collect`);
  const earningsType  = `${d.usufructPackageId}::earnings_message::EarningsMessage<${SUI}>`;
  const receivingType = `0x2::transfer::Receiving<${earningsType}>`;
  const txCol = new Transaction();
  txCol.setSender(d.governor.address);
  const tickets   = refs.map(r => txCol.receivingRef({ objectId: r.objectId, version: r.version, digest: r.digest }));
  const ticketVec = txCol.makeMoveVec({ type: receivingType, elements: tickets });
  const coin = txCol.moveCall({
    target: `${d.usufructPackageId}::earnings::collect_earnings_messages`,
    typeArguments: [SUI],
    arguments: [txCol.object(inboxId), ticketVec],
  });
  txCol.transferObjects([coin], d.governor.address);
  const rCol = await measure(client, kp.governor, `collect_fleet_${refs.length}`, 0, txCol);
  steps.push(rCol);
  console.log(`  collect(${refs.length}): net=${rCol.net}`);

  // 5. teardown — retire → apply → claim each escrow with the one shared cap.
  for (let i = 0; i < N; i++) {
    const txR = new Transaction();
    txR.setSender(d.governor.address);
    txR.moveCall({ target: `${d.usufructPackageId}::escrow::retire`, typeArguments: typeArgs,
      arguments: [txR.object(escrows[i]), txR.object(governanceCapId), clock(txR)] });
    steps.push(await measure(client, kp.governor, `retire_${i}`, 0, txR));

    const txA = new Transaction();
    txA.setSender(d.governor.address);
    txA.moveCall({ target: `${d.usufructPackageId}::escrow::apply_pending_transition_states`, typeArguments: typeArgs,
      arguments: [txA.object(escrows[i]), clock(txA)] });
    steps.push(await measure(client, kp.governor, `apply_retire_${i}`, 0, txA));

    const txC = new Transaction();
    txC.setSender(d.governor.address);
    const asset = txC.moveCall({ target: `${d.usufructPackageId}::escrow::claim_asset`, typeArguments: typeArgs,
      arguments: [txC.object(escrows[i]), txC.object(governanceCapId), clock(txC)] });
    txC.transferObjects([asset], d.governor.address);
    steps.push(await measure(client, kp.governor, `claim_${i}`, 0, txC));
  }

  const totalNet = steps.reduce((acc, s) => acc + s.net, 0n);
  console.log(`\nN=${N} fleet portfolio. Total net: ${totalNet} MIST  (collect step: ${rCol.net} MIST)`);

  writeFileSync(
    resolve(DIR, `../results/b_07_fleet_portfolio_collect_N${N}.json`),
    JSON.stringify(steps.map(s => ({ ...s, computation: s.computation.toString(), storage: s.storage.toString(), rebate: s.rebate.toString(), nonRefundable: s.nonRefundable.toString(), net: s.net.toString() })), null, 2),
  );
}

main().catch(e => { console.error(e); process.exit(1); });
