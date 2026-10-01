#!/usr/bin/env python3
"""Check an OEM raw 2048+64 NAND dump against 256-byte Linux Hamming ECC.

Usage: verify-gambit-ecc.py RAW_DUMP (use - for stdin).
Read-only diagnostic; never generates an image for writing.
"""
import sys


def hamming256(data):
    if len(data) != 256:
        raise ValueError("Hamming step must be 256 bytes")
    columns = (0x55, 0x56, 0x59, 0x5a, 0x65, 0x66, 0x69, 0x6a)
    column = odd_rows = even_rows = 0
    for address, value in enumerate(data):
        parity = 0
        for bit, mask in enumerate(columns):
            if value & (1 << bit):
                parity ^= mask
        column ^= parity & 0x3f
        if parity & 0x40:
            odd_rows ^= address
            even_rows ^= address ^ 0xff
    upper = lower = 0
    for bit in range(4):
        upper |= ((odd_rows >> (bit + 4)) & 1) << (2 * bit + 1)
        upper |= ((even_rows >> (bit + 4)) & 1) << (2 * bit)
        lower |= ((odd_rows >> bit) & 1) << (2 * bit + 1)
        lower |= ((even_rows >> bit) & 1) << (2 * bit)
    return bytes((upper ^ 0xff, lower ^ 0xff, ((column ^ 0x3f) << 2) | 3))


def verify(raw):
    if not raw or len(raw) % 2112:
        raise ValueError("dump must contain complete 2048+64-byte pages")
    pages = len(raw) // 2112
    for page in range(pages):
        start = page * 2112
        data = raw[start:start + 2048]
        expected = b"".join(hamming256(data[step:step + 256])
                            for step in range(0, 2048, 256))
        observed = raw[start + 2048 + 40:start + 2112]
        if expected != observed:
            raise ValueError(f"page {page}: Hamming/OOB mismatch: "
                             f"calculated {expected.hex()}, stored {observed.hex()}")
    return pages


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with (sys.stdin.buffer if sys.argv[1] == "-" else open(sys.argv[1], "rb")) as stream:
        raw = stream.read()
    try:
        pages = verify(raw)
    except ValueError as error:
        sys.exit(str(error))
    print(f"{pages} pages match Linux 256-byte/1-bit software Hamming ECC "
          "at OOB offsets 40..63")
