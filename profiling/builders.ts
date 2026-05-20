import { Transaction } from '@mysten/sui/transactions';
import type { TransactionArgument } from '@mysten/sui/transactions';
import {
  CLOCK_ID, RANDOM_ID,
  FLOOR_PRICE_MIST, TENURE_DURATION_MS, HANDOVER_FLOOR_MS, DELTA_PRICE_MIST,
} from './env.ts';

// monetary::price() and phases::duration() are now public — use Move calls, not BCS pure.
function priceArg(tx: Transaction, pkg: string, mist: bigint): TransactionArgument {
  return tx.moveCall({
    target: `${pkg}::monetary::price`,
    arguments: [tx.pure.u64(mist)],
  });
}
function durationArg(tx: Transaction, pkg: string, ms: bigint): TransactionArgument {
  return tx.moveCall({
    target: `${pkg}::phases::duration`,
    arguments: [tx.pure.u64(ms)],
  });
}

export function clock(tx: Transaction)  { return tx.object(CLOCK_ID);  }
export function random(tx: Transaction) { return tx.object(RANDOM_ID); }

// Builds the minimal PolicyEnsemble for profiling (HandoverPolicy::Off).
export function buildMinimalEnsemble(tx: Transaction, pkg: string): TransactionArgument {
  const restPrice = tx.moveCall({
    target: `${pkg}::rest_price_policy::new_fixed`,
    arguments: [priceArg(tx, pkg, FLOOR_PRICE_MIST)],
  });
  const tenureDuration = tx.moveCall({
    target: `${pkg}::tenure_duration_policy::new_fixed`,
    arguments: [durationArg(tx, pkg, TENURE_DURATION_MS)],
  });
  const tenureExtend = tx.moveCall({ target: `${pkg}::tenure_extend_policy::new_multi` });
  const handover     = tx.moveCall({ target: `${pkg}::handover_policy::new_handover_off` });
  const auctionWin   = tx.moveCall({ target: `${pkg}::auction_window_policy::new_descent_off` });
  const creditShape  = tx.moveCall({ target: `${pkg}::curve_shape_policy::new_linear` });
  const auctionShape = tx.moveCall({ target: `${pkg}::curve_shape_policy::new_linear` });
  const escalation   = tx.moveCall({
    target: `${pkg}::price_escalation_policy::new_fixed_delta`,
    arguments: [priceArg(tx, pkg, DELTA_PRICE_MIST)],
  });
  return tx.moveCall({
    target: `${pkg}::policy_ensemble::new_ensemble`,
    arguments: [restPrice, tenureDuration, tenureExtend, handover, auctionWin, creditShape, auctionShape, escalation],
  });
}

// Builds a PolicyEnsemble with HandoverPolicy::Fixed (needed for soft_burn tests).
export function buildHandoverEnsemble(tx: Transaction, pkg: string): TransactionArgument {
  const restPrice = tx.moveCall({
    target: `${pkg}::rest_price_policy::new_fixed`,
    arguments: [priceArg(tx, pkg, FLOOR_PRICE_MIST)],
  });
  const tenureDuration = tx.moveCall({
    target: `${pkg}::tenure_duration_policy::new_fixed`,
    arguments: [durationArg(tx, pkg, TENURE_DURATION_MS)],
  });
  const tenureExtend = tx.moveCall({ target: `${pkg}::tenure_extend_policy::new_multi` });
  const handover     = tx.moveCall({
    target: `${pkg}::handover_policy::new_handover_fixed`,
    arguments: [durationArg(tx, pkg, HANDOVER_FLOOR_MS)],
  });
  const auctionWin   = tx.moveCall({ target: `${pkg}::auction_window_policy::new_descent_off` });
  const creditShape  = tx.moveCall({ target: `${pkg}::curve_shape_policy::new_linear` });
  const auctionShape = tx.moveCall({ target: `${pkg}::curve_shape_policy::new_linear` });
  const escalation   = tx.moveCall({
    target: `${pkg}::price_escalation_policy::new_fixed_delta`,
    arguments: [priceArg(tx, pkg, DELTA_PRICE_MIST)],
  });
  return tx.moveCall({
    target: `${pkg}::policy_ensemble::new_ensemble`,
    arguments: [restPrice, tenureDuration, tenureExtend, handover, auctionWin, creditShape, auctionShape, escalation],
  });
}

// Short tenure (2s) for b_flow profiling — allows lifecycle to complete without waiting 1h.
// Gas costs are tenure-duration-independent, so measurements remain valid.
export const FLOW_TENURE_MS = 10_000n; // 10s — long enough for in-tenure ops, short enough to not wait hours

