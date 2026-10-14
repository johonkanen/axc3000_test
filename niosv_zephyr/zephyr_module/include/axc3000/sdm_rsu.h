/*
 * The SDM's Remote System Update commands, through the QSPI flash driver's
 * mailbox (drivers/flash/flash_axc3000_sdm_qspi.c). Both close the driver's
 * QSPI access first - the SDM needs the flash; the driver reopens on its next
 * use.
 */
#ifndef AXC3000_SDM_RSU_H_
#define AXC3000_SDM_RSU_H_

#include <stdint.h>

/* RSU_STATUS: 9 words - [0..1] the running image's flash address, [2..3]
 * the failing image's address (0 if none), [4] state (error code), [5]
 * version, [6] error location, [7] error details, [8] retry counter
 */
int axc3000_sdm_rsu_status(uint32_t status[9]);

/* RSU_GET_SPT: [0..1] SPT0's flash address, [2..3] SPT1's - high word first
 * (unlike RSU_STATUS's addresses, low word first)
 */
int axc3000_sdm_rsu_get_spt(uint32_t spt[4]);

/* RSU_NOTIFY: a value / flags for the SDM (librsu's rsu_notify()) */
int axc3000_sdm_rsu_notify(uint32_t value);

/* RSU_IMAGE_UPDATE: reconfigure the device from the image at flash_address
 * (returns only if the SDM refuses)
 */
int axc3000_sdm_rsu_image_update(uint64_t flash_address);

#endif
