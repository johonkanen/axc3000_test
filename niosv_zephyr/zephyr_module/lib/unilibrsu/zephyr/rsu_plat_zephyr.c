/* SPDX-License-Identifier: Apache-2.0 */
/*
 * uniLibRSU's platform layer on the AXC3000 (lib/unilibrsu/README.md):
 *
 *   OSAL     the C library's malloc, k_mutex
 *   logging  Zephyr logging (module uniLibRSU, rsu_plat_log.c)
 *   crc32    Zephyr's crc32_ieee_update (zlib's crc32)
 *   file     only the built-in configuration "file" (no file system)
 *   qspi     the QSPI flash driver (axc3000,sdm-qspi), absolute flash
 *            addresses; writes and erases only inside the devicetree
 *            partitions rsu_tables_partition (SPT/CPB) and rsu_p1/p2 -
 *            never BOOT_INFO, the factory image or the MCUboot slots
 *   mailbox  the SDM's RSU commands (<axc3000/sdm_rsu.h>)
 *   misc     DCMF status/version, max retry: not available, -ENOTSUP
 */
#include <string.h>
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/flash.h>
#include <zephyr/storage/flash_map.h>
#include <zephyr/sys/crc.h>
#include <axc3000/sdm_rsu.h>

#include <libRSU_OSAL.h>
#include <hal/RSU_plat_crc32.h>
#include <hal/RSU_plat_file.h>
#include <hal/RSU_plat_mailbox.h>
#include <hal/RSU_plat_misc.h>
#include <hal/RSU_plat_qspi.h>
#include <utils/RSU_logging.h>
#include <version.h>

const RSU_OSAL_CHAR *kGitHash = "21b64b1";
const RSU_OSAL_U32 rsu_poc_verion_major = RSU_POC_VERSION_MAJOR;
const RSU_OSAL_U32 rsu_poc_verion_minor = RSU_POC_VERSION_MINOR;

/* ---- OSAL ---- */

RSU_OSAL_VOID *rsu_malloc(RSU_OSAL_SIZE size)
{
	return malloc(size);
}

RSU_OSAL_VOID rsu_free(RSU_OSAL_VOID *ptr)
{
	free(ptr);
}

RSU_OSAL_VOID *rsu_memset(RSU_OSAL_VOID *s, RSU_OSAL_U8 c, RSU_OSAL_SIZE n)
{
	return memset(s, c, n);
}

RSU_OSAL_VOID *rsu_memcpy(RSU_OSAL_VOID *d, RSU_OSAL_VOID *s, RSU_OSAL_SIZE n)
{
	return memcpy(d, s, n);
}

RSU_OSAL_INT rsu_mutex_init(RSU_OSAL_MUTEX *mutex)
{
	return k_mutex_init(mutex);
}

RSU_OSAL_INT rsu_mutex_timedlock(RSU_OSAL_MUTEX *mutex, RSU_OSAL_U32 const time)
{
	k_timeout_t t = time == RSU_TIME_FOREVER ? K_FOREVER : K_MSEC(time);

	return k_mutex_lock(mutex, t);
}

RSU_OSAL_INT rsu_mutex_unlock(RSU_OSAL_MUTEX *mutex)
{
	return k_mutex_unlock(mutex);
}

RSU_OSAL_INT rsu_mutex_destroy(RSU_OSAL_MUTEX *mutex)
{
	ARG_UNUSED(mutex);
	return 0;
}

/* ---- logging (RSU_LOG_* map to LOG_*; RSU_logger for the rest) ---- */

RSU_OSAL_INT RSU_set_logging(rsu_loglevel_t level)
{
	ARG_UNUSED(level);
	return 0;
}

RSU_OSAL_INT RSU_logging_init(RSU_OSAL_CHAR *cfg_file)
{
	ARG_UNUSED(cfg_file);
	return 0;
}

RSU_OSAL_VOID RSU_logging_exit(RSU_OSAL_VOID)
{
}

RSU_OSAL_VOID RSU_logger(rsu_loglevel_t level, const RSU_OSAL_CHAR *format, ...)
{
	va_list ap;

	if (level > L_LOG_LVL) {
		return;
	}
	va_start(ap, format);
	vprintk(format, ap);
	va_end(ap);
	printk("\n");
}

/* ---- crc32 ---- */

RSU_OSAL_U32 rsu_crc32(RSU_OSAL_U32 crc, const RSU_OSAL_U8 *data, RSU_OSAL_SIZE len)
{
	return crc32_ieee_update(crc, data, len);
}

/* ---- file: only the configuration, built in ---- */

#define RSU_PLAT_CFG_NAME "librsu.rc"

/* librsu_init(NULL) opens DEFAULT_CFG_FILENAME (CMakeLists.txt) */
static const char rsu_plat_cfg[] =
	"# uniLibRSU configuration (lib/unilibrsu/zephyr/rsu_plat_zephyr.c)\n"
	"rsu-spt-checksum 1\n";

