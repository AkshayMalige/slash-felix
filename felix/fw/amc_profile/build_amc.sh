#!/bin/bash
set -Eeuo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
XSA=$(realpath "${1:?usage: $0 <felix_slash.xsa>}")
SRC="$REPO/submodules/AVED/fw/AMC"
DST="$REPO/felix/fw/build/AMC"

[ -f "$XSA" ] || { echo "ERROR: XSA not found: $XSA" >&2; exit 1; }
[ -f "$SRC/CMakeLists.txt" ] || { echo "ERROR: $SRC missing -- git submodule update --init submodules/AVED" >&2; exit 1; }

echo "=== AMC: fresh out-of-tree copy -> ${DST#$REPO/} ==="
rm -rf "$DST" && mkdir -p "$(dirname "$DST")" && cp -a "$SRC" "$DST"
cp -a "$HERE/profiles/felix" "$DST/src/profiles/felix"
patch -p3 -d "$DST" --forward < "$HERE/amc_cmakelists_felix.patch"

echo "=== AMC: BSP from $XSA ==="
( cd "$DST/scripts" && ./build_bsp.sh -xsa "$XSA" -os freertos )
echo "=== AMC: amc.elf (profile felix) ==="
( cd "$DST" && ./scripts/build.sh -amc -profile felix -os freertos )

[ -f "$DST/build/amc.elf" ] || { echo "ERROR: amc.elf was not produced" >&2; exit 1; }
echo "BUILD_AMC_DONE: ${DST#$REPO/}/build/amc.elf"
