#!/usr/bin/env tsx
/** One-off: fund audit-v1-4-2 from the idle profiling actors. */
import { resolve, dirname } from 'path';
import { fileURLToPath }    from 'url';
import { readFileSync }     from 'fs';
import { SuiClient }        from '@mysten/sui/client';
import { Ed25519Keypair }   from '@mysten/sui/keypairs/ed25519';
import { Transaction }      from '@mysten/sui/transactions';

const DIR = dirname(fileURLToPath(import.meta.url));
const RPC = process.env.SUI_RPC ?? 'https://fullnode.testnet.sui.io:443';
const AUDIT = process.env.AUDIT_ADDR!;
const d = JSON.parse(readFileSync(resolve(DIR, '../deployment.json'), 'utf8'));
const client = new SuiClient({ url: RPC });

async function send(name: string, secretKey: string, addr: string, amount: bigint) {
  const kp = Ed25519Keypair.fromSecretKey(secretKey);
  const tx = new Transaction();
  tx.setSender(addr);
  const [c] = tx.splitCoins(tx.gas, [amount]);
  tx.transferObjects([c], AUDIT);
  const r = await client.signAndExecuteTransaction({ transaction: tx, signer: kp, options: { showEffects: true } });
  console.log(`${name} → audit: ${Number(amount)/1e9} SUI  (${r.effects?.status?.status})  ${r.digest}`);
}

async function main() {
  await send('usufructuary1', d.usufructuary1.secretKey, d.usufructuary1.address, 850_000_000n);
  await send('usufructuary2', d.usufructuary2.secretKey, d.usufructuary2.address, 950_000_000n);
}
main().catch(e => { console.error(e); process.exit(1); });
