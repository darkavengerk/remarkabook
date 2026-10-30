#!/bin/sh
# Install (or update) the dual-rM files on the SUB tablet from a PC.
#
#   ./install.sh <sub-ssh-target> [main-wifi-ip]
#
#   <sub-ssh-target>  anything ssh accepts, e.g. root@10.11.99.1 or a ~/.ssh/config alias
#   [main-wifi-ip]    written to dualrm.conf as MAIN_LAN on first install (optional)
#
# Requires xovi + qt-resource-rebuilder already set up on the sub.
# Does NOT touch the device tree (see pogo/README.md) and installs nothing on the main.
# Safe to re-run: files are overwritten, the key and dualrm.conf are kept.
set -e
SUB=${1:?usage: $0 <sub-ssh-target> [main-wifi-ip]}
MAIN_LAN=${2:-}
cd "$(dirname "$0")/sub"

ssh "$SUB" 'mkdir -p /home/root/dualrm && test -d /home/root/xovi/exthome/qt-resource-rebuilder' \
    || { echo "xovi/qt-resource-rebuilder not found on $SUB" >&2; exit 1; }

tar cf - dualrm-sync.sh dualrm-agent.sh dualrm-usbrole.sh dualrm-pogo.sh dualrm.conf.example \
    systemd etc xovi | ssh "$SUB" 'rm -rf /tmp/dualrm-install && mkdir /tmp/dualrm-install && tar xf - -C /tmp/dualrm-install'
ssh "$SUB" "MAIN_LAN='$MAIN_LAN' sh -s" <<'EOF'
set -e
D=/home/root/dualrm
T=/tmp/dualrm-install
cp "$T"/dualrm-sync.sh "$T"/dualrm-agent.sh "$T"/dualrm-usbrole.sh "$T"/dualrm-pogo.sh "$D"/
chmod +x "$D"/*.sh
cp "$T"/xovi/dualrm-open.qmd /home/root/xovi/exthome/qt-resource-rebuilder/
cp "$T"/systemd/dualrm-*.service /etc/systemd/system/
mkdir -p /etc/systemd/system/usb-ether-once.service.d
cp "$T"/systemd/usb-ether-once-dualrm.conf /etc/systemd/system/usb-ether-once.service.d/dualrm.conf
cp "$T"/etc/dualrm-fix-udc.sh /etc/
cp "$T"/etc/05-dualrm-host.network /etc/systemd/network/
if [ ! -f "$D/dualrm.conf" ]; then
    if [ -n "$MAIN_LAN" ]; then echo "MAIN_LAN=$MAIN_LAN" > "$D/dualrm.conf"
    else cp "$T"/dualrm.conf.example "$D/dualrm.conf"; fi
fi
rm -rf "$T"
[ -f "$D/id_dualrm" ] || dropbearkey -t ed25519 -f "$D/id_dualrm" >/dev/null
dropbearkey -y -f "$D/id_dualrm" | grep '^ssh-' > "$D/id_dualrm.pub"

systemctl daemon-reload
systemctl enable dualrm-xovi dualrm-sync dualrm-usbrole >/dev/null 2>&1
# pogo helper only matters with the edited device tree (pogo controller in host mode)
ls -d /sys/devices/soc0/soc/30800000.aips-bus/30b10000.usb/ci_hdrc.* >/dev/null 2>&1 \
    && systemctl enable dualrm-pogo >/dev/null 2>&1
systemctl restart dualrm-xovi     # reload xochitl with the patch
systemctl restart dualrm-usbrole dualrm-sync
echo "installed. Add this key to the MAIN's /home/root/.ssh/authorized_keys:"
cat "$D/id_dualrm.pub"
EOF
