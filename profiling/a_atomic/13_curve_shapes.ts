#!/usr/bin/env tsx
/**
 * Phase A / 13 — curve shape gas cost
 *
 * Measures borrow_asset + return_asset with 10 CurveShapePolicy variants as
 * creditShape. Uses a 60s tenure with a 2s sleep after rent so t > 0 at
 * measure time, ensuring compute_curve_height runs the variant-specific branch
 * and does not short-circuit to 0.
 *
 * Variants:
 *   linear (baseline), smoothstep,
 *   power_law(2/1), power_law(8/1), power_law(3/2), power_law(8/3),
 *   exp(1, pos), exp(8, pos), exp(8, neg),
 *   logistic
 *
 * Output: results/a_13_<variant>.json per variant (standard GasRecord[])
 *         Inline comparison table with Δ vs. linear.
 *
 * Runtime: ~7 min (10 variants × 10 runs × ~4 s/run).
 *          Run standalone: npx tsx a_atomic/13_curve_shapes.ts
 */

import { existsSync, mkdirSync } from 'fs';
import { resolve, dirname }       from 'path';
import { fileURLToPath }          from 'url';
import { Transaction }            from '@mysten/sui/transactions';
import type { TransactionArgument } from '@mysten/sui/transactions';
import { SuiClient }              from '@mysten/sui/client';
import { Ed25519Keypair }         from '@mysten/sui/keypairs/ed25519';
import {
  loadDeployment, loadKeypairs, makeClient, RUNS,
  FLOOR_PRICE_MIST, DELTA_PRICE_MIST,
} from '../env.ts';
import { measure, saveRecords, median, execSetup } from '../measure.ts';
import { clock } from '../builders.ts';

const DIR         = dirname(fileURLToPath(import.meta.url));
const RESULTS_DIR = resolve(DIR, '../results');

// Short tenure so we don't wait 1 hour; sleep puts t/t_max ≈ 0.5 at measure time.
const CURVE_TENURE_MS     = 60_000n; // 60s — ample margin over setup time (~3s) + sleep
const SLEEP_AFTER_RENT_MS = 2_000;   // 2s is enough to advance past t=0 and run curve math

type CurveBuilder = (tx: Transaction, pkg: string) => TransactionArgument;

function buildCurveEnsemble(
  tx:         Transaction,
  pkg:        string,
  buildCurve: CurveBuilder,
): TransactionArgument {
  const p = (mist: bigint) =>
    tx.moveCall({ target: `${pkg}::ensemble::price`,    arguments: [tx.pure.u64(mist)] });
  const d = (ms: bigint) =>
    tx.moveCall({ target: `${pkg}::ensemble::duration`,   arguments: [tx.pure.u64(ms)] });

  const restPrice      = tx.moveCall({ target: `${pkg}::ensemble::new_rest_price_fixed`,          arguments: [p(FLOOR_PRICE_MIST)] });
  const tenureDuration = tx.moveCall({ target: `${pkg}::ensemble::new_tenure_duration_fixed`,     arguments: [d(CURVE_TENURE_MS)] });
  const tenureExtend   = tx.moveCall({ target: `${pkg}::ensemble::new_tenure_multi` });
  const handover       = tx.moveCall({ target: `${pkg}::ensemble::new_handover_off` });
  const auctionWin     = tx.moveCall({ target: `${pkg}::ensemble::new_descent_off` });
  const creditShape    = buildCurve(tx, pkg);
  const auctionShape   = tx.moveCall({ target: `${pkg}::ensemble::new_linear` });
  const escalation     = tx.moveCall({ target: `${pkg}::ensemble::new_price_fixed_delta`, arguments: [p(DELTA_PRICE_MIST)] });

  return tx.moveCall({
    target: `${pkg}::ensemble::new_ensemble`,
    arguments: [restPrice, tenureDuration, tenureExtend, handover, auctionWin, creditShape, auctionShape, escalation],
  });
}

