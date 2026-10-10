cmake_minimum_required(VERSION 3.21)
project(exosuit_scm_watch_native LANGUAGES C CXX)

if(NOT DEFINED HAXEON_NATIVE_OUTPUT_DIR OR HAXEON_NATIVE_OUTPUT_DIR STREQUAL "")
	set(HAXEON_NATIVE_OUTPUT_DIR "${CMAKE_BINARY_DIR}/native")
endif()
file(MAKE_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}")

set(NK_BUILD_SHARED ON CACHE BOOL "Build NativeKit shared libraries" FORCE)
set(NK_BUILD_GPU OFF CACHE BOOL "Disable NativeKit GPU for headless SCM watch tests" FORCE)
set(NK_BUILD_TESTS OFF CACHE BOOL "Disable NativeKit dependency tests" FORCE)
set(NK_BUILD_EXAMPLES OFF CACHE BOOL "Disable NativeKit dependency examples" FORCE)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
	set(NK_USE_SYSTEM_CURL ON CACHE BOOL "Use system curl for NativeKit HTTP support" FORCE)
endif()

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../../../haxeon/vendor/nativekit" nativekit)
set_target_properties(nativekit PROPERTIES
	LIBRARY_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}"
	RUNTIME_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}"
)

add_custom_target(scm_watch_native
	DEPENDS nativekit
	COMMAND "${CMAKE_COMMAND}" -E touch "${HAXEON_NATIVE_OUTPUT_DIR}/exosuit-scm-watch-test.hdll"
	BYPRODUCTS "${HAXEON_NATIVE_OUTPUT_DIR}/exosuit-scm-watch-test.hdll"
	COMMENT "Building NativeKit for SCM watch integration tests"
)
