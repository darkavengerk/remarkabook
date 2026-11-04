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
#                     -> copied there (same folder path, xochitl's importer, new id; the pair is
#                        kept in $D/pairs), then book mode. If the copy fails: a blank notebook
#                        of the same name that grows up to the page being read
# Annotations of book-mode documents (pen, highlights) are copied page by page: from the tablet
# that opened the document before the other one opens it, and both ways once it is closed.
# The newer file wins; a replaced file is kept in $D/backup/ on the tablet it was replaced on.
# Pen settings (pen, colour, width) of paired documents follow each other; when a pair opens,
# the main's settings win. In book mode a page turn by hand moves two pages at once on either
# tablet (one page alone). Scrolling a notebook page on one tablet scrolls the same page on the
# other (notebooks only, not PDF/EPUB). Going to sleep on one tablet puts the other to sleep too (waking
# up is per tablet: only the power button wakes a reMarkable).
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
trap 'exit 0' TERM INT HUP
rmdir "$D/ann.lock" 2>/dev/null
[ -p "$D/linkin" ] || { rm -f "$D/linkin"; mkfifo "$D/linkin"; }
echo $$ > "$D/events.reader"
exec 3<> "$D/events"    # read end (opened read-write so it never sees EOF)
exec 4<> "$D/linkin"    # commands to the main; the ssh session reads the other end

