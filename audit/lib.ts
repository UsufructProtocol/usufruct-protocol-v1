// Adversarial live-audit harness for usufruct v1.4.2 on Sui testnet.
// Bytecode verified == source via `./verify.sh v1.4.2` (Source verification succeeded!).
// TESTNET ONLY. Explicit testnet RPC. Uses the user-provisioned audit-v1-4-2 key (the
// llms.txt "ephemeral keypair" rule is intentionally overridden per user instruction).
import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';
import { readFileSync, existsSync, writeFileSync } from 'fs';

// ── testnet coordinates (immutable; verified) ──
export const RPC   = 'https://fullnode.testnet.sui.io:443';
export const PKG   = '0x415c4372bb9db5affe2ab2bf6d72a6a667ed3178a61d6201e9ff26dc76380e5d';
export const FEE_REF = '0x41a7dee6e39f950fa2f7179464e400bb20cd6e620b5fcdbadf1db1b57ec87145';
export const DUMMY_PKG = '0xa72e830fcb3e688ab3c20ff3cbd0a149cd1b58715709905585e75eb18317a52a';
export const DUMMY_COIN_PKG = '0x97fb7c77162e3edf6a44815ec9eb29b69f9a43747dfb1c1019a7fc5501e2ad96';
export const DUMMY_COIN_TREASURY = '0xccee2bc2227913f441c7544892cf5d220880cbc0c55be8733b4b6777def976bc';
export const CLOCK = '0x6';
export const ASSET_T = `${DUMMY_PKG}::dummy_asset::DummyAsset`;
export const SUI_T = '0x2::sui::SUI';
export const DCOIN_T = `${DUMMY_COIN_PKG}::dummy_coin::DUMMY_COIN`;
// Default coin axis: DUMMY_COIN — free-mint, so stakes cost no SUI and balanceChanges
// carry zero gas noise (gas is always paid in SUI). Conservation is then exact to the mist.
export const COIN_T = DCOIN_T;
export const TYPE_ARGS = [ASSET_T, COIN_T];

export const client = new SuiJsonRpcClient({ url: RPC });

// ── keys ──
function envVal(k: string): string {
  const env = readFileSync(new URL('./.env', import.meta.url), 'utf8');
  const m = env.split('\n').find((l) => l.startsWith(k + '='));
  if (!m) throw new Error(`missing ${k} in .env`);
  return m.slice(k.length + 1).trim();
}
export const mother = Ed25519Keypair.fromSecretKey(envVal('MOTHER_KEY'));
export const addrOf = (k: Ed25519Keypair) => k.getPublicKey().toSuiAddress();
export const MOTHER = addrOf(mother);

// Protocol deployer (owns the ProtocolFeeInbox). Used only for the fee-drain vector (V16),
// with explicit user authorization. Testnet, immutable package.
export const deployer = Ed25519Keypair.fromSecretKey(envVal('DEPLOYER_KEY'));
export const DEPLOYER = addrOf(deployer);
export const FEE_INBOX = '0x0c4b4f9192a4c87d43979baeb0a7941db923a795bf90e646a7f6eca005a31f46';

// Persisted actor keypairs (so re-runs reuse funded addresses).
const ACTORS_FILE = new URL('./actors.json', import.meta.url);
export function loadActors(): Record<string, Ed25519Keypair> {
  if (!existsSync(ACTORS_FILE)) return {};
  const j = JSON.parse(readFileSync(ACTORS_FILE, 'utf8'));
  const out: Record<string, Ed25519Keypair> = {};
  for (const [k, v] of Object.entries(j)) out[k] = Ed25519Keypair.fromSecretKey(v as string);
  return out;
}
export function saveActors(a: Record<string, Ed25519Keypair>) {
  const j: Record<string, string> = {};
  for (const [k, v] of Object.entries(a)) j[k] = (v as any).getSecretKey();
  writeFileSync(ACTORS_FILE, JSON.stringify(j, null, 2));
}

// ── execution ──
export type ExecResult = Awaited<ReturnType<typeof client.signAndExecuteTransaction>>;

export async function send(tx: Transaction, signer: Ed25519Keypair, budget = 30_000_000n): Promise<any> {
  tx.setSender(addrOf(signer));
  tx.setGasBudget(budget);
  const res = await client.signAndExecuteTransaction({
    transaction: tx, signer,
    options: { showEffects: true, showObjectChanges: true, showEvents: true, showBalanceChanges: true },
  });
  await client.waitForTransaction({ digest: res.digest });
  if (res.effects?.status.status !== 'success')
    throw new Error(`tx failed: ${res.effects?.status.error}\n  digest: ${res.digest}`);
  return res;
}

