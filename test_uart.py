#!/usr/bin/env python3
"""
test_uart.py - exercise the axc3000 `uart_bringup` UART register interface.

    python test_uart.py [PORT] [BAUD]        # defaults: COM6 115200

Self-contained - only needs pyserial (`pip install pyserial`).  Speaks the
fpga_interconnect serial protocol directly: 1-byte command, 2-byte address,
4-byte data, big-endian.

Register map (see uart_bringup_top.vhd):
    1   id            0x0000ACDC                     RO
    2   git hash                                     RO
    3   loopback                                     RW
    4   read counter  (+1 on every read of addr 4)   RO
    50  FMA operand a (fp32 bit pattern)             RW
    51  FMA operand b                                RW
    52  FMA operand c                                RW
    53  FMA result    a*b + c  (fp32)                RO
    54  measured FMA pipeline latency (clocks)       RO
    55  write -> run the latency probe               WO
    60  PWM0 duty (mkr_d4)  tenths of a percent      RW
    61  PWM1 duty (mkr_d5)                           RW
    62  PWM2 duty (mkr_d6)                           RW
    63  PWM3 duty (mkr_d7)                           RW

Exit status: 0 = all tests passed, 1 = one or more failed.
"""

import struct
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("this script needs pyserial:  pip install pyserial")

CMD_READ = 0x02
CMD_WRITE = 0x04
ADDR_BYTES = 2
DATA_BYTES = 4
FRAME_LEN = 1 + ADDR_BYTES + DATA_BYTES

PWM_DEFAULTS = {60: 100, 61: 200, 62: 300, 63: 400}


class Uart:
    def __init__(self, port, baud):
        self.s = serial.Serial(port, baud, timeout=0.25)
        self.s.reset_input_buffer()
        self.s.reset_output_buffer()

    def close(self):
        self.s.close()

    def read(self, addr):
        self.s.reset_input_buffer()
        self.s.write(bytes([CMD_READ, (addr >> 8) & 0xFF, addr & 0xFF]))
        frame = self.s.read(FRAME_LEN)
        if len(frame) != FRAME_LEN:
            raise TimeoutError(
                f"no/short response reading addr {addr}: got {len(frame)} bytes {frame.hex()}"
            )
        return int.from_bytes(frame[1 + ADDR_BYTES:], "big")

    def write(self, addr, value):
        value &= 0xFFFFFFFF
        self.s.write(
            bytes([CMD_WRITE, (addr >> 8) & 0xFF, addr & 0xFF])
            + value.to_bytes(DATA_BYTES, "big")
        )
        self.s.flush()


def f2i(x):
    return struct.unpack("!I", struct.pack("!f", x))[0]


def i2f(x):
    return struct.unpack("!f", struct.pack("!I", x))[0]


class Runner:
    def __init__(self):
        self.passed = 0
        self.failed = 0

    def check(self, name, ok, detail=""):
        tag = "PASS" if ok else "FAIL"
        print(f"  [{tag}] {name}" + (f"  - {detail}" if detail else ""))
        if ok:
            self.passed += 1
        else:
            self.failed += 1

    def info(self, msg):
        print(f"  [info] {msg}")


def test_link_and_id(u, r):
    print("link / id (addr 1)")
    val = u.read(1)
    r.check("addr 1 == 0x0000ACDC", val == 0x0000ACDC, f"read 0x{val:08X}")


def test_git_hash(u, r):
    print("git hash (addr 2)")
    val = u.read(2)
    r.check("addr 2 non-zero", val != 0, f"0x{val:08X}")


def test_loopback(u, r):
    print("loopback register (addr 3)")
    for pat in (0x00000000, 0xFFFFFFFF, 0xDEADBEEF, 0x12345678, 0xA5A5A5A5, 0x5A5A5A5A):
        u.write(3, pat)
        got = u.read(3)
        r.check(f"0x{pat:08X}", got == pat, f"read 0x{got:08X}")
    u.write(3, 0)


