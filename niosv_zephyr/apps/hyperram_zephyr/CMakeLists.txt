# SPDX-License-Identifier: Apache-2.0
#
# Build (from niosv_zephyr/zephyr, venv active):
#   west build -b niosv_g -d build_hr_zephyr ../apps/hyperram_zephyr
# The 25 MHz and HyperRAM overlays and the axc3000 module are added here.

cmake_minimum_required(VERSION 3.20.0)

set(NIOSV_ZEPHYR ${CMAKE_CURRENT_LIST_DIR}/../..)
list(APPEND EXTRA_DTC_OVERLAY_FILE
     ${NIOSV_ZEPHYR}/zephyr_overlays/niosv_g_25mhz.overlay
     ${NIOSV_ZEPHYR}/zephyr_overlays/niosv_g_hyperram.overlay)
list(APPEND EXTRA_ZEPHYR_MODULES ${NIOSV_ZEPHYR}/zephyr_module)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(hyperram_zephyr)

target_sources(app PRIVATE src/main.c)
