#!/usr/bin/env python3
import argparse
import mmap
import os
import re
import sys

SLASH_IDS = {("0x10ee", "0x50b4"), ("0x10ee", "0x50c1"), ("0x10ee", "0x50c2")}
FELIX_VENDOR = "0x10dc"
FELIX_REGS = [
    ("REG_MAP_VERSION", 0x000, 0xFFFF),
    ("BOARD_ID_TIMESTAMP", 0x010, 0xFFFFFFFFFF),
    ("GIT_COMMIT_TIME", 0x030, 0xFFFFFFFFFF),
    ("GIT_COMMIT_NUMBER", 0x050, 0xFFFFFFFF),
    ("GIT_HASH", 0x060, 0xFFFFFFFF),
    ("CARD_TYPE", 0x0A0, 0xFFFFFFFFFFFFFFFF),
]
SYS = "/sys/bus/pci/devices"


def rd(path):
    with open(path) as f:
        return f.read().strip()


def root_port(bdf, given):
    if given:
        return given
    if os.path.exists(f"{SYS}/{bdf}.0"):
        return os.path.basename(os.path.dirname(os.path.realpath(f"{SYS}/{bdf}.0")))
    if os.path.exists("/run/felix-modeswitch.rootport"):
        return rd("/run/felix-modeswitch.rootport")
    return None


def devices(rp):
    return sorted(d for d in os.listdir(f"{SYS}/{rp}") if re.fullmatch(r"[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]", d))


def felix_regs(dev):
    base = f"{SYS}/{dev}"
    was_enabled = rd(f"{base}/enable") != "0"
    if not was_enabled:
        with open(f"{base}/enable", "w") as f:
            f.write("1")
    try:
        fd = os.open(f"{base}/resource2", os.O_RDONLY | os.O_SYNC)
        mm = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0)
        os.close(fd)
        q = memoryview(mm).cast("Q")
        vals = {name: q[off // 8] & mask for name, off, mask in FELIX_REGS}
        del q
        mm.close()
    finally:
        if not was_enabled:
            with open(f"{base}/enable", "w") as f:
                f.write("0")
    return vals


def main():
    ap = argparse.ArgumentParser(description="Read-only: which design is the FELIX card running (SLASH or FELIX)")
    ap.add_argument("--bdf", default=os.environ.get("BDF", "0000:41:00"))
    ap.add_argument("--root-port")
    ap.add_argument("--expect", choices=["slash", "felix"])
    ap.add_argument("--expect-card-type", type=int, default=155)
    ap.add_argument("--expect-git-hash", type=lambda s: int(s, 16))
    a = ap.parse_args()

    rp = root_port(a.bdf, a.root_port)
    if not rp:
        print(f"cannot find the root port of {a.bdf}; pass --root-port")
        return 2
    devs = devices(rp)
    ok = True
    ids = set()
    for dev in devs:
        base = f"{SYS}/{dev}"
        vid, did = rd(f"{base}/vendor"), rd(f"{base}/device")
        ids.add((vid, did))
        drv = os.path.basename(os.path.realpath(f"{base}/driver")) if os.path.exists(f"{base}/driver") else "none"
        print(f"{dev}  {vid[2:]}:{did[2:]}  driver {drv}  link {rd(f'{base}/current_link_speed')} x{rd(f'{base}/current_link_width')}")
        if vid == FELIX_VENDOR and os.path.exists(f"{base}/resource2"):
            if os.geteuid() != 0:
                print("    (run as root to read the FELIX registers)")
                continue
            vals = felix_regs(dev)
            for name, _, _ in FELIX_REGS:
                print(f"    {name:<20} 0x{vals[name]:x}")
            if vals["CARD_TYPE"] != a.expect_card_type:
                print(f"    CARD_TYPE is {vals['CARD_TYPE']}, expected {a.expect_card_type}")
                ok = False
            if a.expect_git_hash is not None and vals["GIT_HASH"] != a.expect_git_hash:
                print(f"    GIT_HASH is 0x{vals['GIT_HASH']:x}, expected 0x{a.expect_git_hash:x}")
                ok = False

    if not devs:
        mode = "NONE"
    elif ids <= SLASH_IDS and ("0x10ee", "0x50b4") in ids:
        mode = "SLASH"
    elif any(v == FELIX_VENDOR for v, _ in ids):
        mode = "FELIX"
    else:
        mode = "UNKNOWN"
    print(f"root port {rp}: MODE: {mode}")
    if mode in ("NONE", "UNKNOWN") or (a.expect and mode != a.expect.upper()):
        return 2
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
