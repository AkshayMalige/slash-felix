#!/usr/bin/env bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BDF="${BDF:-0000:41:00}"
RP_CACHE=/run/felix-modeswitch.rootport
SLASH_IDS=("10ee:50b4" "10ee:50c1" "10ee:50c2")
SLASH_DRVS=("ami" "slash_qdma" "slash_ctl")
EXPECT_LINK="32.0 GT/s PCIe x8"
FLXNET="${FLXNET:-$HERE/build/flxnet-drivers}"
FLXNET_REPO=https://gitlab.cern.ch/atlas-tdaq-felix/felix-versal-tools/flxnet-drivers.git
FLXNET_COMMIT=c7d92d8f8030f3191e8c98b7cf41ee2584d7107d

usage() {
    cat <<EOU
usage: $0 status
       sudo $0 reboot --image N [--delay S] [--hold S] [--card ADDR] [--expect slash|felix] [--yes]
       sudo $0 wait-reboot [--settle S] [--expect slash|felix] [--yes]
       sudo $0 recover
       sudo $0 flxnet-up [--card ADDR]
       sudo $0 flxnet-down
       $0 build-flxnet

  status        which design the card runs, link state, AMC reset mailbox, flxnet driver
  reboot        reboot the chip into SD boot file N (0 = BOOT.BIN, N = BOOT000N.BIN) while
                the PCIe link is held down.
                SLASH mode: the AMC reboots the chip.
                FELIX mode: loads the flxnet driver (network over PCIe), runs felix-to-slash
                on FELIX Linux with ssh (user root, asks for its password), unloads the driver
  wait-reboot   any mode: take the link down, wait until the card is rebooted by
                other means (e.g. felix-to-slash on the card console), bring the link up
  recover       link up and rescan after an interrupted run
  flxnet-up     FELIX mode: load the flxnet driver, bring flxnet0 up, print the card's address
                for ssh; unload it with flxnet-down before the card reboots
  flxnet-down   unload the flxnet driver
  build-flxnet  build the flxnet driver for this kernel in $FLXNET

  options: --delay S  the card reboots S s after the request (default 8)
           --hold S   link stays down S s (SLASH mode: default 30, at least delay + 12;
                      FELIX mode: default delay + 60, at least delay + 30)
           --settle S wait-reboot: wait S s after Enter before link up (default 10)
           --card ADDR  FELIX Linux address on flxnet0 (default: found with ping)
           --root-port DDDD:BB:DD.F   if the card is missing from lspci
           env BDF (default 0000:41:00), FLXNET (flxnet driver folder)
EOU
    exit 2
}

CMD="${1:-}"; [ -n "$CMD" ] || usage; shift
IMAGE=""; DELAY=8; HOLD=""; SETTLE=10; EXPECT=""; YES=0; RP=""; CARD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        --delay) DELAY="$2"; shift 2 ;;
        --hold) HOLD="$2"; shift 2 ;;
        --settle) SETTLE="$2"; shift 2 ;;
        --expect) EXPECT="$2"; shift 2 ;;
        --card) CARD="$2"; shift 2 ;;
        --root-port) RP="$2"; shift 2 ;;
        --yes) YES=1; shift ;;
        *) usage ;;
    esac
done

T0=$(date +%s)
IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1
USR="${SUDO_USER:-$(id -un)}"
LINK_DOWN=0
FLXNET_UP=0

log() {
    echo "[$(date +%T) +$(( $(date +%s) - T0 ))s] $*"
    [ "$IS_ROOT" -eq 1 ] && echo "FELIX-MODESWITCH $CMD: $*" > /dev/kmsg 2>/dev/null
    return 0
}
die() { log "ABORT: $*"; exit 1; }
on_exit() {
    [ "$FLXNET_UP" -eq 1 ] && flxnet_unload
    if [ "$LINK_DOWN" -eq 1 ]; then
        echo "The PCIe link is still disabled. Bring the card back with: sudo $0 recover"
    fi
}
trap on_exit EXIT
as_user() { if [ "$IS_ROOT" -eq 1 ] && [ -n "${SUDO_USER:-}" ]; then sudo -u "$USR" -H "$@"; else "$@"; fi; }
need_root() { [ "$IS_ROOT" -eq 1 ] || { echo "run with sudo: sudo $0 $CMD ..." >&2; exit 1; }; }

