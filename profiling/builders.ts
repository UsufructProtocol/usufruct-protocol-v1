import { Transaction } from '@mysten/sui/transactions';
import type { TransactionArgument } from '@mysten/sui/transactions';
import {
  CLOCK_ID,
  FLOOR_PRICE_MIST, TENURE_DURATION_MS, HANDOVER_FLOOR_MS, DELTA_PRICE_MIST,
} from './env.ts';

// All constructors route through the public ensemble API layer.
function priceArg(tx: Transaction, pkg: string, mist: bigint): TransactionArgument {
  return tx.moveCall({
    target: `${pkg}::ensemble::price`,
    arguments: [tx.pure.u64(mist)],
  });
}
function durationArg(tx: Transaction, pkg: string, ms: bigint): TransactionArgument {
  return tx.moveCall({
    target: `${pkg}::ensemble::duration`,
    arguments: [tx.pure.u64(ms)],
  });
}

export function clock(tx: Transaction)  { return tx.object(CLOCK_ID);  }

// Builds the minimal PolicyEnsemble for profiling (HandoverPolicy::Off).
export function buildMinimalEnsemble(tx: Transaction, pkg: string): TransactionArgument {
  const restPrice = tx.moveCall({
    target: `${pkg}::ensemble::new_rest_price_fixed`,
    arguments: [priceArg(tx, pkg, FLOOR_PRICE_MIST)],
  });
  const tenureDuration = tx.moveCall({
    target: `${pkg}::ensemble::new_tenure_duration_fixed`,
    arguments: [durationArg(tx, pkg, TENURE_DURATION_MS)],
  });
  const tenureExtend = tx.moveCall({ target: `${pkg}::ensemble::new_tenure_multi` });
  const handover     = tx.moveCall({ target: `${pkg}::ensemble::new_handover_off` });
  const auctionWin   = tx.moveCall({ target: `${pkg}::ensemble::new_descent_off` });
  const creditShape  = tx.moveCall({ target: `${pkg}::ensemble::new_linear` });
  const auctionShape = tx.moveCall({ target: `${pkg}::ensemble::new_linear` });
  const escalation   = tx.moveCall({
    target: `${pkg}::ensemble::new_price_fixed_delta`,
    arguments: [priceArg(tx, pkg, DELTA_PRICE_MIST)],
  });
  return tx.moveCall({
    target: `${pkg}::ensemble::new_ensemble`,
    arguments: [restPrice, tenureDuration, tenureExtend, handover, auctionWin, creditShape, auctionShape, escalation],
  });
}

// Builds a PolicyEnsemble with HandoverPolicy::Fixed (needed for burn_stale tests).
export function buildHandoverEnsemble(tx: Transaction, pkg: string): TransactionArgument {
  const restPrice = tx.moveCall({
    target: `${pkg}::ensemble::new_rest_price_fixed`,
    arguments: [priceArg(tx, pkg, FLOOR_PRICE_MIST)],
  });
  const tenureDuration = tx.moveCall({
    target: `${pkg}::ensemble::new_tenure_duration_fixed`,
    arguments: [durationArg(tx, pkg, TENURE_DURATION_MS)],
  });
  const tenureExtend = tx.moveCall({ target: `${pkg}::ensemble::new_tenure_multi` });
  const handover     = tx.moveCall({
    target: `${pkg}::ensemble::new_handover_fixed`,
    arguments: [durationArg(tx, pkg, HANDOVER_FLOOR_MS)],
  });
  const auctionWin   = tx.moveCall({ target: `${pkg}::ensemble::new_descent_off` });
  const creditShape  = tx.moveCall({ target: `${pkg}::ensemble::new_linear` });
  const auctionShape = tx.moveCall({ target: `${pkg}::ensemble::new_linear` });
  const escalation   = tx.moveCall({
    target: `${pkg}::ensemble::new_price_fixed_delta`,
    arguments: [priceArg(tx, pkg, DELTA_PRICE_MIST)],
  });
  return tx.moveCall({
    target: `${pkg}::ensemble::new_ensemble`,
    arguments: [restPrice, tenureDuration, tenureExtend, handover, auctionWin, creditShape, auctionShape, escalation],
  });
}

