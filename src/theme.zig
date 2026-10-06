//! Conduit's colour model: the palette both renderers draw from.
//!
//! `theme` owns the terminal palette and the UI colours that `ui` and `render`
//! consume. It draws nothing, and it is the only place a colour may enter
//! Conduit — two renderers, one palette (P6).
//!
//! It may depend on `config`, whose built-in defaults a settings file would
//! override (TASK-37), and on nothing else. It allocates nothing: a palette is
//! a fixed-size value, so it lives on the stack, in a frame arena or inside a
//! struct `ui` owns, and its owner frees it.
//!
//! This is the TASK-4 slice. It owns the model — the colour roles and the rule
//! that maps a role onto its palette slot — and not the built-in schemes: the
//! list of schemes is TASK-38's (`docs/architecture.md` §9), and v0.1 resolves
//! every colour to a built-in default.

const std = @import("std");

/// The log scope for palette diagnostics.
pub const log = std.log.scoped(.theme);

/// How many slots a `Palette` has: the 16 ANSI roles plus the four that are
/// not one of the 16.
pub const role_count = 20;

/// How many of those slots are ANSI roles: the 8 normal colours and the 8
/// bright ones.
pub const ansi_slot_count = 16;

/// An 8-bit-per-channel colour, the form a palette stores. Alpha is part of
/// the value because a role may be drawn over the background; it is 255 for
/// every opaque role.
///
/// This is the palette's colour, not the GPU's. `render` owns the RGBA8 format
/// of the framebuffer and of a captured screenshot, and neither module may
/// import the other, so `ui` is where the two are bridged.
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
};

/// A colour role: a named thing Conduit paints, never a colour value.
///
/// The first 16 are the ANSI slots in the order every terminal palette is
/// specified — the 8 normal colours, then the 8 bright ones — so a role's slot
/// is the index an SGR colour parameter refers to. The last four are the roles
/// that are not one of the 16: the window's background and foreground, and the
/// two the semantic tree marks selection and state with.
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
    background,
    foreground,
    selection,
    accent,

    /// The palette slot this role occupies, 0 through `role_count - 1`.
    pub fn slot(self: Role) u8 {
        return @intFromEnum(self);
    }

    /// Whether the role is one of the 16 ANSI slots. The four roles above them
    /// are named colours, not SGR indices, and asking for their slot as a
    /// colour parameter would send the terminal somewhere Conduit never meant.
    pub fn isAnsi(self: Role) bool {
        return self.slot() < ansi_slot_count;
    }
};

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
};

test "the ANSI roles sit in the slots an SGR colour parameter refers to" {
    const testing = std.testing;

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
    const testing = std.testing;

    try testing.expect(!Role.background.isAnsi());
    try testing.expect(!Role.foreground.isAnsi());
    try testing.expect(!Role.selection.isAnsi());
    try testing.expect(!Role.accent.isAnsi());

    // The boundary: bright white is the last ANSI slot, background is the
    // first that is not.
    try testing.expect(Role.bright_white.isAnsi());
    try testing.expect(Role.bright_white.slot() + 1 == Role.background.slot());
    try testing.expectEqual(@as(usize, role_count), Role.accent.slot() + 1);
}
