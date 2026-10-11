group = "com.fly1pu.audora_files"
version = "0.1.0"

// AGP / Kotlin 版本与 host app 对齐（android/settings.gradle.kts: AGP 9.1.0 + Kotlin 2.4.0）。
// 这里显式声明 classpath 是 Flutter 插件的标准做法——permission_handler_android 14.x
// 就是这么写并在本项目里正常构建的；单独 `flutter build apk` 不带 host 时也能编译。
buildscript {
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.0.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.3.20")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "com.fly1pu.audora_files"

    // 37 而非 flutter 默认的 36：与 host app 同一条理由
    // （permission_handler 13.x 的 AAR 要求宿主 ≥37，见 docs/toolchain-lock.md）
    compileSdk = 37

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // DocumentFile：SAF 树的可读性/可写性探测与目录名列举都靠它
    implementation("androidx.documentfile:documentfile:1.0.1")
}
