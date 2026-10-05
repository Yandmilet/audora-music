@echo off
REM Audora release build: ARM64-only, single APK (no split).
REM --target-platform android-arm64 compiles AOT for arm64 only;
REM output is a single app-release.apk (~20MB), directly installable:
REM   adb install -r build\app\outputs\flutter-apk\app-release.apk
REM 脚本位于 <项目根>/scripts/，%~dp0 指向脚本自身目录，需回退一级到项目根再构建
cd /d "%~dp0.."
flutter build apk --release --target-platform android-arm64
