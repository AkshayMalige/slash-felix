#!/usr/bin/env python3
"""Card tests of the FELIX SLASH shell, from one menu.

Runs the test programs of felix/examples and felix/tools one at a time, each as its own process,
writes one log per test and a summary into a folder per session. Before a kernel image is loaded
it checks that the card runs a SLASH shell, that the vbin was linked against exactly that shell
(<vbin>.shell_id, written by felix/scripts/build_examples.sh) and that the GT streams are held
(a kernel load fails while they run).

  felix_test.py                   menu
  felix_test.py list              tests, sets and what is ready
  felix_test.py run <test|set>... without the menu; exit 0 if everything passed
"""
import argparse
import os
import re
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
EXAMPLES = REPO / "felix" / "examples"
TOOLS = REPO / "felix" / "tools"
GT_LINK = TOOLS / "gt_link" / "build" / "gt_link"
DDR_CAPACITY = TOOLS / "ddr_capacity" / "build" / "ddr_capacity"
MONITOR = TOOLS / "monitor" / "felix_monitor.py"

# vbin -> example folder that builds it (felix/examples/<folder>/build/<vbin>)
VBIN_SRC = {
    "axilite_hw.vbin": "00_axilite",
    "aximm_hw.vbin": "01_aximm",
    "aximm_ddr23_hw.vbin": "01_aximm",
    "test_felix_hw.vbin": "04_test_felix",
    "clock_range_hw.vbin": "06_clock_range",
    "reg_window_hw.vbin": "07_reg_window",
    "gt_loopback_hw.vbin": "08_gt_loopback",
}

# a quad as after boot: streams held, no loopback, PRBS and polarity off (gt_link status line)
HELD = "CTRL 0x100 LOOPBACK 0x000 TX_PRBS 0x0000 RX_PRBS 0x0000 POLARITY 0x00"
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def paint(word):
    if not sys.stdout.isatty():
        return word
    c = {"PASS": "32", "FAIL": "31", "INFO": "33", "SKIP": "33"}.get(word.split()[0], "1")
    return "\x1b[%sm%s\x1b[0m" % (c, word)


class ShellId:
    """Shell build ID: the first 15 hex digits of the commit it was built from; hi bit 31 set when the
    tree had uncommitted changes, bit 28 = compute shell."""

    def __init__(self, lo, hi):
        self.lo, self.hi = lo, hi

    @classmethod
    def parse(cls, text):
        try:
            lo, hi = (int(x, 16) for x in text.split()[:2])
        except ValueError:
            return None
        return cls(lo, hi)

    def __eq__(self, other):
        return isinstance(other, ShellId) and (self.lo, self.hi) == (other.lo, other.hi)

    def __str__(self):
        s = "%07x%08x" % (self.hi & 0x0FFFFFFF, self.lo)
        return s + (" (uncommitted changes)" if self.hi & 0x80000000 else "")


def read_card(bdf):
    """Build ID of the shell on the card, or None if the card does not answer as a SLASH compute shell."""
    vals = []
    for off in ("0x20000", "0x20008"):
        try:
            out = subprocess.run(["v80-smi", "debug", "bar-poke", "-d", bdf, "-b", "4", "-r", "-x", off],
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30).stdout
        except (OSError, subprocess.TimeoutExpired):
            return None
        last = ([ln.strip() for ln in out.splitlines() if ln.strip()] or [""])[-1]
        if not re.fullmatch(r"0x[0-9a-fA-F]{1,8}", last):
            return None
        vals.append(int(last, 16))
    sid = ShellId(*vals)
    return sid if sid.hi != 0xFFFFFFFF and sid.hi & 0x10000000 else None


def vrtd_state():
    try:
        return subprocess.run(["systemctl", "is-active", "vrtd"], stdout=subprocess.PIPE, text=True,
                              timeout=10).stdout.strip() or "unknown"
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"


def pcie_link(bdf):
    d = Path("/sys/bus/pci/devices") / (bdf + ".0")
    try:
        return (d / "current_link_speed").read_text().strip(), (d / "current_link_width").read_text().strip()
    except OSError:
        return "", ""


def default_logs(args):
    if args.logs:
        return Path(args.logs)
    if os.environ.get("FELIX_TEST_LOGS"):
        return Path(os.environ["FELIX_TEST_LOGS"])
    lab = REPO.parent / "felix_tests"
    return lab / "test_runs" if lab.is_dir() else Path.home() / "felix_test_logs"


