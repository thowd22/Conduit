//! The settings surface: setting names and where a value comes from.
//!
//! **Owns** the settings file, its defaults, and hot reload of both.
//! **Never** owns a window, a session or a colour: a setting is data, and the module that consumes
//! it is the one that interprets it.
//! **May depend on** `std`.
//!
//! Scaffold state: this file declares the validated name a setting is addressed by and the
//! precedence rule that decides which of several sources wins. The file format, the watch and the
//! reload land with TASK-37.
//!
//! Allocates nothing: every declaration here is a value type with no owner.

const std = @import("std");

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
/// v0.1 has no settings file, so the built-in layer supplies `menu` and the
/// only other source is the session layer (`--right-click=`). The values are
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
