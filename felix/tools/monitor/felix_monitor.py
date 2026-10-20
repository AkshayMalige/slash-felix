#!/usr/bin/env python3
"""Live view of the FELIX FLX-155 board sensors in SLASH mode.

Data path: board chips -> AMC (felix_sensors.c, polled every 100 ms) -> GCQ
-> ami driver -> hwmon "Alveo" in sysfs, which this script reads.
Views: curses table with trend (default), --once text, --web page with plots.
"V x I" power is computed here, because ami only exports Total_Power.
"""

import argparse
import collections
import curses
import json
import locale
import os
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

TYPES = [
    ("temp", "TEMPERATURE", "C", 1e-3, 1),
    ("in", "VOLTAGE", "V", 1e-3, 3),
    ("curr", "CURRENT", "A", 1e-3, 3),
    ("power", "POWER (AMC)", "W", 1e-6, 2),
]
VXI = ("vxi", "POWER V x I (host)", "W", 2)
VALID = "Sensor Present and Valid"
RP_CACHE = "/run/felix-modeswitch.rootport"
BDF_RE = re.compile(r"^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$")
SPARK_UTF = "▁▂▃▄▅▆▇█"
SPARK_ASCII = "_.-:=+*#"
TREND = 24


def rd(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def num(path, scale):
    v = rd(path)
    try:
        return int(v) * scale
    except (TypeError, ValueError):
        return None


class Card:
    def __init__(self, bdf):
        self.bdf = bdf
        self.dev = "/sys/bus/pci/devices/" + bdf
        self.rp = None
        self.vrtd = "?"
        self.vrtd_t = 0

    def root_port(self):
        if os.path.exists(self.dev):
            self.rp = os.path.basename(os.path.dirname(os.path.realpath(self.dev)))
        elif self.rp is None:
            rp = rd(RP_CACHE)
            sec = rd("/sys/bus/pci/devices/%s/secondary_bus_number" % rp) if rp else None
            if sec is not None and int(sec) == int(self.bdf.split(":")[1], 16):
                self.rp = rp
        return self.rp

    def functions(self):
        rp = self.root_port()
        if not rp:
            return []
        try:
            names = os.listdir("/sys/bus/pci/devices/" + rp)
        except OSError:
            return []
        out = []
        for n in sorted(names):
            if BDF_RE.match(n):
                p = "/sys/bus/pci/devices/" + n
                ven, dev = rd(p + "/vendor"), rd(p + "/device")
                if ven and dev:
                    out.append((n, ven[2:] + ":" + dev[2:]))
        return out

    def mode(self):
        ids = [i for _, i in self.functions()]
        if not ids:
            return "NONE"
        if "10ee:50b4" in ids:
            return "SLASH"
        if any(i.startswith("10dc:") for i in ids):
            return "FELIX"
        return "UNKNOWN"

    def link(self):
        s, w = rd(self.dev + "/current_link_speed"), rd(self.dev + "/current_link_width")
        return "%s x%s" % (s, w) if s and w else "-"

    def amc(self):
        v, st = rd(self.dev + "/amc_version"), rd(self.dev + "/dev_state")
        return (v.split()[0] if v else "-"), (st or "-")

    def vrtd_state(self):
        if time.time() - self.vrtd_t > 5:
            try:
                r = subprocess.run(["systemctl", "is-active", "vrtd.service"], capture_output=True, text=True, timeout=2)
                self.vrtd = r.stdout.strip() or "?"
            except (OSError, subprocess.SubprocessError):
                self.vrtd = "?"
            self.vrtd_t = time.time()
        return self.vrtd

    def hwmon(self):
        if not os.path.exists(self.dev):
            return None
        real = os.path.realpath(self.dev)
        for h in sorted(os.listdir("/sys/class/hwmon")):
            p = "/sys/class/hwmon/" + h
            if rd(p + "/name") == "Alveo" and os.path.realpath(p + "/device") == real:
                return p
        return None


def read_sensors(hw):
    out = []
    try:
        files = os.listdir(hw)
    except OSError:
        return out
    for prefix, title, unit, scale, dec in TYPES:
        idx = sorted(int(m.group(1)) for f in files for m in [re.match(prefix + r"(\d+)_label$", f)] if m)
        for i in idx:
            b = "%s/%s%d_" % (hw, prefix, i)
            hi = "input_highest" if prefix == "power" else "highest"
            out.append({
                "type": prefix, "title": title, "unit": unit, "dec": dec,
                "label": rd(b + "label") or "%s%d" % (prefix, i),
                "value": num(b + "input", scale),
                "amc_max": num(b + hi, scale),
                "avg": num(b + "average", scale),
                "warn": num(b + "max", scale),
                "crit": num(b + "lcrit", scale),
                "fatal": num(b + "crit", scale),
                "alarm": [rd(b + a) == "1" for a in ("max_alarm", "lcrit_alarm", "crit_alarm")],
                "status": rd(b + "status") or "-",
            })
    return out


def add_vxi(sensors):
    volts = {s["label"]: s for s in sensors if s["type"] == "in"}
    out = []
    for s in sensors:
        v = volts.get(s["label"])
        if s["type"] != "curr" or v is None:
            continue
        ok = s["status"] == VALID and v["status"] == VALID and None not in (s["value"], v["value"])
        out.append({
            "type": VXI[0], "title": VXI[1], "unit": VXI[2], "dec": VXI[3], "label": s["label"],
            "value": v["value"] * s["value"] if ok else None,
            "amc_max": None, "avg": None, "warn": None, "crit": None, "fatal": None,
            "alarm": [False, False, False], "status": VALID if ok else "-",
        })
    return [s for s in sensors if s["type"] != "power"] + out + [s for s in sensors if s["type"] == "power"]


def severity(s):
    if s["value"] is None or s["status"] != VALID:
        return -1
    v = s["value"]
    if s["alarm"][1] or s["alarm"][2] or (s["crit"] is not None and v >= s["crit"]) or \
            (s["fatal"] is not None and v >= s["fatal"]):
        return 2
    if s["alarm"][0] or (s["warn"] is not None and v >= s["warn"]):
        return 1
    return 0


def fmt(v, dec):
    return "-" if v is None else "%.*f" % (dec, v)


def key(s):
    return s["type"] + ":" + s["label"]


def spark(vals, dec, chars):
    nums = [v for v in vals if v is not None]
    if not nums:
        return ""
    lo, hi = min(nums), max(nums)
    span = max(hi - lo, abs(sum(nums) / len(nums)) * 0.01, 2 * 10 ** -dec)
    lo = (lo + hi - span) / 2
    n = len(chars)
    return "".join(" " if v is None else chars[max(0, min(n - 1, int((v - lo) / span * n)))] for v in vals)


class Monitor:
    def __init__(self, args):
        self.args = args
        self.card = Card(args.bdf)
        self.seen = {}
        self.hist = collections.deque(maxlen=max(TREND, int(args.history * 60 / args.interval)))
        self.lock = threading.Lock()
        self.last = None
        self.csv = None
        if args.csv:
            new = not os.path.exists(args.csv)
            self.csv = open(args.csv, "a")
            if new:
                self.csv.write("time,mode,type,label,value,unit,status\n")

    def reset(self):
        with self.lock:
            self.seen = {}

    def sample(self):
        c = self.card
        mode = c.mode()
        hw = c.hwmon() if mode == "SLASH" else None
        sensors = add_vxi(read_sensors(hw)) if hw else []
        amc_v, amc_st = c.amc() if mode == "SLASH" else ("-", "-")
        info = {"bdf": c.bdf, "mode": mode, "link": c.link() if mode != "NONE" else "-",
                "vrtd": c.vrtd_state(), "amc": amc_v, "amc_state": amc_st,
                "hwmon": os.path.basename(hw) if hw else "-", "interval": self.args.interval,
                "history_s": self.hist.maxlen * self.args.interval}
        now = round(time.time(), 2)
        with self.lock:
            for s in sensors:
                k = key(s)
                if s["value"] is not None:
                    lo, hi = self.seen.get(k, (s["value"], s["value"]))
                    self.seen[k] = (min(lo, s["value"]), max(hi, s["value"]))
                s["min"], s["max"] = self.seen.get(k, (None, None))
                s["sev"] = severity(s)
            self.hist.append((now, {key(s): s["value"] for s in sensors}))
            self.last = (now, info, sensors)
        if self.csv:
            t = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(now))
            for s in sensors:
                self.csv.write("%s,%s,%s,%s,%s,%s,%s\n" % (t, mode, s["type"], s["label"],
                               fmt(s["value"], s["dec"] + 1), s["unit"], s["status"]))
            self.csv.flush()

    def state(self, since):
        with self.lock:
            now, info, sensors = self.last or (0, {}, [])
            return {"now": now, "info": info, "sensors": sensors,
                    "samples": [[t, v] for t, v in self.hist if t > since]}

    def trend(self, k, dec, chars):
        with self.lock:
            vals = [v.get(k) for _, v in list(self.hist)[-TREND:]]
        return spark(vals, dec, chars)

    def lines(self, chars=None):
        self.sample()
        now, info, sensors = self.last
        tw = TREND + 2 if chars else 0
        out = [
            ("FELIX FLX-155 monitor   %s   refresh %g s   q quit, r reset min/max" %
             (time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now)), self.args.interval), 3),
            ("card %s   mode %s   link %s   vrtd %s   AMC %s (%s)   sensors %s" %
             (info["bdf"], info["mode"], info["link"], info["vrtd"], info["amc"], info["amc_state"],
              info["hwmon"]), 3),
            ("", 0),
        ]
        if info["mode"] != "SLASH":
            msg = {"FELIX": "card is in FELIX mode: the AMC sensors exist only in SLASH mode",
                   "NONE": "card not visible on PCIe (link down or switching)"}.get(info["mode"], "unknown design on the card")
            return out + [(msg, -1)]
        if not sensors:
            return out + [("SLASH mode, but no Alveo sensor device yet (ami driver not bound, or AMC not answering)", -1)]
        head = "%-20s %10s %-*s %10s %10s %10s %10s %9s %9s %9s  %s" % (
            "", "now", tw, "  trend" if chars else "", "min", "max", "AMC max", "AMC avg", "warning", "critical",
            "fatal", "status")
        last = None
        for s in sensors:
            if s["type"] != last:
                if last is not None:
                    out.append(("", 0))
                t = "%s (%s)" % (s["title"], s["unit"])
                out.append((t + head[len(t):], 3))
                last = s["type"]
            d = s["dec"]
            st = "ok" if s["status"] == VALID else s["status"]
            if s["sev"] == 2:
                st = "CRITICAL" if s["status"] == VALID else st
            elif s["sev"] == 1:
                st = "WARNING"
            tr = "  " + self.trend(key(s), d, chars) if chars else ""
            out.append(("  %-18s %10s %-*s %10s %10s %10s %10s %9s %9s %9s  %s" % (
                s["label"][:18], fmt(s["value"], d), tw, tr, fmt(s["min"], d), fmt(s["max"], d),
                fmt(s["amc_max"], d), fmt(s["avg"], d),
                fmt(s["warn"], 1), fmt(s["crit"], 1), fmt(s["fatal"], 1), st), s["sev"]))
        return out


