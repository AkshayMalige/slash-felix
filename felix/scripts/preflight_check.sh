#!/usr/bin/env bash

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
BDF="${BDF:-0000:41:00}"

PASS=0; FAIL=0; SKIP=0; WARN=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; SKIP=$((SKIP+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; WARN=$((WARN+1)); }

BD=felix/hw/scripts/export_top.tcl
AMC_ELF=felix/fw/build/AMC/build/amc.elf
BASE_PDI=felix/hw/artifacts/top_wrapper.pdi
AMC_PDI=felix/hw/amc_pdi/build/felix_slash_amc.pdi

echo
echo "=== 1. PS-side DDR route (the PLM-stall root cause) ======================"
if [ ! -f "$BD" ]; then
    bad "$BD missing - run 'felix/scripts/build_all.sh hw'"
else
    for space in PMC_NOC_AXI_0 LPD_AXI_NOC_0; do
        if grep -q "get_bd_addr_spaces static_region/aved/cips/${space}\] \[get_bd_addr_segs.*C0_DDR_LOW0" "$BD"; then
            ok "$space can reach C0_DDR_LOW0"
        else
            bad "$space has NO DDR mapping -> the AMC will stall the PLM. See 05_fix_static.tcl step 2c."
        fi
    done
    if grep -q "M00_INI" felix/hw/scripts/05_fix_static.tcl && \
       ! grep -q "S02_AXI" felix/hw/scripts/05_fix_static.tcl; then
        bad "05_fix_static.tcl does not re-point S02_AXI/S03_AXI off the dead M00_INI"
    else
        ok "05_fix_static.tcl re-points the PMC/RPU DDR routes"
    fi
    if grep -q "get_bd_addr_segs static_region/clk_rst_shell/build_id_gpio/S_AXI/Reg" "$BD" && \
       grep -q "assign_bd_address -offset 0x020400020000" "$BD"; then
        ok "shell build-ID register mapped at 0x204_0002_0000 (vrtd reads PF2 BAR4+0x20000)"
    else
        bad "no build-ID register at 0x204_0002_0000 -> vrtd cannot identify the shell"
    fi
fi
echo
echo "=== 1b. FELIX shell staged for the linker ==============================="
SSC=linker/slashkit/resources/static_shell_compute
for f in static_shell_slash.dcp slash_base/slash_base.bd board.json; do
    [ -f "$SSC/$f" ] && ok "$SSC/$f" || bad "$SSC/$f missing - run felix/scripts/stage_artifacts.sh"
done
IMPL_DCP=felix/hw/proj/felix_slash.runs/impl_1/static_shell_slash.dcp
if [ -f "$SSC/static_shell_slash.dcp" ] && [ -f "$IMPL_DCP" ] && ! cmp -s "$SSC/static_shell_slash.dcp" "$IMPL_DCP"; then
    bad "staged abstract shell differs from the last build's - run felix/scripts/stage_artifacts.sh"
fi

echo
echo "=== 2. AMC firmware load addresses ======================================="
if [ ! -f "$AMC_ELF" ]; then
    skip "$AMC_ELF not built yet (felix/scripts/build_all.sh fw)"
elif ! command -v readelf >/dev/null; then
    skip "readelf not available"
else
    bad_seg=0
    while read -r vaddr memsz; do
        [ -z "$vaddr" ] && continue
        end=$(( vaddr + memsz ))
        if [ "$vaddr" -ge 262144 ] && [ "$end" -gt 2147483648 ]; then
            bad "amc.elf segment 0x$(printf %x "$vaddr")..0x$(printf %x "$end") exceeds the 2G DDR low region"
            bad_seg=1
        fi
    done < <(readelf -lW "$AMC_ELF" | awk '/^  LOAD/{print strtonum($3), strtonum($6)}')
    [ "$bad_seg" -eq 0 ] && ok "amc.elf LOAD segments fit the mapped DDR low region"
    readelf -lW "$AMC_ELF" | awk '/^  LOAD/{printf "        LOAD vaddr=%s memsz=%s\n", $3, $6}'
fi

echo
echo "=== 3. Combined AMC PDI =================================================="
if [ ! -f "$AMC_PDI" ]; then
    skip "$AMC_PDI not built yet (felix/hw/amc_pdi/combine_amc_pdi.sh)"
else
    if [ -f "$BASE_PDI" ] && [ "$AMC_PDI" -ot "$BASE_PDI" ]; then
        bad "$AMC_PDI is OLDER than the base PDI - re-run combine_amc_pdi.sh"
    else
        ok "combined PDI is newer than the base PDI"
    fi
    if command -v bootgen >/dev/null; then
        _bg=$(bootgen -arch versal -read "$AMC_PDI" 2>&1)
        _n=$(grep -c "core: r5-0" <<<"$_bg")
        if [ "$_n" -ge 2 ]; then
            ok "combined PDI has $_n r5-0 partitions (AMC: TCM + DDR segments)"
        elif [ "$_n" -eq 1 ]; then
            bad "combined PDI has only 1 r5-0 partition - expected 2 (TCM + DDR). amc.elf may be truncated."
        else
            bad "combined PDI has no r5-0 image - the AMC is not in it"
        fi
        grep -q "rpu_subsystem \[id:0x1c000000\]" <<<"$_bg" \
            && ok "rpu_subsystem present with id 0x1c000000" \
            || bad "rpu_subsystem/id 0x1c000000 missing - check felix_pdi_combine.bif"
    else
        skip "bootgen not on PATH (source Vitis settings64.sh) - cannot inspect the PDI"
    fi
fi

echo
echo "=== 4. Artifacts staged from THIS implementation ========================="
IMPL=felix/hw/proj/felix_slash.runs/impl_1/top_wrapper.pdi
if [ ! -f "$IMPL" ]; then
    skip "no implemented PDI yet (run_impl.tcl still running or not started)"
elif [ ! -f "$BASE_PDI" ]; then
    bad "$BASE_PDI missing - run felix/scripts/stage_artifacts.sh"
elif [ "$BASE_PDI" -ot "$IMPL" ]; then
    bad "staged PDI is OLDER than impl output - run felix/scripts/stage_artifacts.sh"
else
    ok "staged base PDI is up to date with impl_1"
fi

echo
echo "=== 5. Host stack ========================================================"
for m in slash ami; do
    lsmod | grep -q "^${m} " && ok "module '$m' loaded" || bad "module '$m' NOT loaded (modprobe $m)"
done
for f in 0 1 2; do
    d=$(basename "$(readlink "/sys/bus/pci/devices/${BDF}.$f/driver" 2>/dev/null)" 2>/dev/null)
    if [ -n "$d" ]; then
        ok "PF$f bound to '$d'"
    elif [ "$f" = "2" ]; then
        bad "PF2 unbound - slash module not loaded, or the card is not enumerated at all"
    else
        warn "PF$f unbound - expected while the card has no valid image (kernel log shows 'Invalid config bar'). Re-check after a cold power cycle with the SD image."
    fi
done
if systemctl is-active --quiet vrtd.socket; then ok "vrtd.socket active"
else bad "vrtd.socket inactive - 'sudo systemctl enable --now vrtd.socket'. NEVER run 'vrtd' by hand."; fi
if systemctl is-enabled --quiet vrtd.socket 2>/dev/null; then ok "vrtd.socket enabled at boot"
else bad "vrtd.socket DISABLED - it will not come back after reboot: sudo systemctl enable --now vrtd.socket"; fi
id -nG | tr ' ' '\n' | grep -qx vrtadmin && ok "you are in group 'vrtadmin'" \
    || bad "not in 'vrtadmin' - vrtd will refuse design-write (usermod -aG vrtadmin \$USER; newgrp vrtadmin)"

echo
echo "=========================================================================="
printf 'PASS=%d  FAIL=%d  WARN=%d  SKIP=%d\n' "$PASS" "$FAIL" "$WARN" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
    echo "NOT ready - fix the FAILs above before programming."
    exit 1
fi
[ "$WARN" -gt 0 ] && echo "WARNs: read them above; they do not block."
echo "Build and host look consistent."
echo
echo "Reminders:"
echo "  * VRT/vrtd take the board address without the function: 0000:41:00"
echo "  * the card loads felix/hw/artifacts/felix_sd.img only on a COLD power cycle"
echo "  * after a power cycle: journalctl -u vrtd -b | grep -E 'DDR size|Discovered 1 device'"
exit 0
