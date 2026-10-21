# =============================================================
# Fintech microservices - interactive CLI (Windows / PowerShell)
# =============================================================
# How to run:
#   powershell.exe -ExecutionPolicy Bypass -File ".\scripts\cli.ps1"
# =============================================================

$ErrorActionPreference = "Stop"

$GATEWAY = "http://127.0.0.1:4000"

# Seeded wallets - matches migrations
$WALLETS = @{
    "Alice" = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    "Bob"   = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
}

$TOKEN = $null
$LOGGED_IN_AS = $null

function Header {
    Clear-Host
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "   Fintech Microservices - Interactive CLI"     -ForegroundColor Cyan
    Write-Host "===============================================" -ForegroundColor Cyan
    if ($LOGGED_IN_AS) {
        Write-Host "   Logged in as: $LOGGED_IN_AS" -ForegroundColor Green
    } else {
        Write-Host "   Not logged in" -ForegroundColor Yellow
    }
    Write-Host "-----------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
}

function Ok   { param($msg) Write-Host "OK   $msg" -ForegroundColor Green }
function Err  { param($msg) Write-Host "ERR  $msg" -ForegroundColor Red }
function Info { param($msg) Write-Host "     $msg" -ForegroundColor Yellow }
function Sep  { Write-Host "" ; Write-Host "-----------------------------------------------" -ForegroundColor DarkGray }

