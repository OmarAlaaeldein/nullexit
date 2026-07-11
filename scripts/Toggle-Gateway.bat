<# :
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression ([System.IO.File]::ReadAllText('%~f0') -replace '^(?s).*?#\s*>\s*\r?\n','')"
exit /b
#>
# Toggle-Gateway.bat (Hybrid Batch-PowerShell Toggler) — nullexit Gateway Toggler for Windows
# Mirrors the sophisticated error handling, checks, and automation of toggle.sh

# ─── 1. Administrator Check & Elevation ────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"Invoke-Expression ([System.IO.File]::ReadAllText('$PSCommandPath') -replace '^(?s).*?#\s*>\s*\r?\n','')`"" -Verb RunAs
    Exit
}

# Set console output encoding to UTF8 for clean symbols
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Clear-Host

Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║           nullexit Windows Toggler           ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

# ─── 2. Helpers ────────────────────────────────────────────────────────────────
function Reset-HostDNS {
    Write-Host "Restoring default DNS (DHCP/DHCP-assigned DNS)..." -ForegroundColor Cyan
    $activeAdapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
    foreach ($adapter in $activeAdapters) {
        Write-Host "  -> Resetting DNS on adapter: $($adapter.Name)" -ForegroundColor Gray
        Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ResetServerAddresses -ErrorAction SilentlyContinue
    }
}

function Hijack-HostDNS ($ip) {
    Write-Host "Hijacking DNS to route through AdGuard ($ip)..." -ForegroundColor Yellow
    $activeAdapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
    foreach ($adapter in $activeAdapters) {
        Write-Host "  -> Pointing DNS to $ip on adapter: $($adapter.Name)" -ForegroundColor Gray
        Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses $ip -ErrorAction SilentlyContinue
    }
}

function Get-HostTailscalePath {
    $paths = @(
        "$env:ProgramFiles\Tailscale\tailscale.exe",
        "$env:ProgramFiles (x86)\Tailscale\tailscale.exe",
        "tailscale.exe"
    )
    foreach ($path in $paths) {
        if (Test-Path $path) { return $path }
    }
    return $null
}

# ─── 3. Detect State ───────────────────────────────────────────────────────────
# Prevent deadlocks by resetting DNS to default temporarily during checks
Reset-HostDNS

Write-Host "Checking Docker daemon status..." -ForegroundColor Cyan
& docker info >$null 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker is not running. Starting Docker Desktop..." -ForegroundColor Yellow
    $dockerPath = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    if (Test-Path $dockerPath) {
        Start-Process $dockerPath
        Write-Host "Waiting for Docker daemon to become responsive..." -ForegroundColor Gray
        $timeout = 60
        while ($timeout -gt 0) {
            Start-Sleep -Seconds 2
            & docker info >$null 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Docker is ready!" -ForegroundColor Green
                break
            }
            $timeout -= 2
        }
        if ($timeout -le 0) {
            Write-Error "Docker failed to start in time. Aborting."
            Exit 1
        }
    } else {
        Write-Error "Docker Desktop executable not found at standard path. Please start Docker manually."
        Exit 1
    }
}

# Detect if gateway is already running
$runningWarp = docker compose ps --status running --format json | ConvertFrom-Json -ErrorAction SilentlyContinue | Where-Object { $_.Service -eq "warp" }
$isGatewayActive = ($null -ne $runningWarp)

# ─── 4. Execution ─────────────────────────────────────────────────────────────
if ($isGatewayActive) {
    # ─────────────────────────── STOP PATH ───────────────────────────
    Write-Host "Gateway is currently RUNNING. Disabling now..." -ForegroundColor Yellow
    Write-Host ""

    # Disconnect host Tailscale from exit node if installed
    $tsCli = Get-HostTailscalePath
    if ($null -ne $tsCli) {
        Write-Host "Disconnecting host Tailscale from exit node..." -ForegroundColor Cyan
        & $tsCli up --exit-node= --accept-dns=true >$null 2>&1
    }

    Write-Host "Stopping Docker containers..." -ForegroundColor Cyan
    docker compose down -t 5

    Reset-HostDNS
    Write-Host "Gateway has been successfully STOPPED." -ForegroundColor Green
} else {
    # ─────────────────────────── START PATH ───────────────────────────
    Write-Host "Gateway is currently STOPPED. Enabling now..." -ForegroundColor Yellow
    Write-Host ""

    # Clean up corrupted AdGuardHome configurations
    $confFile = "adguard\conf\AdGuardHome.yaml"
    if (Test-Path $confFile) {
        $fileSize = (Get-Item $confFile).Length
        if ($fileSize -eq 0) {
            Remove-Item $confFile -Force
            Write-Host "Removed corrupted empty AdGuardHome.yaml to prevent container crash loop." -ForegroundColor Yellow
        }
    }

    Write-Host "Starting Docker containers..." -ForegroundColor Cyan
    docker compose up -d

    Write-Host "Waiting for container's Tailscale connection to offer Exit Node..." -ForegroundColor Cyan
    Write-Host "  (This can take up to 60 seconds...)" -ForegroundColor Gray

    $elapsed = 0
    $maxWait = 60
    $resolvedIP = $null

    while ($elapsed -lt $maxWait) {
        $statusJson = docker compose exec -T tailscale tailscale status --json 2>$null
        if ($null -ne $statusJson) {
            $status = $statusJson | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($null -ne $status -and $null -ne $status.Self) {
                # Check if it has a valid Tailscale IP and is running
                if ($status.Self.Online -and $status.Self.TailscaleIPs.Count -gt 0) {
                    $resolvedIP = $status.Self.TailscaleIPs[0]
                    break
                }
            }
        }
        Start-Sleep -Seconds 2
        $elapsed += 2
    }

    if ($null -ne $resolvedIP) {
        Write-Host "Tailscale IP resolved: $resolvedIP" -ForegroundColor Green
        Write-Host ""

        # Configure host Tailscale client to route through this exit node
        $tsCli = Get-HostTailscalePath
        if ($null -ne $tsCli) {
            Write-Host "Configuring host Tailscale to use Exit Node ($resolvedIP)..." -ForegroundColor Cyan
            & $tsCli up --exit-node=$resolvedIP --accept-dns=false >$null 2>&1
        }

        # Hijack DNS
        Hijack-HostDNS $resolvedIP
        Write-Host ""
        Write-Host "Gateway has been successfully STARTED." -ForegroundColor Green
    } else {
        Write-Host "Warning: Could not resolve gateway Tailscale IP. DNS hijacking skipped." -ForegroundColor Red
        # Fallback to .gateway_ip if it exists
        if (Test-Path ".gateway_ip") {
            $fallbackIP = Get-Content ".gateway_ip" -TotalCount 1
            if (-not [string]::IsNullOrWhiteSpace($fallbackIP)) {
                Write-Host "[Fallback] Using static IP from .gateway_ip: $fallbackIP" -ForegroundColor Yellow
                Hijack-HostDNS $fallbackIP
                Write-Host "Gateway STARTED (with static fallback IP)." -ForegroundColor Green
            }
        } else {
            Write-Host "Gateway started in offline/unauthenticated state. Run setup.sh if this is a fresh setup." -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "Press any key to exit..."
[void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
