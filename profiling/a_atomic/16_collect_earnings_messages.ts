#!/usr/bin/env tsx
/**
 * Phase A / 16 — collect_earnings_messages (scalability)
 *
 * Measures: earnings::collect_earnings_messages<SUI> with N tickets — the governor-
 * income twin of a_atomic/12_collect_fee_messages.ts.
 *
 * EarningsMessage generation (ONE shared inbox — the realistic fleet topology):
 *   integrate once (mints the cap+inbox pair) → integrate_into_portfolio ×(N−1),
 *   so all N escrows route their governor-share income to the SAME EarningsInbox.
 *   Each escrow's tenure expiry posts exactly 1 EarningsMessage<SUI> (the 90%):
 *     rent(1 tenure, 1ms) → wait → apply_pending → 1 EarningsMessage to the inbox
 *
 *   integrate alone would scatter messages across N separate inboxes, making a
 *   single batched collect impossible — so the portfolio path is structural here,
 *   not incidental (and it exercises integrate_into_portfolio for free).
 *
 *   The inbox is owned by the profiling governor, so collection signs as the governor —
 *   no DEPLOYER_* env dance (unlike 12, whose ProtocolFeeInbox is deployer-owned).
 *
 * Hypothesis under test:
 *   EarningsMessage<C> is byte-identical to FeeMessage<C>, so this curve should
 *   reproduce 12's: break-even N≈2, ≈ −1.93M MIST/msg at N=50 (rebate-positive).
 *
 * Usage:
 *   tsx a_atomic/16_collect_earnings_messages.ts          # up to N=50
 *   tsx a_atomic/16_collect_earnings_messages.ts 100      # up to N=100
 */

import { writeFileSync }    from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath }    from 'url';
import { Transaction }      from '@mysten/sui/transactions';
import { SuiClient }        from '@mysten/sui/client';
import { Ed25519Keypair }   from '@mysten/sui/keypairs/ed25519';
import type { TransactionArgument } from '@mysten/sui/transactions';
import {
  loadDeployment, loadKeypairs, makeClient, FLOOR_PRICE_MIST,
} from '../env.ts';
import { measure } from '../measure.ts';
import { buildIntegrate, buildIntegrateIntoPortfolio, clock } from '../builders.ts';

const DIR = dirname(fileURLToPath(import.meta.url));

const N_MAX     = parseInt(process.argv[2] ?? '50', 10);
const N_VALUES  = [1, 10, 50, 100, 500, 1000].filter(n => n <= N_MAX);
const MAX_BATCH = 500; // max tickets per collect_earnings_messages PTB

type D   = ReturnType<typeof loadDeployment>;
type KP  = ReturnType<typeof loadKeypairs>;
type Ref = { objectId: string; version: string; digest: string };

const SUI = '0x2::sui::SUI';
const TA  = (d: D) => [`${d.dummyAssetPackageId}::dummy_asset::DummyAsset`, SUI];

// 1ms-tenure ensemble so each tenure expires immediately (fast setup at scale).
// Mirrors 12's inline ensemble — gas is tenure-duration-independent.
function build1msEnsemble(tx: Transaction, pkg: string): TransactionArgument {
  const p  = (m: bigint) => tx.moveCall({ target: `${pkg}::ensemble::price`,    arguments: [tx.pure.u64(m)] });
  const dr = (m: bigint) => tx.moveCall({ target: `${pkg}::ensemble::duration`, arguments: [tx.pure.u64(m)] });
  return tx.moveCall({ target: `${pkg}::ensemble::new_ensemble`, arguments: [
    tx.moveCall({ target: `${pkg}::ensemble::new_rest_price_fixed`,      arguments: [p(FLOOR_PRICE_MIST)] }),
    tx.moveCall({ target: `${pkg}::ensemble::new_tenure_duration_fixed`, arguments: [dr(1n)] }),
    tx.moveCall({ target: `${pkg}::ensemble::new_tenure_single` }),
    tx.moveCall({ target: `${pkg}::ensemble::new_handover_off` }),
    tx.moveCall({ target: `${pkg}::ensemble::new_descent_off` }),
    tx.moveCall({ target: `${pkg}::ensemble::new_linear` }),
    tx.moveCall({ target: `${pkg}::ensemble::new_linear` }),
    tx.moveCall({ target: `${pkg}::ensemble::new_price_fixed_delta`, arguments: [p(1n)] }),
  ]});
}

