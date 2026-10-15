/* RSU status; then, on 'f' (factory, 0x210000) or '1' (P1, 0x800000) typed on
 * the JTAG console, a reconfiguration from that flash image.
 */
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/drivers/flash.h>
#include <axc3000/sdm_rsu.h>
#include <libRSU.h>

#ifdef SLOT_CRC_LEN
#include <zephyr/sys/crc.h>

/* CRC-32 of the first SLOT_CRC_LEN bytes of the MCUboot slots - to compare
 * with an uploaded image (-DSLOT_CRC_LEN=<its size>)
 */
static void slot_crcs(void)
{
	static uint8_t buf[4096];
	const struct device *qspi = DEVICE_DT_GET(DT_NODELABEL(qspi));

	for (uint32_t slot = 0x1000000; slot <= 0x1400000; slot += 0x400000) {
		uint32_t crc = 0;
		int r = 0;

		for (uint32_t off = 0; off < SLOT_CRC_LEN && r == 0; off += sizeof(buf)) {
			uint32_t n = MIN(sizeof(buf), SLOT_CRC_LEN - off);

			r = flash_read(qspi, slot + off, buf, n);
			crc = crc32_ieee_update(crc, buf, n);
		}
		printk("slot 0x%07x: crc32 %08x over %u bytes (read %d)\n", slot, crc,
		       SLOT_CRC_LEN, r);
		k_msleep(20);
	}

	/* MCUboot's RAM-load path: flash_read straight into the HyperRAM
	 * (0x01000000), then the copy's CRC - and where it differs
	 */
	for (int pass = 0; pass < 4; pass++) {
		uint8_t *hr = (uint8_t *)0x01000000;
		uint32_t crc = 0, bad = 0, first_bad = UINT32_MAX;
		int r = flash_read(qspi, 0x1000000, hr, SLOT_CRC_LEN);

		crc = crc32_ieee_update(0, hr, SLOT_CRC_LEN);
		for (uint32_t off = 0; off < SLOT_CRC_LEN; off += sizeof(buf)) {
			uint32_t n = MIN(sizeof(buf), SLOT_CRC_LEN - off);

			(void)flash_read(qspi, 0x1000000 + off, buf, n);
			for (uint32_t i = 0; i < n; i++) {
				if (buf[i] != hr[off + i]) {
					bad++;
					first_bad = MIN(first_bad, off + i);
				}
			}
		}
		printk("copy %d: read %d, crc32 %08x, %u bytes differ, first at 0x%x\n", pass, r,
		       crc, bad, first_bad);
		if (bad) {
			printk("  flash %02x %02x %02x %02x / hyperram %02x %02x %02x %02x\n",
			       buf[0], buf[1], buf[2], buf[3], hr[first_bad], hr[first_bad + 1],
			       hr[first_bad + 2], hr[first_bad + 3]);
		}
		k_msleep(20);
	}
}
#endif

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

#ifdef SLOT_CRC_LEN
			slot_crcs();
#endif
			static const uint32_t at[] = {0x210000, 0x600000, 0x620000, 0x800000, 0xc00000,
						      0xff0000, 0x1000000, 0x1200000, 0x1400000, 0x1800000};

			for (int i = 0; i < ARRAY_SIZE(at); i++) {
				uint32_t w = 0;
				int r = flash_read(DEVICE_DT_GET(DT_NODELABEL(qspi)), at[i], &w, 4);

				printk("  0x%07x: %d 0x%08x\n", at[i], r, w);
				k_msleep(20);   /* the JTAG UART drops what does not fit its FIFO */
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
