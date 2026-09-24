#!/usr/bin/env python3
"""Write the per-family release manifest and cross-check it against the FITs.

Usage:
  manifest.py FAMILIES_JSON FAMILY IMAGES_DIR RELEASE_FILE [FLAVOUR=FIT ...]

FLAVOUR=FIT pairs name each built family FIT (recovery, installer or
persistent). Every configuration that families.json lists for that flavour
must exist in the FIT, so the data cannot drift from the images. The manifest
is written to IMAGES_DIR/cambium-manifest.json.
"""

import hashlib
import json
import os
import re
import subprocess
import sys


def fit_configs(path):
    out = subprocess.run(["fdtget", "-l", path, "/configurations"],
                         check=True, capture_output=True, text=True).stdout
    return set(out.split())


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def role(name, devices):
    rules = [
        ("imagebuilder", r"imagebuilder"),
        ("recovery", re.escape(devices.get("recovery", "\0")) + r"-initramfs-"),
        ("installer", re.escape(devices.get("installer", "\0")) + r"-initramfs-"),
        ("persistent-sysupgrade", re.escape(devices.get("persistent", "\0")) + r"-.*sysupgrade\.bin$"),
        ("persistent-factory", re.escape(devices.get("persistent", "\0")) + r"-.*factory\.ubi$"),
        ("persistent-kernel", re.escape(devices.get("persistent", "\0")) + r"-.*kernel\.itb$"),
        ("persistent-rootfs", re.escape(devices.get("persistent", "\0")) + r"-.*rootfs\.(ubifs|squashfs)$"),
    ]
    for r, pattern in rules:
        if re.search(pattern, name):
            return r
    return None


def main():
    if len(sys.argv) < 5:
        sys.exit(__doc__)
    families_json, family, images, release_file = sys.argv[1:5]
    fits = dict(arg.split("=", 1) for arg in sys.argv[5:])

    fam = next(f for f in json.load(open(families_json))["families"] if f["family"] == family)
    release = dict(re.findall(r"^(\w+)='(.*)'$", open(release_file).read(), re.M))

    errors = []
    for flavour, path in fits.items():
        present = fit_configs(path)
        for m in fam["models"]:
            config = (m.get(flavour) or {}).get("config")
            if config and config not in present:
                errors.append(f"{m['model']} {flavour} {config} missing from {os.path.basename(path)}")
    if errors:
        sys.exit("families.json does not match the built FITs:\n  " + "\n  ".join(errors))

    devices = fam.get("devices", {})
    image_list = []
    for name in sorted(os.listdir(images)):
        r = role(name, devices)
        if r:
            path = os.path.join(images, name)
            image_list.append({"file": name, "role": r, "size": os.path.getsize(path),
                               "sha256": sha256(path)})
    # Every family publishes a recovery image and at least one way to install
    # the persistent image: a factory UBI (Thor, Cheetah, Jaguar) or the
    # kernel/rootfs pair and sysupgrade archive (Sage).
    roles = {i["role"] for i in image_list}
    if "recovery" not in roles:
        sys.exit("manifest: no recovery image found")
    if not ("persistent-factory" in roles or
            {"persistent-kernel", "persistent-rootfs"} <= roles):
        sys.exit("manifest: no persistent factory image or kernel/rootfs pair found")

    manifest = {
        "schema": 1,
        "family": family,
        "name": fam["name"],
        "platform": fam["platform"],
        "target": fam["target"],
        "stock_firmware": fam["stock_firmware"],
        "build_id": release.get(fam["name"].upper() + "_BUILD_ID"),
        "source_commit": release.get("CAMBIUM_SOURCE_COMMIT"),
        "upstream_commit": release.get("OPENWRT_UPSTREAM_COMMIT"),
        "devices": devices,
        "models": fam["models"],
        "images": image_list,
    }
    with open(os.path.join(images, "cambium-manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    print(f"manifest: {len(fam['models'])} models, {len(image_list)} images, "
          f"FIT configurations checked for {', '.join(fits) or 'none'}")


if __name__ == "__main__":
    main()
