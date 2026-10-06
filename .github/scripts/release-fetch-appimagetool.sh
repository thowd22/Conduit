#!/usr/bin/env bash
# Fetch the pinned appimagetool and AppImage runtime into a tools directory,
# refusing anything whose SHA-256 does not match the pin recorded here.
#
# Usage: release-fetch-appimagetool.sh <tools-dir>
#
# Both pins were verified against the digests GitHub publishes for the release
# assets (see docs/release.md). Bumping either is a deliberate change to this
# file, never an implicit "latest" download.
set -euo pipefail

tools_dir="${1:?usage: release-fetch-appimagetool.sh <tools-dir>}"

appimagetool_url="https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage"
appimagetool_sha256="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"
runtime_url="https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64"
runtime_sha256="2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d"

mkdir -p "$tools_dir"

fetch_pinned() {
  local url="$1" sha="$2" dest="$3"
  if [ -f "$dest" ] && printf '%s  %s\n' "$sha" "$dest" | sha256sum -c --quiet - 2>/dev/null; then
    echo "PASS: $dest already present with pinned SHA-256"
    return 0
  fi
  curl -fsSL --retry 3 --retry-delay 5 -o "$dest.part" "$url"
  if ! printf '%s  %s\n' "$sha" "$dest.part" | sha256sum -c --quiet -; then
    rm -f -- "$dest.part"
    echo "FAIL: $url does not match the pinned SHA-256 $sha" >&2
    exit 1
  fi
  mv -- "$dest.part" "$dest"
  chmod +x -- "$dest"
  echo "PASS: fetched $url (SHA-256 $sha)"
}

fetch_pinned "$appimagetool_url" "$appimagetool_sha256" "$tools_dir/appimagetool-x86_64.AppImage"
fetch_pinned "$runtime_url" "$runtime_sha256" "$tools_dir/runtime-x86_64"