# ---- output checks: (program output, exit code) -> (ok, note) ----

def check_gt_status(out, rc):
    if "No GT quad" in out:
        return True, "no GT quads in this shell"
    blocks = re.split(r"(?m)^(?=Quad \d+ )", out)[1:]
    if not blocks:
        return False, "no quad listed (exit %d)" % rc
    bad = []
    for b in blocks:
        bank = b.split()[1]
        ref = re.search(r"reference (\d+)", b)
        if "power good 1, TX reset done 1, RX reset done 1" not in b:
            bad.append(bank + " not out of reset")
        elif not ref or not 156000 <= int(ref.group(1)) <= 156500:
            bad.append(bank + " reference clock")
        elif HELD not in b:
            bad.append(bank + " streams not held")
    return not bad, ", ".join(bad) or "%d quads: reference clock, reset done, streams held" % len(blocks)


def check_map_identity(out, rc):
    rows = re.findall(r"(?m)^\s*TX (\S+)\s+-> (.*)$", out)
    if not rows:
        return False, "no lane map (exit %d)" % rc
    bad = [tx for tx, rx in rows if rx.strip() not in ("RX " + tx, "RX %s (inverted)" % tx)]
    if bad:
        return False, "not back on itself: " + ", ".join(bad)
    return True, "all %d TX lanes back on themselves" % len(rows)


def check_firefly(out, rc):
    missing = [m for m in ("FireFly 1 TX", "FireFly 1 RX", "FireFly 2 TX", "FireFly 2 RX")
               if not re.search(re.escape(m) + r"\s+present", out)]
    return not missing and rc == 0, "not present: " + ", ".join(missing) if missing else "4 modules present"


