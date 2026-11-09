# dual-rM: shared notebooks. Sourced by dualrm-sync.sh (uses its state: DOC_*, CP_*, PC_*, LEAD,
# PENDING, MODE, LINK, BS, BM, BOOK_LEFT, and its helpers req, get, put, other, log, now, goto,
# moved, spread, rolepage, mssh, ann_sync, ann_locked).
#
# One notebook on both tablets, in book mode: each tablet keeps its own page ids and the map
# ($D/pagemap/<sub notebook id>, see dualrm-pagemap.sh) says which pages are the same page.
#   - Structure (pages added, moved, deleted) follows the tablet that changed it, through
#     xochitl's own operations (patch commands addpage, delpages, reorder). Pages added on a
#     tablet become a whole spread; a deleted page takes its blank partner along.
#   - Strokes are files: copied through the map (ann_sync) before the other tablet opens the
#     notebook, both ways after it is closed, and by a refresh (close both, copy, reopen) when
#     pages with different strokes on the two tablets come into view on the other tablet.
#   - A pair met for the first time is merged: left tablet's page i, then the other's page i.
# The sync handles one event at a time: while these functions run, the reports of our own
# changes wait in the fifo. Each batch of page commands re-reads both page lists (PL_*), so a
# PAGES report that arrives late finds the list it reports already known and is dropped.
. /home/root/dualrm/dualrm-pagemap.sh
NB=0                    # the open pair is a shared notebook
NBMAP=""                # its map file
NBNAME=""               # its name (for the log)
PL_main=""; PL_sub=""   # page lists (id8, comma-separated) last read from each tablet
TP_main=""; TP_sub=""   # their templates, "|"-separated, same order
NBQ=0                   # until then (uptime s), PAGE reports are our own changes settling
NB_REFRESHED=0          # a refresh ran for this opening: do not start another
NB_DEL_MAX=10           # more deletes than this in one go are refused (logged)
mkdir -p "$D/pagemap"

nb_quiet() { now; NBQ=$((NOW + 3)); }   # we just changed pages: their PAGE reports are ours

nb_count() { echo "$1" | tr , '\n' | grep -c .; }

nb_lists() { # read both tablets' page lists -> PL_*, TP_*; 1 (nothing changed) when either fails
    nb_rm=$(req main pages) && nb_rs=$(req sub pages) || return 1
    # an empty list is a failed or stale answer, never "no pages": it must not lead to deletes
    [ -n "${nb_rm%% *}" ] && [ -n "${nb_rs%% *}" ] || { log "notebook: no page list"; return 1; }
    PL_main=${nb_rm%% *}; PL_sub=${nb_rs%% *}
    TP_main=""; case "$nb_rm" in *" "*) TP_main=${nb_rm#* } ;; esac
    TP_sub=""; case "$nb_rs" in *" "*) TP_sub=${nb_rs#* } ;; esac
}

nb_tpl() { # side id8 -> template of that page on side (as last read)
    get PL "$1" | tr , '\n' | awk -v id="$2" -v T="$(get TP "$1")" \
        'BEGIN { split(T, t, "|") } $0 == id { print t[NR]; exit }'
}

nb_ids() { # side i,j,... -> the id8s at those indices on side (as last read)
    get PL "$1" | awk -F, -v I="$2" '{ n = split(I, i, ","); o = ""
        for (j = 1; j <= n; j++) o = o "," $(i[j] + 1); print substr(o, 2) }'
}

nb_on() { # side function args...: a dualrm-lib.sh function on that tablet
    nb_sd=$1; shift
    # no stdin for ssh: it would eat the caller's input (nb_run reads its operations from it)
    if [ "$nb_sd" = sub ]; then "$@"; else mssh ". $D/dualrm-lib.sh; $*" < /dev/null; fi
}

