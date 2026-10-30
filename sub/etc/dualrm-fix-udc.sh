#!/bin/sh
# dual-rM: make sure the USB-C gadget (PC file transfer / SSH over USB) is bound to the
# USB-C controller (30b20000.usb). The stock /usr/sbin/usb-ether-once hardcodes
# ci_hdrc.0 on i.MX7D, but once the pogo controller (30b10000.usb) is enabled it can
# take ci_hdrc.0. Runs as ExecStartPost of usb-ether-once.service; a no-op when the
# stock binding is already right.
G=/sys/kernel/config/usb_gadget/g_ether
d=""
i=0
while [ $i -lt 50 ]; do
    d=$(ls -d /sys/devices/soc0/soc/30800000.aips-bus/30b20000.usb/ci_hdrc.* 2>/dev/null | head -n 1)
    [ -n "$d" ] && break
    sleep 0.2
    i=$((i + 1))
done
[ -n "$d" ] || { echo "dualrm-fix-udc: USB-C controller not found"; exit 0; }
want=${d##*/}
cur=$(cat "$G/UDC" 2>/dev/null)
if [ "$cur" != "$want" ]; then
    [ -n "$cur" ] && echo "" > "$G/UDC" 2>/dev/null
    echo "$want" > "$G/UDC" && echo "dualrm-fix-udc: gadget bound to $want (was '$cur')"
else
    echo "dualrm-fix-udc: gadget already on $want"
fi
exit 0
