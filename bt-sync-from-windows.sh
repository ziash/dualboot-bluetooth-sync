#!/usr/bin/env bash
# Copy Bluetooth pairing keys from Windows into Ubuntu (BlueZ), so a device
# paired in Windows also works in Ubuntu without pairing it again.
#
# Why: every pairing makes a new secret key, and the device keeps only the
# latest one. Pairing in Windows therefore breaks Ubuntu's pairing. This
# script gives Ubuntu the same key Windows has, so both systems match.
# (Microsoft mice also take a new address on every pairing; handled here.)
#
# Order:
#   1. Windows: remove old entries of the device, pair it, check it works.
#   2. Windows: Start > Power > Restart (not "Shut down") into Ubuntu.
#   3. Ubuntu:  sudo bash bt-sync-from-windows.sh
#   4. Never pair the device again in either system.
#
# The Windows partition is mounted read-only. /var/lib/bluetooth is backed up
# to /var/lib/bluetooth.bak-<date> before any change.
# Optional argument: path to a Windows SYSTEM registry file.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

WORK=$(mktemp -d /tmp/btsync.XXXX)
MNT=""
BT_STOPPED=0
cleanup() {
  [[ -n "$MNT" ]] && { umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; }
  [[ $BT_STOPPED -eq 1 ]] && systemctl start bluetooth
  rm -rf "$WORK"
}
trap cleanup EXIT

HIVE_REL="Windows/System32/config/SYSTEM"
HIVE="${1:-}"

# 1. Find the Windows SYSTEM registry file and copy it.
if [[ -z "$HIVE" ]]; then
  while read -r target; do
    [[ -f "$target/$HIVE_REL" ]] && { HIVE="$target/$HIVE_REL"; break; }
  done < <(findmnt -rn -t ntfs,ntfs3,fuseblk -o TARGET | sed 's/\\x20/ /g')
fi
if [[ -z "$HIVE" ]]; then
  while read -r name fstype; do
    [[ "$fstype" == ntfs ]] || continue
    findmnt -rn -S "/dev/$name" >/dev/null && continue
    MNT=$(mktemp -d /tmp/winmnt.XXXX)
    if mount -t ntfs-3g -o ro "/dev/$name" "$MNT" 2>/dev/null \
       || mount -t ntfs3 -o ro "/dev/$name" "$MNT" 2>/dev/null; then
      if [[ -f "$MNT/$HIVE_REL" ]]; then HIVE="$MNT/$HIVE_REL"; break; fi
      umount "$MNT"
    fi
    rmdir "$MNT"; MNT=""
  done < <(lsblk -rno NAME,FSTYPE)
fi
[[ -n "$HIVE" && -f "$HIVE" ]] || { echo "Windows partition not found. Pass the SYSTEM file path as argument."; exit 1; }
echo "Windows registry: $HIVE"
cp "$HIVE" "$WORK/SYSTEM"
if [[ -n "$MNT" ]]; then umount "$MNT"; rmdir "$MNT"; MNT=""; fi

# 2. Registry reader (hivex).
python3 -c 'import hivex' 2>/dev/null || apt-get install -y python3-hivex

# 3. Stop Bluetooth, back up, write the keys, start Bluetooth again.
systemctl stop bluetooth
BT_STOPPED=1
BACKUP="/var/lib/bluetooth.bak-$(date +%Y%m%d-%H%M%S)"
cp -a /var/lib/bluetooth "$BACKUP"
echo "Backup: $BACKUP"

python3 - "$WORK/SYSTEM" <<'PY'
import configparser, glob, os, re, sys
import hivex

h = hivex.Hivex(sys.argv[1])

def child(node, name):
    for c in h.node_children(node):
        if h.node_name(c).lower() == name.lower():
            return c
    return None

def path(*names):
    n = h.root()
    for name in names:
        n = child(n, name)
        if n is None:
            return None
    return n

def values(node):
    return {h.value_key(v): h.value_value(v)[1] for v in h.node_values(node)}

def num(b):
    return int.from_bytes(b, "little")

def mac(hexstr):
    return ":".join(hexstr[i:i + 2] for i in range(0, 12, 2)).upper()

cs = "ControlSet%03d" % num(values(path("Select"))["Current"])
params = path(cs, "Services", "BTHPORT", "Parameters")
keys = child(params, "Keys") if params is not None else None
devs = child(params, "Devices") if params is not None else None
if keys is None:
    sys.exit("No Bluetooth keys in Windows. Pair the device in Windows first, then Restart.")

