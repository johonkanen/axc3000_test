/*
 * FPGA bitstream updates over mcumgr (SMP): a command group (64, the first
 * user group) on Altera's uniLibRSU (lib/unilibrsu). The image - an RSU application image,
 * hw/flash/make_flash_images.sh's application.rpd - is uploaded in chunks
 * into a buffer in the HyperRAM, then programmed into an RSU slot (P1/P2) -
 * which makes it the highest priority - and verified: the SDM's decision firmware boots
 * it at the next configuration from flash, and falls back to the next one /
 * the factory image if it fails. The factory image is never written.
 *
 *   0 status  (read)  {"current", "fail", "state", "ver" (not "version": an
 *                      SMP message field of that name exists),
 *                      "slots": [{"name", "addr", "size", "prio"}, ...]}
 *   1 upload  (write) {"off", "len" (total, with off = 0), "data"} -> {"off"}
 *   2 program (write) {"slot", "crc" (CRC-32 of the whole image)} -> {"slot", "librsu"
 *                      (0, or libRSU's error), "step" (where it failed:
 *                      1 erase, 2 program - also makes it the highest
 *                      priority, 3 verify)}
 *   3 load    (write) {"slot"}: reconfigure from that slot now
 *   4 pr      (write) {"crc"} -> {"status" (the PR controller's last, 3 =
 *                      done), "step" (0 done, else where it failed: 1 start,
 *                      2 stream, 3 finish), "ms"}: program the uploaded image
 *                      - a PR bitstream (persona) - into the PR region
 *                      (CONFIG_AXC3000_PR_MGMT, the PR_DEMO hardware)
 *
 * mcuboot/update_bitstream.py is the host side.
 */
#include <zephyr/kernel.h>
#include <zephyr/mgmt/mcumgr/mgmt/mgmt.h>
#include <zephyr/mgmt/mcumgr/mgmt/handlers.h>
#include <zephyr/mgmt/mcumgr/smp/smp.h>
#include <zephyr/sys/crc.h>
#include <zephyr/logging/log.h>
#include <zcbor_common.h>
#include <zcbor_decode.h>
#include <zcbor_encode.h>
#include <mgmt/mcumgr/util/zcbor_bulk.h>
#include <axc3000/hyperram.h>
#include <libRSU.h>

LOG_MODULE_REGISTER(rsu_mgmt, LOG_LEVEL_INF);

/* The handlers run on mcumgr's transport workqueue; the default 2 KB stack
 * overflowed silently under the earlier libRSU port (its 4 KB image blocks
 * were on the stack - uniLibRSU mallocs them).
 */
BUILD_ASSERT(CONFIG_MCUMGR_TRANSPORT_WORKQUEUE_STACK_SIZE >= 8192,
	     "rsu_mgmt: CONFIG_MCUMGR_TRANSPORT_WORKQUEUE_STACK_SIZE must be at least 8192");

#define RSU_MGMT_GROUP   MGMT_GROUP_ID_PERUSER
#define RSU_MGMT_STATUS  0
#define RSU_MGMT_UPLOAD  1
#define RSU_MGMT_PROGRAM 2
#define RSU_MGMT_LOAD    3
#define RSU_MGMT_PR      4

#define MAX_IMAGE (4 * 1024 * 1024)       /* an RSU slot */

static uint8_t *image;                    /* in the HyperRAM heap */
static uint32_t image_len;                /* total, from the first chunk */
static uint32_t image_have;               /* bytes received, in order */
static bool librsu_ready;

static int librsu_up(void)
{
	if (!librsu_ready) {
		int ret = librsu_init(NULL);

		if (ret) {
			LOG_ERR("librsu_init: %d", ret);
			return ret;
		}
		librsu_ready = true;
	}
	return 0;
}

