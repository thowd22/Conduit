//! The settings surface: setting names, where a value comes from, the settings file, its
//! validation and its hot reload.
//!
//! **Owns** the settings file format, its built-in defaults, the platform-appropriate location,
//! validation with line-numbered diagnostics, and the watcher that notices edits.
//! **Never** owns a window, a session or a colour: a setting is data, and the module that consumes
//! it is the one that interprets it. A chord string in a `keybind` line is carried as text and
//! parsed by `input`; whether an action exists is the registry's answer, given in `app`.
//! **May depend on** `std` (and `builtin`, to select the location and the watch backend).
//!
//! TASK-37 adds the file layer. The format is Ghostty-style text: one `key = value` per line, `#`
//! starts a comment line, blank lines are ignored. `docs/config.md` is the user-facing grammar.
//!
//! Threads: `parse`, `readFile` and `load` run on the caller's thread (the app calls them on the
//! main thread). A `Watcher` owns one background thread that only observes the file system and
//! sets an atomic flag before calling the caller's wake callback; it never reads or parses the
//! file and never touches app state.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The log scope for configuration failures. TASK-6 replaces this with the project's diagnostics
/// infrastructure.
pub const log = std.log.scoped(.config);

/// The name a setting is addressed by.
///
/// Invariant: a name is lowercase, made of `_`- and `.`-separated words, and starts with a letter, so
/// the name in the file, the name in the palette and the name in a log line are always the same
/// string. Anything else is `error.InvalidName` rather than a setting nobody can find again.
pub const Name = struct {
    bytes: []const u8,

    /// The longest name accepted. Long enough for `font.bold_italic`, short enough that a typo is
    /// obvious in the palette.
    pub const max_length: usize = 64;

    pub const Error = error{InvalidName};

    /// Validate and wrap a setting name.
    pub fn parse(raw: []const u8) Error!Name {
        if (raw.len == 0 or raw.len > max_length) return error.InvalidName;
        if (!std.ascii.isLower(raw[0])) return error.InvalidName;
        for (raw) |c| {
            if (!(std.ascii.isLower(c) or c == '_' or c == '.')) return error.InvalidName;
        }
        // A doubled separator means a typo in a hand-edited file, and two spellings of one setting is
        // exactly the failure a settings file must not have.
        if (std.mem.indexOf(u8, raw, "__") != null) return error.InvalidName;
        return .{ .bytes = raw };
    }

    /// Render the name back to the text it was parsed from.
    pub fn text(self: Name) []const u8 {
        return self.bytes;
    }

    /// Order two names, so a palette listing settings is stable.
    pub fn order(a: Name, b: Name) std.math.Order {
        return std.mem.order(u8, a.bytes, b.bytes);
    }
};

/// Where a value came from, lowest precedence first.
///
/// The order of this enum *is* the precedence order: a value from a later layer replaces one from an
/// earlier layer, and the first layer is what a `reset` returns to.
pub const Layer = enum(u8) {
    /// The value compiled into Conduit. Always present, never optional.
    built_in,
    /// The value in the user's settings file.
    file,
    /// A value set for this run only, by a command or a flag. Not persisted.
    session,

    /// Pick the value to use from the layers that supply one.
    ///
    /// `null` means "this layer has nothing to say". A session override always wins, so the same
    /// file plus the same flag produces the same answer regardless of what the file happened to say.
    pub fn resolve(comptime T: type, built_in: T, file: ?T, session: ?T) T {
        return session orelse file orelse built_in;
    }

    /// The precedence of this layer: higher wins.
    pub fn precedence(self: Layer) u8 {
        return @intFromEnum(self);
    }
};

/// What a right click over a terminal pane does when the program under the
/// pointer has not captured the mouse: the `mouse.right_click` setting.
///
/// The built-in layer supplies `menu`, the settings file may say otherwise,
/// and the session layer (`--right-click=`) wins over both. The values are
/// the setting's file spellings so the flag, the file and a log line agree.
pub const RightClick = enum {
    /// Open the minimal terminal-style context menu at the pointer.
    menu,
    /// Paste the clipboard into the terminal, Unix style.
    paste,

    /// The setting's validated name.
    pub const name: Name = .{ .bytes = "mouse.right_click" };

    /// The value compiled into Conduit: the built-in layer.
    pub const built_in: RightClick = .menu;

    pub const Error = error{InvalidRightClick};

    /// Parse the setting's text spelling. Anything else is an error rather
    /// than a silent fallback, so a typo in a flag is reported.
    pub fn parse(raw: []const u8) Error!RightClick {
        if (std.mem.eql(u8, raw, "menu")) return .menu;
        if (std.mem.eql(u8, raw, "paste")) return .paste;
        return error.InvalidRightClick;
    }

    /// Render the value back to the text it was parsed from.
    pub fn text(self: RightClick) []const u8 {
        return @tagName(self);
    }
};

/// How the sidebar draws agent states: the `sidebar.status_icons` setting
/// (TASK-85). Both styles follow herdr's: `dots` marks every state that is
/// not idle with a filled dot and lets its colour tell them apart, `symbols`
/// gives each state its own shape. The values are the file spellings.
pub const StatusIcons = enum {
    /// `●` for working, blocked and done, `○` idle.
    dots,
    /// `◐` working, `×` blocked, `✓` done, `○` idle.
    symbols,

    /// The value compiled into Conduit.
    pub const built_in: StatusIcons = .dots;

    pub const Error = error{InvalidStatusIcons};

    /// Parse the setting's exact spelling; anything else is an error.
    pub fn parse(raw: []const u8) Error!StatusIcons {
        if (std.mem.eql(u8, raw, "dots")) return .dots;
        if (std.mem.eql(u8, raw, "symbols")) return .symbols;
        return error.InvalidStatusIcons;
    }

    /// Render the value back to the text it was parsed from.
    pub fn text(self: StatusIcons) []const u8 {
        return @tagName(self);
    }
};

/// Which macOS Option keys act as Alt: the `macos.option_as_alt` setting (TASK-48).
///
/// `false`, the built-in value, is the macOS convention: Option types the characters the layout
/// puts on it (Option+e starts an acute accent). `true` makes both Option keys Alt (Meta, ESC
/// prefixed), and `left` or `right` makes only that one Alt so the other still composes. The
/// setting is read on every OS and acts only on macOS. The tag names are the file spellings.
pub const OptionAsAlt = enum {
    false,
    true,
    left,
    right,

    /// The setting's validated name.
    pub const name: Name = .{ .bytes = "macos.option_as_alt" };

    /// The value compiled into Conduit: the built-in layer.
    pub const built_in: OptionAsAlt = .false;

    pub const Error = error{InvalidOptionAsAlt};

    /// Parse the setting's text spelling: exactly `true`, `false`, `left` or `right`.
    pub fn parse(raw: []const u8) Error!OptionAsAlt {
        inline for (comptime std.enums.values(OptionAsAlt)) |value| {
            if (std.mem.eql(u8, raw, @tagName(value))) return value;
        }
        return error.InvalidOptionAsAlt;
    }

    /// Render the value back to the text it was parsed from.
    pub fn text(self: OptionAsAlt) []const u8 {
        return @tagName(self);
    }
};

// ---------------------------------------------------------------------------
// The settings file
// ---------------------------------------------------------------------------

/// The largest settings file read. A larger file is reported and the previous settings stand: a
/// hand-edited text file this big is a mistake, and reading it whole must stay cheap.
pub const max_file_bytes: usize = 256 * 1024;
/// The longest line accepted. A longer line is reported and skipped.
pub const max_line_bytes: usize = 1024;
/// The longest string value accepted, after removing surrounding quotes.
pub const max_string_bytes: usize = 256;
/// The most `keybind` lines one file may hold; later ones are reported and ignored.
pub const max_keybinds: usize = 256;
/// The most diagnostics retained per load. Further problems are counted, not stored.
pub const max_diagnostics: usize = 64;

/// The built-in font size in points. `app` builds its face at this size when the file is silent.
pub const default_font_points: f32 = 14.0;
/// `font.size` bounds in points. The lower bound is `font.Size.min_points`; the upper one keeps a
/// glyph inside the atlas the app allocates.
pub const min_font_points: f32 = 1.0;
pub const max_font_points: f32 = 72.0;
/// The range the size commands step within. A file may set a smaller size; the commands never
/// step below this, and never step a smaller size further down.
pub const min_step_font_points: f32 = 6.0;
/// The most `font.fallbacks` families one file may name.
pub const max_font_fallbacks: usize = 8;

/// Which way a size command moves `font.size`.
pub const FontStep = enum { increase, decrease };

/// The size after one step of `step`: whole points, one at a time, within `min_step_font_points`
/// and `max_font_points`. A fractional size moves to the next whole point in that direction. A
/// step that would leave the range returns `points` unchanged rather than jumping across it.
pub fn stepFontPoints(points: f32, step: FontStep) f32 {
    return switch (step) {
        .increase => if (points >= max_font_points) points else @min(max_font_points, @max(min_step_font_points, @floor(points) + 1)),
        .decrease => if (points <= min_step_font_points) points else @max(min_step_font_points, @ceil(points) - 1),
    };
}

/// Split a `font.fallbacks` value (already unquoted) into trimmed, non-empty family names stored
/// in `out`, borrowing from `text`. More than `max_font_fallbacks` names is an error.
pub fn splitFallbacks(text: []const u8, out: *[max_font_fallbacks][]const u8) error{TooManyFallbacks}![]const []const u8 {
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |part| {
        const name = std.mem.trim(u8, part, " \t");
        if (name.len == 0) continue;
        if (count == max_font_fallbacks) return error.TooManyFallbacks;
        out[count] = name;
        count += 1;
    }
    return out[0..count];
}

/// The `font.fallbacks` value for `families`: the names joined by `, `, as `parse` reads back.
pub fn formatFallbacks(buffer: []u8, families: []const []const u8) error{NoSpaceLeft}![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    for (families, 0..) |family, index| {
        if (index != 0) writer.writeAll(", ") catch return error.NoSpaceLeft;
        writer.writeAll(family) catch return error.NoSpaceLeft;
    }
    return writer.buffered();
}
/// Scratchpad presentation bounds in percent of the window height.
pub const min_scratchpad_percent: u8 = 10;
pub const max_scratchpad_percent: u8 = 100;

/// One setting the file may assign. The enum order is the order of `docs/config.md` and of the
/// defaults document.
pub const Key = enum {
    font_family,
    font_bold,
    font_italic,
    font_bold_italic,
    font_size,
    font_ligatures,
    font_nerd_symbols,
    font_fallbacks,
    theme,
    scratchpad_size,
    scratchpad_large_size,
    mouse_right_click,
    macos_option_as_alt,
    notifications_enabled,
    notifications_os,
    notifications_permission,
    notifications_input,
    notifications_done,
    notifications_error,
    notifications_terminal,
    notifications_claude_code,
    notifications_codex,
    notifications_pi,
    notifications_opencode,
    remote_profile,
    remote_recent,
    control_enabled,
    restore_enabled,
    accessibility_enabled,
    sidebar_agents,
    sidebar_status_icons,
    shell,
    profile,
    editor_command,
    keybind,

    /// The key's spelling in the file, which is also its `Name`.
    pub fn name(self: Key) []const u8 {
        return switch (self) {
            .font_family => "font.family",
            .font_bold => "font.bold",
            .font_italic => "font.italic",
            .font_bold_italic => "font.bold_italic",
            .font_size => "font.size",
            .font_ligatures => "font.ligatures",
            .font_nerd_symbols => "font.nerd_symbols",
            .font_fallbacks => "font.fallbacks",
            .theme => "theme",
            .scratchpad_size => "scratchpad.size",
            .scratchpad_large_size => "scratchpad.large_size",
            .mouse_right_click => RightClick.name.text(),
            .macos_option_as_alt => OptionAsAlt.name.text(),
            .notifications_enabled => "notifications.enabled",
            .notifications_os => "notifications.os",
            .notifications_permission => "notifications.permission",
            .notifications_input => "notifications.input",
            .notifications_done => "notifications.done",
            .notifications_error => "notifications.error",
            .notifications_terminal => "notifications.terminal",
            .notifications_claude_code => "notifications.claude_code",
            .notifications_codex => "notifications.codex",
            .notifications_pi => "notifications.pi",
            .notifications_opencode => "notifications.opencode",
            .remote_profile => "remote.profile",
            .remote_recent => "remote.recent",
            .control_enabled => "control.enabled",
            .restore_enabled => "restore.enabled",
            .accessibility_enabled => "accessibility.enabled",
            .sidebar_agents => "sidebar.agents",
            .sidebar_status_icons => "sidebar.status_icons",
            .shell => "shell",
            .profile => "profile",
            .editor_command => "editor.command",
            .keybind => "keybind",
        };
    }

    /// The key a file spelling names, or null for an unknown key.
    pub fn fromName(text: []const u8) ?Key {
        for (std.enums.values(Key)) |key| {
            if (std.mem.eql(u8, key.name(), text)) return key;
        }
        return null;
    }
};

/// Every value the file layer resolves, already validated.
///
/// Strings are borrowed from the `Config` that produced them and die with it. The defaults are
/// the built-in layer: what a missing file, an empty file or a file silent about a key yields.
pub const Settings = struct {
    /// The primary family. Null means the file is silent, so the built-in (bundled face) or a
    /// session `--font` decides; an explicit empty string also means the bundled face.
    font_family: ?[]const u8 = null,
    /// Style-face families. Empty derives the style from the primary family; otherwise the named
    /// family's bold, italic or bold-italic face (else its regular face) draws that style.
    font_bold: []const u8 = "",
    font_italic: []const u8 = "",
    font_bold_italic: []const u8 = "",
    font_size: f32 = default_font_points,
    /// Whether HarfBuzz forms programming ligatures (`liga`, `calt`, `dlig`).
    font_ligatures: bool = true,
    /// Whether box drawing, blocks, braille and Powerline separators are drawn as built-in sprites.
    font_nerd_symbols: bool = true,
    /// Families searched, in order, for a codepoint the primary family lacks, before any other
    /// installed face. At most `max_font_fallbacks`; each name is trimmed and non-empty.
    font_fallbacks: []const []const u8 = &.{},
    /// The colour scheme: empty for Conduit's default, a bundled or user theme name, or
    /// `auto:<dark>,<light>`. `app` resolves it through `theme`; an unknown name is reported there.
    theme: []const u8 = "",
    /// The two scratchpad presentations, in percent of the window height.
    scratchpad_size: u8 = 50,
    scratchpad_large_size: u8 = 90,
    /// The file layer of `mouse.right_click`; null when the file is silent.
    right_click: ?RightClick = null,
    /// Which macOS Option keys are Alt; inert on other OSes (TASK-48).
    macos_option_as_alt: OptionAsAlt = OptionAsAlt.built_in,
    /// Which agent and terminal notifications are raised (TASK-56).
    notifications: Notifications = .{},
    /// Saved SSH connection profiles (TASK-44), in file order, one per name.
    remote_profiles: []const Profile = &.{},
    /// Destinations connected to most recently, newest first, at most
    /// `max_remote_recent`.
    remote_recent: []const []const u8 = &.{},
    /// The file layer of `control.enabled` (TASK-60): whether the local
    /// control endpoint and the single-instance endpoint run. Null when the
    /// file is silent, which means on in Debug builds and off in release
    /// builds (`controlEnabled`). Read at startup only.
    control_enabled: ?bool = null,
    /// `restore.enabled` (TASK-65): whether a plain run saves its workspaces,
    /// tabs, pane layout, theme and window size to the state file and restores
    /// them on the next launch. Read at startup only. False neither saves nor
    /// restores; `--no-restore` skips one restore and still saves.
    restore_enabled: bool = true,
    /// `accessibility.enabled` (TASK-68): whether the accessibility bridge
    /// exposes the semantic tree to the platform's assistive technologies
    /// (AT-SPI2 on Linux). Read at startup only.
    accessibility_enabled: bool = true,
    /// `sidebar.agents` (TASK-80): whether every agent gets its own row,
    /// `<glyph> <harness> <state>`, nested under its tab in the sidebar.
    /// False keeps only the glyph in front of the tab's name. Hot-reloaded.
    sidebar_agents: bool = true,
    /// `sidebar.status_icons` (TASK-85): the icon style for agent states on
    /// agent, tab and workspace rows. Hot-reloaded.
    sidebar_status_icons: StatusIcons = StatusIcons.built_in,
    /// `shell` (TASK-46): the name of the profile a new tab or pane runs
    /// when none is chosen. Empty keeps the built-in default (the user's
    /// shell on POSIX, the first of PowerShell 7, Windows PowerShell and cmd
    /// on Windows, the remote login shell over SSH).
    shell: []const u8 = "",
    /// Shell profiles (TASK-46), in file order, one per name, with their
    /// `profile.<name>.*` attributes applied.
    shell_profiles: []const ShellProfile = &.{},
    /// `editor.command` (TASK-79): the VSCodium command or path the editor
    /// pane detects first, as one argv item resolved on the workspace
    /// context's PATH. Empty means only the default `codium` is tried.
    editor_command: []const u8 = "",
};

/// The built-in value of `control.enabled`: on in development builds, off in
/// release builds unless the file or a `--control` flag turns it on.
pub const control_enabled_default: bool = builtin.mode == .Debug;

/// Resolve `control.enabled` from the session layer (`--control` /
/// `--no-control`), then the file, then the build's default.
pub fn controlEnabled(session: ?bool, file: ?bool) bool {
    return session orelse file orelse control_enabled_default;
}

/// The most saved connection profiles one file may hold.
pub const max_remote_profiles: usize = 32;
/// How many recent destinations `remote.recent` keeps.
pub const max_remote_recent: usize = 10;
/// The longest profile name.
pub const max_profile_name_bytes: usize = 64;

/// One `remote.profile = <name> = <destination>` line (TASK-44). It holds a
/// destination only: never a password, a key or any other secret.
pub const Profile = struct {
    name: []const u8,
    /// `[user@]host[:port]`, already validated by `parseDestination`.
    destination: []const u8,
};

/// A validated SSH destination: what `ssh` is given, and an explicit port.
pub const Destination = struct {
    /// `[user@]host`, a slice of the parsed text.
    target: []const u8,
    port: ?u16 = null,
};

pub const DestinationError = error{InvalidDestination};

