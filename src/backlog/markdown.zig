//! The Markdown body of a backlog file: its named sections and its
//! acceptance-criteria checklist.
//!
//! Backlog.md brackets each section it manages with HTML comment markers
//! (`<!-- SECTION:NOTES:BEGIN -->` … `<!-- SECTION:NOTES:END -->`,
//! `<!-- AC:BEGIN -->` … `<!-- AC:END -->`) under a `## Heading`. The markers
//! are authoritative; a hand-written file without them falls back to the text
//! between the heading and the next `## ` heading. Nothing here interprets the
//! text beyond that: it is untrusted and handed to the view as data.
//!
//! Memory: sections borrow the body. Criteria are allocated in the caller's
//! arena and their text borrows the body.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One acceptance criterion. `index` is the `#N` the tool numbers it with and
/// that `backlog task edit --check-ac N` addresses; a hand-written item
/// without one takes its 1-based position.
pub const Criterion = struct {
    index: u32,
    checked: bool,
    text: []const u8,
};

/// The bounds on one checklist.
pub const Limits = struct {
    max_criteria: usize = 256,
    max_line_bytes: usize = 16 * 1024,
};

fn trimLine(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, " \t\r");
}

/// The text of section `marker` (`DESCRIPTION`, `PLAN`, `NOTES`,
/// `FINAL_SUMMARY`), or of the `## heading` section when the markers are
/// absent. Trimmed; null when the file has neither.
pub fn section(body: []const u8, comptime marker: []const u8, heading: []const u8) ?[]const u8 {
    if (between(body, "<!-- SECTION:" ++ marker ++ ":BEGIN -->", "<!-- SECTION:" ++ marker ++ ":END -->")) |inner| {
        return std.mem.trim(u8, inner, " \t\r\n");
    }
    return headingSection(body, heading);
}

/// The text between `begin` and the next `end`, or null.
fn between(body: []const u8, begin: []const u8, end: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, body, begin) orelse return null;
    const content_start = start + begin.len;
    const stop = std.mem.indexOfPos(u8, body, content_start, end) orelse return null;
    return body[content_start..stop];
}

/// The text under `## heading` up to the next level-two heading.
pub fn headingSection(body: []const u8, heading: []const u8) ?[]const u8 {
    var offset: usize = 0;
    var content_start: ?usize = null;
    while (offset < body.len) {
        const end = std.mem.indexOfScalarPos(u8, body, offset, '\n') orelse body.len;
        const line = trimLine(body[offset..end]);
        if (std.mem.startsWith(u8, line, "## ")) {
            if (content_start) |start| return std.mem.trim(u8, body[start..offset], " \t\r\n");
            if (std.mem.eql(u8, std.mem.trim(u8, line[3..], " \t"), heading)) content_start = @min(end + 1, body.len);
        }
        offset = end + 1;
    }
    if (content_start) |start| return std.mem.trim(u8, body[start..], " \t\r\n");
    return null;
}

/// Parse the acceptance-criteria checklist: `- [ ] #1 text` / `- [x] #2 text`
/// lines inside the AC markers, or under `## Acceptance Criteria`. Lines that
/// are not checklist items are ignored. `cut` is set when the checklist
/// exceeded the limits.
pub fn acceptanceCriteria(arena: Allocator, body: []const u8, limits: Limits, cut: *bool) Allocator.Error![]const Criterion {
    const region = between(body, "<!-- AC:BEGIN -->", "<!-- AC:END -->") orelse
        headingSection(body, "Acceptance Criteria") orelse
        return &.{};
    var criteria: std.ArrayList(Criterion) = .empty;
    var lines = std.mem.splitScalar(u8, region, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const checked = if (std.mem.startsWith(u8, line, "- [ ]"))
            false
        else if (std.mem.startsWith(u8, line, "- [x]") or std.mem.startsWith(u8, line, "- [X]"))
            true
        else
            continue;
        if (criteria.items.len >= limits.max_criteria) {
            cut.* = true;
            break;
        }
        var text = std.mem.trimStart(u8, line[5..], " \t");
        var index: u32 = @intCast(criteria.items.len + 1);
        if (text.len > 1 and text[0] == '#') {
            var digits: usize = 1;
            while (digits < text.len and std.ascii.isDigit(text[digits])) digits += 1;
            if (digits > 1 and (digits == text.len or text[digits] == ' ')) {
                if (std.fmt.parseInt(u32, text[1..digits], 10)) |number| {
                    index = number;
                    text = std.mem.trimStart(u8, text[digits..], " \t");
                } else |_| {}
            }
        }
        if (text.len > limits.max_line_bytes) {
            text = text[0..limits.max_line_bytes];
            cut.* = true;
        }
        try criteria.append(arena, .{ .index = index, .checked = checked, .text = text });
    }
    return criteria.items;
}

