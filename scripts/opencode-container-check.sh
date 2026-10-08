#!/usr/bin/env bash
# Live OpenCode check for TASK-78, run by hand (not CI).
#
# OpenCode is not installed on the development machine and nothing is
# installed there for this: a throwaway ubuntu:24.04 image gets Node and npm
# from the Ubuntu archive and `npm install -g opencode-ai@$OPENCODE_VERSION`.
# A fixed OpenAI-compatible model (scripts/opencode-mock-provider.py) answers
# inside the container, so real OpenCode turns run with no network model and
# no credentials; `permission.bash = "ask"` makes its one tool call ask.
#
# On the host this stages Conduit for glibc 2.35 (the host's own glibc is
# newer than the image's) plus the `agent` unit tests for the same target,
# then runs, inside the container:
#   1. the agent tests, whose skip-marked live test starts a real
#      `opencode serve` and, with CONDUIT_OPENCODE_LIVE_TURN, drives one turn
#      through the adapter (prompt, permission request, answer, done);
#   2. Conduit under Xvfb, driven by `conduit-test` through the real input
#      path: `opencode` started by hand in a plain tab is observed (AC3), and
#      `Agent: launch` starts OpenCode whose structured events drive the tab
#      glyph and the agent view, where the permission is answered by click
#      (AC1, AC2).
# The transcript, screenshots, semantic trees and logs land in the output
# directory (default: .zig-cache/opencode-live). Requires docker and zig.
#
# Usage: scripts/opencode-container-check.sh [output-dir]
set -euo pipefail

OPENCODE_VERSION=1.18.35
IMAGE="conduit-opencode-check:$OPENCODE_VERSION"
TARGET=x86_64-linux-gnu.2.35

if [ "${1:-}" = "--inside" ]; then
  shift
  exec_inside=1
else
  exec_inside=0
fi

# ---------------------------------------------------------------------------
# Inside the container.
# ---------------------------------------------------------------------------
if [ "$exec_inside" = 1 ]; then
  out=/out
  export HOME=/tmp/home
  mkdir -p "$HOME" /tmp/proj /tmp/oc
  ct=/stage/bin/conduit-test
  step() { printf '\n== %s\n' "$*"; }

  cat > /tmp/oc/opencode.json <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "autoupdate": false,
  "share": "disabled",
  "provider": {
    "conduit": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Conduit mock",
      "options": { "baseURL": "http://127.0.0.1:8765/v1", "apiKey": "mock" },
      "models": { "conduit-mock": { "name": "Conduit mock", "tool_call": true } }
    }
  },
  "model": "conduit/conduit-mock",
  "small_model": "conduit/conduit-mock",
  "permission": { "bash": "ask", "edit": "ask" }
}
JSON
  # OPENCODE_CONFIG survives conduit-test's isolated HOME: Local children
  # inherit Conduit's environment (TASK-73).
  export OPENCODE_CONFIG=/tmp/oc/opencode.json
  python3 /scripts/opencode-mock-provider.py --port 8765 --log "$out/provider.log" &

  step "opencode version"
  opencode --version

  step "1. agent unit tests with the live OpenCode turn"
  mkdir -p /tmp/work
  cp -r /repo-test /tmp/work/test
  cd /tmp/work
  set +e
  CONDUIT_OPENCODE_LIVE_TURN=1 /agent-test 2>&1 | tee "$out/agent-test.log"
  agent_status=${PIPESTATUS[0]}
  set -e
  echo "agent-test exit status: $agent_status"

  step "2. Conduit under Xvfb, driven by conduit-test"
  Xvfb :99 -screen 0 1280x800x24 -nolisten tcp > "$out/xvfb.log" 2>&1 &
  export DISPLAY=:99 SDL_VIDEODRIVER=x11
  for _ in $(seq 1 100); do [ -e /tmp/.X11-unix/X99 ] && break; sleep 0.1; done
  export SHELL=/bin/bash
  root=/tmp/ct
  run=$("$ct" --root="$root" launch --width=1100 --height=620 --scale=1)
  echo "run $run"
  c() { "$ct" --root="$root" --run="$run" "$@"; }
  failures=0
  check() {
    if "$@"; then echo "ok   $*"; else echo "FAIL $*"; failures=$((failures + 1)); fi
  }
  shot() {
    local path
    path=$(c screenshot)
    cp "$path" "$out/$1.png"
    echo "screenshot $out/$1.png"
  }
  # Wait for any element whose id starts with $1 (the glyph's state is
  # whatever the PTY baseline says at that moment). Bounded polling of the
  # semantic tree: `wait-for` takes exact ids only.
  wait_prefix() {
    local deadline=$((SECONDS + ${2:-30}))
    while [ "$SECONDS" -lt "$deadline" ]; do
      if c --json inspect | grep -qo "\"$1[a-z0-9_.-]*\""; then return 0; fi
      sleep 0.25
    done
    return 1
  }

  # Markers the shell computes, so the typed line itself never matches.
  c type "cd /tmp/proj && printf 'OC%sREADY\\n' -"
  c key ENTER
  check c wait-for terminal-text 'OC-READY' 20000

  step "AC3: opencode started by hand in a plain tab is observed"
  c type 'opencode'
  c key ENTER
  check wait_prefix 'workspace.1.tab.1.agent.' 60
  # OpenCode's own TUI has drawn (its prompt bar names the model).
  check c wait-for terminal-text 'Conduit mock' 60000
  c --json inspect > "$out/observed-tree.json"
  grep -o '"workspace.1.tab.1.agent.[a-z_]*"' "$out/observed-tree.json" | sort -u || true
  shot observed-opencode
  # OpenCode's exit chord; a second one when the first only cleared input.
  c key CTRL+c
  if ! c wait-for element workspace.1.tab.1.agent.done exists true 5000; then c key CTRL+c; fi
  check c wait-for element workspace.1.tab.1.agent.done exists true 20000
  c type "printf 'OC%sBACK\\n' -"
  c key ENTER
  check c wait-for terminal-text 'OC-BACK' 20000
  shot observed-ended

  step "AC1/AC2: Agent: launch OpenCode, structured status and the permission answered in the view"
  c key CTRL+SHIFT+p
  check c wait-for element palette.query focused true 5000
  c type 'Agent: launch'
  c key ENTER
  c --json inspect > "$out/launch-choices.json"
  grep -o '"palette.choice[^"]*"' "$out/launch-choices.json" | head -5 || true
  c key ENTER
  check c wait-for element palette.argument exists true 5000
  c type 'run the marker'
  c key ENTER
  check c wait-for element workspace.1.tab.2.agent.working exists true 60000
  check c wait-for element workspace.1.tab.2.agent.waiting_permission exists true 60000
  shot launched-waiting-permission
  c key CTRL+SHIFT+a
  check wait_prefix 'agent.view.' 10
  c --json inspect > "$out/view-tree.json"
  once=$(grep -o '"agent\.view\.[0-9]*\.perm\.[^"]*\.once"' "$out/view-tree.json" | head -1 | tr -d '"' || true)
  echo "permission control: $once"
  shot agent-view-permission
  check test -n "$once"
  if [ -n "$once" ]; then c click "$once"; fi
  outcome="${once%.once}.outcome"
  check c wait-for element "$outcome" exists true 20000
  check c wait-for element workspace.1.tab.2.agent.done exists true 60000
  c --json inspect > "$out/final-tree.json"
  shot agent-view-done
  c logs 1048576 > "$out/conduit.log" || true
  c quit || true
  echo "conduit-test failures: $failures"
  [ "$agent_status" = 0 ] && [ "$failures" = 0 ]
  exit $?
