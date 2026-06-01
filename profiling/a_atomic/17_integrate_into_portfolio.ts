#!/usr/bin/env tsx
/**
 * Phase A / 17 — integrate_into_portfolio
 * Measures: escrow::integrate_into_portfolio (joins a fresh DummyAsset to an
 *           EXISTING cap+inbox pair). Mints NO inbox (+2 obj: Escrow + UsufructuarySeat-
 *           less, just the shared Escrow), so it should land ≈ `integrate` minus
 *           one object — the marginal cost of onboarding each additional escrow
 *           into a fleet governed by one GovernanceCap and one EarningsInbox.
 * Precondition: one integrate to obtain the pair (done once; reused across runs).
 */

import { resolve, dirname } from 'path';
import { fileURLToPath }  from 'url';
import { Transaction }    from '@mysten/sui/transactions';
import { SuiClient }      from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import {
  loadDeployment, loadKeypairs, makeClient, RUNS,
} from '../env.ts';
import { measure, saveRecords, median, execSetup } from '../measure.ts';
import { buildIntegrate, buildIntegrateIntoPortfolio } from '../builders.ts';

const DIR = dirname(fileURLToPath(import.meta.url));

async function setupPair(
  client: SuiClient,
  governor: Ed25519Keypair,
  d: ReturnType<typeof loadDeployment>,
): Promise<{ governanceCapId: string; inboxId: string }> {
  const tx = new Transaction();
  tx.setSender(d.governor.address);
  const { governanceCap, inbox } = buildIntegrate(tx, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId);
  tx.transferObjects([governanceCap, inbox], d.governor.address);

  const r = await execSetup(client, governor, tx);
  const changes = r.objectChanges ?? [];
  const governanceCapId = (changes.find(c => c.type === 'created' && (c as any).objectType?.includes('GovernanceCap')) as any).objectId;
  const inboxId    = (changes.find(c => c.type === 'created' && (c as any).objectType?.includes('EarningsInbox')) as any).objectId;
  return { governanceCapId, inboxId };
}

async function main() {
  const d      = loadDeployment();
  const client = makeClient();
  const kp     = loadKeypairs(d);

  process.stdout.write('  setup: integrate (mint pair)...');
  const { governanceCapId, inboxId } = await setupPair(client, kp.governor, d);
  console.log(` cap=${governanceCapId.slice(0, 10)}…  inbox=${inboxId.slice(0, 10)}…`);

  const records = [];
  for (let run = 0; run < RUNS; run++) {
    process.stdout.write(`  run ${run + 1}/${RUNS}...`);

    const tx = new Transaction();
    tx.setSender(d.governor.address);
    buildIntegrateIntoPortfolio(tx, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId, governanceCapId, inboxId);

    const rec = await measure(client, kp.governor, 'integrate_into_portfolio', run, tx);
    records.push(rec);
    console.log(` net=${rec.net} MIST  +${rec.objectsCreated}obj`);
  }

  const med = median(records);
  console.log(`\nMedian net: ${med.net} MIST`);

  saveRecords(resolve(DIR, '../results/a_17_integrate_into_portfolio.json'), records);
}

main().catch(e => { console.error(e); process.exit(1); });
