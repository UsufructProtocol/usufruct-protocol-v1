#!/usr/bin/env tsx
/**
 * Runs all profiling scripts in sequence.
 * Usage:
 *   tsx run_all.ts             — runs both phases
 *   tsx run_all.ts --phase=a   — Phase A only
 *   tsx run_all.ts --phase=b   — Phase B only
 *   tsx run_all.ts --resume    — skip scripts whose result file already exists
 */

import { execSync }            from 'child_process';
import { existsSync }          from 'fs';
import { dirname, resolve }    from 'path';
import { fileURLToPath }       from 'url';

const DIR    = dirname(fileURLToPath(import.meta.url));
const phase  = process.argv.find(a => a.startsWith('--phase='))?.split('=')[1];
const resume = process.argv.includes('--resume');

// Maps each script entry to the sentinel result file it produces last.
// If the file exists and --resume is set, the script is skipped.
const SENTINEL: Record<string, string> = {
  'a_atomic/01_integrate.ts':               'results/a_01_integrate.json',
  'a_atomic/02_rent.ts':                    'results/a_02_rent.json',
  'a_atomic/02b_rent_multi_tenure.ts 1':    'results/a_02b_rent_N1.json',
  'a_atomic/02b_rent_multi_tenure.ts 10':   'results/a_02b_rent_N10.json',
  'a_atomic/02b_rent_multi_tenure.ts 100':  'results/a_02b_rent_N100.json',
  'a_atomic/03_borrow_return.ts':           'results/a_03_borrow_return.json',
  'a_atomic/04_burn_stale.ts':              'results/a_04_burn_stale.json',
  'a_atomic/05_burn.ts':                    'results/a_05_burn.json',
  'a_atomic/06_apply_transitions.ts':       'results/a_06_apply_transitions.json',
  'a_atomic/07_retire.ts':                  'results/a_07_retire.json',
  'a_atomic/08_claim_asset.ts':             'results/a_08_claim_asset.json',
  'a_atomic/10_extend_retire_commitment.ts': 'results/a_10_extend_retire_commitment.json',
  'a_atomic/11_update_ensemble.ts':         'results/a_11_update_ensemble.json',
  'a_atomic/12_collect_fee_messages.ts':    'results/a_12_collect_fee_messages.json',
  'a_atomic/13_curve_shapes.ts':            'results/a_13_logistic.json',
  'a_atomic/14_update_usufructuary_refund_address.ts': 'results/a_14_update_usufructuary_refund_address.json',
  'a_atomic/15_extend_ensemble_commitment.ts': 'results/a_15_extend_ensemble_commitment.json',
  'a_atomic/16_collect_earnings_messages.ts': 'results/a_16_collect_earnings_messages.json',
  'a_atomic/17_integrate_into_portfolio.ts': 'results/a_17_integrate_into_portfolio.json',
  'a_atomic/18_governance_fleet_retire.ts': 'results/a_18_governance_fleet_retire.json',
  'b_flows/01_minimal.ts':                  'results/b_01_minimal.json',
  'b_flows/02_asset_lifecycle.ts':          'results/b_02_asset_lifecycle.json',
  'b_flows/03_handover.ts':                 'results/b_03_handover.json',
  'b_flows/04_sequential_rents.ts 3':       'results/b_04_multi_tenure_N3.json',
  'b_flows/04_sequential_rents.ts 5':       'results/b_04_multi_tenure_N5.json',
  'b_flows/04_sequential_rents.ts 10':      'results/b_04_multi_tenure_N10.json',
  'b_flows/05_earnings.ts':                 'results/b_05_earnings.json',
  'b_flows/06_refund_redirect_then_handover.ts': 'results/b_06_refund_redirect_then_handover.json',
  'b_flows/07_fleet_portfolio_collect.ts':  'results/b_07_fleet_portfolio_collect_N3.json',
};

const A_SCRIPTS = [
  'a_atomic/01_integrate.ts',
  'a_atomic/02_rent.ts',
  'a_atomic/02b_rent_multi_tenure.ts 1',
  'a_atomic/02b_rent_multi_tenure.ts 10',
  'a_atomic/02b_rent_multi_tenure.ts 100',
  'a_atomic/03_borrow_return.ts',
  'a_atomic/04_burn_stale.ts',
  'a_atomic/05_burn.ts',
  'a_atomic/06_apply_transitions.ts',
  'a_atomic/07_retire.ts',
  'a_atomic/08_claim_asset.ts',
  'a_atomic/10_extend_retire_commitment.ts',
  'a_atomic/11_update_ensemble.ts',
  'a_atomic/12_collect_fee_messages.ts',
  'a_atomic/13_curve_shapes.ts',
  'a_atomic/14_update_usufructuary_refund_address.ts',
  'a_atomic/15_extend_ensemble_commitment.ts',
  'a_atomic/16_collect_earnings_messages.ts',
  'a_atomic/17_integrate_into_portfolio.ts',
  'a_atomic/18_governance_fleet_retire.ts',
];

const B_SCRIPTS = [
  'b_flows/01_minimal.ts',
  'b_flows/02_asset_lifecycle.ts',
  'b_flows/03_handover.ts',
  'b_flows/04_sequential_rents.ts 3',
  'b_flows/04_sequential_rents.ts 5',
  'b_flows/04_sequential_rents.ts 10',
  'b_flows/05_earnings.ts',
  'b_flows/06_refund_redirect_then_handover.ts',
  'b_flows/07_fleet_portfolio_collect.ts',
];

const toRun = [
  ...(phase !== 'b' ? A_SCRIPTS : []),
  ...(phase !== 'a' ? B_SCRIPTS : []),
];

console.log(`Running ${toRun.length} scripts...${resume ? ' (--resume: skipping completed)' : ''}\n`);

for (const script of toRun) {
  const [file, ...args] = script.split(' ');
  const label    = script.replace('a_atomic/', '').replace('b_flows/', '');
  const sentinel = SENTINEL[script] ? resolve(DIR, SENTINEL[script]) : null;

  if (resume && sentinel && existsSync(sentinel)) {
    console.log(`\n${'─'.repeat(60)}`);
    console.log(`✓ ${label}  (skipped — result exists)`);
    continue;
  }

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
