//! Conduit's GPU surface and everything drawn into it.
//!
//! `render` owns the framebuffer the renderer *always* draws into, the shaders
//! and programs, the viewport and scissor, `present`, and `capture`
//! (`glReadPixels`). The grid renderer and the UI renderer are two draw
//! sequences into that one target — that is P6 as call order.
//!
//! It never decides what to draw: it draws what `ui` hands it, and owns no
//! product or layout state. It never calls an SDL window or event function, and
//! it never blocks on IO. It may depend on `platform` for the window and the GL
//! context, and on `zopengl` for the bindings.
//!
//! Memory: the FBO, the readback buffer and the atlas are allocated once and
//! reused — `capture` reads into a buffer the caller owns precisely so a
//! screenshot does not allocate — because the hot path may not allocate per
//! frame. PNG encoding is deliberately outside the hot path and returns one
//! caller-owned allocation for a worker to persist. The value types below
//! allocate nothing.
//!
//! This is the TASK-7 slice: the surface the renderer always draws into, the
//! blit that puts it on screen, and the readback that proves what a user would
//! see. The grid renderer itself is TASK-11. TASK-22 adds the PNG encoder, while
//! `capture` still hands back pixels so filesystem IO can remain off the render
//! thread.
//!
//! ## The grid renderer (TASK-11)
//!
//! `Grid` draws the terminal's cells into that surface: a background rectangle
//! and a glyph per cell, the attribute decorations SGR can ask for, and the
//! cursor in the shape and phase the terminal says it is in. It reads
//! `term.damage()` and redraws the rows that changed and no others, and it
//! rasterises and places every glyph at the physical pixel size the surface
//! actually has, which is what makes a HiDPI window sharp rather than scaled.
//!
//! ## How glyphs are sampled, and why
//!
//! The glyph coverage mask lives in one CPU atlas (`font`) and is uploaded as
//! a single `GL_R8` texture. Sampling is a plain `texture(atlas, uv)` in the
//! fragment shader, with the sampler state set once on the texture object:
//! OpenGL 3.3 core has no sampler objects (they arrived in 3.5 / ARB), and no
//! compute shaders either, so there is nothing to bind per draw and nothing
//! to dispatch. NEAREST on both filters and `CLAMP_TO_EDGE` on both axes is
//! the whole sampling story: a glyph is a stencil of whole texels, so anything
//! that interpolated between them would bleed a neighbour's coverage into it.
//! The one thing that must be exact is the half-texel inset in `uvOf`, which
//! puts each sample at a texel centre rather than on a boundary.
//!
//! Both draw sequences are **instanced**: the base quad is six corners built
//! from `gl_VertexID`, so there is no vertex buffer at all, and every rectangle
//! in a frame is one instance carrying its own rectangle, and for a glyph its
//! atlas rectangle and colour. That is what keeps a frame to two `glDrawArraysInstanced`
//! calls and one buffer upload whatever the grid's size, and it is why "no
//! per-frame allocation" survives here: the instance arrays are the renderer's
//! own buffers, reserved when the grid changes size and cleared — never freed
//! and reallocated — every frame.
//!
//! TASK-30 adds `GridViewport` and `Grid.drawViewport`. A viewport is an
//! absolute, top-down pixel rectangle on the shared surface; callers that lay
//! panes out in cells use `GridViewport.fromCells`. Each pane owns a separate
//! `Grid`, so its damage, cursor and retained staging state are independent.
//! Viewport clears and all three terminal passes are scissored to that pane.
//! Layout, the one-cell gaps used as dividers, and clearing pixels vacated by a
//! layout change remain the app compositor's responsibility.
//!
//! TASK-39 (font manager v2): a cell's glyph is whatever `font.Manager.resolve`
//! finds through its fallback chain, built-in box/Powerline sprites included,
//! and a wide cell asks for a glyph fitted to two cells. Colour glyphs (emoji)
//! live in the manager's RGBA colour atlas, are queued in `color_glyphs` and
//! drawn by a third instanced pass that samples an `RGBA8` texture unmodulated
//! with premultiplied blending. With ligatures on, runs of printable ASCII that
//! contain ligature punctuation are shaped together (`addLigatureRow`), and each
//! resulting glyph is still drawn in the cell its cluster came from.

const std = @import("std");
const platform = @import("platform");
const zopengl = @import("zopengl");
const font = @import("font");
const term = @import("term");

/// The OpenGL entry points, loaded once by `load` against the current context.
const gl = zopengl.bindings;

/// The log scope for surface diagnostics.
pub const log = std.log.scoped(.render);

/// A colour in the surface's own format.
///
/// The framebuffer's colour texture and a captured screenshot are both RGBA8
/// (decision-2), so a colour that crosses this module's boundary is eight bits
/// per channel rather than a float. This is not `theme.Color`: the palette is
/// `theme`'s and this module may not import it, so `ui` is where a palette
/// colour becomes a surface colour.
pub const Rgba = struct {
    /// Red, 0 to 255.
    r: u8,
    /// Green, on the same scale as `r`.
    g: u8,
    /// Blue, on the same scale as `r`.
    b: u8,
    /// Coverage over what is behind the colour. Defaults to opaque because the
    /// surface is cleared opaque and every colour drawn over it is opaque
    /// unless something deliberately composites.
    a: u8 = 255,

    /// The colour as the normalised floats `glClearColor` and the shaders
    /// take. 8-bit channels are not evenly spaced, so each is divided by 255
    /// rather than scaled by a constant.
    pub fn toFloats(self: Rgba) [4]f32 {
        return .{
            @as(f32, @floatFromInt(self.r)) / 255.0,
            @as(f32, @floatFromInt(self.g)) / 255.0,
            @as(f32, @floatFromInt(self.b)) / 255.0,
            @as(f32, @floatFromInt(self.a)) / 255.0,
        };
    }
};

/// A size in device pixels — the window's size multiplied by the scale, so
/// every dimension the renderer reasons about is already scaled and nothing
/// downstream multiplies a second time.
pub const Size = struct {
    /// Width in device pixels.
    width: u32,
    /// Height in device pixels.
    height: u32,

    /// How many pixels the size covers, in a type wide enough that a large
    /// surface cannot overflow it.
    pub fn area(self: Size) u64 {
        return @as(u64, self.width) * @as(u64, self.height);
    }

    /// The size at a display scale, rounded to whole pixels: a framebuffer
    /// cannot be a fraction of a pixel across.
    ///
    /// The scale arrives from the display rather than from Conduit, so an
    /// absurd or negative one saturates at zero and at the largest representable
    /// size instead of trapping the render thread.
    pub fn scaled(self: Size, factor: f32) Size {
        return .{
            .width = scaleDimension(self.width, factor),
            .height = scaleDimension(self.height, factor),
        };
    }

    /// Whether two sizes are the same size.
    ///
    /// A named comparison rather than `==` on the struct, because the places that
    /// need it — a resize to the size already in use — are exactly the places
    /// where "did anything actually move" is the whole question.
    pub fn eql(a: Size, b: Size) bool {
        return a.width == b.width and a.height == b.height;
    }
};

/// One dimension at a display scale: rounded to the nearest whole pixel and
/// clamped into the range a u32 can hold.
fn scaleDimension(dimension: u32, factor: f32) u32 {
    const exact: f64 = @as(f64, @floatFromInt(dimension)) * @as(f64, factor);
    const rounded = std.math.clamp(@round(exact), 0.0, @as(f64, std.math.maxInt(u32)));
    return @intFromFloat(rounded);
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// What the GPU refuses, and how Conduit says so. Every value here is a driver
/// or a context answering "no": all of them are logged and returned, never
/// asserted on (CONDUIT.md §11).
pub const GlError = error{
    /// `glGetError` returned something other than `GL_NO_ERROR`.
    GlCallFailed,
    /// The framebuffer is not complete: the colour texture the driver would not
    /// accept. A 3.3 core context has no geometry shader or anything else a
    /// framebuffer can be missing, so this is a driver that ran out of memory.
    IncompleteFramebuffer,
};

/// What `read` refuses before it touches the GPU. A buffer too small for the
/// surface is a caller's mistake, and catching it here costs nothing.
pub const ReadbackError = error{
    /// The caller's buffer cannot hold the whole surface.
    CaptureBufferTooSmall,
};

// ---------------------------------------------------------------------------
// The surface
// ---------------------------------------------------------------------------

/// Load every OpenGL entry point this module uses, through the loader `platform`
/// owns.
///
/// Called once, after `platform.Window.create` has left a context current:
/// `SDL_GL_GetProcAddress` only answers for the current context. The bindings
/// live in `zopengl`'s globals for the life of the process, which is why there
/// is no matching `unload` to forget to call.
pub fn load() !void {
    try zopengl.loadCoreProfile(
        &platform.glProcAddress,
        @as(u32, @intCast(platform.gl_major_version)),
        @as(u32, @intCast(platform.gl_minor_version)),
    );
    log.info("OpenGL {s} on {s}, GLSL {s}", .{
        glString(gl.RENDERER),
        glString(gl.VERSION),
        glString(gl.SHADING_LANGUAGE_VERSION),
    });
}

/// A GL string as a slice. GL hands back a NUL-terminated string that stays
/// valid until the context is destroyed, so the slice is a view, not a copy.
fn glString(name: gl.Enum) []const u8 {
    return std.mem.span(gl.getString(name));
}

/// The bytes `read` writes for a surface of `size`: RGBA8, four bytes a pixel,
/// and no padding between rows because `read` sets `GL_PACK_ALIGNMENT` to 1.
pub fn readbackLen(size: Size) usize {
    return @as(usize, @intCast(size.area())) * 4;
}

/// Whether `len` bytes are enough to capture a surface of `size`.
///
/// This is the whole of the readback's size rule, and it is a function rather
/// than an expression inside `read` so the caller can check a buffer *before*
/// reserving one — and so the rule can be a unit test without a GPU.
pub fn captureFits(size: Size, len: usize) bool {
    return len >= readbackLen(size);
}

// ---------------------------------------------------------------------------
// PNG encoding
// ---------------------------------------------------------------------------

/// Invalid RGBA input or an image too large for this encoder's single IDAT
/// chunk.
pub const PngError = error{
    /// PNG does not permit either image dimension to be zero.
    InvalidImageSize,
    /// The input must contain exactly four bytes for every pixel.
    InvalidPixelLength,
    /// The image or compressed stream cannot be represented by this encoder.
    ImageTooLarge,
    /// Storage for compression or the resulting PNG could not be allocated.
    OutOfMemory,
};

/// Encode top-down RGBA8 pixels as a deterministic PNG byte stream.
///
/// Ownership: the returned slice belongs to `allocator` and the caller must
/// free it. Encoding performs no filesystem IO, so a screenshot worker can
/// persist the result without blocking the render thread. `pixels` is read in
/// its existing row order; `Surface.read` has already converted OpenGL's
/// bottom-up rows to top-down rows.
pub fn encodePng(
    allocator: std.mem.Allocator,
    size: Size,
    pixels: []const u8,
) PngError![]u8 {
    if (size.width == 0 or size.height == 0) return error.InvalidImageSize;

    const pixel_len_u64 = std.math.mul(u64, size.area(), 4) catch
        return error.ImageTooLarge;
    if (pixel_len_u64 > std.math.maxInt(usize)) return error.ImageTooLarge;
    const pixel_len: usize = @intCast(pixel_len_u64);
    if (pixels.len != pixel_len) return error.InvalidPixelLength;

    const filtered_len_u64 = std.math.add(u64, pixel_len_u64, size.height) catch
        return error.ImageTooLarge;
    // A single IDAT makes output deterministic and keeps the API small. PNG
    // chunk lengths are 32-bit, and deflate can be slightly larger than its
    // input, so leave room for its framing and worst-case block overhead.
    if (filtered_len_u64 > std.math.maxInt(u32) - 64) return error.ImageTooLarge;

    var compressed = std.Io.Writer.Allocating.initCapacity(allocator, 256) catch
        return error.OutOfMemory;
    defer compressed.deinit();

    var compression_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = std.compress.flate.Compress.init(
        &compressed.writer,
        &compression_buffer,
        .zlib,
        .default,
    ) catch return error.OutOfMemory;

    const row_len: usize = @as(usize, @intCast(size.width)) * 4;
    for (0..@as(usize, @intCast(size.height))) |row| {
        compressor.writer.writeByte(0) catch return error.OutOfMemory;
        const start = row * row_len;
        compressor.writer.writeAll(pixels[start..][0..row_len]) catch
            return error.OutOfMemory;
    }
    compressor.finish() catch return error.OutOfMemory;

    const idat = compressed.written();
    if (idat.len > std.math.maxInt(u32)) return error.ImageTooLarge;
    const png_capacity = std.math.add(usize, idat.len, 57) catch
        return error.ImageTooLarge;
    var png = std.Io.Writer.Allocating.initCapacity(allocator, png_capacity) catch
        return error.OutOfMemory;
    defer png.deinit();

    png.writer.writeAll("\x89PNG\r\n\x1a\n") catch return error.OutOfMemory;

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], size.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], size.height, .big);
    ihdr[8] = 8; // eight bits per channel
    ihdr[9] = 6; // truecolour with alpha
    ihdr[10] = 0; // deflate compression
    ihdr[11] = 0; // adaptive filtering
    ihdr[12] = 0; // no interlace
    writePngChunk(&png.writer, "IHDR", &ihdr) catch return error.OutOfMemory;
    writePngChunk(&png.writer, "IDAT", idat) catch return error.OutOfMemory;
    writePngChunk(&png.writer, "IEND", &.{}) catch return error.OutOfMemory;

    return png.toOwnedSlice() catch return error.OutOfMemory;
}

fn writePngChunk(
    writer: *std.Io.Writer,
    chunk_type: *const [4]u8,
    data: []const u8,
) std.Io.Writer.Error!void {
    try writer.writeInt(u32, @intCast(data.len), .big);
    try writer.writeAll(chunk_type);
    try writer.writeAll(data);

    var crc = std.hash.Crc32.init();
    crc.update(chunk_type);
    crc.update(data);
    try writer.writeInt(u32, crc.final(), .big);
}

/// The framebuffer every draw goes into.
///
/// Ownership: `fbo` and `color` are GL object names, not heap memory, so this
/// allocates nothing, and `deinit` gives both back. The readback buffer is the
/// caller's — see `read` — which is why a screenshot allocates nothing either.
pub const Surface = struct {
    /// The framebuffer object, `0` until `resize` has created it.
    fbo: gl.Uint = 0,
    /// The RGBA8 colour texture attached to it.
    color: gl.Uint = 0,
    /// The size the texture is currently at. `{0, 0}` means "not created yet".
    size: Size = .{ .width = 0, .height = 0 },

    /// Create the surface at `size`.
    pub fn init(size: Size) !Surface {
        var surface = Surface{};
        errdefer surface.deinit();
        try surface.resize(size);
        return surface;
    }

    /// Give the GL objects back. Safe on a surface that was never created, and
    /// safe to call twice.
    pub fn deinit(self: *Surface) void {
        if (self.fbo != 0) gl.deleteFramebuffers(1, &self.fbo);
        if (self.color != 0) gl.deleteTextures(1, &self.color);
        self.* = undefined;
    }

    /// Put the surface at `size`.
    ///
    /// Re-specifying the texture at the new size *is* the resize: the object
    /// names survive, so nothing that holds the surface has to be told, and a
    /// window event that moves the window and puts it back where it was costs a
    /// log line rather than a texture reallocation.
    pub fn resize(self: *Surface, size: Size) !void {
        // A surface of no pixels is not a surface, and a compositor mid-resize
        // will happily report a zero for a moment.
        const wanted = Size{ .width = @max(size.width, 1), .height = @max(size.height, 1) };
        if (self.fbo != 0 and self.size.eql(wanted)) return;

        if (self.color == 0) gl.genTextures(1, &self.color);
        if (self.fbo == 0) gl.genFramebuffers(1, &self.fbo);
        try checkGl("genTextures/genFramebuffers");

        gl.bindTexture(gl.TEXTURE_2D, self.color);
        gl.texImage2D(
            gl.TEXTURE_2D,
            0,
            gl.RGBA8,
            @as(gl.Sizei, @intCast(wanted.width)),
            @as(gl.Sizei, @intCast(wanted.height)),
            0,
            gl.RGBA,
            gl.UNSIGNED_BYTE,
            null,
        );
        // Linear filtering so a surface that is a pixel or two off the
        // drawable's size still presents as an image rather than as a mosaic.
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        try checkGl("texImage2D");

        gl.bindFramebuffer(gl.FRAMEBUFFER, self.fbo);
        gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, self.color, 0);
        // A 3.3 core context has no default draw buffer for a user framebuffer,
        // so the attachment has to be named explicitly or the framebuffer is
        // incomplete and every draw into it is dropped.
        const attachments = [_]gl.Enum{gl.COLOR_ATTACHMENT0};
        gl.drawBuffers(1, &attachments);
        const status = gl.checkFramebufferStatus(gl.FRAMEBUFFER);
        gl.bindFramebuffer(gl.FRAMEBUFFER, 0);
        if (status != gl.FRAMEBUFFER_COMPLETE) {
            log.err("framebuffer incomplete at {d}x{d}: status 0x{X}", .{
                wanted.width,
                wanted.height,
                status,
            });
            return error.IncompleteFramebuffer;
        }
        try checkGl("framebuffer setup");

        self.size = wanted;
        log.debug("surface is {d}x{d}", .{ wanted.width, wanted.height });
    }

    /// Make the surface the target of the next draw, with the viewport covering
    /// exactly its pixels and no scissor left behind by an earlier frame.
    pub fn bind(self: *const Surface) void {
        gl.bindFramebuffer(gl.FRAMEBUFFER, self.fbo);
        gl.viewport(0, 0, @as(gl.Int, @intCast(self.size.width)), @as(gl.Int, @intCast(self.size.height)));
        gl.disable(gl.SCISSOR_TEST);
    }

    /// Clear the whole surface to `color`. The first thing every frame does.
    pub fn clear(self: *const Surface, color: Rgba) void {
        self.bind();
        const channels = color.toFloats();
        gl.clearColor(channels[0], channels[1], channels[2], channels[3]);
        gl.clear(gl.COLOR_BUFFER_BIT);
    }

    /// Read the surface back into `buffer` and return the filled prefix.
    ///
    /// Ownership: `buffer` belongs to the caller and is written in place. Nothing
    /// here allocates, which is what lets a screenshot be taken in the middle of
    /// a frame.
    ///
    /// Rows come back from GL bottom-up and are flipped here, so the buffer is
    /// top-down like every image format Conduit writes.
    ///
    /// No fence, no `glFinish` and no sleep: `glReadPixels` is a synchronising
    /// read — the specification requires the values to be those of the rendering
    /// that preceded it — so the pixels are the ones just drawn. decision-2
    /// recorded "no fence is needed on the readback path" as an inference for
    /// TASK-7 to prove, and `--self-test` proves it by capturing immediately
    /// after the draw with nothing in between and checking every pixel.
    pub fn read(self: *const Surface, buffer: []u8) (GlError || ReadbackError)![]u8 {
        const needed = readbackLen(self.size);
        if (!captureFits(self.size, buffer.len)) return error.CaptureBufferTooSmall;

        // The read framebuffer is bound, never the draw framebuffer: a capture
        // in the middle of a frame must not redirect what the renderer is
        // drawing into.
        gl.bindFramebuffer(gl.READ_FRAMEBUFFER, self.fbo);
        // One byte of alignment. The default is four, which pads a row whose
        // width is not a multiple of four and shears the image.
        gl.pixelStorei(gl.PACK_ALIGNMENT, 1);
        gl.readPixels(
            0,
            0,
            @as(gl.Sizei, @intCast(self.size.width)),
            @as(gl.Sizei, @intCast(self.size.height)),
            gl.RGBA,
            gl.UNSIGNED_BYTE,
            buffer.ptr,
        );
        try checkGl("glReadPixels");
        gl.bindFramebuffer(gl.READ_FRAMEBUFFER, 0);

        flipVertically(buffer, self.size);
        return buffer[0..needed];
    }

    /// Copy the surface onto the window's default framebuffer, if the window is
    /// on screen, and hand it to the window system.
    ///
    /// A hidden window gets nothing: its pixels are read from the FBO instead
    /// (doc-2). That is what makes a headless capture the same image a user
    /// would see — one renderer, one surface, two ways of reading it.
    pub fn present(self: *const Surface, window: *const platform.Window) GlError!void {
        if (!window.isVisible()) return;
        const width: gl.Int = @intCast(self.size.width);
        const height: gl.Int = @intCast(self.size.height);
        gl.bindFramebuffer(gl.READ_FRAMEBUFFER, self.fbo);
        gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, 0);
        gl.blitFramebuffer(0, 0, width, height, 0, 0, width, height, gl.COLOR_BUFFER_BIT, gl.NEAREST);
        gl.bindFramebuffer(gl.FRAMEBUFFER, 0);
        try checkGl("present blit");
        window.swap();
    }
};

/// Reverse the row order of a readback, in place.
///
/// GL returns the first row at the bottom of the framebuffer and every image
/// format Conduit writes puts its first row at the top. The swap is in place and
/// allocation-free, because a screenshot must not allocate.
fn flipVertically(buffer: []u8, size: Size) void {
    if (size.height < 2) return;
    const row: usize = @as(usize, size.width) * 4;
    var top: usize = 0;
    var bottom: usize = (@as(usize, size.height) - 1) * row;
    while (top < bottom) {
        for (0..row) |x| std.mem.swap(u8, &buffer[top + x], &buffer[bottom + x]);
        top += row;
        bottom -= row;
    }
}

