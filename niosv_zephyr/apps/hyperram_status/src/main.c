/* Polls the HyperRAM bring-up status PIOs (niosv_zephyr/hw_hyperram's
 * pio_hr_status/_debug_lo/_debug_hi/_timeouts, base 0xA0000) and prints
 * them over the console (JTAG UART). hyperram_axi's own status bit
 * layout (see source/hVHDL_memory_library/hyperram/hyperram_axi.vhd's
 * header): bit0 calibrated, bit1 no setting passed, bits 15:8/23:16
 * phases that passed, bits 26:24 selected phase, bit 27 selected order.
 */
#include <zephyr/kernel.h>
#include <stdint.h>

#define HR_STATUS   (*(volatile uint32_t *)0xA0000)
#define HR_DEBUG_LO (*(volatile uint32_t *)0xA0010)
#define HR_DEBUG_HI (*(volatile uint32_t *)0xA0020)
#define HR_TIMEOUTS (*(volatile uint32_t *)0xA0030)

int main(void)
{
	for (int i = 0; i < 20; i++) {
		uint32_t status = HR_STATUS;

		/* the relative-phase layout (zephyr_module <axc3000/hyperram.h>) */
		printk("hr status=0x%08x calibrated=%d passed=%d step=%u window=%u (%u ps) "
		       "other=%u lo_first=%d debug=0x%08x%08x timeouts=%u\n",
		       status, status & 1, !(status & 2), (status >> 4) & 0xff,
		       (status >> 12) & 0xff, ((status >> 12) & 0xff) * 52, (status >> 20) & 0xff,
		       (status >> 2) & 1, HR_DEBUG_HI, HR_DEBUG_LO, HR_TIMEOUTS);
		k_msleep(500);
	}
	return 0;
}
