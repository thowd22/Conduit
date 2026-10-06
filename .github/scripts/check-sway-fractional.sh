#!/usr/bin/env bash
set -euo pipefail

artifact_root="${1:?usage: check-sway-fractional.sh ARTIFACT_ROOT}"
mkdir -p "$artifact_root/logs"

runtime_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/conduit-sway.XXXXXX")"
chmod 700 "$runtime_root"
sway_pid=""

cleanup() {
  status=$?
  trap - EXIT
  if [[ -n "$sway_pid" ]] && kill -0 "$sway_pid" 2>/dev/null; then
    if [[ -n "${SWAYSOCK:-}" ]]; then
      swaymsg exit >/dev/null 2>&1 || kill "$sway_pid" 2>/dev/null || true
    else
      kill "$sway_pid" 2>/dev/null || true
    fi
    if ! timeout 5s tail --pid="$sway_pid" -f /dev/null >/dev/null 2>&1; then
      kill "$sway_pid" 2>/dev/null || true
      if ! timeout 5s tail --pid="$sway_pid" -f /dev/null >/dev/null 2>&1; then
        kill -KILL "$sway_pid" 2>/dev/null || true
      fi
    fi
    wait "$sway_pid" 2>/dev/null || true
  fi
  rm -rf -- "$runtime_root"
  exit "$status"
}
trap cleanup EXIT

cat >"$artifact_root/sway.conf" <<'EOF'
output * mode 1280x720 scale 1.25
seat seat0 fallback true
default_border none
xwayland disable
for_window [app_id="io.github.thowd22.Conduit"] floating enable, resize set width 640 px height 360 px
EOF

export XDG_RUNTIME_DIR="$runtime_root"
export WLR_BACKENDS=headless
export WLR_HEADLESS_OUTPUTS=1
export WLR_LIBINPUT_NO_DEVICES=1
# SDL's OpenGL client submits EGL buffers. wlroots' GLES2 software renderer can import those
# buffers under llvmpipe; the pixman renderer is intentionally avoided because it is limited to
# CPU buffers on combinations shipped by Ubuntu and can reject an otherwise valid GL client.
export WLR_RENDERER=gles2
export WLR_RENDERER_ALLOW_SOFTWARE=1
export LIBGL_ALWAYS_SOFTWARE=1

sway --unsupported-gpu --debug --config "$artifact_root/sway.conf" \
  >"$artifact_root/sway.log" 2>&1 &
sway_pid=$!

# Poll the resources Sway publishes rather than assuming a compositor startup delay.
deadline=$((SECONDS + 20))
while :; do
  if ! kill -0 "$sway_pid" 2>/dev/null; then
    echo "Sway exited before publishing its Wayland and IPC sockets" >&2
    exit 1
  fi
  wayland_socket="$(find "$runtime_root" -maxdepth 1 -type s -name 'wayland-*' -print -quit)"
  sway_socket="$(find "$runtime_root" -maxdepth 1 -type s -name 'sway-ipc.*.sock' -print -quit)"
  if [[ -n "$wayland_socket" && -n "$sway_socket" ]]; then
    break
  fi
  if (( SECONDS >= deadline )); then
    echo "Sway did not publish its sockets within 20 seconds" >&2
    exit 1
  fi
  sleep 0.05
done

export WAYLAND_DISPLAY="$(basename "$wayland_socket")"
export SWAYSOCK="$sway_socket"

deadline=$((SECONDS + 20))
until swaymsg --type get_outputs --raw >"$artifact_root/outputs.json" 2>"$artifact_root/swaymsg.err" &&
  jq -e '
    [ .[] | select(
        .active == true and
        (.scale == 1.25) and
        (.current_mode.width == 1280) and
        (.current_mode.height == 720) and
        (.rect.width == 1024) and
        (.rect.height == 576)
      ) ] | length == 1
  ' "$artifact_root/outputs.json" >/dev/null; do
  if ! kill -0 "$sway_pid" 2>/dev/null; then
    echo "Sway exited before its IPC endpoint became ready" >&2
    exit 1
  fi
  if (( SECONDS >= deadline )); then
    echo "Sway IPC did not become ready within 20 seconds" >&2
    exit 1
  fi
  sleep 0.05
done

# The successful wait above is compositor evidence, not an intended-value echo: IPC reported one
# active 1.25-scale output with the logical size of its 1280x720 mode divided by that scale.
swaymsg --type get_version --raw >"$artifact_root/version.json"

export SDL_VIDEODRIVER=wayland
./zig-out/bin/conduit \
  --self-test \
  --width=640 \
  --height=360 \
  --log-dir="$artifact_root/logs" \
  --screenshot="$artifact_root/final.png" \
  >"$artifact_root/conduit.stdout" \
  2>"$artifact_root/conduit.stderr"

grep -Fq "window backend wayland, high-pixel-density enabled" "$artifact_root"/logs/*.log
grep -Fq "window reports 1.25 physical pixels per logical pixel" "$artifact_root"/logs/*.log
grep -Fq "window geometry 640x360 logical, 800x450 pixels" "$artifact_root"/logs/*.log
grep -Fq "self-test: 0 grid failure(s)" "$artifact_root/conduit.stdout"

python3 - "$artifact_root/final.png" <<'PY'
import struct
import sys

with open(sys.argv[1], "rb") as image:
    header = image.read(24)
if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
    raise SystemExit("Conduit did not write a complete PNG header")
width, height = struct.unpack(">II", header[16:24])
# --self-test asks for a half-size resize. Wayland compositors may accept that request or retain
# the original toplevel size; either valid outcome must remain a 1.25-scaled physical surface.
if (width, height) not in {(800, 450), (400, 225)}:
    raise SystemExit(
        f"fractional-scale screenshot is {width}x{height}, expected 800x450 or 400x225"
    )
PY
