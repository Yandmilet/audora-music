@echo off
REM Audora release build: ARM64-only, single APK (no split).
REM --target-platform android-arm64 compiles AOT for arm64 only;
REM output is a single app-release.apk (~20MB), directly installable:
REM   adb install -r build\app\outputs\flutter-apk\app-release.apk
cd /d "%~dp0"
flutter build apk --release --target-platform android-arm64
