#!/bin/sh
# dual-rM link end on the MAIN tablet, started by the sub over ssh:
#   ssh main sh /home/root/dualrm/dualrm-link.sh
# stdout: this tablet's events ("EV DOC/PAGE/RESP ..."), "HELLO" once, "HB" every 30 s
# stdin:  "CMD <nonce> <command...>" from the sub
#         find <parent|-> <type> <name...>, has <uuid>, fsize <file>, snap_docs, new_doc and power_key
#         are answered here from the files; everything else goes to xochitl.
. /home/root/dualrm/dualrm-lib.sh
mkfifos

# one link at a time: a link left over from a vanished sub would split the event stream
old=$(cat "$D/events.reader" 2>/dev/null)
[ -n "$old" ] && kill -9 $old 2>/dev/null

( while sleep 30; do echo HB; done ) &
hb=$!
( exec 3<> "$D/events"; while IFS= read -r l <&3; do printf '%s\n' "$l"; done ) &
fwd=$!
echo "$$ $hb $fwd" > "$D/events.reader"
cleanup() {
    kill $hb $fwd 2>/dev/null
    [ "$(cat "$D/events.reader" 2>/dev/null)" = "$$ $hb $fwd" ] && rm -f "$D/events.reader"
}
trap cleanup EXIT
trap 'exit 0' TERM HUP

echo HELLO
while IFS= read -r l; do
    case "$l" in
        CMD\ *)
            l=${l#CMD }; nonce=${l%% *}; c=${l#* }
            case "$c" in
                find\ *)
                    set -f; set -- $c; set +f
                    p=$2; [ "$p" = - ] && p=""
                    t=$3; name=${c#find * * }
                    echo "EV RESP $nonce ok $(find_child "$p" "$t" "$name")" ;;
                has\ *)
                    if live "${c#has }"; then echo "EV RESP $nonce ok yes"; else echo "EV RESP $nonce ok no"; fi ;;
                fsize\ *)
                    echo "EV RESP $nonce ok $(stat -c %s "$XD/${c#fsize }" 2>/dev/null)" ;;
                snap_docs)
                    snap_docs; echo "EV RESP $nonce ok" ;;
                new_doc)
                    echo "EV RESP $nonce ok $(new_doc)" ;;
                power_key)
                    power_key; echo "EV RESP $nonce ok" ;;
                *)
                    local_post "$nonce $c" ;;
            esac ;;
    esac
done
