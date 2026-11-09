# dual-rM: page structure of shared notebooks (pure functions: no tablets, no files but the map).
# Sourced by dualrm-sync.sh (through dualrm-notebook.sh) and by tests/pagemap.test.sh.
#
# Each tablet keeps its own page ids. A pair's map, $D/pagemap/<sub notebook id>, says which
# pages are the same page:
#   doc <sub notebook id> <main notebook id>     (first line)
#   <sub page id8> <main page id8>               (one line per page; id8 = first 8 characters)
# Page lists are comma-separated id8s in page order ("" = no pages).
#
#   pm_plan <sublist> <mainlist> <mapfile> <leader>
#       what to do so both tablets have the same pages, in the leader's order. Prints, in order:
#         del <side> <i,j,...>            delete these indices (current list of side)
#         add <side> <index> <partner>    add a blank page on side at index; partner: the id8 of
#                                         the same page on the other side
#       A mapped page missing on one side is deleted on the other; a page without mapping is
#       added on the other side (the follower's new pages after their predecessor). Adds come
#       in ascending index order: run them in that order, after the deletes. The follower's
#       order is fixed afterwards with pm_perm.
#       Preconditions: both lists non-empty, else exit 1 with no output (a failed `pages` query
#       must not mean "all deleted"). del indices are descending (delete in this order). add
#       indices on the follower side are positions in the leader's final order (the follower's
#       real order is fixed afterwards with pm_perm).
#   pm_merge <sublist> <mainlist> <left>
#       interleave two notebooks that were never shared: left side's page i at 2i, the other
#       side's page i at 2i+1; missing pages are blank. Prints "add <side> <index> <partner>",
#       partner "=<row>" when the page is new on both sides (same row: map the two together).
#   pm_perm <fromlist> <tolist>   -> "i0,i1,..." (page at position j of tolist was at i_j of
#                                    fromlist); nothing when equal; exit 1 when the sets differ
#                                    or an id repeats
#   pm_translate <list> <mapfile> <to>  -> the list in the other side's ids (to: sub | main);
#                                    1 when a page has no mapping
#   pm_spread_add <old> <new>     pages added on one tablet become a whole spread after the
#                                 spread holding the page they follow. Prints
#                                   order <list>   reorder to this list (only when it differs)
#                                   pad <index>    then add one blank page there (odd count)
#   pm_spread_del <old> <new> <blanklist>
#                                 a deleted page's spread partner goes too when it is blank
#                                 (blanklist), otherwise a blank page takes the deleted page's
#                                 place. Prints "del <i,j,...>" (indices in new) and/or
#                                 "add <index>" lines (ascending, after the delete)
#       Preconditions of both pm_spread_*: old count even (not checked), only adds (or only deletes), no
#       reorder (else no output: no plan). pm_spread_add gathers scattered added pages
#       into one block.
#   pm_sides <old> <new>          the pages whose side (left / right) changed
#   pm_differ <subann> <mainann> <mapfile> <sublist>
#                                 ann_list outputs of both notebooks: the sub id8s in sublist
#                                 whose strokes (.rm md5) differ between the tablets