class Runner:
    def __init__(self, args):
        self.args = args
        self.bdf = args.bdf
        self.log_root = default_logs(args)
        self.run_dir = None
        self.seq = 0
        self.results = []          # (test, result, seconds, log file)
        self.gt_seconds = args.seconds
        self.card = None
        self.log = None
        self.steps = []            # (label, result, note) of the running test
        self.stop = False          # Ctrl-C during a test: end the set

    # ---- paths and readiness ----

    def vbin(self, name):
        if self.args.vbins:
            return Path(self.args.vbins) / name
        return EXAMPLES / VBIN_SRC[name] / "build" / name

    def vbin_problem(self, name):
        """(short, long) reason why the vbin cannot be loaded on the card now, or None."""
        p = self.vbin(name)
        if not p.is_file():
            return "no vbin", "%s not found (build: felix/scripts/build_examples.sh %s)" % (p, VBIN_SRC[name])
        if self.args.any_shell:
            return None
        stamp = Path(str(p) + ".shell_id")
        sid = ShellId.parse(stamp.read_text()) if stamp.is_file() else None
        if sid is None:
            return "no shell ID", "%s has no %s: relink it with build_examples.sh %s, or use --any-shell" % (
                p, stamp.name, VBIN_SRC[name])
        if self.card is None:
            return "card?", "the card's shell is unknown"
        if sid != self.card:
            return "other shell", "%s was linked for shell %s, the card runs %s: relink with build_examples.sh %s" % (
                p.name, sid, self.card, VBIN_SRC[name])
        return None

    def test_problem(self, test):
        for prog in test.programs:
            if not prog.is_file():
                return "not built"
        for v in test.vbins:
            pr = self.vbin_problem(v)
            if pr:
                return pr[0]
        return None

    # ---- logging ----

    def write(self, text):
        self.log.write(text)
        self.log.flush()

    def record(self, label, result, note=""):
        """result: PASS, FAIL, INFO (never fails the test) or SKIP"""
        self.steps.append((label, result, note))
        self.write("### %s: %s %s\n" % (label, result, note))
        print("  %-58s %s %s" % (label, paint(result), note))

    # ---- running programs ----

    def _on_sigint(self, *_):
        self.stop = True

    def capture(self, argv):
        """Runs a short program quietly (log only); returns (exit code, output)."""
        self.write("### %s\n" % " ".join(map(str, argv)))
        try:
            p = subprocess.run([str(a) for a in argv], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, errors="replace", timeout=120, cwd=self.run_dir)
        except (OSError, subprocess.TimeoutExpired) as e:
            self.write("%s\n" % e)
            return -1, str(e)
        out = ANSI.sub("", p.stdout)
        self.write(out)
        return p.returncode, out

    def step(self, label, argv, vbin=None, check=None, info=False, sigint_after=None):
        """Runs one program with its output on the screen and in the log. PASS = exit code 0, or what
        check(output, exit code) says. vbin: the image the program loads (checked first, streams held
        before the load). sigint_after: Ctrl-C to the program after that many seconds."""
        if self.stop:
            return self.record(label, "SKIP", "interrupted")
        exe = Path(argv[1] if argv[0] == sys.executable else argv[0])
        if not exe.is_file():
            return self.record(label, "FAIL", "not built: %s" % exe)
        if vbin:
            pr = self.vbin_problem(vbin)
            if pr:
                return self.record(label, "FAIL", pr[1])
            if not self.ensure_held():
                return self.record(label, "FAIL", "GT quads not readable or not held after gt_link off (see log)")
        print("--- %s" % label)
        self.write("\n### %s\n### %s\n" % (label, " ".join(map(str, argv))))
        since = time.strftime("%Y-%m-%d %H:%M:%S")
        out, fired = [], []
        p = subprocess.Popen(["stdbuf", "-oL", "-eL"] + [str(a) for a in argv], stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, errors="replace", bufsize=1, cwd=self.run_dir)

        def interrupt():
            fired.append(True)
            p.send_signal(signal.SIGINT)

        timer = threading.Timer(sigint_after, interrupt) if sigint_after else None
        if timer:
            timer.start()
        for line in p.stdout:
            line = ANSI.sub("", line)
            out.append(line)
            self.log.write(line)
            if self.args.verbose or "] [DEBUG]" not in line:
                sys.stdout.write(line)
                sys.stdout.flush()
        rc = p.wait()
        if timer:
            timer.cancel()
        text = "".join(out)
        if self.stop:
            ok, note = False, "interrupted (exit %d)" % rc
        elif sigint_after:
            ok = bool(fired)
            note = ("stopped with Ctrl-C after %g s (exit %d)" % (sigint_after, rc) if fired
                    else "ended before the Ctrl-C (exit %d)" % rc)
        elif check:
            ok, note = check(text, rc)
        else:
            ok, note = rc == 0, "exit %d" % rc
        if vbin:
            _, j = self.capture(["journalctl", "-u", "vrtd", "--since", since, "--no-pager", "-o", "cat"])
            loads = re.findall(r"Design write (completed successfully|failed|transferred but PF2 refresh failed)", j)
            good = loads.count("completed successfully")
            if loads:
                note += "; vrtd: %d load(s) completed, %d failed" % (good, len(loads) - good)
                ok = ok and good == len(loads)
        return self.record(label, "INFO" if info else ("PASS" if ok else "FAIL"), note)

    def quads_held(self):
        """(number of quads, number in the boot state) from gt_link status; (0, 0) without quads."""
        rc, out = self.capture([GT_LINK, self.bdf, "status"])
        if "No GT quad" in out:
            return 0, 0
        if rc != 0:
            return -1, 0
        return len(re.findall(r"(?m)^Quad \d+ ", out)), out.count(HELD)

    def ensure_held(self):
        if not GT_LINK.is_file():
            return False
        n, held = self.quads_held()
        if n >= 0 and held == n:
            return True
        print("  GT quads not in the boot state (%d of %d): gt_link off" % (held, n))
        self.capture([GT_LINK, self.bdf, "off"])
        n, held = self.quads_held()
        return n >= 0 and held == n

    def held_step(self, label):
        """The test itself: are the quads back in the boot state? (then fixed for the next steps)"""
        if self.stop:
            return self.record(label, "SKIP", "interrupted")
        if not GT_LINK.is_file():
            return self.record(label, "FAIL", "not built: %s" % GT_LINK)
        n, held = self.quads_held()
        ok = n >= 0 and held == n
        self.record(label, "PASS" if ok else "FAIL",
                    "no GT quads" if n == 0 else "gt_link status failed (see log)" if n < 0
                    else "%d of %d quads held, PRBS/loopback/polarity off" % (held, n))
        if not ok:
            self.ensure_held()

    def kernel(self, label, ex, vbin, extra=(), **kw):
        return self.step(label, [EXAMPLES / ex / "build" / ex, self.bdf, self.vbin(vbin), *extra], vbin=vbin, **kw)

    # ---- tests and sets ----

    def open_run_dir(self):
        if self.run_dir:
            return
        self.run_dir = self.log_root / time.strftime("%Y%m%d_%H%M%S")
        self.run_dir.mkdir(parents=True, exist_ok=True)
        git = subprocess.run(["git", "-C", str(REPO), "describe", "--always", "--dirty"], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True).stdout.strip()
        with open(self.run_dir / "summary.txt", "a") as f:
            f.write("FELIX card tests %s\n  card %s, shell %s\n  programs from %s (%s)\n  vbins from %s\n\n" % (
                time.strftime("%Y-%m-%d %H:%M:%S"), self.bdf, self.card or "not readable", REPO, git or "?",
                self.args.vbins or "felix/examples/*/build"))

    def run_test(self, test):
        self.card = read_card(self.bdf)
        self.open_run_dir()
        self.seq += 1
        name = "%02d_%s.log" % (self.seq, test.key)
        self.steps = []
        t0 = time.time()
        print("\n=== %s: %s" % (test.key, test.desc))
        with open(self.run_dir / name, "w") as self.log:
            self.write("%s  %s: %s\ncard %s, shell %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), test.key,
                                                            test.desc, self.bdf, self.card or "not readable"))
            if self.card is None and test.key != "status":
                self.record("card", "FAIL", "no SLASH shell answers on %s (FELIX mode, rebooting, or vrtd down)" % self.bdf)
            else:
                try:
                    test.func(self)
                except Exception as e:  # a bug in this script ends the test, not the session
                    self.record("felix_test.py", "FAIL", "%s: %s" % (type(e).__name__, e))
            results = [r for _, r, _ in self.steps]
            result = "FAIL" if "FAIL" in results or not results else ("SKIP" if "SKIP" in results else "PASS")
            secs = time.time() - t0
            self.write("\n%s: %s (%.0f s)\n" % (test.key, result, secs))
        self.log = None
        self.results.append((test.key, result, secs, name))
        with open(self.run_dir / "summary.txt", "a") as f:
            f.write("  %s  %-12s %-4s %5.0f s  %s\n" % (time.strftime("%H:%M:%S"), test.key, result, secs, name))
        print("=== %s: %s (%.0f s) -> %s" % (test.key, paint(result), secs, self.run_dir / name))
        return result

    def run(self, tests, gt_seconds=None):
        # Ctrl-C reaches the running test program (its own handler holds the GT streams); here it
        # only ends the set
        self.stop = False
        self.gt_seconds = gt_seconds or self.args.seconds
        prev = signal.signal(signal.SIGINT, self._on_sigint)
        try:
            for t in tests:
                if self.stop:
                    break
                self.run_test(t)
        finally:
            signal.signal(signal.SIGINT, prev)
            self.gt_seconds = self.args.seconds
        self.summary()

    def summary(self):
        if not self.results:
            return
        print("\nResults this session (%s):" % self.run_dir)
        for key, result, secs, name in self.results:
            print("  %-12s %s %5.0f s  %s" % (key, paint("%-4s" % result), secs, name))


