#!/usr/bin/env tsx
/**
 * Verification probe — is the per-message collect cost of fee vs earnings really
 * identical, and does inbox residual count affect it?
 *
 * The on-chain code is provably identical (same struct, receive_message,
 * consume_message, event). This isolates the two candidate causes of the ~75k
 * MIST/msg gap seen between a_12 (fee) and a_16 (earnings):
 *
 *   PART 1 (message TYPE, controlled N=1, same escrow & instant):
 *     one escrow, rent->apply posts 1 fee msg (to the populated deployment fee
 *     inbox) AND 1 earnings msg (to a fresh earnings inbox). Collect each alone.
 *     net_fee1 vs net_earn1.
 *
 *   PART 2 (RESIDUAL count, same message type):
 *     accumulate ~20 earnings msgs in that same fresh inbox, collect exactly 1
 *     (leaving the rest), -> net_earn_amid. Compare to net_earn1 (1-of-1).
 *     Equal => residual sibling count does NOT change per-message collect gas
 *     => the residual hypothesis is refuted.
 */

import { Transaction }    from '@mysten/sui/transactions';
import { SuiClient }      from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import type { TransactionArgument } from '@mysten/sui/transactions';
import {
  loadDeployment, loadKeypairs, makeClient, FLOOR_PRICE_MIST,
} from './env.ts';
import { measure } from './measure.ts';
import { buildIntegrate, clock } from './builders.ts';

const SUI       = '0x2::sui::SUI';
const RESIDUALS = 12;

type D = ReturnType<typeof loadDeployment>;
type Ref = { objectId: string; version: string; digest: string };
const TA = (d: D) => [`${d.dummyAssetPackageId}::dummy_asset::DummyAsset`, SUI];

