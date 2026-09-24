#!/usr/bin/env python3
"""Generate select-config.sh from cambium/families.json.

The generated POSIX shell script runs on the access point's stock firmware.
It reads the board SKU and prints the model and the FIT configuration to boot
for the requested image, refusing unknown SKUs and images that are not built
for that model.
"""

import json
import sys

FLAVOURS = ("recovery", "installer", "persistent")


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: gen-select-config.py families.json > select-config.sh")
    with open(sys.argv[1]) as f:
        families = json.load(f)["families"]

    cases = []
    for fam in families:
        for m in fam["models"]:
            lines = [f"\t{m['sku']})", f"\t\tfamily={fam['family']} model={m['model']}"]
            for flavour in FLAVOURS:
                entry = m.get(flavour)
                if entry is None:
                    continue
                var = flavour
                if entry.get("config"):
                    lines.append(f"\t\t{var}_config={entry['config']} {var}_status={entry['status']}")
                else:
                    note = entry.get("note") or ("no OpenWrt build for this family yet"
                                                 if entry["status"] == "no-build" else "not built")
                    note = note.replace("'", "'\\''")
                    lines.append(f"\t\t{var}_status={entry['status']} {var}_note='{note}'")
            lines.append("\t\t;;")
            cases.append("\n".join(lines))

    print("""#!/bin/sh
# Generated from cambium/families.json by cambium/scripts/gen-select-config.py.
# Run on the access point's stock firmware as root:
#   sh select-config.sh recovery|installer|persistent
# Prints FAMILY, MODEL, SKU, CONFIG and STATUS as shell assignments, e.g.
#   eval "$(sh select-config.sh recovery)" && echo "$CONFIG"
# Exits non-zero, printing nothing on stdout, for an unknown SKU or an image
# that is not built for this model.

flavour=${1:-}
case "$flavour" in
recovery|installer|persistent) ;;
*) echo "usage: $0 recovery|installer|persistent" >&2; exit 2 ;;
esac

sku=
node=/proc/device-tree/cambium-platform/board-sku
if [ -r "$node" ]; then
	hex=$(od -An -tx1 "$node" | tr -d ' \\n')
	[ -n "$hex" ] && sku=$(printf '%d' "0x$hex")
fi
if [ -z "$sku" ] && [ -r /proc/sku ]; then
	sku=$(tr -dc '0-9' < /proc/sku)
fi
[ -n "$sku" ] || { echo "Cannot read the board SKU on this firmware" >&2; exit 1; }

family= model=
case "$sku" in
""" + "\n".join(cases) + """
	*) echo "Unknown board SKU $sku: not a known Cambium model, do not install" >&2; exit 1 ;;
esac

eval "config=\\${${flavour}_config:-} status=\\${${flavour}_status:-} note=\\${${flavour}_note:-}"
if [ -z "$status" ]; then
	echo "$model (SKU $sku, $family): no $flavour image for this family" >&2
	exit 1
fi
if [ -z "$config" ]; then
	echo "$model (SKU $sku, $family): no $flavour image: $note" >&2
	exit 1
fi
[ "$status" = validated ] ||
	echo "Warning: $model $flavour image is $status on hardware; trial only on a unit you can recover" >&2
printf "FAMILY='%s'\\nMODEL='%s'\\nSKU='%s'\\nCONFIG='%s'\\nSTATUS='%s'\\n" \\
	"$family" "$model" "$sku" "$config" "$status"
""", end="")


if __name__ == "__main__":
    main()
