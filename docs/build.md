# 本地编译指南

> 本文由原 README「本地编译」章节迁出。

## 已验证工具链（2026-09-29 实测通过）

| 组件                     | 版本                                 |
| ---------------------- | ---------------------------------- |
| Flutter                | 3.47.5 stable                      |
| AGP                    | 9.1.0                              |
| Gradle                 | 9.3.1（wrapper 已含）                  |
| Kotlin                 | 2.4.0                              |
| JDK                    | 17                                 |
| compileSdk / targetSdk | 36（Flutter 默认）                     |
| minSdk                 | 24（Android 7.0+，Flutter 3.47 强制下限） |

> 注：设计文档原定 minSdk 23（Android 6.0），但 Flutter 3.47 的构建迁移器会把
> `minSdk = 16~23` 自动改写为默认值 24（已实测：APK `sdkVersion:'24'`）。
> 如确需 Android 6.0 支持，需降级 Flutter 或自行改造迁移规则，个人自用场景无实际影响。

## 步骤

```bash
# 1. 拉依赖
flutter pub get

# 2. 构建（按 ABI 分包）
flutter build apk --release --split-per-abi
```

产物路径：`build/app/outputs/flutter-apk/app-<abi>-release.apk`

### 仅构建 ARM64 单包

仓库提供一键脚本（输出单个 ~20MB 的 app-release.apk，可直接 `adb install -r`）：

```bash
scripts\build-arm64.bat
```

脚本内容等价于 `flutter build apk --release --target-platform android-arm64`。

## ⚠️ 路径要求（重要）

工程目录名必须是**纯 ASCII**。Windows 上
Flutter 的 AOT 编译器无法处理非 ASCII 路径，release 构建会报：

```
Error: Unable to read file: ...app.dill
Dart snapshot generator failed with exit code 255
```

（debug 构建因走 JIT 不受影响，仅 release 会失败——因此中文目录名的问题
在 debug 阶段不会暴露，极易踩坑。）

## 关于 `local.properties`

`android/local.properties` 包含本机 SDK 绝对路径，**不提交到版本库**（已在 `.gitignore` 中）。
克隆后首次构建若报找不到 SDK，手动创建并改成自己的路径：

```properties
sdk.dir=/your/path/to/Android/Sdk
flutter.sdk=/your/path/to/flutter
```

> Flutter 在 `flutter pub get` / 构建时通常会自动生成该文件。
