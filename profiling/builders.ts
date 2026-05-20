import { bcs }         from '@mysten/sui/bcs';
import { Transaction } from '@mysten/sui/transactions';
import type { TransactionArgument } from '@mysten/sui/transactions';
import {
  CLOCK_ID, RANDOM_ID,
  FLOOR_PRICE_MIST, TENURE_DURATION_MS, HANDOVER_FLOOR_MS, DELTA_PRICE_MIST,
} from './env.ts';

// Price and Duration are single-field structs — their BCS encoding equals their inner u64.
function pricePure(tx: Transaction, mist: bigint): TransactionArgument {
  return tx.pure(bcs.u64().serialize(mist));
}
function durationPure(tx: Transaction, ms: bigint): TransactionArgument {
  return tx.pure(bcs.u64().serialize(ms));
}

export function clock(tx: Transaction)  { return tx.object(CLOCK_ID);  }
export function random(tx: Transaction) { return tx.object(RANDOM_ID); }

// Builds the minimal PolicyEnsemble for profiling (HandoverPolicy::Off).
export function buildMinimalEnsemble(tx: Transaction, pkg: string): TransactionArgument {
  const restPrice = tx.moveCall({
    target: `${pkg}::rest_price_policy::new_fixed`,
    arguments: [pricePure(tx, FLOOR_PRICE_MIST)],
  });
  const tenureDuration = tx.moveCall({
    target: `${pkg}::tenure_duration_policy::new_fixed`,
    arguments: [durationPure(tx, TENURE_DURATION_MS)],
  });
  const tenureExtend = tx.moveCall({ target: `${pkg}::tenure_extend_policy::new_multi` });
  const handover     = tx.moveCall({ target: `${pkg}::handover_policy::new_handover_off` });
  const auctionWin   = tx.moveCall({ target: `${pkg}::auction_window_policy::new_descent_off` });
  const creditShape  = tx.moveCall({ target: `${pkg}::curve_shape_policy::new_linear` });
  const auctionShape = tx.moveCall({ target: `${pkg}::curve_shape_policy::new_linear` });
  const escalation   = tx.moveCall({
    target: `${pkg}::price_escalation_policy::new_fixed_delta`,
    arguments: [pricePure(tx, DELTA_PRICE_MIST)],
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
    arguments: [pricePure(tx, FLOOR_PRICE_MIST)],
  });
  const tenureDuration = tx.moveCall({
    target: `${pkg}::tenure_duration_policy::new_fixed`,
    arguments: [durationPure(tx, TENURE_DURATION_MS)],
  });
  const tenureExtend = tx.moveCall({ target: `${pkg}::tenure_extend_policy::new_multi` });
  const handover     = tx.moveCall({
    target: `${pkg}::handover_policy::new_handover_fixed`,
    arguments: [durationPure(tx, HANDOVER_FLOOR_MS)],
  });
  const auctionWin   = tx.moveCall({ target: `${pkg}::auction_window_policy::new_descent_off` });
  const creditShape  = tx.moveCall({ target: `${pkg}::curve_shape_policy::new_linear` });
  const auctionShape = tx.moveCall({ target: `${pkg}::curve_shape_policy::new_linear` });
  const escalation   = tx.moveCall({
    target: `${pkg}::price_escalation_policy::new_fixed_delta`,
    arguments: [pricePure(tx, DELTA_PRICE_MIST)],
  });
  return tx.moveCall({
    target: `${pkg}::policy_ensemble::new_ensemble`,
    arguments: [restPrice, tenureDuration, tenureExtend, handover, auctionWin, creditShape, auctionShape, escalation],
  });
}

export function buildImmediateCommitment(tx: Transaction, pkg: string): TransactionArgument {
  return tx.moveCall({ target: `${pkg}::commitment_policy::new_immediate` });
}

// Integrates a DummyAsset into a new escrow. Returns the OwnerCap result.
// The Escrow is shared automatically by the Move call.
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
  const escrow  = tx.object(escrowId);
  const [payment] = tx.splitCoins(tx.gas, [tx.pure.u64(FLOOR_PRICE_MIST)]);
  const cycles  = tx.moveCall({
    target: `${usufructPkg}::tenures::tenures`,
    arguments: [tx.pure.u64(1n)],
  });
  return tx.moveCall({
    target: `${usufructPkg}::escrow::rent`,
    typeArguments: [`${dummyPkg}::dummy_asset::DummyAsset`, '0x2::sui::SUI'],
    arguments: [escrow, payment, cycles, random(tx), clock(tx)],
  });
}
