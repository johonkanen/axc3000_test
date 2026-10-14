/* SPDX-License-Identifier: BSD-2-Clause */
/* librsu on Zephyr: the two MTD structures librsu_ll.h uses (no MTD here) */
#ifndef LIBRSU_COMPAT_MTD_USER_H
#define LIBRSU_COMPAT_MTD_USER_H
#include <stdint.h>
struct mtd_info_user {
	uint32_t size;
	uint32_t erasesize;
};
struct erase_info_user {
	uint32_t start;
	uint32_t length;
};
#endif
