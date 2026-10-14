# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.20.0)

# the CPU clock (-DNIOSV_CPU_HZ=..., default 120 MHz), matching the hardware
include(${CMAKE_CURRENT_LIST_DIR}/../niosv_cpu_clock.cmake)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(hyperram_status)

target_sources(app PRIVATE src/main.c)
