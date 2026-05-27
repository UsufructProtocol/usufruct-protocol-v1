#!/usr/bin/env tsx
/**
 * Phase A / 12 — collect_fee_messages (scalability)
 *
 * Measures: fee_message::collect_fee_messages<SUI> with N tickets.
 *
 * FeeMessage generation:
 *   Each escrow produces exactly 1 FeeMessage<SUI> when its tenure expires:
 *     integrate → rent(1 tenure, 1ms) → wait → apply_pending → 1 FeeMessage
 *
 *   Note: tenures(N) does NOT create N FeeMessages — it creates ONE tenure
 *   of N×1ms total duration (compute_total_duration). The three chained steps
 *   in apply_pending (step_handover → step_tenure_expiry → step_auction_expiry)
 *   fire once, returning Idle. Verified empirically.
 *
 *   Therefore: N FeeMessages require N separate escrows → 2N+1 PTBs setup.
 *   Note: integrate and rent no longer require Random. Setup can now batch:
 *   N integrates in one PTB, then N (rent + apply_pending) each in one PTB
 *   → 2N+1 PTBs instead of 3N.
 *
 *   All messages use SUI → single typed vector<Receiving<FeeMessage<SUI>>>.
 *
 * Scalability:
 *   N = [1, 10, 50, 100, 500]   (collected in ≤MAX_BATCH per PTB)
 *   Optional: pass CLI arg to include larger N (slow setup)
 *
 * Usage:
 *   tsx a_atomic/12_collect_fee_messages.ts          # up to N=500
 *   tsx a_atomic/12_collect_fee_messages.ts 100      # up to N=100
 *   tsx a_atomic/12_collect_fee_messages.ts 1000     # up to N=1000 (~25min setup)
 */

import { writeFileSync }    from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath }    from 'url';
import { Transaction }      from '@mysten/sui/transactions';
import { SuiClient }        from '@mysten/sui/client';
import { Ed25519Keypair }   from '@mysten/sui/keypairs/ed25519';
import {
  loadDeployment, loadKeypairs, makeClient, FLOOR_PRICE_MIST,
} from '../env.ts';
import { measure } from '../measure.ts';
import { clock } from '../builders.ts';

const DIR = dirname(fileURLToPath(import.meta.url));

const N_MAX    = parseInt(process.argv[2] ?? '50', 10);
const N_VALUES = [1, 10, 50, 100, 500, 1000, 5000, 10000].filter(n => n <= N_MAX);
const MAX_BATCH = 500; // max tickets per collect_fee_messages PTB

type D    = ReturnType<typeof loadDeployment>;
type KP   = ReturnType<typeof loadKeypairs>;
type Ref  = { objectId: string; version: string; digest: string };

const SUI     = '0x2::sui::SUI';
const TA      = (d: D) => [`${d.dummyAssetPackageId}::dummy_asset::DummyAsset`, SUI];

// ── Single-escrow setup: integrate → rent(1 tenure, 1ms) ──────────────────

