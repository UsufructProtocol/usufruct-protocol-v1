#!/usr/bin/env tsx
/**
 * Deploys usufruct + dummy_asset to the active network and writes deployment.json.
 * Uses the Sui SDK directly so the generated owner keypair signs everything.
 *
 * Usage: npm run setup:deploy
 *   SUI_RPC=https://fullnode.testnet.sui.io:443 npm run setup:deploy
 */

import { execSync }        from 'child_process';
import { writeFileSync }   from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath }   from 'url';
import { SuiClient }       from '@mysten/sui/client';
import { Ed25519Keypair }  from '@mysten/sui/keypairs/ed25519';
import { Transaction }     from '@mysten/sui/transactions';
import { RPC_URL, FAUCET_URL } from '../env.ts';

const DIR  = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(DIR, '..');

const client = new SuiClient({ url: RPC_URL });

async function requestFaucet(address: string): Promise<void> {
  const res = await fetch(FAUCET_URL, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify({ FixedAmountRequest: { recipient: address } }),
  });
  if (!res.ok) throw new Error(`Faucet failed for ${address}: ${await res.text()}`);
  await new Promise(r => setTimeout(r, 2000));
}

function buildBytecode(packagePath: string): { modules: string[]; dependencies: string[] } {
  const output = execSync(
    `sui move build --dump-bytecode-as-base64 --path ${packagePath}`,
    { encoding: 'utf8', stdio: ['pipe', 'pipe', 'ignore'] },
  ).trim();
  return JSON.parse(output) as { modules: string[]; dependencies: string[] };
}

async function publishPackage(
  signer: Ed25519Keypair,
  packagePath: string,
): Promise<{ packageId: string; objectChanges: any[] }> {
  const { modules, dependencies } = buildBytecode(packagePath);

  const tx = new Transaction();
  const upgradeCap = tx.publish({ modules, dependencies });
  tx.transferObjects([upgradeCap], signer.getPublicKey().toSuiAddress());
  tx.setGasBudget(300_000_000n);

  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    options: { showObjectChanges: true },
  });

  if (result.effects?.status.status !== 'success') {
    throw new Error(`Publish failed: ${result.effects?.status.error}`);
  }

  const changes  = result.objectChanges ?? [];
  const published = changes.find(c => c.type === 'published') as any;
  if (!published) throw new Error(`No published package found in ${packagePath} output`);

  return { packageId: published.packageId, objectChanges: changes };
}

async function main() {
  console.log(`Network: ${RPC_URL}\n`);

  console.log('Generating keypairs...');
  const owner   = new Ed25519Keypair();
  const tenant1 = new Ed25519Keypair();
  const tenant2 = new Ed25519Keypair();

  const ownerAddr = owner.getPublicKey().toSuiAddress();
  console.log(`Owner:   ${ownerAddr}`);
  console.log(`Tenant1: ${tenant1.getPublicKey().toSuiAddress()}`);
  console.log(`Tenant2: ${tenant2.getPublicKey().toSuiAddress()}`);

  console.log('\nFunding owner (x2 faucet requests)...');
  await requestFaucet(ownerAddr);
  await requestFaucet(ownerAddr);

  console.log('\nPublishing dummy_asset...');
  const dummy = await publishPackage(owner, resolve(ROOT, 'asset'));
  console.log(`  dummy_asset: ${dummy.packageId}`);

  console.log('\nPublishing usufruct...');
  const usufruct = await publishPackage(owner, resolve(ROOT, '..', 'usufruct'));
  console.log(`  usufruct: ${usufruct.packageId}`);

  const feeInboxObj = usufruct.objectChanges.find(
    (c: any) => c.type === 'created' && c.objectType?.includes('ProtocolFeeInbox'),
  ) as any;
  const feeRefObj = usufruct.objectChanges.find(
    (c: any) => c.type === 'created' && c.objectType?.includes('ProtocolFeeRef'),
  ) as any;

  if (!feeInboxObj || !feeRefObj) {
    console.error('Object changes:', JSON.stringify(usufruct.objectChanges, null, 2));
    throw new Error('ProtocolFeeInbox or ProtocolFeeRef not found in publish output');
  }

  // getSecretKey() returns a bech32 string ("suiprivkey1...") — store directly
  const deployment = {
    usufructPackageId:   usufruct.packageId,
    dummyAssetPackageId: dummy.packageId,
    protocolFeeInboxId:  feeInboxObj.objectId,
    protocolFeeRefId:    feeRefObj.objectId,
    owner:   { address: owner.getPublicKey().toSuiAddress(),   secretKey: owner.getSecretKey()   },
    tenant1: { address: tenant1.getPublicKey().toSuiAddress(), secretKey: tenant1.getSecretKey() },
    tenant2: { address: tenant2.getPublicKey().toSuiAddress(), secretKey: tenant2.getSecretKey() },
  };

  writeFileSync(resolve(ROOT, 'deployment.json'), JSON.stringify(deployment, null, 2));
  console.log('\ndeployment.json written.');
  console.log('\nNext: npm run setup:fund   (funds tenant1 and tenant2)');
}

main().catch(e => { console.error(e); process.exit(1); });
