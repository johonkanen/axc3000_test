/*
 * AXC3000 onboard HyperRAM - see zephyr_module/src/hyperram.c.
 */
#ifndef AXC3000_HYPERRAM_H_
#define AXC3000_HYPERRAM_H_

#include <zephyr/kernel.h>
#include <zephyr/devicetree.h>
#include <zephyr/linker/devicetree_regions.h>
#include <zephyr/toolchain.h>
#include <stdbool.h>
#include <zephyr/sys/util.h>

/* places a static object in the HyperRAM: NOLOAD, so it is neither loaded
 * nor zeroed - it holds whatever the memory held
 */
#define HYPERRAM_SECTION Z_GENERIC_SECTION(LINKER_DT_NODE_REGION_NAME(DT_NODELABEL(hyperram)))

#define HYPERRAM_BASE DT_REG_ADDR(DT_NODELABEL(hyperram))
#define HYPERRAM_SIZE DT_REG_SIZE(DT_NODELABEL(hyperram))

/* the HyperRAM not taken by HYPERRAM_SECTION objects; usable once
 * hyperram_ready() is true
 */
extern struct k_heap hyperram_heap;

/* calibration passed at boot and hyperram_heap is set up */
bool hyperram_ready(void);

/* hyperram_axi's status word (hVHDL_memory_library hyperram_core.vhd, the
 * relative read clock phase this board's PLL has): bit 0 calibrated, bit 1
 * failed (no passing window of g_min_window steps, or a step not
 * acknowledged), bit 2 the selected order of the input halves, bit 3 a step
 * not acknowledged, 11:4 the selected step (52 ps each, 192 a period), 19:12
 * its window's width in steps, 27:20 the other order's widest window
 */
uint32_t hyperram_status(void);

#define HYPERRAM_STATUS_CALIBRATED   BIT(0)
#define HYPERRAM_STATUS_FAILED       BIT(1)
#define HYPERRAM_STATUS_STEP(s)      (((s) >> 4) & 0xff)
#define HYPERRAM_STATUS_WINDOW(s)    (((s) >> 12) & 0xff)
#define HYPERRAM_STATUS_OTHER(s)     (((s) >> 20) & 0xff)

#endif