const testing = std.testing;

test "sections come from the tool's markers, or from headings without them" {
    const marked =
        \\## Description
        \\
        \\<!-- SECTION:DESCRIPTION:BEGIN -->
        \\Read a project.
        \\<!-- SECTION:DESCRIPTION:END -->
        \\
        \\## Implementation Notes
        \\
        \\<!-- SECTION:NOTES:BEGIN -->
        \\Line one.
        \\
        \\Line two.
        \\<!-- SECTION:NOTES:END -->
    ;
    try testing.expectEqualStrings("Read a project.", section(marked, "DESCRIPTION", "Description").?);
    try testing.expectEqualStrings("Line one.\n\nLine two.", section(marked, "NOTES", "Implementation Notes").?);
    try testing.expect(section(marked, "PLAN", "Implementation Plan") == null);

    const hand_written = "## Description\n\nWritten by hand.\n\n## Other\nx\n";
    try testing.expectEqualStrings("Written by hand.", section(hand_written, "DESCRIPTION", "Description").?);
    try testing.expectEqualStrings("x", headingSection(hand_written, "Other").?);
}

test "acceptance criteria keep their numbers, check state and text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\## Acceptance Criteria
        \\<!-- AC:BEGIN -->
        \\- [ ] #1 Tasks are parsed
        \\- [x] #2 Changes update live
        \\- [X] #10 Upper-case check
        \\not an item
        \\<!-- AC:END -->
    ;
    var cut = false;
    const criteria = try acceptanceCriteria(arena, body, .{}, &cut);
    try testing.expect(!cut);
    try testing.expectEqual(@as(usize, 3), criteria.len);
    try testing.expectEqualDeep(Criterion{ .index = 1, .checked = false, .text = "Tasks are parsed" }, criteria[0]);
    try testing.expectEqual(@as(u32, 2), criteria[1].index);
    try testing.expect(criteria[1].checked);
    try testing.expectEqualStrings("Changes update live", criteria[1].text);
    try testing.expectEqual(@as(u32, 10), criteria[2].index);
    try testing.expect(criteria[2].checked);

    // Without markers or numbers: the heading's items, numbered by position.
    const plain = "## Acceptance Criteria\n- [ ] first\n- [x] second\n## Next\n- [ ] not a criterion\n";
    const positional = try acceptanceCriteria(arena, plain, .{}, &cut);
    try testing.expectEqual(@as(usize, 2), positional.len);
    try testing.expectEqual(@as(u32, 2), positional[1].index);
    try testing.expectEqualStrings("second", positional[1].text);

    // Bounded.
    const many = "<!-- AC:BEGIN -->\n- [ ] #1 a\n- [ ] #2 b\n- [ ] #3 c\n<!-- AC:END -->";
    const capped = try acceptanceCriteria(arena, many, .{ .max_criteria = 2 }, &cut);
    try testing.expectEqual(@as(usize, 2), capped.len);
    try testing.expect(cut);
}
