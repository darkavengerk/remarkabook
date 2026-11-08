# remarkabook

Use two reMarkable 2 tablets as one device: open a document on either tablet and the
other one follows. PDFs and EPUBs become a two-page book, one page on each tablet.

> **Unofficial, at your own risk.** remarkabook patches xochitl (the reMarkable UI) through
> [xovi](https://github.com/asivery/xovi) and needs root access over SSH. It is not affiliated
> with reMarkable AS. Read [Limitations](#limitations) and keep a backup of your documents.

## Features

- **Notebooks**: the other tablet opens the notebook with the same name in the same folder
  (folders and a blank notebook are created if missing) and keeps the same page count and
  page. Each tablet keeps its own strokes: notebook content is not copied.
- **Book mode** (PDF / EPUB present on both tablets, e.g. through the reMarkable cloud):
  one tablet shows the left page, the other the right page. A swipe or page key on either
  tablet turns the spread on both, in one step. Jumping to a page (page list, search, link)
  opens the spread that holds it. A tablet on its own turns one page at a time.
- **Missing PDF / EPUB**: a document on only one tablet is copied to the other (same folder
  path, imported with xochitl's own importer, no restart) and opened there in book mode. If
  the copy fails, the other tablet opens a blank notebook of the same name instead.
- **Annotations** (pen strokes, highlights) of book-mode documents are copied page by page:
  from the tablet that opened the document before the other one opens it, and both ways once
  it is closed. The newer page wins; a replaced page is kept in `dualrm/backup/` for 30 days.
  Annotations go over the tablet-to-tablet link only, not the reMarkable cloud.
- **Scrolling (notebooks)**: scrolling a notebook page on one tablet scrolls the same page
  on the other to the same height, once the scroll settles (about half a second). Zoom
  stays per tablet. PDF / EPUB pages are not followed.
- **Pens**: changing pen, colour or width on one tablet changes it on the other (which pen
  is in hand stays per tablet). When a pair opens, the main's settings win.
- **Sleep**: putting one tablet to sleep puts the other to sleep too. Waking up is per
  tablet: in deep sleep only the power button (or a charger) wakes a reMarkable.
- **Close** follows too.
- **Link indicator**: while the tablets are linked, both show `● USB` or `● WiFi` at the top
  right. No indicator: not linked (nothing follows).

### Tested

| Tablet | Firmware |
|---|---|
| main | 3.29.1 |
| sub | 3.23.0 |

Other 3.x versions may work: the xochitl QML changes between releases, so the patch may not
load. `install.sh` warns on untested versions. Reports (works / does not) are welcome as
issues; include `cat /etc/os-release` and the sub's `sync.log`.

| Feature | State |
|---|---|
| Open / close follows, both ways | works |
| Notebook page count / current page, both ways | works (pages are added, never deleted) |
| Notebook scroll position, both ways | works |
| Book mode for PDFs on both tablets | works |
| Book mode page turn in one step | new, not yet tested on the tablets |
| PDF / EPUB missing on one tablet: copied over | works |
| Annotations of book-mode documents, both ways | works (on open / close; not live) |
| Pen settings, both ways | works |
| Sleep together | works |
| Link over WiFi, main found without a fixed address | new, not yet tested on the tablets |
| Link indicator (top right) | new, not yet tested on the tablets |
| Link over one USB cable (no WiFi) | works, see [USB cable](#usb-cable) |
| Link over the sub's pogo pins | experimental, see [pogo/](pogo/README.md) |

## Requirements

- Two **reMarkable 2** tablets (not reMarkable 1 or Paper Pro).
- Root SSH access to both. The root password is in *Settings → Help → Copyrights and
  licenses → General information*. Over USB a tablet is at `10.11.99.1`; on WiFi use the
  address shown there.
- On **both** tablets: [xovi](https://github.com/asivery/xovi) with the
  qt-resource-rebuilder extension and a hash table for the installed firmware.
  [Vellum](https://github.com/vellum-dev/vellum-cli) installs these:
  `vellum add qt-resource-rebuilder`, then `/home/root/xovi/rebuild_hashtable`.
- A PC with `ssh` and `tar` (Linux, macOS or WSL) to run the installer.
- An SSH key from the PC on both tablets is recommended (`ssh-copy-id root@<tablet>`);
  otherwise you type the root password many times during install.

### Which tablet is the sub?

The two tablets do the same work except that the **sub** runs the sync (the part that
decides) and logs in to the **main** over SSH. Pick as sub:

- the tablet you would rather not update (see [Firmware updates](#firmware-updates)), and
- if you want a USB cable between them, the tablet that sits on the unpowered side of the
  adapter (see [USB cable](#usb-cable)).

Book mode puts the main on the left by default (`BOOK_LEFT` in [Configuration](#configuration)).

## Install

1. Install xovi and qt-resource-rebuilder on both tablets and build the hash table
   (see [Requirements](#requirements)). Check that xovi starts: run `/home/root/xovi/start`
   on each tablet; the UI restarts.
2. On the **main**, check that SSH over WiFi works from the PC (the installer uses it).
3. From this repository on the PC:

   ```sh
   ./install.sh root@<sub-address> root@<main-address> <main-wifi-address>
   ```

   The last argument is optional: the sub also finds the main on a shared WiFi by itself.

The installer checks both tablets (model, firmware, xovi, hash table), asks before going
on, copies the files, enables the services, restarts xochitl once on each tablet, authorizes
the sub's key on the main and waits for the link. Open a document on either tablet: the other
follows.

Re-run `install.sh` to update; it keeps the sub's key and `dualrm.conf`. xochitl may be
restarted only 4 times in 10 minutes; more and the tablet reboots, so do not run the
installer several times in a row.

The installer also enables `dualrm-xovi.service`, which starts xovi at boot on both tablets.
If you already start xovi another way, disable it: `systemctl disable dualrm-xovi`.

### Uninstall

```sh
./uninstall.sh root@<sub-address> root@<main-address>     # "-" skips a tablet
```

Removes the services, scripts and patch, takes the sub's key off the main and restarts
xochitl. xovi and its other extensions stay. Annotation backups are kept in
`/home/root/dualrm-backup`.

## Configuration

`/home/root/dualrm/dualrm.conf` on the sub (`systemctl restart dualrm-sync` after a change):

```sh
MAIN_LAN=192.168.1.50   # optional: the main's WiFi address, tried first; empty: found by itself
BOOK_LEFT=main          # tablet showing the left page in book mode: main | sub
BOOK_COVER=0            # 1: first page alone on the right, like a printed book
```

## Using it

- Turn the reMarkable cloud sync off on one tablet (or both): two tablets editing the same
  document make the cloud drop one side's changes. A PDF can still arrive on both through
  the cloud before you turn it off; otherwise remarkabook copies it over.
- A tablet reads a page's annotations when it opens the document, so annotations copied
  while it has the document open show up the next time it is opened.
- Annotating the same page on both tablets while they are apart: the newer page wins, the
  other is in `dualrm/backup/`.
- Annotations of a copied PDF are matched by PDF page, so pages inserted into a copy are not
  copied. EPUB copies are not matched at all (each tablet lays out the pages itself).
- Firmware 3.29 names an imported copy without the `.pdf` extension, 3.23 keeps it.

## Connecting the tablets

### WiFi

Both tablets on the same network. The sub finds the main by itself (an IPv6 ping to all hosts
on the network, then its SSH key, which only the main accepts), so the main needs no fixed
address. With `MAIN_LAN` set, that address is tried first. The sync prefers a USB link when
there is one and falls back to WiFi.

Most public WiFi (cafés, shops, libraries) does not let devices on it talk to each other: the
tablets cannot link there. Use a phone hotspot instead, or the USB cable.

### USB cable

The reMarkable 2 USB-C port never outputs 5 V and cannot do USB-PD role swaps, so a plain
C-to-C cable does not work. What does:

```
 main ── USB-C plug │ passthrough adapter │ USB-A ── A-to-C cable ── sub
                    │  (USB-C plug,       │
 power bank ── PD in│   USB-A, PD in)     │
```

- The adapter is a plain "USB-C to USB-A + PD charging" passthrough (no hub chip). Its PD
  input powers only the USB-C plug side, so the **main** goes on that side and gets
  charged; the main only shows up as a USB device when it sees 5 V.
- The **sub** sits on the USB-A side without power. `dualrm-usbrole.sh` puts the sub's port
  into host mode whenever no power comes in; the main shows up as a USB network device
  (`10.11.99.1`) and the sync switches to it.
- The other way round (sub on the PD side) does not work: the main gets no 5 V. The sides
  are fixed by which tablet you installed as sub.
- The sub is not charged in this setup. Unplugging the cable falls back to WiFi.
- With the sub on a PC or a charger, its port stays a normal USB device (file transfer,
  SSH over USB).

### Pogo pins (experimental)

The sub's pogo connector is a second USB controller. With a one-line device tree edit it
runs as a USB host, which would allow a cable from the sub's pogo pins to the main's USB-C
while the sub's own USB-C stays free for charging. See [pogo/](pogo/README.md). Kernel
modules are not an option: production kernels enforce module signatures.

## Firmware updates

- **Sub**: turn automatic updates off. An update boots a fresh root partition: the
  services and xovi's start-up are gone (and the device tree edit, if you made it).
- **Main** (and the sub, if you update it): run `vellum check-os <version>` before; after
  the update run `vellum upgrade`, `/home/root/xovi/rebuild_hashtable`, then `install.sh`
  again. Check that the patch still loads (see [Troubleshooting](#troubleshooting)).

## Troubleshooting

```sh
tail -n 30 /home/root/dualrm/sync.log                # (sub) what the sync did; "link up" = linked
cat /home/root/dualrm/ssh.err                        # (sub) why the link to the main failed
journalctl -u xochitl -n 100 | grep -i 'qmldiff\|dualrm'   # (either) did the patch load?
systemctl disable --now dualrm-sync dualrm-usbrole   # (sub) turn the sync off
/home/root/xovi/stock                                # (either) xochitl without patches until next boot
```

- **Nothing follows**: no `● USB` / `● WiFi` at the top right means no link; the sub's
  `sync.log` shows `link up (usb|wifi)` and `link ... lost`. No link over WiFi: are both on
  the same network, and not a public one that isolates devices? `found the main at` in the
  log means discovery worked. A new main tablet: delete `/home/root/dualrm/main.id` on the sub
  (or re-run `install.sh`).
- **The UI misbehaves after an update**: run `/home/root/xovi/stock` on that tablet, then
  rebuild the hash table and re-run `install.sh`. If it still fails, that firmware is not
  supported yet: please open an issue with the `journalctl` output above.
- **The tablet rebooted during install**: xochitl was restarted too often (4 times in 10
  minutes). Wait 10 minutes before trying again.

## Limitations

- reMarkable 2 only; tested on the firmware versions above.
- Notebook strokes are not copied between tablets; book-mode annotations are copied when a
  document is opened or closed, not live.
- Pages are added to keep notebooks the same length, never deleted.
- Waking from sleep is per tablet.
- One pair of tablets per installation.

## Security

- The sub holds an SSH key (no passphrase) that logs in to the main as root. Anyone with
  root on the sub has root on the main. `uninstall.sh` removes the key from the main.
- The event and command sockets listen on `127.0.0.1` only; nothing new is exposed on the
  network. The link between the tablets is SSH.

## How it works

```
 main (xovi)                            sub (xovi + sync)
 ┌────────────────────┐  ssh (USB/WiFi) ┌──────────────────────────────┐
 │ xochitl + patch    │                 │ xochitl + patch              │
 │   │events  ▲cmds   │                 │   │events  ▲cmds             │
 │ sockets 7781/7782  │                 │ sockets 7781/7782            │
 │   ▼        │       │                 │   ▼        │                 │
 │ dualrm-link.sh ◄───┼─────────────────┼─► dualrm-sync.sh (decides)   │
 └────────────────────┘                 └──────────────────────────────┘
```

Nothing polls. Both tablets run the same pieces (`node/`):

- **`dualrm.qmd`**, a qt-resource-rebuilder patch for xochitl. It reports document and page
  changes the moment they happen (`GET http://127.0.0.1:7781/ev?...`) and takes commands
  over a held request (`GET http://127.0.0.1:7782/next`): `open`, `close`, `status`,
  `addpage`, `gotopage`, `ensure`, `mkdir`, `create`, `emit`, `import`, `pen`, `setpen`,
  `setscroll`, `pagestep`; events `DOC`, `PAGE`, `PEN`, `SCROLL`, `SLEEP`, `WAKE`.
- **`dualrm-ev.sh` / `dualrm-cmd.sh`** behind systemd socket units (`Accept=yes`), so a
  shell only runs while an event or command is in flight.
- **`dualrm-link.sh`** is the main's end of the SSH session: it forwards the main's events
  and hands the sub's commands to the main's xochitl.
- **`dualrm-xovi.service`**: starts xovi at boot.

The sub additionally runs:

- **`sub/dualrm-sync.sh`**: holds the link (USB first, then WiFi), sleeps on a fifo of
  events from both tablets, pairs documents and moves the other tablet. It recognises its
  own echoes (the other tablet reporting what it was just told to do). Copied PDFs are
  remembered in `dualrm/pairs`.
- **`sub/dualrm-usbrole.sh`**: switches the sub's USB-C port between device mode (PC) and
  host mode (main tablet).
- Sleep together works by pressing the other tablet's power key through its input device:
  xochitl refuses to go to sleep any other way.

## License

MIT, see [LICENSE](LICENSE). The pogo adapter hardware referenced in `pogo/adapter/` is
[veryapt/remarkable-2-pogo-to-usb-adapter](https://github.com/veryapt/remarkable-2-pogo-to-usb-adapter)
(CERN-OHL-S v2) and is not included here.
