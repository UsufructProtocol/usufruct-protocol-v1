#!/usr/bin/env tsx
/**
 * Burns every GovernanceCap owned by the governor via `cap::renounce_governance`.
 *
 * After a teardown the caps are dangling governance tokens for escrows that are
 * already claimed/gone, so renouncing them just reclaims the cap's object storage.
 * (In live use `renounce_governance` seals the escrows the cap governs — here there
 * are none left to seal.) Batches many renounces per PTB.
 *
 * Usage:
 *   SUI_RPC=https://fullnode.testnet.sui.io:443 npx tsx setup/renounce_caps.ts
 */

import { SuiClient }      from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction }    from '@mysten/sui/transactions';
import { loadDeployment, makeClient, RPC_URL } from '../env.ts';

const CAPS_PER_PTB = 50;

async function withRetry<T>(fn: () => Promise<T>, label: string): Promise<T> {
  for (let attempt = 1; ; attempt++) {
    try { return await fn(); }
    catch (e: any) {
      if (attempt >= 6) throw e;
      const ms = 500 * attempt;
      process.stderr.write(`\n  [retry ${attempt} after ${ms}ms: ${label}]`);
      await new Promise(r => setTimeout(r, ms));
    }
  }
}

async function main() {
  if (!RPC_URL.includes('testnet')) {
    console.error('Expected testnet RPC. Set SUI_RPC=https://fullnode.testnet.sui.io:443');
    process.exit(1);
  }

  const d   = loadDeployment();
  const c   = makeClient();
  const kp  = Ed25519Keypair.fromSecretKey(d.governor.secretKey);
  const gov = d.governor.address;
  const pkg = d.usufructPackageId;
  const capType = `${pkg}::governance_cap::GovernanceCap`;

  console.log(`Governor: ${gov}`);
  console.log(`Package: ${pkg}\n`);

  process.stdout.write('Finding GovernanceCaps...');
  const ids: string[] = [];
  let cursor: string | null | undefined = undefined;
  while (true) {
    const page = await withRetry(() => c.getOwnedObjects({
      owner: gov, filter: { StructType: capType }, options: {}, cursor, limit: 50,
    }), 'getOwnedObjects(GovernanceCap)');
    for (const o of page.data) if (o.data) ids.push(o.data.objectId);
    if (!page.hasNextPage || !page.nextCursor) break;
    cursor = page.nextCursor;
  }
  console.log(` ${ids.length}\n`);
  if (ids.length === 0) { console.log('Nothing to renounce.'); return; }

  let totalNet = 0n, burned = 0;
  for (let i = 0; i < ids.length; i += CAPS_PER_PTB) {
    const batch = ids.slice(i, i + CAPS_PER_PTB);
    const tx = new Transaction();
    tx.setSender(gov);
    tx.setGasBudget(300_000_000);
    for (const capId of batch) {
      tx.moveCall({ target: `${pkg}::cap::renounce_governance`, arguments: [tx.object(capId)] });
    }

    const bytes  = await tx.build({ client: c });
    const sig    = await kp.signTransaction(bytes);
    const result = await c.executeTransactionBlock({
      transactionBlock: bytes, signature: sig.signature, options: { showEffects: true },
    });
    await c.waitForTransaction({ digest: result.digest });

    const status = (result.effects as any)?.status?.status;
    if (status !== 'success') throw new Error(`renounce failed: ${(result.effects as any)?.status?.error ?? 'unknown'}`);

    const g   = (result.effects as any).gasUsed;
    const net = BigInt(g.computationCost) + BigInt(g.storageCost) - BigInt(g.storageRebate);
    totalNet += net;
    burned   += batch.length;
    const sign = net < 0n ? '' : '+';
    console.log(`  PTB ${Math.floor(i / CAPS_PER_PTB) + 1}: ${batch.length} caps  net=${sign}${net} MIST`);
  }

  const sign = totalNet < 0n ? '' : '+';
  console.log(`\nDone — ${burned} GovernanceCaps renounced`);
  console.log(`Total net: ${sign}${totalNet} MIST  (${sign}${(Number(totalNet) / 1e9).toFixed(6)} SUI)`);
  console.log('Negative = rebate received (SUI recovered to governor wallet).');
}

main().catch(e => { console.error(e); process.exit(1); });
