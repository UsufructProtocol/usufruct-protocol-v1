import { writeFileSync }  from 'fs';
import { SuiClient }      from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction }    from '@mysten/sui/transactions';

// Setup helper: sign + execute + explicit waitForTransaction.
export async function execSetup(
  client: SuiClient,
  signer: Ed25519Keypair,
  tx:     Transaction,
): Promise<{ objectChanges: any[] }> {
  tx.setGasBudget(200_000_000n);
  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    options: { showObjectChanges: true },
  });
  await client.waitForTransaction({ digest: result.digest });
  return { objectChanges: result.objectChanges ?? [] };
}

export interface GasRecord {
  op:             string;
  run:            number;
  computation:    bigint;
  storage:        bigint;
  rebate:         bigint;
  nonRefundable:  bigint;
  net:            bigint;
  objectsCreated: number;
  objectsDeleted: number;
  digest:         string;
}

// Time-dependent ops (apply firing a settlement after a tenure expiry) build
// their gas estimate from a dry-run taken BEFORE the boundary is crossed, so the
// SDK auto-budget can underestimate the post-expiry cost and abort with
// InsufficientGas. An explicit, generous budget removes that dependency without
// affecting the measured numbers — gas *used* (computation/storage/rebate) is
// independent of the budget as long as budget ≥ cost.
const GAS_BUDGET = 200_000_000n;

export async function measure(
  client: SuiClient,
  signer: Ed25519Keypair,
  op:     string,
  run:    number,
  tx:     Transaction,
): Promise<GasRecord> {
  tx.setGasBudget(GAS_BUDGET);
  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    options: { showEffects: true, showObjectChanges: true },
  });

  await client.waitForTransaction({ digest: result.digest });

  if (result.effects?.status.status !== 'success') {
    throw new Error(`[${op} run ${run}] tx failed: ${result.effects?.status.error}`);
  }

  const g       = result.effects!.gasUsed;
  const changes = result.objectChanges ?? [];

  return {
    op,
    run,
    computation:    BigInt(g.computationCost),
    storage:        BigInt(g.storageCost),
    rebate:         BigInt(g.storageRebate),
    nonRefundable:  BigInt(g.nonRefundableStorageFee),
    net:            BigInt(g.computationCost) + BigInt(g.storageCost) - BigInt(g.storageRebate),
    objectsCreated: changes.filter(c => c.type === 'created').length,
    objectsDeleted: changes.filter(c => c.type === 'deleted').length,
    digest:         result.digest,
  };
}

export function median(records: GasRecord[]): GasRecord {
  if (records.length === 0) throw new Error('empty records');
  const sorted = [...records].sort((a, b) => (a.net < b.net ? -1 : a.net > b.net ? 1 : 0));
  return sorted[Math.floor(sorted.length / 2)];
}

export function saveRecords(path: string, records: GasRecord[]): void {
  const serializable = records.map(r => ({
    ...r,
    computation:   r.computation.toString(),
    storage:       r.storage.toString(),
    rebate:        r.rebate.toString(),
    nonRefundable: r.nonRefundable.toString(),
    net:           r.net.toString(),
  }));
  writeFileSync(path, JSON.stringify(serializable, null, 2));
}
