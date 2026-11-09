#!/bin/sh
# Install (or update) remarkabook on two reMarkable 2 tablets from a PC.
#
#   ./install.sh [-y] <sub-ssh-target> <main-ssh-target> [main-wifi-ip]
#
#   sub           the tablet that runs the sync and logs in to the other one
#   main          the other tablet (on a USB cable, either one can sit on either side)
#   targets       anything ssh accepts, e.g. root@10.11.99.1 or a ~/.ssh/config alias
#   main-wifi-ip  written to the sub's dualrm.conf as MAIN_LAN on first install (optional:
#                 the sub also finds the main on a shared WiFi by itself; this is only faster)
#   -y            do not ask before restarting xochitl
#
# Requires xovi + qt-resource-rebuilder (with a hashtab for the installed firmware) on BOTH.
# Does NOT touch the device tree (see pogo/README.md).
# Safe to re-run: files are overwritten, the key and dualrm.conf are kept.
# Each run restarts xochitl once per tablet (xochitl allows 4 starts per 10 minutes).
set -e
TESTED="3.23 3.29"      # firmware versions this was tested with (major.minor)
usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

YES=0
[ "$1" = -h ] || [ "$1" = --help ] && usage 0
[ "$1" = -y ] && { YES=1; shift; }
[ $# -ge 2 ] || usage
SUB=$1; MAIN=$2; MAIN_LAN=${3:-}
cd "$(dirname "$0")"

# ---------------------------------------------------------------- checks
check() { # target role -> prints the firmware version; exits on a blocking problem
    out=$(ssh -o ConnectTimeout=10 "$1" sh -s <<'EOF'
m=$(tr -d '\0' < /sys/devices/soc0/machine 2>/dev/null)
v=$(sed -n 's/^IMG_VERSION="\{0,1\}\([0-9][0-9.]*\).*/\1/p' /etc/os-release 2>/dev/null)
[ -n "$v" ] || v=$(sed -n 's/^REMARKABLE_RELEASE_VERSION=//p' /usr/share/remarkable/update.conf 2>/dev/null)
echo "machine=$m"
echo "version=$v"
X=/home/root/xovi
[ -f $X/xovi.so ] && [ -f $X/start ] || echo "missing=xovi (/home/root/xovi/xovi.so, start)"
[ -f $X/extensions.d/qt-resource-rebuilder.so ] || echo "missing=qt-resource-rebuilder"
[ -f $X/exthome/qt-resource-rebuilder/hashtab ] || echo "missing=hashtab (run /home/root/xovi/rebuild_hashtable)"
command -v systemctl >/dev/null || echo "missing=systemd"
EOF
) || { echo "cannot reach the $2 ($1) over ssh" >&2; exit 1; }
    m=$(echo "$out" | sed -n 's/^machine=//p'); v=$(echo "$out" | sed -n 's/^version=//p')
    case "$m" in
        "reMarkable 2"*) ;;
        *) echo "the $2 ($1) is '${m:-unknown}': only the reMarkable 2 is supported" >&2; exit 1 ;;
    esac
    if echo "$out" | grep -q '^missing='; then
        echo "the $2 ($1) is not ready:" >&2
        echo "$out" | sed -n 's/^missing=/  - /p' >&2
        exit 1
    fi
    mm=$(echo "$v" | cut -d. -f1,2)
    case " $TESTED " in
        *" $mm "*) ;;
        *) echo "warning: the $2 runs firmware ${v:-unknown}, not tested (tested: $TESTED)." >&2
           echo "         If xochitl misbehaves, run /home/root/xovi/stock on it and see README." >&2 ;;
    esac
    echo "$2: $m, firmware ${v:-unknown}"
}
check "$MAIN" main
check "$SUB" sub
idm=$(ssh "$MAIN" cat /etc/machine-id 2>/dev/null || :); ids=$(ssh "$SUB" cat /etc/machine-id 2>/dev/null || :)
if [ -n "$idm" ] && [ "$idm" = "$ids" ]; then echo "main and sub are the same tablet" >&2; exit 1; fi

