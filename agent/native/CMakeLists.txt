cmake_minimum_required(VERSION 3.21)
project(exosuit_agent_native LANGUAGES C CXX)
set(NK_BUILD_SHARED ON CACHE BOOL "" FORCE)
set(NK_BUILD_GPU OFF CACHE BOOL "" FORCE)
set(NK_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(NK_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    # The workspace relay connector obtains one-use socket tickets over HTTPS.
    # NativeKit's Linux HTTP backend is opt-in because it depends on system curl.
    set(NK_USE_SYSTEM_CURL ON CACHE BOOL "" FORCE)
endif()
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../../haxeon/vendor/nativekit" nativekit)
set_target_properties(nativekit PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}" RUNTIME_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}")
add_custom_target(exosuit_agent_native DEPENDS nativekit
 COMMAND "${CMAKE_COMMAND}" -E touch "${HAXEON_NATIVE_OUTPUT_DIR}/exosuit-agent-native.hdll")
