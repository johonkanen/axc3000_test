# SPDX-License-Identifier: Apache-2.0
#
# Build (from niosv_zephyr/zephyr, venv active):
#   west build -b niosv_g -d build_hr_zephyr ../apps/hyperram_zephyr
#   west build -b niosv_g -d build_hr_xip    ../apps/hyperram_zephyr -- -DHYPERRAM_XIP=1
# The first runs from on-chip RAM and uses the HyperRAM for data; the second
# (CONFIG_XIP) executes from the HyperRAM. The 25 MHz and HyperRAM overlays
# and the axc3000 module are added here.

cmake_minimum_required(VERSION 3.20.0)

set(NIOSV_ZEPHYR ${CMAKE_CURRENT_LIST_DIR}/../..)
list(APPEND EXTRA_DTC_OVERLAY_FILE ${NIOSV_ZEPHYR}/zephyr_overlays/niosv_g_25mhz.overlay)
if(HYPERRAM_XIP)
  list(APPEND EXTRA_DTC_OVERLAY_FILE ${NIOSV_ZEPHYR}/zephyr_overlays/niosv_g_hyperram_xip.overlay)
  list(APPEND EXTRA_CONF_FILE ${CMAKE_CURRENT_LIST_DIR}/xip.conf)
else()
  list(APPEND EXTRA_DTC_OVERLAY_FILE ${NIOSV_ZEPHYR}/zephyr_overlays/niosv_g_hyperram.overlay)
endif()
list(APPEND EXTRA_ZEPHYR_MODULES ${NIOSV_ZEPHYR}/zephyr_module)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(hyperram_zephyr)

target_sources(app PRIVATE src/main.c)
