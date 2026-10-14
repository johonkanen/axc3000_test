/* SPDX-License-Identifier: BSD-2-Clause */
/* librsu on Zephyr: zlib's crc32() is the IEEE CRC-32, as Zephyr's */
#ifndef LIBRSU_COMPAT_ZLIB_H
#define LIBRSU_COMPAT_ZLIB_H
#include <stddef.h>
#include <stdint.h>
#include <zephyr/sys/crc.h>
static inline unsigned long crc32(unsigned long crc, const unsigned char *buf, unsigned int len)
{
	return crc32_ieee_update((uint32_t)crc, buf, len);
}
#endif
