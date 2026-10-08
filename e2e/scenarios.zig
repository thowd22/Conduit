//! Declarative TASK-25 scenarios consumed by the standalone E2E runner.
//!
//! Scenario steps name only public `conduit-test` operations. Assertions use
//! bounded driver waits, and pointer input names semantic ids rather than
//! coordinates, so a layout or display-scale change does not rewrite tests.
//!
//! Workspace restore (TASK-65) has no scenario here: a scenario is one
//! launch, and driven runs neither save nor restore by design. The built-in
//! `--restore-test` covers it by running two apps in turn on one window.

const std = @import("std");

/// One operation performed by a separate `conduit-test` client process.
pub const Step = union(enum) {
    inspect,
    click: []const u8,
    ctrl_click: []const u8,
    right_click: []const u8,
    key: []const u8,
    type_text: []const u8,
    wait_element: struct {
        id: []const u8,
        state: []const u8,
        equals: bool,
        timeout_ms: u32 = 5_000,
    },
    wait_terminal_text: struct {
        contains: []const u8,
        timeout_ms: u32 = 5_000,
    },
    screenshot,
};

/// One variable the runner sets on top of its own environment for `launch`.
pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

/// Fixed launch geometry and ordered user-visible operations for one run.
pub const Scenario = struct {
    name: []const u8,
    width: u32 = 640,
    height: u32 = 360,
    scale: f32 = 1,
    /// Set for the `launch` client only; every other client inherits the
    /// runner's environment unchanged.
    launch_env: []const EnvVar = &.{},
    command: []const u8,
    steps: []const Step,
};

// This shell has no user startup file: conduit-test supplies an isolated HOME,
// and ENV points at /dev/null before the interactive shell starts. A real shell
// still interprets what the driver types, so output assertions cover the PTY.
const deterministic_shell =
    "PS1='CONDUIT_E2E> '; ENV=/dev/null; export PS1 ENV; exec /bin/sh -i";

const launch_prompt_steps = [_]Step{
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_E2E> " } },
    .inspect,
    .screenshot,
};

const type_command_steps = [_]Step{
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_E2E> " } },
    // The asserted spelling never appears in the typed command, so terminal
    // echo alone cannot make this pass when Enter or shell execution breaks.
    .{ .type_text = "printf 'CONDUIT_%s\\n' 'ASSERTED'" },
    .{ .key = "ENTER" },
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_ASSERTED" } },
    .screenshot,
};

const select_copy_steps = [_]Step{
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_E2E> " } },
    .{ .key = "CTRL+SHIFT+p" },
    .{ .wait_element = .{
        .id = "palette.query",
        .state = "exists",
        .equals = true,
    } },
    .{ .click = "palette.query" },
    // Copy a command whose execution transforms two separate spellings into
    // the asserted output. Seeing COPY_ASSERTED therefore proves both paste
    // and shell execution rather than merely seeing the pasted command echo.
    .{ .type_text = "printf 'COPY_%s\\n' 'ASSERTED'" },
    // Focused Input fields use the native editing chord. Terminal paste keeps
    // the shipped Linux terminal chord after Escape returns focus to the PTY.
    .{ .key = "CTRL+a" },
    .{ .key = "CTRL+c" },
    .{ .key = "ESCAPE" },
    .{ .key = "CTRL+SHIFT+v" },
    .{ .key = "ENTER" },
    .{ .wait_terminal_text = .{ .contains = "COPY_ASSERTED" } },
    .screenshot,
};

const terminal_link_url = "https://192.0.2.1/conduit-e2e";

// The first workspace is 1 and its human terminal is session 2 because the
// permanent scratchpad reserves session 1. The child clears and homes the
// terminal before printing, so the link starts at viewport row 0, column 0.
// The fingerprint is SHA-256("conduit-terminal-link-v1\0" || URL kind 0x01 ||
// big-endian line 0 || big-endian column 0 || terminal_link_url), truncated to
// 16 bytes and rendered lowercase hexadecimal by App.composeTerminalLinkRow.
const terminal_link_id =
    "workspace.1.session.2.terminal-link.0.0.40989a0ff4dc7589a09be53774d38440.29";

const terminal_link_command =
    "stty -echo; " ++
    "printf '\x1b[2J\x1b[H%s' '" ++ terminal_link_url ++ "'; " ++
    "while :; do sleep 60; done";

const terminal_link_steps = [_]Step{
    .{ .wait_terminal_text = .{ .contains = terminal_link_url } },
    .{ .wait_element = .{
        .id = terminal_link_id,
        .state = "exists",
        .equals = true,
    } },
    .{ .ctrl_click = terminal_link_id },
    .screenshot,
};

// Short on purpose: vim truncates its status message to the columns left
// beside the ruler and showcmd areas, and the resolved spelling must fit.
const terminal_file_reference = "./cdt-e2e.txt";
const terminal_file_reference_cwd = "/tmp";
const terminal_file_reference_text = terminal_file_reference ++ ":3";
// vim echoes its path argument quoted exactly as given, whether the file is
// new or already exists, so this is the resolved `vi +3 -- <cwd>/file` proof.
const terminal_file_reference_resolved = "\"" ++ terminal_file_reference_cwd ++ "/cdt-e2e.txt\"";

// Same workspace/session/row/column derivation as `terminal_link_id`, with the
// file kind 0x02, big-endian line 3 and column 0 hashed over the visible path
// spelling (not the resolved path), so the id does not depend on any cwd.
const terminal_file_reference_id =
    "workspace.1.session.2.terminal-link.0.0.abba01736f140c39a7a42d68263c19bc.13";

// The second tab a workspace creates; the first human terminal is tab 1.
const terminal_file_reference_tab_id = "workspace.1.tab.2";

// The child claims `/tmp` as its tracked cwd with OSC 7 before printing the
// relative reference. `/tmp` exists on every Linux runner, so the real `vi`
// spawn with that cwd succeeds and the reference resolves deterministically.
const terminal_file_reference_command =
    "stty -echo; " ++
    "printf '\x1b[2J\x1b[H\x1b]7;file://localhost" ++ terminal_file_reference_cwd ++ "\x07%s' '" ++
    terminal_file_reference_text ++ "'; " ++
    "while :; do sleep 60; done";

// Only the newly created (and selected) tab can show the quoted resolved
// spelling: the source terminal printed the relative form. Waiting for that
// text in the active terminal therefore proves the editor really started with
// `vi +3 -- <cwd>/file` without depending on `~` filler, which other visible
// text could mimic.
const terminal_file_reference_steps = [_]Step{
    .{ .wait_terminal_text = .{ .contains = terminal_file_reference_text } },
    .{ .wait_element = .{
        .id = terminal_file_reference_id,
        .state = "exists",
        .equals = true,
    } },
    .{ .ctrl_click = terminal_file_reference_id },
    .{ .wait_element = .{
        .id = terminal_file_reference_tab_id,
        .state = "exists",
        .equals = true,
    } },
    .{ .wait_terminal_text = .{ .contains = terminal_file_reference_resolved } },
    .screenshot,
};

// The first workspace is 1 and its first tab owns pane 1; the pane id is
// stable across frames, so a right click on it lands on the human terminal.
const terminal_pane_id = "workspace.1.pane.1";

// A right click over the focused terminal opens the context menu at the
// pointer (the built-in `mouse.right_click = menu` default). Clicking its
// `search` row dispatches the completed `search.open` action, whose semantic
// Input proves the row was a real command rather than an inert label.
const context_menu_steps = [_]Step{
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_E2E> " } },
    .{ .right_click = terminal_pane_id },
    .{ .wait_element = .{
        .id = "context-menu.search",
        .state = "exists",
        .equals = true,
    } },
    .screenshot,
    .{ .click = "context-menu.search" },
    .{ .wait_element = .{
        .id = "search.query",
        .state = "exists",
        .equals = true,
    } },
    .{ .wait_element = .{
        .id = "context-menu",
        .state = "exists",
        .equals = false,
    } },
    .screenshot,
};

// TASK-72: a multi-megabyte burst of output must drain at parser speed
// rather than one PTY read per frame. The 4 MB of records overwrite one row
// with carriage returns, so the run measures the drain and frame pacing rather
// than how fast a Debug engine scrolls (it verifies its page list on every
// scroll). Before the fix this took about 13 s in a ReleaseSafe build at
// 1000x640 for 40 MB; after it, about 1.4 s. The marker is built by the shell
// at run time, so the echoed command line (which contains `FLOOD_$((1+1))_DONE`)
// cannot satisfy the wait: only the shell finishing the flood and then running
// `echo` can.
//
// TASK-67: a second command is typed through the real key path straight after
// the first, while the flood is still running. The shell is busy, so the line
// waits in the terminal's input queue and runs once the flood ends; its marker
// appearing proves input typed during a flood is neither dropped nor reordered.
// Whether or not the flood is still running when the keys land, the outcome is
// the same, which keeps the scenario deterministic.
const output_flood_marker = "FLOOD_2_DONE";
const output_flood_command =
    "yes 0123456789abcdef | tr '\\n' '\\r' | head -c 4000000; echo; echo FLOOD_$((1+1))_DONE";