// Never throws on a Move abort: returns {ok, error, digest, res}. Used to PROVE defenses.
export async function trySend(tx: Transaction, signer: Ed25519Keypair, budget = 30_000_000n):
  Promise<{ ok: boolean; error?: string; digest?: string; res?: any }> {
  try {
    const res = await send(tx, signer, budget);
    return { ok: true, digest: res.digest, res };
  } catch (e: any) {
    return { ok: false, error: String(e.message ?? e) };
  }
}

// ── object id extraction ──
export const createdId = (res: any, frag: string): string => {
  const c = (res.objectChanges ?? []).find((c: any) => c.type === 'created' && c.objectType?.includes(frag));
  if (!c) throw new Error(`no created object matching ${frag}`);
  return c.objectId;
};
export const createdIds = (res: any, frag: string): string[] =>
  (res.objectChanges ?? []).filter((c: any) => c.type === 'created' && c.objectType?.includes(frag)).map((c: any) => c.objectId);

// ── events ──
export const events = (res: any, suffix: string): any[] =>
  (res.events ?? []).filter((e: any) => e.type.includes(suffix)).map((e: any) => e.parsedJson);
export const eventAmounts = (res: any, suffix: string, field = 'amount'): bigint[] =>
  events(res, suffix).map((j) => BigInt(j[field]));
export const sumEvent = (res: any, suffix: string, field = 'amount'): bigint =>
  eventAmounts(res, suffix, field).reduce((a, b) => a + b, 0n);

// ── balance changes (signed, per address+coin) ──
export function balanceDelta(res: any, addr: string, coinType = COIN_T): bigint {
  let total = 0n;
  for (const bc of res.balanceChanges ?? []) {
    const owner = (bc.owner as any)?.AddressOwner;
    if (owner === addr && bc.coinType === coinType) total += BigInt(bc.amount);
  }
  return total;
}

// ── coin minting (DUMMY_COIN: free permissionless mint) ──
export function mintDummy(tx: Transaction, amount: bigint) {
  return tx.moveCall({
    target: `${DUMMY_COIN_PKG}::dummy_coin::mint`,
    arguments: [tx.object(DUMMY_COIN_TREASURY), tx.pure.u64(amount)],
  });
}

// ── type-string helpers (coin-type discipline for collection over poly-coin inboxes) ──
// extract the top-level generic args of a fully-qualified type, e.g.
//   "PKG::escrow::Escrow<A::dummy_asset::DummyAsset, 0x2::sui::SUI>" → [A…::DummyAsset, 0x2::sui::SUI]
export function typeArgsOf(fullType: string): string[] {
  const lt = fullType.indexOf('<');
  if (lt < 0) return [];
  const inner = fullType.slice(lt + 1, fullType.lastIndexOf('>'));
  const out: string[] = [];
  let depth = 0, start = 0;
  for (let i = 0; i < inner.length; i++) {
    const ch = inner[i];
    if (ch === '<') depth++;
    else if (ch === '>') depth--;
    else if (ch === ',' && depth === 0) { out.push(inner.slice(start, i).trim()); start = i + 1; }
  }
  if (inner.trim()) out.push(inner.slice(start).trim());
  return out;
}
// canonicalize Sui addresses inside a type string (strip leading zeros, lowercase hex) so
// "0x000…02::sui::SUI" and "0x2::sui::SUI" compare equal.
export const normType = (t: string) => t.replace(/0x0*([0-9a-fA-F]+)/g, (_m, h) => '0x' + h.toLowerCase());
export const sameType = (a: string, b: string) => normType(a) === normType(b);

// distinct coin types present among messages of a module fragment held by an inbox object
export async function coinTypesInInbox(inboxId: string, frag: string): Promise<string[]> {
  const seen: string[] = [];
  let cursor: any = null;
  do {
    const page = await client.getOwnedObjects({ owner: inboxId, cursor, options: { showType: true }, limit: 50 });
    for (const o of page.data) {
      const t = o.data?.type ?? '';
      if (!t.includes(frag)) continue;
      const c = typeArgsOf(t)[0];
      if (c && !seen.some((s) => sameType(s, c))) seen.push(c);
    }
    cursor = page.hasNextPage ? page.nextCursor : null;
  } while (cursor);
  return seen;
}