/// Parse `[user@]host[:port]` as typed by a person or stored in the file.
/// Refused: empty text, a leading `-` (it would become an `ssh` option),
/// whitespace, control bytes, and anything outside letters, digits and
/// `._-@:[]%+`, so a destination is always one plain `ssh` argument and one
/// comma-free item of `remote.recent`. A trailing `:<digits>` is the port
/// (1 to 65535); a bracketed IPv6 host keeps its colons (`[::1]:22`).
pub fn parseDestination(text: []const u8) DestinationError!Destination {
    if (text.len == 0 or text.len > max_string_bytes or text[0] == '-') return error.InvalidDestination;
    for (text) |byte| {
        const allowed = std.ascii.isAlphanumeric(byte) or switch (byte) {
            '.', '_', '-', '@', ':', '[', ']', '%', '+' => true,
            else => false,
        };
        if (!allowed) return error.InvalidDestination;
    }
    var target = text;
    var port: ?u16 = null;
    if (std.mem.lastIndexOfScalar(u8, text, ':')) |colon| {
        const bracket = std.mem.lastIndexOfScalar(u8, text, ']');
        const single_colon = std.mem.indexOfScalar(u8, text, ':').? == colon;
        // `host:22` and `[v6]:22` carry a port; a bare IPv6 address does not.
        const has_port = if (bracket) |close| close + 1 == colon else single_colon;
        if (has_port) {
            const tail = text[colon + 1 ..];
            if (tail.len == 0 or tail.len > 5) return error.InvalidDestination;
            for (tail) |byte| {
                if (!std.ascii.isDigit(byte)) return error.InvalidDestination;
            }
            const value = std.fmt.parseInt(u32, tail, 10) catch return error.InvalidDestination;
            if (value == 0 or value > std.math.maxInt(u16)) return error.InvalidDestination;
            port = @intCast(value);
            target = text[0..colon];
        }
    }
    if (target.len == 0 or target[0] == '-') return error.InvalidDestination;
    if (std.mem.indexOfScalar(u8, target, '@')) |at| {
        if (at == 0 or at + 1 == target.len) return error.InvalidDestination;
        if (std.mem.indexOfScalarPos(u8, target, at + 1, '@') != null) return error.InvalidDestination;
        if (target[at + 1] == '-') return error.InvalidDestination;
    }
    return .{ .target = target, .port = port };
}

/// The host part of a destination, for naming a workspace after it.
pub fn destinationHost(destination: Destination) []const u8 {
    const at = std.mem.indexOfScalar(u8, destination.target, '@') orelse return destination.target;
    return destination.target[at + 1 ..];
}

/// Whether `name` can name a profile: non-empty, trimmed, at most
/// `max_profile_name_bytes`, valid UTF-8 and free of `=`, `"`, `,` and
/// control bytes.
pub fn validProfileName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_profile_name_bytes) return false;
    if (std.mem.trim(u8, name, " \t").len != name.len) return false;
    if (hasControl(name) or std.mem.indexOfAny(u8, name, "=\",") != null) return false;
    return std.unicode.utf8ValidateSlice(name);
}

/// Split one `remote.profile` value, `<name> = <destination>`.
fn splitProfile(value: []const u8) ValueError!Profile {
    const text = try parseString(value);
    const equals = std.mem.indexOfScalar(u8, text, '=') orelse return error.ProfileShape;
    const name = std.mem.trim(u8, text[0..equals], " \t");
    const destination = std.mem.trim(u8, text[equals + 1 ..], " \t");
    if (!validProfileName(name)) return error.ProfileShape;
    _ = parseDestination(destination) catch return error.NotDestination;
    return .{ .name = name, .destination = destination };
}

/// Split a `remote.recent` value into at most `max_remote_recent`
/// destinations, each validated. An empty value is the empty list.
fn splitRecent(text: []const u8, out: *[max_remote_recent][]const u8) ValueError![]const []const u8 {
    var count: usize = 0;
    var items = std.mem.splitScalar(u8, text, ',');
    while (items.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t");
        if (item.len == 0) continue;
        _ = parseDestination(item) catch return error.NotDestination;
        if (count == max_remote_recent) return error.TooManyRecent;
        out[count] = item;
        count += 1;
    }
    return out[0..count];
}

/// The `remote.recent` value with `newest` first: `existing` follows without
/// duplicates of it, the whole list cut to `max_remote_recent`, written
/// comma-separated into `buffer`.
pub fn formatRecent(buffer: []u8, newest: []const u8, existing: []const []const u8) error{NoSpaceLeft}![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    writer.writeAll(newest) catch return error.NoSpaceLeft;
    var kept: usize = 1;
    for (existing) |item| {
        if (kept == max_remote_recent) break;
        if (std.mem.eql(u8, item, newest)) continue;
        writer.print(",{s}", .{item}) catch return error.NoSpaceLeft;
        kept += 1;
    }
    return writer.buffered();
}

// ---------------------------------------------------------------------------
// Shell profiles (TASK-46)
// ---------------------------------------------------------------------------

/// The most shell profiles one file may hold.
pub const max_shell_profiles: usize = 32;
/// The most words (program and arguments) one profile's command may have.
pub const max_profile_args: usize = 32;
/// The most `profile.<name>.env` lines one profile may carry.
pub const max_profile_env: usize = 32;
/// The longest shell profile name.
pub const max_shell_profile_name_bytes: usize = 32;

/// One `profile = <name> = <command> [arguments...]` line with its
/// `profile.<name>.env`, `.cwd` and `.login` attributes (TASK-46).
///
/// A profile is the user's own configuration, trusted like a keybinding: it
/// names a program to run, never text a terminal produced. Every slice is
/// owned by the `Config` arena it came from.
pub const ShellProfile = struct {
    name: []const u8,
    /// The program, then its arguments, already unquoted. Never empty.
    argv: []const []const u8,
    /// `NAME=value` entries added on top of the child's environment.
    env: []const []const u8 = &.{},
    /// The directory the child starts in, in the workspace's own path
    /// syntax; null inherits the invoking terminal's directory.
    cwd: ?[]const u8 = null,
    /// Start the program as a login shell (`-l` for a POSIX shell).
    login: bool = false,
};

/// The names Conduit's built-in profiles use on this platform, which
/// `shell` may name without a `profile` line: `login` everywhere (the
/// user's login shell, or the remote one over SSH) and, on Windows, `pwsh`,
/// `powershell` and `cmd`.
pub const builtin_shell_profile_names: []const []const u8 = if (builtin.os.tag == .windows)
    &.{ "pwsh", "powershell", "cmd", "login" }
else
    &.{"login"};

/// Whether `name` can name a shell profile: 1 to 32 ASCII letters, digits,
/// `-` and `_`, so it is also a single `profile.<name>.env` key segment and
/// a palette choice value.
pub fn validShellProfileName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_shell_profile_name_bytes) return false;
    for (name) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_')) return false;
    }
    return true;
}

/// Whether `entry` is a `NAME=value` environment entry: a name of letters,
/// digits and `_` that does not start with a digit, and a value without
/// control characters.
pub fn validEnvEntry(entry: []const u8) bool {
    const equals = std.mem.indexOfScalar(u8, entry, '=') orelse return false;
    const name = entry[0..equals];
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return !hasControl(entry[equals + 1 ..]);
}

/// Split a command line into words, shell style, unquoting into `storage`
/// (at least `text.len` bytes) and pointing `out` at the words.
///
/// Blanks separate words. `'...'` is literal. `"..."` is literal except
/// that `\"` is a quote and `\\` a backslash. A backslash anywhere else is
/// an ordinary byte, so a Windows path needs no doubling. An unterminated
/// quote, a control character, no words, or more than `out.len` words is an
/// error.
pub fn splitCommandLine(text: []const u8, storage: []u8, out: [][]const u8) ValueError![]const []const u8 {
    if (hasControl(text)) return error.ControlCharacter;
    if (text.len > storage.len) return error.TooLong;
    var count: usize = 0;
    var used: usize = 0;
    var index: usize = 0;
    while (true) {
        while (index < text.len and (text[index] == ' ' or text[index] == '\t')) index += 1;
        if (index == text.len) break;
        if (count == out.len) return error.ShellProfileShape;
        const start = used;
        while (index < text.len and text[index] != ' ' and text[index] != '\t') {
            switch (text[index]) {
                '\'' => {
                    const close = std.mem.indexOfScalarPos(u8, text, index + 1, '\'') orelse return error.Unquoted;
                    const inner = text[index + 1 .. close];
                    @memcpy(storage[used..][0..inner.len], inner);
                    used += inner.len;
                    index = close + 1;
                },
                '"' => {
                    index += 1;
                    while (true) {
                        if (index == text.len) return error.Unquoted;
                        const byte = text[index];
                        if (byte == '"') break;
                        if (byte == '\\' and index + 1 < text.len and (text[index + 1] == '"' or text[index + 1] == '\\')) {
                            storage[used] = text[index + 1];
                            index += 2;
                        } else {
                            storage[used] = byte;
                            index += 1;
                        }
                        used += 1;
                    }
                    index += 1;
                },
                else => |byte| {
                    storage[used] = byte;
                    used += 1;
                    index += 1;
                },
            }
        }
        out[count] = storage[start..used];
        count += 1;
    }
    if (count == 0 or out[0].len == 0) return error.ShellProfileShape;
    return out[0..count];
}

const SplitShellProfile = struct {
    name: []const u8,
    argv: []const []const u8,
};

/// Split one `profile` value, `<name> = <command> [arguments...]`. The words
/// borrow `storage` (at least `max_line_bytes`) and `args`.
fn splitShellProfile(value: []const u8, storage: []u8, args: *[max_profile_args][]const u8) ValueError!SplitShellProfile {
    const equals = std.mem.indexOfScalar(u8, value, '=') orelse return error.ShellProfileShape;
    const name = std.mem.trim(u8, value[0..equals], " \t");
    if (!validShellProfileName(name)) return error.ShellProfileName;
    const command = std.mem.trim(u8, value[equals + 1 ..], " \t");
    const argv = try splitCommandLine(command, storage, args);
    return .{ .name = name, .argv = argv };
}

/// Apply one `profile` line: a later line for the same name replaces the
/// earlier one's command and keeps its place.
fn applyShellProfile(settings: *Settings, allocator: Allocator, value: []const u8) (ValueError || Allocator.Error)!void {
    var storage: [max_line_bytes]u8 = undefined;
    var args: [max_profile_args][]const u8 = undefined;
    const split = try splitShellProfile(value, &storage, &args);
    const argv = try allocator.alloc([]const u8, split.argv.len);
    for (argv, split.argv) |*slot, word| slot.* = try allocator.dupe(u8, word);
    const owned: ShellProfile = .{ .name = try allocator.dupe(u8, split.name), .argv = argv };
    for (settings.shell_profiles, 0..) |existing, index| {
        if (std.mem.eql(u8, existing.name, owned.name)) {
            const list = try allocator.dupe(ShellProfile, settings.shell_profiles);
            list[index] = owned;
            settings.shell_profiles = list;
            return;
        }
    }
    if (settings.shell_profiles.len >= max_shell_profiles) return error.TooManyShellProfiles;
    const list = try allocator.alloc(ShellProfile, settings.shell_profiles.len + 1);
    @memcpy(list[0..settings.shell_profiles.len], settings.shell_profiles);
    list[settings.shell_profiles.len] = owned;
    settings.shell_profiles = list;
}

/// One `profile.<name>.<field> = <value>` line, kept until every `profile`
/// line has been read.
const ProfileAttribute = struct {
    line: u32,
    name: []const u8,
    field: Field,
    value: []const u8,

    const Field = enum { env, cwd, login };

    /// The attribute `key` names, or null when `key` is not
    /// `profile.<name>.env|cwd|login` with a valid profile name. Borrows
    /// `key` and `value`.
    fn parse(key: []const u8, value: []const u8, line: u32) ?ProfileAttribute {
        const prefix = "profile.";
        if (!std.mem.startsWith(u8, key, prefix)) return null;
        const rest = key[prefix.len..];
        const dot = std.mem.lastIndexOfScalar(u8, rest, '.') orelse return null;
        const name = rest[0..dot];
        if (!validShellProfileName(name)) return null;
        const field = std.meta.stringToEnum(Field, rest[dot + 1 ..]) orelse return null;
        return .{ .line = line, .name = name, .field = field, .value = value };
    }
};

/// Attach each `profile.<name>.*` line to its profile, in file order. A line
/// for a name no `profile` line defines, or with a value its field rejects,
/// is reported on its own line and skipped; the profile keeps the rest.
fn applyProfileAttributes(result: *Config, attributes: []const ProfileAttribute) Allocator.Error!void {
    if (attributes.len == 0) return;
    const allocator = result.arena.allocator();
    const profiles = try allocator.dupe(ShellProfile, result.settings.shell_profiles);
    result.settings.shell_profiles = profiles;
    for (attributes) |attribute| {
        const field = @tagName(attribute.field);
        const profile = for (profiles) |*candidate| {
            if (std.mem.eql(u8, candidate.name, attribute.name)) break candidate;
        } else {
            result.addDiagnostic(attribute.line, "profile.{s}.{s}: no profile with that name", .{ attribute.name, field });
            continue;
        };
        switch (attribute.field) {
            .env => {
                if (!validEnvEntry(attribute.value)) {
                    result.addDiagnostic(attribute.line, "profile.{s}.env: expected `NAME=value`", .{attribute.name});
                    continue;
                }
                if (profile.env.len >= max_profile_env) {
                    result.addDiagnostic(attribute.line, "profile.{s}.env: more than {d} variables; the rest are ignored", .{ attribute.name, max_profile_env });
                    continue;
                }
                const list = try allocator.alloc([]const u8, profile.env.len + 1);
                @memcpy(list[0..profile.env.len], profile.env);
                list[profile.env.len] = attribute.value;
                profile.env = list;
            },
            .cwd => {
                const path = parseString(attribute.value) catch |err| {
                    result.addDiagnostic(attribute.line, "profile.{s}.cwd: {s}", .{ attribute.name, valueMessage(.profile, err) });
                    continue;
                };
                profile.cwd = if (path.len == 0) null else path;
            },
            .login => profile.login = parseBool(attribute.value) catch {
                result.addDiagnostic(attribute.line, "profile.{s}.login: expected `true` or `false`", .{attribute.name});
                continue;
            },
        }
    }
}

/// Report a `shell` that names neither a configured nor a built-in profile.
/// The value stays: the app falls back to the built-in default, and the
/// message says why the named one is not used.
fn checkShellName(result: *Config) void {
    const name = result.settings.shell;
    if (name.len == 0) return;
    if (findShellProfile(result.settings.shell_profiles, name) != null) return;
    for (builtin_shell_profile_names) |known| {
        if (std.mem.eql(u8, known, name)) return;
    }
    result.addDiagnostic(result.lines.get(.shell), "shell: no profile with that name", .{});
}

/// The configured profile called `name`, if any.
pub fn findShellProfile(profiles: []const ShellProfile, name: []const u8) ?ShellProfile {
    for (profiles) |profile| {
        if (std.mem.eql(u8, profile.name, name)) return profile;
    }
    return null;
}

/// The `notifications.*` switches (TASK-56). Every one defaults to on. `enabled` gates the whole
/// in-app list and every OS notification; `os` gates only the OS notification when the window is
/// unfocused; the per-type switches name what an entry is about, and the per-harness switches
/// silence one coding agent. `app` interprets them; this module only parses them.
pub const Notifications = struct {
    enabled: bool = true,
    os: bool = true,
    permission: bool = true,
    input: bool = true,
    done: bool = true,
    @"error": bool = true,
    terminal: bool = true,
    claude_code: bool = true,
    codex: bool = true,
    pi: bool = true,
    opencode: bool = true,

    /// The field a `notifications.*` key sets, or null for any other key.
    pub fn field(key: Key) ?*const fn (*Notifications) *bool {
        return switch (key) {
            inline .notifications_enabled,
            .notifications_os,
            .notifications_permission,
            .notifications_input,
            .notifications_done,
            .notifications_error,
            .notifications_terminal,
            .notifications_claude_code,
            .notifications_codex,
            .notifications_pi,
            .notifications_opencode,
            => |tag| &struct {
                fn get(n: *Notifications) *bool {
                    return &@field(n, tag.name()["notifications.".len..]);
                }
            }.get,
            else => null,
        };
    }

    /// The value a `notifications.*` key has here.
    pub fn get(self: Notifications, key: Key) ?bool {
        var copy = self;
        const accessor = field(key) orelse return null;
        return accessor(&copy).*;
    }
};

/// One `keybind = <chord>=<action>[:<argument>]` line, split but not yet resolved.
///
/// `chord` is parsed by `input.parseChord`; `action` is checked against the action registry by
/// `app`. Both are borrowed from the `Config`.
pub const Keybind = struct {
    line: u32,
    chord: []const u8,
    /// Null means `unbind`: remove whatever the chord is bound to.
    action: ?[]const u8,
    argument: ?[]const u8 = null,
};

/// One problem with the file. `line` is 1-based; 0 means the whole file.
///
/// `message` is terse and specific, names the key when there is one, and never repeats the
/// user's value: it is logged and shown as is.
pub const Diagnostic = struct {
    line: u32,
    message: []const u8,
};

