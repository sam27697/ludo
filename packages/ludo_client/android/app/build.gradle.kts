plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "app.fayad.ludo"
    // compileSdk, minSdk and targetSdk are pinned as integer literals rather
    // than left as flutter.compileSdkVersion / flutter.minSdkVersion /
    // flutter.targetSdkVersion. Those Flutter-provided values happen to be
    // 36 / 24 / 36 today (read from the installed SDK's
    // packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt) but
    // they are the Flutter template's defaults, not a promise, and a future
    // Flutter upgrade that changes its defaults must not silently change what
    // this app ships against. targetSdk 36 is also a hard Play requirement
    // for new apps from 2026-08-31.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Permanent on first Play upload; anchored to the fayad.app domain.
        // Do not change this after the first release is ever uploaded.
        applicationId = "app.fayad.ludo"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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
