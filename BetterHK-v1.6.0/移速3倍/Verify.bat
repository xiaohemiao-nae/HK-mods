@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0TripleWalkSpeed.ps1" -Action verify
echo.
pause
