/*
 * Wait for the HyperRAM's calibration without using it otherwise (MCUboot:
 * it RAM-loads the application into the HyperRAM right after a cold boot,
 * while the calibration may still run). hw/'s pio_hr_status at 0xA0000, as
 * src/hyperram.c.
 */
#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>

#define HR_STATUS_ADDR 0xA0000u
#define HR_CALIBRATED  BIT(0)
#define HR_NO_PASS     BIT(1)

static int hyperram_wait_init(void)
{
	uint32_t status;
	uint32_t waited_ms = 0;

	while (!((status = *(volatile uint32_t *)HR_STATUS_ADDR) & HR_CALIBRATED)) {
		if (waited_ms >= CONFIG_AXC3000_HYPERRAM_WAIT_TIMEOUT_MS) {
			printk("hyperram: not calibrated after %u ms (status 0x%08x)\n",
			       waited_ms, status);
			return -ETIMEDOUT;
		}
		k_busy_wait(1000);
		waited_ms++;
	}
	/* the status layout: <axc3000/hyperram.h> */
	printk("hyperram: calibrated after %u ms (status 0x%08x: step %u, window %u steps = %u ps%s)\n",
	       waited_ms, status, (status >> 4) & 0xff, (status >> 12) & 0xff,
	       ((status >> 12) & 0xff) * 52, (status & HR_NO_PASS) ? ", FAILED" : "");
	return (status & HR_NO_PASS) ? -EIO : 0;
}

SYS_INIT(hyperram_wait_init, POST_KERNEL, 0);
