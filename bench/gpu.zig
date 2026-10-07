//! The GL context, fonts and colours the GPU benchmarks share.
//!
//! A hidden SDL window only provides the context: every benchmark draws into
//! `render.Surface`'s offscreen FBO, exactly as the app and `--grid-test` do,
//! so the window's own size never matters.

const std = @import("std");
const platform = @import("platform");
const render = @import("render");
const font = @import("font");
const zopengl = @import("zopengl");

const gl = zopengl.bindings;

/// The atlas size the app uses (`atlas_width_px` in `src/main.zig`).
pub const atlas_px: u32 = 1024;

/// The app's default font size in points (`config.default_font_points`).
pub const font_points: f32 = 14.0;

/// A live GL context behind a hidden window.
pub const Context = struct {
    window: platform.Window,
    renderer: []const u8,
    software: bool,

    /// Open the hidden window and load GL. Fails with `error.VideoUnavailable`
    /// when there is no display; the caller reports the case as skipped.
    pub fn open() !Context {
        var window = try platform.Window.create(.{
            .title = "conduit-bench",
            .logical = .{ .width = 320, .height = 200 },
            .hidden = true,
            .resizable = false,
            .fixed_scale = platform.Scale.fromPlatform(1.0),
        });
        errdefer window.deinit();
        try render.load();
        const renderer = std.mem.span(gl.getString(gl.RENDERER));
        return .{
            .window = window,
            .renderer = renderer,
            .software = isSoftwareRenderer(renderer),
        };
    }

    pub fn close(self: *Context) void {
        self.window.deinit();
    }
};

/// Wait for every queued GL command to complete, so a timing includes the
/// GPU's (or llvmpipe's) share of the frame.
pub fn finish() void {
    gl.finish();
}

/// Whether a `GL_RENDERER` string names a CPU rasteriser. Numbers measured on
/// one are labelled indicative: they measure the CPU, not a GPU.
pub fn isSoftwareRenderer(renderer: []const u8) bool {
    const markers = [_][]const u8{ "llvmpipe", "softpipe", "SwiftShader", "Software Rasterizer" };
    for (markers) |marker| {
        if (std.ascii.indexOfIgnoreCase(renderer, marker) != null) return true;
    }
    return false;
}

/// The app's default font stack at `scale`: the default family (empty, so the
/// manager's own default applies), ligatures on, the app's atlas size.
pub fn openFonts(gpa: std.mem.Allocator, io: std.Io, scale: f32) !font.Manager {
    return font.Manager.init(gpa, io, .{
        .size = try font.Size.init(font_points, scale),
        .home_dir = null,
        .atlas_width_px = atlas_px,
        .atlas_height_px = atlas_px,
    });
}

/// A fixed dark palette, so a benchmark never reads the user's theme.
pub fn colors() render.Colors {
    var ansi: [render.ansi_count]render.Rgba = undefined;
    const base = [_]render.Rgba{
        .{ .r = 0x1d, .g = 0x1f, .b = 0x21 }, .{ .r = 0xcc, .g = 0x66, .b = 0x66 },
        .{ .r = 0xb5, .g = 0xbd, .b = 0x68 }, .{ .r = 0xf0, .g = 0xc6, .b = 0x74 },
        .{ .r = 0x81, .g = 0xa2, .b = 0xbe }, .{ .r = 0xb2, .g = 0x94, .b = 0xbb },
        .{ .r = 0x8a, .g = 0xbe, .b = 0xb7 }, .{ .r = 0xc5, .g = 0xc8, .b = 0xc6 },
    };
    for (0..8) |index| {
        ansi[index] = base[index];
        ansi[index + 8] = .{
            .r = base[index].r +| 0x20,
            .g = base[index].g +| 0x20,
            .b = base[index].b +| 0x20,
        };
    }
    return .{ .ansi = ansi };
}

test "software renderers are recognised by their GL_RENDERER string" {
    try std.testing.expect(isSoftwareRenderer("llvmpipe (LLVM 19.1.1, 256 bits)"));
    try std.testing.expect(isSoftwareRenderer("Mesa softpipe"));
    try std.testing.expect(!isSoftwareRenderer("AMD Radeon Graphics (radeonsi, renoir)"));
}
