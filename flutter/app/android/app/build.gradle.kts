plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.voxscripta.voxscripta"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.voxscripta.voxscripta"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // The engine is built for arm64-v8a and x86_64 only. Flutter would also ship
    // its 32-bit ARM libraries, and a bundle carrying those installs on an old phone
    // and then cannot find the engine, so that ABI is left out and the Play Store
    // does not offer the app to such devices.
    packaging {
        jniLibs {
            excludes += "**/armeabi-v7a/**"
        }
    }

    assetPacks += listOf(":speech_model")

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

// The speech model ships as a Play Asset Delivery pack (see :speech_model), which
// only an app bundle carries. Without this a bundle would build happily with an
// empty pack and every install would then say it has no model, so a bundle is
// refused unless the pack holds a real ggml model. APK builds, the everyday
// development path, ignore the pack and are not held up by it.
val verifySpeechModel = tasks.register("verifySpeechModel") {
    val models = rootProject.file("speech_model/src/main/assets/models")
    doLast {
        val found = models.listFiles { f -> f.name.startsWith("ggml-") && f.name.endsWith(".bin") }
            .orEmpty()
        if (found.isEmpty()) {
            throw GradleException(
                "The speech model pack is empty. Run Tools/stage-android-model.sh " +
                    "(small by default) before building an app bundle.",
            )
        }
        for (file in found) {
            val magic = file.inputStream().use { input -> ByteArray(4).also { input.read(it) } }
            // ggml's magic 0x67676d6c, written little-endian: 6c 6d 67 67 on disk.
            if (!magic.contentEquals(byteArrayOf(0x6c, 0x6d, 0x67, 0x67))) {
                throw GradleException("${file.name} in the speech model pack is not a ggml model.")
            }
        }
    }
}

tasks.whenTaskAdded {
    if (name in setOf("bundleRelease", "bundleDebug", "bundleProfile")) {
        dependsOn(verifySpeechModel)
    }
}
