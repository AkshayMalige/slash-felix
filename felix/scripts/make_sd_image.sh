#!/usr/bin/env bash

set -Eeuo pipefail

FELIX="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PDI="${1:-$FELIX/hw/amc_pdi/build/felix_slash_amc.pdi}"
OUT="${2:-$FELIX/hw/artifacts/felix_sd.img}"
SIZE_MB="${3:-64}"
PART_OFFSET="1M"

[ -f "$PDI" ] || { echo "ERROR: PDI not found: $PDI" >&2; exit 1; }
for t in parted mformat mcopy dd; do
    command -v "$t" >/dev/null || { echo "ERROR: '$t' not found (install parted + mtools)" >&2; exit 1; }
done
PDI_MB=$(( ($(stat -c %s "$PDI") + 1048575) / 1048576 ))
if [ "$SIZE_MB" -lt $(( PDI_MB + 4 )) ]; then
    echo "ERROR: size_MB=$SIZE_MB too small for a ${PDI_MB} MB PDI (need >= $((PDI_MB+4)))" >&2
    exit 1
fi

echo "==> PDI     : $PDI ($(du -h "$PDI" | cut -f1))"
echo "==> Output  : $OUT (${SIZE_MB} MB)"

rm -f "$OUT"
dd if=/dev/zero of="$OUT" bs=1M count="$SIZE_MB" status=none

parted -s "$OUT" mklabel msdos
parted -s "$OUT" mkpart primary fat32 "$PART_OFFSET" 100%
parted -s "$OUT" set 1 boot on
parted -s "$OUT" set 1 lba on
sfdisk --part-type "$OUT" 1 0c >/dev/null

export MTOOLS_SKIP_CHECK=1
mformat -i "$OUT@@${PART_OFFSET}" -F -v BOOT ::
mcopy   -i "$OUT@@${PART_OFFSET}" "$PDI" ::/BOOT.BIN

echo "==> Partition table (type must be 'c'/FAT32 LBA):"
sfdisk -l "$OUT" 2>/dev/null | grep -E "Device|img1|\.img1|type=|Id" | sed 's/^/    /'
echo "==> FAT contents (must show BOOT.BIN):"
mdir -i "$OUT@@${PART_OFFSET}" ::/ | sed 's/^/    /'

echo
echo "SD image ready: $OUT"
echo "Next:"
echo "  1. Flash it with Balena Etcher (or: sudo dd if=$OUT of=/dev/sdX bs=4M conv=fsync)"
echo "  2. Set boot switch SW1 = 1110 (SD1) on the FLX-155"
echo "  3. Insert the card, COLD power-cycle the card"
echo "  4. Verify:  lspci -d 10ee: -nn   &&   v80-smi list"