def run_curses(stdscr, mon, chars):
    curses.curs_set(0)
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_GREEN, -1)
    curses.init_pair(2, curses.COLOR_YELLOW, -1)
    curses.init_pair(3, curses.COLOR_RED, -1)
    curses.init_pair(4, curses.COLOR_CYAN, -1)
    attr = {0: curses.color_pair(1), 1: curses.color_pair(2) | curses.A_BOLD,
            2: curses.color_pair(3) | curses.A_BOLD, 3: curses.color_pair(4), -1: curses.A_DIM}
    stdscr.timeout(int(mon.args.interval * 1000))
    while True:
        lines = mon.lines(chars)
        stdscr.erase()
        h, w = stdscr.getmaxyx()
        for y, (text, sev) in enumerate(lines[:h - 1]):
            try:
                stdscr.addnstr(y, 0, text, w - 1, attr.get(sev, 0) if text else 0)
            except curses.error:
                pass
        stdscr.refresh()
        k = stdscr.getch()
        if k in (ord("q"), ord("Q")):
            return
        if k in (ord("r"), ord("R")):
            mon.reset()


PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>FELIX Sensors</title>
<style>
:root {
  --bg: #f6f7f9; --card: #ffffff; --fg: #1c2330; --muted: #677285; --line: #e2e6ec;
  --ok: #1f8a4c; --warn: #b7791f; --crit: #c53030; --off: #9aa3b2; --plot: #2b6cb0; --fill: rgba(43,108,176,.10);
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #11151c; --card: #1a2029; --fg: #e6e9ef; --muted: #8b95a7; --line: #2a323e;
    --ok: #48bb78; --warn: #ecc94b; --crit: #fc8181; --off: #5c6676; --plot: #63b3ed; --fill: rgba(99,179,237,.12);
  }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 14px/1.4 system-ui, -apple-system, "Segoe UI", sans-serif; }
