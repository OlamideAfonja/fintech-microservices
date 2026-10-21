# =============================================================
# Fintech microservices - local setup (Windows / PowerShell)
# Uses Neon (cloud Postgres) - no local Postgres install needed.
# Run once. Re-running is safe (idempotent).
# =============================================================
# Prerequisites:
#   Node 20+   -> https://nodejs.org
#   RabbitMQ   -> https://www.rabbitmq.com/install-windows.html
#                 (install Erlang first - linked on that page)
#   Neon DBs   -> https://neon.tech (free, create 3 DBs: auth, payments, wallet)
# =============================================================
# How to run (bypasses policy for this process only):
#   powershell.exe -ExecutionPolicy Bypass -File ".\scripts\setup-local.ps1"
# =============================================================

$ErrorActionPreference = "Stop"
$ROOT = Split-Path -Parent $PSScriptRoot

function Step { param($msg) Write-Host "" ; Write-Host ">> $msg" -ForegroundColor Cyan }
function Ok   { param($msg) Write-Host "OK  $msg" -ForegroundColor Green }
function Warn { param($msg) Write-Host "!!  $msg" -ForegroundColor Yellow }
function Die  { param($msg) Write-Host "ERR $msg" -ForegroundColor Red; exit 1 }

# ------------------------------------------------------------------
# 1. Node check
# ------------------------------------------------------------------

Step "Checking Node.js"

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Die "node not found. Install from https://nodejs.org (v20 or higher required)"
}

$nodeVer = node -e "process.stdout.write(process.versions.node.split('.')[0])"
if (([int]$nodeVer) -lt 20) {
    Die "Node v20+ required. You have $(node --version). Update at https://nodejs.org"
}

Ok "Node $(node --version)"

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Die "npm not found. Reinstall Node from https://nodejs.org"
}

Ok "npm $(npm --version)"

# ------------------------------------------------------------------
# 2. RabbitMQ check
# ------------------------------------------------------------------

Step "Checking RabbitMQ"

$rmq = Get-Service -Name "RabbitMQ" -ErrorAction SilentlyContinue

if ($null -eq $rmq) {
    Write-Host ""
    Write-Host "  RabbitMQ Windows service not found." -ForegroundColor Red
    Write-Host "  Install steps:" -ForegroundColor Yellow
    Write-Host "    1. Install Erlang:  https://www.erlang.org/downloads" -ForegroundColor Yellow
    Write-Host "    2. Install RabbitMQ: https://www.rabbitmq.com/install-windows.html" -ForegroundColor Yellow
    Write-Host "  Then re-run this script." -ForegroundColor Yellow
    exit 1
}

if ($rmq.Status -ne "Running") {
    Warn "RabbitMQ service exists but is not running. Starting it..."
    Start-Service -Name "RabbitMQ"
    Start-Sleep -Seconds 3
    $rmq = Get-Service -Name "RabbitMQ"
    if ($rmq.Status -ne "Running") {
        Die "Could not start RabbitMQ. Try: Start-Service RabbitMQ (as Administrator)"
    }
}

Ok "RabbitMQ is running"

# ------------------------------------------------------------------
# 3. Collect Neon connection strings
# ------------------------------------------------------------------

Step "Neon connection strings"

Write-Host ""
Write-Host "  You need 3 free Neon databases named: auth, payments, wallet" -ForegroundColor Yellow
Write-Host "  Sign up at https://neon.tech, create the databases, then" -ForegroundColor Yellow
Write-Host "  copy each connection string from the dashboard." -ForegroundColor Yellow
Write-Host ""
Write-Host "  Connection string format:" -ForegroundColor DarkGray
Write-Host "  postgresql://user:pass@ep-xxx.region.aws.neon.tech/dbname?sslmode=require" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  NOTE: Migrations are NOT run automatically by this script." -ForegroundColor Cyan
Write-Host "  After setup completes, open Neon Dashboard -> SQL Editor," -ForegroundColor Cyan
Write-Host "  select each database, and paste + run the matching .sql file:" -ForegroundColor Cyan
Write-Host "    auth     <- services\auth-service\migrations\001_init.sql" -ForegroundColor DarkGray
Write-Host "    payments <- services\payments-service\migrations\001_init.sql" -ForegroundColor DarkGray
Write-Host "    wallet   <- services\wallet-service\migrations\001_init.sql" -ForegroundColor DarkGray
Write-Host ""

