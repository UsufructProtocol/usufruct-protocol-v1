#!/usr/bin/env tsx
/**
 * Testnet setup for profiling — deploys only dummy_asset.
 *
 * usufruct v1.0.0 is already deployed and immutable on testnet:
 *   Package:  0xe4662b44e47ce58beabdd6d45a541346636fbbffec0c7d4feb18d3f30bd95aaf
 *   FeeInbox: 0x0fcaa718a4166f33eef48e9ec3984bc39b10d9e5e1864354a61ef3c341b52962
 *   FeeRef:   0x20efbe0a6eff8fb62d0af9813adcb8b8a514bb0e0954e7df91d1a10927503d63
 *
 * This script:
 *   1. Generates fresh ephemeral keypairs
 *   2. Funds owner via testnet faucet (x2)
 *   3. Publishes dummy_asset against the testnet network
 *   4. Writes deployment.json with all IDs
 *
 * Usage:
 *   SUI_RPC=https://fullnode.testnet.sui.io:443 \
 *   SUI_FAUCET=https://faucet.testnet.sui.io/gas \
 *   npm run setup:testnet
 */

import { execSync }                                            from 'child_process';
import { readFileSync, writeFileSync, existsSync, unlinkSync } from 'fs';
import { resolve, dirname }                                    from 'path';
import { fileURLToPath }                                       from 'url';
import { SuiClient }                                           from '@mysten/sui/client';
import { Ed25519Keypair }                                      from '@mysten/sui/keypairs/ed25519';
import { RPC_URL, FAUCET_URL }                                 from '../env.ts';

const DIR  = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(DIR, '..');

// Testnet usufruct deployment — immutable, never changes
const TESTNET_USUFRUCT_PACKAGE_ID = '0xe4662b44e47ce58beabdd6d45a541346636fbbffec0c7d4feb18d3f30bd95aaf';
const TESTNET_FEE_INBOX_ID        = '0x0fcaa718a4166f33eef48e9ec3984bc39b10d9e5e1864354a61ef3c341b52962';
const TESTNET_FEE_REF_ID          = '0x20efbe0a6eff8fb62d0af9813adcb8b8a514bb0e0954e7df91d1a10927503d63';

const client = new SuiClient({ url: RPC_URL });

function run(cmd: string): string {
  return execSync(cmd, { encoding: 'utf8' }).trim();
}

async function requestFaucet(address: string): Promise<void> {
  console.log(`  Funding ${address}...`);
  const res = await fetch(FAUCET_URL, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify({ FixedAmountRequest: { recipient: address } }),
  });
  if (!res.ok) throw new Error(`Faucet failed for ${address}: ${await res.text()}`);
  const data = await res.json() as any;
  console.log(`    ok — coins: ${data.transferredGasObjects?.length ?? '?'}`);
  await new Promise(r => setTimeout(r, 2000));
}

function withPatchedToml<T>(
  packagePath: string,
  alias:       string,
  chainId:     string,
  fn:          () => T,
): T {
  const moveTomlPath = resolve(packagePath, 'Move.toml');
  const original     = readFileSync(moveTomlPath, 'utf8');

  let patched = original;
  const envEntry    = `${alias} = "${chainId}"`;
  const aliasPattern = new RegExp(`${alias}\\s*=\\s*"[^"]*"`);
  if (aliasPattern.test(patched)) {
    patched = patched.replace(aliasPattern, envEntry);
  } else if (patched.includes('[environments]')) {
    patched = patched.replace('[environments]', `[environments]\n${envEntry}`);
  } else {
    patched = patched + `\n[environments]\n${envEntry}\n`;
  }

  writeFileSync(moveTomlPath, patched);

  const lockPath   = resolve(packagePath, 'Move.lock');
  const lockBackup = existsSync(lockPath) ? readFileSync(lockPath) : null;
  if (lockBackup) unlinkSync(lockPath);

  try {
    return fn();
  } finally {
    writeFileSync(moveTomlPath, original);
    if (lockBackup) writeFileSync(lockPath, lockBackup);
    else if (existsSync(lockPath)) unlinkSync(lockPath);
  }
}