// Short tenure (2s) for b_flow profiling — allows lifecycle to complete without waiting 1h.
// Gas costs are tenure-duration-independent, so measurements remain valid.
export const FLOW_TENURE_MS = 10_000n; // 10s — long enough for in-tenure ops, short enough to not wait hours

export function buildFlowEnsemble(tx: Transaction, pkg: string): TransactionArgument {
  const p = (mist: bigint) =>
    tx.moveCall({ target: `${pkg}::ensemble::price`, arguments: [tx.pure.u64(mist)] });
  const d = (ms: bigint) =>
    tx.moveCall({ target: `${pkg}::ensemble::duration`, arguments: [tx.pure.u64(ms)] });

  const restPrice      = tx.moveCall({ target: `${pkg}::ensemble::new_rest_price_fixed`,      arguments: [p(FLOOR_PRICE_MIST)] });
  const tenureDuration = tx.moveCall({ target: `${pkg}::ensemble::new_tenure_duration_fixed`, arguments: [d(FLOW_TENURE_MS)] });
  const tenureExtend   = tx.moveCall({ target: `${pkg}::ensemble::new_tenure_multi` });
  const handover       = tx.moveCall({ target: `${pkg}::ensemble::new_handover_off` });
  const auctionWin     = tx.moveCall({ target: `${pkg}::ensemble::new_descent_off` });
  const creditShape    = tx.moveCall({ target: `${pkg}::ensemble::new_linear` });
  const auctionShape   = tx.moveCall({ target: `${pkg}::ensemble::new_linear` });
  const escalation     = tx.moveCall({ target: `${pkg}::ensemble::new_price_fixed_delta`, arguments: [p(DELTA_PRICE_MIST)] });
  return tx.moveCall({
    target: `${pkg}::ensemble::new_ensemble`,
    arguments: [restPrice, tenureDuration, tenureExtend, handover, auctionWin, creditShape, auctionShape, escalation],
  });
}

export function buildFlowHandoverEnsemble(tx: Transaction, pkg: string): TransactionArgument {
  const p = (mist: bigint) =>
    tx.moveCall({ target: `${pkg}::ensemble::price`, arguments: [tx.pure.u64(mist)] });
  const d = (ms: bigint) =>
    tx.moveCall({ target: `${pkg}::ensemble::duration`, arguments: [tx.pure.u64(ms)] });

  const restPrice      = tx.moveCall({ target: `${pkg}::ensemble::new_rest_price_fixed`,      arguments: [p(FLOOR_PRICE_MIST)] });
  const tenureDuration = tx.moveCall({ target: `${pkg}::ensemble::new_tenure_duration_fixed`, arguments: [d(FLOW_TENURE_MS)] });
  const tenureExtend   = tx.moveCall({ target: `${pkg}::ensemble::new_tenure_multi` });
  const handover       = tx.moveCall({ target: `${pkg}::ensemble::new_handover_full_tenure` });
  const auctionWin     = tx.moveCall({ target: `${pkg}::ensemble::new_descent_off` });
  const creditShape    = tx.moveCall({ target: `${pkg}::ensemble::new_linear` });
  const auctionShape   = tx.moveCall({ target: `${pkg}::ensemble::new_linear` });
  const escalation     = tx.moveCall({ target: `${pkg}::ensemble::new_price_fixed_delta`, arguments: [p(DELTA_PRICE_MIST)] });
  return tx.moveCall({
    target: `${pkg}::ensemble::new_ensemble`,
    arguments: [restPrice, tenureDuration, tenureExtend, handover, auctionWin, creditShape, auctionShape, escalation],
  });
}

export function buildImmediateRetireCommitment(tx: Transaction, pkg: string): TransactionArgument {
  return tx.moveCall({ target: `${pkg}::ensemble::new_retire_commitment_immediate` });
}

