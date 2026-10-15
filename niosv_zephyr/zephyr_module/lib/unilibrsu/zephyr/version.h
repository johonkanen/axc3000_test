/* SPDX-License-Identifier: Apache-2.0 */
/*
 * uniLibRSU's version.h (upstream generates it from version/version.h.in).
 * Zephyr's generated <version.h> (the kernel version) has the same name and
 * comes first on the include path: take it, then add uniLibRSU's.
 */
#include_next <version.h>

#ifndef UNILIBRSU_VERSION_H
#define UNILIBRSU_VERSION_H

#include <libRSU_OSAL.h>

#define RSU_POC_VERSION_MAJOR 1
#define RSU_POC_VERSION_MINOR 0

extern const RSU_OSAL_CHAR *kGitHash;
extern const RSU_OSAL_U32 rsu_poc_verion_major;
extern const RSU_OSAL_U32 rsu_poc_verion_minor;

#endif