def win_name(dev_hex):
    d = child(devs, dev_hex) if devs is not None else None
    raw = values(d).get("Name", b"") if d is not None else b""
    return raw.split(b"\0")[0].decode("utf-8", "replace")

def read_info(p):
    cp = configparser.ConfigParser(interpolation=None)
    cp.optionxform = str
    if os.path.exists(p):
        cp.read(p)
    return cp

def write_info(p, cp):
    tmp = p + ".tmp"
    with open(tmp, "w") as f:
        cp.write(f, space_around_delimiters=False)
    os.chmod(tmp, 0o600)
    os.replace(tmp, p)

# Windows entries: classic devices are values under the adapter key,
# Bluetooth LE devices are subkeys of it.
entries = []
for ad in h.node_children(keys):
    adapter = mac(h.node_name(ad))
    for k, v in values(ad).items():
        if re.fullmatch(r"[0-9a-fA-F]{12}", k) and len(v) == 16:
            entries.append(dict(adapter=adapter, hex=k.lower(), le=False, data={"LinkKey": v}, ts=0))
    for dn in h.node_children(ad):
        dv = values(dn)
        if "LTK" in dv:
            entries.append(dict(adapter=adapter, hex=h.node_name(dn).lower(), le=True, data=dv,
                                ts=h.node_timestamp(dn)))

# The same LE device paired several times in Windows: use only the newest pairing.
newest = {}
for e in entries:
    e["name"] = win_name(e["hex"])
    if e["le"] and e["name"]:
        k = (e["adapter"], e["name"])
        if k not in newest or e["ts"] > newest[k]["ts"]:
            newest[k] = e
entries = [e for e in entries if not (e["le"] and e["name"]) or newest[(e["adapter"], e["name"])] is e]

if not entries:
    sys.exit("No paired devices found in Windows.")

for e in entries:
    dev = mac(e["hex"])
    base = "/var/lib/bluetooth/" + e["adapter"]
    label = "%s (%s)" % (e["name"] or "?", dev)
    if not os.path.isdir(base):
        print("skip %s: Ubuntu has no adapter %s" % (label, e["adapter"]))
        continue
    target = os.path.join(base, dev)
    if not os.path.exists(os.path.join(target, "info")):
        # Ubuntu may know this device under its old address: move that entry.
        old = [d for d in glob.glob(base + "/??:??:??:??:??:??")
               if e["name"] and read_info(d + "/info").get("General", "Name", fallback=None) == e["name"]]
        if old:
            old.sort(key=os.path.getmtime)
            if os.path.exists(target):
                os.rmdir(target)
            os.rename(old[-1], target)
            print("%s: reused Ubuntu entry %s" % (label, os.path.basename(old[-1])))
        else:
            os.makedirs(target, mode=0o700, exist_ok=True)
    info = os.path.join(target, "info")
    cp = read_info(info)
    if "General" not in cp:
        cp["General"] = {}
    g = cp["General"]
    if e["name"]:
        g.setdefault("Name", e["name"])
    g.setdefault("Trusted", "true")
    g.setdefault("Blocked", "false")
    d = e["data"]
    if e["le"]:
        static = num(d.get("AddressType", b"\1")) == 1
        g["AddressType"] = "static" if static else "public"
        g.setdefault("SupportedTechnologies", "LE;")
        ediv, rand = num(d.get("EDIV", b"\0")), num(d.get("ERand", b"\0"))
        sc = ediv == 0 and rand == 0
        mitm = bool(num(d.get("AuthReq", b"\0")) & 0x04)
        cp["LongTermKey"] = {
            "Key": d["LTK"].hex().upper(),
            "Authenticated": str((2 if sc else 0) + (1 if mitm else 0)),
            "EncSize": str(num(d.get("KeyLength", b"\x10"))),
            "EDiv": str(ediv),
            "Rand": str(rand),
        }
        if static:
            # The old identity key belongs to the old pairing; a static address needs none.
            cp.remove_section("IdentityResolvingKey")
    else:
        g.setdefault("SupportedTechnologies", "BR/EDR;")
        lk = cp["LinkKey"] if "LinkKey" in cp else {}
        cp["LinkKey"] = {"Key": d["LinkKey"].hex().upper(), "Type": lk.get("Type", "4"),
                         "PINLength": lk.get("PINLength", "0")}
    write_info(info, cp)
    print("%s: key copied from Windows" % label)
PY

echo "Done. Turn the mouse off and on (or move it) if it does not connect within a few seconds."
