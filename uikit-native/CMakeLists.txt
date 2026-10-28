cmake_minimum_required(VERSION 3.21)

project(exosuit_ui_native VERSION 0.1.0 LANGUAGES C CXX)

if(NOT DEFINED HAXEON_NATIVE_OUTPUT_DIR OR HAXEON_NATIVE_OUTPUT_DIR STREQUAL "")
    set(HAXEON_NATIVE_OUTPUT_DIR "${CMAKE_BINARY_DIR}/native")
endif()
file(MAKE_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}")

# This package builds the NativeKit and UIKit runtime for DesktopUiHost.
# The plugin callback bridge is provided by the separate plugin-host package.
set(NK_BUILD_SHARED ON CACHE BOOL "Build shared NativeKit libraries" FORCE)
set(NK_BUILD_GPU ON CACHE BOOL "Build NativeKit GPU" FORCE)
set(NK_BUILD_TESTS OFF CACHE BOOL "Disable dependency tests in the exosuit build" FORCE)
set(NK_BUILD_EXAMPLES OFF CACHE BOOL "Disable dependency examples in the exosuit build" FORCE)
set(NKUI_ENABLE_SECTION_GC ON CACHE BOOL "Keep UIKit section garbage collection enabled" FORCE)

get_filename_component(EXOSUIT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
set(EXOSUIT_HAXEON_ROOT "${EXOSUIT_ROOT}/haxeon" CACHE PATH "Haxeon source directory")
add_subdirectory("${EXOSUIT_HAXEON_ROOT}/vendor/nativekit" nativekit)
if(WIN32)
    enable_language(RC)
    configure_file(windows/app-icon.rc.in "${CMAKE_CURRENT_BINARY_DIR}/app-icon.rc" @ONLY)
    target_sources(nativekit PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/app-icon.rc")
    target_compile_definitions(nativekit PRIVATE NK_APPLICATION_ICON_RESOURCE_ID=101)
endif()
set(NKUI_NATIVEKIT_DIR "${EXOSUIT_HAXEON_ROOT}/vendor/nativekit" CACHE PATH "NativeKit source for the UI package" FORCE)
add_subdirectory("${EXOSUIT_HAXEON_ROOT}/packages/ui" uikit)

add_library(exosuit_clipboard SHARED clipboard.cpp thumbnail.cpp)
target_include_directories(exosuit_clipboard PRIVATE "${EXOSUIT_HAXEON_ROOT}/packages/ui/vendor/nanovg/src")
if(WIN32)
    target_link_libraries(exosuit_clipboard PRIVATE windowscodecs ole32 gdi32 user32)
endif()
add_library(exosuit_artifact_preview SHARED artifact_preview.cpp)
add_executable(exosuit_artifact_preview_stub_test EXCLUDE_FROM_ALL artifact_preview.cpp tests/artifact_preview_stub.cpp)
if(WIN32 AND NK_ENABLE_WEBVIEW2)
    include(FetchContent)
    FetchContent_GetProperties(nativekit_webview2)
    target_compile_definitions(exosuit_artifact_preview PRIVATE EXOSUIT_WEBVIEW2=1)
    target_compile_features(exosuit_artifact_preview PRIVATE cxx_std_17)
    target_include_directories(exosuit_artifact_preview PRIVATE "${EXOSUIT_HAXEON_ROOT}/vendor/nativekit/include" "${nativekit_webview2_SOURCE_DIR}/build/native/include")
    target_link_libraries(exosuit_artifact_preview PRIVATE nativekit ole32 user32)
    add_library(exosuit_artifact_preview_test SHARED EXCLUDE_FROM_ALL artifact_preview.cpp)
    target_compile_features(exosuit_artifact_preview_test PRIVATE cxx_std_17)
    target_compile_definitions(exosuit_artifact_preview_test PRIVATE EXOSUIT_WEBVIEW2=1 EXOSUIT_PREVIEW_TESTING=1)
    target_include_directories(exosuit_artifact_preview_test PRIVATE "${EXOSUIT_HAXEON_ROOT}/vendor/nativekit/include" "${nativekit_webview2_SOURCE_DIR}/build/native/include")
    target_link_libraries(exosuit_artifact_preview_test PRIVATE nativekit ole32 user32)
    set_target_properties(exosuit_artifact_preview_test PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}" ARCHIVE_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}")
    add_executable(exosuit_artifact_preview_smoke EXCLUDE_FROM_ALL tests/artifact_preview_smoke.cpp)
    target_include_directories(exosuit_artifact_preview_smoke PRIVATE "${EXOSUIT_HAXEON_ROOT}/vendor/nativekit/include")
    target_link_libraries(exosuit_artifact_preview_smoke PRIVATE exosuit_artifact_preview_test nativekit ws2_32 iphlpapi)
endif()
set(EXOSUIT_UI_RUNTIME_TARGETS nativekit nativekit_gpu nativekit_ui exosuit_clipboard exosuit_artifact_preview)
foreach(target_name IN LISTS EXOSUIT_UI_RUNTIME_TARGETS)
    if(NOT TARGET "${target_name}")
        message(FATAL_ERROR "exosuit-ui-native did not define ${target_name}")
    endif()
    set_target_properties("${target_name}" PROPERTIES
        LIBRARY_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}"
        RUNTIME_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}"
        ARCHIVE_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}")
endforeach()

# Haxeon's coarse CMake artifact is a build stamp, not a loadable library;
# the runtime libraries loaded by generated FFI calls are the libnativekit*
# files placed above.
add_custom_target(exosuit_ui_native
    DEPENDS ${EXOSUIT_UI_RUNTIME_TARGETS}
    COMMAND "${CMAKE_COMMAND}" -E touch "${HAXEON_NATIVE_OUTPUT_DIR}/exosuit-ui-native.hdll"
    BYPRODUCTS "${HAXEON_NATIVE_OUTPUT_DIR}/exosuit-ui-native.hdll"
    COMMENT "Building NativeKit and UIKit native dependencies for exosuit")


if(WIN32)
    add_executable(exosuit_clipboard_smoke EXCLUDE_FROM_ALL clipboard_smoke.cpp thumbnail.cpp)
    target_include_directories(exosuit_clipboard_smoke PRIVATE "${EXOSUIT_HAXEON_ROOT}/packages/ui/vendor/nanovg/src")
    target_link_libraries(exosuit_clipboard_smoke PRIVATE windowscodecs ole32 gdi32 user32)
endif()

if(WIN32)
    add_executable(exosuit_clipboard_isolation_smoke EXCLUDE_FROM_ALL clipboard_isolation_smoke.cpp thumbnail.cpp)
    target_include_directories(exosuit_clipboard_isolation_smoke PRIVATE "${EXOSUIT_HAXEON_ROOT}/packages/ui/vendor/nanovg/src")
    target_link_libraries(exosuit_clipboard_isolation_smoke PRIVATE windowscodecs ole32 gdi32 user32)
endif()
