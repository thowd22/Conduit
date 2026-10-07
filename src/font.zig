//! The font stack: discovery, shaping and the glyph atlas.
//!
//! **Owns** finding font files, opening a family's regular, bold, italic and bold-italic faces,
//! shaping a run of text, and the atlas of rasterised glyphs. **Never** draws anything and never
//! reads a terminal: the renderer consumes what this module produces, and terminal state never
//! reaches this file.
//! **May depend on** `std`, the vendored FreeType and HarfBuzz, and the filesystem.
//!
//! Allocates through the allocator passed to every entry point. A `Manager` owns its FreeType
//! library handle, its distinct `FT_Face` and HarfBuzz font handles, its shared HarfBuzz buffer,
//! its atlas and every string it reports; `deinit` releases all of it. Nothing here reaches for a
//! global allocator.
//!
//! ## How a codepoint finds a glyph (v2, TASK-39)
//!
//! The configured family's four styles are resolved as in v1: an absent style uses the primary
//! regular face with a *synthetic* style (FreeType emboldening and a 12-degree shear), so bold and
//! italic text stay distinct even when only the bundled regular face exists. The primary regular
//! face is the sole source of cell metrics.
//!
//! `Manager.resolve` then walks a per-codepoint fallback chain, first hit wins:
//!
//! 1. built-in sprites (`font_sprite.zig`: box drawing, blocks, braille, Powerline separators),
//!    drawn at the cell size so they tile; only while `Request.builtin_symbols` is on, so a user's
//!    own Nerd Font can draw them instead;
//! 2. the primary family's face for the requested style, then its regular face;
//! 3. the configured `Request.fallbacks` families, in order;
//! 4. every installed system face whose recorded coverage holds the codepoint, monospaced regular
//!    faces first and colour faces last (first for emoji presentation); private-use codepoints try
//!    the bundled symbols face before this step because their meaning is font-specific and the
//!    Nerd Fonts assignment is the one terminals mean;
//! 5. the bundled Symbols Nerd Font Mono face;
//! 6. the bundled JetBrains Mono regular face, when the primary is something else.
//!
//! Every face beyond the primary styles is a numbered *extra* face, opened lazily and cached, and
//! its glyphs are scaled down and recentred into the cell box (one or two cells wide) when they
//! would not fit, so a fallback never changes the grid. Colour bitmap glyphs (CBDT/sbix, through
//! FreeType's libpng support) go into a separate RGBA atlas and are scaled to the cell box. Face
//! indices carry the synthetic-style and two-cell flags (`face_flag_*`) in their high bits, which
//! is what makes each variant a distinct atlas key.
//!
//! ## Grapheme clustering and widths
//!
//! `shape` shapes the bytes it is given and reports each glyph's byte cluster. It does **not**
//! segment text into grapheme clusters, and it does **not** decide how many terminal cells a
//! codepoint spans: both belong to the terminal engine, which is where `ghostty-vt`'s
//! `unicode.codepointWidth` and `unicode.graphemeWidth` live. Neither is imported here on purpose:
//! the `ghostty-vt` module root does not re-export `unicode`, and its `props_table.zig` needs the
//! generated `unicode_tables` options module that Ghostty's own build produces, so reaching those
//! tables from Conduit is a separate build-level decision belonging to whoever wires `term` to the
//! grid (TASK-11). Callers shape one cell's already-segmented content. Full clustering needs
//! `graphemeWidth`, per-cluster shaping and bidirectional reordering, none of which v1 does.

const std = @import("std");
const builtin = @import("builtin");

/// FreeType and HarfBuzz through one seam module, under the names each library
/// is known by. `hb-ft.h` takes an `FT_Face` and returns a HarfBuzz font built
/// from it, so both libraries have to come from the *same* translation: two
/// seams would give Conduit two unrelated Zig types for the same C struct and
/// handing a face from one to the other would not compile. Since TASK-39 the
/// shaper deliberately does not use `hb-ft` (see `harfBuzzFont`), but the seam
/// stays one translation so the two libraries' headers cannot drift apart.
const seam = @import("font-c");
const ft = seam;
const hb = seam;
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;

/// The log scope for font failures.
pub const log = std.log.scoped(.font);

/// The bundled fallback face, compiled into the binary.
///
/// The app must be able to draw text on a machine with no fonts installed at all, so the fallback
/// is not a path on disk that a packaging step might forget: it is bytes in the executable, loaded
/// through FreeType's memory-face entry point.
///
/// JetBrains Mono 2.304, SIL Open Font License 1.1. The licence text is in
/// `assets/fonts/LICENSE-JetBrainsMono-OFL-1.1.txt`; the provenance and licence of every other
/// font-bearing file in the repository is in `assets/fonts/README.md`.
pub const bundled_face = @import("bundled-face").data;

/// The repository path of the bundled face, as reported in logs and to callers. It is a label, not
/// something the font manager opens: the bytes are `bundled_face`.
pub const bundled_path = "assets/fonts/JetBrainsMono-Regular.ttf";

/// The bundled Nerd Fonts "Symbols Nerd Font Mono" face, compiled into the binary so private-use
/// icons draw without a patched font installed. Nerd Fonts v3.5.1; its licences and provenance are
/// in `assets/fonts/README.md`.
pub const bundled_symbols = @import("bundled-symbols").data;

/// The repository path of the bundled symbols face, as a label.
pub const bundled_symbols_path = "assets/fonts/SymbolsNerdFontMono-Regular.ttf";

/// Procedural box drawing, block elements, braille and Powerline separators.
pub const sprite = @import("font_sprite.zig");

/// The face index of built-in sprite glyphs. Their glyph index is the codepoint itself.
pub const sprite_face: u32 = face_style_count;

/// Extra (fallback) faces are numbered from here, in the order they were opened.
const extra_base: u32 = sprite_face + 1;

/// Render the glyph with FreeType emboldening: the style asked for bold and its face is not bold.
pub const face_flag_bold: u32 = 1 << 31;
/// Render the glyph sheared: the style asked for italic and its face is upright.
pub const face_flag_oblique: u32 = 1 << 30;
/// The glyph occupies two cells, which widens the box a fallback glyph is fitted into.
pub const face_flag_wide: u32 = 1 << 29;
/// The face number without its flags.
pub const face_id_mask: u32 = face_flag_wide - 1;

/// The face index a renderer passes for a glyph drawn in a two-cell (wide) cell.
pub fn wideFace(face_index: u32) u32 {
    return face_index | face_flag_wide;
}

/// The file name extensions discovery accepts. Everything else in a font directory — bitmaps,
/// metadata, `dir` caches — is skipped without being opened.
const font_extensions: []const []const u8 = &.{ ".ttf", ".otf", ".ttc", ".otc" };

/// A font size in points, with the display scale it is being rendered at.
///
/// Conduit stores sizes in points and converts to pixels here, once, so a size in the settings file
/// means the same thing on every display and changing scale does not silently change the chosen
/// size.
pub const Size = struct {
    points: f32,
    scale: f32,

    /// The smallest size Conduit will render. Below this a cell is smaller than a pixel and the grid
    /// rounds every glyph away.
    pub const min_points: f32 = 1.0;

    pub const Error = error{SizeOutOfRange};

    /// Build a size, rejecting a value that is zero, negative, NaN, infinite, or below `min_points`.
    ///
    /// Rejecting rather than clamping: a settings file that says `font.size = 0` is broken, and a
    /// broken file must say so in the log rather than draw a blank terminal.
    pub fn init(points: f32, scale: f32) Error!Size {
        if (!std.math.isFinite(points) or points < min_points) return error.SizeOutOfRange;
        if (!std.math.isFinite(scale) or scale <= 0) return error.SizeOutOfRange;
        return .{ .points = points, .scale = scale };
    }

    /// The size in device pixels: what the rasteriser and the grid layout actually use.
    pub fn pixels(self: Size) u32 {
        const raw = @as(f64, self.points) * @as(f64, self.scale);
        const rounded: u32 = @intFromFloat(@round(raw));
        return @max(rounded, @as(u32, 1));
    }

    /// The same size at a different display scale, for a window moved to another monitor.
    pub fn atScale(self: Size, scale: f32) Error!Size {
        return init(self.points, scale);
    }
};

/// The pixel size of one character cell: the advance width and the line height.
///
/// Invariant: both dimensions are at least one pixel. Every grid calculation divides by the cell
/// size, so a zero in either one is how a renderer ends up dividing by zero rather than how a font
/// gets rejected.
pub const CellSize = struct {
    width_px: u32,
    height_px: u32,

    /// Build a cell size, clamping both dimensions up to one pixel.
    pub fn init(width_px: u32, height_px: u32) CellSize {
        return .{ .width_px = @max(width_px, 1), .height_px = @max(height_px, 1) };
    }

    /// The number of whole cells that fit in a surface, per axis.
    ///
    /// A surface smaller than one cell holds zero cells rather than a fraction of one: the grid is
    /// integral, and a fractional last cell would leave the renderer drawing off the surface.
    pub fn cellsPer(self: CellSize, width_px: u32, height_px: u32) struct { columns: u32, rows: u32 } {
        return .{
            .columns = width_px / self.width_px,
            .rows = height_px / self.height_px,
        };
    }
};

/// The metrics of the face Conduit draws with, in device pixels at the resolved size.
///
/// The grid is computed from these and nothing else: cell `n` is `width_px * n` pixels from the
/// left and `height_px * row` from the top, and a glyph is drawn with its top-left at
/// `(cell_x + bearing_x_px, cell_y + baseline_px - bearing_y_px)`. A glyph that overhangs its cell —
/// an accent, an italic — spills into the neighbouring cells without any of that reaching the grid
/// maths, which is why the renderer never needs to know a glyph's size to place it.
pub const Metrics = struct {
    cell: CellSize,
    /// Distance from the top of the cell to the baseline.
    baseline_px: u32,
    /// Distance from the baseline up to the top of the face's ascent.
    ascent_px: u32,
    /// Distance from the baseline down to the bottom of the face's descent.
    descent_px: u32,
};

/// The FreeType library, shared by every face a `Manager` opens and by discovery.
///
/// One library per owner rather than one per process: a library handle is a few hundred bytes, and
/// the alternative — a process-global — is exactly the hidden state this project does not have.
const Library = struct {
    handle: ft.FT_Library,

    fn init() !Library {
        var handle: ft.FT_Library = undefined;
        if (ft.FT_Init_FreeType(&handle) != 0) return error.FreeTypeInitFailed;
        return .{ .handle = handle };
    }

    fn deinit(self: *Library) void {
        _ = ft.FT_Done_FreeType(self.handle);
        self.* = undefined;
    }
};

/// One open face at one size. Owns the `FT_Face` it wraps.
const Face = struct {
    handle: ft.FT_Face,
    /// Where the face's bytes are, borrowed: the shaper opens its own view of the same font from
    /// here (see `harfBuzzFont`). A path is owned by the catalog that found it; memory is one of
    /// the bundled faces compiled into the binary.
    origin: Origin,

    const Origin = union(enum) {
        path: [:0]const u8,
        memory: []const u8,
    };

    /// Open a face from a file. Every failure here is a font file that is not the face it claims to
    /// be, which is external input: it is returned, never asserted. `path` must outlive the face.
    fn open(library: ft.FT_Library, path: [:0]const u8, size_px: u32) !Face {
        var handle: ft.FT_Face = undefined;
        if (ft.FT_New_Face(library, path.ptr, 0, &handle) != 0) return error.FontFileUnreadable;
        errdefer _ = ft.FT_Done_Face(handle);
        return sized(handle, .{ .path = path }, size_px);
    }

    /// Open a face from bytes already in memory: how the bundled fallback is loaded, and how a
    /// caller that fetched a font itself would load one. `bytes` must outlive the face.
    fn openMemory(library: ft.FT_Library, bytes: []const u8, size_px: u32) !Face {
        var handle: ft.FT_Face = undefined;
        if (ft.FT_New_Memory_Face(library, bytes.ptr, @intCast(bytes.len), 0, &handle) != 0) {
            return error.FontFileUnreadable;
        }
        errdefer _ = ft.FT_Done_Face(handle);
        return sized(handle, .{ .memory = bytes }, size_px);
    }

    fn sized(handle: ft.FT_Face, origin: Origin, size_px: u32) !Face {
        const flags = handle.*.face_flags;
        if (flags & ft.FT_FACE_FLAG_SCALABLE == 0 and handle.*.num_fixed_sizes > 0) {
            // A bitmap-only face (Noto Color Emoji's CBDT strikes) has a fixed set of sizes and
            // refuses any other. The strike closest to the wanted size is selected and the glyph
            // is scaled to the cell when it is rasterised.
            const strikes = handle.*.available_sizes[0..@intCast(handle.*.num_fixed_sizes)];
            var best: usize = 0;
            for (strikes, 0..) |strike, index| {
                const distance = @abs(@as(i64, strike.height) - @as(i64, size_px));
                const best_distance = @abs(@as(i64, strikes[best].height) - @as(i64, size_px));
                if (distance < best_distance) best = index;
            }
            if (ft.FT_Select_Size(handle, @intCast(best)) != 0) return error.UnsupportedPixelSize;
            return .{ .handle = handle, .origin = origin };
        }
        // Zero width means "same as the height", which is what a monospaced face wants.
        if (ft.FT_Set_Pixel_Sizes(handle, 0, size_px) != 0) return error.UnsupportedPixelSize;
        return .{ .handle = handle, .origin = origin };
    }

    fn isColor(self: Face) bool {
        return self.handle.*.face_flags & ft.FT_FACE_FLAG_COLOR != 0;
    }

    fn deinit(self: *Face) void {
        _ = ft.FT_Done_Face(self.handle);
        self.* = undefined;
    }

    /// The family name from the face's own name table: what discovery matched, and what a caller is
    /// told, whatever name was configured.
    fn familyName(self: Face) []const u8 {
        return std.mem.span(self.handle.*.family_name);
    }

    fn styleName(self: Face) []const u8 {
        return std.mem.span(self.handle.*.style_name);
    }

    fn unitsPerEm(self: Face) u32 {
        return @intCast(self.handle.*.units_per_EM);
    }

    /// The metrics of this face at this size.
    ///
    /// `ascender`, `descender` and `height` are FreeType's scaled design metrics, and FreeType has
    /// already rounded them outwards to whole pixels — the ascender up and the descender down — so
    /// that a rasterised glyph is never clipped by the cell it lands in. Converting them is
    /// therefore exact, and the numbers here are the face's own at this size rather than anything
    /// this module chose.
    ///
    /// The cell height is the font's own line height, but never less than ascent + descent: a font
    /// whose declared line height is tighter than its own glyphs still gets a cell that holds them.
    fn metrics(self: Face) Metrics {
        const scaled = self.handle.*.size.*.metrics;
        const ascent_px = round26_6(scaled.ascender);
        const descent_px = round26_6(-scaled.descender);
        const height_px = @max(round26_6(scaled.height), ascent_px + descent_px);
        return .{
            .cell = CellSize.init(self.cellAdvance(), height_px),
            .baseline_px = ascent_px,
            .ascent_px = ascent_px,
            .descent_px = descent_px,
        };
    }

    /// The width of one cell: the widest advance in printable ASCII at this size.
    ///
    /// A terminal grid cannot reflow, so a cell has to be wide enough for every glyph drawn in it or
    /// Latin text overlaps itself. Printable ASCII is the range a cell is sized against; a wide
    /// (East Asian) glyph spans two cells and is deliberately not part of it. The advances are read
    /// unhinted and rounded to the nearest pixel, because a cell that moved by a pixel when a
    /// different face took over would resize the whole grid, and because a glyph's own advance
    /// (truncated to whole pixels when drawn) then lands on exactly the cell width.
    fn cellAdvance(self: Face) u32 {
        var widest: i64 = 0;
        var cp: u32 = ' ';
        while (cp <= '~') : (cp += 1) {
            const index = ft.FT_Get_Char_Index(self.handle, cp);
            if (index == 0) continue;
            if (ft.FT_Load_Glyph(self.handle, index, ft.FT_LOAD_NO_HINTING | ft.FT_LOAD_NO_BITMAP) != 0) {
                continue;
            }
            const advance = self.handle.*.glyph.*.metrics.horiAdvance;
            if (advance > widest) widest = advance;
        }
        return round26_6(widest);
    }
};

/// A 26.6 fixed-point pixel count from FreeType as a whole number of pixels, rounded to nearest and
/// never to zero. The design metrics arrive already rounded outwards to whole pixels, so for those
/// this is an exact conversion; an advance arrives fractional and is rounded, which is what makes a
/// glyph advance land on the cell width the grid was built from.
fn round26_6(value: anytype) u32 {
    const v: i64 = value;
    const magnitude: u64 = @intCast(if (v < 0) -v else v);
    return @intCast(@max((magnitude + 32) / 64, 1));
}

/// A face style Conduit can request from a configured family.
///
/// The integer value is also the stable atlas face slot for a distinct loaded style. Slot zero is
/// always the primary regular resolution; an unavailable style resolves back to that slot.
pub const FaceStyle = enum(u2) {
    regular,
    bold,
    italic,
    bold_italic,
};

const face_style_count = 4;

fn styleIndex(style: FaceStyle) usize {
    return @intFromEnum(style);
}

/// Classify the two independent style bits FreeType read from a face's metadata.
fn classifyStyle(style_flags: ft.FT_Long) FaceStyle {
    const bold = style_flags & @as(ft.FT_Long, ft.FT_STYLE_FLAG_BOLD) != 0;
    const italic = style_flags & @as(ft.FT_Long, ft.FT_STYLE_FLAG_ITALIC) != 0;
    if (bold and italic) return .bold_italic;
    if (bold) return .bold;
    if (italic) return .italic;
    return .regular;
}

