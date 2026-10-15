/* SPDX-License-Identifier: Apache-2.0 */
/*
 * uniLibRSU's OS abstraction types (libRSU_OSAL.h) on Zephyr. Upstream's
 * Zephyr platform files live in Altera's internal Zephyr tree; this is the
 * AXC3000 one (lib/unilibrsu/README.md).
 */
#ifndef RSU_OSAL_TYPES_H
#define RSU_OSAL_TYPES_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <errno.h>
#include <sys/types.h>
#include <zephyr/kernel.h>

typedef uint64_t RSU_OSAL_U64;
typedef uint32_t RSU_OSAL_U32;
typedef uint16_t RSU_OSAL_U16;
typedef uint8_t RSU_OSAL_U8;

typedef int64_t RSU_OSAL_S64;
typedef int32_t RSU_OSAL_S32;
typedef int16_t RSU_OSAL_S16;
typedef int8_t RSU_OSAL_S8;

typedef void RSU_OSAL_VOID;
typedef char RSU_OSAL_CHAR;
typedef bool RSU_OSAL_BOOL;

typedef int RSU_OSAL_INT;
typedef off_t RSU_OSAL_OFFSET;
typedef size_t RSU_OSAL_SIZE;

typedef struct k_mutex RSU_OSAL_MUTEX;
/* the only "file" is the built-in configuration (rsu_plat_zephyr.c) */
typedef struct rsu_plat_file RSU_OSAL_FILE;

#endif
