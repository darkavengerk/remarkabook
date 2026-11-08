#!/bin/sh
# dual-rM USB role switcher. Runs on BOTH tablets (systemd: dualrm-usbrole.service).
#
# The reMarkable 2 never puts 5 V on its USB-C port, so of two cabled tablets only the one that
# gets power (from the passthrough adapter's PD input, see README) can be the USB device. The
# rule, the same on both tablets:
#   power in  -> USB device (gadget): a PC (file transfer, SSH over USB), a charger, or the
#                other tablet as USB host. The powered tablet is charged.
#   no power  -> USB host: the other tablet shows up as a USB network device (cdc_ether,
#                named dualrm0 by 10-dualrm-peer.link)
# A power reading counts once it has been the same for SETTLE samples in a row (about 1 s), so
# a charger negotiating or a wiggled cable does not flip the role. Both tablets powered, or
# neither: both are devices, or both hosts, and there is no USB link (WiFi still works).
#
# Only the sub runs the sync; it re-picks its link when it is restarted here: on a role change,
# when the other tablet shows up or goes (this tablet host), and when a USB host starts talking
# to us (this tablet device: the main as host, or a PC).
D=/home/root/dualrm
# USB-C controller. Its ci_hdrc.N number depends on probe order (the pogo controller,
# 30b10000, can take ci_hdrc.0 when it is enabled), so resolve it instead of assuming 0.
USBC=/sys/devices/soc0/soc/30800000.aips-bus/30b20000.usb
CI=$(ls -d $USBC/ci_hdrc.* 2>/dev/null | head -n 1)
ROLE=$CI/role
ONLINE=/sys/class/power_supply/max77818-charger/online
UDC=/sys/class/udc/${CI##*/}/state
SETTLE=5                # power readings 250 ms apart that must agree (about 1 s)
SUB=0; [ -f /etc/systemd/system/dualrm-sync.service ] && SUB=1   # the sub runs the sync
[ -f "$D/dualrm.conf" ] && . "$D/dualrm.conf"

log() { echo "$(date +%H:%M:%S) usbrole: $*"; }
rd() { V=""; { read -r V < "$1"; } 2>/dev/null; }

settle() { # power reading (1 | 0) -> WANT: gadget (powered) or host (not), "" until the
           # reading has been the same SETTLE times in a row. State: P_LAST, P_N.
    if [ "$1" = "$P_LAST" ]; then
        [ "$P_N" -lt "$SETTLE" ] && P_N=$((P_N + 1))
    else
        P_LAST=$1; P_N=1
    fi
    WANT=""
    [ "$P_N" -ge "$SETTLE" ] || return 0
    if [ "$1" = 1 ]; then WANT=gadget; else WANT=host; fi
}

[ -n "$DUALRM_USBROLE_LIB" ] && return 0   # tests: functions only

set_role() { # role -> CHANGED=1 when the controller was not in it (also after suspend/resume,
             # which puts it back into gadget mode)
    CHANGED=0
    rd "$ROLE"
    if [ "$V" != "$1" ]; then
        echo "$1" > "$ROLE" && { log "role -> $1"; CHANGED=1; }
    fi
    [ "$1" = host ] && keep_hub_awake
    return 0
}
# The root hub runtime-suspends at once (autosuspend_delay 0) and on this SoC it does not wake
# up when a device is plugged in later, so keep it powered while we are host.
keep_hub_awake() { # the USB-C root hub (bus number varies once the pogo host exists)
    k=0; h=""
    while [ $k -lt 40 ]; do
        for h in "$CI"/usb*/power/control; do [ -e "$h" ] && break 2; done
        h=""; usleep 50000; k=$((k + 1))
    done
    [ -n "$h" ] || return 0
    rd "$h"
    [ "$V" = on ] || echo on > "$h" 2>/dev/null
}
# The other tablet shows up as a USB network interface (cdc_ether). Any other USB device
# (hub, card reader, keyboard) must not count.
peer() { # -> PEER: its interface name, "" when there is none
    PEER=""
    for n in /sys/class/net/*; do
        case "$(readlink "$n/device/driver" 2>/dev/null)" in *cdc_ether*) PEER=${n##*/}; return 0 ;; esac
    done
    return 1
}
# The main: NetworkManager leaves the interface alone (conf.d/dualrm.conf), so bring it up
# here, with an IPv6 link-local address only. The sub finds the main on it like on WiFi and
# logs in through dualrm-ssh.socket. (On the sub, systemd-networkd handles it.)
peer_up() { # interface
    echo 0 > "/proc/sys/net/ipv6/conf/$1/disable_ipv6" 2>/dev/null
    ip link set "$1" up
}
kick_sync() { [ $SUB = 1 ] && systemctl restart dualrm-sync.service 2>/dev/null; return 0; }
usb_link() { rd "$D/mainhost"; case "$V" in *%usb*) return 0 ;; esac; return 1; }  # sync linked over our gadget

P_LAST=""; P_N=0; WANT=""
DONE=""         # role last decided
PEER_ON=""      # the other tablet's interface while we are host and it is there
HOST_ON=0       # 1 while a USB host talks to us (we are device)
log "started ($([ $SUB = 1 ] && echo sub || echo main))"
while :; do
    rd "$ONLINE"
    if [ "$V" = 1 ]; then settle 1; else settle 0; fi
    if [ -z "$WANT" ]; then usleep 250000; continue; fi     # reading changed: sample faster
    set_role "$WANT"
    if [ "$WANT" != "$DONE" ]; then
        # a new decision (not the controller falling back after resume): the sync re-picks its
        # link, unless this is our start and the role was right already
        { [ -n "$DONE" ] || [ "$CHANGED" = 1 ]; } && kick_sync
        DONE=$WANT; PEER_ON=""; HOST_ON=0
    fi
    if [ "$WANT" = host ]; then
        peer
        if [ -n "$PEER" ] && [ "$PEER" != "$PEER_ON" ]; then
            PEER_ON=$PEER; log "other tablet attached ($PEER, this tablet is USB host)"
            [ $SUB = 1 ] || peer_up "$PEER"
            kick_sync
        elif [ -z "$PEER" ] && [ -n "$PEER_ON" ]; then
            log "other tablet detached ($PEER_ON)"; PEER_ON=""
            kick_sync
        fi
    else
        # a PC or the other tablet resets and configures us; a plain charger leaves the bus idle
        rd "$UDC"
        if [ "$V" = configured ] && [ $HOST_ON = 0 ]; then
            HOST_ON=1; log "USB host attached (this tablet is USB device)"
            kick_sync
        elif [ "$V" != configured ] && [ $HOST_ON = 1 ]; then
            HOST_ON=0; log "USB host detached"
            usb_link && kick_sync
        fi
    fi
    sleep 2     # settled: state checks only
done