async function setupOneEscrow(
  client: SuiClient, owner: Ed25519Keypair, tenant: Ed25519Keypair, d: D,
): Promise<string> {
  const pkg = d.usufructPackageId;

  // integrate
  const tx1 = new Transaction();
  tx1.setSender(d.owner.address);
  const p  = (m: bigint) => tx1.moveCall({ target: `${pkg}::ensemble::price`, arguments: [tx1.pure.u64(m)] });
  const dr = (m: bigint) => tx1.moveCall({ target: `${pkg}::ensemble::duration`, arguments: [tx1.pure.u64(m)] });
  const ens = tx1.moveCall({ target: `${pkg}::ensemble::new_ensemble`, arguments: [
    tx1.moveCall({ target: `${pkg}::ensemble::new_rest_price_fixed`,          arguments: [p(FLOOR_PRICE_MIST)] }),
    tx1.moveCall({ target: `${pkg}::ensemble::new_tenure_duration_fixed`,     arguments: [dr(1n)] }),
    tx1.moveCall({ target: `${pkg}::ensemble::new_tenure_single` }),
    tx1.moveCall({ target: `${pkg}::ensemble::new_handover_off` }),
    tx1.moveCall({ target: `${pkg}::ensemble::new_descent_off` }),
    tx1.moveCall({ target: `${pkg}::ensemble::new_linear` }),
    tx1.moveCall({ target: `${pkg}::ensemble::new_linear` }),
    tx1.moveCall({ target: `${pkg}::ensemble::new_price_fixed_delta`, arguments: [p(1n)] }),
  ]});
  const asset = tx1.moveCall({ target: `${d.dummyAssetPackageId}::dummy_asset::mint` });
  const comm  = tx1.moveCall({ target: `${pkg}::ensemble::new_commitment_immediate` });
  const oc    = tx1.moveCall({ target: `${pkg}::escrow::integrate`, typeArguments: TA(d),
    arguments: [asset, ens, comm, tx1.object(d.protocolFeeRefId), clock(tx1)] });
  tx1.transferObjects([oc], d.owner.address);

  const r1 = await client.signAndExecuteTransaction({
    transaction: tx1, signer: owner, options: { showEffects: true, showObjectChanges: true },
  });
  await client.waitForTransaction({ digest: r1.digest });
  if (r1.effects?.status.status !== 'success') throw new Error(`integrate failed`);

  const escrowObj = (r1.objectChanges ?? []).find(
    c => c.type === 'created' && (c as any).objectType?.includes('::escrow::Escrow'),
  ) as any;
  const escrowId = escrowObj.objectId;

  // rent(1 tenure)
  const tx2 = new Transaction();
  tx2.setSender(d.tenant1.address);
  const [pay] = tx2.splitCoins(tx2.gas, [tx2.pure.u64(FLOOR_PRICE_MIST)]);
  const tenures   = tx2.moveCall({ target: `${pkg}::ensemble::tenures`, arguments: [tx2.pure.u64(1n)] });
  const cap   = tx2.moveCall({ target: `${pkg}::escrow::rent`, typeArguments: TA(d),
    arguments: [tx2.object(escrowId), pay, tenures, clock(tx2)] });
  tx2.transferObjects([cap], d.tenant1.address);

  const r2 = await client.signAndExecuteTransaction({
    transaction: tx2, signer: tenant, options: { showEffects: true },
  });
  await client.waitForTransaction({ digest: r2.digest });
  if (r2.effects?.status.status !== 'success') throw new Error(`rent failed`);

  return escrowId;
}

// apply_pending with fresh gas to avoid stale coin version errors
async function applyPending(
  client: SuiClient, owner: Ed25519Keypair, d: D, escrowId: string,
): Promise<boolean> {
  const coins = await client.getCoins({ owner: d.owner.address, limit: 3 });
  const tx = new Transaction();
  tx.setSender(d.owner.address);
  if (coins.data.length > 0) {
    tx.setGasPayment(coins.data.map(c => ({ objectId: c.coinObjectId, version: c.version, digest: c.digest })));
  }
  tx.moveCall({ target: `${d.usufructPackageId}::escrow::apply_pending_transition_states`,
    typeArguments: TA(d), arguments: [tx.object(escrowId), clock(tx)] });

  const r = await client.signAndExecuteTransaction({
    transaction: tx, signer: owner, options: { showEffects: true },
  });
  await client.waitForTransaction({ digest: r.digest });
  return r.effects?.status.status === 'success';
}

// ── Generate N FeeMessages: N escrows × (integrate + rent + apply) ─────────

