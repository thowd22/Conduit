#!/usr/bin/env bash
# Give a Windows runner a `/bin/sh` that Conduit's `--command` path can start.
#
# Usage: windows-sh-standin.sh
#
# Conduit runs a `--command` line, and every built-in check's fixed child, as
# `/bin/sh -c <line>` (src/main.zig `ChildSpec`). On Windows the ConPTY backend
# takes a program with a slash in it as a path, so `/bin/sh` means `\bin\sh` on
# the current drive. Until TASK-46 gives Windows its own command shell, this
# stages Git for Windows' MSYS2 `sh` there (with the MSYS runtime DLLs and the
# few utilities the checks call) on the C: and workspace drives. It is a test
# fixture for the runner, not something a Windows user needs: an interactive
# Windows session uses `SHELL` (or, after TASK-46, its shell profile).
set -euo pipefail

git_usr="$(cygpath -u "${PROGRAMFILES:-C:\\Program Files}")/Git/usr/bin"
[ -x "$git_usr/sh.exe" ] || { echo "FAIL: no Git for Windows sh at $git_usr" >&2; exit 1; }

drives="c"
workspace_drive="$(cygpath -w "${GITHUB_WORKSPACE:-$PWD}" | cut -c1 | tr 'A-Z' 'a-z')"
[ "$workspace_drive" = c ] || drives="$drives $workspace_drive"
for drive in $drives; do
  dest="/$drive/bin"
  # The MSYS runtime takes `\bin`'s parent as its root, so `/tmp` is `<drive>:\tmp`.
  mkdir -p "$dest" "/$drive/tmp"
  cp "$git_usr"/*.dll "$dest/"
  for tool in sh bash cat printf sleep head tail seq stty env ls tr sed grep pwd mkdir rm touch wc od dd true false test; do
    if [ -f "$git_usr/$tool.exe" ]; then cp "$git_usr/$tool.exe" "$dest/"; fi
  done
  # The name Conduit asks for, with no extension: CreateProcessW starts a PE
  # image whatever its name, and `\bin\sh` is the path `/bin/sh` resolves to.
  # Through PowerShell: MSYS `cp` silently appends `.exe` to an executable's
  # copy, which would leave no `sh` at all.
  powershell.exe -NoProfile -Command "Copy-Item -LiteralPath '$(cygpath -w "$git_usr/sh.exe")' -Destination '$(cygpath -w "$dest")\\sh' -Force"
  powershell.exe -NoProfile -Command "if (-not (Test-Path -LiteralPath '$(cygpath -w "$dest")\\sh' -PathType Leaf)) { exit 1 }"
  echo "staged $(cygpath -w "$dest")\\sh"
done
