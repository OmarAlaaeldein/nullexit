@echo off
setlocal EnableDelayedExpansion
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Toggle-Gateway.ps1"