/// A parsed settings file: values, keybind lines and diagnostics, all owned by one arena.
pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    settings: Settings = .{},
    /// The line each key's value came from, 0 when it is the built-in value.
    lines: std.EnumArray(Key, u32) = .initFill(0),
    /// Keys whose every line in this file was rejected, so the previous value stands for them.
    kept_previous: std.EnumSet(Key) = .initEmpty(),
    keybinds: std.ArrayList(Keybind) = .empty,
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    /// Problems beyond `max_diagnostics`, counted rather than stored.
    dropped_diagnostics: usize = 0,

    /// An empty config: the built-in layer, no keybind overrides, no diagnostics.
    pub fn initDefaults(gpa: Allocator) Config {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Record a problem. The message is copied into the arena. An allocation failure still counts
    /// the problem, so a file that produced one is never reported as clean.
    pub fn addDiagnostic(self: *Config, line: u32, comptime format: []const u8, args: anytype) void {
        if (self.diagnostics.items.len >= max_diagnostics) {
            self.dropped_diagnostics += 1;
            return;
        }
        const allocator = self.arena.allocator();
        const message = std.fmt.allocPrint(allocator, format, args) catch {
            self.dropped_diagnostics += 1;
            return;
        };
        self.diagnostics.append(allocator, .{ .line = line, .message = message }) catch {
            self.dropped_diagnostics += 1;
        };
    }

    /// Whether this load reported anything.
    pub fn hasDiagnostics(self: *const Config) bool {
        return self.diagnostics.items.len != 0 or self.dropped_diagnostics != 0;
    }

    /// The diagnostic to show first: the lowest line, file-wide problems before any line, and the
    /// first reported among equals.
    pub fn firstDiagnostic(self: *const Config) ?Diagnostic {
        var best: ?Diagnostic = null;
        for (self.diagnostics.items) |diagnostic| {
            if (best == null or diagnostic.line < best.?.line) best = diagnostic;
        }
        return best;
    }

    fn dupe(self: *Config, text: []const u8) Allocator.Error![]const u8 {
        return self.arena.allocator().dupe(u8, text);
    }

    fn dupeList(self: *Config, items: []const []const u8) Allocator.Error![]const []const u8 {
        const list = try self.arena.allocator().alloc([]const u8, items.len);
        for (list, items) |*slot, item| slot.* = try self.dupe(item);
        return list;
    }

    /// A deep copy of `profiles` in this config's arena.
    fn dupeShellProfiles(self: *Config, profiles: []const ShellProfile) Allocator.Error![]const ShellProfile {
        const list = try self.arena.allocator().alloc(ShellProfile, profiles.len);
        for (list, profiles) |*slot, profile| slot.* = .{
            .name = try self.dupe(profile.name),
            .argv = try self.dupeList(profile.argv),
            .env = try self.dupeList(profile.env),
            .cwd = if (profile.cwd) |cwd| try self.dupe(cwd) else null,
            .login = profile.login,
        };
        return list;
    }

    /// Copy `previous`'s value for `key` into this config, so it outlives `previous`.
    fn keepPrevious(self: *Config, key: Key, previous: *const Config) Allocator.Error!void {
        const from = &previous.settings;
        const to = &self.settings;
        switch (key) {
            .font_family => to.font_family = if (from.font_family) |family| try self.dupe(family) else null,
            .font_bold => to.font_bold = try self.dupe(from.font_bold),
            .font_italic => to.font_italic = try self.dupe(from.font_italic),
            .font_bold_italic => to.font_bold_italic = try self.dupe(from.font_bold_italic),
            .font_size => to.font_size = from.font_size,
            .font_ligatures => to.font_ligatures = from.font_ligatures,
            .font_nerd_symbols => to.font_nerd_symbols = from.font_nerd_symbols,
            .font_fallbacks => {
                const list = try self.arena.allocator().alloc([]const u8, from.font_fallbacks.len);
                for (list, from.font_fallbacks) |*slot, family| slot.* = try self.dupe(family);
                to.font_fallbacks = list;
            },
            .theme => to.theme = try self.dupe(from.theme),
            .scratchpad_size => to.scratchpad_size = from.scratchpad_size,
            .scratchpad_large_size => to.scratchpad_large_size = from.scratchpad_large_size,
            .mouse_right_click => to.right_click = from.right_click,
            .macos_option_as_alt => to.macos_option_as_alt = from.macos_option_as_alt,
            .notifications_enabled,
            .notifications_os,
            .notifications_permission,
            .notifications_input,
            .notifications_done,
            .notifications_error,
            .notifications_terminal,
            .notifications_claude_code,
            .notifications_codex,
            .notifications_pi,
            .notifications_opencode,
            => Notifications.field(key).?(&to.notifications).* = previous.settings.notifications.get(key).?,
            .remote_profile => {
                const list = try self.arena.allocator().alloc(Profile, from.remote_profiles.len);
                for (list, from.remote_profiles) |*slot, profile| slot.* = .{
                    .name = try self.dupe(profile.name),
                    .destination = try self.dupe(profile.destination),
                };
                to.remote_profiles = list;
            },
            .remote_recent => {
                const list = try self.arena.allocator().alloc([]const u8, from.remote_recent.len);
                for (list, from.remote_recent) |*slot, item| slot.* = try self.dupe(item);
                to.remote_recent = list;
            },
            .control_enabled => to.control_enabled = from.control_enabled,
            .restore_enabled => to.restore_enabled = from.restore_enabled,
            .accessibility_enabled => to.accessibility_enabled = from.accessibility_enabled,
            .sidebar_agents => to.sidebar_agents = from.sidebar_agents,
            .sidebar_status_icons => to.sidebar_status_icons = from.sidebar_status_icons,
            .shell => to.shell = try self.dupe(from.shell),
            .profile => to.shell_profiles = try self.dupeShellProfiles(from.shell_profiles),
            .editor_command => to.editor_command = try self.dupe(from.editor_command),
            // Keybind lines are resolved against the previous binding table by `app`, which is
            // the only place that knows what a rejected chord used to do.
            .keybind => {},
        }
        self.lines.set(key, previous.lines.get(key));
        self.kept_previous.insert(key);
    }

    /// A deep copy of `previous` carrying one file-wide diagnostic: what a file that cannot be
    /// read at all yields, so every previous value stands.
    pub fn keepAll(gpa: Allocator, previous: *const Config, line: u32, comptime format: []const u8, args: anytype) Allocator.Error!Config {
        var result = initDefaults(gpa);
        errdefer result.deinit();
        for (std.enums.values(Key)) |key| try result.keepPrevious(key, previous);
        const allocator = result.arena.allocator();
        try result.keybinds.ensureTotalCapacity(allocator, previous.keybinds.items.len);
        for (previous.keybinds.items) |keybind| {
            result.keybinds.appendAssumeCapacity(.{
                .line = keybind.line,
                .chord = try result.dupe(keybind.chord),
                .action = if (keybind.action) |action| try result.dupe(action) else null,
                .argument = if (keybind.argument) |argument| try result.dupe(argument) else null,
            });
        }
        result.addDiagnostic(line, format, args);
        return result;
    }
};

/// Why a value was rejected. Each maps to one terse, specific message.
const ValueError = error{
    Empty,
    TooLong,
    Unquoted,
    ControlCharacter,
    NotNumber,
    OutOfRange,
    NotBool,
    NotRightClick,
    NotStatusIcons,
    NotOptionAsAlt,
    NotPercent,
    TooManyFallbacks,
    KeybindShape,
    KeybindAction,
    KeybindArgument,
    ProfileShape,
    NotDestination,
    TooManyRecent,
    TooManyProfiles,
    ShellProfileShape,
    ShellProfileName,
    TooManyShellProfiles,
    EditorCommand,
};

/// Parse `text` as a settings file.
///
/// Every line is judged on its own: a bad line is reported with its number and skipped, and the
/// rest of the file still applies. A key whose every line was rejected keeps `previous`'s value
/// (or the built-in one when there is no previous config), so a typo never resets a working
/// setting. A later valid line for a key replaces an earlier one. Never fails on input; only an
/// allocation failure is an error.
pub fn parse(gpa: Allocator, text: []const u8, previous: ?*const Config) Allocator.Error!Config {
    var result = Config.initDefaults(gpa);
    errdefer result.deinit();
    const allocator = result.arena.allocator();

    var accepted: std.EnumSet(Key) = .initEmpty();
    var rejected: std.EnumSet(Key) = .initEmpty();
    var keybind_overflow_reported = false;
    // `profile.<name>.*` lines, applied once every `profile` line is known so
    // an attribute may come before the profile it describes.
    var profile_attributes: std.ArrayList(ProfileAttribute) = .empty;

    var body = text;
    // A UTF-8 byte order mark is an editor's habit, not part of the first key.
    if (std.mem.startsWith(u8, body, "\xEF\xBB\xBF")) body = body[3..];

    var line_number: u32 = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        line_number +|= 1;
        var line = raw_line;
        if (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len > max_line_bytes) {
            result.addDiagnostic(line_number, "line is longer than {d} bytes", .{max_line_bytes});
            continue;
        }
        if (!std.unicode.utf8ValidateSlice(line)) {
            result.addDiagnostic(line_number, "line is not valid UTF-8", .{});
            continue;
        }
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse {
            result.addDiagnostic(line_number, "expected `key = value`", .{});
            continue;
        };
        const key_text = std.mem.trim(u8, trimmed[0..equals], " \t");
        const value = std.mem.trim(u8, trimmed[equals + 1 ..], " \t");
        if (ProfileAttribute.parse(key_text, value, line_number)) |attribute| {
            try profile_attributes.append(allocator, .{
                .line = attribute.line,
                .name = try allocator.dupe(u8, attribute.name),
                .field = attribute.field,
                .value = try allocator.dupe(u8, attribute.value),
            });
            continue;
        }
        const key = Key.fromName(key_text) orelse {
            if (key_text.len == 0) {
                result.addDiagnostic(line_number, "expected `key = value`", .{});
            } else if (Name.parse(key_text)) |name| {
                result.addDiagnostic(line_number, "unknown key `{s}`", .{name.text()});
            } else |_| {
                result.addDiagnostic(line_number, "invalid key name", .{});
            }
            continue;
        };

        if (key == .keybind and result.keybinds.items.len >= max_keybinds) {
            if (!keybind_overflow_reported) {
                result.addDiagnostic(line_number, "keybind: more than {d} keybind lines; the rest are ignored", .{max_keybinds});
                keybind_overflow_reported = true;
            }
            continue;
        }

        applyValue(&result, allocator, key, value, line_number) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => |value_error| {
                result.addDiagnostic(line_number, "{s}: {s}", .{ key.name(), valueMessage(key, value_error) });
                rejected.insert(key);
                continue;
            },
        };
        accepted.insert(key);
        result.lines.set(key, line_number);
    }

    if (previous) |before| {
        var kept = rejected.differenceWith(accepted).iterator();
        while (kept.next()) |key| try result.keepPrevious(key, before);
    }
    // When every `profile` line was rejected the previous profiles stand
    // whole, attributes included, so this file's attributes are not stacked
    // on top of them.
    if (!result.kept_previous.contains(.profile)) try applyProfileAttributes(&result, profile_attributes.items);
    checkShellName(&result);
    return result;
}

fn valueMessage(key: Key, err: ValueError) []const u8 {
    return switch (err) {
        error.Empty => "expected a value",
        error.TooLong => "value is longer than 256 bytes",
        error.Unquoted => "unbalanced quotes",
        error.ControlCharacter => "value contains a control character",
        error.NotNumber => "expected a number of points",
        error.OutOfRange => switch (key) {
            .font_size => "expected 1 to 72 points",
            else => "out of range",
        },
        error.NotBool => "expected `true` or `false`",
        error.NotRightClick => "expected `menu` or `paste`",
        error.NotStatusIcons => "expected `dots` or `symbols`",
        error.NotOptionAsAlt => "expected `true`, `false`, `left` or `right`",
        error.NotPercent => "expected a whole percentage from 10 to 100",
        error.TooManyFallbacks => "expected at most 8 comma-separated families",
        error.KeybindShape => "expected `<chord>=<action>[:<argument>]`",
        error.KeybindAction => "invalid action name",
        error.KeybindArgument => "invalid argument",
        error.ProfileShape => "expected `<name> = <user@host[:port]>`",
        error.NotDestination => "expected `[user@]host[:port]`",
        error.TooManyRecent => "expected at most 10 comma-separated destinations",
        error.TooManyProfiles => "more than 32 profiles; the rest are ignored",
        error.ShellProfileShape => "expected `<name> = <command> [arguments...]`",
        error.ShellProfileName => "expected a profile name: letters, digits, `-` and `_`",
        error.TooManyShellProfiles => "more than 32 shell profiles; the rest are ignored",
        error.EditorCommand => "expected a command name or path, not an option",
    };
}

fn applyValue(result: *Config, allocator: Allocator, key: Key, value: []const u8, line: u32) (ValueError || Allocator.Error)!void {
    const settings = &result.settings;
    switch (key) {
        .font_family => settings.font_family = try allocator.dupe(u8, try parseString(value)),
        .font_bold => settings.font_bold = try allocator.dupe(u8, try parseString(value)),
        .font_italic => settings.font_italic = try allocator.dupe(u8, try parseString(value)),
        .font_bold_italic => settings.font_bold_italic = try allocator.dupe(u8, try parseString(value)),
        .theme => settings.theme = try allocator.dupe(u8, try parseString(value)),
        .font_size => settings.font_size = try parsePoints(value),
        .font_ligatures => settings.font_ligatures = try parseBool(value),
        .font_nerd_symbols => settings.font_nerd_symbols = try parseBool(value),
        .font_fallbacks => {
            var names: [max_font_fallbacks][]const u8 = undefined;
            const parsed = try splitFallbacks(try parseString(value), &names);
            const list = try allocator.alloc([]const u8, parsed.len);
            for (list, parsed) |*slot, family| slot.* = try allocator.dupe(u8, family);
            settings.font_fallbacks = list;
        },
        .scratchpad_size => settings.scratchpad_size = try parsePercent(value),
        .scratchpad_large_size => settings.scratchpad_large_size = try parsePercent(value),
        .mouse_right_click => settings.right_click = RightClick.parse(value) catch return error.NotRightClick,
        .macos_option_as_alt => settings.macos_option_as_alt = OptionAsAlt.parse(value) catch return error.NotOptionAsAlt,
        .notifications_enabled,
        .notifications_os,
        .notifications_permission,
        .notifications_input,
        .notifications_done,
        .notifications_error,
        .notifications_terminal,
        .notifications_claude_code,
        .notifications_codex,
        .notifications_pi,
        .notifications_opencode,
        => Notifications.field(key).?(&settings.notifications).* = try parseBool(value),
        .remote_profile => {
            const profile = try splitProfile(value);
            const owned: Profile = .{
                .name = try allocator.dupe(u8, profile.name),
                .destination = try allocator.dupe(u8, profile.destination),
            };
            // A later line for the same name replaces the earlier one.
            for (settings.remote_profiles, 0..) |existing, index| {
                if (std.mem.eql(u8, existing.name, owned.name)) {
                    const list = try allocator.dupe(Profile, settings.remote_profiles);
                    list[index] = owned;
                    settings.remote_profiles = list;
                    return;
                }
            }
            if (settings.remote_profiles.len >= max_remote_profiles) return error.TooManyProfiles;
            const list = try allocator.alloc(Profile, settings.remote_profiles.len + 1);
            @memcpy(list[0..settings.remote_profiles.len], settings.remote_profiles);
            list[settings.remote_profiles.len] = owned;
            settings.remote_profiles = list;
        },
        .remote_recent => {
            var items: [max_remote_recent][]const u8 = undefined;
            const parsed = try splitRecent(try parseString(value), &items);
            const list = try allocator.alloc([]const u8, parsed.len);
            for (list, parsed) |*slot, item| slot.* = try allocator.dupe(u8, item);
            settings.remote_recent = list;
        },
        .control_enabled => settings.control_enabled = try parseBool(value),
        .restore_enabled => settings.restore_enabled = try parseBool(value),
        .accessibility_enabled => settings.accessibility_enabled = try parseBool(value),
        .sidebar_agents => settings.sidebar_agents = try parseBool(value),
        .sidebar_status_icons => settings.sidebar_status_icons = StatusIcons.parse(value) catch return error.NotStatusIcons,
        .shell => {
            const name = try parseString(value);
            if (name.len != 0 and !validShellProfileName(name)) return error.ShellProfileName;
            settings.shell = try allocator.dupe(u8, name);
        },
        .profile => try applyShellProfile(settings, allocator, value),
        .editor_command => settings.editor_command = try allocator.dupe(u8, try parseEditorCommand(value)),
        .keybind => {
            const split = try splitKeybind(value);
            try result.keybinds.append(allocator, .{
                .line = line,
                .chord = try allocator.dupe(u8, split.chord),
                .action = if (split.action) |action| try allocator.dupe(u8, action) else null,
                .argument = if (split.argument) |argument| try allocator.dupe(u8, argument) else null,
            });
        },
    }
}

fn hasControl(text: []const u8) bool {
    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7f) return true;
    }
    return false;
}

/// A string value: bare, or wrapped in one pair of double quotes. Empty is allowed and means
/// "the default" for every string key.
fn parseString(value: []const u8) ValueError![]const u8 {
    var inner = value;
    if (inner.len != 0 and inner[0] == '"') {
        if (inner.len < 2 or inner[inner.len - 1] != '"') return error.Unquoted;
        inner = inner[1 .. inner.len - 1];
        if (std.mem.indexOfScalar(u8, inner, '"') != null) return error.Unquoted;
    } else if (std.mem.indexOfScalar(u8, inner, '"') != null) {
        return error.Unquoted;
    }
    if (inner.len > max_string_bytes) return error.TooLong;
    if (hasControl(inner)) return error.ControlCharacter;
    return inner;
}

/// One argv item: never an option, so a configured value cannot inject a flag
/// into the editor's command line.
fn parseEditorCommand(value: []const u8) ValueError![]const u8 {
    const text = try parseString(value);
    if (text.len != 0 and text[0] == '-') return error.EditorCommand;
    return text;
}

fn parsePoints(value: []const u8) ValueError!f32 {
    if (value.len == 0) return error.Empty;
    for (value) |byte| {
        if (!(std.ascii.isDigit(byte) or byte == '.')) return error.NotNumber;
    }
    const points = std.fmt.parseFloat(f32, value) catch return error.NotNumber;
    if (!std.math.isFinite(points)) return error.NotNumber;
    if (points < min_font_points or points > max_font_points) return error.OutOfRange;
    return points;
}

fn parseBool(value: []const u8) ValueError!bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.NotBool;
}

fn parsePercent(value: []const u8) ValueError!u8 {
    const digits = if (value.len != 0 and value[value.len - 1] == '%') value[0 .. value.len - 1] else value;
    if (digits.len == 0 or digits.len > 3) return error.NotPercent;
    for (digits) |byte| {
        if (!std.ascii.isDigit(byte)) return error.NotPercent;
    }
    const percent = std.fmt.parseInt(u8, digits, 10) catch return error.NotPercent;
    if (percent < min_scratchpad_percent or percent > max_scratchpad_percent) return error.NotPercent;
    return percent;
}

const SplitKeybind = struct {
    chord: []const u8,
    action: ?[]const u8,
    argument: ?[]const u8,
};

/// Split `<chord>=<action>[:<argument>]` or `<chord>=unbind`. The chord is the text before the
/// first `=`, so `=` and `+` are spelled `equal` and `plus` inside a chord.
fn splitKeybind(value: []const u8) ValueError!SplitKeybind {
    if (hasControl(value)) return error.ControlCharacter;
    const equals = std.mem.indexOfScalar(u8, value, '=') orelse return error.KeybindShape;
    const chord = std.mem.trim(u8, value[0..equals], " \t");
    const target = std.mem.trim(u8, value[equals + 1 ..], " \t");
    if (chord.len == 0 or target.len == 0) return error.KeybindShape;
    if (std.mem.eql(u8, target, "unbind")) return .{ .chord = chord, .action = null, .argument = null };

    const colon = std.mem.indexOfScalar(u8, target, ':');
    const action = if (colon) |index| target[0..index] else target;
    if (!validActionName(action)) return error.KeybindAction;
    const argument: ?[]const u8 = if (colon) |index| argument: {
        const text = target[index + 1 ..];
        if (text.len == 0 or text.len > max_string_bytes) return error.KeybindArgument;
        if (std.mem.indexOfAny(u8, text, " \t") != null) return error.KeybindArgument;
        break :argument text;
    } else null;
    return .{ .chord = chord, .action = action, .argument = argument };
}

fn validActionName(text: []const u8) bool {
    if (text.len == 0 or text.len > Name.max_length) return false;
    if (!std.ascii.isLower(text[0])) return false;
    for (text) |byte| {
        if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '.' or byte == '-' or byte == '_')) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Reading the file
// ---------------------------------------------------------------------------

/// What reading the settings file found.
pub const ReadResult = union(enum) {
    /// No file: the built-in layer applies and nothing is reported.
    missing,
    /// The file's bytes, owned by the caller's allocator.
    bytes: []u8,
    /// The file exists but could not be used; the message says why, terse and without content.
    failed: []const u8,
};

/// Read the whole settings file, bounded by `max_file_bytes`.
pub fn readFile(io: Io, gpa: Allocator, path: []const u8) Allocator.Error!ReadResult {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes + 1)) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => .missing,
        error.StreamTooLong => .{ .failed = "file is larger than 256 KiB" },
        error.IsDir => .{ .failed = "the config path is a directory" },
        error.AccessDenied, error.PermissionDenied => .{ .failed = "permission denied" },
        error.OutOfMemory => error.OutOfMemory,
        else => .{ .failed = "file could not be read" },
    };
    return .{ .bytes = bytes };
}

/// Read and parse the settings file at `path` into a new config.
///
/// A missing file yields the built-in defaults with no diagnostics. A file that exists but cannot
/// be read keeps every value of `previous` (or the defaults) and reports one file-wide diagnostic.
pub fn load(io: Io, gpa: Allocator, path: []const u8, previous: ?*const Config) Allocator.Error!Config {
    switch (try readFile(io, gpa, path)) {
        .missing => return Config.initDefaults(gpa),
        .failed => |message| {
            if (previous) |before| return Config.keepAll(gpa, before, 0, "{s}", .{message});
            var result = Config.initDefaults(gpa);
            result.addDiagnostic(0, "{s}", .{message});
            return result;
        },
        .bytes => |bytes| {
            defer gpa.free(bytes);
            return parse(gpa, bytes, previous);
        },
    }
}

