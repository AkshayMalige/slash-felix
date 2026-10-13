#!/bin/bash
set -Eeuo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO"
command -v vivado >/dev/null || { echo "ERROR: source Vitis/Vivado 2025.1 settings64.sh first" >&2; exit 1; }

stage_hw() {
    echo "########## HW ##########"
    make -C linker/slashkit/resources/base/common/iprepo build-hbm_bandwidth
    mkdir -p "$REPO/felix/build_logs"
    ( cd "$REPO/felix/build_logs" && vivado -mode batch -source "$REPO/felix/hw/scripts/run_all.tcl" )
    ( cd "$REPO/felix/build_logs" && vivado -mode batch -source "$REPO/felix/hw/scripts/run_impl.tcl" )
    felix/scripts/stage_artifacts.sh
    echo "HW_DONE"
}

stage_fw() {
    echo "########## FW ##########"
    local XSA="$REPO/felix/hw/artifacts/felix_slash.xsa"
    [ -f "$XSA" ] || { echo "ERROR: $XSA missing -- run '$0 hw' first" >&2; exit 1; }
    felix/fw/amc_profile/build_amc.sh "$XSA"
    felix/hw/amc_pdi/combine_amc_pdi.sh
    felix/scripts/make_sd_image.sh
    echo "FW_DONE"
}

stage_sw() {
    echo "########## SW ##########"
    [ -f linker/slashkit/resources/static_shell_compute/board.json ] || \
        echo "WARNING: no FELIX shell staged -- the slashkit package will not be able to link for FELIX"
    local clean_path="/usr/bin:/bin:$(echo "$PATH" | tr ':' '\n' | grep -viE 'conda|miniforge|mamba|/\.venv/' | paste -sd:)"
    env -u CONDA_PREFIX -u CONDA_DEFAULT_ENV -u CONDA_EXE -u CONDA_PYTHON_EXE -u VIRTUAL_ENV \
        PATH="$clean_path" SLASH_PKG_SKIP_ROOT_DESIGN_BUILD=1 \
        scripts/package-deb.sh --noninteractive
    echo "SW_DONE -> deb/  (install: felix/scripts/install_sw.sh)"
}

case "${1:-}" in
    hw)  stage_hw ;;
    fw)  stage_fw ;;
    sw)  stage_sw ;;
    all) stage_hw; stage_fw; stage_sw ;;
    *)   echo "usage: $0 {hw|fw|sw|all}"; exit 2 ;;
esac
echo "BUILD_ALL_DONE: ${1}"