const output_flood_typed_marker = "TYPED_DURING_FLOOD_5";
const output_flood_typed_command = "echo TYPED_DURING_FLOOD_$((2+3))";

const output_flood_steps = [_]Step{
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_E2E> " } },
    .{ .type_text = output_flood_command },
    .{ .key = "ENTER" },
    .{ .type_text = output_flood_typed_command },
    .{ .key = "ENTER" },
    .{ .wait_terminal_text = .{ .contains = output_flood_marker, .timeout_ms = 20_000 } },
    .{ .wait_terminal_text = .{ .contains = output_flood_typed_marker, .timeout_ms = 10_000 } },
    .inspect,
    .screenshot,
};

// TASK-74: the sidebar footer's only control is the centred `Palette <chord>`
// hint. Clicking it through the real pointer path must open the command
// palette with its query focused, which is the mouse route to every sidebar
// command the footer used to list.
const sidebar_palette_steps = [_]Step{
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_E2E> " } },
    .{ .wait_element = .{
        .id = "sidebar.version",
        .state = "exists",
        .equals = true,
    } },
    .{ .click = "sidebar.palette" },
    .{ .wait_element = .{
        .id = "palette.dialog",
        .state = "exists",
        .equals = true,
    } },
    .{ .wait_element = .{
        .id = "palette.query",
        .state = "focused",
        .equals = true,
    } },
    .screenshot,
};

// TASK-73: a Local child inherits the environment Conduit was launched with.
// The runner sets a profile-style export, a stand-in agent socket and both
// conduit-test addressing variables for the launch only; the app inherits
// them from `conduit-test launch`, and its child must see the first two but
// never the driver addressing. The display variable comes from the display
// the suite runs under (Xvfb in CI), and the isolated HOME/XDG/TMPDIR layout
// that `launch` imposes must still be what the child sees. The command is
// not typed, so no label can be satisfied by echo; every wait needs the child
// to have expanded the variable itself.
const child_environment_launch_env = [_]EnvVar{
    .{ .name = "CONDUIT_PROBE_VAR", .value = "inherited" },
    .{ .name = "SSH_AUTH_SOCK", .value = "/conduit-e2e/agent.sock" },
    .{ .name = "CONDUIT_TEST_RUN", .value = "run-leak-probe" },
    .{ .name = "CONDUIT_TEST_ROOT", .value = "/conduit-e2e/leak-probe" },
};

const child_environment_command =
    "stty -echo; printf '\x1b[2J\x1b[H'; " ++
    "printf 'ENV_PROBE=%s\\n' \"$CONDUIT_PROBE_VAR\"; " ++
    "if [ -n \"$DISPLAY$WAYLAND_DISPLAY\" ]; then d=present; else d=absent; fi; " ++
    "printf 'ENV_DISPLAY=%s\\n' \"$d\"; " ++
    "printf 'ENV_AGENT=%s\\n' \"$SSH_AUTH_SOCK\"; " ++
    "r=\"${HOME%/home}\"; " ++
    "if [ \"$r\" != \"$HOME\" ] && [ \"$XDG_CONFIG_HOME\" = \"$r/config\" ] && [ \"$TMPDIR\" = \"$r/tmp\" ]; " ++
    "then i=isolated; else i=leaked; fi; " ++
    "printf 'ENV_HOME=%s\\n' \"$i\"; " ++
    "printf 'ENV_DRIVER=%s/%s\\n' \"${CONDUIT_TEST_RUN:-unset}\" \"${CONDUIT_TEST_ROOT:-unset}\"; " ++
    "printf 'ENV_TERM=%s/%s\\n' \"$TERM\" \"$TERM_PROGRAM\"; " ++
    "while :; do sleep 60; done";

const child_environment_steps = [_]Step{
    .{ .wait_terminal_text = .{ .contains = "ENV_PROBE=inherited" } },
    .{ .wait_terminal_text = .{ .contains = "ENV_DISPLAY=present" } },
    .{ .wait_terminal_text = .{ .contains = "ENV_AGENT=/conduit-e2e/agent.sock" } },
    .{ .wait_terminal_text = .{ .contains = "ENV_HOME=isolated" } },
    .{ .wait_terminal_text = .{ .contains = "ENV_DRIVER=unset/unset" } },
    .{ .wait_terminal_text = .{ .contains = "ENV_TERM=xterm-256color/conduit" } },
    .inspect,
    .screenshot,
};

/// All scenarios in deterministic execution and report order.
// TASK-39: one screen of every glyph category the font stack resolves beyond
// the primary face. A Starship-style prompt (Powerline arrows and rounded caps
// over coloured segments, a Nerd Font branch icon), box drawing with light,
// heavy and double strokes, block elements, braille, a CJK word through the
// system fallback, Claude Code's U+273B, a supplementary-plane Nerd Font icon,
// programming ligatures and colour emoji. Every byte is printed by the child,
// so the screenshot shows what the renderer drew for each category.
const font_coverage_marker = "FONT_COVERAGE_READY";

const font_coverage_command =
    "stty -echo; printf '\x1b[2J\x1b[H'; " ++
    "printf '\x1b[30;44m \u{F126} main \x1b[34;42m\u{E0B0}\x1b[30;42m ~/src/conduit \x1b[32;45m\u{E0B0}" ++
    "\x1b[30;45m 3.2s \x1b[35;49m\u{E0B0}\x1b[0m \x1b[33m\u{E0B6}\x1b[30;43m zig \x1b[33;49m\u{E0B4}\x1b[0m\\n'; " ++
    "printf '\x1b[32m\u{276F}\x1b[0m cargo build => ok != err -> done\\n\\n'; " ++
    "printf '\u{256D}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{252C}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{256E} " ++
    "\u{2554}\u{2550}\u{2550}\u{2566}\u{2550}\u{2550}\u{2557} \u{250F}\u{2501}\u{2501}\u{2513}\\n'; " ++
    "printf '\u{2502} \u{4E2D}\u{6587} \u{2502} \u{273B} \u{F0068}  \u{2502} \u{2551}\u{2588}\u{2588}\u{2551}\u{2592}\u{2592}\u{2551} " ++
    "\u{2503}\u{2580}\u{2584}\u{2503}\\n'; " ++
    "printf '\u{2570}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2534}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{256F} " ++
    "\u{255A}\u{2550}\u{2550}\u{2569}\u{2550}\u{2550}\u{255D} \u{2517}\u{2501}\u{2501}\u{251B}\\n\\n'; " ++
    "printf 'braille \u{28FF}\u{2847}\u{283F}\u{28B8}\u{28C0}\u{281B}\u{28E4}\u{2836}  emoji \u{1F600} \u{1F680} \u{1F40D}\\n'; " ++
    "printf 'FONT_%s\\n' COVERAGE_READY; " ++
    "while :; do sleep 60; done";

const font_coverage_steps = [_]Step{
    .{ .wait_terminal_text = .{ .contains = font_coverage_marker } },
    .{ .wait_terminal_text = .{ .contains = "\u{4E2D}\u{6587}" } },
    .inspect,
    .screenshot,
};

// Palette choice rows are `palette.choice.<action index>.<choice>`, where the
// action index is the command's position in the app's action registry:
// `theme.pick` is 50 and `font.pick` is 51. These shift when an action is
// registered before them in `App.init`; `--ui-test` pins the same order.
const theme_pick_first_choice = "palette.choice.50.0";
const theme_pick_second_choice = "palette.choice.50.1";
const font_pick_first_choice = "palette.choice.51.0";
const font_pick_second_choice = "palette.choice.51.1";

// TASK-38: the theme picker by keyboard (Down previews the next theme live,
// Escape closes and reverts) and by mouse (the sidebar hint, the typed
// command, a clicked choice that commits and closes the dialog).
const theme_picker_steps = [_]Step{
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_E2E> " } },
    .{ .key = "CTRL+SHIFT+p" },
    .{ .wait_element = .{ .id = "palette.query", .state = "focused", .equals = true } },
    .{ .type_text = "theme" },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = theme_pick_first_choice, .state = "exists", .equals = true } },
    .{ .key = "DOWN" },
    .screenshot,
    .{ .key = "ESCAPE" },
    .{ .wait_element = .{ .id = "palette.dialog", .state = "exists", .equals = false } },
    .{ .click = "sidebar.palette" },
    .{ .wait_element = .{ .id = "palette.query", .state = "focused", .equals = true } },
    .{ .type_text = "theme" },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = theme_pick_second_choice, .state = "exists", .equals = true } },
    .{ .click = theme_pick_second_choice },
    .{ .wait_element = .{ .id = "palette.dialog", .state = "exists", .equals = false } },
    .screenshot,
};

