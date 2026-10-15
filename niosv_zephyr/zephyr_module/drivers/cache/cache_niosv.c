/*
 * Nios V/g caches for Zephyr's cache API (CONFIG_EXTERNAL_CACHE): the data
 * cache is write-back, with the operations of Altera's HAL
 * (intel_niosv_common/HAL/inc/intel_niosv.h, alt_dcache_flush*.c):
 *   by index (the whole cache: a loop over its lines) - custom MISC-MEM
 *     encodings, funct12 0x080 invalidate, 0x081 clean (write back),
 *     0x082 flush (write back and invalidate)
 *   by address - the standard Zicbom cbo.inval / cbo.clean / cbo.flush
 *     (funct12 0x000 / 0x001 / 0x002)
 * The instruction cache is invalidated with fence.i.
 *
 * Zephyr's names: "flush" = write back (clean), "invd" = invalidate,
 * "flush_and_invd" = both.
 *
 * The cache is flushed at the start too (soc_prep_hook, before .data is
 * copied and .bss cleared): after a warm reboot it may hold the previous
 * program's lines. A flush, not an invalidate, so whatever the code before
 * it has written (the stack) is kept; after an FPGA configuration the tags
 * are the block RAMs' initial zeros - nothing valid.
 */
#include <zephyr/kernel.h>
#include <zephyr/cache.h>
#include <zephyr/drivers/cache.h>
#include <zephyr/platform/hooks.h>

#define DCACHE_SIZE  CONFIG_AXC3000_NIOSV_DCACHE_SIZE
#define LINE         32       /* bytes, both caches (intel_niosv_hw_lib.tcl) */

BUILD_ASSERT(CONFIG_DCACHE_LINE_SIZE == LINE, "Nios V/g: 32-byte cache lines");

#define BY_INDEX(funct12, i) \
	__asm__ volatile(".insn i 0x0F, 0x2, zero, %0, " #funct12 :: "r"(i) : "memory")
#define BY_ADDRESS(funct12, a) \
	__asm__ volatile(".insn i 0x0F, 0x2, zero, %0, " #funct12 :: "r"(a) : "memory")

static ALWAYS_INLINE void all_lines(int op)
{
	for (uintptr_t i = 0; i < DCACHE_SIZE; i += LINE) {
		switch (op) {
		case 0:
			BY_INDEX(0x080, i);
			break;
		case 1:
			BY_INDEX(0x081, i);
			break;
		default:
			BY_INDEX(0x082, i);
			break;
		}
	}
}

static ALWAYS_INLINE void range_lines(int op, void *addr, size_t size)
{
	uintptr_t a = (uintptr_t)addr & ~(uintptr_t)(LINE - 1);
	uintptr_t end = (uintptr_t)addr + size;

	for (; a < end; a += LINE) {
		switch (op) {
		case 0:
			BY_ADDRESS(0x000, a);
			break;
		case 1:
			BY_ADDRESS(0x001, a);
			break;
		default:
			BY_ADDRESS(0x002, a);
			break;
		}
	}
}

void cache_data_enable(void)
{
}

void cache_data_disable(void)
{
}

int cache_data_flush_all(void)
{
	all_lines(1);
	return 0;
}

int cache_data_invd_all(void)
{
	all_lines(0);
	return 0;
}

int cache_data_flush_and_invd_all(void)
{
	all_lines(2);
	return 0;
}

int cache_data_flush_range(void *addr, size_t size)
{
	range_lines(1, addr, size);
	return 0;
}

int cache_data_invd_range(void *addr, size_t size)
{
	range_lines(0, addr, size);
	return 0;
}

int cache_data_flush_and_invd_range(void *addr, size_t size)
{
	range_lines(2, addr, size);
	return 0;
}

size_t cache_data_line_size_get(void)
{
	return LINE;
}

void cache_instr_enable(void)
{
}

void cache_instr_disable(void)
{
}

int cache_instr_flush_all(void)
{
	return -ENOTSUP;
}

int cache_instr_invd_all(void)
{
	__asm__ volatile("fence.i" ::: "memory");
	return 0;
}

int cache_instr_flush_and_invd_all(void)
{
	return cache_instr_invd_all();
}

int cache_instr_flush_range(void *addr, size_t size)
{
	ARG_UNUSED(addr);
	ARG_UNUSED(size);
	return -ENOTSUP;
}

int cache_instr_invd_range(void *addr, size_t size)
{
	ARG_UNUSED(addr);
	ARG_UNUSED(size);
	return cache_instr_invd_all();
}

int cache_instr_flush_and_invd_range(void *addr, size_t size)
{
	return cache_instr_invd_range(addr, size);
}

size_t cache_instr_line_size_get(void)
{
	return LINE;
}

/* before .data and .bss: a warm reboot's previous program may have left
 * lines - written back and dropped, the stack's own written back
 */
void soc_prep_hook(void)
{
	all_lines(2);
}