pm_plan() {
    [ -n "$1" ] && [ -n "$2" ] || return 1       # an empty list is a failed query, not "all deleted"
    awk -v S="$1" -v M="$2" -v L="$4" '
        function split_list(s, a,    n) { if (s == "") return 0; return split(s, a, ",") }
        BEGIN {
            ns = split_list(S, s); nm = split_list(M, m)
            for (i = 1; i <= ns; i++) ps[s[i]] = i
            for (i = 1; i <= nm; i++) pm[m[i]] = i
        }
        $1 == "doc" { next }
        NF == 2 { sm[$1] = $2; ms[$2] = $1 }
        END {
            # deletes: a mapped page gone on one side goes on the other
            for (a in sm) {
                b = sm[a]
                if ((a in ps) && !(b in pm)) { ds[ps[a]] = 1; gone[a] = 1 }
                if ((b in pm) && !(a in ps)) { dm[pm[b]] = 1; gone[b] = 1 }
            }
            dsub = ""; for (i = ns; i >= 1; i--) if (i in ds) dsub = dsub "," (i - 1)
            dmain = ""; for (i = nm; i >= 1; i--) if (i in dm) dmain = dmain "," (i - 1)
            if (dsub != "") print "del sub " substr(dsub, 2)
            if (dmain != "") print "del main " substr(dmain, 2)
            # leader rows, then the follower pages that are new after their predecessor
            if (L == "sub") { nl = ns; for (i = 1; i <= ns; i++) ld[i] = s[i]; nf = nm; for (i = 1; i <= nm; i++) fl[i] = m[i]; for (k in sm) lf[k] = sm[k]; for (k in ms) fm[k] = ms[k] }
            else            { nl = nm; for (i = 1; i <= nm; i++) ld[i] = m[i]; nf = ns; for (i = 1; i <= ns; i++) fl[i] = s[i]; for (k in ms) lf[k] = ms[k]; for (k in sm) fm[k] = sm[k] }
            F = (L == "sub") ? "main" : "sub"
            # follower pages without mapping, grouped after the last mapped follower page before them
            anchor = "^"
            for (i = 1; i <= nf; i++) {
                f = fl[i]
                if (f in gone) continue
                if (f in fm) { anchor = fm[f]; continue }
                after[anchor] = after[anchor] "," f
            }
            k = 0
            n = split(substr(after["^"], 2), hd, ",")
            for (j = 1; j <= n; j++) { if (hd[j] != "") { print "add " L " " k " " hd[j]; k++ } }
            for (i = 1; i <= nl; i++) {
                r = ld[i]
                if (!(r in gone)) {
                    if (!(r in lf)) print "add " F " " k " " r
                    k++
                }
                n = split(substr(after[r], 2), af, ",")
                for (j = 1; j <= n; j++) { if (af[j] != "") { print "add " L " " k " " af[j]; k++ } }
            }
        }' "$3"
}

pm_merge() {
    awk -v S="$1" -v M="$2" -v LEFT="$3" '
        function split_list(s, a) { if (s == "") return 0; return split(s, a, ",") }
        BEGIN {
            ns = split_list(S, s); nm = split_list(M, m)
            if (LEFT == "sub") { nl = ns; for (i = 1; i <= ns; i++) l[i] = s[i]; nr = nm; for (i = 1; i <= nm; i++) r[i] = m[i]; R = "main" }
            else               { nl = nm; for (i = 1; i <= nm; i++) l[i] = m[i]; nr = ns; for (i = 1; i <= ns; i++) r[i] = s[i]; R = "sub" }
            n = nl > nr ? nl : nr
            for (i = 1; i <= n; i++) {
                k = 2 * (i - 1)
                # row k: left page i (blank on the right side)
                if (i <= nl) print "add " R " " k " " l[i]
                else { print "add " LEFT " " k " =" k; print "add " R " " k " =" k }
                # row k+1: right page i (blank on the left side)
                if (i <= nr) print "add " LEFT " " (k + 1) " " r[i]
                else { print "add " LEFT " " (k + 1) " =" (k + 1); print "add " R " " (k + 1) " =" (k + 1) }
            }
        }' | sort -k2,2 -k3,3n
}

pm_perm() {
    [ "$1" = "$2" ] && return 0
    awk -v A="$1" -v B="$2" 'BEGIN {
        na = split(A, a, ","); nb = split(B, b, ",")
        if (na != nb) exit 1
        for (i = 1; i <= na; i++) { if (a[i] in p) exit 1; p[a[i]] = i - 1 }
        o = ""
        for (j = 1; j <= nb; j++) { if (!(b[j] in p) || (b[j] in used)) exit 1; used[b[j]] = 1; o = o "," p[b[j]] }
        print substr(o, 2)
    }'
}

pm_translate() {
    awk -v A="$1" -v TO="$3" '
        $1 == "doc" { next }
        NF == 2 { if (TO == "main") t[$1] = $2; else t[$2] = $1 }
        END {
            if (A == "") exit 0
            n = split(A, a, ","); o = ""
            for (i = 1; i <= n; i++) { if (!(a[i] in t)) exit 1; o = o "," t[a[i]] }
            print substr(o, 2)
        }' "$2"
}

