#!/bin/sh
# Test for node/dualrm-link.sh on the PC: paths rewritten into a temp dir.
#   sh tests/link.test.sh
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d); trap 'kill $LP 2>/dev/null; rm -rf "$T"' EXIT
sed "s#/home/root/dualrm#$T#g" node/dualrm-lib.sh > "$T/dualrm-lib.sh"
sed "s#/home/root/dualrm#$T#g" node/dualrm-link.sh > "$T/link.sh"
FAIL=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; FAIL=1; fi; }
alive() { kill -0 "$LP" 2>/dev/null && echo yes || echo no; }

mkfifo "$T/in"; exec 5<> "$T/in"
LINK_IDLE=2 sh "$T/link.sh" <&5 > "$T/out" 2>/dev/null &
LP=$!
sleep 1
check "says HELLO" "$(head -n 1 "$T/out")" HELLO

echo "CMD n1 status" >&5; sleep 1
check "CMD forwarded" "$(cat "$T/cmd")" "n1 status"

echo PING >&5; sleep 1; echo PING >&5; sleep 1
check "PING keeps it alive" "$(alive)" yes
check "PING not forwarded" "$(cat "$T/cmd")" "n1 status"

sleep 3
check "exits after LINK_IDLE" "$(alive)" no
check "posts link - on exit" "$(cat "$T/cmd")" "L$LP link -"

[ $FAIL = 0 ] && echo PASS || { echo FAILED; exit 1; }
