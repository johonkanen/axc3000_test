# SPDX-License-Identifier: Apache-2.0
#
# The QSPI configuration flash through the SDM mailbox: ID, reads, and an
# erase / write / verify / erase-back round trip in the last 64 KB block -
# only if that block reads fully erased. Results on the JTAG console.
#   west build -b niosv_g -d build_flash_test ../apps/flash_test

cmake_minimum_required(VERSION 3.20.0)

set(NIOSV_ZEPHYR ${CMAKE_CURRENT_LIST_DIR}/../..)
include(${CMAKE_CURRENT_LIST_DIR}/../niosv_cpu_clock.cmake)
list(APPEND EXTRA_DTC_OVERLAY_FILE ${NIOSV_ZEPHYR}/zephyr_overlays/niosv_g_sdm_qspi.overlay)
list(APPEND EXTRA_ZEPHYR_MODULES ${NIOSV_ZEPHYR}/zephyr_module)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(flash_test)

target_sources(app PRIVATE src/main.c)
