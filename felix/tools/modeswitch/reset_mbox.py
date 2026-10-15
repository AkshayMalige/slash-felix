#!/usr/bin/env python3
import argparse
import mmap
import os
import sys
import time

PAGE_OFFSET = 0x0FFFF000
MAGIC = 0x46524254
KEEP = 0xFFFFFFFF
READY = 0x52454459
ARMED = 0x41524D44
STATES = {READY: "READY", ARMED: "ARMED", 0x52535421: "RESETTING"}


class Mailbox:
    def __init__(self, bdf):
        fd = os.open(f"/sys/bus/pci/devices/{bdf}/resource0", os.O_RDWR | os.O_SYNC)
        self.mm = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=PAGE_OFFSET)
        os.close(fd)
        self.words = memoryview(self.mm).cast("I")

    def rd(self, off):
        return self.words[off // 4]

    def wr(self, off, val):
        self.words[off // 4] = val & 0xFFFFFFFF


def show(mb):
    st = mb.rd(0x40)
    return (f"state={STATES.get(st, f'unknown(0x{st:08x})')} uptime={mb.rd(0x44) / 1000:.1f}s "
            f"requests_seen={mb.rd(0x48)} boot_MULTI_BOOT=0x{mb.rd(0x4C):08x} version={mb.rd(0x50)}")


def main():
    ap = argparse.ArgumentParser(description="FELIX AMC reset mailbox (card DDR 0x3FFF_F000 = PF0 BAR0 + 0x0FFF_F000)")
    ap.add_argument("cmd", choices=["status", "request"])
    ap.add_argument("--bdf", default=os.environ.get("FELIX_BDF", "0000:41:00.0"))
    ap.add_argument("--delay-ms", type=int, default=8000)
    ap.add_argument("--multiboot", default="keep")
    a = ap.parse_args()

    mb = Mailbox(a.bdf)
    if a.cmd == "status":
        print(show(mb))
        return 0 if mb.rd(0x40) == READY and mb.rd(0x50) >= 1 else 1

    if mb.rd(0x40) != READY or mb.rd(0x50) < 1:
        print(f"mailbox not ready: {show(mb)}", file=sys.stderr)
        return 2
    if not 0 <= a.delay_ms <= 60000:
        print("--delay-ms must be 0..60000", file=sys.stderr)
        return 2
    value = KEEP if a.multiboot == "keep" else int(a.multiboot, 0)
    mb.wr(0x04, value)
    mb.wr(0x08, a.delay_ms)
    mb.wr(0x00, MAGIC)
    t0 = time.time()
    while time.time() - t0 < 2.0:
        if mb.rd(0x40) == ARMED:
            print(f"ARMED after {(time.time() - t0) * 1000:.0f} ms: system reset in {a.delay_ms} ms, "
                  f"MULTI_BOOT {'keep' if value == KEEP else f'0x{value:08x}'}")
            return 0
        time.sleep(0.02)
    mb.wr(0x00, 0)
    print(f"no ARMED acknowledgement within 2 s, request withdrawn: {show(mb)}", file=sys.stderr)
    return 3


if __name__ == "__main__":
    sys.exit(main())
