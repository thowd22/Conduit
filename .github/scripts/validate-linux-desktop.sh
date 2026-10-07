#!/usr/bin/env bash
set -euo pipefail

artifact_root="${1:?usage: validate-linux-desktop.sh ARTIFACT_ROOT}"
app_id="io.github.thowd22.Conduit"
desktop="zig-out/share/applications/$app_id.desktop"
icon_sizes=(16 22 24 32 48 64 128 256 512)

mkdir -p "$artifact_root"
desktop-file-validate "$desktop" 2>"$artifact_root/desktop-validation.txt"
cp -- "$desktop" "$artifact_root/$app_id.desktop"

# Every installed hicolor icon must be a PNG whose IHDR declares its directory's size. The
# signature and IHDR are the first 24 bytes of any valid PNG, so they are read directly.
for size in "${icon_sizes[@]}"; do
  icon="zig-out/share/icons/hicolor/${size}x${size}/apps/$app_id.png"
  if [ ! -f "$icon" ]; then
    echo "missing icon: $icon" >&2
    exit 1
  fi
  python3 - "$icon" "$size" <<'PY'
import struct
import sys

path, size = sys.argv[1], int(sys.argv[2])
with open(path, "rb") as handle:
    header = handle.read(24)
if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
    sys.exit(f"{path}: not a PNG")
width, height = struct.unpack(">II", header[16:24])
if (width, height) != (size, size):
    sys.exit(f"{path}: {width}x{height}, expected {size}x{size}")
print(f"icon {size}x{size}: PNG {width}x{height}")
PY
done | tee "$artifact_root/icon-validation.txt"

cp -- "zig-out/share/icons/hicolor/256x256/apps/$app_id.png" "$artifact_root/icon-256.png"
