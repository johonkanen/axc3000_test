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
    56  float->fixed input (fp32)                    RW
    57  fixed-point result (signed int)             RO  (= trunc(float * 2**radix))
    58  float->fixed radix                           RW  (default 10)
    60  PWM0 duty (mkr_d4), integer 0..1024          RO
    61  PWM1 duty (mkr_d5), integer 0..1024          RO
    62  PWM2 duty (mkr_d6), integer 0..1024          RO
    63  PWM3 duty (mkr_d7), integer 0..1024          RO
    64  PWM0 duty ratio as a float [0,1] (fp32)      RW
    65  PWM1 duty ratio as a float [0,1] (fp32)      RW
    66  PWM2 duty ratio as a float [0,1] (fp32)      RW
    67  PWM3 duty ratio as a float [0,1] (fp32)      RW

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


def _read_fixed(u):
    got = u.read(57)
    if got >= 2 ** 31:
        got -= 2 ** 32
    return got


def test_float_to_fixed(u, r):
    print("float -> fixed-point, radix 10 (write addr 56, read addr 57)  fixed = trunc(x * 1024)")
    import math
    u.write(58, 10)
    for x in (1.0, 0.5, 0.25, 0.75, 0.1, 0.0, -0.5, 2.0, 1.0 / 3.0, 2 ** -10):
        u.write(56, f2i(x))
        time.sleep(0.02)
        got = _read_fixed(u)
        exp = math.trunc(x * 1024)
        r.check(f"{x:+.5f}", abs(got - exp) <= 1, f"got {got}, expected {exp}")


def test_float_to_fixed_radix(u, r):
    print("float -> fixed-point, run-time radix (addr 58) - one denormalizer, many radixes")
    import math
    cases = [
        (1.0, 10, 1024), (1.0, 8, 256), (1.0, 12, 4096), (1.0, 0, 1),
        (0.5, 10, 512), (0.5, 9, 256),
        (0.1, 10, 102), (0.1, 14, math.trunc(0.1 * 2 ** 14)),
        (-0.5, 11, -1024), (3.0, 10, 3072), (2 ** -10, 10, 1),
    ]
    for x, radix, exp in cases:
        u.write(58, radix)
        u.write(56, f2i(x))
        time.sleep(0.02)
        got = _read_fixed(u)
        r.check(f"{x:+.5f} @ radix {radix:>2}", abs(got - exp) <= 1, f"got {got}, expected {exp}")
    u.write(58, 10)
    r.info("radix register restored to 10")


PWM_PERIOD = 1024   # 100 MHz / 1024 = 97.66 kHz


def test_pwm(u, r):
    print("PWM duty from float (write addr 64-67, read integer duty 60-63)")
    defaults = [u.read(a) for a in (60, 61, 62, 63)]
    exp_def = [int(x * PWM_PERIOD) for x in (0.1, 0.2, 0.3, 0.4)]
    if all(abs(d - e) <= 1 for d, e in zip(defaults, exp_def)):
        r.check(f"reset defaults ~{exp_def}", True, f"{defaults}")
    else:
        r.info(f"duty regs not at reset defaults ({defaults}) - board already poked")

    # write a duty ratio as a float, read the resulting integer duty (0..1024)
    for ch, x in ((0, 0.0), (1, 0.25), (2, 0.5), (3, 0.95)):
        u.write(64 + ch, f2i(x))
        time.sleep(0.02)
        got = u.read(60 + ch)
        exp = int(x * PWM_PERIOD)          # float_to_fixed truncates
        r.check(f"ch{ch}  {x:.2f} -> duty {got}", abs(got - exp) <= 2, f"expected ~{exp}")

    # float readback
    u.write(64, f2i(0.5))
    r.check("addr 64 float readback", abs(i2f(u.read(64)) - 0.5) < 1e-6, f"{i2f(u.read(64))}")

    for ch, x in ((0, 0.1), (1, 0.2), (2, 0.3), (3, 0.4)):
        u.write(64 + ch, f2i(x))
    r.info("PWM duty ratios restored to 0.1/0.2/0.3/0.4")


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
            test_float_to_fixed,
            test_float_to_fixed_radix,
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
