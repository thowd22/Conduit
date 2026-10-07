//! The YAML subset Backlog.md writes into front matter and `config.yml`.
//!
//! This is deliberately not a YAML parser. It reads exactly the shapes the
//! backlog tool emits: one `key: value` per top-level line, where the value is
//! a plain scalar, a single- or double-quoted scalar, a one-line flow list
//! (`[a, 'b']`), a block list (`key:` followed by indented `- item` lines) or a
//! block scalar (`key: >-` / `|` followed by indented lines). Anything else —
//! nested maps, anchors, tags, multi-line quoted or flow values — becomes an
//! `Issue` with its line number, never an error, and the parse continues with
//! the next top-level key. Unknown keys are returned like any other; callers
//! ignore what they do not read.
//!
//! The input is untrusted text. Every count is bounded by `Limits`, and an
//! over-long line or list is reported and cut, not trusted.
//!
//! Memory: values borrow `text` when they can and are otherwise allocated in
//! the caller's arena. Free the arena to free everything; `text` must outlive
//! the returned `Document`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Bounds on one parse.
pub const Limits = struct {
    max_line_bytes: usize = 4096,
    max_fields: usize = 128,
    max_list_items: usize = 256,
    max_issues: usize = 32,
};

/// One parsed value.
pub const Value = union(enum) {
    scalar: []const u8,
    list: []const []const u8,
};

/// One top-level key. `line` is 1-based within the parsed text.
pub const Field = struct {
    key: []const u8,
    value: Value,
    line: u32,
};

/// Something the subset does not accept. `message` is static text.
pub const Issue = struct {
    line: u32,
    message: []const u8,
};

pub const Document = struct {
    fields: []const Field,
    issues: []const Issue,

    /// The first field named `key`.
    pub fn get(self: Document, key: []const u8) ?Field {
        for (self.fields) |field| {
            if (std.mem.eql(u8, field.key, key)) return field;
        }
        return null;
    }

    /// A scalar field's text, or null when absent or a list.
    pub fn scalar(self: Document, key: []const u8) ?[]const u8 {
        const field = self.get(key) orelse return null;
        return switch (field.value) {
            .scalar => |text| text,
            .list => null,
        };
    }

    /// A list field's items. An absent or empty scalar is an empty list, and a
    /// non-empty scalar is a list of one, which is how the tool writes a single
    /// assignee in older files.
    pub fn list(self: Document, arena: Allocator, key: []const u8) Allocator.Error![]const []const u8 {
        const field = self.get(key) orelse return &.{};
        return switch (field.value) {
            .list => |items| items,
            .scalar => |text| if (text.len == 0) &.{} else blk: {
                const one = try arena.alloc([]const u8, 1);
                one[0] = text;
                break :blk one;
            },
        };
    }
};

const Line = struct {
    /// Without the line terminator (LF or CRLF).
    text: []const u8,
    number: u32,
};

const LineIterator = struct {
    rest: []const u8,
    number: u32 = 0,

    fn next(self: *LineIterator) ?Line {
        if (self.rest.len == 0) return null;
        const end = std.mem.indexOfScalar(u8, self.rest, '\n') orelse self.rest.len;
        var text = self.rest[0..end];
        self.rest = if (end < self.rest.len) self.rest[end + 1 ..] else self.rest[self.rest.len..];
        if (text.len > 0 and text[text.len - 1] == '\r') text = text[0 .. text.len - 1];
        self.number += 1;
        return .{ .text = text, .number = self.number };
    }

    fn peek(self: *const LineIterator) ?Line {
        var copy = self.*;
        return copy.next();
    }
};

const Parser = struct {
    arena: Allocator,
    limits: Limits,
    fields: std.ArrayList(Field) = .empty,
    issues: std.ArrayList(Issue) = .empty,

    fn issue(self: *Parser, line: u32, message: []const u8) Allocator.Error!void {
        if (self.issues.items.len >= self.limits.max_issues) return;
        try self.issues.append(self.arena, .{ .line = line, .message = message });
    }
};

fn indentation(text: []const u8) usize {
    var n: usize = 0;
    while (n < text.len and text[n] == ' ') n += 1;
    return n;
}

fn isBlank(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t").len == 0;
}

fn isComment(text: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, text, " \t");
    return trimmed.len > 0 and trimmed[0] == '#';
}

fn validKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    }
    return true;
}

