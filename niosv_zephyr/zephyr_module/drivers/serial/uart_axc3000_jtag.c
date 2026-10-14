/*
 * The Altera JTAG UART as a console that never hangs: characters are dropped
 * while no host (juart-terminal) reads the JTAG side.
 *
 * Zephyr's uart_altera_jtag.c waits for room in the 64-byte write FIFO with
 * a spinlock held (interrupts off) and no timeout. With no host attached -
 * the board booting from flash on its own - the FIFO never drains and the
 * first long printk hangs the system; with a host, the wait still blocks
 * interrupts for milliseconds. Here: write while there is room; when the
 * FIFO is full, wait (interrupts on) only while a host has shown activity
 * (the controller's AC bit, set whenever the host polls) - give up on it
 * after HOST_TIMEOUT_MS of no progress and drop characters until it shows
 * up again.
 */
#define DT_DRV_COMPAT axc3000_jtag_uart

#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/sys_io.h>

#define REG_DATA      0x0
#define REG_CONTROL   0x4

#define DATA_RVALID   BIT(15)
#define CTRL_AC       BIT(10)     /* host activity; write 1 to clear */
#define CTRL_WSPACE(c) ((c) >> 16)

#define HOST_TIMEOUT_MS 100

struct jtag_uart_config {
	mm_reg_t base;
};

struct jtag_uart_data {
	bool host_present;
};

static void jtag_uart_poll_out(const struct device *dev, unsigned char c)
{
	const struct jtag_uart_config *cfg = dev->config;
	struct jtag_uart_data *data = dev->data;
	uint32_t ctrl = sys_read32(cfg->base + REG_CONTROL);
	uint32_t start, timeout;

	if (ctrl & CTRL_AC) {
		data->host_present = true;
		sys_write32(CTRL_AC, cfg->base + REG_CONTROL);
	}
	if (CTRL_WSPACE(ctrl) > 0) {
		sys_write32(c, cfg->base + REG_DATA);
		return;
	}
	if (!data->host_present) {
		return;     /* nobody listening: drop */
	}

	/* full, and a host has been reading: give it time to drain (on the
	 * cycle counter - it runs before the kernel's timer does)
	 */
	start = k_cycle_get_32();
	timeout = (uint32_t)((uint64_t)HOST_TIMEOUT_MS * sys_clock_hw_cycles_per_sec() / 1000);
	do {
		ctrl = sys_read32(cfg->base + REG_CONTROL);
		if (CTRL_WSPACE(ctrl) > 0) {
			sys_write32(c, cfg->base + REG_DATA);
			return;
		}
	} while (k_cycle_get_32() - start < timeout);

	/* the host went away */
	data->host_present = false;
}

static int jtag_uart_poll_in(const struct device *dev, unsigned char *c)
{
	const struct jtag_uart_config *cfg = dev->config;
	uint32_t d = sys_read32(cfg->base + REG_DATA);

	if (!(d & DATA_RVALID)) {
		return -1;
	}
	*c = d & 0xff;
	return 0;
}

static int jtag_uart_init(const struct device *dev)
{
	const struct jtag_uart_config *cfg = dev->config;

	/* no interrupts; clear a stale activity flag */
	sys_write32(CTRL_AC, cfg->base + REG_CONTROL);
	return 0;
}

static DEVICE_API(uart, jtag_uart_api) = {
	.poll_in = jtag_uart_poll_in,
	.poll_out = jtag_uart_poll_out,
};

#define JTAG_UART_INIT(n)                                                           \
	static const struct jtag_uart_config jtag_uart_config_##n = {               \
		.base = DT_INST_REG_ADDR(n),                                        \
	};                                                                          \
	static struct jtag_uart_data jtag_uart_data_##n;                            \
	DEVICE_DT_INST_DEFINE(n, jtag_uart_init, NULL, &jtag_uart_data_##n,         \
			      &jtag_uart_config_##n, PRE_KERNEL_1,                  \
			      CONFIG_SERIAL_INIT_PRIORITY, &jtag_uart_api);

DT_INST_FOREACH_STATUS_OKAY(JTAG_UART_INIT)
