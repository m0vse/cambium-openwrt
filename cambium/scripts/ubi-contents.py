#!/usr/bin/env python3
"""Print the content of a factory UBI image's kernel and rootfs volumes as
"volume bytes sha256" lines: the FIT's own size (its FDT header totalsize)
and the SquashFS bytes_used, without UBI or image padding. The installer
hashes the same bytes after writing the image to flash.

Usage: ubi-contents.py FACTORY.ubi [PEB_SIZE]   (PEB size default 131072)
"""
import hashlib
import struct
import sys

LAYOUT_VOLUME = 0x7FFFEFFF


def main():
    path = sys.argv[1]
    peb = int(sys.argv[2]) if len(sys.argv) > 2 else 131072
    data = open(path, "rb").read()
    if len(data) % peb or data[:4] != b"UBI#":
        sys.exit(f"{path}: not a UBI image with {peb}-byte eraseblocks")
    vid_off, data_off = struct.unpack(">II", data[16:24])
    leb = peb - data_off
    names, lebs = {}, {}
    for i in range(len(data) // peb):
        block = data[i * peb:(i + 1) * peb]
        vid = block[vid_off:vid_off + 64]
        if vid[:4] != b"UBI!":
            continue
        vol_id, lnum = struct.unpack(">II", vid[8:16])
        payload = block[data_off:data_off + leb]
        if vol_id == LAYOUT_VOLUME:
            if lnum == 0:
                for r in range(128):
                    rec = payload[r * 172:(r + 1) * 172]
                    reserved, name_len = struct.unpack(">I", rec[:4])[0], struct.unpack(">H", rec[14:16])[0]
                    if reserved:
                        names[rec[16:16 + name_len].decode()] = r
            continue
        lebs.setdefault(vol_id, {})[lnum] = payload
    volume = {}
    for name, vol_id in names.items():
        parts = lebs.get(vol_id, {})
        volume[name] = b"".join(parts[n] for n in sorted(parts))

    kernel = volume.get("kernel", b"")
    if kernel[:4] != b"\xd0\x0d\xfe\xed":
        sys.exit(f"{path}: kernel volume is not a FIT")
    ksize = struct.unpack(">I", kernel[4:8])[0]
    root = volume.get("rootfs", b"")
    if root[:4] != b"hsqs":
        sys.exit(f"{path}: rootfs volume is not SquashFS")
    rsize = struct.unpack("<Q", root[40:48])[0]
    for name, blob, size in (("kernel", kernel, ksize), ("rootfs", root, rsize)):
        if size > len(blob):
            sys.exit(f"{path}: {name} claims {size} bytes but the volume holds {len(blob)}")
        print(name, size, hashlib.sha256(blob[:size]).hexdigest())


if __name__ == "__main__":
    main()