fi

# ---------------------------------------------------------------------------
# On the host.
# ---------------------------------------------------------------------------
repo=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-$repo/.zig-cache/opencode-live}
mkdir -p "$out"
out=$(cd "$out" && pwd)
stage="$out/stage"
exec > >(tee "$out/transcript.log") 2>&1

echo "== stage Conduit for $TARGET (ReleaseSafe)"
rm -rf "$stage"
(cd "$repo" && zig build --prefix "$stage" -Dtarget="$TARGET" -Doptimize=ReleaseSafe)

echo "== build the agent tests for $TARGET"
# The suite also runs here (the host's glibc is newer); only the agent test
# binary is taken, named by the verbose run command.
set +e
(cd "$repo" && zig build test -Dtarget="$TARGET" --summary none --verbose) > "$out/host-target-tests.log" 2>&1
set -e
agent_test=$(grep -o '[^ ]*/agent-test\b' "$out/host-target-tests.log" | tail -1)
[ -n "$agent_test" ] || { echo "the agent test binary was not found"; exit 1; }
cp "$repo/${agent_test#./}" "$out/agent-test"
echo "agent tests: $agent_test"

echo "== build the image $IMAGE"
image_dir="$out/image"
mkdir -p "$image_dir"
cat > "$image_dir/Dockerfile" <<EOF
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \\
    nodejs npm ca-certificates python3 curl xvfb xauth libgl1-mesa-dri libgl1 libegl1 \\
    libfontconfig1 libfreetype6 fonts-dejavu-core libx11-6 libxext6 libxrandr2 libxcursor1 \\
    libxi6 libxfixes3 libxss1 libxkbcommon0 libxkbcommon-x11-0 libwayland-client0 \\
    libdbus-1-3 git procps && rm -rf /var/lib/apt/lists/*
RUN npm install -g opencode-ai@$OPENCODE_VERSION && opencode --version
EOF
docker build -q -t "$IMAGE" "$image_dir"

echo "== run the checks in the container"
mkdir -p "$out/container"
docker run --rm --init -u "$(id -u):$(id -g)" \
  -v "$repo/scripts:/scripts:ro" \
  -v "$repo/test:/repo-test:ro" \
  -v "$stage:/stage:ro" \
  -v "$out/agent-test:/agent-test:ro" \
  -v "$out/container:/out" \
  "$IMAGE" bash /scripts/opencode-container-check.sh --inside
echo "== passed; evidence in $out/container"
