# SPDX-License-Identifier: Apache-2.0
#
# The partial reconfiguration demo app, for the PR_DEMO hardware
# (PR_DEMO=1 hw/build_all.sh + hw/pr/build_personas.sh): swaps the LED
# blinker region between its two personas - blue and green - every few
# seconds, both persona bitstreams built into the app. Otherwise smp_app:
# runs from the HyperRAM under MCUboot, takes app and bitstream updates over
# mcumgr on the 12 MBaud FTDI UART.
#
#   west build -b niosv_g -d build_pr_blinker ../apps/pr_blinker -- -DAPP_VERSION=2.0.0
#     [-DPR_HW=<dir with output_files/, default ../hw>] [-DPR_PERIOD_MS=3000]
#   ../mcuboot/sign_app.sh build_pr_blinker 2.0.0

cmake_minimum_required(VERSION 3.20.0)

set(NIOSV_ZEPHYR ${CMAKE_CURRENT_LIST_DIR}/../..)
include(${CMAKE_CURRENT_LIST_DIR}/../niosv_cpu_clock.cmake)
list(APPEND EXTRA_DTC_OVERLAY_FILE
     ${NIOSV_ZEPHYR}/zephyr_overlays/niosv_g_hyperram_xip.overlay
     ${NIOSV_ZEPHYR}/zephyr_overlays/niosv_g_uart_fifo.overlay
     ${NIOSV_ZEPHYR}/zephyr_overlays/niosv_g_sdm_qspi.overlay
     ${NIOSV_ZEPHYR}/zephyr_overlays/niosv_g_flash_layout.overlay
     ${NIOSV_ZEPHYR}/zephyr_overlays/niosv_g_bootinfo.overlay
     ${NIOSV_ZEPHYR}/zephyr_overlays/niosv_g_pr.overlay
     ${CMAKE_CURRENT_LIST_DIR}/app.overlay)
list(APPEND EXTRA_CONF_FILE ${NIOSV_ZEPHYR}/mcuboot/app_ram_load.conf)

if(NOT DEFINED APP_VERSION)
  set(APP_VERSION 0.0.0)
endif()
if(NOT DEFINED PR_HW)
  set(PR_HW ${NIOSV_ZEPHYR}/hw)
endif()
if(NOT DEFINED PR_PERIOD_MS)
  set(PR_PERIOD_MS 3000)
endif()
# the personas of that hardware's base revision: they only load into it
get_filename_component(PR_HW ${PR_HW} ABSOLUTE BASE_DIR $ENV{PWD})
set(PERSONA_BLUE  ${PR_HW}/output_files/niosv_zephyr.blinker.rbf)
set(PERSONA_GREEN ${PR_HW}/output_files/impl_green.blinker.rbf)
foreach(f ${PERSONA_BLUE} ${PERSONA_GREEN})
  if(NOT EXISTS ${f})
    message(FATAL_ERROR "${f} missing: PR_DEMO=1 ./build_all.sh and pr/build_personas.sh in ${PR_HW}")
  endif()
endforeach()

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(pr_blinker)

target_sources(app PRIVATE src/main.c src/personas.S)
target_compile_definitions(app PRIVATE APP_VERSION="${APP_VERSION}" PR_PERIOD_MS=${PR_PERIOD_MS}
  PERSONA_BLUE="${PERSONA_BLUE}" PERSONA_GREEN="${PERSONA_GREEN}")
# rebuild when a persona changes
set_property(SOURCE src/personas.S APPEND PROPERTY OBJECT_DEPENDS ${PERSONA_BLUE} ${PERSONA_GREEN})
