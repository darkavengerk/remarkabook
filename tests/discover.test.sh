#!/bin/sh
# Test for sub/dualrm-discover.sh, no network needed (ssh, ping6, ip are stubbed).
#   sh tests/discover.test.sh            on the PC
# On a tablet's busybox, from /tmp only:
#   tar cf - sub/dualrm-discover.sh tests node/dualrm-lib.sh node/dualrm-link.sh | ssh root@<tablet> \
#     'rm -rf /tmp/dt && mkdir /tmp/dt && cd /tmp/dt && tar xf - && sh tests/discover.test.sh; rm -rf /tmp/dt'
# No EXIT trap: busybox ash can run it in a forked child that is killed early ($T would go).
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d)
D=$T; KEY=$T/key
FAIL=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; FAIL=1; fi; }

. ./sub/dualrm-discover.sh

command -v usleep >/dev/null 2>&1 || usleep() { sleep 0.2; }
log() { echo "$*" >> "$T/log"; }; : > "$T/log"
MAINID=0123456789abcdef0123456789abcdef
OWN=fe80::1
ip() { [ -n "$OWN" ] && echo "    inet6 $OWN/64 scope link "; }
RESP="fe80::1 fe80::aa fe80::bb"
PINGS=0
ping6() {
    PINGS=$((PINGS + 1)); echo "$PINGS" > "$T/pings"
    for a in $RESP; do echo "64 bytes from $a: seq=0 ttl=64 time=1.000 ms (DUP!)"; done
}
# fe80::aa refuses the key, fe80::bb is the main, fe80::dd is another tablet,
# fe80::cc never answers, fe80::ee asks for a password
ssh() {
    for a; do case "$a" in root@*) h=${a#root@}; h=${h%\%*} ;; esac; done
    echo "$h" >> "$T/ssh.log"
    case "$h" in
        fe80::bb) echo "$MAINID" ;;
        fe80::dd) echo ffffffffffffffffffffffffffffffff ;;
        fe80::cc) exec sleep 5 ;;
        fe80::ee) printf "root@%s's password: " "$h" >&2; exec sleep 5 ;;
        *) return 1 ;;
    esac
}
T_NOW=100; disc_now() { DISC_T=$T_NOW; }
tries() { cat "$T/ssh.log" 2>/dev/null | wc -l | tr -d ' '; }
cs() { read -r u _ < /proc/uptime; echo "${u%.*}${u#*.}"; }   # uptime in 1/100 s
reset() { DISC_BAD=""; DISC_BAD_T=0; DISC_NEXT=0; DISC_WAIT=0; : > "$T/ssh.log"; echo 0 > "$T/pings"; PINGS=0; }

# 1. no main.id: discovery off, logged once
reset
discover_main; r1=$?; discover_main; r2=$?
check "no main.id: returns 1" "$r1 $r2" "1 1"
check "no main.id: no ping" "$(cat "$T/pings")" 0
check "no main.id: logged once" "$(grep -c 'discovery off: no main.id' "$T/log")" 1

# 2. main.id set: the host whose node.id matches is the main
echo "$MAINID" > "$T/main.id"
reset
discover_main; r=$?
check "found" "$r $DISC_FOUND" "0 fe80::bb%wlan0"
check "own address never tried" "$(grep -c '^fe80::1$' "$T/ssh.log")" 0
check "refusing host marked bad" "$DISC_BAD" " fe80::aa"
check "back-off reset on hit" "$DISC_WAIT $DISC_NEXT" "0 0"

# 3. another tablet: marked bad and logged
reset; : > "$T/log"; RESP="fe80::dd"
discover_main; r=$?
check "wrong id not accepted" "$r '$DISC_FOUND'" "1 ''"
check "wrong id marked bad" "$DISC_BAD" " fe80::dd"
check "wrong id logged" "$(cat "$T/log")" "discovery: fe80::dd answered another id"
check "first back-off 5 s" "$DISC_WAIT $DISC_NEXT" "5 105"

# 4. password prompt: marked bad at once, not logged
reset; : > "$T/log"; RESP="fe80::ee"
t0=$(cs); discover_main; t1=$(cs)
check "password host marked bad" "$DISC_BAD" " fe80::ee"
check "password host given up within 1.5 s" "$([ $((t1 - t0)) -lt 150 ] && echo yes || echo "no ($((t1 - t0))/100 s)")" yes
check "password host not logged" "$(cat "$T/log")" ""

# 5. silent host: marked bad after DISC_TIMEOUT
reset; RESP="fe80::cc"; DISC_TIMEOUT=1
t0=$(cs); discover_main; t1=$(cs)
check "silent host marked bad" "$DISC_BAD" " fe80::cc"
check "silent host given up after ~1 s" \
    "$([ $((t1 - t0)) -ge 80 ] && [ $((t1 - t0)) -lt 250 ] && echo yes || echo "no ($((t1 - t0))/100 s)")" yes
DISC_TIMEOUT=8

# 6. the bad list is forgotten DISC_FORGET s after its first entry
reset; RESP="fe80::aa"; T_NOW=1000; DISC_FORGET=180
discover_main
check "bad list started" "$DISC_BAD $DISC_BAD_T" " fe80::aa 1000"
T_NOW=1179; DISC_NEXT=0; : > "$T/ssh.log"; discover_main
check "bad host skipped before DISC_FORGET" "$(tries)" 0
T_NOW=1180; DISC_NEXT=0; : > "$T/ssh.log"; discover_main
check "bad host tried again after DISC_FORGET" "$(tries)" 1
check "bad list restarted" "$DISC_BAD $DISC_BAD_T" " fe80::aa 1180"

# 7. back-off: nothing tried before DISC_NEXT, then 5, 10, 20, 30, 30
reset; RESP="fe80::1 fe80::aa"; T_NOW=100
discover_main; check "first back-off 5 s" "$DISC_WAIT $DISC_NEXT" "5 105"
: > "$T/ssh.log"; echo 0 > "$T/pings"
T_NOW=104; discover_main
check "skipped before DISC_NEXT" "$(cat "$T/pings")" 0
T_NOW=105; discover_main
check "second back-off 10 s" "$DISC_WAIT $DISC_NEXT" "10 115"
check "bad hosts not tried again" "$(tries)" 0
T_NOW=115; discover_main; check "third back-off 20 s" "$DISC_WAIT" 20
T_NOW=135; discover_main; check "back-off capped 30 s" "$DISC_WAIT" 30
T_NOW=165; discover_main; check "back-off stays 30 s" "$DISC_WAIT" 30

# 8. no link-local address on wlan0 (WiFi off): no ping
reset; OWN=""
discover_main; r=$?
check "wifi off: returns 1" "$r" 1
check "wifi off: no ping" "$(cat "$T/pings")" 0

rm -rf "$T"
[ $FAIL = 0 ] && echo PASS || { echo FAILED; exit 1; }