/// Drain GL's error queue and turn the first error into an error value.
///
/// GL reports failure by queueing a flag rather than by returning anything, so a
/// call whose failure would otherwise be silent checks here. The queue is
/// drained to `GL_NO_ERROR` — bounded, because a broken driver can queue one
/// error per call for ever — so that one mistake does not turn every later call
/// into an error too.
fn checkGl(what: []const u8) GlError!void {
    var first: gl.Enum = gl.NO_ERROR;
    for (0..32) |_| {
        const code = gl.getError();
        if (code == gl.NO_ERROR) break;
        if (first == gl.NO_ERROR) first = code;
    }
    if (first == gl.NO_ERROR) return;
    log.err("{s}: OpenGL error 0x{X}", .{ what, first });
    return error.GlCallFailed;
}

// ---------------------------------------------------------------------------
// Colours the grid draws with
// ---------------------------------------------------------------------------

/// How many of the terminal's 256 palette slots a theme owns. The other 240
/// are fixed by every terminal that ever drew them, so they are arithmetic
/// here rather than a theme's business.
pub const ansi_count = 16;

/// The six levels each axis of the 6x6x6 colour cube is built from.
pub const cube_levels = [_]u8{ 0, 95, 135, 175, 215, 255 };

/// The colour of terminal palette slot `index`, for 16 and above: the 6x6x6
/// cube (16 to 231) and the 24 greyscale steps (232 to 255).
///
/// These slots are defined by what every terminal has always drawn and no
/// palette changes them, which is exactly why they belong here. Slots below
/// 16 do not: those are the theme's, and they come from `Colors.ansi`.
pub fn cube(index: u8) Rgba {
    if (index < 232) {
        const offset = index - 16;
        return .{
            .r = cube_levels[offset / 36],
            .g = cube_levels[(offset / 6) % 6],
            .b = cube_levels[offset % 6],
        };
    }
    const grey: u8 = 8 + (index - 232) * 10;
    return .{ .r = grey, .g = grey, .b = grey };
}

/// The colours the grid draws with, already in the surface's own format.
///
/// `theme` owns the palette and this module has no edge to it, so the caller
/// converts: a `theme.Color` becomes an `Rgba` before it arrives here, and
/// every colour that reaches the GPU arrived that way. Nothing in this type is
/// a palette type, which is what keeps the two modules apart.
pub const Colors = struct {
    /// The 16 ANSI slots in SGR order, which is where `theme.Role`'s first
    /// sixteen slots live. Deliberately without a default: a grid with an
    /// implicit palette is a grid whose colours nobody chose.
    ansi: [ansi_count]Rgba,
    /// What `term.Color.default` means for text.
    foreground: Rgba = .{ .r = 0xd8, .g = 0xd8, .b = 0xe0 },
    /// What `term.Color.default` means for a cell's background.
    background: Rgba = .{ .r = 0x16, .g = 0x1a, .b = 0x22 },
    /// The cursor's own colour.
    cursor: Rgba = .{ .r = 0xd8, .g = 0xd8, .b = 0xe0 },

    /// The background a selected cell is painted.
    ///
    /// Painted *under* the cell's own background rather than over its
    /// foreground, so a selected cell keeps its glyph and its underline and
    /// strikethrough — inverting them would make a selection of coloured
    /// output unreadable, which is most of what people select. A cell whose own
    /// background is set keeps it and is drawn with the selection only when its
    /// background is the default, because a program's own background is
    /// information and overwriting it loses it.
    selection: Rgba = .{ .r = 0x2c, .g = 0x3a, .b = 0x4d },

    /// The colour a terminal colour resolves to. `foreground` says which of
    /// the two default slots `.default` means, because the same `.default` is
    /// text in one place and a cell background in another.
    pub fn resolve(self: Colors, color: term.Color, foreground: bool) Rgba {
        return switch (color) {
            .default => if (foreground) self.foreground else self.background,
            .rgb => |rgb| .{ .r = rgb.r, .g = rgb.g, .b = rgb.b },
            .palette => |index| if (index < ansi_count) self.ansi[index] else cube(index),
        };
    }
};

/// A colour mixed towards what it is drawn on, which is how "faint" reads on a
/// terminal that has one face per family rather than a lighter weight.
pub fn faint(color: Rgba, background: Rgba) Rgba {
    return .{
        .r = mix(color.r, background.r),
        .g = mix(color.g, background.g),
        .b = mix(color.b, background.b),
    };
}

/// Subtly reduce inactive-pane contrast without changing opacity.
///
/// Seven eighths of the original colour is retained and one eighth comes from
/// the terminal's default background. This keeps inactive text readable while
/// making focus visible, and makes the default background itself unchanged so
/// pane bounds do not flash when focus moves.
pub fn inactivePaneColor(color: Rgba, background: Rgba) Rgba {
    return .{
        .r = dimChannel(color.r, background.r),
        .g = dimChannel(color.g, background.g),
        .b = dimChannel(color.b, background.b),
        .a = color.a,
    };
}

fn dimChannel(value: u8, background: u8) u8 {
    return @intCast((@as(u16, value) * 7 + @as(u16, background)) / 8);
}

/// The configured face selected by the two independent SGR font attributes.
///
/// Weight and slant select a face only. Colour is resolved separately by
/// `Grid.addCell`, so asking for bold text never turns an ANSI colour into its
/// bright counterpart or otherwise changes an explicit palette/truecolor
/// value.
fn faceStyle(attributes: term.Style.Attributes) font.FaceStyle {
    if (attributes.bold) {
        return if (attributes.italic) .bold_italic else .bold;
    }
    return if (attributes.italic) .italic else .regular;
}

/// Two thirds of `channel` and one third of `behind`, in whole bytes.
fn mix(channel: u8, behind: u8) u8 {
    return @intCast((2 * @as(u32, channel) + @as(u32, behind)) / 3);
}

// ---------------------------------------------------------------------------
// Layout, in device pixels
// ---------------------------------------------------------------------------

/// The size of the glyph atlas texture, which is the size of the CPU atlas it
/// is uploaded from.
pub const AtlasSize = struct {
    /// Width in pixels.
    width_px: u32,
    /// Height in pixels.
    height_px: u32,
};

/// A rectangle in device pixels, with `y` counted down from the top of the
/// surface: the same way round as the grid's rows. The vertex shader converts
/// it to GL's bottom-up clip space, so nothing downstream has to know that GL
/// counts the other way.
pub const PixelRect = struct {
    /// Left edge, in device pixels from the left of the surface.
    x: f32 = 0,
    /// Top edge, in device pixels from the top of the surface.
    y: f32 = 0,
    /// Width in device pixels.
    width: f32 = 0,
    /// Height in device pixels.
    height: f32 = 0,
};

/// A zero-based position in the shared canvas's cell coordinate system.
pub const CellPoint = struct {
    /// Columns from the left edge of the shared canvas.
    col: u32,
    /// Rows from the top edge of the shared canvas.
    row: u32,
};

/// An integer pixel rectangle clipped to a surface, with a top-down Y axis.
///
/// This is the renderer-neutral form of an OpenGL scissor. The GL boundary
/// converts its Y coordinate to bottom-up immediately before `glScissor`.
pub const ViewportBounds = struct {
    /// Left edge in device pixels.
    x_px: u32,
    /// Top edge in device pixels.
    y_px: u32,
    /// Clipped width in device pixels.
    width_px: u32,
    /// Clipped height in device pixels.
    height_px: u32,
};

/// One terminal grid's bounded rectangle on the shared GPU surface.
///
/// Coordinates and dimensions are device pixels. `fromCells` is the normal
/// pane-layout bridge: it converts an absolute cell origin and terminal size
/// using the font's already-scaled cell metrics. A viewport may extend beyond
/// the surface; `clipped` intersects it safely, and an empty intersection
/// performs no GPU work. `dimmed` only transforms terminal ink and cell
/// backgrounds; the shared UI overlay remains at its theme colours.
pub const GridViewport = struct {
    /// Left edge in device pixels from the surface's left edge.
    x_px: u32,
    /// Top edge in device pixels from the surface's top edge.
    y_px: u32,
    /// Hard clipping width in device pixels.
    width_px: u32,
    /// Hard clipping height in device pixels.
    height_px: u32,
    /// Whether this terminal is an inactive pane and should be subtly dimmed.
    dimmed: bool = false,

    /// Convert a cell-aligned pane rectangle to device pixels.
    pub fn fromCells(origin: CellPoint, size: term.GridSize, cell: font.CellSize) GridViewport {
        return .{
            .x_px = saturatingPixels(origin.col, cell.width_px),
            .y_px = saturatingPixels(origin.row, cell.height_px),
            .width_px = saturatingPixels(size.cols, cell.width_px),
            .height_px = saturatingPixels(size.rows, cell.height_px),
        };
    }

    /// Return this viewport's non-empty intersection with `surface`.
    pub fn clipped(self: GridViewport, surface: Size) ?ViewportBounds {
        const right = @min(saturatingAdd(self.x_px, self.width_px), surface.width);
        const bottom = @min(saturatingAdd(self.y_px, self.height_px), surface.height);
        const left = @min(self.x_px, surface.width);
        const top = @min(self.y_px, surface.height);
        if (right <= left or bottom <= top) return null;
        return .{
            .x_px = left,
            .y_px = top,
            .width_px = right - left,
            .height_px = bottom - top,
        };
    }

    /// Place a terminal-local cell at its absolute surface position.
    pub fn cellRect(self: GridViewport, col: u16, row: u16, cell: font.CellSize) PixelRect {
        var rect = render.cellRect(col, row, cell);
        rect.x += @floatFromInt(self.x_px);
        rect.y += @floatFromInt(self.y_px);
        return rect;
    }
};

const render = @This();

fn saturatingPixels(cells: anytype, pixels: u32) u32 {
    return std.math.mul(u32, @as(u32, @intCast(cells)), pixels) catch std.math.maxInt(u32);
}

fn saturatingAdd(a: u32, b: u32) u32 {
    return std.math.add(u32, a, b) catch std.math.maxInt(u32);
}

/// The rectangle of one cell, from the grid's own arithmetic: cell `n` is
/// `cell * n` pixels from the left and `cell * row` pixels from the top. Every
/// dimension is already in device pixels because `font.Size.pixels` folds the
/// display scale into the face's pixel size, so a HiDPI grid is the same
/// arithmetic on twice the numbers rather than a second code path.
pub fn cellRect(col: u16, row: u16, cell: font.CellSize) PixelRect {
    const width: f32 = @floatFromInt(cell.width_px);
    const height: f32 = @floatFromInt(cell.height_px);
    return .{
        .x = @as(f32, @floatFromInt(col)) * width,
        .y = @as(f32, @floatFromInt(row)) * height,
        .width = width,
        .height = height,
    };
}

/// The rectangle of one terminal cell after the workspace UI's left inset.
///
/// Overlay cells deliberately continue to use `cellRect` directly: their
/// coordinates are absolute in the full canvas, while terminal columns start
/// after `origin_columns`.
fn terminalCellRect(col: u16, row: u16, cell: font.CellSize, origin_columns: u16) PixelRect {
    var rect = cellRect(col, row, cell);
    rect.x += @as(f32, @floatFromInt(origin_columns)) * rect.width;
    return rect;
}

/// The rectangle a glyph's coverage mask goes in: its cell, moved by the
/// bearing FreeType reported and by the cell's own baseline. A glyph that
/// overhangs its cell — an accent, an italic — spills into the neighbouring
/// cells, and none of that reaches the grid arithmetic.
pub fn glyphRect(cell: PixelRect, baseline_px: u32, entry: font.Entry) PixelRect {
    return .{
        .x = cell.x + @as(f32, @floatFromInt(entry.bearing_x_px)),
        .y = cell.y + @as(f32, @floatFromInt(baseline_px)) - @as(f32, @floatFromInt(entry.bearing_y_px)),
        .width = @floatFromInt(entry.rect.width),
        .height = @floatFromInt(entry.rect.height),
    };
}

/// The atlas coordinates of a glyph, inset half a texel at each end so that
/// every sample lands in the middle of a texel rather than on the seam between
/// two of them. This is the only reason the glyph pass is not a mosaic.
pub fn uvOf(rect: font.Rect, atlas: AtlasSize) [4]f32 {
    const width: f32 = @floatFromInt(atlas.width_px);
    const height: f32 = @floatFromInt(atlas.height_px);
    return .{
        (@as(f32, @floatFromInt(rect.x)) + 0.5) / width,
        (@as(f32, @floatFromInt(rect.y)) + 0.5) / height,
        (@as(f32, @floatFromInt(rect.x + rect.width)) - 0.5) / width,
        (@as(f32, @floatFromInt(rect.y + rect.height)) - 0.5) / height,
    };
}

/// How many rectangles the hollow cursor is drawn as: a block with its middle
/// left empty is four bars.
pub const max_cursor_rects = 4;

/// A cursor as the rectangles that draw it.
pub const CursorPaint = struct {
    rects: [max_cursor_rects]PixelRect = [_]PixelRect{.{}} ** max_cursor_rects,
    count: u8 = 0,

    fn add(self: *CursorPaint, rect: PixelRect) void {
        self.rects[self.count] = rect;
        self.count += 1;
    }
};

/// The rectangles that draw `shape` over `cell`.
///
/// The filled shapes are one rectangle and the hollow one is four bars with
/// nothing in the middle, so the cell's own colours and glyph show through the
/// centre rather than being painted over with the cursor's colour.
pub fn cursorPaint(shape: term.CursorShape, cell: PixelRect, thickness: f32) CursorPaint {
    var paint = CursorPaint{};
    const t = @min(thickness, @min(cell.width, cell.height) / 2);
    switch (shape) {
        .block => paint.add(cell),
        .block_hollow => {
            paint.add(.{ .x = cell.x, .y = cell.y, .width = cell.width, .height = t });
            paint.add(.{
                .x = cell.x,
                .y = cell.y + cell.height - t,
                .width = cell.width,
                .height = t,
            });
            paint.add(.{ .x = cell.x, .y = cell.y + t, .width = t, .height = cell.height - 2 * t });
            paint.add(.{
                .x = cell.x + cell.width - t,
                .y = cell.y + t,
                .width = t,
                .height = cell.height - 2 * t,
            });
        },
        .bar => paint.add(.{ .x = cell.x, .y = cell.y, .width = t, .height = cell.height }),
        .underline => paint.add(.{
            .x = cell.x,
            .y = cell.y + cell.height - t,
            .width = cell.width,
            .height = t,
        }),
    }
    return paint;
}

// ---------------------------------------------------------------------------
// Shaders
// ---------------------------------------------------------------------------

/// One rectangle per instance, filled with that instance's colour. Used for
/// cell backgrounds, the attribute decorations and the cursor.
const solid_vertex_source =
    \\#version 330 core
    \\const vec2 corners[6] = vec2[6](
    \\    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(1.0, 1.0),
    \\    vec2(0.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)
    \\);
    \\layout(location = 0) in vec4 i_rect;
    \\layout(location = 1) in vec4 i_color;
    \\uniform vec2 u_viewport;
    \\out vec4 v_color;
    \\
    \\void main() {
    \\    vec2 corner = corners[gl_VertexID];
    \\    vec2 pixel = i_rect.xy + corner * i_rect.zw;
    \\    // Device pixels, y down, to normalised device coordinates, y up.
    \\    vec2 ndc = vec2(pixel.x / u_viewport.x * 2.0 - 1.0,
    \\                   1.0 - pixel.y / u_viewport.y * 2.0);
    \\    v_color = i_color;
    \\    gl_Position = vec4(ndc, 0.0, 1.0);
    \\}
;

/// One glyph per instance: the same rectangle, plus the part of the atlas it
/// samples and the colour it is drawn in.
const glyph_vertex_source =
    \\#version 330 core
    \\const vec2 corners[6] = vec2[6](
    \\    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(1.0, 1.0),
    \\    vec2(0.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)
    \\);
    \\layout(location = 0) in vec4 i_rect;
    \\layout(location = 1) in vec4 i_uv;
    \\layout(location = 2) in vec4 i_color;
    \\uniform vec2 u_viewport;
    \\out vec2 v_uv;
    \\out vec4 v_color;
    \\
    \\void main() {
    \\    vec2 corner = corners[gl_VertexID];
    \\    vec2 pixel = i_rect.xy + corner * i_rect.zw;
    \\    vec2 ndc = vec2(pixel.x / u_viewport.x * 2.0 - 1.0,
    \\                   1.0 - pixel.y / u_viewport.y * 2.0);
    \\    v_uv = mix(i_uv.xy, i_uv.zw, corner);
    \\    v_color = i_color;
    \\    gl_Position = vec4(ndc, 0.0, 1.0);
    \\}
;

/// No blending: every colour a background pass draws is opaque, so writing it
/// directly is what makes a known background colour read back as exactly that
/// colour rather than as a rounding of it.
const solid_fragment_source =
    \\#version 330 core
    \\in vec4 v_color;
    \\out vec4 o_color;
    \\
    \\void main() {
    \\    o_color = v_color;
    \\}
;

/// The coverage atlas is one byte per texel in an `GL_R8` texture, so the red
/// channel *is* the coverage, and the blend function the draw enables
/// composites the glyph's colour over the background.
///
/// With `u_color_mode` set, the same program samples the colour atlas instead
/// (TASK-39): an `RGBA8` texture of premultiplied colour glyphs such as emoji,
/// drawn as they are rather than tinted. The instance colour only scales their
/// opacity, and that pass blends premultiplied.
const glyph_fragment_source =
    \\#version 330 core
    \\in vec2 v_uv;
    \\in vec4 v_color;
    \\uniform sampler2D u_atlas;
    \\uniform int u_color_mode;
    \\out vec4 o_color;
    \\
    \\void main() {
    \\    vec4 texel = texture(u_atlas, v_uv);
    \\    if (u_color_mode == 1) {
    \\        o_color = texel * v_color.a;
    \\    } else {
    \\        o_color = vec4(v_color.rgb, v_color.a * texel.r);
    \\    }
    \\}
;

// ---------------------------------------------------------------------------
// The grid
// ---------------------------------------------------------------------------

/// One instance of the solid pipeline: a rectangle and a colour, side by side
/// in memory exactly as the vertex attributes read them.
const SolidInstance = extern struct {
    rect: [4]f32,
    color: [4]f32,
};

/// One instance of the glyph pipeline: the same rectangle, plus the atlas
/// rectangle to sample and the colour to composite.
const GlyphInstance = extern struct {
    rect: [4]f32,
    uv: [4]f32,
    color: [4]f32,
};

const solid_stride = @sizeOf(SolidInstance);
const glyph_stride = @sizeOf(GlyphInstance);

/// How much UTF-8 one cell's text may occupy when it is shaped. A cluster
/// longer than this is drawn from its base codepoint alone: the text is already
/// untrusted input from a running program, and the alternative is a buffer
/// whose size the program decides.
const cell_text_capacity = 64;

/// How many cells of one ligature run are shaped at once. Longer runs are
/// shaped in pieces of this size; a ligature straddling a piece boundary is
/// drawn as its plain glyphs.
const ligature_run_capacity = 256;

/// Whether a cell can join a ligature run: printable ASCII other than space,
/// one codepoint, one cell wide and visible. Wide, combined and concealed
/// cells keep the per-cell path.
fn ligatureCandidate(cell: term.Cell) bool {
    if (cell.wide or cell.wide_tail or cell.grapheme.len != 0) return false;
    if (cell.style.attributes.invisible) return false;
    return cell.codepoint > ' ' and cell.codepoint < 0x7F;
}

/// The end of the run starting at `start`: the candidate cells after it in
/// the same face style, or just `start` itself when it is not a candidate.
fn ligatureRunEnd(cells: []const term.Cell, start: usize) usize {
    if (!ligatureCandidate(cells[start])) return start + 1;
    const style = faceStyle(cells[start].style.attributes);
    var end = start + 1;
    while (end < cells.len and ligatureCandidate(cells[end]) and
        faceStyle(cells[end].style.attributes) == style) : (end += 1)
    {}
    return end;
}

/// Whether a run holds any of the punctuation programming ligatures are made
/// of. A run of letters and digits is left to the cheaper per-cell path.
fn runHasLigatureTrigger(cells: []const term.Cell) bool {
    for (cells) |cell| {
        if (std.mem.indexOfScalar(u8, "!#$%&*+-./:;<=>?@\\^_|~", @intCast(cell.codepoint)) != null) return true;
    }
    return false;
}

/// The longest UTF-8 grapheme an overlay cell accepts.
///
/// This is the same bounded cell text the terminal renderer shapes. Overlay
/// content can come from an agent transcript or another untrusted source, so a
/// single cell may not make the render thread reserve memory in proportion to
/// its input.
pub const max_overlay_grapheme_bytes: usize = cell_text_capacity;

/// One cell-grid position in a flattened UI overlay.
pub const OverlayPosition = struct {
    /// Zero-based absolute column in the full shared canvas.
    col: u32,
    /// Zero-based absolute row in the full shared canvas.
    row: u32,
};

/// How many adjacent cells one overlay entry occupies.
pub const OverlaySpan = enum(u2) {
    one = 1,
    two = 2,

    /// The span as a cell count.
    pub fn cells(self: OverlaySpan) u32 {
        return @intFromEnum(self);
    }
};

/// One final cell in a flattened UI overlay.
///
/// `text` borrows exactly one validated UTF-8 grapheme from the UI owner and
/// stays live through `Grid.drawOverlay`. Its cell width must equal
/// `span`; an empty slice is a background/decorations-only cell. The UI has
/// already resolved painter order, so entries in one view are unique and do
/// not overlap. Box-drawing characters are ordinary one-grapheme text.
///
/// A null background leaves the pixels already on the shared surface alone.
/// Decoration colours are optional independently, so an entry may paint any
/// subset of underline, strikethrough and overline.
pub const OverlayCell = struct {
    position: OverlayPosition,
    foreground: Rgba,
    span: OverlaySpan = .one,
    text: []const u8 = "",
    face_style: font.FaceStyle = .regular,
    background: ?Rgba = null,
    underline: ?Rgba = null,
    strikethrough: ?Rgba = null,
    overline: ?Rgba = null,

    /// Whether this entry is safe to draw in a grid of `cols` by `rows`.
    ///
    /// Invalid UTF-8, multiple graphemes, a mismatched display width and the
    /// orphaned half of a wide entry are all external input and return false.
    pub fn validFor(self: OverlayCell, cols: u32, rows: u32) bool {
        if (self.position.col >= cols or self.position.row >= rows) return false;
        const width = self.span.cells();
        if (width > cols - self.position.col) return false;
        return overlayTextMatchesSpan(self.text, self.span);
    }
};