function Pause {
    Write-Host ""
    Write-Host "Press any key to return to the menu..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

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

function AuthHeader {
    return @{ Authorization = "Bearer $TOKEN" }
}

function Require-Login {
    if (-not $TOKEN) {
        Err "You must log in first. Choose option 1 from the menu."
        Pause
        return $false
    }
    return $true
}

function Wait-ForStatus {
    param([string]$TransferId, [string]$Expected)
    Write-Host ""
    for ($i = 1; $i -le 20; $i++) {
        $result = Fetch -Uri "$GATEWAY/transfers/$TransferId" -Headers (AuthHeader)
        if ($result.status -eq $Expected -or $result.status -eq "failed") {
            return $result
        }
        Write-Host "  Waiting for saga to settle... ($i)" -ForegroundColor DarkGray
        Start-Sleep -Seconds 1
    }
    return $null
}

# ==================================================================
# Menu actions
# ==================================================================

function Do-Login {
    Header
    Write-Host "LOGIN" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Available users:"
    Write-Host "  1. alice@example.com"
    Write-Host "  2. bob@example.com"
    Write-Host "  3. Enter custom email"
    Write-Host ""
    $choice = Read-Host "  Choose (1/2/3)"

    $email = switch ($choice) {
        "1" { "alice@example.com" }
        "2" { "bob@example.com" }
        "3" { Read-Host "  Enter email" }
        default { "alice@example.com" }
    }

    try {
        $result = Fetch -Uri "$GATEWAY/auth/login" -Method "POST" -Body @{ email = $email }
        $script:TOKEN = $result.token
        $script:LOGGED_IN_AS = $email
        Ok "Logged in as $email"
    } catch {
        Err "Login failed: $_"
    }
    Pause
}

function Do-CheckBalance {
    Header
    Write-Host "WALLET BALANCES" -ForegroundColor Cyan
    Write-Host ""
    if (-not (Require-Login)) { return }

    try {
        foreach ($name in $WALLETS.Keys) {
            $id     = $WALLETS[$name]
            $wallet = Fetch -Uri "$GATEWAY/wallets/$id" -Headers (AuthHeader)
            $ngn    = [math]::Round($wallet.balance_minor / 100, 2)
            Info "$name ($id)"
            Write-Host "     Balance: $($wallet.balance_minor) minor units  (NGN $ngn)" -ForegroundColor White
            Write-Host ""
        }

        Write-Host "  Enter a custom wallet ID to check (or press Enter to skip):" -ForegroundColor DarkGray
        $customId = Read-Host "  Wallet ID"
        if ($customId) {
            $wallet = Fetch -Uri "$GATEWAY/wallets/$customId" -Headers (AuthHeader)
            $ngn    = [math]::Round($wallet.balance_minor / 100, 2)
            Info "Wallet $customId"
            Write-Host "     Balance: $($wallet.balance_minor) minor units  (NGN $ngn)" -ForegroundColor White
        }
    } catch {
        Err "Failed to fetch balance: $_"
    }
    Pause
}

function Do-Transfer {
    Header
    Write-Host "SEND TRANSFER" -ForegroundColor Cyan
    Write-Host ""
    if (-not (Require-Login)) { return }

    Write-Host "  FROM wallet:"
    Write-Host "  1. Alice  ($($WALLETS['Alice']))"
    Write-Host "  2. Bob    ($($WALLETS['Bob']))"
    Write-Host "  3. Custom wallet ID"
    Write-Host ""
    $fromChoice = Read-Host "  Choose (1/2/3)"
    $fromId = switch ($fromChoice) {
        "1" { $WALLETS["Alice"] }
        "2" { $WALLETS["Bob"] }
        "3" { Read-Host "  Enter FROM wallet ID" }
        default { $WALLETS["Alice"] }
    }

    Write-Host ""
    Write-Host "  TO wallet:"
    Write-Host "  1. Alice  ($($WALLETS['Alice']))"
    Write-Host "  2. Bob    ($($WALLETS['Bob']))"
    Write-Host "  3. Custom wallet ID"
    Write-Host ""
    $toChoice = Read-Host "  Choose (1/2/3)"
    $toId = switch ($toChoice) {
        "1" { $WALLETS["Alice"] }
        "2" { $WALLETS["Bob"] }
        "3" { Read-Host "  Enter TO wallet ID" }
        default { $WALLETS["Bob"] }
    }

    Write-Host ""
    $amountNgn   = Read-Host "  Amount in NGN (e.g. 1000 for NGN 1,000)"
    $amountMinor = [int]($amountNgn) * 100

    Write-Host ""
    Info "Sending NGN $amountNgn ($amountMinor minor units)..."
    Info "From: $fromId"
    Info "To:   $toId"
    Write-Host ""

    try {
        $key = "cli-$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
        $hdr = @{ Authorization = "Bearer $TOKEN"; "Idempotency-Key" = $key }

        $transfer = Fetch -Uri "$GATEWAY/transfers" -Method "POST" -Headers $hdr -Body @{
            fromWalletId = $fromId
            toWalletId   = $toId
            amountMinor  = $amountMinor
            currency     = "NGN"
        }

        Info "Transfer ID: $($transfer.id)"
        Info "Status:      $($transfer.status) (settling...)"

        $settled = Wait-ForStatus -TransferId $transfer.id -Expected "completed"

        if ($settled.status -eq "completed") {
            Ok "Transfer completed successfully"
        } else {
            Err "Transfer failed - reason: $($settled.reason)"
        }
    } catch {
        Err "Transfer request failed: $_"
    }
    Pause
}

function Do-CheckTransfer {
    Header
    Write-Host "CHECK TRANSFER STATUS" -ForegroundColor Cyan
    Write-Host ""
    if (-not (Require-Login)) { return }

    $transferId = Read-Host "  Enter Transfer ID"
    if (-not $transferId) { Pause; return }

    try {
        $t = Fetch -Uri "$GATEWAY/transfers/$transferId" -Headers (AuthHeader)
        Write-Host ""
        Write-Host "  Transfer Details" -ForegroundColor Cyan
        Write-Host "  ----------------"
        Info "ID:          $($t.id)"
        Info "Status:      $($t.status)"
        Info "From wallet: $($t.fromWalletId)"
        Info "To wallet:   $($t.toWalletId)"
        Info "Amount:      $($t.amountMinor) minor units  (NGN $([math]::Round($t.amountMinor / 100, 2)))"
        Info "Currency:    $($t.currency)"
        if ($t.reason) {
            Info "Reason:      $($t.reason)"
        }
        Info "Created:     $($t.createdAt)"
    } catch {
        Err "Could not find transfer: $_"
    }
    Pause
}

function Do-ViewLedger {
    Header
    Write-Host "VIEW LEDGER ENTRIES" -ForegroundColor Cyan
    Write-Host ""
    if (-not (Require-Login)) { return }

    Write-Host "  Which wallet?"
    Write-Host "  1. Alice  ($($WALLETS['Alice']))"
    Write-Host "  2. Bob    ($($WALLETS['Bob']))"
    Write-Host "  3. Custom wallet ID"
    Write-Host ""
    $choice   = Read-Host "  Choose (1/2/3)"
    $walletId = switch ($choice) {
        "1" { $WALLETS["Alice"] }
        "2" { $WALLETS["Bob"] }
        "3" { Read-Host "  Enter wallet ID" }
        default { $WALLETS["Alice"] }
    }

    $countStr = Read-Host "  How many entries to show? (default 10)"
    $count    = if ($countStr -match '^\d+$') { [int]$countStr } else { 10 }

    try {
        $ledger = Fetch -Uri "$GATEWAY/wallets/$walletId/ledger" -Headers (AuthHeader)
        if ($ledger.Count -eq 0) {
            Info "No ledger entries found for this wallet."
        } else {
            Write-Host ""
            $ledger | Select-Object -First $count |
                Format-Table transfer_id, direction, amount_minor, created_at -AutoSize
            Info "Showing $([math]::Min($count, $ledger.Count)) of $($ledger.Count) total entries"
        }
    } catch {
        Err "Could not fetch ledger: $_"
    }
    Pause
}

function Do-HealthCheck {
    Header
    Write-Host "SERVICE HEALTH" -ForegroundColor Cyan
    Write-Host ""
    $services = @{
        4000 = "api-gateway"
        4001 = "auth-service"
        4002 = "payments-service"
        4003 = "wallet-service"
    }
    foreach ($port in $services.Keys | Sort-Object) {
        try {
            $h = Fetch -Uri "http://127.0.0.1:$port/health"
            Ok "Port $port  $($services[$port])  -> $($h.status)"
        } catch {
            Err "Port $port  $($services[$port])  -> unreachable"
        }
    }
    Pause
}

# ==================================================================
# Main loop
# ==================================================================

while ($true) {
    Header
    Write-Host "  What do you want to do?" -ForegroundColor White
    Write-Host ""
    Write-Host "  1.  Login"                        -ForegroundColor White
    Write-Host "  2.  Check wallet balances"        -ForegroundColor White
    Write-Host "  3.  Send a transfer"              -ForegroundColor White
    Write-Host "  4.  Check transfer status by ID"  -ForegroundColor White
    Write-Host "  5.  View ledger entries"          -ForegroundColor White
    Write-Host "  6.  Service health check"         -ForegroundColor White
    Write-Host "  7.  Exit"                         -ForegroundColor DarkGray
    Write-Host ""

    $choice = Read-Host "  Enter choice"

    switch ($choice) {
        "1" { Do-Login }
        "2" { Do-CheckBalance }
        "3" { Do-Transfer }
        "4" { Do-CheckTransfer }
        "5" { Do-ViewLedger }
        "6" { Do-HealthCheck }
        "7" { Write-Host "Bye." -ForegroundColor Cyan; exit 0 }
        default {
            Err "Invalid choice. Enter a number from 1 to 7."
            Pause
        }
    }
}