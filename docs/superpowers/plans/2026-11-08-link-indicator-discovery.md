# Link Indicator and WiFi Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Both tablets show `● USB` / `● WiFi` at the top right while linked, and the sub finds the main on any shared WiFi network without a fixed address.

**Architecture:** A new xochitl patch command `link <usb|wifi|->` drives an overlay `Rectangle` in MainView; the sub sends it to both tablets on link up / link down, and the main's link end clears it when the session ends (now also after 75 s of silence). Discovery lives in a new sourced file `sub/dualrm-discover.sh`: ping the IPv6 all-nodes group on `wlan0`, try the sub's key on each responder, accept the one whose `/etc/machine-id` matches `$D/main.id`, connect over its link-local address.

**Tech Stack:** POSIX sh (busybox ash on the tablets: 1.36 on the sub, 1.37 on the main), dropbear client `ssh`, QML (xochitl via xovi qt-resource-rebuilder `.qmd`).

Spec: `docs/superpowers/specs/2026-11-08-link-indicator-discovery-design.md`.

**Ground rules for every task**
- Tablets: sub `root@192.168.219.112` (3.23), main `root@192.168.219.114` (3.29). Do NOT run `install.sh`, restart services or write outside `/tmp` on them: deploying is the user's step. Running a test from `/tmp` on the sub is fine.
- The sub's busybox has no `timeout` applet. Use only applets that exist (checked: `sed sort read -t kill wait sleep usleep mktemp`).
- Commit after each task with the repo's message style (plain imperative subject, e.g. "Turn book-mode pages in one step"), ending with the attribution lines from your own system reminder.

---

### Task 1: Discovery module

**Goal:** `sub/dualrm-discover.sh` provides `discover_main`, which finds the main among IPv6 all-nodes responders on `wlan0`, with back-off and a list of hosts known not to be the main.

**Files:**
- Create: `sub/dualrm-discover.sh`
- Create: `tests/discover.test.sh`

**Acceptance Criteria:**
- [ ] With no `$D/main.id`, the first responder that returns a 32-char machine-id becomes the main; `DISC_FOUND=<addr>%wlan0`, id saved to `$D/main.id`.
- [ ] With `$D/main.id`, a responder with a different id is not accepted and is added to `DISC_BAD`.
- [ ] The sub's own link-local address is never tried; addresses in `DISC_BAD` are not tried again.
- [ ] A host that does not answer within `DISC_TIMEOUT` is not added to `DISC_BAD`.
- [ ] After a miss, the next attempt is skipped until 5, then 10, 20, 30, 30 s later; a hit resets the back-off.
- [ ] No `wlan0` link-local address: no ping is sent, returns 1.
- [ ] Tests pass under PC `sh` and under the sub's busybox `sh`.

**Verify:** `sh tests/discover.test.sh` → every line starts with `ok`, last line `PASS`

**Steps:**

- [ ] **Step 1: Write the failing test** `tests/discover.test.sh`