// ── PolicyEnsemble builder (configurable) ──
export interface EnsembleOpts {
  restPrice?: bigint;        // per-tenure rest price (mist)
  tenureMs?: bigint;         // tenure duration (ms)
  multi?: boolean;           // tenure_multi vs tenure_single
  handover?: 'off' | { fixed: bigint } | 'full_tenure';
  descent?: 'off' | { fixed: bigint };
  creditShape?: ShapeSpec;
  auctionShape?: ShapeSpec;
  escalation?: { fixed: bigint } | { compound: { bps: bigint; delta: bigint } };
}
export type ShapeSpec =
  | 'linear' | 'smoothstep' | 'logistic'
  | { power_law: { num: number; den: number } }
  | { exponential: { abs: number; neg: boolean } };

function shape(tx: Transaction, s: ShapeSpec) {
  if (s === 'linear') return tx.moveCall({ target: `${PKG}::ensemble::new_linear` });
  if (s === 'smoothstep') return tx.moveCall({ target: `${PKG}::ensemble::new_smoothstep` });
  if (s === 'logistic') return tx.moveCall({ target: `${PKG}::ensemble::new_logistic` });
  if ('power_law' in s) return tx.moveCall({ target: `${PKG}::ensemble::new_power_law`, arguments: [tx.pure.u8(s.power_law.num), tx.pure.u8(s.power_law.den)] });
  return tx.moveCall({ target: `${PKG}::ensemble::new_exponential`, arguments: [tx.pure.u8(s.exponential.abs), tx.pure.bool(s.exponential.neg)] });
}

export function buildEnsemble(tx: Transaction, o: EnsembleOpts = {}) {
  const price = (m: bigint) => tx.moveCall({ target: `${PKG}::ensemble::price`, arguments: [tx.pure.u64(m)] });
  const dur = (m: bigint) => tx.moveCall({ target: `${PKG}::ensemble::duration`, arguments: [tx.pure.u64(m)] });
  const restPrice = tx.moveCall({ target: `${PKG}::ensemble::new_rest_price_fixed`, arguments: [price(o.restPrice ?? 1_000n)] });
  const tenureDuration = tx.moveCall({ target: `${PKG}::ensemble::new_tenure_duration_fixed`, arguments: [dur(o.tenureMs ?? 60_000n)] });
  const tenureExtend = tx.moveCall({ target: `${PKG}::ensemble::${o.multi === false ? 'new_tenure_single' : 'new_tenure_multi'}` });
  const handover =
    o.handover === 'full_tenure' ? tx.moveCall({ target: `${PKG}::ensemble::new_handover_full_tenure` })
    : o.handover && typeof o.handover === 'object' ? tx.moveCall({ target: `${PKG}::ensemble::new_handover_fixed`, arguments: [dur(o.handover.fixed)] })
    : tx.moveCall({ target: `${PKG}::ensemble::new_handover_off` });
  const auctionWindow =
    o.descent && typeof o.descent === 'object' ? tx.moveCall({ target: `${PKG}::ensemble::new_descent_fixed`, arguments: [dur(o.descent.fixed)] })
    : tx.moveCall({ target: `${PKG}::ensemble::new_descent_off` });
  const creditShape = shape(tx, o.creditShape ?? 'linear');
  const auctionShape = shape(tx, o.auctionShape ?? 'linear');
  const escalation =
    o.escalation && 'compound' in o.escalation
      ? tx.moveCall({ target: `${PKG}::ensemble::new_price_compound_delta`, arguments: [tx.pure.u64(o.escalation.compound.bps), price(o.escalation.compound.delta)] })
      : tx.moveCall({ target: `${PKG}::ensemble::new_price_fixed_delta`, arguments: [price((o.escalation as any)?.fixed ?? 1n)] });
  return tx.moveCall({
    target: `${PKG}::ensemble::new_ensemble`,
    arguments: [restPrice, tenureDuration, tenureExtend, handover, auctionWindow, creditShape, auctionShape, escalation],
  });
}

