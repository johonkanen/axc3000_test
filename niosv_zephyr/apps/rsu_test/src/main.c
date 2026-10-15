/* RSU status; then, on 'f' (factory, 0x210000) or '1' (P1, 0x800000) typed on
 * the JTAG console, a reconfiguration from that flash image.
 */
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/drivers/flash.h>
#include <axc3000/sdm_rsu.h>
#include <libRSU.h>

int main(void)
{
	const struct device *con = DEVICE_DT_GET(DT_CHOSEN(zephyr_console));
	int ret = librsu_init(NULL);
	int lib_ok = ret == 0;

	if (!lib_ok) {
		printk("librsu_init: %d\n", ret);
	}

	for (int n = 0;; n++) {
		if (n % 300 == 0) {     /* every 3 s: the console may attach late */
			uint32_t st[9] = {0};
			static const uint32_t at[] = {0x210000, 0x600000, 0x620000, 0x800000, 0xc00000,
						      0xff0000, 0x1000000, 0x1200000, 0x1400000, 0x1800000};

			for (int i = 0; i < ARRAY_SIZE(at); i++) {
				uint32_t w = 0;
				int r = flash_read(DEVICE_DT_GET(DT_NODELABEL(qspi)), at[i], &w, 4);

				printk("  0x%07x: %d 0x%08x\n", at[i], r, w);
			}
			ret = axc3000_sdm_rsu_status(st);
			printk("RSU_STATUS: %d\n", ret);
			printk("  current image 0x%08x%08x\n", st[1], st[0]);
			printk("  failing image 0x%08x%08x\n", st[3], st[2]);
			printk("  error 0x%08x location 0x%08x details 0x%08x\n", st[4], st[5], st[7]);
			printk("  version 0x%08x retries 0x%08x\n", st[6], st[8]);
			{
				uint32_t spt[4] = {0};
				int r = axc3000_sdm_rsu_get_spt(spt);

				printk("RSU_GET_SPT: %d %08x %08x %08x %08x\n", r, spt[0], spt[1],
				       spt[2], spt[3]);
			}
			if (!lib_ok) {
				ret = librsu_init(NULL);
				lib_ok = ret == 0;
				printk("librsu_init: %d\n", ret);
			}
			if (lib_ok) {
				struct rsu_status_info info;
				int slots = rsu_slot_count();

				printk("librsu: %d slots\n", slots);
				for (int i = 0; i < slots; i++) {
					struct rsu_slot_info si;

					if (rsu_slot_get_info(i, &si) == 0) {
						printk("  slot %d %-8s 0x%08llx %8d priority %d\n", i,
						       si.name, si.offset, si.size, si.priority);
					}
				}
				if (rsu_status_log(&info) == 0) {
					printk("  current 0x%llx state 0x%llx version 0x%llx\n",
					       info.current_image, info.state, info.version);
				}
			}
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
