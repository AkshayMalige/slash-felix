import json
from dataclasses import dataclass
from importlib import resources
from typing import Any, Dict

V80_PART = "xcv80-lsva4737-2MHP-e-S"

BOARD_FILE_NAME = "board.json"


@dataclass(frozen=True)
class BoardProfile:
    name: str = "v80"
    part: str = V80_PART
    hbm_axi_ports: bool = True
    rm_reset_bufg: bool = True
    user_clock_at_source: bool = False
    max_user_clock_hz: int = 0

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "BoardProfile":
        unknown = set(data) - {"board", "part", "hbm_axi_ports", "rm_reset_bufg",
                               "user_clock_at_source", "max_user_clock_hz"}
        if unknown:
            raise ValueError(
                f"Unknown key(s) in {BOARD_FILE_NAME}: {', '.join(sorted(unknown))}")
        defaults = cls()
        part = data.get("part", defaults.part)
        hbm = data.get("hbm_axi_ports", defaults.hbm_axi_ports)
        if not isinstance(part, str) or not part:
            raise ValueError(f"'part' in {BOARD_FILE_NAME} must be a non-empty string")
        if not isinstance(hbm, bool):
            raise ValueError(f"'hbm_axi_ports' in {BOARD_FILE_NAME} must be true or false")
        bufg = data.get("rm_reset_bufg", defaults.rm_reset_bufg)
        if not isinstance(bufg, bool):
            raise ValueError(f"'rm_reset_bufg' in {BOARD_FILE_NAME} must be true or false")
        at_source = data.get("user_clock_at_source", defaults.user_clock_at_source)
        if not isinstance(at_source, bool):
            raise ValueError(f"'user_clock_at_source' in {BOARD_FILE_NAME} must be true or false")
        max_hz = data.get("max_user_clock_hz", defaults.max_user_clock_hz)
        if isinstance(max_hz, bool) or not isinstance(max_hz, int) or max_hz < 0:
            raise ValueError(f"'max_user_clock_hz' in {BOARD_FILE_NAME} must be a non-negative integer")
        return cls(name=str(data.get("board", defaults.name)), part=part,
                   hbm_axi_ports=hbm, rm_reset_bufg=bufg,
                   user_clock_at_source=at_source, max_user_clock_hz=max_hz)


def load_board_profile(static_shell_package: str) -> BoardProfile:
    try:
        board_file = resources.files(static_shell_package) / BOARD_FILE_NAME
    except ModuleNotFoundError:
        return BoardProfile()
    if not board_file.is_file():
        return BoardProfile()
    with board_file.open("r", encoding="utf-8") as fh:
        return BoardProfile.from_dict(json.load(fh))
