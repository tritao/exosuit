cmake_minimum_required(VERSION 3.22)
project(exosuit_edit_window_probe LANGUAGES C CXX)

if(NOT DEFINED SKRIBIDI_SOURCE)
  message(FATAL_ERROR "Pass -DSKRIBIDI_SOURCE=/path/to/uikit/vendor/skribidi")
endif()

add_subdirectory("${SKRIBIDI_SOURCE}" skribidi)
add_executable(edit_window_probe edit_window_probe.c)
target_compile_features(edit_window_probe PRIVATE c_std_17)
target_compile_definitions(edit_window_probe PRIVATE SKRIBIDI_SOURCE="${SKRIBIDI_SOURCE}")
target_link_libraries(edit_window_probe PRIVATE skribidi m)
