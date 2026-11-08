# Link indicator and WiFi discovery

Date: 2026-11-08. Branch: `event-driven`.

## Why

Field test 2026-11-07 (bookstore, KST 16:40):

- USB: the link came up twice (sub log `link up`, main log: sub's SSH login) and dropped by
  itself 8 s and 11 s later, at the same moment power appeared on the sub's port. The user
  opened a document after each drop, saw nothing follow, and kept re-plugging: there is no way
  to see on a tablet whether the link is up. (The drop itself is a power/adapter question,
  investigated separately.)
- WiFi: both tablets joined the same public network; the main got `10.23.1.149`. The sub only
  tries `MAIN_LAN=192.168.219.114` (the home DHCP reservation), so it never tried to connect.

## Goals

1. Both tablets show a small status indicator at the top right while they are linked:
   `● USB` or `● WiFi`. No indicator when not linked. No toast.
2. The sub finds the main on whatever WiFi network both are on, without a fixed address.

Out of scope: why the USB link dropped yesterday; networks with client isolation (public
WiFi usually blocks tablet-to-tablet traffic: the README points to a phone hotspot).

## 1. Link indicator

### Patch (`node/xovi/dualrm.qmd`, MainView)

- New command `link <usb|wifi|->`. `usb`/`wifi`: show the indicator with that label. `-`: hide
  it and set `dualrmPageStep` to 1 (alone again: what `pagestep 1` did at link down).
- The indicator is an `Item` added to MainView's root after the existing poller: high `z`,
  anchored top right with a margin, a filled black dot and the label in the stock font
  (Noto Sans has no Hangul: English labels only). No input handlers, so touches and pen go
  through. Starts hidden on every xochitl start.
- Position is a first guess; it is moved after checking on the tablets if it covers stock
  buttons.

### Sub (`sub/dualrm-sync.sh`)

- `link_loop` reports the transport with the link-up event: `RM LINKUP usb` when the main is
  `10.11.99.1`, otherwise `RM LINKUP wifi`.
- `LINKUP <via>`: `local_request link <via>` and `remote_request link <via>`.
- `LINKDOWN`: `local_request link -` (replaces the book-mode-only `pagestep 1`), only when
  the link had been up.
- When the sync stops: `ExecStopPost=` in `dualrm-sync.service` posts `link -` (not the EXIT
  trap). `PING` is written only while linked (`$D/linked`).
- At start: `local_request link -`, so an indicator left from a killed sync goes away (the
  sync restarts on every USB attach/detach).

### Main (`node/dualrm-link.sh`)

- `cleanup` posts `link -` instead of `pagestep 1` (one command: `local_post` keeps only the
  last waiting command, so two posts in a row would lose the first).
- Stale sessions: the sub writes `PING` to the link every 30 s; `dualrm-link.sh` reads with
  `read -t 75` and exits when nothing arrives, so the main's indicator goes off within 75 s
  of the sub vanishing (today a dead WiFi session lingered 39 min). Lines other than `CMD`
  are ignored, as now.

## 2. WiFi discovery (`sub/dualrm-sync.sh`)

Order in `pick_main`: USB (unchanged) → `MAIN_LAN` if set (unchanged) → discovery.

Discovery, only when `wlan0` has an IPv6 link-local address:

0. Only when `$D/main.id` holds 32 characters. Otherwise discovery is off (no ping) and the
   sync logs `discovery off: no main.id (install.sh or one USB link writes it)` once. No host
   is ever adopted on trust (revised after review: adoption let any host that accepted the
   key, or answered first, become the main).
1. `ping6 -w 2 ff02::1%wlan0` (no `-c`: the sub's own reply ended a count of 2 after ~1 s);
   collect the `fe80::…` responders, minus the sub's own.
2. Skip addresses in the bad list. Every outcome other than the right id (refused, password
   prompt, timeout, wrong id) adds the address; the whole list is forgotten 180 s
   (`DISC_FORGET`) after its first entry, so a main that was still booting is tried again.
   Only wrong-id answers are logged (`discovery: <addr> answered another id`).
3. For each candidate: `ssh -y -o DisableTrivialAuth=yes -i $KEY root@<addr>%wlan0 cat
   /home/root/dualrm/node.id`, stdin `/dev/null`, stderr to `$D/disc.err`. The shell polls
   every 0.2 s for up to 8 s (`DISC_TIMEOUT`; busybox on 3.23 has no `timeout`): a
   `password` prompt in `disc.err` kills the probe at once (dropbear's client has no
   BatchMode and falls back to password attempts), so does the timeout. No watcher subshell:
   busybox ash can run the parent's EXIT trap in a forked child that is killed early. The
   answer must equal `$D/main.id`.
4. Found: connect to `<addr>%wlan0` (tested: dropbear accepts `root@fe80::…%wlan0` without
   brackets). `mainhost` holds that address, so `mssh` works unchanged.

Back-off: when discovery finds nothing, the next attempt waits 5, 10, 20, then 30 s (cap);
reset on link up. USB and `MAIN_LAN` keep being checked every 5 s as now.

Identity (revised after review): `/home/root/dualrm/node.id` on the main, 32 hex characters
from `/proc/sys/kernel/random/uuid`, created when missing. Not `/etc/machine-id`: that is on
the rootfs, which firmware updates replace. The id only travels inside an ssh session that
the sub's key opened, so a host that is not the main cannot answer it: this is what
authenticates the main.

`$D/main.id` on the sub is written by
- `install.sh`, in this order: install the main; set up the sub without restarting its
  services; authorize the sub's key on the main; create `node.id` on the main and write it
  to the sub's `main.id`; only then restart `dualrm-xovi`, then `dualrm-usbrole
  dualrm-sync` on the sub (so the first sync already has `main.id`);
- the sync at every link up (a link up means the main ran our `dualrm-link.sh` with the
  sub's key, so it is trusted): it reads `node.id` over `mssh`, creating it if missing, and
  rewrites `main.id` when the answer has 32 characters and differs.

`MAIN_LAN` that answers ping but gives no link (a session without `HELLO`) is skipped for
300 s, so discovery gets a turn.

Tested by hand at home (2026-11-08): the main answers `ff02::1`; `ssh root@fe80::…%wlan0`
from the sub reaches the main and returns its machine-id; a host without the key (the PC)
fails and the client exits.

## Docs

README: `MAIN_LAN` becomes optional (faster first connect on a known network); the indicator;
public WiFi usually isolates clients, use a phone hotspot outside. `dualrm.conf.example` text
updated to match.

## Testing

- Shell tests (stubbed `ssh`/`ping6`/`ip`; on the PC and on the sub's busybox from `/tmp`):
  discovery is off without `main.id`, picks the host whose `node.id` matches, skips own and
  bad addresses (refused, password prompt, timeout, wrong id), forgets the bad list, backs
  off; `dualrm-link.sh` exits after the read timeout and posts `link -`.
- The sync's LINKUP/LINKDOWN wiring: `sh -n` plus the on-device check (the sync needs live
  fifos and xochitl; a mock would test the mock).
- On the tablets (user): indicator appears/disappears on USB plug/unplug and on WiFi, and
  where it sits; discovery on a phone hotspot.
