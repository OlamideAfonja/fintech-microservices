#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# Fintech microservices — start all services
# Ctrl+C shuts everything down cleanly.
# ─────────────────────────────────────────────

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ANSI prefix colours per service
C_GATEWAY='\033[0;35m'  # magenta
C_AUTH='\033[0;34m'     # blue
C_PAYMENTS='\033[0;33m' # yellow
C_WALLET='\033[0;32m'   # green
NC='\033[0m'

# Run a service, prefix every output line with [name] in colour, load its .env
run_service() {
  local NAME=$1 COLOR=$2 DIR=$3
  (
    cd "$DIR"
    # Export vars from .env — skip comments and blank lines
    set -o allexport
    [[ -f .env ]] && source .env
    set +o allexport

    npm run dev 2>&1 | while IFS= read -r line; do
      echo -e "${COLOR}[${NAME}]${NC} $line"
    done
  ) &
  # Store PID so we can kill it on Ctrl+C
  PIDS+=($!)
}

PIDS=()

cleanup() {
  echo ""
  echo "Shutting down all services..."
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  echo "Done."
  exit 0
}
trap cleanup SIGINT SIGTERM

echo ""
echo "Starting fintech services... (Ctrl+C to stop all)"
echo ""

# Start in dependency order: auth first (gateway depends on it to verify tokens)
run_service "gateway " "$C_GATEWAY"  "$ROOT/services/api-gateway"
run_service "auth    " "$C_AUTH"     "$ROOT/services/auth-service"
run_service "payments" "$C_PAYMENTS" "$ROOT/services/payments-service"
run_service "wallet  " "$C_WALLET"   "$ROOT/services/wallet-service"

# Wait for all background processes
wait
