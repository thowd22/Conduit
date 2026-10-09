//! Screen manifests (TASK-84): what a harness's TUI shows when it is busy,
//! asking for permission, waiting for the human or reporting an error, as
//! bounded literal patterns matched against the bottom rows of its terminal.
//!
//! The design follows herdr's per-agent manifests (Apache-2.0,
//! https://github.com/herdrdev/herdr, `src/detect/manifests/*.toml`): each
//! harness ships its own rules as data, a rule is a conjunction of literal
//! needles inside a bottom-of-screen region, and a visible blocker outranks
//! everything else. Conduit keeps the matcher to literals, case-folded ASCII
//! and a row-start anchor instead of herdr's regexes, so a manifest is
//! compile-time data checked against fixed bounds and matching allocates
//! nothing.
//!
//! The text matched is untrusted: a classification may only move an agent's
//! heuristic state (`Heuristics`), never answer a prompt or trigger anything,
//! and the text is never logged.
//!
//! Threads: none of its own. Memory: values and borrowed slices only.

const std = @import("std");

/// What a screen shows, by the manifest of the harness drawing it.
pub const Class = enum {
    /// No pattern matched.
    none,
    /// A turn is visibly running (a spinner line, an interrupt hint).
    working,
    /// The harness waits at its prompt for the human's next message.
    input,
    /// The harness asks for permission to use a tool.
    permission,
    /// The last turn visibly failed.
    errored,
};

/// One rule: every `all` literal appears in the region, no `none` literal
/// does, and when `row_prefix` is set some row of the region starts with it
/// after its leading spaces. Literals match case-insensitively for ASCII and
/// byte for byte otherwise, and are written in lower case.
pub const Pattern = struct {
    all: []const []const u8 = &.{},
    none: []const []const u8 = &.{},
    row_prefix: ?[]const u8 = null,
    /// The region: this many bottom non-blank rows (0 means every row read).
    rows: u8 = 0,
};

/// A harness's patterns for each class, plus the build they were captured
/// from (a pattern is only as good as the screens it was derived from).
pub const ScreenManifest = struct {
    captured_from: []const u8,
    permission: []const Pattern = &.{},
    working: []const Pattern = &.{},
    errored: []const Pattern = &.{},
    input: []const Pattern = &.{},

    pub const max_patterns = 16;
    pub const max_literals = 4;
    pub const max_literal_len = 64;
    pub const max_rows = 32;

    /// Whether every class is empty: nothing to read the screen for.
    pub fn isEmpty(self: *const ScreenManifest) bool {
        return self.permission.len == 0 and self.working.len == 0 and self.errored.len == 0 and self.input.len == 0;
    }

    /// Classify `text` (rows separated by `\n`, newest last). A visible
    /// blocker outranks a busy screen, a busy screen outranks a stale error
    /// line, and an error outranks the prompt that always follows it.
    pub fn classify(self: *const ScreenManifest, text: []const u8) Class {
        if (anyMatches(self.permission, text)) return .permission;
        if (anyMatches(self.working, text)) return .working;
        if (anyMatches(self.errored, text)) return .errored;
        if (anyMatches(self.input, text)) return .input;
        return .none;
    }

    /// Check the bounds. Called at compile time by every manifest's owner,
    /// so an oversized manifest does not build.
    pub fn validate(comptime self: ScreenManifest) void {
        inline for (.{ self.permission, self.working, self.errored, self.input }) |patterns| {
            if (patterns.len > max_patterns) @compileError("too many screen patterns in one class");
            inline for (patterns) |pattern| {
                if (pattern.all.len > max_literals or pattern.none.len > max_literals)
                    @compileError("too many literals in one screen pattern");
                if (pattern.all.len == 0 and pattern.row_prefix == null)
                    @compileError("a screen pattern must name something to find");
                if (pattern.rows > max_rows) @compileError("a screen pattern's region is too tall");
                inline for (pattern.all ++ pattern.none) |literal| checkLiteral(literal);
                if (pattern.row_prefix) |prefix| checkLiteral(prefix);
            }
        }
    }
};

fn checkLiteral(comptime literal: []const u8) void {
    if (literal.len == 0 or literal.len > ScreenManifest.max_literal_len)
        @compileError("a screen literal must be 1 to 64 bytes");
    for (literal) |c| {
        if (std.ascii.isUpper(c)) @compileError("screen literals are written in lower case: " ++ literal);
    }
}

fn anyMatches(patterns: []const Pattern, text: []const u8) bool {
    for (patterns) |*pattern| {
        if (matches(pattern, text)) return true;
    }
    return false;
}

/// Whether one pattern matches `text`.
pub fn matches(pattern: *const Pattern, text: []const u8) bool {
    const region = bottomRows(text, pattern.rows);
    for (pattern.all) |literal| {
        if (!containsFolded(region, literal)) return false;
    }
    for (pattern.none) |literal| {
        if (containsFolded(region, literal)) return false;
    }
    if (pattern.row_prefix) |prefix| {
        var rows = std.mem.splitScalar(u8, region, '\n');
        while (rows.next()) |row| {
            const trimmed = std.mem.trimStart(u8, row, " ");
            if (trimmed.len >= prefix.len and eqlFolded(trimmed[0..prefix.len], prefix)) return true;
        }
        return false;
    }
    return true;
}

/// The tail of `text` holding its last `count` non-blank rows (all of it
/// for 0). Blank rows between them stay; a region never splits a row.
fn bottomRows(text: []const u8, count: u8) []const u8 {
    if (count == 0) return text;
    var seen: u8 = 0;
    var end = text.len;
    while (true) {
        const start = if (std.mem.lastIndexOfScalar(u8, text[0..end], '\n')) |nl| nl + 1 else 0;
        if (std.mem.trim(u8, text[start..end], " ").len != 0) {
            seen += 1;
            if (seen == count) return text[start..];
        }
        if (start == 0) return text;
        end = start - 1;
    }
}

fn foldByte(c: u8) u8 {
    return std.ascii.toLower(c);
}

fn eqlFolded(haystack: []const u8, lower: []const u8) bool {
    for (haystack, lower) |a, b| {
        if (foldByte(a) != b) return false;
    }
    return true;
}

fn containsFolded(haystack: []const u8, lower: []const u8) bool {
    if (lower.len > haystack.len) return false;
    var i: usize = 0;
    while (i + lower.len <= haystack.len) : (i += 1) {
        if (eqlFolded(haystack[i..][0..lower.len], lower)) return true;
    }
    return false;
}

/// A manifest with no patterns: the PTY baseline alone.
pub const empty: ScreenManifest = .{ .captured_from = "" };

const testing = std.testing;

test "patterns match literals in a bottom region, case-folded, with a row anchor" {
    const text = "old line: Do you want to proceed?\n\n  \u{276f} 1. Yes\n\n Esc to cancel\n";
    try testing.expect(matches(&.{ .all = &.{ "do you want to proceed?", "esc to cancel" } }, text));
    // The question is outside the last two non-blank rows.
    try testing.expect(!matches(&.{ .all = &.{"do you want to proceed?"}, .rows = 2 }, text));
    try testing.expect(matches(&.{ .row_prefix = "\u{276f} 1. yes", .rows = 2 }, text));
    // An anchor is a row start, not anywhere in a row.
    try testing.expect(!matches(&.{ .row_prefix = "1. yes" }, text));
    try testing.expect(!matches(&.{ .all = &.{"esc to cancel"}, .none = &.{"old line"} }, text));
    try testing.expect(matches(&.{ .all = &.{"esc to cancel"}, .none = &.{"old line"}, .rows = 2 }, text));
    // A region larger than the text is the whole text.
    try testing.expect(matches(&.{ .all = &.{"old line"}, .rows = 30 }, text));
    try testing.expect(!matches(&.{ .all = &.{"absent"} }, ""));
}

test "a blocker outranks work, work outranks an error, an error outranks the prompt" {
    const manifest: ScreenManifest = comptime blk: {
        const m: ScreenManifest = .{
            .captured_from = "test",
            .permission = &.{.{ .all = &.{"allow?"} }},
            .working = &.{.{ .all = &.{"busy"} }},
            .errored = &.{.{ .row_prefix = "error:" }},
            .input = &.{.{ .row_prefix = ">" }},
        };
        m.validate();
        break :blk m;
    };
    try testing.expectEqual(Class.permission, manifest.classify("busy\nallow?\n>"));
    try testing.expectEqual(Class.working, manifest.classify("Error: x\nbusy\n>"));
    try testing.expectEqual(Class.errored, manifest.classify("Error: x\n>"));
    try testing.expectEqual(Class.input, manifest.classify("done\n> "));
    try testing.expectEqual(Class.none, manifest.classify("plain shell output"));
    try testing.expect(empty.isEmpty());
    try testing.expectEqual(Class.none, empty.classify("allow? busy > error:"));
}