static int rsu_mgmt_status(struct smp_streamer *ctxt)
{
	zcbor_state_t *zse = ctxt->writer->zs;
	struct rsu_status_info info = {0};
	bool ok;
	int slots;

	if (librsu_up() || rsu_status_log(&info)) {
		return MGMT_ERR_EUNKNOWN;
	}
	slots = rsu_slot_count();

	ok = zcbor_tstr_put_lit(zse, "current") && zcbor_uint64_put(zse, info.current_image) &&
	     zcbor_tstr_put_lit(zse, "fail") && zcbor_uint64_put(zse, info.fail_image) &&
	     zcbor_tstr_put_lit(zse, "state") && zcbor_uint64_put(zse, info.state) &&
	     zcbor_tstr_put_lit(zse, "ver") && zcbor_uint64_put(zse, info.version) &&
	     zcbor_tstr_put_lit(zse, "slots") && zcbor_list_start_encode(zse, slots);
	for (int i = 0; ok && i < slots; i++) {
		struct rsu_slot_info si;

		if (rsu_slot_get_info(i, &si)) {
			return MGMT_ERR_EUNKNOWN;
		}
		ok = zcbor_map_start_encode(zse, 4) &&
		     zcbor_tstr_put_lit(zse, "name") && zcbor_tstr_put_term(zse, si.name, sizeof(si.name)) &&
		     zcbor_tstr_put_lit(zse, "addr") && zcbor_uint64_put(zse, si.offset) &&
		     zcbor_tstr_put_lit(zse, "size") && zcbor_int32_put(zse, si.size) &&
		     zcbor_tstr_put_lit(zse, "prio") && zcbor_int32_put(zse, si.priority) &&
		     zcbor_map_end_encode(zse, 4);
	}
	ok = ok && zcbor_list_end_encode(zse, slots);
	return ok ? MGMT_ERR_EOK : MGMT_ERR_EMSGSIZE;
}

static int rsu_mgmt_upload(struct smp_streamer *ctxt)
{
	zcbor_state_t *zsd = ctxt->reader->zs;
	zcbor_state_t *zse = ctxt->writer->zs;
	struct zcbor_string data = {0};
	uint32_t off = UINT32_MAX;
	uint32_t len = 0;
	size_t decoded;

	struct zcbor_map_decode_key_val upload_decode[] = {
		ZCBOR_MAP_DECODE_KEY_DECODER("off", zcbor_uint32_decode, &off),
		ZCBOR_MAP_DECODE_KEY_DECODER("len", zcbor_uint32_decode, &len),
		ZCBOR_MAP_DECODE_KEY_DECODER("data", zcbor_bstr_decode, &data),
	};

	if (zcbor_map_decode_bulk(zsd, upload_decode, ARRAY_SIZE(upload_decode), &decoded) ||
	    off == UINT32_MAX) {
		return MGMT_ERR_EINVAL;
	}

	if (off == 0) {
		if (len == 0 || len > MAX_IMAGE) {
			return MGMT_ERR_EINVAL;
		}
		if (!hyperram_ready()) {
			return MGMT_ERR_ENOMEM;
		}
		if (image) {
			k_heap_free(&hyperram_heap, image);
		}
		image = k_heap_alloc(&hyperram_heap, len, K_NO_WAIT);
		if (!image) {
			return MGMT_ERR_ENOMEM;
		}
		image_len = len;
		image_have = 0;
	}

	/* in order only; a repeated chunk (a lost reply) is fine */
	if (!image || off > image_have || off + data.len > image_len) {
		return MGMT_ERR_EINVAL;
	}
	memcpy(image + off, data.value, data.len);
	image_have = MAX(image_have, off + (uint32_t)data.len);

	return zcbor_tstr_put_lit(zse, "off") && zcbor_uint32_put(zse, image_have) ?
	       MGMT_ERR_EOK : MGMT_ERR_EMSGSIZE;
}