/// One discovered font file: a path, and the family and style FreeType reads out of it.
pub const FontFile = struct {
    /// The file's path, owned by the `Catalog` that found it.
    path: [:0]u8,
    /// The family name from the file's name table, owned by the `Catalog`.
    family: []u8,
    /// The style name from the file's name table, owned by the `Catalog`.
    style: []u8,
    /// Style classification from FreeType's `style_flags`, not a guess from the file or style name.
    face_style: FaceStyle,
    /// The codepoints the face maps, as sorted, disjoint, inclusive ranges, owned by the `Catalog`.
    /// Read once at scan time so the fallback chain can ask "who has U+XXXX" without opening a
    /// file on the render thread.
    coverage: []const CodepointRange = &.{},
    /// FreeType says every glyph has the same advance.
    fixed_width: bool = false,
    /// The face carries colour glyphs (CBDT, sbix, COLR).
    color: bool = false,

    /// Whether the face maps `codepoint`.
    pub fn covers(self: FontFile, codepoint: u21) bool {
        return rangesContain(self.coverage, codepoint);
    }
};

/// An inclusive run of codepoints.
pub const CodepointRange = struct {
    first: u21,
    last: u21,
};

fn rangesContain(ranges: []const CodepointRange, codepoint: u21) bool {
    var low: usize = 0;
    var high: usize = ranges.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const range = ranges[mid];
        if (codepoint < range.first) {
            high = mid;
        } else if (codepoint > range.last) {
            low = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

/// Read a face's Unicode character map into sorted inclusive ranges. FreeType walks its cmap in
/// ascending order, so consecutive codepoints extend the last range rather than adding one.
fn readCoverage(gpa: Allocator, handle: ft.FT_Face) ![]CodepointRange {
    var ranges: std.ArrayList(CodepointRange) = .empty;
    errdefer ranges.deinit(gpa);
    var glyph_index: ft.FT_UInt = 0;
    var code = ft.FT_Get_First_Char(handle, &glyph_index);
    while (glyph_index != 0) : (code = ft.FT_Get_Next_Char(handle, code, &glyph_index)) {
        if (code > 0x10FFFF) break;
        const cp: u21 = @intCast(code);
        if (ranges.items.len > 0 and ranges.items[ranges.items.len - 1].last + 1 == cp) {
            ranges.items[ranges.items.len - 1].last = cp;
        } else {
            try ranges.append(gpa, .{ .first = cp, .last = cp });
        }
    }
    return ranges.toOwnedSlice(gpa);
}

/// The best exact-style file found for each face of one family.
pub const FamilyFaces = struct {
    files: [face_style_count]?FontFile = @splat(null),

    pub fn get(self: FamilyFaces, style: FaceStyle) ?FontFile {
        return self.files[styleIndex(style)];
    }
};

/// Every font file found under a set of directories.
///
/// The catalog owns every `path`, `family` and `style` string it reports; `deinit` frees them. A
/// `Manager` keeps its own copy of the one resolved path, so a caller can still name the face after
/// the catalog is gone.
pub const Catalog = struct {
    gpa: Allocator,
    files: std.ArrayList(FontFile) = .empty,

    /// Walk every directory in `directories` and record each font file it contains.
    ///
    /// A directory that does not exist, cannot be read, or is not a directory is skipped with a
    /// debug log: a machine with no `/usr/share/fonts` is a normal machine, not an error. A file
    /// FreeType refuses is skipped for the same reason — one corrupt download in a font directory
    /// must not cost every other font. Only running out of memory is returned.
    ///
    /// `directories` is not owned. Ownership of every returned string is the catalog's.
    pub fn scan(io: Io, gpa: Allocator, directories: []const []const u8) !Catalog {
        var self: Catalog = .{ .gpa = gpa };
        errdefer self.deinit();

        // One library for the whole scan: discovery opens hundreds of faces, and re-initialising
        // FreeType per file would be the slowest thing this function could do.
        var library = try Library.init();
        defer library.deinit();

        for (directories) |directory| {
            var dir = Dir.openDirAbsolute(io, directory, .{ .iterate = true }) catch |err| {
                log.debug("font directory {s} not searched: {s}", .{ directory, @errorName(err) });
                continue;
            };
            defer dir.close(io);

            var walker = dir.walk(gpa) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
            defer walker.deinit();

            while (walker.next(io) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // One unreadable entry — a broken symlink, a file that vanished mid-walk — must not
                // end the scan of the rest of the tree.
                else => {
                    log.debug("font walk of {s} skipped an entry: {s}", .{ directory, @errorName(err) });
                    continue;
                },
            }) |entry| {
                if (entry.kind != .file) continue;
                if (!hasFontExtension(entry.basename)) continue;
                const path = std.fs.path.joinZ(gpa, &.{ directory, entry.path }) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                };
                defer gpa.free(path);
                self.addFile(library.handle, path) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                };
            }
        }
        return self;
    }

    /// Open one font file and record its family and style.
    fn addFile(self: *Catalog, library: ft.FT_Library, path: [:0]const u8) !void {
        var handle: ft.FT_Face = undefined;
        if (ft.FT_New_Face(library, path.ptr, 0, &handle) != 0) {
            log.debug("not a font file Conduit can read: {s}", .{path});
            return error.FontFileUnreadable;
        }
        defer _ = ft.FT_Done_Face(handle);

        const family = std.mem.span(handle.*.family_name);
        if (family.len == 0) {
            log.debug("font file has no family name: {s}", .{path});
            return error.FontFileUnreadable;
        }

        const owned_path = try self.gpa.dupeZ(u8, path);
        errdefer self.gpa.free(owned_path);
        const owned_family = try self.gpa.dupe(u8, family);
        errdefer self.gpa.free(owned_family);
        const owned_style = try self.gpa.dupe(u8, std.mem.span(handle.*.style_name));
        errdefer self.gpa.free(owned_style);
        const coverage = try readCoverage(self.gpa, handle);
        errdefer self.gpa.free(coverage);
        const flags = handle.*.face_flags;
        try self.files.append(self.gpa, .{
            .path = owned_path,
            .family = owned_family,
            .style = owned_style,
            .face_style = classifyStyle(handle.*.style_flags),
            .coverage = coverage,
            .fixed_width = flags & ft.FT_FACE_FLAG_FIXED_WIDTH != 0,
            .color = flags & ft.FT_FACE_FLAG_COLOR != 0,
        });
    }

    /// The file to use for a configured family: an exact, case-insensitive match on family name.
    ///
    /// When several files carry the family, the regular face wins. If the family has no regular
    /// face, the lexicographically first path wins, preserving the old ability to resolve a family
    /// that only exposes a styled face without depending on directory iteration order. Case is
    /// ignored because a configured family is typed by a human.
    pub fn findFamily(self: Catalog, family: []const u8) ?FontFile {
        const styles = self.findFamilyFaces(family);
        if (styles.get(.regular)) |regular| return regular;

        var other: ?FontFile = null;
        for (self.files.items) |file| {
            if (!std.ascii.eqlIgnoreCase(file.family, family)) continue;
            if (other == null or pathPrecedes(file, other.?)) other = file;
        }
        return other;
    }

    /// Resolve each exact style of a family deterministically.
    ///
    /// A family can contain several weights that FreeType classifies with the same flags. The
    /// canonical style name wins within each flag class (`Regular`, `Bold`, `Italic` or
    /// `Bold Italic`); the lexicographically first path breaks every remaining tie so filesystem
    /// walk order cannot change the chosen face between launches.
    pub fn findFamilyFaces(self: Catalog, family: []const u8) FamilyFaces {
        var found: FamilyFaces = .{};
        for (self.files.items) |file| {
            if (!std.ascii.eqlIgnoreCase(file.family, family)) continue;
            const index = styleIndex(file.face_style);
            if (found.files[index] == null or styleCandidatePrecedes(
                file.face_style,
                file,
                found.files[index].?,
            )) {
                found.files[index] = file;
            }
        }
        return found;
    }

    /// The families a person can pick as a terminal font: every family with a non-colour file
    /// that FreeType reports as fixed-width and that maps `M` and `0`, so a symbols or emoji face
    /// that happens to be monospaced is not offered as a text font.
    ///
    /// Sorted case-insensitively (bytes break ties) with case-insensitive duplicates removed, and
    /// bounded to `limit` names. The strings are borrowed from the catalog; the caller frees only
    /// the returned slice, with `gpa`.
    pub fn monospaceFamilies(self: Catalog, gpa: Allocator, limit: usize) Allocator.Error![][]const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        for (self.files.items) |file| {
            if (!file.fixed_width or file.color) continue;
            if (!file.covers('M') or !file.covers('0')) continue;
            try names.append(gpa, file.family);
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return switch (std.ascii.orderIgnoreCase(a, b)) {
                    .lt => true,
                    .gt => false,
                    .eq => std.mem.order(u8, a, b) == .lt,
                };
            }
        }.lessThan);
        var unique: std.ArrayList([]const u8) = .empty;
        errdefer unique.deinit(gpa);
        for (names.items) |name| {
            if (unique.items.len == limit) break;
            if (unique.items.len != 0 and std.ascii.eqlIgnoreCase(unique.items[unique.items.len - 1], name)) continue;
            try unique.append(gpa, name);
        }
        return unique.toOwnedSlice(gpa);
    }

    pub fn deinit(self: *Catalog) void {
        for (self.files.items) |file| {
            self.gpa.free(file.path);
            self.gpa.free(file.family);
            self.gpa.free(file.style);
            self.gpa.free(file.coverage);
        }
        self.files.deinit(self.gpa);
        self.* = undefined;
    }
};

fn hasFontExtension(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const extension = name[dot..];
    for (font_extensions) |candidate| {
        if (std.ascii.eqlIgnoreCase(extension, candidate)) return true;
    }
    return false;
}

fn pathPrecedes(candidate: FontFile, current: FontFile) bool {
    return std.mem.order(u8, candidate.path, current.path) == .lt;
}

fn styleCandidatePrecedes(style: FaceStyle, candidate: FontFile, current: FontFile) bool {
    const canonical = canonicalStyleName(style);
    const candidate_is_canonical = std.ascii.eqlIgnoreCase(candidate.style, canonical);
    const current_is_canonical = std.ascii.eqlIgnoreCase(current.style, canonical);
    if (candidate_is_canonical != current_is_canonical) return candidate_is_canonical;
    return pathPrecedes(candidate, current);
}

fn canonicalStyleName(style: FaceStyle) []const u8 {
    return switch (style) {
        .regular => "Regular",
        .bold => "Bold",
        .italic => "Italic",
        .bold_italic => "Bold Italic",
    };
}

/// The directories system fonts are searched in, most specific first. The caller owns the result
/// and frees it with the allocator it passed.
///
/// `home_dir` is the user's home directory, or `null` when the caller has no environment to read it
/// from. It is a parameter rather than an environment lookup because `std.process` in Zig 0.16
/// hands the environment out through the process init rather than through a global: the font
/// manager asks for what it needs instead of reaching behind the caller.
///
/// Linux and macOS search the same shapes of directory, because on both the system, distribution
/// and per-user font directories have the same names and the same tree layout. Windows is the odd
/// one out — its per-user fonts live under `%LOCALAPPDATA%` rather than in the home directory, and
/// a registered font may exist in no directory at all — so TASK-49 replaces this list with GDI or
/// DirectWrite enumeration rather than extending it.
pub fn systemFontDirectories(gpa: Allocator, home_dir: ?[]const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |owned| gpa.free(owned);
        list.deinit(gpa);
    }

    const roots: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{"C:\\Windows\\Fonts"},
        .macos => &.{
            "/System/Library/Fonts",
            "/System/Library/Fonts/Supplemental",
            "/Library/Fonts",
        },
        else => &.{
            "/usr/local/share/fonts",
            "/usr/share/fonts",
        },
    };
    for (roots) |root| try list.append(gpa, try gpa.dupe(u8, root));

    if (home_dir) |home| {
        const suffixes: []const []const u8 = switch (builtin.os.tag) {
            .macos => &.{"Library/Fonts"},
            else => &.{ ".local/share/fonts", ".fonts" },
        };
        for (suffixes) |suffix| {
            try list.append(gpa, try std.fmt.allocPrint(gpa, "{s}/{s}", .{ home, suffix }));
        }
    }
    return list.toOwnedSlice(gpa);
}

/// Identifies a rasterised glyph: the glyph, in the face it came from.
pub const Key = struct {
    glyph_index: u32,
    /// Which distinct loaded face it came from. Missing styles use slot zero, the primary face.
    face_index: u32 = 0,
};

/// A rectangle in the atlas, in pixels from its top-left corner.
pub const Rect = struct {
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,

    pub fn isEmpty(self: Rect) bool {
        return self.width == 0 or self.height == 0;
    }
};

/// A coverage mask to copy into the atlas: `height_px` rows of `pitch` bytes, of which the first
/// `width_px` bytes of each row are the glyph's pixels.
pub const Bitmap = struct {
    data: []const u8,
    width_px: u32,
    height_px: u32,
    pitch: u32,
};

/// A rasterised glyph, placed in the atlas.
///
/// Entries are copied by value and are only good while the atlas still holds the glyph, because
/// eviction can take those pixels back at any time. `Atlas.isLive` is how a caller checks before
/// drawing, and the answer when it fails is "ask for the glyph again" — which is why a renderer
/// asks for the glyphs of the cells it is about to draw rather than holding entries across frames.
pub const Entry = struct {
    key: Key,
    /// Where the coverage mask lives in the atlas.
    rect: Rect,
    /// Offset from the pen position to the left edge of the bitmap.
    bearing_x_px: i32,
    /// Offset from the baseline to the top edge of the bitmap, downwards positive.
    bearing_y_px: i32,
    /// How far the pen moves after this glyph.
    advance_px: u32,
    /// The atlas slot this entry reads from, which is what `isLive` checks.
    slot: u32,
    /// Whether the entry lives in the RGBA colour atlas rather than the coverage atlas.
    color: bool = false,
};

const Slot = struct {
    key: Key,
    rect: Rect,
    bearing_x_px: i32,
    bearing_y_px: i32,
    advance_px: u32,
    last_used: u64,
    live: bool,
};

/// What the cache did, so a test can prove a hit happened rather than infer it from a pixel that
/// would have been produced anyway.
pub const Stats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    insertions: u64 = 0,
    evictions: u64 = 0,
};

