# SPDX-License-Identifier: Apache-2.0

zephyr_include_directories(include)

if(CONFIG_AXC3000_HYPERRAM OR CONFIG_UART_AXC3000 OR CONFIG_UART_AXC3000_JTAG OR CONFIG_FLASH_AXC3000_SDM_QSPI)
  zephyr_library_named(axc3000)
  zephyr_library_sources_ifdef(CONFIG_AXC3000_HYPERRAM src/hyperram.c)
  zephyr_library_sources_ifdef(CONFIG_UART_AXC3000 drivers/serial/uart_axc3000.c)
  zephyr_library_sources_ifdef(CONFIG_UART_AXC3000_JTAG drivers/serial/uart_axc3000_jtag.c)
  zephyr_library_sources_ifdef(CONFIG_FLASH_AXC3000_SDM_QSPI drivers/flash/flash_axc3000_sdm_qspi.c)
endif()
