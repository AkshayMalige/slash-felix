#!/bin/bash
set -Eeuo pipefail

HERE=$(realpath "$(dirname "$0")")
BUILD="${HERE}/build"

_staged="${HERE}/../artifacts/top_wrapper.pdi"
_impl="${HERE}/../proj/felix_slash.runs/impl_1/top_wrapper.pdi"
BASE_PDI="${1:-$([ -f "$_staged" ] && echo "$_staged" || echo "$_impl")}"
AMC_ELF="${2:-$(realpath -m "${HERE}/../../fw/build/AMC/build/amc.elf")}"

OUT_PDI="${BUILD}/felix_slash_amc.pdi"

for f in "$BASE_PDI" "$AMC_ELF"; do
    [ -f "$f" ] || { echo "ERROR: missing input: $f" >&2; exit 1; }
done
command -v bootgen >/dev/null || { echo "ERROR: bootgen not on PATH -- source Vitis settings64.sh" >&2; exit 1; }

rm -rf "$BUILD"; mkdir -p "$BUILD"
cp -a "$BASE_PDI" "${BUILD}/top_wrapper.pdi"
cp -a "$AMC_ELF"  "${BUILD}/amc.elf"

echo "=== bootgen: combining base PDI + AMC (r5-0) ==="
( cd "$HERE" && bootgen -arch versal -image "${HERE}/felix_pdi_combine.bif" -w -o "$OUT_PDI" )

echo "COMBINE_AMC_PDI_DONE: $OUT_PDI"
ls -la "$OUT_PDI"
