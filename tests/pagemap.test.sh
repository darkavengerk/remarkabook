#!/bin/sh
# Test for sub/dualrm-pagemap.sh (pure functions, no tablets).
#   sh tests/pagemap.test.sh            on the PC (and on a tablet's busybox, from /tmp)
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAIL=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; FAIL=1; fi; }
lines() { tr '\n' ';' | sed 's/;$//'; }      # several output lines on one line for check

. ./sub/dualrm-pagemap.sh

MAP=$T/map
mkmap() { echo "doc S M" > "$MAP"; for p in "$@"; do echo "$p" | tr : ' ' >> "$MAP"; done; }

# ---- pm_plan
mkmap s1:m1 s2:m2
check "plan: in step, nothing" "$(pm_plan s1,s2 m1,m2 "$MAP" main | lines)" ""
check "plan: page added at the end on main" "$(pm_plan s1,s2 m1,m2,m3 "$MAP" main | lines)" "add sub 2 m3"
check "plan: page added in the middle on main" "$(pm_plan s1,s2 m1,m3,m2 "$MAP" main | lines)" "add sub 1 m3"
check "plan: page added at the front on sub" "$(pm_plan s3,s1,s2 m1,m2 "$MAP" sub | lines)" "add main 0 s3"
check "plan: page deleted on main" "$(pm_plan s1,s2 m2 "$MAP" main | lines)" "del sub 0"
check "plan: page deleted on sub (main leads)" "$(pm_plan s2 m1,m2 "$MAP" main | lines)" "del main 0"
mkmap s1:m1 s2:m2 s3:m3
check "plan: new on both while apart (main leads)" \
    "$(pm_plan s1,s4,s2,s3 m1,m2,m5,m3 "$MAP" main | lines)" "add main 1 s4;add sub 3 m5"
check "plan: new on follower after a deleted page" \
    "$(pm_plan s1,s2,s4,s3 m1,m3 "$MAP" main | lines)" "del sub 1;add main 1 s4"
check "plan: page deleted on sub, sub leads" "$(pm_plan s1,s3 m1,m2,m3 "$MAP" sub | lines)" "del main 1"
check "plan: moved only, nothing to add" "$(pm_plan s1,s2,s3 m3,m1,m2 "$MAP" main | lines)" ""
check "plan: unmapped follower page first" "$(pm_plan s9,s1,s2,s3 m1,m2,m3 "$MAP" main | lines)" "add main 0 s9"

mkmap s1:m1 s2:m2 s3:m3 s4:m4 s5:m5
check "plan: deletes on both sides, descending" \
    "$(pm_plan s1,s2,s4,s5 m1,m3,m5 "$MAP" main | lines)" "del sub 2,1;del main 1"
pm_plan "" m1 "$MAP" main >/dev/null; check "plan: empty sub list fails" "$?" 1
pm_plan s1 "" "$MAP" main >/dev/null; check "plan: empty main list fails" "$?" 1
check "plan: empty list prints nothing" "$(pm_plan "" m1 "$MAP" main 2>&1)" ""

# ---- pm_merge (left = main)
check "merge: 2 + 2" "$(pm_merge s1,s2 m1,m2 main | lines)" \
    "add main 1 s1;add main 3 s2;add sub 0 m1;add sub 2 m2"
check "merge: main longer" "$(pm_merge s1 m1,m2 main | lines)" \
    "add main 1 s1;add main 3 =3;add sub 0 m1;add sub 2 m2;add sub 3 =3"
check "merge: sub longer" "$(pm_merge s1,s2 m1 main | lines)" \
    "add main 1 s1;add main 2 =2;add main 3 s2;add sub 0 m1;add sub 2 =2"
check "merge: sub has no pages" "$(pm_merge "" m1 main | lines)" \
    "add main 1 =1;add sub 0 m1;add sub 1 =1"