```sh
#!/bin/sh
# Test for sub/dualrm-discover.sh, no network needed (ssh, ping6, ip are stubbed).
#   sh tests/discover.test.sh            on the PC
#   (on the sub's busybox: see the plan, Task 1 Step 5)
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
D=$T; KEY=$T/key
FAIL=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; FAIL=1; fi; }

. ./sub/dualrm-discover.sh

MAINID=0123456789abcdef0123456789abcdef
OWN=fe80::1
ip() { [ -n "$OWN" ] && echo "    inet6 $OWN/64 scope link "; }
RESP="fe80::1 fe80::aa fe80::bb"
PINGS=0
ping6() {
    PINGS=$((PINGS + 1)); echo "$PINGS" > "$T/pings"
    for a in $RESP; do echo "64 bytes from $a: seq=0 ttl=64 time=1.000 ms (DUP!)"; done
}
# fe80::aa refuses the key, fe80::bb is the main, fe80::cc never answers
ssh() {
    shift 3; h=${1#root@}; h=${h%\%*}; echo "$h" >> "$T/ssh.log"
    case "$h" in
        fe80::bb) echo "$MAINID" ;;
        fe80::cc) sleep 5 ;;
        *) return 1 ;;
    esac
}
T_NOW=100; disc_now() { DISC_T=$T_NOW; }
tries() { cat "$T/ssh.log" 2>/dev/null | wc -l | tr -d ' '; }

# 1. no main.id: first host that accepts the key is the main
discover_main; r=$?
check "found (no main.id)" "$r $DISC_FOUND" "0 fe80::bb%wlan0"
check "main.id saved" "$(cat "$T/main.id")" "$MAINID"
check "own address never tried" "$(grep -c '^fe80::1$' "$T/ssh.log")" 0
check "refusing host marked bad" "$DISC_BAD" " fe80::aa"
check "back-off reset on hit" "$DISC_WAIT $DISC_NEXT" "0 0"

# 2. main.id set to another tablet: bb is not accepted
echo ffffffffffffffffffffffffffffffff > "$T/main.id"
DISC_BAD=""; : > "$T/ssh.log"
discover_main; r=$?
check "wrong id not accepted" "$r '$DISC_FOUND'" "1 ''"
check "wrong id marked bad" "$DISC_BAD" " fe80::aa fe80::bb"
check "first back-off 5 s" "$DISC_WAIT $DISC_NEXT" "5 105"

# 3. back-off: nothing tried before DISC_NEXT, then 10, 20, 30, 30
: > "$T/ssh.log"; echo 0 > "$T/pings"; PINGS=0
T_NOW=104; discover_main
check "skipped before DISC_NEXT" "$(cat "$T/pings")" 0
T_NOW=105; discover_main
check "second back-off 10 s" "$DISC_WAIT $DISC_NEXT" "10 115"
check "bad hosts not tried again" "$(tries)" 0
T_NOW=115; discover_main; check "third back-off 20 s" "$DISC_WAIT" 20
T_NOW=135; discover_main; check "back-off capped 30 s" "$DISC_WAIT" 30
T_NOW=165; discover_main; check "back-off stays 30 s" "$DISC_WAIT" 30

# 4. silent host is not marked bad
DISC_BAD=""; DISC_NEXT=0; DISC_WAIT=0; RESP="fe80::cc"; DISC_TIMEOUT=1
discover_main
check "silent host not marked bad" "'$DISC_BAD'" "''"

# 5. no link-local address on wlan0 (WiFi off): no ping
OWN=""; DISC_NEXT=0; echo 0 > "$T/pings"; PINGS=0
discover_main; r=$?
check "wifi off: returns 1" "$r" 1
check "wifi off: no ping" "$(cat "$T/pings")" 0

[ $FAIL = 0 ] && echo PASS || { echo FAILED; exit 1; }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh tests/discover.test.sh`
Expected: error `./sub/dualrm-discover.sh: No such file or directory` (non-zero exit).

- [ ] **Step 3: Write the module** `sub/dualrm-discover.sh`

```sh
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
```

Note: `discover_main` must run in the shell that keeps its state (`DISC_BAD`, `DISC_WAIT`, `DISC_NEXT`); never call it inside `$(...)`.

- [ ] **Step 4: Run test to verify it passes**

Run: `sh tests/discover.test.sh`
Expected: all `ok`, last line `PASS`.

- [ ] **Step 5: Run the same test on the sub's busybox (from /tmp only)**

```sh
tar cf - sub/dualrm-discover.sh tests/discover.test.sh | ssh root@192.168.219.112 \
  'rm -rf /tmp/dt && mkdir /tmp/dt && cd /tmp/dt && tar xf - && sh tests/discover.test.sh; rm -rf /tmp/dt'
```
Expected: all `ok`, `PASS`. If the sub is unreachable, say so in the report instead.

