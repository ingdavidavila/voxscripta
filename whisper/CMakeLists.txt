# The whisper.cpp transcription engine. Portable: the same wrapper serves Windows
# today and Android later, so it lives beside core/ rather than under windows/.
#
# whisper.cpp itself is not committed; Tools/fetch-whisper.sh pins and fetches it.
cmake_minimum_required(VERSION 3.22)

set(VOXSCRIPTA_WHISPER_DIR ${CMAKE_CURRENT_LIST_DIR}/../third_party/whisper.cpp)
if(NOT EXISTS ${VOXSCRIPTA_WHISPER_DIR}/CMakeLists.txt)
    message(FATAL_ERROR "whisper.cpp not found at ${VOXSCRIPTA_WHISPER_DIR}. Run Tools/fetch-whisper.sh")
endif()

# CPU only, no tools. GGML_NATIVE tunes for this machine's instruction set,
# which is right for a local build and wrong for a binary you hand to others.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(GGML_CUDA OFF CACHE BOOL "" FORCE)
set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
set(GGML_METAL OFF CACHE BOOL "" FORCE)
set(GGML_BLAS OFF CACHE BOOL "" FORCE)
set(GGML_CCACHE OFF CACHE BOOL "" FORCE)
add_subdirectory(${VOXSCRIPTA_WHISPER_DIR} whisper.cpp EXCLUDE_FROM_ALL)

add_library(voxscripta_whisper STATIC src/whisper_engine.cpp)
target_include_directories(voxscripta_whisper PUBLIC include)
target_link_libraries(voxscripta_whisper PUBLIC voxscripta_core PRIVATE whisper)
if(MSVC)
    target_compile_options(voxscripta_whisper PRIVATE /W4 /WX)
else()
    target_compile_options(voxscripta_whisper PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()