function build1ms(tx: Transaction, pkg: string): TransactionArgument {
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

async function rentAndApply(client: SuiClient, kp: any, d: D, escrowId: string): Promise<void> {
  const txR = new Transaction();
  txR.setSender(d.usufructuary1.address);
  const [pay] = txR.splitCoins(txR.gas, [txR.pure.u64(FLOOR_PRICE_MIST)]);
  const tenures = txR.moveCall({ target: `${d.usufructPackageId}::ensemble::tenures`, arguments: [txR.pure.u64(1n)] });
  const cap = txR.moveCall({ target: `${d.usufructPackageId}::escrow::rent`, typeArguments: TA(d),
    arguments: [txR.object(escrowId), pay, tenures, clock(txR)] });
  txR.transferObjects([cap], d.usufructuary1.address);
  const r1 = await client.signAndExecuteTransaction({ transaction: txR, signer: kp.usufructuary1, options: { showEffects: true } });
  await client.waitForTransaction({ digest: r1.digest });

  const coins = await client.getCoins({ governor: d.governor.address, limit: 3 });
  const txA = new Transaction();
  txA.setSender(d.governor.address);
  if (coins.data.length) txA.setGasPayment(coins.data.map(c => ({ objectId: c.coinObjectId, version: c.version, digest: c.digest })));
  txA.moveCall({ target: `${d.usufructPackageId}::escrow::apply_pending_transition_states`, typeArguments: TA(d),
    arguments: [txA.object(escrowId), clock(txA)] });
  const r2 = await client.signAndExecuteTransaction({ transaction: txA, signer: kp.governor, options: { showEffects: true } });
  await client.waitForTransaction({ digest: r2.digest });
}

async function refsAt(client: SuiClient, addr: string, typeFrag: string, limit: number): Promise<Ref[]> {
  const out: Ref[] = [];
  let cursor: string | null | undefined = undefined;
  while (out.length < limit) {
    const page = await client.getOwnedObjects({ governor: addr, cursor, options: { showType: true }, limit: 50 });
    for (const o of page.data) {
      if ((o.data?.type ?? '').includes(typeFrag)) {
        out.push({ objectId: o.data!.objectId, version: o.data!.version, digest: o.data!.digest });
        if (out.length >= limit) break;
      }
    }
    if (!page.hasNextPage || !page.nextCursor) break;
    cursor = page.nextCursor;
  }
  return out;
}

async function collectFee(client: SuiClient, kp: any, d: D, ref: Ref, label: string): Promise<any> {
  const recvType = `0x2::transfer::Receiving<${d.usufructPackageId}::fee_message::FeeMessage<${SUI}>>`;
  const tx = new Transaction();
  tx.setSender(d.governor.address);
  const ticket = tx.receivingRef(ref);
  const vec    = tx.makeMoveVec({ type: recvType, elements: [ticket] });
  const coin   = tx.moveCall({ target: `${d.usufructPackageId}::fee_inbox::collect_fee_messages`, typeArguments: [SUI],
    arguments: [tx.object(d.protocolFeeInboxId), vec] });
  tx.transferObjects([coin], d.governor.address);
  return measure(client, kp.governor, label, 0, tx);
}

async function collectEarn(client: SuiClient, kp: any, d: D, inboxId: string, ref: Ref, label: string): Promise<any> {
  const recvType = `0x2::transfer::Receiving<${d.usufructPackageId}::earnings_message::EarningsMessage<${SUI}>>`;
  const tx = new Transaction();
  tx.setSender(d.governor.address);
  const ticket = tx.receivingRef(ref);
  const vec    = tx.makeMoveVec({ type: recvType, elements: [ticket] });
  const coin   = tx.moveCall({ target: `${d.usufructPackageId}::earnings::collect_earnings_messages`, typeArguments: [SUI],
    arguments: [tx.object(inboxId), vec] });
  tx.transferObjects([coin], d.governor.address);
  return measure(client, kp.governor, label, 0, tx);
}

async function main() {
  const d = loadDeployment();
  const client = makeClient();
  const kp = loadKeypairs(d);
  const n = (x: bigint) => Number(x).toLocaleString('en-US');

  // ── PART 1: integrate one escrow with a fresh earnings inbox ──
  console.log('Part 1: integrate + 1 rent/apply → 1 fee msg + 1 earnings msg (same instant)');
  const tx1 = new Transaction();
  tx1.setSender(d.governor.address);
  const { governanceCap, inbox } = buildIntegrate(tx1, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId, build1ms);
  tx1.transferObjects([governanceCap, inbox], d.governor.address);
  const ri = await client.signAndExecuteTransaction({ transaction: tx1, signer: kp.governor, options: { showEffects: true, showObjectChanges: true } });
  await client.waitForTransaction({ digest: ri.digest });
  const ch = ri.objectChanges ?? [];
  const escrowId = (ch.find(c => c.type === 'created' && (c as any).objectType?.includes('::escrow::Escrow')) as any).objectId;
  const inboxId  = (ch.find(c => c.type === 'created' && (c as any).objectType?.includes('EarningsInbox')) as any).objectId;

  await rentAndApply(client, kp, d, escrowId);
  await new Promise(r => setTimeout(r, 800));

  const feeRef  = (await refsAt(client, d.protocolFeeInboxId, 'fee_message::FeeMessage', 1))[0];
  const earnRef = (await refsAt(client, inboxId,              'earnings_message::EarningsMessage', 1))[0];
  if (!feeRef || !earnRef) throw new Error(`missing refs: fee=${!!feeRef} earn=${!!earnRef}`);

  const recFee1  = await collectFee(client, kp, d, feeRef, 'collect_fee_1');
  const recEarn1 = await collectEarn(client, kp, d, inboxId, earnRef, 'collect_earn_1');

  // ── PART 2: accumulate RESIDUALS earnings msgs in the SAME fresh inbox, collect 1-of-many twice ──
  console.log(`Part 2: accumulate ${RESIDUALS} earnings msgs in the same inbox, collect 1-of-many (×2 for determinism)`);
  for (let i = 0; i < RESIDUALS; i++) { await rentAndApply(client, kp, d, escrowId); process.stdout.write('.'); }
  console.log('');
  await new Promise(r => setTimeout(r, 800));

  const many = await refsAt(client, inboxId, 'earnings_message::EarningsMessage', RESIDUALS);
  if (many.length < RESIDUALS) throw new Error(`expected ≥${RESIDUALS} earnings msgs, found ${many.length}`);
  const recEarnAmid  = await collectEarn(client, kp, d, inboxId, many[0], `collect_earn_1of${RESIDUALS}`);
  const recEarnAmid2 = await collectEarn(client, kp, d, inboxId, many[1], `collect_earn_1of${RESIDUALS - 1}`); // control: same state −1

  // ── Verdict ──
  const row = (lbl: string, r: any) =>
    `${lbl.padEnd(30)} comp=${n(r.computation).padStart(11)}  store=${n(r.storage).padStart(11)}  rebate=${n(r.rebate).padStart(11)}  net=${n(r.net).padStart(11)}`;
  console.log('\n═══ VERIFICATION (breakdown, MIST) ═══');
  console.log(row('fee  1-of-many (populated)', recFee1));
  console.log(row('earn 1-of-1 (emptied inbox)', recEarn1));
  console.log(row(`earn 1-of-${RESIDUALS} (amid residual)`, recEarnAmid));
  console.log(row(`earn 1-of-${RESIDUALS - 1} (control, same)`, recEarnAmid2));
  console.log('');
  console.log(`Δnet residual (1of${RESIDUALS} − 1of1) = ${n(recEarnAmid.net - recEarn1.net)} MIST`);
  console.log(`  ↳ from computation: ${n(recEarnAmid.computation - recEarn1.computation)}`);
  console.log(`  ↳ from storage:     ${n(recEarnAmid.storage - recEarn1.storage)}`);
  console.log(`  ↳ from rebate:      ${n(recEarnAmid.rebate - recEarn1.rebate)}  (less rebate ⇒ higher net)`);
  console.log(`Δnet control (1of${RESIDUALS} − 1of${RESIDUALS - 1}) = ${n(recEarnAmid.net - recEarnAmid2.net)} MIST  (≈0 ⇒ deterministic per state)`);
}

main().catch(e => { console.error(e); process.exit(1); });
