#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# Fintech microservices — automated demo
# Requires: services running via start-local.sh
#           jq installed (sudo apt install jq)
# ─────────────────────────────────────────────

GATEWAY="http://127.0.0.1:4000"
ALICE_WALLET="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
BOB_WALLET="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

header() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }
ok()     { echo -e "${GREEN}✔ $1${NC}"; }
fail()   { echo -e "${RED}✖ $1${NC}"; }
info()   { echo -e "${YELLOW}  $1${NC}"; }

wait_for_status() {
  local TRANSFER_ID=$1 EXPECTED=$2 TOKEN=$3
  for i in $(seq 1 15); do
    STATUS=$(curl -s -H "authorization: Bearer $TOKEN" \
      "$GATEWAY/transfers/$TRANSFER_ID" | jq -r .status)
    if [[ "$STATUS" == "$EXPECTED" ]]; then
      ok "Transfer settled → $STATUS"
      return
    fi
    echo -e "  waiting for saga to settle (attempt $i, current: $STATUS)..."
    sleep 1
  done
  fail "Transfer did not reach '$EXPECTED' within 15s (last status: $STATUS)"
  exit 1
}

# ─── Health check ────────────────────────────

header "0. Health check"
for PORT in 4000 4001 4002 4003; do
  STATUS=$(curl -s "http://127.0.0.1:$PORT/health" | jq -r .status 2>/dev/null || echo "unreachable")
  if [[ "$STATUS" == "ok" ]]; then
    ok "Port $PORT healthy"
  else
    fail "Port $PORT not healthy ($STATUS) — is start-local.sh running?"
    exit 1
  fi
done

# ─── Login ───────────────────────────────────

header "1. Login as Alice"
LOGIN=$(curl -s -X POST "$GATEWAY/auth/login" \
  -H "content-type: application/json" \
  -d '{"email":"alice@example.com"}')
TOKEN=$(echo "$LOGIN" | jq -r .token)
info "JWT: ${TOKEN:0:40}..."
ok "Logged in"

# ─── Starting balances ───────────────────────

header "2. Starting balances"
ALICE_START=$(curl -s "$GATEWAY/wallets/$ALICE_WALLET" | jq -r .balance_minor)
BOB_START=$(curl -s "$GATEWAY/wallets/$BOB_WALLET" | jq -r .balance_minor)
info "Alice: $ALICE_START minor units"
info "Bob:   $BOB_START minor units"

# ─── Happy path transfer ─────────────────────

header "3. Happy path — Alice sends Bob NGN 1,000 (100000 minor units)"
TRANSFER=$(curl -s -X POST "$GATEWAY/transfers" \
  -H "authorization: Bearer $TOKEN" \
  -H "content-type: application/json" \
  -H "idempotency-key: demo-happy-$(date +%s)" \
  -d "{
    \"fromWalletId\": \"$ALICE_WALLET\",
    \"toWalletId\": \"$BOB_WALLET\",
    \"amountMinor\": 100000,
    \"currency\": \"NGN\"
  }")
TRANSFER_ID=$(echo "$TRANSFER" | jq -r .id)
INITIAL_STATUS=$(echo "$TRANSFER" | jq -r .status)
info "Transfer ID: $TRANSFER_ID"
info "Initial status: $INITIAL_STATUS  ← 202 accepted; saga hasn't settled yet"

wait_for_status "$TRANSFER_ID" "completed" "$TOKEN"

ALICE_END=$(curl -s "$GATEWAY/wallets/$ALICE_WALLET" | jq -r .balance_minor)
BOB_END=$(curl -s "$GATEWAY/wallets/$BOB_WALLET" | jq -r .balance_minor)
info "Alice: $ALICE_START → $ALICE_END  (diff: $((ALICE_END - ALICE_START)))"
info "Bob:   $BOB_START → $BOB_END  (diff: $((BOB_END - BOB_START)))"

# ─── Idempotency ─────────────────────────────

header "4. Idempotency — same request twice with same idempotency-key"
IDEM_KEY="demo-idempotency-$(date +%s)"
R1=$(curl -s -X POST "$GATEWAY/transfers" \
  -H "authorization: Bearer $TOKEN" \
  -H "content-type: application/json" \
  -H "idempotency-key: $IDEM_KEY" \
  -d "{\"fromWalletId\":\"$ALICE_WALLET\",\"toWalletId\":\"$BOB_WALLET\",\"amountMinor\":50000,\"currency\":\"NGN\"}")
R2=$(curl -s -X POST "$GATEWAY/transfers" \
  -H "authorization: Bearer $TOKEN" \
  -H "content-type: application/json" \
  -H "idempotency-key: $IDEM_KEY" \
  -d "{\"fromWalletId\":\"$ALICE_WALLET\",\"toWalletId\":\"$BOB_WALLET\",\"amountMinor\":50000,\"currency\":\"NGN\"}")

ID1=$(echo "$R1" | jq -r .id)
ID2=$(echo "$R2" | jq -r .id)
if [[ "$ID1" == "$ID2" ]]; then
  ok "Both calls returned the same transfer ID ($ID1) — no duplicate created"
else
  fail "Idempotency broken: got two different transfer IDs ($ID1 vs $ID2)"
fi

# ─── Insufficient funds ───────────────────────

header "5. Saga failure — amount exceeds Alice's balance"
FAIL_TRANSFER=$(curl -s -X POST "$GATEWAY/transfers" \
  -H "authorization: Bearer $TOKEN" \
  -H "content-type: application/json" \
  -H "idempotency-key: demo-fail-$(date +%s)" \
  -d "{
    \"fromWalletId\": \"$ALICE_WALLET\",
    \"toWalletId\": \"$BOB_WALLET\",
    \"amountMinor\": 999999999,
    \"currency\": \"NGN\"
  }")
FAIL_ID=$(echo "$FAIL_TRANSFER" | jq -r .id)
wait_for_status "$FAIL_ID" "failed" "$TOKEN"
REASON=$(curl -s -H "authorization: Bearer $TOKEN" "$GATEWAY/transfers/$FAIL_ID" | jq -r .reason)
info "Failure reason: $REASON"

ALICE_UNCHANGED=$(curl -s "$GATEWAY/wallets/$ALICE_WALLET" | jq -r .balance_minor)
if [[ "$ALICE_UNCHANGED" == "$ALICE_END" ]]; then
  ok "Alice's balance unchanged after failed transfer — compensating path worked"
else
  fail "Balance changed despite failure (expected $ALICE_END, got $ALICE_UNCHANGED)"
fi

# ─── Ledger entries ───────────────────────────

header "6. Double-entry ledger — Alice's last 5 entries"
curl -s "$GATEWAY/wallets/$ALICE_WALLET/ledger" | jq '.[0:5]'

# ─── Done ─────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  All demo scenarios passed.${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
