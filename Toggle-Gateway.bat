@echo off
setlocal
cd /d "%~dp0"

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
    docker compose up -d
    echo.
    echo Gateway has been STARTED.
)
echo.
pause