/// The glyph cache: one coverage-mask texture that rasterised glyphs are packed into.
///
/// The atlas owns its `pixels` and its slot table; `deinit` frees them. Free space is a first-fit
/// list of rectangles that are not coalesced when freed: merging neighbours on every free costs
/// more than the occasional strip it recovers, and when the atlas really is full, `insert` evicts
/// rather than fails.
pub const Atlas = struct {
    gpa: Allocator,
    width_px: u32,
    height_px: u32,
    /// `depth` bytes per pixel, row-major, `width_px * height_px * depth` long: one byte of
    /// coverage for the glyph atlas, four bytes of premultiplied RGBA for the colour atlas.
    pixels: []u8,
    /// Bytes per pixel: 1 for coverage, 4 for colour.
    depth: u32 = 1,
    /// Every entry ever inserted, live or not. A dead slot is reused rather than removed so an
    /// `Entry` handed to a caller keeps addressing the same slot until that slot is reused.
    slots: std.ArrayList(Slot) = .empty,
    free: std.ArrayList(Rect) = .empty,
    live_count: u32 = 0,
    clock: u64 = 0,
    stats: Stats = .{},

    pub const Error = error{ AtlasSizeOutOfRange, BitmapSizeMismatch, AtlasFull, OutOfMemory };

    /// Allocate a zeroed `width_px` by `height_px` atlas.
    ///
    /// Both dimensions must be at least one pixel and the product must fit a `usize`: a zero-size
    /// atlas would hand out entries no renderer could sample, and one whose byte count overflowed
    /// would allocate the wrong number of bytes.
    pub fn init(gpa: Allocator, width_px: u32, height_px: u32) Error!Atlas {
        return initDepth(gpa, width_px, height_px, 1);
    }

    /// Allocate a zeroed atlas of `depth` bytes per pixel, under the same rules as `init`.
    pub fn initDepth(gpa: Allocator, width_px: u32, height_px: u32, depth: u32) Error!Atlas {
        if (width_px == 0 or height_px == 0 or depth == 0) return error.AtlasSizeOutOfRange;
        const area = std.math.mul(usize, width_px, height_px) catch return error.AtlasSizeOutOfRange;
        const count = std.math.mul(usize, area, depth) catch return error.AtlasSizeOutOfRange;
        const pixels = try gpa.alloc(u8, count);
        @memset(pixels, 0);

        var self: Atlas = .{
            .gpa = gpa,
            .width_px = width_px,
            .height_px = height_px,
            .pixels = pixels,
            .depth = depth,
        };
        errdefer self.deinit();

        // The whole atlas starts as one free rectangle. Without this the first `insert` would have
        // nowhere to put a glyph and would evict a glyph that does not exist yet.
        try self.free.append(gpa, .{ .width = width_px, .height = height_px });
        return self;
    }

    pub fn deinit(self: *Atlas) void {
        self.slots.deinit(self.gpa);
        self.free.deinit(self.gpa);
        self.gpa.free(self.pixels);
        self.* = undefined;
    }

    /// One row of a live entry's coverage mask, `rect.width` bytes, in atlas coordinates.
    ///
    /// Empty for an entry the atlas no longer holds, for a glyph with no ink, and for a row past
    /// the bottom of the rectangle.
    pub fn row(self: Atlas, entry: Entry, index: u32) []const u8 {
        if (!self.isLive(entry)) return &.{};
        if (index >= entry.rect.height) return &.{};
        const start = ((@as(usize, entry.rect.y + index) * self.width_px) + entry.rect.x) * self.depth;
        return self.pixels[start..][0 .. @as(usize, entry.rect.width) * self.depth];
    }

    /// Copy a live entry's coverage mask into `dest`, row by row and without the gaps between the
    /// atlas rows, and return how many bytes were written — zero for an entry the atlas no longer
    /// holds, for a glyph with no ink, or when `dest` is too small.
    ///
    /// This rather than a slice of `pixels`, because a glyph's rows are `width_px` apart in the
    /// atlas: reading `width * height` bytes from its top-left corner would return the atlas rows
    /// it happens to span, which for a glyph narrower than the atlas is the wrong pixels entirely.
    pub fn copyInto(self: Atlas, entry: Entry, dest: []u8) usize {
        if (!self.isLive(entry) or entry.rect.isEmpty()) return 0;
        const row_len = @as(usize, entry.rect.width) * self.depth;
        const count = row_len * entry.rect.height;
        if (dest.len < count) return 0;
        for (0..entry.rect.height) |index| {
            const from = ((@as(usize, entry.rect.y + index) * self.width_px) + entry.rect.x) * self.depth;
            @memcpy(dest[@as(usize, index) * row_len ..][0..row_len], self.pixels[from..][0..row_len]);
        }
        return count;
    }

    /// Whether this entry still addresses the glyph it was created for.
    pub fn isLive(self: Atlas, entry: Entry) bool {
        if (entry.slot >= self.slots.items.len) return false;
        const slot = self.slots.items[entry.slot];
        if (!slot.live) return false;
        return slot.key.glyph_index == entry.key.glyph_index and
            slot.key.face_index == entry.key.face_index;
    }

    /// The cached entry for a key, counted as a hit or a miss.
    pub fn find(self: *Atlas, key: Key) ?Entry {
        for (self.slots.items, 0..) |slot, index| {
            if (!slot.live) continue;
            if (slot.key.glyph_index != key.glyph_index) continue;
            if (slot.key.face_index != key.face_index) continue;
            self.stats.hits += 1;
            self.slots.items[index].last_used = self.tick();
            return entryFrom(self.slots.items[index], index);
        }
        self.stats.misses += 1;
        return null;
    }

    /// Mark an entry as used now, so it is the last thing eviction reaches for.
    pub fn touch(self: *Atlas, entry: Entry) void {
        if (!self.isLive(entry)) return;
        self.slots.items[entry.slot].last_used = self.tick();
    }

    /// Copy a bitmap into the atlas, evicting the glyph used longest ago until it fits.
    ///
    /// A glyph with no ink — a space — is cached with an empty rectangle and costs no atlas space:
    /// it is worth caching because the renderer asks for it on every space of every line, and it
    /// costs nothing to answer.
    pub fn insert(self: *Atlas, key: Key, bitmap: Bitmap, bearing_x_px: i32, bearing_y_px: i32, advance_px: u32) Error!Entry {
        if (bitmap.pitch < @as(u64, bitmap.width_px) * self.depth) return error.BitmapSizeMismatch;
        if (bitmap.data.len != 0 and bitmap.data.len < @as(usize, bitmap.pitch) * bitmap.height_px) {
            return error.BitmapSizeMismatch;
        }

        const rect: Rect = if (bitmap.width_px == 0 or bitmap.height_px == 0)
            Rect{}
        else blk: {
            while (true) {
                if (self.allocate(bitmap.width_px, bitmap.height_px)) |found| break :blk found;
                // No free rectangle fits. Evict the glyph that was used longest ago and try again:
                // an atlas that refuses a glyph the renderer is about to draw is a blank cell,
                // where an evicted glyph is one the renderer will ask for again.
                if (!self.evictLeastRecentlyUsed()) return error.AtlasFull;
            }
        };

        if (!rect.isEmpty()) self.blit(rect, bitmap);

        const slot_index = try self.slotFor(key);
        self.slots.items[slot_index] = .{
            .key = key,
            .rect = rect,
            .bearing_x_px = bearing_x_px,
            .bearing_y_px = bearing_y_px,
            .advance_px = advance_px,
            .last_used = self.tick(),
            .live = true,
        };
        self.live_count += 1;
        self.stats.insertions += 1;
        return entryFrom(self.slots.items[slot_index], slot_index);
    }

    /// Drop the least recently used glyph and hand its rectangle back to the free list. Returns
    /// whether anything was evicted.
    pub fn evictLeastRecentlyUsed(self: *Atlas) bool {
        var oldest: ?usize = null;
        for (self.slots.items, 0..) |slot, index| {
            if (!slot.live) continue;
            if (oldest == null or slot.last_used < self.slots.items[oldest.?].last_used) {
                oldest = index;
            }
        }
        const index = oldest orelse return false;
        const rect = self.slots.items[index].rect;

        if (!rect.isEmpty()) {
            self.free.append(self.gpa, rect) catch {
                // Without a free rectangle the eviction would leak the space forever, so the
                // glyph is kept and the atlas reports itself full.
                log.warn("glyph atlas is out of memory freeing a rectangle; eviction skipped", .{});
                return false;
            };
            // The rectangle goes back with its pixels already cleared, so a rectangle that ends up
            // under a partially drawn glyph shows no coverage rather than a ghost of the last one.
            self.clear(rect);
        }
        self.slots.items[index].live = false;
        self.live_count -= 1;
        self.stats.evictions += 1;
        return true;
    }

    fn tick(self: *Atlas) u64 {
        self.clock += 1;
        return self.clock;
    }

    fn slotFor(self: *Atlas, key: Key) !usize {
        for (self.slots.items, 0..) |slot, index| {
            if (!slot.live and slot.key.glyph_index == key.glyph_index and
                slot.key.face_index == key.face_index)
            {
                return index;
            }
        }
        try self.slots.append(self.gpa, .{
            .key = key,
            .rect = .{},
            .bearing_x_px = 0,
            .bearing_y_px = 0,
            .advance_px = 0,
            .last_used = 0,
            .live = false,
        });
        return self.slots.items.len - 1;
    }

    fn entryFrom(slot: Slot, index: usize) Entry {
        return .{
            .key = slot.key,
            .rect = slot.rect,
            .bearing_x_px = slot.bearing_x_px,
            .bearing_y_px = slot.bearing_y_px,
            .advance_px = slot.advance_px,
            .slot = @intCast(index),
        };
    }

    /// First fit over the free list, splitting what is left of the rectangle it used into the strip
    /// to its right and the strip below it.
    fn allocate(self: *Atlas, width_px: u32, height_px: u32) ?Rect {
        for (self.free.items, 0..) |rect, index| {
            if (rect.width < width_px or rect.height < height_px) continue;
            const taken = Rect{ .x = rect.x, .y = rect.y, .width = width_px, .height = height_px };
            const right = Rect{
                .x = rect.x + width_px,
                .y = rect.y,
                .width = rect.width - width_px,
                .height = rect.height,
            };
            // The strip below is only as wide as the rectangle that was taken, so the two remainders
            // are disjoint. A full-width strip below would overlap the strip to the right in the
            // bottom corner, and two glyphs handed the same overlapping space is exactly how an
            // atlas corrupts its own contents.
            const below = Rect{
                .x = rect.x,
                .y = rect.y + height_px,
                .width = width_px,
                .height = rect.height - height_px,
            };

            // The remainder replaces the entry in place and the extra strip is inserted after it,
            // rather than rebuilding the list: an index shift mid-iteration would hand the same
            // space out twice.
            const kept: Rect = if (!right.isEmpty()) right else below;
            if (kept.isEmpty()) {
                _ = self.free.orderedRemove(index);
            } else {
                self.free.items[index] = kept;
                if (!right.isEmpty() and !below.isEmpty()) {
                    self.free.insert(self.gpa, index + 1, below) catch return null;
                }
            }
            return taken;
        }
        return null;
    }

    fn blit(self: *Atlas, rect: Rect, bitmap: Bitmap) void {
        const row_len = @as(usize, rect.width) * self.depth;
        for (0..rect.height) |line| {
            const from = @as(usize, line) * bitmap.pitch;
            const to = ((@as(usize, rect.y + line) * self.width_px) + rect.x) * self.depth;
            @memcpy(self.pixels[to..][0..row_len], bitmap.data[from..][0..row_len]);
        }
    }

    fn clear(self: *Atlas, rect: Rect) void {
        const row_len = @as(usize, rect.width) * self.depth;
        for (0..rect.height) |line| {
            const to = ((@as(usize, rect.y + line) * self.width_px) + rect.x) * self.depth;
            @memset(self.pixels[to..][0..row_len], 0);
        }
    }
};

/// One glyph of a shaped run.
pub const ShapedGlyph = struct {
    glyph_index: u32,
    /// The distinct loaded face that produced this glyph. Use it when rasterising: different faces
    /// routinely assign the same numeric glyph index to different outlines.
    face_index: u32,
    /// Byte offset into the shaped text where this glyph's cluster starts. A cluster is what the
    /// caller passed in: v1 does not re-segment the text (see the module comment).
    cluster: u32,
    /// How far the pen moves after this glyph, in pixels, in the run's direction.
    x_advance_px: f32,
    y_advance_px: f32,
    /// Offset from the glyph origin to where the glyph is drawn, in pixels.
    x_offset_px: f32,
    y_offset_px: f32,
};

/// What to load, and how big an atlas to give it.
///
/// Every field added after v1 has a default, so a caller that only names a family and a size gets
/// the full v2 chain: built-in sprites, ligatures, the system fallback and the bundled symbols face.
pub const Request = struct {
    /// The configured family. Empty means the bundled face, which is also what a family that is not
    /// installed gets.
    family: []const u8 = "",
    /// Families whose bold, italic and bold-italic faces replace the ones derived from `family`.
    /// Empty derives the style from the primary family (its own style file, else synthesis). The
    /// family's exact style face is used when it has one, otherwise its regular face. A family that
    /// is not installed keeps the derived face and is logged. Borrowed only for `Manager.init`.
    bold_family: []const u8 = "",
    italic_family: []const u8 = "",
    bold_italic_family: []const u8 = "",
    size: Size,
    /// The user's home directory, when the caller knows it. See `systemFontDirectories`.
    home_dir: ?[]const u8 = null,
    atlas_width_px: u32 = 1024,
    atlas_height_px: u32 = 1024,
    /// Families consulted, in order, for a codepoint the configured family lacks, before any system
    /// face. Borrowed only for the duration of `Manager.init`. A family that is not installed is
    /// skipped with a log line rather than failing the load.
    fallbacks: []const []const u8 = &.{},
    /// Whether HarfBuzz may form ligatures. Off disables `liga`, `calt` and `dlig`. See
    /// `Manager.setLigatures` for the runtime toggle.
    ligatures: bool = true,
    /// Whether box drawing, block elements, braille and the Powerline separators are drawn by
    /// `font_sprite` at the cell size rather than taken from a font. Turning it off lets a user's
    /// own Nerd Font draw them.
    builtin_symbols: bool = true,
    /// Whether installed system faces are searched for codepoints the configured faces lack.
    system_fallback: bool = true,
    /// The RGBA atlas colour glyphs are packed into.
    color_atlas_width_px: u32 = 512,
    color_atlas_height_px: u32 = 512,

    pub const Error = error{AtlasSizeOutOfRange};
};

/// A glyph resolved for a codepoint: the face (with its `face_flag_*` bits) and the glyph in it.
pub const GlyphRef = struct {
    face_index: u32,
    glyph_index: u32,
};

/// How a codepoint asked to be presented. An emoji variation selector (U+FE0F) asks for colour
/// faces first; a text selector (U+FE0E) keeps them last.
pub const Presentation = enum(u2) { default, text, emoji };

/// Where an extra face came from.
const ExtraKind = enum { configured, system, symbols, bundled };

/// A face beyond the primary styles: a fallback family, a system face, or a bundled face. Owns its
/// FreeType face and the HarfBuzz font that reads it.
const Extra = struct {
    kind: ExtraKind,
    face: Face,
    font: *hb.hb_font_t,
    color: bool,
    /// The catalog file a system face was opened from.
    catalog_index: ?u32 = null,
};

/// The face index stored in the resolution cache for "no face has this codepoint".
const no_face: u32 = face_id_mask;

/// The resolution cache is cleared rather than grown past this many codepoints, so a program that
/// prints every codepoint in Unicode cannot make the render thread hold memory in proportion.
const max_resolved = 65536;

/// The shear FreeType's own `FT_GlyphSlot_Oblique` applies: about 12 degrees, in 16.16.
const oblique_shear: ft.FT_Fixed = 0x0366A;

/// HarfBuzz's tag for an OpenType feature name.
fn featureTag(comptime name: *const [4]u8) u32 {
    return (@as(u32, name[0]) << 24) | (@as(u32, name[1]) << 16) | (@as(u32, name[2]) << 8) | name[3];
}

/// The features that turn every kind of ligature off, applied to the whole buffer.
const ligatures_off = [_]hb.hb_feature_t{
    .{ .tag = featureTag("liga"), .value = 0, .start = 0, .end = std.math.maxInt(c_uint) },
    .{ .tag = featureTag("calt"), .value = 0, .start = 0, .end = std.math.maxInt(c_uint) },
    .{ .tag = featureTag("dlig"), .value = 0, .start = 0, .end = std.math.maxInt(c_uint) },
};

/// Codepoints whose default presentation is emoji, approximately: the pictographic planes. Text
/// default symbols such as U+2764 only prefer colour when followed by U+FE0F.
fn defaultEmoji(codepoint: u21) bool {
    return switch (codepoint) {
        0x1F000...0x1F0FF, 0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1FAFF => true,
        else => false,
    };
}

/// The private use areas, whose glyphs mean whatever a font says they mean.
fn privateUse(codepoint: u21) bool {
    return switch (codepoint) {
        0xE000...0xF8FF, 0xF0000...0x10FFFF => true,
        else => false,
    };
}

/// The synthetic flags a regular face needs to stand in for `style`.
fn syntheticFlags(style: FaceStyle) u32 {
    return switch (style) {
        .regular => 0,
        .bold => face_flag_bold,
        .italic => face_flag_oblique,
        .bold_italic => face_flag_bold | face_flag_oblique,
    };
}

