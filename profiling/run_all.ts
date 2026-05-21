#!/usr/bin/env tsx
/**
 * Runs all profiling scripts in sequence.
 * Usage:
 *   tsx run_all.ts           — runs both phases
 *   tsx run_all.ts --phase=a — Phase A only
 *   tsx run_all.ts --phase=b — Phase B only
 */

import { execSync } from 'child_process';
import { dirname, resolve } from 'path';
import { fileURLToPath } from 'url';

const DIR   = dirname(fileURLToPath(import.meta.url));
const phase = process.argv.find(a => a.startsWith('--phase='))?.split('=')[1];

const A_SCRIPTS = [
  'a_atomic/01_integrate.ts',
  'a_atomic/02_rent.ts',
  'a_atomic/02b_rent_multi_tenure.ts 1',
  'a_atomic/02b_rent_multi_tenure.ts 10',
  'a_atomic/02b_rent_multi_tenure.ts 100',
  'a_atomic/03_borrow_return.ts',
  'a_atomic/04_soft_burn.ts',
  'a_atomic/05_hard_burn.ts',
  'a_atomic/06_apply_transitions.ts',
  'a_atomic/07_retire.ts',
  'a_atomic/08_claim_asset.ts',
  'a_atomic/09_withdraw_earnings.ts',
  'a_atomic/10_extend_commitment.ts',
  'a_atomic/11_update_config.ts',
  'a_atomic/12_collect_fee_messages.ts',
];

const B_SCRIPTS = [
  'b_flows/01_minimal.ts',
  'b_flows/02_asset_lifecycle.ts',
  'b_flows/03_handover.ts',
  'b_flows/04_sequential_rents.ts 3',
  'b_flows/04_sequential_rents.ts 5',
  'b_flows/04_sequential_rents.ts 10',
  'b_flows/05_earnings.ts',
];

const toRun = [
  ...(phase !== 'b' ? A_SCRIPTS : []),
  ...(phase !== 'a' ? B_SCRIPTS : []),
];

console.log(`Running ${toRun.length} scripts...\n`);

for (const script of toRun) {
  const [file, ...args] = script.split(' ');
  const label = script.replace('a_atomic/', '').replace('b_flows/', '');
  console.log(`\n${'─'.repeat(60)}`);
  console.log(`▶ ${label}`);
  console.log('─'.repeat(60));
  try {
    execSync(`npx tsx ${resolve(DIR, file)} ${args.join(' ')}`, {
      stdio: 'inherit',
      cwd: DIR,
    });
  } catch (e) {
    console.error(`\n✗ ${label} FAILED`);
    process.exit(1);
  }
}

console.log(`\n${'─'.repeat(60)}`);
console.log('All scripts done. Run `npm run report` to see results.');
