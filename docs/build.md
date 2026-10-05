# 本地编译指南

## 工具链（已验证）

| 组件 | 版本 |
|------|------|
| Flutter | 3.47.5 stable |
| AGP | 9.1.0 |
| Kotlin | 2.4.0 |
| JDK | 17 |
| compileSdk | 37 |
| minSdk | 24（Android 7.0+） |

## 步骤

```bash
flutter pub get
scripts\build-arm64.bat    # ARM64 单包 release，输出 app-release.apk
```

等价命令：`flutter build apk --release --target-platform android-arm64`

产物路径：`build/app/outputs/flutter-apk/app-release.apk`

## 注意事项

- **工程目录必须纯 ASCII** —— 非 ASCII 路径导致 release 构建 AOT 失败（debug 不受影响，容易踩坑）
- `android/local.properties`（SDK 路径）不入库，`flutter pub get` 会自动生成
