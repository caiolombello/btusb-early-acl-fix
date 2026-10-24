# btusb-early-acl-fix

Fix for Bluetooth LE mice and keyboards that **freeze or disconnect about 30 seconds after connecting on Linux**, caused by the kernel dropping the device's first packet. Confirmed with a **Keychron M6 8K** on a **Realtek RTL8852BU** adapter (`0bda:b85b`).

Installs a patched `btusb` driver with DKMS, so it is rebuilt automatically for every new kernel.

## Do you have this problem?

Typical symptoms with a Bluetooth LE mouse or keyboard:

- it connects and works for a few seconds (up to ~30 s), then stops responding or disconnects, and may not reconnect;
- or it shows as connected but the cursor never moves;
- the kernel log shows this line right when the device connects:

```
Bluetooth: hci0: ACL packet for unknown connection handle 16
```

Check with:

```
journalctl -k -b | grep "unknown connection handle"
```

or run `./diagnose.sh` from this repository (no root needed).

## Cause

Some USB Bluetooth controllers send the first data packet of a new LE connection on the USB bulk endpoint a few milliseconds **before** the "LE Connection Complete" event arrives on the interrupt endpoint. The kernel does not know the connection handle yet, so it drops the packet.

With the Keychron M6 8K that packet is the mouse's ATT *Exchange MTU Request*. The mouse waits for a reply that never comes, and after the ATT 30-second transaction timeout it stops sending input (Bluetooth Core Specification, Vol 3, Part F, 3.3.3). The same lost exchange also makes the mouse return a truncated HID Report Map, which is why the cursor sometimes never moves at all.

Measured on the RTL8852BU: the event arrives 4 to 12 ms after the data. The driver's existing `force_poll_sync` option delays data by only one USB polling interval (~1 ms), which is not enough.

This is not a BlueZ bug: BlueZ never receives the dropped packet.

## What the fix does

The patch (about 90 lines, in `patches/`) changes `btusb` so that a data packet whose connection handle is not registered yet is held for at most 50 ms and delivered right after the kernel processes the Connection Complete event. Packet order is preserved. Packets for known connections are not affected. Each saved packet is logged:

```
Bluetooth: hci0: Delivered early ACL for handle 16 after 4 ms
```

## Tested

| Distro | Kernel | Adapter | Device | Result |
|---|---|---|---|---|
| Fedora 44 | 7.2.11-200.fc44 | Realtek RTL8852BU (`0bda:b85b`), firmware 0x127cfd78 | Keychron M6 8K | Works: 9+ minutes with idle periods, reconnects after power cycling, full HID descriptor with stock BlueZ 5.87 |
| Fedora rawhide | 7.3.0-65.fc46 | — | — | Builds; source check exact. Not tested on hardware |

Supported kernel layouts: Linux up to 7.2 (`btusb-early-acl-hold.patch`) and 7.3 (`btusb-early-acl-hold-v7.3.patch`). Linux 7.4 splits `btusb.c` into several files and is not supported yet; the build stops with a clear message and the stock driver stays in use.

The same race has been reported upstream on the Intel Wireless-AC 9260 (`8087:0025`) and an Edimax adapter (`7392:c611`). This fix has not been tested on them; reports are welcome.

## Install

Requirements: DKMS, the headers for your running kernel, gcc, make, binutils, patch and curl. On Fedora the installer installs them for you.

```
git clone https://github.com/caiolombello/btusb-early-acl-fix.git
cd btusb-early-acl-fix
sudo ./install.sh --reload
```

`--reload` switches to the fixed driver right away (Bluetooth devices disconnect for a few seconds). Without it, the fix starts on the next boot.

For each kernel the build:

1. downloads `drivers/bluetooth/btusb.c` for the matching upstream version from kernel.org (GitHub mirror as fallback);
2. builds it **unmodified** and compares the result with your distro's own `btusb` module;
3. only then applies the patch that matches that source exactly and builds the fixed module.

If the source does not match your distro's driver (for example, a distro that patches `btusb`), nothing is installed and the stock driver stays in use. On Fedora the comparison is exact: the rebuilt stock driver is instruction-for-instruction identical to Fedora's.

Other distros are untested. Install the requirements yourself first; for Debian/Ubuntu that is `sudo apt install dkms linux-headers-$(uname -r) build-essential curl patch`. Ubuntu kernels carry their own patches and will probably fail the source check.

## Check that it works

```
cat /sys/module/btusb/parameters/early_acl_hold_ms   # 50 = fix loaded
./diagnose.sh
```

After connecting the device you should see `Delivered early ACL ...` in the kernel log and no more `unknown connection handle`.

## Settings

Hold time (driver option), for example to allow 100 ms:

```
echo "options btusb early_acl_hold_ms=100" | sudo tee /etc/modprobe.d/btusb-early-acl.conf
```

At runtime: `echo 100 | sudo tee /sys/module/btusb/parameters/early_acl_hold_ms` (`0` disables the hold).

Build options go in `/etc/btusb-early-acl.conf`:

- `SOURCE_TAG=v7.2.11` downloads this upstream tag instead of the one derived from `uname -r`;
- `SKIP_VERIFY=1` builds even if the source does not match your distro's driver (at your own risk).

## Secure Boot

With Secure Boot enabled, the kernel only loads signed modules. DKMS signs the module with its own key; enroll that key once and reboot:

```
sudo mokutil --import /var/lib/dkms/mok.pub
```

## Kernel updates

DKMS rebuilds the fix whenever a new kernel is installed. If a new kernel changes `btusb.c` so the patch no longer applies, the build fails, the new kernel keeps its stock driver and the problem comes back until this repository is updated. The weekly [CI job](.github/workflows/build.yml) builds against the newest Fedora kernel to catch that early.

## Uninstall

```
sudo ./uninstall.sh --reload
```

DKMS puts the original driver back.

## Upstream status

The bug is in the Linux kernel. A different fix for the same race was proposed on the linux-bluetooth mailing list in July 2026 ([discussion](https://lists.openwall.net/linux-kernel/2026/07/31/1885)) and had not been merged at the time of writing. Its proposed 4 ms window would be too short for some connections on the RTL8852BU, where gaps of up to 12 ms were measured. Once your kernel includes a fix, uninstall this one.

Without patching anything, the 2.4 GHz receiver of the mouse (if it has one) avoids the problem.

## License

GPL-2.0, like the Linux kernel code it modifies. See [LICENSE](LICENSE).

---

## Português

Correção para mouses e teclados Bluetooth LE que **travam ou desconectam cerca de 30 segundos depois de conectar no Linux**. Confirmada com o **Keychron M6 8K** e o adaptador **Realtek RTL8852BU**.

O sinal no log do kernel é `ACL packet for unknown connection handle`. Alguns adaptadores USB entregam o primeiro pacote do dispositivo antes de anunciar a conexão, e o kernel descarta esse pacote. Sem resposta, o mouse para de enviar dados após 30 s.

Instalação (recompila sozinha a cada atualização do kernel):

```
git clone https://github.com/caiolombello/btusb-early-acl-fix.git
cd btusb-early-acl-fix
sudo ./install.sh --reload
```

Para conferir: `./diagnose.sh`. Para remover: `sudo ./uninstall.sh --reload`.