header { position: sticky; top: 0; z-index: 2; background: var(--bg); border-bottom: 1px solid var(--line); padding: 12px 16px; }
.top { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 16px; }
h1 { font-size: 18px; margin: 0; font-weight: 600; }
#dot { width: 10px; height: 10px; border-radius: 50%; background: var(--off); display: inline-block; margin-right: 6px; }
#dot.live { background: var(--ok); }
#info { color: var(--muted); font-size: 13px; }
.ctl { margin-left: auto; display: flex; gap: 4px; flex-wrap: wrap; }
button { font: inherit; font-size: 13px; padding: 4px 10px; border: 1px solid var(--line); background: var(--card); color: var(--fg); border-radius: 6px; cursor: pointer; }
button.on { border-color: var(--plot); color: var(--plot); font-weight: 600; }
main { padding: 16px; max-width: 1500px; margin: 0 auto; }
#banner { display: none; padding: 12px 14px; border-radius: 8px; background: var(--card); border: 1px solid var(--line); margin-bottom: 16px; color: var(--warn); }
.tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 12px; margin-bottom: 20px; }
.tile { background: var(--card); border: 1px solid var(--line); border-radius: 10px; padding: 12px 14px; }
.tile .k { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: .04em; }
.tile .v { font-size: 26px; font-weight: 600; font-variant-numeric: tabular-nums; margin-top: 2px; }
.tile .s { color: var(--muted); font-size: 12px; }
h2 { font-size: 13px; font-weight: 600; color: var(--muted); text-transform: uppercase; letter-spacing: .05em; margin: 22px 0 10px; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(230px, 1fr)); gap: 12px; }
.card { background: var(--card); border: 1px solid var(--line); border-left: 4px solid var(--ok); border-radius: 10px; padding: 10px 12px 8px; min-width: 0; }
.card.s1 { border-left-color: var(--warn); }
.card.s2 { border-left-color: var(--crit); }
.card.s-1 { border-left-color: var(--off); }
.row { display: flex; justify-content: space-between; align-items: baseline; gap: 8px; }
.name { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.val { font-size: 20px; font-weight: 600; font-variant-numeric: tabular-nums; white-space: nowrap; }
.unit { font-size: 13px; color: var(--muted); font-weight: 400; margin-left: 2px; }
canvas { width: 100%; height: 64px; display: block; margin: 6px 0 4px; }
.meta { color: var(--muted); font-size: 12px; font-variant-numeric: tabular-nums; display: flex; justify-content: space-between; gap: 8px; flex-wrap: wrap; }
.st { font-size: 12px; font-weight: 600; }
.st.s0 { color: var(--ok); } .st.s1 { color: var(--warn); } .st.s2 { color: var(--crit); } .st.s-1 { color: var(--off); }
footer { color: var(--muted); font-size: 12px; padding: 8px 16px 24px; max-width: 1500px; margin: 0 auto; }
@media (max-width: 520px) { .ctl { margin-left: 0; } .tile .v { font-size: 22px; } }
</style>
</head>
<body>
<header>
  <div class="top">
    <h1><span id="dot"></span>FELIX FLX-155 sensors</h1>
    <span id="info">connecting...</span>
    <div class="ctl" id="win"></div>
    <div class="ctl"><button id="pause">Pause</button></div>
  </div>
</header>
<main>
  <div id="banner"></div>
  <div class="tiles" id="tiles"></div>
  <div id="groups"></div>
</main>
<footer>Values from the card's AMC through the ami driver (hwmon). "V x I" power is computed on the host from each rail's voltage and current. Plot ranges follow the data; min/max are over the shown window.</footer>
<script>
const WINDOWS = [[120, "2 min"], [600, "10 min"], [1800, "30 min"], [3600, "1 h"]];
let win = 600, paused = false, since = 0, maxAge = 3600, interval = 2;
const series = {}, cards = {}, groups = {};
let latest = null;

function fmt(v, d) { return v === null || v === undefined ? "-" : v.toFixed(d); }
function css(n) { return getComputedStyle(document.documentElement).getPropertyValue(n).trim(); }
function stName(s) {
  if (s.status !== "Sensor Present and Valid") return s.status === "-" ? "no data" : s.status;
  return ["ok", "WARNING", "CRITICAL"][s.sev] || "ok";
}

const winBox = document.getElementById("win");
for (const [s, name] of WINDOWS) {
  const b = document.createElement("button");
  b.textContent = name;
  b.onclick = () => { win = s; for (const x of winBox.children) x.classList.toggle("on", x === b); draw(); };
  if (s === win) b.classList.add("on");
  winBox.appendChild(b);
}
document.getElementById("pause").onclick = (e) => {
  paused = !paused;
  e.target.textContent = paused ? "Resume" : "Pause";
  e.target.classList.toggle("on", paused);
};

function card(s) {
  const k = s.type + ":" + s.label;
  if (cards[k]) return cards[k];
  if (!groups[s.type]) {
    const h = document.createElement("h2");
    h.textContent = s.title + " (" + s.unit + ")";
    const g = document.createElement("div");
    g.className = "grid";
    document.getElementById("groups").append(h, g);
    groups[s.type] = g;
  }
  const el = document.createElement("div");
  el.className = "card";
  el.innerHTML = '<div class="row"><span class="name"></span><span class="val"></span></div>' +
    '<canvas></canvas><div class="meta"><span class="mm"></span><span class="st"></span></div>' +
    '<div class="meta"><span class="lim"></span></div>';
  el.querySelector(".name").textContent = s.label;
  el.querySelector(".name").title = s.label;
  groups[s.type].appendChild(el);
  return (cards[k] = { el, key: k, cv: el.querySelector("canvas") });
}

function plot(c, s) {
  const cv = c.cv, dpr = window.devicePixelRatio || 1;
  const w = cv.clientWidth, h = cv.clientHeight;
  if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) {
    cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr);
  }
  const g = cv.getContext("2d");
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  g.clearRect(0, 0, w, h);
  const d = series[c.key];
  const now = latest ? latest.now : Date.now() / 1000;
  const t0 = d && d.t.length ? Math.min(Math.max(now - win, d.t[0]), now - 10 * interval) : now - win;
  const span = now - t0;
  const pts = [];
  if (d) for (let i = 0; i < d.t.length; i++) if (d.t[i] >= t0) pts.push([d.t[i], d.v[i]]);
  const nums = pts.map(p => p[1]).filter(v => v !== null);
  let lo = 0, hi = 1, mn = null, mx = null;
  if (nums.length) {
    mn = Math.min(...nums); mx = Math.max(...nums);
    const mean = nums.reduce((a, b) => a + b, 0) / nums.length;
    const span = Math.max(mx - mn, Math.abs(mean) * 0.01, 2 * Math.pow(10, -s.dec));
    lo = (mn + mx - span) / 2 - span * 0.1; hi = lo + span * 1.2;
  }
  g.strokeStyle = css("--line"); g.lineWidth = 1;
  g.beginPath(); g.moveTo(0, h - 0.5); g.lineTo(w, h - 0.5); g.stroke();
  const X = t => (t - t0) / span * (w - 4) + 2, Y = v => h - 4 - (v - lo) / (hi - lo) * (h - 8);
  const col = s.sev === 2 ? css("--crit") : s.sev === 1 ? css("--warn") : css("--plot");
  let path = [];
  const segs = [];
  for (const [t, v] of pts) {
    if (v === null) { if (path.length) segs.push(path); path = []; continue; }
    path.push([X(t), Y(v)]);
  }
  if (path.length) segs.push(path);
  for (const sg of segs) {
    g.fillStyle = css("--fill");
    g.beginPath(); g.moveTo(sg[0][0], h);
    for (const [x, y] of sg) g.lineTo(x, y);
    g.lineTo(sg[sg.length - 1][0], h); g.closePath(); g.fill();
    g.strokeStyle = col; g.lineWidth = 1.6;
    g.beginPath();
    sg.forEach(([x, y], i) => i ? g.lineTo(x, y) : g.moveTo(x, y));
    g.stroke();
  }
  const lp = segs.length ? segs[segs.length - 1] : null;
  if (lp) { const [x, y] = lp[lp.length - 1]; g.fillStyle = col; g.beginPath(); g.arc(x, y, 2.5, 0, 7); g.fill(); }
  g.fillStyle = css("--muted"); g.font = "10px system-ui, sans-serif";
  if (nums.length) { g.fillText(fmt(hi, s.dec), 3, 10); g.fillText(fmt(lo, s.dec), 3, h - 6); }
  return [mn, mx];
}

