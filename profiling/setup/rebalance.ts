#!/usr/bin/env tsx
/**
 * One-off: drain spare SUI from the light actors (usufructuary1/2) into the
 * heavy actor (governor), which bears all the scalability-sweep integrates and
 * runs out first. Keeps a gas floor in each usufructuary for their phase-B rents.
 *
 *   SUI_RPC=https://fullnode.testnet.sui.io:443 tsx setup/rebalance.ts
 */
import { resolve, dirname } from 'path';
import { fileURLToPath }    from 'url';
import { readFileSync }     from 'fs';
import { SuiClient }        from '@mysten/sui/client';
import { Ed25519Keypair }   from '@mysten/sui/keypairs/ed25519';
import { Transaction }      from '@mysten/sui/transactions';

const DIR = dirname(fileURLToPath(import.meta.url));
const RPC = process.env.SUI_RPC ?? 'https://fullnode.testnet.sui.io:443';
const KEEP = 350_000_000n;      // 0.35 SUI gas floor left in each usufructuary
const GASBUF = 10_000_000n;

const d = JSON.parse(readFileSync(resolve(DIR, '../deployment.json'), 'utf8'));
const client = new SuiClient({ url: RPC });
const GOV = d.governor.address;

async function drain(name: string, secretKey: string, addr: string) {
  const kp  = Ed25519Keypair.fromSecretKey(secretKey);
  const bal = BigInt((await client.getBalance({ owner: addr })).totalBalance);
  const send = bal - KEEP - GASBUF;
  if (send <= 0n) { console.log(`${name}: balance ${Number(bal)/1e9} — nothing to send`); return; }
  const tx = new Transaction();
  tx.setSender(addr);
  const [c] = tx.splitCoins(tx.gas, [send]);
  tx.transferObjects([c], GOV);
  const r = await client.signAndExecuteTransaction({ transaction: tx, signer: kp, options: { showEffects: true } });
  console.log(`${name} → governor: ${Number(send)/1e9} SUI  (${r.effects?.status?.status})  ${r.digest}`);
}

async function main() {
  console.log(`Rebalancing spare SUI → governor ${GOV}\n`);
  await drain('usufructuary1', d.usufructuary1.secretKey, d.usufructuary1.address);
  await drain('usufructuary2', d.usufructuary2.secretKey, d.usufructuary2.address);
  const g = BigInt((await client.getBalance({ owner: GOV })).totalBalance);
  console.log(`\ngovernor now: ${Number(g)/1e9} SUI`);
}
main().catch(e => { console.error(e); process.exit(1); });
