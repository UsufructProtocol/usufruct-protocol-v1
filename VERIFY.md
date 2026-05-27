# Source Verification — usufruct v1.1.0 testnet

## Why this file exists

SuiScan delegates source verification to Welldone Studio. Their verification
server runs Sui CLI `v1.51.1` while the testnet framework is at `v1.72.2`.
`usufruct` uses `std::type_name::with_defining_ids`, which was added after
`v1.51.1` — so their server cannot compile the package to compare bytecodes.

Issue filed: [welldonestudio/welldonestudio.github.io#63](https://github.com/welldonestudio/welldonestudio.github.io/issues/63).
Once they update their compiler, standard SuiScan verification will work.

In the meantime, any developer can verify independently using `verify.py`.

---

## Deployment record

| Field      | Value                                                                  |
|------------|------------------------------------------------------------------------|
| Network    | Sui testnet                                                            |
| Package ID | `0x2615bed67854d3d628ebd64750742ce6db4b75f0de00b0d69054881fac7bae7c` |
| Commit     | `51c653c` — `chore: bump version to 1.1.0 ahead of testnet deploy`    |
| Tx digest  | `7iivzCnZjWaB1absq9gKPE1dXLyFCEEfayAdjwu4a673`                       |
| Deployed   | 2026-05-27                                                             |
| UpgradeCap | Burned atomically — package is immutable                               |

---

## Canonical bytecode hash

SHA-256 computed over all 36 compiled modules sorted by name, with the
package address normalized to `0x0` (canonical pre-publish form — the chain
performs this substitution on publish):

```
1d7deb8b1686bda303ac6c8c012ec5fb1d7b05e022db8678658add44125c200d
```

---

## How to verify

```sh
git checkout 51c653c
cd usufruct/
python3 ../verify.py
```

Expected output:

```
Building locally...
  36 modules compiled
Fetching on-chain bytecode...
  36 modules on-chain

Canonical hash: 1d7deb8b1686bda303ac6c8c012ec5fb1d7b05e022db8678658add44125c200d
Expected hash:  1d7deb8b1686bda303ac6c8c012ec5fb1d7b05e022db8678658add44125c200d

✓ VERIFIED — on-chain bytecode matches source at commit 51c653c
```

### What the script does

1. Compiles the package with `sui move build --dump-bytecode-as-base64`
2. Fetches the on-chain bytecode via `sui_getObject` (Sui testnet RPC)
3. Normalizes both sides: replaces the deployed package address with `0x0`
4. Computes SHA-256 over all modules sorted by name
5. Compares against the expected hash above

---

## Previous deployments

| Version | Package ID | Deployed |
|---------|-----------|----------|
| v1.0.0  | `0xe4662b44e47ce58beabdd6d45a541346636fbbffec0c7d4feb18d3f30bd95aaf` | 2026-05-26 |
