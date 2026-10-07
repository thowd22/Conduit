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
    theme,
    scratchpad_size,
    scratchpad_large_size,
    mouse_right_click,
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
            .theme => "theme",
            .scratchpad_size => "scratchpad.size",
            .scratchpad_large_size => "scratchpad.large_size",
            .mouse_right_click => RightClick.name.text(),
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
    /// Style-face families. Empty derives the style from the primary family. Validated and
    /// stored; the font manager consumes them once it can load configured style faces.
    font_bold: []const u8 = "",
    font_italic: []const u8 = "",
    font_bold_italic: []const u8 = "",
    font_size: f32 = default_font_points,
    /// Stored for the font manager; `docs/config.md` says which keys take effect today.
    font_ligatures: bool = true,
    font_nerd_symbols: bool = true,
    /// The colour scheme: empty for Conduit's default, a bundled or user theme name, or
    /// `auto:<dark>,<light>`. `app` resolves it through `theme`; an unknown name is reported there.
    theme: []const u8 = "",
    /// The two scratchpad presentations, in percent of the window height.
    scratchpad_size: u8 = 50,
    scratchpad_large_size: u8 = 90,
    /// The file layer of `mouse.right_click`; null when the file is silent.
    right_click: ?RightClick = null,
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
            .theme => to.theme = try self.dupe(from.theme),
            .scratchpad_size => to.scratchpad_size = from.scratchpad_size,
            .scratchpad_large_size => to.scratchpad_large_size = from.scratchpad_large_size,
            .mouse_right_click => to.right_click = from.right_click,
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
    NotPercent,
    KeybindShape,
    KeybindAction,
    KeybindArgument,
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
        error.NotPercent => "expected a whole percentage from 10 to 100",
        error.KeybindShape => "expected `<chord>=<action>[:<argument>]`",
        error.KeybindAction => "invalid action name",
        error.KeybindArgument => "invalid argument",
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
        .scratchpad_size => settings.scratchpad_size = try parsePercent(value),
        .scratchpad_large_size => settings.scratchpad_large_size = try parsePercent(value),
        .mouse_right_click => settings.right_click = RightClick.parse(value) catch return error.NotRightClick,
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
    if (key == .keybind) return error.InvalidValue;
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
    try testing.expectEqualStrings("solarized", settings.theme);
    try testing.expectEqual(@as(u8, 30), settings.scratchpad_size);
    try testing.expectEqual(@as(u8, 100), settings.scratchpad_large_size);
    try testing.expectEqual(RightClick.paste, settings.right_click.?);
    try testing.expectEqual(@as(u32, 5), config.lines.get(.font_size));
    try testing.expectEqual(@as(usize, 3), config.keybinds.items.len);
    try testing.expectEqualStrings("ctrl+shift+t", config.keybinds.items[0].chord);
    try testing.expectEqualStrings("tab.new", config.keybinds.items[0].action.?);
    try testing.expectEqual(@as(?[]const u8, null), config.keybinds.items[0].argument);
    try testing.expectEqual(@as(u32, 12), config.keybinds.items[0].line);
    try testing.expectEqualStrings("alt+1", config.keybinds.items[1].chord);
    try testing.expectEqualStrings("tab.goto", config.keybinds.items[1].action.?);
    try testing.expectEqualStrings("1", config.keybinds.items[1].argument.?);
    try testing.expectEqualStrings("ctrl+shift+w", config.keybinds.items[2].chord);
    try testing.expectEqual(@as(?[]const u8, null), config.keybinds.items[2].action);
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
    // Every key appears in the document, keybind four times.
    try testing.expectEqual(std.enums.values(Key).len - 1 + 4, settings_lines);

    var config = try parse(testing.allocator, uncommented.items, null);
    defer config.deinit();
    try testing.expect(!config.hasDiagnostics());
    const built_in: Settings = .{};
    try testing.expectEqualStrings("", config.settings.font_family.?);
    try testing.expectEqual(built_in.font_size, config.settings.font_size);
    try testing.expectEqual(built_in.font_ligatures, config.settings.font_ligatures);
    try testing.expectEqual(built_in.font_nerd_symbols, config.settings.font_nerd_symbols);
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
