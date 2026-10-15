/*
 * Warm reboot: restart MCUboot without reconfiguring the FPGA.
 *
 * MCUboot is linked as an XIP image into the bottom 64 KB of the on-chip RAM
 * (mcuboot/mcuboot.overlay) - its code and .data's initial values are never
 * written at run time, and every start copies .data and clears .bss - so the
 * application can reboot by jumping to the reset vector. MCUboot then copies
 * the newest application from flash into the HyperRAM and starts it, as after
 * power-up, without the FPGA reconfiguration from flash (cold reboot,
 * drivers/flash/flash_axc3000_sdm_qspi.c).
 *
 * The boot flags (zephyr_overlays/niosv_g_bootinfo.overlay) tell the
 * application that the MCUboot in the on-chip RAM is such an image: it sets
 * them at every start. A bitstream with an older MCUboot leaves them zero
 * (the RAM's initial contents), and the reboot is cold.
 */
#include <zephyr/kernel.h>
#include <zephyr/init.h>
#include <zephyr/arch/riscv/csr.h>
#include <zephyr/cache.h>
#include <axc3000/warm_reboot.h>

#define BOOT_FLAGS ((volatile uint32_t *)DT_REG_ADDR(DT_NODELABEL(axc3000_boot_flags)))
#define BOOT_FLAGS_MAGIC 0x4d435842u        /* MCUboot XIP image, restartable */
#define RESET_VECTOR 0x0                    /* hw/build_niosv_system.tcl: resetOffset 0 */

static inline void icache_invalidate(void)
{
	__asm__ volatile("fence.i" ::: "memory");
}

#if defined(CONFIG_MCUBOOT)

/* At every MCUboot start: forget the instructions the previous application
 * left in the instruction cache (MCUboot is about to put a new one at the
 * same addresses - the CPU has no data cache, the copy goes to the HyperRAM
 * directly), and say that a warm reboot can come back here.
 */
static int warm_reboot_mcuboot_init(void)
{
	icache_invalidate();
	BOOT_FLAGS[0] = BOOT_FLAGS_MAGIC;
	BOOT_FLAGS[1] = ~BOOT_FLAGS_MAGIC;
	return 0;
}

SYS_INIT(warm_reboot_mcuboot_init, EARLY, 0);

#endif

bool axc3000_warm_reboot_possible(void)
{
	return BOOT_FLAGS[0] == BOOT_FLAGS_MAGIC && BOOT_FLAGS[1] == ~BOOT_FLAGS_MAGIC;
}

FUNC_NORETURN void axc3000_warm_reboot(void)
{
	(void)irq_lock();
	/* no interrupt source enabled for MCUboot's early start; it enables
	 * the ones its drivers use
	 */
	csr_write(mie, 0);
#if defined(CONFIG_AXC3000_NIOSV_CACHE)
	/* the data cache's lines to memory and dropped: MCUboot's RAM may be
	 * where this program's was
	 */
	(void)sys_cache_data_flush_and_invd_all();
#endif
	icache_invalidate();
	((void (*)(void))RESET_VECTOR)();
	CODE_UNREACHABLE;
}
