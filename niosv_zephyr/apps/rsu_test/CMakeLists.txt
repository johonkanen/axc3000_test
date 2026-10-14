# SPDX-License-Identifier: Apache-2.0
# RSU status, and (on request over the JTAG console) a reconfiguration from
# a flash image. Runs from on-chip RAM (load with hw/download.sh).
cmake_minimum_required(VERSION 3.20.0)
set(NIOSV_ZEPHYR ${CMAKE_CURRENT_LIST_DIR}/../..)
include(${CMAKE_CURRENT_LIST_DIR}/../niosv_cpu_clock.cmake)
list(APPEND EXTRA_DTC_OVERLAY_FILE ${NIOSV_ZEPHYR}/zephyr_overlays/niosv_g_sdm_qspi.overlay)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(rsu_test)
target_sources(app PRIVATE src/main.c)
