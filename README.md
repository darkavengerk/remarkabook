# remarkabook

Use a second reMarkable 2 as a "secondary monitor" for the first one.

Open a document on the **main** tablet and the **sub** tablet opens the document with the
same name in the same folder (creating the folders and a blank notebook if they do not
exist yet). Closing follows too, and the sub keeps the same page count / current page.

The main tablet stays completely stock: nothing is installed on it. All logic runs on
the sub, which logs into the main over SSH and watches what is open there.

```
 main (stock)                          sub (xovi + this repo)
 ┌──────────────┐   ssh (USB or WiFi)  ┌─────────────────────────────┐
 │ xochitl      │◄────────────────────│ dualrm-sync.sh              │
 │ dualrm-agent │  OPEN/STATE/CLOSE   │   └─ request/response files │
 │  (streamed,  │────────────────────►│ dualrm-open.qmd (xochitl    │
 │  not stored) │                     │   patch: open/close/pages)  │
 └──────────────┘                     └─────────────────────────────┘
```

## Status

Tested with main on firmware 3.29.1 and sub on 3.23.0 (xovi, qt-resource-rebuilder).

| Feature | State |
|---|---|
| Open / close mirroring, folder path + auto-create | works |
| Notebook page count / current page | works (pages are added, never deleted) |
| PDF / EPUB | sub notebook grows lazily up to the page being viewed |
| Link over home WiFi | works |
| Link over one USB cable (no WiFi) | works, see [USB cable](#usb-cable) |
| Link over the sub's pogo pins | experimental, see [pogo/](pogo/README.md) |

## How it works

- **`sub/dualrm-agent.sh`** is streamed to the main on each connection
  (`ssh main 'sh -s' < dualrm-agent.sh`). It polls `xochitl.conf` (`LastOpen`) and the
  open document's `.metadata` / `.content`, and prints `OPEN`, `STATE`, `CLOSE` and
  heartbeat lines.
- **`sub/dualrm-sync.sh`** (service on the sub) picks the link (USB first, then WiFi),
  runs the agent and mirrors each event: finds or creates the folder chain and the
  notebook by name, opens it, keeps the page count.
- **`sub/xovi/dualrm-open.qmd`** is a qt-resource-rebuilder patch for xochitl on the sub.
  A QML timer polls `/home/root/dualrm/request` and answers in `.../response`
  (`open`, `close`, `status`, `addpage`, `gotopage`, `ensure`, `mkdir`, `create`).
- **`sub/dualrm-usbrole.sh`** switches the sub's USB-C port between device mode (PC) and
  host mode (main tablet) automatically.
- **`sub/systemd/dualrm-xovi.service`** starts xovi at boot (xovi normally needs to be
  started by hand after every reboot).

## Install

Requirements on the **sub**: root SSH access, [xovi](https://github.com/asivery/xovi)
with the qt-resource-rebuilder extension and its hash table built for that firmware.
Nothing is needed on the main except SSH access.

```sh
./install.sh root@<sub-ip> <main-wifi-ip>
```

The script copies the files, enables the services, restarts xochitl with the patch and
prints the sub's public key. Add that key to the **main**'s
`/home/root/.ssh/authorized_keys`. Re-running it updates the files and keeps the key
and `dualrm.conf`.

Give the main a fixed address in your router (DHCP reservation) if you use WiFi.

### Useful commands (on the sub)

```sh
tail -n 20 /home/root/dualrm/sync.log           # what the sync did
systemctl disable --now dualrm-sync dualrm-usbrole   # turn it off
/home/root/xovi/stock                            # xochitl without patches until next boot
systemctl disable dualrm-xovi                    # stop starting xovi at boot
```

### Firmware updates

- **Sub**: turn automatic updates off. An update boots a fresh root partition: the
  services, the device tree edit and xovi's start-up are gone, and xovi needs a hash
  table for the new firmware.
- **Main**: can be updated, but check the sync afterwards. 3.29 changed the
  `LastOpen` format, which the agent had to learn.

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