// ── high-level operations ──
export async function integrate(signer: Ed25519Keypair, o: EnsembleOpts = {}, typeArgs = TYPE_ARGS) {
  const tx = new Transaction();
  const asset = tx.moveCall({ target: `${DUMMY_PKG}::dummy_asset::mint` });
  const ensemble = buildEnsemble(tx, o);
  const retireC = tx.moveCall({ target: `${PKG}::ensemble::new_retire_commitment_immediate` });
  const ensembleC = tx.moveCall({ target: `${PKG}::ensemble::new_ensemble_commitment_immediate` });
  const [govCap, inbox] = tx.moveCall({
    target: `${PKG}::escrow::integrate`, typeArguments: typeArgs,
    arguments: [asset, ensemble, retireC, ensembleC, tx.object(FEE_REF), tx.object(CLOCK)],
  });
  tx.transferObjects([govCap, inbox], addrOf(signer));
  const res = await send(tx, signer);
  return {
    escrowId: createdId(res, '::escrow::Escrow'),
    govCapId: createdId(res, '::governance_cap::GovernanceCap'),
    inboxId: createdId(res, '::earnings_inbox::EarningsInbox'),
    assetId: createdId(res, '::dummy_asset::DummyAsset'),
    digest: res.digest, res,
  };
}

// rent paying in DUMMY_COIN minted inline (free). For SUI coin axis use rentSui.
export async function rent(signer: Ed25519Keypair, escrowId: string, stake: bigint, n: bigint, typeArgs = TYPE_ARGS) {
  const tx = new Transaction();
  const payment = mintDummy(tx, stake);
  const tenures = tx.moveCall({ target: `${PKG}::ensemble::tenures`, arguments: [tx.pure.u64(n)] });
  const cap = tx.moveCall({
    target: `${PKG}::escrow::rent`, typeArguments: typeArgs,
    arguments: [tx.object(escrowId), payment, tenures, tx.object(CLOCK)],
  });
  tx.transferObjects([cap], addrOf(signer));
  const res = await send(tx, signer);
  return { capId: createdId(res, '::usufruct_cap::UsufructCap'), digest: res.digest, res };
}

export async function apply(signer: Ed25519Keypair, escrowId: string, typeArgs = TYPE_ARGS) {
  const tx = new Transaction();
  tx.moveCall({ target: `${PKG}::escrow::apply_pending_transition_states`, typeArguments: typeArgs, arguments: [tx.object(escrowId), tx.object(CLOCK)] });
  return await send(tx, signer);
}

export async function collectEarnings(signer: Ed25519Keypair, inboxId: string, coinT = COIN_T) {
  const refs: any[] = [];
  let cursor: any = null;
  do {
    const page = await client.getOwnedObjects({ owner: inboxId, cursor, options: { showType: true }, limit: 50 });
    for (const ob of page.data) {
      const t = ob.data?.type ?? '';
      // match the FULLY-QUALIFIED EarningsMessage<coinT> — a poly-coin inbox holds several coins;
      // mixing them into one Receiving<…<coinT>> vec aborts in 0x2::transfer::receive_impl.
      if (t.includes('earnings_message::EarningsMessage') && sameType(typeArgsOf(t)[0] ?? '', coinT))
        refs.push({ objectId: ob.data!.objectId, version: ob.data!.version, digest: ob.data!.digest });
    }
    cursor = page.hasNextPage ? page.nextCursor : null;
  } while (cursor);
  if (!refs.length) return { amount: 0n, refs: 0, res: null };
  const tx = new Transaction();
  const tickets = refs.map((r) => tx.receivingRef(r));
  const vec = tx.makeMoveVec({ type: `0x2::transfer::Receiving<${PKG}::earnings_message::EarningsMessage<${coinT}>>`, elements: tickets });
  const coin = tx.moveCall({ target: `${PKG}::earnings::collect_earnings_messages`, typeArguments: [coinT], arguments: [tx.object(inboxId), vec] });
  tx.transferObjects([coin], addrOf(signer));
  const res = await send(tx, signer);
  return { amount: sumEvent(res, 'EarningsMessageCollected'), refs: refs.length, res };
}

// ── Wave 2 helpers ──