/// The font manager: up to four distinct style faces and shapers, the extra faces of the fallback
/// chain, one shared buffer, a coverage atlas and a colour atlas.
///
/// A `Manager` owns everything it reports. `deinit` must run before the allocator that built it goes
/// away; every other module holds it behind a pointer rather than by value.
///
/// Threads: built on a loader thread, then used only by the render thread. Resolving a codepoint no
/// loaded face covers may open one system font file (once per file, never per frame); the file's
/// coverage was already read on the loader thread, so the search itself does no IO.
pub const Manager = struct {
    gpa: Allocator,
    library: Library,
    /// Slot zero is always the primary face. Other slots exist only for distinct style files;
    /// absent styles resolve to slot zero and therefore cannot double-own a face handle.
    faces: [face_style_count]?Face,
    /// HarfBuzz fonts parallel `faces`, each destroyed before the FreeType face it reads from.
    fonts: [face_style_count]?*hb.hb_font_t,
    /// Reused across every style's shape calls so shaping a frame's text allocates nothing.
    buffer: *hb.hb_buffer_t,
    atlas: Atlas,
    /// Premultiplied RGBA colour glyphs: emoji and other bitmap colour faces.
    color_atlas: Atlas,
    face_metrics: Metrics,
    /// The resolved size in device pixels: what HarfBuzz's font units are scaled by.
    size_px: u32,
    /// The family actually loaded, from the face's own name table. Owned.
    family: []u8,
    /// Where it came from: a system path, or the bundled asset's path. Owned.
    source_path: []u8,
    /// Whether the configured family was missing and the bundled face is standing in for it.
    used_fallback: bool,
    /// Faces numbered from `extra_base`, in the order they were opened.
    extras: std.ArrayList(Extra) = .empty,
    /// Every system font file and its coverage, kept for the fallback search.
    catalog: Catalog,
    /// Catalog indices in fallback preference order.
    system_order: []u32 = &.{},
    /// Catalog indices that failed to open, so they are not retried for every codepoint.
    failed_system: std.ArrayList(u32) = .empty,
    /// Codepoint and style to resolved glyph, including misses.
    resolved: std.AutoHashMapUnmanaged(u32, GlyphRef) = .empty,
    /// Rasterisation scratch for sprites and scaled colour glyphs; grows, never shrinks.
    scratch: std.ArrayList(u8) = .empty,
    ligatures_enabled: bool = true,
    builtin_symbols: bool = true,
    system_fallback: bool = true,

    pub const Error = error{
        FreeTypeInitFailed,
        FontFileUnreadable,
        UnsupportedPixelSize,
        GlyphLoadFailed,
        UnsupportedPixelFormat,
        OutOfMemory,
        NoSpaceLeft,
        InvalidFaceIndex,
    } || Request.Error || Atlas.Error;

    /// Resolve a family, open it, and build the atlases for it.
    ///
    /// Resolution never fails for want of a font: a family that is not installed falls back to the
    /// bundled face and logs it, because a terminal full of boxes because a family name was
    /// misspelled is worse than a terminal in the wrong font. Everything else — a face FreeType will
    /// not open, an atlas that will not allocate, running out of memory — is returned to the caller.
    ///
    /// A new `Size` (a font size change, or a window moved to a display of another scale) is a new
    /// `Manager`: every face is re-opened at the new pixel size, both atlases start empty and every
    /// glyph, sprite and emoji is rasterised again at that size rather than scaled from the old one.
    pub fn init(gpa: Allocator, io: Io, request: Request) Error!Manager {
        var manager = try initPrimary(gpa, io, request);
        // From here the manager owns every resource, and `deinit` releases all of it.
        errdefer manager.deinit();
        try manager.openFixedExtras(request);
        return manager;
    }

    /// Everything but the extra faces: the primary resolution, both atlases and the catalog.
    fn initPrimary(gpa: Allocator, io: Io, request: Request) Error!Manager {
        const size_px = request.size.pixels();

        var library = try Library.init();
        errdefer library.deinit();

        const directories = try systemFontDirectories(gpa, request.home_dir);
        defer freeAll(gpa, directories);

        var catalog = try Catalog.scan(io, gpa, directories);
        errdefer catalog.deinit();

        var resolution = try resolveFaces(gpa, library.handle, &catalog, request, size_px);
        errdefer resolution.deinit(gpa);

        var fonts: [face_style_count]?*hb.hb_font_t = @splat(null);
        errdefer {
            for (fonts) |maybe_font| {
                if (maybe_font) |font| hb.hb_font_destroy(font);
            }
        }
        for (resolution.faces, 0..) |maybe_face, index| {
            const face = maybe_face orelse continue;
            fonts[index] = try harfBuzzFont(face, size_px);
        }

        const buffer: *hb.hb_buffer_t = hb.hb_buffer_create() orelse return error.OutOfMemory;
        errdefer hb.hb_buffer_destroy(buffer);

        var atlas = try Atlas.init(gpa, request.atlas_width_px, request.atlas_height_px);
        errdefer atlas.deinit();
        var color_atlas = try Atlas.initDepth(
            gpa,
            request.color_atlas_width_px,
            request.color_atlas_height_px,
            4,
        );
        errdefer color_atlas.deinit();
        const system_order = try systemOrder(gpa, &catalog);
        errdefer gpa.free(system_order);
        const face_metrics = resolution.faces[styleIndex(.regular)].?.metrics();

        return .{
            .gpa = gpa,
            .library = library,
            .faces = resolution.faces,
            .fonts = fonts,
            .buffer = buffer,
            .atlas = atlas,
            .color_atlas = color_atlas,
            .face_metrics = face_metrics,
            .size_px = size_px,
            .family = resolution.family,
            .source_path = resolution.source_path,
            .used_fallback = resolution.used_fallback,
            .catalog = catalog,
            .system_order = system_order,
            .ligatures_enabled = request.ligatures,
            .builtin_symbols = request.builtin_symbols,
            .system_fallback = request.system_fallback,
        };
    }

    /// Release the atlases, shared buffer, every HarfBuzz font and face, the library and all strings.
    pub fn deinit(self: *Manager) void {
        self.atlas.deinit();
        self.color_atlas.deinit();
        hb.hb_buffer_destroy(self.buffer);
        for (&self.fonts) |*maybe_font| {
            if (maybe_font.*) |font| hb.hb_font_destroy(font);
        }
        for (&self.faces) |*maybe_face| {
            if (maybe_face.*) |*face| face.deinit();
        }
        for (self.extras.items) |*extra| {
            hb.hb_font_destroy(extra.font);
            extra.face.deinit();
        }
        self.extras.deinit(self.gpa);
        self.library.deinit();
        self.catalog.deinit();
        self.gpa.free(self.system_order);
        self.failed_system.deinit(self.gpa);
        self.resolved.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        self.gpa.free(self.family);
        self.gpa.free(self.source_path);
        self.* = undefined;
    }

    /// Open the configured fallback families and the bundled faces, which are always in the chain.
    /// Done at load time, on the loader thread, so the render thread never opens these files.
    fn openFixedExtras(self: *Manager, request: Request) Error!void {
        for (request.fallbacks) |family| {
            const file = self.catalog.findFamily(family) orelse {
                log.warn("fallback font family '{s}' is not installed; skipped", .{family});
                continue;
            };
            const face = Face.open(self.library.handle, file.path, self.size_px) catch |err| {
                log.warn("fallback font {s} could not be opened ({s}); skipped", .{ file.path, @errorName(err) });
                continue;
            };
            _ = try self.addExtra(.configured, face, null);
        }
        _ = try self.addExtra(
            .symbols,
            try Face.openMemory(self.library.handle, bundled_symbols, self.size_px),
            null,
        );
        if (!self.used_fallback) {
            _ = try self.addExtra(
                .bundled,
                try Face.openMemory(self.library.handle, bundled_face, self.size_px),
                null,
            );
        }
    }

    /// Take ownership of `face` as the next extra face and return its face index. The face is
    /// released on failure.
    fn addExtra(self: *Manager, kind: ExtraKind, face: Face, catalog_index: ?u32) Error!u32 {
        var owned = face;
        errdefer owned.deinit();
        const font = try harfBuzzFont(owned, self.size_px);
        errdefer hb.hb_font_destroy(font);
        const index: u32 = @intCast(self.extras.items.len);
        if (extra_base + index >= face_id_mask) return error.InvalidFaceIndex;
        try self.extras.append(self.gpa, .{
            .kind = kind,
            .face = owned,
            .font = font,
            .color = owned.isColor(),
            .catalog_index = catalog_index,
        });
        return extra_base + index;
    }

    /// The family actually loaded, which is not the configured one when the fallback was used.
    pub fn familyName(self: Manager) []const u8 {
        return self.family;
    }

    /// Where the loaded face came from: a system path, or the bundled asset's path.
    pub fn sourcePath(self: Manager) []const u8 {
        return self.source_path;
    }

    /// Whether the configured family was missing and the bundled face is standing in for it.
    pub fn isFallback(self: Manager) bool {
        return self.used_fallback;
    }

    /// How many `Request.fallbacks` families were installed and opened.
    pub fn configuredFallbackCount(self: Manager) usize {
        var count: usize = 0;
        for (self.extras.items) |extra| {
            if (extra.kind == .configured) count += 1;
        }
        return count;
    }

    /// Whether box drawing, blocks, braille and Powerline separators are drawn as sprites.
    pub fn builtinSymbols(self: Manager) bool {
        return self.builtin_symbols;
    }

    /// The family a style draws with: the primary family unless a style face, from the family
    /// itself or a `Request` style override, is loaded for it.
    pub fn styleFamilyName(self: Manager, style: FaceStyle) []const u8 {
        const face = self.faces[styleIndex(style)] orelse return self.family;
        return face.familyName();
    }

    /// The cell metrics of the loaded face.
    pub fn metrics(self: Manager) Metrics {
        return self.face_metrics;
    }

    /// Whether shaping forms ligatures.
    pub fn ligatures(self: Manager) bool {
        return self.ligatures_enabled;
    }

    /// Turn ligatures on or off at runtime. Shaping is not cached, so the next shaped run follows
    /// the new setting; the caller must invalidate any grid that already drew text with the old one.
    pub fn setLigatures(self: *Manager, enabled: bool) void {
        self.ligatures_enabled = enabled;
    }

    /// The glyph index for a codepoint in the primary regular face, or 0 when it has none. This is
    /// the primary face only; `resolve` walks the fallback chain.
    pub fn glyphIndex(self: Manager, codepoint: u21) u32 {
        return self.glyphIndexForStyle(.regular, codepoint);
    }

    /// The glyph index for a codepoint in a requested style's primary face, or 0 when it has none.
    pub fn glyphIndexForStyle(self: Manager, style: FaceStyle, codepoint: u21) u32 {
        const face_index = self.faceIndexForStyle(style);
        return ft.FT_Get_Char_Index(self.faces[face_index].?.handle, codepoint);
    }

    /// The coverage atlas, for the renderer to upload as a single-channel texture.
    pub fn atlasPixels(self: Manager) []const u8 {
        return self.atlas.pixels;
    }

    /// The colour atlas, premultiplied RGBA8, for the renderer to upload as a four-channel texture.
    pub fn colorAtlasPixels(self: Manager) []const u8 {
        return self.color_atlas.pixels;
    }

    /// Resolve a codepoint through the fallback chain (see the module comment) with its default
    /// presentation. Null when no face in the chain has it.
    pub fn resolve(self: *Manager, style: FaceStyle, codepoint: u21) ?GlyphRef {
        return self.resolveWith(style, codepoint, .default);
    }

    /// Resolve a codepoint with an explicit presentation.
    pub fn resolveWith(self: *Manager, style: FaceStyle, codepoint: u21, presentation: Presentation) ?GlyphRef {
        if (self.builtin_symbols and sprite.covers(codepoint)) {
            return .{ .face_index = sprite_face, .glyph_index = codepoint };
        }
        const key: u32 = @as(u32, codepoint) |
            (@as(u32, @intFromEnum(style)) << 21) |
            (@as(u32, @intFromEnum(presentation)) << 23);
        if (self.resolved.get(key)) |hit| {
            return if (hit.face_index == no_face) null else hit;
        }
        const found = self.search(style, codepoint, presentation);
        if (self.resolved.count() >= max_resolved) self.resolved.clearRetainingCapacity();
        // The cache only saves repeating the search; failing to grow it costs time, not
        // correctness, so the answer is returned either way.
        self.resolved.put(self.gpa, key, found orelse .{ .face_index = no_face, .glyph_index = 0 }) catch {};
        return found;
    }

    fn search(self: *Manager, style: FaceStyle, codepoint: u21, presentation: Presentation) ?GlyphRef {
        const want_color = presentation == .emoji or (presentation == .default and defaultEmoji(codepoint));
        const synthetic = syntheticFlags(style);

        if (want_color) {
            if (self.searchExtras(.configured, codepoint, synthetic, .color_only)) |hit| return hit;
            if (self.searchSystem(codepoint, synthetic, .color_only)) |hit| return hit;
        }

        const slot = self.faceIndexForStyle(style);
        const in_slot = ft.FT_Get_Char_Index(self.faces[slot].?.handle, codepoint);
        if (in_slot != 0) {
            return .{ .face_index = @as(u32, @intCast(slot)) | (if (slot == 0) synthetic else 0), .glyph_index = in_slot };
        }
        if (slot != 0) {
            const regular = ft.FT_Get_Char_Index(self.faces[0].?.handle, codepoint);
            if (regular != 0) return .{ .face_index = synthetic, .glyph_index = regular };
        }

        if (self.searchExtras(.configured, codepoint, synthetic, .any)) |hit| return hit;
        if (privateUse(codepoint)) {
            if (self.searchExtras(.symbols, codepoint, synthetic, .any)) |hit| return hit;
        }
        if (self.system_fallback) {
            if (self.searchSystem(codepoint, synthetic, if (want_color) .any else .color_last)) |hit| return hit;
        }
        if (self.searchExtras(.symbols, codepoint, synthetic, .any)) |hit| return hit;
        if (self.searchExtras(.bundled, codepoint, synthetic, .any)) |hit| return hit;
        return null;
    }

    const ColorFilter = enum { any, color_only, color_last };

    fn searchExtras(self: *Manager, kind: ExtraKind, codepoint: u21, synthetic: u32, filter: ColorFilter) ?GlyphRef {
        for (self.extras.items, 0..) |extra, index| {
            if (extra.kind != kind) continue;
            if (filter == .color_only and !extra.color) continue;
            const glyph_index = ft.FT_Get_Char_Index(extra.face.handle, codepoint);
            if (glyph_index == 0) continue;
            const flags: u32 = if (extra.color) 0 else synthetic;
            return .{ .face_index = (extra_base + @as(u32, @intCast(index))) | flags, .glyph_index = glyph_index };
        }
        return null;
    }

    fn searchSystem(self: *Manager, codepoint: u21, synthetic: u32, filter: ColorFilter) ?GlyphRef {
        if (!self.system_fallback) return null;
        // `color_last` is the preference order itself: `systemOrder` already sorts colour faces
        // after every other face.
        for (self.system_order) |catalog_index| {
            const file = self.catalog.files.items[catalog_index];
            if (filter == .color_only and !file.color) continue;
            if (!file.covers(codepoint)) continue;
            const face_index = self.systemFace(catalog_index) orelse continue;
            const extra = self.extras.items[face_index - extra_base];
            const glyph_index = ft.FT_Get_Char_Index(extra.face.handle, codepoint);
            if (glyph_index == 0) continue;
            const flags: u32 = if (extra.color) 0 else synthetic;
            return .{ .face_index = face_index | flags, .glyph_index = glyph_index };
        }
        return null;
    }

    /// The extra face for a catalog file, opening it on first use. Null when it cannot be opened,
    /// which is remembered.
    fn systemFace(self: *Manager, catalog_index: u32) ?u32 {
        for (self.extras.items, 0..) |extra, index| {
            if (extra.catalog_index == catalog_index) return extra_base + @as(u32, @intCast(index));
        }
        for (self.failed_system.items) |failed| {
            if (failed == catalog_index) return null;
        }
        const file = self.catalog.files.items[catalog_index];
        const opened = blk: {
            const face = Face.open(self.library.handle, file.path, self.size_px) catch |err| break :blk err;
            break :blk self.addExtra(.system, face, catalog_index);
        };
        return opened catch |err| {
            log.debug("fallback font {s} could not be opened: {s}", .{ file.path, @errorName(err) });
            // Failing to record the failure only means it is retried later.
            self.failed_system.append(self.gpa, catalog_index) catch {};
            return null;
        };
    }

    /// The face and HarfBuzz font for a face number (no flags), or null when there is none.
    fn faceById(self: *Manager, id: u32) ?Face {
        if (id < face_style_count) return self.faces[id];
        if (id < extra_base) return null;
        const index = id - extra_base;
        if (index >= self.extras.items.len) return null;
        return self.extras.items[index].face;
    }

    fn fontById(self: *Manager, id: u32) ?*hb.hb_font_t {
        if (id < face_style_count) return self.fonts[id];
        if (id < extra_base) return null;
        const index = id - extra_base;
        if (index >= self.extras.items.len) return null;
        return self.extras.items[index].font;
    }

    fn isColorFace(self: *Manager, id: u32) bool {
        if (id < extra_base) return false;
        const index = id - extra_base;
        return index < self.extras.items.len and self.extras.items[index].color;
    }

    /// Whether `face_index` (with or without flags) draws into the colour atlas.
    pub fn isColor(self: *Manager, face_index: u32) bool {
        return self.isColorFace(face_index & face_id_mask);
    }

    /// Shape a run of text into glyphs, appending them to `out`.
    ///
    /// `out` belongs to the caller: shaping clears it and keeps its capacity, so a frame's runs
    /// allocate nothing after the first. Positions are pixels at the resolved size.
    pub fn shape(self: *Manager, text: []const u8, out: *std.ArrayList(ShapedGlyph)) Error!void {
        return self.shapeForStyle(.regular, text, out);
    }

    /// Shape with a requested style. The face is the one the fallback chain resolves for the run's
    /// first codepoint (a cell's base character), so a combining mark or an emoji sequence is
    /// shaped by the face that draws its base. Glyphs that face has no outline for (glyph 0) are
    /// dropped rather than drawn as a missing-glyph box.
    pub fn shapeForStyle(
        self: *Manager,
        style: FaceStyle,
        text: []const u8,
        out: *std.ArrayList(ShapedGlyph),
    ) Error!void {
        out.clearRetainingCapacity();
        if (text.len == 0) return;

        const first = firstCodepoint(text);
        const fallback_target: GlyphRef = .{
            .face_index = @as(u32, @intCast(self.faceIndexForStyle(style))) |
                (if (self.faces[styleIndex(style)] == null) syntheticFlags(style) else 0),
            .glyph_index = 0,
        };
        const target = if (first) |cp| self.resolveWith(style, cp, presentationOf(text)) orelse fallback_target else fallback_target;
        const id = target.face_index & face_id_mask;
        if (id == sprite_face) {
            try out.append(self.gpa, .{
                .glyph_index = target.glyph_index,
                .face_index = sprite_face,
                .cluster = 0,
                .x_advance_px = @floatFromInt(self.face_metrics.cell.width_px),
                .y_advance_px = 0,
                .x_offset_px = 0,
                .y_offset_px = 0,
            });
            return;
        }
        const face = self.faceById(id) orelse return error.InvalidFaceIndex;
        const font = self.fontById(id) orelse return error.InvalidFaceIndex;

        hb.hb_buffer_clear_contents(self.buffer);
        _ = hb.hb_buffer_add_utf8(self.buffer, text.ptr, @intCast(text.len), 0, @intCast(text.len));
        hb.hb_buffer_guess_segment_properties(self.buffer);
        if (self.ligatures_enabled) {
            hb.hb_shape(font, self.buffer, null, 0);
        } else {
            hb.hb_shape(font, self.buffer, &ligatures_off, ligatures_off.len);
        }

        const count = hb.hb_buffer_get_length(self.buffer);
        if (count == 0) return;
        var info_count: c_uint = 0;
        var position_count: c_uint = 0;
        const infos = hb.hb_buffer_get_glyph_infos(self.buffer, &info_count);
        const positions = hb.hb_buffer_get_glyph_positions(self.buffer, &position_count);
        if (infos == null or positions == null) return;

        const scale = @as(f32, @floatFromInt(self.size_px)) /
            @as(f32, @floatFromInt(face.unitsPerEm()));
        for (0..@as(usize, @intCast(count))) |index| {
            if (infos[index].codepoint == 0) continue;
            try out.append(self.gpa, .{
                .glyph_index = infos[index].codepoint,
                .face_index = target.face_index,
                .cluster = infos[index].cluster,
                .x_advance_px = @as(f32, @floatFromInt(positions[index].x_advance)) * scale,
                .y_advance_px = @as(f32, @floatFromInt(positions[index].y_advance)) * scale,
                .x_offset_px = @as(f32, @floatFromInt(positions[index].x_offset)) * scale,
                .y_offset_px = @as(f32, @floatFromInt(positions[index].y_offset)) * scale,
            });
        }
    }

    /// The bitmap of a glyph, rasterising it if the atlas does not have it yet.
    ///
    /// The entry stays valid until the glyph is evicted; check it with `Atlas.isLive` before drawing
    /// and ask again if it is gone.
    pub fn glyph(self: *Manager, glyph_index: u32) Error!Entry {
        return self.glyphForStyle(.regular, glyph_index);
    }

    /// Rasterise a primary-face glyph in a requested style: the style's own face when it has one,
    /// otherwise the regular face with a synthetic style.
    pub fn glyphForStyle(self: *Manager, style: FaceStyle, glyph_index: u32) Error!Entry {
        const slot = self.faceIndexForStyle(style);
        const flags: u32 = if (slot == 0) syntheticFlags(style) else 0;
        return self.glyphForFace(@as(u32, @intCast(slot)) | flags, glyph_index);
    }

    /// Rasterise a glyph from the face reported by `ShapedGlyph.face_index` or `GlyphRef`, flags
    /// included. A colour glyph comes back with `Entry.color` set and lives in `color_atlas`.
    pub fn glyphForFace(self: *Manager, face_index: u32, glyph_index: u32) Error!Entry {
        const id = face_index & face_id_mask;
        if (id == sprite_face) return self.spriteGlyph(glyph_index);
        const face = self.faceById(id) orelse return error.InvalidFaceIndex;
        const color = self.isColorFace(id);
        var flags = face_index & ~face_id_mask;
        // The primary faces are drawn exactly as the font made them; only fallback glyphs are
        // fitted to a one- or two-cell box. Bitmaps cannot be emboldened or sheared.
        if (id < face_style_count) flags &= ~face_flag_wide;
        if (color) flags &= face_flag_wide;
        const key: Key = .{ .glyph_index = glyph_index, .face_index = id | flags };
        const target = if (color) &self.color_atlas else &self.atlas;
        if (target.find(key)) |entry| return withColor(entry, color);
        return withColor(try self.rasterise(face, id, flags, key), color);
    }

    fn withColor(entry: Entry, color: bool) Entry {
        var marked = entry;
        marked.color = color;
        return marked;
    }

    fn rasterise(self: *Manager, face: Face, id: u32, flags: u32, key: Key) Error!Entry {
        const color = self.isColorFace(id);
        const load_flags: i32 = if (color) @intCast(ft.FT_LOAD_COLOR) else ft.FT_LOAD_DEFAULT;
        if (ft.FT_Load_Glyph(face.handle, key.glyph_index, load_flags) != 0) return error.GlyphLoadFailed;
        const slot = face.handle.*.glyph;
        const cells: u32 = if (flags & face_flag_wide != 0) 2 else 1;

        if (slot.*.format == ft.FT_GLYPH_FORMAT_OUTLINE) {
            const outline = &slot.*.outline;
            if (flags & face_flag_bold != 0) {
                // FreeType's own synthetic-bold strength: a 24th of the em, in 26.6.
                const strength: ft.FT_Pos = @intCast(@max(@as(u32, 1), self.size_px * 64 / 24));
                if (ft.FT_Outline_Embolden(outline, strength) != 0) return error.GlyphLoadFailed;
            }
            if (flags & face_flag_oblique != 0) {
                var shear: ft.FT_Matrix = .{ .xx = 0x10000, .xy = oblique_shear, .yx = 0, .yy = 0x10000 };
                ft.FT_Outline_Transform(outline, &shear);
            }
            if (id >= extra_base) self.fitOutline(outline, cells);
            if (ft.FT_Render_Glyph(slot, ft.FT_RENDER_MODE_NORMAL) != 0) return error.GlyphLoadFailed;
        }

        const bitmap = slot.*.bitmap;
        const width_px: u32 = bitmap.width;
        const height_px: u32 = bitmap.rows;
        const pitch: u32 = if (bitmap.pitch < 0) 0 else @intCast(bitmap.pitch);
        const advance_px: u32 = @intCast(@max(@divTrunc(slot.*.advance.x, 64), 0));
        const source: []const u8 = if (bitmap.buffer == null)
            &.{}
        else
            @as([*]const u8, @ptrCast(bitmap.buffer))[0 .. @as(usize, pitch) * height_px];

        switch (bitmap.pixel_mode) {
            ft.FT_PIXEL_MODE_GRAY => {
                if (color) return self.insertColorFromGray(key, source, width_px, height_px, pitch, slot.*.bitmap_left, slot.*.bitmap_top, advance_px);
                // FreeType's own buffer is the source, pitch and all: copying it out per glyph
                // would be an allocation on the hot path, and the atlas copy is the one that
                // persists.
                return self.atlas.insert(key, .{
                    .data = source,
                    .width_px = width_px,
                    .height_px = height_px,
                    .pitch = pitch,
                }, slot.*.bitmap_left, slot.*.bitmap_top, advance_px);
            },
            ft.FT_PIXEL_MODE_MONO => {
                // A one-bit bitmap font: expand to coverage.
                const count = @as(usize, width_px) * height_px;
                try self.scratch.resize(self.gpa, count);
                for (0..height_px) |y| for (0..width_px) |x| {
                    const byte = source[y * pitch + x / 8];
                    const bit = (byte >> @intCast(7 - (x % 8))) & 1;
                    self.scratch.items[y * width_px + x] = if (bit != 0) 255 else 0;
                };
                if (color) return self.insertColorFromGray(key, self.scratch.items, width_px, height_px, width_px, slot.*.bitmap_left, slot.*.bitmap_top, advance_px);
                return self.atlas.insert(key, .{
                    .data = self.scratch.items,
                    .width_px = width_px,
                    .height_px = height_px,
                    .pitch = width_px,
                }, slot.*.bitmap_left, slot.*.bitmap_top, advance_px);
            },
            ft.FT_PIXEL_MODE_BGRA => {
                if (!color) return error.UnsupportedPixelFormat;
                return self.insertColorBitmap(key, source, width_px, height_px, pitch, cells);
            },
            else => return error.UnsupportedPixelFormat,
        }
    }

    /// Scale a fallback outline down to the cell box when it does not fit, and recentre it in the
    /// box when it would spill out of it. Shifts are whole pixels so the rasterised edges stay as
    /// crisp as the font's own.
    fn fitOutline(self: *Manager, outline: *ft.FT_Outline, cells: u32) void {
        const cell = self.face_metrics.cell;
        const box_w: f64 = @floatFromInt(@as(u64, cells) * cell.width_px * 64);
        const box_h: f64 = @floatFromInt(@as(u64, cell.height_px) * 64);
        const top: f64 = @floatFromInt(@as(u64, self.face_metrics.baseline_px) * 64);
        const bottom: f64 = top - box_h;

        var cbox: ft.FT_BBox = undefined;
        ft.FT_Outline_Get_CBox(outline, &cbox);
        var width: f64 = @floatFromInt(cbox.xMax - cbox.xMin);
        var height: f64 = @floatFromInt(cbox.yMax - cbox.yMin);
        if (width <= 0 or height <= 0) return;

        var scaled = false;
        if (width > box_w or height > box_h) {
            const factor = @min(box_w / width, box_h / height);
            const fixed: ft.FT_Fixed = @intFromFloat(@floor(factor * 65536.0));
            var matrix: ft.FT_Matrix = .{ .xx = fixed, .xy = 0, .yx = 0, .yy = fixed };
            ft.FT_Outline_Transform(outline, &matrix);
            ft.FT_Outline_Get_CBox(outline, &cbox);
            width = @floatFromInt(cbox.xMax - cbox.xMin);
            height = @floatFromInt(cbox.yMax - cbox.yMin);
            scaled = true;
        }
        const x_min: f64 = @floatFromInt(cbox.xMin);
        const x_max: f64 = @floatFromInt(cbox.xMax);
        const y_min: f64 = @floatFromInt(cbox.yMin);
        const y_max: f64 = @floatFromInt(cbox.yMax);
        // A moved glyph's left and bottom edges are snapped onto pixel boundaries (never outside
        // the box), so a glyph no wider or taller than the box rasterises to a bitmap that is not
        // either: an edge left between two pixels would spill one partial pixel past the cell.
        var dx: f64 = 0;
        var dy: f64 = 0;
        if (scaled or x_min < 0 or x_max > box_w) {
            dx = @max(0, @floor((box_w - width) / 2 / 64.0) * 64.0) - x_min;
        }
        if (scaled or y_max > top or y_min < bottom) {
            dy = @max(bottom, bottom + @floor((box_h - height) / 2 / 64.0) * 64.0) - y_min;
        }
        const shift_x: ft.FT_Pos = @intFromFloat(dx);
        const shift_y: ft.FT_Pos = @intFromFloat(dy);
        if (shift_x != 0 or shift_y != 0) ft.FT_Outline_Translate(outline, shift_x, shift_y);
    }

    /// Scale a premultiplied BGRA bitmap glyph to fit its cell box (box-filtered, never enlarged),
    /// convert it to RGBA and centre it in the box.
    fn insertColorBitmap(self: *Manager, key: Key, source: []const u8, width_px: u32, height_px: u32, pitch: u32, cells: u32) Error!Entry {
        const cell = self.face_metrics.cell;
        const box_w = cells * cell.width_px;
        const box_h = cell.height_px;
        if (width_px == 0 or height_px == 0) {
            return self.color_atlas.insert(key, .{ .data = &.{}, .width_px = 0, .height_px = 0, .pitch = 0 }, 0, 0, box_w);
        }
        const factor = @min(
            1.0,
            @min(
                @as(f64, @floatFromInt(box_w)) / @as(f64, @floatFromInt(width_px)),
                @as(f64, @floatFromInt(box_h)) / @as(f64, @floatFromInt(height_px)),
            ),
        );
        const out_w: u32 = @max(1, @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(width_px)) * factor))));
        const out_h: u32 = @max(1, @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(height_px)) * factor))));
        try self.scratch.resize(self.gpa, @as(usize, out_w) * out_h * 4);
        for (0..out_h) |oy| for (0..out_w) |ox| {
            const x0 = ox * width_px / out_w;
            const x1 = @max(x0 + 1, (ox + 1) * width_px / out_w);
            const y0 = oy * height_px / out_h;
            const y1 = @max(y0 + 1, (oy + 1) * height_px / out_h);
            var sum: [4]u32 = .{ 0, 0, 0, 0 };
            var y = y0;
            while (y < y1) : (y += 1) {
                var x = x0;
                while (x < x1) : (x += 1) {
                    const pixel = source[y * pitch + x * 4 ..][0..4];
                    for (0..4) |channel| sum[channel] += pixel[channel];
                }
            }
            const samples: u32 = @intCast((x1 - x0) * (y1 - y0));
            const out = self.scratch.items[(oy * out_w + ox) * 4 ..][0..4];
            // BGRA in, RGBA out, both premultiplied.
            out[0] = @intCast(sum[2] / samples);
            out[1] = @intCast(sum[1] / samples);
            out[2] = @intCast(sum[0] / samples);
            out[3] = @intCast(sum[3] / samples);
        };
        const bearing_x: i32 = @intCast((box_w -| out_w) / 2);
        const top_offset: i32 = @intCast((box_h -| out_h) / 2);
        const bearing_y: i32 = @as(i32, @intCast(self.face_metrics.baseline_px)) - top_offset;
        return self.color_atlas.insert(key, .{
            .data = self.scratch.items,
            .width_px = out_w,
            .height_px = out_h,
            .pitch = out_w * 4,
        }, bearing_x, bearing_y, box_w);
    }

    /// A coverage glyph from a colour face (an outline glyph in a COLR font without a colour
    /// layer): stored as white ink so it still draws.
    fn insertColorFromGray(self: *Manager, key: Key, source: []const u8, width_px: u32, height_px: u32, pitch: u32, bearing_x: i32, bearing_y: i32, advance_px: u32) Error!Entry {
        const count = @as(usize, width_px) * height_px * 4;
        var expanded = try self.gpa.alloc(u8, count);
        defer self.gpa.free(expanded);
        for (0..height_px) |y| for (0..width_px) |x| {
            const coverage = source[y * pitch + x];
            @memset(expanded[(y * width_px + x) * 4 ..][0..4], coverage);
        };
        return self.color_atlas.insert(key, .{
            .data = expanded,
            .width_px = width_px,
            .height_px = height_px,
            .pitch = width_px * 4,
        }, bearing_x, bearing_y, advance_px);
    }

    /// A built-in sprite, drawn at exactly one cell and anchored to the cell's top-left corner.
    fn spriteGlyph(self: *Manager, codepoint: u32) Error!Entry {
        const key: Key = .{ .glyph_index = codepoint, .face_index = sprite_face };
        if (self.atlas.find(key)) |entry| return entry;
        if (codepoint > std.math.maxInt(u21)) return error.GlyphLoadFailed;
        const cell = self.face_metrics.cell;
        try self.scratch.resize(self.gpa, @as(usize, cell.width_px) * cell.height_px);
        if (!sprite.render(@intCast(codepoint), cell.width_px, cell.height_px, self.scratch.items)) {
            return error.GlyphLoadFailed;
        }
        return self.atlas.insert(key, .{
            .data = self.scratch.items,
            .width_px = cell.width_px,
            .height_px = cell.height_px,
            .pitch = cell.width_px,
        }, 0, @intCast(self.face_metrics.baseline_px), cell.width_px);
    }

    fn faceIndexForStyle(self: Manager, style: FaceStyle) usize {
        const requested = styleIndex(style);
        return if (self.faces[requested] != null) requested else styleIndex(.regular);
    }
};

