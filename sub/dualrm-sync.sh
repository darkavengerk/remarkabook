#!/bin/sh
# dual-rM sync. Runs ON THE SUB tablet (systemd: dualrm-sync.service) and treats both tablets
# alike: whatever is opened, closed or paged on one is mirrored on the other.
#
# Both tablets run the xochitl patch and the event/command sockets (node/). The main is reached
# over one ssh session (USB first, then home WiFi) running node/dualrm-link.sh. Nothing polls:
# this script sleeps on the $D/events fifo, fed by
#   "EV ..."  events of this tablet (dualrm-ev.sh)
#   "RM ..."  events of the main (forwarded by the link reader below)
#
# Pairing rules
#   notebook          -> same folder path + name on the other tablet (created if missing),
#                        same page count (pages are added, never deleted), same page
#   pdf/epub present on both (same document id, e.g. via reMarkable cloud)
#                     -> book mode: one tablet shows the left page, the other the right page
#   pdf/epub missing on the other tablet
#                     -> blank notebook of the same name that grows up to the page being read
# Echoes (the other tablet reporting what we just told it to do) are recognised and dropped.
. /home/root/dualrm/dualrm-lib.sh
KEY=$D/id_dualrm
MAIN_USB=10.11.99.1
MAIN_LAN=""
BOOK_LEFT=main          # tablet showing the left page in book mode (main | sub)
BOOK_COVER=0            # 1: first page alone on the right, like a printed book
[ -f "$D/dualrm.conf" ] && . "$D/dualrm.conf"

mkfifos
trap 'rm -f "$D/events.reader"' EXIT
[ -p "$D/linkin" ] || { rm -f "$D/linkin"; mkfifo "$D/linkin"; }
echo $$ > "$D/events.reader"
exec 3<> "$D/events"    # read end (opened read-write so it never sees EOF)
exec 4<> "$D/linkin"    # commands to the main; the ssh session reads the other end

now() { read -r up _ < /proc/uptime; NOW=${up%.*}; }

# ---------------------------------------------------------------- link to the main
ROLE=$(ls -d /sys/devices/soc0/soc/30800000.aips-bus/30b20000.usb/ci_hdrc.*/role 2>/dev/null | head -n 1)