// ---------------------------------------------------------------------------
// Location
// ---------------------------------------------------------------------------

/// The environment values the location depends on. Each is null when unset or empty.
pub const PathEnv = struct {
    xdg_config_home: ?[]const u8 = null,
    home: ?[]const u8 = null,
    appdata: ?[]const u8 = null,
};

/// The settings file's platform-appropriate path, written into `buffer`.
///
/// - Linux and other Unix: `$XDG_CONFIG_HOME/conduit/config`, else `$HOME/.config/conduit/config`.
///   A relative `XDG_CONFIG_HOME` is ignored, as the XDG base directory specification requires.
/// - macOS: `$HOME/Library/Application Support/conduit/config`.
/// - Windows: `%APPDATA%\conduit\config`.
///
/// Null when the environment names no home, or the path does not fit.
pub fn defaultPath(buffer: []u8, os: std.Target.Os.Tag, env: PathEnv) ?[]const u8 {
    switch (os) {
        .windows => {
            const appdata = env.appdata orelse return null;
            return std.fmt.bufPrint(buffer, "{s}\\conduit\\config", .{std.mem.trimEnd(u8, appdata, "\\/")}) catch null;
        },
        .macos => {
            const home = env.home orelse return null;
            return std.fmt.bufPrint(buffer, "{s}/Library/Application Support/conduit/config", .{std.mem.trimEnd(u8, home, "/")}) catch null;
        },
        else => {
            if (env.xdg_config_home) |xdg| {
                if (xdg.len != 0 and xdg[0] == '/') {
                    return std.fmt.bufPrint(buffer, "{s}/conduit/config", .{std.mem.trimEnd(u8, xdg, "/")}) catch null;
                }
            }
            const home = env.home orelse return null;
            return std.fmt.bufPrint(buffer, "{s}/.config/conduit/config", .{std.mem.trimEnd(u8, home, "/")}) catch null;
        },
    }
}

/// The directory part of a settings path: what a watcher watches and what is created before the
/// defaults document is written.
pub fn directoryOf(path: []const u8) ?[]const u8 {
    const index = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return null;
    if (index == 0) return path[0..1];
    return path[0..index];
}

fn baseNameOf(path: []const u8) []const u8 {
    const index = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[index + 1 ..];
}

/// The user theme directory for a settings path: `themes` beside the settings file, written into
/// `buffer` with the path's own separator. Null when the path has no directory or does not fit.
pub fn themesDirectory(buffer: []u8, settings_path: []const u8) ?[]const u8 {
    const dir = directoryOf(settings_path) orelse return null;
    const separator: u8 = if (std.mem.lastIndexOfScalar(u8, settings_path, '\\') != null and
        std.mem.lastIndexOfScalar(u8, settings_path, '/') == null) '\\' else '/';
    return std.fmt.bufPrint(buffer, "{s}{c}themes", .{ dir, separator }) catch null;
}

// ---------------------------------------------------------------------------
// The defaults document
// ---------------------------------------------------------------------------

const keybind_examples = if (builtin.os.tag == .macos)
    "# keybind = super+`=scratchpad.toggle-50\n" ++
        "# keybind = super+shift+`=scratchpad.toggle-90\n" ++
        "# keybind = super+shift+p=palette.open\n" ++
        "# keybind = super+,=config.open\n"
else
    "# keybind = ctrl+`=scratchpad.toggle-50\n" ++
        "# keybind = ctrl+shift+`=scratchpad.toggle-90\n" ++
        "# keybind = ctrl+shift+p=palette.open\n" ++
        "# keybind = ctrl+,=config.open\n";

/// The defaults document's `control.enabled` line: this build's own default.
const control_default_line = if (control_enabled_default)
    "# control.enabled = true\n"
else
    "# control.enabled = false\n";

/// What `config.open` writes when there is no file yet: every key, commented out, at its built-in
/// value. Uncommenting a setting line leaves the behaviour unchanged, so the file documents itself.
pub const defaults_document =
    "# Conduit configuration\n" ++
    "#\n" ++
    "# One `key = value` per line; a line starting with `#` is a comment. Edits apply as soon\n" ++
    "# as the file is saved. A line with a problem is reported in the sidebar and skipped, and\n" ++
    "# the rest of the file still applies. Every setting below is the built-in default.\n" ++
    "\n" ++
    "# Fonts. An empty family is the bundled face. Size is in points, 1 to 72.\n" ++
    "# font.family = \"\"\n" ++
    "# font.bold = \"\"\n" ++
    "# font.italic = \"\"\n" ++
    "# font.bold_italic = \"\"\n" ++
    "# font.size = 14\n" ++
    "# font.ligatures = true\n" ++
    "# font.nerd_symbols = true\n" ++
    "# Families tried, in order, for characters the family lacks: a comma-separated list.\n" ++
    "# font.fallbacks = \"\"\n" ++
    "\n" ++
    "# Colour scheme: a bundled name (gruvbox-dark, catppuccin-latte, dracula, nord, ...), the\n" ++
    "# name of a Ghostty-format file in the themes directory next to this file, or\n" ++
    "# auto:<dark>,<light> to follow the system preference. Empty is conduit-dark.\n" ++
    "# theme = \"\"\n" ++
    "\n" ++
    "# Scratchpad heights in percent of the window, 10 to 100.\n" ++
    "# scratchpad.size = 50\n" ++
    "# scratchpad.large_size = 90\n" ++
    "\n" ++
    "# Right click over a terminal: menu or paste.\n" ++
    "# mouse.right_click = menu\n" ++
    "\n" ++
    "# macOS only: which Option keys are Alt (Meta) instead of typing accented characters:\n" ++
    "# false, true (both), left or right.\n" ++
    "# macos.option_as_alt = false\n" ++
    "\n" ++
    "# Agent and terminal notifications: the in-app list, and an OS notification while the\n" ++
    "# window is unfocused. Per kind: permission, input, done, error and terminal (OSC 9/777\n" ++
    "# and a background bell); per harness: claude_code, codex, pi and opencode.\n" ++
    "# notifications.enabled = true\n" ++
    "# notifications.os = true\n" ++
    "# notifications.permission = true\n" ++
    "# notifications.input = true\n" ++
    "# notifications.done = true\n" ++
    "# notifications.error = true\n" ++
    "# notifications.terminal = true\n" ++
    "# notifications.claude_code = true\n" ++
    "# notifications.codex = true\n" ++
    "# notifications.pi = true\n" ++
    "# notifications.opencode = true\n" ++
    "\n" ++
    "# One sidebar row per agent under its tab: its state glyph, harness and state. Click it,\n" ++
    "# or Enter on it, to open that agent's view. false keeps only the glyph on the tab.\n" ++
    "# sidebar.agents = true\n" ++
    "\n" ++
    "# The agent state icons on agent, tab and workspace rows. dots: ● working (yellow),\n" ++
    "# blocked (red) and done (cyan), ○ idle (green). symbols: ◐ working, × blocked, ✓ done,\n" ++
    "# ○ idle. An errored agent is a × in the danger colour in both.\n" ++
    "# sidebar.status_icons = dots\n" ++
    "\n" ++
    "# Remote connections (Remote: connect). Saved profiles hold a destination, never a\n" ++
    "# secret, and repeat one per line: remote.profile = <name> = <user@host[:port]>\n" ++
    "# The last ten destinations connected to, newest first:\n" ++
    "# remote.recent = \"\"\n" ++
    "\n" ++
    "# The local control endpoint (docs/control-api.md) and the single-instance endpoint the\n" ++
    "# conduit command reuses. Read at startup. Off in release builds unless turned on.\n" ++
    control_default_line ++
    "\n" ++
    "# Save workspaces, tabs, pane layouts, working directories, the theme and the window size,\n" ++
    "# and restore them on the next launch. Terminal contents are never saved. Read at startup.\n" ++
    "# restore.enabled = true\n" ++
    "\n" ++
    "# Expose the interface to screen readers and other assistive technologies. Read at startup.\n" ++
    "# accessibility.enabled = true\n" ++
    "\n" ++
    "# Shell profiles: what a new tab or pane runs. Each is one line,\n" ++
    "# `profile = <name> = <command> [arguments...]`,\n" ++
    "# with optional profile.<name>.env = NAME=value (repeats), profile.<name>.cwd = <dir>\n" ++
    "# and profile.<name>.login = true. New tab with profile lists them. `shell` names the\n" ++
    "# profile new tabs use; empty is the built-in default (your login shell, or on\n" ++
    "# Windows the first of pwsh, powershell and cmd that is installed).\n" ++
    "# shell = \"\"\n" ++
    "\n" ++
    "# The VSCodium command (or its full path) the editor pane runs. Conduit never installs\n" ++
    "# it; empty tries `codium` on the PATH.\n" ++
    "# editor.command = \"\"\n" ++
    "\n" ++
    "# Keybindings: keybind = <chord>=<action>[:<argument>], or <chord>=unbind.\n" ++
    "# Modifiers are ctrl, shift, alt and super (cmd). These lines repeat some defaults.\n" ++
    keybind_examples;

// ---------------------------------------------------------------------------
// Editing the document
// ---------------------------------------------------------------------------

/// Why `setDocumentValue` refused an edit.
pub const EditError = error{
    /// The value is not something `parse` would read back as the same string.
    InvalidValue,
    /// The edited document would exceed `max_file_bytes`.
    TooLarge,
} || Allocator.Error;

/// `document` with `key` set to `value`, as a new allocation the caller owns.
///
/// The last uncommented line for `key` (the one that wins when the file is parsed) is replaced in
/// place, keeping its indentation and line ending; every other line, comments and blank lines
/// included, is kept byte for byte. When no line sets the key, `key = value` is appended. The value
/// is written bare when that reads back unchanged, otherwise in double quotes. Only string values
/// without control characters or double quotes are accepted, and never `keybind`, which repeats.
pub fn setDocumentValue(gpa: Allocator, document: []const u8, key: Key, value: []const u8) EditError![]u8 {
    if (key == .keybind or key == .remote_profile or key == .profile) return error.InvalidValue;
    if (value.len > max_string_bytes or !std.unicode.utf8ValidateSlice(value) or hasControl(value) or
        std.mem.indexOfScalar(u8, value, '"') != null) return error.InvalidValue;
    const quoted = value.len == 0 or std.mem.trim(u8, value, " \t").len != value.len;

    // The byte range of the last line that sets `key`, without its line ending.
    var target_start: ?usize = null;
    var target_end: usize = 0;
    var start: usize = 0;
    while (start < document.len) {
        const newline = std.mem.indexOfScalarPos(u8, document, start, '\n');
        var end = newline orelse document.len;
        const next = if (newline) |index| index + 1 else document.len;
        if (end > start and document[end - 1] == '\r') end -= 1;
        const line = document[start..end];
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len != 0 and trimmed[0] != '#') {
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |equals| {
                if (std.mem.eql(u8, std.mem.trim(u8, trimmed[0..equals], " \t"), key.name())) {
                    target_start = start + (line.len - trimmed.len);
                    target_end = end;
                }
            }
        }
        start = next;
    }

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    writeEdited(&out.writer, document, target_start, target_end, key.name(), value, quoted) catch return error.OutOfMemory;
    if (out.written().len > max_file_bytes) return error.TooLarge;
    return out.toOwnedSlice();
}

/// Why a value typed for `key` would be rejected: the message a settings file line holding it
/// reports after `<key>: `, or null when `parse` would accept it. `value` is the text that would
/// follow `key = ` in the file, written bare: a double quote anywhere is refused because
/// `setDocumentValue` adds the quotes itself. Allocates nothing. `keybind` is never a single value.
pub fn checkValue(key: Key, value: []const u8) ?[]const u8 {
    const failure: ValueError = check: {
        if (!std.unicode.utf8ValidateSlice(value)) break :check error.ControlCharacter;
        switch (key) {
            .font_family, .font_bold, .font_italic, .font_bold_italic, .theme, .font_fallbacks => {
                if (std.mem.indexOfScalar(u8, value, '"') != null) break :check error.Unquoted;
                const text = parseString(value) catch |err| break :check err;
                if (key == .font_fallbacks) {
                    var names: [max_font_fallbacks][]const u8 = undefined;
                    _ = splitFallbacks(text, &names) catch |err| break :check err;
                }
                return null;
            },
            .font_size => {
                _ = parsePoints(value) catch |err| break :check err;
                return null;
            },
            .font_ligatures,
            .font_nerd_symbols,
            .control_enabled,
            .restore_enabled,
            .accessibility_enabled,
            .sidebar_agents,
            .notifications_enabled,
            .notifications_os,
            .notifications_permission,
            .notifications_input,
            .notifications_done,
            .notifications_error,
            .notifications_terminal,
            .notifications_claude_code,
            .notifications_codex,
            .notifications_pi,
            .notifications_opencode,
            => {
                _ = parseBool(value) catch |err| break :check err;
                return null;
            },
            .scratchpad_size, .scratchpad_large_size => {
                _ = parsePercent(value) catch |err| break :check err;
                return null;
            },
            .mouse_right_click => {
                _ = RightClick.parse(value) catch break :check error.NotRightClick;
                return null;
            },
            .sidebar_status_icons => {
                _ = StatusIcons.parse(value) catch break :check error.NotStatusIcons;
                return null;
            },
            .macos_option_as_alt => {
                _ = OptionAsAlt.parse(value) catch break :check error.NotOptionAsAlt;
                return null;
            },
            .remote_profile => {
                _ = splitProfile(value) catch |err| break :check err;
                return null;
            },
            .remote_recent => {
                if (std.mem.indexOfScalar(u8, value, '"') != null) break :check error.Unquoted;
                var items: [max_remote_recent][]const u8 = undefined;
                _ = splitRecent(parseString(value) catch |err| break :check err, &items) catch |err| break :check err;
                return null;
            },
            .shell => {
                if (std.mem.indexOfScalar(u8, value, '"') != null) break :check error.Unquoted;
                const name = parseString(value) catch |err| break :check err;
                if (name.len != 0 and !validShellProfileName(name)) break :check error.ShellProfileName;
                return null;
            },
            .editor_command => {
                if (std.mem.indexOfScalar(u8, value, '"') != null) break :check error.Unquoted;
                _ = parseEditorCommand(value) catch |err| break :check err;
                return null;
            },
            .profile => {
                var storage: [max_line_bytes]u8 = undefined;
                var args: [max_profile_args][]const u8 = undefined;
                _ = splitShellProfile(value, &storage, &args) catch |err| break :check err;
                return null;
            },
            .keybind => break :check error.KeybindShape,
        }
    };
    return valueMessage(key, failure);
}

/// `document` with the `keybind` lines that bind `action` replaced, as a new allocation the caller
/// owns.
///
/// Every uncommented `keybind = <chord>=<action>[:<argument>]` line naming `action` is removed, as
/// is every `keybind = <chord>=unbind` line whose chord is spelled (ignoring ASCII case) as one of
/// `unbind_chords`, so repeated edits never pile up duplicates. Then one `keybind = <chord>=unbind`
/// line per `unbind_chords` entry and, when `chord` is not null, `keybind = <chord>=<action>` are
/// appended in that order, so they win over every earlier line. Every other line, comments and
/// blank lines included, is kept byte for byte. A keybind line replaces whatever its chord was
/// bound to, so the appended `<chord>=<action>` takes that chord from any other action. Chords are
/// written as given: non-empty, without `=`, a quote, a control character or surrounding blanks.
pub fn setActionKeybinds(
    gpa: Allocator,
    document: []const u8,
    action: []const u8,
    unbind_chords: []const []const u8,
    chord: ?[]const u8,
) EditError![]u8 {
    if (!validActionName(action)) return error.InvalidValue;
    for (unbind_chords) |text| if (!validChordText(text)) return error.InvalidValue;
    if (chord) |text| if (!validChordText(text)) return error.InvalidValue;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    writeKeybindEdit(&out.writer, document, action, unbind_chords, chord) catch return error.OutOfMemory;
    if (out.written().len > max_file_bytes) return error.TooLarge;
    return out.toOwnedSlice();
}

fn writeKeybindEdit(
    writer: *std.Io.Writer,
    document: []const u8,
    action: []const u8,
    unbind_chords: []const []const u8,
    chord: ?[]const u8,
) std.Io.Writer.Error!void {
    var start: usize = 0;
    var last: u8 = '\n';
    while (start < document.len) {
        const newline = std.mem.indexOfScalarPos(u8, document, start, '\n');
        var end = newline orelse document.len;
        const next = if (newline) |index| index + 1 else document.len;
        if (end > start and document[end - 1] == '\r') end -= 1;
        if (!keybindLineIsReplaced(document[start..end], action, unbind_chords)) {
            try writer.writeAll(document[start..next]);
            last = document[next - 1];
        }
        start = next;
    }
    if (last != '\n') try writer.writeByte('\n');
    for (unbind_chords) |text| try writer.print("keybind = {s}=unbind\n", .{text});
    if (chord) |text| try writer.print("keybind = {s}={s}\n", .{ text, action });
}

fn validChordText(text: []const u8) bool {
    return text.len != 0 and text.len <= max_string_bytes and !hasControl(text) and
        std.mem.indexOfAny(u8, text, "=\"") == null and std.mem.trim(u8, text, " \t").len == text.len;
}

/// Whether `line` is a `keybind` line `setActionKeybinds` drops for `action`.
fn keybindLineIsReplaced(line: []const u8, action: []const u8, unbind_chords: []const []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0 or trimmed[0] == '#') return false;
    const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse return false;
    const key = Key.fromName(std.mem.trim(u8, trimmed[0..equals], " \t")) orelse return false;
    if (key != .keybind) return false;
    const split = splitKeybind(std.mem.trim(u8, trimmed[equals + 1 ..], " \t")) catch return false;
    if (split.action) |bound| return std.mem.eql(u8, bound, action);
    for (unbind_chords) |text| {
        if (std.ascii.eqlIgnoreCase(text, split.chord)) return true;
    }
    return false;
}

fn writeEdited(
    writer: *std.Io.Writer,
    document: []const u8,
    target_start: ?usize,
    target_end: usize,
    name: []const u8,
    value: []const u8,
    quoted: bool,
) std.Io.Writer.Error!void {
    if (target_start) |line_start| {
        try writer.writeAll(document[0..line_start]);
        try writeSetting(writer, name, value, quoted);
        try writer.writeAll(document[target_end..]);
        return;
    }
    try writer.writeAll(document);
    if (document.len != 0 and document[document.len - 1] != '\n') try writer.writeByte('\n');
    try writeSetting(writer, name, value, quoted);
    try writer.writeByte('\n');
}

fn writeSetting(writer: *std.Io.Writer, name: []const u8, value: []const u8, quoted: bool) std.Io.Writer.Error!void {
    if (quoted) {
        try writer.print("{s} = \"{s}\"", .{ name, value });
    } else {
        try writer.print("{s} = {s}", .{ name, value });
    }
}

/// Set `key` in the settings file at `path`, creating the file (and its directory) from
/// `defaults_document` when it is missing. The new file is written beside the old one and renamed
/// over it, so a reader never sees half a file and the watcher sees one change. Main thread only.
pub fn writeDocumentValue(io: Io, gpa: Allocator, path: []const u8, key: Key, value: []const u8) !void {
    const existing: ?[]u8 = switch (try readFile(io, gpa, path)) {
        .missing => null,
        .bytes => |bytes| bytes,
        .failed => return error.Unreadable,
    };
    defer if (existing) |bytes| gpa.free(bytes);
    const edited = try setDocumentValue(gpa, existing orelse defaults_document, key, value);
    defer gpa.free(edited);
    try replaceDocument(io, path, edited);
}