/// A flattened UI layer to paint above the terminal and its cursor.
///
/// The slice and every `OverlayCell.text` in it are borrowed for the duration
/// of `Grid.drawOverlay`. Empty space is absent from the slice and therefore
/// leaves the terminal visible.
pub const OverlayView = struct {
    cells: []const OverlayCell = &.{},
    /// Full-canvas width used to validate absolute overlay coordinates.
    /// Zero preserves the legacy terminal-grid extent.
    cols: u32 = 0,
    /// Full-canvas height used to validate absolute overlay coordinates.
    /// Zero preserves the legacy terminal-grid extent.
    rows: u32 = 0,
};

/// Whether `text` is one bounded grapheme whose terminal width is `span`.
fn overlayTextMatchesSpan(text: []const u8, span: OverlaySpan) bool {
    if (text.len == 0) return true;
    if (text.len > max_overlay_grapheme_bytes) return false;

    const view = std.unicode.Utf8View.init(text) catch return false;
    var iterator = view.iterator();
    var codepoints: [cell_text_capacity]u21 = undefined;
    var count: usize = 0;
    while (iterator.nextCodepoint()) |codepoint| {
        // UTF-8 uses at least one byte per codepoint, so the byte bound above
        // proves this array has room. Keep the check explicit because this is
        // untrusted UI content and that relationship must remain true if the
        // two capacities ever diverge.
        if (count == codepoints.len) return false;
        codepoints[count] = codepoint;
        count += 1;
    }

    const measured = term.graphemeWidth(codepoints[0..count]);
    return measured.len == count and measured.width == span.cells();
}

/// One draw sequence: a program, a vertex array bound to an instance buffer,
/// and the uniforms its shaders read. There is no vertex buffer, because the
/// base geometry is `gl_VertexID`.
const Pipeline = struct {
    program: gl.Uint,
    vao: gl.Uint,
    vbo: gl.Uint,
    viewport_uniform: gl.Int,
    atlas_uniform: gl.Int = -1,
    /// The glyph program's switch between coverage and colour sampling.
    color_mode_uniform: gl.Int = -1,
    /// How many bytes the instance buffer holds. It starts at nothing:
    /// `glBufferSubData` into a buffer with no store is `GL_INVALID_VALUE`, and
    /// a driver that queues that error makes every later call in the frame look
    /// like the failure too.
    capacity: usize = 0,
};

/// One contiguous run of viewport rows that has to be redrawn, inclusive.
const RowRange = struct {
    first: u16,
    last: u16,
};

/// What the grid renderer has done, counted.
///
/// The counts are the point. "Damage was honoured" and "an unchanged frame
/// re-uploaded nothing" are claims about work done, and the only honest way to
/// make one is to count it: a boolean that says "no upload happened" is the
/// same boolean a renderer that uploaded anyway would return.
pub const GridStats = struct {
    /// Frames that drew at least one row.
    frames: u64 = 0,
    /// Frames that were asked to draw and had nothing to draw.
    skipped_frames: u64 = 0,
    /// Full-canvas overlay frames staged independently of terminal damage.
    overlay_frames: u64 = 0,
    /// Full-canvas overlay requests skipped because neither UI nor base changed.
    overlay_skipped_frames: u64 = 0,
    /// Rows repainted.
    rows: u64 = 0,
    /// Cells read from the terminal.
    cells: u64 = 0,
    /// Rectangles pushed into the solid pass: every background, plus every
    /// underline, strikethrough and overline.
    backgrounds: u64 = 0,
    /// Glyphs pushed into the glyph pass.
    glyphs: u64 = 0,
    /// `glDrawArraysInstanced` calls.
    draws: u64 = 0,
    /// `glBufferSubData` calls: one per pass per frame that had anything to
    /// draw, and none at all for a frame with no work.
    buffer_uploads: u64 = 0,
    /// Bytes uploaded for instance data.
    buffer_bytes: u64 = 0,
    /// `glTexSubImage2D` calls: how many times new glyph coverage reached the
    /// GPU.
    atlas_uploads: u64 = 0,
    /// Bytes uploaded for glyph coverage.
    atlas_bytes: u64 = 0,
    /// Glyphs FreeType rasterised into the CPU atlas.
    rasterised: u64 = 0,
};

/// Which rows the cursor alone forces into a frame.
///
/// Kept separate from `Grid.draw` and free of GL so it can be unit tested. The
/// cases it has to get right are exactly the ones a damage-only renderer gets
/// wrong, and "nothing changed" has to be the answer for an idle cursor.
///
/// `painted` and `painted_rect` say where the cursor's pixels *are*, which is
/// not the same as where the terminal says the cursor *is*: a renderer that
/// conflates the two repaints the cursor's row on every frame forever, which is
/// what `--grid-test` reported as an idle frame doing three draws.
pub const CursorDamage = struct {
    /// The row the cursor was painted on and is no longer on, which has to be
    /// repainted to erase it. Null when there is nothing to erase.
    erase_row: ?u16,
    /// The row the cursor is on now and is not already painted on, which has to
    /// be repainted so the cursor has a freshly drawn cell to sit on. Null
    /// when the cursor is unchanged or not wanted.
    paint_row: ?u16,
};

/// What the cursor alone forces into this frame's rows.
///
/// The two questions are independent and each has one answer:
///
/// - **Erase** the row a painted cursor is leaving — because it moved off it or
///   is no longer wanted. A cursor sitting exactly where it was painted erases
///   nothing, and that case is what an idle frame is made of.
/// - **Paint** the current row when the cursor is wanted and its pixels are not
///   already on the surface there: it moved, it appeared, or it blinked on.
///
/// Whether the cursor's pixels are redrawn follows from the rows: a row that is
/// repainted erases the cursor that was on it, so `Grid.draw` redraws the
/// cursor whenever the row it is on is in the frame.
pub fn cursorDamage(
    painted: bool,
    painted_rect: PixelRect,
    painted_row: u16,
    cursor_rect: PixelRect,
    cursor_row: ?u16,
    wanted: bool,
) CursorDamage {
    // Both halves of "are the cursor's pixels already on the surface exactly
    // where the terminal wants them" have to be asked, and `painted` is not the
    // afterthought. `moved` alone answers "yes" for a cursor that was erased
    // and is now wanted again on the cell it was erased from: hidden and
    // revealed on the same cell, which is what `\x1b[?25l` then `\x1b[?25h` does,
    // and every blink off/on pair, because blinking never moves the cursor. Its
    // pixels are gone either way, so its row has to go back into the frame or
    // the cursor never comes back.
    const absent = !painted;
    const moved = !std.meta.eql(painted_rect, cursor_rect);
    const erase_row: ?u16 = if (painted and (moved or !wanted)) painted_row else null;
    const paint_row: ?u16 = if (wanted and (moved or absent)) cursor_row else null;
    return .{
        .erase_row = erase_row,
        .paint_row = paint_row,
    };
}

/// The rows a cursor adds to a frame's own damage: ascending, at most two.
///
/// `into` is the caller's two-element scratch so this allocates nothing, which
/// is what keeps `mergeDamage` allocation-free on the hot path.
pub fn cursorRows(plan: CursorDamage, into: *[2]u16) []const u16 {
    var count: usize = 0;
    if (plan.erase_row) |row| {
        into[count] = row;
        count += 1;
    }
    if (plan.paint_row) |row| {
        into[count] = row;
        count += 1;
    }
    // `mergeRows` walks both inputs together, so they have to arrive sorted.
    if (count == 2 and into[0] > into[1]) std.mem.swap(u16, &into[0], &into[1]);
    return into[0..count];
}

