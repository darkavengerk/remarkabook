# dual-rM: find the main on the WiFi network the sub is on, without a fixed address.
# Sourced by dualrm-sync.sh (needs D and KEY).
#
# Every host on the network answers a ping to ff02::1 (IPv6 all-nodes) on wlan0. The sub
# tries its key on each one: only the main accepts it, and the main's /etc/machine-id must
# match $D/main.id (written by install.sh and at link up; when missing, the first host that
# accepts the key is taken and its id saved). The link then runs over the main's link-local
# address (fe80::...%wlan0), so it does not matter which IPv4 address the network gave it.
# Networks that isolate clients (most public WiFi) block this: use a phone hotspot.
#
#   discover_main  -> 0 and DISC_FOUND="fe80::...%wlan0", or 1 (nothing found / not due yet)
DISC_IF=wlan0
DISC_TIMEOUT=${DISC_TIMEOUT:-8}  # s: a host that does not finish ssh by then is skipped (not marked)
DISC_BAD=""                      # addresses that refused the key or are another tablet
DISC_WAIT=0; DISC_NEXT=0         # back-off after a miss: 5, 10, 20, 30 s
DISC_FOUND=""; DISC_ID=""

disc_now() { read -r _up _ < /proc/uptime; DISC_T=${_up%.*}; }

disc_own() { ip -6 addr show "$DISC_IF" 2>/dev/null | sed -n 's/.*inet6 \(fe80:[0-9a-f:]*\)\/.*/\1/p' | head -n 1; }

disc_candidates() { # own-address -> responders to the all-nodes ping, minus own and DISC_BAD
    ping6 -c 2 -w 3 "ff02::1%$DISC_IF" 2>/dev/null \
        | sed -n 's/.* from \(fe80:[0-9a-f:]*[0-9a-f]\): seq.*/\1/p' | sort -u \
        | while read -r _c; do
            [ "$_c" = "$1" ] && continue
            case " $DISC_BAD " in *" $_c "*) continue ;; esac
            echo "$_c"
        done
}

disc_id() { # address -> 0 and DISC_ID (machine-id) when the host accepts the sub's key;
            # 2 when it did not finish within DISC_TIMEOUT (busy, waking up: try again later)
    DISC_ID=""
    rm -f "$D/disc.out" "$D/disc.to"
    ssh -y -i "$KEY" "root@$1%$DISC_IF" cat /etc/machine-id < /dev/null > "$D/disc.out" 2>/dev/null &
    _p=$!
    ( sleep "$DISC_TIMEOUT"; kill -0 $_p 2>/dev/null && { : > "$D/disc.to"; kill $_p 2>/dev/null; } ) &
    _w=$!
    wait $_p 2>/dev/null
    kill $_w 2>/dev/null
    [ -f "$D/disc.to" ] && return 2
    read -r DISC_ID < "$D/disc.out" 2>/dev/null
    [ ${#DISC_ID} = 32 ]
}

discover_main() {
    DISC_FOUND=""
    disc_now
    [ "$DISC_T" -ge "$DISC_NEXT" ] || return 1
    _own=$(disc_own)
    if [ -n "$_own" ]; then
        _want=$(cat "$D/main.id" 2>/dev/null)
        for _a in $(disc_candidates "$_own"); do
            disc_id "$_a"; _r=$?
            [ $_r = 2 ] && continue
            if [ $_r = 0 ] && { [ -z "$_want" ] || [ "$DISC_ID" = "$_want" ]; }; then
                [ -n "$_want" ] || echo "$DISC_ID" > "$D/main.id"
                DISC_FOUND="$_a%$DISC_IF"; DISC_WAIT=0; DISC_NEXT=0
                return 0
            fi
            DISC_BAD="$DISC_BAD $_a"
        done
    fi
    case $DISC_WAIT in 0) DISC_WAIT=5 ;; 5) DISC_WAIT=10 ;; 10) DISC_WAIT=20 ;; *) DISC_WAIT=30 ;; esac
    DISC_NEXT=$((DISC_T + DISC_WAIT))
    return 1
}