// integrate another escrow into an existing cap+inbox portfolio (fleet)
export async function integrateIntoPortfolio(signer: Ed25519Keypair, govCapId: string, inboxId: string, o: EnsembleOpts = {}, typeArgs = TYPE_ARGS) {
  const tx = new Transaction();
  const asset = tx.moveCall({ target: `${DUMMY_PKG}::dummy_asset::mint` });
  const ensemble = buildEnsemble(tx, o);
  const retireC = tx.moveCall({ target: `${PKG}::ensemble::new_retire_commitment_immediate` });
  const ensembleC = tx.moveCall({ target: `${PKG}::ensemble::new_ensemble_commitment_immediate` });
  tx.moveCall({
    target: `${PKG}::escrow::integrate_into_portfolio`, typeArguments: typeArgs,
    arguments: [asset, ensemble, retireC, ensembleC, tx.object(FEE_REF), tx.object(govCapId), tx.object(inboxId), tx.object(CLOCK)],
  });
  const res = await send(tx, signer);
  return { escrowId: createdId(res, '::escrow::Escrow'), digest: res.digest, res };
}

export async function retire(signer: Ed25519Keypair, escrowId: string, govCapId: string, typeArgs = TYPE_ARGS) {
  const tx = new Transaction();
  tx.moveCall({ target: `${PKG}::escrow::retire`, typeArguments: typeArgs, arguments: [tx.object(escrowId), tx.object(govCapId), tx.object(CLOCK)] });
  return await send(tx, signer);
}

export function extendRetireCommitmentTx(escrowId: string, govCapId: string, deferMs: bigint, typeArgs = TYPE_ARGS) {
  const t = new Transaction();
  const d = t.moveCall({ target: `${PKG}::ensemble::duration`, arguments: [t.pure.u64(deferMs)] });
  const pol = t.moveCall({ target: `${PKG}::ensemble::new_retire_commitment_deferred`, arguments: [d] });
  t.moveCall({ target: `${PKG}::escrow::extend_retire_commitment`, typeArguments: typeArgs, arguments: [t.object(escrowId), t.object(govCapId), pol, t.object(CLOCK)] });
  return t;
}

export function extendEnsembleCommitmentTx(escrowId: string, govCapId: string, deferMs: bigint, typeArgs = TYPE_ARGS) {
  const t = new Transaction();
  const d = t.moveCall({ target: `${PKG}::ensemble::duration`, arguments: [t.pure.u64(deferMs)] });
  const pol = t.moveCall({ target: `${PKG}::ensemble::new_ensemble_commitment_deferred`, arguments: [d] });
  t.moveCall({ target: `${PKG}::escrow::extend_ensemble_commitment`, typeArguments: typeArgs, arguments: [t.object(escrowId), t.object(govCapId), pol, t.object(CLOCK)] });
  return t;
}

export function updateEnsembleTx(escrowId: string, govCapId: string, o: EnsembleOpts, typeArgs = TYPE_ARGS) {
  const t = new Transaction();
  const ens = buildEnsemble(t, o);
  t.moveCall({ target: `${PKG}::escrow::update_ensemble`, typeArguments: typeArgs, arguments: [t.object(escrowId), t.object(govCapId), ens, t.object(CLOCK)] });
  return t;
}

export function burnStaleCapTx(escrowId: string, capId: string, typeArgs = TYPE_ARGS) {
  const t = new Transaction();
  t.moveCall({ target: `${PKG}::escrow::burn_stale_usufruct_cap`, typeArguments: typeArgs, arguments: [t.object(escrowId), t.object(capId), t.object(CLOCK)] });
  return t;
}

// drain the ProtocolFeeInbox (deployer-owned) — V16, authorized
export async function collectFees(coinT = COIN_T) {
  const refs: any[] = [];
  let cursor: any = null;
  do {
    const page = await client.getOwnedObjects({ owner: FEE_INBOX, cursor, options: { showType: true }, limit: 50 });
    for (const ob of page.data) {
      const t = ob.data?.type ?? '';
      if (t.includes('fee_message::FeeMessage') && sameType(typeArgsOf(t)[0] ?? '', coinT))
        refs.push({ objectId: ob.data!.objectId, version: ob.data!.version, digest: ob.data!.digest });
    }
    cursor = page.hasNextPage ? page.nextCursor : null;
  } while (cursor);
  if (!refs.length) return { amount: 0n, refs: 0, res: null };
  const tx = new Transaction();
  const tickets = refs.map((r) => tx.receivingRef(r));
  const vec = tx.makeMoveVec({ type: `0x2::transfer::Receiving<${PKG}::fee_message::FeeMessage<${coinT}>>`, elements: tickets });
  const coin = tx.moveCall({ target: `${PKG}::fees::collect_fee_messages`, typeArguments: [coinT], arguments: [tx.object(FEE_INBOX), vec] });
  tx.transferObjects([coin], DEPLOYER);
  const res = await send(tx, deployer);
  return { amount: sumEvent(res, 'FeeMessageCollected'), refs: refs.length, res };
}

