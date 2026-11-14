@echo off
setlocal
cd /d "%~dp0"
title .NET SDK 8 Installer
set "ARGS=%*"

net session >nul 2>&1
if %errorlevel% EQU 0 goto :run
echo Requesting administrator privileges... Please approve the UAC prompt.
if "%ARGS%"=="" (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
) else (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -ArgumentList '%ARGS%'" >nul 2>&1
)
exit /b

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0InstallSDK8.ps1" %*
echo.
pause
