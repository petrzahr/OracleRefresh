@echo off
setlocal
title Database Refresh Utility
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0scripts\Start-OracleRefreshUI.ps1"
set "exitCode=%errorlevel%"
if not "%exitCode%"=="0" (
    echo.
    echo Database Refresh Utility could not start. See the error above.
    pause
)
exit /b %exitCode%
