#!/usr/bin/env tsx
/**
 * Reads all results/*.json files and prints a summary table + writes results/report.csv.
 */

import { readdirSync, readFileSync, writeFileSync, existsSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const DIR         = dirname(fileURLToPath(import.meta.url));
const RESULTS_DIR = resolve(DIR, 'results');

interface RawRecord {
  op: string; run: number;
  computation: string; storage: string; rebate: string;
  nonRefundable: string; net: string;
  objectsCreated: number; objectsDeleted: number;
  digest: string;
}

function toMist(s: string): bigint { return BigInt(s); }

function median(values: bigint[]): bigint {
  const sorted = [...values].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  return sorted[Math.floor(sorted.length / 2)];
}

function formatMist(v: bigint): string {
  return v.toLocaleString('en-US').padStart(14);
}

function formatNum(n: number): string {
  return String(n).padStart(5);
}

type Summary = {
  file: string;
  op: string;
  runs: number;
  medComputation: bigint;
  medStorage: bigint;
  medRebate: bigint;
  medNet: bigint;
  medCreated: number;
  medDeleted: number;
  isFlow: boolean;
};

async function main() {
  if (!existsSync(RESULTS_DIR)) {
    console.error('No results/ directory found. Run profiling scripts first.');
    process.exit(1);
  }

  const files = readdirSync(RESULTS_DIR)
    .filter(f => f.endsWith('.json') && f !== '.gitkeep')
    .sort();

  if (files.length === 0) {
    console.log('No result files found. Run `npm run a` or `npm run b` first.');
    return;
  }

  const summaries: Summary[] = [];

  const scalabilityFiles: { file: string; records: any[] }[] = [];

  for (const file of files) {
    const raw: RawRecord[] = JSON.parse(readFileSync(resolve(RESULTS_DIR, file), 'utf8'));
    // Skip files with custom (non-GasRecord) format
    if (!raw[0] || raw[0].computation === undefined) {
      scalabilityFiles.push({ file, records: raw });
      continue;
    }
    const isFlow = file.startsWith('b_');

    if (isFlow) {
      // Flow files: each record is one step — report each step individually
      for (const r of raw) {
        summaries.push({
          file,
          op:           `${file.replace('.json', '')} / ${r.op}`,
          runs:         1,
          medComputation: toMist(r.computation),
          medStorage:   toMist(r.storage),
          medRebate:    toMist(r.rebate),
          medNet:       toMist(r.net),
          medCreated:   r.objectsCreated,
          medDeleted:   r.objectsDeleted,
          isFlow:       true,
        });
      }
    } else {
      // Atomic files: multiple runs of the same op — report median
      const computation = raw.map(r => toMist(r.computation));
      const storage     = raw.map(r => toMist(r.storage));
      const rebate      = raw.map(r => toMist(r.rebate));
      const net         = raw.map(r => toMist(r.net));
      const created     = raw.map(r => r.objectsCreated);
      const deleted     = raw.map(r => r.objectsDeleted);

      summaries.push({
        file,
        op:             raw[0].op,
        runs:           raw.length,
        medComputation: median(computation),
        medStorage:     median(storage),
        medRebate:      median(rebate),
        medNet:         median(net),
        medCreated:     created.sort()[Math.floor(created.length / 2)],
        medDeleted:     deleted.sort()[Math.floor(deleted.length / 2)],
        isFlow:         false,
      });
    }
  }

  // ── Phase A table ─────────────────────────────────────────────────────────
  const atomics = summaries.filter(s => !s.isFlow);
  if (atomics.length > 0) {
    console.log('\n=== PHASE A: Atomic Operations (median of N runs) ===\n');
    console.log(
      'Operation'.padEnd(30) +
      'Compute (MIST)'.padStart(16) +
      'Storage (MIST)'.padStart(16) +
      'Rebate (MIST)'.padStart(15) +
      'Net (MIST)'.padStart(14) +
      '+Obj'.padStart(6) +
      '-Obj'.padStart(6),
    );
    console.log('─'.repeat(103));
    for (const s of atomics) {
      console.log(
        s.op.padEnd(30) +
        formatMist(s.medComputation) +
        formatMist(s.medStorage) +
        formatMist(s.medRebate).padStart(15) +
        formatMist(s.medNet) +
        formatNum(s.medCreated) +
        formatNum(s.medDeleted),
      );
    }
  }

  // ── Phase B table ─────────────────────────────────────────────────────────
  const flows = summaries.filter(s => s.isFlow);
  if (flows.length > 0) {
    console.log('\n=== PHASE B: Flow Steps ===\n');

    let currentFile = '';
    for (const s of flows) {
      if (s.file !== currentFile) {
        currentFile = s.file;
        const flowName = s.file.replace('.json', '');
        const totalNet = flows
          .filter(f => f.file === currentFile)
          .reduce((acc, f) => acc + f.medNet, 0n);
        console.log(`\n── ${flowName}  (total net: ${totalNet.toLocaleString()} MIST) ──`);
      }
      const step = s.op.split(' / ')[1];
      console.log(
        `  ${step.padEnd(26)} net=${formatMist(s.medNet).trim().padStart(12)} MIST` +
        `  +${s.medCreated} -${s.medDeleted}`,
      );
    }
  }

  // ── Scalability tables ────────────────────────────────────────────────────
  // Two custom shapes coexist:
  //   message-collect (a_12 / a_16): { n, totalNet, perMessage, numCalls }
  //   governance      (a_18):        { n, *Separate, *Batched per-retire }
  if (scalabilityFiles.length > 0) {
    for (const { file, records } of scalabilityFiles) {
      if (!records[0]) continue;
      console.log(`\n=== ${file.replace('.json', '')} (scalability) ===\n`);

      if (records[0].perRetireSeparate !== undefined) {
        // Governance: one cap over N escrows, separate vs batched.
        console.log('N'.padEnd(8) + 'per-retire separate'.padStart(24) + 'per-retire batched'.padStart(22));
        console.log('─'.repeat(54));
        for (const r of records) {
          console.log(
            String(r.n).padEnd(8) +
            `${BigInt(r.perRetireSeparate).toLocaleString('en-US')} MIST`.padStart(24) +
            `${BigInt(r.perRetireBatched).toLocaleString('en-US')} MIST`.padStart(22),
          );
        }
      } else {
        // Message-collect: total + per-message + PTB calls.
        console.log('N'.padEnd(8) + 'Total net (MIST)'.padStart(20) + 'Per msg (MIST)'.padStart(18) + 'PTB calls'.padStart(12));
        console.log('─'.repeat(58));
        for (const r of records) {
          console.log(
            String(r.n).padEnd(8) +
            BigInt(r.totalNet).toLocaleString('en-US').padStart(20) +
            BigInt(r.perMessage).toLocaleString('en-US').padStart(18) +
            String(r.numCalls).padStart(12),
          );
        }
      }
    }
  }

  // ── CSV ────────────────────────────────────────────────────────────────────
  const csv = [
    'file,op,runs,computation,storage,rebate,net,created,deleted',
    ...summaries.map(s =>
      [s.file, s.op, s.runs, s.medComputation, s.medStorage, s.medRebate, s.medNet, s.medCreated, s.medDeleted].join(','),
    ),
  ].join('\n');

  writeFileSync(resolve(RESULTS_DIR, 'report.csv'), csv);
  console.log('\n\nreport.csv written to results/');
}

main().catch(e => { console.error(e); process.exit(1); });
