/*
 * The AXC3000's QSPI configuration flash, through the SDM mailbox
 * (Intel/Altera "Mailbox Client" IP, intel_mailbox_client). The flash belongs
 * to the SDM; the FPGA reaches it with mailbox commands: QSPI_OPEN (exclusive
 * access), QSPI_SET_CS, QSPI_READ / QSPI_WRITE (at most 1024 words each),
 * QSPI_ERASE (4/32/64 KB sectors), QSPI_CLOSE. Protocol as Intel's Nios V HAL
 * driver (ip/altera/pgm/intel_mailbox_client/HAL/src/intel_mailbox_client*.c),
 * polled.
 *
 * Zephyr flash API: read anywhere, write in whole words (write-block-size 4)
 * to erased flash, erase in 4 KB pages (64 KB / 32 KB sectors where aligned).
 * The flash is opened at init and kept open.
 */
#define DT_DRV_COMPAT axc3000_sdm_qspi

#include <zephyr/device.h>
#include <zephyr/drivers/flash.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/sys_io.h>
#include <zephyr/logging/log.h>
#include <string.h>

LOG_MODULE_REGISTER(flash_axc3000_sdm_qspi, CONFIG_FLASH_LOG_LEVEL);

/* mailbox client registers */
#define MBOX_CMD        0x00
#define MBOX_EOP        0x04
#define MBOX_FIFO_EMPTY 0x08    /* command FIFO: non-zero = room */
#define MBOX_RSP_DATA   0x14
#define MBOX_FIFO_LVL   0x18    /* response FIFO: bit 0 SOP, bit 1 EOP, 31:2 words */
#define MBOX_IER        0x1c
#define MBOX_ISR        0x20

#define IRQ_DATA_VALID  BIT(0)
#define IRQ_CMD_INVALID BIT(3)
#define IRQ_EOP_TIMEOUT BIT(4)
#define IRQ_BACKP_TOUT  BIT(5)
#define IRQ_ERRORS      (IRQ_CMD_INVALID | IRQ_EOP_TIMEOUT | IRQ_BACKP_TOUT)

#define HDR(id, len, cmd) (((uint32_t)(id) << 24) | ((uint32_t)(len) << 12) | (cmd))
#define HDR_ERR(h)        ((h) & 0x7ff)
#define HDR_LEN(h)        (((h) >> 12) & 0x7ff)
#define HDR_ID(h)         (((h) >> 24) & 0xf)

#define CLIENT_ID 0x9            /* the HAL's MAILBOX_FLASH_ID */

#define QSPI_OPEN            0x32
#define QSPI_CLOSE           0x33
#define QSPI_SET_CS          0x34
#define QSPI_READ_DEVICE_REG 0x35
#define QSPI_ERASE           0x38
#define QSPI_WRITE           0x39
#define QSPI_READ            0x3a
#define RSU_STATUS           0x5b
#define RSU_IMAGE_UPDATE     0x5c

#define MAX_WORDS     1024       /* per QSPI_READ / QSPI_WRITE */
#define PAGE_SIZE     4096       /* smallest erase */
#define TIMEOUT_MS    10000                /* a 64 KB erase takes up to ~1 s */

struct sdm_qspi_config {
	mm_reg_t base;
	uint32_t size;
};

struct sdm_qspi_data {
	struct k_mutex lock;
	bool open;
	uint32_t buf[MAX_WORDS];
};

static const struct flash_parameters sdm_qspi_parameters = {
	.write_block_size = 4,
	.erase_value = 0xff,
	.caps = {
		.no_explicit_erase = false,
	},
};

static inline uint32_t rd(const struct device *dev, uint32_t off)
{
	const struct sdm_qspi_config *cfg = dev->config;

	return sys_read32(cfg->base + off);
}

static inline void wr(const struct device *dev, uint32_t off, uint32_t v)
{
	const struct sdm_qspi_config *cfg = dev->config;

	sys_write32(v, cfg->base + off);
}

/* Tight register polls against a cycle-counter deadline: a k_busy_wait()
 * per poll made 4 KB reads (1024 response words, drained through a 16-word
 * FIFO) take most of a second.
 */
static inline uint32_t deadline_cycles(void)
{
	return k_cycle_get_32() + (uint32_t)((uint64_t)TIMEOUT_MS * sys_clock_hw_cycles_per_sec() / 1000);
}

static inline bool expired(uint32_t deadline)
{
	return (int32_t)(k_cycle_get_32() - deadline) > 0;
}