pm_spread_add() {
    awk -v O="$1" -v N="$2" 'BEGIN {
        no = split(O, o, ","); nn = split(N, n, ",")
        for (i = 1; i <= no; i++) had[o[i]] = 1
        for (j = 1; j <= nn; j++) inn[n[j]] = 1
        for (i = 1; i <= no; i++) if (!(o[i] in inn)) exit 0     # pages deleted too: not a pure add
        nb = 0; first = 0; nk = 0
        for (j = 1; j <= nn; j++) {
            if (n[j] in had) { keep[++nk] = n[j]; continue }
            blk[++nb] = n[j]; if (!first) { first = j; pre = nk }
        }
        if (nb == 0) exit 0
        for (i = 1; i <= nk; i++) if (keep[i] != o[i]) exit 0   # reordered too: no plan
        # pre = kept pages before the first added one; the block goes after their spread
        b = (pre == 0) ? 0 : 2 * int((pre - 1) / 2) + 2
        if (b > nk) b = nk
        t = ""
        for (i = 1; i <= nk; i++) {
            if (i - 1 == b) for (j = 1; j <= nb; j++) t = t "," blk[j]
            t = t "," keep[i]
        }
        if (b == nk) for (j = 1; j <= nb; j++) t = t "," blk[j]
        t = substr(t, 2)
        if (t != N) print "order " t
        if (nb % 2) print "pad " (b + nb)
    }'
}

pm_spread_del() {
    awk -v O="$1" -v N="$2" -v B="$3" 'BEGIN {
        no = split(O, o, ","); nn = split(N, n, ",")
        for (j = 1; j <= nn; j++) { pn[n[j]] = j - 1 }
        for (i = 1; i <= no; i++) had[o[i]] = 1
        for (j = 1; j <= nn; j++) if (!(n[j] in had)) exit 0     # pages added too: not a delete
        k2 = 0; for (i = 1; i <= no; i++) if (o[i] in pn) { if (n[++k2] != o[i]) exit 0 }   # reordered: no plan
        nbl = split(B, bl, ","); for (i = 1; i <= nbl; i++) blank[bl[i]] = 1
        dels = ""; nf = 0; any = 0
        for (i = 1; i <= no; i += 2) {
            a = o[i]; b = (i + 1 <= no) ? o[i + 1] : ""
            ka = (a in pn); kb = (b != "" && (b in pn))
            if (!ka || (b != "" && !kb)) any = 1
            if (ka && kb) { f[++nf] = a; f[++nf] = b; continue }
            if (!ka && !kb) continue
            if (b == "") { if (ka) f[++nf] = a; continue }
            k = ka ? a : b                     # the partner that survived
            if (k in blank) { dels = dels "," pn[k]; continue }
            if (ka) { f[++nf] = a; f[++nf] = "+" } else { f[++nf] = "+"; f[++nf] = b }
        }
        if (!any) exit 0
        if (dels != "") print "del " substr(dels, 2)
        for (i = 1; i <= nf; i++) if (f[i] == "+") print "add " (i - 1)
    }'
}

pm_differ() {
    awk -v W="$4" '
        FILENAME == ARGV[1] { if ($1 != "doc" && NF == 2) ms[$2] = $1; next }
        $1 == "F" && $2 == "rm" {
            id = substr($3, 1, 8)
            if (FILENAME == ARGV[2]) hs[id] = $5
            else if (id in ms) hm[ms[id]] = $5
        }
        END {
            n = split(W, w, ",")
            for (i = 1; i <= n; i++) if (hs[w[i]] != hm[w[i]]) print w[i]
        }' "$3" "$1" "$2"
}

pm_sides() { # <old> <new> -> the pages (in new) whose side changed: left <-> right
    awk -v A="$1" -v B="$2" 'BEGIN {
        na = split(A, a, ","); nb = split(B, b, ",")
        for (i = 1; i <= na; i++) p[a[i]] = i
        o = ""
        for (j = 1; j <= nb; j++) if ((b[j] in p) && (p[b[j]] - j) % 2) o = o "," b[j]
        if (o != "") print substr(o, 2)
    }'
}