// TASK-40: the font family picker. Its `palette.preview` line exists only
// while the window is drawn with the highlighted family, so waiting for it
// after Down waits for the previewed face to finish loading. The mouse path
// commits the second listed family; reopening the picker then lists it first
// and, once its line is back, the screenshot shows the committed face.
const font_picker_label = "Font: Change Family";

const font_picker_steps = [_]Step{
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_E2E> " } },
    .{ .key = "CTRL+SHIFT+p" },
    .{ .wait_element = .{ .id = "palette.query", .state = "focused", .equals = true } },
    .{ .type_text = font_picker_label },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = font_pick_first_choice, .state = "exists", .equals = true } },
    .{ .wait_element = .{ .id = "palette.preview", .state = "exists", .equals = true } },
    .{ .key = "DOWN" },
    .{ .wait_element = .{ .id = "palette.preview", .state = "exists", .equals = true } },
    .screenshot,
    .{ .key = "ESCAPE" },
    .{ .wait_element = .{ .id = "palette.dialog", .state = "exists", .equals = false } },
    .{ .click = "sidebar.palette" },
    .{ .wait_element = .{ .id = "palette.query", .state = "focused", .equals = true } },
    .{ .type_text = font_picker_label },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = font_pick_second_choice, .state = "exists", .equals = true } },
    .{ .click = font_pick_second_choice },
    .{ .wait_element = .{ .id = "palette.dialog", .state = "exists", .equals = false } },
    .{ .key = "CTRL+SHIFT+p" },
    .{ .wait_element = .{ .id = "palette.query", .state = "focused", .equals = true } },
    .{ .type_text = font_picker_label },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = "palette.preview", .state = "exists", .equals = true } },
    .screenshot,
};

// TASK-41: the settings view opened from the palette by keyboard (Down moves
// the highlight over the Fonts heading, Escape closes) and by mouse (the
// sidebar hint, the typed command, a clicked bool row that toggles and saves
// while the dialog stays open). The launch's private config directory holds
// the file the click writes.
const settings_bool_row = "settings.row.font.ligatures";

const settings_view_steps = [_]Step{
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_E2E> " } },
    .{ .key = "CTRL+SHIFT+p" },
    .{ .wait_element = .{ .id = "palette.query", .state = "focused", .equals = true } },
    .{ .type_text = "settings" },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = "settings.dialog", .state = "exists", .equals = true } },
    .{ .key = "DOWN" },
    .screenshot,
    .{ .key = "ESCAPE" },
    .{ .wait_element = .{ .id = "settings.dialog", .state = "exists", .equals = false } },
    .{ .click = "sidebar.palette" },
    .{ .wait_element = .{ .id = "palette.query", .state = "focused", .equals = true } },
    .{ .type_text = "settings" },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = settings_bool_row, .state = "exists", .equals = true } },
    .{ .click = settings_bool_row },
    .{ .wait_element = .{ .id = "settings.dialog", .state = "exists", .equals = true } },
    .{ .wait_element = .{ .id = "settings.error", .state = "exists", .equals = false } },
    .screenshot,
};

// TASK-76/77: a minimal shell over a real repository in a private temporary
// directory (removed when the child exits). Every evaluated line is followed
// by an OSC 7 cwd and an OSC 133 prompt, the signals an integrated shell
// sends, and git's user and system configuration are masked.
const sidebar_branch_command =
    "stty -echo; " ++
    "export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=c GIT_AUTHOR_EMAIL=c@c " ++
    "GIT_COMMITTER_NAME=c GIT_COMMITTER_EMAIL=c@c; " ++
    "root=$(mktemp -d \"${TMPDIR:-/tmp}/conduit-e2e-branch.XXXXXX\") || exit 1; " ++
    "trap 'rm -rf \"$root\"' EXIT; trap 'exit 1' HUP TERM INT; " ++
    "REPO=\"$root/repo\"; git init -q -b main \"$REPO\" && git -C \"$REPO\" commit -q --allow-empty -m init || exit 1; " ++
    "cd \"$REPO\"; " ++
    "p() { printf '\\033]7;file://localhost%s\\007\\033]133;A\\007branch$ \\033]133;B\\007' \"$PWD\"; }; p; " ++
    "while IFS= read -r line; do printf '\\033]133;C\\007'; eval \"$line\"; p; done";

const sidebar_branch_id = "workspace.1.tab.1.branch";

const sidebar_branch_steps = [_]Step{
    .{ .wait_terminal_text = .{ .contains = "branch$ " } },
    .{ .wait_element = .{ .id = sidebar_branch_id, .state = "exists", .equals = true } },
    // The printed spelling needs an expansion, so echo alone cannot match.
    .{ .type_text = "git checkout -q -b e2e/feature && printf 'ON-%s\\n' \"$(git branch --show-current)\"" },
    .{ .key = "ENTER" },
    .{ .wait_terminal_text = .{ .contains = "ON-e2e/feature" } },
    .{ .wait_element = .{ .id = sidebar_branch_id, .state = "exists", .equals = true } },
    .{ .type_text = "cd /" },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = sidebar_branch_id, .state = "exists", .equals = false } },
    .{ .type_text = "cd \"$REPO\"" },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = sidebar_branch_id, .state = "exists", .equals = true } },
    // A second workspace is listed below the first's two-row tab, shifted by
    // the TASK-77 gap; a real click on its row switches to it.
    .{ .key = "CTRL+SHIFT+p" },
    .{ .wait_element = .{ .id = "palette.query", .state = "focused", .equals = true } },
    .{ .type_text = "Create workspace" },
    .{ .key = "ENTER" },
    .{ .type_text = "/tmp" },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = "workspace.2", .state = "exists", .equals = true } },
    .{ .click = "workspace.1" },
    .{ .wait_element = .{ .id = sidebar_branch_id, .state = "exists", .equals = true } },
    .screenshot,
    .{ .click = "workspace.2" },
    .{ .wait_element = .{ .id = sidebar_branch_id, .state = "exists", .equals = false } },
    .{ .wait_element = .{ .id = "workspace.2.tab.1", .state = "exists", .equals = true } },
};

// TASK-56: the scripted fake agent, offered only to a driver run whose
// launch sets CONDUIT_TEST_FAKE_AGENT=1, is launched from the palette by
// keyboard (it is always the first harness choice), stepped by typed lines
// through idle, working, waiting for permission and done, and its done
// notification is opened from the list by a real click while another tab is
// active. The agent's own tab is the workspace's second.
const agent_tab_id = "workspace.1.tab.2";

const agent_notifications_env = [_]EnvVar{
    .{ .name = "CONDUIT_TEST_FAKE_AGENT", .value = "1" },
};

