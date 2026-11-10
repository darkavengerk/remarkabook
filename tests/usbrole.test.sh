#!/bin/sh
# Test for the role decision of node/dualrm-usbrole.sh (no sysfs needed: functions only).
#   sh tests/usbrole.test.sh
cd "$(dirname "$0")/.." || exit 1
FAIL=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; FAIL=1; fi; }

DUALRM_USBROLE_LIB=1; DUALRM_LIB=./node/dualrm-lib.sh
. ./node/dualrm-usbrole.sh

feed() { # readings... -> the role each one settles on ("-": not settled yet)
    _o=""
    for r; do settle "$r"; _o="$_o ${WANT:--}"; done
    echo "${_o# }"
}

SETTLE=5
P_LAST=""; P_N=0
check "powered: device after SETTLE same readings" "$(feed 1 1 1 1 1 1)" "- - - - gadget gadget"
P_LAST=""; P_N=0
check "no power: host after SETTLE same readings" "$(feed 0 0 0 0 0)" "- - - - host"
P_LAST=""; P_N=0
check "flicker never settles" "$(feed 1 0 1 0 1 0 1 0)" "- - - - - - - -"
P_LAST=""; P_N=0; feed 1 1 1 1 1 > /dev/null
settle 1; check "settled: stays device" "$WANT" gadget
check "power lost: not at once" "$(feed 0)" "-"
P_LAST=1; P_N=5
check "power lost: host after SETTLE" "$(feed 0 0 0 0 0)" "- - - - host"
P_LAST=1; P_N=5
check "short drop: no change, then settles again" "$(feed 0 0 1 1 1 1 1)" "- - - - - - gadget"
P_LAST=""; P_N=0
for i in 1 2 3 4 5 6 7 8 9 10; do settle 1; done
check "count capped at SETTLE" "$P_N" 5
SETTLE=1; P_LAST=""; P_N=0
check "SETTLE=1: at once" "$(feed 1 0)" "gadget host"

[ $FAIL = 0 ] && echo PASS || { echo FAILED; exit 1; }
