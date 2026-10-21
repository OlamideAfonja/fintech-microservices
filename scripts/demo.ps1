# =============================================================
# Fintech microservices - automated demo (Windows / PowerShell)
# =============================================================
# How to run:
#   powershell.exe -ExecutionPolicy Bypass -File ".\scripts\demo.ps1"
# =============================================================

$ErrorActionPreference = "Stop"

$GATEWAY      = "http://127.0.0.1:4000"
$ALICE_WALLET = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
$BOB_WALLET   = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

function Step { param($msg) Write-Host "" ; Write-Host "=== $msg ===" -ForegroundColor Cyan }
function Ok   { param($msg) Write-Host "OK  $msg" -ForegroundColor Green }
function Fail { param($msg) Write-Host "ERR $msg" -ForegroundColor Red; exit 1 }
function Info { param($msg) Write-Host "    $msg" -ForegroundColor Yellow }

function Fetch {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [hashtable]$Headers = @{},
        [hashtable]$Body = $null
    )
    $params = @{ Uri = $Uri; Method = $Method; Headers = $Headers }
    if ($null -ne $Body) {
        $params["Body"]        = ($Body | ConvertTo-Json -Compress -Depth 5)
        $params["ContentType"] = "application/json"
    }
    Invoke-RestMethod @params
}

function Wait-ForStatus {
    param([string]$TransferId, [string]$Expected, [string]$Token)
    for ($i = 1; $i -le 15; $i++) {
        $result = Fetch -Uri "$GATEWAY/transfers/$TransferId" -Headers @{ Authorization = "Bearer $Token" }
        if ($result.status -eq $Expected) {
            Ok "Transfer settled -> $($result.status)"
            return $result
        }
        Info "Waiting for saga... attempt $i, current status: $($result.status)"
        Start-Sleep -Seconds 1
    }
    Fail "Transfer did not reach '$Expected' within 15 seconds"
}

# ==================================================================
# 0. Health checks
# ==================================================================

Step "0. Health check - all four services"

foreach ($port in @(4000, 4001, 4002, 4003)) {
    try {
        $h = Fetch -Uri "http://127.0.0.1:$port/health"
        Ok "Port $port -> $($h.status)"
    } catch {
        Fail "Port $port not reachable. Is start-local.ps1 still running? Error: $_"
    }
}

# ==================================================================
# 1. Login as Alice
# ==================================================================

Step "1. Login as Alice"

$login = Fetch -Uri "$GATEWAY/auth/login" -Method "POST" -Body @{ email = "alice@example.com" }
$TOKEN = $login.token
$AUTH  = @{ Authorization = "Bearer $TOKEN" }

Info "JWT (first 40 chars): $($TOKEN.Substring(0, 40))..."
Ok "Logged in as Alice"

# ==================================================================
# 2. Starting balances
# ==================================================================

Step "2. Starting balances"

$aliceStart = (Fetch -Uri "$GATEWAY/wallets/$ALICE_WALLET" -Headers $AUTH).balance_minor
$bobStart   = (Fetch -Uri "$GATEWAY/wallets/$BOB_WALLET"   -Headers $AUTH).balance_minor

Info "Alice: $aliceStart minor units"
Info "Bob:   $bobStart minor units"

# ==================================================================
# 3. Happy path - Alice sends Bob NGN 1,000
# ==================================================================

Step "3. Happy path - Alice sends Bob NGN 1000 (100000 minor units)"

$happyKey  = "demo-happy-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$happyHdr  = @{ Authorization = "Bearer $TOKEN"; "Idempotency-Key" = $happyKey }

$transfer = Fetch -Uri "$GATEWAY/transfers" -Method "POST" -Headers $happyHdr -Body @{
    fromWalletId = $ALICE_WALLET
    toWalletId   = $BOB_WALLET
    amountMinor  = 100000
    currency     = "NGN"
}

Info "Transfer ID:    $($transfer.id)"
Info "Initial status: $($transfer.status)  <- 202 accepted, saga not settled yet"

