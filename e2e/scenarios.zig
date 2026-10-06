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

/// Fixed launch geometry and ordered user-visible operations for one run.
pub const Scenario = struct {
    name: []const u8,
    width: u32 = 640,
    height: u32 = 360,
    scale: f32 = 1,
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

/// All scenarios in deterministic execution and report order.
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
        .name = "context-menu",
        .command = deterministic_shell,
        .steps = &context_menu_steps,
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
    const scenario = all[all.len - 1];
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
