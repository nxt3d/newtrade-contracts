#!/usr/bin/env bash
# Export compiled migration ABIs and a raw BundleMigrated log captured from an
# actual passing Forge execution. This is a test emission, not a deployment.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
handoff_dir="${HANDOFF_DIR:-$repo_root/abi}"
fixture_dir="${FIXTURE_DIR:-$repo_root/test/fixtures/migration}"
test_json="$(mktemp)"
test_logs="$(mktemp)"
trap 'rm -f "$test_json" "$test_logs"' EXIT

mkdir -p "$handoff_dir"
mkdir -p "$fixture_dir"
HANDOFF_DIR="$handoff_dir" "$repo_root/tooling/export-abis.sh"

cd "$repo_root"
forge test \
  --match-contract ERC8048DiscoveryTest \
  --match-test test_DiscoveredAccountMigratesNftFirstWithoutOwnerOrSignerGates \
  -vvvv --json | grep -m1 '^{' > "$test_json"
# (forge can print a dependency notice on stdout before the JSON, e.g. in a fresh
# git worktree with uninitialised submodules; keep only the JSON document.)

jq -e '
  .["test/ERC8048Discovery.t.sol:ERC8048DiscoveryTest"]
    .test_results["test_DiscoveredAccountMigratesNftFirstWithoutOwnerOrSignerGates()"] as $test
  | if $test.status != "Success" then error("fixture source test did not pass") else
      ($test.logs[-10:] | to_entries | map(.value + {logIndex: .key}))
    end
' "$test_json" > "$test_logs"
# The current signatureless deposit emits ten transaction logs, without the
# former receipt Approval. Reject stale positional assumptions before export.
jq -e '
  length == 10 and
  .[0].topics[0] == "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" and
  .[5].topics[0] == "0xad0ad27730438606f8c4a3e19618727fe7b5e81b2a9027e22afb790c651d650b" and
  .[9].topics[0] == "0x1b4b9c6dbf58717e525d27a080ecc3fbe4180138216e3890f8afc0c4bbf21086"
' "$test_logs" >/dev/null
# Forge's full report includes wall-clock timings. Hash only canonical emitted
# logs so rerunning the same successful test produces an identical handoff.
logs_sha="$(jq -S -c . "$test_logs" | sha256sum | cut -d " " -f 1)"
jq -n --slurpfile logs "$test_logs" --arg logsSha "$logs_sha" '
  {
    schemaVersion: 2,
    provenance: {
      kind: "actual-foundry-all-logs",
      command: "forge test --match-test test_DiscoveredAccountMigratesNftFirstWithoutOwnerOrSignerGates -vvvv --json",
      logsSha256: $logsSha,
      notes: "All transaction logs are copied from a successful local Foundry execution; no network transaction or deployment was submitted."
    },
    chainId: 8453,
    timestamp: "1",
    replayCursor: {
      kind: "synthetic-test-cursor",
      transactionHash: "0x0000000000000000000000000000000000000000000000000000000000006551",
      blockNumber: "1",
      transactionIndex: 0
    },
    escrow: $logs[0][5].address,
    vault: ("0x" + $logs[0][0].topics[2][-40:]),
    bundleId: "1",
    receiptId: "1",
    seller: ("0x" + $logs[0][9].topics[3][-40:]),
    sourceAccount: ("0x" + $logs[0][9].topics[2][-40:]),
    controllingNFT: $logs[0][0].address,
    controllingTokenId: "42",
    manifestHash: ("0x" + $logs[0][5].data[130:194]),
    custodyDeadline: "86401",
    nonce: $logs[0][9].data,
    manifest: [
      {kind: 0, token: $logs[0][1].address, tokenId: "0", amount: "20000000000000000000"},
      {kind: 1, token: $logs[0][2].address, tokenId: "7", amount: "1"},
      {kind: 2, token: $logs[0][3].address, tokenId: "3", amount: "4"}
    ],
    expectedLogOrder: [
      "ControllingNFT.Transfer", "ERC20.Transfer", "ERC721.Transfer", "ERC1155.TransferSingle",
      "Receipt.Transfer", "BundleDeposited", "ManifestAsset", "ManifestAsset",
      "ManifestAsset", "BundleMigrated"
    ],
    logs: $logs[0]
  }
' > "$fixture_dir/all-logs-fixture.json"

(
  cd "$handoff_dir"
  # sha256sum is GNU coreutils; macOS ships shasum. Same output format.
  if command -v sha256sum >/dev/null 2>&1; then sum=(sha256sum); else sum=(shasum -a 256); fi
  "${sum[@]}" \
    IERC6551ExecutableAccount.abi.json \
    NewTradeBundle.abi.json \
    NewTradeEscrowV2.abi.json \
    NewTradeV2VaultV2.abi.json \
    SeaportV16.min.abi.json > artifact-manifest.sha256
)

printf 'ERC-6551 migration handoff written to %s\n' "$handoff_dir"
