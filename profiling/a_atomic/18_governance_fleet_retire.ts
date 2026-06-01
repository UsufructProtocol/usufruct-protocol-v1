#!/usr/bin/env tsx
/**
 * Phase A / 18 — governance over a fleet: one GovernanceCap retires N escrows
 *
 * Tests the core claim of the pure-governance-token model: a single GovernanceCap
 * governing N escrows costs the same per-escrow as one-cap-per-escrow, because
 * the cap is a by-reference token validated SEAT-SIDE
 * (governance_cap::identity(cap) == seat.cap_identity) — no registry, no cross-escrow
 * coupling, no per-N state. Governance is linear and topology-independent.
 *
 * Setup (one-to-many): integrate once (mint the cap+inbox pair) →
 *   integrate_into_portfolio ×(2N−1), so 2N escrows sit under the SAME single cap.
 *   Immediate retire commitment ⇒ retire is callable straight from Idle.
 *   Two disjoint sub-fleets of N each (retire consumes an escrow's retirability,
 *   so the separate and batched modes need distinct escrows).
 *
 * Measured two ways, both with the SAME &GovernanceCap:
 *   (1) N separate PTBs — retire(escrow_i, &cap) each. Per-call net must be flat
 *       in N and ≈ the one-to-one baseline from 07_retire.ts.
 *   (2) One PTB, N retires — N retire move-calls sharing one cap object reference.
 *       Shows the O(1) PTB overhead amortized across the batch.
 *
 * Control: compare perRetireSeparate to 07_retire.ts (one-to-one, distinct cap per
 * escrow). Equality ⇒ the shared cap introduces zero overhead.
 *
 * Usage:
 *   tsx a_atomic/18_governance_fleet_retire.ts          # up to N=50
 *   tsx a_atomic/18_governance_fleet_retire.ts 100      # up to N=100
 */

import { writeFileSync }    from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath }    from 'url';
import { Transaction }      from '@mysten/sui/transactions';
import { SuiClient }        from '@mysten/sui/client';
import {
  loadDeployment, loadKeypairs, makeClient,
} from '../env.ts';
import { measure } from '../measure.ts';
import { buildIntegrate, buildIntegrateIntoPortfolio, clock } from '../builders.ts';

const DIR = dirname(fileURLToPath(import.meta.url));

const N_MAX    = parseInt(process.argv[2] ?? '50', 10);
const N_VALUES = [1, 10, 50, 100].filter(n => n <= N_MAX);

type D  = ReturnType<typeof loadDeployment>;
type KP = ReturnType<typeof loadKeypairs>;

const SUI = '0x2::sui::SUI';
const TA  = (d: D) => [`${d.dummyAssetPackageId}::dummy_asset::DummyAsset`, SUI];

// ── Build a portfolio of `total` Idle escrows under ONE cap. ──────────────────
async function generatePortfolio(
  client: SuiClient, kp: KP, d: D, total: number,
): Promise<{ escrows: string[]; governanceCapId: string }> {
  console.log(`  Setup: 1 integrate + ${total - 1} integrate_into_portfolio (one shared cap)`);
  const escrows: string[] = [];
  let governanceCapId = '';
  let inboxId    = '';

  process.stdout.write(`  integrate: `);
  for (let i = 0; i < total; i++) {
    const tx = new Transaction();
    tx.setSender(d.governor.address);
    if (i === 0) {
      const { governanceCap, inbox } = buildIntegrate(tx, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId);
      tx.transferObjects([governanceCap, inbox], d.governor.address);
    } else {
      buildIntegrateIntoPortfolio(tx, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId, governanceCapId, inboxId);
    }
    const r = await client.signAndExecuteTransaction({
      transaction: tx, signer: kp.governor, options: { showEffects: true, showObjectChanges: true },
    });
    await client.waitForTransaction({ digest: r.digest });
    if (r.effects?.status.status !== 'success') throw new Error(`integrate ${i} failed`);
    const changes = r.objectChanges ?? [];
    escrows.push((changes.find(c => c.type === 'created' && (c as any).objectType?.includes('::escrow::Escrow')) as any).objectId);
    if (i === 0) {
      governanceCapId = (changes.find(c => c.type === 'created' && (c as any).objectType?.includes('GovernanceCap')) as any).objectId;
      inboxId    = (changes.find(c => c.type === 'created' && (c as any).objectType?.includes('EarningsInbox')) as any).objectId;
    }
    if ((i + 1) % 10 === 0) process.stdout.write(`${i + 1}`); else process.stdout.write('.');
  }
  console.log(` ✓  cap=${governanceCapId.slice(0, 10)}…`);
  return { escrows, governanceCapId };
}

