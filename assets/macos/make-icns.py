#!/usr/bin/env python3
"""Write assets/macos/AppIcon.icns from the checked-in hicolor PNG renders.

Usage: make-icns.py <png-1024> <output.icns>

An .icns file is the 8-byte header `icns` + total length (big-endian), then one
element per image: a 4-byte OSType, a 4-byte big-endian length that includes
the 8-byte element header, and the payload. Every OSType used here takes a PNG
payload (macOS 10.7 and later), so the renders are embedded byte for byte and
no image is re-encoded. The 1024 render is not checked in as a hicolor size; it
is passed in (see assets/macos/README.md for the exact `convert` command).
"""

import pathlib
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
HICOLOR = ROOT / "assets/linux/icons/hicolor"

# OSType -> pixel size. ic11..ic14 are the @2x variants of 16, 32, 128 and 256.
ELEMENTS = [
    ("icp4", 16),
    ("ic11", 32),
    ("icp5", 32),
    ("ic12", 64),
    ("ic07", 128),
    ("ic13", 256),
    ("ic08", 256),
    ("ic14", 512),
    ("ic09", 512),
    ("ic10", 1024),
]


def png_for(size: int, png_1024: pathlib.Path) -> bytes:
    path = png_1024 if size == 1024 else HICOLOR / f"{size}x{size}/apps/io.github.thowd22.Conduit.png"
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise SystemExit(f"{path}: not a PNG")
    width, height = struct.unpack(">II", data[16:24])
    if (width, height) != (size, size):
        raise SystemExit(f"{path}: {width}x{height}, expected {size}x{size}")
    return data


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    png_1024 = pathlib.Path(sys.argv[1])
    body = b""
    for ostype, size in ELEMENTS:
        data = png_for(size, png_1024)
        body += ostype.encode("ascii") + struct.pack(">I", len(data) + 8) + data
    pathlib.Path(sys.argv[2]).write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


if __name__ == "__main__":
    main()
