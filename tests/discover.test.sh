#!/bin/sh
# Test for sub/dualrm-discover.sh, no network needed (ssh, ping6, ip are stubbed).
#   sh tests/discover.test.sh            on the PC
#   (on the sub's busybox: see the plan, Task 1 Step 5)
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
D=$T; KEY=$T/key
FAIL=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; FAIL=1; fi; }

. ./sub/dualrm-discover.sh

MAINID=0123456789abcdef0123456789abcdef
OWN=fe80::1
ip() { [ -n "$OWN" ] && echo "    inet6 $OWN/64 scope link "; }
RESP="fe80::1 fe80::aa fe80::bb"
PINGS=0
ping6() {
    PINGS=$((PINGS + 1)); echo "$PINGS" > "$T/pings"
    for a in $RESP; do echo "64 bytes from $a: seq=0 ttl=64 time=1.000 ms (DUP!)"; done
}
# fe80::aa refuses the key, fe80::bb is the main, fe80::cc never answers
ssh() {
    shift 3; h=${1#root@}; h=${h%\%*}; echo "$h" >> "$T/ssh.log"
    case "$h" in
        fe80::bb) echo "$MAINID" ;;
        fe80::cc) sleep 5 ;;
        *) return 1 ;;
    esac
}
T_NOW=100; disc_now() { DISC_T=$T_NOW; }
tries() { cat "$T/ssh.log" 2>/dev/null | wc -l | tr -d ' '; }

# 1. no main.id: first host that accepts the key is the main
discover_main; r=$?
check "found (no main.id)" "$r $DISC_FOUND" "0 fe80::bb%wlan0"
check "main.id saved" "$(cat "$T/main.id")" "$MAINID"
check "own address never tried" "$(grep -c '^fe80::1$' "$T/ssh.log")" 0
check "refusing host marked bad" "$DISC_BAD" " fe80::aa"
check "back-off reset on hit" "$DISC_WAIT $DISC_NEXT" "0 0"

# 2. main.id set to another tablet: bb is not accepted
echo ffffffffffffffffffffffffffffffff > "$T/main.id"
DISC_BAD=""; : > "$T/ssh.log"
discover_main; r=$?
check "wrong id not accepted" "$r '$DISC_FOUND'" "1 ''"
check "wrong id marked bad" "$DISC_BAD" " fe80::aa fe80::bb"
check "first back-off 5 s" "$DISC_WAIT $DISC_NEXT" "5 105"

# 3. back-off: nothing tried before DISC_NEXT, then 10, 20, 30, 30
: > "$T/ssh.log"; echo 0 > "$T/pings"; PINGS=0
T_NOW=104; discover_main
check "skipped before DISC_NEXT" "$(cat "$T/pings")" 0
T_NOW=105; discover_main
check "second back-off 10 s" "$DISC_WAIT $DISC_NEXT" "10 115"
check "bad hosts not tried again" "$(tries)" 0
T_NOW=115; discover_main; check "third back-off 20 s" "$DISC_WAIT" 20
T_NOW=135; discover_main; check "back-off capped 30 s" "$DISC_WAIT" 30
T_NOW=165; discover_main; check "back-off stays 30 s" "$DISC_WAIT" 30

# 4. silent host is not marked bad
DISC_BAD=""; DISC_NEXT=0; DISC_WAIT=0; RESP="fe80::cc"; DISC_TIMEOUT=1
discover_main
check "silent host not marked bad" "'$DISC_BAD'" "''"

# 5. no link-local address on wlan0 (WiFi off): no ping
OWN=""; DISC_NEXT=0; echo 0 > "$T/pings"; PINGS=0
discover_main; r=$?
check "wifi off: returns 1" "$r" 1
check "wifi off: no ping" "$(cat "$T/pings")" 0

[ $FAIL = 0 ] && echo PASS || { echo FAILED; exit 1; }
