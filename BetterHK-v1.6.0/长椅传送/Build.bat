@echo off
setlocal
cd /d "%~dp0"
title BenchWarp - Build
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0BenchWarp.ps1" -Action build
echo.
pause
