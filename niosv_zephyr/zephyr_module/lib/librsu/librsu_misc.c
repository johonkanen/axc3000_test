// SPDX-License-Identifier: BSD-2-Clause

/* Intel Copyright 2018 */

#ifndef __ZEPHYR__
#include <fcntl.h>
#endif
#include "librsu_cfg.h"
#include "librsu_misc.h"
#include <stdlib.h>
#include <string.h>
#ifndef __ZEPHYR__
#include <sys/stat.h>
#include <unistd.h>
#endif

static char *reserved_names[] = {
	"BOOT_INFO",
	"FACTORY_IMAGE",
	"SPT",
	"SPT0",
	"SPT1",
	"CPB",
	"CPB0",
	"CPB1",
	""	/* Terminating table entry */
};

int librsu_misc_is_rsvd_name(char *name)
{
	int x;

	for (x = 0; reserved_names[x][0] != '\0'; x++)
		if (strcmp(name, reserved_names[x]) == 0)
			return 1;

	return 0;
}

int librsu_misc_is_slot(struct librsu_ll_intf *ll_intf, int part_num)
{
	if (ll_intf->partition.readonly(part_num) ||
	    ll_intf->partition.reserved(part_num))
		return 0;

	if (librsu_misc_is_rsvd_name(ll_intf->partition.name(part_num)))
		return 0;

	return 1;
}

int librsu_misc_slot2part(struct librsu_ll_intf *ll_intf, int slot)
{
	int partitions;
	int cnt = 0;
	int x;

	partitions = ll_intf->partition.count();

	for (x = 0; x < partitions; x++) {
		if (librsu_misc_is_slot(ll_intf, x)) {
			if (slot == cnt)
				return x;
			cnt++;
		}
	}

	return -1;
}

#ifdef __ZEPHYR__
/*
 * On Linux these are the stratix10-rsu driver's sysfs attributes; here the
 * same values straight from the SDM (zephyr_module's axc3000/sdm_rsu.h).
 * RSU_STATUS: [0..1] current image, [2..3] failing image, [4] state,
 * [5] version, [6] error location, [7] error details, [8] retry counter.
 */
#include <axc3000/sdm_rsu.h>

static __u64 word64(const uint32_t *w)
{
	return ((__u64)w[1] << 32) | w[0];
}

int librsu_misc_get_devattr(char *attr, __u64 *value)
{
	uint32_t st[9] = {0};
	uint32_t spt[4] = {0};

	if (strcmp(attr, "spt0_address") == 0 || strcmp(attr, "spt1_address") == 0) {
		if (axc3000_sdm_rsu_get_spt(spt))
			return -1;
		/* RSU_GET_SPT gives the high word first (RSU_STATUS: low first) */
		const uint32_t *w = attr[3] == '0' ? &spt[0] : &spt[2];

		*value = ((__u64)w[0] << 32) | w[1];
		return 0;
	}

	if (axc3000_sdm_rsu_status(st))
		return -1;
	if (strcmp(attr, "current_image") == 0)
		*value = word64(&st[0]);
	else if (strcmp(attr, "fail_image") == 0)
		*value = word64(&st[2]);
	else if (strcmp(attr, "state") == 0)
		*value = st[4];
	else if (strcmp(attr, "version") == 0)
		*value = st[5];
	else if (strcmp(attr, "error_location") == 0)
		*value = st[6];
	else if (strcmp(attr, "error_details") == 0)
		*value = st[7];
	else if (strcmp(attr, "retry_counter") == 0)
		*value = st[8];
	else {
		/* max_retry, dcmfN, dcmfN_status: not available here */
		librsu_log(HIGH, __func__, "attribute '%s' not supported", attr);
		return -1;
	}
	return 0;
}

int librsu_misc_put_devattr(char *attr, __u64 value)
{
	if (strcmp(attr, "reboot_image") == 0) {
		/* Linux: load this image at the next reboot; here: now */
		return axc3000_sdm_rsu_image_update(value) ? -1 : 0;
	}
	if (strcmp(attr, "notify") == 0)
		return axc3000_sdm_rsu_notify((uint32_t)value) ? -1 : 0;

	librsu_log(HIGH, __func__, "attribute '%s' not supported", attr);
	return -1;
}

#else /* upstream: sysfs */

int librsu_misc_get_devattr(char *attr, __u64 *value)
{
	FILE *attr_file;
	char *buf;
	int size = 256;

	buf = (char *)calloc(1, size);
	if (!buf) {
		librsu_log(LOW, __func__,
			   "error: failed to alloc buf\n");
		return -1;
	}

	strncat(buf, librsu_cfg_get_rsu_dev(), size - strlen(buf) - 1);
	strncat(buf, "/", size - strlen(buf) - 1);
	strncat(buf, attr, size - strlen(buf) - 1);

	attr_file = fopen(buf, "r");
	if (!attr_file) {
		librsu_log(LOW, __func__,
			   "error: Unable to open device attribute file '%s'",
			   buf);
		free(buf);
		return -1;
	}

	if (fgets(buf, size, attr_file)) {
		*value = strtol(buf, NULL, 0);
		fclose(attr_file);
		free(buf);
		return 0;
	}

	fclose(attr_file);
	free(buf);
	return -1;
}

int librsu_misc_put_devattr(char *attr, __u64 value)
{
	FILE *attr_file;
	char *buf;
	int size = 256;

	buf = (char *)calloc(1, size);
	if (!buf) {
		librsu_log(LOW, __func__,
			   "error: failed to alloc buf\n");
		return -1;
	}

	strncat(buf, librsu_cfg_get_rsu_dev(), size - strlen(buf) - 1);
	strncat(buf, "/", size - strlen(buf) - 1);
	strncat(buf, attr, size - strlen(buf) - 1);

	attr_file = fopen(buf, "w");
	if (!attr_file) {
		librsu_log(LOW, __func__,
			   "error: Unable to open device attribute file '%s'",
			   buf);
		free(buf);
		return -1;
	}

	snprintf(buf, size, "%lli", value);

	if (fputs(buf, attr_file) > 0) {
		fclose(attr_file);
		free(buf);
		return 0;
	}

	fclose(attr_file);
	free(buf);
	return -1;
}

#endif /* __ZEPHYR__ */