async function generateFeeMessages(
  client: SuiClient, kp: KP, d: D, n: number,
): Promise<void> {
  console.log(`  Setup: ${n} escrows × 3 PTBs (integrate + rent + apply_pending)`);
  const escrows: string[] = [];

  // Phase 1: integrate all N escrows
  process.stdout.write(`  [1/3] integrate: `);
  for (let i = 0; i < n; i++) {
    const pkg = d.usufructPackageId;
    const tx  = new Transaction();
    tx.setSender(d.owner.address);
    const p  = (m: bigint) => tx.moveCall({ target: `${pkg}::ensemble::price`, arguments: [tx.pure.u64(m)] });
    const dr = (m: bigint) => tx.moveCall({ target: `${pkg}::ensemble::duration`, arguments: [tx.pure.u64(m)] });
    const ens = tx.moveCall({ target: `${pkg}::ensemble::new_ensemble`, arguments: [
      tx.moveCall({ target: `${pkg}::ensemble::new_rest_price_fixed`,          arguments: [p(FLOOR_PRICE_MIST)] }),
      tx.moveCall({ target: `${pkg}::ensemble::new_tenure_duration_fixed`,     arguments: [dr(1n)] }),
      tx.moveCall({ target: `${pkg}::ensemble::new_tenure_single` }),
      tx.moveCall({ target: `${pkg}::ensemble::new_handover_off` }),
      tx.moveCall({ target: `${pkg}::ensemble::new_descent_off` }),
      tx.moveCall({ target: `${pkg}::ensemble::new_linear` }),
      tx.moveCall({ target: `${pkg}::ensemble::new_linear` }),
      tx.moveCall({ target: `${pkg}::ensemble::new_price_fixed_delta`, arguments: [p(1n)] }),
    ]});
    const asset = tx.moveCall({ target: `${d.dummyAssetPackageId}::dummy_asset::mint` });
    const comm  = tx.moveCall({ target: `${pkg}::ensemble::new_commitment_immediate` });
    const oc    = tx.moveCall({ target: `${pkg}::escrow::integrate`, typeArguments: TA(d),
      arguments: [asset, ens, comm, tx.object(d.protocolFeeRefId), clock(tx)] });
    tx.transferObjects([oc], d.owner.address);

    const r = await client.signAndExecuteTransaction({
      transaction: tx, signer: kp.owner, options: { showEffects: true, showObjectChanges: true },
    });
    await client.waitForTransaction({ digest: r.digest });
    const esc = (r.objectChanges ?? []).find(
      c => c.type === 'created' && (c as any).objectType?.includes('::escrow::Escrow'),
    ) as any;
    escrows.push(esc.objectId);
    if ((i + 1) % 10 === 0) process.stdout.write(`${i + 1}`);
    else process.stdout.write('.');
  }
  console.log(` ✓`);

  // Phase 2: rent each escrow (1 tenure, 1ms)
  process.stdout.write(`  [2/3] rent:      `);
  for (let i = 0; i < n; i++) {
    const tx = new Transaction();
    tx.setSender(d.tenant1.address);
    const [pay] = tx.splitCoins(tx.gas, [tx.pure.u64(FLOOR_PRICE_MIST)]);
    const tenures   = tx.moveCall({ target: `${d.usufructPackageId}::ensemble::tenures`, arguments: [tx.pure.u64(1n)] });
    const cap   = tx.moveCall({ target: `${d.usufructPackageId}::escrow::rent`, typeArguments: TA(d),
      arguments: [tx.object(escrows[i]), pay, tenures, clock(tx)] });
    tx.transferObjects([cap], d.tenant1.address);
    const r = await client.signAndExecuteTransaction({
      transaction: tx, signer: kp.tenant1, options: { showEffects: true },
    });
    await client.waitForTransaction({ digest: r.digest });
    if ((i + 1) % 10 === 0) process.stdout.write(`${i + 1}`);
    else process.stdout.write('.');
  }
  console.log(` ✓`);

  // All 1ms tenures expired by now. Phase 3: apply_pending each escrow → FeeMessage
  process.stdout.write(`  [3/3] apply:     `);
  for (let i = 0; i < n; i++) {
    let ok = false;
    for (let attempt = 0; attempt < 3 && !ok; attempt++) {
      ok = await applyPending(client, kp.owner, d, escrows[i]);
    }
    if (!ok) throw new Error(`apply_pending failed for escrow ${i} after 3 attempts`);
    if ((i + 1) % 10 === 0) process.stdout.write(`${i + 1}`);
    else process.stdout.write('.');
  }
  console.log(` ✓`);
}

// ── Query FeeMessage<SUI> in the inbox ────────────────────────────────────

