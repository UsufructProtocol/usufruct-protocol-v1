#!/usr/bin/env tsx
/**
 * Testnet setup for profiling — two-step workflow:
 *
 *   Step 1 — generate wallets:
 *     USUFRUCT_PACKAGE_ID=0x… PROTOCOL_FEE_INBOX_ID=0x… PROTOCOL_FEE_REF_ID=0x… \
 *       npm run setup:testnet:init
 *     → writes deployment.json with wallet keys + the target usufruct IDs (from env)
 *     → prints governor address; fund it at https://faucet.sui.io (1–2 SUI)
 *
 *   Step 2 — deploy dummy_asset:
 *     npm run setup:testnet:deploy
 *     → reads deployment.json, publishes dummy_asset, fills in the package ID
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

const client = new SuiClient({ url: RPC_URL });

function run(cmd: string): string {
  return execSync(cmd, { encoding: 'utf8' }).trim();
}

// The target usufruct deployment is version-specific, so it is supplied via env
// rather than hardcoded here (which would go stale every release). See the
// deployment record in ../../TESTNET_DEPLOY.md / verify.sh for the current IDs.
function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) {
    console.error(`Missing required env var: ${name}`);
    console.error('Point the harness at a deployed usufruct version, e.g.:');
    console.error('  USUFRUCT_PACKAGE_ID=0x… PROTOCOL_FEE_INBOX_ID=0x… PROTOCOL_FEE_REF_ID=0x… \\');
    console.error('    npm run setup:testnet:init');
    process.exit(1);
  }
  return v;
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
    console.log(`\nGovernor:   ${d.governor.address}`);
    console.log(`Usufructuary1: ${d.usufructuary1.address}`);
    console.log(`Usufructuary2: ${d.usufructuary2.address}`);
  } else {
    const usufructPackageId  = requireEnv('USUFRUCT_PACKAGE_ID');
    const protocolFeeInboxId = requireEnv('PROTOCOL_FEE_INBOX_ID');
    const protocolFeeRefId   = requireEnv('PROTOCOL_FEE_REF_ID');

    const governor   = new Ed25519Keypair();
    const usufructuary1 = new Ed25519Keypair();
    const usufructuary2 = new Ed25519Keypair();

    const deployment = {
      usufructPackageId,
      dummyAssetPackageId: '',   // filled in by setup:testnet:deploy
      protocolFeeInboxId,
      protocolFeeRefId,
      governor:   { address: governor.getPublicKey().toSuiAddress(),   secretKey: governor.getSecretKey()   },
      usufructuary1: { address: usufructuary1.getPublicKey().toSuiAddress(), secretKey: usufructuary1.getSecretKey() },
      usufructuary2: { address: usufructuary2.getPublicKey().toSuiAddress(), secretKey: usufructuary2.getSecretKey() },
    };

    writeFileSync(deploymentPath, JSON.stringify(deployment, null, 2));
    console.log('Wallets generated and saved to deployment.json.\n');
    console.log(`Governor:   ${deployment.governor.address}`);
    console.log(`Usufructuary1: ${deployment.usufructuary1.address}`);
    console.log(`Usufructuary2: ${deployment.usufructuary2.address}`);
  }

  const d = JSON.parse(readFileSync(deploymentPath, 'utf8'));
  console.log(`\nFund the governor with 2+ SUI testnet:`);
  console.log(`  https://faucet.sui.io/?address=${d.governor.address}`);
  console.log(`\nOnce funded, run: npm run setup:testnet:deploy`);
}

async function cmdDeploy() {
  const deploymentPath = resolve(ROOT, 'deployment.json');
  if (!existsSync(deploymentPath)) {
    console.error('deployment.json not found — run setup:testnet:init first.');
    process.exit(1);
  }

  const d = JSON.parse(readFileSync(deploymentPath, 'utf8'));
  const governorAddr = d.governor.address;

  // Check governor balance
  const coins = await client.getCoins({ owner: governorAddr, coinType: '0x2::sui::SUI' });
  const totalMist = coins.data.reduce((s: bigint, c: any) => s + BigInt(c.balance), 0n);
  if (totalMist < 500_000_000n) {
    console.error(`Governor balance too low: ${totalMist} MIST (need ≥ 500M for gas)`);
    console.error(`Fund at: https://faucet.sui.io/?address=${governorAddr}`);
    process.exit(1);
  }
  console.log(`Governor balance: ${totalMist} MIST ✓`);

  const chainId  = await client.getChainIdentifier();
  const buildEnv = 'testnet';
  console.log(`Chain:    ${chainId}\n`);

  const governor = Ed25519Keypair.fromSecretKey(d.governor.secretKey);
  run(`sui keytool import "${governor.getSecretKey()}" ed25519`);
  const prevAddress = run('sui client active-address');
  run(`sui client switch --address ${governorAddr}`);
  console.log(`CLI switched to governor: ${governorAddr}`);

  try {
    const dummyPath = resolve(ROOT, 'asset');
    console.log('\nPublishing dummy_asset...');
    const dummy = publishPackage(dummyPath, buildEnv, chainId);
    console.log(`  dummy_asset: ${dummy.packageId}`);

    d.dummyAssetPackageId = dummy.packageId;
    writeFileSync(deploymentPath, JSON.stringify(d, null, 2));
    console.log('\ndeployment.json updated with dummy_asset package ID.');
    console.log('\nNext: npm run setup:fund:testnet   (top up usufructuary wallets)');
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
