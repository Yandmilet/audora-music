plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.audora.audora2"
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
        applicationId = "com.audora.audora2"
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

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
