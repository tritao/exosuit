cmake_minimum_required(VERSION 3.24)
project(exosuit_android LANGUAGES C CXX ASM)

# One configure per ABI builds every native library the Haxe module loads, straight from haxeon/ and native-packages/:
#   libhaxeon (HashLink runtime + JIT + our JNI), libnativekit, libnativekit_gpu, libnativekit_ui (with TLS),
#   libnoisekit, libtextmate_regex, libterminalkit
# Results are collected in ${CMAKE_BINARY_DIR}/libs. Needs ANDROID_PLATFORM android-28 or newer.
get_filename_component(REPO_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(HAXEON_ROOT "${REPO_ROOT}/haxeon")
set(LIBS_DIR "${CMAKE_BINARY_DIR}/libs")

# haxeon's Android host project builds the runtime; these options add NativeKit, UIKit and TLS to it.
set(HAXEON_ANDROID_NATIVEKIT ON CACHE BOOL "" FORCE)
set(HAXEON_ANDROID_UIKIT ON CACHE BOOL "" FORCE)
add_subdirectory("${HAXEON_ROOT}/android/app/src/main/cpp" haxeon-android)
target_sources(haxeon PRIVATE "${CMAKE_CURRENT_LIST_DIR}/exosuit_jni.c")

# Exosuit's native packages.
add_subdirectory("${REPO_ROOT}/native-packages/noise" noisekit)
add_subdirectory("${REPO_ROOT}/native-packages/oniguruma" textmate_regex)
add_subdirectory("${REPO_ROOT}/native-packages/terminal" terminalkit)

foreach(target haxeon nativekit nativekit_gpu nativekit_ui noisekit textmate_regex terminalkit)
    set_target_properties(${target} PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${LIBS_DIR}")
endforeach()
