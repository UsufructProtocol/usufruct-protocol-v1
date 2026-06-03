#!/usr/bin/env tsx
/**
 * Collects all EarningsMessage<SUI> from every EarningsInbox owned by the governor.
 *
 * Each `integrate` mints a fresh EarningsInbox; settlements mail EarningsMessages
 * to it. Collecting destroys the messages and returns the storage rebate plus the
 * earnings coin to the governor. Mirror of collect_fees.ts, except the inboxes are
 * governor-owned (no DEPLOYER_* dance) and there may be many — so this batches
 * several inboxes' collects into one PTB.
 *
 * Usage:
 *   SUI_RPC=https://fullnode.testnet.sui.io:443 npm run collect:earnings:cleanup
 */

import { SuiClient }      from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction }    from '@mysten/sui/transactions';
import { loadDeployment, makeClient, RPC_URL } from '../env.ts';

const INBOX_PER_PTB = 25;  // inboxes drained per transaction

type Ref = { objectId: string; version: string; digest: string };

// Retry transient RPC failures (504s are common across the ~hundreds of queries
// this script makes). Tx execution is NOT retried — only read queries.
async function withRetry<T>(fn: () => Promise<T>, label: string): Promise<T> {
  for (let attempt = 1; ; attempt++) {
    try { return await fn(); }
    catch (e: any) {
      if (attempt >= 6) throw e;
      const ms = 500 * attempt;
      process.stderr.write(`\n  [retry ${attempt} after ${ms}ms: ${label} — ${(e?.message ?? e).toString().slice(0, 80)}]`);
      await new Promise(r => setTimeout(r, ms));
    }
  }
}

// Current object ref for a coin (version/digest move each tx, so refresh per PTB).
async function objRef(client: SuiClient, id: string): Promise<Ref> {
  const o = await client.getObject({ id, options: {} });
  if (!o.data) throw new Error(`gas coin ${id} not found`);
  return { objectId: o.data.objectId, version: o.data.version, digest: o.data.digest };
}

async function getOwned(client: SuiClient, owner: string, type: string): Promise<Ref[]> {
  const refs: Ref[] = [];
  let cursor: string | null | undefined = undefined;
  while (true) {
    const page = await withRetry(() => client.getOwnedObjects({
      owner, filter: { StructType: type }, options: {}, cursor, limit: 50,
    }), `getOwnedObjects(${type.slice(-20)})`);
    for (const o of page.data) {
      if (o.data) refs.push({ objectId: o.data.objectId, version: o.data.version, digest: o.data.digest });
    }
    if (!page.hasNextPage || !page.nextCursor) break;
    cursor = page.nextCursor;
  }
  return refs;
}

async function main() {
  if (!RPC_URL.includes('testnet')) {
    console.error('Expected testnet RPC. Set SUI_RPC=https://fullnode.testnet.sui.io:443');
    process.exit(1);
  }

  const d       = loadDeployment();
  const client  = makeClient();
  const kp      = Ed25519Keypair.fromSecretKey(d.governor.secretKey);
  const gov     = d.governor.address;
  const pkg     = d.usufructPackageId;
  const msgType  = `${pkg}::earnings_message::EarningsMessage<0x2::sui::SUI>`;
  const recvType = `0x2::transfer::Receiving<${msgType}>`;

  // Optional dedicated gas coin (GAS_COIN_ID) so this can run in parallel with
  // another governor-signed process (e.g. cleanup.ts) without contending for gas
  // coins. Pin it via setGasPayment; any conflict aborts the run (no retry).
  const gasCoinId = process.env.GAS_COIN_ID;

  console.log(`Governor: ${gov}`);
  console.log(`Package: ${pkg}`);
  if (gasCoinId) console.log(`Gas coin (pinned): ${gasCoinId}`);
  console.log();

  process.stdout.write('Finding EarningsInboxes...');
  const inboxes = await getOwned(client, gov, `${pkg}::earnings_inbox::EarningsInbox`);
  console.log(` ${inboxes.length}`);

  process.stdout.write('Scanning inboxes for EarningsMessages...');
  const withMsgs: { inbox: string; msgs: Ref[] }[] = [];
  for (const inbox of inboxes) {
    const msgs = await getOwned(client, inbox.objectId, msgType);
    if (msgs.length) withMsgs.push({ inbox: inbox.objectId, msgs });
  }
  const totalMsgs = withMsgs.reduce((s, x) => s + x.msgs.length, 0);
  console.log(` ${withMsgs.length} inboxes hold ${totalMsgs} messages\n`);
  if (totalMsgs === 0) { console.log('Nothing to collect.'); return; }

  let totalNet = 0n, collected = 0;
  for (let i = 0; i < withMsgs.length; i += INBOX_PER_PTB) {
    const batch = withMsgs.slice(i, i + INBOX_PER_PTB);
    const tx = new Transaction();
    tx.setSender(gov);
    tx.setGasBudget(300_000_000);
    if (gasCoinId) tx.setGasPayment([await objRef(client, gasCoinId)]);

    const coins: any[] = [];
    for (const { inbox, msgs } of batch) {
      const tickets = msgs.map(r => tx.receivingRef({ objectId: r.objectId, version: r.version, digest: r.digest }));
      const vec     = tx.makeMoveVec({ type: recvType, elements: tickets });
      const coin = tx.moveCall({
        target:        `${pkg}::earnings::collect_earnings_messages`,
        typeArguments: ['0x2::sui::SUI'],
        arguments:     [tx.object(inbox), vec],
      });
      coins.push(coin);
    }
    tx.transferObjects(coins, gov);

    const bytes  = await tx.build({ client });
    const sig    = await kp.signTransaction(bytes);
    const result = await client.executeTransactionBlock({
      transactionBlock: bytes, signature: sig.signature, options: { showEffects: true },
    });
    await client.waitForTransaction({ digest: result.digest });

    const status = (result.effects as any)?.status?.status;
    if (status !== 'success') throw new Error(`collect failed: ${(result.effects as any)?.status?.error ?? 'unknown'}`);

    const g   = (result.effects as any).gasUsed;
    const net = BigInt(g.computationCost) + BigInt(g.storageCost) - BigInt(g.storageRebate);
    totalNet  += net;
    const msgs = batch.reduce((s, x) => s + x.msgs.length, 0);
    collected += msgs;
    const sign = net < 0n ? '' : '+';
    console.log(`  PTB ${Math.floor(i / INBOX_PER_PTB) + 1}: ${batch.length} inboxes / ${msgs} msgs  net=${sign}${net} MIST`);
  }

  const sign = totalNet < 0n ? '' : '+';
  console.log(`\nDone — ${collected} messages from ${withMsgs.length} inboxes`);
  console.log(`Total net: ${sign}${totalNet} MIST  (${sign}${(Number(totalNet) / 1e9).toFixed(6)} SUI)`);
  console.log('Negative = rebate received (SUI recovered to governor wallet).');
}

main().catch(e => { console.error(e); process.exit(1); });
