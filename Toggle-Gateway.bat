@echo off
setlocal EnableDelayedExpansion
cd /d "%~dp0"
cls

echo Checking Docker daemon...
docker info >nul 2>&1
if %errorlevel% neq 0 (
    echo Docker is not running. Starting Docker Desktop...
    start "" "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    echo Waiting for Docker daemon to start...
    :wait_docker
    timeout /t 3 >nul
    docker info >nul 2>&1
    if errorlevel 1 goto wait_docker
    echo Docker is ready.
    echo.
)

echo Checking Gateway Status...
docker compose ps --status running | findstr "warp" >nul
if %errorlevel% == 0 (
    echo.
    echo Gateway is RUNNING. Stopping it now...
    docker compose down
    echo.
    echo Restoring normal internet (1.1.1.1). Administrator permissions required.
    netsh interface ipv4 set dnsservers "Wi-Fi" static 1.1.1.1 primary >nul 2>&1
    netsh interface ipv4 set dnsservers "Ethernet" static 1.1.1.1 primary >nul 2>&1
    echo.
    echo Gateway has been STOPPED.
) else (
    echo.
    echo Gateway is STOPPED. Starting it now...
    
    if exist "adguard\conf\AdGuardHome.yaml" (
        for %%I in ("adguard\conf\AdGuardHome.yaml") do if %%~zI==0 (
            del "adguard\conf\AdGuardHome.yaml"
            echo Removed corrupted empty AdGuardHome.yaml to prevent crash loop.
        )
    )

    docker compose up -d
    
    echo.
    echo Waiting for gateway container's Tailscale connection to be ready...
    set TS_IP=
    for /L %%i in (1,1,30) do (
        if "!TS_IP!"=="" (
            for /f "usebackq delims=" %%A in (`docker compose exec -T tailscale tailscale ip -4 2^>nul`) do if "!TS_IP!"=="" set "TS_IP=%%A"
            if "!TS_IP!"=="" timeout /t 1 >nul
        )
    )
    if not "!TS_IP!"=="" (
        echo Resolved gateway Tailscale IP: !TS_IP!
        echo.
        echo Hijacking DNS to route through AdGuard ^(!TS_IP!^). Administrator permissions required.
        netsh interface ipv4 set dnsservers "Wi-Fi" static !TS_IP! primary >nul 2>&1
        netsh interface ipv4 set dnsservers "Ethernet" static !TS_IP! primary >nul 2>&1
    ) else (
        if exist "ADGUARD_IP.txt" (
            set /p TS_IP=<ADGUARD_IP.txt
            if not "!TS_IP!"=="" (
                echo [Fallback] Using static IP from ADGUARD_IP.txt: !TS_IP!
                echo.
                echo Hijacking DNS to route through AdGuard ^(!TS_IP!^). Administrator permissions required.
                netsh interface ipv4 set dnsservers "Wi-Fi" static !TS_IP! primary >nul 2>&1
                netsh interface ipv4 set dnsservers "Ethernet" static !TS_IP! primary >nul 2>&1
            )
        ) else (
            echo.
            echo [Warning] Could not resolve gateway Tailscale IP. DNS hijacking skipped.
        )
    )

    echo.
    echo Gateway has been STARTED.
)
echo.
pause