check "merge: main has no pages" "$(pm_merge s1 "" main | lines)" \
    "add main 0 =0;add main 1 s1;add sub 0 =0"
check "merge: left = sub" "$(pm_merge s1 m1 sub | lines)" "add main 0 s1;add sub 1 m1"

# ---- pm_perm / pm_translate
check "perm: same lists" "$(pm_perm a,b,c a,b,c)" ""
check "perm: moved" "$(pm_perm a,b,c c,a,b)" "2,0,1"
pm_perm a,b a,c >/dev/null; check "perm: different sets fail" "$?" 1
pm_perm a,a,b a,b,b >/dev/null; check "perm: repeated id fails" "$?" 1
pm_perm a,b,c a,a,b >/dev/null; check "perm: repeated id in target fails" "$?" 1
mkmap s1:m1 s2:m2
check "translate: main -> sub" "$(pm_translate m2,m1 "$MAP" sub)" "s2,s1"
check "translate: sub -> main" "$(pm_translate s1,s2 "$MAP" main)" "m1,m2"
pm_translate m1,m9 "$MAP" sub >/dev/null; check "translate: unmapped fails" "$?" 1

# ---- pm_spread_add (pages 0..3 = spreads [a,b] [c,d])
check "spread add: after a (left page)" "$(pm_spread_add a,b,c,d a,n,b,c,d | lines)" "order a,b,n,c,d;pad 3"
check "spread add: after b (right page)" "$(pm_spread_add a,b,c,d a,b,n,c,d | lines)" "pad 3"
check "spread add: at the end" "$(pm_spread_add a,b,c,d a,b,c,d,n | lines)" "pad 5"
check "spread add: before the first page" "$(pm_spread_add a,b,c,d n,a,b,c,d | lines)" "pad 1"
check "spread add: two pages after c" "$(pm_spread_add a,b,c,d a,b,c,n,o,d | lines)" "order a,b,c,d,n,o"
check "spread add: odd block of 3 after b" "$(pm_spread_add a,b,c,d a,b,n,o,p,c,d | lines)" "pad 5"
check "spread add: scattered pages gathered" "$(pm_spread_add a,b,c,d a,n,b,c,o,d | lines)" "order a,b,n,o,c,d"
check "spread add: pages deleted too" "$(pm_spread_add a,b,c,d a,n,c,d | lines)" ""
check "spread add: reordered too" "$(pm_spread_add a,b,c,d b,a,n,c,d | lines)" ""
check "spread add: nothing added" "$(pm_spread_add a,b,c,d a,b,c,d | lines)" ""

# ---- pm_spread_del
check "spread del: partner blank goes too" "$(pm_spread_del a,b,c,d a,c,d a | lines)" "del 0"
check "spread del: partner with strokes stays" "$(pm_spread_del a,b,c,d a,c,d "" | lines)" "add 1"
check "spread del: left page deleted, right kept" "$(pm_spread_del a,b,c,d b,c,d "" | lines)" "add 0"
check "spread del: left page deleted, right blank goes too" "$(pm_spread_del a,b,c,d b,c,d b | lines)" "del 0"
check "spread del: whole spread deleted" "$(pm_spread_del a,b,c,d c,d "" | lines)" ""
check "spread del: reordered too" "$(pm_spread_del a,b,c,d c,d,a "" | lines)" ""
check "spread del: nothing deleted" "$(pm_spread_del a,b,c,d a,b,c,d "" | lines)" ""
check "spread del: pages added too" "$(pm_spread_del a,b,c,d a,c,d,n "" | lines)" ""

# ---- pm_differ
mkmap s1aaaaaa:m1aaaaaa s2aaaaaa:m2aaaaaa
printf 'P s1aaaaaa-x - \nF rm s1aaaaaa-x 100 aaa\nF rm s2aaaaaa-x 100 bbb\n' > "$T/s"
printf 'P m1aaaaaa-x - \nF rm m1aaaaaa-x 100 aaa\nF rm m2aaaaaa-x 100 ccc\n' > "$T/m"
check "differ" "$(pm_differ "$T/s" "$T/m" "$MAP" s1aaaaaa,s2aaaaaa)" "s2aaaaaa"