function tile(k, v, s) { return '<div class="tile"><div class="k">' + k + '</div><div class="v">' + v + '</div><div class="s">' + s + '</div></div>'; }

function draw() {
  if (!latest) return;
  const inf = latest.info || {};
  document.getElementById("info").textContent =
    (inf.bdf || "-") + " | " + (inf.mode || "-") + " | " + (inf.link || "-") + " | AMC " + (inf.amc || "-") +
    " (" + (inf.amc_state || "-") + ") | vrtd " + (inf.vrtd || "-") + " | " + new Date(latest.now * 1000).toLocaleTimeString();
  const ban = document.getElementById("banner");
  const sensors = latest.sensors || [];
  let msg = "";
  if (inf.mode && inf.mode !== "SLASH")
    msg = inf.mode === "FELIX" ? "The card is in FELIX mode: the AMC sensors exist only in SLASH mode." :
          inf.mode === "NONE" ? "The card is not visible on PCIe (link down or switching)." : "Unknown design on the card.";
  else if (!sensors.length) msg = "SLASH mode, but no sensor device yet (ami driver not bound, or AMC not answering).";
  ban.textContent = msg; ban.style.display = msg ? "block" : "none";
  const by = {};
  for (const s of sensors) by[s.type + ":" + s.label] = s;
  const pin = by["vxi:12V_INPUT"], dev = by["temp:Device"];
  const temps = sensors.filter(s => s.type === "temp" && s.label !== "Device" && s.value !== null);
  const hot = temps.length ? temps.reduce((a, b) => (b.value > a.value ? b : a)) : null;
  const nw = sensors.filter(s => s.sev === 1).length, nc = sensors.filter(s => s.sev === 2).length;
  const nv = sensors.filter(s => s.sev >= 0).length;
  document.getElementById("tiles").innerHTML = sensors.length ?
    tile("Board input power", pin ? fmt(pin.value, 1) + '<span class="unit">W</span>' : "-", "12 V input, V x I") +
    tile("FPGA (SYSMON)", dev ? fmt(dev.value, 1) + '<span class="unit">C</span>' : "-", "device temperature") +
    tile("Hottest board sensor", hot ? fmt(hot.value, 1) + '<span class="unit">C</span>' : "-", hot ? hot.label : "") +
    tile("Status", nc ? nc + " critical" : nw ? nw + " warning" : "all ok", nv + " readings valid of " + sensors.length) : "";
  for (const s of sensors) {
    const c = card(s);
    c.el.className = "card s" + s.sev;
    c.el.querySelector(".val").innerHTML = fmt(s.value, s.dec) + '<span class="unit">' + s.unit + "</span>";
    const [mn, mx] = plot(c, s);
    c.el.querySelector(".mm").textContent = mn === null ? "" : "min " + fmt(mn, s.dec) + "  max " + fmt(mx, s.dec);
    const st = c.el.querySelector(".st");
    st.textContent = stName(s); st.className = "st s" + s.sev;
    const lim = [["warn", s.warn], ["crit", s.crit], ["fatal", s.fatal]].filter(x => x[1] !== null);
    c.el.querySelector(".lim").textContent = lim.length ? "limits " + lim.map(x => x[0] + " " + (+x[1].toFixed(2))).join(" / ") : "";
  }
  const live = new Set(sensors.map(s => s.type + ":" + s.label));
  for (const k in cards) cards[k].el.style.display = live.has(k) ? "" : "none";
}

