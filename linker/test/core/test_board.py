import json
import re
import shutil
import subprocess
import textwrap
from pathlib import Path
from unittest import mock

import pytest
from jinja2 import ChainableUndefined, Environment, PackageLoader

from slashkit.core import board as board_mod
from slashkit.core import command_config
from slashkit.core.bd_ports import BusType
from slashkit.core.board import V80_PART, BoardProfile, load_board_profile
from slashkit.core.command_config import LinkerConfiguration

from .test_command_config import _make_args, _write_cfg

FELIX = {"board": "felix", "part": "xcvp1552-vsva3340-2MHP-e-S", "hbm_axi_ports": False,
         "rm_reset_bufg": False, "user_clock_at_source": True, "max_user_clock_hz": 400000000}
FELIX_PROFILE = BoardProfile(name="felix", part=FELIX["part"], hbm_axi_ports=False,
                             rm_reset_bufg=False, user_clock_at_source=True,
                             max_user_clock_hz=400000000)


def _fake_package(tmp_path: Path, content=None):
    pkg = tmp_path / "static_shell_pkg"
    pkg.mkdir(exist_ok=True)
    if content is not None:
        (pkg / "board.json").write_text(json.dumps(content))
    return mock.patch.object(board_mod.resources, "files", return_value=pkg)


def test_missing_board_file_means_v80(tmp_path):
    with _fake_package(tmp_path):
        profile = load_board_profile("any.package")
    assert profile == BoardProfile()
    assert profile.part == V80_PART
    assert profile.hbm_axi_ports is True


def test_missing_package_means_v80():
    with mock.patch.object(board_mod.resources, "files", side_effect=ModuleNotFoundError):
        assert load_board_profile("slashkit.resources.not_installed") == BoardProfile()


def test_board_file_is_parsed(tmp_path):
    with _fake_package(tmp_path, FELIX):
        profile = load_board_profile("any.package")
    assert profile == FELIX_PROFILE


def test_gt_stream_fields_are_parsed(tmp_path):
    with _fake_package(tmp_path, {**FELIX, "gt_streams": 4, "gt_stream_mbps": 12900}):
        profile = load_board_profile("any.package")
    assert (profile.gt_streams, profile.gt_stream_mbps) == (4, 12900)
    assert (BoardProfile().gt_streams, BoardProfile().gt_stream_mbps) == (0, 0)


@pytest.mark.parametrize("content", [{"gt_streams": -1}, {"gt_streams": True}, {"gt_stream_mbps": "12900"}])
def test_invalid_gt_stream_fields_are_rejected(tmp_path, content):
    with _fake_package(tmp_path, content), pytest.raises(ValueError):
        load_board_profile("any.package")


@pytest.mark.parametrize("content", [
    {"part": ""},
    {"hbm_axi_ports": "no"},
    {"hbm": False},
    {"rm_reset_bufg": 0},
    {"user_clock_at_source": "yes"},
    {"max_user_clock_hz": -1},
    {"max_user_clock_hz": True},
    {"max_user_clock_hz": 4e8},
])
def test_invalid_board_file_is_rejected(tmp_path, content):
    with _fake_package(tmp_path, content), pytest.raises(ValueError):
        load_board_profile("any.package")


def _compute_config(tmp_path: Path, board_content):
    cfg = _write_cfg(tmp_path, """
        [connectivity]
        shell=compute
    """)
    args = _make_args(tmp_path, config=cfg, cli_pre_synth=[])
    with _fake_package(tmp_path, board_content), \
            mock.patch.object(command_config, "_find_vitis_include", return_value=tmp_path), \
            mock.patch.object(command_config, "apply_config_to_instances", return_value=[]):
        return LinkerConfiguration(args)


def _rtl_names(config: LinkerConfiguration):
    return {p.rtl_name for lst in config.block_design_ports.ports.values() for p in lst
            if p.ptype == BusType.AXI4FULL}


def test_compute_v80_keeps_hbm_ports(tmp_path):
    config = _compute_config(tmp_path, None)
    names = _rtl_names(config)
    assert config.board.part == V80_PART
    assert "HBM_AXI_00" in names and "HBM_AXI_63" in names
    assert "M11_INI" in names and "HBM_VNOC_INI_07" in names


def test_compute_board_without_hbm_drops_only_hbm_ports(tmp_path):
    config = _compute_config(tmp_path, FELIX)
    names = _rtl_names(config)
    assert config.board.part == FELIX["part"]
    assert not any(n.startswith("HBM_AXI_") for n in names)
    assert {"M00_INI", "M11_INI", "HBM_VNOC_INI_00", "HBM_VNOC_INI_07"} <= names


def _render_compute_template(**ctx):
    env = Environment(loader=PackageLoader("slashkit.resources"), undefined=ChainableUndefined,
                      trim_blocks=True, lstrip_blocks=True)
    env.filters["zip"] = lambda a, b: zip(a, b)
    ctx.setdefault("instances", {})
    return env.get_template("slash_compute.tcl").render(**ctx)


def test_compute_template_hbm_apertures_follow_board():
    v80 = _render_compute_template()
    assert v80 == _render_compute_template(hbm_axi_ports=True)
    assert v80.count("[get_bd_intf_ports HBM_AXI_") == 64

    felix = _render_compute_template(hbm_axi_ports=False)
    assert "HBM_AXI_" not in felix
    apertures = [l for l in felix.splitlines() if "set_property APERTURES" in l]
    assert sum("HBM_VNOC_INI_" in l for l in apertures) == 8
    assert any("[get_bd_intf_ports M11_INI]" in l for l in apertures)
    assert any("[get_bd_intf_ports S_AXILITE_INI]" in l for l in apertures)


