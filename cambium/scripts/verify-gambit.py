#!/usr/bin/env python3
"""Verify the actual E400 uImage, appended DT and NAND partition layout.

Usage: verify-gambit.py recovery|installer|persistent IMAGE
No external FDT tools are required (Gambit uses legacy uImages, not FITs).
"""
import lzma
import struct
import sys
import zlib


def require(condition, message):
    if not condition:
        sys.exit("Gambit image verification failed: " + message)


def dt_properties(data):
    start = data.rfind(b"\xd0\x0d\xfe\xed")
    require(start >= 0, "no appended device tree")
    tree = data[start:]
    require(len(tree) >= 40, "truncated device tree header")
    _, total, structures, strings, _, version, _, _, string_size, struct_size = struct.unpack(
        ">10I", tree[:40])
    require(version >= 17 and total <= len(tree), "invalid device tree header")
    require(structures + struct_size <= total and strings + string_size <= total,
            "invalid device tree bounds")
    table = tree[strings:strings + string_size]
    pos, end, stack, nodes = structures, structures + struct_size, [], {}
    while pos + 4 <= end:
        token = struct.unpack_from(">I", tree, pos)[0]
        pos += 4
        if token == 1:  # FDT_BEGIN_NODE
            stop = tree.index(0, pos, end)
            stack.append(tree[pos:stop].decode())
            pos = (stop + 4) & ~3
            nodes.setdefault("/" + "/".join(stack[1:]), {})
        elif token == 2:
            require(bool(stack), "unbalanced device tree")
            stack.pop()
        elif token == 3:
            length, name = struct.unpack_from(">II", tree, pos)
            pos += 8
            require(pos + length <= end and name < len(table), "invalid DT property")
            key = table[name:table.index(0, name)].decode()
            nodes["/" + "/".join(stack[1:])][key] = tree[pos:pos + length]
            pos = (pos + length + 3) & ~3
        elif token == 4:
            continue
        elif token == 9:
            require(not stack, "unclosed device tree nodes")
            return nodes
        else:
            require(False, "invalid device tree token")
    require(False, "device tree has no end token")


def verify_factory_mac(nodes):
    """Ethernet keeps OEM identity instead of borrowing a radio's ART MAC."""
    ethernet = [properties for path, properties in nodes.items()
                if path.endswith("/eth@19000000")]
    require(len(ethernet) == 1, "Ethernet node is missing or ambiguous")
    ethernet = ethernet[0]
    require(ethernet.get("nvmem-cell-names") == b"mac-address\0",
            "Ethernet has no factory MAC reference")
    reference = ethernet.get("nvmem-cells", b"")
    require(len(reference) == 8, "Ethernet MAC must use indexed factory cell")
    phandle, index = struct.unpack(">II", reference)
    require(index == 0, "Ethernet must use the unmodified OEM MAC")
    cells = [(path, properties) for path, properties in nodes.items()
             if properties.get("phandle") == struct.pack(">I", phandle)]
    require(len(cells) == 1, "factory MAC cell reference is ambiguous")
    path, cell = cells[0]
    require(cell.get("compatible") == b"mac-base\0" and
            cell.get("reg") == struct.pack(">II", 6, 12) and
            cell.get("#nvmem-cell-cells") == struct.pack(">I", 1),
            "factory MAC must decode twelve hexadecimal digits at offset 6")
    parent = nodes.get(path.rsplit("/", 2)[0], {})
    require(parent.get("label") == b"mfginfo\0", "Ethernet MAC is not from mfginfo")


def verify_leds(nodes):
    """Hardware-verified LED channels, including the unusual amber polarity."""
    expected = {"green:status": (19, 1), "amber:status": (22, 0),
                "green:lan": (20, 1), "amber:lan": (18, 1)}
    led_nodes = {properties.get("label", b"").rstrip(b"\0").decode(): (path, properties)
                 for path, properties in nodes.items() if path.startswith("/leds/")}
    require(set(led_nodes) == set(expected), "wrong E400 LED channels")
    controllers = set()
    for label, (pin, polarity) in expected.items():
        _, properties = led_nodes[label]
        gpios = properties.get("gpios", b"")
        require(len(gpios) == 12, "invalid LED GPIO: " + label)
        controller, actual_pin, actual_polarity = struct.unpack(">III", gpios)
        controllers.add(controller)
        require((actual_pin, actual_polarity) == (pin, polarity),
                "wrong LED GPIO/polarity: " + label)
        require(properties.get("default-state") == b"off\0",
                "LED must start off: " + label)
    require(len(controllers) == 1, "LED GPIO controllers differ")
    controller = next(iter(controllers))
    gpio = [properties for properties in nodes.values()
            if properties.get("phandle") == struct.pack(">I", controller)]
    require(len(gpio) == 1 and "gpio-controller" in gpio[0] and
            b"qca,ar9340-gpio" in gpio[0].get("compatible", b"").split(b"\0"),
            "LEDs must use the SoC GPIO controller")
    for alias, label in (("led-boot", "green:status"),
                         ("led-running", "green:status"),
                         ("led-failsafe", "amber:status"),
                         ("led-upgrade", "amber:status")):
        path = led_nodes[label][0]
        require(nodes.get("/aliases", {}).get(alias) == path.encode() + b"\0",
                "wrong LED lifecycle alias: " + alias)


