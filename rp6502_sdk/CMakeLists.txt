#
# Copyright (c) 2023 Rumbledethumps
#
# SPDX-License-Identifier: BSD-3-Clause
# SPDX-License-Identifier: Unlicense
#

if(DEFINED ENV{CC65_HOME})
    set(CC65_INCLUDE "$ENV{CC65_HOME}/include")
else()
    set(CC65_INCLUDE "/usr/share/cc65/include")
endif()

add_library(rp6502 STATIC EXCLUDE_FROM_ALL)
target_include_directories(rp6502 PUBLIC
    ${CMAKE_CURRENT_LIST_DIR}/include
    ${CC65_INCLUDE}
)
target_sources(rp6502 PUBLIC
    src/clock.c
    src/close.c
    src/codepage.c
    src/crt0.s
    src/initenv.s
    src/lrand.c
    src/lseek.c
    src/mainargs.s
    src/open.c
    src/oserrlist.s
    src/oserror.s
    src/phi2.c
    src/randomize.c
    src/read_xram.c
    src/read_xstack.c
    src/read.c
    src/ria.s
    src/write_xram.c
    src/write_xstack.c
    src/write.c
    src/xreg.s
)

# Package an executable target as an RP6502 ROM.
#
# RP6502 Executables
# ^^^^^^^^^^^^^^^^^^
#
#  rp6502_executable(<name> [start_addr] [reset_addr])
#
# Packages an executable target called ``<name>`` in RP6502 ROM format.
# ``<start_addr>`` defaults to 0x200.
# ``<reset_addr>`` defaults to ``<start_addr>``.
#
function(rp6502_executable name)
    # Parse optional args
    set(start_addr "0x200")
    set(reset_addr ${start_addr})
    set(extra_args ${ARGN})
    list(LENGTH extra_args extra_count)
    if (${extra_count} GREATER 0)
        list(GET extra_args 0 optional_arg)
        set(start_addr ${optional_arg})
        set(reset_addr ${start_addr})
    endif ()
    if (${extra_count} GREATER 1)
        list(GET extra_args 1 optional_arg)
        set(reset_addr ${optional_arg})
    endif ()
    # Remove old ROM
    add_custom_command(TARGET ${name} PRE_BUILD
        COMMAND ${CMAKE_COMMAND} -E remove
        "${CMAKE_CURRENT_BINARY_DIR}/${name}.rp6502"
    )
    # Create new ROM
    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    add_custom_command(TARGET ${name} POST_BUILD
        COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/rp6502-sdk/rp6502.py"
            -a "${start_addr}" -r "${reset_addr}"
            -o "${CMAKE_CURRENT_BINARY_DIR}/${name}.rp6502"
            create "${CMAKE_CURRENT_BINARY_DIR}/${name}"
        DEPENDS ${name})
endfunction()