nb_where() { # side: its page count and current page, asked (reports may still be on the way)
    nb_st=$(req "$1" status) || return 1
    set -f; set -- "$1" $nb_st; set +f
    [ "$2" = "$(get DOC "$1")" ] || return 1
    put PC "$1" "$3"; put CP "$1" "$4"
}

nb_mapok() { # does the map belong to the pair BS / BM?
    [ "$(sed -n '1s/^doc //p' "$NBMAP" 2>/dev/null)" = "$BS $BM" ]
}

nb_mapline() { # side new-id8 partner-id8: the page just added on side is partner's page
    if [ "$1" = sub ]; then echo "$2 $3"; else echo "$3 $2"; fi >> "$NBMAP"
}

nb_prune() { # drop map lines whose pages are gone on both tablets (after a successful run)
    awk -v S="$PL_sub" -v M="$PL_main" 'BEGIN {
            n = split(S, a, ","); for (i = 1; i <= n; i++) s[a[i]] = 1
            n = split(M, a, ","); for (i = 1; i <= n; i++) m[a[i]] = 1 }
        $1 == "doc" || ($1 in s) || ($2 in m)' "$NBMAP" > "$NBMAP.tmp" && mv "$NBMAP.tmp" "$NBMAP"
}

nb_run() { # ops (pm_plan / pm_merge output, one string) -> done on the tablets, map updated.
           # Deletes first: their indices are positions in the lists as last read (one del line
           # per side). Adds after, ascending; a template is looked up by the partner's id on the
           # other side, whose page is in the list as last read (adds never move it away).
    nb_ops=$1
    [ -n "$nb_ops" ] || return 0
    nb_n=$(echo "$nb_ops" | awk '$1 == "del" { n += split($3, a, ",") } END { print n + 0 }')
    if [ "$nb_n" -gt "$NB_DEL_MAX" ]; then
        log "notebook: refusing to delete $nb_n pages at once (map: $NBMAP)"
        return 1
    fi
    rm -f "$D/nb.rows"
    while read -r nb_op nb_s nb_a nb_p; do
        case "$nb_op" in
            del)
                nb_on "$nb_s" page_backup "$(get DOC "$nb_s")" "$(nb_ids "$nb_s" "$nb_a")"
                req "$nb_s" delpages "$nb_a" >/dev/null || { nb_quiet; return 1; }
                nb_quiet
                log "$nb_s: page(s) $nb_a deleted like on $(other "$nb_s") (strokes in $D/backup)" ;;
            add)
                nb_t=""
                case "$nb_p" in =*) ;; *) nb_t=$(nb_tpl "$(other "$nb_s")" "$nb_p") ;; esac
                nb_new=$(req "$nb_s" addpage "$nb_a" "$nb_t") || { nb_quiet; return 1; }
                nb_quiet
                [ -n "$nb_new" ] || return 1
                case "$nb_p" in
                    =*) # a page new on both tablets: map it with the other side's page of that row
                        nb_o=$(awk -v k="$nb_p" '$1 == k { print $3 }' "$D/nb.rows" 2>/dev/null)
                        if [ -z "$nb_o" ]; then echo "$nb_p $nb_s $nb_new" >> "$D/nb.rows"
                        else nb_mapline "$nb_s" "$nb_new" "$nb_o"; fi ;;
                    *) nb_mapline "$nb_s" "$nb_new" "$nb_p" ;;
                esac ;;
        esac
    done <<EOF
$nb_ops
EOF
    rm -f "$D/nb.rows"
}

nb_order() { # leader: put the other tablet's pages in the leader's order
    nb_f=$(other "$1")
    nb_to=$(pm_translate "$(get PL "$1")" "$NBMAP" "$nb_f") || { log "notebook: page map incomplete"; return 1; }
    nb_pm=$(pm_perm "$(get PL "$nb_f")" "$nb_to") || { log "notebook: pages differ after sync"; return 1; }
    [ -n "$nb_pm" ] || return 0
    req "$nb_f" reorder "$nb_pm" >/dev/null; nb_r=$?
    nb_quiet
    [ "$nb_r" = 0 ] || { nb_lists; return 1; }
    put PL "$nb_f" "$nb_to"
    put TP "$nb_f" "$(get TP "$nb_f" | awk -F'|' -v P="$nb_pm" \
        '{ n = split(P, p, ","); o = ""; for (j = 1; j <= n; j++) o = o "|" $(p[j] + 1); print substr(o, 2) }')"
    log "$nb_f: pages put in $1's order"
}