- [ ] **Step 6: Commit**

```bash
git add sub/dualrm-discover.sh tests/discover.test.sh
git commit -m "Find the main on the WiFi network by IPv6 all-nodes ping"
```

---

### Task 2: Main link end: idle timeout and `link -`

**Goal:** `node/dualrm-link.sh` ends the session after `LINK_IDLE` (75) s without input and, on exit, posts one command `link -` (indicator off + page step 1) instead of `pagestep 1`.

**Files:**
- Modify: `node/dualrm-link.sh` (header comment, `cleanup`, read loop)
- Create: `tests/link.test.sh`

**Acceptance Criteria:**
- [ ] `CMD <nonce> <command>` lines still reach `$D/cmd` as `<nonce> <command>`.
- [ ] With no input for `LINK_IDLE` s the script exits, and `$D/cmd` holds `L<pid> link -`.
- [ ] `PING` lines are ignored (no `$D/cmd` change) but keep the session alive.

**Verify:** `sh tests/link.test.sh` → all `ok`, last line `PASS`

**Steps:**

- [ ] **Step 1: Write the failing test** `tests/link.test.sh`

```sh
#!/bin/sh
# Test for node/dualrm-link.sh on the PC: paths rewritten into a temp dir.
#   sh tests/link.test.sh
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d); trap 'kill $LP 2>/dev/null; rm -rf "$T"' EXIT
sed "s#/home/root/dualrm#$T#g" node/dualrm-lib.sh > "$T/dualrm-lib.sh"
sed "s#/home/root/dualrm#$T#g" node/dualrm-link.sh > "$T/link.sh"
FAIL=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; FAIL=1; fi; }
alive() { kill -0 "$LP" 2>/dev/null && echo yes || echo no; }

mkfifo "$T/in"; exec 5<> "$T/in"
LINK_IDLE=2 sh "$T/link.sh" <&5 > "$T/out" 2>/dev/null &
LP=$!
sleep 1
check "says HELLO" "$(head -n 1 "$T/out")" HELLO

echo "CMD n1 status" >&5; sleep 1
check "CMD forwarded" "$(cat "$T/cmd")" "n1 status"

echo PING >&5; sleep 1; echo PING >&5; sleep 1
check "PING keeps it alive" "$(alive)" yes
check "PING not forwarded" "$(cat "$T/cmd")" "n1 status"

sleep 3
check "exits after LINK_IDLE" "$(alive)" no
check "posts link - on exit" "$(cat "$T/cmd")" "L$LP link -"

[ $FAIL = 0 ] && echo PASS || { echo FAILED; exit 1; }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh tests/link.test.sh`
Expected: `FAIL exits after LINK_IDLE: got 'yes', want 'no'` and `FAIL posts link - on exit` (current script never times out and posts `pagestep 1`).

- [ ] **Step 3: Change `node/dualrm-link.sh`**

Header comment, replace the `stdin:` line block:

```sh
# stdout: this tablet's events ("EV DOC/PAGE/RESP ..."), "HELLO" once, "HB" every 30 s
# stdin:  "CMD <nonce> <command...>" from the sub, "PING" every 30 s (other lines are ignored);
#         nothing for LINK_IDLE s ends the session (the sub vanished without closing it)
#         find <parent|-> <type> <name...>, has <uuid>, fsize <file>, snap_docs, new_doc and power_key
#         are answered here from the files; everything else goes to xochitl.
. /home/root/dualrm/dualrm-lib.sh
mkfifos
LINK_IDLE=${LINK_IDLE:-75}
```

In `cleanup`, replace

```sh
    local_post "L$$ pagestep 1"     # the sub is gone: page turns step one page again
```

with

```sh
    local_post "L$$ link -"         # the sub is gone: indicator off, page turns step one page
```

Read loop, replace `while IFS= read -r l; do` with:

```sh
while IFS= read -r -t "$LINK_IDLE" l; do
```

