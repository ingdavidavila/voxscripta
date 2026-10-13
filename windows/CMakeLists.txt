# Windows platform layer: everything that needs the Windows SDK.
#
# Kept out of core/ on purpose. The core has no platform dependency so that it
# cross-compiles to Android unchanged; this directory is where Media Foundation
# (and later the whisper.cpp engine and the UI) attach to it.
#
#   cmake -S windows -B build/windows -G Ninja
#   cmake --build build/windows
#   ./build/windows/voxscripta_windows_tests.exe
cmake_minimum_required(VERSION 3.22)
project(voxscripta_windows CXX)

if(NOT WIN32)
    message(FATAL_ERROR "windows/ builds only on Windows")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# The core, with its own tests off; they are run from the core build.
set(VOXSCRIPTA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../core core)

add_library(voxscripta_windows STATIC src/mf_decoder.cpp)
target_include_directories(voxscripta_windows PUBLIC include)
target_link_libraries(voxscripta_windows PUBLIC voxscripta_core
                      mfplat mfreadwrite mfuuid ole32)
target_compile_definitions(voxscripta_windows PUBLIC UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
if(MSVC)
    target_compile_options(voxscripta_windows PRIVATE /W4 /WX)
else()
    target_compile_options(voxscripta_windows PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()

enable_testing()
file(GLOB VOXSCRIPTA_WINDOWS_TEST_SOURCES CONFIGURE_DEPENDS tests/*.cpp)
add_executable(voxscripta_windows_tests ${VOXSCRIPTA_WINDOWS_TEST_SOURCES}
               ${CMAKE_CURRENT_SOURCE_DIR}/../core/tests/synthesis.cpp)
target_include_directories(voxscripta_windows_tests PRIVATE
                           ${CMAKE_CURRENT_SOURCE_DIR}/../core/tests)
target_link_libraries(voxscripta_windows_tests PRIVATE voxscripta_windows mfplat mfreadwrite mfuuid ole32)
add_test(NAME windows COMMAND voxscripta_windows_tests)
