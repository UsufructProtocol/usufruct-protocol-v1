// V17 — refund-address authorization (refund-theft prevention).
// update_usufructuary_refund_address lets a cap set ONLY its own seat's refund address. Prove:
//  (a) the active cap changing its OWN refund takes effect at settlement (funds follow it);
//  (b) a PENDING cap cannot reroute the ACTIVE seat's refund — the departing refund still goes to
//      the active usufructuary, never to the attacker address the pending set on its own seat;
//  (c) a STALE cap (displaced) cannot touch any refund → EUsufructCapStale.
import * as U from './lib.ts';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';

function updateRefundTx(escrowId: string, capId: string, addr: string) {
  const t = new Transaction();
  const ra = t.moveCall({ target: `${U.PKG}::refund::refund_address`, arguments: [t.pure.address(addr)] });
  t.moveCall({ target: `${U.PKG}::escrow::update_usufructuary_refund_address`, typeArguments: U.TYPE_ARGS, arguments: [t.object(escrowId), t.object(capId), ra, t.object(U.CLOCK)] });
  return t;
}

// fresh receive-only addresses (no key/funding needed — we only read balanceChanges to them)
const X = U.addrOf(new Ed25519Keypair());          // legitimate redirect target
const ATTACKER = U.addrOf(new Ed25519Keypair());   // attacker's address

async function legitEffect() {
  U.head('V17(a) — active cap redirects its OWN refund; funds follow');
  const { GOV, UA, UB } = U.loadActors();
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 120_000n, handover: { fixed: 3_000n }, multi: true, creditShape: 'linear', escalation: { fixed: 1n } });
  const rA = await U.rent(UA, g.escrowId, 10_000n, 1n);
  const r = await U.trySend(updateRefundTx(g.escrowId, rA.capId, X), UA);
  if (r.ok) U.pass('active cap updated its own refund address'); else { U.finding(`update failed: ${U.truncErr(r.error)}`); return; }
  await U.rent(UB, g.escrowId, 30_000n, 1n);   // displace UA
  await U.sleep(5_000);
  const a = await U.apply(GOV, g.escrowId);
  const toX = U.balanceDelta(a, X), toUA = U.balanceDelta(a, U.addrOf(UA));
  const ev = U.events(a, 'HandoverCompleted')[0];
  U.info(`refund=${ev?.departing_refund_amount}  → X=${toX}  UA=${toUA}`);
  if (ev && toX === BigInt(ev.departing_refund_amount) && toX > 0n && toUA === 0n)
    U.pass(`refund followed the chosen address X (${toX}); UA got 0 — redirect works`);
  else U.finding(`refund routing wrong: X=${toX} UA=${toUA}`);
}

async function pendingCannotReroute() {
  U.head('V17(b) — pending cap CANNOT reroute the active seat refund');
  const { GOV, UA, UB } = U.loadActors();
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 120_000n, handover: { fixed: 3_000n }, multi: true, creditShape: 'linear', escalation: { fixed: 1n } });
  await U.rent(UA, g.escrowId, 10_000n, 1n);          // active = UA, refund → UA
  const rB = await U.rent(UB, g.escrowId, 30_000n, 1n); // UB pending
  const r = await U.trySend(updateRefundTx(g.escrowId, rB.capId, ATTACKER), UB);
  U.info(`pending update: ${r.ok ? 'accepted (sets pending seat only)' : U.truncErr(r.error)}`);
  await U.sleep(5_000);
  const a = await U.apply(GOV, g.escrowId); // handover → UA displaced & refunded
  const toUA = U.balanceDelta(a, U.addrOf(UA)), toAtt = U.balanceDelta(a, ATTACKER);
  const ev = U.events(a, 'HandoverCompleted')[0];
  U.info(`departing refund=${ev?.departing_refund_amount} → UA=${toUA} ATTACKER=${toAtt}`);
  if (ev && toAtt === 0n && toUA === BigInt(ev.departing_refund_amount))
    U.pass(`active's refund went to UA (${toUA}); attacker got 0 — pending cannot steal active's refund`);
  else U.finding(`attacker received ${toAtt} of active's refund — REROUTE POSSIBLE`);
}

async function staleCannotTouch() {
  U.head('V17(c) — stale cap cannot touch refunds');
  const { GOV, UA, UB } = U.loadActors();
  const g = await U.integrate(GOV, { restPrice: 1_000n, tenureMs: 120_000n, handover: { fixed: 3_000n }, multi: true, escalation: { fixed: 1n } });
  const rA = await U.rent(UA, g.escrowId, 10_000n, 1n);
  await U.rent(UB, g.escrowId, 30_000n, 1n);
  await U.sleep(5_000);
  await U.apply(GOV, g.escrowId); // UA now stale, UB active
  U.expectAbort(await U.trySend(updateRefundTx(g.escrowId, rA.capId, ATTACKER), UA), 'EUsufructCapStale', 'stale cap → update_refund');
}

async function main() {
  U.info(`legit target X=${X.slice(0, 12)}  attacker=${ATTACKER.slice(0, 12)}`);
  await legitEffect();
  await pendingCannotReroute();
  await staleCannotTouch();
  U.summary();
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