/// A HarfBuzz font over the same font bytes as `face`, scaled in font units so positions convert to
/// pixels the same way for every face.
///
/// HarfBuzz reads the font through its own OpenType functions rather than through `hb-ft` and the
/// shared `FT_Face`. `hb-ft` resizes the `FT_Face` it is given to its own scale on the first shape
/// (`FT_Set_Char_Size(upem)` in HarfBuzz 11), which silently re-sized every glyph rasterised after
/// the first shaped cluster to `upem / 64` pixels: about 15.6px for JetBrains Mono whatever the
/// configured size or display scale, so text at 2x drew at half size in 2x cells. Keeping the
/// shaper off the rasteriser's face makes `FT_Set_Pixel_Sizes` the only size that face ever has.
/// The glyph indices are the same because both read the same cmap.
///
/// HarfBuzz allocates and can fail doing so, which is a real outcome rather than an invariant.
fn harfBuzzFont(face: Face, size_px: u32) error{ OutOfMemory, FontFileUnreadable }!*hb.hb_font_t {
    const blob: *hb.hb_blob_t = switch (face.origin) {
        .memory => |bytes| hb.hb_blob_create(
            bytes.ptr,
            @intCast(bytes.len),
            hb.HB_MEMORY_MODE_READONLY,
            null,
            null,
        ) orelse return error.OutOfMemory,
        .path => |path| hb.hb_blob_create_from_file_or_fail(path.ptr) orelse
            return error.FontFileUnreadable,
    };
    defer hb.hb_blob_destroy(blob);
    const hb_face: *hb.hb_face_t = hb.hb_face_create(blob, 0) orelse return error.OutOfMemory;
    defer hb.hb_face_destroy(hb_face);
    const font: *hb.hb_font_t = hb.hb_font_create(hb_face) orelse return error.OutOfMemory;
    const upem: i32 = @intCast(face.unitsPerEm());
    hb.hb_font_set_scale(font, upem, upem);
    hb.hb_font_set_ppem(font, @intCast(size_px), @intCast(size_px));
    return font;
}

/// The first codepoint of `text`, or null for malformed UTF-8.
fn firstCodepoint(text: []const u8) ?u21 {
    const length = std.unicode.utf8ByteSequenceLength(text[0]) catch return null;
    if (length > text.len) return null;
    return std.unicode.utf8Decode(text[0..length]) catch null;
}

/// What the variation selectors in a cluster ask for.
fn presentationOf(text: []const u8) Presentation {
    if (std.mem.indexOf(u8, text, "\u{FE0F}") != null) return .emoji;
    if (std.mem.indexOf(u8, text, "\u{FE0E}") != null) return .text;
    return .default;
}

/// Catalog indices in fallback preference order: colour faces last, then monospaced before
/// proportional, regular style first, and path order so the choice is stable between launches.
fn systemOrder(gpa: Allocator, catalog: *const Catalog) ![]u32 {
    const order = try gpa.alloc(u32, catalog.files.items.len);
    for (order, 0..) |*slot, index| slot.* = @intCast(index);
    std.mem.sort(u32, order, catalog, struct {
        fn lessThan(context: *const Catalog, a: u32, b: u32) bool {
            const fa = context.files.items[a];
            const fb = context.files.items[b];
            if (fa.color != fb.color) return !fa.color;
            if (fa.fixed_width != fb.fixed_width) return fa.fixed_width;
            const ra = fa.face_style == .regular;
            const rb = fb.face_style == .regular;
            if (ra != rb) return ra;
            return std.mem.order(u8, fa.path, fb.path) == .lt;
        }
    }.lessThan);
    return order;
}

const Resolution = struct {
    /// Slot zero is the primary resolution. Other slots are distinct exact-style files only.
    faces: [face_style_count]?Face = @splat(null),
    family: []u8,
    source_path: []u8,
    used_fallback: bool,

    fn deinit(self: *Resolution, gpa: Allocator) void {
        for (&self.faces) |*maybe_face| {
            if (maybe_face.*) |*face| face.deinit();
        }
        gpa.free(self.family);
        gpa.free(self.source_path);
        self.* = undefined;
    }
};

/// Pick the primary face and its style faces: the configured family's own, replaced by any
/// `Request` style-family override.
fn resolveFaces(
    gpa: Allocator,
    library: ft.FT_Library,
    catalog: *const Catalog,
    request: Request,
    size_px: u32,
) !Resolution {
    var resolution = try resolvePrimary(gpa, library, catalog, request, size_px);
    errdefer resolution.deinit(gpa);
    applyStyleOverrides(library, catalog, request, size_px, &resolution);
    return resolution;
}

/// Replace a style slot with the face a `Request` style family names. A family that is not
/// installed, or a file that will not open, keeps whatever the slot held: the family's own style
/// face, or nothing, which synthesises the style from the primary face.
fn applyStyleOverrides(
    library: ft.FT_Library,
    catalog: *const Catalog,
    request: Request,
    size_px: u32,
    resolution: *Resolution,
) void {
    const overrides = [_]struct { style: FaceStyle, family: []const u8 }{
        .{ .style = .bold, .family = request.bold_family },
        .{ .style = .italic, .family = request.italic_family },
        .{ .style = .bold_italic, .family = request.bold_italic_family },
    };
    for (overrides) |override| {
        if (override.family.len == 0) continue;
        const file = catalog.findFamilyFaces(override.family).get(override.style) orelse
            catalog.findFamily(override.family) orelse {
            log.warn("{s} font family '{s}' is not installed; keeping the derived face", .{
                canonicalStyleName(override.style),
                override.family,
            });
            continue;
        };
        const face = Face.open(library, file.path, size_px) catch |err| {
            log.warn("font style file {s} could not be opened ({s}); keeping the derived face", .{
                file.path,
                @errorName(err),
            });
            continue;
        };
        const slot = &resolution.faces[styleIndex(override.style)];
        if (slot.*) |*previous| previous.deinit();
        slot.* = face;
    }
}

