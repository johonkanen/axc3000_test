/*
 * AXC3000 UART with RX/TX FIFOs - niosv_zephyr/hw/uart/uart_axi4lite.vhd.
 *
 * 8N1 only. The baud rate is a fractional bit time, BIT_TIME = clock * 256 /
 * baud, so any rate up to clock / 4 is exact on average (4.8 MBaud at 100
 * MHz: 5333). Polled I/O, and the interrupt-driven API on the hardware's RX
 * level / RX timeout and TX level interrupts: RX interrupts at half a FIFO
 * or after 4 quiet characters, TX when half the FIFO is free.
 */
#define DT_DRV_COMPAT axc3000_uart_fifo

#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/irq.h>
#include <zephyr/sys/sys_io.h>
#include <zephyr/sys/util.h>

#define REG_DATA       0x00
#define REG_STATUS     0x04
#define REG_BIT_TIME   0x08
#define REG_IRQ_ENABLE 0x0c
#define REG_IRQ_LEVELS 0x10
#define REG_IRQ_STATUS 0x14
#define REG_ERRORS     0x18

#define DATA_EMPTY     BIT(8)

#define IRQ_RX         BIT(0)
#define IRQ_TX         BIT(1)

#define IRQ_STATUS_RX_LEVEL   BIT(0)
#define IRQ_STATUS_RX_TIMEOUT BIT(1)
#define IRQ_STATUS_TX_LEVEL   BIT(2)
#define IRQ_STATUS_TX_DONE    BIT(3)

struct uart_axc3000_config {
	mm_reg_t base;
	uint32_t clock_frequency;
	uint32_t fifo_size;
#ifdef CONFIG_UART_INTERRUPT_DRIVEN
	void (*irq_config)(const struct device *dev);
#endif
};

struct uart_axc3000_data {
	struct uart_config uart_cfg;
	uint32_t irq_enable;
#ifdef CONFIG_UART_INTERRUPT_DRIVEN
	uart_irq_callback_user_data_t cb;
	void *cb_data;
#endif
};

static inline uint32_t reg_read(const struct device *dev, uint32_t offset)
{
	const struct uart_axc3000_config *cfg = dev->config;

	return sys_read32(cfg->base + offset);
}

static inline void reg_write(const struct device *dev, uint32_t offset, uint32_t value)
{
	const struct uart_axc3000_config *cfg = dev->config;

	sys_write32(value, cfg->base + offset);
}

static inline uint32_t rx_count(const struct device *dev)
{
	return reg_read(dev, REG_STATUS) & 0xffff;
}

static inline uint32_t tx_free(const struct device *dev)
{
	return reg_read(dev, REG_STATUS) >> 16;
}

static int uart_axc3000_poll_in(const struct device *dev, unsigned char *c)
{
	uint32_t data = reg_read(dev, REG_DATA);

	if (data & DATA_EMPTY) {
		return -1;
	}
	*c = data & 0xff;
	return 0;
}

static void uart_axc3000_poll_out(const struct device *dev, unsigned char c)
{
	while (tx_free(dev) == 0) {
	}
	reg_write(dev, REG_DATA, c);
}

static int uart_axc3000_err_check(const struct device *dev)
{
	uint32_t errors = reg_read(dev, REG_ERRORS);
	int err = 0;

	if (errors == 0) {
		return 0;
	}
	if (errors & 0xffff) {
		err |= UART_ERROR_OVERRUN;
	}
	if (errors >> 16) {
		err |= UART_ERROR_FRAMING;
	}
	reg_write(dev, REG_ERRORS, 0);
	return err;
}

static int set_baudrate(const struct device *dev, uint32_t baudrate)
{
	const struct uart_axc3000_config *cfg = dev->config;
	uint64_t bit_time;

	if (baudrate == 0) {
		return -EINVAL;
	}
	bit_time = ((uint64_t)cfg->clock_frequency * 256 + baudrate / 2) / baudrate;
	if (bit_time < 4 * 256 || bit_time > 0xfffff) {
		return -ENOTSUP;
	}
	reg_write(dev, REG_BIT_TIME, (uint32_t)bit_time);
	return 0;
}