/// `document` with the profile `name` saved as `destination`, as a new allocation the caller
/// owns: every uncommented `remote.profile` line for that name is removed and one
/// `remote.profile = <name> = <destination>` line is appended, so a profile is never listed
/// twice. Every other line is kept byte for byte.
pub fn setDocumentProfile(gpa: Allocator, document: []const u8, name: []const u8, destination: []const u8) EditError![]u8 {
    if (!validProfileName(name)) return error.InvalidValue;
    _ = parseDestination(destination) catch return error.InvalidValue;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    writeProfileEdit(&out.writer, document, name, destination) catch return error.OutOfMemory;
    if (out.written().len > max_file_bytes) return error.TooLarge;
    return out.toOwnedSlice();
}

fn writeProfileEdit(writer: *std.Io.Writer, document: []const u8, name: []const u8, destination: []const u8) std.Io.Writer.Error!void {
    var start: usize = 0;
    var last: u8 = '\n';
    while (start < document.len) {
        const newline = std.mem.indexOfScalarPos(u8, document, start, '\n');
        var end = newline orelse document.len;
        const next = if (newline) |index| index + 1 else document.len;
        if (end > start and document[end - 1] == '\r') end -= 1;
        if (!profileLineNames(document[start..end], name)) {
            try writer.writeAll(document[start..next]);
            last = document[next - 1];
        }
        start = next;
    }
    if (last != '\n') try writer.writeByte('\n');
    try writer.print("remote.profile = {s} = {s}\n", .{ name, destination });
}

/// Whether `line` is an uncommented `remote.profile` line for `name`.
fn profileLineNames(line: []const u8, name: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0 or trimmed[0] == '#') return false;
    const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse return false;
    if (Key.fromName(std.mem.trim(u8, trimmed[0..equals], " \t")) != .remote_profile) return false;
    const profile = splitProfile(std.mem.trim(u8, trimmed[equals + 1 ..], " \t")) catch return false;
    return std.mem.eql(u8, profile.name, name);
}

/// Save one profile in the settings file at `path` as `setDocumentProfile` does, creating the
/// file from `defaults_document` when it is missing, with the same write-and-rename as
/// `writeDocumentValue`. Main thread only.
pub fn writeDocumentProfile(io: Io, gpa: Allocator, path: []const u8, name: []const u8, destination: []const u8) !void {
    const existing: ?[]u8 = switch (try readFile(io, gpa, path)) {
        .missing => null,
        .bytes => |bytes| bytes,
        .failed => return error.Unreadable,
    };
    defer if (existing) |bytes| gpa.free(bytes);
    const edited = try setDocumentProfile(gpa, existing orelse defaults_document, name, destination);
    defer gpa.free(edited);
    try replaceDocument(io, path, edited);
}

/// Rewrite the `keybind` lines for `action` in the settings file at `path` as `setActionKeybinds`
/// does, creating the file from `defaults_document` when it is missing, with the same
/// write-and-rename as `writeDocumentValue`. Main thread only.
pub fn writeActionKeybinds(
    io: Io,
    gpa: Allocator,
    path: []const u8,
    action: []const u8,
    unbind_chords: []const []const u8,
    chord: ?[]const u8,
) !void {
    const existing: ?[]u8 = switch (try readFile(io, gpa, path)) {
        .missing => null,
        .bytes => |bytes| bytes,
        .failed => return error.Unreadable,
    };
    defer if (existing) |bytes| gpa.free(bytes);
    const edited = try setActionKeybinds(gpa, existing orelse defaults_document, action, unbind_chords, chord);
    defer gpa.free(edited);
    try replaceDocument(io, path, edited);
}

/// Write `edited` beside `path` and rename it over the original, creating the directory first.
fn replaceDocument(io: Io, path: []const u8, edited: []const u8) !void {
    if (directoryOf(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    var temporary_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temporary = std.fmt.bufPrint(&temporary_buffer, "{s}.conduit-edit", .{path}) catch return error.NameTooLong;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = edited });
    errdefer Io.Dir.cwd().deleteFile(io, temporary) catch |err| {
        log.warn("could not remove the temporary settings file: {s}", .{@errorName(err)});
    };
    try Io.Dir.cwd().rename(temporary, Io.Dir.cwd(), path, io);
}

// ---------------------------------------------------------------------------
// Watching
// ---------------------------------------------------------------------------

/// How long a burst of writes must be quiet before one reload is requested. Editors write a file
/// in several steps (truncate, write, rename, chmod); one reload per save is the goal.
pub const debounce_ms: i32 = 100;
/// How often the portable backend, and the Linux backend while the directory does not exist,
/// compare the file's size, modification time and inode.
pub const poll_interval_ms: i32 = 1000;

/// Notices edits to the settings file without a busy loop.
///
/// Thread ownership: `start` and `stop` run on the owner (main) thread. The watcher's own thread
/// only waits on the file system; on a change it sets `changed` and calls `wake_fn`, which must be
/// safe to call from any thread (the app posts an SDL event). The owner reads and applies the file
/// itself after `takeChanged`, so no file content ever crosses threads.
///
/// Backends: Linux uses inotify on the parent directory, so an editor that saves by writing a
/// temporary file and renaming it over the original is seen; while the directory does not exist
/// it polls every `poll_interval_ms` until it can watch. Every other OS compares size, mtime and
/// inode every `poll_interval_ms`.
pub const Watcher = struct {
    allocator: Allocator,
    io: Io,
    /// Owned copy of the watched path.
    path: []u8,
    wake_context: *anyopaque,
    wake_fn: *const fn (context: *anyopaque) void,
    changed: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    /// Wakes the portable backend's timed wait at shutdown.
    stop_event: Io.Event = .unset,
    /// Linux: an eventfd the owner writes to stop the thread; -1 elsewhere.
    stop_fd: i32 = -1,
    thread: ?std.Thread = null,
    /// The file as `start` saw it on the owner thread, so a write that lands before the watch
    /// is established is still noticed by the first comparison.
    initial: Signature = .{},

    pub const Error = error{WatchUnavailable} || Allocator.Error || std.Thread.SpawnError;

    /// Start watching `path`. The returned watcher is owned by the caller and released by `stop`.
    pub fn start(
        allocator: Allocator,
        io: Io,
        path: []const u8,
        wake_context: *anyopaque,
        wake_fn: *const fn (context: *anyopaque) void,
    ) Error!*Watcher {
        const self = try allocator.create(Watcher);
        errdefer allocator.destroy(self);
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .path = owned_path,
            .wake_context = wake_context,
            .wake_fn = wake_fn,
        };
        if (comptime builtin.os.tag == .linux) {
            const linux = std.os.linux;
            const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
            if (linux.errno(rc) != .SUCCESS) return error.WatchUnavailable;
            self.stop_fd = @intCast(rc);
        }
        errdefer if (comptime builtin.os.tag == .linux) {
            _ = std.os.linux.close(self.stop_fd);
        };
        self.initial = self.signature();
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Stop the thread, join it and free the watcher.
    pub fn stop(self: *Watcher) void {
        self.stopping.store(true, .release);
        self.stop_event.set(self.io);
        if (comptime builtin.os.tag == .linux) {
            const one: u64 = 1;
            // One write cannot overflow the eventfd counter, and a failed write still leaves
            // `stopping` set, which the Linux loop checks after every bounded wait.
            _ = std.os.linux.write(self.stop_fd, std.mem.asBytes(&one), @sizeOf(u64));
        }
        if (self.thread) |thread| thread.join();
        if (comptime builtin.os.tag == .linux) _ = std.os.linux.close(self.stop_fd);
        const allocator = self.allocator;
        allocator.free(self.path);
        allocator.destroy(self);
    }

    /// Whether the file changed since the last call. Owner thread only.
    pub fn takeChanged(self: *Watcher) bool {
        return self.changed.swap(false, .acq_rel);
    }

    fn signal(self: *Watcher) void {
        self.changed.store(true, .release);
        self.wake_fn(self.wake_context);
    }

    fn run(self: *Watcher) void {
        if (comptime builtin.os.tag == .linux) {
            self.runInotify();
        } else {
            self.runPolling();
        }
    }

    /// What polling compares: whether the file exists, and its size, mtime and inode.
    const Signature = struct {
        exists: bool = false,
        size: u64 = 0,
        mtime: i96 = 0,
        inode: u64 = 0,

        fn eql(a: Signature, b: Signature) bool {
            return a.exists == b.exists and a.size == b.size and a.mtime == b.mtime and a.inode == b.inode;
        }
    };

    fn signature(self: *Watcher) Signature {
        const stat = Io.Dir.cwd().statFile(self.io, self.path, .{}) catch return .{};
        return .{
            .exists = true,
            .size = stat.size,
            .mtime = stat.mtime.nanoseconds,
            .inode = @intCast(stat.inode),
        };
    }

    fn runPolling(self: *Watcher) void {
        var last = self.initial;
        while (!self.stopping.load(.acquire)) {
            self.stop_event.waitTimeout(self.io, .{ .duration = .{
                .raw = .fromMilliseconds(poll_interval_ms),
                .clock = .awake,
            } }) catch {
                // A timeout is the normal wake-up of a polling loop; cancelation is
                // answered by the `stopping` check below.
            };
            if (self.stopping.load(.acquire)) return;
            const now = self.signature();
            if (!now.eql(last)) {
                last = now;
                self.signal();
            }
        }
    }

    fn runInotify(self: *Watcher) void {
        const linux = std.os.linux;
        const raw_fd = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
        if (linux.errno(raw_fd) != .SUCCESS) {
            log.warn("inotify is unavailable; polling the config file every {d} ms", .{poll_interval_ms});
            return self.runPolling();
        }
        const inotify_fd: i32 = @intCast(raw_fd);
        defer _ = linux.close(inotify_fd);

        var dir_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
        const dir = directoryOf(self.path) orelse ".";
        if (dir.len >= dir_buffer.len) return self.runPolling();
        @memcpy(dir_buffer[0..dir.len], dir);
        dir_buffer[dir.len] = 0;
        const dir_z: [*:0]const u8 = @ptrCast(&dir_buffer);
        const base = baseNameOf(self.path);
        const mask: u32 = linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO | linux.IN.MOVED_FROM |
            linux.IN.CREATE | linux.IN.DELETE | linux.IN.ATTRIB | linux.IN.MODIFY |
            linux.IN.DELETE_SELF | linux.IN.MOVE_SELF | linux.IN.ONLYDIR;

        var watching = false;
        var last = self.initial;
        while (!self.stopping.load(.acquire)) {
            if (!watching) {
                const rc = linux.inotify_add_watch(inotify_fd, dir_z, mask);
                if (linux.errno(rc) == .SUCCESS) {
                    watching = true;
                    // The directory may have appeared together with the file.
                    const now = self.signature();
                    if (!now.eql(last)) {
                        last = now;
                        self.signal();
                    }
                }
            }
            var fds = [_]linux.pollfd{
                .{ .fd = inotify_fd, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = self.stop_fd, .events = linux.POLL.IN, .revents = 0 },
            };
            const timeout: i32 = if (watching) -1 else poll_interval_ms;
            const ready = linux.poll(&fds, fds.len, timeout);
            if (self.stopping.load(.acquire) or fds[1].revents != 0) return;
            if (linux.errno(ready) != .SUCCESS) continue;
            if (fds[0].revents == 0) {
                if (!watching) {
                    const now = self.signature();
                    if (!now.eql(last)) {
                        last = now;
                        self.signal();
                    }
                }
                continue;
            }
            if (!drainEvents(inotify_fd, base, &watching)) continue;
            // Debounce: collect until the directory has been quiet for `debounce_ms`. Bounded,
            // so a file rewritten continuously still reloads about once a second.
            var rounds: u32 = 0;
            while (rounds < 10) : (rounds += 1) {
                fds[0].revents = 0;
                fds[1].revents = 0;
                const settled = linux.poll(&fds, fds.len, debounce_ms);
                if (self.stopping.load(.acquire) or fds[1].revents != 0) return;
                if (linux.errno(settled) != .SUCCESS or fds[0].revents == 0) break;
                _ = drainEvents(inotify_fd, base, &watching);
            }
            last = self.signature();
            self.signal();
        }
    }

    /// Read every queued inotify event. Returns whether one concerns the settings file, the
    /// watched directory itself, or an overflowed queue (which may have hidden one).
    fn drainEvents(fd: i32, base: []const u8, watching: *bool) bool {
        const linux = std.os.linux;
        var relevant = false;
        var buffer: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            const rc = linux.read(fd, &buffer, buffer.len);
            if (linux.errno(rc) != .SUCCESS or rc == 0) return relevant;
            var offset: usize = 0;
            while (offset + @sizeOf(linux.inotify_event) <= rc) {
                const event: *const linux.inotify_event = @ptrCast(@alignCast(&buffer[offset]));
                const span = @sizeOf(linux.inotify_event) + event.len;
                if (offset + span > rc) break;
                if (event.mask & (linux.IN.IGNORED | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF) != 0) {
                    watching.* = false;
                    relevant = true;
                } else if (event.mask & linux.IN.Q_OVERFLOW != 0) {
                    relevant = true;
                } else if (event.getName()) |name| {
                    if (std.mem.eql(u8, name, base)) relevant = true;
                }
                offset += span;
            }
        }
    }
};

const testing = std.testing;

test "the right-click setting round-trips and rejects unknown spellings" {
    try testing.expectEqual(RightClick.menu, try RightClick.parse("menu"));
    try testing.expectEqual(RightClick.paste, try RightClick.parse("paste"));
    try testing.expectEqualStrings("menu", RightClick.menu.text());
    try testing.expectEqualStrings("paste", RightClick.paste.text());
    try testing.expectError(error.InvalidRightClick, RightClick.parse(""));
    try testing.expectError(error.InvalidRightClick, RightClick.parse("Menu"));
    try testing.expectError(error.InvalidRightClick, RightClick.parse("context-menu"));
    try testing.expectError(error.InvalidRightClick, RightClick.parse("paste "));
    try testing.expectEqualStrings("mouse.right_click", RightClick.name.text());
    _ = try Name.parse(RightClick.name.text());
}

test "the right-click setting resolves through the layers with a built-in default" {
    try testing.expectEqual(RightClick.menu, Layer.resolve(RightClick, RightClick.built_in, null, null));
    try testing.expectEqual(RightClick.paste, Layer.resolve(RightClick, RightClick.built_in, null, .paste));
    try testing.expectEqual(RightClick.menu, Layer.resolve(RightClick, RightClick.built_in, .paste, .menu));
}

test "a setting name round-trips through the parser" {
    const name = try Name.parse("font.bold_italic");

    try testing.expectEqualStrings("font.bold_italic", name.text());
    try testing.expectEqual(std.math.Order.lt, Name.order(name, try Name.parse("font.size")));
}

test "a name that could not be found again is rejected" {
    // Each of these would parse into a setting no palette entry and no log line could name.
    try testing.expectError(error.InvalidName, Name.parse(""));
    try testing.expectError(error.InvalidName, Name.parse("Font.size")); // uppercase
    try testing.expectError(error.InvalidName, Name.parse("font.size ")); // trailing space
    try testing.expectError(error.InvalidName, Name.parse("2fast")); // digit first
    try testing.expectError(error.InvalidName, Name.parse("_hidden")); // leading underscore
    try testing.expectError(error.InvalidName, Name.parse("font__size")); // doubled separator
    try testing.expectError(error.InvalidName, Name.parse("font.size!")); // punctuation
}

test "a name longer than the palette can show is rejected rather than truncated" {
    const too_long = "a" ** (Name.max_length + 1);
    try testing.expectError(error.InvalidName, Name.parse(too_long));

    const at_limit = "a" ** Name.max_length;
    try testing.expectEqualStrings(at_limit, (try Name.parse(at_limit)).text());
}

test "the highest layer that supplies a value wins" {
    // The v0.1 case from the architecture: v0.1 ships built-in defaults only, and a layer with no
    // value must leave the one below it standing.
    try testing.expectEqual(@as(u16, 14), Layer.resolve(u16, 14, null, null));
    try testing.expectEqual(@as(u16, 16), Layer.resolve(u16, 14, 16, null));
    try testing.expectEqual(@as(u16, 18), Layer.resolve(u16, 14, 16, 18));

    // A session override wins even when the file disagrees.
    try testing.expectEqual(@as(u16, 18), Layer.resolve(u16, 14, 99, 18));
}

test "the enum order is the precedence order a UI can render" {
    // If these ever stop being ordered, a settings view that lists layers by precedence starts
    // lying, and nothing else in the codebase would notice.
    try testing.expect(Layer.built_in.precedence() < Layer.file.precedence());
    try testing.expect(Layer.file.precedence() < Layer.session.precedence());
}

fn expectDiagnostic(config: *const Config, line: u32, message: []const u8) !void {
    for (config.diagnostics.items) |diagnostic| {
        if (diagnostic.line == line and std.mem.eql(u8, diagnostic.message, message)) return;
    }
    std.debug.print("missing diagnostic {d}: {s}; have:\n", .{ line, message });
    for (config.diagnostics.items) |diagnostic| std.debug.print("  {d}: {s}\n", .{ diagnostic.line, diagnostic.message });
    return error.TestExpectedEqual;
}

test "an empty or comment-only file is the built-in layer with nothing to report" {
    var empty = try parse(testing.allocator, "", null);
    defer empty.deinit();
    try testing.expect(!empty.hasDiagnostics());
    try testing.expectEqual(@as(?[]const u8, null), empty.settings.font_family);
    try testing.expectEqual(default_font_points, empty.settings.font_size);
    try testing.expectEqual(@as(u8, 50), empty.settings.scratchpad_size);
    try testing.expectEqual(@as(u8, 90), empty.settings.scratchpad_large_size);
    try testing.expectEqual(@as(?RightClick, null), empty.settings.right_click);
    try testing.expectEqual(@as(usize, 0), empty.keybinds.items.len);

    var comments = try parse(testing.allocator, "# a comment\n\n   \t\n  # indented comment\r\n", null);
    defer comments.deinit();
    try testing.expect(!comments.hasDiagnostics());
}

