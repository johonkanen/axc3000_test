/*
 * Partial reconfiguration through Altera's PR Controller IP, Avalon-MM
 * (hw/ip/.../altera_pr_mm_*.sv): word 0 data (written words go to the SDM -
 * only while a PR is in progress -, back-pressured: the CPU's store waits),
 * word 1 CSR (write bit 0 starts; read bits 3:1 the status: 1 system busy,
 * 2 in progress, 3 done, 4 or 6 an error). pio_pr_ctrl's data register: bit
 * 0 freezes the region's outputs, bit 1 resets it.
 */
#include <zephyr/kernel.h>
#include <zephyr/devicetree.h>
#include <zephyr/logging/log.h>
#include <axc3000/pr.h>

LOG_MODULE_REGISTER(axc3000_pr, LOG_LEVEL_INF);

#define PR_NODE      DT_NODELABEL(pr_controller)
#define PR_DATA      ((volatile uint32_t *)DT_REG_ADDR_BY_NAME(PR_NODE, pr))
#define PR_CSR       (PR_DATA + 1)
#define PR_CTRL      ((volatile uint32_t *)DT_REG_ADDR_BY_NAME(PR_NODE, ctrl))
#define PR_FREEZE    BIT(0)
#define PR_RESET     BIT(1)

#define PR_ST_PROG   2
#define PR_ST_DONE   3

static uint32_t pr_status(void)
{
	return (*PR_CSR >> 1) & 7;
}

static bool pr_error(uint32_t st)
{
	return st == 4 || st == 6;
}

/* polls for want (or an error) for up to 1 s */
static uint32_t pr_wait(uint32_t want)
{
	int64_t end = k_uptime_get() + 1000;
	uint32_t st;

	do {
		st = pr_status();
		if (st == want || pr_error(st)) {
			break;
		}
	} while (k_uptime_get() < end);
	return st;
}

enum axc3000_pr_step axc3000_pr_program(const void *image, size_t len, uint32_t *status)
{
	enum axc3000_pr_step step = AXC3000_PR_START;
	uint32_t st;

	/* the region's outputs held, its logic in reset (a few of its 25 MHz
	 * clock's cycles through the synchroniser)
	 */
	*PR_CTRL = PR_FREEZE | PR_RESET;
	k_busy_wait(10);

	*PR_CSR = 1;
	st = pr_wait(PR_ST_PROG);
	if (st == PR_ST_PROG) {
		const uint32_t *w = image;
		size_t n = len / 4;
		bool failed = false;

		step = AXC3000_PR_STREAM;
		/* all of it even after an error: the PR IP user guide's recovery
		 * (Agilex) drains the rest of the bitstream before a retry.
		 * But a damaged image makes the SDM stop taking data, and the
		 * store below then waits forever - the CPU hangs until the FPGA
		 * is reconfigured (seen on the board). A real design needs a
		 * timeout in front of the data port.
		 */
		for (size_t i = 0; i < n; i++) {
			*PR_DATA = w[i];
			if ((i & 1023) == 1023 && !failed && pr_error(st = pr_status())) {
				failed = true;
			}
		}
		if (!failed) {
			step = AXC3000_PR_FINISH;
			st = pr_wait(PR_ST_DONE);
		}
	}
	if (st == PR_ST_DONE) {
		step = AXC3000_PR_OK;
		/* reset released while still frozen, then the outputs */
		*PR_CTRL = PR_FREEZE;
		k_busy_wait(10);
		*PR_CTRL = 0;
	} else {
		/* the region stays frozen and in reset: no half-programmed logic
		 * drives anything
		 */
		LOG_ERR("PR failed: step %d, status %u", step, st);
	}
	if (status) {
		*status = st;
	}
	return step;
}
