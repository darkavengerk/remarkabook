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
- `LINKDOWN`: `local_request link -` (replaces the book-mode-only `pagestep 1`).
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

1. `ping6 -c 2 -w 3 ff02::1%wlan0`; collect the `fe80::…` responders, minus the sub's own.
2. Skip addresses that already failed in this sync process (a list in a variable; the sync
   restarts often enough that it does not grow stale).
3. For each candidate: `ssh -y -i $KEY root@<addr>%wlan0 cat /etc/machine-id`, stdin
   `/dev/null`, killed after 8 s (busybox on 3.23 has no `timeout`). Key auth only works on
   the main (only the main authorizes the sub's key). If `$D/main.id` exists the answer must
   match it; if it does not exist the first host that accepts the key is the main and its id
   is saved.
4. Found: connect to `<addr>%wlan0` (tested: dropbear accepts `root@fe80::…%wlan0` without
   brackets). `mainhost` holds that address, so `mssh` works unchanged.

Back-off: when discovery finds nothing, the next attempt waits 5, 10, 20, then 30 s (cap);
reset on link up. USB and `MAIN_LAN` keep being checked every 5 s as now.

`$D/main.id`: written by `install.sh` (it already reads the main's machine-id) and by the
sync at link up when missing.

Tested by hand at home (2026-11-08): the main answers `ff02::1`; `ssh root@fe80::…%wlan0`
from the sub reaches the main and returns its machine-id; a host without the key (the PC)
fails and the client exits.

## Docs

README: `MAIN_LAN` becomes optional (faster first connect on a known network); the indicator;
public WiFi usually isolates clients, use a phone hotspot outside. `dualrm.conf.example` text
updated to match.

## Testing

- PC mock (shell, fake `ssh`/`ping6`/`local_request`): discovery picks the host whose
  machine-id matches, skips failed and own addresses, backs off; LINKUP/LINKDOWN send the
  right `link` commands; `dualrm-link.sh` exits after the read timeout and posts `link -`.
- On the tablets (user): indicator appears/disappears on USB plug/unplug and on WiFi, and
  where it sits; discovery on a phone hotspot.