pick_main() {
    # USB link = a cdc_ether interface (USB-C in host mode, or the pogo pins)
    for n in /sys/class/net/*; do
        case "$(readlink "$n/device/driver" 2>/dev/null)" in
            *cdc_ether*)
                k=0
                while [ $k -lt 10 ]; do   # DHCP from the main can take a few seconds
                    if ping -c1 -W1 "$MAIN_USB" >/dev/null 2>&1; then echo "$MAIN_USB"; return; fi
                    k=$((k + 1))
                done ;;
        esac
    done
    if [ -n "$MAIN_LAN" ] && ping -c1 -W1 "$MAIN_LAN" >/dev/null 2>&1; then echo "$MAIN_LAN"; fi
}

link_loop() {
    while :; do
        MAIN=$(pick_main)
        if [ -z "$MAIN" ]; then sleep 5; continue; fi
        log "connecting to main at $MAIN"
        # -I: drop the session when the main falls silent (it sends HB every 30 s)
        ssh -y -K 10 -I 75 -i "$KEY" "root@$MAIN" 'sh /home/root/dualrm/dualrm-link.sh' \
            < "$D/linkin" 2>>"$D/ssh.err" | while IFS= read -r l; do
            case "$l" in
                "EV RESP "*) printf '%s\n' "${l#EV RESP }" > "$D/rresponse" ;;
                EV\ *) printf 'RM %s\n' "${l#EV }" > "$D/events" ;;
                HELLO) echo "RM LINKUP" > "$D/events" ;;
            esac
        done
        echo "RM LINKDOWN" > "$D/events"
        log "link to $MAIN lost"
        sleep 3
    done
}

LINK=0
remote_request() { # command... -> "ok" payload from the main
    [ "$LINK" = 1 ] || return 1
    _n="r$(cut -d' ' -f1 /proc/uptime | tr -d .)$$"
    : > "$D/rresponse"
    printf 'CMD %s %s\n' "$_n" "$*" >&4
    _i=0
    while [ $_i -lt 80 ]; do
        _r=$(cat "$D/rresponse" 2>/dev/null)
        case "$_r" in
            "$_n ok"*) _r=${_r#"$_n ok"}; echo "${_r# }"; return 0 ;;
            "$_n error"*) log "main replied: ${_r#"$_n "}"; return 1 ;;
        esac
        usleep 100000
        _i=$((_i + 1))
        [ $((_i % 15)) = 0 ] && printf 'CMD %s %s\n' "$_n" "$*" >&4   # bell may have been eaten
    done
    log "main: no answer for: $*"
    return 1
}

req() { # side command... (side: main | sub)
    _s=$1; shift
    if [ "$_s" = sub ]; then local_request "$@"; else remote_request "$@"; fi
}

other() { if [ "$1" = main ]; then echo sub; else echo main; fi; }

# ---------------------------------------------------------------- state per tablet
# DOC_x FT_x PC_x CP_x: what is open on x.  EXPDOC_x: document we told x to open (its DOC
# event is an echo).  EXPPG_x/EXPT_x: page we told x to show, and when.
DOC_main=""; DOC_sub=""; FT_main=""; FT_sub=""; PC_main=0; PC_sub=0; CP_main=-1; CP_sub=-1
EXPDOC_main=""; EXPDOC_sub=""; EXPPG_main=""; EXPPG_sub=""; EXPT_main=0; EXPT_sub=0
MODE=""; LEAD=""; PENDING=""; CLOSING=""; CLOSET=0
get() { eval "echo \"\$${1}_$2\""; }
put() { eval "${1}_$2=\$3"; }

find_on() { # side parent type name -> uuid or nothing
    if [ "$1" = sub ]; then find_child "$2" "$3" "$4"; else remote_request find "${2:--}" "$3" "$4"; fi
}

has_on() { # side uuid
    if [ "$1" = sub ]; then live "$2"; else [ "$(remote_request has "$2")" = yes ]; fi
}

mirror_path() { # side path -> uuid of the notebook at that path on side (folders/notebook created)
    s=$1; path=$2; parent=""
    oifs=$IFS; IFS=$US; set -f; set -- $path; set +f; IFS=$oifs
    n=$#; i=1
    for part in "$@"; do
        if [ $i -lt $n ]; then
            fid=$(find_on "$s" "$parent" CollectionType "$part")
            if [ -z "$fid" ]; then
                fid=$(req "$s" mkdir "${parent:--}" "$part") || return 1
                log "$s: created folder '$part'"
            fi
            parent=$fid
        else
            doc=$(find_on "$s" "$parent" DocumentType "$part")
            if [ -z "$doc" ]; then
                doc=$(req "$s" create "${parent:--}" "$part") || return 1
                log "$s: created notebook '$part'"
            fi
            echo "$doc"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

goto() { # side page: show page on side unless it is there already
    [ "$(get CP "$1")" = "$2" ] && return 0
    now; put EXPPG "$1" "$2"; put EXPT "$1" "$NOW"
    req "$1" gotopage "$2" >/dev/null
}

# ---------------------------------------------------------------- book mode page math
# Spread s holds left page 2s-COVER and right page 2s+1-COVER (0-based page indices).
spread() { echo $(( ($1 + BOOK_COVER) / 2 )); }
rolepage() { # side spread -> page index on that side (-1: none)
    if [ "$1" = "$BOOK_LEFT" ]; then echo $(( 2 * $2 - BOOK_COVER )); else echo $(( 2 * $2 + 1 - BOOK_COVER )); fi
}

book_sync() { # side oldpage: side moved; put both tablets on the right spread
    x=$1; q=$2; y=$(other "$x"); p=$(get CP "$x"); pc=$(get PC "$x")
    [ "$p" -ge 0 ] 2>/dev/null || return
    s=$(spread "$p")
    if [ "$(rolepage "$x" "$s")" != "$p" ]; then
        # landed on the other tablet's page: one page turned = one spread turned
        if [ "$q" -ge 0 ] 2>/dev/null && [ "$p" -gt "$q" ]; then s=$(( $(spread "$q") + 1 ))
        elif [ "$q" -ge 0 ] 2>/dev/null && [ "$p" -lt "$q" ]; then s=$(( $(spread "$q") - 1 ))
        fi
    fi
    [ "$s" -lt 0 ] && s=0
    tx=$(rolepage "$x" "$s"); ty=$(rolepage "$y" "$s")
    [ "$tx" -ge "$pc" ] && tx=$((pc - 1))
    [ "$ty" -ge "$pc" ] && ty=$((pc - 1))
    [ "$tx" -ge 0 ] && [ "$tx" != "$p" ] && goto "$x" "$tx"
    [ "$ty" -ge 0 ] && goto "$y" "$ty"
    log "book: spread $s ($BOOK_LEFT left)"
}

pages_sync() { # side oldpage oldcount: side's pages changed; bring the other tablet along
    x=$1; q=$2; qc=$3; y=$(other "$x")
    pc=$(get PC "$x"); cp=$(get CP "$x"); ypc=$(get PC "$y")
    case "$MODE" in
        book) book_sync "$x" "$q" ;;
        mirror)
            if [ "$pc" -eq $((qc + 1)) ] && [ "$ypc" -eq "$qc" ] && [ "$cp" -ge 1 ] && [ "$cp" -lt "$pc" ]; then
                # one page inserted at cp: insert at the same place
                now; put EXPPG "$y" "$cp"; put EXPT "$y" "$NOW"
                req "$y" addpage "$cp" >/dev/null && log "$y: inserted page at $cp"
            elif [ "$ypc" -lt "$pc" ]; then
                now; put EXPPG "$y" "$cp"; put EXPT "$y" "$NOW"
                t=$(req "$y" ensure "$pc" "$cp") && [ "$t" -gt "$ypc" ] && { put PC "$y" "$t"; log "$y: $((t - ypc)) page(s) added -> $t"; }
            else
                goto "$y" "$cp"
            fi ;;
        lazy)
            if [ "$(get FT "$x")" = notebook ]; then
                # paging the blank notebook pages the document
                [ "$cp" -lt "$(get PC "$y")" ] && goto "$y" "$cp"
            else
                want=$((cp + 1))
                if [ "$ypc" -lt "$want" ]; then
                    now; put EXPPG "$y" "$cp"; put EXPT "$y" "$NOW"
                    req "$y" ensure "$want" "$cp" >/dev/null
                else
                    goto "$y" "$cp"
                fi
            fi ;;
    esac
}

# ---------------------------------------------------------------- events
on_doc() { # side uuid ft path
    x=$1; u=$2; y=$(other "$x")
    if [ "$u" = - ]; then
        put DOC "$x" ""
        [ -n "$(get EXPDOC "$x")" ] && return      # closing on the way to a document we asked for
        if [ "$CLOSING" = "$x" ]; then CLOSING=""; return; fi
        # opening another document closes this one first: decide a moment later (pending close)
        [ -n "$MODE" ] && { now; CLOSING_FROM=$x; CLOSET=$NOW; }
        return
    fi
    put DOC "$x" "$u"; put FT "$x" "$3"; put PC "$x" 0; put CP "$x" -1
    if [ "$u" = "$(get EXPDOC "$x")" ]; then
        put EXPDOC "$x" ""      # pairing finishes with its first PAGE report (on_page)
        return
    fi
    CLOSING_FROM=""
    [ "$LINK" = 1 ] || return       # no main: just remember; the main's state wins at link up
    # a document was opened by hand on x
    target=""
    case "$3" in
        pdf|epub)
            if has_on "$y" "$u"; then target=$u; MODE=book
            else target=$(mirror_path "$y" "$4") && MODE=lazy
            fi ;;
        *)
            target=$(mirror_path "$y" "$4") && MODE=mirror ;;
    esac
    if [ -z "$target" ]; then log "no counterpart on $y for '$(echo "$4" | tr "$US" /)'"; MODE=""; return; fi
    LEAD=$x
    if [ "$(get DOC "$y")" = "$target" ]; then
        PENDING=""
    else
        PENDING=$y; put EXPDOC "$y" "$target"
        req "$y" open "$target" >/dev/null || { put EXPDOC "$y" ""; PENDING=""; MODE=""; return; }
    fi
    log "$x opened '$(echo "$4" | tr "$US" /)' ($3) -> $y $target, $MODE mode"
    [ -z "$PENDING" ] && pages_sync "$x" -1 0
}

on_page() { # side uuid pagecount currentpage
    x=$1; [ "$2" = "$(get DOC "$x")" ] || return
    q=$(get CP "$x"); qc=$(get PC "$x")
    put PC "$x" "$3"; put CP "$x" "$4"
    [ -n "$MODE" ] || return
    if [ -n "$PENDING" ]; then
        # the other tablet finished opening its counterpart: line it up with the leader
        [ "$PENDING" = "$x" ] && [ -z "$(get EXPDOC "$x")" ] && [ "$4" -ge 0 ] && { PENDING=""; pages_sync "$LEAD" -1 0; }
        return
    fi
    now
    e=$(get EXPPG "$x")
    if [ -n "$e" ] && [ $((NOW - $(get EXPT "$x"))) -le 5 ]; then
        # we moved this tablet: drop the reports on the way there, and the arrival itself
        [ "$4" = "$e" ] || return
        put EXPPG "$x" ""
        return
    fi
    [ "$3" = "$qc" ] && [ "$4" = "$q" ] && return
    pages_sync "$x" "$q" "$qc"
}

close_pending() { # the document on CLOSING_FROM stayed closed: close the other side too
    x=$CLOSING_FROM; CLOSING_FROM=""; y=$(other "$x")
    [ -n "$(get DOC "$x")" ] && return
    MODE=""; PENDING=""
    d=$(get DOC "$y"); [ -n "$d" ] || return
    CLOSING=$y
    req "$y" close "$d" >/dev/null && log "$x closed -> closed on $y"
}

# ---------------------------------------------------------------- main loop
link_loop &
log "sync v7 (event driven, both ways)"
CLOSING_FROM=""
local_request emit >/dev/null
while :; do
    if [ -n "$CLOSING_FROM" ]; then
        if ! IFS= read -r -t 1 line <&3; then
            now; [ $((NOW - CLOSET)) -ge 1 ] && close_pending
            continue
        fi
    else
        IFS= read -r line <&3 || continue
    fi
    side=sub; body=${line#EV }
    case "$line" in RM\ *) side=main; body=${line#RM } ;; esac
    case "$body" in
        "DOC -") on_doc "$side" - ;;
        DOC\ *)
            r=${body#DOC }; u=${r%% *}; r=${r#* }; ft=${r%% *}; path=${r#* }
            on_doc "$side" "$u" "$ft" "$path" ;;
        PAGE\ *)
            set -f; set -- $body; set +f
            on_page "$side" "$2" "$3" "$4" ;;
        LINKUP)
            LINK=1; log "link up"
            remote_request emit >/dev/null ;;
        LINKDOWN)
            LINK=0; MODE=""; PENDING=""; CLOSING_FROM="" ;;
    esac
done
