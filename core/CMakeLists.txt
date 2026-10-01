# libvoxscripta — the platform-neutral core.
#
# Built two ways on purpose. CMake drives Android and the React Native build;
# SwiftPM compiles the same sources directly (see Package.swift) so the existing
# macOS app keeps working against the core throughout the migration. Neither
# build may add a dependency the other cannot satisfy, which is why this library
# has none: no network, no platform SDK, nothing but the standard library.
cmake_minimum_required(VERSION 3.22)
project(voxscripta_core CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

file(GLOB_RECURSE VOXSCRIPTA_CORE_SOURCES CONFIGURE_DEPENDS src/*.cpp)

add_library(voxscripta_core STATIC ${VOXSCRIPTA_CORE_SOURCES})
target_include_directories(voxscripta_core PUBLIC include)
target_compile_options(voxscripta_core PRIVATE -Wall -Wextra -Wpedantic -Werror)

option(VOXSCRIPTA_BUILD_TESTS "Build the core's test binary" ON)
if(VOXSCRIPTA_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
