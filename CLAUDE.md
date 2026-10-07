@AGENTS.md

# Claude Code entry point

`AGENTS.md` is the governing guide. Follow its development loop and worked driver example for
every task; this file only highlights the Claude-facing path through it.

For each implementation slice, run `zig build test` and `zig build`, then validate observable
behaviour through the installed `./zig-out/bin/conduit-test` executable. Start an isolated run
with `launch`, use `inspect` to read the semantic tree, interact through `click`, `right-click`, `key`,
`type`, `scroll` or the other driver commands, assert the result with `wait-for`, capture and actually
inspect a `screenshot`, and finish with `quit`. If validation fails, use the CLI's `logs` command
(the MCP tool is `get_logs`) and another `inspect` before changing code so the logs and semantic
tree identify the failure.

The implemented deterministic app checks are `xvfb-run -a zig build run -- --ui-test`, the same
command with `--ime-test`, `--menu-test`, `--config-test`, `--theme-test`, `--font-test`, `--settings-test`, `--git-test`, `--agent-test` and the other `--*-test` flags listed in `AGENTS.md`, and
the same command with `--driver-test`. The aggregated `zig build e2e` scenario runner exists and
runs fifteen scripted scenarios under a display such as Xvfb with an explicit private
`--artifact-dir`; its Linux CI acceptance (TASK-25) still needs a remote Actions run.

The project `.mcp.json` exposes the same surface through `conduit-test mcp` after Claude Code's
normal workspace approval. Whether using the CLI or MCP tools, every user-facing feature must add
or update a deterministic E2E scenario that exercises the real input path, including keyboard and
mouse paths where both apply.