const agent_notifications_steps = [_]Step{
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_E2E> " } },
    .{ .key = "CTRL+SHIFT+p" },
    .{ .wait_element = .{ .id = "palette.query", .state = "focused", .equals = true } },
    .{ .type_text = "Agent: launch" },
    // Command, then the first harness choice (the fake), then the optional
    // prompt left empty.
    .{ .key = "ENTER" },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = "palette.argument", .state = "exists", .equals = true } },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = agent_tab_id ++ ".agent.idle", .state = "exists", .equals = true } },
    .{ .wait_terminal_text = .{ .contains = "FAKE-AGENT-READY" } },
    .{ .type_text = "one" },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = agent_tab_id ++ ".agent.working", .state = "exists", .equals = true } },
    .{ .wait_element = .{ .id = "workspace.1.agent.working", .state = "exists", .equals = true } },
    .{ .type_text = "two" },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = agent_tab_id ++ ".agent.waiting_permission", .state = "exists", .equals = true } },
    .{ .type_text = "three" },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = agent_tab_id ++ ".agent.done", .state = "exists", .equals = true } },
    .{ .wait_terminal_text = .{ .contains = "FAKE-STEP 3" } },
    // Back to the first tab, then the list by its chord; a click on the
    // newest entry (done) shows the agent's tab again.
    .{ .click = "workspace.1.tab.1" },
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_E2E> " } },
    .{ .key = "CTRL+SHIFT+n" },
    .{ .wait_element = .{ .id = "notifications", .state = "exists", .equals = true } },
    .{ .wait_element = .{ .id = "notification.1", .state = "exists", .equals = true } },
    .screenshot,
    .{ .click = "notification.0" },
    .{ .wait_element = .{ .id = "notifications", .state = "exists", .equals = false } },
    .{ .wait_terminal_text = .{ .contains = "FAKE-STEP 3" } },
    .screenshot,
    // TASK-80: the agent's own sidebar row under its tab. A click on it from
    // the first tab shows the agent and its view; the sidebar keys reach it
    // too, and Enter on the row of the view already showing closes it.
    .{ .click = "workspace.1.tab.1" },
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_E2E> " } },
    .{ .click = agent_row_id },
    // The view is registered only over a pane that is showing, so its
    // presence proves the agent's tab came forward.
    .{ .wait_element = .{ .id = agent_view_id, .state = "exists", .equals = true } },
    .screenshot,
    .{ .key = "CTRL+SHIFT+DOWN" },
    .{ .wait_element = .{ .id = "workspace.1", .state = "focused", .equals = true } },
    .{ .key = "TAB" },
    .{ .key = "DOWN" },
    .{ .key = "DOWN" },
    .{ .wait_element = .{ .id = agent_row_id, .state = "focused", .equals = true } },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = agent_view_id, .state = "exists", .equals = false } },
    // A fake harness started by hand in the first tab is observed: its row
    // appears under that human tab, a click shows its view, the keys close
    // it again, and the row stays, done, once the program leaves.
    .{ .click = "workspace.1.tab.1" },
    .{ .click = "workspace.1.pane.1" },
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_E2E> " } },
    .{ .type_text = observed_fake_command },
    .{ .key = "ENTER" },
    .{ .wait_terminal_text = .{ .contains = "OBS-READY" } },
    .{ .wait_element = .{ .id = observed_row_id, .state = "exists", .equals = true, .timeout_ms = 10_000 } },
    .{ .click = observed_row_id },
    .{ .wait_element = .{ .id = observed_view_id, .state = "exists", .equals = true } },
    .screenshot,
    .{ .key = "CTRL+SHIFT+DOWN" },
    .{ .wait_element = .{ .id = "workspace.1", .state = "focused", .equals = true } },
    .{ .key = "TAB" },
    .{ .key = "DOWN" },
    .{ .wait_element = .{ .id = observed_row_id, .state = "focused", .equals = true } },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = observed_view_id, .state = "exists", .equals = false } },
    .{ .click = "workspace.1.pane.1" },
    .{ .type_text = "bye" },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = "workspace.1.tab.1.agent.done", .state = "exists", .equals = true, .timeout_ms = 10_000 } },
    .{ .wait_element = .{ .id = observed_row_id, .state = "exists", .equals = true } },
    .screenshot,
};

/// The launched fake's sidebar row and view (agent 1, tab 2), and the
/// observed fake's (agent 2, tab 1).
const agent_row_id = agent_tab_id ++ ".agent-row.1";
const observed_row_id = "workspace.1.tab.1.agent-row.2";
const observed_view_id = "agent.view.2";

/// Starts the fake harness by hand as its own foreground job, named
/// `conduit-fake-agent` so it is recognised. Its marker is assembled by
/// printf, so the typed command's echo never contains `OBS-READY`.
const observed_fake_command =
    "set -m; f=\"${TMPDIR:-/tmp}/conduit-fake-agent\"; " ++
    "printf '%s\\n' 'printf \"OBS-%s\\n\" READY' 'read l' > \"$f\"; sh \"$f\"";

// TASK-57: the same fake agent, stepped to its first permission request,
// then shown as the structured agent view by its chord. The request's
// "Allow once" decision is clicked; the row then shows the outcome in place
// of its controls, and the chord returns to the raw terminal underneath.
const agent_view_id = "agent.view.1";
const agent_view_allow_id = agent_view_id ++ ".perm.fake-1.allow";
const agent_view_outcome_id = agent_view_id ++ ".perm.fake-1.outcome";

const agent_view_steps = [_]Step{
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_E2E> " } },
    .{ .key = "CTRL+SHIFT+p" },
    .{ .wait_element = .{ .id = "palette.query", .state = "focused", .equals = true } },
    .{ .type_text = "Agent: launch" },
    .{ .key = "ENTER" },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = "palette.argument", .state = "exists", .equals = true } },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = agent_tab_id ++ ".agent.idle", .state = "exists", .equals = true } },
    .{ .wait_terminal_text = .{ .contains = "FAKE-AGENT-READY" } },
    .{ .type_text = "one" },
    .{ .key = "ENTER" },
    .{ .type_text = "two" },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = agent_tab_id ++ ".agent.waiting_permission", .state = "exists", .equals = true } },
    .{ .key = "CTRL+SHIFT+a" },
    .{ .wait_element = .{ .id = agent_view_id, .state = "exists", .equals = true } },
    .{ .wait_element = .{ .id = agent_view_allow_id, .state = "exists", .equals = true } },
    .screenshot,
    .{ .click = agent_view_allow_id },
    .{ .wait_element = .{ .id = agent_view_outcome_id, .state = "exists", .equals = true } },
    .{ .wait_element = .{ .id = agent_view_allow_id, .state = "exists", .equals = false } },
    .screenshot,
    .{ .key = "CTRL+SHIFT+a" },
    .{ .wait_element = .{ .id = agent_view_id, .state = "exists", .equals = false } },
    .{ .wait_terminal_text = .{ .contains = "FAKE-STEP 2" } },
};

// TASK-58: the same fake agent, launched from the palette, then the agent
// manager opened by its chord from the first tab. Agent 1's row is clicked,
// which closes the manager and shows the agent's own tab again.
const agent_manager_row_id = "agents.row.1";

const agent_manager_steps = [_]Step{
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_E2E> " } },
    .{ .key = "CTRL+SHIFT+p" },
    .{ .wait_element = .{ .id = "palette.query", .state = "focused", .equals = true } },
    .{ .type_text = "Agent: launch" },
    .{ .key = "ENTER" },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = "palette.argument", .state = "exists", .equals = true } },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = agent_tab_id ++ ".agent.idle", .state = "exists", .equals = true } },
    .{ .wait_terminal_text = .{ .contains = "FAKE-AGENT-READY" } },
    .{ .click = "workspace.1.tab.1" },
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_E2E> " } },
    .{ .key = "CTRL+SHIFT+g" },
    .{ .wait_element = .{ .id = "agents.dialog", .state = "exists", .equals = true } },
    .{ .wait_element = .{ .id = agent_manager_row_id, .state = "exists", .equals = true } },
    .screenshot,
    .{ .click = agent_manager_row_id },
    .{ .wait_element = .{ .id = "agents.dialog", .state = "exists", .equals = false } },
    .{ .wait_terminal_text = .{ .contains = "FAKE-AGENT-READY" } },
    .screenshot,
};

// TASK-63: a fixture project written into the run's private TMPDIR, whose
// directory the child claims with OSC 7 so the view opens on it. The stand-in
// CLI the launch names makes the status edit the real `backlog` makes, and
// the child prints MOVED_DONE once the file says so: the move is proved in
// the file and then on the board, never by app state.
const backlog_board_cli = "./.conduit-e2e-backlog";

const backlog_board_env = [_]EnvVar{
    .{ .name = "CONDUIT_TEST_BACKLOG_CLI", .value = backlog_board_cli },
};

const backlog_board_command =
    "stty -echo; d=\"${TMPDIR:-/tmp}/conduit-e2e-backlog\"; " ++
    "mkdir -p \"$d/backlog/tasks\" && cd \"$d\" || exit 1; " ++
    "printf '%s\\n' 'project_name: \"E2E\"' 'statuses: [\"To Do\", \"In Progress\", \"Done\"]' > backlog/config.yml; " ++
    "printf '%s\\n' '---' 'id: TASK-1' 'title: Board scenario' 'status: To Do' 'ordinal: 1000' '---' '' " ++
    "'## Acceptance Criteria' '<!-- AC:BEGIN -->' '- [ ] #1 The board opens' '<!-- AC:END -->' " ++
    "> 'backlog/tasks/task-1 - Board-scenario.md'; " ++
    "printf '%s\\n' '#!/bin/sh' 'sed -i \"s/^status: .*/status: ${4#--status=}/\" backlog/tasks/*.md' > " ++ backlog_board_cli ++ "; " ++
    "chmod 700 " ++ backlog_board_cli ++ "; " ++
    "printf '\\033]7;file://localhost%s\\007' \"$PWD\"; printf 'BACKLOG_%s\\n' READY; " ++
    "until grep -q '^status: In Progress' backlog/tasks/*.md; do sleep 0.2; done; printf 'MOVED_%s\\n' DONE; " ++
    "while :; do sleep 60; done";

