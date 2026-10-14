# librsu - Intel's RSU library, on the AXC3000 Nios V

From https://github.com/altera-opensource/intel-rsu (BSD-2-Clause, see
LICENSE), commit f6e0f1e15e8e77c0c1150e2df34a13d9a5bd9771, `lib/` and `include/librsu.h`.

Upstream runs on Linux: the flash through an MTD device, the SDM through the
stratix10-rsu sysfs attributes. Here (changes marked `__ZEPHYR__`):

- `librsu_ll_qspi.c` - read/write/erase through the Zephyr flash API on the
  QSPI flash (zephyr_module's `axc3000,sdm-qspi`); offsets stay relative to
  SPT0, as upstream's MTD device; no file save/restore of SPT/CPB.
- `librsu_misc.c` - the sysfs attributes (`current_image`, `spt0_address`,
  `reboot_image`, `notify`, ...) answered by SDM mailbox commands
  (RSU_STATUS, RSU_GET_SPT, RSU_IMAGE_UPDATE, RSU_NOTIFY).
- `librsu_cfg.c` - no configuration file: QSPI, one flash, log to printk.
- `librsu.c` / `librsu_cb.c` - no file I/O (`librsu_init(NULL)`).
- `compat/` - `linux/types.h`, `mtd/mtd-user.h`, `zlib.h` (crc32 = Zephyr's
  crc32_ieee_update) for this library only.