test "every key accepts its documented spellings" {
    const text =
        \\font.family = "JetBrains Mono"
        \\font.bold = JetBrains Mono Bold
        \\font.italic = "JetBrains Mono Italic"
        \\font.bold_italic = ""
        \\font.size = 15.5
        \\font.ligatures = false
        \\font.nerd_symbols = false
        \\font.fallbacks = "Noto Sans Mono CJK SC, ,Symbols Nerd Font Mono "
        \\theme = "solarized"
        \\scratchpad.size = 30
        \\scratchpad.large_size = 100%
        \\mouse.right_click = paste
        \\keybind = ctrl+shift+t=tab.new
        \\keybind=alt+1=tab.goto:1
        \\keybind = ctrl+shift+w = unbind
    ;
    var config = try parse(testing.allocator, text, null);
    defer config.deinit();
    try testing.expect(!config.hasDiagnostics());
    const settings = config.settings;
    try testing.expectEqualStrings("JetBrains Mono", settings.font_family.?);
    try testing.expectEqualStrings("JetBrains Mono Bold", settings.font_bold);
    try testing.expectEqualStrings("JetBrains Mono Italic", settings.font_italic);
    try testing.expectEqualStrings("", settings.font_bold_italic);
    try testing.expectEqual(@as(f32, 15.5), settings.font_size);
    try testing.expect(!settings.font_ligatures);
    try testing.expect(!settings.font_nerd_symbols);
    try testing.expectEqual(@as(usize, 2), settings.font_fallbacks.len);
    try testing.expectEqualStrings("Noto Sans Mono CJK SC", settings.font_fallbacks[0]);
    try testing.expectEqualStrings("Symbols Nerd Font Mono", settings.font_fallbacks[1]);
    try testing.expectEqualStrings("solarized", settings.theme);
    try testing.expectEqual(@as(u8, 30), settings.scratchpad_size);
    try testing.expectEqual(@as(u8, 100), settings.scratchpad_large_size);
    try testing.expectEqual(RightClick.paste, settings.right_click.?);
    try testing.expectEqual(@as(u32, 5), config.lines.get(.font_size));
    try testing.expectEqual(@as(usize, 3), config.keybinds.items.len);
    try testing.expectEqualStrings("ctrl+shift+t", config.keybinds.items[0].chord);
    try testing.expectEqualStrings("tab.new", config.keybinds.items[0].action.?);
    try testing.expectEqual(@as(?[]const u8, null), config.keybinds.items[0].argument);
    try testing.expectEqual(@as(u32, 13), config.keybinds.items[0].line);
    try testing.expectEqualStrings("alt+1", config.keybinds.items[1].chord);
    try testing.expectEqualStrings("tab.goto", config.keybinds.items[1].action.?);
    try testing.expectEqualStrings("1", config.keybinds.items[1].argument.?);
    try testing.expectEqualStrings("ctrl+shift+w", config.keybinds.items[2].chord);
    try testing.expectEqual(@as(?[]const u8, null), config.keybinds.items[2].action);
}

test "the notifications switches parse, default on and report a non-boolean" {
    const text =
        \\notifications.enabled = true
        \\notifications.os = false
        \\notifications.permission = false
        \\notifications.error = false
        \\notifications.pi = false
        \\notifications.done = maybe
    ;
    var config = try parse(testing.allocator, text, null);
    defer config.deinit();
    const n = config.settings.notifications;
    try testing.expect(n.enabled);
    try testing.expect(!n.os);
    try testing.expect(!n.permission);
    try testing.expect(!n.@"error");
    try testing.expect(!n.pi);
    // Silent keys keep the built-in value, and a rejected line leaves it too.
    try testing.expect(n.input and n.terminal and n.claude_code and n.codex and n.opencode);
    try testing.expect(n.done);
    try expectDiagnostic(&config, 6, "notifications.done: expected `true` or `false`");
    try testing.expectEqual(@as(?bool, false), n.get(.notifications_os));
    try testing.expectEqual(@as(?bool, null), n.get(.font_size));
    try testing.expectEqual(@as(?[]const u8, null), checkValue(.notifications_codex, "false"));
    try testing.expectEqualStrings("expected `true` or `false`", checkValue(.notifications_input, "on").?);
    try testing.expectEqual(Key.notifications_claude_code, Key.fromName("notifications.claude_code").?);
    for (std.enums.values(Key)) |key| _ = try Name.parse(key.name());
}

test "each malformed value is reported with its line and key and leaves the default" {
    const text =
        \\font.size = 0
        \\font.size = big
        \\font.size = 73
        \\font.ligatures = yes
        \\scratchpad.size = 9
        \\scratchpad.large_size = 101
        \\scratchpad.size = 50.5
        \\mouse.right_click = Menu
        \\font.family = "unterminated
        \\theme = a"b
        \\keybind = ctrl+t
        \\keybind = ctrl+t=Tab.New
        \\keybind = ctrl+t=tab.goto:
        \\keybind = =tab.new
        \\
    ++ "font.family = \"bell\x07inside\"\n";
    var config = try parse(testing.allocator, text, null);
    defer config.deinit();
    try expectDiagnostic(&config, 1, "font.size: expected 1 to 72 points");
    try expectDiagnostic(&config, 2, "font.size: expected a number of points");
    try expectDiagnostic(&config, 3, "font.size: expected 1 to 72 points");
    try expectDiagnostic(&config, 4, "font.ligatures: expected `true` or `false`");
    try expectDiagnostic(&config, 5, "scratchpad.size: expected a whole percentage from 10 to 100");
    try expectDiagnostic(&config, 6, "scratchpad.large_size: expected a whole percentage from 10 to 100");
    try expectDiagnostic(&config, 7, "scratchpad.size: expected a whole percentage from 10 to 100");
    try expectDiagnostic(&config, 8, "mouse.right_click: expected `menu` or `paste`");
    try expectDiagnostic(&config, 9, "font.family: unbalanced quotes");
    try expectDiagnostic(&config, 10, "theme: unbalanced quotes");
    try expectDiagnostic(&config, 11, "keybind: expected `<chord>=<action>[:<argument>]`");
    try expectDiagnostic(&config, 12, "keybind: invalid action name");
    try expectDiagnostic(&config, 13, "keybind: invalid argument");
    try expectDiagnostic(&config, 14, "keybind: expected `<chord>=<action>[:<argument>]`");
    try expectDiagnostic(&config, 15, "font.family: value contains a control character");
    try testing.expectEqual(@as(usize, 15), config.diagnostics.items.len);
    try testing.expectEqual(@as(u32, 1), config.firstDiagnostic().?.line);
    // Nothing was accepted, so every value is still the built-in one.
    try testing.expectEqual(default_font_points, config.settings.font_size);
    try testing.expect(config.settings.font_ligatures);
    try testing.expectEqual(@as(u8, 50), config.settings.scratchpad_size);
    try testing.expectEqual(@as(?RightClick, null), config.settings.right_click);
    try testing.expectEqual(@as(?[]const u8, null), config.settings.font_family);
    try testing.expectEqual(@as(usize, 0), config.keybinds.items.len);
}

test "line-level problems are reported and the rest of the file still applies" {
    const text = "\xEF\xBB\xBFscratchpad.size = 20\r\n" ++
        "no equals sign here\n" ++
        "= value\n" ++
        "colour = red\n" ++
        "Font.Size = 12\n" ++
        "bad\xffutf8 = 1\n" ++
        ("x" ** (max_line_bytes + 1)) ++ "\n" ++
        "scratchpad.large_size = 70\n";
    var config = try parse(testing.allocator, text, null);
    defer config.deinit();
    try expectDiagnostic(&config, 2, "expected `key = value`");
    try expectDiagnostic(&config, 3, "expected `key = value`");
    try expectDiagnostic(&config, 4, "unknown key `colour`");
    try expectDiagnostic(&config, 5, "invalid key name");
    try expectDiagnostic(&config, 6, "line is not valid UTF-8");
    try expectDiagnostic(&config, 7, "line is longer than 1024 bytes");
    try testing.expectEqual(@as(usize, 6), config.diagnostics.items.len);
    try testing.expectEqual(@as(u8, 20), config.settings.scratchpad_size);
    try testing.expectEqual(@as(u8, 70), config.settings.scratchpad_large_size);
    try testing.expectEqual(@as(u32, 1), config.lines.get(.scratchpad_size));
    try testing.expectEqual(@as(u32, 8), config.lines.get(.scratchpad_large_size));
}

test "a rejected line keeps the previous value, and a valid line for the key still wins" {
    var previous = try parse(testing.allocator, "scratchpad.size = 30\nfont.family = Previous\nmouse.right_click = paste\nfont.size = 16\n", null);
    defer previous.deinit();

    const text =
        \\scratchpad.size = banana
        \\font.family = "broken
        \\mouse.right_click = sideways
        \\font.size = 20
        \\font.size = huge
    ;
    var next = try parse(testing.allocator, text, &previous);
    defer next.deinit();
    try testing.expectEqual(@as(u8, 30), next.settings.scratchpad_size);
    try testing.expectEqualStrings("Previous", next.settings.font_family.?);
    try testing.expectEqual(RightClick.paste, next.settings.right_click.?);
    // Line 4 was accepted, so line 5's rejection does not resurrect the previous 16.
    try testing.expectEqual(@as(f32, 20), next.settings.font_size);
    try testing.expect(next.kept_previous.contains(.scratchpad_size));
    try testing.expect(!next.kept_previous.contains(.font_size));
    try testing.expectEqual(@as(u32, 1), next.lines.get(.scratchpad_size));
    // The kept string was copied: the previous config can go first.
    previous.deinit();
    previous = try parse(testing.allocator, "", null);
    try testing.expectEqualStrings("Previous", next.settings.font_family.?);

    // A key the new file is silent about returns to the built-in value.
    var silent = try parse(testing.allocator, "theme = x\n", &next);
    defer silent.deinit();
    try testing.expectEqual(@as(u8, 50), silent.settings.scratchpad_size);
    try testing.expectEqual(@as(?[]const u8, null), silent.settings.font_family);
}

test "keybind lines are bounded and the overflow is reported once" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..max_keybinds + 3) |_| try text.appendSlice(testing.allocator, "keybind = f5=tab.new\n");
    var config = try parse(testing.allocator, text.items, null);
    defer config.deinit();
    try testing.expectEqual(max_keybinds, config.keybinds.items.len);
    try testing.expectEqual(@as(usize, 1), config.diagnostics.items.len);
    try expectDiagnostic(&config, max_keybinds + 1, "keybind: more than 256 keybind lines; the rest are ignored");
}

test "diagnostics are capped and the excess is counted" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..max_diagnostics + 10) |_| try text.appendSlice(testing.allocator, "nonsense\n");
    var config = try parse(testing.allocator, text.items, null);
    defer config.deinit();
    try testing.expectEqual(max_diagnostics, config.diagnostics.items.len);
    try testing.expectEqual(@as(usize, 10), config.dropped_diagnostics);
    try testing.expect(config.hasDiagnostics());
}

test "arbitrary bytes never crash the parser" {
    var prng = std.Random.DefaultPrng.init(0x37);
    const random = prng.random();
    const fragments = [_][]const u8{
        "font.size",       "=",   " ", "\n",                "\r",   "\"",    "keybind",     "ctrl+", "unbind", ":", "#", "\xff", "\x00",
        "scratchpad.size", "100", "%", "mouse.right_click", "menu", "theme", "font.family", "\t",    "=x",
    };
    var buffer: [512]u8 = undefined;
    for (0..2000) |round| {
        var len: usize = 0;
        if (round % 2 == 0) {
            len = random.uintLessThan(usize, buffer.len);
            random.bytes(buffer[0..len]);
        } else {
            while (true) {
                const piece = fragments[random.uintLessThan(usize, fragments.len)];
                if (len + piece.len > buffer.len) break;
                @memcpy(buffer[len..][0..piece.len], piece);
                len += piece.len;
                if (random.uintLessThan(u8, 16) == 0) break;
            }
        }
        var config = try parse(testing.allocator, buffer[0..len], null);
        defer config.deinit();
        try testing.expect(config.settings.scratchpad_size >= min_scratchpad_percent);
        try testing.expect(config.settings.font_size >= min_font_points and config.settings.font_size <= max_font_points);
    }
}

test "the defaults document round-trips: uncommented, it changes nothing and reports nothing" {
    var commented = try parse(testing.allocator, defaults_document, null);
    defer commented.deinit();
    try testing.expect(!commented.hasDiagnostics());
    try testing.expectEqual(@as(usize, 0), commented.keybinds.items.len);

    var uncommented: std.ArrayList(u8) = .empty;
    defer uncommented.deinit(testing.allocator);
    var lines = std.mem.splitScalar(u8, defaults_document, '\n');
    var settings_lines: usize = 0;
    while (lines.next()) |line| {
        // A setting line is `# <key> = <value>`; prose lines never start with a known key.
        if (std.mem.startsWith(u8, line, "# ")) {
            const rest = line[2..];
            const equals = std.mem.indexOfScalar(u8, rest, '=') orelse 0;
            if (equals != 0 and Key.fromName(std.mem.trim(u8, rest[0..equals], " ")) != null) {
                try uncommented.appendSlice(testing.allocator, rest);
                try uncommented.append(testing.allocator, '\n');
                settings_lines += 1;
                continue;
            }
        }
        try uncommented.appendSlice(testing.allocator, line);
        try uncommented.append(testing.allocator, '\n');
    }
    // Every key appears in the document, keybind four times; `remote.profile`
    // and `profile` repeat and are described in prose rather than as setting
    // lines.
    try testing.expectEqual(std.enums.values(Key).len - 3 + 4, settings_lines);

    var config = try parse(testing.allocator, uncommented.items, null);
    defer config.deinit();
    try testing.expect(!config.hasDiagnostics());
    const built_in: Settings = .{};
    try testing.expectEqualStrings("", config.settings.font_family.?);
    try testing.expectEqual(built_in.font_size, config.settings.font_size);
    try testing.expectEqual(built_in.font_ligatures, config.settings.font_ligatures);
    try testing.expectEqual(built_in.font_nerd_symbols, config.settings.font_nerd_symbols);
    try testing.expectEqual(@as(usize, 0), config.settings.font_fallbacks.len);
    try testing.expectEqual(built_in.scratchpad_size, config.settings.scratchpad_size);
    try testing.expectEqual(built_in.scratchpad_large_size, config.settings.scratchpad_large_size);
    try testing.expectEqual(RightClick.built_in, config.settings.right_click.?);
    try testing.expectEqualStrings(built_in.theme, config.settings.theme);
    try testing.expectEqual(@as(usize, 4), config.keybinds.items.len);
    try testing.expectEqualStrings("scratchpad.toggle-50", config.keybinds.items[0].action.?);
    try testing.expectEqualStrings("scratchpad.toggle-90", config.keybinds.items[1].action.?);
    try testing.expectEqualStrings("config.open", config.keybinds.items[3].action.?);
}

test "the location follows each platform's convention" {
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings("/x/conduit/config", defaultPath(&buffer, .linux, .{ .xdg_config_home = "/x/", .home = "/home/u" }).?);
    try testing.expectEqualStrings("/home/u/.config/conduit/config", defaultPath(&buffer, .linux, .{ .home = "/home/u" }).?);
    // A relative XDG_CONFIG_HOME is invalid by specification and ignored.
    try testing.expectEqualStrings("/home/u/.config/conduit/config", defaultPath(&buffer, .linux, .{ .xdg_config_home = "rel", .home = "/home/u" }).?);
    try testing.expectEqual(@as(?[]const u8, null), defaultPath(&buffer, .linux, .{}));
    try testing.expectEqualStrings("/Users/u/Library/Application Support/conduit/config", defaultPath(&buffer, .macos, .{ .xdg_config_home = "/x", .home = "/Users/u" }).?);
    try testing.expectEqualStrings("C:\\Users\\u\\AppData\\Roaming\\conduit\\config", defaultPath(&buffer, .windows, .{ .appdata = "C:\\Users\\u\\AppData\\Roaming", .home = "/h" }).?);
    try testing.expectEqual(@as(?[]const u8, null), defaultPath(&buffer, .windows, .{ .home = "/h" }));
    var tiny: [8]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), defaultPath(&tiny, .linux, .{ .home = "/home/u" }));
    try testing.expectEqualStrings("/home/u/.config/conduit", directoryOf("/home/u/.config/conduit/config").?);
    try testing.expectEqualStrings("config", baseNameOf("/home/u/.config/conduit/config"));
}

fn tmpConfigPath(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, ".zig-cache/tmp/{s}/config", .{tmp.sub_path[0..]});
}

test "loading: a missing file is the defaults, an unreadable one keeps the previous values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try tmpConfigPath(&tmp, &path_buffer);

    var missing = try load(testing.io, testing.allocator, path, null);
    defer missing.deinit();
    try testing.expect(!missing.hasDiagnostics());

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config", .data = "scratchpad.size = 25\nkeybind = f5=tab.new\n" });
    var first = try load(testing.io, testing.allocator, path, null);
    defer first.deinit();
    try testing.expect(!first.hasDiagnostics());
    try testing.expectEqual(@as(u8, 25), first.settings.scratchpad_size);

    const oversized = try testing.allocator.alloc(u8, max_file_bytes + 1);
    defer testing.allocator.free(oversized);
    // Comment lines of 64 bytes, so the only problem is the size.
    for (oversized, 0..) |*byte, index| byte.* = if (index % 64 == 63) '\n' else '#';
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config", .data = oversized });
    var too_large = try load(testing.io, testing.allocator, path, &first);
    defer too_large.deinit();
    try expectDiagnostic(&too_large, 0, "file is larger than 256 KiB");
    try testing.expectEqual(@as(u8, 25), too_large.settings.scratchpad_size);
    try testing.expectEqual(@as(usize, 1), too_large.keybinds.items.len);
    try testing.expectEqualStrings("f5", too_large.keybinds.items[0].chord);

    // Exactly the limit is still read.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config", .data = oversized[0..max_file_bytes] });
    var at_limit = try load(testing.io, testing.allocator, path, &first);
    defer at_limit.deinit();
    try testing.expect(!at_limit.hasDiagnostics());
}

test "the themes directory sits beside the settings file" {
    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings("/home/u/.config/conduit/themes", themesDirectory(&buffer, "/home/u/.config/conduit/config").?);
    try testing.expectEqualStrings("C:\\Users\\u\\conduit\\themes", themesDirectory(&buffer, "C:\\Users\\u\\conduit\\config").?);
    try testing.expect(themesDirectory(&buffer, "config") == null);
    var tiny: [8]u8 = undefined;
    try testing.expect(themesDirectory(&tiny, "/home/u/.config/conduit/config") == null);
}

test "editing the document replaces the winning line in place and keeps everything else" {
    const document =
        "# my settings\n" ++
        "# theme = \"\"\n" ++
        "theme = nord\n" ++
        "scratchpad.size = 30 \n" ++
        "  theme=gruvbox-dark\r\n" ++
        "\n" ++
        "# trailing comment\n";
    const edited = try setDocumentValue(testing.allocator, document, .theme, "Rosé Pine");
    defer testing.allocator.free(edited);
    try testing.expectEqualStrings(
        "# my settings\n" ++
            "# theme = \"\"\n" ++
            "theme = nord\n" ++
            "scratchpad.size = 30 \n" ++
            "  theme = Rosé Pine\r\n" ++
            "\n" ++
            "# trailing comment\n",
        edited,
    );
    var parsed = try parse(testing.allocator, edited, null);
    defer parsed.deinit();
    try testing.expect(!parsed.hasDiagnostics());
    try testing.expectEqualStrings("Rosé Pine", parsed.settings.theme);
    try testing.expectEqual(@as(u8, 30), parsed.settings.scratchpad_size);
}

test "editing the document appends a key it does not set and quotes when it must" {
    const appended = try setDocumentValue(testing.allocator, "# only a comment", .theme, "dracula");
    defer testing.allocator.free(appended);
    try testing.expectEqualStrings("# only a comment\ntheme = dracula\n", appended);

    const from_defaults = try setDocumentValue(testing.allocator, defaults_document, .theme, "dracula");
    defer testing.allocator.free(from_defaults);
    try testing.expect(std.mem.startsWith(u8, from_defaults, defaults_document));
    try testing.expect(std.mem.endsWith(u8, from_defaults, "\ntheme = dracula\n"));

    const empty = try setDocumentValue(testing.allocator, "", .theme, "");
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("theme = \"\"\n", empty);

    try testing.expectError(error.InvalidValue, setDocumentValue(testing.allocator, "", .theme, "a\"b"));
    try testing.expectError(error.InvalidValue, setDocumentValue(testing.allocator, "", .theme, "a\nb"));
    try testing.expectError(error.InvalidValue, setDocumentValue(testing.allocator, "", .keybind, "f5=tab.new"));
}