struct rsu_plat_file {
	size_t pos;
};

static struct rsu_plat_file cfg_file;

static RSU_OSAL_FILE *file_open(RSU_OSAL_CHAR *filename, RSU_filesys_flags_t flag)
{
	if (flag != RSU_FILE_READ || strcmp(filename, RSU_PLAT_CFG_NAME) != 0) {
		RSU_LOG_ERR("no file system: '%s'", filename);
		return NULL;
	}
	cfg_file.pos = 0;
	return &cfg_file;
}

static RSU_OSAL_INT file_read(RSU_OSAL_VOID *buf, RSU_OSAL_SIZE len, RSU_OSAL_FILE *file)
{
	size_t n = MIN(len, sizeof(rsu_plat_cfg) - 1 - file->pos);

	memcpy(buf, rsu_plat_cfg + file->pos, n);
	file->pos += n;
	return n;
}

static RSU_OSAL_INT file_write(RSU_OSAL_VOID *buf, RSU_OSAL_SIZE len, RSU_OSAL_FILE *file)
{
	return -ENOTSUP;
}

/* 0 with a line in str, nonzero at the end */
static RSU_OSAL_INT file_fgets(RSU_OSAL_CHAR *str, RSU_OSAL_SIZE len, RSU_OSAL_FILE *file)
{
	size_t n = 0;

	if (file->pos >= sizeof(rsu_plat_cfg) - 1 || len < 2) {
		return -1;
	}
	while (n < len - 1 && file->pos < sizeof(rsu_plat_cfg) - 1) {
		char c = rsu_plat_cfg[file->pos++];

		str[n++] = c;
		if (c == '\n') {
			break;
		}
	}
	str[n] = '\0';
	return 0;
}

static RSU_OSAL_INT file_fseek(RSU_OSAL_OFFSET offset, RSU_filesys_whence_t whence,
			       RSU_OSAL_FILE *file)
{
	return -ENOTSUP;
}

static RSU_OSAL_INT file_ftruncate(RSU_OSAL_OFFSET length, RSU_OSAL_FILE *file)
{
	return -ENOTSUP;
}

static RSU_OSAL_INT file_close(RSU_OSAL_FILE *file)
{
	return 0;
}

static RSU_OSAL_INT file_terminate(RSU_OSAL_VOID)
{
	return 0;
}

RSU_OSAL_INT plat_filesys_init(struct filesys_ll_intf *filesys_intf)
{
	filesys_intf->open = file_open;
	filesys_intf->read = file_read;
	filesys_intf->write = file_write;
	filesys_intf->fgets = file_fgets;
	filesys_intf->fseek = file_fseek;
	filesys_intf->ftruncate = file_ftruncate;
	filesys_intf->close = file_close;
	filesys_intf->terminate = file_terminate;
	return 0;
}

/* ---- QSPI ---- */

static const struct device *const qspi_flash = DEVICE_DT_GET(DT_NODELABEL(qspi));

/* where librsu may write and erase: the SPT/CPB tables and the slots */
static const struct {
	off_t start;
	size_t size;
} writable[] = {
	{DT_REG_ADDR(DT_NODELABEL(rsu_tables_partition)),
	 DT_REG_SIZE(DT_NODELABEL(rsu_tables_partition))},
	{DT_REG_ADDR(DT_NODELABEL(rsu_p1_partition)),
	 DT_REG_SIZE(DT_NODELABEL(rsu_p1_partition))},
	{DT_REG_ADDR(DT_NODELABEL(rsu_p2_partition)),
	 DT_REG_SIZE(DT_NODELABEL(rsu_p2_partition))},
};

static bool may_write(off_t offset, size_t len)
{
	for (size_t i = 0; i < ARRAY_SIZE(writable); i++) {
		if (offset >= writable[i].start &&
		    offset + len <= writable[i].start + writable[i].size) {
			return true;
		}
	}
	return false;
}

static RSU_OSAL_INT qspi_read(RSU_OSAL_OFFSET offset, RSU_OSAL_VOID *data, RSU_OSAL_SIZE len)
{
	int ret = flash_read(qspi_flash, offset, data, len);

	if (ret) {
		RSU_LOG_ERR("read 0x%08lx +%u: %d", (long)offset, (unsigned int)len, ret);
	}
	return ret;
}

static RSU_OSAL_INT qspi_write(RSU_OSAL_OFFSET offset, const RSU_OSAL_VOID *data,
			       RSU_OSAL_SIZE len)
{
	int ret;

	if (!may_write(offset, len)) {
		RSU_LOG_ERR("refused: write 0x%08lx +%u", (long)offset, (unsigned int)len);
		return -EACCES;
	}
	RSU_LOG_DBG("write 0x%08lx +%u", (long)offset, (unsigned int)len);
	ret = flash_write(qspi_flash, offset, data, len);
	if (ret) {
		RSU_LOG_ERR("write 0x%08lx +%u: %d", (long)offset, (unsigned int)len, ret);
	}
	return ret;
}

