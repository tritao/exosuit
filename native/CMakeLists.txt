cmake_minimum_required(VERSION 3.21)
project(pragtical_hx LANGUAGES C)
add_library(pragtical_hx SHARED headless/platform.c ffi/pragtical_hx.c)
target_include_directories(pragtical_hx PRIVATE ../include)
target_compile_features(pragtical_hx PRIVATE c_std_11)
set_target_properties(pragtical_hx PROPERTIES
    WINDOWS_EXPORT_ALL_SYMBOLS ON
    LIBRARY_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}"
    RUNTIME_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}")