nb_pad() { # an odd page count gets a blank page at the end on both: whole spreads
    nb_c=$(nb_count "$PL_main")
    [ $((nb_c % 2)) = 1 ] || return 0
    nb_run "add main $nb_c =pad
add sub $nb_c =pad"; nb_r=$?
    nb_lists || return 1
    [ "$nb_r" = 0 ] && log "notebook: blank page added at the end (whole spreads)"
}

nb_sync() { # leader: both tablets get the same pages, in the leader's order
    nb_lists || return 1
    # pm_plan fails (no output) on an empty list: that is no reconcile, not "nothing to do"
    nb_plan=$(pm_plan "$PL_sub" "$PL_main" "$NBMAP" "$1") || { log "notebook: no plan"; return 1; }
    if [ -n "$nb_plan" ]; then
        nb_run "$nb_plan"; nb_r=$?
        nb_lists || return 1        # whatever happened, PL_* is what the tablets have now
        [ "$nb_r" = 0 ] || return 1
        nb_prune
    fi
    nb_order "$1" && nb_pad
}

nb_differs() { # sub-id8 list -> those whose strokes differ between the tablets
    [ -n "$1" ] || return 0
    ann_list "$DOC_sub" > "$D/nb.ann.sub"
    if mssh ". $D/dualrm-lib.sh; ann_list $DOC_main" < /dev/null > "$D/nb.ann.main"; then
        pm_differ "$D/nb.ann.sub" "$D/nb.ann.main" "$NBMAP" "$1"
    fi
    rm -f "$D/nb.ann.sub" "$D/nb.ann.main"
}

nb_doc() { if [ "$1" = sub ]; then echo "$BS"; else echo "$BM"; fi; }

nb_close() { # side: close the pair's notebook there for a refresh; 1 when it was not open
    put EXPDOC "$1" "$(nb_doc "$1")"      # its "DOC -" is ours: no close follows on the other
    case "$(req "$1" close "$(nb_doc "$1")")" in closed*) return 0 ;; esac
    put EXPDOC "$1" ""; return 1
}

nb_open() { # side: open the pair's notebook there again after a refresh
    put EXPDOC "$1" "$(nb_doc "$1")"
    req "$1" open "$(nb_doc "$1")" >/dev/null && return 0
    put EXPDOC "$1" ""; log "$1: could not open the notebook again"; return 1
}

nb_refresh() { # close both, copy strokes both ways, open both again; the leader stays on its
               # page and the other tablet is lined up when it reports (PENDING, as at open).
               # BS/BM/NB/MODE stay: the closes are expected (EXPDOC), book_end does not run.
    NB_REFRESHED=1
    nb_y=$(other "$LEAD")
    log "notebook: refresh (strokes to bring over)"
    nb_cl=0; nb_close "$LEAD" && nb_cl=1
    nb_cy=0; nb_close "$nb_y" && nb_cy=1
    sleep 3     # xochitl writes the open page when it closes
    ann_locked ann_sync "$BS" "$BM" both "$NBMAP"
    [ "$nb_cl" = 1 ] && nb_open "$LEAD"
    [ "$nb_cy" = 1 ] || return 0      # still open there: the leader's reports line it up
    PENDING=$nb_y; moved "$nb_y"
    nb_open "$nb_y" || PENDING=""
}

