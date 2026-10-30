# Pogo pins as a USB host (experimental)

The reMarkable 2 has two USB OTG controllers on the i.MX7D:

| Controller | Connector | Stock use |
|---|---|---|
| `30b20000.usb` | USB-C | device (PC), switchable to host |
| `30b10000.usb` | pogo pins (left edge) | Type Folio keyboard, driven by the `rm-pogo` driver; host mode is not implemented in firmware 3.23 or 3.29 |

Pogo pin order (VBUS nearest the USB-C port): **VBUS, D-, D+, ID, GND**.

## Device tree edit

Kernel modules cannot be used (production kernels: `CONFIG_MODULE_SIG_FORCE`, lockdown,
only reMarkable's signing key). The boot loader, however, loads `/boot/zero-sugar.dtb`
without verifying it, so the pogo controller can be put into host mode there.

`dtb/zero-sugar-pogo-host.patch` (against the decompiled 3.23.0 device tree):

```diff
-				extcon = <0x00 0x4c>;
+				dr_mode = "host";
```

in the `usb@30b10000` node. Steps used on the sub (firmware 3.23.0.64):

```sh
# on the PC
scp root@<sub>:/boot/zero-sugar.dtb zero-sugar.orig.dtb
dtc -I dtb -O dts -o zero-sugar.dts zero-sugar.orig.dtb
patch zero-sugar.dts < dtb/zero-sugar-pogo-host.patch
dtc -I dts -O dtb -o zero-sugar-dualrm.dtb zero-sugar.dts
scp zero-sugar-dualrm.dtb root@<sub>:/tmp/

# on the sub: keep the original, and let the boot loader fall back to the other
# partition if the new tree does not boot
cp /boot/zero-sugar.dtb /boot/zero-sugar.dtb.orig
cp /tmp/zero-sugar-dualrm.dtb /boot/zero-sugar.dtb
fw_setenv upgrade_available 1; fw_setenv bootcount 0
reboot
# after a good boot:
fw_setenv upgrade_available 0; fw_setenv bootcount 0
```

Revert: `cp /boot/zero-sugar.dtb.orig /boot/zero-sugar.dtb && reboot`.

The line numbers and phandles in the patch are for 3.23.0; check the `usb@30b10000`
node yourself on other versions.

### Side effects (handled by this repo)

- The pogo controller now probes first and takes `ci_hdrc.0`; USB-C becomes `ci_hdrc.1`.
  The stock `/usr/sbin/usb-ether-once` binds the PC gadget to `ci_hdrc.0`, so
  `sub/etc/dualrm-fix-udc.sh` (drop-in for `usb-ether-once.service`) rebinds it to the
  USB-C controller.
- `sub/dualrm-pogo.sh setup` (boot service) keeps the pogo root hub awake and parks the
  `rm-pogo` keyboard state machine (`manual_fsm=1`), so Type Folio detection is off.
- `sub/dualrm-pogo.sh vbus on|off` switches 5 V out of the pogo VBUS pin
  (`pogo_chargermode` "OTG Supply"). **Untested.**

## Adapter

See [adapter/](adapter/README.md). Not built yet: the device tree part is verified (the
pogo bus comes up as an EHCI root hub), a device on the pins is not.
