#!/usr/bin/env python3
"""FPGA bitstream updates over the 12 MBaud FTDI UART (mcumgr / SMP group 64,
zephyr_module/src/rsu_mgmt.c in the running application).

    update_bitstream.py status
    update_bitstream.py program hw/output_files/application.rpd [--slot N] [--load]
    update_bitstream.py load N

program: uploads an RSU application image (hw/flash/make_flash_images.sh's
application.rpd) into a HyperRAM buffer on the board, which programs it into
an RSU slot with libRSU, verifies it and makes it the highest priority - the
SDM boots it at the next configuration from flash (power-up, or --load now),
and falls back to the other slots / the factory image if it fails. Default
slot: the one that is not running. The factory image is never written.

Run with the project's venv (smpclient): niosv_zephyr/.venv/bin/python3
"""
import argparse
import asyncio
import sys
import time
import zlib

from smp import error, message
from smpclient import SMPClient
from smpclient.transport.serial import SMPSerialTransport

GROUP = 64          # MGMT_GROUP_ID_PERUSER
CHUNK = 8000        # bytes of image per SMP frame (~12 KB encoded: 4 x 4 KB lines);
                    # --small: 1 KB frames, for a board whose UART FIFO is 2 KB
                    # (a 16 KB frame overflows it at 12 MBaud)


class RsuErrorV1(error.ErrorV1):
    _GROUP_ID = GROUP


class RsuErrorV2(error.ErrorV2[int]):
    _GROUP_ID = GROUP


class _Rsu:
    _ErrorV1 = RsuErrorV1
    _ErrorV2 = RsuErrorV2


class StatusResponse(message.ReadResponse):
    _GROUP_ID = GROUP
    _COMMAND_ID = 0
    current: int
    fail: int
    state: int
    ver: int
    slots: list


class StatusRequest(message.ReadRequest, _Rsu):
    _GROUP_ID = GROUP
    _COMMAND_ID = 0
    _Response = StatusResponse


class UploadResponse(message.WriteResponse):
    _GROUP_ID = GROUP
    _COMMAND_ID = 1
    off: int


class UploadRequest(message.WriteRequest, _Rsu):
    _GROUP_ID = GROUP
    _COMMAND_ID = 1
    _Response = UploadResponse
    off: int
    len: int
    data: bytes


class ProgramResponse(message.WriteResponse):
    _GROUP_ID = GROUP
    _COMMAND_ID = 2
    slot: int
    librsu: int
    step: int       # 0 done, else where it failed: 1 erase, 2 program, 3 verify


class ProgramRequest(message.WriteRequest, _Rsu):
    _GROUP_ID = GROUP
    _COMMAND_ID = 2
    _Response = ProgramResponse
    slot: int
    crc: int


class LoadResponse(message.WriteResponse):
    _GROUP_ID = GROUP
    _COMMAND_ID = 3


class LoadRequest(message.WriteRequest, _Rsu):
    _GROUP_ID = GROUP
    _COMMAND_ID = 3
    _Response = LoadResponse
    slot: int


def check(rsp, what):
    if isinstance(rsp, (RsuErrorV1, RsuErrorV2)):
        sys.exit(f"{what} failed: {rsp}")
    return rsp


def show(st):
    print(f"current image 0x{st.current:x}, failing image 0x{st.fail:x}, "
          f"state 0x{st.state:x}, version 0x{st.ver:x}")
    for i, s in enumerate(st.slots):
        running = " (running)" if s["addr"] == st.current else ""
        print(f"  slot {i} {s['name']:<8} 0x{s['addr']:08x} {s['size']:8d} "
              f"priority {s['prio']}{running}")


async def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", default="/dev/ttyUSB0")
    ap.add_argument("--baudrate", type=int, default=12_000_000)
    ap.add_argument("--small", action="store_true", help="1 KB SMP frames (2 KB UART FIFO)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    p = sub.add_parser("program")
    p.add_argument("rpd")
    p.add_argument("--slot", type=int, help="RSU slot (default: one not running)")
    p.add_argument("--load", action="store_true", help="reconfigure from it now")
    p = sub.add_parser("load", help="reconfigure from an RSU slot now")
    p.add_argument("slot", type=int)
    a = ap.parse_args()

    line_length, line_buffers = (512, 2) if a.small else (4096, 4)
    chunk = 600 if a.small else CHUNK
    transport = SMPSerialTransport(line_length=line_length, line_buffers=line_buffers,
                                   baudrate=a.baudrate,
                                   max_smp_encoded_frame_size=line_length * line_buffers)
    async with SMPClient(transport, a.port, timeout_s=60) as client:
        st = check(await client.request(StatusRequest()), "status")
        show(st)
        if a.cmd == "status":
            return
        if a.cmd == "load":
            check(await client.request(LoadRequest(slot=a.slot)), "load")
            print(f"reconfiguring from slot {a.slot}")
            return

        image = open(a.rpd, "rb").read()
        slot = a.slot
        if slot is None:
            idle = [i for i, s in enumerate(st.slots) if s["addr"] != st.current]
            if not idle:
                sys.exit("no slot that is not running")
            slot = min(idle, key=lambda i: st.slots[i]["prio"])
        if len(image) > st.slots[slot]["size"]:
            sys.exit(f"{len(image)} bytes do not fit slot {slot}")

        t0 = time.time()
        off = 0
        while off < len(image):
            part = image[off:off + chunk]
            rsp = check(await client.request(
                UploadRequest(off=off, len=len(image), data=part)), f"upload at {off}")
            off = rsp.off
            print(f"\r  uploaded {off} / {len(image)}", end="", flush=True)
        t1 = time.time()
        print(f" - {len(image) / (t1 - t0) / 1e3:.0f} kB/s")

        print(f"programming slot {slot} ({st.slots[slot]['name']}) ...")
        rsp = check(await client.request(ProgramRequest(slot=slot, crc=zlib.crc32(image)),
                                         timeout_s=300), "program")
        if rsp.librsu:
            steps = {1: "erase", 2: "program", 3: "verify"}
            sys.exit(f"program failed in {steps.get(rsp.step, rsp.step)}: librsu error "
                     f"{rsp.librsu} (zephyr_module/lib/unilibrsu/include/libRSU.h)")
        print(f"  programmed (highest priority), verified in {time.time() - t1:.0f} s")
        show(check(await client.request(StatusRequest()), "status"))

        if a.load:
            check(await client.request(LoadRequest(slot=slot)), "load")
            print(f"reconfiguring from slot {slot}")


asyncio.run(main())
