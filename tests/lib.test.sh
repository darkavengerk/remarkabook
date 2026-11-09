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
page_backup doc1 bbbbbbbb; check "backup: 0 when copied" "$?" 0
chmod 000 "$T/x/doc1/bbbbbbbb-2222.rm"
if [ "$(id -u)" != 0 ]; then
    page_backup doc1 bbbbbbbb 2>/dev/null; check "backup: 1 when a copy fails" "$?" 1
fi
chmod 644 "$T/x/doc1/bbbbbbbb-2222.rm"

# ---- ann_plan: the newer file wins, but a blank .rm (under 512 bytes) never replaces strokes
MAPF=$T/map; printf 'doc S M\nsaaaaaaa maaaaaaa\nsbbbbbbb mbbbbbbb\nsccccccc mccccccc\n' > "$MAPF"
printf 'P saaaaaaa-1 -\nP sbbbbbbb-1 -\nP sccccccc-1 -\nF rm saaaaaaa-1 100 s1 4000\nF rm sbbbbbbb-1 300 s2 409\nF rm sccccccc-1 100 s3 4000\n' > "$T/as"
printf 'P maaaaaaa-1 -\nP mbbbbbbb-1 -\nP mccccccc-1 -\nF rm maaaaaaa-1 200 m1 424\nF rm mbbbbbbb-1 100 m2 4000\nF rm mccccccc-1 200 m3 4000\n' > "$T/am"
check "ann_plan: blank never over strokes, strokes over blank, newer strokes win" \
    "$(ann_plan "$T/as" "$T/am" both 0 "$MAPF" | sort | tr '\n' ';')" \
    "tomain rm saaaaaaa-1 maaaaaaa-1;tosub rm mbbbbbbb-1 sbbbbbbb-1;tosub rm mccccccc-1 sccccccc-1;"
printf 'P maaaaaaa-1 -\nF rm maaaaaaa-1 200 m1 424\n' > "$T/am"
printf 'P saaaaaaa-1 -\nF rm saaaaaaa-1 100 s1 409\n' > "$T/as"
check "ann_plan: blank on both: nothing" "$(ann_plan "$T/as" "$T/am" both 0 "$MAPF")" ""
printf 'P p1 0\nF rm p1 300 s1 409\n' > "$T/as"; printf 'P p1 0\nF rm p1 100 m1 4000\n' > "$T/am"
check "ann_plan: same PDF, blank newer: strokes stay" "$(ann_plan "$T/as" "$T/am" both 1)" "tosub rm p1 p1"
printf 'P p1 0\nF rm p1 300 s1\n' > "$T/as"
check "ann_plan: no size (older lib): an ordinary file" "$(ann_plan "$T/as" "$T/am" both 1)" "tomain rm p1 p1"

# ---- find_child: NotebookType skips a PDF of the same name
mkdir -p "$T/x"
for u in pdf1 nb1; do
    printf '{\n    "deleted": false,\n    "parent": "",\n    "type": "DocumentType",\n    "visibleName": "Same"\n}\n' > "$T/x/$u.metadata"
done
echo '{ "fileType": "pdf" }' > "$T/x/pdf1.content"; echo '{ "fileType": "notebook" }' > "$T/x/nb1.content"
check "find_child: notebook only" "$(find_child "" NotebookType Same)" nb1
check "find_child: any document" "$(find_child "" DocumentType Same | grep -c .)" 1
rm "$T/x/nb1.metadata"
check "find_child: no notebook of that name" "$(find_child "" NotebookType Same)" ""

[ $FAIL = 0 ] && echo PASS || { echo FAILED; exit 1; }