/// The terminal grid, drawn into the surface.
///
/// Ownership: `allocator` is borrowed from the caller, and every buffer this
/// value owns is freed by `deinit`. The instance lists are reserved when the
/// grid's size changes and cleared every frame — never freed and reallocated —
/// which is what keeps a frame's allocation count at zero (`AGENTS.md`,
/// rendering rule). The GL objects are object names rather than heap memory;
/// `deinit` must run while the context is still current.
pub const Grid = struct {
    allocator: std.mem.Allocator,
    colors: Colors,
    solid: Pipeline,
    cursor_pipeline: Pipeline,
    glyph_pipeline: Pipeline,
    atlas_texture: gl.Uint = 0,
    atlas: AtlasSize = .{ .width_px = 0, .height_px = 0 },
    /// `insertions + evictions` at the last upload, so a frame that rasterised
    /// no new glyph uploads nothing. This is a number read from `font` rather
    /// than a flag set here: a glyph evicted to make room for another one
    /// moved pixels too.
    atlas_epoch: u64 = 0,
    /// The RGBA8 texture colour glyphs (emoji) are sampled from, created the
    /// first time the font manager rasterises one, and its size.
    color_texture: gl.Uint = 0,
    color_atlas: AtlasSize = .{ .width_px = 0, .height_px = 0 },
    /// The colour atlas's `insertions + evictions` at the last upload. Starts
    /// at "never uploaded" so a grid attached to a manager that already holds
    /// colour glyphs uploads them.
    color_epoch: u64 = std.math.maxInt(u64),
    solids: std.ArrayList(SolidInstance) = .empty,
    glyphs: std.ArrayList(GlyphInstance) = .empty,
    /// Colour glyphs, drawn in their own pass after the coverage glyphs.
    color_glyphs: std.ArrayList(GlyphInstance) = .empty,
    /// One row of terminal cells, read once so ligature runs can be found
    /// before any of the row's text is queued.
    row_cells: std.ArrayList(term.Cell) = .empty,
    ranges: std.ArrayList(RowRange) = .empty,
    shaped: std.ArrayList(font.ShapedGlyph) = .empty,
    cursor_rects: [max_cursor_rects]SolidInstance = undefined,
    /// The cell the cursor is on, kept so the cursor pass has something to draw
    /// and so the caller can ask where it is.
    cursor_rect: PixelRect = .{},
    /// The row the cursor was last painted on, so a move can repaint what it
    /// covered and a blink can erase it.
    painted_row: u16 = 0,
    /// The cell the cursor is *drawn* on, as opposed to the one it is *on*.
    ///
    /// The renderer draws the cursor and then reports it here; it does not
    /// read this field to decide anything. Keeping the drawn position rather
    /// than the current one is what lets a frame tell whether the cursor's
    /// pixels are already on the surface, which is the difference between an
    /// idle frame that does nothing and one that repaints the cursor's row
    /// forever (`mergeDamage`).
    painted_rect: PixelRect = .{},
    painted: bool = false,
    cols: u16 = 0,
    rows: u16 = 0,
    /// Number of full-canvas columns reserved to the left of the terminal.
    terminal_origin_columns: u16 = 0,
    /// Origin for which the retained staging capacity was last reserved.
    reserved_origin_columns: u16 = 0,
    /// The viewport whose pixels this grid's retained cursor/damage state
    /// describes. Distinct `Grid` values therefore retain pane state
    /// independently even while drawing into the same surface.
    active_viewport: ?GridViewport = null,
    /// Absolute placement used while terminal cells are staged this frame.
    draw_viewport: GridViewport = .{
        .x_px = 0,
        .y_px = 0,
        .width_px = 0,
        .height_px = 0,
    },
    cell: font.CellSize = font.CellSize.init(1, 1),
    baseline_px: u32 = 0,
    ascent_px: u32 = 0,
    /// Something moved that makes every cell a different rectangle: a resize, a
    /// new face, a new palette. Cleared once a full frame has been drawn.
    redraw_all: bool = true,
    /// The terminal's selection generation at the last frame this grid drew.
    ///
    /// A selection change moves no cursor and dirties no cell's *content*, so
    /// the terminal's damage report does not cover it. Reading the generation
    /// is what turns "what is selected" into damage: a frame that sees a
    /// different value repaints everything, because the old selection's rows and
    /// the new one's have nothing to do with each other.
    selection_generation: u64 = 0,
    /// Full-canvas overlay state is independent of terminal-local row damage.
    /// App prepares it before pane rendering and draws it once afterwards.
    canvas_overlay_cols: u32 = 0,
    canvas_overlay_rows: u32 = 0,
    canvas_overlay_invalidated: bool = true,
    stats: GridStats = .{},

    /// Why a grid could not be built or drawn.
    pub const Error = GlError || std.mem.Allocator.Error || error{
        /// `drawCanvasOverlay` received dimensions or font metrics that were
        /// not prepared before the base pane pass.
        CanvasOverlayNotPrepared,
    };

    /// Build the programs, the vertex arrays and the instance buffers.
    ///
    /// Needs a current GL context, because it creates GL objects.
    pub fn init(allocator: std.mem.Allocator, colors: Colors) Error!Grid {
        const solid = try createSolidPipeline();
        errdefer destroyPipeline(solid);
        const cursor_pipeline = try createSolidPipeline();
        errdefer destroyPipeline(cursor_pipeline);
        const glyph_pipeline = try createGlyphPipeline();
        errdefer destroyPipeline(glyph_pipeline);
        return .{
            .allocator = allocator,
            .colors = colors,
            .solid = solid,
            .cursor_pipeline = cursor_pipeline,
            .glyph_pipeline = glyph_pipeline,
        };
    }

    /// Give back the GL objects and every buffer. Needs a current context.
    pub fn deinit(self: *Grid) void {
        destroyPipeline(self.solid);
        destroyPipeline(self.cursor_pipeline);
        destroyPipeline(self.glyph_pipeline);
        if (self.atlas_texture != 0) gl.deleteTextures(1, &self.atlas_texture);
        if (self.color_texture != 0) gl.deleteTextures(1, &self.color_texture);
        self.solids.deinit(self.allocator);
        self.glyphs.deinit(self.allocator);
        self.color_glyphs.deinit(self.allocator);
        self.row_cells.deinit(self.allocator);
        self.ranges.deinit(self.allocator);
        self.shaped.deinit(self.allocator);
        self.* = undefined;
    }

    /// What this grid has done since it was built.
    pub fn gridStats(self: *const Grid) GridStats {
        return self.stats;
    }

    /// The cell the cursor is on, and `null` when the cursor is not shown.
    pub fn cursor(self: *const Grid) ?PixelRect {
        return if (self.painted) self.cursor_rect else null;
    }

    /// Place terminal column zero after this many full-canvas columns.
    ///
    /// An unchanged origin is a no-op. A change invalidates the whole base
    /// frame so pixels at the old position are cleared; the next terminal draw
    /// also reserves staging room for the wider full-canvas overlay as part of
    /// that layout transition.
    pub fn setTerminalOriginColumns(self: *Grid, origin: u16) void {
        if (origin == self.terminal_origin_columns) return;
        self.terminal_origin_columns = origin;
        self.redraw_all = true;
    }

    /// Replace the palette. Every cell's colours may have changed, so the next
    /// frame repaints all of them.
    pub fn setColors(self: *Grid, colors: Colors) void {
        self.colors = colors;
        self.redraw_all = true;
    }

    /// Force the next terminal draw to rebuild the shared surface.
    ///
    /// An overlay owner calls this before an overlay appears, changes, moves
    /// or disappears. The base terminal is repainted first, then the current
    /// overlay (or an empty one) is drawn over it, so no pixels from the prior
    /// UI frame can remain behind.
    pub fn invalidate(self: *Grid) void {
        self.redraw_all = true;
    }

    /// Mark the full-canvas UI layer changed.
    ///
    /// The next `prepareCanvasOverlay` returns true, telling the compositor to
    /// repaint every underlying pane before the new UI is drawn. That base
    /// repaint is what erases cells a modal, divider or preedit used to occupy;
    /// painting only the new sparse overlay could never erase absent entries.
    pub fn invalidateCanvasOverlay(self: *Grid) void {
        self.canvas_overlay_invalidated = true;
    }

    /// Adopt font metrics, reserve a full canvas overlay and report whether its
    /// base must repaint.
    ///
    /// Call this after composing the current `OverlayView` but before drawing
    /// any pane. A dedicated overlay `Grid` never receives terminal draws, so
    /// preparation explicitly adopts the current cell, baseline and ascent
    /// from `fonts` rather than inheriting the 1x1 initialization defaults. If
    /// this returns true, the compositor invalidates every pane grid (and
    /// clears any UI-only background region it owns), draws those bases, then
    /// calls `drawCanvasOverlay` once. Repeating the same metrics and dimensions
    /// after a completed, unchanged frame allocates nothing and returns false.
    pub fn prepareCanvasOverlay(
        self: *Grid,
        fonts: *const font.Manager,
        view: OverlayView,
    ) std.mem.Allocator.Error!bool {
        return self.prepareCanvasOverlayMetrics(view, fonts.metrics());
    }

    fn prepareCanvasOverlayMetrics(
        self: *Grid,
        view: OverlayView,
        metrics: font.Metrics,
    ) std.mem.Allocator.Error!bool {
        if (!self.overlayMetricsMatch(metrics)) {
            self.cell = metrics.cell;
            self.baseline_px = metrics.baseline_px;
            self.ascent_px = metrics.ascent_px;
            self.canvas_overlay_invalidated = true;
        }
        if (view.cols != self.canvas_overlay_cols or view.rows != self.canvas_overlay_rows) {
            try self.reserveCanvasOverlay(view.cols, view.rows);
            self.canvas_overlay_cols = view.cols;
            self.canvas_overlay_rows = view.rows;
            self.canvas_overlay_invalidated = true;
        }
        return self.canvas_overlay_invalidated;
    }

    fn overlayMetricsMatch(self: *const Grid, metrics: font.Metrics) bool {
        return std.meta.eql(self.cell, metrics.cell) and
            self.baseline_px == metrics.baseline_px and
            self.ascent_px == metrics.ascent_px;
    }

    /// Replace the glyph atlas texture with another face's coverage.
    ///
    /// `pixels` is the whole CPU atlas, and it is uploaded in full here, so the
    /// first frame after a scale change draws real glyphs rather than an empty
    /// texture. A face re-rasterised at a new display scale is a new atlas with
    /// the same dimensions.
    pub fn attachAtlas(self: *Grid, pixels: []const u8, size: AtlasSize) GlError!void {
        const wanted = @as(usize, size.width_px) * @as(usize, size.height_px);
        if (pixels.len < wanted) {
            log.err("glyph atlas holds {d} bytes, a {d}x{d} texture needs {d}", .{
                pixels.len,
                size.width_px,
                size.height_px,
                wanted,
            });
            return error.GlCallFailed;
        }
        if (self.atlas_texture == 0) gl.genTextures(1, &self.atlas_texture);
        gl.bindTexture(gl.TEXTURE_2D, self.atlas_texture);
        // One byte per texel: the atlas is a coverage mask, so it is a single
        // channel and GL unpacks it with no row padding to account for.
        gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
        gl.texImage2D(
            gl.TEXTURE_2D,
            0,
            gl.R8,
            @intCast(size.width_px),
            @intCast(size.height_px),
            0,
            gl.RED,
            gl.UNSIGNED_BYTE,
            pixels.ptr,
        );
        // A glyph is a stencil of whole texels: NEAREST on both filters and
        // clamped on both axes, so no neighbouring glyph's coverage can reach
        // into this one. GL 3.3 core has no sampler objects, so this is set
        // once on the texture rather than per draw.
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        try checkGl("glyph atlas texture");
        self.atlas = size;
        // The pixels just uploaded are what the epoch means now, so the first
        // frame only re-uploads if it rasterises something new.
        self.atlas_epoch = 0;
        // A new manager (a new face, size or display scale) has a new colour
        // atlas too; the next frame that needs colour uploads all of it.
        self.color_epoch = std.math.maxInt(u64);
        self.redraw_all = true;
    }

    /// Draw a frame of `terminal` into `surface`.
    ///
    /// `blink_visible` is the cursor's current blink phase; the caller owns the
    /// clock, because this module owns no timer and no event loop.
    ///
    /// Reads `term.damage()` and redraws exactly the rows it names, plus the
    /// rows the cursor moved off and on to. A frame with no damage and no
    /// cursor movement makes no GL call at all — no upload, no draw and no
    /// clear — which is the whole of render-on-demand at the grid level.
    ///
    /// `terminal` must have been refreshed since the bytes were last fed to it:
    /// `term.damage` reports the damage of the last `refresh`, not of the last
    /// `feed`.
    pub fn draw(
        self: *Grid,
        surface: *const Surface,
        fonts: *font.Manager,
        terminal: *term.Terminal,
        blink_visible: bool,
    ) Error!void {
        const metrics = fonts.metrics();
        const viewport = GridViewport.fromCells(
            .{ .col = self.terminal_origin_columns, .row = 0 },
            terminal.gridSize(),
            metrics.cell,
        );
        try self.drawFrame(surface, fonts, terminal, blink_visible, viewport, .whole_surface);
    }

    /// Draw `terminal` inside one independently retained pane viewport.
    ///
    /// Every clear, background, glyph, decoration and cursor is hard-clipped
    /// to `viewport`. A full repaint clears only that clipped rectangle, so it
    /// cannot erase a sibling pane. This method deliberately does **not** clear
    /// a prior viewport when the rectangle moves or disappears: that old area
    /// may now belong to a sibling. Before drawing a changed layout, the app
    /// compositor must clear/repaint the complete layout, including divider
    /// gaps and pixels vacated by removed panes. The app owns one `Grid` per
    /// visible or hidden pane because cursor and damage state are retained by
    /// this value.
    /// Repeating an unchanged viewport with no terminal or cursor damage makes
    /// no GL call and allocates nothing.
    pub fn drawViewport(
        self: *Grid,
        surface: *const Surface,
        fonts: *font.Manager,
        terminal: *term.Terminal,
        blink_visible: bool,
        viewport: GridViewport,
    ) Error!void {
        try self.drawFrame(surface, fonts, terminal, blink_visible, viewport, .viewport);
    }

    const ClearScope = enum {
        whole_surface,
        viewport,
    };

    fn drawFrame(
        self: *Grid,
        surface: *const Surface,
        fonts: *font.Manager,
        terminal: *term.Terminal,
        blink_visible: bool,
        viewport: GridViewport,
        clear_scope: ClearScope,
    ) Error!void {
        const metrics = fonts.metrics();
        const size = terminal.gridSize();

        // A face or a grid that moved puts every cell in a different rectangle,
        // so a damage report about the old arrangement means nothing.
        const grid_changed = !std.meta.eql(metrics.cell, self.cell) or
            size.cols != self.cols or size.rows != self.rows;
        const origin_changed = self.terminal_origin_columns != self.reserved_origin_columns;
        const viewport_changed = self.configureViewport(viewport);
        if (grid_changed) {
            self.cell = metrics.cell;
            self.baseline_px = metrics.baseline_px;
            self.ascent_px = metrics.ascent_px;
            self.cols = size.cols;
            self.rows = size.rows;
            self.redraw_all = true;
        }
        if (grid_changed or origin_changed or viewport_changed) {
            try self.reserve(size);
        }
        if (clear_scope == .viewport and viewport.clipped(surface.size) == null) {
            self.ranges.clearRetainingCapacity();
            self.stats.skipped_frames += 1;
            return;
        }
        const state = terminal.cursor();
        var cursor_row: ?u16 = null;
        var cursor_rect = PixelRect{};
        if (state.position) |at| {
            // A cursor sitting on the empty half of a wide glyph belongs to the
            // glyph, not to the half-cell the engine reports.
            const col = if (state.wide_tail and at.col > 0) at.col - 1 else at.col;
            cursor_row = at.row;
            cursor_rect = viewport.cellRect(col, at.row, self.cell);
        }
        // Where the cursor *is*. Its pixels are somewhere else — `painted_rect`
        // — and the two are allowed to disagree: a frame that changed nothing
        // skips, and a skipped frame still has to be able to answer "where is
        // the cursor" correctly.
        self.cursor_rect = cursor_rect;
        const cursor_wanted = cursor_row != null and state.visible and
            (!state.blinking or blink_visible);
        // The cursor's pixels are on the surface where `painted_rect` says, not
        // where `cursor_rect` says: a frame that changed nothing leaves the
        // cursor exactly where the last frame drew it, and that is what makes
        // such a frame free of work rather than free of *grid* work.
        const plan = cursorDamage(
            self.painted,
            self.painted_rect,
            self.painted_row,
            cursor_rect,
            cursor_row,
            cursor_wanted,
        );

        const damage = terminal.damage();
        switch (damage) {
            .full => self.redraw_all = true,
            .none, .rows => {},
        }

        // What is selected is damage. Nothing about a selection moves a cursor
        // or changes a cell's content, so the terminal's damage report cannot
        // cover it, and a frame that skipped the repaint would leave the old
        // highlight on the surface. A whole frame is redrawn rather than the
        // two ranges the old and new selections touch: a drag changes the
        // selection on every event, and the two ranges are almost always the
        // whole width of the screen anyway.
        const selection = terminal.selectionGeneration();
        if (selection != self.selection_generation) {
            self.selection_generation = selection;
            self.redraw_all = true;
        }
        self.ranges.clearRetainingCapacity();
        if (self.redraw_all) {
            try self.ranges.append(self.allocator, .{ .first = 0, .last = self.rows - 1 });
        } else {
            try self.mergeDamage(damage, plan);
        }

        if (self.ranges.items.len == 0) {
            self.stats.skipped_frames += 1;
            return;
        }

        // A row being repainted erases whatever the cursor drew there, so a
        // cursor whose row is in the frame is drawn again whether or not it
        // moved.
        const repaint_cursor = cursor_wanted and cursor_row != null and
            rangeContains(self.ranges.items, cursor_row.?);
        self.stats.frames += 1;

        self.solids.clearRetainingCapacity();
        self.glyphs.clearRetainingCapacity();
        self.color_glyphs.clearRetainingCapacity();

        // A full frame starts from a clean surface; a partial one starts from
        // what the last frame left, which is the whole point of damage.
        switch (clear_scope) {
            .whole_surface => if (self.redraw_all) {
                surface.clear(self.colors.background);
            } else {
                surface.bind();
            },
            .viewport => {
                bindViewport(surface, viewport);
                if (self.redraw_all) {
                    const background = self.terminalColor(self.colors.background).toFloats();
                    gl.clearColor(background[0], background[1], background[2], background[3]);
                    gl.clear(gl.COLOR_BUFFER_BIT);
                }
            },
        }
        defer if (clear_scope == .viewport) gl.disable(gl.SCISSOR_TEST);

        for (self.ranges.items) |range| {
            var row: u32 = range.first;
            while (row <= range.last) : (row += 1) {
                self.stats.rows += 1;
                if (fonts.ligatures()) {
                    try self.addLigatureRow(fonts, terminal, @intCast(row));
                    continue;
                }
                var col: u32 = 0;
                while (col < self.cols) : (col += 1) {
                    self.stats.cells += 1;
                    const at = term.Position{ .col = @intCast(col), .row = @intCast(row) };
                    try self.addCell(fonts, terminal.cell(at) orelse emptyCell(), at, true);
                }
            }
        }

        // Coverage rasterised into the CPU atlas during this frame has to reach
        // the GPU before the frame that uses it is drawn.
        self.uploadAtlas(fonts);
        try self.drawSolidPass(surface);
        try self.drawGlyphPass(surface);
        try self.drawColorGlyphPass(surface);
        if (repaint_cursor) try self.drawCursor(surface, state.shape, cursor_rect);

        // Where the cursor's pixels are, after this frame: drawn where the
        // terminal says it is if it was drawn, still where it was if this frame
        // left it alone, and nowhere if it was erased.
        if (repaint_cursor) {
            // The cursor is on the surface now, and its pixels are on the cell
            // the terminal says it is on. `repaint_cursor` already means that row
            // is inside this frame, so `cursor_row` is exactly where it was put.
            self.painted = true;
            self.painted_rect = cursor_rect;
            self.painted_row = cursor_row.?;
        } else if (plan.erase_row != null) {
            self.painted = false;
        }
        self.redraw_all = false;
    }

    /// Update the placement retained with this grid's damage state.
    ///
    /// A change invalidates the new rectangle only. The old bounds are dropped
    /// without clearing because another pane may own them after relayout; the
    /// app's full layout repaint restores those pixels before pane draws.
    fn configureViewport(self: *Grid, viewport: GridViewport) bool {
        if (self.active_viewport) |active| {
            if (std.meta.eql(active, viewport)) {
                self.draw_viewport = viewport;
                return false;
            }
        }
        self.active_viewport = viewport;
        self.draw_viewport = viewport;
        self.redraw_all = true;
        return true;
    }

    /// Draw the flattened UI layer over the terminal frame just completed.
    ///
    /// This consumes the row ranges retained by `draw`: terminal damage under
    /// a static overlay repaints only overlay cells on those rows, while an
    /// invalidated full base frame repaints the whole current overlay. Calling
    /// this after an idle `draw` does no GPU work, and calling it twice consumes
    /// the ranges on the first call so glyph coverage is never blended twice.
    ///
    /// The overlay is deliberately drawn after the terminal cursor, making UI
    /// cells the top layer on their shared GPU surface. The view is borrowed
    /// only for this call and is already flattened into non-overlapping final
    /// cells by `ui`; malformed entries are skipped.
    pub fn drawOverlay(
        self: *Grid,
        surface: *const Surface,
        fonts: *font.Manager,
        view: OverlayView,
    ) Error!void {
        if (self.ranges.items.len == 0) return;
        defer self.ranges.clearRetainingCapacity();

        self.solids.clearRetainingCapacity();
        self.glyphs.clearRetainingCapacity();
        self.color_glyphs.clearRetainingCapacity();

        const overlay_cols = if (view.cols == 0) @as(u32, self.cols) else view.cols;
        const overlay_rows = if (view.rows == 0) @as(u32, self.rows) else view.rows;
        for (view.cells) |cell| {
            if (!overlayCellInDamage(cell, overlay_cols, overlay_rows, self.ranges.items)) continue;
            try self.addOverlayCell(fonts, cell);
        }

        if (self.solids.items.len == 0 and self.glyphs.items.len == 0 and self.color_glyphs.items.len == 0) return;
        surface.bind();
        self.uploadAtlas(fonts);
        try self.drawSolidPass(surface);
        try self.drawGlyphPass(surface);
        try self.drawColorGlyphPass(surface);
    }

    /// Draw one prepared, absolute full-canvas UI layer after all pane grids.
    ///
    /// Unlike legacy `drawOverlay`, this never reads or consumes terminal row
    /// damage. It repaints the entire sparse `view` when the UI was invalidated
    /// or `base_changed` says at least one pane drew underneath it; otherwise it
    /// performs no GL call. The compositor must call `prepareCanvasOverlay`
    /// before its pane pass and honor that method's base-repaint result, which
    /// makes removed overlay cells reveal freshly drawn terminal pixels.
    ///
    /// `base_changed` is one aggregate boolean for the whole surface, not a
    /// terminal damage range. The view and every text slice are borrowed only
    /// for this call. All staging storage was retained by preparation, so this
    /// method allocates nothing.
    pub fn drawCanvasOverlay(
        self: *Grid,
        surface: *const Surface,
        fonts: *font.Manager,
        view: OverlayView,
        base_changed: bool,
    ) Error!void {
        if (view.cols != self.canvas_overlay_cols or view.rows != self.canvas_overlay_rows or
            !self.overlayMetricsMatch(fonts.metrics()))
        {
            return error.CanvasOverlayNotPrepared;
        }
        if (self.skipCanvasOverlayIfUnchanged(base_changed)) return;

        self.solids.clearRetainingCapacity();
        self.glyphs.clearRetainingCapacity();
        self.color_glyphs.clearRetainingCapacity();
        for (view.cells) |cell| {
            if (!cell.validFor(view.cols, view.rows)) continue;
            try self.addOverlayCell(fonts, cell);
        }

        if (self.solids.items.len != 0 or self.glyphs.items.len != 0 or self.color_glyphs.items.len != 0) {
            surface.bind();
            self.uploadAtlas(fonts);
            try self.drawSolidPass(surface);
            try self.drawGlyphPass(surface);
            try self.drawColorGlyphPass(surface);
        }
        self.canvas_overlay_invalidated = false;
        self.stats.overlay_frames += 1;
    }

    fn skipCanvasOverlayIfUnchanged(self: *Grid, base_changed: bool) bool {
        if (self.canvas_overlay_invalidated or base_changed) return false;
        self.stats.overlay_skipped_frames += 1;
        return true;
    }

    /// Room for a whole frame of this grid's size, so that no frame allocates.
    fn reserve(self: *Grid, size: term.GridSize) std.mem.Allocator.Error!void {
        const full_cols = std.math.add(
            usize,
            @as(usize, size.cols),
            @as(usize, self.terminal_origin_columns),
        ) catch return error.OutOfMemory;
        const cells = std.math.mul(usize, full_cols, @as(usize, size.rows)) catch
            return error.OutOfMemory;
        // A cell can push a background, three decorations and — if a cluster is
        // longer than one codepoint — several glyphs, so the reserve is the
        // worst case rather than the common one. Include the terminal's left
        // inset because overlays use the full canvas. It is reserved once per
        // size/origin change, which is what keeps a frame from allocating.
        try self.solids.ensureTotalCapacity(self.allocator, cells * 4 + max_cursor_rects);
        try self.glyphs.ensureTotalCapacity(self.allocator, cells * 4);
        // A colour glyph is at most one per cell (an emoji cluster shapes to
        // one glyph), so its pass needs a cell's worth, not four.
        try self.color_glyphs.ensureTotalCapacity(self.allocator, cells);
        try self.ranges.ensureTotalCapacity(self.allocator, size.rows);
        try self.shaped.ensureTotalCapacity(self.allocator, @max(cell_text_capacity, ligature_run_capacity));
        try self.row_cells.ensureTotalCapacity(self.allocator, size.cols);
        self.reserved_origin_columns = self.terminal_origin_columns;
    }

    /// Retain worst-case staging room for a sparse full-canvas overlay.
    fn reserveCanvasOverlay(self: *Grid, cols: u32, rows: u32) std.mem.Allocator.Error!void {
        const cells = std.math.mul(
            usize,
            @as(usize, cols),
            @as(usize, rows),
        ) catch return error.OutOfMemory;
        const instances = std.math.mul(usize, cells, 4) catch return error.OutOfMemory;
        try self.solids.ensureTotalCapacity(self.allocator, instances);
        try self.glyphs.ensureTotalCapacity(self.allocator, instances);
        try self.color_glyphs.ensureTotalCapacity(self.allocator, cells);
        try self.shaped.ensureTotalCapacity(self.allocator, cell_text_capacity);
    }

    /// Merge the terminal's damaged rows with the rows the cursor forces into
    /// the frame: the one it was painted on and is leaving, and the one it is
    /// moving to. Ghostty's damage does not always cover a cursor that moved,
    /// and a renderer that trusted it would leave the cursor's old cell
    /// painted.
    fn mergeDamage(
        self: *Grid,
        damage: term.Damage,
        plan: CursorDamage,
    ) std.mem.Allocator.Error!void {
        const damaged: []const u16 = switch (damage) {
            .rows => |rows| rows,
            .none, .full => &.{},
        };
        // Only the rows `cursorDamage` decided on: a cursor already drawn
        // exactly where the terminal says it is contributes neither, which is
        // what keeps an idle frame at zero rows.
        var extra: [2]u16 = .{ 0, 0 };
        try mergeRows(&self.ranges, self.allocator, damaged, cursorRows(plan, &extra), self.rows);
    }

    /// Add one cell: its background rectangle, its attribute decorations and
    /// its glyphs.
    ///
    /// `draw_text` is false for a cell whose text a ligature run queues
    /// instead (`addLigatureRow`); its background and decorations still come
    /// from here.
    fn addCell(self: *Grid, fonts: *font.Manager, cell: term.Cell, at: term.Position, draw_text: bool) Error!void {
        const rect = self.terminalRect(at);
        const attributes = cell.style.attributes;
        const foreground = self.colors.resolve(cell.style.fg, true);
        const background = self.colors.resolve(cell.style.bg, false);
        // `inverse` swaps the two slots rather than painting over the cell, so
        // the swapped pair is what is drawn and the glyph keeps its own alpha
        // over the swapped background.
        const fg = if (attributes.inverse) background else foreground;

        var bg = if (attributes.inverse) foreground else background;
        // A selected cell is painted with the selection colour *unless the
        // program gave it a background of its own*. An SGR background is
        // information — it is how a diff marks an added line and how `ls`
        // colours a directory — and replacing it would make selecting a
        // highlighted line lose the highlight that made it worth selecting.
        // Every other terminal makes the same trade, in the other direction:
        // they invert, which loses the foreground instead. Losing the glyph's
        // colour is worse than losing its background, because the text is what
        // is being read.
        if (cell.selected and cell.style.bg == .default) bg = self.colors.selection;

        // A wide glyph owns two cells, and its background has to reach the
        // second one: the cell after it holds no text of its own to paint.
        const columns: f32 = if (cell.wide) 2.0 else 1.0;
        try self.pushSolid(
            rect.x,
            rect.y,
            rect.width * columns,
            rect.height,
            self.terminalColor(bg),
        );

        // The empty half of a wide glyph is background only: the glyph is drawn
        // once, from the cell that carries it, at its own bearing.
        if (cell.wide_tail) return;

        // Conceal leaves the cell's background in place but suppresses every
        // kind of foreground ink, including decorations on otherwise empty
        // cells. This must precede the decoration pass below.
        if (attributes.invisible) return;

        const width = rect.width * columns;
        const thickness = @max(1.0, @floor(rect.height / 12.0));
        if (attributes.underline != .none) {
            // SGR 58/59 can set an underline colour that is neither the
            // foreground nor the background.
            try self.pushSolid(
                rect.x,
                rect.y + @as(f32, @floatFromInt(self.baseline_px)),
                width,
                thickness,
                self.terminalColor(self.colors.resolve(cell.style.underline_color, true)),
            );
        }
        if (attributes.strikethrough) {
            const y = rect.y + @as(f32, @floatFromInt(self.baseline_px)) -
                @as(f32, @floatFromInt(self.ascent_px)) / 3.0;
            try self.pushSolid(rect.x, y, width, thickness, self.terminalColor(fg));
        }
        if (attributes.overline) {
            try self.pushSolid(rect.x, rect.y, width, thickness, self.terminalColor(fg));
        }

        if (!cell.hasText() or !draw_text) return;
        try self.addCellText(fonts, cell, rect, faceStyle(attributes), self.inkColor(cell));
    }

    /// Where a terminal cell is on the surface.
    fn terminalRect(self: *const Grid, at: term.Position) PixelRect {
        return if (self.active_viewport != null)
            self.draw_viewport.cellRect(at.col, at.row, self.cell)
        else
            terminalCellRect(at.col, at.row, self.cell, self.terminal_origin_columns);
    }

    /// The colour a cell's glyphs are drawn in: its foreground (or background
    /// under `inverse`), faint and pane dimming applied.
    fn inkColor(self: *const Grid, cell: term.Cell) Rgba {
        const attributes = cell.style.attributes;
        const foreground = self.colors.resolve(cell.style.fg, true);
        const background = self.colors.resolve(cell.style.bg, false);
        const fg = if (attributes.inverse) background else foreground;
        var bg = if (attributes.inverse) foreground else background;
        if (cell.selected and cell.style.bg == .default) bg = self.colors.selection;
        const ink = if (attributes.faint) faint(fg, bg) else fg;
        return self.terminalColor(ink);
    }

    /// Queue one terminal row, shaping runs of ligature-prone ASCII as one
    /// HarfBuzz run so the font's ligatures (`=>`, `!=`, `->`) form across
    /// cells. Every glyph is still placed in the cell its cluster came from,
    /// so the grid never moves; a font whose ligatures are a spacer plus a
    /// glyph that overhangs to the left (JetBrains Mono, Fira Code) draws
    /// them through its own bearings. Everything else is per cell, exactly as
    /// with ligatures off.
    fn addLigatureRow(self: *Grid, fonts: *font.Manager, terminal: *term.Terminal, row: u16) Error!void {
        self.row_cells.clearRetainingCapacity();
        var col: u16 = 0;
        while (col < self.cols) : (col += 1) {
            self.stats.cells += 1;
            const at = term.Position{ .col = col, .row = row };
            // `reserve` sized this to the grid's columns.
            self.row_cells.appendAssumeCapacity(terminal.cell(at) orelse emptyCell());
        }
        const cells = self.row_cells.items;
        var start: usize = 0;
        while (start < cells.len) {
            const end = ligatureRunEnd(cells, start);
            const in_run = end - start >= 2 and runHasLigatureTrigger(cells[start..end]);
            for (cells[start..end], start..) |cell, index| {
                try self.addCell(fonts, cell, .{ .col = @intCast(index), .row = row }, !in_run);
            }
            if (in_run) try self.addLigatureRun(fonts, cells[start..end], @intCast(start), row);
            start = end;
        }
    }

    fn addLigatureRun(self: *Grid, fonts: *font.Manager, cells: []const term.Cell, first_col: u16, row: u16) Error!void {
        var text: [ligature_run_capacity]u8 = undefined;
        var offset: usize = 0;
        while (offset < cells.len) {
            // A run longer than the buffer is shaped in buffer-sized pieces.
            const count = @min(cells.len - offset, text.len);
            for (cells[offset..][0..count], 0..) |cell, index| text[index] = @intCast(cell.codepoint);
            const style = faceStyle(cells[offset].style.attributes);
            fonts.shapeForStyle(style, text[0..count], &self.shaped) catch |err| {
                log.warn("shaping a ligature run failed: {s}", .{@errorName(err)});
                return;
            };
            for (self.shaped.items) |glyph| {
                if (glyph.cluster >= count) continue;
                const index = offset + glyph.cluster;
                const at = term.Position{ .col = first_col + @as(u16, @intCast(index)), .row = row };
                try self.addGlyph(
                    fonts,
                    .{ .face_index = glyph.face_index },
                    glyph.glyph_index,
                    self.terminalRect(at),
                    glyph.x_offset_px,
                    glyph.y_offset_px,
                    self.inkColor(cells[index]),
                );
            }
            offset += count;
        }
    }

    fn terminalColor(self: *const Grid, color: Rgba) Rgba {
        return if (self.draw_viewport.dimmed)
            inactivePaneColor(color, self.colors.background)
        else
            color;
    }

    /// Append one opaque rectangle to the solid pass.
    fn pushSolid(
        self: *Grid,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        color: Rgba,
    ) std.mem.Allocator.Error!void {
        try self.solids.append(self.allocator, .{
            .rect = .{ x, y, width, height },
            .color = color.toFloats(),
        });
        self.stats.backgrounds += 1;
    }

    /// Queue one validated overlay cell without growing a retained buffer.
    fn addOverlayCell(self: *Grid, fonts: *font.Manager, cell: OverlayCell) Error!void {
        var solid_count: usize = 0;
        if (cell.background != null) solid_count += 1;
        if (cell.underline != null) solid_count += 1;
        if (cell.strikethrough != null) solid_count += 1;
        if (cell.overline != null) solid_count += 1;
        if (solid_count > self.solids.capacity - self.solids.items.len) {
            // A flattened view has at most four solids per grid cell, and
            // `reserve` made room for exactly that. More means malformed
            // duplicate/overlapping input; skip instead of allocating in the
            // render path.
            return;
        }

        const rect = cellRect(
            @intCast(cell.position.col),
            @intCast(cell.position.row),
            self.cell,
        );
        const width = rect.width * @as(f32, @floatFromInt(cell.span.cells()));
        const thickness = @max(1.0, @floor(rect.height / 12.0));

        if (cell.background) |color| {
            try self.pushSolid(rect.x, rect.y, width, rect.height, color);
        }
        if (cell.underline) |color| {
            try self.pushSolid(
                rect.x,
                rect.y + @as(f32, @floatFromInt(self.baseline_px)),
                width,
                thickness,
                color,
            );
        }
        if (cell.strikethrough) |color| {
            const y = rect.y + @as(f32, @floatFromInt(self.baseline_px)) -
                @as(f32, @floatFromInt(self.ascent_px)) / 3.0;
            try self.pushSolid(rect.x, y, width, thickness, color);
        }
        if (cell.overline) |color| {
            try self.pushSolid(rect.x, rect.y, width, thickness, color);
        }
        if (cell.text.len == 0) return;

        try self.addOverlayText(fonts, cell, rect);
    }

    /// Shape and queue one overlay grapheme through its actual face slots.
    fn addOverlayText(
        self: *Grid,
        fonts: *font.Manager,
        cell: OverlayCell,
        rect: PixelRect,
    ) Error!void {
        // `reserve` gives this scratch one slot per maximum input byte. UTF-8
        // has at least one byte per codepoint and shaping cannot emit more
        // glyphs than this bounded input without reporting them through the
        // same retained list.
        if (self.shaped.capacity < max_overlay_grapheme_bytes) return;
        fonts.shapeForStyle(cell.face_style, cell.text, &self.shaped) catch |err| {
            log.debug("overlay grapheme could not be shaped: {s}", .{@errorName(err)});
            return;
        };
        if (self.shaped.items.len > self.glyphs.capacity - self.glyphs.items.len) {
            // A pathological cluster may contain far more marks than the usual
            // per-cell reserve. Losing that cell is preferable to allocating
            // on the render thread or dropping only half its cluster.
            return;
        }

        var pen_x: f32 = 0;
        var pen_y: f32 = 0;
        const span: u32 = if (cell.span == .two) font.face_flag_wide else 0;
        for (self.shaped.items) |glyph| {
            try self.addGlyph(
                fonts,
                .{ .face_index = glyph.face_index | span },
                glyph.glyph_index,
                rect,
                pen_x + glyph.x_offset_px,
                pen_y + glyph.y_offset_px,
                cell.foreground,
            );
            pen_x += glyph.x_advance_px;
            pen_y += glyph.y_advance_px;
        }
    }

    /// Add a cell's glyphs: its own codepoint, or the whole cluster shaped as
    /// one run, so that a combining mark lands inside the cell's advance rather
    /// than beside it in the next cell.
    fn addCellText(
        self: *Grid,
        fonts: *font.Manager,
        cell: term.Cell,
        rect: PixelRect,
        face_style: font.FaceStyle,
        color: Rgba,
    ) Error!void {
        // A glyph in a two-cell cell may be fitted to both cells' width.
        const span: u32 = if (cell.wide) font.face_flag_wide else 0;
        if (cell.grapheme.len == 0) {
            // The common case by a wide margin, and the one where shaping has
            // nothing to add: one codepoint is already one cluster. The font
            // manager's fallback chain picks the face, sprites included.
            const resolved = fonts.resolve(face_style, cell.codepoint) orelse {
                log.debug("no glyph for U+{X}; the cell keeps its background", .{cell.codepoint});
                return;
            };
            try self.addGlyph(fonts, .{ .face_index = resolved.face_index | span }, resolved.glyph_index, rect, 0, 0, color);
            return;
        }

        var buffer: [cell_text_capacity]u8 = undefined;
        const head = std.unicode.utf8Encode(cell.codepoint, &buffer) catch return;
        var length: usize = @intCast(head);
        for (cell.grapheme) |codepoint| {
            if (length + 4 > buffer.len) break;
            const tail = std.unicode.utf8Encode(codepoint, buffer[length..]) catch break;
            length += @intCast(tail);
        }
        fonts.shapeForStyle(face_style, buffer[0..length], &self.shaped) catch |err| {
            log.warn("shaping a cell's text failed: {s}", .{@errorName(err)});
            return;
        };
        for (self.shaped.items) |glyph| {
            try self.addGlyph(
                fonts,
                .{ .face_index = glyph.face_index | span },
                glyph.glyph_index,
                rect,
                glyph.x_offset_px,
                glyph.y_offset_px,
                color,
            );
        }
    }

    const GlyphSource = union(enum) {
        /// A primary-face glyph index looked up for this requested style.
        style: font.FaceStyle,
        /// A concrete face, with its `font.face_flag_*` bits, chosen by the
        /// fallback chain (`font.Manager.resolve`) or by HarfBuzz for a shaped
        /// run.
        face_index: u32,
    };

    /// Rasterise a glyph if the atlas does not have it, and queue it for the
    /// glyph pass.
    fn addGlyph(
        self: *Grid,
        fonts: *font.Manager,
        source: GlyphSource,
        glyph_index: u32,
        rect: PixelRect,
        x_offset: f32,
        y_offset: f32,
        color: Rgba,
    ) Error!void {
        // Without an atlas there are no coordinates to sample, and dividing by
        // its width would produce a rectangle the GPU cannot place. The app
        // attaches one before it draws anything; this is the case where that
        // did not happen.
        if (self.atlas.width_px == 0 or self.atlas.height_px == 0) {
            log.err("no glyph atlas is attached, so no glyph can be drawn", .{});
            return;
        }
        const before = fonts.atlas.stats.insertions + fonts.color_atlas.stats.insertions;
        const entry = switch (source) {
            .style => |style| fonts.glyphForStyle(style, glyph_index),
            .face_index => |face_index| fonts.glyphForFace(face_index, glyph_index),
        } catch |err| {
            // A glyph FreeType will not load is the font's problem, not a
            // reason to lose the frame: the cell keeps its background.
            log.debug("glyph {d} could not be rasterised: {s}", .{ glyph_index, @errorName(err) });
            return;
        };
        self.stats.rasterised += fonts.atlas.stats.insertions + fonts.color_atlas.stats.insertions - before;
        // A space rasterises to nothing, which is not a glyph to draw.
        if (entry.rect.isEmpty()) return;

        var placed = glyphRect(rect, self.baseline_px, entry);
        placed.x += @round(x_offset);
        placed.y += @round(y_offset);
        if (entry.color) {
            // Colour glyphs keep their own colours; only the ink's alpha
            // reaches them, so a dimmed pane or faint text still fades them.
            try self.color_glyphs.append(self.allocator, .{
                .rect = .{ placed.x, placed.y, placed.width, placed.height },
                .uv = uvOf(entry.rect, .{
                    .width_px = fonts.color_atlas.width_px,
                    .height_px = fonts.color_atlas.height_px,
                }),
                .color = color.toFloats(),
            });
            self.stats.glyphs += 1;
            return;
        }
        try self.glyphs.append(self.allocator, .{
            .rect = .{ placed.x, placed.y, placed.width, placed.height },
            .uv = uvOf(entry.rect, self.atlas),
            .color = color.toFloats(),
        });
        self.stats.glyphs += 1;
    }

    /// Send new glyph coverage to the GPU, if any arrived.
    ///
    /// The trigger is the atlas's own insertion and eviction counts rather than
    /// a flag this module sets, because eviction moves pixels too and a glyph
    /// that was already in the atlas moves none.
    fn uploadAtlas(self: *Grid, fonts: *font.Manager) void {
        self.uploadColorAtlas(fonts);
        const epoch = fonts.atlas.stats.insertions + fonts.atlas.stats.evictions;
        if (epoch == self.atlas_epoch or self.atlas.width_px == 0) return;
        const pixels = fonts.atlasPixels();
        const wanted = @as(usize, self.atlas.width_px) * @as(usize, self.atlas.height_px);
        if (pixels.len < wanted) {
            // The CPU atlas is smaller than the texture it was asked to become,
            // so it moved under this module. Leaving the last good coverage on
            // the GPU beats reading past the end of it.
            log.err("glyph atlas holds {d} bytes, the {d}x{d} texture needs {d}", .{
                pixels.len,
                self.atlas.width_px,
                self.atlas.height_px,
                wanted,
            });
            return;
        }
        gl.bindTexture(gl.TEXTURE_2D, self.atlas_texture);
        gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
        gl.texSubImage2D(
            gl.TEXTURE_2D,
            0,
            0,
            0,
            @intCast(self.atlas.width_px),
            @intCast(self.atlas.height_px),
            gl.RED,
            gl.UNSIGNED_BYTE,
            pixels.ptr,
        );
        self.atlas_epoch = epoch;
        self.stats.atlas_uploads += 1;
        self.stats.atlas_bytes += wanted;
    }

    /// Send new colour glyphs to the GPU, creating the RGBA texture the first
    /// time there are any. A grid whose manager never rasterised a colour
    /// glyph creates no texture and uploads nothing.
    fn uploadColorAtlas(self: *Grid, fonts: *font.Manager) void {
        const source = &fonts.color_atlas;
        const epoch = source.stats.insertions + source.stats.evictions;
        if (epoch == self.color_epoch) return;
        if (epoch == 0 and self.color_texture == 0) {
            self.color_epoch = 0;
            return;
        }
        const size = AtlasSize{ .width_px = source.width_px, .height_px = source.height_px };
        const wanted = @as(usize, size.width_px) * size.height_px * 4;
        if (source.depth != 4 or source.pixels.len < wanted) {
            log.err("colour atlas holds {d} bytes, the {d}x{d} texture needs {d}", .{
                source.pixels.len,
                size.width_px,
                size.height_px,
                wanted,
            });
            return;
        }
        gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
        if (self.color_texture == 0 or !std.meta.eql(size, self.color_atlas)) {
            if (self.color_texture == 0) gl.genTextures(1, &self.color_texture);
            gl.bindTexture(gl.TEXTURE_2D, self.color_texture);
            gl.texImage2D(
                gl.TEXTURE_2D,
                0,
                gl.RGBA8,
                @intCast(size.width_px),
                @intCast(size.height_px),
                0,
                gl.RGBA,
                gl.UNSIGNED_BYTE,
                source.pixels.ptr,
            );
            // Colour glyphs are scaled to their exact pixel size on the CPU,
            // so they are sampled texel for texel like coverage glyphs.
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
            self.color_atlas = size;
        } else {
            gl.bindTexture(gl.TEXTURE_2D, self.color_texture);
            gl.texSubImage2D(
                gl.TEXTURE_2D,
                0,
                0,
                0,
                @intCast(size.width_px),
                @intCast(size.height_px),
                gl.RGBA,
                gl.UNSIGNED_BYTE,
                source.pixels.ptr,
            );
        }
        self.color_epoch = epoch;
        self.stats.atlas_uploads += 1;
        self.stats.atlas_bytes += wanted;
    }

    fn drawSolidPass(self: *Grid, surface: *const Surface) Error!void {
        if (self.solids.items.len == 0) return;
        gl.disable(gl.BLEND);
        gl.useProgram(self.solid.program);
        gl.bindVertexArray(self.solid.vao);
        setViewport(surface, self.solid);
        self.upload(&self.solid, std.mem.sliceAsBytes(self.solids.items));
        gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, @intCast(self.solids.items.len));
        self.stats.draws += 1;
        try checkGl("grid solid pass");
    }

    fn drawGlyphPass(self: *Grid, surface: *const Surface) Error!void {
        if (self.glyphs.items.len == 0) return;
        gl.enable(gl.BLEND);
        gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
        gl.useProgram(self.glyph_pipeline.program);
        gl.bindVertexArray(self.glyph_pipeline.vao);
        setViewport(surface, self.glyph_pipeline);
        self.upload(&self.glyph_pipeline, std.mem.sliceAsBytes(self.glyphs.items));
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, self.atlas_texture);
        gl.uniform1i(self.glyph_pipeline.atlas_uniform, 0);
        gl.uniform1i(self.glyph_pipeline.color_mode_uniform, 0);
        gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, @intCast(self.glyphs.items.len));
        gl.disable(gl.BLEND);
        self.stats.draws += 1;
        try checkGl("grid glyph pass");
    }

    /// Draw the colour glyphs over the coverage glyphs: the same program and
    /// instance layout, sampling the RGBA atlas and blending premultiplied.
    fn drawColorGlyphPass(self: *Grid, surface: *const Surface) Error!void {
        if (self.color_glyphs.items.len == 0 or self.color_texture == 0) return;
        gl.enable(gl.BLEND);
        gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
        gl.useProgram(self.glyph_pipeline.program);
        gl.bindVertexArray(self.glyph_pipeline.vao);
        setViewport(surface, self.glyph_pipeline);
        self.upload(&self.glyph_pipeline, std.mem.sliceAsBytes(self.color_glyphs.items));
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, self.color_texture);
        gl.uniform1i(self.glyph_pipeline.atlas_uniform, 0);
        gl.uniform1i(self.glyph_pipeline.color_mode_uniform, 1);
        gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, @intCast(self.color_glyphs.items.len));
        gl.uniform1i(self.glyph_pipeline.color_mode_uniform, 0);
        gl.disable(gl.BLEND);
        self.stats.draws += 1;
        try checkGl("grid colour glyph pass");
    }

    /// The cursor, painted over the cell it is on. Opaque, so it is drawn with
    /// blending off: the block cursor is the cursor's colour and not a tint of
    /// it.
    fn drawCursor(
        self: *Grid,
        surface: *const Surface,
        shape: term.CursorShape,
        rect: PixelRect,
    ) Error!void {
        const thickness = @max(1.0, @floor(@as(f32, @floatFromInt(self.cell.width_px)) / 10.0));
        const paint = cursorPaint(shape, rect, thickness);
        const channels = self.terminalColor(self.colors.cursor).toFloats();
        var count: usize = 0;
        for (paint.rects[0..paint.count]) |bar| {
            self.cursor_rects[count] = .{
                .rect = .{ bar.x, bar.y, bar.width, bar.height },
                .color = channels,
            };
            count += 1;
        }
        gl.disable(gl.BLEND);
        gl.useProgram(self.cursor_pipeline.program);
        gl.bindVertexArray(self.cursor_pipeline.vao);
        setViewport(surface, self.cursor_pipeline);
        self.upload(&self.cursor_pipeline, std.mem.sliceAsBytes(self.cursor_rects[0..count]));
        gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, @intCast(count));
        self.stats.draws += 1;
        try checkGl("grid cursor");
    }

    /// Send one pass's instance data to the GPU, and count what it cost.
    ///
    /// The bytes are the instance array itself, in the layout the vertex
    /// attributes read, so the upload is a copy and not a conversion. The
    /// buffer's storage grows by doubling and is never shrunk: after the first
    /// frame or two a grid of a given size uploads into storage that is
    /// already there, which is what keeps a frame's GL work to two calls.
    fn upload(self: *Grid, pipeline: *Pipeline, items: []const u8) void {
        if (items.len == 0) return;
        gl.bindBuffer(gl.ARRAY_BUFFER, pipeline.vbo);
        if (items.len > pipeline.capacity) {
            var wanted: usize = if (pipeline.capacity == 0) 4096 else pipeline.capacity;
            while (wanted < items.len) wanted *= 2;
            gl.bufferData(gl.ARRAY_BUFFER, @intCast(wanted), null, gl.STREAM_DRAW);
            pipeline.capacity = wanted;
        }
        gl.bufferSubData(gl.ARRAY_BUFFER, 0, @intCast(items.len), items.ptr);
        self.stats.buffer_uploads += 1;
        self.stats.buffer_bytes += items.len;
    }
};

