@echo off
setlocal
cd /d "%~dp0"
title BenchWarp - Status
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0BenchWarp.ps1" -Action status
echo.
pause
