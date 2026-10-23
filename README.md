# dualboot-bluetooth-sync

Use one Bluetooth mouse (or keyboard, headset, …) in both Windows and Ubuntu on a
dual-boot PC, without pairing it again every time you switch.

## Why pairing breaks

When you pair, the device and the PC agree on a secret key. The device keeps only
the newest key. So pairing in Windows breaks the pairing in Ubuntu, and the other
way round. (Microsoft Bluetooth mice also take a new address every time you pair.)

The fix: pair once in **Windows**, then copy that key into Ubuntu. Both systems
then use the same key, and the device works in both.

## Steps

**1. Windows:** Settings → Bluetooth & devices. Remove every old entry of the
device, pair it again, check that it works.

**2. Windows:** Start → Power → **Restart** (not "Shut down") and boot into Ubuntu.
The device will not work in Ubuntu yet; that is expected.

**3. Ubuntu:** get this repo and run the script:

```bash
git clone https://github.com/ziash/dualboot-bluetooth-sync.git
cd dualboot-bluetooth-sync
sudo bash bt-sync-from-windows.sh
```

You should see one line per device, ending in `key copied from Windows`.
If the device does not connect within a few seconds, switch it off and on.

**4. From now on, never pair the device again in either system.** If you ever do,
repeat steps 1–3.

## What the script does

1. Finds the Windows partition and mounts it **read-only** (Windows is never changed).
2. Reads the Bluetooth keys from the Windows registry file
   `Windows/System32/config/SYSTEM` (installs `python3-hivex`, a registry-file reader, if needed).
3. Stops Bluetooth, backs up `/var/lib/bluetooth` to `/var/lib/bluetooth.bak-<date>`.
4. Writes the keys into Ubuntu's Bluetooth settings (BlueZ, the Linux Bluetooth
   service). If Ubuntu knew the device under an old address, that entry is moved
   to the new address.
5. Starts Bluetooth again.

Works for Bluetooth Low Energy devices (most modern mice and keyboards) and classic
Bluetooth devices. If the Windows partition is not found, pass the registry file:

```bash
sudo bash bt-sync-from-windows.sh /path/to/Windows/System32/config/SYSTEM
```

## Undo

```bash
sudo systemctl stop bluetooth
sudo rm -rf /var/lib/bluetooth
sudo cp -a /var/lib/bluetooth.bak-<date> /var/lib/bluetooth
sudo systemctl start bluetooth
```

## License

MIT