static int rsu_mgmt_program(struct smp_streamer *ctxt)
{
	zcbor_state_t *zsd = ctxt->reader->zs;
	zcbor_state_t *zse = ctxt->writer->zs;
	uint32_t slot = UINT32_MAX;
	uint32_t crc = 0;
	size_t decoded;
	int ret;

	struct zcbor_map_decode_key_val program_decode[] = {
		ZCBOR_MAP_DECODE_KEY_DECODER("slot", zcbor_uint32_decode, &slot),
		ZCBOR_MAP_DECODE_KEY_DECODER("crc", zcbor_uint32_decode, &crc),
	};

	if (zcbor_map_decode_bulk(zsd, program_decode, ARRAY_SIZE(program_decode), &decoded) ||
	    slot == UINT32_MAX) {
		return MGMT_ERR_EINVAL;
	}
	if (!image || image_have != image_len) {
		LOG_ERR("program: image incomplete (%u of %u)", image_have, image_len);
		return MGMT_ERR_EINVAL;
	}
	if (crc32_ieee(image, image_len) != crc) {
		LOG_ERR("program: CRC mismatch");
		return MGMT_ERR_EBADSTATE;
	}
	if (librsu_up()) {
		return MGMT_ERR_EUNKNOWN;
	}

	LOG_INF("programming %u bytes into slot %u", image_len, slot);
	uint32_t step = 1;

	ret = rsu_slot_erase(slot);
	if (ret == 0) {
		step = 2;
		ret = rsu_slot_program_buf(slot, image, image_len);
	}
	if (ret == 0) {
		step = 3;
		ret = rsu_slot_verify_buf(slot, image, image_len);
	}
	if (ret) {
		LOG_ERR("program slot %u: step %u, librsu %d", slot, step, ret);
	} else {
		LOG_INF("slot %u programmed (highest priority), verified", slot);
		k_heap_free(&hyperram_heap, image);
		image = NULL;
		image_len = image_have = 0;
		step = 0;
	}

	/* the result in the reply too: the console may not be attached */
	return zcbor_tstr_put_lit(zse, "slot") && zcbor_uint32_put(zse, slot) &&
	       zcbor_tstr_put_lit(zse, "librsu") && zcbor_int32_put(zse, ret) &&
	       zcbor_tstr_put_lit(zse, "step") && zcbor_uint32_put(zse, step) ?
	       MGMT_ERR_EOK : MGMT_ERR_EMSGSIZE;
}