const backlog_board_steps = [_]Step{
    .{ .wait_terminal_text = .{ .contains = "BACKLOG_READY" } },
    .{ .key = "CTRL+SHIFT+k" },
    .{ .wait_element = .{ .id = "backlog.view", .state = "exists", .equals = true } },
    .{ .wait_element = .{ .id = "backlog.task.TASK-1.column.0", .state = "exists", .equals = true } },
    .screenshot,
    .{ .click = "backlog.task.TASK-1" },
    .{ .wait_element = .{ .id = "backlog.detail.TASK-1", .state = "exists", .equals = true } },
    .{ .wait_element = .{ .id = "backlog.detail.TASK-1.ac.1", .state = "exists", .equals = true } },
    .screenshot,
    .{ .key = "s" },
    .{ .wait_terminal_text = .{ .contains = "MOVED_DONE" } },
    .{ .key = "ESCAPE" },
    .{ .wait_element = .{ .id = "backlog.detail.TASK-1", .state = "exists", .equals = false } },
    .{ .wait_element = .{ .id = "backlog.task.TASK-1.column.1", .state = "exists", .equals = true } },
    .{ .wait_element = .{ .id = "backlog.task.TASK-1.column.0", .state = "exists", .equals = false } },
    .screenshot,
};

// TASK-60/TASK-66: a shell whose PATH starts with the directory of the
// Conduit it runs in (its parent process), so the typed `conduit control`
// is the installed client talking to this run's own control endpoint.
const control_api_command =
    "d=$(dirname \"$(readlink /proc/$PPID/exe)\"); PATH=\"$d:$PATH\"; " ++
    "PS1='CONDUIT_E2E> '; ENV=/dev/null; export PATH PS1 ENV; exec /bin/sh -i";

// The first tab is tab 1 with pane 1; the API-opened tab is tab 2 with pane
// 2, and the split it then asks for is pane 3.
const control_api_tab_id = "workspace.1.tab.2";
const control_api_split_id = "workspace.1.pane.3";

// TASK-79: a stand-in `codium` in the run's private TMPDIR that records its
// argv and, on a first launch, maps a real X client window whose title
// carries the marker Conduit seeded into the user-data-dir, so the X11
// hosting path runs for real. `editor.command` names it through the run's
// isolated settings file, which the app's watcher reloads. The screen is
// cleared and `/tmp` claimed with OSC 7 before the relative file reference
// is printed at row 0, so its link id matches `terminal-file-reference`'s.
const editor_pane_command =
    \\d="${TMPDIR:-/tmp}/conduit-e2e-editor"; mkdir -p "$d/proj" || exit 1
    \\printf '%s\n' one two three four five six > "$d/proj/notes.txt"
    \\printf '%s\n' '#!/bin/sh' \
    \\  '[ "$1" = --version ] && { echo 1.95.3; exit 0; }' \
    \\  'echo "$*" >> "$(dirname "$0")/codium.log"' \
    \\  '[ "$1" = --new-window ] && { m=$(grep -o "conduit-editor-[0-9a-f]*" "$3/User/settings.json"); setsid xlogo -title "stand-in $m" </dev/null >/dev/null 2>&1 & }' \
    \\  'exit 0' > "$d/codium"
    \\chmod 700 "$d/codium"
    \\c="${XDG_CONFIG_HOME:-$HOME/.config}/conduit"; mkdir -p "$c"
    \\printf 'editor.command = %s\n' "$d/codium" > "$c/config"
    \\cd /tmp || exit 1
    \\printf '\033[2J\033[H\033]7;file://localhost/tmp\007%s\n' './cdt-e2e.txt:3'
    \\x=$(dirname "$(readlink /proc/$PPID/exe)"); PATH="$x:$PATH"; PS1='CONDUIT_E2E> '; ENV=/dev/null
    \\export d PATH PS1 ENV; exec /bin/sh -i
;

// Pane 1 is the first terminal; each new editor pane takes the next id.
const editor_pane_first = "workspace.1.pane.2.editor";
const editor_pane_menu = "workspace.1.pane.3.editor";
const editor_pane_palette = "workspace.1.pane.4.editor";

const editor_pane_steps = [_]Step{
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_E2E> " } },
    // The API: retried while the settings reload finds the stand-in, then
    // a new pane beside the terminal that hosts the stand-in's window.
    .{ .type_text = "until conduit control editor.open \"{\\\"path\\\":\\\"$d/proj/notes.txt\\\",\\\"line\\\":2}\" >/dev/null 2>&1; do sleep 0.2; done; printf 'OPEN_%s\\n' OK" },
    .{ .key = "ENTER" },
    .{ .wait_terminal_text = .{ .contains = "OPEN_OK", .timeout_ms = 10_000 } },
    .{ .wait_element = .{ .id = editor_pane_first, .state = "exists", .equals = true } },
    .{ .wait_element = .{ .id = "editor.placeholder", .state = "exists", .equals = false } },
    .screenshot,
    // A second request reuses the pane: no third pane appears.
    .{ .type_text = "conduit control editor.goto \"{\\\"path\\\":\\\"$d/proj/notes.txt\\\",\\\"line\\\":5}\" >/dev/null && printf 'GOTO_%s\\n' OK" },
    .{ .key = "ENTER" },
    .{ .wait_terminal_text = .{ .contains = "GOTO_OK" } },
    .{ .wait_element = .{ .id = "workspace.1.pane.3", .state = "exists", .equals = false } },
    // The pane's close control (mouse).
    .{ .click = editor_pane_first ++ ".close" },
    .{ .wait_element = .{ .id = editor_pane_first, .state = "exists", .equals = false } },
    // The context menu over the printed `path:line` (mouse).
    .{ .wait_element = .{ .id = editor_pane_link, .state = "exists", .equals = true } },
    .{ .right_click = editor_pane_link },
    .{ .wait_element = .{ .id = "context-menu.open-in-editor", .state = "exists", .equals = true } },
    .{ .click = "context-menu.open-in-editor" },
    .{ .wait_element = .{ .id = editor_pane_menu, .state = "exists", .equals = true } },
    .{ .wait_element = .{ .id = "editor.placeholder", .state = "exists", .equals = false } },
    // Escape over the focused editor pane gives the space back.
    .{ .key = "ESCAPE" },
    .{ .wait_element = .{ .id = editor_pane_menu, .state = "exists", .equals = false } },
    // The palette (keyboard): a path relative to the terminal's OSC 7 cwd.
    .{ .key = "CTRL+SHIFT+p" },
    .{ .wait_element = .{ .id = "palette.query", .state = "exists", .equals = true } },
    .{ .type_text = "Editor: open file" },
    .{ .key = "ENTER" },
    .{ .type_text = "cdt-e2e.txt:2" },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = editor_pane_palette, .state = "exists", .equals = true } },
    .{ .wait_element = .{ .id = "editor.placeholder", .state = "exists", .equals = false } },
    .screenshot,
};

// The same derivation as `terminal_file_reference_id`: the same text at row
// 0, column 0 of the first terminal, with `/tmp` as its cwd.
const editor_pane_link = terminal_file_reference_id;

const control_api_steps = [_]Step{
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_E2E> " } },
    .{ .type_text = "conduit control tab.open '{\"title\":\"api\"}'" },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = control_api_tab_id, .state = "exists", .equals = true } },
    // The new tab's own shell, reached through the same command line.
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_E2E> " } },
    .{ .type_text = "conduit control pane.split '{\"direction\":\"right\"}'" },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = control_api_split_id, .state = "exists", .equals = true } },
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_E2E> " } },
    // The marker is spelled whole only by the shell after an exit status of
    // 0, so a refused request (which exits 1) can never satisfy the wait.
    .{ .type_text = "conduit control tab.status '{\"text\":\"busy\",\"attention\":true}' && printf 'STATUS_%s\\n' SET" },
    .{ .key = "ENTER" },
    .{ .wait_terminal_text = .{ .contains = "STATUS_SET" } },
    // The opened tab is an ordinary tab: the mouse switches away and back.
    .{ .click = "workspace.1.tab.1" },
    .{ .wait_element = .{ .id = "workspace.1.pane.1", .state = "exists", .equals = true } },
    .{ .click = control_api_tab_id },
    .{ .wait_element = .{ .id = control_api_split_id, .state = "exists", .equals = true } },
    .screenshot,
};

// TASK-59: a fixture project written into the run's private TMPDIR, whose
// directory the shell claims with OSC 7, so the fake agent (which reads
// instructions as Claude Code does) is launched there. Its prompts view is
// opened from the palette; CLAUDE.md in the agent's cwd is always the first
// row, and a click on it opens vi on the file in a new tab.
const agent_prompts_command =
    "d=\"${TMPDIR:-/tmp}/conduit-e2e-prompts\"; " ++
    "mkdir -p \"$d/.claude/agents\" && cd \"$d\" || exit 1; " ++
    "printf '%s\\n' '# Project rules' 'Answer in PROMPTS_FIXTURE style.' > CLAUDE.md; " ++
    "printf '%s\\n' 'Review every diff.' > .claude/agents/reviewer.md; " ++
    "printf '\\033]7;file://localhost%s\\007' \"$PWD\"; " ++
    "PS1='CONDUIT_E2E> '; ENV=/dev/null; export PS1 ENV; exec /bin/sh -i";

