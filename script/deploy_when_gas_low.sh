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
MAX_FEE_GWEI="${MAX_FEE_GWEI:-2.05}"
PRIORITY_FEE_GWEI="${PRIORITY_FEE_GWEI:-0}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-30}"
GAS_API_URL="https://api.etherscan.io/v2/api?chainid=1&module=gastracker&action=gasoracle&apikey=${ETHERSCAN_API_KEY}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/.deploy}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_FILE:-$LOG_DIR/deploy-$(date +%Y%m%d-%H%M%S).log}"

DEPLOYER_ADDRESS="$(cast wallet address "$PRIVATE_KEY")"
TARGET_CONTRACT="script/KimJongUn.s.sol:KimJongUnScript"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

balance_eth() {
  cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RPC_URL" | awk '{ printf "%.18f", $1 / 1000000000000000000 }'
}

threshold_met() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
base = float(sys.argv[1])
tip = float(sys.argv[2])
limit = float(sys.argv[3])
sys.exit(0 if (base + tip) <= limit else 1)
PY
}

log "Watching Ethereum mainnet gas for deploy threshold."
log "Deployer: $DEPLOYER_ADDRESS"
log "RPC URL: $RPC_URL"
log "Threshold: base fee + priority fee <= ${MAX_FEE_GWEI} gwei"
log "Configured priority fee: ${PRIORITY_FEE_GWEI} gwei"
log "Current deployer balance: $(balance_eth) ETH"
log "Log file: $LOG_FILE"

while true; do
  response="$(curl -fsSL "$GAS_API_URL")"

  status="$(printf '%s' "$response" | jq -r '.status')"
  if [[ "$status" != "1" ]]; then
    message="$(printf '%s' "$response" | jq -r '.message // "unknown error"')"
    log "Gas API error: $message"
    sleep "$POLL_INTERVAL_SECONDS"
    continue
  fi

  base_fee="$(printf '%s' "$response" | jq -r '.result.suggestBaseFee')"
  propose_fee="$(printf '%s' "$response" | jq -r '.result.ProposeGasPrice')"
  fast_fee="$(printf '%s' "$response" | jq -r '.result.FastGasPrice')"

  log "Observed gas: base=${base_fee} gwei, propose=${propose_fee} gwei, fast=${fast_fee} gwei"

  if threshold_met "$base_fee" "$PRIORITY_FEE_GWEI" "$MAX_FEE_GWEI"; then
    log "Threshold met. Broadcasting deploy and requesting Etherscan verification."
    forge script "$TARGET_CONTRACT" \
      --rpc-url "$RPC_URL" \
      --broadcast \
      --verify \
      --with-gas-price "${MAX_FEE_GWEI}gwei" \
      --priority-gas-price "${PRIORITY_FEE_GWEI}gwei" \
      --slow \
      --non-interactive | tee -a "$LOG_FILE"
    log "Deploy command completed."
    exit 0
  fi

  sleep "$POLL_INTERVAL_SECONDS"
done
