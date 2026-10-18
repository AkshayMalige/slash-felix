#!/bin/bash
set -Eeuo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
PROJ="${REPO}/felix/hw/proj"
IMPL="${PROJ}/felix_slash.runs/impl_1"
BD_SRC="${PROJ}/felix_slash.srcs/sources_1/bd/slash_base"
SSC="${REPO}/linker/slashkit/resources/static_shell_compute"
ART="${REPO}/felix/hw/artifacts"

[ -d "$IMPL" ]   || { echo "ERROR: impl dir not found: $IMPL (run run_impl.tcl first)" >&2; exit 1; }
[ -d "$BD_SRC" ] || { echo "ERROR: slash_base BD not found: $BD_SRC (run run_all.tcl first)" >&2; exit 1; }
mkdir -p "$SSC" "$ART"

copy() {
    local src="${IMPL}/$1" dst="$2/$1"
    if [ -f "$src" ]; then cp -f "$src" "$dst"; echo "  staged: $1 -> ${dst#$REPO/}";
    elif [ "${3:-}" = required ]; then echo "ERROR: missing required artifact: $src" >&2; exit 1;
    else echo "  (skip, absent): $1"; fi
}

echo "=== linker inputs -> ${SSC#$REPO/} ==="
copy static_shell_slash.dcp "$SSC" required
rm -rf "${SSC}/slash_base.tmp" && cp -a "$BD_SRC" "${SSC}/slash_base.tmp"
cp -f "${SSC}/slash_base/__init__.py" "${SSC}/slash_base.tmp/__init__.py"
rm -rf "${SSC}/slash_base" && mv "${SSC}/slash_base.tmp" "${SSC}/slash_base"
echo "  staged: slash_base BD -> ${SSC#$REPO/}/slash_base/"
USER_CLK_MHZ=$(sed -nE 's/^set ::felix_user_clk_mhz ([0-9]+).*/\1/p' "${REPO}/felix/hw/scripts/run_all.tcl")
[ -n "$USER_CLK_MHZ" ] || { echo "ERROR: felix_user_clk_mhz not found in run_all.tcl" >&2; exit 1; }
GT_STREAMS=$(sed -nE 's/^set ::felix_gt_quads \{([^}]*)\}.*/\1/p' "${REPO}/felix/hw/scripts/run_all.tcl" | wc -w)
GT_MBPS=$(sed -nE 's/^set ::felix_gt_stream_mbps ([0-9]+).*/\1/p' "${REPO}/felix/hw/scripts/run_all.tcl")
cat > "${SSC}/board.json" <<EOF
{
  "board": "felix",
  "part": "xcvp1552-vsva3340-2MHP-e-S",
  "hbm_axi_ports": false,
  "rm_reset_bufg": false,
  "user_clock_at_source": true,
  "max_user_clock_hz": ${USER_CLK_MHZ}000000,
  "gt_streams": ${GT_STREAMS},
  "gt_stream_mbps": ${GT_MBPS:-0}
}
EOF
echo "  wrote:  ${SSC#$REPO/}/board.json"
printf '*\n' > "${SSC}/.gitignore"

echo "=== firmware / deploy inputs -> ${ART#$REPO/} ==="
copy felix_slash.xsa                  "$ART" required
copy top_wrapper.pdi                  "$ART" required
copy top_wrapper_routed_bb.dcp        "$ART"
copy report_timing_summary_static.txt "$ART"

echo "STAGE_ARTIFACTS_DONE"