export function buildImmediateEnsembleCommitment(tx: Transaction, pkg: string): TransactionArgument {
  return tx.moveCall({ target: `${pkg}::ensemble::new_ensemble_commitment_immediate` });
}

// Integrates a DummyAsset into a NEW portfolio. Mints the pair: returns both the
// GovernanceCap (governance) and the EarningsInbox (income sink) results — inbox-first
// model, escrow::integrate now returns (GovernanceCap, EarningsInbox).
export function buildIntegrate(
  tx:             Transaction,
  usufructPkg:    string,
  dummyAssetPkg:  string,
  feeRefId:       string,
  ensembleBuilder: (tx: Transaction, pkg: string) => TransactionArgument = buildMinimalEnsemble,
): { governanceCap: TransactionArgument; inbox: TransactionArgument } {
  const asset              = tx.moveCall({ target: `${dummyAssetPkg}::dummy_asset::mint` });
  const ensemble           = ensembleBuilder(tx, usufructPkg);
  const retireCommitment   = buildImmediateRetireCommitment(tx, usufructPkg);
  const ensembleCommitment = buildImmediateEnsembleCommitment(tx, usufructPkg);
  const feeRef             = tx.object(feeRefId);

  const [governanceCap, inbox] = tx.moveCall({
    target: `${usufructPkg}::escrow::integrate`,
    typeArguments: [
      `${dummyAssetPkg}::dummy_asset::DummyAsset`,
      '0x2::sui::SUI',
    ],
    arguments: [asset, ensemble, retireCommitment, ensembleCommitment, feeRef, clock(tx)],
  });
  return { governanceCap, inbox };
}

// Integrates a DummyAsset into an EXISTING portfolio: routes its governance to
// `governanceCapId` and its income to `inboxId`. Mints nothing (the pair already exists);
// escrow::integrate_into_portfolio takes both by reference and returns ().
export function buildIntegrateIntoPortfolio(
  tx:             Transaction,
  usufructPkg:    string,
  dummyAssetPkg:  string,
  feeRefId:       string,
  governanceCapId:     string,
  inboxId:        string,
  ensembleBuilder: (tx: Transaction, pkg: string) => TransactionArgument = buildMinimalEnsemble,
): void {
  const asset              = tx.moveCall({ target: `${dummyAssetPkg}::dummy_asset::mint` });
  const ensemble           = ensembleBuilder(tx, usufructPkg);
  const retireCommitment   = buildImmediateRetireCommitment(tx, usufructPkg);
  const ensembleCommitment = buildImmediateEnsembleCommitment(tx, usufructPkg);
  const feeRef             = tx.object(feeRefId);

  tx.moveCall({
    target: `${usufructPkg}::escrow::integrate_into_portfolio`,
    typeArguments: [
      `${dummyAssetPkg}::dummy_asset::DummyAsset`,
      '0x2::sui::SUI',
    ],
    arguments: [asset, ensemble, retireCommitment, ensembleCommitment, feeRef, tx.object(governanceCapId), tx.object(inboxId), clock(tx)],
  });
}

// Rents an escrow for 1 tenure. Returns UsufructCap result.
export function buildRent(
  tx:          Transaction,
  usufructPkg: string,
  dummyPkg:    string,
  escrowId:    string,
): TransactionArgument {
  const [payment] = tx.splitCoins(tx.gas, [tx.pure.u64(FLOOR_PRICE_MIST)]);
  const tenures   = tx.moveCall({
    target: `${usufructPkg}::ensemble::tenures`,
    arguments: [tx.pure.u64(1n)],
  });
  return tx.moveCall({
    target: `${usufructPkg}::escrow::rent`,
    typeArguments: [`${dummyPkg}::dummy_asset::DummyAsset`, '0x2::sui::SUI'],
    arguments: [tx.object(escrowId), payment, tenures, clock(tx)],
  });
}