# ---- the tests ----

def t_status(r):
    st = vrtd_state()
    r.record("vrtd service", "PASS" if st == "active" else "FAIL", st)
    r.record("SLASH shell on the card", "PASS" if r.card else "FAIL",
             "built from commit %s" % r.card if r.card else "build ID not readable")
    speed, width = pcie_link(r.bdf)
    r.record("PCIe link Gen5 x8", "PASS" if speed.startswith("32.0") and width == "8" else "FAIL",
             "%s x%s" % (speed or "?", width or "?"))
    if r.card is None:
        return
    r.step("transceivers and FireFly lines (gt_link status)", [GT_LINK, r.bdf, "status"], check=check_gt_status)
    r.step("board sensors (felix_monitor --check)", [sys.executable, MONITOR, "--check", "--bdf", r.bdf + ".0"])


def t_ddr_capacity(r):
    r.step("ddr_capacity: whole DDR from the host", [DDR_CAPACITY, "-d", r.bdf])


def t_axilite(r):
    r.kernel("00_axilite", "00_axilite", "axilite_hw.vbin")


def t_aximm(r):
    r.kernel("01_aximm, kernels on DDR0/DDR1", "01_aximm", "aximm_hw.vbin")
    r.kernel("01_aximm, kernels on DDR2/DDR3", "01_aximm", "aximm_ddr23_hw.vbin")


