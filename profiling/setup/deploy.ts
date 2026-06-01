#!/usr/bin/env tsx
/**
 * Deploys usufruct + dummy_asset to the active network and writes deployment.json.
 *
 * Uses `sui client test-publish --build-env <env>` for ephemeral publication.
 * Patches Move.toml files temporarily (restores after) to add the [environments]
 * section and published-at address required by Sui 2024 toolchain.
 *
 * Usage: npm run setup:deploy
 *   SUI_RPC=https://fullnode.testnet.sui.io:443 npm run setup:deploy
 */

import { execSync }                                      from 'child_process';
import { readFileSync, writeFileSync, existsSync, unlinkSync } from 'fs';
import { resolve, dirname }                              from 'path';
import { fileURLToPath }                from 'url';
import { SuiClient }                    from '@mysten/sui/client';
import { Ed25519Keypair }               from '@mysten/sui/keypairs/ed25519';
import { RPC_URL, FAUCET_URL }          from '../env.ts';

const DIR  = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(DIR, '..');

const client = new SuiClient({ url: RPC_URL });

function networkEnvAlias(): string {
  if (RPC_URL.includes('testnet')) return 'testnet';
  if (RPC_URL.includes('devnet'))  return 'devnet';
  if (RPC_URL.includes('mainnet')) return 'mainnet';
  return 'localnet';
}

async function requestFaucet(address: string): Promise<void> {
  const res = await fetch(FAUCET_URL, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify({ FixedAmountRequest: { recipient: address } }),
  });
  if (!res.ok) throw new Error(`Faucet failed for ${address}: ${await res.text()}`);
  await new Promise(r => setTimeout(r, 2000));
}

function run(cmd: string): string {
  return execSync(cmd, { encoding: 'utf8' }).trim();
}

// Temporarily patches a Move.toml with the [environments] entry and optional published-at,
// runs fn(), then restores the original content.
function withPatchedToml<T>(
  packagePath: string,
  alias:       string,
  chainId:     string,
  publishedAt: string | null,
  fn:          () => T,
): T {
  const moveTomlPath = resolve(packagePath, 'Move.toml');
  const original     = readFileSync(moveTomlPath, 'utf8');

  let patched = original;

  // Add published-at to the dependency entry if needed
  if (publishedAt) {
    patched = patched.replace(
      /usufruct\s*=\s*\{\s*local\s*=\s*"([^"]+)"\s*\}/,
      `usufruct = { local = "$1", published-at = "${publishedAt}" }`,
    );
  }

  // Add or replace [environments] entry for this alias
  const envEntry = `${alias} = "${chainId}"`;
  const aliasPattern = new RegExp(`${alias}\\s*=\\s*"[^"]*"`);
  if (aliasPattern.test(patched)) {
    patched = patched.replace(aliasPattern, envEntry);
  } else if (patched.includes('[environments]')) {
    patched = patched.replace('[environments]', `[environments]\n${envEntry}`);
  } else {
    patched = patched + `\n[environments]\n${envEntry}\n`;
  }

  writeFileSync(moveTomlPath, patched);

  // Remove stale lockfile — required when the dependency graph has changed
  // (e.g., adding usufruct as a new dep). The CLI will regenerate it.
  const lockPath = resolve(packagePath, 'Move.lock');
  const lockBackup = existsSync(lockPath) ? readFileSync(lockPath) : null;
  if (lockBackup) unlinkSync(lockPath);

  try {
    return fn();
  } finally {
    writeFileSync(moveTomlPath, original);
    // Restore or remove the regenerated lockfile
    if (lockBackup) writeFileSync(lockPath, lockBackup);
    else if (existsSync(lockPath)) unlinkSync(lockPath);
  }
}

