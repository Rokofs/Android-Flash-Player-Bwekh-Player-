<p align="center"><img src="icons/icon512.png" width="128" alt="Bwekh Player logo"></p>

<h1 align="center">Bwekh Player</h1>

> The app was written entirely with Claude!

> Inspirator and beta tester: manule

A Flash (SWF) game and animation player for Android 5+ (arm64 and arm32), built with the HARMAN AIR SDK. Version **1.9.2**. [Русская версия](README.ru.md)

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

**Signing key:** the archive comes without one. The first build creates `cert.p12` (password `flashplayer`). Keep it: an update installs only over an APK signed with the same key, so an APK built with a new key has to replace an installed one (uninstall it first; its saves go with it).

**Logs:** set `ENABLED = true` in `src/fp/Log.as` and rebuild. The log goes to `Download/BwekhPlayer-log.txt` on the phone.

## Running on a PC

To try games without a phone, run **`tools\desktop\run.bat`** (after `make-apk.bat` has run once: it saves the AIR SDK path to `sdk-path.txt`). It compiles the player and opens it in a window with AIR's `adl`.

- Put the `.swf` files into `tools\desktop\games` (the folder is made on the first start).
- Games play in AIR / AVM1; Ruffle runs only on the phone.
- With logging on, the log is `BwekhPlayer-log.txt` next to `run.bat`.
- The first start also builds the TLF library for Flash CS5 games (`tools\tlf`); later starts only when its sources change.

## Features

- File list from the app folder and, optionally, Download. "Open with" from any app.
- On-screen gamepad, pause, restart, seeking. Games run in landscape.
- Render resolution down to 144p for weak phones.
- Game saves for all engines, written on exit and when the app goes to the background.

If a game doesn't work in one engine, try another: AVM1 and Ruffle don't cover all of ActionScript.

## UX sketches

<p align="center">
  <img src="pic/UX-sketch_mainmenu.png" width="45%" alt="Main menu sketch">
  <img src="pic/UX-sketch_nowplaying.png" width="45%" alt="Now playing sketch">
</p>
<p align="center"><i>Sketches by Manul; Claude designed the UX from them.</i></p>

Ruffle is © Ruffle contributors (MIT / Apache-2.0). Adobe AIR is © HARMAN.
