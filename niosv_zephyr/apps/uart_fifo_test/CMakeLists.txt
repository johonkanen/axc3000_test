# SPDX-License-Identifier: Apache-2.0
#
# Interrupt-driven echo on the FTDI serial port through hw/uart/'s UART
# (zephyr_overlays/niosv_g_uart_fifo.overlay); counters on the JTAG console.
# Build (from niosv_zephyr/zephyr, venv active), the clock matching the
# hardware's CPU_CLOCK_MHZ:
#   west build -b niosv_g -d build_uart_test ../apps/uart_fifo_test -- -DNIOSV_CPU_HZ=100000000
# Then on the host: python3 ../apps/uart_fifo_test/host_echo_test.py

cmake_minimum_required(VERSION 3.20.0)

set(NIOSV_ZEPHYR ${CMAKE_CURRENT_LIST_DIR}/../..)
include(${CMAKE_CURRENT_LIST_DIR}/../niosv_cpu_clock.cmake)
list(APPEND EXTRA_DTC_OVERLAY_FILE ${NIOSV_ZEPHYR}/zephyr_overlays/niosv_g_uart_fifo.overlay)
list(APPEND EXTRA_ZEPHYR_MODULES ${NIOSV_ZEPHYR}/zephyr_module)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(uart_fifo_test)

target_sources(app PRIVATE src/main.c)
