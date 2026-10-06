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
//! ## What v1 resolves, and what it does not
//!
//! v1 resolves the configured family's four styles, falling back to its primary face for any style
//! that is absent. When no installed family matches, the bundled JetBrains Mono regular face backs
//! every style. All distinct faces rasterise into one atlas, and the primary regular resolution is
//! the sole source of cell metrics. Deliberately absent, and belonging to TASK-39 (font manager
//! v2): fallback *chains* across families, colour emoji, symbol/block/Nerd Font coverage and
//! ligature toggling. `CONDUIT.md` §5 puts font manager v2 after v0.1, so a glyph v1 cannot resolve
//! is a known v0.1 gap rather than a promise.
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
/// handing a face from one to the other would not compile.
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

    /// Open a face from a file. Every failure here is a font file that is not the face it claims to
    /// be, which is external input: it is returned, never asserted.
    fn open(library: ft.FT_Library, path: [:0]const u8, size_px: u32) !Face {
        var handle: ft.FT_Face = undefined;
        if (ft.FT_New_Face(library, path.ptr, 0, &handle) != 0) return error.FontFileUnreadable;
        errdefer _ = ft.FT_Done_Face(handle);
        return sized(handle, size_px);
    }

    /// Open a face from bytes already in memory: how the bundled fallback is loaded, and how a
    /// caller that fetched a font itself would load one.
    fn openMemory(library: ft.FT_Library, bytes: []const u8, size_px: u32) !Face {
        var handle: ft.FT_Face = undefined;
        if (ft.FT_New_Memory_Face(library, bytes.ptr, @intCast(bytes.len), 0, &handle) != 0) {
            return error.FontFileUnreadable;
        }
        errdefer _ = ft.FT_Done_Face(handle);
        return sized(handle, size_px);
    }

    fn sized(handle: ft.FT_Face, size_px: u32) !Face {
        // Zero width means "same as the height", which is what a monospaced face wants.
        if (ft.FT_Set_Pixel_Sizes(handle, 0, size_px) != 0) return error.UnsupportedPixelSize;
        return .{ .handle = handle };
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
};

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
        try self.files.append(self.gpa, .{
            .path = owned_path,
            .family = owned_family,
            .style = owned_style,
            .face_style = classifyStyle(handle.*.style_flags),
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

    pub fn deinit(self: *Catalog) void {
        for (self.files.items) |file| {
            self.gpa.free(file.path);
            self.gpa.free(file.family);
            self.gpa.free(file.style);
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
    /// One byte of coverage per pixel, row-major, `width_px * height_px` long.
    pixels: []u8,
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
        if (width_px == 0 or height_px == 0) return error.AtlasSizeOutOfRange;
        const count = std.math.mul(usize, width_px, height_px) catch return error.AtlasSizeOutOfRange;
        const pixels = try gpa.alloc(u8, count);
        @memset(pixels, 0);

        var self: Atlas = .{
            .gpa = gpa,
            .width_px = width_px,
            .height_px = height_px,
            .pixels = pixels,
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
        const start = (@as(usize, entry.rect.y + index) * self.width_px) + entry.rect.x;
        return self.pixels[start..][0..entry.rect.width];
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
        const count = @as(usize, entry.rect.width) * entry.rect.height;
        if (dest.len < count) return 0;
        for (0..entry.rect.height) |index| {
            const row_len = entry.rect.width;
            const from = (@as(usize, entry.rect.y + index) * self.width_px) + entry.rect.x;
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
        if (bitmap.pitch < bitmap.width_px) return error.BitmapSizeMismatch;
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
        for (0..rect.height) |line| {
            const from = @as(usize, line) * bitmap.pitch;
            const to = (@as(usize, rect.y + line) * self.width_px) + rect.x;
            @memcpy(self.pixels[to..][0..rect.width], bitmap.data[from..][0..rect.width]);
        }
    }

    fn clear(self: *Atlas, rect: Rect) void {
        for (0..rect.height) |line| {
            const to = (@as(usize, rect.y + line) * self.width_px) + rect.x;
            @memset(self.pixels[to..][0..rect.width], 0);
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
pub const Request = struct {
    /// The configured family. Empty means the bundled face, which is also what a family that is not
    /// installed gets.
    family: []const u8 = "",
    size: Size,
    /// The user's home directory, when the caller knows it. See `systemFontDirectories`.
    home_dir: ?[]const u8 = null,
    atlas_width_px: u32 = 1024,
    atlas_height_px: u32 = 1024,

    pub const Error = error{AtlasSizeOutOfRange};
};

/// The font manager: up to four distinct style faces and shapers, one shared buffer and one atlas.
///
/// A `Manager` owns everything it reports. `deinit` must run before the allocator that built it goes
/// away; every other module holds it behind a pointer rather than by value.
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
    face_metrics: Metrics,
    /// The resolved size in device pixels: what HarfBuzz's font units are scaled by.
    size_px: u32,
    /// The family actually loaded, from the face's own name table. Owned.
    family: []u8,
    /// Where it came from: a system path, or the bundled asset's path. Owned.
    source_path: []u8,
    /// Whether the configured family was missing and the bundled face is standing in for it.
    used_fallback: bool,

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

    /// Resolve a family, open it, and build an atlas for it.
    ///
    /// Resolution never fails for want of a font: a family that is not installed falls back to the
    /// bundled face and logs it, because a terminal full of boxes because a family name was
    /// misspelled is worse than a terminal in the wrong font. Everything else — a face FreeType will
    /// not open, an atlas that will not allocate, running out of memory — is returned to the caller.
    pub fn init(gpa: Allocator, io: Io, request: Request) Error!Manager {
        const size_px = request.size.pixels();

        var library = try Library.init();
        errdefer library.deinit();

        const directories = try systemFontDirectories(gpa, request.home_dir);
        defer freeAll(gpa, directories);

        var catalog = try Catalog.scan(io, gpa, directories);
        defer catalog.deinit();

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
            // HarfBuzz allocates and can fail doing so. An allocation failure is a real outcome on
            // a loaded machine, not a programmer invariant to unwrap.
            const font: *hb.hb_font_t = hb.hb_ft_font_create_referenced(face.handle) orelse
                return error.OutOfMemory;
            fonts[index] = font;

            // HarfBuzz reports positions in whatever scale its font carries. Using the face's own
            // em size makes the conversion to pixels below identical for every style.
            const upem: i32 = @intCast(face.unitsPerEm());
            hb.hb_font_set_scale(font, upem, upem);
            hb.hb_font_set_ppem(font, @intCast(size_px), @intCast(size_px));
        }

        const buffer: *hb.hb_buffer_t = hb.hb_buffer_create() orelse return error.OutOfMemory;
        errdefer hb.hb_buffer_destroy(buffer);

        const atlas = try Atlas.init(gpa, request.atlas_width_px, request.atlas_height_px);
        const face_metrics = resolution.faces[styleIndex(.regular)].?.metrics();

        return .{
            .gpa = gpa,
            .library = library,
            .faces = resolution.faces,
            .fonts = fonts,
            .buffer = buffer,
            .atlas = atlas,
            .face_metrics = face_metrics,
            .size_px = size_px,
            .family = resolution.family,
            .source_path = resolution.source_path,
            .used_fallback = resolution.used_fallback,
        };
    }

    /// Release the atlas, shared buffer, every HarfBuzz font and face, the library and all strings.
    pub fn deinit(self: *Manager) void {
        self.atlas.deinit();
        hb.hb_buffer_destroy(self.buffer);
        for (&self.fonts) |*maybe_font| {
            if (maybe_font.*) |font| hb.hb_font_destroy(font);
        }
        for (&self.faces) |*maybe_face| {
            if (maybe_face.*) |*face| face.deinit();
        }
        self.library.deinit();
        self.gpa.free(self.family);
        self.gpa.free(self.source_path);
        self.* = undefined;
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

    /// The cell metrics of the loaded face.
    pub fn metrics(self: Manager) Metrics {
        return self.face_metrics;
    }

    /// The glyph index for a codepoint, or 0 when the face has no glyph for it.
    pub fn glyphIndex(self: Manager, codepoint: u21) u32 {
        return self.glyphIndexForStyle(.regular, codepoint);
    }

    /// The glyph index for a codepoint in a requested style, or 0 when its resolved face has none.
    pub fn glyphIndexForStyle(self: Manager, style: FaceStyle, codepoint: u21) u32 {
        const face_index = self.faceIndexForStyle(style);
        return ft.FT_Get_Char_Index(self.faces[face_index].?.handle, codepoint);
    }

    /// The atlas coverage mask, for the renderer to upload as a texture.
    pub fn atlasPixels(self: Manager) []const u8 {
        return self.atlas.pixels;
    }

    /// Shape a run of text into glyphs, appending them to `out`.
    ///
    /// `out` belongs to the caller: shaping clears it and keeps its capacity, so a frame's runs
    /// allocate nothing after the first. Positions are pixels at the resolved size.
    pub fn shape(self: *Manager, text: []const u8, out: *std.ArrayList(ShapedGlyph)) Error!void {
        return self.shapeForStyle(.regular, text, out);
    }

    /// Shape with a requested style, falling back to the primary face when that style is absent.
    pub fn shapeForStyle(
        self: *Manager,
        style: FaceStyle,
        text: []const u8,
        out: *std.ArrayList(ShapedGlyph),
    ) Error!void {
        out.clearRetainingCapacity();
        if (text.len == 0) return;

        const face_index = self.faceIndexForStyle(style);
        const face = self.faces[face_index].?;
        const font = self.fonts[face_index].?;

        hb.hb_buffer_clear_contents(self.buffer);
        _ = hb.hb_buffer_add_utf8(self.buffer, text.ptr, @intCast(text.len), 0, @intCast(text.len));
        hb.hb_buffer_guess_segment_properties(self.buffer);
        hb.hb_shape(font, self.buffer, null, 0);

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
            try out.append(self.gpa, .{
                .glyph_index = infos[index].codepoint,
                .face_index = @intCast(face_index),
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

    /// Rasterise a glyph in a requested style, falling back to the primary face when unavailable.
    pub fn glyphForStyle(self: *Manager, style: FaceStyle, glyph_index: u32) Error!Entry {
        return self.glyphForFace(@intCast(self.faceIndexForStyle(style)), glyph_index);
    }

    /// Rasterise a glyph from the actual face slot reported by `ShapedGlyph.face_index`.
    pub fn glyphForFace(self: *Manager, face_index: u32, glyph_index: u32) Error!Entry {
        if (face_index >= face_style_count or self.faces[face_index] == null) {
            return error.InvalidFaceIndex;
        }
        const key: Key = .{ .glyph_index = glyph_index, .face_index = face_index };
        if (self.atlas.find(key)) |entry| return entry;

        const face = self.faces[face_index].?;
        if (ft.FT_Load_Glyph(face.handle, glyph_index, ft.FT_LOAD_RENDER) != 0) {
            return error.GlyphLoadFailed;
        }
        const slot = face.handle.*.glyph.*;
        const bitmap = slot.bitmap;
        // A colour glyph (CBDT, sbix, COLR) rasterises as something other than coverage, and v1 has
        // no renderer for it. Reported rather than drawn as garbage; TASK-39 replaces this with real
        // colour rendering.
        if (bitmap.pixel_mode != ft.FT_PIXEL_MODE_GRAY) return error.UnsupportedPixelFormat;

        const width_px: u32 = if (bitmap.width < 0) 0 else @intCast(bitmap.width);
        const height_px: u32 = if (bitmap.rows < 0) 0 else @intCast(bitmap.rows);
        const pitch: u32 = if (bitmap.pitch < 0) 0 else @intCast(bitmap.pitch);
        const advance_px: u32 = @intCast(@max(@divTrunc(slot.advance.x, 64), 0));

        // FreeType's own buffer is the source, pitch and all: copying it out per glyph would be an
        // allocation on the hot path, and the atlas copy below is the one that persists.
        const source: []const u8 = if (bitmap.buffer == null)
            &.{}
        else
            @as([*]const u8, @ptrCast(bitmap.buffer))[0 .. @as(usize, pitch) * height_px];

        return self.atlas.insert(key, .{
            .data = source,
            .width_px = width_px,
            .height_px = height_px,
            .pitch = pitch,
        }, slot.bitmap_left, slot.bitmap_top, advance_px);
    }

    fn faceIndexForStyle(self: Manager, style: FaceStyle) usize {
        const requested = styleIndex(style);
        return if (self.faces[requested] != null) requested else styleIndex(.regular);
    }
};

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

/// Pick the primary face and any distinct exact-style faces from the configured family.
fn resolveFaces(
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
        try testing.expectEqual(@as(u32, 0), entry.key.face_index);
    }

    var run: std.ArrayList(ShapedGlyph) = .empty;
    defer run.deinit(testing.allocator);
    try manager.shapeForStyle(.bold_italic, "A", &run);
    try testing.expectEqual(@as(usize, 1), run.items.len);
    try testing.expectEqual(@as(u32, 0), run.items[0].face_index);
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