nb_merge() { # a pair never shared (made in mirror mode): interleave the pages, originals kept
    nb_b=$D/merged/$(date +%Y%m%d-%H%M%S)
    nb_on sub notebook_copy "$DOC_sub" "$nb_b"
    nb_on main notebook_copy "$DOC_main" "$nb_b"
    nb_ns=$(nb_count "$PL_sub"); nb_nm=$(nb_count "$PL_main")
    nb_run "$(pm_merge "$PL_sub" "$PL_main" "$BOOK_LEFT")"; nb_r=$?
    nb_lists || return 1
    [ "$nb_r" = 0 ] || { log "notebook: merge of '$NBNAME' stopped (originals in $nb_b on each tablet)"; return 1; }
    log "merged '$NBNAME': $nb_nm + $nb_ns pages -> $(nb_count "$PL_main") (originals in $nb_b on each tablet)"
}

nb_ready() { # the pair is open on both: same pages (merge the first time), then strokes
    [ "$DOC_sub" = "$BS" ] && [ "$DOC_main" = "$BM" ] || return 1
    nb_lists || return 1
    NBMAP=$D/pagemap/$BS
    if ! nb_mapok; then
        [ -f "$NBMAP" ] && mv "$NBMAP" "$NBMAP.old"
        echo "doc $BS $BM" > "$NBMAP"
        if [ -f "$D/created.$BS" ] || [ -f "$D/created.$BM" ]; then
            echo "${PL_sub%%,*} ${PL_main%%,*}" >> "$NBMAP"     # a new notebook: its first pages
        else
            nb_merge || return 1
        fi
        rm -f "$D/created.$BS" "$D/created.$BM"
    fi
    nb_sync "$LEAD" || return 1
    [ "$NB_REFRESHED" = 1 ] && return 0
    [ -n "$(nb_differs "$PL_sub")" ] && nb_refresh
    return 0
}

# ---------------------------------------------------------------- PAGES: pages changed on x
nb_diff() { # list-a list-b -> the ids of a that are not in b, comma-separated
    echo "$1" | tr , '\n' | awk -v B="$2" 'BEGIN { n = split(B, b, ","); for (i = 1; i <= n; i++) h[b[i]] = 1 }
        $0 != "" && !($0 in h)' | tr '\n' , | sed 's/,$//'
}

nb_spread_add() { # x old new: pages added on x become a whole spread there -> NB_SHOW
    nb_ops=$(pm_spread_add "$2" "$3")
    nb_first=$(nb_diff "$3" "$2"); nb_first=${nb_first%%,*}
    nb_to=$(echo "$nb_ops" | sed -n 's/^order //p'); nb_pad=$(echo "$nb_ops" | sed -n 's/^pad //p')
    if [ -n "$nb_to" ]; then
        req "$1" reorder "$(pm_perm "$3" "$nb_to")" >/dev/null; nb_quiet
    fi
    if [ -n "$nb_pad" ]; then
        req "$1" addpage "$nb_pad" "$(nb_tpl "$1" "$nb_first")" >/dev/null; nb_quiet
    fi
    nb_lists || return 1
    NB_SHOW=$(get PL "$1" | tr , '\n' | grep -nxF "$nb_first" | cut -d: -f1)
    [ -n "$NB_SHOW" ] && NB_SHOW=$((NB_SHOW - 1))
    log "$1: page(s) added -> a spread at page $NB_SHOW"
}

nb_blank_both() { # x id8-list (x's ids) -> those blank on both tablets (no strokes on either)
    nb_y=$(other "$1")
    nb_bx=$(nb_on "$1" pages_blank "$(get DOC "$1")" "$2" | tr '\n' ,)
    # a partner without mapping: unknown on y, so not taken as blank (it is kept)
    nb_py=$(pm_translate "$2" "$NBMAP" "$nb_y" 2>/dev/null) || return 0
    nb_by=$(nb_on "$nb_y" pages_blank "$(get DOC "$nb_y")" "$nb_py" | tr '\n' ,)
    awk -v X="$2" -v Y="$nb_py" -v BX=",$nb_bx" -v BY=",$nb_by" 'BEGIN {
        n = split(X, x, ","); split(Y, y, ","); o = ""
        for (i = 1; i <= n; i++) if (index(BX, "," x[i] ",") && index(BY, "," y[i] ",")) o = o "," x[i]
        if (o != "") print substr(o, 2) }'
}

