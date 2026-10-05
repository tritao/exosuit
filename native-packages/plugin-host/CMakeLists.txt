cmake_minimum_required(VERSION 3.21)
project(exosuit_plugin_host LANGUAGES C)
add_library(exosuit_plugin_host SHARED src/exosuit_plugin_host.c)
target_compile_features(exosuit_plugin_host PRIVATE c_std_11)
target_include_directories(exosuit_plugin_host PUBLIC include)
set_target_properties(exosuit_plugin_host PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
if(DEFINED HAXEON_NATIVE_OUTPUT_DIR)
  set_target_properties(exosuit_plugin_host PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}"
    RUNTIME_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}")
endif()
