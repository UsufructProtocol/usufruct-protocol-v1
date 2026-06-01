#!/usr/bin/env tsx
/**
 * Collects all FeeMessage<SUI> objects from the protocol fee inbox.
 *
 * FeeMessages accumulate every time a tenure expires (apply_pending fires
 * the tenure-expiry transition). Collecting them destroys the objects and
 * returns the storage rebate as Coin<SUI> to the caller.
 *
 * At scale the rebate exceeds gas: ~1.9M MIST net per message at N≥50.
 *
 * Usage:
 *   SUI_RPC=https://fullnode.testnet.sui.io:443 npm run collect:fees:testnet
 */

import { SuiClient }      from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction }    from '@mysten/sui/transactions';
import { loadDeployment, makeClient, RPC_URL } from '../env.ts';

// The ProtocolFeeInbox is an owned object transferred to the deployer on init.
// Only the deployer can pass it mutably — profiling wallets cannot.
// Pass credentials via env vars:
//   DEPLOYER_SECRET_KEY=suiprivkey1...  DEPLOYER_ADDRESS=0x...
const MAX_BATCH = 100;  // tickets per PTB — well under gas limits

type Ref = { objectId: string; version: string; digest: string };

async function getAllFeeMessageRefs(client: SuiClient, inboxId: string, pkg: string): Promise<Ref[]> {
  const feeType = `${pkg}::fee_message::FeeMessage<0x2::sui::SUI>`;
  const refs: Ref[] = [];
  let cursor: string | null | undefined = undefined;

  while (true) {
    const page = await client.getOwnedObjects({
      governor:   inboxId,
      filter:  { StructType: feeType },
      options: { showType: true },
      cursor,
      limit:   50,
    });

    for (const obj of page.data) {
      if (!obj.data) continue;
      refs.push({ objectId: obj.data.objectId, version: obj.data.version, digest: obj.data.digest });
    }

    if (!page.hasNextPage || !page.nextCursor) break;
    cursor = page.nextCursor;
  }

  return refs;
}

async function collectBatch(
  client:    SuiClient,
  keypair:   Ed25519Keypair,
  governorAddr: string,
  inboxId:   string,
  pkg:       string,
  refs:      Ref[],
): Promise<bigint> {
  const feeType       = `${pkg}::fee_message::FeeMessage<0x2::sui::SUI>`;
  const receivingType = `0x2::transfer::Receiving<${feeType}>`;

  const tx = new Transaction();
  tx.setSender(governorAddr);
  tx.setGasBudget(200_000_000);

  const tickets    = refs.map(r => tx.receivingRef({ objectId: r.objectId, version: r.version, digest: r.digest }));
  const ticketVec  = tx.makeMoveVec({ type: receivingType, elements: tickets });
  const coin = tx.moveCall({
    target:        `${pkg}::fee_inbox::collect_fee_messages`,
    typeArguments: ['0x2::sui::SUI'],
    arguments:     [tx.object(inboxId), ticketVec],
  });
  tx.transferObjects([coin], governorAddr);

  const bytes = await tx.build({ client });
  const sig   = await keypair.signTransaction(bytes);
  const result = await client.executeTransactionBlock({
    transactionBlock: bytes,
    signature:        sig.signature,
    options:          { showEffects: true },
  });
  await client.waitForTransaction({ digest: result.digest });

  const status = (result.effects as any)?.status?.status;
  if (status !== 'success') {
    const err = (result.effects as any)?.status?.error ?? 'unknown';
    throw new Error(`collect failed: ${err}`);
  }

  const computation    = BigInt((result.effects as any)?.gasUsed?.computationCost    ?? 0);
  const storage        = BigInt((result.effects as any)?.gasUsed?.storageCost        ?? 0);
  const rebate         = BigInt((result.effects as any)?.gasUsed?.storageRebate      ?? 0);
  const nonRefundable  = BigInt((result.effects as any)?.gasUsed?.nonRefundableStorageFee ?? 0);
  return computation + storage - rebate + nonRefundable;
}

async function main() {
  if (!RPC_URL.includes('testnet')) {
    console.error('Expected testnet RPC. Set SUI_RPC=https://fullnode.testnet.sui.io:443');
    process.exit(1);
  }

  const secretKey = process.env.DEPLOYER_SECRET_KEY;
  const address   = process.env.DEPLOYER_ADDRESS;
  if (!secretKey || !address) {
    console.error('Set DEPLOYER_SECRET_KEY and DEPLOYER_ADDRESS env vars.');
    process.exit(1);
  }

  const d       = loadDeployment();
  const client  = makeClient();
  const keypair = Ed25519Keypair.fromSecretKey(secretKey);

  console.log(`Deployer: ${address}`);
  console.log(`Inbox:    ${d.protocolFeeInboxId}`);
  console.log(`Package: ${d.usufructPackageId}\n`);

  process.stdout.write('Querying FeeMessage objects...');
  const refs = await getAllFeeMessageRefs(client, d.protocolFeeInboxId, d.usufructPackageId);
  console.log(` found ${refs.length}\n`);

  if (refs.length === 0) {
    console.log('Nothing to collect.');
    return;
  }

  // chunk into batches
  const chunks: Ref[][] = [];
  for (let i = 0; i < refs.length; i += MAX_BATCH) {
    chunks.push(refs.slice(i, i + MAX_BATCH));
  }

  let totalNet       = 0n;
  let totalCollected = 0;

  for (let i = 0; i < chunks.length; i++) {
    const chunk = chunks[i];
    process.stdout.write(`  batch ${i + 1}/${chunks.length} (${chunk.length} msgs)...`);
    const net = await collectBatch(client, keypair, address, d.protocolFeeInboxId, d.usufructPackageId, chunk);
    totalNet += net;
    totalCollected += chunk.length;
    const sign = net < 0n ? '' : '+';
    console.log(` net=${sign}${net} MIST`);
  }

  const sign = totalNet < 0n ? '' : '+';
  console.log(`\nDone — ${totalCollected} messages collected`);
  console.log(`Total net: ${sign}${totalNet} MIST  (${sign}${(Number(totalNet) / 1e9).toFixed(6)} SUI)`);
  console.log(`Negative = rebate received (SUI recovered to governor wallet)`);
}

main().catch(e => { console.error(e); process.exit(1); });