- [ ] **Step 4: Run test to verify it passes**

Run: `sh tests/link.test.sh`
Expected: all `ok`, `PASS`.

- [ ] **Step 5: Check busybox `read -t` on the main (read-only)**

```sh
ssh root@192.168.219.114 'echo x | sh -c "IFS= read -r -t 1 l; echo rc=\$? l=\$l"; sleep 3 | sh -c "IFS= read -r -t 1 l; echo rc=\$?"'
```
Expected: `rc=0 l=x`, then a non-zero `rc=` after about 1 s (timeout), and no `illegal option`.

- [ ] **Step 6: Commit**

```bash
git add node/dualrm-link.sh tests/link.test.sh
git commit -m "Main link: end a silent session after 75 s, clear the link indicator"
```

---

### Task 3: Patch: `link` command and indicator

**Goal:** `node/xovi/dualrm.qmd` handles `link <usb|wifi|->` and draws a pill at the top right of MainView while linked.

**Files:**
- Modify: `node/xovi/dualrm.qmd` (header command list; `handle()`; new `Rectangle` after the `dualrmPoller` Item inside the same INSERT)

**Acceptance Criteria:**
- [ ] `link usb` / `link wifi` answers `ok usb` / `ok wifi` and shows the pill with `USB` / `WiFi`.
- [ ] `link -` answers `ok -`, hides the pill and sets `documentView.item.dualrmPageStep = 1` when a document view exists.
- [ ] Pill: white fill, 2 px black border, black dot + label, `z: 10000`, anchored top/right with 12 px margins, no MouseArea; hidden at start.
- [ ] The file still has balanced braces (`grep -o '{' | wc -l` equals `grep -o '}' | wc -l`).

**Verify:** `[ "$(grep -o '{' node/xovi/dualrm.qmd | wc -l)" = "$(grep -o '}' node/xovi/dualrm.qmd | wc -l)" ] && grep -c 'dualrmLink' node/xovi/dualrm.qmd` → a count ≥ 5. On-device rendering is checked in Task 6.

**Steps:**

- [ ] **Step 1: Header comment** — after the `pagestep <n>` entry (the 2-line comment ending `another document opens or the tablet wakes up)`), add:

```
;     link <usb|wifi|->       (linked to the other tablet over USB / WiFi: show the indicator at
;                              the top right; "-": hide it, page turns step one page again)
```

- [ ] **Step 2: Command in `handle()`** — insert directly before the `if (cmd === "import") {` block:

```qml
                        if (cmd === "link") {
                            const via = parts[2] || "-";
                            dualrmLink.via = via === "-" ? "" : via;
                            if (via === "-" && documentView.item) {
                                documentView.item.dualrmPageStep = 1;   // alone again
                            }
                            respond(nonce, "ok " + via);
                            return;
                        }
```

- [ ] **Step 3: Indicator** — the first AFFECT block ends like this (end of `handle()`, end of the `dualrmPoller` Item, end of INSERT):

```qml
                        respond(nonce, "error unknown-command " + cmd);
                    } catch (e) {
                        respond(nonce, "error exception " + e);
                    }
                }

            }
        }
    END TRAVERSE
```

Replace it with:

```qml
                        respond(nonce, "error unknown-command " + cmd);
                    } catch (e) {
                        respond(nonce, "error exception " + e);
                    }
                }

            }

            // link indicator: "● USB" / "● WiFi" while linked to the other tablet (command "link").
            // No input handlers: touches and pen go through to whatever is underneath.
            Rectangle {
                id: dualrmLink
                objectName: "dualrmLink"
                property string via: ""
                visible: via !== ""
                z: 10000
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.topMargin: 12
                anchors.rightMargin: 12
                width: dualrmLinkRow.implicitWidth + 28
                height: 44
                radius: 22
                color: "white"
                border.color: "black"
                border.width: 2
                Row {
                    id: dualrmLinkRow
                    anchors.centerIn: parent
                    spacing: 8
                    Rectangle {
                        width: 14
                        height: 14
                        radius: 7
                        color: "black"
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: dualrmLink.via === "usb" ? "USB" : "WiFi"
                        color: "black"
                        font.pixelSize: 24
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
        }
    END TRAVERSE
```

