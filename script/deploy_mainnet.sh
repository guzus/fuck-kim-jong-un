#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source ".env"
  set +a
fi

: "${PRIVATE_KEY:?PRIVATE_KEY is required in .env}"
: "${ETHERSCAN_API_KEY:?ETHERSCAN_API_KEY is required in .env}"

RPC_URL="${MAINNET_RPC_URL:-https://ethereum-rpc.publicnode.com}"
PRIORITY_FEE_GWEI="${PRIORITY_FEE_GWEI:-0}"
MAX_FEE_GWEI="${MAX_FEE_GWEI:-}"
EXPECTED_NONCE="${EXPECTED_NONCE:-}"
DEPLOYER_ADDRESS="$(cast wallet address "$PRIVATE_KEY")"

ARGS=(
  script/KimJongUn.s.sol:KimJongUnScript
  --rpc-url "$RPC_URL"
  --broadcast
  --verify
  --priority-gas-price "${PRIORITY_FEE_GWEI}gwei"
  --slow
  --non-interactive
)

if [[ -n "$MAX_FEE_GWEI" ]]; then
  ARGS+=(--with-gas-price "${MAX_FEE_GWEI}gwei")
fi

echo "Deploying KimJongUn to Ethereum mainnet"
echo "Deployer: $DEPLOYER_ADDRESS"
echo "RPC: $RPC_URL"
if [[ -n "$MAX_FEE_GWEI" ]]; then
  echo "Max fee: ${MAX_FEE_GWEI} gwei"
else
  echo "Max fee: RPC default"
fi
echo "Priority fee: ${PRIORITY_FEE_GWEI} gwei"

if [[ -n "$EXPECTED_NONCE" ]]; then
  CURRENT_NONCE="$(cast nonce "$DEPLOYER_ADDRESS" --rpc-url "$RPC_URL")"
  echo "Expected nonce: $EXPECTED_NONCE"
  echo "Current nonce: $CURRENT_NONCE"
  if [[ "$CURRENT_NONCE" != "$EXPECTED_NONCE" ]]; then
    echo "Nonce mismatch. Refusing to deploy." >&2
    exit 1
  fi
fi

forge script "${ARGS[@]}"
