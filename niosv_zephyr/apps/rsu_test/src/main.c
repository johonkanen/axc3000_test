/* RSU status; then, on 'f' (factory, 0x210000) or '1' (P1, 0x800000) typed on
 * the JTAG console, a reconfiguration from that flash image.
 */
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/drivers/flash.h>
#include <axc3000/sdm_rsu.h>

int main(void)
{
	const struct device *con = DEVICE_DT_GET(DT_CHOSEN(zephyr_console));
	int ret;

	for (int n = 0;; n++) {
		if (n % 300 == 0) {     /* every 3 s: the console may attach late */
			uint32_t st[9] = {0};
			uint32_t w = 0;
			int r = flash_read(DEVICE_DT_GET(DT_NODELABEL(qspi)), 0x1000000, &w, 4);

			printk("flash read first: %d (0x%08x)\n", r, w);
			ret = axc3000_sdm_rsu_status(st);
			printk("RSU_STATUS: %d\n", ret);
			printk("  current image 0x%08x%08x\n", st[1], st[0]);
			printk("  failing image 0x%08x%08x\n", st[3], st[2]);
			printk("  error 0x%08x location 0x%08x details 0x%08x\n", st[4], st[5], st[7]);
			printk("  version 0x%08x retries 0x%08x\n", st[6], st[8]);
			printk("f: factory 0x210000, 1: P1 0x800000 - reconfigure\n");
		}
		unsigned char c;

		if (uart_poll_in(con, &c) == 0 && (c == 'f' || c == '1')) {
			uint64_t addr = c == 'f' ? 0x210000 : 0x800000;

			printk("RSU_IMAGE_UPDATE 0x%llx\n", addr);
			ret = axc3000_sdm_rsu_image_update(addr);
			printk("returned %d\n", ret);
		}
		k_msleep(10);
	}
	return 0;
}
