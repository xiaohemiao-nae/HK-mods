@echo off
setlocal
net session >nul 2>&1
if %errorlevel% NEQ 0 (
  echo Requesting administrator privileges... Please approve the UAC prompt.
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0TripleWalkSpeed.ps1" -Action apply
echo.
pause
