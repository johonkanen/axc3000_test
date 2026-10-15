/* The partial reconfiguration demo: swaps the PR region between the blue
 * and the green LED blinker persona every PR_PERIOD_MS, while the rest of
 * the FPGA - this CPU, the HyperRAM it runs from, mcumgr on the UART - keeps
 * running.
 */
#include <zephyr/kernel.h>
#include <axc3000/pr.h>

extern const uint8_t persona_blue[], persona_blue_end[];
extern const uint8_t persona_green[], persona_green_end[];

struct persona {
	const char *name;
	const uint8_t *start, *end;
};

static const struct persona personas[] = {
	{"green", persona_green, persona_green_end},
	{"blue", persona_blue, persona_blue_end},
};

int main(void)
{
	printk("pr_blinker %s: swapping personas every %d ms\n", APP_VERSION, PR_PERIOD_MS);

	for (unsigned int n = 0;; n++) {
		const struct persona *p = &personas[n % ARRAY_SIZE(personas)];
		size_t len = p->end - p->start;
		int64_t t0 = k_uptime_get();
		uint32_t status;
		enum axc3000_pr_step step = axc3000_pr_program(p->start, len, &status);

		if (step != AXC3000_PR_OK) {
			printk("pr_blinker: %s failed (step %d, status %u) - stopping\n",
			       p->name, step, status);
			break;
		}
		printk("pr_blinker: %s (%zu bytes) in %lld ms\n", p->name, len,
		       k_uptime_get() - t0);
		k_msleep(PR_PERIOD_MS);
	}
	return 0;
}