export function buildFlowEnsemble(tx: Transaction, pkg: string): TransactionArgument {
  const p = (mist: bigint) =>
    tx.moveCall({ target: `${pkg}::monetary::price`, arguments: [tx.pure.u64(mist)] });
  const d = (ms: bigint) =>
    tx.moveCall({ target: `${pkg}::phases::duration`, arguments: [tx.pure.u64(ms)] });

  const restPrice      = tx.moveCall({ target: `${pkg}::rest_price_policy::new_fixed`,          arguments: [p(FLOOR_PRICE_MIST)] });
  const tenureDuration = tx.moveCall({ target: `${pkg}::tenure_duration_policy::new_fixed`,     arguments: [d(FLOW_TENURE_MS)] });
  const tenureExtend   = tx.moveCall({ target: `${pkg}::tenure_extend_policy::new_multi` });
  const handover       = tx.moveCall({ target: `${pkg}::handover_policy::new_handover_off` });
  const auctionWin     = tx.moveCall({ target: `${pkg}::auction_window_policy::new_descent_off` });
  const creditShape    = tx.moveCall({ target: `${pkg}::curve_shape_policy::new_linear` });
  const auctionShape   = tx.moveCall({ target: `${pkg}::curve_shape_policy::new_linear` });
  const escalation     = tx.moveCall({ target: `${pkg}::price_escalation_policy::new_fixed_delta`, arguments: [p(DELTA_PRICE_MIST)] });
  return tx.moveCall({
    target: `${pkg}::policy_ensemble::new_ensemble`,
    arguments: [restPrice, tenureDuration, tenureExtend, handover, auctionWin, creditShape, auctionShape, escalation],
  });
}

export function buildFlowHandoverEnsemble(tx: Transaction, pkg: string): TransactionArgument {
  const p = (mist: bigint) =>
    tx.moveCall({ target: `${pkg}::monetary::price`, arguments: [tx.pure.u64(mist)] });
  const d = (ms: bigint) =>
    tx.moveCall({ target: `${pkg}::phases::duration`, arguments: [tx.pure.u64(ms)] });

  const restPrice      = tx.moveCall({ target: `${pkg}::rest_price_policy::new_fixed`,          arguments: [p(FLOOR_PRICE_MIST)] });
  const tenureDuration = tx.moveCall({ target: `${pkg}::tenure_duration_policy::new_fixed`,     arguments: [d(FLOW_TENURE_MS)] });
  const tenureExtend   = tx.moveCall({ target: `${pkg}::tenure_extend_policy::new_multi` });
  const handover       = tx.moveCall({ target: `${pkg}::handover_policy::new_handover_full_tenure` });
  const auctionWin     = tx.moveCall({ target: `${pkg}::auction_window_policy::new_descent_off` });
  const creditShape    = tx.moveCall({ target: `${pkg}::curve_shape_policy::new_linear` });
  const auctionShape   = tx.moveCall({ target: `${pkg}::curve_shape_policy::new_linear` });
  const escalation     = tx.moveCall({ target: `${pkg}::price_escalation_policy::new_fixed_delta`, arguments: [p(DELTA_PRICE_MIST)] });
  return tx.moveCall({
    target: `${pkg}::policy_ensemble::new_ensemble`,
    arguments: [restPrice, tenureDuration, tenureExtend, handover, auctionWin, creditShape, auctionShape, escalation],
  });
}

export function buildImmediateCommitment(tx: Transaction, pkg: string): TransactionArgument {
  return tx.moveCall({ target: `${pkg}::commitment_policy::new_immediate` });
}

// Integrates a DummyAsset into a new escrow. Returns the OwnerCap result.
export function buildIntegrate(
  tx:             Transaction,
  usufructPkg:    string,
  dummyAssetPkg:  string,
  feeRefId:       string,
  ensembleBuilder: (tx: Transaction, pkg: string) => TransactionArgument = buildMinimalEnsemble,
): TransactionArgument {
  const asset      = tx.moveCall({ target: `${dummyAssetPkg}::dummy_asset::mint` });
  const ensemble   = ensembleBuilder(tx, usufructPkg);
  const commitment = buildImmediateCommitment(tx, usufructPkg);
  const feeRef     = tx.object(feeRefId);

  return tx.moveCall({
    target: `${usufructPkg}::escrow::integrate`,
    typeArguments: [
      `${dummyAssetPkg}::dummy_asset::DummyAsset`,
      '0x2::sui::SUI',
    ],
    arguments: [asset, ensemble, commitment, feeRef, random(tx), clock(tx)],
  });
}

// Rents an escrow for 1 tenure. Returns TenantCap result.
export function buildRent(
  tx:          Transaction,
  usufructPkg: string,
  dummyPkg:    string,
  escrowId:    string,
): TransactionArgument {
  const [payment] = tx.splitCoins(tx.gas, [tx.pure.u64(FLOOR_PRICE_MIST)]);
  const cycles    = tx.moveCall({
    target: `${usufructPkg}::tenures::tenures`,
    arguments: [tx.pure.u64(1n)],
  });
  return tx.moveCall({
    target: `${usufructPkg}::escrow::rent`,
    typeArguments: [`${dummyPkg}::dummy_asset::DummyAsset`, '0x2::sui::SUI'],
    arguments: [tx.object(escrowId), payment, cycles, random(tx), clock(tx)],
  });
}
