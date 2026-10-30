#!/bin/sh
# dual-rM USB role switcher. Runs ON THE SUB tablet (systemd: dualrm-usbrole.service).
#
# The sub's USB-C is normally a USB device (gadget): PC file transfer, charging.
# To talk to the main over a cable it must be the USB host. This decides automatically:
#   power in + a host (PC) talks to us within PC_WAIT      -> stay gadget (PC mode)
#   power in + nobody talks to us                           -> try host mode for PROBE_WAIT
#        a USB device (the main) appears                    -> stay host ("linked")
#        nothing appears (plain charger)                    -> HOLD_HOST=1: stay host, charging continues
#                                                              HOLD_HOST=0: back to gadget, re-probe later
#   no power in                                             -> host mode (the main can be reached
#                                                              through a passthrough adapter whose
#                                                              charger powers only the main's side)
#   linked and the device disappears                        -> back to gadget
D=/home/root/dualrm
# USB-C controller. Its ci_hdrc.N number depends on probe order (the pogo controller,
# 30b10000, can take ci_hdrc.0 when it is enabled), so resolve it instead of assuming 0.
USBC=/sys/devices/soc0/soc/30800000.aips-bus/30b20000.usb
CI=$(ls -d $USBC/ci_hdrc.* 2>/dev/null | head -n 1)
ROLE=$CI/role
ONLINE=/sys/class/power_supply/max77818-charger/online
UDC=/sys/class/udc/${CI##*/}/state
PC_WAIT=25              # x100ms: time a PC gets to enumerate us
PROBE_WAIT=40           # x100ms: time the main gets to show up in host mode
REPROBE="10 30 60"      # seconds between re-probes on a plain charger (last value repeats)
HOLD_HOST=1             # 1: on non-PC power stay in host mode (charging verified to continue
                        #    in host mode, 2026-10-30); 0: probe and return to gadget
[ -f "$D/dualrm.conf" ] && . "$D/dualrm.conf"

log() { echo "$(date +%H:%M:%S) usbrole: $*"; }
rd() { V=""; read -r V < "$1" 2>/dev/null; }
now() { read -r up _ < /proc/uptime; NOW=${up%.*}; }
powered() { rd "$ONLINE"; [ "$V" = 1 ]; }
# A PC resets/addresses us. A plain charger leaves the bus idle, which the UDC reports
# as "powered" and later "suspended", so "suspended" alone does not mean a PC.
host_talks() { rd "$UDC"; case "$V" in default|addressed|configured) return 0 ;; esac; return 1; }
# The main shows up as a USB network interface (cdc_ether). Any other USB device
# (hub, card reader, keyboard) must not count as "main attached".
device_present() {
    for n in /sys/class/net/*; do
        [ -e "$n/device/driver" ] || continue
        case "$(readlink "$n/device/driver")" in *cdc_ether*) return 0 ;; esac
    done
    return 1
}
set_role() {
    rd "$ROLE"
    if [ "$V" != "$1" ]; then
        echo "$1" > "$ROLE" && log "role -> $1"
    fi
    [ "$1" = host ] && keep_hub_awake
    return 0
}
# The root hub runtime-suspends at once (autosuspend_delay 0) and on this SoC it does
# not wake up when a device is plugged in later, so keep it powered while we are host.
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
kick_sync() { systemctl restart dualrm-sync.service 2>/dev/null; }

probe() { # 0 = main found (role stays host)
    set_role host
    i=0
    while [ $i -lt $PROBE_WAIT ]; do
        device_present && return 0
        usleep 100000
        i=$((i + 1))
    done
    [ "$HOLD_HOST" = 1 ] && return 1
    set_role gadget
    return 1
}

schedule_reprobe() { # step index -> NEXT (uptime seconds)
    set -- $REPROBE
    k=$1; j=0
    for s in "$@"; do [ $j -le "$STEP" ] && k=$s; j=$((j + 1)); done
    now; NEXT=$((NOW + k))
    STEP=$((STEP + 1))
}

on_charger() { # enter charger state
    STATE=charger; STEP=0
    if [ "$HOLD_HOST" = 1 ]; then set_role host; log "no PC, holding host mode"; else schedule_reprobe; log "no PC, no main: charger"; fi
}

set_role gadget
STATE=idle
log "started"
while :; do
    case "$STATE" in
        idle)
            if ! powered; then
                set_role host
                if device_present; then STATE=linked; log "main attached (unpowered)"; kick_sync; fi
            else
                # a PC can only enumerate us in gadget mode
                set_role gadget
                i=0
                while [ $i -lt $PC_WAIT ] && powered && ! host_talks; do usleep 100000; i=$((i + 1)); done
                if host_talks; then
                    STATE=pc; log "PC attached"
                elif powered; then
                    if probe; then STATE=linked; log "main attached"; kick_sync; else on_charger; fi
                fi
            fi ;;
        pc)
            if ! powered; then STATE=idle; log "unplugged"; fi ;;
        linked)
            # suspend/resume puts the controller back into gadget mode: take host back
            set_role host
            if ! device_present; then
                set_role gadget; log "main detached"; kick_sync
                if powered; then on_charger; else STATE=idle; fi
            fi ;;
        charger)
            if [ "$HOLD_HOST" = 1 ]; then
                powered && set_role host   # re-take host after suspend/resume
                if device_present; then STATE=linked; log "main attached"; kick_sync
                elif ! powered; then set_role gadget; STATE=idle; log "unplugged"
                fi
            elif ! powered; then
                STATE=idle; log "unplugged"
            elif host_talks; then
                STATE=pc; log "PC attached"
            else
                now
                if [ "$NOW" -ge "$NEXT" ]; then
                    if probe; then STATE=linked; log "main attached"; kick_sync; else schedule_reprobe; fi
                fi
            fi ;;
    esac
    sleep 2     # state checks only; transitions above have their own short waits
done