def t_registers(r):
    r.kernel("07_reg_window", "07_reg_window", "reg_window_hw.vbin")


def t_clocks(r):
    r.kernel("06_clock_range", "06_clock_range", "clock_range_hw.vbin")


def t_memory(r):
    r.kernel("04_test_felix", "04_test_felix", "test_felix_hw.vbin")


def t_gt(r):
    r.step("gt_link prbs: GT PRBS-31 in-chip, 10 s", [GT_LINK, r.bdf, "prbs"])
    r.step("gt_link map: every TX lane back on itself", [GT_LINK, r.bdf, "map"], check=check_map_identity)
    r.kernel("08_gt_loopback: kernel path, %g s long run" % r.gt_seconds, "08_gt_loopback", "gt_loopback_hw.vbin",
             ["%g" % r.gt_seconds])
    r.held_step("quads back in the boot state")


def t_gt_fibre(r):
    r.step("FireFly modules present", [GT_LINK, r.bdf, "firefly"], check=check_firefly)
    r.step("gt_link prbs --external: GT PRBS-31 over the fibres", [GT_LINK, r.bdf, "prbs", "--external"])
    r.step("gt_link map --external: fibre lane order", [GT_LINK, r.bdf, "map", "--external"], info=True)
    r.kernel("08_gt_loopback --external, %g s long run" % r.gt_seconds, "08_gt_loopback", "gt_loopback_hw.vbin",
             ["%g" % r.gt_seconds, "--external"])
    r.held_step("quads back in the boot state")


def t_after_gt(r):
    gt, ax = "gt_loopback_hw.vbin", "axilite_hw.vbin"
    r.kernel("1. 00_axilite", "00_axilite", ax)
    r.kernel("2. 08_gt_loopback, 5 s long run", "08_gt_loopback", gt, ["5"])
    r.held_step("3. quads back in the boot state")
    r.kernel("4. 00_axilite: load after a GT run", "00_axilite", ax)
    r.kernel("5. 08_gt_loopback --park: generators on held quads", "08_gt_loopback", gt, ["--park"])
    r.kernel("6. 00_axilite: load with TX data parked", "00_axilite", ax)
    r.step("7. gt_link prbs, Ctrl-C after 3 s", [GT_LINK, r.bdf, "prbs"], sigint_after=3)
    r.held_step("8. quads back in the boot state")
    r.kernel("9. 08_gt_loopback, Ctrl-C after 25 s (long run)", "08_gt_loopback", gt, ["40"], sigint_after=25)
    r.held_step("10. quads back in the boot state")
    r.kernel("11. 00_axilite: load after Ctrl-C", "00_axilite", ax)


class Test:
    def __init__(self, key, group, desc, func, programs=(), vbins=()):
        self.key, self.group, self.desc, self.func = key, group, desc, func
        self.programs, self.vbins = list(programs), list(vbins)


def ex(name):
    return EXAMPLES / name / "build" / name


TESTS = [
    Test("status", "Card, no kernel", "build ID, vrtd, PCIe link, transceivers, FireFly lines, sensors",
         t_status, [GT_LINK, MONITOR]),
    Test("ddr_capacity", "Card, no kernel", "the whole DDR written and read from the host (~40 s)",
         t_ddr_capacity, [DDR_CAPACITY]),
    Test("axilite", "Kernels", "kernel control, kernel-to-kernel stream (00_axilite)",
         t_axilite, [ex("00_axilite")], ["axilite_hw.vbin"]),
    Test("aximm", "Kernels", "kernel DMA on the DDR0-DDR3 ports (01_aximm)",
         t_aximm, [ex("01_aximm")], ["aximm_hw.vbin", "aximm_ddr23_hw.vbin"]),
    Test("registers", "Kernels", "host writes reach kernel registers 0x40-0xBF (07_reg_window)",
         t_registers, [ex("07_reg_window")], ["reg_window_hw.vbin"]),
    Test("clocks", "Kernels", "kernel clock 100-400 MHz (06_clock_range)",
         t_clocks, [ex("06_clock_range")], ["clock_range_hw.vbin"]),
    Test("memory", "Kernels", "QDMA, kernel DDR access, bandwidths (04_test_felix)",
         t_memory, [ex("04_test_felix")], ["test_felix_hw.vbin"]),
    Test("gt", "Transceivers", "in-chip loopback: gt_link prbs + map, kernel path (08)",
         t_gt, [GT_LINK, ex("08_gt_loopback")], ["gt_loopback_hw.vbin"]),
    Test("gt_fibre", "Transceivers", "over the fibre loops: the same (needs the fibres)",
         t_gt_fibre, [GT_LINK, ex("08_gt_loopback")], ["gt_loopback_hw.vbin"]),
    Test("after_gt", "After transceiver runs", "kernel loads after a GT run, with TX parked, after Ctrl-C",
         t_after_gt, [GT_LINK, ex("00_axilite"), ex("08_gt_loopback")], ["axilite_hw.vbin", "gt_loopback_hw.vbin"]),
]
BY_KEY = {t.key: t for t in TESTS}