/// Parse `text` as the front-matter subset. Allocation failure is the only
/// error; malformed input becomes `Document.issues`.
pub fn parse(arena: Allocator, text: []const u8, limits: Limits) Allocator.Error!Document {
    var parser: Parser = .{ .arena = arena, .limits = limits };
    var lines: LineIterator = .{ .rest = text };

    while (lines.next()) |line| {
        if (line.text.len > limits.max_line_bytes) {
            try parser.issue(line.number, "line too long");
            continue;
        }
        if (isBlank(line.text) or isComment(line.text)) continue;
        if (indentation(line.text) != 0 or line.text[0] == '\t') {
            try parser.issue(line.number, "unexpected indentation");
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line.text, ':') orelse {
            try parser.issue(line.number, "expected `key: value`");
            continue;
        };
        const key = std.mem.trim(u8, line.text[0..colon], " \t");
        if (!validKey(key)) {
            try parser.issue(line.number, "unsupported key");
            skipIndented(&lines);
            continue;
        }
        const rest = std.mem.trim(u8, line.text[colon + 1 ..], " \t");

        const value: ?Value = if (rest.len == 0)
            try parseBlockList(&parser, &lines, line.number)
        else if (rest[0] == '>' or rest[0] == '|')
            try parseBlockScalar(&parser, &lines, line.number, rest)
        else if (rest[0] == '[')
            try parseFlowList(&parser, line.number, rest)
        else if (rest[0] == '{' or rest[0] == '&' or rest[0] == '*' or rest[0] == '!') blk: {
            try parser.issue(line.number, "unsupported YAML value");
            break :blk null;
        } else if (try parseScalar(&parser, line.number, rest)) |scalar|
            .{ .scalar = scalar }
        else
            null;

        const parsed = value orelse continue;
        if (parser.fields.items.len >= limits.max_fields) {
            try parser.issue(line.number, "too many keys");
            continue;
        }
        try parser.fields.append(arena, .{ .key = key, .value = parsed, .line = line.number });
    }

    return .{ .fields = parser.fields.items, .issues = parser.issues.items };
}

/// Skip the indented continuation of a key the subset rejected.
fn skipIndented(lines: *LineIterator) void {
    while (lines.peek()) |next| {
        if (!isBlank(next.text) and indentation(next.text) == 0 and next.text[0] != '\t') return;
        _ = lines.next();
    }
}

/// `key:` with nothing after it: the indented `- item` lines that follow, or
/// an empty scalar when nothing indented follows.
fn parseBlockList(parser: *Parser, lines: *LineIterator, key_line: u32) Allocator.Error!?Value {
    var items: std.ArrayList([]const u8) = .empty;
    var saw_any = false;
    var nested_map = false;
    while (lines.peek()) |next| {
        if (isBlank(next.text) or isComment(next.text)) {
            _ = lines.next();
            continue;
        }
        if (indentation(next.text) == 0 and next.text[0] != '\t') break;
        _ = lines.next();
        saw_any = true;
        if (next.text.len > parser.limits.max_line_bytes) {
            try parser.issue(next.number, "line too long");
            continue;
        }
        const trimmed = std.mem.trim(u8, next.text, " \t");
        if (!(std.mem.startsWith(u8, trimmed, "- ") or std.mem.eql(u8, trimmed, "-"))) {
            nested_map = true;
            continue;
        }
        const item_text = std.mem.trim(u8, trimmed[1..], " \t");
        if (items.items.len >= parser.limits.max_list_items) {
            try parser.issue(next.number, "list too long");
            continue;
        }
        const item = if (item_text.len == 0) "" else (try parseScalar(parser, next.number, item_text)) orelse continue;
        try items.append(parser.arena, item);
    }
    if (nested_map) {
        try parser.issue(key_line, "nested maps are not supported");
        return null;
    }
    if (!saw_any) return .{ .scalar = "" };
    return .{ .list = items.items };
}

/// `>`/`|` with optional chomping indicator: the indented lines that follow.
fn parseBlockScalar(parser: *Parser, lines: *LineIterator, key_line: u32, header: []const u8) Allocator.Error!?Value {
    const folded = header[0] == '>';
    const indicator = header[1..];
    const chomp: enum { clip, strip, keep } = if (indicator.len == 0)
        .clip
    else if (std.mem.eql(u8, indicator, "-"))
        .strip
    else if (std.mem.eql(u8, indicator, "+"))
        .keep
    else {
        try parser.issue(key_line, "unsupported block scalar header");
        skipIndented(lines);
        return null;
    };

    var out: std.ArrayList(u8) = .empty;
    var block_indent: ?usize = null;
    var pending_breaks: usize = 0;
    var first = true;
    while (lines.peek()) |next| {
        if (!isBlank(next.text) and indentation(next.text) == 0) break;
        _ = lines.next();
        if (isBlank(next.text)) {
            pending_breaks += 1;
            continue;
        }
        if (next.text.len > parser.limits.max_line_bytes) {
            try parser.issue(next.number, "line too long");
            continue;
        }
        const indent = block_indent orelse blk: {
            block_indent = indentation(next.text);
            break :blk block_indent.?;
        };
        const content = if (indentation(next.text) >= indent) next.text[indent..] else std.mem.trimStart(u8, next.text, " ");
        if (!first) {
            if (folded and pending_breaks == 0) {
                try out.append(parser.arena, ' ');
            } else if (folded) {
                try out.appendNTimes(parser.arena, '\n', pending_breaks);
            } else {
                try out.appendNTimes(parser.arena, '\n', pending_breaks + 1);
            }
        }
        pending_breaks = 0;
        first = false;
        try out.appendSlice(parser.arena, content);
    }
    switch (chomp) {
        .strip => {},
        .clip => if (!first) try out.append(parser.arena, '\n'),
        .keep => if (!first) try out.appendNTimes(parser.arena, '\n', pending_breaks + 1),
    }
    return .{ .scalar = out.items };
}

