#!/bin/bash
set -Eeuo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
PLATFORM=hw
[ "${1:-}" = "--emu" ] && { PLATFORM=emu; shift; }
[ $# -ge 1 ] || { echo "usage: $0 [--emu] <example> [<example>...] | all" >&2; exit 2; }
command -v vivado >/dev/null || { echo "ERROR: source Vitis/Vivado 2025.1 settings64.sh first" >&2; exit 1; }
if [ "$1" = all ]; then
    set --
    for f in "$REPO"/felix/examples/*/CMakeLists.txt; do set -- "$@" "$(basename "$(dirname "$f")")"; done
fi
SSC="$REPO/linker/slashkit/resources/static_shell_compute"

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
    # A vbin only loads on the shell it was linked against, but make does not see a new
    # staged shell as a dependency: relink any vbin older than the staged shell.
    shell="$SSC/static_shell_slash.dcp"
    for v in "${vbins[@]}"; do
        if [ "$PLATFORM" = hw ] && [ -f "$build/$v.vbin" ] && [ "$build/$v.vbin" -ot "$shell" ]; then
            echo "$v.vbin is older than the staged shell: relinking"
            rm -rf -- "${build:?}/$v.vbin" "${build:?}/$v.vbin.prj" "${build:?}/$v.vbin.shell_id"
        fi
    done
    cmake --build "$build" --target "${vbins[@]}"
    for v in "${vbins[@]}"; do
        ls -la "$build/$v.vbin"
        # build ID of the shell this vbin was linked against; felix/test/felix_test.py checks it
        # against the card before it loads the vbin
        if [ "$PLATFORM" = hw ]; then
            if [ -f "$SSC/shell_build_id" ]; then
                cp -f "$SSC/shell_build_id" "$build/$v.vbin.shell_id"
            else
                rm -f -- "${build:?}/$v.vbin.shell_id"
                echo "WARNING: no shell_build_id staged with the shell: $v.vbin gets no shell ID" >&2
            fi
        fi
    done
    echo "EXAMPLE_DONE: $ex"
done