- [ ] **Step 4: Verify**

Run: `[ "$(grep -o '{' node/xovi/dualrm.qmd | wc -l)" = "$(grep -o '}' node/xovi/dualrm.qmd | wc -l)" ] && echo balanced; grep -c dualrmLink node/xovi/dualrm.qmd`
Expected: `balanced`, then a number ≥ 5.

- [ ] **Step 5: Commit**

```bash
git add node/xovi/dualrm.qmd
git commit -m "Patch: show a link indicator at the top right while linked"
```

---

### Task 4: Sync: transport, indicator commands, PING, discovery

**Goal:** `sub/dualrm-sync.sh` uses discovery after USB and `MAIN_LAN`, tells both tablets the link state with `link`, sends `PING` every 30 s, and saves the main's machine-id at link up.

**Files:**
- Modify: `sub/dualrm-sync.sh` (header comment; source discover module; `pick_main`; `link_loop`; new `save_main_id`; main loop start; `LINKUP`/`LINKDOWN`)

**Acceptance Criteria:**
- [ ] `pick_main` sets `MAIN`/`VIA` (no command substitution), order USB → `MAIN_LAN` → `discover_main`.
- [ ] HELLO produces `RM LINKUP usb` when `MAIN=10.11.99.1`, else `RM LINKUP wifi`.
- [ ] LINKUP: log `link up (<via>)`, `local_request link <via>`, `remote_request link <via>`, `save_main_id`, then `remote_request emit` as before.
- [ ] LINKDOWN: `local_request link -` always (replaces the book-only `pagestep 1`).
- [ ] At start, before `local_request emit`: `local_request link -`.
- [ ] A background loop writes `PING` to fd 4 every 30 s.
- [ ] `sh -n sub/dualrm-sync.sh` passes; `install.sh`'s `grep -q 'link up'` still matches the new log line.

**Verify:** `sh -n sub/dualrm-sync.sh && sh tests/discover.test.sh | tail -n 1` → `PASS`

**Steps:**

- [ ] **Step 1: Header comment** — replace the line
`# over one ssh session (USB first, then home WiFi) running node/dualrm-link.sh. Nothing polls:`
with
`# over one ssh session (USB first, then WiFi: MAIN_LAN or found, see dualrm-discover.sh) running`
`# node/dualrm-link.sh. Both tablets show a link indicator while it is up. Nothing polls:`

- [ ] **Step 2: Source the module** — directly after `[ -f "$D/dualrm.conf" ] && . "$D/dualrm.conf"` add:

```sh
. /home/root/dualrm/dualrm-discover.sh
```

- [ ] **Step 3: Replace `pick_main` and `link_loop`** (from `pick_main() {` through the closing `}` of `link_loop`) with:

