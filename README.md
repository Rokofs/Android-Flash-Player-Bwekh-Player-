> The app was written entirely with Claude!

>Insipirator and beta tester: manule

# Bwekh Player

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

## Building (Linux)

There's no script for Linux yet: the commands below do the same as `make-apk.bat`. Install the Linux [HARMAN AIR SDK 51.x](https://airsdk.harman.com/download), JDK 17 (`sudo apt install openjdk-17-jdk`, or your distro's package), `unzip`, and the Android SDK with Platform 34 and Build-Tools 34.0.0 (via Android Studio, or `sdkmanager "platforms;android-34" "build-tools;34.0.0" "platform-tools"`). Run from the project folder:

```sh
export AIR_SDK=~/sdks/AIRSDK_51.1      # your AIR SDK folder (the one with bin/adt)
export ANDROID_HOME=~/Android/Sdk
mkdir -p ~/.airsdk && echo "AndroidPlatformSDK=$ANDROID_HOME" > ~/.airsdk/adt.cfg

# 1. Native extension (.ane)
rm -rf build bin && mkdir -p build/ext build/swc bin/icons bin/ruffle
mkdir -p build/ane/default build/ane/android-arm/libs/armeabi-v7a build/ane/android-arm64/libs/arm64-v8a
"$AIR_SDK/bin/acompc" -source-path native/as3 -include-classes com.vibefoxcodding.fpnative.FPNative -output build/fpnative.swc
unzip -o build/fpnative.swc library.swf -d build/swc
cp build/swc/library.swf build/ane/default/
for p in android-arm android-arm64; do cp build/swc/library.swf native/build/fpnative.jar build/ane/$p/; done
cp native/build/ruffle-libs/armeabi-v7a/*.so build/ane/android-arm/libs/armeabi-v7a/
cp native/build/ruffle-libs/arm64-v8a/*.so build/ane/android-arm64/libs/arm64-v8a/
"$AIR_SDK/bin/adt" -package -target ane build/ext/com.vibefoxcodding.fpnative.ane native/extension.xml -swc build/fpnative.swc \
  -platform Android-ARM -C build/ane/android-arm . \
  -platform Android-ARM64 -C build/ane/android-arm64 . \
  -platform default -C build/ane/default .

# 2. The app
"$AIR_SDK/bin/amxmlc" +configname=airmobile -source-path+=src -external-library-path+=build/fpnative.swc \
  -output bin/FlashPlayer.swf src/Main.as
cp icons/icon*.png bin/icons/ && rm bin/icons/icon512.png
echo native > bin/ruffle/native.txt

# 3. Signing key (once) and APKs
[ -f cert.p12 ] || "$AIR_SDK/bin/adt" -certificate -cn BwekhPlayer -validityPeriod 25 2048-RSA cert.p12 flashplayer
sed 's|<manifest android:installLocation="auto">|&\n\t<uses-sdk android:minSdkVersion="21" android:targetSdkVersion="30"/>|' \
  application.xml > build/application-arm32.xml
mkdir -p dist
for t in "armv8 BwekhPlayer-arm64.apk application.xml" "armv7 BwekhPlayer-arm32.apk build/application-arm32.xml"; do
  set -- $t
  "$AIR_SDK/bin/adt" -package -target apk-captive-runtime -arch $1 -storetype pkcs12 -keystore cert.p12 -storepass flashplayer \
    dist/$2 $3 -platformsdk "$ANDROID_HOME" -extdir build/ext -C bin FlashPlayer.swf icons ruffle
done
```

The APKs appear in `dist`. To install on a phone connected over USB: `adb install -r dist/BwekhPlayer-arm64.apk`.

Rebuild the prebuilt parts only if you change their source code:

```sh
# Java part -> native/build/fpnative.jar (JDK 17)
AJAR=$(ls "$ANDROID_HOME"/platforms/android-*/android.jar | sort -V | tail -1)
mkdir -p build/native-stubs build/native-classes
javac --release 8 -encoding UTF-8 -nowarn -cp "$AJAR" -d build/native-stubs $(find native/android/fre-stubs -name '*.java')
javac --release 8 -encoding UTF-8 -nowarn -cp "$AJAR:build/native-stubs" -d build/native-classes $(find native/android/src -name '*.java')
jar cf native/build/fpnative.jar -C build/native-classes .

# Native Ruffle -> native/build/ruffle-libs (Rust + NDK)
export ANDROID_NDK_HOME=$(ls -d "$ANDROID_HOME"/ndk/* | sort -V | tail -1)
cd native/ruffle-rs
rustup toolchain install && rustup target add aarch64-linux-android armv7-linux-androideabi
cargo install cargo-ndk
rm -rf ../build/ruffle-libs
cargo ndk -t armeabi-v7a -t arm64-v8a -P 21 -o ../build/ruffle-libs build --release
cd ../..
```

If `llvm-readelf -d` shows that `libruffle_android.so` needs `libc++_shared.so`, copy it next to the library from `$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/<aarch64-linux-android|arm-linux-androideabi>/`. The first Ruffle build takes 20–60 minutes. The signing key and logs work the same as on Windows.

## Features

- File list from the app folder and, optionally, Download. "Open with" from any app.
- On-screen gamepad, pause, restart, seeking. Games run in landscape.
- Render resolution down to 144p for weak phones.
- Game saves for all engines, written on exit and when the app goes to the background.

If a game doesn't work in one engine, try another: AVM1 and Ruffle don't cover all of ActionScript.

Ruffle is © Ruffle contributors (MIT / Apache-2.0). Adobe AIR is © HARMAN.