/// Tell a pipeline how big the surface is, in the pixels its rectangle maths
/// divides by.
fn setViewport(surface: *const Surface, pipeline: Pipeline) void {
    gl.uniform2f(
        pipeline.viewport_uniform,
        @floatFromInt(surface.size.width),
        @floatFromInt(surface.size.height),
    );
}

/// Bind the shared surface and restrict every following raster operation to
/// one top-down pane rectangle. Callers only use this after `clipped` returned
/// non-null, so the casts describe a real framebuffer extent rather than
/// accepting unbounded external coordinates at the GL seam.
fn bindViewport(surface: *const Surface, viewport: GridViewport) void {
    const bounds = viewport.clipped(surface.size) orelse return;
    surface.bind();
    gl.enable(gl.SCISSOR_TEST);
    gl.scissor(
        @intCast(bounds.x_px),
        @intCast(scissorY(bounds, surface.size.height)),
        @intCast(bounds.width_px),
        @intCast(bounds.height_px),
    );
}

fn scissorY(bounds: ViewportBounds, surface_height: u32) u32 {
    return surface_height - (bounds.y_px + bounds.height_px);
}

/// A cell outside the grid reads as no text and no attributes, which is the
/// same as a blank cell rather than an error: a damage report can name rows
/// the grid no longer has after a resize.
fn emptyCell() term.Cell {
    return .{
        .codepoint = 0,
        .grapheme = &.{},
        .wide = false,
        .wide_tail = false,
    };
}

/// Whether a safe overlay cell intersects a row rebuilt by the terminal pass.
fn overlayCellInDamage(
    cell: OverlayCell,
    cols: u32,
    rows: u32,
    ranges: []const RowRange,
) bool {
    if (!cell.validFor(cols, rows)) return false;
    if (cell.position.row > @as(u32, std.math.maxInt(u16))) return false;
    return rangeContains(ranges, @intCast(cell.position.row));
}

/// Whether `row` falls inside one of `ranges`.
fn rangeContains(ranges: []const RowRange, row: u16) bool {
    for (ranges) |range| {
        if (row >= range.first and row <= range.last) return true;
    }
    return false;
}

/// Add `row` to the frame's rows, merging it into the last range when it
/// touches or overlaps it. Rows must arrive in ascending order.
fn pushRow(
    ranges: *std.ArrayList(RowRange),
    allocator: std.mem.Allocator,
    row: u16,
) std.mem.Allocator.Error!void {
    if (ranges.items.len > 0) {
        const last = &ranges.items[ranges.items.len - 1];
        // Already inside the last range. Damage rows arrive without repeats,
        // but a cursor row can be one the terminal already named.
        if (row <= last.last) return;
        if (row == last.last + 1) {
            last.last = row;
            return;
        }
    }
    try ranges.append(allocator, .{ .first = row, .last = row });
}

/// The rows a frame has to redraw: the union of what the terminal says changed
/// and what the cursor forces, as merged ranges, with rows the grid no longer
/// has left out.
///
/// Both inputs are sorted, so the union is a walk rather than a sort, and the
/// result is sorted and free of overlaps — which is what lets the draw loop
/// walk it once and never repaint a row twice.
fn mergeRows(
    ranges: *std.ArrayList(RowRange),
    allocator: std.mem.Allocator,
    damaged: []const u16,
    extra: []const u16,
    row_limit: u16,
) std.mem.Allocator.Error!void {
    var at_damaged: usize = 0;
    var at_extra: usize = 0;
    while (at_damaged < damaged.len or at_extra < extra.len) {
        var next: u16 = undefined;
        if (at_extra >= extra.len or
            (at_damaged < damaged.len and damaged[at_damaged] <= extra[at_extra]))
        {
            next = damaged[at_damaged];
            at_damaged += 1;
        } else {
            next = extra[at_extra];
            at_extra += 1;
        }
        // A damage report can name rows a smaller grid no longer has, after a
        // resize that was computed for the old one.
        if (next >= row_limit) continue;
        try pushRow(ranges, allocator, next);
    }
}

fn createSolidPipeline() GlError!Pipeline {
    const program = try createProgram(solid_vertex_source, solid_fragment_source);
    errdefer gl.deleteProgram(program);
    var vao: gl.Uint = 0;
    var vbo: gl.Uint = 0;
    gl.genVertexArrays(1, &vao);
    gl.genBuffers(1, &vbo);
    gl.bindVertexArray(vao);
    gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
    // Offset 0 is handed over as a null pointer and not as an address: in Zig
    // 0.16 the last argument of `vertexAttribPointer` is a byte offset into the
    // bound buffer, and a zero there is not a null pointer.
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 4, gl.FLOAT, 0, solid_stride, null);
    gl.enableVertexAttribArray(1);
    gl.vertexAttribPointer(1, 4, gl.FLOAT, 0, solid_stride, offsetPointer(SolidInstance, "color"));
    gl.vertexAttribDivisor(0, 1);
    gl.vertexAttribDivisor(1, 1);
    gl.bindVertexArray(0);
    try checkGl("solid pipeline");
    return .{
        .program = program,
        .vao = vao,
        .vbo = vbo,
        .viewport_uniform = gl.getUniformLocation(program, "u_viewport"),
    };
}

fn createGlyphPipeline() GlError!Pipeline {
    const program = try createProgram(glyph_vertex_source, glyph_fragment_source);
    errdefer gl.deleteProgram(program);
    var vao: gl.Uint = 0;
    var vbo: gl.Uint = 0;
    gl.genVertexArrays(1, &vao);
    gl.genBuffers(1, &vbo);
    gl.bindVertexArray(vao);
    gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 4, gl.FLOAT, 0, glyph_stride, null);
    gl.enableVertexAttribArray(1);
    gl.vertexAttribPointer(1, 4, gl.FLOAT, 0, glyph_stride, offsetPointer(GlyphInstance, "uv"));
    gl.enableVertexAttribArray(2);
    gl.vertexAttribPointer(2, 4, gl.FLOAT, 0, glyph_stride, offsetPointer(GlyphInstance, "color"));
    gl.vertexAttribDivisor(0, 1);
    gl.vertexAttribDivisor(1, 1);
    gl.vertexAttribDivisor(2, 1);
    gl.bindVertexArray(0);
    try checkGl("glyph pipeline");
    return .{
        .program = program,
        .vao = vao,
        .vbo = vbo,
        .viewport_uniform = gl.getUniformLocation(program, "u_viewport"),
        .atlas_uniform = gl.getUniformLocation(program, "u_atlas"),
        .color_mode_uniform = gl.getUniformLocation(program, "u_color_mode"),
    };
}

