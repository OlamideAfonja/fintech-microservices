# =============================================================
# Fintech microservices - start all services (Windows / PowerShell)
# Opens each service in its own terminal window.
# =============================================================
# How to run:
#   powershell.exe -ExecutionPolicy Bypass -File ".\scripts\start-local.ps1"
# =============================================================

$ErrorActionPreference = "Stop"
$ROOT = Split-Path -Parent $PSScriptRoot
$LAUNCHERS = "$ROOT\scripts\launchers"

function Ok   { param($msg) Write-Host "OK  $msg" -ForegroundColor Green }
function Warn { param($msg) Write-Host "!!  $msg" -ForegroundColor Yellow }
function Die  { param($msg) Write-Host "ERR $msg" -ForegroundColor Red; exit 1 }

function Read-EnvFile {
    param([string]$EnvPath)
    $result = @{}
    if (-not (Test-Path $EnvPath)) { return $result }
    foreach ($line in (Get-Content $EnvPath)) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*$') { continue }
        $parts = $line -split '=', 2
        if ($parts.Length -eq 2) {
            $result[$parts[0].Trim()] = $parts[1].Trim()
        }
    }
    return $result
}

function Start-Service-Window {
    param(
        [string]$ServiceName,
        [string]$ServiceDir
    )

    $envFile = Join-Path $ServiceDir ".env"
    if (-not (Test-Path $envFile)) {
        Die "Missing .env for $ServiceName at $envFile - run setup-local.ps1 first"
    }

    $envVars = Read-EnvFile -EnvPath $envFile

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Auto-generated launcher for $ServiceName")
    $lines.Add('$ErrorActionPreference = "Stop"')

    foreach ($key in $envVars.Keys) {
        $val = $envVars[$key]
        $lines.Add('$env:' + $key + ' = "' + $val + '"')
    }

    $lines.Add('Set-Location "' + $ServiceDir + '"')
    $lines.Add('Write-Host "Starting ' + $ServiceName + '..." -ForegroundColor Cyan')
    $lines.Add("npm run dev")

    $launcherPath = Join-Path $LAUNCHERS "$ServiceName.ps1"
    $lines | Set-Content -Path $launcherPath -Encoding UTF8

    Start-Process powershell.exe -ArgumentList "-ExecutionPolicy", "Bypass", "-NoExit", "-File", $launcherPath

    Ok "Started $ServiceName (new window)"
}

Write-Host ""
Write-Host "Starting fintech microservices..." -ForegroundColor Cyan
Write-Host "Each service opens in its own window." -ForegroundColor Cyan
Write-Host "Close any window to stop that service." -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $LAUNCHERS)) {
    New-Item -ItemType Directory -Path $LAUNCHERS | Out-Null
}

Start-Service-Window -ServiceName "api-gateway"      -ServiceDir "$ROOT\services\api-gateway"
Start-Sleep -Milliseconds 800
Start-Service-Window -ServiceName "auth-service"     -ServiceDir "$ROOT\services\auth-service"
Start-Sleep -Milliseconds 800
Start-Service-Window -ServiceName "payments-service" -ServiceDir "$ROOT\services\payments-service"
Start-Sleep -Milliseconds 800
Start-Service-Window -ServiceName "wallet-service"   -ServiceDir "$ROOT\services\wallet-service"

Write-Host ""
Write-Host "All four service windows launched." -ForegroundColor Green
Write-Host "Wait about 10 seconds for them to connect to Neon and RabbitMQ." -ForegroundColor Yellow
Write-Host "Then run the demo:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  powershell.exe -ExecutionPolicy Bypass -File .\scripts\demo.ps1" -ForegroundColor Cyan
Write-Host ""