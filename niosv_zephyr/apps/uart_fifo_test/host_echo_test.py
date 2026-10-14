#!/usr/bin/env python3
"""Echo test for apps/uart_fifo_test: send random data over the FTDI serial
port, read the echo back at the same time, compare, report throughput.

    python3 host_echo_test.py [--port /dev/ttyUSB0] [--baud 4800000] [--bytes 1000000]
"""
import argparse, os, sys, threading, time
import serial

ap = argparse.ArgumentParser()
ap.add_argument("--port", default="/dev/ttyUSB0")
ap.add_argument("--baud", type=int, default=4_800_000)
ap.add_argument("--bytes", type=int, default=1_000_000)
ap.add_argument("--chunk", type=int, default=4096)
ap.add_argument("--rate", type=float, default=0, help="pace sending to this many kB/s (0: as fast as the port goes)")
a = ap.parse_args()

data = os.urandom(a.bytes)
s = serial.Serial(a.port, a.baud, timeout=0.2)
# ftdi_sio's latency timer defaults to 16 ms; low-latency mode (allowed
# without root) sets it to 1 ms. At 480 kB/s the FTDI's receive buffer
# otherwise overflows now and then before the host - through usbipd, in
# WSL - fetches it, and echoed bytes are lost on the way in.
try:
    s.set_low_latency_mode(True)
except (OSError, ValueError, NotImplementedError) as e:
    print(f"note: low-latency mode not set ({e})")
s.reset_input_buffer()

received = bytearray()
done = threading.Event()

def reader():
    idle = 0
    while not done.is_set() or idle < 10:
        b = s.read(65536)
        if b:
            received.extend(b)
            idle = 0
        else:
            idle += 1
        if len(received) >= len(data):
            break

t = threading.Thread(target=reader)
t.start()
t0 = time.time()
for i in range(0, len(data), a.chunk):
    s.write(data[i:i + a.chunk])
    if a.rate:
        ahead = t0 + (i + a.chunk) / (a.rate * 1e3) - time.time()
        if ahead > 0:
            time.sleep(ahead)
s.flush()
t_sent = time.time()
done.set()
t.join()
t1 = time.time()

n = len(received)
first_bad = next((i for i in range(min(n, len(data))) if received[i] != data[i]), None)
print(f"sent {len(data)} B in {t_sent - t0:.2f} s ({len(data) / (t_sent - t0) / 1e3:.0f} kB/s), "
      f"echo {n} B in {t1 - t0:.2f} s ({n / (t1 - t0) / 1e3:.0f} kB/s)")
if n == len(data) and first_bad is None:
    print("PASS: echo identical")
    sys.exit(0)
print(f"FAIL: {n} of {len(data)} bytes back, first difference at "
      f"{first_bad if first_bad is not None else n}")
sys.exit(1)
