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

/* hyperram_axi's status word (hVHDL_memory_library hyperram_axi.vhd): bit 0
 * calibrated, bit 1 no setting passed, 15:8 / 23:16 the phases that passed,
 * 26:24 the selected phase, bit 27 the selected order
 */
uint32_t hyperram_status(void);

#endif
