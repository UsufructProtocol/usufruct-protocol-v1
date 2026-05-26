# Source Verification — usufruct v1.0.0 testnet

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
| Package ID | `0xe4662b44e47ce58beabdd6d45a541346636fbbffec0c7d4feb18d3f30bd95aaf` |
| Commit     | `7c75828` — `chore: bump version to 1.0.0 ahead of testnet deploy`    |
| Tx digest  | `GoZByPfMgeEEZPkK7USnGtuKcXRibFijPHYUYbhLVTX4`                       |
| Deployed   | 2026-05-26                                                             |
| UpgradeCap | Burned atomically — package is immutable                               |

---

## Canonical bytecode hash

SHA-256 computed over all 36 compiled modules sorted by name, with the
package address normalized to `0x0` (canonical pre-publish form — the chain
performs this substitution on publish):

```
2933c39334392156ed75baa785461ea48c5b672df6839b4192e136fb78904100
```

---

## How to verify

```sh
git checkout 7c75828
python3 verify.py
```

Expected output:

```
Building locally...
  36 modules compiled
Fetching on-chain bytecode...
  36 modules on-chain

Canonical hash: 2933c39334392156ed75baa785461ea48c5b672df6839b4192e136fb78904100
Expected hash:  2933c39334392156ed75baa785461ea48c5b672df6839b4192e136fb78904100

✓ VERIFIED — on-chain bytecode matches source at commit 7c75828
```

### What the script does

1. Compiles the package with `sui move build --dump-bytecode-as-base64`
2. Fetches the on-chain bytecode via `sui_getObject` (Sui testnet RPC)
3. Normalizes both sides: replaces the deployed package address with `0x0`
4. Computes SHA-256 over all modules sorted by name
5. Compares against the expected hash above
