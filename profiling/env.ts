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
  governor:   { address: string; secretKey: string };
  usufructuary1: { address: string; secretKey: string };
  usufructuary2: { address: string; secretKey: string };
}

// Network config — override via environment variables:
//   SUI_RPC=https://fullnode.testnet.sui.io:443
//   SUI_FAUCET=https://faucet.testnet.sui.io/gas   (omit on mainnet)
export const RPC_URL    = process.env.SUI_RPC    ?? 'http://127.0.0.1:9000';
export const FAUCET_URL = process.env.SUI_FAUCET ?? 'http://127.0.0.1:9123/gas';

// Sui system objects
export const CLOCK_ID  = '0x0000000000000000000000000000000000000000000000000000000000000006';
export const RANDOM_ID = '0x0000000000000000000000000000000000000000000000000000000000000008';

export const RUNS = 5;

// Default profiling config values
export const FLOOR_PRICE_MIST    = 1_000n;       // 0.000001 SUI — minimal stake for testnet budget
export const TENURE_DURATION_MS  = 60_000n;     // 1 minute (testnet: keeps N×tenure lock manageable)
export const HANDOVER_FLOOR_MS   = 30_000n;     // 30 seconds (must be < tenure)
export const DELTA_PRICE_MIST    = 1n;          // minimal escalation

export function loadDeployment(): Deployment {
  const path = resolve(DIR, 'deployment.json');
  let base: Deployment;
  try {
    base = JSON.parse(readFileSync(path, 'utf8')) as Deployment;
  } catch {
    throw new Error(
      'deployment.json not found — run `npm run setup:deploy` first',
    );
  }
  // Protocol IDs can be overridden per-invocation via env vars.
  // Wallet keys always come from deployment.json (they are account-specific).
  //
  //   USUFRUCT_PACKAGE_ID=0x...   PROTOCOL_FEE_INBOX_ID=0x...   PROTOCOL_FEE_REF_ID=0x...
  //
  // Example — target v1.0.0 without touching deployment.json:
  //   USUFRUCT_PACKAGE_ID=0xe466... PROTOCOL_FEE_INBOX_ID=0x0fca... npm run cleanup:testnet
  return {
    ...base,
    usufructPackageId:  process.env.USUFRUCT_PACKAGE_ID   ?? base.usufructPackageId,
    protocolFeeInboxId: process.env.PROTOCOL_FEE_INBOX_ID ?? base.protocolFeeInboxId,
    protocolFeeRefId:   process.env.PROTOCOL_FEE_REF_ID   ?? base.protocolFeeRefId,
  };
}

export function makeClient(): SuiClient {
  return new SuiClient({ url: RPC_URL });
}

export function makeKeypair(secretKey: string): Ed25519Keypair {
  return Ed25519Keypair.fromSecretKey(secretKey);
}

export function loadKeypairs(d: Deployment) {
  return {
    governor:   makeKeypair(d.governor.secretKey),
    usufructuary1: makeKeypair(d.usufructuary1.secretKey),
    usufructuary2: makeKeypair(d.usufructuary2.secretKey),
  };
}