test "writing a value creates the file from the defaults and edits it in place afterwards" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/conduit/config", .{tmp.sub_path[0..]});

    try writeDocumentValue(testing.io, testing.allocator, path, .theme, "dracula");
    var first = try load(testing.io, testing.allocator, path, null);
    defer first.deinit();
    try testing.expect(!first.hasDiagnostics());
    try testing.expectEqualStrings("dracula", first.settings.theme);

    try writeDocumentValue(testing.io, testing.allocator, path, .theme, "nord");
    var buffer: [4096]u8 = undefined;
    const text = try Io.Dir.cwd().readFile(testing.io, path, &buffer);
    try testing.expect(std.mem.startsWith(u8, text, defaults_document));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\ntheme = "));
    try testing.expect(std.mem.endsWith(u8, text, "\ntheme = nord\n"));
}

test "size steps are whole points within 6 to 72 and never jump across the range" {
    try testing.expectEqual(@as(f32, 15), stepFontPoints(14, .increase));
    try testing.expectEqual(@as(f32, 13), stepFontPoints(14, .decrease));
    try testing.expectEqual(@as(f32, 14), stepFontPoints(13.5, .increase));
    try testing.expectEqual(@as(f32, 13), stepFontPoints(13.5, .decrease));
    try testing.expectEqual(@as(f32, 72), stepFontPoints(71.5, .increase));
    try testing.expectEqual(@as(f32, 72), stepFontPoints(72, .increase));
    try testing.expectEqual(@as(f32, 71), stepFontPoints(72, .decrease));
    try testing.expectEqual(@as(f32, 6), stepFontPoints(7, .decrease));
    try testing.expectEqual(@as(f32, 6), stepFontPoints(6, .decrease));
    try testing.expectEqual(@as(f32, 6), stepFontPoints(6.5, .decrease));
    // A file may set a size below the stepping range: decrease leaves it, increase enters it.
    try testing.expectEqual(@as(f32, 3), stepFontPoints(3, .decrease));
    try testing.expectEqual(@as(f32, 6), stepFontPoints(3, .increase));
    // Every step parses back as a valid `font.size`.
    var points: f32 = 1;
    while (points < 72) {
        const next = stepFontPoints(points, .increase);
        var buffer: [16]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "{d}", .{next});
        try testing.expectEqual(next, try parsePoints(text));
        points = next;
    }
}

test "font.fallbacks splits, trims, bounds and serialises back to itself" {
    var names: [max_font_fallbacks][]const u8 = undefined;
    const parsed = try splitFallbacks(" DejaVu Sans Mono ,, Noto Sans Mono CJK SC,", &names);
    try testing.expectEqual(@as(usize, 2), parsed.len);
    try testing.expectEqualStrings("DejaVu Sans Mono", parsed[0]);
    try testing.expectEqualStrings("Noto Sans Mono CJK SC", parsed[1]);
    // The parsed names live in `names`; other splits use their own storage.
    var scratch: [max_font_fallbacks][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), (try splitFallbacks("", &scratch)).len);
    try testing.expectEqual(@as(usize, 8), (try splitFallbacks("a,b,c,d,e,f,g,h", &scratch)).len);
    try testing.expectError(error.TooManyFallbacks, splitFallbacks("a,b,c,d,e,f,g,h,i", &scratch));

    var buffer: [256]u8 = undefined;
    const text = try formatFallbacks(&buffer, parsed);
    try testing.expectEqualStrings("DejaVu Sans Mono, Noto Sans Mono CJK SC", text);
    try testing.expectEqualStrings("", try formatFallbacks(&buffer, &.{}));
    var tiny: [4]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, formatFallbacks(&tiny, parsed));

    // Written by the edit helper and parsed back, the list is the same.
    const edited = try setDocumentValue(testing.allocator, "# fonts\n", .font_fallbacks, text);
    defer testing.allocator.free(edited);
    try testing.expectEqualStrings("# fonts\nfont.fallbacks = DejaVu Sans Mono, Noto Sans Mono CJK SC\n", edited);
    var config = try parse(testing.allocator, edited, null);
    defer config.deinit();
    try testing.expect(!config.hasDiagnostics());
    try testing.expectEqual(@as(usize, 2), config.settings.font_fallbacks.len);
    try testing.expectEqualStrings("Noto Sans Mono CJK SC", config.settings.font_fallbacks[1]);

    // Too many names is a line-numbered problem that keeps the previous list.
    var rejected = try parse(testing.allocator, "font.fallbacks = a,b,c,d,e,f,g,h,i\n", &config);
    defer rejected.deinit();
    try expectDiagnostic(&rejected, 1, "font.fallbacks: expected at most 8 comma-separated families");
    try testing.expectEqual(@as(usize, 2), rejected.settings.font_fallbacks.len);
    try testing.expectEqualStrings("DejaVu Sans Mono", rejected.settings.font_fallbacks[0]);
}

test "each font command's write leaves the rest of the file, comments included, as it was" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/conduit/config", .{tmp.sub_path[0..]});
    const original =
        "# my fonts\n" ++
        "font.size = 13.5 \n" ++
        "# keep this\n" ++
        "theme = nord\n";
    try Io.Dir.cwd().createDirPath(testing.io, directoryOf(path).?);
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = original });

    var buffer: [4096]u8 = undefined;
    try writeDocumentValue(testing.io, testing.allocator, path, .font_size, "14");
    try testing.expectEqualStrings(
        "# my fonts\nfont.size = 14\n# keep this\ntheme = nord\n",
        try Io.Dir.cwd().readFile(testing.io, path, &buffer),
    );
    try writeDocumentValue(testing.io, testing.allocator, path, .font_family, "DejaVu Sans Mono");
    try writeDocumentValue(testing.io, testing.allocator, path, .font_ligatures, "false");
    try writeDocumentValue(testing.io, testing.allocator, path, .font_nerd_symbols, "false");
    try writeDocumentValue(testing.io, testing.allocator, path, .font_fallbacks, "Noto Sans Mono CJK SC");
    try writeDocumentValue(testing.io, testing.allocator, path, .font_size, "15");
    try testing.expectEqualStrings(
        "# my fonts\n" ++
            "font.size = 15\n" ++
            "# keep this\n" ++
            "theme = nord\n" ++
            "font.family = DejaVu Sans Mono\n" ++
            "font.ligatures = false\n" ++
            "font.nerd_symbols = false\n" ++
            "font.fallbacks = Noto Sans Mono CJK SC\n",
        try Io.Dir.cwd().readFile(testing.io, path, &buffer),
    );
    // The bundled face is the empty family, written quoted so it reads back as empty.
    try writeDocumentValue(testing.io, testing.allocator, path, .font_family, "");
    var loaded = try load(testing.io, testing.allocator, path, null);
    defer loaded.deinit();
    try testing.expect(!loaded.hasDiagnostics());
    try testing.expectEqualStrings("", loaded.settings.font_family.?);
    try testing.expectEqual(@as(f32, 15), loaded.settings.font_size);
    try testing.expect(!loaded.settings.font_ligatures);
    try testing.expect(!loaded.settings.font_nerd_symbols);
    try testing.expectEqualStrings("Noto Sans Mono CJK SC", loaded.settings.font_fallbacks[0]);
    try testing.expectEqualStrings("nord", loaded.settings.theme);
}

test "a typed value is checked with the message its file line would report" {
    try testing.expectEqual(@as(?[]const u8, null), checkValue(.font_size, "13.5"));
    try testing.expectEqualStrings("expected 1 to 72 points", checkValue(.font_size, "99").?);
    try testing.expectEqualStrings("expected a number of points", checkValue(.font_size, "big").?);
    try testing.expectEqualStrings("expected a value", checkValue(.font_size, "").?);
    try testing.expectEqual(@as(?[]const u8, null), checkValue(.scratchpad_size, "40%"));
    try testing.expectEqualStrings("expected a whole percentage from 10 to 100", checkValue(.scratchpad_size, "5").?);
    try testing.expectEqualStrings("expected a whole percentage from 10 to 100", checkValue(.scratchpad_large_size, "abc").?);
    try testing.expectEqual(@as(?[]const u8, null), checkValue(.font_ligatures, "false"));
    try testing.expectEqualStrings("expected `true` or `false`", checkValue(.font_nerd_symbols, "yes").?);
    try testing.expectEqual(@as(?[]const u8, null), checkValue(.mouse_right_click, "paste"));
    try testing.expectEqualStrings("expected `menu` or `paste`", checkValue(.mouse_right_click, "both").?);
    try testing.expectEqual(@as(?[]const u8, null), checkValue(.font_bold, "DejaVu Sans Mono"));
    try testing.expectEqual(@as(?[]const u8, null), checkValue(.font_bold, ""));
    try testing.expectEqualStrings("unbalanced quotes", checkValue(.font_italic, "\"x\"").?);
    try testing.expectEqualStrings("value contains a control character", checkValue(.font_bold_italic, "a\tb").?);
    try testing.expectEqualStrings("value is longer than 256 bytes", checkValue(.font_bold, "x" ** 257).?);
    try testing.expectEqual(@as(?[]const u8, null), checkValue(.font_fallbacks, "a, b"));
    try testing.expectEqualStrings("expected at most 8 comma-separated families", checkValue(.font_fallbacks, "a,b,c,d,e,f,g,h,i").?);
    try testing.expect(checkValue(.keybind, "ctrl+a=tab.new") != null);
    // Every accepted value is accepted by the parser too, written the way the editor writes it.
    for ([_]struct { key: Key, value: []const u8 }{
        .{ .key = .font_size, .value = "13.5" },
        .{ .key = .scratchpad_size, .value = "40%" },
        .{ .key = .font_bold, .value = "" },
        .{ .key = .font_fallbacks, .value = "a, b" },
    }) |case| {
        const document = try setDocumentValue(testing.allocator, "", case.key, case.value);
        defer testing.allocator.free(document);
        var parsed = try parse(testing.allocator, document, null);
        defer parsed.deinit();
        try testing.expect(!parsed.hasDiagnostics());
    }
}

test "rewriting an action's keybinds drops its old lines, keeps the rest and appends the new ones" {
    const original =
        "# my keys\n" ++
        "keybind = ctrl+shift+p=unbind\n" ++
        "keybind = ctrl+alt+p=palette.open\n" ++
        "font.size = 13\n" ++
        "# keybind = ctrl+q=palette.open\n" ++
        "keybind = ctrl+alt+t=tab.new\n" ++
        "  keybind = alt+p = palette.open  \r\n" ++
        "keybind = ctrl+alt+k=unbind\n" ++
        "keybind = f5=pane.split:right\n";
    const edited = try setActionKeybinds(testing.allocator, original, "palette.open", &.{"Ctrl+Alt+K"}, "ctrl+alt+k");
    defer testing.allocator.free(edited);
    try testing.expectEqualStrings(
        "# my keys\n" ++
            "keybind = ctrl+shift+p=unbind\n" ++
            "font.size = 13\n" ++
            "# keybind = ctrl+q=palette.open\n" ++
            "keybind = ctrl+alt+t=tab.new\n" ++
            "keybind = f5=pane.split:right\n" ++
            "keybind = Ctrl+Alt+K=unbind\n" ++
            "keybind = ctrl+alt+k=palette.open\n",
        edited,
    );
    var parsed = try parse(testing.allocator, edited, null);
    defer parsed.deinit();
    try testing.expect(!parsed.hasDiagnostics());
    const last = parsed.keybinds.items[parsed.keybinds.items.len - 1];
    try testing.expectEqualStrings("ctrl+alt+k", last.chord);
    try testing.expectEqualStrings("palette.open", last.action.?);

    // Applying it again changes nothing; an action with an argument is matched by its name.
    const again = try setActionKeybinds(testing.allocator, edited, "palette.open", &.{"Ctrl+Alt+K"}, "ctrl+alt+k");
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(edited, again);
    const split = try setActionKeybinds(testing.allocator, original, "pane.split", &.{}, null);
    defer testing.allocator.free(split);
    try testing.expect(std.mem.indexOf(u8, split, "pane.split") == null);
    try testing.expect(std.mem.indexOf(u8, split, "keybind = ctrl+alt+p=palette.open\n") != null);

    // Clearing to unbound writes only the unbind lines; a file without a final newline gets one.
    const cleared = try setActionKeybinds(testing.allocator, "font.size = 13", "tab.new", &.{ "ctrl+shift+t", "f9" }, null);
    defer testing.allocator.free(cleared);
    try testing.expectEqualStrings("font.size = 13\nkeybind = ctrl+shift+t=unbind\nkeybind = f9=unbind\n", cleared);

    try testing.expectError(error.InvalidValue, setActionKeybinds(testing.allocator, "", "Bad Action", &.{}, "f5"));
    try testing.expectError(error.InvalidValue, setActionKeybinds(testing.allocator, "", "tab.new", &.{}, "ctrl+="));
    try testing.expectError(error.InvalidValue, setActionKeybinds(testing.allocator, "", "tab.new", &.{"a\nb"}, null));
    try testing.expectError(error.InvalidValue, setActionKeybinds(testing.allocator, "", "tab.new", &.{}, ""));
}

test "writing an action's keybinds creates the file from the defaults and edits it in place" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/conduit/config", .{tmp.sub_path[0..]});
    try writeActionKeybinds(testing.io, testing.allocator, path, "palette.open", &.{"ctrl+shift+p"}, "ctrl+alt+k");
    var buffer: [8192]u8 = undefined;
    const written = try Io.Dir.cwd().readFile(testing.io, path, &buffer);
    try testing.expect(std.mem.startsWith(u8, written, defaults_document));
    try testing.expect(std.mem.endsWith(u8, written, "keybind = ctrl+shift+p=unbind\nkeybind = ctrl+alt+k=palette.open\n"));
    try writeActionKeybinds(testing.io, testing.allocator, path, "palette.open", &.{"ctrl+shift+p"}, "ctrl+alt+j");
    const rewritten = try Io.Dir.cwd().readFile(testing.io, path, &buffer);
    try testing.expectEqualStrings(defaults_document ++ "keybind = ctrl+shift+p=unbind\nkeybind = ctrl+alt+j=palette.open\n", rewritten);
}

const WakeProbe = struct {
    event: Io.Event = .unset,
    count: std.atomic.Value(u32) = .init(0),

    fn wake(context: *anyopaque) void {
        const self: *WakeProbe = @ptrCast(@alignCast(context));
        _ = self.count.fetchAdd(1, .acq_rel);
        self.event.set(testing.io);
    }

    fn waitForWake(self: *WakeProbe) !void {
        self.event.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } }) catch {};
        if (!self.event.isSet()) return error.Timeout;
        self.event.reset();
    }
};

test "the watcher reports a write and a rename-replace, and stops promptly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try tmpConfigPath(&tmp, &path_buffer);

    var probe: WakeProbe = .{};
    const watcher = try Watcher.start(testing.allocator, testing.io, path, &probe, WakeProbe.wake);
    defer watcher.stop();
    try testing.expect(!watcher.takeChanged());

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config", .data = "scratchpad.size = 20\n" });
    try probe.waitForWake();
    try testing.expect(watcher.takeChanged());
    try testing.expect(!watcher.takeChanged());

    // The way many editors save: write a sibling, then rename it over the file.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.tmp", .data = "scratchpad.size = 30\n" });
    try tmp.dir.rename("config.tmp", tmp.dir, "config", testing.io);
    try probe.waitForWake();
    try testing.expect(watcher.takeChanged());

    // An unrelated file in the same directory is not a change to the settings.
    const before = probe.count.load(.acquire);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "unrelated", .data = "x" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config", .data = "scratchpad.size = 40\n" });
    try probe.waitForWake();
    try testing.expectEqual(before + 1, probe.count.load(.acquire));
}

test "a destination is one plain ssh argument with an optional port" {
    const plain = try parseDestination("dev-box");
    try testing.expectEqualStrings("dev-box", plain.target);
    try testing.expectEqual(@as(?u16, null), plain.port);
    const full = try parseDestination("deploy@build.example.com:2222");
    try testing.expectEqualStrings("deploy@build.example.com", full.target);
    try testing.expectEqual(@as(?u16, 2222), full.port);
    try testing.expectEqualStrings("build.example.com", destinationHost(full));
    const v6 = try parseDestination("me@[::1]:22");
    try testing.expectEqualStrings("me@[::1]", v6.target);
    try testing.expectEqual(@as(?u16, 22), v6.port);
    try testing.expectEqual(@as(?u16, null), (try parseDestination("::1")).port);

    for ([_][]const u8{
        "",      "-oProxyCommand=x", "user@-oX", "a b",        "host\ttab",  "a,b",
        "x;rm",  "host:",            "host:0",   "host:65536", "host:22x",   "@host",
        "user@", "a@b@c",            "it's",     "$(x)",       "host\nnext",
    }) |bad| {
        try testing.expectError(error.InvalidDestination, parseDestination(bad));
    }
}

test "profiles repeat by name and recent destinations are a bounded list" {
    var config = try parse(testing.allocator,
        \\remote.profile = work = deploy@build.example.com:2222
        \\remote.profile = box = dev-box
        \\remote.profile = work = ops@build.example.com
        \\remote.profile = broken
        \\remote.profile = bad = -oProxyCommand=x
        \\remote.recent = "dev-box, ops@a:2200"
        \\
    , null);
    defer config.deinit();
    const profiles = config.settings.remote_profiles;
    try testing.expectEqual(@as(usize, 2), profiles.len);
    try testing.expectEqualStrings("work", profiles[0].name);
    try testing.expectEqualStrings("ops@build.example.com", profiles[0].destination);
    try testing.expectEqualStrings("box", profiles[1].name);
    try testing.expectEqual(@as(usize, 2), config.diagnostics.items.len);
    try testing.expectEqual(@as(u32, 4), config.diagnostics.items[0].line);
    try testing.expectEqual(@as(u32, 5), config.diagnostics.items[1].line);
    try testing.expectEqual(@as(usize, 2), config.settings.remote_recent.len);
    try testing.expectEqualStrings("ops@a:2200", config.settings.remote_recent[1]);

    // Eleven recent destinations are refused; the previous list stands.
    var over = try parse(testing.allocator, "remote.recent = a,b,c,d,e,f,g,h,i,j,k\n", &config);
    defer over.deinit();
    try testing.expectEqual(@as(usize, 1), over.diagnostics.items.len);
    try testing.expectEqual(@as(usize, 2), over.settings.remote_recent.len);
    try testing.expectEqual(@as(?[]const u8, null), checkValue(.remote_recent, "a,b"));
    try testing.expect(checkValue(.remote_recent, "a b") != null);
    try testing.expect(checkValue(.remote_profile, "x = -y") != null);
}

test "the newest recent destination leads, without duplicates, ten at most" {
    var buffer: [1024]u8 = undefined;
    try testing.expectEqualStrings("b,a,c", try formatRecent(&buffer, "b", &.{ "a", "b", "c" }));
    const ten = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" };
    try testing.expectEqualStrings("new,1,2,3,4,5,6,7,8,9", try formatRecent(&buffer, "new", &ten));
    var tiny: [4]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, formatRecent(&tiny, "abc", &.{"def"}));

    const document = "# keep\nremote.recent = a\n";
    const edited = try setDocumentValue(testing.allocator, document, .remote_recent, "b,a");
    defer testing.allocator.free(edited);
    try testing.expectEqualStrings("# keep\nremote.recent = b,a\n", edited);
}

