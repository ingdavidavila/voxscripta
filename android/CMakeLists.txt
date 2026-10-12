# The Android native build.
#
# Gradle's externalNativeBuild points here. It compiles the platform-neutral
# core from ../core and wraps it in the JNI shared library Kotlin loads. The
# core itself knows nothing about Android; everything platform-specific lives
# in jni/.
cmake_minimum_required(VERSION 3.22)
project(voxscripta_android CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# The core's own tests are a host-side concern; building them for a device
# would need a test runner on the device that this project does not have.
set(VOXSCRIPTA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../core ${CMAKE_CURRENT_BINARY_DIR}/core)

add_library(voxscripta_jni SHARED jni/voxscripta_jni.cpp)
target_link_libraries(voxscripta_jni PRIVATE voxscripta_core)
target_compile_options(voxscripta_jni PRIVATE -Wall -Wextra -Wpedantic -Werror)

# Exceptions are load-bearing here — the JNI layer translates them into Java
# throwables — so make it an error if a toolchain ever turns them off.
target_compile_options(voxscripta_jni PRIVATE -fexceptions)

if(ANDROID)
    find_library(ANDROID_LOG log)
    target_link_libraries(voxscripta_jni PRIVATE ${ANDROID_LOG})
endif()
