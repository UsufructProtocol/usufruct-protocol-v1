#!/usr/bin/env tsx
/**
 * Retires + claims all abandoned profiling escrows on testnet.
 *
 * Inbox-first discovery: a `GovernanceCap` no longer points at an escrow (it is a
 * pure governance token that may govern N escrows, validated seat-side). Escrows
 * are *shared* objects, so they cannot be listed by owner either. Instead we
 * replay the `AssetIntegrated` event stream — each event carries `escrow_id`,
 * `governance_cap_id`, and `governor_address` — and filter to this governor. That
 * yields every (escrow, governing cap) pair, one-to-one and portfolio alike.
 *
 * State machine for each escrow:
 *   does not exist  → skip (already claimed / torn down)
 *   is_retired      → claim_asset
 *   is_retiring     → tenure expired? claim_asset : skip (rented)
 *   neither         → retire (apply_pending fires internally) → claim if retired
 *
 * retire → claim_asset are two separate transactions: claim_asset receives the
 * escrow by value at its chain-committed state; chaining them in one PTB passes the
 * pre-retire state and aborts with ENotRetired.
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

// Replay AssetIntegrated events to recover every (escrow, governing cap) pair for
// this governor. The cap no longer links to its escrows on-chain (inbox-first), so
// the event log is the only complete index.
async function getIntegratedEscrows(governorAddr: string, pkg: string): Promise<{ capId: string; escrowId: string }[]> {
  const pairs: { capId: string; escrowId: string }[] = [];
  const seen = new Set<string>();
  let cursor: any = null;

  while (true) {
    const page = await client.queryEvents({
      query:  { MoveEventType: `${pkg}::asset_state::AssetIntegrated` },
      cursor,
      limit:  50,
    });

    for (const e of page.data) {
      const j = e.parsedJson as any;
      if (!j || j.governor_address !== governorAddr) continue;
      if (seen.has(j.escrow_id)) continue;
      seen.add(j.escrow_id);
      pairs.push({ capId: j.governance_cap_id, escrowId: j.escrow_id });
    }

    if (!page.hasNextPage || !page.nextCursor) break;
    cursor = page.nextCursor;
  }

  return pairs;
}

async function escrowExists(escrowId: string): Promise<boolean> {
  const obj = await client.getObject({ id: escrowId, options: {} });
  return !!obj.data && !obj.error;
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

type Outcome = 'claimed' | 'rented' | 'gone' | 'error';

async function tryClaimEscrow(
  escrowId:  string,
  capId:     string,
  d:         ReturnType<typeof loadDeployment>,
  keypair:   Ed25519Keypair,
  governorAddr: string,
): Promise<Outcome> {
  const pkg      = d.usufructPackageId;
  const dummyPkg = d.dummyAssetPackageId;
  const typeArgs = [`${dummyPkg}::dummy_asset::DummyAsset`, '0x2::sui::SUI'];

  if (!await escrowExists(escrowId)) return 'gone';

  const view = makeViewers(governorAddr, pkg, typeArgs);

  try {
    if (!await view.isRetired(escrowId)) {
      if (await view.isRetiring(escrowId)) {
        const expiry = await getTenureExpiryMs(governorAddr, pkg, typeArgs, escrowId);
        if (expiry === null || expiry > Date.now()) return 'rented';
        // Tenure expired — fall through to claim_asset.
      } else {
        const txRet = new Transaction();
        txRet.setSender(governorAddr);
        txRet.setGasBudget(30_000_000);
        txRet.moveCall({
          target:        `${pkg}::escrow::retire`,
          typeArguments: typeArgs,
          arguments:     [txRet.object(escrowId), txRet.object(capId), txRet.object(CLOCK_ID)],
        });
        const retResult = await signAndExecute(txRet, keypair);
        if ((retResult.effects as any)?.status?.status !== 'success') {
          console.error(`  retire failed: ${(retResult.effects as any)?.status?.error ?? 'unknown'}`);
          return 'error';
        }
        if (!await view.isRetired(escrowId)) return 'rented';
      }
    }

    const txClaim = new Transaction();
    txClaim.setSender(governorAddr);
    txClaim.setGasBudget(30_000_000);
    const asset = txClaim.moveCall({
      target:        `${pkg}::escrow::claim_asset`,
      typeArguments: typeArgs,
      arguments:     [txClaim.object(escrowId), txClaim.object(capId), txClaim.object(CLOCK_ID)],
    });
    txClaim.moveCall({ target: `${dummyPkg}::dummy_asset::burn`, arguments: [asset] });

    const claimResult = await signAndExecute(txClaim, keypair);
    if ((claimResult.effects as any)?.status?.status !== 'success') {
      console.error(`  claim failed: ${(claimResult.effects as any)?.status?.error ?? 'unknown'}`);
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

  process.stdout.write('Replaying AssetIntegrated events...');
  const escrows = await getIntegratedEscrows(governorAddr, d.usufructPackageId);
  console.log(` ${escrows.length} escrows ever integrated by this governor\n`);

  if (escrows.length === 0) {
    console.log('Nothing to clean up.');
    return;
  }

  let claimed = 0, rented = 0, gone = 0, errors = 0;

  for (const { capId, escrowId } of escrows) {
    const result = await tryClaimEscrow(escrowId, capId, d, keypair, governorAddr);
    if (result === 'claimed') { claimed++; process.stdout.write(`  ${escrowId.slice(0, 10)}… claimed\n`); }
    else if (result === 'rented') { rented++; }
    else if (result === 'gone')   { gone++; }
    else errors++;
    if ((claimed + rented + gone + errors) % 25 === 0) {
      console.log(`  … ${claimed + rented + gone + errors}/${escrows.length} (claimed ${claimed}, gone ${gone}, rented ${rented}, err ${errors})`);
    }
  }

  console.log(`\nDone — claimed: ${claimed}  already-gone: ${gone}  rented (skipped): ${rented}  errors: ${errors}`);
  if (rented > 0) console.log(`\nRented escrows still within tenure. Run again after they expire.`);
}

main().catch(e => { console.error(e); process.exit(1); });
