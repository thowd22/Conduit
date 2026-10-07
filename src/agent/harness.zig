//! The closed set of harnesses the product names (CONDUIT.md §3) and the
//! spellings Conduit itself writes for them — the one thing modules outside
//! `agent` need to say "a Claude Code agent" without knowing anything else
//! about Claude Code.
//!
//! Memory: nothing here allocates. `Harness` is a value and the strings it is
//! parsed from and printed to are owned by the caller.

const std = @import("std");

/// The coding-agent CLIs Conduit drives: Claude Code, Codex and Pi
/// (CONDUIT.md §13). One adapter per harness, all of them behind the common
/// adapter interface; nothing above this module may branch on which one it is.
///
/// The set is closed, which is the enforcement of P11 at the type level: a
/// fourth harness is a product decision with its own adapter and its own task,
/// not a name that arrives as data.
pub const Harness = enum {
    claude_code,
    codex,
    pi,

    /// The error a spelling that is none of the three harnesses produces.
    pub const Error = error{UnknownHarness};

    /// Every harness Conduit ships, in the order the product catalogue lists
    /// them.
    pub const all = [_]Harness{ .claude_code, .codex, .pi };

    /// The name shown in the agent view and stored with the agent's state.
    pub fn displayName(self: Harness) []const u8 {
        return switch (self) {
            .claude_code => "Claude Code",
            .codex => "Codex",
            .pi => "Pi",
        };
    }

    /// Parse a harness from the spellings Conduit itself writes: the display
    /// name, the snake_case tag and the hyphenated tag. The match is exact —
    /// a harness named on the command line is not one this module may guess
    /// at.
    pub fn parse(text: []const u8) Error!Harness {
        inline for (@typeInfo(Harness).@"enum".fields) |field| {
            const harness: Harness = @enumFromInt(field.value);
            const tag = @tagName(harness);
            if (std.mem.eql(u8, text, harness.displayName())) return harness;
            if (std.mem.eql(u8, text, tag)) return harness;
            if (eqlHyphenated(tag, text)) return harness;
        }
        return error.UnknownHarness;
    }
};

/// Whether `text` is `tag` with its underscores written as hyphens. Written
/// as a comparison rather than a replacement so `parse` never allocates.
fn eqlHyphenated(comptime tag: []const u8, text: []const u8) bool {
    if (text.len != tag.len) return false;
    inline for (tag, 0..) |c, i| {
        const expected = if (c == '_') @as(u8, '-') else c;
        if (text[i] != expected) return false;
    }
    return true;
}

test "every harness parses back from the spellings Conduit writes" {
    const testing = std.testing;

    // The catalogue is the three harnesses named in CONDUIT.md, and no more.
    try testing.expectEqual(@as(usize, 3), Harness.all.len);

    for (Harness.all) |harness| {
        const tag = @tagName(harness);
        try testing.expectEqual(harness, try Harness.parse(harness.displayName()));
        try testing.expectEqual(harness, try Harness.parse(tag));

        // One spelling, one harness: no two harnesses answer to the same name.
        for (Harness.all) |other| {
            if (other == harness) continue;
            try testing.expect(!std.mem.eql(u8, other.displayName(), harness.displayName()));
        }
    }

    // The hyphenated spelling is the same tag written the way it is typed on
    // a command line, and it names the same harness.
    try testing.expectEqual(Harness.claude_code, try Harness.parse("claude-code"));
    try testing.expectError(error.UnknownHarness, Harness.parse("claude_code-x"));
}

test "a harness that is not one of the three is not an agent" {
    const testing = std.testing;

    for ([_][]const u8{
        "",
        "claude",
        "Claude",
        "claude code",
        "code",
        "pi2",
        "Cursor",
        "openai",
    }) |unknown| {
        try testing.expectError(error.UnknownHarness, Harness.parse(unknown));
    }
}