/// `[a, 'b, c', "d"]` on one line.
fn parseFlowList(parser: *Parser, line: u32, text: []const u8) Allocator.Error!?Value {
    if (text[text.len - 1] != ']') {
        try parser.issue(line, "unterminated flow list");
        return null;
    }
    const inner = std.mem.trim(u8, text[1 .. text.len - 1], " \t");
    var items: std.ArrayList([]const u8) = .empty;
    if (inner.len == 0) return .{ .list = items.items };

    var start: usize = 0;
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i <= inner.len) : (i += 1) {
        const at_end = i == inner.len;
        if (!at_end) {
            const c = inner[i];
            if (quote) |q| {
                if (c == q) {
                    // `''` inside a single-quoted item is an escaped quote.
                    if (q == '\'' and i + 1 < inner.len and inner[i + 1] == '\'') {
                        i += 1;
                    } else quote = null;
                } else if (c == '\\' and q == '"' and i + 1 < inner.len) {
                    i += 1;
                }
                continue;
            }
            if (c == '\'' or c == '"') {
                quote = c;
                continue;
            }
            if (c == '[' or c == '{') {
                try parser.issue(line, "nested flow collections are not supported");
                return null;
            }
            if (c != ',') continue;
        } else if (quote != null) {
            try parser.issue(line, "unterminated quoted scalar");
            return null;
        }
        const item_text = std.mem.trim(u8, inner[start..i], " \t");
        start = i + 1;
        if (items.items.len >= parser.limits.max_list_items) {
            try parser.issue(line, "list too long");
            break;
        }
        if (item_text.len == 0) continue;
        const item = (try parseScalar(parser, line, item_text)) orelse continue;
        try items.append(parser.arena, item);
    }
    return .{ .list = items.items };
}

/// A plain, single-quoted or double-quoted scalar on one line.
fn parseScalar(parser: *Parser, line: u32, text: []const u8) Allocator.Error!?[]const u8 {
    if (text[0] == '\'') return parseSingleQuoted(parser, line, text);
    if (text[0] == '"') return parseDoubleQuoted(parser, line, text);
    // A ` #` starts a comment after a plain scalar.
    var end = text.len;
    var i: usize = 0;
    while (i + 1 < text.len) : (i += 1) {
        if ((text[i] == ' ' or text[i] == '\t') and text[i + 1] == '#') {
            end = i;
            break;
        }
    }
    return std.mem.trimEnd(u8, text[0..end], " \t");
}

fn parseSingleQuoted(parser: *Parser, line: u32, text: []const u8) Allocator.Error!?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\'') {
            if (i + 1 < text.len and text[i + 1] == '\'') {
                try out.append(parser.arena, '\'');
                i += 1;
                continue;
            }
            if (!trailingIsComment(text[i + 1 ..])) {
                try parser.issue(line, "text after a quoted scalar");
                return null;
            }
            return out.items;
        }
        try out.append(parser.arena, text[i]);
    }
    try parser.issue(line, "unterminated quoted scalar");
    return null;
}

fn parseDoubleQuoted(parser: *Parser, line: u32, text: []const u8) Allocator.Error!?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '"') {
            if (!trailingIsComment(text[i + 1 ..])) {
                try parser.issue(line, "text after a quoted scalar");
                return null;
            }
            return out.items;
        }
        if (c == '\\' and i + 1 < text.len) {
            i += 1;
            const escaped: u8 = switch (text[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '0' => 0,
                else => text[i],
            };
            try out.append(parser.arena, escaped);
            continue;
        }
        try out.append(parser.arena, c);
    }
    try parser.issue(line, "unterminated quoted scalar");
    return null;
}