async function main() {
  const d      = loadDeployment();
  const client = makeClient();
  const kp     = loadKeypairs(d);

  console.log(`governance_fleet_retire — one GovernanceCap over N escrows`);
  console.log(`N_max=${N_MAX}  values=[${N_VALUES.join(', ')}]\n`);

  const results: any[] = [];
  for (const n of N_VALUES) {
    console.log(`\n─── N = ${n} ───`);
    const { escrows, governanceCapId } = await generatePortfolio(client, kp, d, 2 * n);
    const sep   = escrows.slice(0, n);
    const batch = escrows.slice(n, 2 * n);

    // (1) N separate PTBs, same cap reference.
    let totalNetSeparate = 0n;
    process.stdout.write(`  separate retire: `);
    for (let i = 0; i < n; i++) {
      const tx = new Transaction();
      tx.setSender(d.governor.address);
      tx.moveCall({ target: `${d.usufructPackageId}::escrow::retire`, typeArguments: TA(d),
        arguments: [tx.object(sep[i]), tx.object(governanceCapId), clock(tx)] });
      const rec = await measure(client, kp.governor, `retire_sep_${n}_${i}`, i, tx);
      totalNetSeparate += rec.net;
      if ((i + 1) % 10 === 0) process.stdout.write(`${i + 1}`); else process.stdout.write('.');
    }
    console.log(` ✓`);

    // (2) One PTB, N retires, same cap reference.
    const txB = new Transaction();
    txB.setSender(d.governor.address);
    for (let i = 0; i < n; i++) {
      txB.moveCall({ target: `${d.usufructPackageId}::escrow::retire`, typeArguments: TA(d),
        arguments: [txB.object(batch[i]), txB.object(governanceCapId), clock(txB)] });
    }
    const recB = await measure(client, kp.governor, `retire_batch_${n}`, 0, txB);
    const totalNetBatched = recB.net;

    const perRetireSeparate = totalNetSeparate / BigInt(n);
    const perRetireBatched  = totalNetBatched  / BigInt(n);
    console.log(`  separate: total=${totalNetSeparate.toLocaleString()}  per=${perRetireSeparate.toLocaleString()} MIST`);
    console.log(`  batched:  total=${totalNetBatched.toLocaleString()}  per=${perRetireBatched.toLocaleString()} MIST`);

    results.push({
      n,
      totalNetSeparate: totalNetSeparate.toString(),
      perRetireSeparate: perRetireSeparate.toString(),
      totalNetBatched: totalNetBatched.toString(),
      perRetireBatched: perRetireBatched.toString(),
    });
  }

  console.log('\n═══ Governance scalability (one cap, N escrows) ═══');
  console.log('N'.padEnd(6) + 'per-retire separate'.padEnd(24) + 'per-retire batched');
  console.log('─'.repeat(54));
  for (const r of results) {
    console.log(
      String(r.n).padEnd(6) +
      `${BigInt(r.perRetireSeparate).toLocaleString()} MIST`.padEnd(24) +
      `${BigInt(r.perRetireBatched).toLocaleString()} MIST`,
    );
  }

  writeFileSync(resolve(DIR, '../results/a_18_governance_fleet_retire.json'), JSON.stringify(results, null, 2));
}

main().catch(e => { console.error(e); process.exit(1); });
