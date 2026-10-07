//! Declarative TASK-25 scenarios consumed by the standalone E2E runner.
//!
//! Scenario steps name only public `conduit-test` operations. Assertions use
//! bounded driver waits, and pointer input names semantic ids rather than
//! coordinates, so a layout or display-scale change does not rewrite tests.

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
const output_flood_marker = "FLOOD_2_DONE";
const output_flood_command =
    "yes 0123456789abcdef | tr '\\n' '\\r' | head -c 4000000; echo; echo FLOOD_$((1+1))_DONE";

const output_flood_steps = [_]Step{
    .{ .wait_terminal_text = .{ .contains = "CONDUIT_E2E> " } },
    .{ .type_text = output_flood_command },
    .{ .key = "ENTER" },
    .{ .wait_terminal_text = .{ .contains = output_flood_marker, .timeout_ms = 20_000 } },
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
};

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
        .wait_terminal_text => |wait| {
            try std.testing.expectEqualStrings(output_flood_marker, wait.contains);
            try std.testing.expect(wait.timeout_ms <= 20_000);
        },
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
