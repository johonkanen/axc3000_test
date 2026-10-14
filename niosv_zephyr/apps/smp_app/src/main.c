/* The updatable application: prints its version, and serves mcumgr (SMP) on
 * the FTDI UART - image upload into the QSPI flash slots, reset. Reset is a
 * reconfiguration from the running bitstream (zephyr_module), which brings
 * MCUboot back; MCUboot then RAM-loads the newer of the two slots.
 */
#include <zephyr/kernel.h>

int main(void)
{
	for (int n = 0;; n++) {
		printk("smp_app %s running (%d)\n", APP_VERSION, n);
		k_msleep(2000);
	}
	return 0;
}