static RSU_OSAL_INT qspi_erase(RSU_OSAL_OFFSET offset, RSU_OSAL_SIZE len)
{
	int ret;

	if (!may_write(offset, len)) {
		RSU_LOG_ERR("refused: erase 0x%08lx +%u", (long)offset, (unsigned int)len);
		return -EACCES;
	}
	RSU_LOG_INF("erase 0x%08lx +0x%x", (long)offset, (unsigned int)len);
	ret = flash_erase(qspi_flash, offset, len);
	if (ret) {
		RSU_LOG_ERR("erase 0x%08lx +%u: %d", (long)offset, (unsigned int)len, ret);
	}
	return ret;
}

static RSU_OSAL_INT qspi_terminate(RSU_OSAL_VOID)
{
	return 0;
}

RSU_OSAL_INT plat_qspi_init(struct qspi_ll_intf *qspi_intf, RSU_OSAL_CHAR *config_file)
{
	ARG_UNUSED(config_file);
	if (!device_is_ready(qspi_flash)) {
		RSU_LOG_ERR("QSPI flash not ready");
		return -ENODEV;
	}
	qspi_intf->read = qspi_read;
	qspi_intf->write = qspi_write;
	qspi_intf->erase = qspi_erase;
	qspi_intf->terminate = qspi_terminate;
	return 0;
}

/* ---- mailbox ---- */

static RSU_OSAL_INT mbox_get_rsu_status(struct mbox_status_info *data)
{
	uint32_t st[9];
	int ret = axc3000_sdm_rsu_status(st);

	if (ret) {
		return ret;
	}
	/* RSU_STATUS: addresses low word first */
	data->current_image = ((uint64_t)st[1] << 32) | st[0];
	data->fail_image = ((uint64_t)st[3] << 32) | st[2];
	data->state = st[4];
	data->version = st[5];
	data->error_location = st[6];
	data->error_details = st[7];
	data->retry_counter = st[8];
	return 0;
}

static RSU_OSAL_INT mbox_send_rsu_update(RSU_OSAL_U64 addr)
{
	/* Linux sets this for the next reboot; here it reconfigures now and
	 * returns only if the SDM refuses
	 */
	return axc3000_sdm_rsu_image_update(addr);
}

static RSU_OSAL_INT mbox_get_spt_addresses(struct mbox_data_rsu_spt_address *data)
{
	uint32_t spt[4];
	int ret = axc3000_sdm_rsu_get_spt(spt);

	if (ret) {
		return ret;
	}
	/* RSU_GET_SPT: high word first */
	data->spt0_address = ((uint64_t)spt[0] << 32) | spt[1];
	data->spt1_address = ((uint64_t)spt[2] << 32) | spt[3];
	RSU_LOG_DBG("SPT0 0x%llx, SPT1 0x%llx", data->spt0_address, data->spt1_address);
	return 0;
}

static RSU_OSAL_INT mbox_rsu_notify(RSU_OSAL_U32 notify)
{
	return axc3000_sdm_rsu_notify(notify);
}

static RSU_OSAL_INT mbox_terminate(RSU_OSAL_VOID)
{
	return 0;
}

RSU_OSAL_INT plat_mbox_init(struct mbox_ll_intf *mbox_intf, RSU_OSAL_CHAR *config_file)
{
	ARG_UNUSED(config_file);
	mbox_intf->get_rsu_status = mbox_get_rsu_status;
	mbox_intf->send_rsu_update = mbox_send_rsu_update;
	mbox_intf->get_spt_addresses = mbox_get_spt_addresses;
	mbox_intf->rsu_notify = mbox_rsu_notify;
	mbox_intf->terminate = mbox_terminate;
	return 0;
}

/* ---- misc: not available through the mailbox client ---- */

static RSU_OSAL_INT misc_dcmf_status(struct rsu_dcmf_status *data)
{
	return -ENOTSUP;
}

static RSU_OSAL_INT misc_max_retry(RSU_OSAL_U8 *rsu_max_retry)
{
	return -ENOTSUP;
}

static RSU_OSAL_INT misc_dcmf_version(struct rsu_dcmf_version *version)
{
	return -ENOTSUP;
}

static RSU_OSAL_INT misc_terminate(RSU_OSAL_VOID)
{
	return 0;
}

RSU_OSAL_INT plat_rsu_misc_init(struct rsu_ll_misc *misc_intf, RSU_OSAL_CHAR *config_file)
{
	ARG_UNUSED(config_file);
	misc_intf->rsu_get_dcmf_status = misc_dcmf_status;
	misc_intf->rsu_get_max_retry_count = misc_max_retry;
	misc_intf->rsu_get_dcmf_version = misc_dcmf_version;
	misc_intf->terminate = misc_terminate;
	return 0;
}
