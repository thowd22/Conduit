#!/usr/bin/env bash
# Give Conduit an OpenGL 3.3 core driver on a GitHub Windows runner.
#
# Usage: windows-mesa.sh <dir>...
#
# Hosted Windows runners have no GPU and no display driver beyond Microsoft's
# basic adapter, so the only OpenGL on them is the GDI generic implementation
# (OpenGL 1.1): Conduit's GL 3.3 loader stops at once with
# OpenGL_FunctionNotFound (glDrawRangeElements). Mesa's llvmpipe is the
# Windows equivalent of the Xvfb/llvmpipe stack the Linux gate draws with:
# pal1000/mesa-dist-win's release build, pinned by version and SHA-256, whose
# opengl32.dll and its gallium driver are copied beside each conduit.exe
# (Windows looks for opengl32.dll in the program's directory before
# System32). This is a test fixture for GPU-less runners, not part of the
# shipped zip: on a Windows machine with a display driver the system OpenGL is
# used.
set -euo pipefail

version=26.2.4
sha256=351fc8c8b695878ffb3eaa044b3ead08672a48b1a045e3c3e3975811df0f6695
archive="mesa3d-$version-release-msvc.7z"
url="https://github.com/pal1000/mesa-dist-win/releases/download/$version/$archive"
[ "$#" -gt 0 ] || { echo "usage: windows-mesa.sh <dir>..." >&2; exit 2; }

work="${RUNNER_TEMP:-/tmp}/mesa-$version"
mkdir -p "$work"
if [ ! -f "$work/$archive" ]; then
  curl -fsSL --retry 3 -o "$work/$archive" "$url"
fi
echo "$sha256  $work/$archive" | sha256sum -c -
rm -rf "$work/x"
7z x -y -o"$(cygpath -w "$work/x")" "$(cygpath -w "$work/$archive")" > /dev/null
ls "$work/x/x64" | grep -iE '\.dll$' | tr '\n' ' '
echo
for dir in "$@"; do
  mkdir -p "$dir"
  for dll in opengl32.dll libgallium_wgl.dll libglapi.dll; do
    if [ -f "$work/x/x64/$dll" ]; then cp "$work/x/x64/$dll" "$dir/"; fi
  done
  echo "Mesa $version llvmpipe (opengl32.dll) staged beside $(cygpath -w "$dir")"
done