printf 'P s1aaaaaa-x - \nF rm s1aaaaaa-x 100 aaa\n' > "$T/s"
printf 'P m1aaaaaa-x - \nP m2aaaaaa-x - \nF rm m2aaaaaa-x 100 ccc\n' > "$T/m"
check "differ: .rm on one side only" "$(pm_differ "$T/s" "$T/m" "$MAP" s1aaaaaa,s2aaaaaa | lines)" "s1aaaaaa;s2aaaaaa"

# a .rm under 512 bytes (6th field) holds no strokes: the same as no file
printf 'P s1aaaaaa-x - \nP s2aaaaaa-x - \nF rm s1aaaaaa-x 100 aaa 409\nF rm s2aaaaaa-x 100 bbb 409\n' > "$T/s"
printf 'P m1aaaaaa-x - \nP m2aaaaaa-x - \nF rm m2aaaaaa-x 100 ccc 424\n' > "$T/m"
check "differ: blank vs none, blank vs blank: same" "$(pm_differ "$T/s" "$T/m" "$MAP" s1aaaaaa,s2aaaaaa)" ""
printf 'P m1aaaaaa-x - \nP m2aaaaaa-x - \nF rm m1aaaaaa-x 100 ccc 4000\nF rm m2aaaaaa-x 100 ccc 424\n' > "$T/m"
check "differ: blank vs strokes" "$(pm_differ "$T/s" "$T/m" "$MAP" s1aaaaaa,s2aaaaaa)" "s1aaaaaa"

# ---- pm_sides
check "sides: moved to the front" "$(pm_sides a,b,c,d c,a,b,d)" "a,b"
check "sides: spread moved" "$(pm_sides a,b,c,d c,d,a,b)" ""
check "sides: nothing prints no line" "$(pm_sides a,b,c,d c,d,a,b | wc -l | tr -d ' ')" "0"

# ---- first map of a pair: by id (same notebook on both), by position
check "idmap: ids in both" "$(pm_idmap a,b,c,d a,c,e | lines)" "a a;c c"
check "idmap: nothing in common" "$(pm_idmap a,b c,d | lines)" ""
check "posmap: same count" "$(pm_posmap s1,s2 m1,m2 | lines)" "s1 m1;s2 m2"
check "posmap: as far as both go" "$(pm_posmap s1,s2,s3 m1 | lines)" "s1 m1"

# ---- a half last spread
pm_spread_short 3 1; check "short: 3 pages, spread 1 (page 2 alone)" "$?" 0
pm_spread_short 1 0; check "short: 1 page, spread 0" "$?" 0
pm_spread_short 3 0; check "not short: spread 0 of 3 pages" "$?" 1
pm_spread_short 4 1; check "not short: even count" "$?" 1

# ---- delete guard
pm_del_ok 0 4 0; check "del ok: nothing" "$?" 0
pm_del_ok 6 12 0; check "del ok: 6 of 12" "$?" 0
pm_del_ok 10 12 0; check "del ok: 10 of 12 (not more than 10)" "$?" 0
pm_del_ok 11 30 0; check "del ok: 11 of 30 (not more than half)" "$?" 0
pm_del_ok 11 20 0; check "del refused: 11 of 20" "$?" 1
pm_del_ok 1 2 0; check "del ok: 1 of 2 leaves 1 (padded after)" "$?" 0
pm_del_ok 2 2 0; check "del refused: 2 of 2 leaves none" "$?" 1
pm_del_ok 2 2 1; check "del ok: 2 of 2, a blank page added" "$?" 0

[ $FAIL = 0 ] && echo PASS || { echo FAILED; exit 1; }