/// Pick the primary face and any distinct exact-style faces from the configured family.
fn resolvePrimary(
    gpa: Allocator,
    library: ft.FT_Library,
    catalog: *const Catalog,
    request: Request,
    size_px: u32,
) !Resolution {
    if (catalog.findFamily(request.family)) |file| {
        if (Face.open(library, file.path, size_px)) |face| {
            var resolution = try makeResolution(gpa, face, file.path, false);
            errdefer resolution.deinit(gpa);

            const styles = catalog.findFamilyFaces(request.family);
            const optional_styles = [_]FaceStyle{ .bold, .italic, .bold_italic };
            for (optional_styles) |style| {
                const style_file = styles.get(style) orelse continue;
                // A family without a regular face can use (for example) its bold face as the
                // primary resolution. That handle already lives in slot zero and must not be
                // opened and owned a second time merely because its metadata also says "bold".
                if (std.mem.eql(u8, style_file.path, file.path)) continue;
                resolution.faces[styleIndex(style)] = Face.open(
                    library,
                    style_file.path,
                    size_px,
                ) catch |err| {
                    log.warn("font style file {s} could not be opened ({s}); using the primary face", .{
                        style_file.path,
                        @errorName(err),
                    });
                    continue;
                };
            }
            return resolution;
        } else |err| {
            // The catalog opened this file moments ago, so failing now means it changed underneath
            // us. Falling back beats refusing to start.
            log.warn("font file {s} could not be opened ({s}); using the bundled face", .{
                file.path,
                @errorName(err),
            });
            return bundled(gpa, library, size_px);
        }
    } else if (request.family.len != 0) {
        log.warn("font family '{s}' is not installed; using the bundled {s}", .{
            request.family,
            bundled_path,
        });
    }
    return bundled(gpa, library, size_px);
}

/// The bundled face, loaded from the bytes compiled into the binary.
fn bundled(gpa: Allocator, library: ft.FT_Library, size_px: u32) !Resolution {
    return makeResolution(gpa, try Face.openMemory(library, bundled_face, size_px), bundled_path, true);
}

/// A resolution owns its faces and copies of the two primary strings it reports, so a caller can
/// keep the family and path after the catalog that found them is gone.
fn makeResolution(gpa: Allocator, face: Face, path: []const u8, used_fallback: bool) !Resolution {
    var owned_face = face;
    errdefer owned_face.deinit();
    const family = try gpa.dupe(u8, face.familyName());
    errdefer gpa.free(family);
    const source_path = try gpa.dupe(u8, path);
    errdefer gpa.free(source_path);
    var faces: [face_style_count]?Face = @splat(null);
    faces[styleIndex(.regular)] = owned_face;
    return .{
        .faces = faces,
        .family = family,
        .source_path = source_path,
        .used_fallback = used_fallback,
    };
}

fn freeAll(gpa: Allocator, owned: []const []const u8) void {
    for (owned) |item| gpa.free(item);
    gpa.free(owned);
}

const testing = std.testing;

fn appendSyntheticFont(
    catalog: *Catalog,
    path: []const u8,
    family: []const u8,
    style_name: []const u8,
    face_style: FaceStyle,
) !void {
    const owned_path = try catalog.gpa.dupeZ(u8, path);
    errdefer catalog.gpa.free(owned_path);
    const owned_family = try catalog.gpa.dupe(u8, family);
    errdefer catalog.gpa.free(owned_family);
    const owned_style = try catalog.gpa.dupe(u8, style_name);
    errdefer catalog.gpa.free(owned_style);
    try catalog.files.append(catalog.gpa, .{
        .path = owned_path,
        .family = owned_family,
        .style = owned_style,
        .face_style = face_style,
    });
}

test "FreeType style flags classify all four face styles" {
    try testing.expectEqual(FaceStyle.regular, classifyStyle(0));
    try testing.expectEqual(
        FaceStyle.bold,
        classifyStyle(@as(ft.FT_Long, ft.FT_STYLE_FLAG_BOLD)),
    );
    try testing.expectEqual(
        FaceStyle.italic,
        classifyStyle(@as(ft.FT_Long, ft.FT_STYLE_FLAG_ITALIC)),
    );
    try testing.expectEqual(
        FaceStyle.bold_italic,
        classifyStyle(@as(ft.FT_Long, ft.FT_STYLE_FLAG_BOLD | ft.FT_STYLE_FLAG_ITALIC)),
    );
}

test "family styles resolve exactly and deterministically" {
    var catalog: Catalog = .{ .gpa = testing.allocator };
    defer catalog.deinit();

    // Canonical names beat lexicographically earlier non-canonical weights. Where neither name is
    // canonical (the bold pair), path order remains the deterministic fallback rather than the
    // directory walk's order. The face-style fields model FreeType's flags: on real JetBrains Mono,
    // ExtraBold is reported as non-bold and ExtraBold Italic as italic.
    try appendSyntheticFont(&catalog, "/fonts/a-extra-bold.ttf", "Conduit Mono", "ExtraBold", .regular);
    try appendSyntheticFont(&catalog, "/fonts/z-regular.ttf", "Conduit Mono", "Regular", .regular);
    try appendSyntheticFont(&catalog, "/fonts/z-bold.ttf", "Conduit Mono", "Heavy", .bold);
    try appendSyntheticFont(&catalog, "/fonts/a-bold.ttf", "Conduit Mono", "Weight 700", .bold);
    try appendSyntheticFont(&catalog, "/fonts/a-extra-bold-italic.ttf", "Conduit Mono", "ExtraBold Italic", .italic);
    try appendSyntheticFont(&catalog, "/fonts/z-italic.ttf", "Conduit Mono", "Italic", .italic);
    try appendSyntheticFont(&catalog, "/fonts/bold-italic.ttf", "Conduit Mono", "BI", .bold_italic);
    try appendSyntheticFont(&catalog, "/fonts/unrelated.ttf", "Other Mono", "Regular", .regular);

    const styles = catalog.findFamilyFaces("conduit mono");
    try testing.expectEqualStrings("/fonts/z-regular.ttf", styles.get(.regular).?.path);
    try testing.expectEqualStrings("/fonts/a-bold.ttf", styles.get(.bold).?.path);
    try testing.expectEqualStrings("/fonts/z-italic.ttf", styles.get(.italic).?.path);
    try testing.expectEqualStrings("/fonts/bold-italic.ttf", styles.get(.bold_italic).?.path);
    try testing.expectEqualStrings("/fonts/z-regular.ttf", catalog.findFamily("Conduit Mono").?.path);

    var styled_only: Catalog = .{ .gpa = testing.allocator };
    defer styled_only.deinit();
    try appendSyntheticFont(&styled_only, "/fonts/z-bold.ttf", "Styled Only", "Bold", .bold);
    try appendSyntheticFont(&styled_only, "/fonts/a-italic.ttf", "Styled Only", "Italic", .italic);
    try testing.expect(styled_only.findFamilyFaces("Styled Only").get(.regular) == null);
    try testing.expectEqualStrings(
        "/fonts/a-italic.ttf",
        styled_only.findFamily("Styled Only").?.path,
    );
}

test "a size that could not produce a pixel is rejected" {
    // These are exactly the values a hand-edited settings file produces, and every one of them would
    // otherwise reach the rasteriser.
    try testing.expectError(error.SizeOutOfRange, Size.init(0, 1.0));
    try testing.expectError(error.SizeOutOfRange, Size.init(-14, 1.0));
    try testing.expectError(error.SizeOutOfRange, Size.init(std.math.nan(f32), 1.0));
    try testing.expectError(error.SizeOutOfRange, Size.init(std.math.inf(f32), 1.0));
    try testing.expectError(error.SizeOutOfRange, Size.init(Size.min_points / 2, 1.0));
    // A zero or negative scale comes from the display, not the file, but it must not survive either.
    try testing.expectError(error.SizeOutOfRange, Size.init(14, 0));
    try testing.expectError(error.SizeOutOfRange, Size.init(14, -1));

    const at_floor = try Size.init(Size.min_points, 1.0);
    try testing.expectEqual(Size.min_points, at_floor.points);
}

test "points convert to device pixels at the display scale" {
    const at_1x = try Size.init(14, 1.0);
    try testing.expectEqual(@as(u32, 14), at_1x.pixels());

    // 14pt at 2x is 28 device pixels, so the terminal keeps the same physical size.
    const at_2x = try Size.init(14, 2.0);
    try testing.expectEqual(@as(u32, 28), at_2x.pixels());

    // A fractional scale rounds to the nearest whole pixel: 13 * 1.5 = 19.5 -> 20.
    const at_1_5x = try Size.init(13, 1.5);
    try testing.expectEqual(@as(u32, 20), at_1_5x.pixels());
}

test "moving a window to a monitor of another scale keeps the chosen point size" {
    const at_1x = try Size.init(16, 1.0);
    const moved = try at_1x.atScale(2.0);

    try testing.expectEqual(at_1x.points, moved.points);
    try testing.expectEqual(@as(u32, 32), moved.pixels());

    // An impossible scale is refused instead of producing a zero-pixel font.
    try testing.expectError(error.SizeOutOfRange, at_1x.atScale(0));
}

test "a cell never has a zero dimension" {
    const collapsed = CellSize.init(0, 0);
    try testing.expectEqual(@as(u32, 1), collapsed.width_px);
    try testing.expectEqual(@as(u32, 1), collapsed.height_px);

    const real = CellSize.init(9, 21);
    try testing.expectEqual(@as(u32, 9), real.width_px);
    try testing.expectEqual(@as(u32, 21), real.height_px);
}

test "the grid is integral: a partial cell is dropped, not drawn" {
    const cell = CellSize.init(9, 21);

    const exact = cell.cellsPer(900, 420);
    try testing.expectEqual(@as(u32, 100), exact.columns);
    try testing.expectEqual(@as(u32, 20), exact.rows);

    // 905px fits 100 whole cells; the 5px remainder is not a fractional column.
    const ragged = cell.cellsPer(905, 425);
    try testing.expectEqual(@as(u32, 100), ragged.columns);
    try testing.expectEqual(@as(u32, 20), ragged.rows);

    // A surface smaller than one cell has no cells at all.
    const tiny = cell.cellsPer(4, 4);
    try testing.expectEqual(@as(u32, 0), tiny.columns);
    try testing.expectEqual(@as(u32, 0), tiny.rows);
}

test "an atlas with no pixels to give out is refused" {
    try testing.expectError(error.AtlasSizeOutOfRange, Atlas.init(testing.allocator, 0, 16));
    try testing.expectError(error.AtlasSizeOutOfRange, Atlas.init(testing.allocator, 16, 0));
}

test "a cached glyph is answered from the atlas, not rasterised again" {
    var atlas = try Atlas.init(testing.allocator, 64, 64);
    defer atlas.deinit();

    const bitmap = Bitmap{ .data = &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }, .width_px = 3, .height_px = 3, .pitch = 3 };
    const first = try atlas.insert(.{ .glyph_index = 7 }, bitmap, 1, 2, 3);
    try testing.expect(atlas.isLive(first));
    var read_back: [9]u8 = undefined;
    try testing.expectEqual(@as(usize, 9), atlas.copyInto(first, &read_back));
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }, &read_back);

    const second = atlas.find(.{ .glyph_index = 7 }).?;
    try testing.expectEqual(first.slot, second.slot);
    try testing.expectEqual(@as(u64, 1), atlas.stats.hits);
    try testing.expectEqual(@as(u64, 0), atlas.stats.misses);

    // A glyph the atlas has never seen is a miss, not a hit on whatever sits in slot 0.
    try testing.expect(atlas.find(.{ .glyph_index = 8 }) == null);
    try testing.expectEqual(@as(u64, 1), atlas.stats.misses);
}

test "equal glyph indices from distinct face slots keep distinct atlas entries" {
    var atlas = try Atlas.init(testing.allocator, 16, 8);
    defer atlas.deinit();

    const regular_pixels = [_]u8{1} ** 16;
    const bold_pixels = [_]u8{2} ** 16;
    const regular = try atlas.insert(
        .{ .glyph_index = 42, .face_index = 0 },
        .{ .data = &regular_pixels, .width_px = 4, .height_px = 4, .pitch = 4 },
        0,
        4,
        4,
    );
    const bold = try atlas.insert(
        .{ .glyph_index = 42, .face_index = 1 },
        .{ .data = &bold_pixels, .width_px = 4, .height_px = 4, .pitch = 4 },
        0,
        4,
        4,
    );

    try testing.expect(regular.slot != bold.slot);
    try testing.expect(atlas.find(.{ .glyph_index = 42, .face_index = 0 }).?.slot == regular.slot);
    try testing.expect(atlas.find(.{ .glyph_index = 42, .face_index = 1 }).?.slot == bold.slot);
    var regular_copy: [16]u8 = undefined;
    var bold_copy: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, regular_copy.len), atlas.copyInto(regular, &regular_copy));
    try testing.expectEqual(@as(usize, bold_copy.len), atlas.copyInto(bold, &bold_copy));
    try testing.expectEqualSlices(u8, &regular_pixels, &regular_copy);
    try testing.expectEqualSlices(u8, &bold_pixels, &bold_copy);
}

test "rows padded to a wider pitch are copied without the padding" {
    var atlas = try Atlas.init(testing.allocator, 16, 16);
    defer atlas.deinit();

    // Two rows of three pixels each, padded to four bytes a row: the padding must not end up in
    // the atlas, or every glyph after it would be skewed.
    const padded = [_]u8{ 1, 2, 3, 0xAA, 4, 5, 6, 0xAA };
    const entry = try atlas.insert(
        .{ .glyph_index = 1 },
        .{ .data = &padded, .width_px = 3, .height_px = 2, .pitch = 4 },
        0,
        2,
        3,
    );
    var unpacked: [6]u8 = undefined;
    try testing.expectEqual(@as(usize, 6), atlas.copyInto(entry, &unpacked));
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, &unpacked);
}

test "a glyph with no ink is cached and costs no atlas space" {
    var atlas = try Atlas.init(testing.allocator, 64, 64);
    defer atlas.deinit();

    const before = atlas.pixels.len;
    const space = try atlas.insert(
        .{ .glyph_index = 3 },
        .{ .data = &.{}, .width_px = 0, .height_px = 0, .pitch = 0 },
        0,
        0,
        8,
    );
    try testing.expect(atlas.isLive(space));
    try testing.expectEqual(@as(usize, 0), atlas.copyInto(space, &.{}));
    try testing.expectEqual(before, atlas.pixels.len);
}

test "a full atlas evicts the least recently used glyph, and its pixels come back identical" {
    var atlas = try Atlas.init(testing.allocator, 16, 16);
    defer atlas.deinit();

    // Four 8x8 glyphs fill a 16x16 atlas exactly.
    const first_bitmap = [_]u8{1} ** 64;
    const first = try atlas.insert(
        .{ .glyph_index = 1 },
        .{ .data = &first_bitmap, .width_px = 8, .height_px = 8, .pitch = 8 },
        0,
        8,
        8,
    );
    var read_back: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 64), atlas.copyInto(first, &read_back));
    try testing.expectEqualSlices(u8, &first_bitmap, &read_back);
    for ([_]u32{ 2, 3, 4 }, 0..) |index, value| {
        const filled = [_]u8{@intCast(value + 1)} ** 64;
        _ = try atlas.insert(
            .{ .glyph_index = index },
            .{ .data = &filled, .width_px = 8, .height_px = 8, .pitch = 8 },
            0,
            8,
            8,
        );
    }
    try testing.expectEqual(@as(u32, 4), atlas.live_count);

    // Touch 2, 3 and 4, so 1 is the least recently used, then overflow the atlas.
    for ([_]u32{ 2, 3, 4 }) |index| _ = atlas.find(.{ .glyph_index = index });
    const replacement = [_]u8{5} ** 64;
    _ = try atlas.insert(
        .{ .glyph_index = 5 },
        .{ .data = &replacement, .width_px = 8, .height_px = 8, .pitch = 8 },
        0,
        8,
        8,
    );

    try testing.expectEqual(@as(u64, 1), atlas.stats.evictions);
    try testing.expect(!atlas.isLive(first));
    try testing.expect(atlas.find(.{ .glyph_index = 1 }) == null);
    // Whatever now holds the evicted rectangle holds its own pixels and nothing of the glyph that
    // was there before: a cache that leaves the old glyph showing through is a corrupted cache.
    const occupant = atlas.find(.{ .glyph_index = 5 }).?;
    var occupied: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 64), atlas.copyInto(occupant, &occupied));
    try testing.expectEqualSlices(u8, &replacement, &occupied);

    // The evicted glyph re-rasterises to exactly the bytes it had before: eviction moves rectangles
    // around, and a bitmap that came back different is a corrupted glyph.
    const again = try atlas.insert(
        .{ .glyph_index = 1 },
        .{ .data = &first_bitmap, .width_px = 8, .height_px = 8, .pitch = 8 },
        0,
        8,
        8,
    );
    var after_eviction: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 64), atlas.copyInto(again, &after_eviction));
    try testing.expectEqualSlices(u8, &first_bitmap, &after_eviction);
}

test "a bitmap that is not the size it claims is refused" {
    var atlas = try Atlas.init(testing.allocator, 16, 16);
    defer atlas.deinit();

    // A pitch narrower than the bitmap would read past the row.
    const eight = [_]u8{1} ** 8;
    try testing.expectError(error.BitmapSizeMismatch, atlas.insert(
        .{ .glyph_index = 1 },
        .{ .data = &eight, .width_px = 3, .height_px = 3, .pitch = 2 },
        0,
        0,
        3,
    ));

    // And a buffer too short for the bitmap it claims would read past its end.
    const four = [_]u8{1} ** 4;
    try testing.expectError(error.BitmapSizeMismatch, atlas.insert(
        .{ .glyph_index = 1 },
        .{ .data = &four, .width_px = 3, .height_px = 3, .pitch = 3 },
        0,
        0,
        3,
    ));
}

