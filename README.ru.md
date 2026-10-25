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

## Возможности

- Список файлов из папки приложения и (по желанию) из Download. «Открыть с помощью» из любого приложения.
- Экранный геймпад, пауза, перезапуск, перемотка. Игры идут в альбомной ориентации.
- Разрешение рендера вплоть до 144p для слабых телефонов.
- Сохранения игр во всех движках: записываются при выходе и при сворачивании приложения.

Если игра не работает в одном движке, попробуйте другой: AVM1 и Ruffle поддерживают не весь ActionScript.

Ruffle © Ruffle contributors (MIT / Apache-2.0). Adobe AIR © HARMAN.