const VARIANTS: { label: string; slug: string; buildCurve: CurveBuilder }[] = [
  {
    label: 'linear',
    slug:  'linear',
    buildCurve: (tx, pkg) =>
      tx.moveCall({ target: `${pkg}::ensemble::new_linear` }),
  },
  {
    label: 'smoothstep',
    slug:  'smoothstep',
    buildCurve: (tx, pkg) =>
      tx.moveCall({ target: `${pkg}::ensemble::new_smoothstep` }),
  },
  {
    label: 'power_law(2/1)',
    slug:  'power_law_2_1',
    buildCurve: (tx, pkg) =>
      tx.moveCall({
        target:    `${pkg}::ensemble::new_power_law`,
        arguments: [tx.pure.u8(2), tx.pure.u8(1)],
      }),
  },
  {
    label: 'power_law(8/1)',
    slug:  'power_law_8_1',
    buildCurve: (tx, pkg) =>
      tx.moveCall({
        target:    `${pkg}::ensemble::new_power_law`,
        arguments: [tx.pure.u8(8), tx.pure.u8(1)],
      }),
  },
  {
    label: 'power_law(3/2)',
    slug:  'power_law_3_2',
    buildCurve: (tx, pkg) =>
      tx.moveCall({
        target:    `${pkg}::ensemble::new_power_law`,
        arguments: [tx.pure.u8(3), tx.pure.u8(2)],
      }),
  },
  {
    label: 'power_law(8/3)',
    slug:  'power_law_8_3',
    buildCurve: (tx, pkg) =>
      tx.moveCall({
        target:    `${pkg}::ensemble::new_power_law`,
        arguments: [tx.pure.u8(8), tx.pure.u8(3)],
      }),
  },
  {
    label: 'exp(1, pos)',
    slug:  'exp_1_pos',
    buildCurve: (tx, pkg) =>
      tx.moveCall({
        target:    `${pkg}::ensemble::new_exponential`,
        arguments: [tx.pure.u8(1), tx.pure.bool(false)],
      }),
  },
  {
    label: 'exp(8, pos)',
    slug:  'exp_8_pos',
    buildCurve: (tx, pkg) =>
      tx.moveCall({
        target:    `${pkg}::ensemble::new_exponential`,
        arguments: [tx.pure.u8(8), tx.pure.bool(false)],
      }),
  },
  {
    label: 'exp(8, neg)',
    slug:  'exp_8_neg',
    buildCurve: (tx, pkg) =>
      tx.moveCall({
        target:    `${pkg}::ensemble::new_exponential`,
        arguments: [tx.pure.u8(8), tx.pure.bool(true)],
      }),
  },
  {
    label: 'logistic',
    slug:  'logistic',
    buildCurve: (tx, pkg) =>
      tx.moveCall({ target: `${pkg}::ensemble::new_logistic` }),
  },
];

async function setupOccupiedEscrow(
  client:     SuiClient,
  owner:      Ed25519Keypair,
  tenant1:    Ed25519Keypair,
  d:          ReturnType<typeof loadDeployment>,
  buildCurve: CurveBuilder,
): Promise<{ escrowId: string; tenantCapId: string }> {
  const ta = [`${d.dummyAssetPackageId}::dummy_asset::DummyAsset`, '0x2::sui::SUI'];

  // Step 1: integrate with the target curve shape
  const tx1 = new Transaction();
  tx1.setSender(d.owner.address);
  const asset      = tx1.moveCall({ target: `${d.dummyAssetPackageId}::dummy_asset::mint` });
  const ensemble   = buildCurveEnsemble(tx1, d.usufructPackageId, buildCurve);
  const commitment = tx1.moveCall({ target: `${d.usufructPackageId}::ensemble::new_commitment_immediate` });
  const ownerCap   = tx1.moveCall({
    target:        `${d.usufructPackageId}::escrow::integrate`,
    typeArguments: ta,
    arguments:     [asset, ensemble, commitment, tx1.object(d.protocolFeeRefId), clock(tx1)],
  });
  tx1.transferObjects([ownerCap], d.owner.address);
  const r1 = await execSetup(client, owner, tx1);

  const escrowObj = r1.objectChanges?.find(
    c => c.type === 'created' && (c as any).objectType?.includes('Escrow'),
  );
  if (!escrowObj) throw new Error('setup: Escrow not found');
  const escrowId = (escrowObj as any).objectId;

  // Step 2: rent (1 tenure)
  const tx2 = new Transaction();
  tx2.setSender(d.tenant1.address);
  const [payment] = tx2.splitCoins(tx2.gas, [tx2.pure.u64(FLOOR_PRICE_MIST)]);
  const tenures    = tx2.moveCall({
    target:    `${d.usufructPackageId}::ensemble::tenures`,
    arguments: [tx2.pure.u64(1n)],
  });
  const tenantCap = tx2.moveCall({
    target:        `${d.usufructPackageId}::escrow::rent`,
    typeArguments: ta,
    arguments:     [tx2.object(escrowId), payment, tenures, clock(tx2)],
  });
  tx2.transferObjects([tenantCap], d.tenant1.address);
  const r2 = await execSetup(client, tenant1, tx2);

  const capObj = r2.objectChanges?.find(
    c => c.type === 'created' && (c as any).objectType?.includes('TenantCap'),
  );
  if (!capObj) throw new Error('setup: TenantCap not found');

  return { escrowId, tenantCapId: (capObj as any).objectId };
}

