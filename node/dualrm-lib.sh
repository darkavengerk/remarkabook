# dual-rM shared helpers, sourced by the scripts on BOTH tablets.
#
# Local plumbing on each tablet (no polling anywhere):
#   xochitl patch --GET http://127.0.0.1:7781/ev?<msg>--> dualrm-ev.sh  (events + command answers)
#   xochitl patch --GET http://127.0.0.1:7782/next ----> dualrm-cmd.sh (long-poll: held until a command)
#   $D/cmd      the command waiting for xochitl ("<nonce> <command...>"), cleared when answered
#   $D/bell     fifo: a write wakes the waiting dualrm-cmd.sh
#   $D/response last answer from xochitl ("<nonce> ok ..." / "<nonce> error ...")
#   $D/events   fifo: "EV DOC ..." / "EV PAGE ..." / "EV RESP ..." lines for whoever is listening
#               (the sub's dualrm-sync.sh, or dualrm-link.sh on the main); only written while
#               $D/events.reader exists
D=/home/root/dualrm
XD=/home/root/.local/share/remarkable/xochitl
US=$(printf '\037')
CR=$(printf '\r')

log() { echo "$(date +%H:%M:%S) $*"; }

mkfifos() {
    [ -p "$D/bell" ] || { rm -f "$D/bell"; mkfifo "$D/bell"; }
    [ -p "$D/events" ] || { rm -f "$D/events"; mkfifo "$D/events"; }
}

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

live() { # uuid -> 0 if the entry exists here and is not deleted
    [ -f "$XD/$1.metadata" ] || return 1
    getkey "$XD/$1.metadata" deleted; [ "$KEYVAL" != true ] || return 1
    getkey "$XD/$1.metadata" parent; [ "$KEYVAL" != trash ]
}

doc_type() { # uuid -> notebook | pdf | epub
    t=$(grep -ho -m1 '"fileType": "[a-z]*"' "$XD/$1.content" 2>/dev/null); t=${t##* }; t=${t#\"}; t=${t%\"}
    echo "${t:-notebook}"
}

doc_path() { # uuid -> folder names (root first) + document name, joined by \037
    [ -f "$XD/$1.metadata" ] || return 1
    getkey "$XD/$1.metadata" visibleName; c=$KEYVAL
    getkey "$XD/$1.metadata" parent; p=$KEYVAL
    n=0
    while [ -n "$p" ] && [ "$p" != trash ] && [ -f "$XD/$p.metadata" ] && [ $n -lt 32 ]; do
        getkey "$XD/$p.metadata" visibleName; c="${KEYVAL}${US}${c}"
        getkey "$XD/$p.metadata" parent; p=$KEYVAL
        n=$((n + 1))
    done
    echo "$c"
}

find_child() { # parent type name -> uuid of a live entry with that name, or nothing
    cd "$XD" || return
    grep -l -F "\"visibleName\": \"$3\"" *.metadata 2>/dev/null | while read -r f; do
        getkey "$f" type; [ "$KEYVAL" = "$2" ] || continue
        getkey "$f" parent; [ "$KEYVAL" = "$1" ] || continue
        getkey "$f" deleted; [ "$KEYVAL" = true ] && continue
        echo "${f%.metadata}"
        break
    done | head -n 1
}

urldecode() { printf '%b' "$(printf '%s' "$1" | sed 's/+/ /g; s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"; }

drain_headers() { # consume the HTTP request headers (replying with unread input resets the socket)
    while IFS= read -r h; do h=${h%"$CR"}; [ -z "$h" ] && break; done
}

http_reply() { printf 'HTTP/1.0 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n%s' "$1"; }

ring() { # wake the waiting dualrm-cmd.sh; give up after 2 s when nobody waits (xochitl down)
    echo x > "$D/bell" &
    rp=$!
    ( sleep 2; kill $rp 2>/dev/null ) &
}

local_post() { # "<nonce> <command...>" -> hand to xochitl here
    printf '%s\n' "$1" > "$D/cmd.tmp" && mv "$D/cmd.tmp" "$D/cmd"
    ring
}

local_request() { # command... -> prints the "ok" payload of the local xochitl; 1 on error/timeout
    _n="$(cut -d' ' -f1 /proc/uptime | tr -d .)$$"
    : > "$D/response"
    local_post "$_n $*"
    _i=0
    while [ $_i -lt 80 ]; do
        _r=$(cat "$D/response" 2>/dev/null)
        case "$_r" in
            "$_n ok"*) _r=${_r#"$_n ok"}; echo "${_r# }"; return 0 ;;
            "$_n error"*) log "xochitl replied: ${_r#"$_n "}" >&2; return 1 ;;
        esac
        usleep 100000
        _i=$((_i + 1))
        [ $((_i % 10)) = 0 ] && ring   # a stale long-poll may have eaten the bell
    done
    log "no answer for: $*" >&2
    : > "$D/cmd"
    return 1
}