fn destroyPipeline(pipeline: Pipeline) void {
    if (pipeline.vao != 0) gl.deleteVertexArrays(1, &pipeline.vao);
    if (pipeline.vbo != 0) gl.deleteBuffers(1, &pipeline.vbo);
    if (pipeline.program != 0) gl.deleteProgram(pipeline.program);
}

/// A byte offset into an instance struct, which is what `vertexAttribPointer`
/// takes for the fields that are not first.
fn offsetPointer(comptime Instance: type, comptime field_name: []const u8) *const anyopaque {
    return @ptrFromInt(@offsetOf(Instance, field_name));
}

fn createProgram(vertex: [:0]const u8, fragment: [:0]const u8) GlError!gl.Uint {
    const vs = try compileShader(gl.VERTEX_SHADER, vertex);
    defer gl.deleteShader(vs);
    const fs = try compileShader(gl.FRAGMENT_SHADER, fragment);
    defer gl.deleteShader(fs);

    const program = gl.createProgram();
    gl.attachShader(program, vs);
    gl.attachShader(program, fs);
    gl.linkProgram(program);
    var status: gl.Int = 0;
    gl.getProgramiv(program, gl.LINK_STATUS, &status);
    if (status == 0) {
        var buffer: [512]u8 = undefined;
        log.err("shader program did not link: {s}", .{infoLog(false, program, &buffer)});
        gl.deleteProgram(program);
        return error.GlCallFailed;
    }
    gl.detachShader(program, vs);
    gl.detachShader(program, fs);
    return program;
}

fn compileShader(kind: gl.Enum, source: [:0]const u8) GlError!gl.Uint {
    const shader = gl.createShader(kind);
    const strings = [_][*:0]const u8{source};
    const lengths = [_]gl.Int{-1};
    gl.shaderSource(shader, 1, &strings, &lengths);
    gl.compileShader(shader);
    var status: gl.Int = 0;
    gl.getShaderiv(shader, gl.COMPILE_STATUS, &status);
    if (status == 0) {
        var buffer: [512]u8 = undefined;
        log.err("{s} shader did not compile: {s}", .{
            if (kind == gl.VERTEX_SHADER) "vertex" else "fragment",
            infoLog(true, shader, &buffer),
        });
        gl.deleteShader(shader);
        return error.GlCallFailed;
    }
    return shader;
}

/// The driver's own message about a failed compile or link, as a slice of
/// `buffer`. GL fills it with a NUL-terminated string, so what arrived is
/// measured rather than what was asked for.
fn infoLog(is_shader: bool, object: gl.Uint, buffer: []u8) []const u8 {
    var length: gl.Sizei = 0;
    const size: gl.Int = @intCast(buffer.len);
    if (is_shader) {
        gl.getShaderInfoLog(object, size, @ptrCast(&length), @ptrCast(buffer.ptr));
    } else {
        gl.getProgramInfoLog(object, size, @ptrCast(&length), @ptrCast(buffer.ptr));
    }
    const used: usize = @min(@as(usize, @intCast(length)), buffer.len);
    return std.mem.sliceTo(buffer[0..used], 0);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "a surface is scaled to whole pixels" {
    const testing = std.testing;

    const base = Size{ .width = 800, .height = 600 };
    try testing.expectEqual(base, base.scaled(1.0));
    try testing.expectEqual(Size{ .width = 1600, .height = 1200 }, base.scaled(2.0));
    try testing.expectEqual(Size{ .width = 400, .height = 300 }, base.scaled(0.5));
    try testing.expectEqual(Size{ .width = 1000, .height = 750 }, base.scaled(1.25));

    // A fractional result rounds to the nearest pixel, both ways.
    try testing.expectEqual(Size{ .width = 1200, .height = 900 }, base.scaled(1.5));
    try testing.expectEqual(@as(u32, 902), (Size{ .width = 601, .height = 1 }).scaled(1.5).width);
    try testing.expectEqual(@as(u32, 902), (Size{ .width = 1, .height = 601 }).scaled(1.5).height);

    try testing.expectEqual(@as(u64, 480000), base.area());
}

test "an absurd display scale saturates instead of trapping" {
    const testing = std.testing;

    const huge = (Size{ .width = 800, .height = 600 }).scaled(1e30);
    try testing.expectEqual(std.math.maxInt(u32), huge.width);
    try testing.expectEqual(std.math.maxInt(u32), huge.height);

    const negative = (Size{ .width = 800, .height = 600 }).scaled(-1.0);
    try testing.expectEqual(@as(u32, 0), negative.width);
    try testing.expectEqual(@as(u32, 0), negative.height);

    // Saturating rather than trapping must not break the untouched dimension.
    try testing.expectEqual(@as(u32, 0), (Size{ .width = 800, .height = 0 }).scaled(1e30).height);
}

test "a surface colour converts to the floats the GL calls take" {
    const testing = std.testing;

    const channels = (Rgba{ .r = 0, .g = 128, .b = 255, .a = 255 }).toFloats();
    try testing.expectEqual(@as(f32, 0.0), channels[0]);
    try testing.expectEqual(@as(f32, 1.0), channels[2]);
    try testing.expectEqual(@as(f32, 1.0), channels[3]);
    try testing.expectEqual(@as(f32, 128.0 / 255.0), channels[1]);

    // Alpha defaults to opaque, so the default is the full-strength colour.
    try testing.expectEqual(@as(f32, 1.0), (Rgba{ .r = 1, .g = 2, .b = 3 }).toFloats()[3]);
    try testing.expectEqual(@as(f32, 0.0), (Rgba{ .r = 1, .g = 2, .b = 3, .a = 0 }).toFloats()[3]);
}

test "a capture buffer is four bytes a pixel and no more" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 0), readbackLen(Size{ .width = 0, .height = 0 }));
    try testing.expectEqual(@as(usize, 4), readbackLen(Size{ .width = 1, .height = 1 }));
    // 960*640*4: the size of the window the app opens by default, so the number
    // a reader checks against `800 * 600 * 4` by hand.
    try testing.expectEqual(@as(usize, 960 * 640 * 4), readbackLen(Size{ .width = 960, .height = 640 }));
    // A width that is not a multiple of four is the reason the read sets
    // GL_PACK_ALIGNMENT to 1; the buffer has no row padding either way.
    try testing.expectEqual(@as(usize, 601 * 1 * 4), readbackLen(Size{ .width = 601, .height = 1 }));
}

test "a buffer one byte too small for the surface is refused, not truncated" {
    const testing = std.testing;

    const size = Size{ .width = 640, .height = 480 };
    const needed = readbackLen(size);

    try testing.expect(captureFits(size, needed));
    // A larger buffer is fine: `read` writes exactly `needed` bytes and returns
    // the prefix, so one buffer serves several surface sizes.
    try testing.expect(captureFits(size, needed + 1));
    try testing.expect(!captureFits(size, needed - 1));
    try testing.expect(!captureFits(size, 0));

    // A surface of no pixels needs no buffer, which is why the rule is a
    // comparison rather than an assertion that something exists.
    try testing.expect(captureFits(Size{ .width = 0, .height = 0 }, 0));
}

test "PNG input must be a non-empty complete RGBA8 image" {
    const testing = std.testing;

    try testing.expectError(
        error.InvalidImageSize,
        encodePng(testing.allocator, .{ .width = 0, .height = 1 }, &.{}),
    );
    try testing.expectError(
        error.InvalidImageSize,
        encodePng(testing.allocator, .{ .width = 1, .height = 0 }, &.{}),
    );
    try testing.expectError(
        error.InvalidPixelLength,
        encodePng(testing.allocator, .{ .width = 1, .height = 1 }, &.{ 1, 2, 3 }),
    );
    try testing.expectError(
        error.InvalidPixelLength,
        encodePng(testing.allocator, .{ .width = 1, .height = 1 }, &.{ 1, 2, 3, 4, 5 }),
    );
}

test "PNG chunks have valid CRCs and contain top-down unfiltered RGBA rows" {
    const testing = std.testing;
    const pixels = [_]u8{
        255, 0, 0, 255, // top row
        0, 255, 0, 128, // bottom row
    };
    const png = try encodePng(testing.allocator, .{ .width = 1, .height = 2 }, &pixels);
    defer testing.allocator.free(png);

    try testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", png[0..8]);

    var idat: []const u8 = &.{};
    var offset: usize = 8;
    var chunk_index: usize = 0;
    while (offset < png.len) : (chunk_index += 1) {
        try testing.expect(png.len - offset >= 12);
        const data_len: usize = std.mem.readInt(u32, png[offset..][0..4], .big);
        const chunk_type = png[offset + 4 ..][0..4];
        const data_start = offset + 8;
        try testing.expect(data_len <= png.len - data_start - 4);
        const data = png[data_start..][0..data_len];
        const crc_offset = data_start + data_len;
        const stored_crc = std.mem.readInt(u32, png[crc_offset..][0..4], .big);

        var crc = std.hash.Crc32.init();
        crc.update(chunk_type);
        crc.update(data);
        try testing.expectEqual(crc.final(), stored_crc);

        switch (chunk_index) {
            0 => {
                try testing.expectEqualSlices(u8, "IHDR", chunk_type);
                try testing.expectEqual(@as(usize, 13), data.len);
                try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, data[0..4], .big));
                try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, data[4..8], .big));
                try testing.expectEqualSlices(u8, &.{ 8, 6, 0, 0, 0 }, data[8..13]);
            },
            1 => {
                try testing.expectEqualSlices(u8, "IDAT", chunk_type);
                idat = data;
            },
            2 => {
                try testing.expectEqualSlices(u8, "IEND", chunk_type);
                try testing.expectEqual(@as(usize, 0), data.len);
            },
            else => return error.UnexpectedPngChunk,
        }
        offset = crc_offset + 4;
    }
    try testing.expectEqual(@as(usize, 3), chunk_index);
    try testing.expectEqual(png.len, offset);
    try testing.expect(idat.len != 0);

    var compressed_reader: std.Io.Reader = .fixed(idat);
    var decompression_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor: std.compress.flate.Decompress = .init(
        &compressed_reader,
        .zlib,
        &decompression_buffer,
    );
    var decoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer decoded.deinit();
    const decoded_len = try decompressor.reader.streamRemaining(&decoded.writer);

    const expected = [_]u8{
        0, 255, 0, 0, 255, // filter byte, top row
        0, 0, 255, 0, 128, // filter byte, bottom row
    };
    try testing.expectEqual(expected.len, decoded_len);
    try testing.expectEqualSlices(u8, &expected, decoded.written());
}

test "a captured image is flipped top-down in place" {
    const testing = std.testing;

    // Three rows of two RGBA pixels, written in the order GL returns them: the
    // bottom row first.
    const size = Size{ .width = 2, .height = 3 };
    var buffer = [_]u8{
        1, 0, 0, 255, 2, 0, 0, 255, // row 0: the bottom of the image
        3, 0, 0, 255, 4, 0, 0, 255, // row 1: the middle
        5, 0, 0, 255, 6, 0, 0, 255, // row 2: the top
    };
    flipVertically(&buffer, size);

    try testing.expectEqualSlices(u8, &[_]u8{
        5, 0, 0, 255, 6, 0, 0, 255,
        3, 0, 0, 255, 4, 0, 0, 255,
        1, 0, 0, 255, 2, 0, 0, 255,
    }, &buffer);
}

test "a single-row image is left alone, and a single-column one still flips" {
    const testing = std.testing;

    // One row of three pixels: the top row is the bottom row, so there is nothing
    // to swap, and the loop must not walk off the end of the buffer looking for
    // a row that is not there.
    var wide = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    const wide_before = wide;
    flipVertically(&wide, Size{ .width = 3, .height = 1 });
    try testing.expectEqualSlices(u8, &wide_before, &wide);

    // One pixel across and three rows down is still three rows: width is not what
    // decides the flip, height is.
    var tall = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    flipVertically(&tall, Size{ .width = 1, .height = 3 });
    try testing.expectEqualSlices(u8, &[_]u8{ 9, 10, 11, 12, 5, 6, 7, 8, 1, 2, 3, 4 }, &tall);

    // An empty capture is not flipped either, and a one-pixel one is its own
    // reverse.
    var nothing = [_]u8{};
    flipVertically(&nothing, Size{ .width = 0, .height = 0 });
    try testing.expectEqual(@as(usize, 0), nothing.len);

    var single = [_]u8{ 7, 8, 9, 10 };
    flipVertically(&single, Size{ .width = 1, .height = 1 });
    try testing.expectEqualSlices(u8, &[_]u8{ 7, 8, 9, 10 }, &single);
}

test "the 6x6x6 cube and the greyscale steps are what every terminal draws" {
    const testing = std.testing;

    // The corners of the cube: black at 16, blue at 21, white at 231.
    try testing.expectEqual(Rgba{ .r = 0, .g = 0, .b = 0 }, cube(16));
    try testing.expectEqual(Rgba{ .r = 0, .g = 0, .b = 255 }, cube(21));
    try testing.expectEqual(Rgba{ .r = 255, .g = 0, .b = 0 }, cube(196));
    try testing.expectEqual(Rgba{ .r = 255, .g = 255, .b = 255 }, cube(231));

    // A cube entry steps one level on each axis, which is the whole of the
    // mapping from an offset to a colour.
    try testing.expectEqual(Rgba{ .r = 0, .g = 0, .b = 95 }, cube(17));
    try testing.expectEqual(Rgba{ .r = 0, .g = 95, .b = 0 }, cube(22));
    try testing.expectEqual(Rgba{ .r = 215, .g = 135, .b = 175 }, cube(16 + 4 * 36 + 2 * 6 + 3));

    // The greyscale ramp starts at 8 and steps by 10, twenty-four times.
    try testing.expectEqual(Rgba{ .r = 8, .g = 8, .b = 8 }, cube(232));
    try testing.expectEqual(Rgba{ .r = 238, .g = 238, .b = 238 }, cube(255));
}

