# SPDX-License-Identifier: Apache-2.0

zephyr_include_directories(include)

if(CONFIG_AXC3000_HYPERRAM OR CONFIG_UART_AXC3000 OR CONFIG_UART_AXC3000_JTAG OR CONFIG_FLASH_AXC3000_SDM_QSPI
   OR CONFIG_AXC3000_WARM_REBOOT OR CONFIG_AXC3000_HYPERRAM_WAIT OR CONFIG_AXC3000_NIOSV_CACHE)
  zephyr_library_named(axc3000)
  zephyr_library_sources_ifdef(CONFIG_AXC3000_HYPERRAM src/hyperram.c)
  zephyr_library_sources_ifdef(CONFIG_AXC3000_HYPERRAM_WAIT src/hyperram_wait.c)
  zephyr_library_sources_ifdef(CONFIG_UART_AXC3000 drivers/serial/uart_axc3000.c)
  zephyr_library_sources_ifdef(CONFIG_UART_AXC3000_JTAG drivers/serial/uart_axc3000_jtag.c)
  zephyr_library_sources_ifdef(CONFIG_FLASH_AXC3000_SDM_QSPI drivers/flash/flash_axc3000_sdm_qspi.c)
  zephyr_library_sources_ifdef(CONFIG_AXC3000_WARM_REBOOT src/warm_reboot.c)
  zephyr_library_sources_ifdef(CONFIG_AXC3000_NIOSV_CACHE drivers/cache/cache_niosv.c)
endif()

# Altera's uniLibRSU (MIT-0, lib/unilibrsu/README.md), on the QSPI flash
# driver and the SDM mailbox
if(CONFIG_AXC3000_LIBRSU)
  set(UNILIBRSU lib/unilibrsu)
  zephyr_include_directories(${UNILIBRSU}/include ${UNILIBRSU}/zephyr)
  zephyr_library_named(axc3000_librsu)
  # zephyr/ first: its version.h wraps Zephyr's generated one
  zephyr_library_include_directories(
    ${UNILIBRSU}/zephyr
    ${UNILIBRSU}/src/priv_include
    ${UNILIBRSU}/platform/platform_include
  )
  zephyr_library_compile_definitions(
    PLATFORM_ZEPHYR=1
    DEFAULT_CFG_FILENAME="librsu.rc"
  )
  zephyr_library_sources(
    ${UNILIBRSU}/src/libRSU.c
    ${UNILIBRSU}/src/libRSU_cb.c
    ${UNILIBRSU}/src/libRSU_cfg.c
    ${UNILIBRSU}/src/libRSU_image.c
    ${UNILIBRSU}/src/libRSU_misc.c
    ${UNILIBRSU}/src/libRSU_ops.c
    ${UNILIBRSU}/src/libRSU_utils.c
    ${UNILIBRSU}/zephyr/rsu_plat_log.c
    ${UNILIBRSU}/zephyr/rsu_plat_zephyr.c
  )
  zephyr_library_sources_ifdef(CONFIG_AXC3000_RSU_MGMT src/rsu_mgmt.c)
  zephyr_library_include_directories(${ZEPHYR_BASE}/subsys/mgmt/mcumgr/util/include)
endif()
