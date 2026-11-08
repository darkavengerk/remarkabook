# dual-rM: find the main on the WiFi network the sub is on, without a fixed address.
# Sourced by dualrm-sync.sh (needs D, KEY and log). Call discover_main from one shell only:
# its state (back-off, bad list) lives in variables of that shell.
#
# Every host on the network answers a ping to ff02::1 (IPv6 all-nodes) on wlan0. The sub
# logs in to each one with its key and reads /home/root/dualrm/node.id (a random id the main
# keeps); the answer must match $D/main.id, written by install.sh and at every link up. The
# id only travels inside ssh, so a host that is not the main cannot give it: this is what
# tells the main apart. No main.id: discovery is off (no host is taken on trust).
# The link then runs over the main's link-local address (fe80::...%wlan0), so it does not
# matter which IPv4 address the network gave it.
# Networks that isolate clients (most public WiFi) block this: use a phone hotspot.
#
#   discover_main  -> 0 and DISC_FOUND="fe80::...%wlan0", or 1 (nothing found / not due yet)
DISC_IF=wlan0
DISC_TIMEOUT=${DISC_TIMEOUT:-8}  # s: a host that does not finish ssh by then is not the main
DISC_FORGET=${DISC_FORGET:-180}  # s: the bad list is dropped this long after its first entry
DISC_BAD=""; DISC_BAD_T=0        # addresses that were not the main, since DISC_BAD_T
DISC_WAIT=0; DISC_NEXT=0         # back-off after a miss: 5, 10, 20, 30 s
DISC_FOUND=""; DISC_ID=""; DISC_OFF=0

disc_now() { read -r _up _ < /proc/uptime; DISC_T=${_up%.*}; }

disc_own() { ip -6 addr show "$DISC_IF" 2>/dev/null | sed -n 's/.*inet6 \(fe80:[0-9a-f:]*\)\/.*/\1/p' | head -n 1; }

disc_candidates() { # own-address -> responders to the all-nodes ping, minus own and DISC_BAD
    # no -c: the sub's own reply would end a count of 2 after about a second
    ping6 -w 2 "ff02::1%$DISC_IF" 2>/dev/null \
        | sed -n 's/.* from \(fe80:[0-9a-f:]*[0-9a-f]\): seq.*/\1/p' | sort -u \
        | while read -r _c; do
            [ "$_c" = "$1" ] && continue
            case " $DISC_BAD " in *" $_c "*) continue ;; esac
            echo "$_c"
        done
}

disc_id() { # address -> DISC_ID: what the host answered for node.id ("" when it refused the
            # key, asked for a password or did not finish within DISC_TIMEOUT)
    DISC_ID=""
    rm -f "$D/disc.out"; : > "$D/disc.err"
    ssh -y -o DisableTrivialAuth=yes -i "$KEY" "root@$1%$DISC_IF" cat /home/root/dualrm/node.id \
        < /dev/null > "$D/disc.out" 2> "$D/disc.err" &
    _p=$!
    # Polled here, no watcher subshell: busybox ash can run the parent's EXIT trap in a forked
    # child that is killed early. dropbear's client has no BatchMode: when the key is refused
    # it asks for a password, so a prompt ends the probe at once.
    _i=0
    while kill -0 $_p 2>/dev/null; do
        if grep -qi password "$D/disc.err" 2>/dev/null || [ $_i -ge $((DISC_TIMEOUT * 5)) ]; then
            kill $_p 2>/dev/null; wait $_p 2>/dev/null; return
        fi
        usleep 200000
        _i=$((_i + 1))
    done
    wait $_p 2>/dev/null
    [ -f "$D/disc.out" ] && read -r DISC_ID < "$D/disc.out"
}

discover_main() {
    DISC_FOUND=""
    _want=""; [ -f "$D/main.id" ] && read -r _want < "$D/main.id"
    if [ ${#_want} != 32 ]; then
        [ $DISC_OFF = 1 ] || log "discovery off: no main.id (install.sh or one USB link writes it)"
        DISC_OFF=1
        return 1
    fi
    disc_now
    [ "$DISC_T" -ge "$DISC_NEXT" ] || return 1
    # forget the bad list after a while: a main that was still booting is tried again
    [ -n "$DISC_BAD" ] && [ $((DISC_T - DISC_BAD_T)) -ge "$DISC_FORGET" ] && DISC_BAD=""
    _own=$(disc_own)
    if [ -n "$_own" ]; then
        for _a in $(disc_candidates "$_own"); do
            disc_id "$_a"
            if [ "$DISC_ID" = "$_want" ]; then
                DISC_FOUND="$_a%$DISC_IF"; DISC_WAIT=0; DISC_NEXT=0
                return 0
            fi
            [ -n "$DISC_ID" ] && log "discovery: $_a answered another id"
            [ -n "$DISC_BAD" ] || DISC_BAD_T=$DISC_T
            DISC_BAD="$DISC_BAD $_a"
        done
    fi
    case $DISC_WAIT in 0) DISC_WAIT=5 ;; 5) DISC_WAIT=10 ;; 10) DISC_WAIT=20 ;; *) DISC_WAIT=30 ;; esac
    DISC_NEXT=$((DISC_T + DISC_WAIT))
    return 1
}