test "a family is resolved by name from a directory of font files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    // The file's name and location have nothing to do with its family: resolution reads the name
    // table, so a file called anything, in any directory, answers to its family.
    try tmp.dir.writeFile(io, .{ .sub_path = "whatever.ttf", .data = bundled_face });
    try tmp.dir.createDirPath(io, "nested/deeper");
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/deeper/also-whatever.otf", .data = bundled_face });
    // Files that are not fonts, and a file named like one that is not, are skipped rather than
    // failing the scan.
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "not a font" });
    try tmp.dir.writeFile(io, .{ .sub_path = "broken.ttf", .data = "not a font either" });

    const root = try tmp.parent_dir.realPathFileAlloc(io, &tmp.sub_path, testing.allocator);
    defer testing.allocator.free(root);

    var catalog = try Catalog.scan(io, testing.allocator, &.{root});
    defer catalog.deinit();

    try testing.expectEqual(@as(usize, 2), catalog.files.items.len);

    const found = catalog.findFamily("JetBrains Mono") orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, found.path, "whatever") != null);
    try testing.expectEqualStrings("Regular", found.style);
    try testing.expectEqual(FaceStyle.regular, found.face_style);

    // Discovery paths must remain NUL-terminated when retained by the catalog: FreeType's file API
    // accepts a C string, and reopening a merely length-delimited slice can read into adjacent heap
    // bytes and fail even though the scan opened the same file moments earlier.
    try testing.expectEqual(@as(u8, 0), found.path[found.path.len]);
    var library = try Library.init();
    defer library.deinit();
    var reopened = try Face.open(library.handle, found.path, 14);
    defer reopened.deinit();
    try testing.expectEqualStrings("JetBrains Mono", reopened.familyName());

    // A family name is typed by a human, so case is not part of the request.
    const lower = catalog.findFamily("jetbrains mono") orelse return error.TestExpectedEqual;
    try testing.expectEqual(found.path, lower.path);

    // A family nobody installed is not found, which is what makes the bundled face the fallback.
    try testing.expect(catalog.findFamily("Conduit Family That Does Not Exist") == null);
}

test "a configured family that is not installed falls back to the bundled face" {
    var manager = try Manager.init(testing.allocator, testing.io, .{
        .family = "Conduit Family That Does Not Exist",
        .size = try Size.init(14, 1.0),
    });
    defer manager.deinit();

    try testing.expect(manager.isFallback());
    try testing.expectEqualStrings(bundled_path, manager.sourcePath());
    try testing.expectEqualStrings("JetBrains Mono", manager.familyName());

    const metrics = manager.metrics();
    try testing.expectEqual(@as(u32, 8), metrics.cell.width_px);
    try testing.expectEqual(@as(u32, 15), metrics.baseline_px);
    try testing.expectEqual(@as(u32, 20), metrics.cell.height_px);

    // The bundled face really is loaded, not merely named: its glyphs rasterise.
    const entry = try manager.glyph(manager.glyphIndex('A'));
    try testing.expect(entry.rect.width > 0);
    try testing.expect(entry.rect.height > 0);
}

test "a missing style uses the regular face without another owned slot" {
    var manager = try Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try Size.init(14, 1.0),
    });
    defer manager.deinit();

    const regular_index = manager.glyphIndex('A');
    for ([_]FaceStyle{ .bold, .italic, .bold_italic }) |style| {
        try testing.expectEqual(regular_index, manager.glyphIndexForStyle(style, 'A'));
        const entry = try manager.glyphForStyle(style, regular_index);
        // No other face is owned: the regular face stands in, with the synthetic style the request
        // asked for carried in the flag bits so bold and italic still look different (TASK-39).
        try testing.expectEqual(@as(u32, 0), entry.key.face_index & face_id_mask);
        try testing.expectEqual(syntheticFlags(style), entry.key.face_index & ~face_id_mask);
    }

    var run: std.ArrayList(ShapedGlyph) = .empty;
    defer run.deinit(testing.allocator);
    try manager.shapeForStyle(.bold_italic, "A", &run);
    try testing.expectEqual(@as(usize, 1), run.items.len);
    try testing.expectEqual(@as(u32, 0), run.items[0].face_index & face_id_mask);
    try testing.expectEqual(face_flag_bold | face_flag_oblique, run.items[0].face_index & ~face_id_mask);
    _ = try manager.glyphForFace(run.items[0].face_index, run.items[0].glyph_index);
    try testing.expectError(error.InvalidFaceIndex, manager.glyphForFace(1, regular_index));
}

test "the bundled face rasterises glyphs with ink" {
    var manager = try Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try Size.init(14, 1.0),
    });
    defer manager.deinit();

    for ([_]u21{ 'g', 'A', '@', 'W' }) |codepoint| {
        const index = manager.glyphIndex(codepoint);
        try testing.expect(index != 0);
        const entry = try manager.glyph(index);
        try testing.expect(manager.atlas.isLive(entry));
        try testing.expect(entry.rect.width > 0);
        try testing.expect(entry.rect.height > 0);

        var inked = false;
        var row: [256]u8 = undefined;
        const copied = manager.atlas.copyInto(entry, &row);
        try testing.expectEqual(@as(usize, @intCast(entry.rect.width * entry.rect.height)), copied);
        for (row[0..copied]) |coverage| {
            if (coverage > 0) inked = true;
        }
        try testing.expect(inked);
    }

    // A space has no ink, and asking for it must still work: every line of terminal output has
    // more spaces than anything else.
    const space = try manager.glyph(manager.glyphIndex(' '));
    try testing.expect(space.rect.width == 0);
    try testing.expect(space.advance_px > 0);
}

test "a glyph survives eviction and re-rasterises to the same pixels" {
    // A real face, a real atlas far too small for it, and a real eviction: the pixels read back for
    // a glyph before the eviction have to be the pixels read back after it.
    var manager = try Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try Size.init(20, 1.0),
        .atlas_width_px = 24,
        .atlas_height_px = 24,
    });
    defer manager.deinit();

    const watched = manager.glyphIndex('g');
    const entry = try manager.glyph(watched);
    try testing.expect(entry.rect.width > 0);

    const gpa = testing.allocator;
    const before = try gpa.alloc(u8, @as(usize, entry.rect.width) * entry.rect.height);
    defer gpa.free(before);
    try testing.expect(before.len == manager.atlas.copyInto(entry, before));

    // Fill the atlas with other glyphs until the watcher is evicted. ASCII covers far more glyphs
    // than 24x24 pixels hold.
    var codepoint: u21 = '!';
    while (codepoint <= '~' and manager.atlas.isLive(entry)) : (codepoint += 1) {
        if (codepoint == 'g') continue;
        _ = manager.glyph(manager.glyphIndex(codepoint)) catch continue;
    }
    try testing.expect(!manager.atlas.isLive(entry));
    try testing.expect(manager.atlas.stats.evictions > 0);

    const again = try manager.glyph(watched);
    try testing.expect(manager.atlas.isLive(again));
    const after = try gpa.alloc(u8, before.len);
    defer gpa.free(after);
    try testing.expectEqual(before.len, manager.atlas.copyInto(again, after));
    try testing.expectEqualSlices(u8, before, after);
}

test "cell metrics come from the loaded face" {
    var manager = try Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try Size.init(14, 1.0),
    });
    defer manager.deinit();

    // JetBrains Mono at 14px, from the font file's own tables — read out of the TTF directly by an
    // independent parse: 1000 units per em, ascender 1020, descender -300, line gap 0, and an
    // advance of 600 units for every glyph. Scaled to 14 pixels that is an 8.4px advance, a 14.3px
    // ascent and a 4.2px descent, which FreeType rounds outwards to whole pixels as 8px, 15px and
    // 5px. The cell is ascent + descent, because that is 20px while the font's own line height
    // rounds to 19px. None of these numbers is a constant this module chose.
    try testing.expectEqual(@as(u32, 8), manager.metrics().cell.width_px);
    try testing.expectEqual(@as(u32, 15), manager.metrics().baseline_px);
    try testing.expectEqual(@as(u32, 20), manager.metrics().cell.height_px);
    try testing.expectEqual(
        manager.metrics().baseline_px + manager.metrics().descent_px,
        manager.metrics().cell.height_px,
    );

    // The metrics follow the size: twice the pixels, and every dimension scales with them.
    var bigger = try Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try Size.init(28, 1.0),
    });
    defer bigger.deinit();
    try testing.expectEqual(@as(u32, 17), bigger.metrics().cell.width_px);
    try testing.expectEqual(@as(u32, 29), bigger.metrics().baseline_px);
    try testing.expectEqual(@as(u32, 38), bigger.metrics().cell.height_px);
}

test "shaping a run reports one glyph per character, in pixels" {
    var manager = try Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try Size.init(14, 1.0),
    });
    defer manager.deinit();

    var run: std.ArrayList(ShapedGlyph) = .empty;
    defer run.deinit(testing.allocator);

    try manager.shape("hello", &run);
    try testing.expectEqual(@as(usize, 5), run.items.len);
    try testing.expectEqual(@as(u32, 0), run.items[0].cluster);
    try testing.expectEqual(@as(u32, 4), run.items[4].cluster);
    try testing.expectEqual(@as(u32, 0), run.items[0].face_index);

    // A monospaced face advances 600 of its 1000 units per glyph, which at 14px is 8.4 pixels.
    var total: f32 = 0;
    for (run.items) |glyph| {
        try testing.expectApproxEqAbs(@as(f32, 8.4), glyph.x_advance_px, 0.01);
        total += glyph.x_advance_px;
    }
    try testing.expectApproxEqAbs(42.0, total, 0.01);

    // Shaping again reuses the buffer rather than growing it.
    const capacity = run.capacity;
    try manager.shape("hi", &run);
    try testing.expectEqual(@as(usize, 2), run.items.len);
    try testing.expectEqual(capacity, run.capacity);
}

test "an installed family resolves from the system, and says so" {
    const directories = try systemFontDirectories(testing.allocator, null);
    defer freeAll(testing.allocator, directories);

    var catalog = try Catalog.scan(testing.io, testing.allocator, directories);
    defer catalog.deinit();

    const found = catalog.findFamily("JetBrains Mono");
    if (found == null) {
        // JetBrains Mono is one of Conduit's test fonts on a developer machine, but CI runners
        // install no packages and ship none of ours, so this half of the criterion runs only
        // where the family is installed. Resolution by name out of a directory of files — the rest
        // of it — is covered unconditionally by the catalog test above.
        log.info("JetBrains Mono is not installed here; skipping system resolution", .{});
        return;
    }

    try testing.expect(found.?.path.len > 0);
    try testing.expect(hasFontExtension(found.?.path));
    var canonical_regular_present = false;
    for (catalog.files.items) |file| {
        if (std.ascii.eqlIgnoreCase(file.family, "JetBrains Mono") and
            file.face_style == .regular and
            std.ascii.eqlIgnoreCase(file.style, canonicalStyleName(.regular)))
        {
            canonical_regular_present = true;
        }
    }
    if (canonical_regular_present) {
        try testing.expectEqualStrings(canonicalStyleName(.regular), found.?.style);
    }

    var manager = try Manager.init(testing.allocator, testing.io, .{
        .family = "JetBrains Mono",
        .size = try Size.init(14, 1.0),
    });
    defer manager.deinit();

    try testing.expect(!manager.isFallback());
    try testing.expectEqualStrings(found.?.path, manager.sourcePath());
    try testing.expectEqualStrings("JetBrains Mono", manager.familyName());
    try testing.expect(manager.metrics().cell.width_px > 0);

    // A developer installation usually carries all four JetBrains Mono faces. Exercise every
    // distinct canonical style the catalog actually found, while package-free CI can still run the
    // deterministic synthetic coverage above without an installed font.
    const family_faces = catalog.findFamilyFaces("JetBrains Mono");
    var run: std.ArrayList(ShapedGlyph) = .empty;
    defer run.deinit(testing.allocator);
    for ([_]FaceStyle{ .bold, .italic, .bold_italic }) |style| {
        const style_file = family_faces.get(style) orelse continue;
        if (!std.ascii.eqlIgnoreCase(style_file.style, canonicalStyleName(style))) continue;
        if (std.mem.eql(u8, style_file.path, found.?.path)) continue;

        try manager.shapeForStyle(style, "A", &run);
        try testing.expect(run.items.len > 0);
        const expected_face_index: u32 = @intFromEnum(style);
        for (run.items) |glyph| {
            try testing.expectEqual(expected_face_index, glyph.face_index);
        }
        const entry = try manager.glyphForFace(run.items[0].face_index, run.items[0].glyph_index);
        try testing.expectEqual(expected_face_index, entry.key.face_index);
    }
}

test "coverage ranges merge consecutive codepoints and answer lookups" {
    const ranges = [_]CodepointRange{
        .{ .first = 'A', .last = 'Z' },
        .{ .first = 0x2500, .last = 0x257F },
        .{ .first = 0x4E00, .last = 0x4E00 },
    };
    try testing.expect(rangesContain(&ranges, 'A'));
    try testing.expect(rangesContain(&ranges, 'M'));
    try testing.expect(!rangesContain(&ranges, 'a'));
    try testing.expect(rangesContain(&ranges, 0x2550));
    try testing.expect(rangesContain(&ranges, 0x4E00));
    try testing.expect(!rangesContain(&ranges, 0x4E01));
    try testing.expect(!rangesContain(&.{}, 'A'));

    // The bundled face's own cmap, read the way the catalog reads every system file.
    var library = try Library.init();
    defer library.deinit();
    var face = try Face.openMemory(library.handle, bundled_face, 14);
    defer face.deinit();
    const coverage = try readCoverage(testing.allocator, face.handle);
    defer testing.allocator.free(coverage);
    try testing.expect(coverage.len > 1);
    for (coverage[1..], coverage[0 .. coverage.len - 1]) |range, previous| {
        // Sorted, disjoint and maximal: two ranges never touch.
        try testing.expect(range.first > previous.last + 1);
    }
    try testing.expect(rangesContain(coverage, 'A'));
    try testing.expect(rangesContain(coverage, 0x2500));
    try testing.expect(!rangesContain(coverage, 0x4E2D));
}

test "a colour atlas stores four bytes per pixel" {
    var atlas = try Atlas.initDepth(testing.allocator, 8, 8, 4);
    defer atlas.deinit();
    try testing.expectEqual(@as(usize, 8 * 8 * 4), atlas.pixels.len);
    // Two RGBA pixels per row, padded to a pitch of twelve bytes.
    const data = [_]u8{
        1, 2,  3,  4,  5,  6,  7,  8,  0, 0, 0, 0,
        9, 10, 11, 12, 13, 14, 15, 16, 0, 0, 0, 0,
    };
    const entry = try atlas.insert(.{ .glyph_index = 1 }, .{ .data = &data, .width_px = 2, .height_px = 2, .pitch = 12 }, 0, 0, 2);
    var out: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 16), atlas.copyInto(entry, &out));
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }, &out);
    try testing.expectEqualSlices(u8, &.{ 9, 10, 11, 12, 13, 14, 15, 16 }, atlas.row(entry, 1));
    // A pitch narrower than a row of four-byte pixels is refused.
    try testing.expectError(
        error.BitmapSizeMismatch,
        atlas.insert(.{ .glyph_index = 2 }, .{ .data = &data, .width_px = 2, .height_px = 2, .pitch = 4 }, 0, 0, 2),
    );
}

test "the fallback chain resolves sprites, the primary, the symbols face and then nothing" {
    var manager = try Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try Size.init(14, 1.0),
        .system_fallback = false,
    });
    defer manager.deinit();

    // Box drawing, blocks, braille and Powerline are sprites while built-in symbols are on.
    for ([_]u21{ 0x2500, 0x2588, 0x28FF, 0xE0B0 }) |cp| {
        const hit = manager.resolve(.regular, cp).?;
        try testing.expectEqual(sprite_face, hit.face_index);
        try testing.expectEqual(@as(u32, cp), hit.glyph_index);
    }
    // Ordinary text comes from the primary face, unflagged.
    const letter = manager.resolve(.regular, 'A').?;
    try testing.expectEqual(@as(u32, 0), letter.face_index);
    try testing.expectEqual(manager.glyphIndex('A'), letter.glyph_index);
    // A bold request on a regular-only family keeps the face and carries the synthetic flag.
    try testing.expectEqual(face_flag_bold, manager.resolve(.bold, 'A').?.face_index);

    // A Nerd Font icon comes from the bundled symbols face, which is always in the chain.
    const icon = manager.resolve(.regular, 0xF126).?;
    const icon_extra = manager.extras.items[(icon.face_index & face_id_mask) - extra_base];
    try testing.expectEqual(ExtraKind.symbols, icon_extra.kind);
    // So are the flames, which the sprites deliberately leave to it.
    const flame = manager.resolve(.regular, 0xE0C0).?;
    try testing.expectEqual(ExtraKind.symbols, manager.extras.items[(flame.face_index & face_id_mask) - extra_base].kind);

    // With the system search off, nothing in the chain has a CJK ideograph, and the miss is
    // cached: the second lookup answers from the cache.
    try testing.expect(manager.resolve(.regular, 0x4E2D) == null);
    const cached = manager.resolved.count();
    try testing.expect(manager.resolve(.regular, 0x4E2D) == null);
    try testing.expectEqual(cached, manager.resolved.count());
    // The bundled face is the primary here, so it is not opened a second time as a fallback.
    for (manager.extras.items) |extra| try testing.expect(extra.kind != .bundled);

    // Turning built-in symbols off hands box drawing back to the font, so a user's own Nerd Font
    // can draw it.
    var plain = try Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try Size.init(14, 1.0),
        .system_fallback = false,
        .builtin_symbols = false,
    });
    defer plain.deinit();
    const line = plain.resolve(.regular, 0x2500).?;
    try testing.expectEqual(@as(u32, 0), line.face_index);
    try testing.expectEqual(plain.glyphIndex(0x2500), line.glyph_index);
}