const agent_prompts_dialog_id = "agent.prompts.1";
const agent_prompts_claude_row = agent_prompts_dialog_id ++ ".item.0";
// Tab 1 is the shell, tab 2 the agent, tab 3 the editor.
const agent_prompts_editor_tab = "workspace.1.tab.3";

const agent_prompts_steps = [_]Step{
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_E2E> " } },
    .{ .key = "CTRL+SHIFT+p" },
    .{ .wait_element = .{ .id = "palette.query", .state = "focused", .equals = true } },
    .{ .type_text = "Agent: launch" },
    .{ .key = "ENTER" },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = "palette.argument", .state = "exists", .equals = true } },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = agent_tab_id ++ ".agent.idle", .state = "exists", .equals = true } },
    .{ .wait_terminal_text = .{ .contains = "FAKE-AGENT-READY" } },
    .{ .key = "CTRL+SHIFT+p" },
    .{ .wait_element = .{ .id = "palette.query", .state = "focused", .equals = true } },
    .{ .type_text = "Agent: prompts" },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = agent_prompts_dialog_id, .state = "exists", .equals = true } },
    .{ .wait_element = .{ .id = agent_prompts_claude_row, .state = "exists", .equals = true } },
    .screenshot,
    .{ .click = agent_prompts_claude_row },
    .{ .wait_element = .{ .id = agent_prompts_dialog_id, .state = "exists", .equals = false } },
    .{ .wait_element = .{ .id = agent_prompts_editor_tab, .state = "exists", .equals = true } },
    // vi shows the file's own text, never typed by the scenario.
    .{ .wait_terminal_text = .{ .contains = "PROMPTS_FIXTURE style." } },
    .screenshot,
};

// TASK-46: a tab opened from the shell-profile chooser. The palette lists the
// built-in profiles first, so choice 0 of `tab.new-with-profile` (registry
// index 82; it shifts when an action is registered before it) is `login`, the
// launch's `$SHELL` as a login shell under the isolated HOME. The new tab's
// row appears, and the shell it runs answers a typed command with output its
// spelling does not contain.
const tab_profile_action_index = "82";
const profile_tab_choice = "palette.choice." ++ tab_profile_action_index ++ ".0";
const profile_tab_row = "workspace.1.tab.2";

const profile_tab_steps = [_]Step{
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_E2E> " } },
    .{ .key = "CTRL+SHIFT+p" },
    .{ .wait_element = .{ .id = "palette.query", .state = "focused", .equals = true } },
    .{ .type_text = "New tab with profile" },
    .{ .key = "ENTER" },
    .{ .wait_element = .{ .id = profile_tab_choice, .state = "exists", .equals = true } },
    .screenshot,
    .{ .click = profile_tab_choice },
    .{ .wait_element = .{ .id = profile_tab_row, .state = "exists", .equals = true } },
    .{ .wait_element = .{ .id = "palette.dialog", .state = "exists", .equals = false } },
    .{ .type_text = "printf 'PROFILE_%s\\n' 'TAB_READY'" },
    .{ .key = "ENTER" },
    .{ .wait_terminal_text = .{ .contains = "PROFILE_TAB_READY", .timeout_ms = 15_000 } },
    .screenshot,
};

pub const all = [_]Scenario{
    .{
        .name = "launch-prompt",
        .command = deterministic_shell,
        .steps = &launch_prompt_steps,
    },
    .{
        .name = "type-command",
        .command = deterministic_shell,
        .steps = &type_command_steps,
    },
    .{
        .name = "select-copy",
        .command = deterministic_shell,
        .steps = &select_copy_steps,
    },
    .{
        .name = "terminal-links",
        .command = terminal_link_command,
        .steps = &terminal_link_steps,
    },
    .{
        .name = "terminal-file-reference",
        .command = terminal_file_reference_command,
        .steps = &terminal_file_reference_steps,
    },
    .{
        .name = "output-flood",
        .command = deterministic_shell,
        .steps = &output_flood_steps,
    },
    .{
        .name = "context-menu",
        .command = deterministic_shell,
        .steps = &context_menu_steps,
    },
    .{
        .name = "child-environment",
        .launch_env = &child_environment_launch_env,
        .command = child_environment_command,
        .steps = &child_environment_steps,
    },
    .{
        .name = "sidebar-palette",
        .command = deterministic_shell,
        .steps = &sidebar_palette_steps,
    },
    .{
        .name = "font-coverage",
        .command = font_coverage_command,
        .steps = &font_coverage_steps,
    },
    .{
        .name = "theme-picker",
        .command = deterministic_shell,
        .steps = &theme_picker_steps,
    },
    .{
        .name = "font-picker",
        .command = deterministic_shell,
        .steps = &font_picker_steps,
    },
    .{
        .name = "settings-view",
        .command = deterministic_shell,
        .steps = &settings_view_steps,
    },
    .{
        .name = "sidebar-branch",
        .command = sidebar_branch_command,
        .steps = &sidebar_branch_steps,
    },
    .{
        .name = "agent-notifications",
        .launch_env = &agent_notifications_env,
        .command = deterministic_shell,
        .steps = &agent_notifications_steps,
    },
    .{
        .name = "agent-view",
        .launch_env = &agent_notifications_env,
        .command = deterministic_shell,
        .steps = &agent_view_steps,
    },
    .{
        .name = "agent-manager",
        .launch_env = &agent_notifications_env,
        .command = deterministic_shell,
        .steps = &agent_manager_steps,
    },
    .{
        .name = "backlog-board",
        .launch_env = &backlog_board_env,
        .command = backlog_board_command,
        .steps = &backlog_board_steps,
    },
    .{
        .name = "control-api",
        .command = control_api_command,
        .steps = &control_api_steps,
    },
    .{
        .name = "agent-prompts",
        .launch_env = &agent_notifications_env,
        .command = agent_prompts_command,
        .steps = &agent_prompts_steps,
    },
    .{
        .name = "profile-tab",
        .command = deterministic_shell,
        .steps = &profile_tab_steps,
    },
    .{
        .name = "editor-pane",
        .command = editor_pane_command,
        .steps = &editor_pane_steps,
    },
};

test "the editor pane scenario opens by API, context menu and palette and closes by click and Escape" {
    const scenario = all[21];
    try std.testing.expectEqualStrings("editor-pane", scenario.name);
    try std.testing.expectEqual(@as(usize, 22), all.len);
    var api = false;
    var goto = false;
    var menu = false;
    var palette = false;
    var clicked_close = false;
    var escaped = false;
    for (scenario.steps) |step| switch (step) {
        .type_text => |text| {
            if (std.mem.indexOf(u8, text, "conduit control editor.open") != null) api = true;
            if (std.mem.indexOf(u8, text, "conduit control editor.goto") != null) goto = true;
            if (std.mem.eql(u8, text, "Editor: open file")) palette = true;
        },
        .click => |id| {
            if (std.mem.eql(u8, id, "context-menu.open-in-editor")) menu = true;
            if (std.mem.eql(u8, id, editor_pane_first ++ ".close")) clicked_close = true;
        },
        .key => |key| if (std.mem.eql(u8, key, "ESCAPE")) {
            escaped = true;
        },
        // The asserted markers are spelled whole only by the shell's printf.
        .wait_terminal_text => |wait| for (scenario.steps) |other| switch (other) {
            .type_text => |text| try std.testing.expect(std.mem.indexOf(u8, text, wait.contains) == null),
            else => {},
        },
        else => {},
    };
    try std.testing.expect(api and goto and menu and palette and clicked_close and escaped);
}

test "the profile tab scenario opens the chooser by keyboard and clicks the built-in row" {
    const scenario = all[20];
    try std.testing.expectEqualStrings("profile-tab", scenario.name);
    var clicked = false;
    var typed_command = false;
    for (scenario.steps) |step| switch (step) {
        .click => |id| {
            if (std.mem.eql(u8, id, profile_tab_choice)) clicked = true;
        },
        .type_text => |text| {
            if (std.mem.startsWith(u8, text, "printf")) typed_command = true;
        },
        // The asserted output never appears in the typed command.
        .wait_terminal_text => |wait| for (scenario.steps) |other| switch (other) {
            .type_text => |text| try std.testing.expect(std.mem.indexOf(u8, text, wait.contains) == null),
            else => {},
        },
        else => {},
    };
    try std.testing.expect(clicked and typed_command);
}