static int wait_cmd_room(const struct device *dev)
{
	uint32_t deadline = deadline_cycles();

	while (rd(dev, MBOX_FIFO_EMPTY) == 0) {
		if (expired(deadline)) {
			return -ETIMEDOUT;
		}
	}
	return 0;
}

static int wait_rsp_words(const struct device *dev)
{
	uint32_t deadline = deadline_cycles();

	while ((rd(dev, MBOX_FIFO_LVL) >> 2) == 0) {
		if (expired(deadline)) {
			return -ETIMEDOUT;
		}
	}
	return 0;
}

/*
 * One mailbox command: args then data (args_n + data_n words; the last one
 * through EOP), then the response: its header, and up to resp_max words into
 * resp (the rest read and dropped). Returns 0, a negative errno, or -(SDM
 * error code) when the SDM reports one.
 */
static int mbox_cmd(const struct device *dev, uint32_t cmd, const uint32_t *args, int args_n,
		    const uint32_t *data, int data_n, uint32_t *resp, int resp_max)
{
	int len = args_n + data_n;
	uint32_t hdr, isr;
	int ret, i;

	wr(dev, MBOX_IER, IRQ_DATA_VALID | IRQ_ERRORS);

	ret = wait_cmd_room(dev);
	if (ret) {
		return ret;
	}
	wr(dev, len == 0 ? MBOX_EOP : MBOX_CMD, HDR(CLIENT_ID, len, cmd));
	for (i = 0; i < len; i++) {
		uint32_t w = i < args_n ? args[i] : data[i - args_n];

		ret = wait_cmd_room(dev);
		if (ret) {
			return ret;
		}
		wr(dev, i == len - 1 ? MBOX_EOP : MBOX_CMD, w);
	}

	/* the response: its start, or an error */
	uint32_t deadline = deadline_cycles();

	for (;;) {
		isr = rd(dev, MBOX_ISR);
		if (isr & IRQ_ERRORS) {
			LOG_ERR("mailbox command 0x%x: ISR 0x%x", cmd, isr);
			return -EIO;
		}
		if (rd(dev, MBOX_FIFO_LVL) & BIT(0)) {
			break;
		}
		if (expired(deadline)) {
			LOG_ERR("mailbox command 0x%x: no response", cmd);
			return -ETIMEDOUT;
		}
	}

	ret = wait_rsp_words(dev);
	if (ret) {
		return ret;
	}
	hdr = rd(dev, MBOX_RSP_DATA);
	for (i = 0; i < HDR_LEN(hdr); i++) {
		ret = wait_rsp_words(dev);
		if (ret) {
			return ret;
		}
		uint32_t w = rd(dev, MBOX_RSP_DATA);

		if (i < resp_max) {
			resp[i] = w;
		}
	}
	if (HDR_ERR(hdr)) {
		/* logged by the callers, where it is not expected */
		LOG_DBG("mailbox command 0x%x: SDM error 0x%x", cmd, HDR_ERR(hdr));
		return -(int)HDR_ERR(hdr);
	}
	if (HDR_ID(hdr) != CLIENT_ID) {
		return -EIO;
	}
	return 0;
}

static int sdm_qspi_open(const struct device *dev)
{
	struct sdm_qspi_data *data = dev->data;
	uint32_t cs = 0;
	uint32_t id_args[2] = {0xaf, 8};   /* read ID, 8 bytes - as the HAL does */
	uint32_t id[2] = {0, 0};
	int ret;

	if (data->open) {
		return 0;
	}
	/* A previous run may have been stopped mid-command (a debugger reset)
	 * or left the flash open: drop any response words still waiting, and
	 * close before opening (its error, if it was not open, is ignored).
	 */
	for (int i = 0; i < 4096 && (rd(dev, MBOX_FIFO_LVL) >> 2) != 0; i++) {
		(void)rd(dev, MBOX_RSP_DATA);
	}
	(void)mbox_cmd(dev, QSPI_CLOSE, NULL, 0, NULL, 0, NULL, 0);
	ret = mbox_cmd(dev, QSPI_OPEN, NULL, 0, NULL, 0, NULL, 0);
	if (ret) {
		LOG_ERR("QSPI_OPEN: %d", ret);
		return ret;
	}
	ret = mbox_cmd(dev, QSPI_SET_CS, &cs, 1, NULL, 0, NULL, 0);
	if (ret == 0) {
		ret = mbox_cmd(dev, QSPI_READ_DEVICE_REG, id_args, 2, NULL, 0, id, 2);
	}
	if (ret) {
		LOG_ERR("QSPI chip select / read ID: %d", ret);
		mbox_cmd(dev, QSPI_CLOSE, NULL, 0, NULL, 0, NULL, 0);
		return ret;
	}
	/* the HAL takes the capacity from bits 23:16 of the second word */
	LOG_INF("QSPI flash open, ID 0x%08x 0x%08x (capacity code 0x%02x)", id[0], id[1],
		(id[1] >> 16) & 0xff);
	data->open = true;
	return 0;
}

