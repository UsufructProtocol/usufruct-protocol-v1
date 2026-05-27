#!/usr/bin/env tsx
/**
 * Testnet setup for profiling — two-step workflow:
 *
 *   Step 1 — generate wallets:
 *     npm run setup:testnet:init
 *     → writes deployment.json with wallet keys + testnet usufruct IDs
 *     → prints owner address; fund it at https://faucet.sui.io (1–2 SUI)
 *
 *   Step 2 — deploy dummy_asset:
 *     npm run setup:testnet:deploy
 *     → reads deployment.json, publishes dummy_asset, fills in the package ID
 *
 * usufruct v1.0.0 is already deployed and immutable on testnet:
 *   Package:  0xe4662b44e47ce58beabdd6d45a541346636fbbffec0c7d4feb18d3f30bd95aaf
 *   FeeInbox: 0x0fcaa718a4166f33eef48e9ec3984bc39b10d9e5e1864354a61ef3c341b52962
 *   FeeRef:   0x20efbe0a6eff8fb62d0af9813adcb8b8a514bb0e0954e7df91d1a10927503d63
 */

import { execSync }                                            from 'child_process';
import { readFileSync, writeFileSync, existsSync, unlinkSync } from 'fs';
import { resolve, dirname }                                    from 'path';
import { fileURLToPath }                                       from 'url';
import { SuiClient }                                           from '@mysten/sui/client';
import { Ed25519Keypair }                                      from '@mysten/sui/keypairs/ed25519';
import { RPC_URL }                                             from '../env.ts';

const DIR  = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(DIR, '..');

const TESTNET_USUFRUCT_PACKAGE_ID = '0xe4662b44e47ce58beabdd6d45a541346636fbbffec0c7d4feb18d3f30bd95aaf';
const TESTNET_FEE_INBOX_ID        = '0x0fcaa718a4166f33eef48e9ec3984bc39b10d9e5e1864354a61ef3c341b52962';
const TESTNET_FEE_REF_ID          = '0x20efbe0a6eff8fb62d0af9813adcb8b8a514bb0e0954e7df91d1a10927503d63';

const client = new SuiClient({ url: RPC_URL });

function run(cmd: string): string {
  return execSync(cmd, { encoding: 'utf8' }).trim();
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
  const envEntry     = `${alias} = "${chainId}"`;
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

async function cmdInit() {
  const deploymentPath = resolve(ROOT, 'deployment.json');
  if (existsSync(deploymentPath)) {
    console.log('deployment.json already exists — skipping wallet generation.');
    console.log('Delete it first if you want fresh wallets.');
    const d = JSON.parse(readFileSync(deploymentPath, 'utf8'));
    console.log(`\nOwner:   ${d.owner.address}`);
    console.log(`Tenant1: ${d.tenant1.address}`);
    console.log(`Tenant2: ${d.tenant2.address}`);
  } else {
    const owner   = new Ed25519Keypair();
    const tenant1 = new Ed25519Keypair();
    const tenant2 = new Ed25519Keypair();

    const deployment = {
      usufructPackageId:   TESTNET_USUFRUCT_PACKAGE_ID,
      dummyAssetPackageId: '',   // filled in by setup:testnet:deploy
      protocolFeeInboxId:  TESTNET_FEE_INBOX_ID,
      protocolFeeRefId:    TESTNET_FEE_REF_ID,
      owner:   { address: owner.getPublicKey().toSuiAddress(),   secretKey: owner.getSecretKey()   },
      tenant1: { address: tenant1.getPublicKey().toSuiAddress(), secretKey: tenant1.getSecretKey() },
      tenant2: { address: tenant2.getPublicKey().toSuiAddress(), secretKey: tenant2.getSecretKey() },
    };

    writeFileSync(deploymentPath, JSON.stringify(deployment, null, 2));
    console.log('Wallets generated and saved to deployment.json.\n');
    console.log(`Owner:   ${deployment.owner.address}`);
    console.log(`Tenant1: ${deployment.tenant1.address}`);
    console.log(`Tenant2: ${deployment.tenant2.address}`);
  }

  const d = JSON.parse(readFileSync(deploymentPath, 'utf8'));
  console.log(`\nFund the owner with 2+ SUI testnet:`);
  console.log(`  https://faucet.sui.io/?address=${d.owner.address}`);
  console.log(`\nOnce funded, run: npm run setup:testnet:deploy`);
}

async function cmdDeploy() {
  const deploymentPath = resolve(ROOT, 'deployment.json');
  if (!existsSync(deploymentPath)) {
    console.error('deployment.json not found — run setup:testnet:init first.');
    process.exit(1);
  }

  const d = JSON.parse(readFileSync(deploymentPath, 'utf8'));
  const ownerAddr = d.owner.address;

  // Check owner balance
  const coins = await client.getCoins({ owner: ownerAddr, coinType: '0x2::sui::SUI' });
  const totalMist = coins.data.reduce((s: bigint, c: any) => s + BigInt(c.balance), 0n);
  if (totalMist < 500_000_000n) {
    console.error(`Owner balance too low: ${totalMist} MIST (need ≥ 500M for gas)`);
    console.error(`Fund at: https://faucet.sui.io/?address=${ownerAddr}`);
    process.exit(1);
  }
  console.log(`Owner balance: ${totalMist} MIST ✓`);

  const chainId  = await client.getChainIdentifier();
  const buildEnv = 'testnet';
  console.log(`Chain:    ${chainId}\n`);

  const owner = Ed25519Keypair.fromSecretKey(d.owner.secretKey);
  run(`sui keytool import "${owner.getSecretKey()}" ed25519`);
  const prevAddress = run('sui client active-address');
  run(`sui client switch --address ${ownerAddr}`);
  console.log(`CLI switched to owner: ${ownerAddr}`);

  try {
    const dummyPath = resolve(ROOT, 'asset');
    console.log('\nPublishing dummy_asset...');
    const dummy = publishPackage(dummyPath, buildEnv, chainId);
    console.log(`  dummy_asset: ${dummy.packageId}`);

    d.dummyAssetPackageId = dummy.packageId;
    writeFileSync(deploymentPath, JSON.stringify(d, null, 2));
    console.log('\ndeployment.json updated with dummy_asset package ID.');
    console.log('\nNext: npm run setup:fund:testnet   (top up tenant wallets)');
    console.log('Then: npm run run:testnet');
  } finally {
    run(`sui client switch --address ${prevAddress}`);
    console.log(`\nCLI restored to: ${prevAddress}`);
  }
}

async function main() {
  if (!RPC_URL.includes('testnet')) {
    console.error(`Expected testnet RPC — got: ${RPC_URL}`);
    console.error('Set SUI_RPC=https://fullnode.testnet.sui.io:443');
    process.exit(1);
  }

  const mode = process.argv[2];
  if (mode === '--init')   return cmdInit();
  if (mode === '--deploy') return cmdDeploy();

  console.error('Usage:');
  console.error('  npm run setup:testnet:init    # generate wallets');
  console.error('  npm run setup:testnet:deploy  # publish dummy_asset');
  process.exit(1);
}

main().catch(e => { console.error(e); process.exit(1); });
