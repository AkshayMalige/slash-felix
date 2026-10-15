#!/usr/bin/env bash

FELIX="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO=https://gitlab.cern.ch/atlas-tdaq-felix/felix-versal-tools/flx-petalinux.git
BRANCH=flx155a_support
COMMIT=adf674a
WORK="$FELIX/petalinux/build"
FW_TAR=""
PLNX_DIR="${PETALINUX:-}"
STAGE=all

usage() {
    cat <<EOU
usage: $0 --fw FELIX_FIRMWARE.tar.gz --petalinux PETALINUX_DIR [--work DIR] [--stage prepare|build|all]
  --fw         FELIX firmware build archive containing the .xsa, e.g.
               FLX155_INTERLAKEN_8CH_LTICLK_GIT_phase2-master_rm-5.5_257_260929_1508.tar.gz
  --petalinux  PetaLinux 2024.2 installation (the folder with settings.sh)
  --work       build folder, about 50 GB (default $WORK)
  --stage      prepare: clone $BRANCH@$COMMIT, apply felix/petalinux/patches, import the XSA
               build:   petalinux-build + petalinux-package boot
Output: <work>/flx-petalinux/images/linux (BOOT.BIN, boot.scr, image.ub, rootfs.tar.gz)
Then:   felix/tools/modeswitch/make_dual_sd.sh --petalinux <work>/flx-petalinux/images/linux
EOU
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --fw) FW_TAR="$2"; shift 2 ;;
        --petalinux) PLNX_DIR="$2"; shift 2 ;;
        --work) WORK="$2"; shift 2 ;;
        --stage) STAGE="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$PLNX_DIR" ] && [ -f "$PLNX_DIR/settings.sh" ] || { echo "ERROR: --petalinux must point to a PetaLinux 2024.2 installation" >&2; usage; }
source "$PLNX_DIR/settings.sh" "$PLNX_DIR" >/dev/null
set -Eeuo pipefail
[ "${PETALINUX_VER:-}" = 2024.2 ] || { echo "ERROR: PetaLinux ${PETALINUX_VER:-?} found, 2024.2 required" >&2; exit 1; }
PRJ="$WORK/flx-petalinux"

prepare() {
    [ -f "$FW_TAR" ] || { echo "ERROR: --fw archive not found: '$FW_TAR'" >&2; exit 1; }
    [ ! -e "$PRJ" ] || { echo "ERROR: $PRJ exists; remove it or run --stage build" >&2; exit 1; }
    mkdir -p "$WORK/hw"
    git clone -q -b "$BRANCH" "$REPO" "$PRJ"
    git -C "$PRJ" checkout -q "$COMMIT"
    git -C "$PRJ" apply --index "$FELIX"/petalinux/patches/*.patch
    local mu="$PRJ/project-spec/meta-user"
    cp "$mu/recipes-bsp/device-tree/files/system-user.dtsi.flx155A" "$mu/recipes-bsp/device-tree/files/system-user.dtsi"
    cp "$mu/recipes-apps/bist/ez-hw-test.bb.flx155A" "$mu/recipes-apps/bist/ez-hw-test.bb"
    cp "$mu/recipes-apps/bist/files/ez_hw_test.service.flx155A" "$mu/recipes-apps/bist/files/ez_hw_test.service"
    tar xzf "$FW_TAR" -C "$WORK/hw" --wildcards '*.xsa'
    local xsa; xsa=$(ls "$WORK"/hw/*.xsa | head -1)
    echo "==> hardware: $xsa"
    cd "$PRJ"
    petalinux-config --silentconfig --get-hw-description "$xsa"
    petalinux-config -c rootfs --silentconfig
    grep -q "^CONFIG_felix-to-slash=y" project-spec/configs/rootfs_config \
        || { echo "ERROR: felix-to-slash is not enabled in the rootfs config" >&2; exit 1; }
}

build() {
    cd "$PRJ"
    petalinux-build
    petalinux-package boot --u-boot --force
    local img="$PRJ/images/linux"
    local files; files=$(tar tzf "$img/rootfs.tar.gz")
    grep -qx "./usr/bin/felix-to-slash" <<<"$files" || { echo "ERROR: felix-to-slash missing in the rootfs" >&2; exit 1; }
    grep -qx "./usr/sbin/devmem" <<<"$files" || { echo "ERROR: devmem missing in the rootfs" >&2; exit 1; }
    if command -v dtc >/dev/null; then
        local mem; mem=$(dtc -I dtb -O dts "$img/system.dtb" 2>/dev/null | grep -A2 "memory@0 {")
        [[ "$mem" == *"reg = <0x00 0x00 0x00 0x80000000>;"* ]] || { echo "ERROR: system.dtb memory is not limited to 2 GB" >&2; exit 1; }
        echo "==> device tree: Linux memory limited to 2 GB"
    fi
    echo "==> rootfs: felix-to-slash and devmem present"
    echo "==> $img"
    ls -la "$img/BOOT.BIN" "$img/boot.scr" "$img/image.ub" "$img/rootfs.tar.gz"
    echo "Next: $FELIX/tools/modeswitch/make_dual_sd.sh --petalinux $img"
}

case "$STAGE" in
    prepare) prepare ;;
    build) build ;;
    all) prepare; build ;;
    *) usage ;;
esac
