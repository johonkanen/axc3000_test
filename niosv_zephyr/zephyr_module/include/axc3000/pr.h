/*
 * Partial reconfiguration of the PR_DEMO hardware's PR region - see
 * zephyr_module/src/pr.c.
 */
#ifndef AXC3000_PR_H_
#define AXC3000_PR_H_

#include <stddef.h>
#include <stdint.h>

/* where axc3000_pr_program() stopped */
enum axc3000_pr_step {
	AXC3000_PR_OK = 0,
	AXC3000_PR_START = 1,     /* the controller did not start */
	AXC3000_PR_STREAM = 2,    /* an error while streaming */
	AXC3000_PR_FINISH = 3,    /* no "done" after the last word */
};

/*
 * Programs a PR bitstream (a persona's .rbf, len a multiple of 4, 4-byte
 * aligned) into the region: freezes and resets it, streams the image
 * through the PR controller, then releases it. Returns the step it stopped
 * at; *status (if not NULL) is the controller's last status (3 = done).
 * After a failure the region stays frozen and in reset.
 *
 * The image must be a good one: the SDM can stop taking data on a damaged
 * image, and the store to the controller then waits forever (the CPU hangs).
 */
enum axc3000_pr_step axc3000_pr_program(const void *image, size_t len, uint32_t *status);

#endif
