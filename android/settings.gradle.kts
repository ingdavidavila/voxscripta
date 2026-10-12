// Opened directly in Android Studio: File > Open > this `android` directory.
//
// The native core lives one level up in ../core and is compiled by
// android/CMakeLists.txt, so this Gradle project is only the Android shell.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "VoxScripta"
include(":app")