test "saving a profile replaces its own line, keeps the rest and never writes a second copy" {
    const document = "# comment\nremote.profile = work = old@host\nremote.profile = box = dev-box\nfont.size = 12";
    const once = try setDocumentProfile(testing.allocator, document, "work", "deploy@host:2222");
    defer testing.allocator.free(once);
    try testing.expectEqualStrings(
        "# comment\nremote.profile = box = dev-box\nfont.size = 12\nremote.profile = work = deploy@host:2222\n",
        once,
    );
    const twice = try setDocumentProfile(testing.allocator, once, "work", "deploy@host:2222");
    defer testing.allocator.free(twice);
    try testing.expectEqualStrings(once, twice);
    try testing.expectError(error.InvalidValue, setDocumentProfile(testing.allocator, document, "a=b", "host"));
    try testing.expectError(error.InvalidValue, setDocumentProfile(testing.allocator, document, "x", "-oX"));
    try testing.expectError(error.InvalidValue, setDocumentValue(testing.allocator, document, .remote_profile, "x = y"));

    var parsed = try parse(testing.allocator, twice, null);
    defer parsed.deinit();
    try testing.expect(!parsed.hasDiagnostics());
    try testing.expectEqual(@as(usize, 2), parsed.settings.remote_profiles.len);
}

test "sidebar.agents is a boolean that defaults on and keeps its value on a bad line" {
    var silent = try parse(testing.allocator, "", null);
    defer silent.deinit();
    try testing.expect(silent.settings.sidebar_agents);

    var off = try parse(testing.allocator, "sidebar.agents = false\n", null);
    defer off.deinit();
    try testing.expect(!off.hasDiagnostics());
    try testing.expect(!off.settings.sidebar_agents);

    var bad = try parse(testing.allocator, "sidebar.agents = hidden\n", &off);
    defer bad.deinit();
    try testing.expect(bad.hasDiagnostics());
    try testing.expect(!bad.settings.sidebar_agents);
    try testing.expectEqual(Key.sidebar_agents, Key.fromName("sidebar.agents").?);
    try testing.expectEqual(@as(?[]const u8, null), checkValue(.sidebar_agents, "true"));
    try testing.expect(checkValue(.sidebar_agents, "yes") != null);
}

test "sidebar.status_icons is dots or symbols, defaults to dots and keeps its value on a bad line" {
    var silent = try parse(testing.allocator, "", null);
    defer silent.deinit();
    try testing.expectEqual(StatusIcons.dots, silent.settings.sidebar_status_icons);

    var symbols = try parse(testing.allocator, "sidebar.status_icons = symbols\n", null);
    defer symbols.deinit();
    try testing.expect(!symbols.hasDiagnostics());
    try testing.expectEqual(StatusIcons.symbols, symbols.settings.sidebar_status_icons);

    var bad = try parse(testing.allocator, "sidebar.status_icons = Dots\n", &symbols);
    defer bad.deinit();
    try expectDiagnostic(&bad, 1, "sidebar.status_icons: expected `dots` or `symbols`");
    try testing.expectEqual(StatusIcons.symbols, bad.settings.sidebar_status_icons);

    try testing.expectEqual(Key.sidebar_status_icons, Key.fromName("sidebar.status_icons").?);
    try testing.expectEqual(@as(?[]const u8, null), checkValue(.sidebar_status_icons, "dots"));
    try testing.expectEqualStrings("expected `dots` or `symbols`", checkValue(.sidebar_status_icons, "circles").?);
    try testing.expectEqualStrings("symbols", StatusIcons.symbols.text());
}

test "restore.enabled and accessibility.enabled are booleans that default on" {
    var silent = try parse(testing.allocator, "", null);
    defer silent.deinit();
    try testing.expect(silent.settings.restore_enabled);
    try testing.expect(silent.settings.accessibility_enabled);

    var off = try parse(testing.allocator, "restore.enabled = false\naccessibility.enabled = false\n", null);
    defer off.deinit();
    try testing.expect(!off.hasDiagnostics());
    try testing.expect(!off.settings.restore_enabled);
    try testing.expect(!off.settings.accessibility_enabled);

    var bad = try parse(testing.allocator, "restore.enabled = sometimes\naccessibility.enabled = 2\n", null);
    defer bad.deinit();
    try testing.expect(bad.hasDiagnostics());
    try testing.expect(bad.settings.restore_enabled);
    try testing.expect(bad.settings.accessibility_enabled);
    try testing.expectEqual(@as(?[]const u8, null), checkValue(.restore_enabled, "false"));
    try testing.expect(checkValue(.accessibility_enabled, "yes") != null);
    try testing.expectEqualStrings("restore.enabled", Key.restore_enabled.name());
    try testing.expectEqual(Key.accessibility_enabled, Key.fromName("accessibility.enabled").?);
}

test "editor.command is one argv item that defaults to empty and refuses an option" {
    var silent = try parse(testing.allocator, "", null);
    defer silent.deinit();
    try testing.expectEqualStrings("", silent.settings.editor_command);

    var set = try parse(testing.allocator, "editor.command = \"/opt/VSCodium/bin/codium\"\n", null);
    defer set.deinit();
    try testing.expect(!set.hasDiagnostics());
    try testing.expectEqualStrings("/opt/VSCodium/bin/codium", set.settings.editor_command);

    var bad = try parse(testing.allocator, "editor.command = --disable-extensions\n", &set);
    defer bad.deinit();
    try testing.expect(bad.hasDiagnostics());
    try testing.expectEqualStrings("/opt/VSCodium/bin/codium", bad.settings.editor_command);

    try testing.expectEqual(Key.editor_command, Key.fromName("editor.command").?);
    try testing.expectEqual(@as(?[]const u8, null), checkValue(.editor_command, "codium"));
    try testing.expectEqual(@as(?[]const u8, null), checkValue(.editor_command, ""));
    try testing.expectEqualStrings("expected a command name or path, not an option", checkValue(.editor_command, "-r").?);
    try testing.expect(checkValue(.editor_command, "a\x07b") != null);
}

test "control.enabled is a boolean the session layer overrides and the build defaults" {
    var silent = try parse(testing.allocator, "", null);
    defer silent.deinit();
    try testing.expectEqual(@as(?bool, null), silent.settings.control_enabled);
    try testing.expectEqual(builtin.mode == .Debug, controlEnabled(null, silent.settings.control_enabled));

    var off = try parse(testing.allocator, "control.enabled = false\n", null);
    defer off.deinit();
    try testing.expect(!off.hasDiagnostics());
    try testing.expectEqual(@as(?bool, false), off.settings.control_enabled);
    try testing.expect(!controlEnabled(null, off.settings.control_enabled));
    try testing.expect(controlEnabled(true, off.settings.control_enabled));

    var on = try parse(testing.allocator, "control.enabled = true\n", null);
    defer on.deinit();
    try testing.expect(controlEnabled(null, on.settings.control_enabled));
    try testing.expect(!controlEnabled(false, on.settings.control_enabled));

    var bad = try parse(testing.allocator, "control.enabled = maybe\n", null);
    defer bad.deinit();
    try testing.expect(bad.hasDiagnostics());
    try testing.expectEqual(@as(?bool, null), bad.settings.control_enabled);
    try testing.expectEqual(@as(?[]const u8, null), checkValue(.control_enabled, "true"));
    try testing.expect(checkValue(.control_enabled, "yes") != null);
}

test "macos.option_as_alt parses its four spellings and rejects the rest" {
    try testing.expectEqual(OptionAsAlt.false, try OptionAsAlt.parse("false"));
    try testing.expectEqual(OptionAsAlt.true, try OptionAsAlt.parse("true"));
    try testing.expectEqual(OptionAsAlt.left, try OptionAsAlt.parse("left"));
    try testing.expectEqual(OptionAsAlt.right, try OptionAsAlt.parse("right"));
    for ([_][]const u8{ "", "True", "both", "only_left", "left ", "yes" }) |bad| {
        try testing.expectError(error.InvalidOptionAsAlt, OptionAsAlt.parse(bad));
    }
    for (std.enums.values(OptionAsAlt)) |value| {
        try testing.expectEqual(value, try OptionAsAlt.parse(value.text()));
    }
    try testing.expectEqual(Key.macos_option_as_alt, Key.fromName("macos.option_as_alt").?);
    _ = try Name.parse(OptionAsAlt.name.text());

    var config = try parse(testing.allocator, "macos.option_as_alt = right\n", null);
    defer config.deinit();
    try testing.expect(!config.hasDiagnostics());
    try testing.expectEqual(OptionAsAlt.right, config.settings.macos_option_as_alt);

    // A bad value is a numbered diagnostic, and the previous value stands.
    var bad = try parse(testing.allocator, "macos.option_as_alt = both\n", &config);
    defer bad.deinit();
    try expectDiagnostic(&bad, 1, "macos.option_as_alt: expected `true`, `false`, `left` or `right`");
    try testing.expectEqual(OptionAsAlt.right, bad.settings.macos_option_as_alt);
    try testing.expectEqualStrings("expected `true`, `false`, `left` or `right`", checkValue(.macos_option_as_alt, "Left").?);
    try testing.expectEqual(@as(?[]const u8, null), checkValue(.macos_option_as_alt, "left"));

    // Silent file: the built-in value, the macOS convention.
    var empty = try parse(testing.allocator, "", null);
    defer empty.deinit();
    try testing.expectEqual(OptionAsAlt.false, empty.settings.macos_option_as_alt);
}

// ---------------------------------------------------------------------------
// Shell profile tests (TASK-46)
// ---------------------------------------------------------------------------

test "shell profiles parse with quoting, attributes in any order, and a default" {
    const text =
        \\profile.alpha.env = PROFILE_VAR=alpha value
        \\profile = alpha = sh -c 'echo "A:$PROFILE_VAR"; exec sh'
        \\profile.alpha.env = SECOND=2
        \\profile.alpha.cwd = "/tmp/a dir"
        \\profile = beta = /bin/bash
        \\profile.beta.login = true
        \\profile = win = "C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo "a \"quoted\" word"
        \\shell = beta
    ;
    var config = try parse(testing.allocator, text, null);
    defer config.deinit();
    try testing.expect(!config.hasDiagnostics());
    const profiles = config.settings.shell_profiles;
    try testing.expectEqual(@as(usize, 3), profiles.len);

    try testing.expectEqualStrings("alpha", profiles[0].name);
    try testing.expectEqual(@as(usize, 3), profiles[0].argv.len);
    try testing.expectEqualStrings("sh", profiles[0].argv[0]);
    try testing.expectEqualStrings("-c", profiles[0].argv[1]);
    try testing.expectEqualStrings("echo \"A:$PROFILE_VAR\"; exec sh", profiles[0].argv[2]);
    try testing.expectEqual(@as(usize, 2), profiles[0].env.len);
    try testing.expectEqualStrings("PROFILE_VAR=alpha value", profiles[0].env[0]);
    try testing.expectEqualStrings("SECOND=2", profiles[0].env[1]);
    try testing.expectEqualStrings("/tmp/a dir", profiles[0].cwd.?);
    try testing.expect(!profiles[0].login);

    try testing.expectEqualStrings("beta", profiles[1].name);
    try testing.expect(profiles[1].login);
    try testing.expectEqual(@as(?[]const u8, null), profiles[1].cwd);

    // A backslash outside `\"` and `\\` is an ordinary byte: Windows paths need no doubling.
    try testing.expectEqualStrings("C:\\Program Files\\PowerShell\\7\\pwsh.exe", profiles[2].argv[0]);
    try testing.expectEqualStrings("-NoLogo", profiles[2].argv[1]);
    try testing.expectEqualStrings("a \"quoted\" word", profiles[2].argv[2]);

    try testing.expectEqualStrings("beta", config.settings.shell);
    try testing.expectEqual(@as(u32, 8), config.lines.get(.shell));
    try testing.expectEqualStrings("beta", findShellProfile(profiles, "beta").?.name);
    try testing.expectEqual(@as(?ShellProfile, null), findShellProfile(profiles, "gamma"));
}

test "a later profile line replaces its command in place and profiles are bounded" {
    var config = try parse(testing.allocator,
        \\profile = one = sh
        \\profile = two = bash
        \\profile = one = zsh -i
    , null);
    defer config.deinit();
    try testing.expect(!config.hasDiagnostics());
    try testing.expectEqual(@as(usize, 2), config.settings.shell_profiles.len);
    try testing.expectEqualStrings("one", config.settings.shell_profiles[0].name);
    try testing.expectEqualStrings("zsh", config.settings.shell_profiles[0].argv[0]);
    try testing.expectEqualStrings("-i", config.settings.shell_profiles[0].argv[1]);

    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(testing.allocator);
    for (0..max_shell_profiles + 1) |index| {
        var line: [64]u8 = undefined;
        try many.appendSlice(testing.allocator, try std.fmt.bufPrint(&line, "profile = p{d} = sh\n", .{index}));
    }
    var full = try parse(testing.allocator, many.items, null);
    defer full.deinit();
    try testing.expectEqual(max_shell_profiles, full.settings.shell_profiles.len);
    try testing.expectEqual(@as(u32, max_shell_profiles + 1), full.firstDiagnostic().?.line);
    try testing.expectEqualStrings("profile: more than 32 shell profiles; the rest are ignored", full.firstDiagnostic().?.message);
}

test "malformed profile lines are reported on their own line and the rest apply" {
    const text =
        \\profile = good = sh
        \\profile = bad name = sh
        \\profile = open = sh -c 'unterminated
        \\profile = empty =
        \\profile.ghost.env = A=1
        \\profile.good.env = 1BAD=x
        \\profile.good.login = yes
        \\profile.good.cwd = "unbalanced
        \\shell = nobody
        \\profile = nameless
    ;
    var config = try parse(testing.allocator, text, null);
    defer config.deinit();
    try testing.expectEqual(@as(usize, 1), config.settings.shell_profiles.len);
    try testing.expectEqualStrings("good", config.settings.shell_profiles[0].name);
    try testing.expectEqual(@as(usize, 0), config.settings.shell_profiles[0].env.len);
    try testing.expect(!config.settings.shell_profiles[0].login);
    const expected = [_]struct { line: u32, message: []const u8 }{
        .{ .line = 2, .message = "profile: expected a profile name: letters, digits, `-` and `_`" },
        .{ .line = 3, .message = "profile: unbalanced quotes" },
        .{ .line = 4, .message = "profile: expected `<name> = <command> [arguments...]`" },
        .{ .line = 5, .message = "profile.ghost.env: no profile with that name" },
        .{ .line = 6, .message = "profile.good.env: expected `NAME=value`" },
        .{ .line = 7, .message = "profile.good.login: expected `true` or `false`" },
        .{ .line = 8, .message = "profile.good.cwd: unbalanced quotes" },
        .{ .line = 9, .message = "shell: no profile with that name" },
        .{ .line = 10, .message = "profile: expected `<name> = <command> [arguments...]`" },
    };
    try testing.expectEqual(expected.len, config.diagnostics.items.len);
    for (expected) |want| {
        var found = false;
        for (config.diagnostics.items) |diagnostic| {
            if (diagnostic.line == want.line and std.mem.eql(u8, diagnostic.message, want.message)) found = true;
        }
        if (!found) {
            std.log.err("missing diagnostic {d}: {s}", .{ want.line, want.message });
            return error.TestExpectedDiagnostic;
        }
    }
    // The value stays even when it names nothing; the app falls back.
    try testing.expectEqualStrings("nobody", config.settings.shell);
    // A built-in profile name is not reported.
    var builtin_name = try parse(testing.allocator, "shell = login\n", null);
    defer builtin_name.deinit();
    try testing.expect(!builtin_name.hasDiagnostics());
}

test "when every profile line is rejected the previous profiles stand whole" {
    var first = try parse(testing.allocator,
        \\profile = keep = sh
        \\profile.keep.env = A=1
        \\shell = keep
    , null);
    var second = try parse(testing.allocator,
        \\profile = keep = 'broken
        \\profile.keep.env = B=2
        \\shell = "bad name"
    , &first);
    defer second.deinit();
    // The kept values were copied: they outlive the config they came from.
    first.deinit();
    try testing.expectEqual(@as(usize, 1), second.settings.shell_profiles.len);
    try testing.expectEqualStrings("keep", second.settings.shell_profiles[0].name);
    try testing.expectEqualStrings("sh", second.settings.shell_profiles[0].argv[0]);
    try testing.expectEqual(@as(usize, 1), second.settings.shell_profiles[0].env.len);
    try testing.expectEqualStrings("A=1", second.settings.shell_profiles[0].env[0]);
    try testing.expectEqualStrings("keep", second.settings.shell);
}

test "command lines split shell style and refuse what cannot be one" {
    var storage: [max_line_bytes]u8 = undefined;
    var words: [4][]const u8 = undefined;
    const split = try splitCommandLine("  a 'b c'd \"e \\\\ \\\" f\\g\"  ", &storage, &words);
    try testing.expectEqual(@as(usize, 3), split.len);
    try testing.expectEqualStrings("a", split[0]);
    try testing.expectEqualStrings("b cd", split[1]);
    try testing.expectEqualStrings("e \\ \" f\\g", split[2]);
    try testing.expectError(error.ShellProfileShape, splitCommandLine("   ", &storage, &words));
    try testing.expectError(error.ShellProfileShape, splitCommandLine("'' x", &storage, &words));
    try testing.expectError(error.ShellProfileShape, splitCommandLine("a b c d e", &storage, &words));
    try testing.expectError(error.Unquoted, splitCommandLine("a \"b", &storage, &words));
    try testing.expectError(error.ControlCharacter, splitCommandLine("a\x07", &storage, &words));
    var short: [2]u8 = undefined;
    try testing.expectError(error.TooLong, splitCommandLine("abc", &short, &words));

    try testing.expect(validShellProfileName("pwsh-7_x"));
    try testing.expect(!validShellProfileName("has space"));
    try testing.expect(!validShellProfileName("dot.ted"));
    try testing.expect(!validShellProfileName(""));
    try testing.expect(validEnvEntry("_A1=x=y"));
    try testing.expect(validEnvEntry("EMPTY="));
    try testing.expect(!validEnvEntry("NOVALUE"));
    try testing.expect(!validEnvEntry("A-B=1"));
}

test "a typed shell or profile value is checked the way its file line would be" {
    try testing.expectEqual(@as(?[]const u8, null), checkValue(.shell, "pwsh"));
    try testing.expectEqual(@as(?[]const u8, null), checkValue(.shell, ""));
    try testing.expectEqualStrings("expected a profile name: letters, digits, `-` and `_`", checkValue(.shell, "two words").?);
    try testing.expectEqual(@as(?[]const u8, null), checkValue(.profile, "x = sh -l"));
    try testing.expect(checkValue(.profile, "x =") != null);
    // A profile repeats, so it is never set as one value.
    try testing.expectError(error.InvalidValue, setDocumentValue(testing.allocator, "", .profile, "x = sh"));
    const edited = try setDocumentValue(testing.allocator, "# a\n", .shell, "alpha");
    defer testing.allocator.free(edited);
    try testing.expectEqualStrings("# a\nshell = alpha\n", edited);
}