now() { read -r up _ < /proc/uptime; NOW=${up%.*}; }
tick() { read -r up _ < /proc/uptime; TICK=${up%.*}${up#*.}; }   # uptime in 1/100 s

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
        echo "$MAIN" > "$D/mainhost"
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

mssh() { ssh -y -K 10 -i "$KEY" "root@$(cat "$D/mainhost")" "$@" 2>>"$D/ssh.err"; }   # extra session for files

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

shell_on() { # side function [args]: a lib function, run on side (the main's link answers these)
    _s=$1; shift
    if [ "$_s" = sub ]; then "$@"; else remote_request "$@"; fi
}

fsize_on() { # side file-in-XD
    if [ "$1" = sub ]; then stat -c %s "$XD/$2" 2>/dev/null; else remote_request fsize "$2"; fi
}

mirror_folders() { # side path -> id of the folder holding the path's last name ("-": top level),
                   # folders created as needed
    s=$1; path=$2; parent=""
    oifs=$IFS; IFS=$US; set -f; set -- $path; set +f; IFS=$oifs
    n=$#; i=1
    for part in "$@"; do
        [ $i -lt $n ] || break
        fid=$(find_on "$s" "$parent" CollectionType "$part")
        if [ -z "$fid" ]; then
            fid=$(req "$s" mkdir "${parent:--}" "$part") || return 1
            log "$s: created folder '$part'"
        fi
        parent=$fid
        i=$((i + 1))
    done
    echo "${parent:--}"
}

mirror_path() { # side path -> uuid of the notebook at that path on side (folders/notebook created)
    parent=$(mirror_folders "$1" "$2") || return 1
    [ "$parent" = - ] && parent=""
    name=${2##*"$US"}
    doc=$(find_on "$1" "$parent" DocumentType "$name")
    if [ -z "$doc" ]; then
        doc=$(req "$1" create "${parent:--}" "$name") || return 1
        log "$1: created notebook '$name'"
    fi
    echo "$doc"
}

# ---------------------------------------------------------------- PDF / EPUB on both tablets
pair_of() { # side doc ft path -> the same document on the other tablet: same id, an earlier
            # copy ($D/pairs), or a file of the same name and size in the same folder
    x=$1; u=$2; y=$(other "$x")
    if has_on "$y" "$u"; then echo "$u"; return 0; fi
    if [ -f "$D/pairs" ]; then
        if [ "$x" = sub ]; then c=$(awk -v u="$u" '$1 == u { c = $2 } END { print c }' "$D/pairs")
        else c=$(awk -v u="$u" '$2 == u { c = $1 } END { print c }' "$D/pairs"); fi
        [ -n "$c" ] && has_on "$y" "$c" && { echo "$c"; return 0; }
    fi
    parent=$(mirror_folders "$y" "$4") || return 1
    [ "$parent" = - ] && parent=""
    c=$(find_on "$y" "$parent" DocumentType "${4##*"$US"}")
    [ -n "$c" ] && [ "$(fsize_on "$y" "$c.$3")" = "$(fsize_on "$x" "$u.$3")" ] || return 1
    pair_add "$x" "$u" "$c"
    echo "$c"
}

pair_add() { # side doc other-doc
    if [ "$1" = sub ]; then echo "$2 $3"; else echo "$3 $2"; fi >> "$D/pairs"
}

copy_doc() ( # side doc ft path -> id of a new copy on the other tablet (same folder path)
    x=$1; u=$2; ft=$3; y=$(other "$x")
    parent=$(mirror_folders "$y" "$4") || exit 1
    name=${4##*"$US"}
    # the importer names the copy after the file (3.29 drops the extension, 3.23 keeps it)
    f=$(printf '%s' "$name" | tr / _)
    case "$f" in *."$ft") ;; *) f="$f.$ft" ;; esac
    log "copying '$name' ($(( $(fsize_on "$x" "$u.$ft") / 1024 )) KB) to $y"
    shell_on "$y" snap_docs >/dev/null || exit 1
    if [ "$y" = main ]; then
        { printf '%s\n' "$f"; cat "$XD/$u.$ft"; } \
            | mssh 'IFS= read -r n; mkdir -p /home/root/dualrm/inbox && cat > "/home/root/dualrm/inbox/$n"' || exit 1
    else
        mkdir -p "$D/inbox" && mssh "cat $XD/$u.$ft" > "$D/inbox/$f" || exit 1
    fi
    req "$y" import "$parent" "$D/inbox/$f" >/dev/null || exit 1
    i=0; c=""
    while [ $i -lt 120 ] && [ -z "$c" ]; do
        sleep 1; i=$((i + 1))
        c=$(shell_on "$y" new_doc)
    done
    if [ "$y" = main ]; then mssh 'rm -rf /home/root/dualrm/inbox'; else rm -rf "$D/inbox"; fi
    [ -n "$c" ] || { log "$y: import of '$name' did not finish"; exit 1; }
    pair_add "$x" "$u" "$c"
    log "$y: imported '$name' as $c"
    sleep 1     # let the library list it before it is opened
    echo "$c"
)

ann_sync() ( # sub-doc main-doc both|tomain|tosub: copy the newer annotation files across
    s=$1; m=$2; T=$D/ann.work
    # an EPUB copy lays out its pages by itself: only the same document can be matched
    [ "$s" != "$m" ] && [ -f "$XD/$s.epub" ] && exit 0
    rm -rf "$T"; mkdir -p "$T/out" "$T/in"
    ann_list "$s" > "$T/s"
    mssh ". $D/dualrm-lib.sh; ann_list $m" > "$T/m" || { rm -rf "$T"; exit 1; }
    same=0; [ "$s" = "$m" ] && same=1
    # pages are matched by page id (same document) or by PDF page (a copy)
    awk -v same=$same -v dir="$3" '
        { side = (FILENAME == ARGV[1]) ? 1 : 2 }
        $1 == "P" { k = same ? $2 : $3; if (k == "-" || k == "x") next; ID[side, k] = $2; K[side, $2] = k; next }
        $1 == "F" { k = K[side, $3]; if (k == "") next; T[side, $2, k] = $4; H[side, $2, k] = $5; ALL[$2 " " k] = 1 }
        END {
            for (tk in ALL) {
                split(tk, a, " "); t = a[1]; k = a[2]
                hs = H[1, t, k]; hm = H[2, t, k]
                if (hs == hm) continue
                if (dir != "tosub" && hs != "" && (hm == "" || T[1, t, k] > T[2, t, k]) && ID[2, k] != "")
                    print "tomain", t, ID[1, k], ID[2, k]
                else if (dir != "tomain" && hm != "" && (hs == "" || T[2, t, k] > T[1, t, k]) && ID[1, k] != "")
                    print "tosub", t, ID[2, k], ID[1, k]
            }
        }' "$T/s" "$T/m" > "$T/plan"
    rel() { # doc kind page -> annotation file, and the page preview that goes with it
        if [ "$2" = hl ]; then echo "$1.highlights/$3.json"; else echo "$1/$3.rm $1.thumbnails/$3.png"; fi
    }
    up=0; down=0; list=""
    while read -r d t from to; do
        if [ "$d" = tomain ]; then
            set -- $(rel "$s" "$t" "$from"); set -- "$@" $(rel "$m" "$t" "$to")
            if [ $# = 4 ]; then mkdir -p "$T/out/$m" "$T/out/$m.thumbnails"; cp -p "$XD/$1" "$T/out/$3"
                [ -f "$XD/$2" ] && cp -p "$XD/$2" "$T/out/$4"
            else mkdir -p "$T/out/$m.highlights"; cp -p "$XD/$1" "$T/out/$2"; fi
            up=$((up + 1))
        else
            list="$list $(rel "$m" "$t" "$from")"
            down=$((down + 1))
        fi
    done < "$T/plan"
    if [ $up -gt 0 ]; then
        tar cf - -C "$T/out" . | mssh ". $D/dualrm-lib.sh; t=$D/ann.in; rm -rf \$t; mkdir -p \$t && tar xf - -C \$t && ann_place \$t" \
            || log "annotations: copy to main failed"
    fi
    if [ $down -gt 0 ]; then
        mssh "cd $XD && set -- && for f in $list; do [ -e \$f ] && set -- \"\$@\" \$f; done; tar cf - \"\$@\"" \
            | tar xf - -C "$T/in" || log "annotations: copy from main failed"
        mkdir -p "$T/out2"
        while read -r d t from to; do
            [ "$d" = tosub ] || continue
            set -- $(rel "$m" "$t" "$from"); set -- "$@" $(rel "$s" "$t" "$to")
            if [ $# = 4 ]; then mkdir -p "$T/out2/$s" "$T/out2/$s.thumbnails"; mv "$T/in/$1" "$T/out2/$3"
                [ -f "$T/in/$2" ] && mv "$T/in/$2" "$T/out2/$4"
            else mkdir -p "$T/out2/$s.highlights"; mv "$T/in/$1" "$T/out2/$2"; fi
        done < "$T/plan"
        ann_place "$T/out2"
    fi
    [ $((up + down)) -gt 0 ] && log "annotations: $up page(s) to main, $down to sub"
    rm -rf "$T"
)

ann_locked() { # command...: one annotation copy at a time
    while ! mkdir "$D/ann.lock" 2>/dev/null; do sleep 1; done
    "$@"
    rmdir "$D/ann.lock"
}

BS=""; BM=""    # the book-mode pair: sub's document, main's document
book_end() { # book mode is over: copy annotations both ways once both have saved
    [ -n "$BS" ] && [ "$LINK" = 1 ] && ( sleep 3; ann_locked ann_sync "$BS" "$BM" both ) &
    BS=""; BM=""
}

goto() { # side page: show page on side unless it is there already
    [ "$(get CP "$1")" = "$2" ] && return 0
    now; put EXPPG "$1" "$2"; put EXPT "$1" "$NOW"; moved "$1"
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
        # landed on the other tablet's page. One page turned (a tablet still stepping one page
        # at a time) = one spread turned; a jump (page list, search, link) = the spread showing
        # that page, which then is on the other tablet.
        if [ "$q" -ge 0 ] 2>/dev/null && [ "$p" -eq $((q + 1)) ]; then s=$(( $(spread "$q") + 1 ))
        elif [ "$q" -ge 0 ] 2>/dev/null && [ "$p" -eq $((q - 1)) ]; then s=$(( $(spread "$q") - 1 ))
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

step_align() { # a pair is open on both: in book mode a page turn on either tablet moves two pages
    [ "$MODE" = book ] || return 0
    req main pagestep 2 >/dev/null && req sub pagestep 2 >/dev/null && log "book: page turns step 2"
}

pages_sync() { # side oldpage oldcount: side's pages changed; bring the other tablet along
    x=$1; q=$2; qc=$3; y=$(other "$x")
    pc=$(get PC "$x"); cp=$(get CP "$x"); ypc=$(get PC "$y")
    case "$MODE" in
        book) book_sync "$x" "$q" ;;
        mirror)
            if [ "$pc" -eq $((qc + 1)) ] && [ "$ypc" -eq "$qc" ] && [ "$cp" -ge 1 ] && [ "$cp" -lt "$pc" ]; then
                # one page inserted at cp: insert at the same place
                now; put EXPPG "$y" "$cp"; put EXPT "$y" "$NOW"; moved "$y"
                req "$y" addpage "$cp" >/dev/null && log "$y: inserted page at $cp"
            elif [ "$ypc" -lt "$pc" ]; then
                now; put EXPPG "$y" "$cp"; put EXPT "$y" "$NOW"; moved "$y"
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
    put DOC "$x" "$u"; put FT "$x" "$3"; put PC "$x" 0; put CP "$x" -1; put SCR "$x" ""
    if [ "$u" = "$(get EXPDOC "$x")" ]; then
        put EXPDOC "$x" ""      # pairing finishes with its first PAGE report (on_page)
        return
    fi
    CLOSING_FROM=""
    [ "$LINK" = 1 ] || return       # no main: just remember; the main's state wins at link up
    # a document was opened by hand on x
    target=""
    book_end
    case "$3" in
        pdf|epub)
            target=$(pair_of "$x" "$u" "$3" "$4") || target=$(copy_doc "$x" "$u" "$3" "$4")
            if [ -n "$target" ]; then MODE=book
            else target=$(mirror_path "$y" "$4") && MODE=lazy
            fi ;;
        *)
            target=$(mirror_path "$y" "$4") && MODE=mirror ;;
    esac
    if [ -z "$target" ]; then log "no counterpart on $y for '$(echo "$4" | tr "$US" /)'"; MODE=""; return; fi
    LEAD=$x
    if [ "$MODE" = book ]; then
        if [ "$x" = sub ]; then BS=$u; BM=$target; dir=tomain; else BS=$target; BM=$u; dir=tosub; fi
        # the other tablet reads its pages when it opens the document: copy before that
        [ "$(get DOC "$y")" = "$target" ] || ann_locked ann_sync "$BS" "$BM" "$dir"
    fi
    if [ "$(get DOC "$y")" = "$target" ]; then
        PENDING=""
    else
        PENDING=$y; put EXPDOC "$y" "$target"; moved "$y"
        req "$y" open "$target" >/dev/null || { put EXPDOC "$y" ""; PENDING=""; MODE=""; return; }
    fi
    log "$x opened '$(echo "$4" | tr "$US" /)' ($3) -> $y $target, $MODE mode"
    [ -z "$PENDING" ] && { pages_sync "$x" -1 0; pen_align; step_align; scroll_to "$y" "$(get SCR "$x")"; }
}

on_page() { # side uuid pagecount currentpage
    x=$1; [ "$2" = "$(get DOC "$x")" ] || return
    q=$(get CP "$x"); qc=$(get PC "$x")
    put PC "$x" "$3"; put CP "$x" "$4"
    [ -n "$MODE" ] || return
    if [ -n "$PENDING" ]; then
        # the other tablet finished opening its counterpart: line it up with the leader
        [ "$PENDING" = "$x" ] && [ -z "$(get EXPDOC "$x")" ] && [ "$4" -ge 0 ] && {
            PENDING=""; pages_sync "$LEAD" -1 0; pen_align; step_align; scroll_to "$(other "$LEAD")" "$(get SCR "$LEAD")"; }
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

# ---------------------------------------------------------------- notebook scrolling
# A notebook page scrolled on one tablet is scrolled to the same place on the other (mirror
# mode only: PDF/EPUB pages are not followed). A tablet we just opened, paged or scrolled
# reports where it settles: those reports are dropped for SCROLL_QUIET.
SCR_main=""; SCR_sub=""         # "<page> <top>" each tablet last reported
SCRT_main=0; SCRT_sub=0         # when we last moved each tablet (1/100 s)
SCROLL_QUIET=250
moved() { tick; put SCRT "$1" "$TICK"; }

scroll_to() { # side "<page> <top>": scroll side's page like the other tablet's
    _y=$1; set -f; set -- $2; set +f
    [ "$MODE" = mirror ] && [ -z "$PENDING" ] && [ -n "$2" ] || return 0
    [ "$(get CP "$_y")" = "$1" ] || [ "$(get EXPPG "$_y")" = "$1" ] || return 0
    moved "$_y"
    req "$_y" setscroll "$1" "$2" >/dev/null
}

on_scroll() { # side uuid page top
    [ "$2" = "$(get DOC "$1")" ] || return
    put SCR "$1" "$3 $4"
    [ "$MODE" = mirror ] && [ -z "$PENDING" ] || return
    tick; [ $((TICK - $(get SCRT "$1"))) -lt $SCROLL_QUIET ] && return
    scroll_to "$(other "$1")" "$3 $4"
}

# ---------------------------------------------------------------- pens and sleep
PENSET_main=""; PENSET_sub=""   # settings we last gave each tablet, and when: its report of
PENSETT_main=0; PENSETT_sub=0   # them right after is an echo
PENT=0                          # when the main's settings were last given to the sub
pen_align() { # a pair is open on both: the main's pen settings win
    st=$(req main pen) && [ -n "$st" ] || return
    now; PENT=$NOW
    PENSET_sub=$st; PENSETT_sub=$NOW
    req sub setpen "$st" >/dev/null && log "pens: main -> sub"
}

on_pen() { # side json
    x=$1; y=$(other "$x")
    [ -n "$MODE" ] && [ -z "$PENDING" ] && [ -n "$(get DOC "$y")" ] || return
    now
    [ "$2" = "$(get PENSET "$x")" ] && [ $((NOW - $(get PENSETT "$x"))) -le 3 ] && return
    # the sub changing right as the main's settings arrive: keep the main's
    [ "$x" = sub ] && [ $((NOW - PENT)) -le 2 ] && return
    [ "$x" = main ] && PENT=$NOW
    put PENSET "$y" "$2"; put PENSETT "$y" "$NOW"
    req "$y" setpen "$2" >/dev/null && log "pens: $x -> $y"
}

# xochitl only sleeps through its own power button handling (BatteryManager.goToSleep refuses
# while the screen is not showing the sleep screen), so the other tablet gets a key press. It
# must be awake for that: a press on a tablet showing the sleep screen wakes it up.
AWAKE_main=1; AWAKE_sub=1
on_sleep() { # side: x is going to sleep
    x=$1; y=$(other "$x")
    put AWAKE "$x" 0
    [ "$(get AWAKE "$y")" = 1 ] || return
    [ "$y" = sub ] || [ "$LINK" = 1 ] || return
    put AWAKE "$y" 0
    shell_on "$y" power_key >/dev/null && log "$x went to sleep -> $y too"
}

on_wake() { # side
    put AWAKE "$1" 1
    # the sub's link may be stuck on a session that died while either tablet slept: start over
    [ "$1" = sub ] || return
    for pd in /proc/[0-9]*; do
        case "$(tr '\0' ' ' 2>/dev/null < "$pd/cmdline")" in
            ssh\ *dualrm-link.sh*) kill "${pd#/proc/}" 2>/dev/null ;;
        esac
    done
}

close_pending() { # the document on CLOSING_FROM stayed closed: close the other side too
    x=$CLOSING_FROM; CLOSING_FROM=""; y=$(other "$x")
    [ -n "$(get DOC "$x")" ] && return
    book_end
    MODE=""; PENDING=""
    d=$(get DOC "$y"); [ -n "$d" ] || return
    CLOSING=$y
    req "$y" close "$d" >/dev/null && log "$x closed -> closed on $y"
}

# ---------------------------------------------------------------- main loop
link_loop &
log "sync v10 (event driven, both ways, copies PDFs and annotations, pens, notebook scroll, sleep)"
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
        PEN\ *) on_pen "$side" "${body#PEN }" ;;
        SCROLL\ *)
            set -f; set -- $body; set +f
            on_scroll "$side" "$2" "$3" "$4" ;;
        SLEEP) on_sleep "$side" ;;
        WAKE) on_wake "$side" ;;
        LINKUP)
            LINK=1; AWAKE_main=1; log "link up"
            remote_request emit >/dev/null ;;
        LINKDOWN)
            # alone again: page turns step one page (the main's link end does the same there)
            [ "$MODE" = book ] && local_request pagestep 1 >/dev/null
            LINK=0; MODE=""; PENDING=""; CLOSING_FROM=""; BS=""; BM="" ;;
    esac
done