```sh
pick_main() { # -> MAIN (address) and VIA (usb | wifi); MAIN empty when the main is not reachable.
              # Sets variables instead of printing: discover_main keeps state between calls.
    MAIN=""; VIA=""
    # USB link = a cdc_ether interface (USB-C in host mode, or the pogo pins)
    for n in /sys/class/net/*; do
        case "$(readlink "$n/device/driver" 2>/dev/null)" in
            *cdc_ether*)
                k=0
                while [ $k -lt 10 ]; do   # DHCP from the main can take a few seconds
                    if ping -c1 -W1 "$MAIN_USB" >/dev/null 2>&1; then MAIN=$MAIN_USB; VIA=usb; return; fi
                    k=$((k + 1))
                done ;;
        esac
    done
    if [ -n "$MAIN_LAN" ] && ping -c1 -W1 "$MAIN_LAN" >/dev/null 2>&1; then MAIN=$MAIN_LAN; VIA=wifi; return; fi
    if discover_main; then MAIN=$DISC_FOUND; VIA=wifi; log "found the main at $MAIN"; fi
}

link_loop() {
    while :; do
        pick_main
        if [ -z "$MAIN" ]; then sleep 5; continue; fi
        log "connecting to main at $MAIN"
        echo "$MAIN" > "$D/mainhost"
        # -I: drop the session when the main falls silent (it sends HB every 30 s)
        ssh -y -K 10 -I 75 -i "$KEY" "root@$MAIN" 'sh /home/root/dualrm/dualrm-link.sh' \
            < "$D/linkin" 2>>"$D/ssh.err" | while IFS= read -r l; do
            case "$l" in
                "EV RESP "*) printf '%s\n' "${l#EV RESP }" > "$D/rresponse" ;;
                EV\ *) printf 'RM %s\n' "${l#EV }" > "$D/events" ;;
                HELLO) echo "RM LINKUP $VIA" > "$D/events" ;;
            esac
        done
        echo "RM LINKDOWN" > "$D/events"
        log "link to $MAIN lost"
        sleep 3
    done
}

save_main_id() { # remember which tablet the main is, for discovery (install.sh writes it too)
    [ -s "$D/main.id" ] && return
    _id=$(mssh cat /etc/machine-id)
    [ ${#_id} = 32 ] && echo "$_id" > "$D/main.id"
}
```

`save_main_id` uses `mssh`, defined right after `link_loop`; both are only called later from the main loop, so the order of definitions is fine.

- [ ] **Step 4: Main loop start** — replace

```sh
link_loop &
log "sync v10 (event driven, both ways, copies PDFs and annotations, pens, notebook scroll, sleep)"
CLOSING_FROM=""
local_request emit >/dev/null
```

with

```sh
link_loop &
( while sleep 30; do echo PING >&4; done ) &   # keeps the main's link end from timing out
log "sync v11 (event driven, both ways, copies PDFs and annotations, pens, notebook scroll, sleep, link indicator, WiFi discovery)"
CLOSING_FROM=""
local_request link - >/dev/null   # no link yet (an indicator may be left from a killed sync)
local_request emit >/dev/null
```

- [ ] **Step 5: LINKUP / LINKDOWN** — replace

```sh
        LINKUP)
            LINK=1; AWAKE_main=1; log "link up"
            remote_request emit >/dev/null ;;
        LINKDOWN)
            # alone again: page turns step one page (the main's link end does the same there)
            [ "$MODE" = book ] && local_request pagestep 1 >/dev/null
            LINK=0; MODE=""; PENDING=""; CLOSING_FROM=""; BS=""; BM="" ;;
```

with

```sh
        LINKUP\ *)
            via=${body#LINKUP }
            LINK=1; AWAKE_main=1; log "link up ($via)"
            local_request link "$via" >/dev/null
            remote_request link "$via" >/dev/null
            save_main_id
            remote_request emit >/dev/null ;;
        LINKDOWN)
            # alone again: indicator off, page turns step one page (the main's link end does the
            # same there)
            local_request link - >/dev/null
            LINK=0; MODE=""; PENDING=""; CLOSING_FROM=""; BS=""; BM="" ;;
```

- [ ] **Step 6: Verify**

Run: `sh -n sub/dualrm-sync.sh && echo syntax-ok; grep -n 'RM LINKUP \$VIA\|LINKUP\\ \*)\|local_request link\|PING >&4\|dualrm-discover.sh' sub/dualrm-sync.sh`
Expected: `syntax-ok` and one match for each pattern (`local_request link` matches 3 times).

- [ ] **Step 7: Commit**

```bash
git add sub/dualrm-sync.sh
git commit -m "Sync: link indicator on both tablets, find the main on WiFi, keep-alive PING"
```

---

### Task 5: Install, config example, README