if [ "$CMD" = build-flxnet ]; then
    KDIR="/lib/modules/$(uname -r)/build"
    [ -d "$KDIR" ] || die "kernel headers not found: $KDIR (package linux-headers-$(uname -r))"
    if [ ! -d "$FLXNET/.git" ]; then
        as_user mkdir -p "$(dirname "$FLXNET")"
        as_user git clone -q "$FLXNET_REPO" "$FLXNET" || die "git clone $FLXNET_REPO failed"
    fi
    as_user git -C "$FLXNET" checkout -q "$FLXNET_COMMIT" || die "commit $FLXNET_COMMIT not found in $FLXNET"
    as_user make -s -C "$KDIR" M="$FLXNET" clean
    as_user make -s -C "$KDIR" M="$FLXNET" modules || die "build failed"
    log "built $FLXNET/flxnet_dev.ko and flxnet_pcie.ko for kernel $(uname -r)"
    exit 0
fi

if [ -z "$RP" ]; then
    if [ -e "/sys/bus/pci/devices/$BDF.0" ]; then
        RP="$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$BDF.0")")")"
    elif [ -f "$RP_CACHE" ]; then
        RP="$(cat "$RP_CACHE")"
    fi
fi
[ -n "$RP" ] || die "cannot find the root port of $BDF; pass --root-port"
[ "$IS_ROOT" -eq 1 ] && echo "$RP" > "$RP_CACHE"

