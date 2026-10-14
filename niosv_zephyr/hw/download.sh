#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# download.sh - load an ELF onto the running Nios V/g over JTAG and run it,
#               without rebuilding/reflashing the .sof. The board must
#               already be configured with niosv_zephyr.sof (program it
#               once per hardware change with quartus_pgm, see README.md).
#
#   ./download.sh path/to/zephyr.elf
#   ./download.sh ../zephyr/build_hello/zephyr/zephyr.elf
#
# Console: juart-terminal (same JTAG cable, no extra setup).
#
# OpenOCD directly rather than niosv-download, because of the instruction
# cache (see README.md "Live JTAG download"):
#   - block memory writes through the debug module (OpenOCD's load_image /
#     write_memory, which niosv-download's GDB load uses too) drop words
#     when the I-cache is on - the image lands shifted. Single-word writes
#     (mww) and all reads are fine, so the image is written one word at a
#     time, then read back and compared;
#   - then fence.i (the I-cache still holds the previous program) and a
#     start at the ELF's entry point - 0x0 for an on-chip RAM build, the
#     HyperRAM for an XIP build (the reset vector is in on-chip RAM).
# ---------------------------------------------------------------------------
set -euo pipefail

ELF="$(realpath "${1:?usage: download.sh <path-to-elf>}")"

export PATH="$HOME/altera_pro/26.1.1/niosv/bin:$HOME/altera_pro/26.1.1/quartus/bin:$HOME/altera_pro/26.1.1/quartus/linux64/oocd/openocd/bin:$PATH"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
openocd-cfg-gen "$TMP/niosv.cfg" > /dev/null

# the OpenOCD script: one mww per word of every loadable segment, a
# read-back check, fence.i, pc = entry, resume
python3 - "$ELF" > "$TMP/load.tcl" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
assert d[:4] == b"\x7fELF" and d[4] == 1, "32-bit ELF expected"
entry, phoff = struct.unpack_from("<II", d, 24)
phentsize, phnum = struct.unpack_from("<HH", d, 42)
print("halt")
checks = []
total = 0
for i in range(phnum):
    p_type, off, vaddr, paddr, filesz, memsz, flags, align = struct.unpack_from("<8I", d, phoff + i * phentsize)
    if p_type != 1 or filesz == 0:
        continue
    data = d[off:off + filesz]
    data += b"\0" * (-len(data) % 4)
    words = struct.unpack("<%dI" % (len(data) // 4), data)
    for k, w in enumerate(words):
        print("mww 0x%08x 0x%08x" % (paddr + 4 * k, w))
    checks.append((paddr, words))
    total += 4 * len(words)
for n, (addr, words) in enumerate(checks):
    print("set got [read_memory 0x%08x 32 %d]" % (addr, len(words)))
    print("set want {%s}" % " ".join("0x%x" % w for w in words))
    print("set bad 0")
    print("foreach g $got w $want { if {$g != $w} { incr bad } }")
    print('if {$bad} { echo "VERIFY FAILED: $bad words wrong in segment at 0x%08x"; shutdown error }' % addr)
print('echo "loaded %d bytes, verified"' % total)
print("riscv exec_progbuf 0x0000100f")
print("reg pc 0x%08x" % entry)
print("resume")
print('echo "started at 0x%08x"' % entry)
print("shutdown")
PY

openocd -c "tcl port disabled" -c "gdb port disabled" -c "telnet port disabled" \
    -f "$TMP/niosv.cfg" -f "$TMP/load.tcl" 2>&1 \
    | grep -E "loaded|started|VERIFY|Error" || true
