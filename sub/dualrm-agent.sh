#!/bin/sh
# dual-rM main-side agent. Runs ON THE MAIN tablet, fed over one ssh session
# by the sub's dualrm-sync.sh ("ssh main 'sh -s' < dualrm-agent.sh").
# Nothing is installed on the main tablet.
#
# Polls (no journal: journald rotation silently breaks `journalctl -f` here):
#   xochitl.conf LastOpen           -> which document is open ("" = none)
#   <doc>.metadata lastOpenedPage   -> current page
#   <doc>.content  pageCount        -> page count
# One grep per tick. Emits one event per line:
#   OPEN <uuid> <fileType> <folder1>\037<folder2>\037...<docName>
#   STATE <uuid> <pageCount> <currentPage>
#   CLOSE <uuid>
#   HB                               (heartbeat; a dead link kills this agent on write)
XD=/home/root/.local/share/remarkable/xochitl
CONF=/home/root/.config/remarkable/xochitl.conf
US=$(printf '\037')
TICK=300000      # usleep between polls
HB_TICKS=30      # heartbeat every ~9s

KEYVAL=""
getkey() { # file key -> KEYVAL (builtins only, for small .metadata files)
    KEYVAL=""
    while IFS= read -r l; do
        case "$l" in
            *"\"$2\": "*) l=${l#*\"$2\": }; l=${l%,}; l=${l#\"}; KEYVAL=${l%\"}; return 0 ;;
        esac
    done < "$1"
    return 1
}

chain() { # uuid -> CHAIN = folder names (root first) + doc name, joined by \037
    CHAIN=""
    [ -f "$XD/$1.metadata" ] || return 1
    getkey "$XD/$1.metadata" visibleName; CHAIN=$KEYVAL
    getkey "$XD/$1.metadata" parent; p=$KEYVAL
    n=0
    while [ -n "$p" ] && [ "$p" != trash ] && [ -f "$XD/$p.metadata" ] && [ $n -lt 32 ]; do
        getkey "$XD/$p.metadata" visibleName; CHAIN="${KEYVAL}${US}${CHAIN}"
        getkey "$XD/$p.metadata" parent; p=$KEYVAL
        n=$((n + 1))
    done
}

prev=""; pc=""; cp=""; ft=""; settle=""; hb=0
while :; do
    if [ -n "$prev" ]; then
        out=$(grep -ho -e '^LastOpen=.*' -e '"lastOpenedPage": [0-9-]*' -e '"pageCount": [0-9]*' -e '"fileType": "[a-z]*"' \
              "$CONF" "$XD/$prev.metadata" "$XD/$prev.content" 2>/dev/null)
    else
        out=$(grep -ho -e '^LastOpen=.*' "$CONF" 2>/dev/null)
    fi
    cur=""; npc=""; ncp=""; nft=""
    oifs=$IFS; IFS='
'
    for l in $out; do
        case "$l" in
            LastOpen=*)
                # 3.23-3.27: LastOpen=<uuid> / LastOpen=   3.29+: LastOpen=@ByteArray(<uuid>) / @ByteArray()
                cur=${l#LastOpen=}; cur=${cur#@ByteArray(}; cur=${cur%)}
                case "$cur" in ????????-????-????-????-????????????) ;; *) cur="" ;; esac ;;
            *lastOpenedPage*) ncp=${l##* } ;;
            *pageCount*) [ -z "$npc" ] && npc=${l##* } ;;
            *fileType*) [ -z "$nft" ] && { nft=${l##* }; nft=${nft#\"}; nft=${nft%\"}; } ;;
        esac
    done
    IFS=$oifs

    if [ "$cur" != "$prev" ]; then
        [ -n "$prev" ] && echo "CLOSE $prev"
        prev=""; pc=""; cp=""; ft=""; settle=""
        if [ -n "$cur" ] && chain "$cur"; then
            ft=$(grep -ho -m1 '"fileType": "[a-z]*"' "$XD/$cur.content" 2>/dev/null); ft=${ft##* }; ft=${ft#\"}; ft=${ft%\"}
            echo "OPEN $cur ${ft:-notebook} $CHAIN"
            prev=$cur
        fi
    elif [ -n "$cur" ] && [ -n "$npc" ] && [ -n "$ncp" ]; then
        if [ "$npc" != "$pc" ] || [ "$ncp" != "$cp" ]; then
            # page count changed: wait one tick so the new current page is written too
            if [ "$npc" != "$pc" ] && [ -n "$pc" ] && [ -z "$settle" ]; then
                settle=1
            else
                settle=""; pc=$npc; cp=$ncp
                echo "STATE $cur $pc $cp"
            fi
        fi
    fi

    hb=$((hb + 1))
    if [ $hb -ge $HB_TICKS ]; then echo HB; hb=0; fi
    usleep $TICK
done
