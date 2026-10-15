# SPDX-License-Identifier: Apache-2.0
#
# The updatable application: runs from the HyperRAM under MCUboot (RAM-load),
# and takes new images over the 12 MBaud FTDI UART (mcumgr / SMP server):
# upload into a flash slot, then reset - MCUboot boots the newer version.
#
#   west build -b niosv_g -d build_smp_app ../apps/smp_app -- -DAPP_VERSION=1.0.0
#   ../mcuboot/sign_app.sh build_smp_app 1.0.0
#   then: smpmgr --port /dev/ttyUSB0 --baudrate 12000000 ... upgrade zephyr.signed.bin

cmake_minimum_required(VERSION 3.20.0)

set(NIOSV_ZEPHYR ${CMAKE_CURRENT_LIST_DIR}/../..)
include(${CMAKE_CURRENT_LIST_DIR}/../niosv_cpu_clock.cmake)
# -DSMALL_OCRAM=1: the small on-chip RAM hardware variant (68 KB ram0, an 8
# KB data cache; hw_a065dc) - all of the application's memory in the HyperRAM
if(SMALL_OCRAM)
  set(XIP_OVERLAY niosv_g_hyperram_xip_small)
  set(BOOTINFO_OVERLAY niosv_g_bootinfo_small)
else()
  set(XIP_OVERLAY niosv_g_hyperram_xip)
  set(BOOTINFO_OVERLAY niosv_g_bootinfo)
endif()
list(APPEND EXTRA_DTC_OVERLAY_FILE
     ${NIOSV_ZEPHYR}/zephyr_overlays/${XIP_OVERLAY}.overlay
     ${NIOSV_ZEPHYR}/zephyr_overlays/niosv_g_uart_fifo.overlay
     ${NIOSV_ZEPHYR}/zephyr_overlays/niosv_g_sdm_qspi.overlay
     ${NIOSV_ZEPHYR}/zephyr_overlays/niosv_g_flash_layout.overlay
     ${NIOSV_ZEPHYR}/zephyr_overlays/${BOOTINFO_OVERLAY}.overlay
     ${CMAKE_CURRENT_LIST_DIR}/app.overlay)
list(APPEND EXTRA_CONF_FILE ${NIOSV_ZEPHYR}/mcuboot/app_ram_load.conf)
if(SMALL_OCRAM)
  list(APPEND EXTRA_CONF_FILE ${NIOSV_ZEPHYR}/zephyr_overlays/niosv_g_small_ocram.conf)
endif()

if(NOT DEFINED APP_VERSION)
  set(APP_VERSION 0.0.0)
endif()

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(smp_app)

target_sources(app PRIVATE src/main.c)
target_compile_definitions(app PRIVATE APP_VERSION="${APP_VERSION}")
