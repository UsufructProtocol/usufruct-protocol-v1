// Clean up the escrows this audit created on testnet — coin/asset-type aware.
// For each audit governor, replay AssetIntegrated, then per escrow derive its real <Asset, Coin>
// from the on-chain object type and retire → claim_asset → (burn DummyAsset | transfer) with the
// CORRECT type args. Escrows still within tenure / behind a commitment floor are skipped.
import * as U from './lib.ts';
import { Transaction } from '@mysten/sui/transactions';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';

async function integratedBy(addr: string): Promise<{ capId: string; escrowId: string }[]> {
  const out: { capId: string; escrowId: string }[] = [];
  const seen = new Set<string>();
  let cursor: any = null;
  do {
    const page = await U.client.queryEvents({ query: { MoveEventType: `${U.PKG}::asset_state::AssetIntegrated` }, cursor, limit: 50 });
    for (const e of page.data) {
      const j = e.parsedJson as any;
      if (!j || j.governor_address !== addr || seen.has(j.escrow_id)) continue;
      seen.add(j.escrow_id);
      out.push({ capId: j.governance_cap_id, escrowId: j.escrow_id });
    }
    cursor = page.hasNextPage ? page.nextCursor : null;
  } while (cursor);
  return out;
}

// returns the escrow's [Asset, Coin] type args, or null if it no longer exists
async function escrowTypeArgs(escrowId: string): Promise<string[] | null> {
  const o = await U.client.getObject({ id: escrowId, options: { showType: true } });
  if (!o.data || o.error) return null;
  const ta = U.typeArgsOf(o.data.type ?? '');
  return ta.length === 2 ? ta : null;
}

async function claimOne(escrowId: string, capId: string, gov: Ed25519Keypair): Promise<'claimed' | 'rented' | 'gone' | 'error'> {
  const ta = await escrowTypeArgs(escrowId);
  if (!ta) return 'gone';
  const [assetT] = ta;
  try {
    if (!await U.viewBool('is_retired', escrowId, [], ta)) {
      if (await U.viewBool('is_retiring', escrowId, [], ta)) {
        const exp = await U.viewOptU64('tenure_expiry_ms', escrowId, [], ta);
        if (exp !== null && exp > BigInt(Date.now())) return 'rented';
      } else {
        const t = new Transaction();
        t.moveCall({ target: `${U.PKG}::escrow::retire`, typeArguments: ta, arguments: [t.object(escrowId), t.object(capId), t.object(U.CLOCK)] });
        const r = await U.trySend(t, gov);
        if (!r.ok) return 'rented'; // within tenure, or commitment floor not elapsed
        if (!await U.viewBool('is_retired', escrowId, [], ta)) return 'rented';
      }
    }
    const tc = new Transaction();
    const asset = tc.moveCall({ target: `${U.PKG}::escrow::claim_asset`, typeArguments: ta, arguments: [tc.object(escrowId), tc.object(capId), tc.object(U.CLOCK)] });
    if (U.sameType(assetT, U.ASSET_T)) tc.moveCall({ target: `${U.DUMMY_PKG}::dummy_asset::burn`, arguments: [asset] });
    else tc.transferObjects([asset], U.addrOf(gov)); // non-dummy asset: hand it back, don't burn
    const r = await U.trySend(tc, gov);
    return r.ok ? 'claimed' : 'error';
  } catch { return 'error'; }
}

async function cleanGovernor(name: string, gov: Ed25519Keypair) {
  const escrows = await integratedBy(U.addrOf(gov));
  U.info(`${name} (${U.addrOf(gov).slice(0, 10)}): ${escrows.length} escrows ever integrated`);
  let claimed = 0, rented = 0, gone = 0, error = 0;
  for (const { capId, escrowId } of escrows) {
    const r = await claimOne(escrowId, capId, gov);
    if (r === 'claimed') { claimed++; process.stdout.write(`  ${escrowId.slice(0, 10)}… claimed\n`); }
    else if (r === 'rented') rented++; else if (r === 'gone') gone++; else error++;
  }
  console.log(`  → ${name}: claimed ${claimed}, gone ${gone}, rented(skipped) ${rented}, errors ${error}`);
  return { claimed, rented, gone, error };
}

async function main() {
  U.head('audit cleanup — reclaim/burn escrows created by this audit (type-aware)');
  const a = U.loadActors();
  const tot = { claimed: 0, rented: 0, gone: 0, error: 0 };
  for (const [name, kp] of [['GOV', a.GOV], ['mother', U.mother], ['UA', a.UA], ['UB', a.UB]] as [string, Ed25519Keypair][]) {
    const r = await cleanGovernor(name, kp);
    tot.claimed += r.claimed; tot.rented += r.rented; tot.gone += r.gone; tot.error += r.error;
  }
  console.log(`\nDone — claimed ${tot.claimed}, already-gone ${tot.gone}, rented(skipped) ${tot.rented}, errors ${tot.error}`);
  if (tot.rented) console.log('Some escrows are still within tenure / commitment floor — re-run after they elapse.');
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