test "a terminal colour resolves through the palette, the cube, or itself" {
    const testing = std.testing;

    var ansi: [ansi_count]Rgba = undefined;
    for (&ansi, 0..) |*entry, index| {
        entry.* = .{ .r = @intCast(index * 7), .g = 0, .b = 0 };
    }
    const colors = Colors{
        .ansi = ansi,
        .foreground = .{ .r = 0xd8, .g = 0xd8, .b = 0xe0 },
        .background = .{ .r = 0x16, .g = 0x1a, .b = 0x22 },
        .cursor = .{ .r = 0xff, .g = 0xff, .b = 0xff },
    };

    // `default` is a different colour for text than for a background, which is
    // why `resolve` is told which one it is resolving.
    try testing.expectEqual(colors.foreground, colors.resolve(.default, true));
    try testing.expectEqual(colors.background, colors.resolve(.default, false));

    // A slot below 16 is the theme's, and is exactly what the theme said.
    try testing.expectEqual(ansi[3], colors.resolve(.{ .palette = 3 }, false));

    // A slot from 16 up is arithmetic, and never the theme's.
    try testing.expectEqual(cube(231), colors.resolve(.{ .palette = 231 }, true));

    // A direct colour is taken as given, and is opaque: a cell's own alpha
    // would only be read as a tint over a background the cell already names.
    const direct = colors.resolve(.{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, true);
    try testing.expectEqual(Rgba{ .r = 1, .g = 2, .b = 3, .a = 255 }, direct);
}

test "faint is the foreground mixed towards what it is drawn on" {
    const testing = std.testing;

    try testing.expectEqual(Rgba{ .r = 0, .g = 0, .b = 0 }, faint(.{ .r = 0, .g = 0, .b = 0 }, .{ .r = 0, .g = 0, .b = 0 }));
    // White on black keeps two thirds of its brightness; black on white picks up
    // a third of the white behind it.
    try testing.expectEqual(Rgba{ .r = 170, .g = 170, .b = 170 }, faint(.{ .r = 255, .g = 255, .b = 255 }, .{ .r = 0, .g = 0, .b = 0 }));
    try testing.expectEqual(Rgba{ .r = 85, .g = 85, .b = 85 }, faint(.{ .r = 0, .g = 0, .b = 0 }, .{ .r = 255, .g = 255, .b = 255 }));
}

test "bold and italic select each configured face without affecting colour" {
    const testing = std.testing;

    const cases = [_]struct {
        attributes: term.Style.Attributes,
        expected: font.FaceStyle,
    }{
        .{ .attributes = .{}, .expected = .regular },
        .{ .attributes = .{ .bold = true }, .expected = .bold },
        .{ .attributes = .{ .italic = true }, .expected = .italic },
        .{ .attributes = .{ .bold = true, .italic = true }, .expected = .bold_italic },
    };
    for (cases) |case| {
        try testing.expectEqual(case.expected, faceStyle(case.attributes));
    }

    // Face selection and colour resolution are deliberately independent. In
    // particular, bold ANSI red stays slot 1 instead of becoming bright red
    // in slot 9.
    var ansi: [ansi_count]Rgba = undefined;
    for (&ansi, 0..) |*entry, index| {
        entry.* = .{ .r = @intCast(index), .g = 0, .b = 0 };
    }
    const colors: Colors = .{ .ansi = ansi };
    try testing.expectEqual(ansi[1], colors.resolve(.{ .palette = 1 }, true));
    try testing.expectEqual(.bold, faceStyle(.{ .bold = true }));
}

test "conceal queues the background but no decorations or glyphs" {
    const testing = std.testing;

    const background = Rgba{ .r = 10, .g = 20, .b = 30 };
    var grid: Grid = .{
        .allocator = testing.allocator,
        .colors = .{ .ansi = @splat(.{ .r = 0, .g = 0, .b = 0 }) },
        // `addCell` does no GL work. These pipelines are intentionally absent
        // so this remains an allocator-clean unit test rather than a GPU test.
        .solid = undefined,
        .cursor_pipeline = undefined,
        .glyph_pipeline = undefined,
        .cell = font.CellSize.init(8, 20),
        .baseline_px = 15,
        .ascent_px = 14,
    };
    defer grid.solids.deinit(testing.allocator);
    defer grid.glyphs.deinit(testing.allocator);
    defer grid.color_glyphs.deinit(testing.allocator);
    defer grid.row_cells.deinit(testing.allocator);

    // The font manager is never touched for a concealed cell. Passing the
    // uninitialised value makes the ordering part of the test: moving conceal
    // below glyph handling would fail immediately rather than silently draw.
    var unused_fonts: font.Manager = undefined;
    try grid.addCell(&unused_fonts, .{
        .codepoint = 'A',
        .grapheme = &.{},
        .wide = false,
        .wide_tail = false,
        .style = .{
            .fg = .{ .rgb = .{ .r = 200, .g = 100, .b = 50 } },
            .bg = .{ .rgb = .{ .r = background.r, .g = background.g, .b = background.b } },
            .underline_color = .{ .rgb = .{ .r = 250, .g = 0, .b = 250 } },
            .attributes = .{
                .invisible = true,
                .underline = .single,
                .strikethrough = true,
                .overline = true,
            },
        },
    }, .{ .col = 0, .row = 0 }, true);

    try testing.expectEqual(@as(usize, 1), grid.solids.items.len);
    try testing.expectEqual(@as(usize, 0), grid.glyphs.items.len);
    try testing.expectEqual(@as(u64, 1), grid.stats.backgrounds);
    try testing.expectEqual([4]f32{ 0, 0, 8, 20 }, grid.solids.items[0].rect);
    try testing.expectEqual(background.toFloats(), grid.solids.items[0].color);
}

test "a cell is its cell size, and a wide one is two of them" {
    const testing = std.testing;

    const cell = font.CellSize.init(8, 17);
    try testing.expectEqual(PixelRect{ .x = 0, .y = 0, .width = 8, .height = 17 }, cellRect(0, 0, cell));
    try testing.expectEqual(PixelRect{ .x = 24, .y = 51, .width = 8, .height = 17 }, cellRect(3, 3, cell));

    // A wide glyph is placed by its own cell; the background behind it is the
    // two-cell width, which is the renderer's arithmetic and not the font's.
    const wide_width = cellRect(3, 3, cell).width * 2;
    try testing.expectEqual(@as(f32, 16), wide_width);
}

test "pane viewport converts cell origins in both axes to bounded pixels" {
    const testing = std.testing;
    const cell = font.CellSize.init(8, 17);
    const size = try term.GridSize.init(7, 4);
    const viewport = GridViewport.fromCells(.{ .col = 3, .row = 2 }, size, cell);

    try testing.expectEqual(GridViewport{
        .x_px = 24,
        .y_px = 34,
        .width_px = 56,
        .height_px = 68,
    }, viewport);
    try testing.expectEqual(
        PixelRect{ .x = 40, .y = 85, .width = 8, .height = 17 },
        viewport.cellRect(2, 3, cell),
    );
}

test "pane viewport clipping is a hard surface intersection" {
    const testing = std.testing;
    const surface = Size{ .width = 100, .height = 80 };

    try testing.expectEqual(ViewportBounds{
        .x_px = 90,
        .y_px = 70,
        .width_px = 10,
        .height_px = 10,
    }, (GridViewport{
        .x_px = 90,
        .y_px = 70,
        .width_px = 30,
        .height_px = 40,
    }).clipped(surface).?);
    try testing.expectEqual(@as(u32, 0), scissorY(.{
        .x_px = 90,
        .y_px = 70,
        .width_px = 10,
        .height_px = 10,
    }, surface.height));
    try testing.expectEqual(@as(u32, 50), scissorY(.{
        .x_px = 0,
        .y_px = 10,
        .width_px = 10,
        .height_px = 20,
    }, surface.height));
    try testing.expect((GridViewport{
        .x_px = 100,
        .y_px = 0,
        .width_px = 1,
        .height_px = 1,
    }).clipped(surface) == null);
    try testing.expect((GridViewport{
        .x_px = 0,
        .y_px = 0,
        .width_px = 0,
        .height_px = 80,
    }).clipped(surface) == null);

    // Overflow is saturated before intersection, never wrapped back into a
    // sibling pane near the left edge.
    try testing.expectEqual(@as(u32, 1), (GridViewport{
        .x_px = 99,
        .y_px = 0,
        .width_px = std.math.maxInt(u32),
        .height_px = 1,
    }).clipped(surface).?.width_px);
}

test "inactive pane colour preserves opacity and subtly approaches background" {
    const testing = std.testing;
    const background = Rgba{ .r = 16, .g = 24, .b = 32 };

    try testing.expectEqual(
        Rgba{ .r = 212, .g = 108, .b = 11, .a = 99 },
        inactivePaneColor(.{ .r = 240, .g = 120, .b = 8, .a = 99 }, background),
    );
    try testing.expectEqual(background, inactivePaneColor(background, background));
}

test "grid viewport state is independent and an unchanged viewport invalidates no work" {
    const testing = std.testing;
    const colors = Colors{ .ansi = @splat(.{ .r = 0, .g = 0, .b = 0 }) };
    var first: Grid = .{
        .allocator = testing.allocator,
        .colors = colors,
        .solid = undefined,
        .cursor_pipeline = undefined,
        .glyph_pipeline = undefined,
        .redraw_all = false,
    };
    var second: Grid = .{
        .allocator = testing.allocator,
        .colors = colors,
        .solid = undefined,
        .cursor_pipeline = undefined,
        .glyph_pipeline = undefined,
        .redraw_all = false,
    };

    const left = GridViewport{ .x_px = 8, .y_px = 17, .width_px = 80, .height_px = 68 };
    const right = GridViewport{ .x_px = 96, .y_px = 17, .width_px = 80, .height_px = 68 };
    try testing.expect(first.configureViewport(left));
    try testing.expect(first.redraw_all);
    try testing.expect(second.active_viewport == null);
    try testing.expect(!second.redraw_all);

    // Simulate completion of the first retained frame. Reusing the same
    // viewport leaves its damage/cursor state alone and requests no redraw.
    first.redraw_all = false;
    first.painted = true;
    first.painted_row = 2;
    first.painted_rect = left.cellRect(1, 2, font.CellSize.init(8, 17));
    try testing.expect(!first.configureViewport(left));
    try testing.expect(!first.redraw_all);
    try testing.expect(first.painted);
    try testing.expectEqual(@as(u16, 2), first.painted_row);

    try testing.expect(second.configureViewport(right));
    try testing.expectEqual(left, first.active_viewport.?);
    try testing.expectEqual(right, second.active_viewport.?);
    try testing.expect(first.painted);

    // Focus dimming is visual state, so toggling it invalidates only the pane
    // whose viewport changed.
    second.redraw_all = false;
    var dimmed_right = right;
    dimmed_right.dimmed = true;
    try testing.expect(second.configureViewport(dimmed_right));
    try testing.expect(second.redraw_all);
    try testing.expect(!first.redraw_all);

    // Relayout retains only the new bounds and requests a repaint there. It
    // does not treat the old rectangle as renderer-owned: clearing that area
    // could erase a sibling that moved into it, so App clears and repaints the
    // complete layout before drawing changed viewports.
    first.redraw_all = false;
    const moved_left = GridViewport{ .x_px = 16, .y_px = 34, .width_px = 72, .height_px = 51 };
    try testing.expect(first.configureViewport(moved_left));
    try testing.expectEqual(moved_left, first.active_viewport.?);
    try testing.expect(first.redraw_all);
    try testing.expectEqual(left.cellRect(1, 2, font.CellSize.init(8, 17)), first.painted_rect);
}

test "pane staging applies two-axis origin and inactive colour to terminal cells" {
    const testing = std.testing;
    const background = Rgba{ .r = 16, .g = 24, .b = 32 };
    const viewport = GridViewport{
        .x_px = 24,
        .y_px = 34,
        .width_px = 80,
        .height_px = 68,
        .dimmed = true,
    };
    var grid: Grid = .{
        .allocator = testing.allocator,
        .colors = .{
            .ansi = @splat(.{ .r = 0, .g = 0, .b = 0 }),
            .background = background,
        },
        .solid = undefined,
        .cursor_pipeline = undefined,
        .glyph_pipeline = undefined,
        .active_viewport = viewport,
        .draw_viewport = viewport,
        .cell = font.CellSize.init(8, 17),
    };
    defer grid.solids.deinit(testing.allocator);
    defer grid.glyphs.deinit(testing.allocator);
    defer grid.color_glyphs.deinit(testing.allocator);
    defer grid.row_cells.deinit(testing.allocator);

    var unused_fonts: font.Manager = undefined;
    const cell_background = Rgba{ .r = 240, .g = 120, .b = 8 };
    try grid.addCell(&unused_fonts, .{
        .codepoint = 0,
        .grapheme = &.{},
        .wide = false,
        .wide_tail = false,
        .style = .{ .bg = .{ .rgb = .{
            .r = cell_background.r,
            .g = cell_background.g,
            .b = cell_background.b,
        } } },
    }, .{ .col = 2, .row = 1 }, true);

    try testing.expectEqual(@as(usize, 1), grid.solids.items.len);
    try testing.expectEqual([4]f32{ 40, 51, 8, 17 }, grid.solids.items[0].rect);
    try testing.expectEqual(
        inactivePaneColor(cell_background, background).toFloats(),
        grid.solids.items[0].color,
    );
}

test "terminal origin shifts terminal geometry and cursor damage only horizontally" {
    const testing = std.testing;
    const cell = font.CellSize.init(8, 17);
    const before = terminalCellRect(2, 3, cell, 0);
    const after = terminalCellRect(2, 3, cell, 4);

    try testing.expectEqual(PixelRect{ .x = 16, .y = 51, .width = 8, .height = 17 }, before);
    try testing.expectEqual(PixelRect{ .x = 48, .y = 51, .width = 8, .height = 17 }, after);

    const damage = cursorDamage(true, before, 3, after, 3, true);
    try testing.expectEqual(@as(?u16, 3), damage.erase_row);
    try testing.expectEqual(@as(?u16, 3), damage.paint_row);

    var grid: Grid = undefined;
    grid.painted = true;
    grid.cursor_rect = after;
    try testing.expectEqual(after, grid.cursor().?);
}

test "terminal origin shifts cell backgrounds and decorations together" {
    const testing = std.testing;
    var grid: Grid = .{
        .allocator = testing.allocator,
        .colors = .{ .ansi = @splat(.{ .r = 0, .g = 0, .b = 0 }) },
        .solid = undefined,
        .cursor_pipeline = undefined,
        .glyph_pipeline = undefined,
        .terminal_origin_columns = 2,
        .cell = font.CellSize.init(8, 20),
        .baseline_px = 15,
        .ascent_px = 12,
    };
    defer grid.solids.deinit(testing.allocator);
    defer grid.glyphs.deinit(testing.allocator);
    defer grid.color_glyphs.deinit(testing.allocator);
    defer grid.row_cells.deinit(testing.allocator);

    var unused_fonts: font.Manager = undefined;
    try grid.addCell(&unused_fonts, .{
        .codepoint = 0,
        .grapheme = &.{},
        .wide = false,
        .wide_tail = false,
        .style = .{
            .attributes = .{
                .underline = .single,
                .strikethrough = true,
                .overline = true,
            },
        },
    }, .{ .col = 1, .row = 0 }, true);

    try testing.expectEqual(@as(usize, 4), grid.solids.items.len);
    for (grid.solids.items) |solid| {
        try testing.expectEqual(@as(f32, 24), solid.rect[0]);
    }
}

test "changing terminal origin invalidates once and reserves the full overlay width" {
    const testing = std.testing;
    var grid: Grid = .{
        .allocator = testing.allocator,
        .colors = .{ .ansi = @splat(.{ .r = 0, .g = 0, .b = 0 }) },
        .solid = undefined,
        .cursor_pipeline = undefined,
        .glyph_pipeline = undefined,
        .terminal_origin_columns = 2,
        .reserved_origin_columns = 2,
        .redraw_all = false,
    };
    defer grid.solids.deinit(testing.allocator);
    defer grid.glyphs.deinit(testing.allocator);
    defer grid.color_glyphs.deinit(testing.allocator);
    defer grid.row_cells.deinit(testing.allocator);
    defer grid.ranges.deinit(testing.allocator);
    defer grid.shaped.deinit(testing.allocator);

    grid.setTerminalOriginColumns(2);
    try testing.expect(!grid.redraw_all);
    grid.setTerminalOriginColumns(3);
    try testing.expect(grid.redraw_all);

    const size = try term.GridSize.init(8, 2);
    try grid.reserve(size);
    const full_cells: usize = (8 + 3) * 2;
    try testing.expect(grid.solids.capacity >= full_cells * 4 + max_cursor_rects);
    try testing.expect(grid.glyphs.capacity >= full_cells * 4);
    try testing.expectEqual(@as(u16, 3), grid.reserved_origin_columns);
}

test "overlay cells accept one matching grapheme and reject malformed or half-wide input" {
    const testing = std.testing;
    const foreground = Rgba{ .r = 220, .g = 220, .b = 220 };

    const narrow: OverlayCell = .{
        .position = .{ .col = 2, .row = 1 },
        .foreground = foreground,
        .text = "A",
    };
    try testing.expect(narrow.validFor(10, 4));

    const combining: OverlayCell = .{
        .position = .{ .col = 3, .row = 1 },
        .foreground = foreground,
        .text = "e\xCC\x81",
    };
    try testing.expect(combining.validFor(10, 4));

    const wide: OverlayCell = .{
        .position = .{ .col = 8, .row = 1 },
        .foreground = foreground,
        .span = .two,
        .text = "\xE7\x95\x8C",
    };
    try testing.expect(wide.validFor(10, 4));

    var wrong_span = wide;
    wrong_span.span = .one;
    try testing.expect(!wrong_span.validFor(10, 4));

    var half_wide = wide;
    half_wide.position.col = 9;
    try testing.expect(!half_wide.validFor(10, 4));

    var outside = narrow;
    outside.position.row = 4;
    try testing.expect(!outside.validFor(10, 4));

    var multiple = narrow;
    multiple.text = "AB";
    try testing.expect(!multiple.validFor(10, 4));

    var invalid = narrow;
    invalid.text = &[_]u8{0xff};
    try testing.expect(!invalid.validFor(10, 4));

    var zero_width = narrow;
    zero_width.text = "\xCC\x81";
    try testing.expect(!zero_width.validFor(10, 4));

    // Empty text can still fill/decorate a two-cell surface, but it cannot
    // claim an orphaned second cell at the grid edge.
    const fill: OverlayCell = .{
        .position = .{ .col = 7, .row = 2 },
        .foreground = foreground,
        .span = .two,
        .background = .{ .r = 10, .g = 20, .b = 30 },
    };
    try testing.expect(fill.validFor(10, 4));
    var orphaned_fill = fill;
    orphaned_fill.position.col = 9;
    try testing.expect(!orphaned_fill.validFor(10, 4));
}

test "overlay damage selects only valid cells on repainted rows" {
    const testing = std.testing;
    const foreground = Rgba{ .r = 220, .g = 220, .b = 220 };
    const ranges = [_]RowRange{
        .{ .first = 2, .last = 3 },
        .{ .first = 7, .last = 7 },
    };

    const damaged: OverlayCell = .{
        .position = .{ .col = 1, .row = 3 },
        .foreground = foreground,
        .text = "x",
    };
    try testing.expect(overlayCellInDamage(damaged, 10, 8, &ranges));

    var untouched = damaged;
    untouched.position.row = 4;
    try testing.expect(!overlayCellInDamage(untouched, 10, 8, &ranges));

    var malformed = damaged;
    malformed.text = "xy";
    try testing.expect(!overlayCellInDamage(malformed, 10, 8, &ranges));

    var outside = damaged;
    outside.position.col = 10;
    try testing.expect(!overlayCellInDamage(outside, 10, 8, &ranges));

    try testing.expect(!overlayCellInDamage(damaged, 10, 8, &.{}));
}

test "overlay validation uses its absolute full-canvas extent" {
    const testing = std.testing;
    const ranges = [_]RowRange{.{ .first = 1, .last = 1 }};
    const sidebar_edge: OverlayCell = .{
        .position = .{ .col = 10, .row = 1 },
        .foreground = .{ .r = 220, .g = 220, .b = 220 },
        .text = "x",
    };

    // An eight-column terminal inset by three columns shares an eleven-column
    // canvas. Overlay coordinates are absolute, not shifted by the terminal.
    try testing.expect(overlayCellInDamage(sidebar_edge, 11, 2, &ranges));
    try testing.expect(!overlayCellInDamage(sidebar_edge, 8, 2, &ranges));
    try testing.expectEqual(@as(f32, 80), cellRect(10, 1, font.CellSize.init(8, 17)).x);

    const legacy: OverlayView = .{};
    try testing.expectEqual(@as(u32, 0), legacy.cols);
    try testing.expectEqual(@as(u32, 0), legacy.rows);
}

test "full canvas overlay preparation retains storage and unchanged frames do no work" {
    const testing = std.testing;
    const metrics: font.Metrics = .{
        .cell = font.CellSize.init(8, 17),
        .baseline_px = 13,
        .ascent_px = 12,
        .descent_px = 4,
    };
    var grid: Grid = .{
        .allocator = testing.allocator,
        .colors = .{ .ansi = @splat(.{ .r = 0, .g = 0, .b = 0 }) },
        .solid = undefined,
        .cursor_pipeline = undefined,
        .glyph_pipeline = undefined,
    };
    defer grid.solids.deinit(testing.allocator);
    defer grid.glyphs.deinit(testing.allocator);
    defer grid.color_glyphs.deinit(testing.allocator);
    defer grid.row_cells.deinit(testing.allocator);
    defer grid.ranges.deinit(testing.allocator);
    defer grid.shaped.deinit(testing.allocator);

    const view = OverlayView{ .cols = 12, .rows = 8 };
    try testing.expect(try grid.prepareCanvasOverlayMetrics(view, metrics));
    try testing.expectEqual(metrics.cell, grid.cell);
    try testing.expectEqual(metrics.baseline_px, grid.baseline_px);
    try testing.expectEqual(metrics.ascent_px, grid.ascent_px);
    try testing.expect(grid.solids.capacity >= 12 * 8 * 4);
    try testing.expect(grid.glyphs.capacity >= 12 * 8 * 4);

    // Simulate the successful first overlay pass. The same prepared extent
    // keeps every retained capacity and requires no base repaint.
    grid.canvas_overlay_invalidated = false;
    const solid_capacity = grid.solids.capacity;
    const glyph_capacity = grid.glyphs.capacity;
    try testing.expect(!try grid.prepareCanvasOverlayMetrics(view, metrics));
    try testing.expectEqual(solid_capacity, grid.solids.capacity);
    try testing.expectEqual(glyph_capacity, grid.glyphs.capacity);

    // The unchanged draw decision happens before any GPU work.
    try testing.expect(grid.skipCanvasOverlayIfUnchanged(false));
    try testing.expect(!grid.skipCanvasOverlayIfUnchanged(true));
    try testing.expectEqual(@as(u64, 1), grid.stats.overlay_skipped_frames);
    try testing.expectEqual(@as(u64, 0), grid.stats.overlay_frames);

    var unused_surface: Surface = undefined;
    var unused_fonts: font.Manager = undefined;
    grid.invalidateCanvasOverlay();
    try testing.expect(try grid.prepareCanvasOverlayMetrics(view, metrics));

    const wrong_size = OverlayView{ .cols = 11, .rows = 8 };
    try testing.expectError(
        error.CanvasOverlayNotPrepared,
        grid.drawCanvasOverlay(&unused_surface, &unused_fonts, wrong_size, false),
    );
}

test "full canvas overlay staging stays absolute for a nonzero pane origin" {
    const testing = std.testing;
    const pane = GridViewport{
        .x_px = 40,
        .y_px = 34,
        .width_px = 48,
        .height_px = 51,
    };
    var grid: Grid = .{
        .allocator = testing.allocator,
        .colors = .{ .ansi = @splat(.{ .r = 0, .g = 0, .b = 0 }) },
        .solid = undefined,
        .cursor_pipeline = undefined,
        .glyph_pipeline = undefined,
        .active_viewport = pane,
        .draw_viewport = pane,
        .cell = font.CellSize.init(8, 17),
    };
    defer grid.solids.deinit(testing.allocator);
    defer grid.glyphs.deinit(testing.allocator);
    defer grid.color_glyphs.deinit(testing.allocator);
    defer grid.row_cells.deinit(testing.allocator);
    defer grid.ranges.deinit(testing.allocator);
    defer grid.shaped.deinit(testing.allocator);

    const view = OverlayView{ .cols = 12, .rows = 8 };
    _ = try grid.prepareCanvasOverlayMetrics(view, .{
        .cell = font.CellSize.init(8, 17),
        .baseline_px = 13,
        .ascent_px = 12,
        .descent_px = 4,
    });
    var unused_fonts: font.Manager = undefined;
    try grid.addOverlayCell(&unused_fonts, .{
        .position = .{ .col = 7, .row = 5 },
        .foreground = .{ .r = 220, .g = 220, .b = 220 },
        .background = .{ .r = 10, .g = 20, .b = 30 },
    });

    try testing.expectEqual(@as(usize, 1), grid.solids.items.len);
    // Overlay coordinates remain full-canvas coordinates. The pane's 40x34
    // origin is deliberately irrelevant, especially to the nonzero row.
    try testing.expectEqual([4]f32{ 56, 85, 8, 17 }, grid.solids.items[0].rect);
}

test "invalidating a grid requests a full base repaint" {
    const testing = std.testing;

    var grid: Grid = undefined;
    grid.redraw_all = false;
    grid.invalidate();
    try testing.expect(grid.redraw_all);
}

test "a glyph sits where its bearing and the cell's baseline put it" {
    const testing = std.testing;

    const entry = font.Entry{
        .key = .{ .glyph_index = 1 },
        .rect = .{ .x = 10, .y = 20, .width = 7, .height = 12 },
        // One pixel right of the pen, and its top nine pixels above the
        // baseline: the usual shape for a glyph with an ascender.
        .bearing_x_px = 1,
        .bearing_y_px = 9,
        .advance_px = 8,
        .slot = 0,
    };
    const cell = cellRect(2, 1, font.CellSize.init(8, 17));
    const placed = glyphRect(cell, 13, entry);
    try testing.expectEqual(@as(f32, 17), placed.x);
    try testing.expectEqual(@as(f32, 21), placed.y);
    try testing.expectEqual(@as(f32, 7), placed.width);
    try testing.expectEqual(@as(f32, 12), placed.height);

    // A negative bearing puts the glyph left of its pen, which is what an
    // italic overhang or a combining mark does.
    const overhanging = glyphRect(cell, 13, .{
        .key = .{ .glyph_index = 2 },
        .rect = .{ .width = 4, .height = 4 },
        .bearing_x_px = -2,
        .bearing_y_px = -1,
        .advance_px = 4,
        .slot = 1,
    });
    try testing.expectEqual(@as(f32, 14), overhanging.x);
    // A negative top bearing puts the glyph below the baseline rather than
    // above it: 17 + 13 + 1.
    try testing.expectEqual(@as(f32, 31), overhanging.y);
}

test "atlas coordinates land in the middle of a texel, not on its edge" {
    const testing = std.testing;

    const atlas = AtlasSize{ .width_px = 1024, .height_px = 512 };
    const uv = uvOf(.{ .x = 0, .y = 0, .width = 8, .height = 16 }, atlas);
    try testing.expectApproxEqAbs(@as(f32, 0.5 / 1024.0), uv[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f32, 0.5 / 512.0), uv[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f32, 7.5 / 1024.0), uv[2], 1e-9);
    try testing.expectApproxEqAbs(@as(f32, 15.5 / 512.0), uv[3], 1e-9);

    // A one-texel glyph samples one texel centre, so its two coordinates are
    // equal and NEAREST filtering cannot pick a neighbour.
    const dot = uvOf(.{ .x = 3, .y = 4, .width = 1, .height = 1 }, atlas);
    try testing.expectEqual(dot[0], dot[2]);
    try testing.expectEqual(dot[1], dot[3]);
}

test "each cursor shape is the shape it claims to be" {
    const testing = std.testing;

    const cell = PixelRect{ .x = 32, .y = 51, .width = 8, .height = 17 };

    // A block is the whole cell and nothing else.
    const block = cursorPaint(.block, cell, 1);
    try testing.expectEqual(@as(u8, 1), block.count);
    try testing.expectEqual(cell, block.rects[0]);

    // A hollow block is four bars and no fill, and between them they cover
    // exactly the cell: the middle is left to the cell's own colours.
    const hollow = cursorPaint(.block_hollow, cell, 1);
    try testing.expectEqual(@as(u8, 4), hollow.count);
    try testing.expectEqual(@as(f32, 8), hollow.rects[0].width);
    try testing.expectEqual(@as(f32, 1), hollow.rects[0].height);
    // The right bar sits on the cell's trailing edge, not on the cell's left.
    try testing.expectEqual(@as(f32, 39), hollow.rects[3].x);
    try testing.expectEqual(@as(f32, 40), hollow.rects[3].x + hollow.rects[3].width);

    // A bar is a vertical line on the leading edge, as tall as the cell.
    const bar = cursorPaint(.bar, cell, 2);
    try testing.expectEqual(@as(u8, 1), bar.count);
    try testing.expectEqual(@as(f32, 32), bar.rects[0].x);
    try testing.expectEqual(@as(f32, 2), bar.rects[0].width);
    try testing.expectEqual(@as(f32, 17), bar.rects[0].height);

    // An underline is a horizontal line along the bottom, as wide as the cell.
    const underline = cursorPaint(.underline, cell, 2);
    try testing.expectEqual(@as(u8, 1), underline.count);
    try testing.expectEqual(@as(f32, 8), underline.rects[0].width);
    try testing.expectEqual(@as(f32, 66), underline.rects[0].y);
    try testing.expectEqual(@as(f32, 2), underline.rects[0].height);

    // A thickness larger than the cell cannot produce a negative bar.
    const fat = cursorPaint(.block_hollow, cell, 40);
    try testing.expect(fat.rects[0].height <= cell.height);
    try testing.expect(fat.rects[3].height >= 0);
}

test "the rows a frame must redraw merge, sort, and stay inside the grid" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ranges: std.ArrayList(RowRange) = .empty;
    defer ranges.deinit(allocator);

    // Nothing changed and no cursor moved: nothing to draw.
    try mergeRows(&ranges, allocator, &.{}, &.{}, 24);
    try testing.expectEqual(@as(usize, 0), ranges.items.len);

    // One damaged row is one range.
    try mergeRows(&ranges, allocator, &.{4}, &.{}, 24);
    try testing.expectEqual(@as(usize, 1), ranges.items.len);
    try testing.expectEqual(RowRange{ .first = 4, .last = 4 }, ranges.items[0]);

    // A cursor that moved adds the row it left and the row it is on, and the
    // union of the two lists is still sorted and free of overlap.
    ranges.clearRetainingCapacity();
    try mergeRows(&ranges, allocator, &.{ 4, 5, 9 }, &.{ 3, 9 }, 24);
    try testing.expectEqual(@as(usize, 2), ranges.items.len);
    try testing.expectEqual(RowRange{ .first = 3, .last = 5 }, ranges.items[0]);
    try testing.expectEqual(RowRange{ .first = 9, .last = 9 }, ranges.items[1]);

    // A gap stays a gap: rows the terminal did not name are not repainted.
    ranges.clearRetainingCapacity();
    try mergeRows(&ranges, allocator, &.{ 0, 2 }, &.{}, 24);
    try testing.expectEqual(@as(usize, 2), ranges.items.len);
    try testing.expectEqual(RowRange{ .first = 0, .last = 0 }, ranges.items[0]);
    try testing.expectEqual(RowRange{ .first = 2, .last = 2 }, ranges.items[1]);

    // Rows the grid no longer has are dropped rather than walked off the end of.
    ranges.clearRetainingCapacity();
    try mergeRows(&ranges, allocator, &.{ 5, 40 }, &.{99}, 24);
    try testing.expectEqual(@as(usize, 1), ranges.items.len);
    try testing.expectEqual(RowRange{ .first = 5, .last = 5 }, ranges.items[0]);
}

