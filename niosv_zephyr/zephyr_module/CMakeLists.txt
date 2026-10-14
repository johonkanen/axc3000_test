# SPDX-License-Identifier: Apache-2.0

zephyr_include_directories(include)

if(CONFIG_AXC3000_HYPERRAM OR CONFIG_UART_AXC3000 OR CONFIG_UART_AXC3000_JTAG OR CONFIG_FLASH_AXC3000_SDM_QSPI)
  zephyr_library_named(axc3000)
  zephyr_library_sources_ifdef(CONFIG_AXC3000_HYPERRAM src/hyperram.c)
  zephyr_library_sources_ifdef(CONFIG_UART_AXC3000 drivers/serial/uart_axc3000.c)
  zephyr_library_sources_ifdef(CONFIG_UART_AXC3000_JTAG drivers/serial/uart_axc3000_jtag.c)
  zephyr_library_sources_ifdef(CONFIG_FLASH_AXC3000_SDM_QSPI drivers/flash/flash_axc3000_sdm_qspi.c)
endif()

# Intel's libRSU (BSD-2-Clause, lib/librsu/README.md), on the QSPI flash
# driver and the SDM mailbox
if(CONFIG_AXC3000_LIBRSU)
  zephyr_library_named(axc3000_librsu)
  zephyr_library_include_directories(lib/librsu/compat lib/librsu)
  zephyr_library_compile_definitions(LIBRSU_VER=0)   # as upstream's makefile
  zephyr_library_sources(
    lib/librsu/librsu.c
    lib/librsu/librsu_cb.c
    lib/librsu/librsu_cfg.c
    lib/librsu/librsu_image.c
    lib/librsu/librsu_ll_qspi.c
    lib/librsu/librsu_misc.c
  )
  zephyr_library_sources_ifdef(CONFIG_AXC3000_RSU_MGMT src/rsu_mgmt.c)
  zephyr_library_include_directories(${ZEPHYR_BASE}/subsys/mgmt/mcumgr/util/include)
endif()
