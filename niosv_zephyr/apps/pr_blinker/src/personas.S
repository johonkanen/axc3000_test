/* the two persona bitstreams, word-aligned for the PR controller's 32-bit
 * data port; their sizes as words after each
 */
	.section .rodata.personas, "a"

	.balign 4
	.global persona_blue
persona_blue:
	.incbin PERSONA_BLUE
	.global persona_blue_end
persona_blue_end:

	.balign 4
	.global persona_green
persona_green:
	.incbin PERSONA_GREEN
	.global persona_green_end
persona_green_end:
