//! Conduit's colour model: the palette both renderers draw from.
//!
//! `theme` owns the terminal palette and the UI colours that `ui` and `render`
//! consume. It draws nothing, and it is the only place a colour may enter
//! Conduit — two renderers, one palette (P6).
//!
//! TASK-38 adds the engine on top of the TASK-4 model: a `Scheme` is what a
//! colour-scheme author writes (16 ANSI colours, foreground, background,
//! cursor, selection), `derive` maps it onto every `Role` Conduit paints, the
//! bundled schemes live in `theme_schemes.zig`, `parseGhostty` reads a user's
//! Ghostty-format theme file, and `Selection` is the parsed `theme` setting.
//!
//! It depends on nothing but `std` (the build also offers `config`, which this
//! module does not need). It allocates nothing: a scheme and a palette are
//! fixed-size values, and the parser reports into a fixed-size result.

const std = @import("std");
const schemes = @import("theme_schemes.zig");

/// The log scope for palette diagnostics. Theme names may be logged; colours
/// and file contents are not.
pub const log = std.log.scoped(.theme);

/// How many of the slots are ANSI roles: the 8 normal colours and the 8
/// bright ones.
pub const ansi_slot_count = 16;

/// An 8-bit-per-channel colour, the form a palette stores. Alpha is part of
/// the value because a role may be drawn over the background; it is 255 for
/// every opaque role.
///
/// This is the palette's colour, not the GPU's. `render` owns the RGBA8 format
/// of the framebuffer and of a captured screenshot, and neither module may
/// import the other, so `app` is where the two are bridged.
pub const Color = struct {
    /// Red, 0 is black and 255 is full intensity.
    r: u8,
    /// Green, on the same scale as `r`.
    g: u8,
    /// Blue, on the same scale as `r`.
    b: u8,
    /// Coverage over what is behind the colour. Defaults to opaque, because
    /// almost every role is: only a state Conduit marks on purpose is drawn
    /// translucent.
    a: u8 = 255,

    /// An opaque colour from `0xRRGGBB`, the way scheme files spell colours.
    pub fn hex(value: u24) Color {
        return .{
            .r = @truncate(value >> 16),
            .g = @truncate(value >> 8),
            .b = @truncate(value),
        };
    }

    /// Whether two colours are the same value, alpha included.
    pub fn eql(a: Color, b: Color) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
    }
};

/// A colour role: a named thing Conduit paints, never a colour value.
///
/// The first 16 are the ANSI slots in the order every terminal palette is
/// specified — the 8 normal colours, then the 8 bright ones — so a role's slot
/// is the index an SGR colour parameter refers to. After them come the
/// terminal's named colours, then the chrome roles `derive` computes from the
/// scheme so the UI stays readable on dark and light schemes alike.
pub const Role = enum {
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,
    /// The window's and the terminal's default background.
    background,
    /// The terminal's default text colour.
    foreground,
    /// Selected text and the selected or hovered UI row.
    selection,
    /// The focus and link colour: focused rows, underlines, input carets.
    accent,
    /// The terminal cursor.
    cursor,
    /// Emphasised UI text (labels, the active row) on `background`.
    strong,
    /// De-emphasised UI text, hints and dividers.
    muted,
    /// Panel and dialog borders.
    border,
    /// Titles and warnings that must catch the eye.
    attention,
    /// Errors.
    danger,
    /// Text drawn on an `accent` background.
    on_accent,
    /// The background of a text input field.
    field,

    /// The palette slot this role occupies, 0 through `role_count - 1`.
    pub fn slot(self: Role) u8 {
        return @intFromEnum(self);
    }

    /// Whether the role is one of the 16 ANSI slots. The roles above them are
    /// named colours, not SGR indices, and asking for their slot as a colour
    /// parameter would send the terminal somewhere Conduit never meant.
    pub fn isAnsi(self: Role) bool {
        return self.slot() < ansi_slot_count;
    }
};

/// How many slots a `Palette` has: one per `Role`.
pub const role_count = @typeInfo(Role).@"enum".fields.len;

/// A resolved palette: one colour per role, stored in role order so a lookup
/// is an array index rather than a search.
///
/// Sized, not dynamic: every role is known at compile time, so building a
/// palette costs no allocation and cannot fail part-way.
pub const Palette = struct {
    /// The colours, indexed by `Role.slot`.
    colors: [role_count]Color,

    /// The colour of `role`. Every role has a slot, so this cannot fail.
    pub fn get(self: Palette, role: Role) Color {
        return self.colors[role.slot()];
    }

    fn set(self: *Palette, role: Role, color: Color) void {
        self.colors[role.slot()] = color;
    }

    /// Whether every role has the same colour in both palettes.
    pub fn eql(a: Palette, b: Palette) bool {
        for (a.colors, b.colors) |one, other| {
            if (!one.eql(other)) return false;
        }
        return true;
    }
};

// ---------------------------------------------------------------------------
// Schemes
// ---------------------------------------------------------------------------

/// Whether a scheme is meant for a dark or a light background.
pub const Kind = enum { dark, light };

/// A colour scheme as its author writes it: the terminal's colours and
/// nothing about Conduit's UI, which `derive` computes.
pub const Scheme = struct {
    /// The 16 ANSI colours in SGR order.
    ansi: [ansi_slot_count]Color,
    foreground: Color,
    background: Color,
    cursor: Color,
    /// The colour of the glyph under a block cursor. Stored; the grid draws
    /// the cell's own background colour there today.
    cursor_text: ?Color = null,
    selection_background: Color,
    /// The text colour a scheme wants under a selection. Stored; the grid
    /// keeps each cell's own foreground, which is why `derive` tones a
    /// selection that would hide that foreground.
    selection_foreground: ?Color = null,

    /// Dark when the background is closer to black than to white.
    pub fn kind(self: Scheme) Kind {
        const lum = luminance(self.background);
        return if (contrastFromLuminance(lum, 0) >= contrastFromLuminance(lum, 1)) .light else .dark;
    }

    /// Whether every colour of the two schemes is the same.
    pub fn eql(a: Scheme, b: Scheme) bool {
        for (a.ansi, b.ansi) |one, other| {
            if (!one.eql(other)) return false;
        }
        return a.foreground.eql(b.foreground) and a.background.eql(b.background) and
            a.cursor.eql(b.cursor) and optionalEql(a.cursor_text, b.cursor_text) and
            a.selection_background.eql(b.selection_background) and
            optionalEql(a.selection_foreground, b.selection_foreground);
    }
};

fn optionalEql(a: ?Color, b: ?Color) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

/// A scheme Conduit ships: a stable `id` (what `theme = ...` and the picker
/// write), a display `label` and the colours.
pub const Bundled = struct {
    id: []const u8,
    label: []const u8,
    scheme: Scheme,
};

/// Every bundled scheme. `conduit-dark` is first.
pub const bundled: []const Bundled = &schemes.all;

/// Conduit's own default scheme, what an empty `theme` setting means.
pub const conduit_dark: Scheme = schemes.conduit_dark;

/// The id of `conduit_dark`.
pub const default_id = "conduit-dark";

/// Whether two theme names refer to the same theme: ASCII case, spaces,
/// hyphens and underscores are ignored, so `Tokyo Night`, `tokyo-night` and
/// `TokyoNight` are one name.
pub fn sameName(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and isNameSeparator(a[i])) i += 1;
        while (j < b.len and isNameSeparator(b[j])) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[j])) return false;
        i += 1;
        j += 1;
    }
}

fn isNameSeparator(byte: u8) bool {
    return byte == ' ' or byte == '-' or byte == '_';
}

/// The bundled scheme `name` refers to by id or label, or null.
pub fn findBundled(name: []const u8) ?*const Bundled {
    for (bundled) |*entry| {
        if (sameName(entry.id, name) or sameName(entry.label, name)) return entry;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Contrast
// ---------------------------------------------------------------------------

/// WCAG relative luminance, 0 for black and 1 for white.
pub fn luminance(color: Color) f32 {
    return 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b);
}

fn linear(channel: u8) f32 {
    const value = @as(f32, @floatFromInt(channel)) / 255.0;
    if (value <= 0.04045) return value / 12.92;
    return std.math.pow(f32, (value + 0.055) / 1.055, 2.4);
}

fn contrastFromLuminance(a: f32, b: f32) f32 {
    const light = @max(a, b);
    const dark = @min(a, b);
    return (light + 0.05) / (dark + 0.05);
}

/// The WCAG contrast ratio of two colours, 1 (identical) to 21.
pub fn contrast(a: Color, b: Color) f32 {
    return contrastFromLuminance(luminance(a), luminance(b));
}

/// `a` weighted `weight` out of `out_of`, the rest `b`. Deterministic integer
/// arithmetic, so a derived palette is the same on every machine.
pub fn mix(a: Color, b: Color, weight: u8, out_of: u8) Color {
    const w: u16 = weight;
    const total: u16 = out_of;
    return .{
        .r = @intCast((@as(u16, a.r) * w + @as(u16, b.r) * (total - w) + total / 2) / total),
        .g = @intCast((@as(u16, a.g) * w + @as(u16, b.g) * (total - w) + total / 2) / total),
        .b = @intCast((@as(u16, a.b) * w + @as(u16, b.b) * (total - w) + total / 2) / total),
    };
}

/// Black or white, whichever reads better on `against`. Every colour has at
/// least 4.58:1 contrast with one of them.
fn extreme(against: Color) Color {
    const black = Color.hex(0x000000);
    const white = Color.hex(0xffffff);
    return if (contrast(black, against) >= contrast(white, against)) black else white;
}

fn firstReadable(candidates: []const Color, against: Color, minimum: f32) ?Color {
    for (candidates) |candidate| {
        if (contrast(candidate, against) >= minimum) return candidate;
    }
    return null;
}

fn readable(candidates: []const Color, against: Color, minimum: f32) Color {
    return firstReadable(candidates, against, minimum) orelse extreme(against);
}

/// The contrast every derived text role keeps with the surface it is drawn
/// on (WCAG AA for body text).
pub const text_contrast: f32 = 4.5;
/// The contrast the coloured chrome roles (accent, border-like colours,
/// attention, danger) keep with the background.
pub const chrome_contrast: f32 = 3.0;
/// The floor for `muted`: visibly there, deliberately quiet.
pub const muted_contrast: f32 = 1.8;

/// Map a scheme onto every role Conduit paints.
///
/// The terminal roles are the scheme's own. The chrome roles prefer the ANSI
/// colour a terminal UI conventionally uses for that job and fall back, one
/// rule at a time, when that colour would be unreadable on this scheme's
/// background (bright white text on a light scheme, say):
///
/// - `strong`: bright white, else the foreground, else ANSI black, else black
///   or white.
/// - `muted`: bright black, else the foreground mixed halfway to the background.
/// - `accent`: bright blue, else blue, else the foreground.
/// - `border`: bright blue, else blue (at 2:1), else `muted`.
/// - `attention`: bright yellow, else yellow, else the foreground.
/// - `danger`: bright red, else red, else the foreground.
/// - `on_accent`: black, else the background, else bright white, else the
///   foreground, whichever first reads at 4.5:1 on `accent`.
/// - `field`: ANSI black when both the foreground and `strong` read on it,
///   else the background with an eighth of the foreground mixed in.
/// - `selection`: the scheme's selection colour when the foreground and
///   `strong` both read on it at 3:1, else that colour mixed a quarter into the
///   background, because the grid keeps a selected cell's own foreground.
///
/// For `conduit-dark` every rule takes its first choice, which is exactly the
/// palette Conduit drew with before themes existed.
pub fn derive(scheme: Scheme) Palette {
    @setEvalBranchQuota(100_000);
    var palette: Palette = undefined;
    for (scheme.ansi, 0..) |color, slot| palette.colors[slot] = color;
    const a = scheme.ansi;
    const bg = scheme.background;
    const fg = scheme.foreground;
    palette.set(.background, bg);
    palette.set(.foreground, fg);
    palette.set(.cursor, scheme.cursor);

    const strong = readable(&.{ a[15], fg, a[0] }, bg, text_contrast);
    const muted = firstReadable(&.{a[8]}, bg, muted_contrast) orelse mix(fg, bg, 1, 2);
    const accent = readable(&.{ a[12], a[4], fg }, bg, chrome_contrast);
    palette.set(.strong, strong);
    palette.set(.muted, muted);
    palette.set(.accent, accent);
    palette.set(.border, firstReadable(&.{ a[12], a[4] }, bg, 2.0) orelse muted);
    palette.set(.attention, readable(&.{ a[11], a[3], fg }, bg, chrome_contrast));
    palette.set(.danger, readable(&.{ a[9], a[1], fg }, bg, chrome_contrast));
    palette.set(.on_accent, readable(&.{ a[0], bg, a[15], fg }, accent, text_contrast));
    const field = if (contrast(fg, a[0]) >= text_contrast and contrast(strong, a[0]) >= text_contrast)
        a[0]
    else
        mix(fg, bg, 1, 8);
    palette.set(.field, field);
    const selection = scheme.selection_background;
    palette.set(.selection, if (@min(contrast(fg, selection), contrast(strong, selection)) >= chrome_contrast)
        selection
    else
        mix(selection, bg, 1, 4));
    return palette;
}

// ---------------------------------------------------------------------------
// Ghostty theme files
// ---------------------------------------------------------------------------

/// The largest theme file read. Real ones are under 1 KiB.
pub const max_file_bytes: usize = 64 * 1024;
/// The longest line considered.
pub const max_line_bytes: usize = 1024;
/// How many problems one parse records; the rest are counted.
pub const max_diagnostics: usize = 8;

/// One problem in a theme file. `line` is 1-based, 0 for the whole file.
/// `message` is static text and never repeats the file's content.
pub const Diagnostic = struct {
    line: u32,
    message: []const u8,
};

/// What `parseGhostty` produced: always a usable scheme, plus what was wrong.
pub const Parsed = struct {
    scheme: Scheme,
    diagnostic_storage: [max_diagnostics]Diagnostic = undefined,
    diagnostic_count: usize = 0,
    /// Problems beyond `max_diagnostics`.
    dropped: usize = 0,

    /// The recorded problems, first line first.
    pub fn diagnostics(self: *const Parsed) []const Diagnostic {
        return self.diagnostic_storage[0..self.diagnostic_count];
    }

    fn add(self: *Parsed, line: u32, message: []const u8) void {
        if (self.diagnostic_count == max_diagnostics) {
            self.dropped += 1;
            return;
        }
        self.diagnostic_storage[self.diagnostic_count] = .{ .line = line, .message = message };
        self.diagnostic_count += 1;
    }
};

/// Parse a theme in Ghostty's theme file format: `key = value` lines, `#`
/// comment lines and blank lines. The keys are `palette = N=#rrggbb` (N from 0
/// to 15), `background`, `foreground`, `cursor-color`, `cursor-text`,
/// `selection-background` and `selection-foreground`; a colour is `#rrggbb` or
/// `rrggbb`, optionally in double quotes. Anything else is reported and
/// skipped. A colour the file does not set comes from `conduit-dark`, so a
/// partial file is still a whole scheme. Never fails.
pub fn parseGhostty(text: []const u8) Parsed {
    var result: Parsed = .{ .scheme = conduit_dark };
    if (text.len > max_file_bytes) {
        result.add(0, "file is larger than 64 KiB");
        return result;
    }
    var body = text;
    if (std.mem.startsWith(u8, body, "\xEF\xBB\xBF")) body = body[3..];
    var line_number: u32 = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        line_number +|= 1;
        var line = raw;
        if (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len > max_line_bytes) {
            result.add(line_number, "line is longer than 1024 bytes");
            continue;
        }
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse {
            result.add(line_number, "expected `key = value`");
            continue;
        };
        const key = std.mem.trim(u8, trimmed[0..equals], " \t");
        const value = unquote(std.mem.trim(u8, trimmed[equals + 1 ..], " \t"));
        if (std.mem.eql(u8, key, "palette")) {
            const inner = std.mem.indexOfScalar(u8, value, '=') orelse {
                result.add(line_number, "palette: expected `N=#rrggbb`");
                continue;
            };
            const index = std.fmt.parseUnsigned(u8, std.mem.trim(u8, value[0..inner], " \t"), 10) catch {
                result.add(line_number, "palette: invalid index");
                continue;
            };
            if (index >= ansi_slot_count) {
                result.add(line_number, "palette: only entries 0 to 15 are used");
                continue;
            }
            const color = parseColor(std.mem.trim(u8, value[inner + 1 ..], " \t")) orelse {
                result.add(line_number, "palette: invalid colour");
                continue;
            };
            result.scheme.ansi[index] = color;
            continue;
        }
        const target: enum { background, foreground, cursor, cursor_text, selection, selection_text } =
            if (std.mem.eql(u8, key, "background"))
                .background
            else if (std.mem.eql(u8, key, "foreground"))
                .foreground
            else if (std.mem.eql(u8, key, "cursor-color"))
                .cursor
            else if (std.mem.eql(u8, key, "cursor-text"))
                .cursor_text
            else if (std.mem.eql(u8, key, "selection-background"))
                .selection
            else if (std.mem.eql(u8, key, "selection-foreground"))
                .selection_text
            else {
                result.add(line_number, "unknown key");
                continue;
            };
        const color = parseColor(value) orelse {
            result.add(line_number, "invalid colour");
            continue;
        };
        switch (target) {
            .background => result.scheme.background = color,
            .foreground => result.scheme.foreground = color,
            .cursor => result.scheme.cursor = color,
            .cursor_text => result.scheme.cursor_text = color,
            .selection => result.scheme.selection_background = color,
            .selection_text => result.scheme.selection_foreground = color,
        }
    }
    return result;
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') return value[1 .. value.len - 1];
    return value;
}

/// `#rrggbb` or `rrggbb`, hex digits in either case.
pub fn parseColor(text: []const u8) ?Color {
    const digits = if (text.len != 0 and text[0] == '#') text[1..] else text;
    if (digits.len != 6) return null;
    const value = std.fmt.parseUnsigned(u24, digits, 16) catch return null;
    return Color.hex(value);
}

/// Write `scheme` as a Ghostty theme file: what `parseGhostty` reads back to
/// the same scheme.
pub fn formatGhostty(scheme: Scheme, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (scheme.ansi, 0..) |color, index| {
        try writer.print("palette = {d}=", .{index});
        try writeColor(writer, color);
    }
    const Named = struct { key: []const u8, color: ?Color };
    const named = [_]Named{
        .{ .key = "background", .color = scheme.background },
        .{ .key = "foreground", .color = scheme.foreground },
        .{ .key = "cursor-color", .color = scheme.cursor },
        .{ .key = "cursor-text", .color = scheme.cursor_text },
        .{ .key = "selection-background", .color = scheme.selection_background },
        .{ .key = "selection-foreground", .color = scheme.selection_foreground },
    };
    for (named) |entry| {
        const color = entry.color orelse continue;
        try writer.print("{s} = ", .{entry.key});
        try writeColor(writer, color);
    }
}

fn writeColor(writer: *std.Io.Writer, color: Color) std.Io.Writer.Error!void {
    try writer.print("#{x:0>2}{x:0>2}{x:0>2}\n", .{ color.r, color.g, color.b });
}

// ---------------------------------------------------------------------------
// The `theme` setting
// ---------------------------------------------------------------------------

/// The parsed `theme` setting.
pub const Selection = union(enum) {
    /// Empty: Conduit's default scheme.
    default,
    /// One theme, by name.
    named: []const u8,
    /// `auto:<dark>,<light>`: follow the platform's light/dark preference.
    auto: struct { dark: []const u8, light: []const u8 },

    /// The theme name to use when the platform prefers `preference`; null
    /// (unknown) counts as dark. Null result means the default scheme.
    pub fn name(self: Selection, preference: ?Kind) ?[]const u8 {
        return switch (self) {
            .default => null,
            .named => |value| value,
            .auto => |pair| if ((preference orelse .dark) == .light) pair.light else pair.dark,
        };
    }
};

pub const SelectionError = error{InvalidAuto};

/// Parse a `theme` value: empty, a name, or `auto:<dark>,<light>` (the
/// `auto:` prefix in any case, both names non-empty). Borrows `value`.
pub fn parseSelection(value: []const u8) SelectionError!Selection {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return .default;
    const prefix = "auto:";
    if (trimmed.len >= prefix.len and std.ascii.eqlIgnoreCase(trimmed[0..prefix.len], prefix)) {
        const rest = trimmed[prefix.len..];
        const comma = std.mem.indexOfScalar(u8, rest, ',') orelse return error.InvalidAuto;
        const dark = std.mem.trim(u8, rest[0..comma], " \t");
        const light = std.mem.trim(u8, rest[comma + 1 ..], " \t");
        if (dark.len == 0 or light.len == 0 or std.mem.indexOfScalar(u8, light, ',') != null) return error.InvalidAuto;
        return .{ .auto = .{ .dark = dark, .light = light } };
    }
    return .{ .named = trimmed };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test {
    _ = schemes;
}

test "the ANSI roles sit in the slots an SGR colour parameter refers to" {
    // The order every terminal palette is written in, and the order an escape
    // sequence addresses: 30-37 then the bright 90-97.
    const ansi_roles = [ansi_slot_count]Role{
        .black,        .red,            .green,        .yellow,
        .blue,         .magenta,        .cyan,         .white,
        .bright_black, .bright_red,     .bright_green, .bright_yellow,
        .bright_blue,  .bright_magenta, .bright_cyan,  .bright_white,
    };

    for (ansi_roles, 0..) |role, expected| {
        try testing.expectEqual(@as(u8, @intCast(expected)), role.slot());
        try testing.expect(role.isAnsi());
    }

    // The named roles follow the 16, in the order they are declared.
    try testing.expectEqual(@as(u8, 16), Role.background.slot());
    try testing.expectEqual(@as(u8, 17), Role.foreground.slot());
    try testing.expectEqual(@as(u8, 18), Role.selection.slot());
    try testing.expectEqual(@as(u8, 19), Role.accent.slot());
}

test "a named role is not an ANSI slot" {
    try testing.expect(!Role.background.isAnsi());
    try testing.expect(!Role.foreground.isAnsi());
    try testing.expect(!Role.selection.isAnsi());
    try testing.expect(!Role.accent.isAnsi());
    try testing.expect(!Role.strong.isAnsi());
    try testing.expect(!Role.field.isAnsi());

    // The boundary: bright white is the last ANSI slot, background is the
    // first that is not, and the last declared role is the last slot.
    try testing.expect(Role.bright_white.isAnsi());
    try testing.expect(Role.bright_white.slot() + 1 == Role.background.slot());
    try testing.expectEqual(@as(usize, role_count), @as(usize, Role.field.slot()) + 1);
}

test "bundled schemes are complete, uniquely named and include the default first" {
    try testing.expect(bundled.len >= 11);
    try testing.expectEqualStrings(default_id, bundled[0].id);
    try testing.expect(bundled[0].scheme.eql(conduit_dark));
    for (bundled, 0..) |entry, index| {
        try testing.expectEqual(@as(usize, ansi_slot_count), entry.scheme.ansi.len);
        try testing.expect(entry.id.len != 0 and entry.label.len != 0);
        try testing.expect(std.unicode.utf8ValidateSlice(entry.label));
        // Ids are already in the canonical spelling a user may type.
        for (entry.id) |byte| try testing.expect(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-');
        for (bundled[0..index]) |previous| {
            try testing.expect(!sameName(previous.id, entry.id));
            try testing.expect(!sameName(previous.label, entry.label));
        }
        try testing.expectEqual(entry, findBundled(entry.id).?.*);
        try testing.expectEqual(entry, findBundled(entry.label).?.*);
    }
}

test "every bundled scheme survives a Ghostty-format round trip" {
    for (bundled) |entry| {
        var buffer: [2048]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try formatGhostty(entry.scheme, &writer);
        const parsed = parseGhostty(writer.buffered());
        try testing.expectEqual(@as(usize, 0), parsed.diagnostics().len);
        try testing.expect(parsed.scheme.eql(entry.scheme));
    }
}

test "the bundled data matches upstream for a spot-checked scheme" {
    const dracula = findBundled("dracula").?.scheme;
    try testing.expect(dracula.background.eql(Color.hex(0x282a36)));
    try testing.expect(dracula.ansi[4].eql(Color.hex(0xbd93f9)));
    try testing.expect(dracula.selection_background.eql(Color.hex(0x44475a)));
    try testing.expectEqual(Kind.dark, dracula.kind());
    try testing.expectEqual(Kind.light, findBundled("Solarized Light").?.scheme.kind());
    try testing.expectEqual(Kind.light, findBundled("catppuccin latte").?.scheme.kind());
    try testing.expectEqual(Kind.dark, findBundled("Rosé Pine").?.scheme.kind());
}

test "theme names ignore case, spaces, hyphens and underscores" {
    try testing.expect(sameName("Tokyo Night", "tokyo-night"));
    try testing.expect(sameName("TokyoNight", "tokyo_night"));
    try testing.expect(sameName("  rose pine", "rose-pine"));
    try testing.expect(!sameName("nord", "nord-light"));
    try testing.expect(!sameName("", "a"));
    try testing.expect(sameName("", " - "));
    try testing.expectEqualStrings("tokyo-night", findBundled("TokyoNight").?.id);
    try testing.expectEqualStrings("rose-pine", findBundled("Rose Pine").?.id);
    try testing.expect(findBundled("no such theme") == null);
}

/// The palette Conduit shipped before TASK-38, slot for slot, as it was
/// written in `app`.
const shipped_palette = [20]Color{
    .hex(0x1a1c24), .hex(0xcc5555), .hex(0x7fb874), .hex(0xd6b055),
    .hex(0x617fd4), .hex(0xb47ad0), .hex(0x56b6c2), .hex(0xc8c8d2),
    .hex(0x4a4f5c), .hex(0xe06c6c), .hex(0x9ad08c), .hex(0xecc86a),
    .hex(0x7c9ce8), .hex(0xd092e4), .hex(0x6cccd6), .hex(0xf0f0f6),
    .hex(0x161a22), .hex(0xd8d8e0), .hex(0x2c3a4d), .hex(0x7c9ce8),
};

test "conduit-dark derives exactly the palette Conduit shipped before themes" {
    const palette = derive(conduit_dark);
    for (shipped_palette, 0..) |color, slot| try testing.expect(palette.colors[slot].eql(color));
    // Each chrome role took the ANSI colour the UI drew that job with.
    try testing.expect(palette.get(.strong).eql(palette.get(.bright_white)));
    try testing.expect(palette.get(.muted).eql(palette.get(.bright_black)));
    try testing.expect(palette.get(.border).eql(palette.get(.bright_blue)));
    try testing.expect(palette.get(.attention).eql(palette.get(.bright_yellow)));
    try testing.expect(palette.get(.danger).eql(palette.get(.bright_red)));
    try testing.expect(palette.get(.on_accent).eql(palette.get(.black)));
    try testing.expect(palette.get(.field).eql(palette.get(.black)));
    try testing.expect(palette.get(.cursor).eql(palette.get(.foreground)));
}

fn expectReadable(palette: Palette) !void {
    const bg = palette.get(.background);
    try testing.expect(contrast(palette.get(.strong), bg) >= text_contrast);
    try testing.expect(contrast(palette.get(.muted), bg) >= muted_contrast);
    try testing.expect(contrast(palette.get(.accent), bg) >= chrome_contrast);
    try testing.expect(contrast(palette.get(.attention), bg) >= chrome_contrast);
    try testing.expect(contrast(palette.get(.danger), bg) >= chrome_contrast);
    try testing.expect(contrast(palette.get(.on_accent), palette.get(.accent)) >= text_contrast);
    try testing.expect(contrast(palette.get(.strong), palette.get(.field)) >= chrome_contrast);
    try testing.expect(contrast(palette.get(.foreground), palette.get(.field)) >= chrome_contrast);
    try testing.expect(contrast(palette.get(.strong), palette.get(.selection)) >= 2.0);
}

test "derived chrome stays readable on a dark and a light scheme" {
    const dark = findBundled("gruvbox-dark").?.scheme;
    const light = findBundled("solarized-light").?.scheme;
    const dark_palette = derive(dark);
    const light_palette = derive(light);
    try expectReadable(dark_palette);
    try expectReadable(light_palette);

    // On a light scheme bright white would vanish, so emphasis falls back to
    // the foreground, or past a low-contrast foreground (Solarized's) to ANSI
    // black; on the dark one it is bright white itself.
    try testing.expect(dark_palette.get(.strong).eql(dark.ansi[15]));
    try testing.expect(light_palette.get(.strong).eql(light.ansi[0]));
    const gruvbox_light = findBundled("gruvbox-light").?.scheme;
    try testing.expect(derive(gruvbox_light).get(.strong).eql(gruvbox_light.foreground));
    // Solarized's bright black is its background: muted falls back to a mix.
    const solarized_dark = derive(findBundled("solarized-dark").?.scheme);
    try testing.expect(!solarized_dark.get(.muted).eql(solarized_dark.get(.background)));
    // The terminal roles are the scheme's own, untouched.
    for (light.ansi, 0..) |color, slot| try testing.expect(light_palette.colors[slot].eql(color));
    try testing.expect(light_palette.get(.background).eql(light.background));
    try testing.expect(light_palette.get(.cursor).eql(light.cursor));
}

test "every bundled scheme derives a readable palette" {
    for (bundled) |entry| try expectReadable(derive(entry.scheme));
}

test "a selection colour meant to sit under its own foreground is toned toward the background" {
    const kanagawa = findBundled("kanagawa-wave").?.scheme;
    const palette = derive(kanagawa);
    try testing.expect(!palette.get(.selection).eql(kanagawa.selection_background));
    try testing.expect(palette.get(.selection).eql(mix(kanagawa.selection_background, kanagawa.background, 1, 4)));
    const dracula = findBundled("dracula").?.scheme;
    try testing.expect(derive(dracula).get(.selection).eql(dracula.selection_background));
}

test "mix and contrast are the documented arithmetic" {
    const black = Color.hex(0x000000);
    const white = Color.hex(0xffffff);
    try testing.expectApproxEqAbs(@as(f32, 21.0), contrast(black, white), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1.0), contrast(white, white), 0.0001);
    try testing.expect(mix(white, black, 1, 2).eql(Color.hex(0x808080)));
    try testing.expect(mix(white, black, 1, 4).eql(Color.hex(0x404040)));
    try testing.expect(mix(white, black, 4, 4).eql(white));
}

/// The Ghostty project's Dracula theme file, verbatim.
const ghostty_dracula =
    \\palette = 0=#21222c
    \\palette = 1=#ff5555
    \\palette = 2=#50fa7b
    \\palette = 3=#f1fa8c
    \\palette = 4=#bd93f9
    \\palette = 5=#ff79c6
    \\palette = 6=#8be9fd
    \\palette = 7=#f8f8f2
    \\palette = 8=#6272a4
    \\palette = 9=#ff6e6e
    \\palette = 10=#69ff94
    \\palette = 11=#ffffa5
    \\palette = 12=#d6acff
    \\palette = 13=#ff92df
    \\palette = 14=#a4ffff
    \\palette = 15=#ffffff
    \\background = #282a36
    \\foreground = #f8f8f2
    \\cursor-color = #f8f8f2
    \\cursor-text = #282a36
    \\selection-background = #44475a
    \\selection-foreground = #ffffff
    \\
;

test "a real Ghostty theme file parses to the bundled scheme" {
    const parsed = parseGhostty(ghostty_dracula);
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics().len);
    try testing.expect(parsed.scheme.eql(findBundled("dracula").?.scheme));
}

test "comments, CRLF, quotes and bare hex are accepted" {
    const parsed = parseGhostty(
        "\xEF\xBB\xBF# a comment\r\n\r\n  background = \"102030\"\r\n\tforeground=#A0B0C0\r\npalette = 3 = #010203\r\n",
    );
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics().len);
    try testing.expect(parsed.scheme.background.eql(Color.hex(0x102030)));
    try testing.expect(parsed.scheme.foreground.eql(Color.hex(0xa0b0c0)));
    try testing.expect(parsed.scheme.ansi[3].eql(Color.hex(0x010203)));
}

test "malformed lines are reported, skipped and never fatal" {
    const text =
        \\background = #282a36
        \\palette = 16=#ffffff
        \\palette = x=#ffffff
        \\palette = 2
        \\foreground = red
        \\font-family = Iosevka
        \\just words
        \\cursor-color = #12345
        \\palette = 1=#ff0000
    ;
    const parsed = parseGhostty(text);
    const want = [_]Diagnostic{
        .{ .line = 2, .message = "palette: only entries 0 to 15 are used" },
        .{ .line = 3, .message = "palette: invalid index" },
        .{ .line = 4, .message = "palette: expected `N=#rrggbb`" },
        .{ .line = 5, .message = "invalid colour" },
        .{ .line = 6, .message = "unknown key" },
        .{ .line = 7, .message = "expected `key = value`" },
        .{ .line = 8, .message = "invalid colour" },
    };
    try testing.expectEqual(want.len, parsed.diagnostics().len);
    for (want, parsed.diagnostics()) |expected, got| {
        try testing.expectEqual(expected.line, got.line);
        try testing.expectEqualStrings(expected.message, got.message);
    }
    // The good lines applied; everything unset is conduit-dark's.
    try testing.expect(parsed.scheme.background.eql(Color.hex(0x282a36)));
    try testing.expect(parsed.scheme.ansi[1].eql(Color.hex(0xff0000)));
    try testing.expect(parsed.scheme.foreground.eql(conduit_dark.foreground));
    try testing.expect(parsed.scheme.ansi[2].eql(conduit_dark.ansi[2]));
    try testing.expect(parsed.scheme.cursor.eql(conduit_dark.cursor));
}

test "oversized files and lines are bounded" {
    const huge = [_]u8{'#'} ** (max_file_bytes + 1);
    const whole = parseGhostty(&huge);
    try testing.expectEqual(@as(usize, 1), whole.diagnostics().len);
    try testing.expectEqual(@as(u32, 0), whole.diagnostics()[0].line);
    try testing.expect(whole.scheme.eql(conduit_dark));

    const long_line = "background = #000000" ++ [_]u8{' '} ** max_line_bytes;
    const parsed = parseGhostty(long_line);
    try testing.expectEqual(@as(u32, 1), parsed.diagnostics()[0].line);
    try testing.expect(parsed.scheme.background.eql(conduit_dark.background));

    const noisy = "x\n" ** (max_diagnostics + 3);
    const many = parseGhostty(noisy);
    try testing.expectEqual(max_diagnostics, many.diagnostics().len);
    try testing.expectEqual(@as(usize, 3), many.dropped);
}

test "an empty file is the default scheme" {
    const parsed = parseGhostty("");
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics().len);
    try testing.expect(parsed.scheme.eql(conduit_dark));
}

test "the theme setting parses names and the auto pair" {
    try testing.expectEqual(Selection.default, try parseSelection(""));
    try testing.expectEqual(Selection.default, try parseSelection("   "));
    try testing.expectEqualStrings("Gruvbox Dark", (try parseSelection(" Gruvbox Dark ")).named);

    const auto = try parseSelection("AUTO: dracula , solarized-light");
    try testing.expectEqualStrings("dracula", auto.auto.dark);
    try testing.expectEqualStrings("solarized-light", auto.auto.light);
    try testing.expectEqualStrings("dracula", auto.name(.dark).?);
    try testing.expectEqualStrings("solarized-light", auto.name(.light).?);
    // An unknown preference is dark.
    try testing.expectEqualStrings("dracula", auto.name(null).?);
    try testing.expect((try parseSelection("")).name(.light) == null);
    try testing.expectEqualStrings("nord", (try parseSelection("nord")).name(.light).?);

    try testing.expectError(error.InvalidAuto, parseSelection("auto:"));
    try testing.expectError(error.InvalidAuto, parseSelection("auto:dracula"));
    try testing.expectError(error.InvalidAuto, parseSelection("auto:,nord"));
    try testing.expectError(error.InvalidAuto, parseSelection("auto:nord,"));
    try testing.expectError(error.InvalidAuto, parseSelection("auto:a,b,c"));
}