**Goal:** The installer ships the discovery module and writes `main.id`; docs say `MAIN_LAN` is optional, describe the indicator and the public-WiFi limit.

**Files:**
- Modify: `install.sh` (header comment, sub file list, after key authorization, final hint)
- Modify: `sub/dualrm.conf.example`
- Modify: `README.md` (Features, state table, Install step 2/3, Configuration, WiFi section, USB-cable bullet, Troubleshooting)

**Acceptance Criteria:**
- [ ] `install_node "$SUB"` list contains `dualrm-discover.sh`.
- [ ] After authorizing the key, `install.sh` writes the main's machine-id to the sub's `/home/root/dualrm/main.id` when it was read.
- [ ] No text says WiFi needs `MAIN_LAN` or that without it the tablets link only over USB.
- [ ] README mentions the indicator, discovery, and that public WiFi usually blocks it (phone hotspot).
- [ ] `sh -n install.sh` passes.

**Verify:** `sh -n install.sh && grep -c dualrm-discover.sh install.sh && ! grep -n 'only link over a USB\|only find each other over a USB\|USB cable only' install.sh README.md sub/dualrm.conf.example` → `1` and no matches

**Steps:**

- [ ] **Step 1: `install.sh` header** — replace

```sh
#   main-wifi-ip  written to the sub's dualrm.conf as MAIN_LAN on first install (optional;
#                 without it the tablets only find each other over a USB cable)
```

with

```sh
#   main-wifi-ip  written to the sub's dualrm.conf as MAIN_LAN on first install (optional:
#                 the sub also finds the main on a shared WiFi by itself; this is only faster)
```

- [ ] **Step 2: sub file list** — replace
`install_node "$SUB" dualrm-sync.sh dualrm-usbrole.sh dualrm-pogo.sh dualrm.conf.example systemd etc`
with
`install_node "$SUB" dualrm-sync.sh dualrm-discover.sh dualrm-usbrole.sh dualrm-pogo.sh dualrm.conf.example systemd etc`

- [ ] **Step 3: main.id** — after the line `echo "the sub's key is authorized on the main"` add:

```sh
[ -n "$idm" ] && ssh "$SUB" "echo '$idm' > /home/root/dualrm/main.id"   # for WiFi discovery
```

- [ ] **Step 4: final hint** — replace
`[ -n "$MAIN_LAN" ] || echo "(no main-wifi-ip given: the tablets only link over a USB cable, see README)"`
with
`echo "(both on the same WiFi: the sub finds the main by itself; public WiFi often blocks this, see README)"`

- [ ] **Step 5: `sub/dualrm.conf.example`** — replace

```sh
# WiFi address of the main tablet, used when no USB link is up. Empty: USB cable only.
# Give the main a fixed address in your router (DHCP reservation). Example: MAIN_LAN=192.168.1.50
MAIN_LAN=
```

with

```sh
# WiFi address of the main tablet, tried first when no USB link is up (optional). Empty: the
# sub finds the main on the WiFi both are on by itself. Example: MAIN_LAN=192.168.1.50
MAIN_LAN=
```

- [ ] **Step 6: README** — make these replacements:

1. Features list: after the `- **Close** follows too.` bullet add:

```markdown
- **Link indicator**: while the tablets are linked, both show `● USB` or `● WiFi` at the top
  right. No indicator: not linked (nothing follows).
```

2. State table: replace the row `| Link over home WiFi | works |` with:

```markdown
| Link over WiFi, main found without a fixed address | new, not yet tested on the tablets |
| Link indicator (top right) | new, not yet tested on the tablets |
```

3. Install step 2: replace

```markdown
2. On the **main**, check that SSH over WiFi works from the PC (if you want the WiFi link).
   Give the main a fixed address in your router (DHCP reservation).
```

with

```markdown
2. On the **main**, check that SSH over WiFi works from the PC (the installer uses it).
```

