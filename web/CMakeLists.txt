cmake_minimum_required(VERSION 3.21)

# Emscripten host for the browser build of exosuit. The editor
# itself is a separate Haxeon wasm32 guest (see build.sh); this executable
# supplies the browser runtime and the native C ABIs the guest imports, all in
# one linear memory that the guest shares through the Haxeon memory contract.
project(exosuit_web_host VERSION 0.1.0 LANGUAGES C CXX)

if(NOT EMSCRIPTEN)
    message(FATAL_ERROR "exosuit/web is the Emscripten host; configure it with emcmake")
endif()

set(EXOSUIT_WEB_GUEST_WASM "" CACHE FILEPATH "Haxeon guest module the host exports functions to")
set(EXOSUIT_WEB_EXPORTS_FILE "" CACHE FILEPATH
    "Emscripten response file listing the C functions the guest imports from linked libraries")
if(NOT EXISTS "${EXOSUIT_WEB_GUEST_WASM}" OR NOT EXISTS "${EXOSUIT_WEB_EXPORTS_FILE}")
    message(FATAL_ERROR "Build the browser editor with exosuit/web/build.sh, which compiles the guest first")
endif()

set(EXOSUIT_HAXEON_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../haxeon" CACHE PATH "Haxeon source directory")

get_filename_component(MATERIA_SOURCE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

set(NK_BUILD_SHARED OFF CACHE BOOL "Emscripten links one static host" FORCE)
set(NK_BUILD_GPU ON CACHE BOOL "The editor viewport renders through NativeKit GPU" FORCE)
set(NK_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(NK_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(NK_SOKOL_BACKEND gles3 CACHE STRING "WebGL2" FORCE)
set(NK_WEB_EXPORTED_RUNTIME_METHODS "ccall,addFunction,removeFunction" CACHE STRING "Guest callback runtime" FORCE)
add_subdirectory("${EXOSUIT_HAXEON_ROOT}/vendor/nativekit" nativekit)
set(NKUI_NATIVEKIT_DIR "${EXOSUIT_HAXEON_ROOT}/vendor/nativekit" CACHE PATH "NativeKit source for the UI package" FORCE)
add_subdirectory("${EXOSUIT_HAXEON_ROOT}/packages/ui" uikit)

set(NKSCENE_NATIVEKIT_DIR "${EXOSUIT_HAXEON_ROOT}/vendor/nativekit")
set(NK_LIBRARY_TYPE STATIC)
add_subdirectory("${MATERIA_SOURCE_ROOT}/scenekit/scene" scene)
add_subdirectory("${MATERIA_SOURCE_ROOT}/scenekit/scene_render" scene_render)
add_subdirectory("${MATERIA_SOURCE_ROOT}/exosuit/native-packages/noise" noisekit)

# The host heap ends where the guest's managed heap begins; the guest owns the
# rest of the fixed-size memory. Values are byte offsets, multiples of 64 KiB.
set(EXOSUIT_WEB_GUEST_MEMORY_LIMIT 805306368 CACHE STRING "Total linear memory in bytes")
set(NKUI_HAXEON_MEMORY_CONTRACT_VERSION 1)
set(NKUI_HAXEON_WASM_PAGE_SIZE 65536)
set(NKUI_HAXEON_HOST_HEAP_BASE 0)
set(NKUI_HAXEON_HOST_HEAP_LIMIT ${NK_WASM_HOST_HEAP_LIMIT})
set(NKUI_HAXEON_GUEST_MEMORY_BASE ${NKUI_HAXEON_HOST_HEAP_LIMIT})
set(NKUI_HAXEON_GUEST_MEMORY_LIMIT ${EXOSUIT_WEB_GUEST_MEMORY_LIMIT})
set(NKUI_HAXEON_MEMORY_LIMIT ${EXOSUIT_WEB_GUEST_MEMORY_LIMIT})
configure_file("${EXOSUIT_HAXEON_ROOT}/packages/ui/cmake/wasm_memory_contract.h.in"
    "${CMAKE_CURRENT_BINARY_DIR}/nativekit_haxeon_memory_contract.h" @ONLY)

add_executable(exosuit_web
    host.cpp
    "${EXOSUIT_HAXEON_ROOT}/packages/ui/src/platform/wasm/haxeon_memory_contract.cpp")
target_include_directories(exosuit_web PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
target_link_libraries(exosuit_web PRIVATE
    NativeKit::nativekit NativeKit::gpu NativeKit::ui NativeKit::scene NativeKit::scene_render
    NativeKit::wasm_host_allocator noisekit)
target_link_options(exosuit_web PRIVATE
    "-sINITIAL_MEMORY=${EXOSUIT_WEB_GUEST_MEMORY_LIMIT}"
    "-sALLOW_MEMORY_GROWTH=0"
    "-sEXPORTED_FUNCTIONS=@${EXOSUIT_WEB_EXPORTS_FILE}"
    # The page adds the guest's native callbacks to the function table.
    "-sEXPORTED_RUNTIME_METHODS=${NK_WEB_EXPORTED_RUNTIME_METHODS}"
    "-sALLOW_TABLE_GROWTH=1"
    "-sNO_EXIT_RUNTIME=1")
set_property(TARGET exosuit_web APPEND PROPERTY LINK_DEPENDS "${EXOSUIT_WEB_EXPORTS_FILE}")
