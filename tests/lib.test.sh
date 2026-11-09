#!/bin/sh
# Test for the file helpers in node/dualrm-lib.sh (no tablet).
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sed "s#/home/root/dualrm#$T/d#g; s#/home/root/.local/share/remarkable/xochitl#$T/x#g" node/dualrm-lib.sh > "$T/lib.sh"
mkdir -p "$T/d" "$T/x/doc1" "$T/x/doc1.thumbnails"
. "$T/lib.sh"
FAIL=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; FAIL=1; fi; }
head -c 409 /dev/zero > "$T/x/doc1/aaaaaaaa-1111.rm"      # saved without strokes
head -c 4000 /dev/zero > "$T/x/doc1/bbbbbbbb-2222.rm"     # strokes
echo x > "$T/x/doc1.content"
check "blank pages" "$(pages_blank doc1 aaaaaaaa,bbbbbbbb,cccccccc | tr '\n' ,)" "aaaaaaaa,cccccccc,"
page_backup doc1 bbbbbbbb
check "backup copied" "$(ls "$T"/d/backup/*/doc1/)" "bbbbbbbb-2222.rm"
notebook_copy doc1 "$T/m"
check "notebook copied" "$(ls "$T/m" | tr '\n' ' ')" "doc1 doc1.content doc1.thumbnails "
check "notebook pages copied" "$(ls "$T/m/doc1" | wc -l | tr -d ' ')" 2
[ $FAIL = 0 ] && echo PASS || { echo FAILED; exit 1; }