// ── coin-agnostic collection: discover every coin in an inbox, drain all in ONE PTB ──
// gather Receiving refs grouped by coin type for messages of a module fragment
async function refsByCoin(inboxId: string, frag: string): Promise<Map<string, any[]>> {
  const m = new Map<string, any[]>();
  let cursor: any = null;
  do {
    const page = await client.getOwnedObjects({ owner: inboxId, cursor, options: { showType: true }, limit: 50 });
    for (const o of page.data) {
      const t = o.data?.type ?? '';
      if (!t.includes(frag)) continue;
      const c = typeArgsOf(t)[0]; if (!c) continue;
      const key = [...m.keys()].find((k) => sameType(k, c)) ?? c;
      const arr = m.get(key) ?? []; arr.push({ objectId: o.data!.objectId, version: o.data!.version, digest: o.data!.digest }); m.set(key, arr);
    }
    cursor = page.hasNextPage ? page.nextCursor : null;
  } while (cursor);
  return m;
}
const coinTail = (t: string) => t.split('::').slice(-2).join('::').toLowerCase();
type CollectResult = { total: bigint; byCoin: { coin: string; refs: number; amount: bigint }[]; res: any };

// one moveCall per discovered coin type, all in a single PTB → O(1) txs per inbox
async function collectAll(inboxId: string, frag: string, collectTarget: string, collectModuleEvent: string, recipient: string, signer: Ed25519Keypair): Promise<CollectResult> {
  const groups = await refsByCoin(inboxId, frag);
  if (!groups.size) return { total: 0n, byCoin: [], res: null };
  const tx = new Transaction();
  const msgType = frag.endsWith('FeeMessage') ? `${PKG}::fee_message::FeeMessage` : `${PKG}::earnings_message::EarningsMessage`;
  for (const [coinT, refs] of groups) {
    const tickets = refs.map((r) => tx.receivingRef(r));
    const vec = tx.makeMoveVec({ type: `0x2::transfer::Receiving<${msgType}<${coinT}>>`, elements: tickets });
    const coin = tx.moveCall({ target: collectTarget, typeArguments: [coinT], arguments: [tx.object(inboxId), vec] });
    tx.transferObjects([coin], recipient);
  }
  const res = await send(tx, signer);
  const evs = events(res, collectModuleEvent);
  const byCoin = [...groups].map(([coin, refs]) => ({
    coin, refs: refs.length,
    amount: evs.filter((e: any) => e.coin_type && coinTail(e.coin_type) === coinTail(coin)).reduce((a: bigint, e: any) => a + BigInt(e.amount), 0n),
  }));
  return { total: evs.reduce((a: bigint, e: any) => a + BigInt(e.amount), 0n), byCoin, res };
}

// drain ALL coin types of one EarningsInbox in a single PTB
export const collectAllEarnings = (signer: Ed25519Keypair, inboxId: string) =>
  collectAll(inboxId, 'earnings_message::EarningsMessage', `${PKG}::earnings::collect_earnings_messages`, 'EarningsMessageCollected', addrOf(signer), signer);

// drain ALL coin types of the deployer ProtocolFeeInbox in a single PTB
export const collectAllFees = () =>
  collectAll(FEE_INBOX, 'fee_message::FeeMessage', `${PKG}::fees::collect_fee_messages`, 'FeeMessageCollected', DEPLOYER, deployer);

// ── views (devInspect) ──
export async function view(fn: string, escrowId: string, extra: any[] = [], typeArgs = TYPE_ARGS, sender = MOTHER): Promise<number[] | undefined> {
  const tx = new Transaction();
  tx.moveCall({ target: `${PKG}::escrow::${fn}`, typeArguments: typeArgs, arguments: [tx.object(escrowId), ...extra] });
  const res = await client.devInspectTransactionBlock({ transactionBlock: tx, sender });
  return res.results?.[0]?.returnValues?.[0]?.[0] as number[] | undefined;
}
export const decBool = (b?: number[]) => Array.isArray(b) && b[0] === 1;
export const decU64 = (b?: number[]) => (Array.isArray(b) ? Buffer.from(b.slice(0, 8)).readBigUInt64LE(0) : null);
export const decOptU64 = (b?: number[]) => (!Array.isArray(b) || b[0] === 0 ? null : Buffer.from(b.slice(1, 9)).readBigUInt64LE(0));
export const decOptAddr = (b?: number[]) => (!Array.isArray(b) || b[0] === 0 ? null : '0x' + Buffer.from(b.slice(1, 33)).toString('hex'));

