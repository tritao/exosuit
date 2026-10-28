cmake_minimum_required(VERSION 3.21)
project(exosuit_suit_native LANGUAGES C CXX)
# suit needs NativeKit for its event loop, the local control endpoint and the
# Windows tray icon. It makes no HTTP requests.
set(NK_BUILD_SHARED ON CACHE BOOL "" FORCE)
set(NK_BUILD_GPU OFF CACHE BOOL "" FORCE)
set(NK_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(NK_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../../haxeon/vendor/nativekit" nativekit)
set_target_properties(nativekit PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}" RUNTIME_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}")
add_custom_target(exosuit_suit_native DEPENDS nativekit
 COMMAND "${CMAKE_COMMAND}" -E touch "${HAXEON_NATIVE_OUTPUT_DIR}/exosuit-suit.hdll"
 BYPRODUCTS "${HAXEON_NATIVE_OUTPUT_DIR}/exosuit-suit.hdll")
