#!/usr/bin/env bash

set -Eeuo pipefail

FELIX="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SLASH="$FELIX/hw/amc_pdi/build/felix_slash_amc.pdi"
IMAGE1=""
PLNX=""
OUT="$FELIX/hw/artifacts/felix_sd_dual.img"
FAT_MB=512
ROOT_MB=2048

usage() {
    cat <<EOU
usage: $0 [--slash FILE] (--image1 FILE | --petalinux DIR) [--out FILE]
  --slash FILE      SLASH boot image for BOOT.BIN (default $SLASH)
  --image1 FILE     boot image for BOOT0001.BIN, e.g. a FELIX firmware .pdi (FPGA only)
  --petalinux DIR   FELIX PetaLinux images/linux: BOOT.BIN -> BOOT0001.BIN, boot.scr, image.ub,
                    rootfs.tar.gz -> second partition (ext4)
  --out FILE        default $OUT
EOU
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --slash) SLASH="$2"; shift 2 ;;
        --image1) IMAGE1="$2"; shift 2 ;;
        --petalinux) PLNX="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$PLNX" ] && [ -z "$IMAGE1" ] && IMAGE1="$PLNX/BOOT.BIN"
[ -n "$IMAGE1" ] || usage
for f in "$SLASH" "$IMAGE1" ${PLNX:+"$PLNX/boot.scr" "$PLNX/image.ub" "$PLNX/rootfs.tar.gz"}; do
    [ -f "$f" ] || { echo "ERROR: missing $f" >&2; exit 1; }
done
for t in sfdisk mkfs.vfat mcopy mdir dd ${PLNX:+fakeroot mkfs.ext4 e2fsck debugfs}; do
    command -v "$t" >/dev/null || { echo "ERROR: '$t' not found (dosfstools, mtools, fakeroot, e2fsprogs)" >&2; exit 1; }
done

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export MTOOLS_SKIP_CHECK=1

TOTAL_MB=$(( 1 + FAT_MB + ${PLNX:+ROOT_MB +} 0 ))
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
truncate -s "${TOTAL_MB}M" "$OUT"
{
    echo "label: dos"
    echo "start=2048, size=$(( FAT_MB * 2048 )), type=c, bootable"
    [ -n "$PLNX" ] && echo "start=$(( (1 + FAT_MB) * 2048 )), size=$(( ROOT_MB * 2048 )), type=83"
} | sfdisk -q "$OUT"

truncate -s "${FAT_MB}M" "$T/fat.img"
mkfs.vfat -F 32 -n BOOT "$T/fat.img" >/dev/null
mcopy -i "$T/fat.img" "$SLASH" ::/BOOT.BIN
mcopy -i "$T/fat.img" "$IMAGE1" ::/BOOT0001.BIN
if [ -n "$PLNX" ]; then
    mcopy -i "$T/fat.img" "$PLNX/boot.scr" ::/boot.scr
    mcopy -i "$T/fat.img" "$PLNX/image.ub" ::/image.ub
fi
dd if="$T/fat.img" of="$OUT" bs=1M seek=1 conv=notrunc status=none

if [ -n "$PLNX" ]; then
    mkdir "$T/root"
    fakeroot -- bash -c "tar -xpf '$PLNX/rootfs.tar.gz' -C '$T/root' && mkfs.ext4 -q -F -L rootfs -d '$T/root' '$T/root.img' ${ROOT_MB}M"
    e2fsck -fn "$T/root.img" >/dev/null
    dd if="$T/root.img" of="$OUT" bs=1M seek=$(( 1 + FAT_MB )) conv=notrunc status=none
fi

echo "==> $OUT ($TOTAL_MB MB)"
sfdisk -l "$OUT" | grep -E "^Device|img[0-9]" | sed 's/^/    /'
echo "==> partition 1 (FAT):"
mdir -i "$OUT@@1M" ::/ | grep -E "BIN|scr|ub" | sed 's/^/    /'
echo "    BOOT.BIN     = $(basename "$SLASH")"
echo "    BOOT0001.BIN = $IMAGE1"
if [ -n "$PLNX" ]; then
    echo "==> partition 2 (ext4, FELIX Linux root file system): fsck clean"
    debugfs -R "stat /usr/bin/felix-to-slash" "$T/root.img" 2>/dev/null | grep -E "User:" | sed 's/^/    felix-to-slash: /' \
        || echo "    WARNING: /usr/bin/felix-to-slash not found"
fi
echo
echo "Flash it (Etcher, or: sudo dd if=$OUT of=/dev/sdX bs=4M conv=fsync), SW1 = 1110 (SD1)."
echo "Power-on boots BOOT.BIN (SLASH); felix/tools/modeswitch/modeswitch.sh reboot --image 1 boots BOOT0001.BIN."
