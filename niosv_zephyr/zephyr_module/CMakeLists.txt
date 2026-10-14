# SPDX-License-Identifier: Apache-2.0

if(CONFIG_AXC3000_HYPERRAM)
  zephyr_include_directories(include)
  zephyr_library_named(axc3000)
  zephyr_library_sources(src/hyperram.c)
endif()
