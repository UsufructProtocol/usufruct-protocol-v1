// Re-collect every outstanding message left by the audit — fully coin-agnostic.
// Each inbox is poly-coin; collectAllEarnings / collectAllFees discover every coin type present
// and drain them ALL in a single PTB (one collect moveCall per coin type). No hardcoded coin list.
import * as U from './lib.ts';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';

const short = (c: string) => c.split('::').slice(-1)[0];
const fmt = (byCoin: { coin: string; refs: number; amount: bigint }[]) =>
  byCoin.map((b) => `${b.amount} ${short(b.coin)} (${b.refs})`).join(', ');

async function collectGovernor(name: string, kp: Ed25519Keypair) {
  let cursor: any = null; const inboxes: string[] = [];
  do {
    const page = await U.client.getOwnedObjects({ owner: U.addrOf(kp), cursor, options: { showType: true }, limit: 50 });
    for (const o of page.data) if ((o.data?.type ?? '').includes('earnings_inbox::EarningsInbox')) inboxes.push(o.data!.objectId);
    cursor = page.hasNextPage ? page.nextCursor : null;
  } while (cursor);
  U.info(`${name} (${U.addrOf(kp).slice(0, 10)}): ${inboxes.length} EarningsInbox owned`);

  let total = 0n;
  for (const inboxId of inboxes) {
    try {
      const r = await U.collectAllEarnings(kp, inboxId);
      if (r.total > 0n) { total += r.total; process.stdout.write(`  ${inboxId.slice(0, 10)}… ${fmt(r.byCoin)} — one PTB\n`); }
    } catch (e: any) { process.stdout.write(`  ${inboxId.slice(0, 10)}… skipped (${U.truncErr(String(e.message ?? e)).slice(0, 50)})\n`); }
  }
  console.log(`  → ${name}: ${total} mist total (any coin)`);
  return total;
}

async function main() {
  U.head('recollect — drain outstanding Fee + Earnings (coin-agnostic, one PTB per inbox)');

  // protocol fees — every coin in the deployer inbox, drained in one PTB
  const f = await U.collectAllFees();
  console.log(`Fees: ${f.total} mist [${fmt(f.byCoin) || '—'}]${f.res ? ` — ${f.res.digest}` : ''}`);

  // governor earnings — every inbox, every coin
  const a = U.loadActors();
  let earn = 0n;
  for (const [name, kp] of [['GOV', a.GOV], ['mother', U.mother]] as [string, Ed25519Keypair][]) earn += await collectGovernor(name, kp);

  console.log(`\nDone — fees ${f.total} mist; earnings ${earn} mist (all coin types, no hardcoded list).`);
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