test "a range set says which rows it covers" {
    const testing = std.testing;

    const ranges = [_]RowRange{ .{ .first = 2, .last = 4 }, .{ .first = 9, .last = 9 } };
    try testing.expect(!rangeContains(&ranges, 1));
    try testing.expect(rangeContains(&ranges, 2));
    try testing.expect(rangeContains(&ranges, 4));
    try testing.expect(!rangeContains(&ranges, 5));
    try testing.expect(rangeContains(&ranges, 9));
    try testing.expect(!rangeContains(&ranges, 10));
    try testing.expect(!rangeContains(&.{}, 0));
}

test "a cursor sitting still forces nothing: the idle frame regression" {
    const testing = std.testing;
    const cell = font.CellSize.init(8, 20);
    const drawn = cellRect(2, 4, cell);

    // The bug: `mergeDamage` used to be handed one flag meaning "this cursor
    // needs drawing" (wanted AND moved-or-not-yet-painted) and read it as "this
    // cursor is wanted". An idle frame therefore looked like a cursor that had
    // just disappeared, and its row was repainted every single frame —
    // `--grid-test` reported an idle frame doing 3 draws and 512 B of uploads.
    const idle = cursorDamage(true, drawn, 4, drawn, 4, true);
    try testing.expectEqual(@as(?u16, null), idle.erase_row);
    try testing.expectEqual(@as(?u16, null), idle.paint_row);

    var scratch: [2]u16 = .{ 0, 0 };
    try testing.expectEqual(@as(usize, 0), cursorRows(idle, &scratch).len);

    // Same answer when the terminal reports nothing either: no damage, no rows.
    var ranges: std.ArrayList(RowRange) = .empty;
    defer ranges.deinit(testing.allocator);
    try mergeRows(&ranges, testing.allocator, &.{}, cursorRows(idle, &scratch), 24);
    try testing.expectEqual(@as(usize, 0), ranges.items.len);

    // And when one row really did change, that row and nothing else is drawn:
    // a frame with damage still does not repaint the cursor's row for free.
    try mergeRows(&ranges, testing.allocator, &.{7}, cursorRows(idle, &scratch), 24);
    try testing.expectEqual(@as(usize, 1), ranges.items.len);
    try testing.expectEqual(RowRange{ .first = 7, .last = 7 }, ranges.items[0]);
}

test "a cursor that moves repaints the row it left and the row it reached" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const cell = font.CellSize.init(8, 20);
    const was = cellRect(2, 4, cell);
    const now = cellRect(0, 1, cell);

    const moved = cursorDamage(true, was, 4, now, 1, true);
    try testing.expectEqual(@as(?u16, 4), moved.erase_row);
    try testing.expectEqual(@as(?u16, 1), moved.paint_row);

    // The two rows are handed over in ascending order whatever order they were
    // decided in, because `mergeRows` walks both inputs together.
    var scratch: [2]u16 = .{ 0, 0 };
    try testing.expectEqualSlices(u16, &.{ 1, 4 }, cursorRows(moved, &scratch));

    var ranges: std.ArrayList(RowRange) = .empty;
    defer ranges.deinit(allocator);
    try mergeRows(&ranges, allocator, &.{1}, cursorRows(moved, &scratch), 24);
    // The cursor's rows and the damaged row are the same two rows, so the frame
    // repaints two rows rather than three.
    try testing.expectEqual(@as(usize, 2), ranges.items.len);
    try testing.expectEqual(RowRange{ .first = 1, .last = 1 }, ranges.items[0]);
    try testing.expectEqual(RowRange{ .first = 4, .last = 4 }, ranges.items[1]);
}

test "a cursor within one row erases that row once, and nothing else" {
    const testing = std.testing;
    const cell = font.CellSize.init(8, 20);
    const was = cellRect(0, 1, cell);
    const now = cellRect(1, 1, cell);

    // Same row, so erase and paint name the same row and the merge collapses
    // them: one row repainted, not two.
    const slid = cursorDamage(true, was, 1, now, 1, true);
    try testing.expectEqual(@as(?u16, 1), slid.erase_row);
    try testing.expectEqual(@as(?u16, 1), slid.paint_row);

    var scratch: [2]u16 = .{ 0, 0 };
    var ranges: std.ArrayList(RowRange) = .empty;
    defer ranges.deinit(testing.allocator);
    try mergeRows(&ranges, testing.allocator, &.{}, cursorRows(slid, &scratch), 24);
    try testing.expectEqual(@as(usize, 1), ranges.items.len);
    try testing.expectEqual(RowRange{ .first = 1, .last = 1 }, ranges.items[0]);
}

test "a cursor that appears, hides, or blinks is erased once and drawn once" {
    const testing = std.testing;
    const cell = font.CellSize.init(8, 20);
    const here = cellRect(2, 4, cell);

    // Appearing: there is nothing on the surface to erase, and the row it lands
    // on is repainted so the cursor has a freshly drawn cell to sit on.
    const appeared = cursorDamage(false, .{}, 0, here, 4, true);
    try testing.expectEqual(@as(?u16, null), appeared.erase_row);
    try testing.expectEqual(@as(?u16, 4), appeared.paint_row);

    // A cursor on the second blink phase: still drawn where it was, so still no
    // rows — a blinking cursor must not cost a frame per phase.
    const blinked = cursorDamage(true, here, 4, here, 4, true);
    try testing.expectEqual(@as(?u16, null), blinked.erase_row);
    try testing.expectEqual(@as(?u16, null), blinked.paint_row);

    // Hiding, or blinking off: the row it was drawn on has to be repainted to
    // erase it, and nothing is drawn.
    const hidden = cursorDamage(true, here, 4, here, 4, false);
    try testing.expectEqual(@as(?u16, 4), hidden.erase_row);
    try testing.expectEqual(@as(?u16, null), hidden.paint_row);

    // Blinking back on, on the same cell — and the same is true of hiding with
    // `\x1b[?25l` and revealing with `\x1b[?25h`. The cell it was painted on is
    // the cell the terminal wants it on, so comparing the two rectangles alone
    // would answer "already there" and the cursor would never come back.
    const blinked_on = cursorDamage(false, here, 4, here, 4, true);
    try testing.expectEqual(@as(?u16, null), blinked_on.erase_row);
    try testing.expectEqual(@as(?u16, 4), blinked_on.paint_row);

    // A terminal with no cursor at all, and nothing painted, adds nothing.
    const none = cursorDamage(false, .{}, 0, .{}, null, false);
    try testing.expectEqual(@as(?u16, null), none.erase_row);
    try testing.expectEqual(@as(?u16, null), none.paint_row);

    var scratch: [2]u16 = .{ 0, 0 };
    try testing.expectEqual(@as(usize, 0), cursorRows(none, &scratch).len);
    try testing.expectEqualSlices(u16, &.{4}, cursorRows(blinked_on, &scratch));
    try testing.expectEqualSlices(u16, &.{4}, cursorRows(hidden, &scratch));

    // A cursor that moved off the grid entirely adds no row: the merge drops
    // rows the grid no longer has rather than walking off the end of them.
    var ranges: std.ArrayList(RowRange) = .empty;
    defer ranges.deinit(testing.allocator);
    const off_grid = cursorDamage(true, here, 4, here, 99, true);
    try mergeRows(&ranges, testing.allocator, &.{}, cursorRows(off_grid, &scratch), 5);
    try testing.expectEqual(@as(usize, 0), ranges.items.len);
}

test "a cursor that blinks or is un-hidden repaints its own row, and an idle frame repaints nothing" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const cell = font.CellSize.init(8, 20);
    const here = cellRect(2, 4, cell);

    // Where `Grid.draw` believes the cursor's pixels are, walked the way `draw`
    // walks it: the plan for one frame, then the update `draw` makes once that
    // frame has been drawn. The cursor's cases differ only in the state they
    // leave behind, so they are worth checking as a sequence and not one call
    // at a time — the blink and the hide/reveal are the same two frames with
    // different bytes on the wire, and both have to come back.
    const Bookkeeping = struct {
        painted: bool = false,
        rect: PixelRect = .{},
        row: u16 = 0,

        /// One frame in which the terminal reported no damage of its own.
        fn frame(
            self: *@This(),
            rect: PixelRect,
            row: ?u16,
            wanted: bool,
            gpa: std.mem.Allocator,
        ) !struct { plan: CursorDamage, repainted: bool, rows: usize } {
            const plan = cursorDamage(self.painted, self.rect, self.row, rect, row, wanted);
            var scratch: [2]u16 = .{ 0, 0 };
            var ranges: std.ArrayList(RowRange) = .empty;
            defer ranges.deinit(gpa);
            try mergeRows(&ranges, gpa, &.{}, cursorRows(plan, &scratch), 24);
            const repainted = wanted and row != null and rangeContains(ranges.items, row.?);
            if (repainted) {
                self.painted = true;
                self.rect = rect;
                self.row = row.?;
            } else if (plan.erase_row != null) {
                self.painted = false;
            }
            return .{ .plan = plan, .repainted = repainted, .rows = ranges.items.len };
        }
    };

    var state: Bookkeeping = .{};

    // Appearing: nothing on the surface to erase, and the one row the cursor
    // lands on is repainted so the cursor has a cell to sit on.
    var frame = try state.frame(here, 4, true, allocator);
    try testing.expectEqual(@as(?u16, null), frame.plan.erase_row);
    try testing.expectEqual(@as(?u16, 4), frame.plan.paint_row);
    try testing.expectEqual(@as(usize, 1), frame.rows);
    try testing.expect(frame.repainted);

    // Sitting still is an idle frame, and an idle frame costs nothing: no
    // rows, however many of them arrive.
    for (0..5) |_| {
        frame = try state.frame(here, 4, true, allocator);
        try testing.expectEqual(@as(?u16, null), frame.plan.erase_row);
        try testing.expectEqual(@as(?u16, null), frame.plan.paint_row);
        try testing.expectEqual(@as(usize, 0), frame.rows);
        try testing.expect(!frame.repainted);
    }

    // Blinking off, then on again. Blinking never moves the cursor, so the
    // rectangle it is drawn at is byte-for-byte the one it was drawn at a
    // moment ago; the only thing that says its row is due is that its pixels
    // are gone. Asking the rectangle alone says "already there" and the cursor
    // never comes back.
    frame = try state.frame(here, 4, false, allocator);
    try testing.expectEqual(@as(?u16, 4), frame.plan.erase_row);
    try testing.expectEqual(@as(?u16, null), frame.plan.paint_row);
    try testing.expectEqual(@as(usize, 1), frame.rows);
    try testing.expect(!frame.repainted);
    try testing.expect(!state.painted);

    frame = try state.frame(here, 4, true, allocator);
    try testing.expectEqual(@as(?u16, null), frame.plan.erase_row);
    try testing.expectEqual(@as(?u16, 4), frame.plan.paint_row);
    try testing.expectEqual(@as(usize, 1), frame.rows);
    try testing.expect(frame.repainted);
    try testing.expect(state.painted);

    // And the frame after that is idle again: drawn once, not once per blink
    // phase for the rest of the session.
    frame = try state.frame(here, 4, true, allocator);
    try testing.expectEqual(@as(usize, 0), frame.rows);

    // Hiding with `\x1b[?25l` and revealing with `\x1b[?25h` is the same pair
    // of frames with different bytes behind it, on the same cell throughout.
    frame = try state.frame(here, 4, false, allocator);
    try testing.expectEqual(@as(?u16, 4), frame.plan.erase_row);
    try testing.expectEqual(@as(usize, 1), frame.rows);
    try testing.expect(!frame.repainted);

    frame = try state.frame(here, 4, true, allocator);
    try testing.expectEqual(@as(?u16, 4), frame.plan.paint_row);
    try testing.expectEqual(@as(usize, 1), frame.rows);
    try testing.expect(frame.repainted);

    frame = try state.frame(here, 4, true, allocator);
    try testing.expectEqual(@as(usize, 0), frame.rows);

    // Moving to another cell erases the row it left and repaints the one it
    // reached — two rows, and neither of them stays dirty afterwards.
    frame = try state.frame(cellRect(0, 1, cell), 1, true, allocator);
    try testing.expectEqual(@as(?u16, 4), frame.plan.erase_row);
    try testing.expectEqual(@as(?u16, 1), frame.plan.paint_row);
    try testing.expectEqual(@as(usize, 2), frame.rows);
    try testing.expect(frame.repainted);

    frame = try state.frame(cellRect(0, 1, cell), 1, true, allocator);
    try testing.expectEqual(@as(usize, 0), frame.rows);
}

fn textCell(codepoint: u21) term.Cell {
    return .{ .codepoint = codepoint, .grapheme = &.{}, .wide = false, .wide_tail = false };
}

/// A grid that stages glyphs without a GL context: `addCell` and `addGlyph`
/// only need an atlas size to compute texture coordinates.
fn stagingGrid(metrics: font.Metrics) Grid {
    return .{
        .allocator = std.testing.allocator,
        .colors = .{ .ansi = @splat(.{ .r = 0, .g = 0, .b = 0 }) },
        .solid = undefined,
        .cursor_pipeline = undefined,
        .glyph_pipeline = undefined,
        .atlas = .{ .width_px = 1024, .height_px = 1024 },
        .cell = metrics.cell,
        .baseline_px = metrics.baseline_px,
        .ascent_px = metrics.ascent_px,
    };
}

fn freeStaging(grid: *Grid) void {
    grid.solids.deinit(std.testing.allocator);
    grid.glyphs.deinit(std.testing.allocator);
    grid.color_glyphs.deinit(std.testing.allocator);
    grid.shaped.deinit(std.testing.allocator);
    grid.row_cells.deinit(std.testing.allocator);
}

test "ligature runs are maximal same-style ASCII and need a punctuation trigger" {
    const testing = std.testing;
    var cells = [_]term.Cell{ textCell('a'), textCell('='), textCell('>'), textCell(' '), textCell('b'), textCell('c') };
    try testing.expectEqual(@as(usize, 3), ligatureRunEnd(&cells, 0));
    try testing.expect(runHasLigatureTrigger(cells[0..3]));
    try testing.expectEqual(@as(usize, 4), ligatureRunEnd(&cells, 3));
    try testing.expectEqual(@as(usize, 6), ligatureRunEnd(&cells, 4));
    try testing.expect(!runHasLigatureTrigger(cells[4..6]));

    // A style change ends the run, and so do wide, combined and concealed cells.
    cells[2].style.attributes.bold = true;
    try testing.expectEqual(@as(usize, 2), ligatureRunEnd(&cells, 0));
    var wide = textCell(0x4E2D);
    wide.wide = true;
    try testing.expect(!ligatureCandidate(wide));
    var hidden = textCell('=');
    hidden.style.attributes.invisible = true;
    try testing.expect(!ligatureCandidate(hidden));
    try testing.expect(!ligatureCandidate(textCell(' ')));
}

test "a ligature run draws the font's ligature, and toggling ligatures off draws the plain glyphs" {
    const testing = std.testing;
    var fonts = try font.Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try font.Size.init(14, 1.0),
        .system_fallback = false,
    });
    defer fonts.deinit();
    var grid = stagingGrid(fonts.metrics());
    defer freeStaging(&grid);
    try grid.shaped.ensureTotalCapacity(testing.allocator, ligature_run_capacity);

    const cells = [_]term.Cell{ textCell('='), textCell('>') };
    try grid.addLigatureRun(&fonts, &cells, 0, 0);
    // JetBrains Mono draws `=>` as an empty spacer in the first cell and one
    // glyph anchored in the second that reaches back over the first.
    try testing.expectEqual(@as(usize, 1), grid.glyphs.items.len);
    const second_cell_x: f32 = @floatFromInt(fonts.metrics().cell.width_px);
    try testing.expect(grid.glyphs.items[0].rect[0] < second_cell_x);
    try testing.expect(grid.glyphs.items[0].rect[2] > second_cell_x);

    // Off: each cell's own glyph, which is what the per-cell path draws too.
    grid.glyphs.clearRetainingCapacity();
    fonts.setLigatures(false);
    try grid.addLigatureRun(&fonts, &cells, 0, 0);
    try testing.expectEqual(@as(usize, 2), grid.glyphs.items.len);
    try testing.expect(grid.glyphs.items[1].rect[0] >= second_cell_x);
}

test "box drawing and Powerline cells are sprites that cover their cell exactly" {
    const testing = std.testing;
    var fonts = try font.Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try font.Size.init(14, 1.0),
        .system_fallback = false,
    });
    defer fonts.deinit();
    var grid = stagingGrid(fonts.metrics());
    defer freeStaging(&grid);

    const cell = fonts.metrics().cell;
    for ([_]u21{ 0x2502, 0x2500, 0xE0B0, 0x2588 }, 0..) |codepoint, col| {
        grid.glyphs.clearRetainingCapacity();
        try grid.addCell(&fonts, textCell(codepoint), .{ .col = @intCast(col), .row = 1 }, true);
        try testing.expectEqual(@as(usize, 1), grid.glyphs.items.len);
        const expected = cellRect(@intCast(col), 1, cell);
        try testing.expectEqual(
            [4]f32{ expected.x, expected.y, expected.width, expected.height },
            grid.glyphs.items[0].rect,
        );
    }
}

test "a colour emoji is queued for the colour pass and a wide fallback glyph spans its cells" {
    const testing = std.testing;
    var fonts = try font.Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try font.Size.init(14, 1.0),
    });
    defer fonts.deinit();
    var grid = stagingGrid(fonts.metrics());
    defer freeStaging(&grid);
    const cell = fonts.metrics().cell;

    if (fonts.resolve(.regular, 0x1F600)) |hit| if (fonts.isColor(hit.face_index)) {
        var emoji = textCell(0x1F600);
        emoji.wide = true;
        try grid.addCell(&fonts, emoji, .{ .col = 0, .row = 0 }, true);
        try testing.expectEqual(@as(usize, 1), grid.color_glyphs.items.len);
        try testing.expectEqual(@as(usize, 0), grid.glyphs.items.len);
        const rect = grid.color_glyphs.items[0].rect;
        try testing.expect(rect[0] >= 0 and rect[0] + rect[2] <= @as(f32, @floatFromInt(2 * cell.width_px)));
        try testing.expect(rect[1] >= 0 and rect[1] + rect[3] <= @as(f32, @floatFromInt(cell.height_px)));
    };

    if (fonts.resolve(.regular, 0x4E2D) != null) {
        var ideograph = textCell(0x4E2D);
        ideograph.wide = true;
        grid.glyphs.clearRetainingCapacity();
        try grid.addCell(&fonts, ideograph, .{ .col = 0, .row = 0 }, true);
        try testing.expectEqual(@as(usize, 1), grid.glyphs.items.len);
        try testing.expect(grid.glyphs.items[0].rect[2] > @as(f32, @floatFromInt(cell.width_px)));
    }
}
