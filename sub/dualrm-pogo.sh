#!/bin/sh
# dual-rM pogo-port helper. Runs ON THE SUB tablet.
#   dualrm-pogo.sh setup       boot-time: keep the pogo USB root hub awake, park the
#                              rm-pogo keyboard state machine (manual_fsm=1) so it does not
#                              toggle VBUS while probing for a Type Folio over the ID pin
#   dualrm-pogo.sh vbus on|off 5V out of the pogo VBUS pin (powers the main) / back to normal
#   dualrm-pogo.sh status
# The pogo controller (30b10000.usb) is only a USB host because of the edited device tree
# (/boot/zero-sugar.dtb, original in /boot/zero-sugar.dtb.orig).
POGO=/sys/devices/soc0/soc/30800000.aips-bus/30b10000.usb
PC=/sys/pogo/control

hub_ctl() { for h in "$POGO"/ci_hdrc.*/usb*/power/control; do [ -e "$h" ] && { echo "$h"; return; }; done; }

case "$1" in
    setup)
        h=$(hub_ctl)
        if [ -z "$h" ]; then echo "pogo USB host not present (device tree not applied?)"; exit 1; fi
        echo on > "$h"
        echo 1 > $PC/manual_fsm
        echo "pogo: root hub $(cat "$h"), manual_fsm $(cat $PC/manual_fsm), vbus mode: $(cat $PC/pogo_chargermode)"
        ;;
    vbus)
        case "$2" in
            on)  echo "OTG Supply" > $PC/pogo_chargermode ;;
            off) echo "Charger" > $PC/pogo_chargermode ;;
            *)   echo "usage: $0 vbus on|off"; exit 2 ;;
        esac
        echo "pogo vbus: $2"
        ;;
    status)
        h=$(hub_ctl)
        echo "controller: $(ls -d "$POGO"/ci_hdrc.* 2>/dev/null) role=$(cat "$POGO"/ci_hdrc.*/role 2>/dev/null)"
        echo "root hub: ${h:-none} $( [ -n "$h" ] && cat "$h")"
        echo "rm-pogo: manual_fsm=$(cat $PC/manual_fsm) fsm_state=$(cat /sys/pogo/status/fsm_state) chargermode-options=[$(cat $PC/pogo_chargermode)]"
        echo "devices on pogo bus:"
        for d in "$POGO"/ci_hdrc.*/usb*/*-*; do
            case "$d" in *:*) continue ;; esac
            [ -e "$d/idVendor" ] && echo "  $(basename "$d") $(cat "$d/idVendor"):$(cat "$d/idProduct") $(cat "$d/product" 2>/dev/null)"
        done
        ;;
    *)
        echo "usage: $0 setup | vbus on|off | status"; exit 2 ;;
esac
