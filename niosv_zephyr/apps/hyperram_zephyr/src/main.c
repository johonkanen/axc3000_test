/* Zephyr using the AXC3000 HyperRAM through zephyr_module (axc3000):
 * a static buffer in the HYPERRAM section, the hyperram_heap, memcpy
 * between on-chip RAM and HyperRAM, and two threads working on HyperRAM
 * blocks at once.
 */
#include <zephyr/kernel.h>
#include <zephyr/sys/sys_heap.h>
#include <axc3000/hyperram.h>
#include <string.h>

#define BIG_BUFFER_SIZE (1024u * 1024u)

/* 1 MB static buffer in the HyperRAM (NOLOAD: not zeroed) */
static uint32_t big_buffer[BIG_BUFFER_SIZE / 4] HYPERRAM_SECTION;

static uint32_t sram_buffer[4096 / 4];

static unsigned int errors;

static inline uint32_t pattern(uint32_t i, uint32_t seed)
{
	uint32_t x = (i + seed) * 0x9e3779b1u;

	return x ^ (x >> 15);
}

static void check(bool ok, const char *what)
{
	printk("%-34s %s\n", what, ok ? "ok" : "FAIL");
	if (!ok) {
		errors++;
	}
}

static bool fill_and_verify(uint32_t *p, size_t words, uint32_t seed)
{
	for (size_t i = 0; i < words; i++) {
		p[i] = pattern(i, seed);
	}
	for (size_t i = 0; i < words; i++) {
		if (p[i] != pattern(i, seed)) {
			printk("  mismatch at %p: 0x%08x != 0x%08x\n", (void *)&p[i], p[i],
			       pattern(i, seed));
			return false;
		}
	}
	return true;
}

static void test_static_buffer(void)
{
	bool in_window = (uintptr_t)big_buffer >= HYPERRAM_BASE &&
			 (uintptr_t)big_buffer + sizeof(big_buffer) <= HYPERRAM_BASE + HYPERRAM_SIZE;

	printk("big_buffer at %p\n", (void *)big_buffer);
	check(in_window, "static buffer in the HyperRAM");
	check(fill_and_verify(big_buffer, ARRAY_SIZE(big_buffer), 1), "static 1 MB buffer");
}

static void test_heap(void)
{
	struct sys_memory_stats before, after;
	void *blocks[48];
	size_t sizes[48];
	bool ok = true;

	sys_heap_runtime_stats_get(&hyperram_heap.heap, &before);
	printk("heap: %u KB free\n", (unsigned int)(before.free_bytes / 1024));

	for (int i = 0; i < ARRAY_SIZE(blocks); i++) {
		/* 16 bytes .. 128 KB, mixed */
		sizes[i] = 16u << (i % 14);
		blocks[i] = k_heap_alloc(&hyperram_heap, sizes[i], K_NO_WAIT);
		if (blocks[i] == NULL) {
			printk("  alloc %u bytes failed\n", (unsigned int)sizes[i]);
			ok = false;
			continue;
		}
		ok &= (uintptr_t)blocks[i] >= HYPERRAM_BASE &&
		      (uintptr_t)blocks[i] < HYPERRAM_BASE + HYPERRAM_SIZE;
		for (size_t k = 0; k < sizes[i] / 4; k++) {
			((uint32_t *)blocks[i])[k] = pattern(k, 100 + i);
		}
	}
	/* every block still holds its own pattern: no overlap */
	for (int i = 0; i < ARRAY_SIZE(blocks); i++) {
		for (size_t k = 0; blocks[i] && k < sizes[i] / 4; k++) {
			if (((uint32_t *)blocks[i])[k] != pattern(k, 100 + i)) {
				printk("  block %d corrupted at word %u\n", i, (unsigned int)k);
				ok = false;
				break;
			}
		}
	}
	for (int i = 0; i < ARRAY_SIZE(blocks); i++) {
		k_heap_free(&hyperram_heap, blocks[i]);
	}
	sys_heap_runtime_stats_get(&hyperram_heap.heap, &after);
	check(ok, "heap: 48 blocks, 16 B - 128 KB");
	check(after.free_bytes == before.free_bytes, "heap: all freed");
}

static void test_memcpy(void)
{
	void *hr = k_heap_alloc(&hyperram_heap, 256 * 1024, K_NO_WAIT);
	bool ok = true;

	if (hr == NULL) {
		check(false, "memcpy: alloc");
		return;
	}
	for (size_t i = 0; i < ARRAY_SIZE(sram_buffer); i++) {
		sram_buffer[i] = pattern(i, 7);
	}

	int64_t t0 = k_uptime_get();

	for (size_t off = 0; off < 256 * 1024; off += sizeof(sram_buffer)) {
		memcpy((char *)hr + off, sram_buffer, sizeof(sram_buffer));
	}
	int64_t t1 = k_uptime_get();

	for (size_t off = 0; off < 256 * 1024; off += sizeof(sram_buffer)) {
		memset(sram_buffer, 0, sizeof(sram_buffer));
		memcpy(sram_buffer, (char *)hr + off, sizeof(sram_buffer));
		for (size_t i = 0; i < ARRAY_SIZE(sram_buffer); i++) {
			ok &= sram_buffer[i] == pattern(i, 7);
		}
	}
	int64_t t2 = k_uptime_get();

	printk("  memcpy SRAM->HyperRAM 256 KB in %lld ms, back + check in %lld ms\n",
	       t1 - t0, t2 - t1);
	k_heap_free(&hyperram_heap, hr);
	check(ok, "memcpy SRAM <-> HyperRAM");
}

/* two threads, each repeatedly filling and checking its own HyperRAM block:
 * preemption in the middle of HyperRAM accesses must not corrupt either
 */
#define WORKER_STACK 1024
K_THREAD_STACK_ARRAY_DEFINE(worker_stacks, 2, WORKER_STACK);
static struct k_thread workers[2];
static volatile bool worker_ok[2];

static void worker(void *p1, void *p2, void *p3)
{
	int id = (int)(uintptr_t)p1;
	uint32_t *block = k_heap_alloc(&hyperram_heap, 32 * 1024, K_NO_WAIT);
	bool ok = block != NULL;

	for (int round = 0; ok && round < 8; round++) {
		ok = fill_and_verify(block, 32 * 1024 / 4, id * 1000 + round);
		k_yield();
	}
	k_heap_free(&hyperram_heap, block);
	worker_ok[id] = ok;
}

static void test_threads(void)
{
	for (int i = 0; i < 2; i++) {
		k_thread_create(&workers[i], worker_stacks[i], WORKER_STACK, worker,
				(void *)(uintptr_t)i, NULL, NULL, K_PRIO_PREEMPT(5), 0, K_NO_WAIT);
	}
	for (int i = 0; i < 2; i++) {
		k_thread_join(&workers[i], K_FOREVER);
	}
	check(worker_ok[0] && worker_ok[1], "two threads on HyperRAM blocks");
}

int main(void)
{
	printk("Zephyr on the AXC3000 HyperRAM: status 0x%08x\n", hyperram_status());
	if (!hyperram_ready()) {
		printk("RESULT: FAIL (HyperRAM not ready)\n");
		return 0;
	}

	test_static_buffer();
	test_heap();
	test_memcpy();
	test_threads();

	printk("RESULT: %s (%u failures)\n", errors ? "FAIL" : "PASS", errors);
	return 0;
}