if [ $YES = 0 ]; then
    printf 'This restarts xochitl on both tablets (open documents are saved). Continue? [y/N] '
    read -r a
    case "$a" in y|Y|yes) ;; *) echo "aborted"; exit 1 ;; esac
fi

# ---------------------------------------------------------------- both tablets
install_node() { # target [tar arguments for more files: -C ../sub file...]
    t=$1; shift
    tar cf - -C node dualrm-lib.sh dualrm-ev.sh dualrm-cmd.sh dualrm-link.sh dualrm-usbrole.sh \
        systemd xovi etc "$@" \
        | ssh "$t" 'rm -rf /tmp/dualrm-install && mkdir /tmp/dualrm-install && tar xf - -C /tmp/dualrm-install'
    ssh "$t" sh -s <<'EOF'
set -e
D=/home/root/dualrm; T=/tmp/dualrm-install
mkdir -p "$D"
cp "$T"/dualrm-*.sh "$D"/
chmod +x "$D"/*.sh
cp "$T"/xovi/dualrm.qmd "$T"/xovi/dualrm-tray.qmd /home/root/xovi/exthome/qt-resource-rebuilder/
cp "$T"/systemd/dualrm-ev.socket "$T"/systemd/dualrm-ev@.service \
   "$T"/systemd/dualrm-cmd.socket "$T"/systemd/dualrm-cmd@.service "$T"/systemd/dualrm-xovi.service \
   "$T"/systemd/dualrm-usbrole.service /etc/systemd/system/
# the other tablet on the cable is always named dualrm0 (devices plugged in from now on)
mkdir -p /etc/systemd/network
cp "$T"/etc/10-dualrm-peer.link /etc/systemd/network/
udevadm control --reload >/dev/null 2>&1 || :
systemctl daemon-reload
systemctl enable --now dualrm-ev.socket dualrm-cmd.socket >/dev/null 2>&1
systemctl enable dualrm-xovi dualrm-usbrole >/dev/null 2>&1
EOF
}

# main: event/command sockets, link end, patch, USB role switching, SSH on the cable
echo "installing on the main ($MAIN)"
install_node "$MAIN" -C ../sub systemd/dualrm-xovi.service \
    -C ../main systemd/dualrm-ssh.socket systemd/dualrm-ssh@.service etc/NetworkManager-dualrm.conf
ssh "$MAIN" sh -s <<'EOF'
set -e
T=/tmp/dualrm-install
cp "$T"/systemd/dualrm-ssh.socket "$T"/systemd/dualrm-ssh@.service /etc/systemd/system/
# NetworkManager leaves dualrm0 alone (read now, applied when the device appears)
mkdir -p /etc/NetworkManager/conf.d
cp "$T"/etc/NetworkManager-dualrm.conf /etc/NetworkManager/conf.d/dualrm.conf
nmcli general reload conf >/dev/null 2>&1 || :
rm -rf "$T"
systemctl daemon-reload
# started each time dualrm0 appears (WantedBy its device unit); now only if it is there already
systemctl enable dualrm-ssh.socket >/dev/null 2>&1
[ ! -e /sys/class/net/dualrm0 ] || systemctl start dualrm-ssh.socket
systemctl restart dualrm-xovi dualrm-usbrole
EOF

# sub: the same, plus sync and the pogo helpers
echo "installing on the sub ($SUB)"
logn=$(ssh "$SUB" 'wc -l < /home/root/dualrm/sync.log 2>/dev/null || echo 0')
install_node "$SUB" -C ../sub dualrm-sync.sh dualrm-discover.sh dualrm-pagemap.sh dualrm-notebook.sh dualrm-pogo.sh dualrm.conf.example systemd etc
ssh "$SUB" "MAIN_LAN='$MAIN_LAN' sh -s" <<'EOF'
set -e
D=/home/root/dualrm; T=/tmp/dualrm-install
cp "$T"/systemd/dualrm-sync.service "$T"/systemd/dualrm-pogo.service /etc/systemd/system/
mkdir -p /etc/systemd/system/usb-ether-once.service.d
cp "$T"/systemd/usb-ether-once-dualrm.conf /etc/systemd/system/usb-ether-once.service.d/dualrm.conf
cp "$T"/etc/dualrm-fix-udc.sh /etc/
cp "$T"/etc/05-dualrm-host.network /etc/systemd/network/
if [ ! -f "$D/dualrm.conf" ]; then
    cp "$T"/dualrm.conf.example "$D/dualrm.conf"
    [ -n "$MAIN_LAN" ] && sed -i "s/^MAIN_LAN=.*/MAIN_LAN=$MAIN_LAN/" "$D/dualrm.conf"
fi
rm -rf "$T"
# page maps kept by uninstall.sh: shared notebooks stay paired (without them, merged again)
if [ -z "$(ls -A "$D/pagemap" 2>/dev/null)" ] && [ -d /home/root/dualrm-backup/pagemap ]; then
    mkdir -p "$D/pagemap" && cp -a /home/root/dualrm-backup/pagemap/. "$D/pagemap/"
    echo "  page maps restored from /home/root/dualrm-backup/pagemap"
fi
[ -f "$D/id_dualrm" ] || dropbearkey -t ed25519 -f "$D/id_dualrm" >/dev/null
dropbearkey -y -f "$D/id_dualrm" | grep '^ssh-' > "$D/id_dualrm.pub"

systemctl daemon-reload
systemctl enable dualrm-sync >/dev/null 2>&1
# pogo helper only matters with the edited device tree (pogo controller in host mode)
ls -d /sys/devices/soc0/soc/30800000.aips-bus/30b10000.usb/ci_hdrc.* >/dev/null 2>&1 \
    && systemctl enable dualrm-pogo >/dev/null 2>&1
EOF

# ---------------------------------------------------------------- the sub may log in to the main
key=$(ssh "$SUB" cat /home/root/dualrm/id_dualrm.pub)
ssh "$MAIN" "mkdir -p /home/root/.ssh && chmod 700 /home/root/.ssh &&
    { grep -qxF '$key' /home/root/.ssh/authorized_keys 2>/dev/null ||
      echo '$key' >> /home/root/.ssh/authorized_keys; } && chmod 600 /home/root/.ssh/authorized_keys"
echo "the sub's key is authorized on the main"

# ---------------------------------------------------------------- the main's id, for WiFi discovery
# a random id kept on the main (not /etc/machine-id: that is on the rootfs, which updates replace)
nid=$(ssh "$MAIN" 'f=/home/root/dualrm/node.id; [ -s $f ] || cat /proc/sys/kernel/random/uuid | tr -d - > $f; cat $f')
[ ${#nid} = 32 ] || { echo "could not read or create /home/root/dualrm/node.id on the main" >&2; exit 1; }
ssh "$SUB" "echo '$nid' > /home/root/dualrm/main.id"

# ---------------------------------------------------------------- start the sub
ssh "$SUB" 'systemctl restart dualrm-xovi && systemctl restart dualrm-usbrole dualrm-sync'

echo "waiting for the link..."
i=0
while [ $i -lt 20 ]; do
    if ssh "$SUB" "tail -n +$((logn + 1)) /home/root/dualrm/sync.log 2>/dev/null | grep -q 'link up'"; then
        echo "done: the tablets are linked. Open a document on either one."
        exit 0
    fi
    sleep 2; i=$((i + 1))
done
echo "installed, but no link yet. Check the sub's log:"
echo "  ssh $SUB tail -n 20 /home/root/dualrm/sync.log"
echo "(both on the same WiFi: the sub finds the main by itself; public WiFi often blocks this, see README)"