static bool in_range(const struct device *dev, off_t offset, size_t len)
{
	const struct sdm_qspi_config *cfg = dev->config;

	return offset >= 0 && (uint64_t)offset + len <= cfg->size;
}

static int sdm_qspi_read(const struct device *dev, off_t offset, void *dst, size_t len)
{
	struct sdm_qspi_data *data = dev->data;
	uint8_t *out = dst;
	int ret = 0;

	if (!in_range(dev, offset, len)) {
		return -EINVAL;
	}
	if (len == 0) {
		return 0;
	}
	k_mutex_lock(&data->lock, K_FOREVER);
	ret = sdm_qspi_open(dev);
	while (ret == 0 && len > 0) {
		uint32_t start = offset & ~3u;
		uint32_t skip = offset - start;
		uint32_t words = MIN((skip + len + 3) / 4, MAX_WORDS);
		uint32_t args[2] = {start, words};
		size_t n = MIN(len, words * 4 - skip);

		ret = mbox_cmd(dev, QSPI_READ, args, 2, NULL, 0, data->buf, words);
		if (ret == 0) {
			memcpy(out, (uint8_t *)data->buf + skip, n);
			out += n;
			offset += n;
			len -= n;
		}
	}
	k_mutex_unlock(&data->lock);
	if (ret) {
		LOG_ERR("read 0x%lx: %d", (long)offset, ret);
	}
	return ret;
}

static int sdm_qspi_write(const struct device *dev, off_t offset, const void *src, size_t len)
{
	struct sdm_qspi_data *data = dev->data;
	const uint8_t *in = src;
	int ret = 0;

	if (!in_range(dev, offset, len) || (offset & 3) || (len & 3)) {
		return -EINVAL;
	}
	k_mutex_lock(&data->lock, K_FOREVER);
	ret = sdm_qspi_open(dev);
	while (ret == 0 && len > 0) {
		uint32_t words = MIN(len / 4, MAX_WORDS);
		uint32_t args[2] = {(uint32_t)offset, words};

		memcpy(data->buf, in, words * 4);
		ret = mbox_cmd(dev, QSPI_WRITE, args, 2, data->buf, words, NULL, 0);
		in += words * 4;
		offset += words * 4;
		len -= words * 4;
	}
	k_mutex_unlock(&data->lock);
	if (ret) {
		LOG_ERR("write 0x%lx: %d", (long)offset, ret);
	}
	return ret;
}

static int sdm_qspi_erase(const struct device *dev, off_t offset, size_t size)
{
	struct sdm_qspi_data *data = dev->data;
	int ret;

	if (!in_range(dev, offset, size) || (offset % PAGE_SIZE) || (size % PAGE_SIZE)) {
		return -EINVAL;
	}
	k_mutex_lock(&data->lock, K_FOREVER);
	ret = sdm_qspi_open(dev);
	while (ret == 0 && size > 0) {
		/* the largest sector that fits the alignment and what is left */
		uint32_t sector = (offset % 0x10000 == 0 && size >= 0x10000) ? 0x10000 :
				  (offset % 0x8000 == 0 && size >= 0x8000) ? 0x8000 : PAGE_SIZE;
		uint32_t args[2] = {(uint32_t)offset, sector / 4};

		ret = mbox_cmd(dev, QSPI_ERASE, args, 2, NULL, 0, NULL, 0);
		offset += sector;
		size -= sector;
	}
	k_mutex_unlock(&data->lock);
	if (ret) {
		LOG_ERR("erase 0x%lx: %d", (long)offset, ret);
	}
	return ret;
}

static const struct flash_parameters *sdm_qspi_get_parameters(const struct device *dev)
{
	ARG_UNUSED(dev);
	return &sdm_qspi_parameters;
}

static int sdm_qspi_get_size(const struct device *dev, uint64_t *size)
{
	const struct sdm_qspi_config *cfg = dev->config;

	*size = cfg->size;
	return 0;
}

#if defined(CONFIG_FLASH_PAGE_LAYOUT)
static void sdm_qspi_page_layout(const struct device *dev,
				 const struct flash_pages_layout **layout, size_t *layout_size)
{
	const struct sdm_qspi_config *cfg = dev->config;
	static struct flash_pages_layout pages;

	pages.pages_size = PAGE_SIZE;
	pages.pages_count = cfg->size / PAGE_SIZE;
	*layout = &pages;
	*layout_size = 1;
}
#endif

