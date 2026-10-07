cmake_minimum_required(VERSION 3.21)
project(terminalkit LANGUAGES C)

set(LIBTSM vendor/libtsm)
if(EMSCRIPTEN)
    set(TERMINALKIT_LIBRARY_TYPE STATIC)
else()
    set(TERMINALKIT_LIBRARY_TYPE SHARED)
endif()
add_library(terminalkit ${TERMINALKIT_LIBRARY_TYPE}
    src/terminalkit.c
    vendor/pragtical/terminal_emulator_libtsm.c
    ${LIBTSM}/src/tsm/tsm-render.c
    ${LIBTSM}/src/tsm/tsm-screen.c
    ${LIBTSM}/src/tsm/tsm-selection.c
    ${LIBTSM}/src/tsm/tsm-unicode.c
    ${LIBTSM}/src/tsm/tsm-vte-charsets.c
    ${LIBTSM}/src/tsm/tsm-vte.c
    ${LIBTSM}/src/shared/shl-htable.c
    ${LIBTSM}/external/wcwidth/wcwidth.c)
target_compile_features(terminalkit PRIVATE c_std_11)
target_compile_definitions(terminalkit PRIVATE TERMINALKIT_BUILDING=1 TSM_STATIC=1)
target_include_directories(terminalkit PUBLIC include PRIVATE
    vendor/pragtical ${LIBTSM}/src/tsm ${LIBTSM}/src/shared
    ${LIBTSM}/external/wcwidth ${LIBTSM}/external)
set_target_properties(terminalkit PROPERTIES C_VISIBILITY_PRESET hidden)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    include(CTest)
    if(BUILD_TESTING)
        add_executable(terminalkit_contract tests/contract.c)
        target_compile_features(terminalkit_contract PRIVATE c_std_11)
        target_link_libraries(terminalkit_contract PRIVATE terminalkit)
        add_test(NAME terminal_contract COMMAND terminalkit_contract)
        if(UNIX)
            add_executable(terminalkit_pty_bridge tests/pty_bridge.c)
            target_compile_features(terminalkit_pty_bridge PRIVATE c_std_11)
            target_link_libraries(terminalkit_pty_bridge PRIVATE terminalkit)
            if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
                target_link_libraries(terminalkit_pty_bridge PRIVATE util)
            endif()
            add_test(NAME terminal_pty_bridge COMMAND terminalkit_pty_bridge)
        endif()
    endif()
endif()
