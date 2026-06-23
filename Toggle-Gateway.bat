@echo off
setlocal
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
    echo Gateway has been STARTED.
)
echo.
pause
