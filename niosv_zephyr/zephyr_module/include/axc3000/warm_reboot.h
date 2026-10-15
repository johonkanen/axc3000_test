/*
 * Warm reboot: restart MCUboot without reconfiguring the FPGA
 * (src/warm_reboot.c). sys_reboot(SYS_REBOOT_WARM) uses it when possible.
 */
#ifndef AXC3000_WARM_REBOOT_H_
#define AXC3000_WARM_REBOOT_H_

#include <stdbool.h>
#include <zephyr/toolchain.h>

/* the MCUboot in the on-chip RAM is restartable (it set the boot flags) */
bool axc3000_warm_reboot_possible(void);

/* jump to the reset vector, MCUboot - call with the devices quiet */
FUNC_NORETURN void axc3000_warm_reboot(void);

#endif