test "configured fallbacks come before system faces, and system faces are found by coverage" {
    const directories = try systemFontDirectories(testing.allocator, null);
    defer freeAll(testing.allocator, directories);
    var catalog = try Catalog.scan(testing.io, testing.allocator, directories);
    defer catalog.deinit();

    // U+273B, Claude Code's spinner glyph, is not in JetBrains Mono.
    const star: u21 = 0x273B;
    var coverer: ?FontFile = null;
    for (catalog.files.items) |file| {
        if (file.covers(star) and !file.color) coverer = file;
    }
    if (coverer == null) {
        log.info("no installed font covers U+273B here; skipping the system half", .{});
        return;
    }

    var manager = try Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try Size.init(14, 1.0),
    });
    defer manager.deinit();
    const hit = manager.resolve(.regular, star).?;
    const extra = manager.extras.items[(hit.face_index & face_id_mask) - extra_base];
    try testing.expectEqual(ExtraKind.system, extra.kind);
    // The face chosen is the first file in preference order whose coverage holds the codepoint.
    var expected: ?u32 = null;
    for (manager.system_order) |index| {
        if (manager.catalog.files.items[index].covers(star)) {
            expected = index;
            break;
        }
    }
    try testing.expectEqual(expected, extra.catalog_index);
    const entry = try manager.glyphForFace(hit.face_index, hit.glyph_index);
    try testing.expect(entry.rect.width > 0 and entry.rect.height > 0);
    // Fitted to one cell: a fallback never changes the grid.
    try testing.expect(entry.rect.width <= manager.metrics().cell.width_px);
    try testing.expect(entry.rect.height <= manager.metrics().cell.height_px);

    // A configured fallback family that covers it wins over the system search.
    var configured = try Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try Size.init(14, 1.0),
        .fallbacks = &.{ "Conduit Family That Does Not Exist", coverer.?.family },
    });
    defer configured.deinit();
    const preferred = configured.resolve(.regular, star).?;
    try testing.expectEqual(
        ExtraKind.configured,
        configured.extras.items[(preferred.face_index & face_id_mask) - extra_base].kind,
    );
    try testing.expectEqual(extra_base, preferred.face_index & face_id_mask);
}

test "a CJK ideograph falls back to a system face and fits two cells" {
    var manager = try Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try Size.init(14, 1.0),
    });
    defer manager.deinit();
    const hit = manager.resolve(.regular, 0x4E2D) orelse {
        log.info("no installed font covers U+4E2D here; skipping", .{});
        return;
    };
    try testing.expect(hit.face_index & face_id_mask >= extra_base);
    const entry = try manager.glyphForFace(wideFace(hit.face_index), hit.glyph_index);
    try testing.expect(!entry.color);
    try testing.expect(entry.rect.width > manager.metrics().cell.width_px / 2);
    try testing.expect(entry.rect.width <= 2 * manager.metrics().cell.width_px);
    try testing.expect(entry.rect.height <= manager.metrics().cell.height_px);
}

test "colour emoji resolve to a colour face and rasterise into the colour atlas" {
    var manager = try Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try Size.init(14, 1.0),
    });
    defer manager.deinit();
    const hit = manager.resolve(.regular, 0x1F600) orelse {
        log.info("no installed font covers U+1F600 here; skipping", .{});
        return;
    };
    if (!manager.isColor(hit.face_index)) {
        log.info("U+1F600 resolved to a monochrome face here; skipping the colour half", .{});
        return;
    }
    // Colour glyphs never take synthetic styles: a bitmap cannot be emboldened.
    try testing.expectEqual(@as(u32, 0), manager.resolve(.bold, 0x1F600).?.face_index & ~face_id_mask);

    const entry = try manager.glyphForFace(wideFace(hit.face_index), hit.glyph_index);
    try testing.expect(entry.color);
    const cell = manager.metrics().cell;
    // Scaled from the font's 109px strike into the two-cell box, centred in it.
    try testing.expect(entry.rect.width > cell.width_px and entry.rect.width <= 2 * cell.width_px);
    try testing.expect(entry.rect.height > cell.height_px / 2 and entry.rect.height <= cell.height_px);
    try testing.expect(entry.bearing_x_px >= 0);

    const pixels = try testing.allocator.alloc(u8, @as(usize, entry.rect.width) * entry.rect.height * 4);
    defer testing.allocator.free(pixels);
    try testing.expectEqual(pixels.len, manager.color_atlas.copyInto(entry, pixels));
    // Real colour: some opaque pixel whose channels differ (a yellow face is not grey).
    var coloured = false;
    var index: usize = 0;
    while (index < pixels.len) : (index += 4) {
        const p = pixels[index..][0..4];
        if (p[3] > 200 and (p[0] != p[1] or p[1] != p[2])) coloured = true;
        // Premultiplied: no channel exceeds its alpha.
        try testing.expect(p[0] <= p[3] and p[1] <= p[3] and p[2] <= p[3]);
    }
    try testing.expect(coloured);
    // The coverage atlas did not receive it.
    try testing.expectEqual(@as(u64, 0), manager.atlas.stats.insertions);

    // An emoji variation selector picks the colour face for a text-default symbol too.
    if (manager.resolveWith(.regular, 0x2764, .emoji)) |heart| {
        try testing.expect(manager.isColor(heart.face_index));
    }
}

test "ligatures shape differently on and off, and can be toggled at runtime" {
    var manager = try Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try Size.init(14, 1.0),
        .system_fallback = false,
    });
    defer manager.deinit();
    try testing.expect(manager.ligatures());

    var on: std.ArrayList(ShapedGlyph) = .empty;
    defer on.deinit(testing.allocator);
    var off: std.ArrayList(ShapedGlyph) = .empty;
    defer off.deinit(testing.allocator);

    for ([_][]const u8{ "=>", "->", "!=" }) |text| {
        manager.setLigatures(true);
        try manager.shapeForStyle(.regular, text, &on);
        manager.setLigatures(false);
        try manager.shapeForStyle(.regular, text, &off);

        // Off: exactly the two plain glyphs a cell-by-cell renderer would draw.
        try testing.expectEqual(@as(usize, 2), off.items.len);
        try testing.expectEqual(manager.glyphIndex(text[0]), off.items[0].glyph_index);
        try testing.expectEqual(manager.glyphIndex(text[1]), off.items[1].glyph_index);
        // On: JetBrains Mono's contextual alternates replace the pair with its ligature, which it
        // draws as a spacer plus one glyph spanning both cells, so the advances still tile the
        // grid while the glyphs are not the plain ones.
        try testing.expect(on.items.len >= 1 and on.items.len <= 2);
        var same = on.items.len == off.items.len;
        if (same) {
            for (on.items, off.items) |a, b| {
                if (a.glyph_index != b.glyph_index) same = false;
            }
        }
        try testing.expect(!same);
        var advance: f32 = 0;
        for (on.items) |g| advance += g.x_advance_px;
        try testing.expectApproxEqAbs(@as(f32, 16.8), advance, 0.01);
    }
}

test "a missing bold or italic face is synthesised, visibly distinct from regular" {
    var manager = try Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try Size.init(20, 1.0),
        .system_fallback = false,
    });
    defer manager.deinit();
    // A vertical bar: shearing it can only lean it, so any extra width is the slant itself.
    const index = manager.glyphIndex('|');
    const regular = try manager.glyphForStyle(.regular, index);
    const bold = try manager.glyphForStyle(.bold, index);
    const italic = try manager.glyphForStyle(.italic, index);
    try testing.expect(manager.atlas.isLive(regular) and manager.atlas.isLive(bold) and manager.atlas.isLive(italic));

    const ink = struct {
        fn sum(atlas: Atlas, entry: Entry) u64 {
            var total: u64 = 0;
            var row: u32 = 0;
            while (row < entry.rect.height) : (row += 1) {
                for (atlas.row(entry, row)) |p| total += p;
            }
            return total;
        }
    }.sum;
    // Emboldening adds ink; shearing leans the stem, so the glyph gets wider at the same height.
    try testing.expect(ink(manager.atlas, bold) > ink(manager.atlas, regular) * 11 / 10);
    try testing.expect(italic.rect.width > regular.rect.width);
    try testing.expect(italic.rect.height + 1 >= regular.rect.height);
    // The three are distinct atlas entries.
    try testing.expect(bold.slot != regular.slot and italic.slot != regular.slot and italic.slot != bold.slot);
}

test "sprites are drawn at exactly one cell, anchored at the cell's top" {
    var manager = try Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try Size.init(14, 1.0),
        .system_fallback = false,
    });
    defer manager.deinit();
    const cell = manager.metrics().cell;
    const entry = try manager.glyphForFace(sprite_face, 0x2502);
    try testing.expectEqual(cell.width_px, entry.rect.width);
    try testing.expectEqual(cell.height_px, entry.rect.height);
    try testing.expectEqual(@as(i32, 0), entry.bearing_x_px);
    // A renderer places a glyph's top at baseline - bearing_y, which is the cell's own top.
    try testing.expectEqual(@as(i32, @intCast(manager.metrics().baseline_px)), entry.bearing_y_px);
    // The vertical line reaches the first and last rows of the cell.
    const x = (cell.width_px - sprite.lineThickness(cell.height_px)) / 2;
    try testing.expectEqual(@as(u8, 255), manager.atlas.row(entry, 0)[x]);
    try testing.expectEqual(@as(u8, 255), manager.atlas.row(entry, cell.height_px - 1)[x]);
    // Shaping a box-drawing cluster reports the sprite face too.
    var run: std.ArrayList(ShapedGlyph) = .empty;
    defer run.deinit(testing.allocator);
    try manager.shapeForStyle(.bold, "\u{2502}", &run);
    try testing.expectEqual(@as(usize, 1), run.items.len);
    try testing.expectEqual(sprite_face, run.items[0].face_index);
}

test "a size or scale change re-rasterises glyphs and sprites at the new pixel size" {
    var at_1x = try Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try Size.init(14, 1.0),
        .system_fallback = false,
    });
    defer at_1x.deinit();
    var at_2x = try Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try Size.init(14, 2.0),
        .system_fallback = false,
    });
    defer at_2x.deinit();

    // Metrics are derived again from the face at the new size, not doubled.
    try testing.expectEqual(@as(u32, 28), at_2x.size_px);
    try testing.expect(at_2x.metrics().cell.height_px + 2 >= 2 * at_1x.metrics().cell.height_px);

    const small = try at_1x.glyph(at_1x.glyphIndex('g'));
    const large = try at_2x.glyph(at_2x.glyphIndex('g'));
    // Roughly twice the bitmap in each dimension...
    try testing.expect(large.rect.width + 2 >= 2 * small.rect.width and large.rect.width <= 2 * small.rect.width + 2);
    try testing.expect(large.rect.height + 2 >= 2 * small.rect.height and large.rect.height <= 2 * small.rect.height + 2);
    // ...but rasterised from the outline at 28px rather than a pixel-doubled copy of the 14px
    // glyph: a doubled copy would have every 2x2 block uniform, and a real rasterisation has
    // anti-aliased edges that land on single pixels.
    var non_uniform_blocks: u32 = 0;
    var y: u32 = 0;
    while (y + 1 < large.rect.height) : (y += 2) {
        const top = at_2x.atlas.row(large, y);
        const bottom = at_2x.atlas.row(large, y + 1);
        var x: usize = 0;
        while (x + 1 < top.len) : (x += 2) {
            if (top[x] != top[x + 1] or top[x] != bottom[x] or top[x] != bottom[x + 1]) non_uniform_blocks += 1;
        }
    }
    try testing.expect(non_uniform_blocks > 4);

    // Sprites follow the new cell exactly, with a stroke drawn for that cell.
    const line_1x = try at_1x.glyphForFace(sprite_face, 0x2500);
    const line_2x = try at_2x.glyphForFace(sprite_face, 0x2500);
    try testing.expectEqual(at_2x.metrics().cell.width_px, line_2x.rect.width);
    try testing.expectEqual(at_2x.metrics().cell.height_px, line_2x.rect.height);
    try testing.expectEqual(at_1x.metrics().cell.width_px, line_1x.rect.width);
    try testing.expect(sprite.lineThickness(line_2x.rect.height) >= sprite.lineThickness(line_1x.rect.height));
}

test "a private-use icon from the bundled symbols face is fitted to one cell" {
    var manager = try Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try Size.init(14, 1.0),
        .system_fallback = false,
    });
    defer manager.deinit();
    const cell = manager.metrics().cell;
    for ([_]u21{ 0xF126, 0xF0068, 0xE0C0 }) |cp| {
        const hit = manager.resolve(.regular, cp).?;
        const entry = try manager.glyphForFace(hit.face_index, hit.glyph_index);
        try testing.expect(entry.rect.width > 0);
        // Inside the cell box: from the cell's left edge to its right, top to bottom.
        try testing.expect(entry.bearing_x_px >= 0);
        try testing.expect(@as(i64, entry.bearing_x_px) + entry.rect.width <= cell.width_px);
        try testing.expect(entry.bearing_y_px <= @as(i32, @intCast(manager.metrics().baseline_px)));
        try testing.expect(@as(i64, manager.metrics().baseline_px) - entry.bearing_y_px + entry.rect.height <= cell.height_px);
    }
}

test "shaping never resizes the face glyphs are rasterised from" {
    // Regression: HarfBuzz's FreeType bridge set the shared face's size to its own scale on the
    // first shape, so every glyph rasterised after any shaped cluster came out at upem/64 pixels
    // (15.6px for JetBrains Mono) instead of the configured size.
    var fresh = try Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try Size.init(14, 2.0),
        .system_fallback = false,
    });
    defer fresh.deinit();
    const unshaped = try fresh.glyph(fresh.glyphIndex('M'));

    var shaped = try Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try Size.init(14, 2.0),
        .system_fallback = false,
    });
    defer shaped.deinit();
    var run: std.ArrayList(ShapedGlyph) = .empty;
    defer run.deinit(testing.allocator);
    try shaped.shape("a => b", &run);
    try shaped.shapeForStyle(.bold, "x", &run);
    const after = try shaped.glyph(shaped.glyphIndex('M'));
    try testing.expectEqual(unshaped.rect.width, after.rect.width);
    try testing.expectEqual(unshaped.rect.height, after.rect.height);
    // And the size is the configured one: JetBrains Mono's cap height is 730 of 1000 units, so a
    // 28px 'M' stands about 20px tall.
    try testing.expect(after.rect.height >= 19 and after.rect.height <= 22);
}

fn appendCatalogFile(
    catalog: *Catalog,
    path: []const u8,
    family: []const u8,
    fixed_width: bool,
    color: bool,
    coverage: []const CodepointRange,
) !void {
    try appendSyntheticFont(catalog, path, family, "Regular", .regular);
    const file = &catalog.files.items[catalog.files.items.len - 1];
    file.coverage = try catalog.gpa.dupe(CodepointRange, coverage);
    file.fixed_width = fixed_width;
    file.color = color;
}

test "the monospace family list is sorted, de-duplicated, bounded and text faces only" {
    var catalog: Catalog = .{ .gpa = testing.allocator };
    defer catalog.deinit();
    const latin = [_]CodepointRange{.{ .first = 0x20, .last = 0x7E }};
    const symbols = [_]CodepointRange{.{ .first = 0xE000, .last = 0xF8FF }};
    try appendCatalogFile(&catalog, "/f/zed.ttf", "Zed Mono", true, false, &latin);
    try appendCatalogFile(&catalog, "/f/dejavu.ttf", "DejaVu Sans Mono", true, false, &latin);
    try appendCatalogFile(&catalog, "/f/dejavu-bold.ttf", "DejaVu Sans Mono", true, false, &latin);
    try appendCatalogFile(&catalog, "/f/dejavu-case.ttf", "dejavu sans mono", true, false, &latin);
    try appendCatalogFile(&catalog, "/f/sans.ttf", "Proportional Sans", false, false, &latin);
    try appendCatalogFile(&catalog, "/f/emoji.ttf", "Colour Emoji", true, true, &latin);
    try appendCatalogFile(&catalog, "/f/symbols.ttf", "Symbols Mono", true, false, &symbols);
    try appendCatalogFile(&catalog, "/f/agave.ttf", "agave", true, false, &latin);

    const all = try catalog.monospaceFamilies(testing.allocator, 16);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 3), all.len);
    try testing.expectEqualStrings("agave", all[0]);
    try testing.expectEqualStrings("DejaVu Sans Mono", all[1]);
    try testing.expectEqualStrings("Zed Mono", all[2]);

    const bounded = try catalog.monospaceFamilies(testing.allocator, 2);
    defer testing.allocator.free(bounded);
    try testing.expectEqual(@as(usize, 2), bounded.len);
    try testing.expectEqualStrings("DejaVu Sans Mono", bounded[1]);
}

test "a configured style family replaces the derived style face" {
    const directories = try systemFontDirectories(testing.allocator, null);
    defer freeAll(testing.allocator, directories);
    var catalog = try Catalog.scan(testing.io, testing.allocator, directories);
    defer catalog.deinit();
    if (catalog.findFamily("DejaVu Sans Mono") == null) {
        log.info("DejaVu Sans Mono is not installed here; skipping", .{});
        return;
    }

    var manager = try Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try Size.init(14, 1.0),
        .bold_family = "DejaVu Sans Mono",
        .italic_family = "Conduit Family That Does Not Exist",
        .system_fallback = false,
    });
    defer manager.deinit();
    // The primary stays the bundled face; only bold comes from the configured family.
    try testing.expect(manager.isFallback());
    try testing.expectEqualStrings("DejaVu Sans Mono", manager.styleFamilyName(.bold));
    // A family that is not installed keeps the derived (here synthesised) style.
    try testing.expectEqualStrings(manager.familyName(), manager.styleFamilyName(.italic));
    try testing.expect(manager.glyphIndexForStyle(.bold, 'M') != 0);
}

test "the fallback count reports only installed configured families" {
    var manager = try Manager.init(testing.allocator, testing.io, .{
        .family = "",
        .size = try Size.init(14, 1.0),
        .fallbacks = &.{"Conduit Family That Does Not Exist"},
        .builtin_symbols = false,
        .system_fallback = false,
    });
    defer manager.deinit();
    try testing.expectEqual(@as(usize, 0), manager.configuredFallbackCount());
    try testing.expect(!manager.builtinSymbols());
}
