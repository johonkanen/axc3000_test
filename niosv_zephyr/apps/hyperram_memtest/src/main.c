/* HyperRAM memory test over Nios V/g's data bus. The HyperRAM is a 16 MB
 * window at 0x01000000 (niosv_zephyr_sys hr_axi -> hyperram_axi4lite_bridge
 * -> hyperram_axi, see hw/niosv_zephyr_top.vhd). No data cache, so every
 * access goes to the memory.
 *
 * hyperram_axi holds the bus until its calibration is done, so the status
 * PIO is checked first: touching the window before that would hang the CPU.
 */
#include <zephyr/kernel.h>
#include <stdint.h>
#include <stdbool.h>

#define HR_STATUS   (*(volatile uint32_t *)0xA0000)
#define HR_DEBUG_LO (*(volatile uint32_t *)0xA0010)
#define HR_DEBUG_HI (*(volatile uint32_t *)0xA0020)
#define HR_TIMEOUTS (*(volatile uint32_t *)0xA0030)

#define HR_BASE  0x01000000u
#define HR_SIZE  (16u * 1024u * 1024u)
#define HR_WORDS (HR_SIZE / 4u)

#define MAX_REPORTED 8

static volatile uint32_t *const hr32 = (volatile uint32_t *)HR_BASE;

static unsigned int errors;

static void print_status(const char *when)
{
	uint32_t status = HR_STATUS;

	printk("%s: status=0x%08x calibrated=%d passed=%d phase=%u lo_first=%d "
	       "pass_map=0x%04x debug=0x%08x%08x timeouts=%u\n",
	       when, status, status & 1, !(status & 2), (status >> 24) & 7,
	       (status >> 27) & 1, (status >> 8) & 0xffff,
	       HR_DEBUG_HI, HR_DEBUG_LO, HR_TIMEOUTS);
}

static void fail(const char *test, uint32_t offset, uint32_t expected, uint32_t got)
{
	if (errors < MAX_REPORTED) {
		printk("  FAIL %s @0x%06x: expected 0x%08x got 0x%08x (xor 0x%08x)\n",
		       test, offset, expected, got, expected ^ got);
	}
	errors++;
}

static bool report(const char *test, unsigned int before)
{
	unsigned int n = errors - before;

	printk("%-24s %s (%u errors)\n", test, n ? "FAIL" : "ok", n);
	return n == 0;
}

/* data bus: walking 1s and 0s through one word, both 32-bit halves of a beat */
static bool test_data_bus(void)
{
	unsigned int before = errors;

	for (uint32_t w = 0; w < 2; w++) {
		for (int bit = 0; bit < 32; bit++) {
			uint32_t one = 1u << bit;

			hr32[w] = one;
			uint32_t got = hr32[w];

			if (got != one) {
				fail("walking 1", w * 4, one, got);
			}
			hr32[w] = ~one;
			got = hr32[w];
			if (got != ~one) {
				fail("walking 0", w * 4, ~one, got);
			}
		}
	}
	return report("data bus", before);
}

/* address bus: a unique value at every power-of-two word offset, then check
 * none of them aliases another (a stuck or shorted address bit would)
 */
static bool test_address_bus(void)
{
	unsigned int before = errors;
	uint32_t offsets[24];
	int n = 0;

	offsets[n++] = 0;
	for (uint32_t off = 1; off < HR_WORDS; off <<= 1) {
		offsets[n++] = off;
	}
	for (int i = 0; i < n; i++) {
		hr32[offsets[i]] = 0xa5000000u | (uint32_t)i;
	}
	for (int i = 0; i < n; i++) {
		uint32_t got = hr32[offsets[i]];

		if (got != (0xa5000000u | (uint32_t)i)) {
			fail("address", offsets[i] * 4, 0xa5000000u | (uint32_t)i, got);
		}
	}
	return report("address bus", before);
}

/* byte and halfword writes: the write strobes (RWDS masking) */
static bool test_strobes(void)
{
	unsigned int before = errors;
	volatile uint8_t *hr8 = (volatile uint8_t *)HR_BASE;
	volatile uint16_t *hr16 = (volatile uint16_t *)HR_BASE;

	for (uint32_t w = 16; w < 18; w++) {
		hr32[w] = 0x00000000u;
		for (int b = 0; b < 4; b++) {
			uint32_t expected = 0;

			hr8[w * 4 + b] = 0x11u * (uint8_t)(b + 1);
			for (int k = 0; k <= b; k++) {
				expected |= (0x11u * (uint32_t)(k + 1)) << (8 * k);
			}
			uint32_t got = hr32[w];

			if (got != expected) {
				fail("byte write", w * 4 + b, expected, got);
			}
		}
		for (int b = 0; b < 4; b++) {
			uint8_t got = hr8[w * 4 + b];

			if (got != 0x11u * (uint8_t)(b + 1)) {
				fail("byte read", w * 4 + b, 0x11u * (uint32_t)(b + 1), got);
			}
		}
		hr32[w] = 0xffffffffu;
		hr16[w * 2 + 1] = 0x1234;
		if (hr32[w] != 0x1234ffffu) {
			fail("halfword hi", w * 4 + 2, 0x1234ffffu, hr32[w]);
		}
		hr16[w * 2] = 0x5678;
		if (hr32[w] != 0x12345678u) {
			fail("halfword lo", w * 4, 0x12345678u, hr32[w]);
		}
	}
	return report("byte/halfword strobes", before);
}

/* every word, an address-derived pattern: catches aliasing over the whole
 * array and data-dependent errors; run twice with the pattern inverted so
 * every bit of every word is both 0 and 1
 */
static inline uint32_t pattern(uint32_t i, uint32_t invert)
{
	uint32_t x = i * 0x9e3779b1u + 0x7f4a7c15u;

	x ^= x >> 15;
	return x ^ invert;
}

static bool test_full(uint32_t invert)
{
	unsigned int before = errors;
	int64_t t0 = k_uptime_get();

	for (uint32_t i = 0; i < HR_WORDS; i++) {
		hr32[i] = pattern(i, invert);
	}
	int64_t t1 = k_uptime_get();

	for (uint32_t i = 0; i < HR_WORDS; i++) {
		uint32_t got = hr32[i];
		uint32_t expected = pattern(i, invert);

		if (got != expected) {
			fail("full array", i * 4, expected, got);
		}
	}
	int64_t t2 = k_uptime_get();

	printk("  16 MB write %lld ms (%u KB/s), verify %lld ms (%u KB/s)\n",
	       t1 - t0, (unsigned int)(16384 * 1000 / (t1 - t0 + 1)),
	       t2 - t1, (unsigned int)(16384 * 1000 / (t2 - t1 + 1)));
	return report(invert ? "full array, inverted" : "full array", before);
}

int main(void)
{
	printk("HyperRAM memory test, window 0x%08x, %u MB\n", HR_BASE, HR_SIZE >> 20);

	int64_t deadline = k_uptime_get() + 2000;

	while (!(HR_STATUS & 1)) {
		if (k_uptime_get() > deadline) {
			print_status("not calibrated after 2 s");
			printk("ABORT: the window would hang the bus\n");
			return 0;
		}
		k_msleep(10);
	}
	print_status("calibrated");

	bool ok = true;

	ok &= test_data_bus();
	ok &= test_address_bus();
	ok &= test_strobes();
	ok &= test_full(0);
	ok &= test_full(0xffffffffu);

	print_status("after tests");
	printk("RESULT: %s (%u errors)\n", ok ? "PASS" : "FAIL", errors);
	return 0;
}
