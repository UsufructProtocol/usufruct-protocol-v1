#!/usr/bin/env tsx
/** One-off: governor tops up both usufructuaries for phase B (one PTB). */
import { resolve, dirname } from 'path';
import { fileURLToPath }    from 'url';
import { readFileSync }     from 'fs';
import { SuiClient }        from '@mysten/sui/client';
import { Ed25519Keypair }   from '@mysten/sui/keypairs/ed25519';
import { Transaction }      from '@mysten/sui/transactions';

const DIR = dirname(fileURLToPath(import.meta.url));
const RPC = process.env.SUI_RPC ?? 'https://fullnode.testnet.sui.io:443';
const d = JSON.parse(readFileSync(resolve(DIR, '../deployment.json'), 'utf8'));
const client = new SuiClient({ url: RPC });

async function main() {
  const gov = Ed25519Keypair.fromSecretKey(d.governor.secretKey);
  const tx = new Transaction();
  tx.setSender(d.governor.address);
  const [c1, c2] = tx.splitCoins(tx.gas, [900_000_000, 700_000_000]); // 0.9 → u1, 0.7 → u2
  tx.transferObjects([c1], d.usufructuary1.address);
  tx.transferObjects([c2], d.usufructuary2.address);
  const r = await client.signAndExecuteTransaction({ transaction: tx, signer: gov, options: { showEffects: true } });
  console.log(`governor → u1 0.9 + u2 0.7  (${r.effects?.status?.status})  ${r.digest}`);
}
main().catch(e => { console.error(e); process.exit(1); });