lnkcap() { setpci -s "$RP" CAP_EXP+0x0c.l; }
lnksta() { setpci -s "$RP" CAP_EXP+0x12.w; }
DLL_CAPABLE=0
[ "$IS_ROOT" -eq 1 ] && [ $(( (16#$(lnkcap) >> 20) & 1 )) -eq 1 ] && DLL_CAPABLE=1

link_str() {
    local s=$((16#$(lnksta)))
    echo "gen=$((s & 0xf)) width=x$(((s >> 4) & 0x3f)) training=$(((s >> 11) & 1)) dll_active=$(((s >> 13) & 1))"
}
link_is_up() {
    local s=$((16#$(lnksta)))
    [ $(((s >> 11) & 1)) -eq 0 ] || return 1
    if [ "$DLL_CAPABLE" -eq 1 ]; then [ $(((s >> 13) & 1)) -eq 1 ]; else [ $(((s >> 4) & 0x3f)) -gt 0 ]; fi
}
wait_link() {
    local want="$1" t=0
    while [ "$t" -lt $(($2 * 5)) ]; do
        if [ "$want" = up ] && link_is_up; then return 0; fi
        if [ "$want" = down ] && ! link_is_up; then return 0; fi
        sleep 0.2; t=$((t + 1))
    done
    return 1
}
link_disable() {
    setpci -s "$RP" CAP_EXP+0x10.w=0010:0010
    LINK_DOWN=1
    if wait_link down 5; then log "link disabled ($(link_str))"; else log "link did not report down ($(link_str))"; fi
}
link_enable() {
    setpci -s "$RP" CAP_EXP+0x10.w=0000:0010
    LINK_DOWN=0
    local t; t=$(date +%s)
    wait_link up "$1" || die "link not up $1 s after Link Enable ($(link_str))"
    log "link up after $(( $(date +%s) - t )) s ($(link_str))"
    sleep 0.5
}

devices() { ls "/sys/bus/pci/devices/$RP/" 2>/dev/null | grep -E '^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$' || true; }
id_of() { echo "$(cut -c3- "/sys/bus/pci/devices/$1/vendor"):$(cut -c3- "/sys/bus/pci/devices/$1/device")"; }
drv_of() { [ -e "/sys/bus/pci/devices/$1/driver" ] && basename "$(readlink -f "/sys/bus/pci/devices/$1/driver")" || echo none; }

mode_now() {
    local ids=() d
    for d in $(devices); do ids+=("$(id_of "$d")"); done
    [ "${#ids[@]}" -gt 0 ] || { echo NONE; return; }
    case " ${ids[*]} " in *" 10ee:50b4 "*) echo SLASH; return ;; esac
    case " ${ids[*]} " in *" 10dc:"*) echo FELIX; return ;; esac
    echo UNKNOWN
}

slash_bound() {
    local i
    for i in 0 1 2; do
        local d="$BDF.$i"
        [ -e "/sys/bus/pci/devices/$d" ] || return 1
        [ "$(id_of "$d")" = "${SLASH_IDS[$i]}" ] || return 1
        [ "$(drv_of "$d")" = "${SLASH_DRVS[$i]}" ] || return 1
    done
}

stop_vrtd() {
    if systemctl is-active --quiet vrtd.service || systemctl is-active --quiet vrtd.socket; then
        log "stopping vrtd"
        systemctl stop vrtd.socket vrtd.service
    fi
    local users
    users=$(fuser /dev/slash_ctl* /dev/slash_qdma* /dev/slash_hotplug 2>/dev/null || true)
    if [ -n "$users" ]; then
        log "processes still use the card: $users"
        systemctl start vrtd.socket vrtd.service || true
        die "stop the programs using the card first"
    fi
}

remove_devices() {
    local d
    for d in $(devices | sort -r); do
        log "remove $d ($(id_of "$d"), driver $(drv_of "$d"))"
        echo 1 > "/sys/bus/pci/devices/$d/remove"
    done
    [ -z "$(devices)" ] || die "devices still present after remove"
}

confirm() {
    [ "$YES" -eq 1 ] && return 0
    echo
    echo "This takes the card's PCIe link down. This server's BIOS handles PCIe errors itself"
    echo "(firmware-first) and could reset the whole server if something goes wrong. Save your work."
    local ans
    read -r -p "Type YES to continue: " ans < /dev/tty || ans=""
    [ "$ans" = YES ] || die "not confirmed"
}

mailbox() { python3 "$HERE/reset_mbox.py" --bdf "$BDF.0" "$@"; }

check_unbound() {
    local d drv
    for d in $(devices); do
        drv=$(drv_of "$d")
        case " ${SLASH_DRVS[*]} none " in
            *" $drv "*) ;;
            *) die "$d has the driver $drv bound; unload it first" ;;
        esac
    done
}

flxnet_loaded() { [ -d /sys/module/flxnet_pcie ] || [ -d /sys/module/flxnet_dev ]; }
flxnet_unload() {
    local m
    for m in flxnet_pcie flxnet_dev; do
        [ -d "/sys/module/$m" ] || continue
        rmmod "$m" || { log "rmmod $m failed"; return 1; }
    done
    FLXNET_UP=0
    log "flxnet driver unloaded"
}
flxnet_check() {
    local ko
    for ko in flxnet_dev flxnet_pcie; do
        [ -f "$FLXNET/$ko.ko" ] || die "$FLXNET/$ko.ko not found; build it with: $0 build-flxnet"
        [ "$(modinfo -F vermagic "$FLXNET/$ko.ko" 2>/dev/null | cut -d' ' -f1)" = "$(uname -r)" ] \
            || die "$FLXNET/$ko.ko is not built for kernel $(uname -r); run: $0 build-flxnet"
    done
}
flxnet_addr() { ip -6 -o addr show dev flxnet0 scope link 2>/dev/null | grep -v tentative | awk '{print $4}' | cut -d/ -f1; }
flxnet_up() {
    flxnet_loaded && { flxnet_unload || die "cannot unload the flxnet driver that is already loaded"; }
    FLXNET_UP=1
    insmod "$FLXNET/flxnet_dev.ko" || die "insmod flxnet_dev.ko failed"
    insmod "$FLXNET/flxnet_pcie.ko" || die "insmod flxnet_pcie.ko failed"
    local t=0
    until [ -e /sys/class/net/flxnet0 ]; do
        sleep 0.2; t=$((t + 1))
        [ "$t" -lt 25 ] || die "flxnet_pcie did not create flxnet0 (dmesg | grep flxnet)"
    done
    # NetworkManager may claim flxnet0 and remove its IPv6 link-local address: release it,
    # then make sure the kernel creates a fresh link-local address.
    if command -v nmcli > /dev/null && nmcli -t -f RUNNING general 2>/dev/null | grep -qx running; then
        t=0
        until nmcli -t -f DEVICE device 2>/dev/null | grep -qx flxnet0; do
            sleep 0.2; t=$((t + 1))
            [ "$t" -lt 25 ] || break
        done
        nmcli device set flxnet0 managed no > /dev/null 2>&1 || log "WARNING: NetworkManager did not release flxnet0"
    fi
    ip link set flxnet0 down
    sysctl -qw net.ipv6.conf.flxnet0.disable_ipv6=0 net.ipv6.conf.flxnet0.addr_gen_mode=0
    ip -6 addr flush dev flxnet0 scope link
    ip link set flxnet0 up || die "cannot bring flxnet0 up"
    t=0
    until [ -n "$(flxnet_addr)" ]; do
        sleep 0.2; t=$((t + 1))
        [ "$t" -lt 50 ] || die "flxnet0 got no IPv6 link-local address"
    done
    log "flxnet driver loaded, flxnet0 up ($(flxnet_addr))"
}
flxnet_find() {
    local own a end=$((SECONDS + 90))
    own=$(flxnet_addr)
    while [ "$SECONDS" -lt "$end" ]; do
        for a in $(ping -6 -n -c 2 -w 3 "ff02::1%flxnet0" 2>/dev/null | grep -oE 'from fe80:[0-9a-f:]+' | cut -d' ' -f2 | sort -u); do
            grep -qxF "$a" <<< "$own" || { echo "$a"; return 0; }
        done
    done
    return 1
}
card_ssh() {
    as_user ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=10 "root@$CARD%flxnet0" "$@"
}

came_up() {
    local want_mb="${1:-}"
    log "rescan via $RP"
    echo 1 > "/sys/bus/pci/devices/$RP/rescan"
    local t=0
    until [ -n "$(devices)" ]; do
        sleep 1; t=$((t + 1))
        [ "$t" -lt 30 ] || die "no device appeared behind $RP"
    done
    sleep 1
    local mode; mode=$(mode_now)
    local d
    for d in $(devices); do
        local l; l="$(cat "/sys/bus/pci/devices/$d/current_link_speed") x$(cat "/sys/bus/pci/devices/$d/current_link_width")"
        log "found $d $(id_of "$d") link $l"
        [ "$l" = "$EXPECT_LINK" ] || log "WARNING: link is $l, expected $EXPECT_LINK"
    done
    RESULT=PASS
    if [ "$mode" = SLASH ]; then
        log "SLASH: waiting for the drivers (ami waits for the AMC, up to ~60 s)"
        t=0
        until slash_bound; do
            sleep 1; t=$((t + 1))
            [ "$t" -lt 120 ] || die "SLASH functions/drivers not complete after 120 s"
        done
        log "SLASH functions bound after $t s"
        systemctl reset-failed vrtd.service 2>/dev/null || true
        systemctl start vrtd.socket vrtd.service || log "WARNING: vrtd did not start"
        local mb; mb=$(mailbox status 2>&1)
        log "AMC mailbox: $mb"
        if [ -n "$want_mb" ]; then
            local got; got=$(echo "$mb" | grep -oE "boot_MULTI_BOOT=0x[0-9a-f]+" | cut -d= -f2)
            if [ "$got" = "$(printf '0x%08x' "$want_mb")" ]; then
                log "booted from the requested image (MULTI_BOOT $got)"
            else
                log "booted with MULTI_BOOT $got, requested $(printf '0x%08x' "$want_mb")"; RESULT=FAIL
            fi
        fi
        as_user v80-smi list 2>&1 | tail -1
    elif [ "$mode" = FELIX ]; then
        python3 "$HERE/mode_check.py" --root-port "$RP" || RESULT=FAIL
    else
        log "the card came back as $mode"; RESULT=FAIL
    fi
    if [ -n "$EXPECT" ] && [ "$mode" != "${EXPECT^^}" ]; then
        log "expected ${EXPECT^^}, got $mode"; RESULT=FAIL
    fi
    log "RESULT: $RESULT (card in $mode mode, $(( $(date +%s) - T0 )) s)"
    [ "$RESULT" = PASS ]
}

case "$CMD" in
    status)
        if [ "$IS_ROOT" -eq 1 ]; then echo "root port $RP: $(link_str)"; fi
        python3 "$HERE/mode_check.py" --root-port "$RP"
        echo "vrtd: $(systemctl is-active vrtd.service)"
        echo "flxnet driver: $(flxnet_loaded && echo loaded || echo not loaded)"
        if [ "$(mode_now)" = SLASH ] && [ "$IS_ROOT" -eq 1 ]; then
            echo "AMC reset mailbox: $(mailbox status 2>&1)"
        fi
        ;;
    reboot)
        need_root
        [[ "$IMAGE" =~ ^[0-9]$ ]] || die "--image N (0..9) is required"
        [[ "$DELAY" =~ ^[0-9]+$ ]] || die "--delay S must be a whole number of seconds"
        MB=$(( 0xF0000000 + IMAGE ))
        FILE=$( [ "$IMAGE" = 0 ] && echo BOOT.BIN || echo "BOOT000$IMAGE.BIN")
        MODE=$(mode_now)
        if [ "$MODE" = FELIX ]; then
            HOLD="${HOLD:-$((DELAY + 60))}"; MIN_HOLD=$((DELAY + 30))
        else
            HOLD="${HOLD:-30}"; MIN_HOLD=$((DELAY + 12))
        fi
        [ "$HOLD" -ge "$MIN_HOLD" ] || die "--hold must be at least $MIN_HOLD s in $MODE mode (--delay + card reboot time)"
        case "$MODE" in
            SLASH)
                slash_bound || die "SLASH functions or drivers are not complete; try: sudo $0 recover"
                mailbox status > /dev/null || die "AMC reset mailbox not ready: $(mailbox status 2>&1)"
                log "reboot into SD boot file $IMAGE ($FILE), root port $RP, link $(link_str)"
                confirm
                stop_vrtd
                log "asking the AMC for a system reset in $DELAY s with MULTI_BOOT $(printf '0x%08x' "$MB")"
                mailbox request --delay-ms $((DELAY * 1000)) --multiboot "$MB" || die "the AMC did not acknowledge (nothing was changed)"
                T_REQ=$(date +%s%N)
                ;;
            FELIX)
                check_unbound
                flxnet_check
                log "reboot into SD boot file $IMAGE ($FILE) from FELIX Linux over flxnet, root port $RP, link $(link_str)"
                confirm
                flxnet_up
                if [ -z "$CARD" ]; then
                    log "looking for FELIX Linux on flxnet0 (up to 90 s; it boots ~1 min after the switch into FELIX)"
                    CARD=$(flxnet_find) || die "FELIX Linux does not answer on flxnet0"
                fi
                log "ssh root@$CARD%flxnet0 felix-to-slash -m $(printf '0x%08X' "$MB") -d $DELAY"
                OUT=$(card_ssh "felix-to-slash -m $(printf '0x%08X' "$MB") -d $DELAY" 2>&1); RC=$?
                T_REQ=$(date +%s%N)
                while IFS= read -r l; do [ -n "$l" ] && log "card: $l"; done <<< "$OUT"
                if [[ "$OUT" == *"FELIX_TO_SLASH: ARMED"* ]]; then
                    :
                elif [[ "$OUT" == *"FELIX_TO_SLASH: FAIL"* || "$OUT" != *"MULTI_BOOT now"* ]]; then
                    die "felix-to-slash did not arm a reboot (ssh exit $RC); the card stays in FELIX mode"
                else
                    log "WARNING: felix-to-slash started but did not finish its report; handling the reboot as armed"
                fi
                flxnet_unload
                if [ -d /sys/module/flxnet_pcie ]; then
                    card_ssh "kill \$(pgrep -f '[s]ync; reboot')" \
                        && die "the flxnet driver could not be unloaded, so the card's reboot was cancelled"
                    die "the flxnet driver could not be unloaded and the card's reboot could not be cancelled. Cancel it NOW on the card console: kill \$(pgrep -f '[s]ync; reboot')"
                fi
                ;;
            *)
                die "the card is in $MODE mode; reboot needs SLASH or FELIX (try: sudo $0 recover)" ;;
        esac
        remove_devices
        link_disable
        EL=$(( ($(date +%s%N) - T_REQ) / 1000000 ))
        log "link down ${EL} ms after the request, the card reboots at $((DELAY * 1000)) ms"
        log "holding the link down for $HOLD s while the card reboots"
        sleep "$HOLD"
        link_enable 30
        came_up "$MB"
        ;;
    wait-reboot)
        need_root
        MODE=$(mode_now)
        log "card in $MODE mode, root port $RP, link $(link_str)"
        check_unbound
        confirm
        [ "$MODE" = SLASH ] && stop_vrtd
        if flxnet_loaded; then
            flxnet_unload || die "the flxnet driver could not be unloaded; it must not run while the card reboots"
        fi
        remove_devices
        link_disable
        echo
        echo "=================================================================================="
        echo " The card's PCIe link is OFF. Reboot the card now, for example on FELIX Linux:"
        echo "     felix-to-slash"
        echo " Wait until its console shows the new boot (Platform Loader and Manager banner),"
        echo " then press Enter here. Type  abort  and Enter to bring the old design back."
        echo "=================================================================================="
        read -r -p "Enter = the card is rebooting, abort = cancel: " ANS < /dev/tty || ANS=abort
        if [ "$ANS" = abort ]; then
            log "aborted by the operator"
            link_enable 30
            came_up || true
            exit 1
        fi
        log "waiting $SETTLE s before Link Enable"
        sleep "$SETTLE"
        link_enable 60
        came_up
        ;;
    flxnet-up)
        need_root
        MODE=$(mode_now)
        [ "$MODE" = FELIX ] || die "the card is in $MODE mode; flxnet exists only in FELIX mode"
        check_unbound
        flxnet_check
        flxnet_up
        if [ -z "$CARD" ]; then
            log "looking for FELIX Linux on flxnet0 (up to 90 s; it boots ~1 min after the switch into FELIX)"
            CARD=$(flxnet_find) || die "FELIX Linux does not answer on flxnet0"
        fi
        FLXNET_UP=0
        log "FELIX Linux answers at $CARD%flxnet0"
        echo "ssh root@$CARD%flxnet0      (unload before any card reboot: sudo $0 flxnet-down)"
        ;;
    flxnet-down)
        need_root
        if flxnet_loaded; then
            flxnet_unload || die "the flxnet driver could not be unloaded"
        else
            log "flxnet driver not loaded"
        fi
        ;;
    recover)
        need_root
        log "recover: link $(link_str)"
        link_enable 30
        came_up
        ;;
    *)
        usage ;;
esac
