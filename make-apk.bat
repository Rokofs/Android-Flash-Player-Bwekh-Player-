@echo off
rem Builds FlashPlayer-arm64.apk and FlashPlayer-arm32.apk. See README.md
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\make-apk.ps1"
echo.
pause