// apply_pending with fresh gas to avoid stale coin version errors
async function applyPending(
  client: SuiClient, governor: Ed25519Keypair, d: D, escrowId: string,
): Promise<boolean> {
  const coins = await client.getCoins({ owner: d.governor.address, limit: 3 });
  const tx = new Transaction();
  tx.setSender(d.governor.address);
  if (coins.data.length > 0) {
    tx.setGasPayment(coins.data.map(c => ({ objectId: c.coinObjectId, version: c.version, digest: c.digest })));
  }
  tx.moveCall({ target: `${d.usufructPackageId}::escrow::apply_pending_transition_states`,
    typeArguments: TA(d), arguments: [tx.object(escrowId), clock(tx)] });
  const r = await client.signAndExecuteTransaction({ transaction: tx, signer: governor, options: { showEffects: true } });
  await client.waitForTransaction({ digest: r.digest });
  return r.effects?.status.status === 'success';
}

// ── Build a portfolio of N escrows sharing ONE inbox, each with 1 pending msg ──
// Returns the shared inbox id.
async function generateEarningsMessages(
  client: SuiClient, kp: KP, d: D, n: number,
): Promise<string> {
  console.log(`  Setup: 1 integrate + ${n - 1} integrate_into_portfolio + ${n}×(rent+apply)`);
  const escrows: string[] = [];
  let inboxId  = '';
  let governanceCapId = '';

  // Phase 1: integrate escrow 0 (mint pair), then join the rest to the portfolio.
  process.stdout.write(`  [1/3] integrate: `);
  for (let i = 0; i < n; i++) {
    const tx = new Transaction();
    tx.setSender(d.governor.address);
    if (i === 0) {
      const { governanceCap, inbox } = buildIntegrate(tx, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId, build1msEnsemble);
      tx.transferObjects([governanceCap, inbox], d.governor.address);
    } else {
      buildIntegrateIntoPortfolio(tx, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId, governanceCapId, inboxId, build1msEnsemble);
    }
    const r = await client.signAndExecuteTransaction({
      transaction: tx, signer: kp.governor, options: { showEffects: true, showObjectChanges: true },
    });
    await client.waitForTransaction({ digest: r.digest });
    if (r.effects?.status.status !== 'success') throw new Error(`integrate ${i} failed`);
    const changes = r.objectChanges ?? [];
    const esc = changes.find(c => c.type === 'created' && (c as any).objectType?.includes('::escrow::Escrow')) as any;
    escrows.push(esc.objectId);
    if (i === 0) {
      inboxId    = (changes.find(c => c.type === 'created' && (c as any).objectType?.includes('EarningsInbox')) as any).objectId;
      governanceCapId = (changes.find(c => c.type === 'created' && (c as any).objectType?.includes('GovernanceCap')) as any).objectId;
    }
    if ((i + 1) % 10 === 0) process.stdout.write(`${i + 1}`); else process.stdout.write('.');
  }
  console.log(` ✓  inbox=${inboxId.slice(0, 10)}…`);

  // Phase 2: rent each escrow (1 tenure, 1ms)
  process.stdout.write(`  [2/3] rent:      `);
  for (let i = 0; i < n; i++) {
    const tx = new Transaction();
    tx.setSender(d.usufructuary1.address);
    const [pay] = tx.splitCoins(tx.gas, [tx.pure.u64(FLOOR_PRICE_MIST)]);
    const tenures = tx.moveCall({ target: `${d.usufructPackageId}::ensemble::tenures`, arguments: [tx.pure.u64(1n)] });
    const cap = tx.moveCall({ target: `${d.usufructPackageId}::escrow::rent`, typeArguments: TA(d),
      arguments: [tx.object(escrows[i]), pay, tenures, clock(tx)] });
    tx.transferObjects([cap], d.usufructuary1.address);
    const r = await client.signAndExecuteTransaction({ transaction: tx, signer: kp.usufructuary1, options: { showEffects: true } });
    await client.waitForTransaction({ digest: r.digest });
    if ((i + 1) % 10 === 0) process.stdout.write(`${i + 1}`); else process.stdout.write('.');
  }
  console.log(` ✓`);

  // Phase 3: apply_pending each escrow → posts 1 EarningsMessage to the shared inbox
  process.stdout.write(`  [3/3] apply:     `);
  for (let i = 0; i < n; i++) {
    let ok = false;
    for (let attempt = 0; attempt < 3 && !ok; attempt++) ok = await applyPending(client, kp.governor, d, escrows[i]);
    if (!ok) throw new Error(`apply_pending failed for escrow ${i} after 3 attempts`);
    if ((i + 1) % 10 === 0) process.stdout.write(`${i + 1}`); else process.stdout.write('.');
  }
  console.log(` ✓`);

  return inboxId;
}

