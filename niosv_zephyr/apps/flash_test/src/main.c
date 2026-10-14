/* QSPI configuration flash through the SDM mailbox: reads, and a write test
 * that only touches the last 64 KB block, and only if it is fully erased -
 * and erases it back afterwards.
 */
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/flash.h>
#include <string.h>

static const struct device *const flash = DEVICE_DT_GET(DT_NODELABEL(qspi));

#define TEST_SIZE 0x10000

static uint8_t buf[4096];
static uint8_t pattern_buf[4096];

static void dump(const char *what, off_t off, size_t n)
{
	uint8_t b[32];

	if (flash_read(flash, off, b, n) != 0) {
		printk("%s: read failed\n", what);
		return;
	}
	printk("%-12s @0x%07lx:", what, (long)off);
	for (size_t i = 0; i < n; i++) {
		printk(" %02x", b[i]);
	}
	printk("\n");
}

static bool all_erased(off_t off, size_t size)
{
	for (size_t done = 0; done < size; done += sizeof(buf)) {
		if (flash_read(flash, off + done, buf, sizeof(buf))) {
			return false;
		}
		for (size_t i = 0; i < sizeof(buf); i++) {
			if (buf[i] != 0xff) {
				return false;
			}
		}
	}
	return true;
}

int main(void)
{
	uint64_t size;
	int errors = 0;

	if (!device_is_ready(flash)) {
		printk("flash not ready\n");
		return 0;
	}
	flash_get_size(flash, &size);
	printk("QSPI flash through the SDM mailbox: %u MB\n", (unsigned int)(size >> 20));

	dump("start", 0x0, 16);
	dump("0x100000", 0x100000, 16);
	dump("0x200000", 0x200000, 16);
	dump("0x300000", 0x300000, 16);

	/* time per read size */
	static const size_t sizes[] = {16, 256, 1024, 4096};

	for (int i = 0; i < ARRAY_SIZE(sizes); i++) {
		uint32_t c0 = k_cycle_get_32();
		int r = flash_read(flash, 0x1000, buf, sizes[i]);
		uint32_t c1 = k_cycle_get_32();

		printk("read %4u B: %d, %u us\n", (unsigned int)sizes[i], r,
		       (unsigned int)k_cyc_to_us_floor32(c1 - c0));
	}

	/* read speed: 1 MB */
	int64_t t0 = k_uptime_get();

	for (off_t off = 0; off < 0x100000; off += sizeof(buf)) {
		int r = flash_read(flash, off, buf, sizeof(buf));

		if (r) {
			printk("read failed at 0x%lx: %d\n", (long)off, r);
			errors++;
			break;
		}
	}
	int64_t t1 = k_uptime_get();

	printk("read 1 MB in %lld ms\n", t1 - t0);

	/* erase speed: 1 MB in the free area (niosv_g_flash_layout: 0x1800000) */
	t0 = k_uptime_get();
	int er = flash_erase(flash, 0x1800000, 0x100000);
	t1 = k_uptime_get();

	printk("erase 1 MB at 0x1800000: %d, %lld ms\n", er, t1 - t0);

	off_t test = size - TEST_SIZE;

	if (!all_erased(test, TEST_SIZE)) {
		printk("test block 0x%lx is not erased - not writing anything\n", (long)test);
		printk("RESULT: READ ONLY\n");
		return 0;
	}

	for (size_t i = 0; i < sizeof(pattern_buf); i++) {
		pattern_buf[i] = (uint8_t)(i * 7 + 3);
	}

	t0 = k_uptime_get();
	errors += flash_erase(flash, test, TEST_SIZE) != 0;
	t1 = k_uptime_get();
	for (size_t done = 0; done < TEST_SIZE; done += sizeof(pattern_buf)) {
		errors += flash_write(flash, test + done, pattern_buf, sizeof(pattern_buf)) != 0;
	}
	int64_t t2 = k_uptime_get();

	for (size_t done = 0; done < TEST_SIZE; done += sizeof(buf)) {
		flash_read(flash, test + done, buf, sizeof(buf));
		if (memcmp(buf, pattern_buf, sizeof(buf)) != 0) {
			printk("verify failed in 0x%lx\n", (long)(test + done));
			errors++;
		}
	}
	printk("erase 64 KB %lld ms, write 64 KB %lld ms\n", t1 - t0, t2 - t1);

	errors += flash_erase(flash, test, TEST_SIZE) != 0;
	if (!all_erased(test, TEST_SIZE)) {
		printk("test block not erased back\n");
		errors++;
	}
	printk("RESULT: %s (%d errors)\n", errors ? "FAIL" : "PASS", errors);
	return 0;
}
