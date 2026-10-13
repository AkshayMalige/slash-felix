#!/usr/bin/env bash
set -Eeuo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run with sudo: sudo bash felix/scripts/install_sw.sh" >&2; exit 1; }
[ -d deb ] || { echo "ERROR: deb/ not found -- run felix/scripts/build_all.sh sw first" >&2; exit 1; }

source scripts/slash-packages.sh
VERSION="$(tr -d '[:space:]' < packaging/version)"

files=()
for p in "${DEB_PACKAGES[@]}"; do
    hits=( deb/${p}_*.deb )
    [ -e "${hits[0]}" ] || { echo "ERROR: no .deb found for $p in deb/" >&2; exit 1; }
    [ "${#hits[@]}" -eq 1 ] || { echo "ERROR: ${#hits[@]} candidate .debs for $p in deb/: ${hits[*]}" >&2; exit 1; }
    files+=( "./${hits[0]}" )
done

echo "== installing ${#files[@]} packages (forced reinstall) =="
apt-get install -y --reinstall --allow-downgrades "${files[@]}"

echo
echo "== verifying the install actually landed =="
rc=0
check() {
    if grep -aq -- "$3" "$2" 2>/dev/null; then
        echo "  OK   : $1"
    else
        echo "  FAIL : $1  (missing '$3' in $2)"
        rc=1
    fi
}
check "libslash-dev uapi header has per-queue aperture_size" \
      /usr/include/slash/uapi/slash_interface.h aperture_size
check "dkms driver source uapi header has per-queue aperture_size" \
      "/usr/src/slash-${VERSION}/driver/libslash/include/slash/uapi/slash_interface.h" aperture_size
cmp -s /usr/include/slash/uapi/slash_interface.h \
       "/usr/src/slash-${VERSION}/driver/libslash/include/slash/uapi/slash_interface.h" \
    && echo "  OK   : uapi header identical in libslash-dev and slash-dkms" \
    || { echo "  FAIL : uapi header differs between libslash-dev and slash-dkms"; rc=1; }
command -v slashkit >/dev/null && echo "  OK   : slashkit on PATH" || { echo "  FAIL : slashkit not on PATH"; rc=1; }

FELIX_DDR_SIZE=14G
mkdir -p /etc/vrt/vrtd.conf.d
cat > /etc/vrt/vrtd.conf.d/felix.conf <<EOC
ddr-size = ${FELIX_DDR_SIZE}
EOC
check "vrtd.conf includes vrtd.conf.d/" /etc/vrt/vrtd.conf "include-glob = vrtd.conf.d/"
check "vrtd ddr-size = ${FELIX_DDR_SIZE} (FELIX 16 GB DIMM)" /etc/vrt/vrtd.conf.d/felix.conf "ddr-size = ${FELIX_DDR_SIZE}"
check "installed vrtd understands ddr-size" /usr/lib/vrt/vrtd "ddr-size"

systemctl enable vrtd.socket vrtd.service >/dev/null 2>&1 || true
for u in vrtd.socket vrtd.service; do
    if systemctl is-enabled --quiet "$u"; then
        echo "  OK   : $u enabled at boot"
    else
        echo "  FAIL : $u not enabled at boot"; rc=1
    fi
done

echo
echo "== dkms status =="
dkms status | grep -iE 'slash|ami' || true
if ! dkms status | grep -q "slash/${VERSION}, $(uname -r).*installed"; then
    echo "  FAIL : slash.ko ${VERSION} not built+installed for $(uname -r)"
    rc=1
else
    echo "  OK   : slash.ko ${VERSION} built for $(uname -r)"
fi

echo
if [ "$rc" -ne 0 ]; then
    echo "########## INSTALL INCOMPLETE -- do NOT power cycle. Fix the FAILs above. ##########"
    exit 1
fi
cat <<'EOF'
##############################################################################
# INSTALL VERIFIED. Now power cycle (the module cannot hot-swap -- stale QDMA
# queues hold a refcount):
#
#     sudo sync && sudo ipmitool chassis power cycle
#
# After it comes back, check vrtd is healthy BEFORE running an example:
#     systemctl status vrtd.socket --no-pager
#     journalctl -u vrtd -n 20 --no-pager   # no "Inappropriate ioctl", no restart
#                                          # loop, no "shell build-ID ... did not respond",
#                                          # "DDR size for buffer allocation: 14336 MB"
#     v80-smi list                         # FELIX shows as the compute shell
##############################################################################
EOF
