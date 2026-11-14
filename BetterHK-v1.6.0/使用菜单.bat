@echo off
setlocal
cd /d "%~dp0"

rem ---------------------------------------------------------------------------
rem  Launcher only. The whole Chinese UI lives in Menu.ps1 (saved as UTF-8 with
rem  BOM), because a .bat that contains Chinese text gets mangled by the console
rem  code page and can even break its own path checks.
rem  Keep this file pure ASCII with CRLF line endings.
rem ---------------------------------------------------------------------------

if not exist "%~dp0Menu.ps1" (
  echo [ERROR] Menu.ps1 is missing. Please extract the whole zip first.
  echo.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Menu.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
exit /b %RC%