# set -> (menu letter, tests, long run of 08 in s or None for --seconds)
SETS = {
    "short": ("s", ["status", "axilite", "registers", "gt"], 10),
    "all": ("a", ["status", "ddr_capacity", "axilite", "aximm", "registers", "clocks", "memory", "gt",
                  "after_gt"], None),
    "fibre": ("f", ["status", "gt_fibre"], None),
}


def resolve(words):
    """Test keys, menu numbers, set names or set letters -> (tests, 08 long run or None); None if unknown."""
    tests, secs = [], None
    for w in words:
        w = w.strip().lower()
        sets = {k: v for k, v in SETS.items() if w in (k, v[0])}
        if sets:
            _, keys, s = next(iter(sets.values()))
            tests += [BY_KEY[k] for k in keys]
            secs = s or secs
        elif w in BY_KEY:
            tests.append(BY_KEY[w])
        elif w.isdigit() and 1 <= int(w) <= len(TESTS):
            tests.append(TESTS[int(w) - 1])
        else:
            print("unknown: %s" % w)
            return None, None
    return tests, secs


def show(r, header=True):
    if header:
        r.card = read_card(r.bdf)
        speed, width = pcie_link(r.bdf)
        print("\nFELIX card tests   card %s   shell %s   vrtd %s   link %s x%s" % (
            r.bdf, r.card or "NOT READABLE (not in SLASH mode?)", vrtd_state(), speed or "?", width or "?"))
        print("logs: %s" % (r.run_dir or r.log_root / "<date_time>"))
    group = None
    for i, t in enumerate(TESTS, 1):
        if t.group != group:
            group = t.group
            print("  %s" % group)
        pr = r.test_problem(t)
        print("   %2d  %-13s %-60s %s" % (i, t.key, t.desc, "" if pr is None else "[%s]" % pr))
    print("  Sets")
    for name, (letter, keys, secs) in SETS.items():
        print("    %s  %-12s %s%s" % (letter, name, " ".join(keys), " (08 long run %d s)" % secs if secs else ""))


def menu(r):
    while True:
        show(r)
        try:
            choice = input("\nTests or a set (e.g. 3 or 3 8 or a), x to exit: ").split()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not choice:
            continue
        if choice[0].lower() in ("x", "q", "quit", "exit"):
            break
        tests, secs = resolve(choice)
        if tests:
            r.run(tests, secs)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("cmd", nargs="?", default="menu", choices=["menu", "list", "run"])
    p.add_argument("names", nargs="*", help="for run: tests (key or number) and sets")
    p.add_argument("--bdf", default="0000:41:00", help="the card (default 0000:41:00)")
    p.add_argument("--vbins", help="take the vbins (and their .shell_id) from this folder")
    p.add_argument("--logs", help="log folder (default $FELIX_TEST_LOGS, else felix_tests/test_runs next to "
                                  "the repo if that exists, else ~/felix_test_logs)")
    p.add_argument("--seconds", type=float, default=40, help="long run of 08_gt_loopback (default 40)")
    p.add_argument("--any-shell", action="store_true", help="load vbins without a matching shell ID")
    p.add_argument("-v", "--verbose", action="store_true", help="show VRT debug lines on the screen too")
    args = p.parse_args()
    r = Runner(args)
    if args.cmd == "list":
        show(r)
        return 0
    if args.cmd == "run":
        tests, secs = resolve(args.names)
        if not tests:
            p.error("run needs tests or sets: " + ", ".join([t.key for t in TESTS] + list(SETS)))
        r.run(tests, secs)
        return 0 if r.results and all(res == "PASS" for _, res, _, _ in r.results) else 1
    menu(r)
    return 0


if __name__ == "__main__":
    sys.exit(main())
