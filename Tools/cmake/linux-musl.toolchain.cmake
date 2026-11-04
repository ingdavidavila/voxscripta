# Cross-compiles C and C++ for aarch64-linux-musl, from a Mac.
#
# Uses the Swift toolchain's clang and the Static Linux SDK's musl sysroot,
# which is the same pair SwiftPM uses for `--swift-sdk aarch64-swift-linux-musl`.
# That matters more than convenience: the C libraries and the Swift that calls
# them have to agree about libc and about the C++ ABI, and the surest way to
# make them agree is to use one toolchain for both.
#
# The SDK ships libc++ and libc++abi, which is what makes this possible at all
# — llama.cpp and whisper.cpp are C++, and a musl sysroot without a C++ runtime
# would have been a dead end.
#
# Set SWIFT_LINUX_SYSROOT and SWIFT_CLANG_BIN to override the search.

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

if(NOT DEFINED VOXSCRIPTA_SYSROOT)
    set(VOXSCRIPTA_SYSROOT "$ENV{SWIFT_LINUX_SYSROOT}")
endif()
if(NOT VOXSCRIPTA_SYSROOT)
    file(GLOB _sdk_candidates
        "$ENV{HOME}/.swiftpm/swift-sdks/*.artifactbundle/*/swift-linux-musl/musl-*.sdk/aarch64")
    list(SORT _sdk_candidates)
    list(REVERSE _sdk_candidates)
    list(GET _sdk_candidates 0 VOXSCRIPTA_SYSROOT)
endif()
if(NOT EXISTS "${VOXSCRIPTA_SYSROOT}/usr/lib/libc.a")
    message(FATAL_ERROR
        "no musl sysroot at '${VOXSCRIPTA_SYSROOT}'. Install the Static Linux SDK, "
        "or set SWIFT_LINUX_SYSROOT.")
endif()

if(NOT DEFINED VOXSCRIPTA_CLANG_BIN)
    set(VOXSCRIPTA_CLANG_BIN "$ENV{SWIFT_CLANG_BIN}")
endif()
if(NOT VOXSCRIPTA_CLANG_BIN)
    set(VOXSCRIPTA_CLANG_BIN "$ENV{HOME}/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin")
endif()
if(NOT EXISTS "${VOXSCRIPTA_CLANG_BIN}/clang")
    message(FATAL_ERROR
        "no clang at '${VOXSCRIPTA_CLANG_BIN}'. Install a swift.org toolchain, "
        "or set SWIFT_CLANG_BIN.")
endif()

set(CMAKE_SYSROOT "${VOXSCRIPTA_SYSROOT}")
set(CMAKE_C_COMPILER   "${VOXSCRIPTA_CLANG_BIN}/clang")
set(CMAKE_CXX_COMPILER "${VOXSCRIPTA_CLANG_BIN}/clang++")
set(CMAKE_C_COMPILER_TARGET   aarch64-unknown-linux-musl)
set(CMAKE_CXX_COMPILER_TARGET aarch64-unknown-linux-musl)

# lld, because the host's ld is Apple's and cannot produce ELF.
set(CMAKE_LINKER "${VOXSCRIPTA_CLANG_BIN}/ld.lld")
set(CMAKE_AR     "${VOXSCRIPTA_CLANG_BIN}/llvm-ar"     CACHE FILEPATH "")
set(CMAKE_RANLIB "${VOXSCRIPTA_CLANG_BIN}/llvm-ranlib" CACHE FILEPATH "")
set(CMAKE_NM     "${VOXSCRIPTA_CLANG_BIN}/llvm-nm"     CACHE FILEPATH "")

# libc++ explicitly: clang would otherwise look for libstdc++, which this
# sysroot does not have.
#
# And compiler-rt, libunwind and the sysroot's own resource directory, because
# clang otherwise reaches for GCC's runtime — libgcc, crtbeginS.o — which an
# LLVM/musl sysroot does not contain. These only matter at link time, so a
# build that produces nothing but static archives appears to work without them
# and fails in whatever links the result.
set(_voxscripta_rt
    "-resource-dir=${VOXSCRIPTA_SYSROOT}/usr/lib/swift/clang -rtlib=compiler-rt -unwindlib=libunwind")
set(CMAKE_C_FLAGS_INIT   "${_voxscripta_rt}")
set(CMAKE_CXX_FLAGS_INIT "-stdlib=libc++ ${_voxscripta_rt}")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld -static ${_voxscripta_rt}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=lld ${_voxscripta_rt}")

# Look only in the sysroot for libraries and headers. Without this CMake finds
# the Mac's, and the first sign of it is a link error a long way from here.
# The sysroot, plus anything this build has already installed. whisper.cpp
# finds the ggml that llama.cpp installed through here; with the sysroot alone
# the search mode below hides it, and whisper's configure fails saying it
# cannot find ggmlConfig.cmake while the file is sitting right there.
set(CMAKE_FIND_ROOT_PATH "${VOXSCRIPTA_SYSROOT}")
if(DEFINED ENV{VOXSCRIPTA_EXTRA_FIND_ROOT})
    list(APPEND CMAKE_FIND_ROOT_PATH "$ENV{VOXSCRIPTA_EXTRA_FIND_ROOT}")
endif()
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM BEFORE)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# A static library build needs no link step to be validated, and letting CMake
# try one here only invites a missing-crt error that says nothing useful.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
