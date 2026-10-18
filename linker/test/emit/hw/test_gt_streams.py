from pathlib import Path

import pytest
from jinja2 import ChainableUndefined, Environment, PackageLoader

from slashkit.core.connectivity import StreamConnect
from slashkit.core.kernel import Kernel, KernelInstance
from slashkit.core.port import BusType, Port
from slashkit.emit.hw.user_region.gt_ctx import build_gt_axis_context


def _inst(name, ports):
    k = Kernel(name=name + "_k", component_xml_path=Path("x.xml"),
               ports={p: Port(p, t, 512) for p, t in ports.items()})
    return KernelInstance(name=name, kernel=k)


@pytest.fixture
def instances():
    return {
        "gen_0": _inst("gen_0", {"axis_out": BusType.AXIS, "s_axi_control": BusType.AXILITE}),
        "chk_0": _inst("chk_0", {"axis_in": BusType.AXIS}),
        "pass_0": _inst("pass_0", {"axis_in": BusType.AXIS, "axis_out": BusType.AXIS}),
    }


def test_tx_rx_map_to_stream_cells_and_unused_rx_is_tied(instances):
    streams = [StreamConnect("gen_0", "axis_out", "gt_0", "tx"),
               StreamConnect("gt_0", "rx", "chk_0", "axis_in"),
               StreamConnect("gen_0", "axis_out", "pass_0", "axis_in")]
    ctx = build_gt_axis_context(instances, streams, 2)
    assert ctx["gt_to_fabric"] == [{"src_pin": "gen_0/axis_out", "dst_pin": "/gt_axis_noc_0/S00_AXIS"}]
    assert ctx["gt_from_fabric"] == [{"src_pin": "/gt_axis_noc_s_0/M00_AXIS", "dst_pin": "chk_0/axis_in"}]
    assert ctx["gt_rx_tready_tie_pins"] == ["gt_axis_noc_s_1/M00_AXIS_tready"]
    assert ctx["streams_leftover"] == [streams[2]]


def test_no_gt_streams_ties_nothing(instances):
    ctx = build_gt_axis_context(instances, [], 0)
    assert ctx["gt_to_fabric"] == [] and ctx["gt_from_fabric"] == []
    assert ctx["gt_rx_tready_tie_pins"] == []


@pytest.mark.parametrize("stream, match", [
    (StreamConnect("gen_0", "axis_out", "gt_1", "tx"), "has 1 GT stream"),
    (StreamConnect("gen_0", "axis_out", "gt_0", "rx"), "only go to gt_0.tx"),
    (StreamConnect("gt_0", "tx", "chk_0", "axis_in"), "only come from gt_0.rx"),
    (StreamConnect("gt_0", "rx", "gt_0", "tx"), "gt->gt"),
    (StreamConnect("gen_0", "s_axi_control", "gt_0", "tx"), "not AXIS"),
])
def test_bad_gt_streams_are_rejected(instances, stream, match):
    with pytest.raises(ValueError, match=match):
        build_gt_axis_context(instances, [stream], 1)


def test_gt_slot_used_twice_is_rejected(instances):
    streams = [StreamConnect("gen_0", "axis_out", "gt_0", "tx"),
               StreamConnect("pass_0", "axis_out", "gt_0", "tx")]
    with pytest.raises(ValueError, match="more than once"):
        build_gt_axis_context(instances, streams, 1)


def test_unknown_instance_is_rejected(instances):
    with pytest.raises(KeyError):
        build_gt_axis_context(instances, [StreamConnect("nope_0", "axis_out", "gt_0", "tx")], 1)


def _render(**ctx):
    env = Environment(loader=PackageLoader("slashkit.resources"), undefined=ChainableUndefined,
                      trim_blocks=True, lstrip_blocks=True)
    env.filters["zip"] = lambda a, b: zip(a, b)
    ctx.setdefault("instances", {})
    return env.get_template("slash_compute.tcl").render(**ctx)


def test_compute_template_creates_gt_cells_and_connections():
    tcl = _render(gt_streams=1, gt_stream_mbps=12900,
                  gt_to_fabric=[{"src_pin": "gen_0/axis_out", "dst_pin": "/gt_axis_noc_0/S00_AXIS"}],
                  gt_from_fabric=[{"src_pin": "/gt_axis_noc_s_0/M00_AXIS", "dst_pin": "chk_0/axis_in"}])
    assert "create_bd_cell -type ip -vlnv xilinx.com:ip:axis_noc:1.0 gt_axis_noc_s_0" in tcl
    assert "create_bd_cell -type ip -vlnv xilinx.com:ip:axis_noc:1.0 gt_axis_noc_0" in tcl
    assert "[get_bd_intf_ports S_GT_INIS0] [get_bd_intf_pins gt_axis_noc_s_0/S00_INIS]" in tcl
    assert "[get_bd_intf_pins gt_axis_noc_0/M00_INIS] [get_bd_intf_ports M_GT_INIS0]" in tcl
    # same text as the shell's 20_slash_base.tcl, so the cell names match the shell's NoC paths
    assert 'CONFIG.CONNECTIONS "M00_AXIS {write_bw {12900}}"' in tcl
    assert 'CONFIG.CONNECTIONS "M00_INIS {write_bw {12900}}"' in tcl
    assert "connect_bd_intf_net [get_bd_intf_pins gen_0/axis_out] [get_bd_intf_pins /gt_axis_noc_0/S00_AXIS]" in tcl
    assert "connect_bd_intf_net [get_bd_intf_pins /gt_axis_noc_s_0/M00_AXIS] [get_bd_intf_pins chk_0/axis_in]" in tcl


def test_compute_template_without_gt_streams_has_no_gt_cells():
    tcl = _render()
    assert "axis_noc:1.0 gt_axis_noc" not in tcl and "GT_INIS" not in tcl
