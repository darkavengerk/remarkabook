#!/bin/sh
# Remove remarkabook from the tablets, from a PC.
#
#   ./uninstall.sh [-y] <sub-ssh-target|-> <main-ssh-target|->
#
#   "-" skips that tablet (e.g. one that is not around).
#   -y  do not ask before restarting xochitl
#
# Removes the services, scripts and the xochitl patch, takes the sub's key off the main and
# puts both tablets' USB-C ports back into device mode. xovi itself and its other extensions stay.
# Annotation backups (dualrm/backup), notebooks as they were before merging (dualrm/merged) and
# the shared notebooks' page maps (dualrm/pagemap, restored by install.sh) are kept in
# /home/root/dualrm-backup.
# xochitl is restarted with xovi (if installed), so other extensions keep working.
set -e
usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }
YES=0
[ "$1" = -h ] || [ "$1" = --help ] && usage 0
[ "$1" = -y ] && { YES=1; shift; }
[ $# -eq 2 ] || usage
SUB=$1; MAIN=$2

if [ $YES = 0 ]; then
    printf 'This removes remarkabook and restarts xochitl. Continue? [y/N] '
    read -r a
    case "$a" in y|Y|yes) ;; *) echo "aborted"; exit 1 ;; esac
fi

remove_node() { # target
    ssh "$1" sh -s <<'EOF'
D=/home/root/dualrm
systemctl disable --now dualrm-sync dualrm-usbrole dualrm-pogo dualrm-ev.socket dualrm-cmd.socket \
    dualrm-xovi dualrm-ssh.socket >/dev/null 2>&1
cd /etc/systemd/system && rm -f dualrm-sync.service dualrm-usbrole.service dualrm-pogo.service \
    dualrm-ev.socket dualrm-ev@.service dualrm-cmd.socket dualrm-cmd@.service dualrm-xovi.service \
    dualrm-ssh.socket dualrm-ssh@.service usb-ether-once.service.d/dualrm.conf
rmdir usb-ether-once.service.d 2>/dev/null
rm -f /etc/dualrm-fix-udc.sh /etc/systemd/network/05-dualrm-host.network \
    /etc/systemd/network/10-dualrm-peer.link
udevadm control --reload >/dev/null 2>&1
if [ -f /etc/NetworkManager/conf.d/dualrm.conf ]; then
    rm -f /etc/NetworkManager/conf.d/dualrm.conf
    nmcli general reload conf >/dev/null 2>&1
fi
systemctl daemon-reload
# USB-C back to device mode (PC file transfer / SSH over USB)
for r in /sys/devices/soc0/soc/30800000.aips-bus/30b20000.usb/ci_hdrc.*/role; do
    [ -f "$r" ] && echo gadget > "$r" 2>/dev/null
done
rm -f /home/root/xovi/exthome/qt-resource-rebuilder/dualrm.qmd /home/root/xovi/exthome/qt-resource-rebuilder/dualrm-tray.qmd
if [ -d "$D/backup" ] && [ -n "$(ls -A "$D/backup")" ]; then
    mkdir -p /home/root/dualrm-backup && cp -a "$D/backup/." /home/root/dualrm-backup/
    echo "  annotation backups kept in /home/root/dualrm-backup"
fi
if [ -d "$D/merged" ] && [ -n "$(ls -A "$D/merged")" ]; then
    mkdir -p /home/root/dualrm-backup/merged && cp -a "$D/merged/." /home/root/dualrm-backup/merged/
    echo "  notebooks as they were before merging kept in /home/root/dualrm-backup/merged"
fi
# without its map a shared notebook would be merged again (pages doubled) after a reinstall
if [ -d "$D/pagemap" ] && [ -n "$(ls -A "$D/pagemap")" ]; then
    rm -rf /home/root/dualrm-backup/pagemap
    mkdir -p /home/root/dualrm-backup/pagemap && cp -a "$D/pagemap/." /home/root/dualrm-backup/pagemap/
    echo "  shared notebooks' page maps kept in /home/root/dualrm-backup/pagemap"
fi
rm -rf "$D"
# reload xochitl without the patch (with xovi when it is installed)
if [ -f /home/root/xovi/start ]; then bash /home/root/xovi/start >/dev/null 2>&1 </dev/null
else systemctl restart xochitl; fi
echo "  removed"
EOF
}

key=""
[ "$SUB" = - ] || key=$(ssh "$SUB" cat /home/root/dualrm/id_dualrm.pub 2>/dev/null || :)
if [ "$MAIN" != - ]; then
    echo "main ($MAIN):"
    remove_node "$MAIN"
    if [ -n "$key" ]; then
        ssh "$MAIN" "f=/home/root/.ssh/authorized_keys; [ -f \$f ] && grep -vxF '$key' \$f > \$f.tmp; mv -f \$f.tmp \$f 2>/dev/null; chmod 600 \$f 2>/dev/null; :"
        echo "  the sub's key is no longer authorized"
    else
        echo "  (the sub's key could not be read: remove its line from /home/root/.ssh/authorized_keys by hand)"
    fi
fi
if [ "$SUB" != - ]; then
    echo "sub ($SUB):"
    remove_node "$SUB"
fi
echo "done. To stop starting xovi at boot as well, see the xovi documentation."