async function main() {
  const d      = loadDeployment();
  const client = makeClient();
  const kp     = loadKeypairs(d);

  if (!existsSync(RESULTS_DIR)) mkdirSync(RESULTS_DIR, { recursive: true });

  const ta = [`${d.dummyAssetPackageId}::dummy_asset::DummyAsset`, '0x2::sui::SUI'];

  const variantMedians: { label: string; net: bigint }[] = [];

  for (const { label, slug, buildCurve } of VARIANTS) {
    console.log(`\n${'─'.repeat(60)}`);
    console.log(`▶ borrow_return  creditShape = ${label}`);
    console.log('─'.repeat(60));

    const records = [];
    for (let run = 0; run < RUNS; run++) {
      if (run > 0) await new Promise(r => setTimeout(r, 1_000));
      process.stdout.write(`  run ${run + 1}/${RUNS} setup...`);
      const { escrowId, tenantCapId } = await setupOccupiedEscrow(
        client, kp.owner, kp.tenant1, d, buildCurve,
      );

      // Sleep so the on-chain clock advances to t ≈ t_max/2 before borrow_return.
      process.stdout.write(` sleeping ${SLEEP_AFTER_RENT_MS / 1_000}s...`);
      await new Promise(r => setTimeout(r, SLEEP_AFTER_RENT_MS));

      process.stdout.write(' measuring...');
      const tx = new Transaction();
      tx.setSender(d.tenant1.address);
      const [asset, receipt] = tx.moveCall({
        target:        `${d.usufructPackageId}::escrow::borrow_asset`,
        typeArguments: ta,
        arguments:     [tx.object(escrowId), tx.object(tenantCapId), clock(tx)],
      }) as any[];
      tx.moveCall({
        target:        `${d.usufructPackageId}::escrow::return_asset`,
        typeArguments: ta,
        arguments:     [tx.object(escrowId), asset, receipt],
      });

      const rec = await measure(client, kp.tenant1, `borrow_return[${label}]`, run, tx);
      records.push(rec);
      console.log(` net=${rec.net} MIST`);
    }

    const med = median(records);
    console.log(`\nMedian net: ${med.net} MIST`);
    variantMedians.push({ label, net: med.net });
    saveRecords(resolve(RESULTS_DIR, `a_13_${slug}.json`), records);
  }

  // ── Comparison table ───────────────────────────────────────────────────────
  const baseline = variantMedians.find(v => v.label === 'linear')!.net;

  console.log(`\n${'═'.repeat(58)}`);
  console.log('CURVE SHAPE GAS  (borrow_return at t ≈ t_max/2)');
  console.log(`tenure=${CURVE_TENURE_MS}ms  sleep=${SLEEP_AFTER_RENT_MS}ms  runs=${RUNS}`);
  console.log('═'.repeat(58));
  console.log('Variant'.padEnd(20) + 'Net (MIST)'.padStart(16) + 'Δ vs linear'.padStart(14));
  console.log('─'.repeat(50));
  for (const { label, net } of variantMedians) {
    const delta = net - baseline;
    const sign  = delta >= 0n ? '+' : '';
    console.log(
      label.padEnd(20) +
      net.toLocaleString('en-US').padStart(16) +
      `${sign}${delta.toLocaleString('en-US')}`.padStart(14),
    );
  }
  console.log('─'.repeat(50));
}

main().catch(e => { console.error(e); process.exit(1); });
