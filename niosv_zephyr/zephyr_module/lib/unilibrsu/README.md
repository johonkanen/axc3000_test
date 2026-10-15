# uniLibRSU - Altera's RSU library, on the AXC3000 Nios V

From https://github.com/altera-fpga/librsu (MIT-0, see LICENSE), commit
21b64b1 (2024-09-05): `src/`, `include/`, `platform/platform_include/`,
unchanged. It replaced an earlier port of the Linux-only
altera-opensource/intel-rsu.

Upstream's Zephyr platform layer (for the HPS, through SiP services) lives in
Altera's internal Zephyr tree; `zephyr/` is this board's:

- `rsu_plat_zephyr.c` - the platform interfaces:
  - QSPI: the flash driver (`axc3000,sdm-qspi`) with absolute flash
    addresses. Writes and erases are allowed only inside the devicetree
    partitions `rsu_tables_partition` (SPT/CPB) and `rsu_p1/p2_partition`;
    anything else (BOOT_INFO, the factory image, the MCUboot slots) is
    refused and logged.
  - mailbox: RSU_STATUS, RSU_GET_SPT, RSU_NOTIFY, RSU_IMAGE_UPDATE
    (`<axc3000/sdm_rsu.h>`). `send_rsu_update` (Linux: at the next reboot)
    reconfigures now.
  - file: no file system - only the built-in configuration `librsu.rc`
    (`librsu_init(NULL)`), SPT checksums on.
  - misc (DCMF status/version, max retry): not available, `-ENOTSUP`.
  - OSAL: malloc, k_mutex; crc32 = `crc32_ieee_update`.
- `rsu_plat_log.c` - the `uniLibRSU` log module (`CONFIG_UNILIBRSU_LOG_LEVEL`).
- `RSU_OSAL_types.h`, `version.h` - what upstream's build generates or keeps
  per platform.

`rsu_slot_program_buf()` checks an application image's CRC, relocates its
section pointers into the slot, verifies each block, and puts the slot first
in the CPB (highest priority).