async function getFeeMessageRefs(
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
      if ((obj.data?.type ?? '').includes('fee_message::FeeMessage')) {
        refs.push({ objectId: obj.data!.objectId, version: obj.data!.version, digest: obj.data!.digest });
        if (refs.length >= limit) break;
      }
    }
    if (!page.hasNextPage || !page.nextCursor) break;
    cursor = page.nextCursor;
  }
  return refs;
}

// ── Collect N FeeMessages (batched at MAX_BATCH per PTB) ──────────────────
//
// ProtocolFeeInbox is owned by whoever deployed the package. On localnet the
// deployer is the same as the profiling owner; on testnet they differ.
// Pass DEPLOYER_SECRET_KEY + DEPLOYER_ADDRESS env vars for the testnet case.

function loadCollectorKeypair(d: D): { keypair: Ed25519Keypair; address: string } {
  const sk  = process.env.DEPLOYER_SECRET_KEY;
  const addr = process.env.DEPLOYER_ADDRESS;
  if (sk && addr) return { keypair: Ed25519Keypair.fromSecretKey(sk), address: addr };
  return { keypair: Ed25519Keypair.fromSecretKey(d.owner.secretKey), address: d.owner.address };
}

async function measureCollect(
  client: SuiClient, kp: KP, d: D, n: number,
): Promise<{ totalNet: bigint; perMessage: bigint; numCalls: number }> {
  const refs = await getFeeMessageRefs(client, d.protocolFeeInboxId, n + 5);
  if (refs.length < n) throw new Error(`Inbox has ${refs.length} FeeMessages, expected ≥${n}`);

  const batch  = refs.slice(0, n);
  const chunks = [] as Ref[][];
  for (let i = 0; i < n; i += MAX_BATCH) chunks.push(batch.slice(i, i + MAX_BATCH));

  const feeType       = `${d.usufructPackageId}::fee_message::FeeMessage<${SUI}>`;
  const receivingType = `0x2::transfer::Receiving<${feeType}>`;
  const { keypair: collector, address: collectorAddr } = loadCollectorKeypair(d);

  let totalNet = 0n;
  let numCalls = 0;

  for (const chunk of chunks) {
    const tx = new Transaction();
    tx.setSender(collectorAddr);
    const tickets   = chunk.map(r => tx.receivingRef({ objectId: r.objectId, version: r.version, digest: r.digest }));
    const ticketVec = tx.makeMoveVec({ type: receivingType, elements: tickets });
    const coin = tx.moveCall({
      target: `${d.usufructPackageId}::fee_inbox::collect_fee_messages`,
      typeArguments: [SUI],
      arguments: [tx.object(d.protocolFeeInboxId), ticketVec],
    });
    tx.transferObjects([coin], collectorAddr);

    const rec = await measure(client, collector, `collect_${n}_c${numCalls}`, numCalls, tx);
    totalNet += rec.net;
    numCalls++;
  }

  return { totalNet, perMessage: n > 0 ? totalNet / BigInt(n) : 0n, numCalls };
}

// ── Main ──────────────────────────────────────────────────────────────────

async function main() {
  const d      = loadDeployment();
  const client = makeClient();
  const kp     = loadKeypairs(d);

  console.log(`collect_fee_messages<SUI> scalability`);
  console.log(`N_max=${N_MAX}  values=[${N_VALUES.join(', ')}]  MAX_BATCH=${MAX_BATCH}`);
  console.log(`Setup cost per N: 2N+1 PTBs\n`);

  const results: any[] = [];

  for (const n of N_VALUES) {
    console.log(`\n─── N = ${n} ───`);
    await generateFeeMessages(client, kp, d, n);

    await new Promise(r => setTimeout(r, 1000));
    process.stdout.write(`  collect(${n}): `);
    const { totalNet, perMessage, numCalls } = await measureCollect(client, kp, d, n);
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

  writeFileSync(resolve(DIR, '../results/a_12_collect_fee_messages.json'), JSON.stringify(results, null, 2));
}

main().catch(e => { console.error(e); process.exit(1); });
