# 工具链版本锁定清单 (Toolchain Lock)

> 目的：把 Audora 的构建工具链钉死到一套**已验证可 `flutter build`（debug + release）**的版本组合，
> 保证任意机器 clone 后能复现同样的构建结果。最后更新：2026-10-11。
> 校验方式：见文末「验证」。改动任何一行都要重新跑验证并更新本清单。

## 一、锁定版本矩阵

| 组件 | 锁定版本 | 强制位置 | 备注 |
|------|---------|---------|------|
| Flutter | **3.47.5** (stable) | `pubspec.yaml` `environment.flutter: '>=3.47.5 <3.48.0'` | 见「偏差说明」关于 3.47.6 |
| Dart | **3.13.4** | `pubspec.yaml` `environment.sdk: '>=3.13.4 <4.0.0'` | 随 Flutter |
| Flutter Engine | `ab598368592da0064197e2bc15c7f5b0a2c6bb1f` (rev `af7e796e16`) | 随 Flutter SDK | 记录用 |
| DevTools | 2.60.0 | 随 Flutter SDK | 记录用 |
| AGP (Android Gradle Plugin) | **9.1.0** | `android/settings.gradle.kts` | 官方模板默认 |
| Gradle | **9.3.1** (bin) | `android/gradle/wrapper/gradle-wrapper.properties` | 带校验和，见下 |
| Gradle 发行版 SHA256 | `b266d5ff6b90eada6dc3b20cb090e3731302e553a27c5d3e4df1f0d76beaff06` | 同上 `distributionSha256Sum` | 锁死字节，防漂移/篡改 |
| Kotlin Gradle Plugin | **2.4.0** | `android/settings.gradle.kts` | 官方模板默认 |
| compileSdk | **37** | `android/app/build.gradle.kts` | ⚠️ 高于官方默认 36，见偏差说明 |
| targetSdk | **36** (`flutter.targetSdkVersion`) | `android/app/build.gradle.kts` | 官方默认 |
| minSdk | **24** (`flutter.minSdkVersion`) | `android/app/build.gradle.kts` | 官方默认 |
| NDK | **28.2.13676358** (`flutter.ndkVersion`) | 随 Flutter SDK；已装于 `android-sdk/ndk` | |
| Java (source/target/jvmTarget) | **17** | `android/app/build.gradle.kts` | |
| JDK（构建机实测） | Microsoft OpenJDK **17.0.20**+1-LTS | 机器环境（非仓库） | 见「环境依赖」 |
| Android SDK Platform | android-37 | 机器环境 | compileSdk 37 需要 |
| Android build-tools | 36.0.0 | 机器环境 | |
| 真机验证目标 | MEIZU 21 / Android 16 (API 36) | — | 逐字歌词装机验机用 |

## 二、全局构建行为锁定（GRADLE_USER_HOME）

- 实际位置：`%GRADLE_USER_HOME%\gradle.properties`（本机 = `C:\FlutterDev\caches\gradle`）。
- 仓库内权威镜像：**`toolchain/global-gradle.properties`** —— 新机器部署时复制到该机的 `%GRADLE_USER_HOME%\gradle.properties`。
- 关键项：`parallel/daemon/caching=true`、`nonTransitiveRClass=true`、`enableJetifier=false`。
- **`configuration-cache` 已关闭**（见第三节）。注意：GRADLE_USER_HOME 的属性优先级**高于**项目内 `android/gradle.properties`，所以配置缓存开关要在全局文件里控制，项目里写 `=false` 会被盖掉。

## 三、configuration cache：为什么关（重要教训）

- 症状：`flutter build`/`flutter run` 在配置缓存序列化阶段崩，报 `:app:DebugMinSdkCheck` / `:app:assembleDebug` 无法序列化 `DefaultProject`/`ConfigurationContainer`/`BuildService`，以及 `java.lang.ref.ReferenceQueue ... module java.base does not "opens java.lang.ref"`。
- 根因：**不是** Flutter 版本问题（3.47.5→3.47.6 的 6 个提交**没有一个**碰 `flutter_tools/gradle` build-logic）。真因是全局 `gradle.properties` 里 `org.gradle.configuration-cache=true` 强行开启，而 Flutter 3.47.x 的 build-logic（`addFlutterTasks` 捕获 `ApkVariantOutputImpl`、`DependencyVersionChecker`）与 AGP 9 的配置缓存不兼容。
- 处置：注释掉全局该行（官方模板本就不强开配置缓存）。关掉后 `flutter build apk --debug` 与 `--release` 均正常。
- 若某台机器仍复现：检查其 `%GRADLE_USER_HOME%\gradle.properties` 是否有 `configuration-cache=true`，或用 `flutter ... ` 时临时 `--no-configuration-cache`（仅命令行优先级能压过 AGP 的强制）。

## 四、偏差说明（相对官方 3.47.6 模板）

1. **compileSdk = 37（官方默认 36）**：`permission_handler` 13.x 的 AAR 元数据要求宿主 compileSdk ≥ 37，降到 36 会构建失败。机器需装 `android-37` platform。此为有意偏离，保留。
2. **Flutter 3.47.5（你核对的官方为 3.47.6）**：已验证两版在 Android build-logic 上零差异，3.47.5 构建通过。`pubspec` 约束 `>=3.47.5 <3.48.0` 同时容纳 3.47.5 与 3.47.6。若你要严格对齐 3.47.6，执行 `cd $FLUTTER_ROOT && git checkout 3.47.6 && flutter doctor` 即可，本清单版本行同步改为 3.47.6。

## 五、环境依赖（不可随仓库分发，需各机器自备）

- JDK 17（Microsoft/Adoptium 均可，`java -version` 应为 17.x）。
- Android SDK：platform `android-37`、build-tools `36.0.0`、NDK `28.2.13676358`（`flutter doctor --android-licenses` 确认）。
- `GRADLE_USER_HOME` 指向何处由机器环境决定；其 `gradle.properties` 用第二节镜像覆盖。

## 六、验证（改动后必跑）

```bash
flutter --version                       # 期望 Flutter 3.47.5 / Dart 3.13.4
flutter clean
flutter pub get                         # 受 pubspec environment 约束校验
flutter analyze                         # 期望 No issues
flutter build apk --debug               # 期望 √ Built（不触发配置缓存崩溃）
flutter build apk --release             # 期望 √ Built（~20MB）
```

装机验机（release 同签名原地更新，保留曲库）：

```bash
adb -s <serial> install -r build/app/outputs/flutter-apk/app-release.apk
adb -s <serial> shell monkey -p com.fly1pu.audoramusic -c android.intent.category.LAUNCHER 1
```
