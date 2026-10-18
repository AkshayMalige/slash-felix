"""GT stream endpoints of a FELIX shell in stream_connect.

``inst.port:gt_<k>.tx`` sends a kernel stream to GT quad k of the shell, ``gt_<k>.rx:inst.port``
receives quad k. In the user region these are the NoC stream cells ``gt_axis_noc_<k>`` (TX) and
``gt_axis_noc_s_<k>`` (RX); the number of slots comes from the board profile (``gt_streams``).
"""
from __future__ import annotations

import re
from typing import Dict, List

from slashkit.core.kernel import KernelInstance
from slashkit.core.port import BusType
from slashkit.emit.hw.service_region.stream_ctx import _resolve_port_name

_GT_EP_RE = re.compile(r"^gt_(\d+)\.(tx|rx)$", re.IGNORECASE)


def _axis_port(instances: Dict[str, KernelInstance], inst: str, port: str) -> str:
    if inst not in instances:
        raise KeyError(f"stream_connect: unknown instance '{inst}'")
    name = _resolve_port_name(instances[inst].kernel, port)
    p = instances[inst].kernel.port(name)
    if p.ptype != BusType.AXIS:
        raise ValueError(f"stream_connect: {inst}.{name} is not AXIS (got {p.ptype.name})")
    return name


def build_gt_axis_context(instances: Dict[str, KernelInstance], streams: List[object],
                          gt_streams: int) -> dict:
    to_fabric: List[dict] = []
    from_fabric: List[dict] = []
    leftover: List[object] = []
    used_tx: set[int] = set()
    used_rx: set[int] = set()

    for s in streams:
        src = _GT_EP_RE.match(f"{s.src_inst}.{s.src_port}")
        dst = _GT_EP_RE.match(f"{s.dst_inst}.{s.dst_port}")
        if not src and not dst:
            leftover.append(s)
            continue
        if src and dst:
            raise ValueError(
                f"stream_connect cannot be gt->gt: '{s.src_inst}.{s.src_port}:{s.dst_inst}.{s.dst_port}'")
        m = dst or src
        idx, direction = int(m.group(1)), m.group(2).lower()
        if idx >= gt_streams:
            raise ValueError(
                f"gt_{idx} does not exist: this board's shell has {gt_streams} GT stream(s)")
        if dst:
            if direction != "tx":
                raise ValueError(f"stream_connect: a kernel stream can only go to gt_{idx}.tx")
            if idx in used_tx:
                raise ValueError(f"stream_connect: gt_{idx}.tx is used more than once")
            used_tx.add(idx)
            port = _axis_port(instances, s.src_inst, s.src_port)
            to_fabric.append({"src_pin": f"{s.src_inst}/{port}", "dst_pin": f"/gt_axis_noc_{idx}/S00_AXIS"})
        else:
            if direction != "rx":
                raise ValueError(f"stream_connect: a kernel stream can only come from gt_{idx}.rx")
            if idx in used_rx:
                raise ValueError(f"stream_connect: gt_{idx}.rx is used more than once")
            used_rx.add(idx)
            port = _axis_port(instances, s.dst_inst, s.dst_port)
            from_fabric.append({"src_pin": f"/gt_axis_noc_s_{idx}/M00_AXIS", "dst_pin": f"{s.dst_inst}/{port}"})

    # An unused RX slot keeps draining, so the static side never backs up.
    tie = [f"gt_axis_noc_s_{i}/M00_AXIS_tready" for i in range(gt_streams) if i not in used_rx]
    return {
        "gt_to_fabric": to_fabric,
        "gt_from_fabric": from_fabric,
        "gt_rx_tready_tie_pins": tie,
        "streams_leftover": leftover,
    }
