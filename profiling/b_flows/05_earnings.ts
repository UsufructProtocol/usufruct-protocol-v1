#!/usr/bin/env tsx
/**
 * Phase B / 05 — Owner income, inbox-first (batched collect)
 * Flow: integrate → N × (rent → wait → apply [each posts 1 EarningsMessage]) →
 *       ONE collect_earnings_messages(all N) → retire → apply → claim
 *
 * Before/after headline. The old model withdrew per tenure (+2.3M MIST each,
 * mutating the SHARED escrow). The inbox-first model mails each tenure's 90%
 * owner share to the EarningsInbox as an owned EarningsMessage, then drains all
 * N in a single rebate-positive PTB against owned objects — the single `collect`
 * step is the payoff line.
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
import { buildIntegrate, buildFlowEnsemble, clock } from '../builders.ts';

const DIR = dirname(fileURLToPath(import.meta.url));
const N   = 3;
const SUI = '0x2::sui::SUI';

type Ref = { objectId: string; version: string; digest: string };

// Query every EarningsMessage<SUI> currently sitting at the inbox address.
async function getEarningsMessageRefs(
  client: SuiClient, usufructPkg: string, inboxId: string,
): Promise<Ref[]> {
  const refs: Ref[] = [];
  let cursor: string | null | undefined = undefined;
  do {
    const page = await client.getOwnedObjects({
      owner: inboxId, cursor, options: { showType: true }, limit: 50,
    });
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

  const typeArgs = [
    `${d.dummyAssetPackageId}::dummy_asset::DummyAsset`,
    '0x2::sui::SUI',
  ];

  const steps: any[] = [];

  // integrate (mints the cap + inbox pair)
  const tx1 = new Transaction();
  tx1.setSender(d.owner.address);
  const { ownerCap, inbox } = buildIntegrate(tx1, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId, buildFlowEnsemble);
  tx1.transferObjects([ownerCap, inbox], d.owner.address);
  const r1 = await measure(client, kp.owner, 'integrate', 0, tx1);
  steps.push(r1);
  console.log(`integrate: net=${r1.net}`);

  const c1 = (await client.getTransactionBlock({ digest: r1.digest, options: { showObjectChanges: true } })).objectChanges ?? [];
  const escrowId   = (c1.find(c => c.type === 'created' && (c as any).objectType?.includes('::escrow::Escrow')) as any).objectId;
  const ownerCapId = (c1.find(c => c.type === 'created' && (c as any).objectType?.includes('OwnerCap')) as any).objectId;
  const inboxId    = (c1.find(c => c.type === 'created' && (c as any).objectType?.includes('EarningsInbox')) as any).objectId;

  // N tenures — each expiry mails one EarningsMessage to the inbox.
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

    // apply (settles tenure → posts EarningsMessage to the inbox)
    const txApp = new Transaction();
    txApp.setSender(d.owner.address);
    txApp.moveCall({
      target: `${d.usufructPackageId}::escrow::apply_pending_transition_states`,
      typeArguments: typeArgs,
      arguments: [txApp.object(escrowId), clock(txApp)],
    });
    const rApp = await measure(client, kp.owner, `apply_${i}`, 0, txApp);
    steps.push(rApp);
    console.log(`  tenure ${i + 1}: rent=${rRent.net}  apply=${rApp.net}`);
  }

  // ── The payoff: one batched collect drains all N EarningsMessages ─────────
  await new Promise(r => setTimeout(r, 1000));
  const refs = await getEarningsMessageRefs(client, d.usufructPackageId, inboxId);
  console.log(`  inbox holds ${refs.length} EarningsMessage(s) → single collect`);

  const earningsType  = `${d.usufructPackageId}::earnings_message::EarningsMessage<${SUI}>`;
  const receivingType = `0x2::transfer::Receiving<${earningsType}>`;
  const txCollect = new Transaction();
  txCollect.setSender(d.owner.address);
  const tickets   = refs.map(r => txCollect.receivingRef({ objectId: r.objectId, version: r.version, digest: r.digest }));
  const ticketVec = txCollect.makeMoveVec({ type: receivingType, elements: tickets });
  const coin = txCollect.moveCall({
    target: `${d.usufructPackageId}::earnings::collect_earnings_messages`,
    typeArguments: [SUI],
    arguments: [txCollect.object(inboxId), ticketVec],
  });
  txCollect.transferObjects([coin], d.owner.address);
  const rCollect = await measure(client, kp.owner, `collect_earnings_${refs.length}`, 0, txCollect);
  steps.push(rCollect);
  console.log(`  collect(${refs.length}): net=${rCollect.net}`);

  // retire + apply + claim
  const txRet = new Transaction();
  txRet.setSender(d.owner.address);
  txRet.moveCall({
    target: `${d.usufructPackageId}::escrow::retire`,
    typeArguments: typeArgs,
    arguments: [txRet.object(escrowId), txRet.object(ownerCapId), clock(txRet)],
  });
  steps.push(await measure(client, kp.owner, 'retire', 0, txRet));

  const txApp2 = new Transaction();
  txApp2.setSender(d.owner.address);
  txApp2.moveCall({
    target: `${d.usufructPackageId}::escrow::apply_pending_transition_states`,
    typeArguments: typeArgs,
    arguments: [txApp2.object(escrowId), clock(txApp2)],
  });
  steps.push(await measure(client, kp.owner, 'apply_transitions', 0, txApp2));

  const txC = new Transaction();
  txC.setSender(d.owner.address);
  const asset = txC.moveCall({
    target: `${d.usufructPackageId}::escrow::claim_asset`,
    typeArguments: typeArgs,
    arguments: [txC.object(escrowId), txC.object(ownerCapId), clock(txC)],
  });
  txC.transferObjects([asset], d.owner.address);
  steps.push(await measure(client, kp.owner, 'claim_asset', 0, txC));

  const totalNet = steps.reduce((acc, s) => acc + s.net, 0n);
  console.log(`\nN=${N} inbox-first earnings. Total net: ${totalNet} MIST`);

  writeFileSync(
    resolve(DIR, '../results/b_05_earnings.json'),
    JSON.stringify(steps.map(s => ({ ...s, computation: s.computation.toString(), storage: s.storage.toString(), rebate: s.rebate.toString(), nonRefundable: s.nonRefundable.toString(), net: s.net.toString() })), null, 2),
  );
}

main().catch(e => { console.error(e); process.exit(1); });
