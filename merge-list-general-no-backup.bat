@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0merge-list-general.ps1" -NoBackup %*
echo.
pause
