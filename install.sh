#!/bin/sh
# Install (or update) dual-rM on both tablets from a PC.
#
#   ./install.sh <sub-ssh-target> <main-ssh-target> [main-wifi-ip]
#
#   targets       anything ssh accepts, e.g. root@10.11.99.1 or a ~/.ssh/config alias
#   main-wifi-ip  written to the sub's dualrm.conf as MAIN_LAN on first install (optional)
#
# Requires xovi + qt-resource-rebuilder (with a hashtab for the installed firmware) on BOTH.
# Does NOT touch the device tree (see pogo/README.md).
# Safe to re-run: files are overwritten, the key and dualrm.conf are kept.
# Each run restarts xochitl once per tablet (xochitl allows 4 starts per 10 minutes).
set -e
SUB=${1:?usage: $0 <sub-ssh-target> <main-ssh-target> [main-wifi-ip]}
MAIN=${2:?usage: $0 <sub-ssh-target> <main-ssh-target> [main-wifi-ip]}
MAIN_LAN=${3:-}
cd "$(dirname "$0")"

node() { # target extra-files-from-sub/...
    t=$1; shift
    ssh "$t" 'mkdir -p /home/root/dualrm && test -d /home/root/xovi/exthome/qt-resource-rebuilder' \
        || { echo "xovi/qt-resource-rebuilder not found on $t" >&2; exit 1; }
    tar cf - -C node dualrm-lib.sh dualrm-ev.sh dualrm-cmd.sh dualrm-link.sh systemd xovi \
        -C ../sub "$@" | ssh "$t" 'rm -rf /tmp/dualrm-install && mkdir /tmp/dualrm-install && tar xf - -C /tmp/dualrm-install'
    ssh "$t" sh -s <<'EOF'
set -e
D=/home/root/dualrm; T=/tmp/dualrm-install
cp "$T"/dualrm-*.sh "$D"/
chmod +x "$D"/*.sh
cp "$T"/xovi/dualrm.qmd /home/root/xovi/exthome/qt-resource-rebuilder/
rm -f /home/root/xovi/exthome/qt-resource-rebuilder/dualrm-open.qmd   # replaced by dualrm.qmd
cp "$T"/systemd/dualrm-ev.socket "$T"/systemd/dualrm-ev@.service \
   "$T"/systemd/dualrm-cmd.socket "$T"/systemd/dualrm-cmd@.service "$T"/systemd/dualrm-xovi.service \
   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now dualrm-ev.socket dualrm-cmd.socket >/dev/null 2>&1
systemctl enable dualrm-xovi >/dev/null 2>&1
EOF
}

# main: event/command sockets, link end, patch
node "$MAIN" systemd/dualrm-xovi.service
ssh "$MAIN" 'rm -rf /tmp/dualrm-install; systemctl restart dualrm-xovi'

# sub: the same, plus sync, USB role switching and the pogo helpers
node "$SUB" dualrm-sync.sh dualrm-usbrole.sh dualrm-pogo.sh dualrm.conf.example systemd etc
ssh "$SUB" "MAIN_LAN='$MAIN_LAN' sh -s" <<'EOF'
set -e
D=/home/root/dualrm; T=/tmp/dualrm-install
cp "$T"/systemd/dualrm-sync.service "$T"/systemd/dualrm-usbrole.service "$T"/systemd/dualrm-pogo.service /etc/systemd/system/
mkdir -p /etc/systemd/system/usb-ether-once.service.d
cp "$T"/systemd/usb-ether-once-dualrm.conf /etc/systemd/system/usb-ether-once.service.d/dualrm.conf
cp "$T"/etc/dualrm-fix-udc.sh /etc/
cp "$T"/etc/05-dualrm-host.network /etc/systemd/network/
if [ ! -f "$D/dualrm.conf" ]; then
    if [ -n "$MAIN_LAN" ]; then echo "MAIN_LAN=$MAIN_LAN" > "$D/dualrm.conf"
    else cp "$T"/dualrm.conf.example "$D/dualrm.conf"; fi
fi
rm -rf "$T" "$D/dualrm-agent.sh" "$D/request"
[ -f "$D/id_dualrm" ] || dropbearkey -t ed25519 -f "$D/id_dualrm" >/dev/null
dropbearkey -y -f "$D/id_dualrm" | grep '^ssh-' > "$D/id_dualrm.pub"

systemctl daemon-reload
systemctl enable dualrm-sync dualrm-usbrole >/dev/null 2>&1
# pogo helper only matters with the edited device tree (pogo controller in host mode)
ls -d /sys/devices/soc0/soc/30800000.aips-bus/30b10000.usb/ci_hdrc.* >/dev/null 2>&1 \
    && systemctl enable dualrm-pogo >/dev/null 2>&1
systemctl restart dualrm-xovi     # reload xochitl with the patch
systemctl restart dualrm-usbrole dualrm-sync
EOF

key=$(ssh "$SUB" cat /home/root/dualrm/id_dualrm.pub)
if ssh "$MAIN" "grep -qF '$key' /home/root/.ssh/authorized_keys 2>/dev/null"; then
    echo "installed; the sub's key is already authorized on the main."
else
    echo "installed. Add this key to the MAIN's /home/root/.ssh/authorized_keys:"
    echo "$key"
fi