static void load_work_handler(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(load_work, load_work_handler);
static int load_slot;

static void load_work_handler(struct k_work *work)
{
	int ret;

	ARG_UNUSED(work);
	/* via the "reboot_image" attribute: RSU_IMAGE_UPDATE, i.e. now
	 * (lib/librsu/librsu_misc.c) - returns only if refused
	 */
	ret = rsu_slot_load_after_reboot(load_slot);
	LOG_ERR("rsu_slot_load_after_reboot(%d): %d", load_slot, ret);
}

static int rsu_mgmt_load(struct smp_streamer *ctxt)
{
	zcbor_state_t *zsd = ctxt->reader->zs;
	uint32_t slot = UINT32_MAX;
	size_t decoded;

	struct zcbor_map_decode_key_val load_decode[] = {
		ZCBOR_MAP_DECODE_KEY_DECODER("slot", zcbor_uint32_decode, &slot),
	};

	if (zcbor_map_decode_bulk(zsd, load_decode, ARRAY_SIZE(load_decode), &decoded) ||
	    slot == UINT32_MAX || librsu_up()) {
		return MGMT_ERR_EINVAL;
	}
	/* after the reply has gone out, as os_mgmt's reset */
	load_slot = slot;
	k_work_schedule(&load_work, K_MSEC(250));
	return MGMT_ERR_EOK;
}

#ifdef CONFIG_AXC3000_PR_MGMT
/*
 * Altera's PR Controller IP, Avalon-MM (ip/.../altera_pr_mm_*.sv): word 0
 * data (written words go to the SDM - only while a PR is in progress -,
 * back-pressured: the CPU's store waits), word 1 CSR (write bit 0 starts;
 * read bits 3:1 the status: 1 system busy, 2 in progress, 3 done, 4 or 6
 * an error). pio_pr_ctrl's data register: bit 0 freeze, bit 1 reset.
 */
#define PR_NODE      DT_NODELABEL(pr_controller)
#define PR_DATA      ((volatile uint32_t *)DT_REG_ADDR_BY_NAME(PR_NODE, pr))
#define PR_CSR       (PR_DATA + 1)
#define PR_CTRL      ((volatile uint32_t *)DT_REG_ADDR_BY_NAME(PR_NODE, ctrl))
#define PR_FREEZE    BIT(0)
#define PR_RESET     BIT(1)

#define PR_ST_BUSY   1
#define PR_ST_PROG   2
#define PR_ST_DONE   3

static uint32_t pr_status(void)
{
	return (*PR_CSR >> 1) & 7;
}

static bool pr_error(uint32_t st)
{
	return st == 4 || st == 6;
}

/* polls for want (or an error) for up to 1 s */
static uint32_t pr_wait(uint32_t want)
{
	int64_t end = k_uptime_get() + 1000;
	uint32_t st;

	do {
		st = pr_status();
		if (st == want || pr_error(st)) {
			break;
		}
	} while (k_uptime_get() < end);
	return st;
}

static int rsu_mgmt_pr(struct smp_streamer *ctxt)
{
	zcbor_state_t *zsd = ctxt->reader->zs;
	zcbor_state_t *zse = ctxt->writer->zs;
	uint32_t crc = 0;
	size_t decoded;
	uint32_t st, step = 1;
	int64_t t0;

	struct zcbor_map_decode_key_val pr_decode[] = {
		ZCBOR_MAP_DECODE_KEY_DECODER("crc", zcbor_uint32_decode, &crc),
	};

	if (zcbor_map_decode_bulk(zsd, pr_decode, ARRAY_SIZE(pr_decode), &decoded)) {
		return MGMT_ERR_EINVAL;
	}
	if (!image || image_have != image_len || image_len % 4) {
		LOG_ERR("pr: image incomplete (%u of %u)", image_have, image_len);
		return MGMT_ERR_EINVAL;
	}
	if (crc32_ieee(image, image_len) != crc) {
		LOG_ERR("pr: CRC mismatch");
		return MGMT_ERR_EBADSTATE;
	}

	t0 = k_uptime_get();
	/* the region's outputs held, its logic in reset (a few of its 25 MHz
	 * clock's cycles through the synchroniser)
	 */
	*PR_CTRL = PR_FREEZE | PR_RESET;
	k_busy_wait(10);

	*PR_CSR = 1;
	st = pr_wait(PR_ST_PROG);
	if (st == PR_ST_PROG) {
		const uint32_t *w = (const uint32_t *)image;
		uint32_t n = image_len / 4;

		bool failed = false;

		step = 2;
		/* all of it even after an error: the PR IP user guide's recovery
		 * (Agilex) drains the rest of the bitstream before a retry.
		 * But a damaged image (one with a valid CRC: corrupted before
		 * the upload) makes the SDM stop taking data, and the store
		 * below then waits forever - the CPU hangs until the FPGA is
		 * reconfigured (seen on the board). A real design needs a
		 * timeout in front of the data port.
		 */
		for (uint32_t i = 0; i < n; i++) {
			*PR_DATA = w[i];
			if ((i & 1023) == 1023 && !failed && pr_error(st = pr_status())) {
				failed = true;
			}
		}
		if (!failed) {
			step = 3;
			st = pr_wait(PR_ST_DONE);
		}
	}
	if (st == PR_ST_DONE) {
		step = 0;
		/* reset released while still frozen, then the outputs */
		*PR_CTRL = PR_FREEZE;
		k_busy_wait(10);
		*PR_CTRL = 0;
		LOG_INF("PR: %u bytes in %lld ms", image_len, k_uptime_get() - t0);
		k_heap_free(&hyperram_heap, image);
		image = NULL;
		image_len = image_have = 0;
	} else {
		/* the region stays frozen and in reset: no half-programmed logic
		 * drives anything
		 */
		LOG_ERR("PR failed: step %u, status %u", step, st);
	}

	return zcbor_tstr_put_lit(zse, "status") && zcbor_uint32_put(zse, st) &&
	       zcbor_tstr_put_lit(zse, "step") && zcbor_uint32_put(zse, step) &&
	       zcbor_tstr_put_lit(zse, "ms") && zcbor_uint32_put(zse, k_uptime_get() - t0) ?
	       MGMT_ERR_EOK : MGMT_ERR_EMSGSIZE;
}
#endif

static const struct mgmt_handler rsu_mgmt_handlers[] = {
	[RSU_MGMT_STATUS] = {.mh_read = rsu_mgmt_status, .mh_write = NULL},
	[RSU_MGMT_UPLOAD] = {.mh_read = NULL, .mh_write = rsu_mgmt_upload},
	[RSU_MGMT_PROGRAM] = {.mh_read = NULL, .mh_write = rsu_mgmt_program},
	[RSU_MGMT_LOAD] = {.mh_read = NULL, .mh_write = rsu_mgmt_load},
#ifdef CONFIG_AXC3000_PR_MGMT
	[RSU_MGMT_PR] = {.mh_read = NULL, .mh_write = rsu_mgmt_pr},
#endif
};

static struct mgmt_group rsu_mgmt_group = {
	.mg_handlers = rsu_mgmt_handlers,
	.mg_handlers_count = ARRAY_SIZE(rsu_mgmt_handlers),
	.mg_group_id = RSU_MGMT_GROUP,
};

static void rsu_mgmt_register_group(void)
{
	mgmt_register_group(&rsu_mgmt_group);
}

MCUMGR_HANDLER_DEFINE(axc3000_rsu_mgmt, rsu_mgmt_register_group);
