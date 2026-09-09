plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.complience_app"
    // Paddle OCR's transitive deps require compileSdk >= 34;
    // flutter_secure_storage v11 requires >= 37.
    compileSdk = 37
    // Highest NDK required by plugins (camera etc.); backward compatible.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.complience_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // flutter_paddle_ocr_v5 requires minSdk 24 (ONNX Runtime).
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // NOTE: do NOT add ndk.abiFilters here — the Flutter Gradle plugin
        // manages ABIs itself and fails the build when splits are enabled
        // ("conflicting configuration"). For small install size use:
        //   flutter build apk --release --split-per-abi   (one APK per ABI)
        //   flutter build appbundle --release             (Play Store)
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