async function poll() {
  try {
    const r = await fetch("api?since=" + since, { cache: "no-store" });
    const d = await r.json();
    if (d.info && d.info.interval) interval = d.info.interval;
    if (d.info && d.info.history_s) maxAge = d.info.history_s;
    for (const [t, vals] of d.samples) {
      for (const k in vals) {
        const s = series[k] || (series[k] = { t: [], v: [] });
        s.t.push(t); s.v.push(vals[k]);
      }
      since = Math.max(since, t);
    }
    const cut = d.now - maxAge;
    for (const k in series) {
      const s = series[k];
      let i = 0;
      while (i < s.t.length && s.t[i] < cut) i++;
      if (i) { s.t.splice(0, i); s.v.splice(0, i); }
    }
    latest = d;
    document.getElementById("dot").className = "live";
    if (!paused) draw();
  } catch (e) {
    document.getElementById("dot").className = "";
    document.getElementById("info").textContent = "no connection to the monitor (" + e.message + ")";
  }
  setTimeout(poll, interval * 1000);
}
window.addEventListener("resize", draw);
poll();
</script>
</body>
</html>
"""


def serve(mon, host, port):
    def sampler():
        while True:
            t0 = time.time()
            try:
                mon.sample()
            except Exception as e:
                print("sample failed: %s" % e, file=sys.stderr)
            time.sleep(max(0.1, mon.args.interval - (time.time() - t0)))

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            u = urlparse(self.path)
            if u.path in ("/", "/index.html"):
                body, ctype = PAGE.encode(), "text/html; charset=utf-8"
            elif u.path == "/api":
                try:
                    since = float(parse_qs(u.query).get("since", ["0"])[0])
                except ValueError:
                    since = 0.0
                body, ctype = json.dumps(mon.state(since)).encode(), "application/json"
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

    mon.sample()
    threading.Thread(target=sampler, daemon=True).start()
    srv = ThreadingHTTPServer((host, port), Handler)
    print("FELIX monitor web page: http://%s:%d/   (history %d min, refresh %g s, Ctrl-C to stop)" %
          ("localhost" if host in ("127.0.0.1", "localhost") else host, port, mon.args.history, mon.args.interval))
    if host in ("127.0.0.1", "localhost"):
        print("from another machine: ssh -L %d:localhost:%d %s@%s   then open http://localhost:%d/" %
              (port, port, os.environ.get("USER", "user"), os.uname().nodename, port))
    sys.stdout.flush()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    srv.server_close()


def main():
    p = argparse.ArgumentParser(description="Live dashboard for the FELIX FLX-155 board sensors (SLASH mode, AMC via ami hwmon)")
    p.add_argument("--bdf", default="0000:41:00.0", help="PCIe function of the card (default 0000:41:00.0)")
    p.add_argument("-i", "--interval", type=float, default=2.0, help="refresh period in seconds (default 2)")
    p.add_argument("--once", action="store_true", help="print one snapshot as text and exit")
    p.add_argument("--check", action="store_true",
                   help="like --once, then SENSORS: PASS or FAIL (exit 1): FAIL if a sensor has no data, is at "
                        "its warning or critical level, or a voltage or temperature reads 0")
    p.add_argument("--csv", help="append every reading to this CSV file")
    p.add_argument("--web", action="store_true", help="serve a live web page with plots instead of the terminal view")
    p.add_argument("--port", type=int, default=8080, help="web page port (default 8080)")
    p.add_argument("--host", default="127.0.0.1", help="web page address to listen on (default 127.0.0.1, this machine only)")
    p.add_argument("--history", type=float, default=60, help="minutes of history kept for the plots (default 60)")
    args = p.parse_args()
    if args.interval < 0.5:
        p.error("--interval must be at least 0.5 s")
    if args.history <= 0:
        p.error("--history must be positive")
    mon = Monitor(args)
    if args.web:
        serve(mon, args.host, args.port)
        return 0
    if args.check:
        rows = mon.lines()
        for text, _ in rows:
            print(text)
        _, _, sensors = mon.last
        bad = [t.split()[0] if t.startswith("  ") else t for t, sev in rows if sev in (-1, 1, 2)]
        # all-zero readings are how a failed AMC I2C bus shows up
        bad += [s["label"] for s in sensors if s["type"] in ("in", "temp") and s["value"] == 0]
        if not sensors and not bad:
            bad = ["no sensors"]
        print("SENSORS: %s%s" % ("FAIL: " if bad else "PASS", ", ".join(bad)))
        return 1 if bad else 0
    if args.once or not sys.stdout.isatty():
        for text, _ in mon.lines():
            print(text)
        return 0
    locale.setlocale(locale.LC_ALL, "")
    chars = SPARK_UTF if "UTF" in locale.getpreferredencoding(False).upper() else SPARK_ASCII
    try:
        curses.wrapper(run_curses, mon, chars)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
