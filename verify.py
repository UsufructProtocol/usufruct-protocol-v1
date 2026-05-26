#!/usr/bin/env python3
"""
Verify that the usufruct source code at a given commit matches the bytecode
deployed on-chain.

Usage:
    python3 verify.py

Requirements:
    - sui CLI in PATH (any recent version)
    - Python 3.8+
    - Internet access (to query Sui testnet RPC)

The script:
  1. Compiles the package locally with `sui move build`
  2. Fetches the on-chain bytecode via JSON-RPC
  3. Normalizes both (replaces the package address with 0x0, which is the
     canonical pre-publish form — the chain performs this substitution on publish)
  4. Computes SHA-256 over all 36 modules sorted by name
  5. Compares against the expected hash published in VERIFY.md
"""

import base64
import hashlib
import json
import subprocess
import sys
import urllib.request

PACKAGE_ID   = "0xe4662b44e47ce58beabdd6d45a541346636fbbffec0c7d4feb18d3f30bd95aaf"
EXPECTED_HASH = "2933c39334392156ed75baa785461ea48c5b672df6839b4192e136fb78904100"
RPC_URL      = "https://fullnode.testnet.sui.io:443"
ADDR_BYTES   = bytes.fromhex(PACKAGE_ID[2:])  # strip 0x
ZERO_BYTES   = bytes(32)


def normalize(bytecode: bytes) -> bytes:
    """Replace the deployed address with 0x0 (pre-publish canonical form)."""
    return bytecode.replace(ADDR_BYTES, ZERO_BYTES)


def build_local() -> list[bytes]:
    result = subprocess.run(
        ["sui", "move", "build", "--dump-bytecode-as-base64", "-e", "testnet"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print("Build failed:\n", result.stderr)
        sys.exit(1)
    data = json.loads(result.stdout)
    return [base64.b64decode(m) for m in data["modules"]]


def fetch_onchain() -> dict[str, bytes]:
    payload = json.dumps({
        "jsonrpc": "2.0", "id": 1,
        "method": "sui_getObject",
        "params": [PACKAGE_ID, {"showBcs": True, "showContent": False}]
    }).encode()
    req = urllib.request.Request(RPC_URL, data=payload,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req) as resp:
        data = json.load(resp)
    module_map = data["result"]["data"]["bcs"]["moduleMap"]
    return {k: base64.b64decode(v) for k, v in module_map.items()}


def canonical_hash(named_modules: dict[str, bytes]) -> str:
    h = hashlib.sha256()
    for name in sorted(named_modules):
        h.update(name.encode())
        h.update(named_modules[name])
    return h.hexdigest()


def main():
    print("Building locally...")
    local = build_local()
    print(f"  {len(local)} modules compiled")

    print("Fetching on-chain bytecode...")
    onchain = fetch_onchain()
    print(f"  {len(onchain)} modules on-chain")

    if len(local) != len(onchain):
        print(f"FAIL: module count mismatch ({len(local)} vs {len(onchain)})")
        sys.exit(1)

    # Normalize on-chain (replace deployed addr → 0x0) and match to local
    named: dict[str, bytes] = {}
    local_set = set(local)
    for name, ob in onchain.items():
        norm = normalize(ob)
        if norm not in local_set:
            print(f"FAIL: on-chain module '{name}' has no matching local bytecode")
            sys.exit(1)
        named[name] = norm

    got = canonical_hash(named)
    print(f"\nCanonical hash: {got}")
    print(f"Expected hash:  {EXPECTED_HASH}")

    if got == EXPECTED_HASH:
        print("\n✓ VERIFIED — on-chain bytecode matches source at commit 7c75828")
    else:
        print("\n✗ MISMATCH — bytecodes do not match")
        sys.exit(1)


if __name__ == "__main__":
    main()
