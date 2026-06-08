// Create + fund 3 distinct adversarial actors from the mother account.
// GOV = governor, UA = incumbent/usufructuary-A, UB = challenger/usufructuary-B.
// They need SUI only for gas; stakes are minted in free DUMMY_COIN.
import * as U from './lib.ts';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';

const GAS_EACH = U.sui(0.3);

async function main() {
  U.head('01 — actor setup');
  let actors = U.loadActors();
  if (!actors.GOV) {
    actors = { GOV: new Ed25519Keypair(), UA: new Ed25519Keypair(), UB: new Ed25519Keypair() };
    U.saveActors(actors);
    U.info('generated GOV, UA, UB');
  } else U.info('reusing persisted actors');
  for (const [k, v] of Object.entries(actors)) U.info(`${k} = ${U.addrOf(v)}`);

  // fund any actor that is below GAS_EACH
  const need: [string, Ed25519Keypair][] = [];
  for (const [k, v] of Object.entries(actors)) {
    const bal = BigInt((await U.client.getBalance({ owner: U.addrOf(v) })).totalBalance);
    if (bal < GAS_EACH / 2n) need.push([k, v]);
    else U.info(`${k} already funded (${Number(bal) / 1e9} SUI)`);
  }
  if (need.length) {
    const tx = new Transaction();
    const splits = tx.splitCoins(tx.gas, need.map(() => tx.pure.u64(GAS_EACH)));
    need.forEach(([_, v], i) => tx.transferObjects([splits[i]], U.addrOf(v)));
    const res = await U.send(tx, U.mother);
    U.info(`funded ${need.map((n) => n[0]).join(', ')} with ${Number(GAS_EACH) / 1e9} SUI each (digest ${res.digest})`);
  }
  U.pass('actors ready');
  U.summary();
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
