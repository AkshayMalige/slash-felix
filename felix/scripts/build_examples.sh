#!/bin/bash
set -Eeuo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
PLATFORM=hw
[ "${1:-}" = "--emu" ] && { PLATFORM=emu; shift; }
[ $# -ge 1 ] || { echo "usage: $0 [--emu] <example> [<example>...]" >&2; exit 2; }
command -v vivado >/dev/null || { echo "ERROR: source Vitis/Vivado 2025.1 settings64.sh first" >&2; exit 1; }

for ex in "$@"; do
    src="$REPO/felix/examples/$ex"
    [ -f "$src/CMakeLists.txt" ] || { echo "ERROR: felix/examples/$ex/CMakeLists.txt not found" >&2; exit 2; }
    build="$src/build"
    mapfile -t vbins < <(grep -E 'add_vbin\(TARGET' "$src/CMakeLists.txt" \
        | grep "PLATFORM \"$PLATFORM\"" | sed -E 's/.*TARGET "([^"]+)".*/\1/')
    [ ${#vbins[@]} -gt 0 ] || { echo "ERROR: no $PLATFORM add_vbin target in $ex" >&2; exit 2; }

    echo "########## $ex: ${vbins[*]} + host programs ##########"
    cmake -S "$src" -B "$build" -DSLASH_USE_REPO="${SLASH_USE_REPO:-ON}"
    cmake --build "$build" -j "$(nproc)"
    cmake --build "$build" --target "${vbins[@]}"
    for v in "${vbins[@]}"; do ls -la "$build/$v.vbin"; done
    echo "EXAMPLE_DONE: $ex"
done
