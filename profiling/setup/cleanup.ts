#!/usr/bin/env tsx
/**
 * Retires + claims all abandoned profiling escrows on testnet.
 *
 * For each OwnerCap in the owner's wallet:
 *   1. Reads escrow state via getObject (is_retired view).
 *   2. If NOT retired: sends a `retire` tx and waits for confirmation.
 *   3. Sends a `claim_asset` tx.
 *
 * Two separate transactions are required because `claim_asset` receives the
 * escrow by value (at its chain-committed state). Chaining retire+claim in a
 * single PTB passes the pre-retire state to claim_asset, causing ENotRetired.
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
  const result = await client.executeTransactionBlock({
    transactionBlock: bytes,
    signature:        sig.signature,
    options:          { showEffects: true },
  });
  await client.waitForTransaction({ digest: result.digest });
  return result;
}

// Fetch all OwnerCap objects for an address
async function getOwnerCaps(address: string, pkg: string): Promise<{ id: string; escrowId: string }[]> {
  const caps: { id: string; escrowId: string }[] = [];
  let cursor: string | null | undefined = undefined;

  while (true) {
    const page = await client.getOwnedObjects({
      owner:   address,
      filter:  { StructType: `${pkg}::owner_cap::OwnerCap` },
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

// Calls a pure bool view function via devInspect.
async function viewBool(
  sender:   string,
  target:   string,
  typeArgs: string[],
  objIds:   string[],
): Promise<boolean> {
  const tx = new Transaction();
  tx.moveCall({ target, typeArguments: typeArgs, arguments: objIds.map(id => tx.object(id)) });
  const result = await client.devInspectTransactionBlock({ transactionBlock: tx, sender });
  const bytes = result.results?.[0]?.returnValues?.[0]?.[0];
  return Array.isArray(bytes) ? bytes[0] === 1 : false;
}

function makeViewers(sender: string, pkg: string, typeArgs: string[]) {
  const v = (fn: string, ids: string[]) => viewBool(sender, `${pkg}::escrow::${fn}`, typeArgs, ids);
  return {
    isRetired: (escrowId: string) => v('is_retired', [escrowId]),
  };
}

async function tryClaimEscrow(
  escrowId:  string,
  capId:     string,
  d:         ReturnType<typeof loadDeployment>,
  keypair:   Ed25519Keypair,
  ownerAddr: string,
): Promise<'claimed' | 'rented' | 'error'> {
  const pkg      = d.usufructPackageId;
  const dummyPkg = d.dummyAssetPackageId;
  const typeArgs = [`${dummyPkg}::dummy_asset::DummyAsset`, '0x2::sui::SUI'];

  const view = makeViewers(ownerAddr, pkg, typeArgs);

  try {
    // 1. If not already retired, call retire unconditionally.
    //    retire calls apply_pending internally: if tenure has expired it fires
    //    Occupied → Idle → Retired in one tx. If the tenure is still active it
    //    sets the Retiring flag and returns, leaving the escrow in Occupied.
    if (!await view.isRetired(escrowId)) {
      const txRet = new Transaction();
      txRet.setSender(ownerAddr);
      txRet.setGasBudget(20_000_000);
      txRet.moveCall({
        target:        `${pkg}::escrow::retire`,
        typeArguments: typeArgs,
        arguments:     [txRet.object(escrowId), txRet.object(capId), txRet.object(CLOCK_ID)],
      });
      const retResult = await signAndExecute(txRet, keypair);
      if ((retResult.effects as any)?.status?.status !== 'success') {
        const err = (retResult.effects as any)?.status?.error ?? 'unknown';
        console.error(`  retire failed: ${err}`);
        return 'error';
      }

      // 2. After retire, check if now Waiting::Retired. If not, the tenure is
      //    still active — the Retiring flag is set and it will auto-retire later.
      if (!await view.isRetired(escrowId)) return 'rented';
    }

    // 3. claim_asset — sees committed Waiting::Retired state.
    const txClaim = new Transaction();
    txClaim.setSender(ownerAddr);
    txClaim.setGasBudget(20_000_000);
    const [asset, earnings] = txClaim.moveCall({
      target:        `${pkg}::escrow::claim_asset`,
      typeArguments: typeArgs,
      arguments:     [txClaim.object(escrowId), txClaim.object(capId), txClaim.object(CLOCK_ID)],
    }) as [any, any];
    txClaim.moveCall({ target: `${dummyPkg}::dummy_asset::burn`, arguments: [asset] });
    txClaim.transferObjects([earnings], ownerAddr);

    const claimResult = await signAndExecute(txClaim, keypair);
    if ((claimResult.effects as any)?.status?.status !== 'success') {
      const err = (claimResult.effects as any)?.status?.error ?? 'unknown';
      console.error(`  claim failed: ${err}`);
      return 'error';
    }

    return 'claimed';

  } catch (e: any) {
    console.error(`  exception: ${(e?.message ?? String(e)).slice(0, 200)}`);
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
    if (result !== 'claimed') process.stdout.write(result === 'rented' ? 'rented\n' : '');
    else console.log('claimed');
    if (result === 'claimed') claimed++;
    else if (result === 'rented') rented++;
    else errors++;
  }

  console.log(`\nDone — claimed: ${claimed}  rented (skipped): ${rented}  errors: ${errors}`);
  if (rented > 0) {
    console.log(`\nRented escrows still within their tenure window. Run again after they expire.`);
  }
}

main().catch(e => { console.error(e); process.exit(1); });
