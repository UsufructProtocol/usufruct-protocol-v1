#!/usr/bin/env bash
# Verify a deployed usufruct package against this repo's source.
#
# Uses `sui client verify-source`, which compiles the local package and compares
# it module-by-module against the on-chain bytecode. No manual hashing, no
# explorer dependency — reproducible by anyone with the Sui CLI.
#
# usufruct VERSIONS, it does not upgrade: every release is a brand-new immutable
# package published from `addresses usufruct = "0x0"` at a fixed commit. To verify
# a version, check out its commit, then run this script:
#
#     git checkout <commit> && ./verify.sh <version>
#
# Requirements:
#   - sui CLI >= 1.52 (older CLIs cannot compile `std::type_name::with_defining_ids`)
#   - active client env pointing at testnet  (`sui client switch --env testnet`)
#   - internet access (testnet RPC)
#
# Expected output:  "Source verification succeeded!"

set -euo pipefail

# version → "commit package_id"
declare -A DEPLOYS=(
  [v1.1.0]="51c653c 0x2615bed67854d3d628ebd64750742ce6db4b75f0de00b0d69054881fac7bae7c"
  [v1.4.0]="89ffcde 0x6e2a7eeed594efa3a3e04c06afe92d8e1a9a9789ea2ef9850fc74fe1bd2b2901"
  [v1.4.1]="a2aeeb9 0x61723e7205f9841ebb4e6f73096f34840a78bcfae73f631d44370e75f1acc0f5"
  [v1.4.2]="0bd8e53 0x415c4372bb9db5affe2ab2bf6d72a6a667ed3178a61d6201e9ff26dc76380e5d"
)

VERSION="${1:-v1.4.2}"
ENTRY="${DEPLOYS[$VERSION]:-}"
if [ -z "$ENTRY" ]; then
  echo "Unknown version: $VERSION"
  echo "Known versions: ${!DEPLOYS[*]}"
  exit 1
fi
read -r COMMIT PKG <<< "$ENTRY"

echo "Verifying usufruct $VERSION"
echo "  package: $PKG"
echo "  commit:  $COMMIT  (make sure you are checked out here)"
echo

cd "$(dirname "$0")/usufruct"
sui client verify-source --address-override "$PKG" --build-env testnet
