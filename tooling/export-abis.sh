#!/usr/bin/env bash
# V2 consumer handoff exporter. The default is the repository's conventional
# ABI handoff directory; consumer owners copy reviewed artifacts themselves.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
handoff_dir="${HANDOFF_DIR:-$repo_root/abi}"
mkdir -p "$handoff_dir"
cd "$repo_root"

forge build >/dev/null
forge inspect NewTradeEscrowV2 abi --json > "$handoff_dir/NewTradeEscrowV2.abi.json"
# The claim collection contract is NewTradeBundle.
forge inspect NewTradeBundle abi --json > "$handoff_dir/NewTradeBundle.abi.json"
forge inspect NewTradeV2VaultV2 abi --json > "$handoff_dir/NewTradeV2VaultV2.abi.json"
forge inspect ISeaport abi --json > "$handoff_dir/SeaportV16.min.abi.json"
forge inspect IERC6551ExecutableAccount abi --json > "$handoff_dir/IERC6551ExecutableAccount.abi.json"
printf 'V2 ABI handoff written to %s\n' "$handoff_dir"