static DEVICE_API(flash, sdm_qspi_api) = {
	.read = sdm_qspi_read,
	.write = sdm_qspi_write,
	.erase = sdm_qspi_erase,
	.get_parameters = sdm_qspi_get_parameters,
	.get_size = sdm_qspi_get_size,
#if defined(CONFIG_FLASH_PAGE_LAYOUT)
	.page_layout = sdm_qspi_page_layout,
#endif
};

/* RSU through the same mailbox (axc3000/sdm_rsu.h) */
int axc3000_sdm_rsu_status(uint32_t status[9])
{
	const struct device *dev = DEVICE_DT_INST_GET(0);
	struct sdm_qspi_data *data = dev->data;
	int ret;

	k_mutex_lock(&data->lock, K_FOREVER);
	if (data->open) {
		(void)mbox_cmd(dev, QSPI_CLOSE, NULL, 0, NULL, 0, NULL, 0);
		data->open = false;
	}
	ret = mbox_cmd(dev, RSU_STATUS, NULL, 0, NULL, 0, status, 9);
	k_mutex_unlock(&data->lock);
	return ret;
}

int axc3000_sdm_rsu_image_update(uint64_t flash_address)
{
	const struct device *dev = DEVICE_DT_INST_GET(0);
	struct sdm_qspi_data *data = dev->data;
	uint32_t args[2] = {(uint32_t)flash_address, (uint32_t)(flash_address >> 32)};
	int ret;

	k_mutex_lock(&data->lock, K_FOREVER);
	if (data->open) {
		(void)mbox_cmd(dev, QSPI_CLOSE, NULL, 0, NULL, 0, NULL, 0);
		data->open = false;
	}
	ret = mbox_cmd(dev, RSU_IMAGE_UPDATE, args, 2, NULL, 0, NULL, 0);
	k_mutex_unlock(&data->lock);
	return ret;
}

#if defined(CONFIG_AXC3000_SDM_REBOOT)
/*
 * Reboot = reconfigure the FPGA from the bitstream that is running (the SDM's
 * RSU_IMAGE_UPDATE with RSU_STATUS's current image address). A CPU-only
 * restart would not do: MCUboot lives in the on-chip RAM's initial contents,
 * which the application has since overwritten - reconfiguration reloads
 * them. Only when RSU_STATUS fails (e.g. no RSU image in the flash) is it a
 * plain jump to the reset vector.
 */
void sys_arch_reboot(int type)
{
	const struct device *dev = DEVICE_DT_INST_GET(0);
	struct sdm_qspi_data *data = dev->data;
	uint32_t status[9] = {0};
	int ret;

	ARG_UNUSED(type);
	(void)irq_lock();

	/* the SDM needs the flash itself */
	if (data->open) {
		(void)mbox_cmd(dev, QSPI_CLOSE, NULL, 0, NULL, 0, NULL, 0);
		data->open = false;
	}
	ret = mbox_cmd(dev, RSU_STATUS, NULL, 0, NULL, 0, status, ARRAY_SIZE(status));
	if (ret == 0) {
		uint32_t image[2] = {status[0], status[1]};   /* its flash address, 64-bit */

		(void)mbox_cmd(dev, RSU_IMAGE_UPDATE, image, 2, NULL, 0, NULL, 0);
		/* the SDM reconfigures the device: this code is gone in a moment */
		for (;;) {
		}
	}

	extern void __start(void);

	__start();
}
#endif

static int sdm_qspi_init(const struct device *dev)
{
	struct sdm_qspi_data *data = dev->data;

	k_mutex_init(&data->lock);
	/* opened on first use: the SDM may still be busy right after boot */
	return 0;
}

#define FLASH_NODE(n) DT_INST_CHILD(n, flash_0)

#define SDM_QSPI_INIT(n)                                                            \
	static const struct sdm_qspi_config sdm_qspi_config_##n = {                 \
		.base = DT_INST_REG_ADDR(n),                                        \
		.size = DT_REG_SIZE(FLASH_NODE(n)),                                 \
	};                                                                          \
	static struct sdm_qspi_data sdm_qspi_data_##n;                              \
	DEVICE_DT_INST_DEFINE(n, sdm_qspi_init, NULL, &sdm_qspi_data_##n,           \
			      &sdm_qspi_config_##n, POST_KERNEL,                    \
			      CONFIG_FLASH_INIT_PRIORITY, &sdm_qspi_api);

DT_INST_FOREACH_STATUS_OKAY(SDM_QSPI_INIT)