$DB_AUTH = Read-Host "  Paste connection string for the AUTH database"
if (-not $DB_AUTH) { Die "AUTH connection string cannot be empty" }

$DB_PAYMENTS = Read-Host "  Paste connection string for the PAYMENTS database"
if (-not $DB_PAYMENTS) { Die "PAYMENTS connection string cannot be empty" }

$DB_WALLET = Read-Host "  Paste connection string for the WALLET database"
if (-not $DB_WALLET) { Die "WALLET connection string cannot be empty" }

Ok "All three connection strings captured"

# ------------------------------------------------------------------
# 4. Write .env files
# ------------------------------------------------------------------

Step "Writing .env files"

function Write-EnvFile {
    param(
        [string]$FilePath,
        [string[]]$Lines
    )
    if (Test-Path $FilePath) {
        Warn "$FilePath already exists - skipping. Delete it to regenerate."
        return
    }
    $Lines | Set-Content -Path $FilePath -Encoding UTF8
    Ok "Wrote $FilePath"
}

Write-EnvFile -FilePath "$ROOT\services\auth-service\.env" -Lines @(
    "DATABASE_URL=$DB_AUTH",
    "JWT_SECRET=local-dev-secret-change-before-prod",
    "PORT=4001"
)

Write-EnvFile -FilePath "$ROOT\services\payments-service\.env" -Lines @(
    "DATABASE_URL=$DB_PAYMENTS",
    "RABBITMQ_URL=amqp://127.0.0.1:5672",
    "PORT=4002"
)

Write-EnvFile -FilePath "$ROOT\services\wallet-service\.env" -Lines @(
    "DATABASE_URL=$DB_WALLET",
    "RABBITMQ_URL=amqp://127.0.0.1:5672",
    "PORT=4003"
)

Write-EnvFile -FilePath "$ROOT\services\api-gateway\.env" -Lines @(
    "AUTH_URL=http://127.0.0.1:4001",
    "PAYMENTS_URL=http://127.0.0.1:4002",
    "WALLET_URL=http://127.0.0.1:4003",
    "JWT_SECRET=local-dev-secret-change-before-prod",
    "PORT=4000"
)

# ------------------------------------------------------------------
# 5. npm install per service
# ------------------------------------------------------------------

Step "Installing npm dependencies"

$services = @("auth-service", "payments-service", "wallet-service", "api-gateway")

foreach ($svc in $services) {
    $dir = "$ROOT\services\$svc"

    if (-not (Test-Path $dir)) {
        Die "Service directory not found: $dir"
    }

    if (Test-Path "$dir\node_modules") {
        Ok "$svc - node_modules already present, skipping"
    } else {
        Write-Host "  Installing $svc..." -ForegroundColor DarkGray
        Push-Location $dir
        npm install --no-audit --no-fund --silent
        if ($LASTEXITCODE -ne 0) {
            Pop-Location
            Die "npm install failed for $svc"
        }
        Pop-Location
        Ok "$svc - installed"
    }
}

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  Setup complete." -ForegroundColor Green
Write-Host ""
Write-Host "  NEXT: Run migrations in Neon SQL Editor" -ForegroundColor Yellow
Write-Host "  THEN: Start services with:" -ForegroundColor Yellow
Write-Host "  powershell.exe -ExecutionPolicy Bypass -File `".\scripts\start-local.ps1`"" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
