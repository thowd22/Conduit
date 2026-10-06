#!/usr/bin/env bash
set -euo pipefail

artifact_root="${1:?usage: validate-linux-desktop.sh ARTIFACT_ROOT}"
desktop="zig-out/share/applications/io.github.thowd22.Conduit.desktop"
icon="zig-out/share/icons/hicolor/scalable/apps/io.github.thowd22.Conduit.svg"

mkdir -p "$artifact_root"
desktop-file-validate "$desktop" 2>"$artifact_root/desktop-validation.txt"
rsvg-convert --output "$artifact_root/icon-render.png" "$icon"
cp -- "$desktop" "$artifact_root/io.github.thowd22.Conduit.desktop"
cp -- "$icon" "$artifact_root/io.github.thowd22.Conduit.svg"