#ifdef CONFIG_UART_USE_RUNTIME_CONFIGURE
static int uart_axc3000_configure(const struct device *dev, const struct uart_config *uart_cfg)
{
	struct uart_axc3000_data *data = dev->data;
	int ret;

	if (uart_cfg->parity != UART_CFG_PARITY_NONE ||
	    uart_cfg->stop_bits != UART_CFG_STOP_BITS_1 ||
	    uart_cfg->data_bits != UART_CFG_DATA_BITS_8 ||
	    uart_cfg->flow_ctrl != UART_CFG_FLOW_CTRL_NONE) {
		return -ENOTSUP;
	}
	ret = set_baudrate(dev, uart_cfg->baudrate);
	if (ret == 0) {
		data->uart_cfg = *uart_cfg;
	}
	return ret;
}

static int uart_axc3000_config_get(const struct device *dev, struct uart_config *uart_cfg)
{
	struct uart_axc3000_data *data = dev->data;

	*uart_cfg = data->uart_cfg;
	return 0;
}
#endif

#ifdef CONFIG_UART_INTERRUPT_DRIVEN
static int uart_axc3000_fifo_fill(const struct device *dev, const uint8_t *buf, int len)
{
	int n = MIN((uint32_t)len, tx_free(dev));

	for (int i = 0; i < n; i++) {
		reg_write(dev, REG_DATA, buf[i]);
	}
	return n;
}

static int uart_axc3000_fifo_read(const struct device *dev, uint8_t *buf, const int len)
{
	int n = MIN((uint32_t)len, rx_count(dev));

	for (int i = 0; i < n; i++) {
		buf[i] = reg_read(dev, REG_DATA) & 0xff;
	}
	return n;
}

static void set_irq_enable(const struct device *dev, uint32_t bits, bool on)
{
	struct uart_axc3000_data *data = dev->data;
	unsigned int key = irq_lock();

	if (on) {
		data->irq_enable |= bits;
	} else {
		data->irq_enable &= ~bits;
	}
	reg_write(dev, REG_IRQ_ENABLE, data->irq_enable);
	irq_unlock(key);
}

static void uart_axc3000_irq_tx_enable(const struct device *dev)
{
	set_irq_enable(dev, IRQ_TX, true);
}

static void uart_axc3000_irq_tx_disable(const struct device *dev)
{
	set_irq_enable(dev, IRQ_TX, false);
}

static int uart_axc3000_irq_tx_ready(const struct device *dev)
{
	struct uart_axc3000_data *data = dev->data;

	if (!(data->irq_enable & IRQ_TX)) {
		return 0;
	}
	return tx_free(dev);
}

static int uart_axc3000_irq_tx_complete(const struct device *dev)
{
	return (reg_read(dev, REG_IRQ_STATUS) & IRQ_STATUS_TX_DONE) ? 1 : 0;
}

static void uart_axc3000_irq_rx_enable(const struct device *dev)
{
	set_irq_enable(dev, IRQ_RX, true);
}

static void uart_axc3000_irq_rx_disable(const struct device *dev)
{
	set_irq_enable(dev, IRQ_RX, false);
}

static int uart_axc3000_irq_rx_ready(const struct device *dev)
{
	struct uart_axc3000_data *data = dev->data;

	if (!(data->irq_enable & IRQ_RX)) {
		return 0;
	}
	return rx_count(dev) > 0;
}

static int uart_axc3000_irq_is_pending(const struct device *dev)
{
	struct uart_axc3000_data *data = dev->data;
	uint32_t status = reg_read(dev, REG_IRQ_STATUS);

	return ((data->irq_enable & IRQ_RX) &&
		(status & (IRQ_STATUS_RX_LEVEL | IRQ_STATUS_RX_TIMEOUT))) ||
	       ((data->irq_enable & IRQ_TX) && (status & IRQ_STATUS_TX_LEVEL));
}

static int uart_axc3000_irq_update(const struct device *dev)
{
	ARG_UNUSED(dev);
	return 1;
}

static void uart_axc3000_irq_callback_set(const struct device *dev,
					  uart_irq_callback_user_data_t cb, void *cb_data)
{
	struct uart_axc3000_data *data = dev->data;

	data->cb = cb;
	data->cb_data = cb_data;
}

static void uart_axc3000_isr(const struct device *dev)
{
	struct uart_axc3000_data *data = dev->data;

	if (data->cb) {
		data->cb(dev, data->cb_data);
	} else {
		/* nobody to serve it: stop it firing */
		set_irq_enable(dev, IRQ_RX | IRQ_TX, false);
	}
}
#endif