def test_read_counter(u, r):
    print("read strobe counter (addr 4)")
    seq = [u.read(4) for _ in range(6)]
    deltas = [(b - a) & 0xFFFFFFFF for a, b in zip(seq, seq[1:])]
    r.check("increments by 1 per read", all(d == 1 for d in deltas), f"{seq}")


def test_fma(u, r):
    print("FP32 fused multiply-add (addr 50-53:  result = a*b + c)")
    cases = [
        (1.5, 2.0, 0.5),
        (3.0, 3.0, 1.0),
        (-2.5, 4.0, 10.0),
        (0.25, -8.0, 100.0),
        (123.0, 0.0, -1.0),
        (1e3, 1e3, -1e6),
    ]
    for a, b, c in cases:
        u.write(50, f2i(a))
        u.write(51, f2i(b))
        u.write(52, f2i(c))
        time.sleep(0.01)
        ra, rb, rc = i2f(u.read(50)), i2f(u.read(51)), i2f(u.read(52))
        res = i2f(u.read(53))
        exp = a * b + c
        tol = 1e-3 * max(1.0, abs(exp))
        ok = (
            abs(res - exp) <= tol
            and ra == struct.unpack("!f", struct.pack("!f", a))[0]
            and rb == struct.unpack("!f", struct.pack("!f", b))[0]
            and rc == struct.unpack("!f", struct.pack("!f", c))[0]
        )
        r.check(
            f"{a} * {b} + {c}",
            ok,
            f"got {res:.6g}, expected {exp:.6g} (operand readback {ra}/{rb}/{rc})",
        )
    for addr in (50, 51, 52):
        u.write(addr, 0)


def test_fma_latency(u, r):
    print("FMA pipeline latency probe (addr 55 trigger, addr 54 result)")
    runs = []
    for _ in range(3):
        u.write(55, 1)
        time.sleep(0.05)
        runs.append(u.read(54))
    stable = len(set(runs)) == 1 and runs[0] not in (0, 0xFFFFFFFF)
    r.check("probe returns a stable value", stable, f"{runs}")
    if stable:
        lat = runs[0]
        # native_fp32.ip enables input regs + adder_input + output reg -> 3,
        # matching the 3-stage sim_native_fp32.vhd behavioural model.
        r.check(
            "hardware latency == 3 (matches sim_native_fp32.vhd)",
            lat == 3,
            f"{lat} core-clock edges  (see sim/fma_latency_tb.vhd)",
        )


def test_pwm(u, r):
    print("PWM duty registers (addr 60-63)")
    defaults = {a: u.read(a) for a in PWM_DEFAULTS}
    if defaults == PWM_DEFAULTS:
        r.check("reset defaults 100/200/300/400", True, f"{list(defaults.values())}")
    else:
        r.info(
            f"duty regs not at reset defaults ({list(defaults.values())}) - "
            "board already poked, skipping the defaults check"
        )
    for addr, val in ((60, 0), (61, 500), (62, 750), (63, 1000)):
        u.write(addr, val)
        got = u.read(addr)
        r.check(f"addr {addr} <- {val}", got == val, f"read {got}")
    for addr, val in PWM_DEFAULTS.items():
        u.write(addr, val)
    r.info("PWM duty registers restored to 100/200/300/400")


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "COM6"
    baud = int(sys.argv[2]) if len(sys.argv) > 2 else 115200

    print(f"axc3000 uart_bringup register test  -  {port} @ {baud} baud\n")
    try:
        u = Uart(port, baud)
    except serial.SerialException as e:
        sys.exit(f"could not open {port}: {e}")

    r = Runner()
    try:
        for t in (
            test_link_and_id,
            test_git_hash,
            test_loopback,
            test_read_counter,
            test_fma,
            test_fma_latency,
            test_pwm,
        ):
            t(u, r)
            print()
    except (TimeoutError, serial.SerialException) as e:
        print(f"\n  [FAIL] communication error: {e}")
        r.failed += 1
    finally:
        u.close()

    total = r.passed + r.failed
    print(f"result: {r.passed}/{total} passed" + (f", {r.failed} FAILED" if r.failed else ""))
    sys.exit(1 if r.failed else 0)


if __name__ == "__main__":
    main()