function publishPackage(
  packagePath: string,
  buildEnv:    string,
  chainId:     string,
): { packageId: string; objectChanges: any[] } {
  const pubfile = `/tmp/profiling-testnet-pub-${Date.now()}.toml`;

  const raw = withPatchedToml(packagePath, buildEnv, chainId, () =>
    run(`sui client test-publish --build-env ${buildEnv} --pubfile-path ${pubfile} --gas-budget 500000000 --json ${packagePath}`)
  );

  const jsonStart = raw.indexOf('{');
  if (jsonStart === -1) throw new Error(`No JSON in test-publish output:\n${raw}`);
  const result = JSON.parse(raw.slice(jsonStart));

  if (result.effects?.status?.status !== 'success') {
    throw new Error(`Publish failed: ${JSON.stringify(result.effects?.status)}`);
  }

  const changes   = result.objectChanges ?? [];
  const published = changes.find((c: any) => c.type === 'published');
  if (!published) throw new Error('No published package in output');

  return { packageId: (published as any).packageId, objectChanges: changes };
}

async function main() {
  if (!RPC_URL.includes('testnet')) {
    console.error(`Expected testnet RPC — got: ${RPC_URL}`);
    console.error('Set SUI_RPC=https://fullnode.testnet.sui.io:443');
    process.exit(1);
  }

  console.log(`Network:  ${RPC_URL}`);
  console.log(`Faucet:   ${FAUCET_URL}`);
  const chainId  = await client.getChainIdentifier();
  const buildEnv = 'testnet';
  console.log(`Chain:    ${chainId}\n`);

  const owner   = new Ed25519Keypair();
  const tenant1 = new Ed25519Keypair();
  const tenant2 = new Ed25519Keypair();

  const ownerAddr = owner.getPublicKey().toSuiAddress();
  console.log(`Owner:   ${ownerAddr}`);
  console.log(`Tenant1: ${tenant1.getPublicKey().toSuiAddress()}`);
  console.log(`Tenant2: ${tenant2.getPublicKey().toSuiAddress()}`);

  console.log('\nFunding owner via testnet faucet (x2)...');
  await requestFaucet(ownerAddr);
  await requestFaucet(ownerAddr);

  run(`sui keytool import "${owner.getSecretKey()}" ed25519`);
  const prevAddress = run('sui client active-address');
  run(`sui client switch --address ${ownerAddr}`);
  console.log(`\nCLI switched to owner: ${ownerAddr}`);

  try {
    const dummyPath = resolve(ROOT, 'asset');

    console.log('\nPublishing dummy_asset...');
    const dummy = publishPackage(dummyPath, buildEnv, chainId);
    console.log(`  dummy_asset: ${dummy.packageId}`);

    const deployment = {
      usufructPackageId:   TESTNET_USUFRUCT_PACKAGE_ID,
      dummyAssetPackageId: dummy.packageId,
      protocolFeeInboxId:  TESTNET_FEE_INBOX_ID,
      protocolFeeRefId:    TESTNET_FEE_REF_ID,
      owner:   { address: ownerAddr,                              secretKey: owner.getSecretKey()   },
      tenant1: { address: tenant1.getPublicKey().toSuiAddress(), secretKey: tenant1.getSecretKey() },
      tenant2: { address: tenant2.getPublicKey().toSuiAddress(), secretKey: tenant2.getSecretKey() },
    };

    writeFileSync(resolve(ROOT, 'deployment.json'), JSON.stringify(deployment, null, 2));
    console.log('\ndeployment.json written.');
    console.log('\nNext: npm run setup:fund:testnet   (to top up tenant wallets)');
    console.log('Then: SUI_RPC=https://fullnode.testnet.sui.io:443 npm run run');
  } finally {
    run(`sui client switch --address ${prevAddress}`);
    console.log(`\nCLI restored to: ${prevAddress}`);
  }
}

main().catch(e => { console.error(e); process.exit(1); });
