import { readFileSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';
import { SuiClient }      from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';

const DIR = dirname(fileURLToPath(import.meta.url));

export interface Deployment {
  usufructPackageId:    string;
  dummyAssetPackageId:  string;
  protocolFeeInboxId:   string;
  protocolFeeRefId:     string;
  owner:   { address: string; secretKey: string };
  tenant1: { address: string; secretKey: string };
  tenant2: { address: string; secretKey: string };
}

export const LOCALNET_RPC = 'http://127.0.0.1:9000';
export const FAUCET_URL   = 'http://127.0.0.1:9123/gas';

// Sui system objects
export const CLOCK_ID  = '0x0000000000000000000000000000000000000000000000000000000000000006';
export const RANDOM_ID = '0x0000000000000000000000000000000000000000000000000000000000000008';

export const RUNS = 10;

// Default profiling config values
export const FLOOR_PRICE_MIST    = 1_000_000n;  // 0.001 SUI
export const TENURE_DURATION_MS  = 3_600_000n;  // 1 hour
export const HANDOVER_FLOOR_MS   = 600_000n;    // 10 minutes (must be < tenure)
export const DELTA_PRICE_MIST    = 1n;          // minimal escalation

export function loadDeployment(): Deployment {
  const path = resolve(DIR, 'deployment.json');
  try {
    return JSON.parse(readFileSync(path, 'utf8')) as Deployment;
  } catch {
    throw new Error(
      'deployment.json not found — run `npm run setup:deploy` first',
    );
  }
}

export function makeClient(): SuiClient {
  return new SuiClient({ url: LOCALNET_RPC });
}

export function makeKeypair(secretKey: string): Ed25519Keypair {
  return Ed25519Keypair.fromSecretKey(secretKey);
}

export function loadKeypairs(d: Deployment) {
  return {
    owner:   makeKeypair(d.owner.secretKey),
    tenant1: makeKeypair(d.tenant1.secretKey),
    tenant2: makeKeypair(d.tenant2.secretKey),
  };
}
