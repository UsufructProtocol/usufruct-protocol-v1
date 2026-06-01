#!/usr/bin/env tsx
/**
 * Requests faucet SUI for all three wallets.
 * Run whenever a wallet runs low on gas.
 *
 * Not available on Mainnet — fund wallets manually there.
 *
 * Usage: npm run setup:fund
 *   SUI_FAUCET=https://faucet.testnet.sui.io/gas npm run setup:fund
 */

import { FAUCET_URL, loadDeployment } from '../env.ts';

async function requestFaucet(address: string): Promise<void> {
  console.log(`  Funding ${address}...`);
  const res = await fetch(FAUCET_URL, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify({ FixedAmountRequest: { recipient: address } }),
  });
  if (!res.ok) throw new Error(`Faucet failed: ${await res.text()}`);
  const data = await res.json() as any;
  console.log(`    ok — coins: ${data.transferredGasObjects?.length ?? '?'}`);
}

async function main() {
  if (!process.env.SUI_FAUCET && process.env.SUI_RPC?.includes('mainnet')) {
    console.error('Mainnet detected — no faucet available. Fund wallets manually.');
    process.exit(1);
  }

  const d = loadDeployment();

  console.log(`Requesting faucet (${FAUCET_URL}) for all wallets...`);
  for (const wallet of [d.governor, d.usufructuary1, d.usufructuary2]) {
    await requestFaucet(wallet.address);
    await new Promise(r => setTimeout(r, 1500));
  }
  console.log('Done.');
}

main().catch(e => { console.error(e); process.exit(1); });
