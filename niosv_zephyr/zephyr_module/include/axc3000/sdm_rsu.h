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
 * the failing image's address (0 if none), [4] error code, [5] error
 * location, [6] version, [7] error details, [8] retry counter
 */
int axc3000_sdm_rsu_status(uint32_t status[9]);

/* RSU_IMAGE_UPDATE: reconfigure the device from the image at flash_address
 * (returns only if the SDM refuses)
 */
int axc3000_sdm_rsu_image_update(uint64_t flash_address);

#endif