export const viewBool = async (fn: string, e: string, extra: any[] = [], ta = TYPE_ARGS) => decBool(await view(fn, e, extra, ta));
export const viewOptU64 = async (fn: string, e: string, extra: any[] = [], ta = TYPE_ARGS) => decOptU64(await view(fn, e, extra, ta));
export const viewU64 = async (fn: string, e: string, extra: any[] = [], ta = TYPE_ARGS) => decU64(await view(fn, e, extra, ta));

// ── misc ──
export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
export const sui = (n: number) => BigInt(Math.round(n * 1e9));

// ── reporting ──
let PASS = 0, FAIL = 0;
export function pass(msg: string) { PASS++; console.log(`  \x1b[32m✓ PASS\x1b[0m ${msg}`); }
export function finding(msg: string) { FAIL++; console.log(`  \x1b[31m⚠ FINDING\x1b[0m ${msg}`); }
export function info(msg: string) { console.log(`  · ${msg}`); }
export function head(msg: string) { console.log(`\n\x1b[1m${msg}\x1b[0m`); }
export function summary() { console.log(`\n── ${PASS} pass · ${FAIL} findings ──`); return { PASS, FAIL }; }

// asset_state.move error constants (code → name), from sources (verified bytecode).
export const ASSET_STATE_ERR: Record<number, string> = {
  0: 'ENotRented', 1: 'EInsufficientPayment', 2: 'ERetireFlagBlocksBid', 3: 'ERetiredNoBid',
  4: 'ERetireCommitmentFloorNotElapsed', 5: 'EAlreadyRetired', 6: 'EWrongEscrowUsufructCap',
  7: 'EPendingUsufructCap', 8: 'EStaleUsufructCap', 9: 'EUsufructCapNotStale',
  10: 'EReceiptEscrowMismatch', 11: 'EWrongEscrowGovernanceCap', 12: 'ENotRetired',
  13: 'ERetireAlreadyScheduled', 14: 'ERetireCommitmentNotExtended', 15: 'EReturnedDifferentAsset',
  16: 'EAlreadyRetiring', 17: 'EUsufructCapStale', 18: 'EEnsembleCommitmentFloorNotElapsed',
  19: 'EEnsembleCommitmentNotExtended',
};
const NAME2CODE: Record<string, number> = Object.fromEntries(Object.entries(ASSET_STATE_ERR).map(([c, n]) => [n, Number(c)]));

// parse the numeric abort code + module from a Sui error string
export function parseAbort(e?: string): { code?: number; module?: string; name?: string } {
  if (!e) return {};
  const mod = e.match(/name:\s*Identifier\("([a-z_]+)"\)/)?.[1];
  // the abort code is the integer right after the closing of MoveLocation: `}, <code>)`
  const code = e.match(/\},\s*(\d+)\s*\)/);
  const c = code ? Number(code[1]) : undefined;
  return { code: c, module: mod, name: c !== undefined && mod === 'asset_state' ? ASSET_STATE_ERR[c] : undefined };
}

// assert an abort happened with the expected error constant (verified by code, not substring)
export function expectAbort(r: { ok: boolean; error?: string }, expectedErr: string, label: string) {
  if (r.ok) { finding(`${label}: expected abort (${expectedErr}) but tx SUCCEEDED`); return false; }
  const p = parseAbort(r.error);
  const expectedCode = NAME2CODE[expectedErr];
  if (p.code !== undefined && expectedCode !== undefined && p.code === expectedCode && (p.module === 'asset_state' || !p.module))
    pass(`${label}: aborted ${expectedErr} (code ${p.code}, ${p.module})`);
  else if (p.code !== undefined)
    finding(`${label}: aborted code ${p.code}=${p.name ?? '?'} in ${p.module} — EXPECTED ${expectedErr}(${expectedCode})`);
  else
    pass(`${label}: aborted [${truncErr(r.error)}] (expected ${expectedErr}; non-Move abort)`);
  return true;
}
export const truncErr = (e?: string) => (e ?? '').replace(/\s+/g, ' ').slice(0, 200);
