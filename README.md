<p align="center"><img src="icons/icon512.png" width="128" alt="Bwekh Player logo"></p>

<h1 align="center">Bwekh Player</h1>

> The app was written entirely with Claude!

> Inspirator and beta tester: manule

A Flash (SWF) game and animation player for Android 5+ (arm64 and arm32), built with the HARMAN AIR SDK. Version **1.8.4**. [Русская версия](README.ru.md)

## Engines

- **AIR**: plays ActionScript 3 directly.
- **AVM1**: our own ActionScript 1/2 engine (`src/fp/avm1`).
- **Ruffle**: the native Rust Flash emulator (`native/ruffle-rs`). Needs OpenGL ES 3.0; on other phones the game opens in AVM1/AIR instead.

Set the default engine in Settings, or long-press a file to pick one just for that file.

## Building (Windows 10/11)

Install [HARMAN AIR SDK 51.x](https://airsdk.harman.com/download) and [Android Studio](https://developer.android.com/studio). Put the project in a folder with no spaces or non-Latin characters in its path (e.g. `C:\dev\BwekhPlayer`) and run **`make-apk.bat`**. The APKs appear in `dist`: `BwekhPlayer-arm64.apk` for most phones, `BwekhPlayer-arm32.apk` for older 32-bit ones.

The Java part and native Ruffle come prebuilt in `native\build`. Rebuild them only if you change their source code:

- `build-native.bat`: Java part (`native\android\src`). Needs JDK 17 (`winget install Microsoft.OpenJDK.17`).
- `build-ruffle-native.bat`: native Ruffle (`native\ruffle-rs`). Needs [Rust](https://rustup.rs) and the NDK (Android Studio → SDK Manager → SDK Tools → NDK). The first build takes 20–60 minutes.

**Signing key:** if there's no `cert.p12`, the first build creates one (password `flashplayer`). Keep it: an update installs only over an APK signed with the same key.

**Logs:** set `ENABLED = true` in `src/fp/Log.as` and rebuild. The log goes to `Download/BwekhPlayer-log.txt` on the phone.

## Features

- File list from the app folder and, optionally, Download. "Open with" from any app.
- On-screen gamepad, pause, restart, seeking. Games run in landscape.
- Render resolution down to 144p for weak phones.
- Game saves for all engines, written on exit and when the app goes to the background.

If a game doesn't work in one engine, try another: AVM1 and Ruffle don't cover all of ActionScript.

Ruffle is © Ruffle contributors (MIT / Apache-2.0). Adobe AIR is © HARMAN.