function publishPackage(
  packagePath:     string,
  buildEnv:        string,
  chainId:         string,
  depPublishedAt?: string,    // published address of a local dep (usufruct)
  depPath?:        string,    // path of that local dep (so its Move.toml is also patched)
): { packageId: string; objectChanges: any[] } {
  const pubfile = `/tmp/profiling-pub-${Date.now()}.toml`;

  const executePublish = () =>
    run(`sui client test-publish --build-env ${buildEnv} --pubfile-path ${pubfile} --gas-budget 2000000000 --json ${packagePath}`);

  // When dummy_asset depends on usufruct locally, the CLI resolves and validates
  // usufruct/Move.toml too — so we must patch both simultaneously.
  const runWithPatches = depPath
    ? () => withPatchedToml(depPath, buildEnv, chainId, null, executePublish)
    : executePublish;

  const raw = withPatchedToml(packagePath, buildEnv, chainId, depPublishedAt ?? null, runWithPatches);

  const jsonStart = raw.indexOf('{');
  if (jsonStart === -1) throw new Error(`No JSON in test-publish output:\n${raw}`);
  const result = JSON.parse(raw.slice(jsonStart));

  if (result.effects?.status?.status !== 'success') {
    throw new Error(`Publish failed: ${JSON.stringify(result.effects?.status)}`);
  }

  const changes   = result.objectChanges ?? [];
  const published = changes.find((c: any) => c.type === 'published');
  if (!published) throw new Error(`No published package in output for ${packagePath}`);

  return { packageId: (published as any).packageId, objectChanges: changes };
}

async function main() {
  console.log(`Network:   ${RPC_URL}`);
  const buildEnv = networkEnvAlias();
  const chainId  = await client.getChainIdentifier();
  console.log(`Build env: ${buildEnv}  Chain: ${chainId}\n`);

  const governor   = new Ed25519Keypair();
  const usufructuary1 = new Ed25519Keypair();
  const usufructuary2 = new Ed25519Keypair();

  const governorAddr = governor.getPublicKey().toSuiAddress();
  console.log(`Governor:   ${governorAddr}`);
  console.log(`Usufructuary1: ${usufructuary1.getPublicKey().toSuiAddress()}`);
  console.log(`Usufructuary2: ${usufructuary2.getPublicKey().toSuiAddress()}`);

  console.log('\nFunding governor (x2 faucet requests)...');
  await requestFaucet(governorAddr);
  await requestFaucet(governorAddr);

  run(`sui keytool import "${governor.getSecretKey()}" ed25519`);
  const prevAddress = run('sui client active-address');
  run(`sui client switch --address ${governorAddr}`);
  console.log(`\nCLI switched to governor: ${governorAddr}`);

  try {
    const usufructPath = resolve(ROOT, '..', 'usufruct');
    const dummyPath    = resolve(ROOT, 'asset');

    console.log('\nPublishing usufruct...');
    const usufruct = publishPackage(usufructPath, buildEnv, chainId);
    console.log(`  usufruct: ${usufruct.packageId}`);

    console.log('\nPublishing dummy_asset...');
    const dummy = publishPackage(dummyPath, buildEnv, chainId);
    console.log(`  dummy_asset: ${dummy.packageId}`);

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

    const deployment = {
      usufructPackageId:   usufruct.packageId,
      dummyAssetPackageId: dummy.packageId,
      protocolFeeInboxId:  feeInboxObj.objectId,
      protocolFeeRefId:    feeRefObj.objectId,
      governor:   { address: governorAddr,                              secretKey: governor.getSecretKey()   },
      usufructuary1: { address: usufructuary1.getPublicKey().toSuiAddress(), secretKey: usufructuary1.getSecretKey() },
      usufructuary2: { address: usufructuary2.getPublicKey().toSuiAddress(), secretKey: usufructuary2.getSecretKey() },
    };

    writeFileSync(resolve(ROOT, 'deployment.json'), JSON.stringify(deployment, null, 2));
    console.log('\ndeployment.json written.');
    console.log('Next: npm run setup:fund');
  } finally {
    run(`sui client switch --address ${prevAddress}`);
    console.log(`CLI restored to: ${prevAddress}`);
  }
}

main().catch(e => { console.error(e); process.exit(1); });
