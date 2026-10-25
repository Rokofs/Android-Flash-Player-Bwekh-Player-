@echo off
rem Builds native Ruffle (Rust) for the APK: native\build\ruffle-libs\<abi>\libruffle_android.so
rem Only needed after changes in native\ruffle-rs (or once, the first time). Then run make-apk.bat. See README.md
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\build-ruffle-native.ps1"
echo.
pause