def main():
    require(len(sys.argv) == 3, __doc__)
    flavour, path = sys.argv[1:]
    require(flavour in ("recovery", "installer", "persistent"), "unknown flavour")
    with open(path, "rb") as file:
        image = file.read()
    require(len(image) > 64, "empty or truncated uImage")
    magic, header_crc, _, size, load, entry, data_crc = struct.unpack(">7I", image[:28])
    require(magic == 0x27051956, "not a legacy uImage")
    require(image[28:32] == bytes((5, 5, 2, 3)), "not Linux/MIPS/kernel/LZMA")
    require(load == entry == 0x80060000, "unexpected load or entry address")
    require(size == len(image) - 64, "payload length mismatch")
    require(zlib.crc32(image[:4] + bytes(4) + image[8:64]) == header_crc,
            "header CRC mismatch")
    require(zlib.crc32(image[64:]) == data_crc, "payload CRC mismatch")
    payload = lzma.decompress(image[64:], format=lzma.FORMAT_ALONE)
    require(load + len(payload) <= 0x83000000, "expanded kernel overlaps the nboot source")
    if flavour == "persistent":
        require(len(image) <= 3840 * 1024, "kernel lacks its bad-block reserve")
    nodes = dt_properties(payload)
    require(b"cambiumnetworks,e400" in nodes["/"]["compatible"].split(b"\0"),
            "wrong board compatible")
    require(nodes["/cambium-platform"]["board-sku"] == struct.pack(">I", 6), "wrong SKU")
    bootargs = nodes.get("/chosen", {}).get("bootargs")
    require((bootargs is None) == (flavour == "persistent"),
            "persistent must take bootargs from U-Boot; RAM must use DT bootargs")
    parts = {}
    for properties in nodes.values():
        if "label" in properties and "reg" in properties:
            label = properties["label"].rstrip(b"\0").decode()
            if label in ("linux0", "rootfs0", "linux1", "rootfs1", "nvram",
                         "u-boot", "u-boot-env", "CrashLog", "mfginfo", "ART"):
                require(label not in parts, "duplicate partition " + label)
                parts[label] = properties
    kernel = 0x300000 if flavour == "recovery" else 0x400000
    geometry = {
        "linux0": (0, kernel), "rootfs0": (kernel, 0x3000000 - kernel),
        "linux1": (0x3000000, kernel),
        "rootfs1": (0x3000000 + kernel, 0x3000000 - kernel),
        "nvram": (0x6000000, 0x2000000), "u-boot": (0, 0x40000),
        "u-boot-env": (0x40000, 0x10000), "CrashLog": (0x50000, 0x790000),
        "mfginfo": (0x7e0000, 0x10000), "ART": (0x7f0000, 0x10000),
    }
    for label, reg in geometry.items():
        require(label in parts and parts[label]["reg"] == struct.pack(">II", *reg),
                "wrong partition geometry: " + label)
        protected = flavour == "recovery" or label not in (
            "linux0", "rootfs0", "linux1", "rootfs1", "u-boot-env")
        require(("read-only" in parts[label]) == protected,
                "wrong partition protection: " + label)
    verify_factory_mac(nodes)
    verify_leds(nodes)
    controllers = [properties for properties in nodes.values()
                   if b"qca,ar934x-nand" in properties.get("compatible", b"").split(b"\0")]
    require(len(controllers) == 1, "NAND controller missing or ambiguous")
    nand = controllers[0]
    require(nand.get("nand-ecc-mode") == b"soft\0" and
            nand.get("nand-ecc-algo") == b"hamming\0" and
            nand.get("nand-ecc-step-size") == struct.pack(">I", 256) and
            nand.get("nand-ecc-strength") == struct.pack(">I", 1),
            "NAND must use OEM-compatible 256-byte/1-bit software Hamming ECC")
    print(f"Gambit {flavour}: uImage CRCs, LZMA, E400 DT (MAC/LED/ECC) and partition protection OK "
          f"({len(image)} bytes; expands to {len(payload)} bytes)")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, IndexError, struct.error, lzma.LZMAError) as error:
        sys.exit("Gambit image verification failed: " + str(error))
