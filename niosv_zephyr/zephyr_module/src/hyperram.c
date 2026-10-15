/*
 * AXC3000 onboard HyperRAM: waits for its calibration, then puts a k_heap on
 * the free part of the 'hyperram' memory region.
 *
 * hyperram_axi holds the bus (arw_ready low) until its calibration is done,
 * so nothing may touch the window before that - the CPU would hang on the
 * access. The status comes from hw/'s pio_hr_status (0xA0000), a read-only
 * PIO that is not in the devicetree.
 */
#include <axc3000/hyperram.h>

#include <zephyr/init.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/util.h>

#define HR_STATUS_ADDR 0xA0000u
#define HR_CALIBRATED  BIT(0)
#define HR_NO_PASS     BIT(1)

/* the board's 256 KB on-chip RAM makes Zephyr default to small-only heaps,
 * which k_heap_init silently caps at 256 KB
 */
BUILD_ASSERT(!IS_ENABLED(CONFIG_SYS_HEAP_SMALL_ONLY),
	     "hyperram_heap needs CONFIG_SYS_HEAP_AUTO=y or CONFIG_SYS_HEAP_BIG_ONLY=y");

/* the end of the HYPERRAM section (the linker's __HYPERRAM_end) */
extern char __HYPERRAM_end[];

struct k_heap hyperram_heap;
static bool ready;

uint32_t hyperram_status(void)
{
	return *(volatile uint32_t *)HR_STATUS_ADDR;
}

bool hyperram_ready(void)
{
	return ready;
}

static int hyperram_init(void)
{
	uint32_t waited_ms = 0;
	uint32_t status;

	while (!((status = hyperram_status()) & HR_CALIBRATED)) {
		if (waited_ms >= CONFIG_AXC3000_HYPERRAM_CALIBRATION_TIMEOUT_MS) {
			printk("hyperram: not calibrated after %u ms (status 0x%08x), not used\n",
			       waited_ms, status);
			return -ETIMEDOUT;
		}
		k_busy_wait(1000);
		waited_ms++;
	}
	if (status & HR_NO_PASS) {
		printk("hyperram: calibration failed (status 0x%08x: window %u steps, "
		       "under the minimum), not used\n", status, HYPERRAM_STATUS_WINDOW(status));
		return -EIO;
	}

	uintptr_t start = ROUND_UP((uintptr_t)__HYPERRAM_end, 8);
	uintptr_t end = HYPERRAM_BASE + HYPERRAM_SIZE;

	k_heap_init(&hyperram_heap, (void *)start, end - start);
	ready = true;
	printk("hyperram: calibrated (status 0x%08x: step %u, window %u steps = %u ps), "
	       "heap %u KB at 0x%08lx\n", status, HYPERRAM_STATUS_STEP(status),
	       HYPERRAM_STATUS_WINDOW(status), HYPERRAM_STATUS_WINDOW(status) * 52,
	       (unsigned int)((end - start) / 1024), (unsigned long)start);
	return 0;
}

SYS_INIT(hyperram_init, POST_KERNEL, 0);