fn trailingIsComment(rest: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, rest, " \t");
    return trimmed.len == 0 or (trimmed[0] == '#' and trimmed.len != rest.len);
}

const testing = std.testing;

test "the subset reads every shape Backlog.md writes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        "id: TASK-27\r\n" ++
        "title: 'Workspace, ExecutionContext and Session model'\n" ++
        "status: Done\n" ++
        "assignee:\n" ++
        "  - '@codex'\n" ++
        "  - \"@claude\"\n" ++
        "created_date: '2026-10-03 21:39'\n" ++
        "labels: []\n" ++
        "statuses: [\"To Do\", In Progress, 'Done']\n" ++
        "# a comment line\n" ++
        "empty:\n" ++
        "quote: 'it''s'\n" ++
        "escaped: \"a\\\"b\"\n" ++
        "plain: value # trailing comment\n" ++
        "long: >-\n" ++
        "  PTY reader can lose its wakeup on the shared wake pipe and stall a session\n" ++
        "  forever\n" ++
        "literal: |\n" ++
        "  one\n" ++
        "  two\n" ++
        "ordinal: 62000\n";
    const doc = try parse(arena, text, .{});
    try testing.expectEqual(@as(usize, 0), doc.issues.len);
    try testing.expectEqualStrings("TASK-27", doc.scalar("id").?);
    try testing.expectEqualStrings("Workspace, ExecutionContext and Session model", doc.scalar("title").?);
    const assignee = try doc.list(arena, "assignee");
    try testing.expectEqual(@as(usize, 2), assignee.len);
    try testing.expectEqualStrings("@codex", assignee[0]);
    try testing.expectEqualStrings("@claude", assignee[1]);
    try testing.expectEqual(@as(usize, 0), (try doc.list(arena, "labels")).len);
    const statuses = try doc.list(arena, "statuses");
    try testing.expectEqual(@as(usize, 3), statuses.len);
    try testing.expectEqualStrings("To Do", statuses[0]);
    try testing.expectEqualStrings("In Progress", statuses[1]);
    try testing.expectEqualStrings("Done", statuses[2]);
    try testing.expectEqual(@as(usize, 0), (try doc.list(arena, "empty")).len);
    try testing.expectEqualStrings("it's", doc.scalar("quote").?);
    try testing.expectEqualStrings("a\"b", doc.scalar("escaped").?);
    try testing.expectEqualStrings("value", doc.scalar("plain").?);
    try testing.expectEqualStrings(
        "PTY reader can lose its wakeup on the shared wake pipe and stall a session forever",
        doc.scalar("long").?,
    );
    try testing.expectEqualStrings("one\ntwo\n", doc.scalar("literal").?);
    try testing.expectEqualStrings("62000", doc.scalar("ordinal").?);
    // A single scalar reads as a list of one.
    try testing.expectEqual(@as(usize, 1), (try doc.list(arena, "status")).len);
}

test "unsupported or malformed YAML becomes line-numbered issues, not errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        "id: TASK-1\n" ++ // 1
        "  stray indentation\n" ++ // 2
        "no colon here\n" ++ // 3
        "title: 'unterminated\n" ++ // 4
        "labels: [a, b\n" ++ // 5
        "map:\n" ++ // 6
        "  nested: value\n" ++ // 7
        "anchor: &x 1\n" ++ // 8
        "bad key!: 1\n" ++ // 9
        "status: To Do\n"; // 10
    const doc = try parse(arena, text, .{});
    try testing.expectEqualStrings("TASK-1", doc.scalar("id").?);
    try testing.expectEqualStrings("To Do", doc.scalar("status").?);
    try testing.expect(doc.get("title") == null);
    try testing.expect(doc.get("labels") == null);
    try testing.expect(doc.get("map") == null);
    const expected_lines = [_]u32{ 2, 3, 4, 5, 6, 8, 9 };
    try testing.expectEqual(expected_lines.len, doc.issues.len);
    for (expected_lines, doc.issues) |line, found| try testing.expectEqual(line, found.line);
}

test "the subset bounds lines, lists, keys and issues" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const limits: Limits = .{ .max_line_bytes = 32, .max_fields = 2, .max_list_items = 2, .max_issues = 3 };
    const text =
        "a: [1, 2, 3]\n" ++
        "b: this value is far longer than thirty-two bytes\n" ++
        "c: 3\n" ++
        "d: 4\n" ++
        "e: 5\n" ++
        "f: 6\n";
    const doc = try parse(arena, text, limits);
    try testing.expectEqual(@as(usize, 2), doc.fields.len);
    try testing.expectEqual(@as(usize, 2), doc.fields[0].value.list.len);
    try testing.expectEqual(@as(usize, 3), doc.issues.len);
}
