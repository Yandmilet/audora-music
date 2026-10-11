plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── Release 签名凭据读取 ──────────────────────────────────────────────
// key.properties 与 audora_music.jks 均在 android/app/ 下，且已加入
// .gitignore（绝对禁止入库，内含明文口令与私钥）。
// 缺失即硬失败：静默回退 debug 签名的 release APK 与已装应用签名不一致、
// 装不上去，还会让人误以为签名链路正常——宁可构建报错指路，也不要一个
// 「看似成功」的假 release。
import java.io.FileInputStream
import java.util.Properties

val keystorePropertiesFile = rootProject.file("app/key.properties")
if (!keystorePropertiesFile.exists()) {
    throw GradleException(
        "缺少 android/app/key.properties（release 签名凭据：storeFile/storePassword/keyAlias/keyPassword）。" +
        "该文件被 .gitignore 排除，新 clone 需从备份恢复；密钥库丢失则用 keytool -genkeypair 重建" +
        "（重建后设备上已装的应用必须卸载重装，本地数据库会被清空）。"
    )
}
val keystoreProperties = Properties().apply {
    load(FileInputStream(keystorePropertiesFile))
}
val keystoreFile = file(
    keystoreProperties.getProperty("storeFile")
        ?: throw GradleException("key.properties 缺少 storeFile 字段")
)
if (!keystoreFile.exists()) {
    throw GradleException(
        "密钥库文件不存在: ${keystoreFile.absolutePath}（key.properties 的 storeFile 指向它）。" +
        "请从备份恢复该 .jks，或用 keytool -genkeypair 重建并同步更新 key.properties。"
    )
}

android {
    namespace = "com.fly1pu.audoramusic"
    // compileSdk 显式取 37：permission_handler 13.x 的 AAR 元数据要求宿主
    // 以 SDK 37 编译（AGP 9.1 的 max-recommended 仍是 36，但那只是警告）。
    // Flutter SDK 自身的 flutter.compileSdkVersion 跟随 Flutter 版本（当前 36）。
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.fly1pu.audoramusic"
        // minSdk 由 Flutter 工具强制为 24（Android 7.0+）：
        // 写 23 会在每次构建时被 flutter tool 自动改回 flutter.minSdkVersion
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        multiDexEnabled = true
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // ── 只出 arm64（唯一目标机型：魅族 21 / arm64-v8a）───────────────
        //
        // ## 为什么这里也要写一遍（和 build-arm64.bat 的关系）
        // 体积由**两处**决定，缺一处就会漏：
        //   1. **AOT 产物**（`libapp.so` / `libflutter.so`）：由构建时选的
        //      target platform 决定。脚本用 `--target-platform android-arm64`
        //      管住了命令行；但 `flutter run`、IDE 的 Run、以及不带参数的
        //      `flutter build apk` **不走脚本** —— 默认三 ABI 各编一份
        //      `libapp.so`，安装包直接翻倍。
        //      下面这段 `ndk.abiFilters` 就是给 Flutter 工具读的：
        //      未显式传 `--target-platform` 时，它按 abiFilters 决定编哪些 ABI。
        //   2. **插件 AAR 自带的 JNI 变体**（mpv / audio_service 等的 .so）：
        //      这部分 AGP 的 `ndk.abiFilters` 实测拦不住（产物字节级相同，
        //      2026-09-29 记录），只能靠下面的 `packaging.jniLibs.excludes` 剔除。
        //
        // 结论：两处都要留，不要「合并」成一处。
        // 副作用：x86_64 模拟器跑不起来（本项目只做真机，接受）。
        ndk {
            abiFilters.clear()
            abiFilters += "arm64-v8a"
        }

        // 只打包 arm64（2026-09-29 决策：仅真机目标魅族 21 / arm64）。
        // AOT 侧由 flutter build 的 --target-platform android-arm64 限制
        // （见 build-arm64.bat）；插件 AAR 自带的 v7a/x86_64 JNI 变体在
        // packaging 层强制剔除——AGP 9 的 ndk.abiFilters 实测不生效
        // （产物字节级相同），不要换回去。
        packaging {
            jniLibs {
                excludes += setOf("lib/armeabi-v7a/**", "lib/x86_64/**")
            }
        }
    }

    // Release 签名配置：key.properties + 密钥库在文件头已硬校验，缺失直接
    // 构建失败，不存在「回退 debug 签名」的假 release。
    signingConfigs {
        create("release") {
            storeFile = keystoreFile
            storePassword = keystoreProperties.getProperty("storePassword")
            keyAlias = keystoreProperties.getProperty("keyAlias")
            keyPassword = keystoreProperties.getProperty("keyPassword")
            enableV1Signing = true
            enableV2Signing = true
            enableV3Signing = true
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