def _slash_rm_argv(monkeypatch, tmp_path, board=None):
    from slashkit.core.command_config import ShellType
    from slashkit.emit.hw import project_gen
    from test.emit.hw.test_project_gen import _rm_config, _stub_rm_build

    seen = []
    monkeypatch.setattr(project_gen, "export_package", lambda _package, out_dir: out_dir.mkdir())
    _stub_rm_build(monkeypatch, tmp_path, lambda argv, _kwargs: seen.append(argv))
    config = _rm_config(tmp_path)
    config.shell_type = ShellType.COMPUTE
    if board is not None:
        config.board = board
    project_gen.build_slash_rm(config)
    return seen[0]


def test_rm_build_uses_board_part(monkeypatch, tmp_path):
    argv = _slash_rm_argv(monkeypatch, tmp_path,
                          BoardProfile(name="felix", part=FELIX["part"], hbm_axi_ports=False))
    assert argv[argv.index("--part") + 1] == FELIX["part"]


def test_rm_build_defaults_to_v80_part(monkeypatch, tmp_path):
    argv = _slash_rm_argv(monkeypatch, tmp_path)
    assert argv[argv.index("--part") + 1] == V80_PART


def test_compute_template_reset_spine_follows_board():
    v80 = _render_compute_template(instances={"k_0": 1})
    assert "util_ds_buf_0" in v80 and "rst_repl_" not in v80

    felix = _render_compute_template(instances={"k_0": 1, "k_1": 1}, rm_reset_bufg=False)
    assert "xilinx.com:ip:util_ds_buf" not in felix
    assert "set _rst_kernels [list k_0 k_1]" in felix
    assert re.search(r"c_shift_ram_0/Q\]\s*\\\s*\[get_bd_pins ilreduced_logic_0/Op1\]", felix)


@pytest.mark.parametrize("domain", ["HBM", "MEM"])
def test_hbm_and_mem_targets_rejected_without_hbm(domain):
    from types import SimpleNamespace
    from slashkit.core.command_config import ShellType
    from slashkit.emit.hw import tcl_gen

    config = SimpleNamespace(
        block_design_ports=None,
        configuration=SimpleNamespace(streams=[]),
        kernel_instances=[SimpleNamespace(
            name="k_0", params={"mem_sp": {"m_axi_gmem0": {"domain": domain}}})],
        kernels=[],
        shell_type=ShellType.COMPUTE,
        board=BoardProfile(name="felix", part=FELIX["part"], hbm_axi_ports=False,
                           rm_reset_bufg=False),
    )
    with pytest.raises(ValueError, match=f"sp=k_0.m_axi_gmem0:{domain} is not available"):
        tcl_gen.generate_tcl(config)


def _write_clock(tmp_path, hz):
    (tmp_path / "system_map.xml").write_text(
        f"<SystemMap><ClockFrequency>{hz}</ClockFrequency></SystemMap>")


def test_rm_build_v80_times_user_clock_at_rm_port(monkeypatch, tmp_path):
    _write_clock(tmp_path, 250000000)
    argv = _slash_rm_argv(monkeypatch, tmp_path)
    assert "--user-clock-xdc" in argv and "--user-clock-impl-tcl" not in argv


def test_rm_build_board_times_user_clock_at_source(monkeypatch, tmp_path):
    _write_clock(tmp_path, 250000000)
    argv = _slash_rm_argv(monkeypatch, tmp_path, FELIX_PROFILE)
    assert "--user-clock-xdc" in argv
    tcl = Path(argv[argv.index("--user-clock-impl-tcl") + 1]).read_text()
    assert "set _slash_target_hz 250000000" in tcl
    assert "create_generated_clock -name user_clk" in tcl


def test_rm_build_rejects_clock_above_board_max(monkeypatch, tmp_path):
    _write_clock(tmp_path, 450000000)
    with pytest.raises(ValueError, match="above 400000000 Hz"):
        _slash_rm_argv(monkeypatch, tmp_path, FELIX_PROFILE)


@pytest.mark.skipif(shutil.which("tclsh") is None, reason="tclsh not installed")
@pytest.mark.parametrize("hz, mul, div", [
    (250000000, 5, 2), (320000000, 16, 5), (200000000, 2, 1),
    (240474000, 101, 42),
    (333333333, 10, 3),
])
def test_user_clock_at_source_ratio(tmp_path, hz, mul, div):
    from slashkit.emit.hw.project_gen import _USER_CLOCK_AT_SOURCE_TCL
    stubs = textwrap.dedent("""
        proc get_pins {args} { return [lindex $args end] }
        proc get_clocks {args} {
            if {[string match *CLKIN1 [lindex $args end]]} { return clk_pl_3 }
            return clkout1_primitive_6
        }
        proc get_property {p o} {
            return [dict get {SOURCE_PINS mmcm/CLKOUT0 SOURCE mmcm/CLKIN1 PERIOD 10.000} $p]
        }
        proc create_generated_clock {args} { puts "CGC $args" }
    """)
    script = tmp_path / "t.tcl"
    script.write_text(stubs + _USER_CLOCK_AT_SOURCE_TCL.format(hz=hz))
    out = subprocess.run(["tclsh", str(script)], capture_output=True, text=True, check=True).stdout
    assert (f"CGC -name user_clk -source mmcm/CLKIN1 -multiply_by {mul} -divide_by {div} "
            "mmcm/CLKOUT0") in out
