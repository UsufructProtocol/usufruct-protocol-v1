#!/usr/bin/env tsx
/**
 * Phase A / 01 — integrate
 * Measures: escrow::integrate (creates Escrow + GovernanceCap + EarningsInbox from a
 *           fresh DummyAsset — inbox-first model mints the cap+inbox pair, +3 obj).
 * Precondition: none
 */

import { writeFileSync }  from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath }  from 'url';
import { Transaction }    from '@mysten/sui/transactions';
import {
  loadDeployment, loadKeypairs, makeClient, RUNS,
} from '../env.ts';
import { measure, saveRecords, median } from '../measure.ts';
import { buildIntegrate } from '../builders.ts';

const DIR = dirname(fileURLToPath(import.meta.url));

async function main() {
  const d      = loadDeployment();
  const client = makeClient();
  const kp     = loadKeypairs(d);

  const records = [];
  for (let run = 0; run < RUNS; run++) {
    process.stdout.write(`  run ${run + 1}/${RUNS}...`);

    const tx = new Transaction();
    tx.setSender(d.governor.address);

    const { governanceCap, inbox } = buildIntegrate(tx, d.usufructPackageId, d.dummyAssetPackageId, d.protocolFeeRefId);
    tx.transferObjects([governanceCap, inbox], d.governor.address);

    const rec = await measure(client, kp.governor, 'integrate', run, tx);
    records.push(rec);
    console.log(` net=${rec.net} MIST  +${rec.objectsCreated}obj`);
  }

  const med = median(records);
  console.log(`\nMedian net: ${med.net} MIST`);

  saveRecords(resolve(DIR, '../results/a_01_integrate.json'), records);
}

main().catch(e => { console.error(e); process.exit(1); });
