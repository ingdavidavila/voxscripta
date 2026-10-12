plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.voxscripta"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.voxscripta"
        // API 28 covers roughly 95% of active devices and is the floor the
        // Swift Android SDK also targets, so the two stay comparable.
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"

        externalNativeBuild {
            cmake {
                // Exceptions are load-bearing: the JNI layer turns them into
                // Java throwables, and the NDK disables them by default for C++.
                cppFlags += listOf("-std=c++20", "-fexceptions")
                arguments += "-DANDROID_STL=c++_static"
            }
        }
        ndk {
            // 32-bit ABIs are built on purpose. They exercise int64 arithmetic
            // the 64-bit targets do not, and the core's overflow guard was
            // first checked there.
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64", "x86")
        }
    }

    externalNativeBuild {
        cmake {
            // The native build sits above this module so the same CMakeLists
            // serves Gradle and Tools/verify-android-core.sh.
            path = file("../CMakeLists.txt")
            version = "3.22.1+"
        }
    }

    // No network permission is declared anywhere in this app, which is how the
    // macOS build makes the same promise. Keep it that way.
    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin {
        compilerOptions {
            jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
        }
    }
}

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.1")
    implementation("androidx.core:core-ktx:1.17.0")
}