// ── Query EarningsMessage<SUI> sitting at the inbox ───────────────────────────
async function getEarningsMessageRefs(
  client: SuiClient, inboxId: string, limit: number,
): Promise<Ref[]> {
  const refs: Ref[] = [];
  let cursor: string | null | undefined = undefined;
  while (refs.length < limit) {
    const page = await client.getOwnedObjects({
      owner: inboxId, cursor, options: { showType: true },
      limit: Math.min(limit - refs.length, 50),
    });
    for (const obj of page.data) {
      if ((obj.data?.type ?? '').includes('earnings_message::EarningsMessage')) {
        refs.push({ objectId: obj.data!.objectId, version: obj.data!.version, digest: obj.data!.digest });
        if (refs.length >= limit) break;
      }
    }
    if (!page.hasNextPage || !page.nextCursor) break;
    cursor = page.nextCursor;
  }
  return refs;
}

// ── Collect N EarningsMessages (batched at MAX_BATCH per PTB) ──────────────────
async function measureCollect(
  client: SuiClient, kp: KP, d: D, inboxId: string, n: number,
): Promise<{ totalNet: bigint; perMessage: bigint; numCalls: number }> {
  const refs = await getEarningsMessageRefs(client, inboxId, n + 5);
  if (refs.length < n) throw new Error(`Inbox has ${refs.length} EarningsMessages, expected ≥${n}`);

  const batch  = refs.slice(0, n);
  const chunks: Ref[][] = [];
  for (let i = 0; i < n; i += MAX_BATCH) chunks.push(batch.slice(i, i + MAX_BATCH));

  const earningsType  = `${d.usufructPackageId}::earnings_message::EarningsMessage<${SUI}>`;
  const receivingType = `0x2::transfer::Receiving<${earningsType}>`;

  let totalNet = 0n;
  let numCalls = 0;
  for (const chunk of chunks) {
    const tx = new Transaction();
    tx.setSender(d.governor.address);
    const tickets   = chunk.map(r => tx.receivingRef({ objectId: r.objectId, version: r.version, digest: r.digest }));
    const ticketVec = tx.makeMoveVec({ type: receivingType, elements: tickets });
    const coin = tx.moveCall({
      target: `${d.usufructPackageId}::earnings::collect_earnings_messages`,
      typeArguments: [SUI],
      arguments: [tx.object(inboxId), ticketVec],
    });
    tx.transferObjects([coin], d.governor.address);

    const rec = await measure(client, kp.governor, `collect_${n}_c${numCalls}`, numCalls, tx);
    totalNet += rec.net;
    numCalls++;
  }
  return { totalNet, perMessage: n > 0 ? totalNet / BigInt(n) : 0n, numCalls };
}

async function main() {
  const d      = loadDeployment();
  const client = makeClient();
  const kp     = loadKeypairs(d);

  console.log(`collect_earnings_messages<SUI> scalability`);
  console.log(`N_max=${N_MAX}  values=[${N_VALUES.join(', ')}]  MAX_BATCH=${MAX_BATCH}`);
  console.log(`Setup cost per N: 3N PTBs (1 integrate + N−1 portfolio joins + N rent + N apply)\n`);

  const results: any[] = [];
  for (const n of N_VALUES) {
    console.log(`\n─── N = ${n} ───`);
    const inboxId = await generateEarningsMessages(client, kp, d, n);

    await new Promise(r => setTimeout(r, 1000));
    process.stdout.write(`  collect(${n}): `);
    const { totalNet, perMessage, numCalls } = await measureCollect(client, kp, d, inboxId, n);
    console.log(`total=${totalNet.toLocaleString()} MIST  per_msg=${perMessage.toLocaleString()} MIST  calls=${numCalls}`);
    results.push({ n, totalNet: totalNet.toString(), perMessage: perMessage.toString(), numCalls });
  }

  console.log('\n═══ Scalability summary ═══');
  console.log('N'.padEnd(8) + 'Net MIST'.padEnd(22) + 'Per msg MIST'.padEnd(20) + 'PTB calls');
  console.log('─'.repeat(62));
  for (const r of results) {
    console.log(
      String(r.n).padEnd(8) +
      BigInt(r.totalNet).toLocaleString().padEnd(22) +
      BigInt(r.perMessage).toLocaleString().padEnd(20) +
      r.numCalls,
    );
  }

  writeFileSync(resolve(DIR, '../results/a_16_collect_earnings_messages.json'), JSON.stringify(results, null, 2));
}

main().catch(e => { console.error(e); process.exit(1); });
