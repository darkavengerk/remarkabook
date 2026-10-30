#!/bin/sh
# dual-rM sub-side daemon. Runs ON THE SUB tablet (systemd: dualrm-sync.service).
# Finds the main tablet (USB first, then home WiFi), streams its events through
# dualrm-agent.sh (run on the main over one ssh session) and mirrors them here
# via the dualrm QMD patch (request/response files).
#
# Page policy:
#   main is a notebook  -> sub keeps the same page count (blank pages added in one batch)
#   main is a pdf/epub  -> sub grows lazily, only up to the page being viewed
#   sub never deletes pages.
D=/home/root/dualrm
XD=/home/root/.local/share/remarkable/xochitl
KEY=$D/id_dualrm
US=$(printf '\037')
MAIN_USB=10.11.99.1
MAIN_LAN=""
[ -f "$D/dualrm.conf" ] && . "$D/dualrm.conf"

log() { echo "$(date +%H:%M:%S) $*"; }

field() {
    sed -n "s/^[[:space:]]*\"$2\": //p" "$1" | head -n 1 | sed 's/,$//; s/^"//; s/"$//'
}

find_child() { # parent name type -> uuid of a live entry, or nothing
    cd "$XD" || return
    grep -l -F "\"visibleName\": \"$2\"" *.metadata 2>/dev/null | while read -r f; do
        [ "$(field "$f" type)" = "$3" ] || continue
        [ "$(field "$f" parent)" = "$1" ] || continue
        [ "$(field "$f" deleted)" = true ] && continue
        echo "${f%.metadata}"
        break
    done | head -n 1
}

request() { # cmd args... -> prints the "ok" payload; returns 1 on error/timeout
    nonce="$(cut -d' ' -f1 /proc/uptime | tr -d .)$$"
    : > "$D/response"
    printf '%s %s\n' "$nonce" "$*" > "$D/request"
    i=0
    while [ $i -lt 150 ]; do
        r=$(cat "$D/response" 2>/dev/null)
        case "$r" in
            "$nonce ok"*) : > "$D/request"; r=${r#"$nonce ok"}; echo "${r# }"; return 0 ;;
            "$nonce error"*) : > "$D/request"; log "sub replied: ${r#"$nonce "}"; return 1 ;;
        esac
        usleep 100000
        i=$((i + 1))
    done
    log "no answer for: $*"
    return 1
}

MAIN_DOC=""; SUB_DOC=""; MAIN_FT=""; SUB_PC=0; LAST_PC=""; LAST_CP=""

mirror_open() { # uuid fileType path
    u=$1; ft=$2; path=$3
    parent=""; doc=""; last=""
    oifs=$IFS; IFS=$US; set -- $path; IFS=$oifs
    n=$#; i=1
    for part in "$@"; do
        if [ $i -lt $n ]; then
            fid=$(find_child "$parent" "$part" CollectionType)
            if [ -z "$fid" ]; then
                fid=$(request mkdir "${parent:--}" "$part") || return
                log "created folder '$part' -> $fid"
            fi
            parent=$fid
        else
            last=$part
            doc=$(find_child "$parent" "$part" DocumentType)
            if [ -z "$doc" ]; then
                doc=$(request create "${parent:--}" "$part") || return
                log "created notebook '$part' -> $doc"
            fi
        fi
        i=$((i + 1))
    done
    [ -n "$doc" ] || return
    request open "$doc" >/dev/null || return
    MAIN_DOC=$u; SUB_DOC=$doc; MAIN_FT=$ft; LAST_PC=""; LAST_CP=""; SUB_PC=0
    # opening can be deferred (e.g. just after xochitl start): wait until it is really open
    k=0
    while [ $k -lt 50 ]; do
        st=$(request status) && set -- $st && [ "$1" = "$doc" ] && { SUB_PC=$2; break; }
        usleep 200000
        k=$((k + 1))
    done
    [ $k -ge 50 ] && log "warning: '$last' did not open in time"
    log "opened '$last' ($ft on main) -> $doc, sub has $SUB_PC pages"
}

mirror_close() {
    [ "$1" = "$MAIN_DOC" ] && [ -n "$SUB_DOC" ] || return
    request close "$SUB_DOC" >/dev/null && log "closed $SUB_DOC"
    MAIN_DOC=""; SUB_DOC=""; MAIN_FT=""; LAST_PC=""; LAST_CP=""
}

mirror_state() { # uuid pageCount currentPage
    [ "$1" = "$MAIN_DOC" ] && [ -n "$SUB_DOC" ] || return
    pc=$2; cp=$3
    [ "$pc" = "$LAST_PC" ] && [ "$cp" = "$LAST_CP" ] && return
    if [ "$MAIN_FT" = notebook ]; then want=$pc; else want=$((cp + 1)); fi

    if [ "$MAIN_FT" = notebook ] && [ -n "$LAST_PC" ] && [ "$pc" -eq $((LAST_PC + 1)) ] \
       && [ "$SUB_PC" -eq "$LAST_PC" ] && [ "$cp" -ge 1 ] && [ "$cp" -lt "$pc" ]; then
        # one page inserted on main at index cp: insert at the same index on sub
        request addpage "$cp" >/dev/null && SUB_PC=$((SUB_PC + 1)) && log "inserted page at $cp -> $SUB_PC pages"
    else
        total=$(request ensure "$want" "$cp") || return
        [ "$total" -gt "$SUB_PC" ] 2>/dev/null && log "added $((total - SUB_PC)) page(s) -> $total"
        SUB_PC=$total
        log "page -> $cp"
    fi
    LAST_PC=$pc; LAST_CP=$cp
}

ROLE=$(ls -d /sys/devices/soc0/soc/30800000.aips-bus/30b20000.usb/ci_hdrc.*/role 2>/dev/null | head -n 1)

pick_main() {
    # USB only while we are the host (in gadget mode 10.11.99.1 is our own address)
    # A USB link to the main exists when a cdc_ether interface is up: over USB-C (when
    # dualrm-usbrole made us host) or over the pogo pins (always host, edited device tree).
    usb_link=""
    for n in /sys/class/net/*; do
        case "$(readlink "$n/device/driver" 2>/dev/null)" in *cdc_ether*) usb_link=1 ;; esac
    done
    if [ -n "$usb_link" ]; then
        k=0
        while [ $k -lt 10 ]; do   # DHCP from the main can take a few seconds
            if ping -c1 -W1 "$MAIN_USB" >/dev/null 2>&1; then echo "$MAIN_USB"; return; fi
            k=$((k + 1))
        done
    fi
    if [ -n "$MAIN_LAN" ] && ping -c1 -W1 "$MAIN_LAN" >/dev/null 2>&1; then echo "$MAIN_LAN"; return; fi
}

mkdir -p "$D"
while :; do
    MAIN=$(pick_main)
    if [ -z "$MAIN" ]; then sleep 5; continue; fi
    log "connecting to main at $MAIN"
    ssh -y -K 10 -i "$KEY" "root@$MAIN" 'sh -s' < "$D/dualrm-agent.sh" 2>>"$D/ssh.err" | while IFS= read -r line; do
        case "$line" in
            OPEN\ *)
                set -- $line
                u=$2; ft=$3; shift 3
                mirror_open "$u" "$ft" "$*" ;;
            STATE\ *)
                set -- $line; mirror_state "$2" "$3" "$4" ;;
            CLOSE\ *)
                mirror_close "${line#CLOSE }" ;;
            HB) : ;;
        esac
    done
    log "link to $MAIN lost"
    sleep 3
done
