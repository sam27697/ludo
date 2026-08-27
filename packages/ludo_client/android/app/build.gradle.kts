import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing reads from android/key.properties, which is never
// committed (see the root .gitignore and android/.gitignore, both of which
// ignore it by name). When that file is absent -- a fork build, a local
// checkout with no upload keystore, a CI run with no signing secrets -- the
// release build type falls back to the debug signing config, and this file
// is loaded to make that fallback loud in the build log rather than silent.
// The keystore itself is a PKCS12 file (storeType "PKCS12"), generated with
// openssl, not keytool -genkeypair; do not assume JKS here.
val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties = Properties()
val hasKeyProperties = keyPropertiesFile.exists()
if (hasKeyProperties) {
    keyPropertiesFile.inputStream().use { keyProperties.load(it) }
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

    signingConfigs {
        if (hasKeyProperties) {
            create("release") {
                // storeFile in key.properties is resolved relative to
                // android/ (the same directory key.properties itself lives
                // in), not relative to android/app/. This is deliberate so
                // the path in key.properties.example reads the same way the
                // file is actually laid out on disk.
                storeFile = rootProject.file(
                    keyProperties.getProperty("storeFile")
                        ?: throw GradleException("key.properties exists but has no storeFile")
                )
                storePassword = keyProperties.getProperty("storePassword")
                    ?: throw GradleException("key.properties exists but has no storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                    ?: throw GradleException("key.properties exists but has no keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
                    ?: throw GradleException("key.properties exists but has no keyPassword")
                // The upload keystore is PKCS12, not JKS. Set this explicitly:
                // the default store type differs between JDK versions and a
                // silently-wrong default here is the kind of thing that only
                // shows up as a mysterious signing failure on someone else's
                // machine.
                storeType = "PKCS12"
            }
        }
    }

    buildTypes {
        release {
            if (hasKeyProperties) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                // No android/key.properties -- no upload keystore was
                // supplied. Signing with the debug key so the release build
                // type still compiles and can still be run and tested, but
                // this bundle must never be uploaded anywhere: Play rejects
                // debug-signed bundles, and a workflow that doesn't check
                // for this file existing would upload one anyway.
                logger.warn(
                    "no android/key.properties found; release build is signing with the DEBUG key, this bundle is not uploadable to Play"
                )
                signingConfig = signingConfigs.getByName("debug")
            }
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
