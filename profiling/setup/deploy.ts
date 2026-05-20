#!/usr/bin/env tsx
/**
 * Deploys usufruct + dummy_asset to localnet and writes deployment.json.
 * Run once before any profiling scripts.
 *
 * Usage: npm run setup:deploy
 */

import { execSync }       from 'child_process';
import { writeFileSync }  from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath }  from 'url';
import { SuiClient }      from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction }    from '@mysten/sui/transactions';
import { LOCALNET_RPC, FAUCET_URL } from '../env.ts';

const DIR = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(DIR, '..');

const client = new SuiClient({ url: LOCALNET_RPC });

async function requestFaucet(address: string): Promise<void> {
  const res = await fetch(FAUCET_URL, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify({ FixedAmountRequest: { recipient: address } }),
  });
  if (!res.ok) throw new Error(`Faucet failed for ${address}: ${await res.text()}`);
  // Give the network a moment to process
  await new Promise(r => setTimeout(r, 2000));
}

function publishPackage(packagePath: string, senderAddress: string): { packageId: string; objects: any[] } {
  const buildOutput = execSync(
    `sui move build --dump-bytecode-as-base64 --path ${packagePath}`,
    { encoding: 'utf8' },
  );
  const { modules, dependencies } = JSON.parse(buildOutput);

  // We use sui client publish via CLI for simplicity
  const publishOutput = execSync(
    `sui client publish --gas-budget 200000000 --json ${packagePath}`,
    { encoding: 'utf8' },
  );
  const result = JSON.parse(publishOutput);

  const packageId = result.objectChanges.find(
    (c: any) => c.type === 'published',
  )?.packageId;

  if (!packageId) throw new Error(`Could not find packageId in publish output for ${packagePath}`);

  return { packageId, objects: result.objectChanges };
}

async function main() {
  console.log('Generating keypairs...');
  const owner   = new Ed25519Keypair();
  const tenant1 = new Ed25519Keypair();
  const tenant2 = new Ed25519Keypair();

  const ownerAddr   = owner.getPublicKey().toSuiAddress();
  const tenant1Addr = tenant1.getPublicKey().toSuiAddress();
  const tenant2Addr = tenant2.getPublicKey().toSuiAddress();

  console.log(`Owner:   ${ownerAddr}`);
  console.log(`Tenant1: ${tenant1Addr}`);
  console.log(`Tenant2: ${tenant2Addr}`);

  console.log('\nFunding owner from faucet (x2)...');
  await requestFaucet(ownerAddr);
  await requestFaucet(ownerAddr);

  console.log('\nPublishing dummy_asset...');
  const dummyPath = resolve(ROOT, 'asset');
  const dummy = publishPackage(dummyPath, ownerAddr);
  console.log(`  dummy_asset: ${dummy.packageId}`);

  console.log('\nPublishing usufruct...');
  const usufructPath = resolve(ROOT, '..', 'usufruct');
  const usufruct = publishPackage(usufructPath, ownerAddr);
  console.log(`  usufruct: ${usufruct.packageId}`);

  // ProtocolFeeInbox is transferred to the deployer (owner)
  const feeInboxObj = usufruct.objects.find(
    (c: any) => c.type === 'created' && c.objectType?.includes('ProtocolFeeInbox'),
  );
  // ProtocolFeeRef is frozen
  const feeRefObj = usufruct.objects.find(
    (c: any) => c.type === 'created' && c.objectType?.includes('ProtocolFeeRef'),
  );

  if (!feeInboxObj || !feeRefObj) {
    console.error('Object changes:', JSON.stringify(usufruct.objects, null, 2));
    throw new Error('Could not find ProtocolFeeInbox or ProtocolFeeRef in publish output');
  }

  const deployment = {
    usufructPackageId:   usufruct.packageId,
    dummyAssetPackageId: dummy.packageId,
    protocolFeeInboxId:  feeInboxObj.objectId,
    protocolFeeRefId:    feeRefObj.objectId,
    owner: {
      address:   ownerAddr,
      secretKey: Buffer.from(owner.getSecretKey()).toString('base64'),
    },
    tenant1: {
      address:   tenant1Addr,
      secretKey: Buffer.from(tenant1.getSecretKey()).toString('base64'),
    },
    tenant2: {
      address:   tenant2Addr,
      secretKey: Buffer.from(tenant2.getSecretKey()).toString('base64'),
    },
  };

  const outputPath = resolve(ROOT, 'deployment.json');
  writeFileSync(outputPath, JSON.stringify(deployment, null, 2));
  console.log(`\ndeployment.json written to ${outputPath}`);
}

main().catch(e => { console.error(e); process.exit(1); });