test "the agent prompts scenario opens the view from the palette and edits CLAUDE.md by a click" {
    const scenario = all[19];
    try std.testing.expectEqualStrings("agent-prompts", scenario.name);
    try std.testing.expectEqual(@as(usize, 22), all.len);
    try std.testing.expectEqualStrings("CONDUIT_TEST_FAKE_AGENT", scenario.launch_env[0].name);
    var opened = false;
    var clicked = false;
    var editor = false;
    for (scenario.steps) |step| switch (step) {
        .type_text => |text| if (std.mem.eql(u8, text, "Agent: prompts")) {
            opened = true;
        },
        .click => |id| if (std.mem.eql(u8, id, agent_prompts_claude_row)) {
            clicked = true;
        },
        .wait_element => |wait| if (std.mem.eql(u8, wait.id, agent_prompts_editor_tab) and wait.equals) {
            editor = true;
        },
        // The asserted file text is never typed by a step.
        .wait_terminal_text => |wait| if (std.mem.indexOf(u8, wait.contains, "PROMPTS_FIXTURE") != null) {
            try std.testing.expect(std.mem.indexOf(u8, agent_prompts_command, wait.contains) != null);
        },
        else => {},
    };
    try std.testing.expect(opened and clicked and editor);
}

test "the control API scenario opens a tab and a pane from the terminal, then switches by mouse" {
    const scenario = all[18];
    try std.testing.expectEqualStrings("control-api", scenario.name);
    try std.testing.expectEqual(@as(usize, 22), all.len);
    var opened = false;
    var split = false;
    var clicked = false;
    for (scenario.steps) |step| switch (step) {
        .type_text => |text| {
            if (std.mem.startsWith(u8, text, "conduit control tab.open")) opened = true;
            if (std.mem.startsWith(u8, text, "conduit control pane.split")) split = true;
        },
        .click => |id| if (std.mem.eql(u8, id, control_api_tab_id)) {
            clicked = true;
        },
        else => {},
    };
    try std.testing.expect(opened and split and clicked);
}

test "the backlog scenario opens the view by chord, a card by click, and moves the task" {
    const scenario = all[17];
    try std.testing.expectEqualStrings("backlog-board", scenario.name);
    try std.testing.expectEqual(@as(usize, 22), all.len);
    try std.testing.expectEqualStrings("CONDUIT_TEST_BACKLOG_CLI", scenario.launch_env[0].name);
    var chord = false;
    var clicked = false;
    var moved = false;
    for (scenario.steps) |step| switch (step) {
        .key => |key| if (std.mem.eql(u8, key, "CTRL+SHIFT+k")) {
            chord = true;
        },
        .click => |id| if (std.mem.eql(u8, id, "backlog.task.TASK-1")) {
            clicked = true;
        },
        .wait_element => |wait| if (std.mem.eql(u8, wait.id, "backlog.task.TASK-1.column.1") and wait.equals) {
            moved = true;
        },
        // The asserted marker is never typed or spelled whole in the command.
        .wait_terminal_text => |wait| try std.testing.expect(std.mem.indexOf(u8, backlog_board_command, wait.contains) == null),
        else => {},
    };
    try std.testing.expect(chord and clicked and moved);
}

test "the agent manager scenario opens the manager by chord and focuses by a click" {
    const scenario = all[16];
    try std.testing.expectEqualStrings("agent-manager", scenario.name);
    try std.testing.expectEqual(@as(usize, 22), all.len);
    try std.testing.expectEqualStrings("CONDUIT_TEST_FAKE_AGENT", scenario.launch_env[0].name);
    var chord = false;
    var clicked = false;
    var closed = false;
    for (scenario.steps) |step| switch (step) {
        .key => |key| if (std.mem.eql(u8, key, "CTRL+SHIFT+g")) {
            chord = true;
        },
        .click => |id| if (std.mem.eql(u8, id, agent_manager_row_id)) {
            clicked = true;
        },
        .wait_element => |wait| if (std.mem.eql(u8, wait.id, "agents.dialog") and !wait.equals) {
            closed = true;
        },
        else => {},
    };
    try std.testing.expect(chord and clicked and closed);
}

test "the agent view scenario opens the view by chord and answers by a click" {
    const scenario = all[15];
    try std.testing.expectEqualStrings("agent-view", scenario.name);
    try std.testing.expectEqual(@as(usize, 22), all.len);
    var chords: usize = 0;
    var clicked = false;
    var outcome = false;
    for (scenario.steps) |step| switch (step) {
        .key => |key| if (std.mem.eql(u8, key, "CTRL+SHIFT+a")) {
            chords += 1;
        },
        .click => |id| if (std.mem.eql(u8, id, agent_view_allow_id)) {
            clicked = true;
        },
        .wait_element => |wait| if (std.mem.eql(u8, wait.id, agent_view_outcome_id) and wait.equals) {
            outcome = true;
        },
        else => {},
    };
    try std.testing.expect(chords == 2 and clicked and outcome);
}

test "the agent scenario enables the fake only for launch and walks every glyph to done" {
    const scenario = all[14];
    try std.testing.expectEqualStrings("agent-notifications", scenario.name);
    try std.testing.expectEqual(@as(usize, 1), scenario.launch_env.len);
    try std.testing.expectEqualStrings("CONDUIT_TEST_FAKE_AGENT", scenario.launch_env[0].name);
    var states: usize = 0;
    var clicked_row = false;
    for (scenario.steps) |step| switch (step) {
        .wait_element => |wait| if (std.mem.indexOf(u8, wait.id, ".agent.") != null) {
            states += 1;
        },
        .click => |id| if (std.mem.eql(u8, id, "notification.0")) {
            clicked_row = true;
        },
        else => {},
    };
    try std.testing.expect(states >= 5 and clicked_row);
}

test "the agent scenario opens launched and observed agents from their sidebar rows by mouse and keys" {
    const scenario = all[14];
    try std.testing.expectEqualStrings("agent-notifications", scenario.name);
    var row_clicks: usize = 0;
    var row_focus: usize = 0;
    var observed_row = false;
    for (scenario.steps) |step| switch (step) {
        .click => |id| if (std.mem.indexOf(u8, id, ".agent-row.") != null) {
            row_clicks += 1;
        },
        .wait_element => |wait| {
            if (std.mem.indexOf(u8, wait.id, ".agent-row.") != null and std.mem.eql(u8, wait.state, "focused") and wait.equals) row_focus += 1;
            if (std.mem.eql(u8, wait.id, observed_row_id) and std.mem.eql(u8, wait.state, "exists") and wait.equals) observed_row = true;
        },
        else => {},
    };
    try std.testing.expect(row_clicks == 2 and row_focus == 2 and observed_row);
    try std.testing.expect(std.mem.indexOf(u8, observed_fake_command, "OBS-READY") == null);
}

test "sidebar branch scenario waits on the branch row appearing, leaving and returning" {
    const scenario = all[13];
    try std.testing.expectEqualStrings("sidebar-branch", scenario.name);
    var appeared: usize = 0;
    var vanished: usize = 0;
    var clicked_second = false;
    for (scenario.steps) |step| switch (step) {
        .wait_element => |wait| if (std.mem.eql(u8, wait.id, sidebar_branch_id)) {
            if (wait.equals) appeared += 1 else vanished += 1;
        },
        .click => |id| if (std.mem.eql(u8, id, "workspace.2")) {
            clicked_second = true;
        },
        // No typed line contains the asserted output verbatim.
        .wait_terminal_text => |wait| try std.testing.expect(std.mem.indexOf(u8, sidebar_branch_command, wait.contains) == null or
            std.mem.eql(u8, wait.contains, "branch$ ")),
        else => {},
    };
    try std.testing.expect(appeared >= 3 and vanished >= 2 and clicked_second);
}

test "scenario names and semantic selectors are stable and non-empty" {
    for (all, 0..) |scenario, index| {
        try std.testing.expect(scenario.name.len != 0);
        try std.testing.expect(scenario.command.len != 0);
        try std.testing.expect(scenario.steps.len != 0);
        for (all[0..index]) |earlier| {
            try std.testing.expect(!std.mem.eql(u8, scenario.name, earlier.name));
        }
        for (scenario.steps) |step| switch (step) {
            .click, .ctrl_click, .right_click => |id| try std.testing.expect(id.len != 0),
            .wait_element => |wait| try std.testing.expect(wait.id.len != 0),
            else => {},
        };
    }
}

test "terminal link scenario pins the production semantic identity" {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("conduit-terminal-link-v1\x00");
    hash.update(&.{0x01});
    hash.update(&.{ 0, 0, 0, 0 });
    hash.update(&.{ 0, 0, 0, 0 });
    hash.update(terminal_link_url);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    const fingerprint = std.fmt.bytesToHex(digest[0..16].*, .lower);
    try std.testing.expectEqualStrings("40989a0ff4dc7589a09be53774d38440", &fingerprint);

    var id_buffer: [128]u8 = undefined;
    const derived_id = try std.fmt.bufPrint(
        &id_buffer,
        "workspace.1.session.2.terminal-link.0.0.{s}.{d}",
        .{ &fingerprint, terminal_link_url.len },
    );
    try std.testing.expectEqualStrings(terminal_link_id, derived_id);
    try std.testing.expectEqualStrings("terminal-links", all[3].name);
    try std.testing.expectEqualStrings(terminal_link_command, all[3].command);
    switch (all[3].steps[2]) {
        .ctrl_click => |id| try std.testing.expectEqualStrings(terminal_link_id, id),
        else => return error.TestUnexpectedResult,
    }
}

