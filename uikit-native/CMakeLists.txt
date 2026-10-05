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
set(NKUI_NATIVEKIT_DIR "${EXOSUIT_HAXEON_ROOT}/vendor/nativekit" CACHE PATH "NativeKit source for the UI package" FORCE)
add_subdirectory("${EXOSUIT_HAXEON_ROOT}/packages/ui" uikit)

set(EXOSUIT_UI_RUNTIME_TARGETS nativekit nativekit_gpu nativekit_ui)
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
