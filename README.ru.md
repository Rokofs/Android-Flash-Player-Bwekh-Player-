> Приложение полностью написано через Claude!

# Bwekh Player

Проигрыватель Flash-игр и анимаций (SWF) для Android 5+ (arm64 и arm32) на HARMAN AIR SDK. Версия **1.8.4**. [English](README.md)

## Движки

- **AIR**: ActionScript 3 играет напрямую.
- **AVM1**: собственный движок для ActionScript 1/2 (`src/fp/avm1`).
- **Ruffle**: нативный эмулятор Flash на Rust (`native/ruffle-rs`). Нужен OpenGL ES 3.0; на других телефонах игра откроется в AVM1/AIR.

Движок по умолчанию выбирается в Settings, для отдельного файла — долгим нажатием на нём.

## Сборка (Windows 10/11)

Установите [HARMAN AIR SDK 51.x](https://airsdk.harman.com/download) и [Android Studio](https://developer.android.com/studio). Положите проект в папку без пробелов и кириллицы в пути (например `C:\dev\BwekhPlayer`) и запустите **`make-apk.bat`**. APK появятся в `dist`: `BwekhPlayer-arm64.apk` для большинства телефонов, `BwekhPlayer-arm32.apk` для старых 32-битных.

Java-часть и нативный Ruffle уже собраны (`native\build`). Пересобирать их нужно, только если вы меняли их код:

- `build-native.bat` — Java-часть (`native\android\src`). Нужен JDK 17 (`winget install Microsoft.OpenJDK.17`).
- `build-ruffle-native.bat` — нативный Ruffle (`native\ruffle-rs`). Нужны [Rust](https://rustup.rs) и NDK (Android Studio → SDK Manager → SDK Tools → NDK). Первая сборка 20–60 минут.

**Ключ подписи:** если `cert.p12` нет, первая сборка создаст его (пароль `flashplayer`). Сохраните его: обновление ставится только поверх APK с тем же ключом.

**Логи:** поставьте `ENABLED = true` в `src/fp/Log.as` и пересоберите. Лог пишется в `Download/BwekhPlayer-log.txt` на телефоне.

## Сборка (Linux)

Скрипта для Linux пока нет: команды ниже делают то же, что `make-apk.bat`. Установите [HARMAN AIR SDK 51.x](https://airsdk.harman.com/download) для Linux, JDK 17 (`sudo apt install openjdk-17-jdk` или пакет вашего дистрибутива), `unzip` и Android SDK с Platform 34 и Build-Tools 34.0.0 (через Android Studio или `sdkmanager "platforms;android-34" "build-tools;34.0.0" "platform-tools"`). Запускайте из папки проекта:

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

APK появятся в `dist`. Установить на телефон, подключённый по USB: `adb install -r dist/BwekhPlayer-arm64.apk`.

Готовые части пересобирать нужно, только если вы меняли их код:

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

Если `llvm-readelf -d` показывает, что `libruffle_android.so` нужна `libc++_shared.so`, скопируйте её рядом с библиотекой из `$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/<aarch64-linux-android|arm-linux-androideabi>/`. Первая сборка Ruffle 20–60 минут. Ключ подписи и логи работают так же, как в Windows.

## Возможности

- Список файлов из папки приложения и (по желанию) из Download. «Открыть с помощью» из любого приложения.
- Экранный геймпад, пауза, перезапуск, перемотка. Игры идут в альбомной ориентации.
- Разрешение рендера вплоть до 144p для слабых телефонов.
- Сохранения игр во всех движках: записываются при выходе и при сворачивании приложения.

Если игра не работает в одном движке, попробуйте другой: AVM1 и Ruffle поддерживают не весь ActionScript.

Ruffle © Ruffle contributors (MIT / Apache-2.0). Adobe AIR © HARMAN.