test "file reference scenario pins the production semantic identity and the new tab" {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("conduit-terminal-link-v1\x00");
    hash.update(&.{0x02});
    hash.update(&.{ 0, 0, 0, 3 });
    hash.update(&.{ 0, 0, 0, 0 });
    hash.update(terminal_file_reference);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    const fingerprint = std.fmt.bytesToHex(digest[0..16].*, .lower);

    var id_buffer: [128]u8 = undefined;
    const derived_id = try std.fmt.bufPrint(
        &id_buffer,
        "workspace.1.session.2.terminal-link.0.0.{s}.{d}",
        .{ &fingerprint, terminal_file_reference.len },
    );
    try std.testing.expectEqualStrings(terminal_file_reference_id, derived_id);
    const scenario = all[4];
    try std.testing.expectEqualStrings("terminal-file-reference", scenario.name);
    try std.testing.expect(std.mem.indexOf(u8, scenario.command, terminal_file_reference_resolved) == null);
    switch (scenario.steps[2]) {
        .ctrl_click => |id| try std.testing.expectEqualStrings(terminal_file_reference_id, id),
        else => return error.TestUnexpectedResult,
    }
    switch (scenario.steps[3]) {
        .wait_element => |wait| try std.testing.expectEqualStrings(terminal_file_reference_tab_id, wait.id),
        else => return error.TestUnexpectedResult,
    }
    switch (scenario.steps[4]) {
        .wait_terminal_text => |wait| try std.testing.expectEqualStrings(terminal_file_reference_resolved, wait.contains),
        else => return error.TestUnexpectedResult,
    }
}

test "context menu scenario right-clicks the terminal pane and activates the search row" {
    const scenario = all[6];
    try std.testing.expectEqualStrings("context-menu", scenario.name);
    try std.testing.expectEqualStrings(deterministic_shell, scenario.command);
    switch (scenario.steps[1]) {
        .right_click => |id| try std.testing.expectEqualStrings(terminal_pane_id, id),
        else => return error.TestUnexpectedResult,
    }
    switch (scenario.steps[2]) {
        .wait_element => |wait| {
            try std.testing.expectEqualStrings("context-menu.search", wait.id);
            try std.testing.expect(wait.equals);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (scenario.steps[4]) {
        .click => |id| try std.testing.expectEqualStrings("context-menu.search", id),
        else => return error.TestUnexpectedResult,
    }
    switch (scenario.steps[5]) {
        .wait_element => |wait| try std.testing.expectEqualStrings("search.query", wait.id),
        else => return error.TestUnexpectedResult,
    }
    switch (scenario.steps[6]) {
        .wait_element => |wait| {
            try std.testing.expectEqualStrings("context-menu", wait.id);
            try std.testing.expect(!wait.equals);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "output flood scenario waits for a marker the typed command cannot echo" {
    const scenario = all[5];
    try std.testing.expectEqualStrings("output-flood", scenario.name);
    try std.testing.expect(std.mem.indexOf(u8, output_flood_command, output_flood_marker) == null);
    switch (scenario.steps[1]) {
        .type_text => |text| try std.testing.expectEqualStrings(output_flood_command, text),
        else => return error.TestUnexpectedResult,
    }
    switch (scenario.steps[3]) {
        .type_text => |text| try std.testing.expectEqualStrings(output_flood_typed_command, text),
        else => return error.TestUnexpectedResult,
    }
    switch (scenario.steps[5]) {
        .wait_terminal_text => |wait| {
            try std.testing.expectEqualStrings(output_flood_marker, wait.contains);
            try std.testing.expect(wait.timeout_ms <= 20_000);
        },
        else => return error.TestUnexpectedResult,
    }
    // The typed-ahead line's marker only exists once the shell expands it.
    try std.testing.expect(std.mem.indexOf(u8, output_flood_typed_command, output_flood_typed_marker) == null);
    switch (scenario.steps[6]) {
        .wait_terminal_text => |wait| try std.testing.expectEqualStrings(output_flood_typed_marker, wait.contains),
        else => return error.TestUnexpectedResult,
    }
}

test "child environment scenario waits only on values the child expanded" {
    const scenario = all[7];
    try std.testing.expectEqualStrings("child-environment", scenario.name);
    try std.testing.expectEqual(child_environment_launch_env.len, scenario.launch_env.len);
    for (scenario.steps) |step| switch (step) {
        // The command text is never shown, but even if it were, no expected
        // line appears in it verbatim: each needs a shell expansion.
        .wait_terminal_text => |wait| try std.testing.expect(std.mem.indexOf(u8, scenario.command, wait.contains) == null),
        else => {},
    };
}

test "sidebar palette scenario clicks the footer hint and waits for the focused query" {
    const scenario = all[8];
    try std.testing.expectEqualStrings("sidebar-palette", scenario.name);
    switch (scenario.steps[2]) {
        .click => |id| try std.testing.expectEqualStrings("sidebar.palette", id),
        else => return error.TestUnexpectedResult,
    }
    switch (scenario.steps[3]) {
        .wait_element => |wait| try std.testing.expectEqualStrings("palette.dialog", wait.id),
        else => return error.TestUnexpectedResult,
    }
    switch (scenario.steps[4]) {
        .wait_element => |wait| {
            try std.testing.expectEqualStrings("palette.query", wait.id);
            try std.testing.expectEqualStrings("focused", wait.state);
            try std.testing.expect(wait.equals);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "picker scenarios drive both pickers by keyboard and by a clicked choice row" {
    const theme_scenario = all[10];
    const font_scenario = all[11];
    try std.testing.expectEqualStrings("theme-picker", theme_scenario.name);
    try std.testing.expectEqualStrings("font-picker", font_scenario.name);
    for ([_]struct { scenario: Scenario, choice: []const u8 }{
        .{ .scenario = theme_scenario, .choice = theme_pick_second_choice },
        .{ .scenario = font_scenario, .choice = font_pick_second_choice },
    }) |case| {
        var saw_down = false;
        var saw_escape = false;
        var saw_hint = false;
        var saw_choice_click = false;
        for (case.scenario.steps) |step| switch (step) {
            .key => |key| {
                if (std.mem.eql(u8, key, "DOWN")) saw_down = true;
                if (std.mem.eql(u8, key, "ESCAPE")) saw_escape = true;
            },
            .click => |id| {
                if (std.mem.eql(u8, id, "sidebar.palette")) saw_hint = true;
                if (std.mem.eql(u8, id, case.choice)) saw_choice_click = true;
            },
            else => {},
        };
        try std.testing.expect(saw_down and saw_escape and saw_hint and saw_choice_click);
    }
    // A font preview is waited for after Down, never assumed.
    for (font_scenario.steps, 0..) |step, index| switch (step) {
        .key => |key| if (std.mem.eql(u8, key, "DOWN")) switch (font_scenario.steps[index + 1]) {
            .wait_element => |wait| try std.testing.expectEqualStrings("palette.preview", wait.id),
            else => return error.TestUnexpectedResult,
        },
        else => {},
    };
}

test "settings view scenario opens by keyboard and by the sidebar hint and clicks a bool row" {
    const scenario = all[12];
    try std.testing.expectEqualStrings("settings-view", scenario.name);
    try std.testing.expectEqual(@as(usize, 22), all.len);
    var saw_dialog = false;
    var saw_down = false;
    var saw_escape = false;
    var saw_hint = false;
    var clicked_row = false;
    var screenshots: usize = 0;
    for (scenario.steps, 0..) |step, index| switch (step) {
        .wait_element => |wait| if (std.mem.eql(u8, wait.id, "settings.dialog") and wait.equals) {
            saw_dialog = true;
        },
        .key => |key| {
            if (std.mem.eql(u8, key, "DOWN")) saw_down = true;
            if (std.mem.eql(u8, key, "ESCAPE")) saw_escape = true;
        },
        .click => |id| {
            if (std.mem.eql(u8, id, "sidebar.palette")) saw_hint = true;
            if (std.mem.eql(u8, id, settings_bool_row)) {
                clicked_row = true;
                // The dialog is still there after the click toggled the row.
                switch (scenario.steps[index + 1]) {
                    .wait_element => |wait| {
                        try std.testing.expectEqualStrings("settings.dialog", wait.id);
                        try std.testing.expect(wait.equals);
                    },
                    else => return error.TestUnexpectedResult,
                }
            }
        },
        .screenshot => screenshots += 1,
        else => {},
    };
    try std.testing.expect(saw_dialog and saw_down and saw_escape and saw_hint and clicked_row);
    try std.testing.expectEqual(@as(usize, 2), screenshots);
}