and in step 3 replace
`   The last argument is optional: without it the tablets only link over a USB cable.`
with
`   The last argument is optional: the sub also finds the main on a shared WiFi by itself.`

4. Configuration block: replace
`MAIN_LAN=192.168.1.50   # the main's WiFi address; empty: USB cable only`
with
`MAIN_LAN=192.168.1.50   # optional: the main's WiFi address, tried first; empty: found by itself`

5. `### WiFi` section body: replace

```markdown
Both tablets on the same network, `MAIN_LAN` set to the main's address. The sync prefers a
USB link when there is one and falls back to WiFi.
```

with

```markdown
Both tablets on the same network. The sub finds the main by itself (an IPv6 ping to all hosts
on the network, then its SSH key, which only the main accepts), so the main needs no fixed
address. With `MAIN_LAN` set, that address is tried first. The sync prefers a USB link when
there is one and falls back to WiFi.

Most public WiFi (cafés, shops, libraries) does not let devices on it talk to each other: the
tablets cannot link there. Use a phone hotspot instead, or the USB cable.
```

6. USB-cable bullet: replace
`- The sub is not charged in this setup. Unplugging the cable falls back to WiFi (if`
`  \`MAIN_LAN\` is set).`
with
`- The sub is not charged in this setup. Unplugging the cable falls back to WiFi.`

7. Troubleshooting: replace

```markdown
- **Nothing follows**: check the sub's `sync.log` for `link up`. No link over WiFi: is
  `MAIN_LAN` right, does the main answer `ping`, does SSH over WiFi work on the main?
```

with

```markdown
- **Nothing follows**: no `● USB` / `● WiFi` at the top right means no link; the sub's
  `sync.log` shows `link up (usb|wifi)` and `link ... lost`. No link over WiFi: are both on
  the same network, and not a public one that isolates devices? `found the main at` in the
  log means discovery worked. A new main tablet: delete `/home/root/dualrm/main.id` on the sub
  (or re-run `install.sh`).
```

- [ ] **Step 7: Verify** — run the Verify command above. Then `grep -n 'MAIN_LAN' README.md` and read each hit: none may say WiFi requires it.

- [ ] **Step 8: Commit**

```bash
git add install.sh sub/dualrm.conf.example README.md
git commit -m "Install the discovery module, record the main's id; document indicator and discovery"
```

---

### Task 6: On-device check (user)

**Goal:** The user installs and confirms on the tablets what the PC tests cannot show.

**USER-ORDERED GATE — NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:** none

**Acceptance Criteria:**
- [ ] After `./install.sh root@192.168.219.112 root@192.168.219.114` the patch loads on both: `journalctl -u xochitl -n 200 | grep -i 'qmldiff\|dualrm'` shows no error.
- [ ] Home WiFi: `● WiFi` appears top right on both within ~10 s of the link; the sub's `sync.log` shows `link up (wifi)`.
- [ ] USB cable plugged: indicator changes to `● USB` on both (`link up (usb)`); unplugged: it goes away and comes back as `● WiFi`.
- [ ] Main's WiFi off: the sub's indicator goes away at once, the main's within 75 s (`link -`).
- [ ] With `MAIN_LAN=` empty on the sub (and `systemctl restart dualrm-sync`): `found the main at fe80::…%wlan0` in `sync.log`, then `link up (wifi)`.
- [ ] Phone hotspot (both tablets on it): link up without any config change.
- [ ] The pill does not cover stock buttons in the library and in a document; if it does, note where to move it.

**Verify:** user reports each item; the agent reads `sync.log` / journal over SSH to confirm.

```json:metadata
{"userGate": true, "tags": ["user-gate"], "files": [], "acceptanceCriteria": ["patch loads without qmldiff errors", "WiFi indicator on both", "USB indicator on plug, back to WiFi on unplug", "main indicator off within 75 s when sub link drops", "discovery with empty MAIN_LAN", "phone hotspot links without config", "pill position acceptable"]}
```
