#!/usr/bin/env tsx
/**
 * Retires + claims all abandoned profiling escrows on testnet.
 *
 * State machine for each GovernanceCap:
 *
 *   is_retired  → claim_asset
 *   is_retiring → tenure_expiry_ms < now
 *                   yes → claim_asset  (internal apply_pending fires
 *                          Occupied{Retiring} → Waiting::Retired)
 *                   no  → skip (rented, wait for expiry)
 *   neither     → retire (calls apply_pending internally: if tenure expired
 *                  it goes directly to Waiting::Retired; otherwise sets the
 *                  Retiring flag) → if now retired: claim_asset, else skip
 *
 * Two separate transactions are required for retire → claim_asset because
 * claim_asset receives the escrow by value at its chain-committed state.
 * Chaining them in one PTB passes the pre-retire state, causing ENotRetired.
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

// Fetch all GovernanceCap objects for an address
async function getGovernanceCaps(address: string, pkg: string): Promise<{ id: string; escrowId: string }[]> {
  const caps: { id: string; escrowId: string }[] = [];
  let cursor: string | null | undefined = undefined;

  while (true) {
    const page = await client.getOwnedObjects({
      owner:   address,
      filter:  { StructType: `${pkg}::governance_cap::GovernanceCap` },
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
    isRetired:  (escrowId: string) => v('is_retired',  [escrowId]),
    isRetiring: (escrowId: string) => v('is_retiring', [escrowId]),
  };
}

// Returns the tenure expiry timestamp in ms, or null if not rented.
async function getTenureExpiryMs(
  sender:    string,
  pkg:       string,
  typeArgs:  string[],
  escrowId:  string,
): Promise<number | null> {
  const tx = new Transaction();
  tx.moveCall({ target: `${pkg}::escrow::tenure_expiry_ms`, typeArguments: typeArgs, arguments: [tx.object(escrowId)] });
  const result = await client.devInspectTransactionBlock({ transactionBlock: tx, sender });
  const bytes  = result.results?.[0]?.returnValues?.[0]?.[0];
  if (!Array.isArray(bytes) || bytes[0] === 0) return null;
  return Number(Buffer.from(bytes.slice(1, 9)).readBigUInt64LE(0));
}

async function tryClaimEscrow(
  escrowId:  string,
  capId:     string,
  d:         ReturnType<typeof loadDeployment>,
  keypair:   Ed25519Keypair,
  governorAddr: string,
): Promise<'claimed' | 'rented' | 'error'> {
  const pkg      = d.usufructPackageId;
  const dummyPkg = d.dummyAssetPackageId;
  const typeArgs = [`${dummyPkg}::dummy_asset::DummyAsset`, '0x2::sui::SUI'];

  const view = makeViewers(governorAddr, pkg, typeArgs);

  try {
    if (!await view.isRetired(escrowId)) {
      if (await view.isRetiring(escrowId)) {
        // Retiring flag already set. Check if tenure has expired:
        // claim_asset calls apply_pending internally, which fires
        // Occupied{Retiring} → Waiting::Retired when tenure is past.
        // If tenure is still active, skip — nothing to do yet.
        const expiry = await getTenureExpiryMs(governorAddr, pkg, typeArgs, escrowId);
        if (expiry === null || expiry > Date.now()) return 'rented';
        // Tenure expired — fall through to claim_asset.
      } else {
        // First time: call retire. Internally calls apply_pending — if tenure
        // has expired the escrow goes directly to Waiting::Retired; otherwise
        // the Retiring flag is set and the escrow auto-retires on expiry.
        const txRet = new Transaction();
        txRet.setSender(governorAddr);
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
        if (!await view.isRetired(escrowId)) return 'rented';
        // Tenure expired and retire fired immediately — fall through to claim.
      }
    }

    // 3. claim_asset — sees committed Waiting::Retired state.
    const txClaim = new Transaction();
    txClaim.setSender(governorAddr);
    txClaim.setGasBudget(20_000_000);
    const asset = txClaim.moveCall({
      target:        `${pkg}::escrow::claim_asset`,
      typeArguments: typeArgs,
      arguments:     [txClaim.object(escrowId), txClaim.object(capId), txClaim.object(CLOCK_ID)],
    });
    txClaim.moveCall({ target: `${dummyPkg}::dummy_asset::burn`, arguments: [asset] });

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
  const governorAddr = d.governor.address;
  const keypair   = Ed25519Keypair.fromSecretKey(d.governor.secretKey);

  run(`sui keytool import "${keypair.getSecretKey()}" ed25519`);

  console.log(`Governor: ${governorAddr}`);
  console.log(`Package: ${d.usufructPackageId}\n`);

  const caps = await getGovernanceCaps(governorAddr, d.usufructPackageId);
  console.log(`Found ${caps.length} GovernanceCap(s)\n`);

  if (caps.length === 0) {
    console.log('Nothing to clean up.');
    return;
  }

  let claimed = 0, rented = 0, errors = 0;

  for (const { id: capId, escrowId } of caps) {
    process.stdout.write(`  escrow ${escrowId.slice(0, 10)}…  cap ${capId.slice(0, 10)}… → `);
    const result = await tryClaimEscrow(escrowId, capId, d, keypair, governorAddr);
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
