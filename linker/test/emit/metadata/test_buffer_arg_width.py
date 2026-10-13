from types import SimpleNamespace

import pytest

from slashkit.emit.metadata.system_map_ctx import _build_functional_args_from_hls


def _hls_data(pointee_bits: int) -> dict:
    return {"Args": {
        "in": {
            "index": "0", "direction": "in",
            "srcType": f"ap_uint<{pointee_bits}>*", "srcSize": str(pointee_bits),
            "hwRefs": [
                {"type": "interface", "interface": "m_axi_gmem0", "usage": "data"},
                {"type": "register", "interface": "s_axi_control", "name": "in_r_1", "usage": "address"},
                {"type": "register", "interface": "s_axi_control", "name": "in_r_2", "usage": "address"},
            ],
        },
        "size": {
            "index": "1", "direction": "in", "srcType": "ap_uint<32>", "srcSize": "32",
            "hwRefs": [{"type": "register", "interface": "s_axi_control", "name": "size", "usage": "data"}],
        },
    }}


def _reg(name, offset):
    return SimpleNamespace(name=name, size=32, address_offset=offset, access="write-only")


REG_BLOCK = SimpleNamespace(registers=[_reg("in_r_1", 0x10), _reg("in_r_2", 0x14), _reg("size", 0x1c)])


@pytest.mark.parametrize("pointee_bits", [32, 64, 512])
def test_buffer_arg_range_is_the_64bit_address(pointee_bits):
    args = {a["name"]: a for a in
            _build_functional_args_from_hls(_hls_data(pointee_bits), "s_axi_control", REG_BLOCK)}
    assert args["in_r"]["range"] == "64"
    assert args["in_r"]["type"] == "buffer"
    assert args["size"]["range"] == "32"