nb_spread_del() { # x old new: a deleted page's partner goes too if blank, else gets a blank page
    nb_gone=$(nb_diff "$2" "$3")
    nb_part=$(echo "$2" | tr , '\n' | awk -v G="$nb_gone" '
        BEGIN { n = split(G, g, ","); for (i = 1; i <= n; i++) d[g[i]] = 1 }
        { p[NR] = $0 } END { for (i = 1; i <= NR; i++) if (p[i] in d) {
            j = (i % 2) ? i + 1 : i - 1; if (j <= NR && !(p[j] in d)) print p[j] } }' | tr '\n' , | sed 's/,$//')
    nb_blank=""; [ -n "$nb_part" ] && nb_blank=$(nb_blank_both "$1" "$nb_part")
    nb_ops=$(pm_spread_del "$2" "$3" "$nb_blank")
    nb_d=$(echo "$nb_ops" | sed -n 's/^del //p')
    if [ -n "$nb_d" ]; then
        req "$1" delpages "$nb_d" >/dev/null && log "$1: blank partner page(s) deleted too"; nb_quiet
    fi
    for nb_a in $(echo "$nb_ops" | sed -n 's/^add //p'); do
        req "$1" addpage "$nb_a" >/dev/null && log "$1: blank page at $nb_a keeps the spreads"; nb_quiet
    done
    nb_lists
}

on_pages() { # side uuid list: pages added, moved or deleted on x
    x=$1; [ "$2" = "$(get DOC "$x")" ] || return
    [ "$NB" = 1 ] && [ "$MODE" = book ] && [ -z "$PENDING" ] && [ "$LINK" = 1 ] || return
    old=$(get PL "$x")
    [ -n "$old" ] && [ "$3" != "$old" ] || return
    # the report may be from before our own last change: what x has now decides
    r=$(req "$x" pages) || return
    new=${r%% *}
    [ -n "$new" ] && [ "$new" != "$old" ] || return
    y=$(other "$x")
    added=$(nb_diff "$new" "$old"); gone=$(nb_diff "$old" "$new")
    NB_SHOW=""
    # spread rules only for pages the user added or deleted alone: a reorder, or adds and
    # deletes together, are only followed. Pages the sync added are in PL already: not "added".
    if [ -n "$added" ] && [ -z "$gone" ]; then nb_spread_add "$x" "$old" "$new" || return
    elif [ -n "$gone" ] && [ -z "$added" ]; then nb_spread_del "$x" "$old" "$new" || return
    fi
    nb_sync "$x" || { log "notebook: pages not in step (see above)"; return; }
    # pages that changed side: refresh when their strokes differ between the tablets
    sides=$(pm_sides "$old" "$(get PL "$x")")
    [ "$x" = main ] && [ -n "$sides" ] && sides=$(pm_translate "$sides" "$NBMAP" sub 2>/dev/null)
    if [ -n "$sides" ] && [ -n "$(nb_differs "$sides")" ]; then
        LEAD=$x; nb_refresh
        return
    fi
    # both tablets on the spread to show: the new one, or where x is now
    nb_where "$x"
    if [ -n "$NB_SHOW" ]; then s=$(spread "$NB_SHOW"); else s=$(spread "$(get CP "$x")"); fi
    [ "$s" -ge 0 ] 2>/dev/null || s=0
    nb_c=$(nb_count "$(get PL "$x")")
    put PC "$x" "$nb_c"; put PC "$y" "$nb_c"
    put CP "$y" -1      # unknown after our changes there: goto always goes
    goto "$x" "$(rolepage "$x" "$s")"; goto "$y" "$(rolepage "$y" "$s")"
    log "notebook: spread $s on both"
}
