#!/usr/bin/env bash
# LOCAL ONLY. Starts its own anvil, then for each exit asks the node for
# eth_estimateGas and sends the transaction at exactly the returned limit.
# Run from the repo root. Uses anvil's public well-known test keys.
set -euo pipefail
export FOUNDRY_OFFLINE=true
PORT=8599
RPC=http://127.0.0.1:$PORT
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
K1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
BUYER=$(cast wallet address --private-key $K1)
SEAPORT=0x0000000000000068F116a894984e2DB1123eB395
CONDUIT=0x1E0049783F008A0085193E00003D00cd54003c71
anvil --port $PORT --gas-limit 200000000 --silent &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do cast block-number --rpc-url $RPC >/dev/null 2>&1 && break; sleep 0.2; done
code() { python3 -c "import json;print(json.load(open('out/$1.sol/$1.json'))['deployedBytecode']['object'])"; }
cast rpc --rpc-url $RPC anvil_setCode $SEAPORT "$(code SeaportV2Mock)" >/dev/null
cast rpc --rpc-url $RPC anvil_setCode $CONDUIT "$(code ConduitMock)" >/dev/null
S=test/rpc/LocalGasGuardSetup.s.sol:LocalGasGuardSetup
LOG=$(forge script $S --sig 'setup()' --rpc-url $RPC --private-key $K0 --broadcast --slow --gas-estimate-multiplier 150 --skip-simulation --gas-limit 150000000 2>&1) || { echo "$LOG" | tail -30; exit 1; }
val() { echo "$LOG" | grep -E "^  $1 " | awk '{print $2}'; }
ESCROW=$(val ESCROW); VAULT=$(val VAULT); TOGGLE=$(val TOGGLE); READER=$(val READER)
A=$(val ID_A); B=$(val ID_B); C=$(val ID_C); MAX=$(val ID_MAX)
forge script $S --sig 'issue(address,uint256,address)' $ESCROW $B $BUYER --rpc-url $RPC --private-key $K0 --broadcast --slow >/dev/null 2>&1
cast rpc --rpc-url $RPC evm_increaseTime 172800 >/dev/null
cast rpc --rpc-url $RPC evm_mine >/dev/null
state() { cast call --rpc-url $RPC $READER 'state(address,uint256)(uint8)' $ESCROW $1; }
held() { cast call --rpc-url $RPC $VAULT 'bundleStatus(uint256)((address,uint256,bool),(bool,bool,uint8,address,address,uint64),uint256)' $1 | tail -1; }
run() { # name key sig args...
  local name=$1 key=$2; shift 2
  local est; est=$(cast estimate --rpc-url $RPC --from "$(cast wallet address --private-key $key)" $ESCROW "$@")
  local out; out=$(cast send --rpc-url $RPC --private-key $key --gas-limit $est --json $ESCROW "$@")
  local status used
  status=$(echo "$out" | python3 -c "import json,sys;print(int(json.load(sys.stdin)['status'],16))")
  used=$(echo "$out" | python3 -c "import json,sys;print(int(json.load(sys.stdin)['gasUsed'],16))")
  echo "$name: estimate=$est status=$status gasUsed=$used"
}
EXTRAS=0x0000000000000000000000000000000000000E87
run "reclaim, healthy 3 entries + NFT" $K0 'reclaim(uint256,address)' $A $EXTRAS
echo "  state=$(state $A) (5=Reclaimed) held=$(held $A)"
run "redeem, healthy 3 entries + NFT, fresh account" $K1 'redeemToFreshAccount(uint256,bytes32)' $B 0x$(printf 'a%.0s' {1..64})
echo "  state=$(state $B) (4=Redeemed) held=$(held $B)"
cast send --rpc-url $RPC --private-key $K0 $TOGGLE 'setFailRelease(bool)' true >/dev/null
cast send --rpc-url $RPC --private-key $K0 --gas-limit 3000000 $ESCROW 'reclaim(uint256,address)' $C $EXTRAS >/dev/null
cast send --rpc-url $RPC --private-key $K0 $TOGGLE 'setFailRelease(bool)' false >/dev/null
echo "bundle C set up: state=$(state $C) (7=Reclaiming) held=$(held $C)"
run "SINGLE-mode retry of the healthy held entry" $K1 'withdrawRemaining(uint256,uint256,bytes)' $C 1 0x
echo "  state=$(state $C) (5=Reclaimed, 7=still Reclaiming) held=$(held $C)"
run "reclaim, 32 budget burners + burning NFT" $K0 'reclaim(uint256,address)' $MAX $EXTRAS
echo "  state=$(state $MAX) (7=Reclaiming) held=$(held $MAX)"
