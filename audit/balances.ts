import * as U from './lib.ts';
const a = U.loadActors();
let total = 0;
for (const [k, v] of Object.entries(a)) {
  const b = Number((await U.client.getBalance({ owner: U.addrOf(v) })).totalBalance) / 1e9;
  total += b;
  console.log(`${k}\t${U.addrOf(v)}\t${b.toFixed(4)} SUI`);
}
const m = Number((await U.client.getBalance({ owner: U.MOTHER })).totalBalance) / 1e9;
total += m;
console.log(`MOTHER\t${U.MOTHER}\t${m.toFixed(4)} SUI`);
console.log(`TOTAL SUI across all audit accounts: ${total.toFixed(4)} (started 2.0000)`);
