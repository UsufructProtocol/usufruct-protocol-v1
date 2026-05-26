#!/usr/bin/env tsx
/**
 * Retires + claims all abandoned profiling escrows on testnet.
 *
 * Finds every OwnerCap in the owner's wallet, reads the escrow state,
 * and for each idle escrow fires retire → claim_asset in a single PTB.
 * (retire already calls apply_pending_transition_states internally.)
 * Rented escrows (tenure not yet expired) are skipped
 * with a note — run again after 1 hour.
 *
 * Usage:
 *   SUI_RPC=https://fullnode.testnet.sui.io:443 npm run cleanup:testnet
 */

import { execSync }            from 'child_process';
import { resolve, dirname }    from 'path';
import { fileURLToPath }       from 'url';
import { SuiClient }           from '@mysten/sui/client';
import { Ed25519Keypair }      from '@mysten/sui/keypairs/ed25519';
import { Transaction }         from '@mysten/sui/transactions';
import { loadDeployment, RPC_URL, CLOCK_ID } from '../env.ts';

const DIR  = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(DIR, '..');

const client = new SuiClient({ url: RPC_URL });

function run(cmd: string): string {
  return execSync(cmd, { encoding: 'utf8' }).trim();
}

async function signAndExecute(tx: Transaction, keypair: Ed25519Keypair) {
  const bytes = await tx.build({ client });
  const sig   = await keypair.signTransaction(bytes);
  return client.executeTransactionBlock({
    transactionBlock: bytes,
    signature:        sig.signature,
    options:          { showEffects: true, showObjectChanges: true },
  });
}

// Fetch all OwnerCap objects for an address
async function getOwnerCaps(address: string, pkg: string): Promise<{ id: string; escrowId: string }[]> {
  const caps: { id: string; escrowId: string }[] = [];
  let cursor: string | null | undefined = undefined;

  while (true) {
    const page = await client.getOwnedObjects({
      owner:  address,
      filter: { StructType: `${pkg}::owner_cap::OwnerCap` },
      options: { showContent: true },
      cursor,
    });

    for (const obj of page.data) {
      const content = (obj.data?.content as any);
      if (!content?.fields) continue;
      const escrowId = content.fields.escrow_identity?.fields?.id;
      if (escrowId) caps.push({ id: obj.data!.objectId, escrowId });
    }

    if (!page.hasNextPage) break;
    cursor = page.nextCursor ?? undefined;
  }

  return caps;
}

// Read escrow state discriminant from on-chain content
async function getEscrowIsIdle(escrowId: string): Promise<boolean | null> {
  const obj = await client.getObject({
    id:      escrowId,
    options: { showContent: true },
  });
  const content = (obj.data?.content as any);
  if (!content?.fields?.state) return null;

  // state is an Option<AssetState> — if the state Option has a variant field
  // we look at the inner discriminant. Simpler: call the view function.
  return null; // fall back to attempting the PTB
}

async function tryClaimEscrow(
  escrowId:   string,
  capId:      string,
  d:          ReturnType<typeof loadDeployment>,
  keypair:    Ed25519Keypair,
  ownerAddr:  string,
): Promise<'claimed' | 'rented' | 'error'> {
  const pkg      = d.usufructPackageId;
  const dummyPkg = d.dummyAssetPackageId;
  const assetType   = `${dummyPkg}::dummy_asset::DummyAsset`;
  const typeArgs    = [assetType, '0x2::sui::SUI'];

  const tx = new Transaction();
  tx.setSender(ownerAddr);
  tx.setGasBudget(50_000_000);

  const escrow  = tx.object(escrowId);
  const cap     = tx.object(capId);
  const clock   = tx.object(CLOCK_ID);

  // retire — internally calls apply_pending_transition_states
  tx.moveCall({
    target:        `${pkg}::escrow::retire`,
    typeArguments: typeArgs,
    arguments:     [escrow, cap, clock],
  });

  // claim_asset — consumes escrow + cap, returns (Asset, Coin<SUI>)
  const [asset, earnings] = tx.moveCall({
    target:        `${pkg}::escrow::claim_asset`,
    typeArguments: typeArgs,
    arguments:     [escrow, cap, clock],
  }) as [any, any];

  // burn the dummy asset
  tx.moveCall({
    target:    `${dummyPkg}::dummy_asset::burn`,
    arguments: [asset],
  });

  // transfer any earnings back to owner
  tx.transferObjects([earnings], ownerAddr);

  try {
    const result = await signAndExecute(tx, keypair);
    const status = (result.effects as any)?.status?.status;
    if (status === 'success') return 'claimed';
    const err = (result.effects as any)?.status?.error ?? '';
    // ENotRetired = 12 — escrow is rented, tenure not yet expired
    if (/MoveAbort.*},\s*12\)/.test(err)) return 'rented';
    console.error(`  error: ${err}`);
    return 'error';
  } catch (e: any) {
    const msg = e?.message ?? String(e);
    if (/MoveAbort.*},\s*12\)/.test(msg)) return 'rented';
    console.error(`  exception: ${msg.slice(0, 200)}`);
    return 'error';
  }
}

async function main() {
  if (!RPC_URL.includes('testnet')) {
    console.error('Expected testnet RPC. Set SUI_RPC=https://fullnode.testnet.sui.io:443');
    process.exit(1);
  }

  const d         = loadDeployment();
  const ownerAddr = d.owner.address;
  const keypair   = Ed25519Keypair.fromSecretKey(d.owner.secretKey);

  run(`sui keytool import "${keypair.getSecretKey()}" ed25519`);

  console.log(`Owner: ${ownerAddr}`);
  console.log(`Package: ${d.usufructPackageId}\n`);

  const caps = await getOwnerCaps(ownerAddr, d.usufructPackageId);
  console.log(`Found ${caps.length} OwnerCap(s)\n`);

  if (caps.length === 0) {
    console.log('Nothing to clean up.');
    return;
  }

  let claimed = 0, rented = 0, errors = 0;

  for (const { id: capId, escrowId } of caps) {
    process.stdout.write(`  escrow ${escrowId.slice(0, 10)}…  cap ${capId.slice(0, 10)}… → `);
    const result = await tryClaimEscrow(escrowId, capId, d, keypair, ownerAddr);
    console.log(result);
    if (result === 'claimed') claimed++;
    else if (result === 'rented') rented++;
    else errors++;
  }

  console.log(`\nDone — claimed: ${claimed}  rented (skipped): ${rented}  errors: ${errors}`);
  if (rented > 0) {
    console.log(`\nRented escrows have a 1-hour tenure. Run again after they expire:`);
    console.log(`  SUI_RPC=https://fullnode.testnet.sui.io:443 npm run cleanup:testnet`);
  }
}

main().catch(e => { console.error(e); process.exit(1); });
