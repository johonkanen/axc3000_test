/* Interrupt-driven echo on uart1 (the FTDI serial port, hw/uart/): every
 * byte received is sent back. The interrupt handler moves bytes straight
 * from the RX FIFO to the TX FIFO, through a ring buffer only when the TX
 * FIFO is full. Counters on the console (the JTAG UART) once the traffic
 * stops.
 * host_echo_test.py drives it.
 */
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/sys/ring_buffer.h>

static const struct device *const uart = DEVICE_DT_GET(DT_NODELABEL(uart1));

RING_BUF_DECLARE(pending, 8192);

/* The console is the JTAG UART, whose driver writes with interrupts locked
 * and waits, without a timeout, for room in its 64-byte FIFO - which only a
 * host (juart-terminal) empties. A status line is printed only when it fits
 * the FIFO as it is, so the echo keeps working with no console attached.
 */
#define JTAG_UART_CTRL (*(volatile uint32_t *)(DT_REG_ADDR(DT_NODELABEL(uart0)) + 4))
#define JTAG_UART_WSPACE() (JTAG_UART_CTRL >> 16)

static volatile uint32_t rx_bytes, tx_bytes, dropped, irqs;
static volatile int errors;

static void uart_isr(const struct device *dev, void *user_data)
{
	uint8_t buf[256];

	irqs++;
	while (uart_irq_update(dev) && uart_irq_is_pending(dev)) {
		/* send what is still waiting first, keeping the order */
		while (!ring_buf_is_empty(&pending)) {
			uint8_t *p;
			uint32_t n = ring_buf_get_claim(&pending, &p, sizeof(buf));
			int sent = uart_fifo_fill(dev, p, n);

			ring_buf_get_finish(&pending, sent);
			tx_bytes += sent;
			if (sent < n) {
				break;
			}
		}
		if (ring_buf_is_empty(&pending)) {
			uart_irq_tx_disable(dev);
		}

		if (uart_irq_rx_ready(dev)) {
			int n = uart_fifo_read(dev, buf, sizeof(buf));
			int sent = 0;

			rx_bytes += n;
			if (ring_buf_is_empty(&pending)) {
				sent = uart_fifo_fill(dev, buf, n);
				tx_bytes += sent;
			}
			if (sent < n) {
				uint32_t put = ring_buf_put(&pending, buf + sent, n - sent);

				dropped += (n - sent) - put;
				uart_irq_tx_enable(dev);
			}
		} else if (ring_buf_is_empty(&pending)) {
			break;
		}
	}
}

int main(void)
{
	struct uart_config cfg;

	if (!device_is_ready(uart)) {
		printk("uart1 not ready\n");
		return 0;
	}
	uart_config_get(uart, &cfg);
	if (JTAG_UART_WSPACE() >= 64) {
		printk("uart_fifo_test: echo, %u baud, CPU %u Hz\n", cfg.baudrate,
		       (unsigned int)sys_clock_hw_cycles_per_sec());
	}

	uart_irq_callback_set(uart, uart_isr);
	uart_irq_rx_enable(uart);

	uint32_t last_rx = 0, reported_rx = 0;

	for (;;) {
		k_msleep(1000);
		int err = uart_err_check(uart);

		if (err) {
			errors |= err;
		}
		uint32_t rx = rx_bytes;

		/* only once the traffic has stopped, and only if the line fits
		 * the JTAG UART's FIFO: printk there waits with interrupts locked
		 * while the FIFO drains to the host - long enough for the 2 KB RX
		 * FIFO to overflow at 4.8 MBaud, forever with no host
		 */
		if (rx == last_rx && rx != reported_rx && JTAG_UART_WSPACE() >= 64) {
			printk("rx %u tx %u dropped %u irqs %u errors 0x%x\n", rx, tx_bytes, dropped,
			       irqs, errors);
			reported_rx = rx;
			errors = 0;
		}
		last_rx = rx;
	}
	return 0;
}
