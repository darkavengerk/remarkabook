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

log() { echo "$(date +%H:%M:%S) $*" >&2; }   # stderr: stdout carries replies / captured results

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

power_key() { # press the power button, as a finger would (puts the tablet to sleep, or wakes it
               # if it is still showing the sleep screen): input events written to the key's device
    _d=""
    for _e in /sys/class/input/event*; do
        case "$(cat "$_e/device/name" 2>/dev/null)" in *powerkey*) _d=/dev/input/${_e##*/} ;; esac
    done
    [ -n "$_d" ] || return 1
    # struct input_event on armv7: 8 bytes time (ignored), type, code, value; then EV_SYN
    printf '\0\0\0\0\0\0\0\0\001\0\164\0\001\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0' > "$_d"   # KEY_POWER down
    usleep 150000
    printf '\0\0\0\0\0\0\0\0\001\0\164\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0' > "$_d"     # KEY_POWER up
}

reader_alive() { # is someone reading $D/events? (a killed reader leaves the file behind)
    _p=$(cat "$D/events.reader" 2>/dev/null) || return 1
    [ -n "$_p" ] && kill -0 ${_p%% *} 2>/dev/null
}

# ---------------------------------------------------------------- copying documents
# A PDF/EPUB missing on the other tablet is imported there with xochitl's own importer
# (patch command "import"): no restart, but the copy gets a new document id.
snap_docs() { ls "$XD" | grep -E '\.(pdf|epub)$' > "$D/inbox.before"; }

new_doc() { # -> id of a document imported since snap_docs, or nothing
    ls "$XD" | grep -E '\.(pdf|epub)$' | grep -vxF -f "$D/inbox.before" | while read -r _f; do
        _u=${_f%.*}
        [ -f "$XD/$_u.metadata" ] && [ -f "$XD/$_u.content" ] && { echo "$_u"; break; }
    done
}

# ---------------------------------------------------------------- annotations
# Pen strokes live in <doc>/<page id>.rm, highlights in <doc>.highlights/<page id>.json,
# page previews in <doc>.thumbnails/<page id>.png. Both copies of a PDF know which PDF page
# each page id shows (.content), so annotations can be matched page by page.
page_map() { # doc -> "<page id> <pdf page|->" per page (.content format 1 or 2)
    awk '
        /"cPages"/ { v2 = 1 }
        v2 && /"id": "/ {
            if (id != "") print id, (del ? "x" : r)
            id = $0; sub(/.*"id": "/, "", id); sub(/".*/, "", id); r = "-"; del = 0; inr = 0; indel = 0
        }
        v2 && /"redir"/ { inr = 1 }
        v2 && /"deleted"/ { indel = 1 }
        v2 && /"value"/ && (inr || indel) {
            n = $0; sub(/.*"value": /, "", n); sub(/[^0-9-].*/, "", n)
            if (inr) r = n; else del = (n != "0")
            inr = 0; indel = 0
        }
        !v2 && /^    "pages": \[/ { inp = 1; next }
        !v2 && /^    "redirectionPageMap": \[/ { inm = 1; next }
        (inp || inm) && /\]/ { inp = 0; inm = 0; next }
        inp { s = $0; gsub(/[ ",]/, "", s); if (s != "") P[np++] = s }
        inm { s = $0; gsub(/[ ,]/, "", s); if (s != "") M[nm++] = s }
        END {
            if (v2) { if (id != "") print id, (del ? "x" : r) }
            else for (i = 0; i < np; i++) print P[i], (i < nm && M[i] >= 0 ? M[i] : "-")
        }' "$XD/$1.content"
}

ann_list() { # doc -> "P <page id> <pdf page>" per page, then "F <rm|hl> <page id> <mtime> <md5>"
    page_map "$1" | sed 's/^/P /'
    for _f in "$XD/$1"/*.rm "$XD/$1.highlights"/*.json; do
        [ -f "$_f" ] || continue
        _n=${_f##*/}; _k=rm; case "$_n" in *.json) _k=hl ;; esac
        _m=$(md5sum "$_f"); echo "F $_k ${_n%.*} $(stat -c %Y "$_f") ${_m%% *}"
    done
}

ann_place() { # staging dir laid out like $XD -> move its files into $XD, keeping a backup of
              # any annotation file that gets replaced (in $D/backup/<time>/)
    _b=$D/backup/$(date +%Y%m%d-%H%M%S)
    ( cd "$1" && find . -type f ) | while read -r _f; do
        _f=${_f#./}
        case "$_f" in
            *.rm|*.json) [ -f "$XD/$_f" ] && mkdir -p "$_b/${_f%/*}" && cp -p "$XD/$_f" "$_b/$_f" ;;
        esac
        mkdir -p "$XD/${_f%/*}"
        mv -f "$1/$_f" "$XD/$_f"
    done
    rm -rf "$1"
    # backups older than 30 days go
    [ -d "$D/backup" ] && find "$D/backup" -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} \;
    :
}