$null = Wait-ForStatus -TransferId $transfer.id -Expected "completed" -Token $TOKEN

$aliceAfterStep3 = (Fetch -Uri "$GATEWAY/wallets/$ALICE_WALLET" -Headers $AUTH).balance_minor
$bobAfterStep3   = (Fetch -Uri "$GATEWAY/wallets/$BOB_WALLET"   -Headers $AUTH).balance_minor

Info "Alice: $aliceStart -> $aliceAfterStep3  (diff: $($aliceAfterStep3 - $aliceStart))"
Info "Bob:   $bobStart -> $bobAfterStep3  (diff: $($bobAfterStep3 - $bobStart))"

# ==================================================================
# 4. Idempotency - same request replayed, no duplicate created
# ==================================================================

Step "4. Idempotency - same Idempotency-Key sent twice"

$sharedKey = "demo-idempotency-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$idemHdr   = @{ Authorization = "Bearer $TOKEN"; "Idempotency-Key" = $sharedKey }
$idemBody  = @{ fromWalletId = $ALICE_WALLET; toWalletId = $BOB_WALLET; amountMinor = 50000; currency = "NGN" }

$r1 = Fetch -Uri "$GATEWAY/transfers" -Method "POST" -Headers $idemHdr -Body $idemBody
$r2 = Fetch -Uri "$GATEWAY/transfers" -Method "POST" -Headers $idemHdr -Body $idemBody

if ($r1.id -eq $r2.id) {
    Ok "Both calls returned the same transfer ID: $($r1.id)"
    Ok "No duplicate transfer created - idempotency is working"
} else {
    Fail "Idempotency broken - got two different IDs: $($r1.id) vs $($r2.id)"
}

# Wait for the idempotency transfer to settle, then snapshot the real balance.
# This is the correct baseline for step 5 - the 50000 transfer above is real
# and does move money, so we must capture the updated balance before checking
# that the failure in step 5 leaves it unchanged.
$null = Wait-ForStatus -TransferId $r1.id -Expected "completed" -Token $TOKEN
$aliceBeforeFailure = (Fetch -Uri "$GATEWAY/wallets/$ALICE_WALLET" -Headers $AUTH).balance_minor
Info "Alice balance after idempotency transfer: $aliceBeforeFailure"

# ==================================================================
# 5. Saga failure - amount exceeds balance
# ==================================================================

Step "5. Saga failure - amount larger than Alice balance"

$failKey = "demo-fail-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$failHdr = @{ Authorization = "Bearer $TOKEN"; "Idempotency-Key" = $failKey }

$failTransfer = Fetch -Uri "$GATEWAY/transfers" -Method "POST" -Headers $failHdr -Body @{
    fromWalletId = $ALICE_WALLET
    toWalletId   = $BOB_WALLET
    amountMinor  = 999999999
    currency     = "NGN"
}

$failed = Wait-ForStatus -TransferId $failTransfer.id -Expected "failed" -Token $TOKEN
Info "Failure reason: $($failed.reason)"

$aliceAfterFailure = (Fetch -Uri "$GATEWAY/wallets/$ALICE_WALLET" -Headers $AUTH).balance_minor

if ($aliceAfterFailure -eq $aliceBeforeFailure) {
    Ok "Alice balance unchanged after failure: $aliceAfterFailure"
    Ok "Saga compensating path worked correctly"
} else {
    Fail "Balance changed despite failure. Expected $aliceBeforeFailure, got $aliceAfterFailure"
}

# ==================================================================
# 6. Double-entry ledger
# ==================================================================

Step "6. Double-entry ledger - Alice last 5 entries"

$ledger = Fetch -Uri "$GATEWAY/wallets/$ALICE_WALLET/ledger" -Headers $AUTH
$ledger | Select-Object -First 5 | Format-Table transfer_id, direction, amount_minor, created_at -AutoSize

# ==================================================================
# Done
# ==================================================================

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  All demo scenarios passed successfully."    -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""