static int uart_axc3000_init(const struct device *dev)
{
	const struct uart_axc3000_config *cfg = dev->config;
	struct uart_axc3000_data *data = dev->data;
	int ret;

	reg_write(dev, REG_IRQ_ENABLE, 0);
	ret = set_baudrate(dev, data->uart_cfg.baudrate);
	if (ret) {
		return ret;
	}
	/* RX: half a FIFO (or the timeout); TX: half a FIFO free */
	reg_write(dev, REG_IRQ_LEVELS, ((cfg->fifo_size / 2) << 16) | (cfg->fifo_size / 2));
	reg_write(dev, REG_ERRORS, 0);
#ifdef CONFIG_UART_INTERRUPT_DRIVEN
	if (cfg->irq_config) {
		cfg->irq_config(dev);
	}
#endif
	return 0;
}

static DEVICE_API(uart, uart_axc3000_api) = {
	.poll_in = uart_axc3000_poll_in,
	.poll_out = uart_axc3000_poll_out,
	.err_check = uart_axc3000_err_check,
#ifdef CONFIG_UART_USE_RUNTIME_CONFIGURE
	.configure = uart_axc3000_configure,
	.config_get = uart_axc3000_config_get,
#endif
#ifdef CONFIG_UART_INTERRUPT_DRIVEN
	.fifo_fill = uart_axc3000_fifo_fill,
	.fifo_read = uart_axc3000_fifo_read,
	.irq_tx_enable = uart_axc3000_irq_tx_enable,
	.irq_tx_disable = uart_axc3000_irq_tx_disable,
	.irq_tx_ready = uart_axc3000_irq_tx_ready,
	.irq_tx_complete = uart_axc3000_irq_tx_complete,
	.irq_rx_enable = uart_axc3000_irq_rx_enable,
	.irq_rx_disable = uart_axc3000_irq_rx_disable,
	.irq_rx_ready = uart_axc3000_irq_rx_ready,
	.irq_is_pending = uart_axc3000_irq_is_pending,
	.irq_update = uart_axc3000_irq_update,
	.irq_callback_set = uart_axc3000_irq_callback_set,
#endif
};

#ifdef CONFIG_UART_INTERRUPT_DRIVEN
#define UART_AXC3000_IRQ_CONFIG(n)                                                  \
	static void uart_axc3000_irq_config_##n(const struct device *dev)          \
	{                                                                           \
		IRQ_CONNECT(DT_INST_IRQN(n), 0,                                     \
			    uart_axc3000_isr, DEVICE_DT_INST_GET(n), 0);            \
		irq_enable(DT_INST_IRQN(n));                                        \
	}
#define UART_AXC3000_IRQ_CONFIG_FUNC(n)                                             \
	.irq_config = COND_CODE_1(DT_INST_IRQ_HAS_IDX(n, 0),                        \
				  (uart_axc3000_irq_config_##n), (NULL)),
#define UART_AXC3000_IRQ_DEFINE(n)                                                  \
	IF_ENABLED(DT_INST_IRQ_HAS_IDX(n, 0), (UART_AXC3000_IRQ_CONFIG(n)))
#else
#define UART_AXC3000_IRQ_CONFIG_FUNC(n)
#define UART_AXC3000_IRQ_DEFINE(n)
#endif

#define UART_AXC3000_INIT(n)                                                        \
	UART_AXC3000_IRQ_DEFINE(n)                                                  \
	static const struct uart_axc3000_config uart_axc3000_config_##n = {         \
		.base = DT_INST_REG_ADDR(n),                                        \
		.clock_frequency = DT_INST_PROP_OR(n, clock_frequency,             \
			DT_PROP(DT_NODELABEL(cpu0), clock_frequency)),              \
		.fifo_size = DT_INST_PROP(n, fifo_size),                            \
		UART_AXC3000_IRQ_CONFIG_FUNC(n)                                     \
	};                                                                          \
	static struct uart_axc3000_data uart_axc3000_data_##n = {                   \
		.uart_cfg = {                                                       \
			.baudrate = DT_INST_PROP(n, current_speed),                 \
			.parity = UART_CFG_PARITY_NONE,                             \
			.stop_bits = UART_CFG_STOP_BITS_1,                          \
			.data_bits = UART_CFG_DATA_BITS_8,                          \
			.flow_ctrl = UART_CFG_FLOW_CTRL_NONE,                       \
		},                                                                  \
	};                                                                          \
	DEVICE_DT_INST_DEFINE(n, uart_axc3000_init, NULL, &uart_axc3000_data_##n,   \
			      &uart_axc3000_config_##n, PRE_KERNEL_1,               \
			      CONFIG_SERIAL_INIT_PRIORITY, &uart_axc3000_api);

DT_INST_FOREACH_STATUS_OKAY(UART_AXC3000_INIT)
