@echo off
rem Rebuilds native\build\fpnative.jar from native\android\src (only needed after Java changes). See README.md
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\build-native.ps1"
echo.
pause
