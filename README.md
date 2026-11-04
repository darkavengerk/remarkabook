# remarkabook

Use two reMarkable 2 tablets as one device.

Open a document on either tablet and the other one follows:

- **Notebooks**: the other tablet opens the notebook with the same name in the same folder
  (folders and a blank notebook are created if missing) and keeps the same page count and
  page.
- **PDF / EPUB present on both tablets** (same document, e.g. through the reMarkable
  cloud): **book mode**. One tablet shows the left page, the other the right page. Turning a
  page on either tablet turns the spread on both.
- **PDF / EPUB only on one tablet**: it is copied to the other tablet (same folder path,
  imported with xochitl's own importer, no restart) and opened there in book mode. The copy
  gets its own document id; the pair is remembered in the sub's `dualrm/pairs`. If the copy
  fails, the other tablet opens a blank notebook of the same name instead.
- **Annotations** (pen strokes, highlights) of book-mode documents are copied page by page:
  from the tablet that opened the document before the other one opens it, and both ways once
  it is closed. The newer file wins; a replaced file is kept in `dualrm/backup/` on that tablet
  for 30 days. Annotations go over the dual-rM link only, not the reMarkable cloud.
- **Scrolling (notebooks)**: scrolling a notebook page on one tablet scrolls the same page on
  the other to the same height, once the scroll settles (about half a second). Zoom stays per
  tablet. PDF / EPUB pages are not followed.
- **Pens**: changing pen, colour or width on one tablet changes it on the other (which pen
  is in hand stays per tablet). When a pair opens, the main's settings win.
- **Sleep**: putting one tablet to sleep puts the other to sleep too (the sync presses its
  power key through the input device; xochitl refuses to sleep any other way). Waking up is
  per tablet: in deep sleep only the power button (or a charger) wakes a reMarkable.
- Closing follows too.

```
 tablet A (xovi)                        tablet B ("sub", xovi + sync)
 ┌────────────────────┐  ssh (USB/WiFi) ┌──────────────────────────────┐
 │ xochitl + patch    │                 │ xochitl + patch              │
 │   │events  ▲cmds   │                 │   │events  ▲cmds             │
 │ sockets 7781/7782  │                 │ sockets 7781/7782            │
 │   ▼        │       │                 │   ▼        │                 │
 │ dualrm-link.sh ◄───┼─────────────────┼─► dualrm-sync.sh (decides)   │
 └────────────────────┘                 └──────────────────────────────┘
```

## Status

Tested with "main" on firmware 3.29.1 and "sub" on 3.23.0, both with xovi and
qt-resource-rebuilder.

| Feature | State |
|---|---|
| Open / close follows, both ways | works |
| Notebook page count / current page, both ways | works (pages are added, never deleted) |
| Book mode for PDFs on both tablets | works |
| PDF / EPUB missing on one tablet: copied over | works |
| Annotations of book-mode documents, both ways | works (on close; not live) |
| Pen settings follow, both ways (main wins at open) | works |
| Notebook scroll position follows, both ways | works |
| Sleep together | works |
| Link over home WiFi | works |
| Link over one USB cable (no WiFi) | works, see [USB cable](#usb-cable) |
| Link over the sub's pogo pins | experimental, see [pogo/](pogo/README.md) |

## How it works

Nothing polls. Both tablets run the same pieces (`node/`):

- **`dualrm.qmd`**, a qt-resource-rebuilder patch for xochitl. It reports document and page
  changes the moment they happen (`GET http://127.0.0.1:7781/ev?...`) and takes commands
  over a held request (`GET http://127.0.0.1:7782/next`): `open`, `close`, `status`,
  `addpage`, `gotopage`, `ensure`, `mkdir`, `create`, `emit`, `import`, `pen`, `setpen`,
  `setscroll`; events `DOC`, `PAGE`, `PEN`, `SCROLL`, `SLEEP`, `WAKE`.
- **`dualrm-ev.sh` / `dualrm-cmd.sh`** behind systemd socket units (`Accept=yes`), so a
  shell only runs while an event or command is in flight.
- **`dualrm-link.sh`** is the main's end of the ssh session: it forwards the main's events
  and hands the sub's commands to the main's xochitl.

The sub additionally runs:

- **`sub/dualrm-sync.sh`**: holds the link (USB first, then WiFi), sleeps on a fifo of
  events from both tablets, pairs documents and moves the other tablet. It recognises its
  own echoes (the other tablet reporting what it was just told to do).
- **`sub/dualrm-usbrole.sh`**: switches the sub's USB-C port between device mode (PC) and
  host mode (main tablet).
- **`dualrm-xovi.service`** (both tablets): starts xovi at boot.

Book mode settings in the sub's `dualrm.conf`:

```sh
BOOK_LEFT=main      # tablet showing the left page (main | sub)
BOOK_COVER=0        # 1: first page alone on the right, like a printed book
```

Notes on copying:

- Annotations are matched by page id (same document on both) or by PDF page (a copy), so
  pages inserted into a copied PDF are not copied. EPUB copies are not matched at all (each
  tablet lays out the pages itself).
- A tablet only reads a page's annotations when it opens the document, so strokes copied
  while it has the document open show up the next time it is opened.
- Annotating the same page on both tablets while they are apart: the newer page wins, the
  other is in `dualrm/backup/`.
- 3.29 names an imported copy without the `.pdf` extension, 3.23 keeps it.
- Turn the reMarkable cloud sync off on one tablet (or both): two tablets editing the same
  document make the cloud drop one side's changes.

## Install

Requirements on **both** tablets: root SSH access, [xovi](https://github.com/asivery/xovi)
with qt-resource-rebuilder and a hash table for the installed firmware
(`xovi/rebuild_hashtable`). [Vellum](https://github.com/vellum-dev/vellum-cli) installs
these: `vellum add qt-resource-rebuilder`.

```sh
./install.sh root@<sub-ip> root@<main-ip> <main-wifi-ip>
```

The script copies the files, enables the sockets and services, restarts xochitl once on
each tablet and prints the sub's public key if the main does not accept it yet. Add that
key to the **main**'s `/home/root/.ssh/authorized_keys`. Re-running it updates the files
and keeps the key and `dualrm.conf`. xochitl may only be restarted 4 times in 10 minutes;
more and the tablet reboots.

Give the main a fixed address in your router (DHCP reservation) if you use WiFi.

### Useful commands

```sh
tail -n 20 /home/root/dualrm/sync.log                # (sub) what the sync did
systemctl disable --now dualrm-sync dualrm-usbrole   # (sub) turn it off
/home/root/xovi/stock                                # xochitl without patches until next boot
systemctl disable dualrm-xovi                        # stop starting xovi at boot
```

### Firmware updates

- **Sub**: turn automatic updates off. An update boots a fresh root partition: the
  services, the device tree edit and xovi's start-up are gone.
- **Main** (and the sub too, if updated): run `vellum check-os <version>` before, and after
  the update `vellum upgrade`, `xovi/rebuild_hashtable`, then `install.sh` again. Check the
  patch still loads: the xochitl QML changes between versions (3.29 for example returns
  document ids that are not plain strings).

## USB cable

The reMarkable 2 USB-C port never outputs 5 V, and it cannot do USB-PD role swaps. What
worked:

```
 main ── USB-C plug │ passthrough adapter │ USB-A ── A-to-C cable ── sub
                    │  (USB-C plug,       │
 power bank ── PD in│   USB-A, PD in)     │
```

- The adapter is a plain "USB-C to USB-A + PD charging" passthrough (no hub chip).
  Its PD input powers only the USB-C plug side, so the **main** goes on that side and
  gets charged; the main only enumerates when it sees 5 V.
- The **sub** sits on the USB-A side without power. `dualrm-usbrole.sh` puts the sub's
  port into host mode whenever no power comes in, the main shows up as a USB network
  device (`10.11.99.1`) and the sync switches to it.
- The other way round (sub on the PD side) does not work: the main gets no 5 V.
- The sub is not charged in this setup.
- Unplugging the cable falls back to WiFi (if `MAIN_LAN` is set).

## Pogo pins (experimental)

The sub's pogo connector is a second USB controller. With a one-line device tree edit
it runs as a USB host, which would allow a cable from the sub's pogo pins to the main's
USB-C while the sub's own USB-C stays free for charging. See [pogo/](pogo/README.md).
Kernel modules are not an option: production kernels enforce module signatures.

## License

MIT, see [LICENSE](LICENSE). The pogo adapter hardware referenced in `pogo/adapter/`
is [veryapt/remarkable-2-pogo-to-usb-adapter](https://github.com/veryapt/remarkable-2-pogo-to-usb-adapter)
(CERN-OHL-S v2) and is not included here.

Not affiliated with reMarkable AS. Modifying your device is at your own risk.
