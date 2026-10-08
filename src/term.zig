//! Conduit's terminal module: the terminal engine's boundary, and the values
//! that cross it.
//!
//! `term` owns the wrapper around the pinned `ghostty-vt` Zig module — terminal
//! construction, feeding PTY bytes through a `Stream`, resize, damage
//! tracking, cell and selection access, and Conduit's own style describer
//! (decision-1). It is the only module that imports `ghostty-vt` and the
//! pinned Oniguruma C seam, so both third-party APIs stay in one file.
//!
//! It never renders, never loads a font, never owns a PTY and never takes a UI
//! concern. It may depend on the `ghostty-vt` package, the statically bundled
//! Oniguruma seam and `pty`, and on no other Conduit module: a `Pty` handle may
//! be *passed* to it so that a resize moves both sides together, but `term`
//! never stores one and never destroys one — the session layer owns the
//! child's lifetime (`CONDUIT.md` P8).
//!
//! ## What crosses the boundary
//!
//! Nothing of Ghostty's. Bytes go in through `feed`; the grid comes back out
//! as Conduit's own `Cell`, `Style`, `Cursor`, `KeyModes`, `Damage` and `Event`
//! values. A caller of this module never names `ghostty_vt.page.Cell` or any
//! other upstream type, so an upstream API change lands in this one file
//! instead of in `render` and `input`.
//!
//! ## Device responses: the seam out to the child
//!
//! A running program asks the terminal questions — a primary or secondary
//! device attributes query, a colour query, a cursor position report, an
//! XTWINOPS size query, XTVERSION — and expects the answer on its own input.
//! Those answers are produced *inside* a parse, by the engine, at moments
//! Conduit does not choose.
//!
//! `term` never writes them anywhere. `Pty.write` is single-owner
//! (`pty.zig`), and a parse that wrote to the PTY from inside the parser would
//! break that ownership *and* block the parser on the child's input buffer,
//! which is exactly the IO the render thread must never wait on. Instead every
//! answer is appended to a fixed-size queue this terminal owns, and the
//! owning thread drains it and writes it out:
//!
//!     // bytes from the child, on the thread that owns the terminal
//!     const got = child.takeBytes(&in);
//!     if (got != 0) terminal.feed(in[0..got]);
//!
//!     // answers back out, on the thread that owns the PTY's write side
//!     const owed = terminal.takeResponses(&out);
//!     if (owed != 0) _ = child.write(out[0..owed]);
//!
//! `takeResponses` is the mirror of `Pty.takeBytes` on purpose: it copies
//! into a buffer the caller already owns, never blocks, never allocates, and
//! never drops a byte it has not handed over. `droppedResponses` says what a
//! flood of queries larger than the queue cost.
//!
//! ## Keys: the seam back out to the child
//!
//! A key press goes the other way, and the same rule applies to it: `input`
//! describes the press in Conduit's own `KeyPress`, and `encodeKey` hands it
//! to Ghostty's encoder, which reads the modes this terminal is in. Conduit
//! writes no key table of its own, because a terminal's key encoding is a
//! protocol rather than a preference, and the protocol keeps growing — the
//! Kitty keyboard protocol is eight escape sequences wide on its own. What
//! Conduit does own is the *intent* layer above it: which key was pressed and
//! what that means to a binding.
//!
//! The one thing Conduit adds is `composing`. While an input method is
//! composing, the encoder writes nothing at all, so a preedit can never reach
//! the child — a property of the encoder rather than a rule `input` has to
//! remember, and one the tests below pin down.
//!
//! ## Threads
//!
//! One owner: the thread that called `init`, which is the render/UI (main)
//! thread in Conduit (`docs/architecture.md` §5, `AGENTS.md`). In Conduit that
//! is also the thread that owns the PTY, so the parse that produces an answer
//! and the write that delivers it are the same thread, and nothing in this
//! module takes a lock.
//!
//! The rule is enforced rather than documented. Every method that touches the
//! grid, the parser, the modes or the response queue goes through `claim`,
//! which compares the calling thread against the one recorded by `init`. A
//! call from any other thread is *refused* and counted in
//! `ownershipViolations`, not allowed to run: two threads mutating one parser
//! produce a terminal that reports corruption, which is far harder to diagnose
//! than a log line naming the mistake. `ownedByCallingThread` exposes the check
//! so a caller can assert it in its own code, and so a test can prove that a
//! second thread really is a second thread.
//!
//! A lock would be the wrong tool here, and it is worth saying why. A mutex
//! makes two threads that both intend to mutate take turns; it does not make a
//! program that mutates from two threads correct, because the bytes still
//! interleave into one parser in whatever order the scheduler chose. Refusing
//! the second thread turns that into a logged, counted bug at the point it is
//! made instead of a grid that is subtly wrong much later. The read-only
//! accessors that run once per cell per frame (`cell`, `cursor`, `damage`,
//! ...) are deliberately not checked, because a thread-id comparison per cell
//! would cost more than the read it protects; they are safe for the same
//! reason the writes are — exactly one thread mutates, and it is this one.
//!
//! The `std.Io` passed to `init` is *borrowed* for the terminal's lifetime —
//! the engine uses it only for the features that touch the filesystem (Kitty
//! graphics file transfer), and `term` itself never calls it.
//!
//! The parser lives inside the `Terminal`, so bytes must be fed through the
//! same value in the order they arrive: that is what lets a sequence split
//! across two reads still parse as one sequence.
//!
//! ## Memory
//!
//! `init`, `resize` and `refresh` take Conduit's allocator explicitly, and
//! `deinit` is given the same one. Every byte Ghostty holds for the terminal —
//! pages, scrollback, the parser, the cached grid view — is owned by the
//! `Terminal` value and is freed by `deinit`. `std.testing.allocator` in the
//! tests below makes a leak fail the test.
//!
//! The value types (`Cell`, `Cursor`, `Style`, `Damage`, `Event`) allocate
//! nothing; they borrow from the terminal and each says how long it stays
//! valid. `init` is in place rather than a constructor returning a value,
//! because it wires Ghostty's effect callbacks to the address it is given:
//!
//!     var terminal: Terminal = undefined;
//!     try terminal.init(io, alloc, .{ .cols = 80, .rows = 24 });
//!     defer terminal.deinit(alloc);
//!
//! so the `Terminal` must keep that address for its whole life and must not be
//! copied after it is initialised.

const std = @import("std");
const builtin = @import("builtin");
const ghostty_vt = @import("ghostty-vt");
const oniguruma = @import("oniguruma-c");
const pty = @import("pty");

const Allocator = std.mem.Allocator;

/// The log scope for terminal state diagnostics.
///
/// The same four calls as `std.log.scoped(.term)`, which is where every line
/// goes. In a test build each line is also kept by `log_witness`, so a test
/// can assert what this module said and, more to the point, what it did not:
/// terminal text such as a working directory never reaches a log line.
pub const log = struct {
    const scoped = std.log.scoped(.term);

    pub fn err(comptime format: []const u8, args: anytype) void {
        @branchHint(.cold);
        witness(.err, format, args);
        scoped.err(format, args);
    }

    pub fn warn(comptime format: []const u8, args: anytype) void {
        witness(.warn, format, args);
        scoped.warn(format, args);
    }

    pub fn info(comptime format: []const u8, args: anytype) void {
        witness(.info, format, args);
        scoped.info(format, args);
    }

    pub fn debug(comptime format: []const u8, args: anytype) void {
        witness(.debug, format, args);
        scoped.debug(format, args);
    }

    fn witness(comptime level: std.log.Level, comptime format: []const u8, args: anytype) void {
        if (comptime !builtin.is_test) return;
        log_witness.note(level, format, args);
    }
};

/// Every line `log` wrote on this thread, as text, in test builds only.
///
/// Per thread because a test reads what its own calls logged, and another
/// thread's refusal warning (see `claim`) is not one of them. A line that does
/// not fit is not kept and `overflowed` says so, so a test can tell "nothing
/// was logged" from "the witness ran out of room".
const LogWitness = struct {
    buffer: [16 * 1024]u8 = undefined,
    len: usize = 0,
    overflowed: bool = false,

    fn note(self: *LogWitness, comptime level: std.log.Level, comptime format: []const u8, args: anytype) void {
        var writer: std.Io.Writer = .fixed(self.buffer[self.len..]);
        writer.print(level.asText() ++ ": " ++ format ++ "\n", args) catch {
            self.overflowed = true;
            return;
        };
        self.len += writer.end;
    }

    fn text(self: *const LogWitness) []const u8 {
        return self.buffer[0..self.len];
    }

    fn clear(self: *LogWitness) void {
        self.len = 0;
        self.overflowed = false;
    }
};

threadlocal var log_witness: if (builtin.is_test) LogWitness else void = if (builtin.is_test) .{} else {};

/// The upstream types this module wraps. Named once, here, so the rest of the
/// file reads as Conduit code with one clearly marked seam.
const Vt = struct {
    const Terminal = ghostty_vt.Terminal;
    const Stream = ghostty_vt.TerminalStream;
    const Handler = ghostty_vt.TerminalStream.Handler;
    const SemanticPrompt = ghostty_vt.TerminalStream.Handler.SemanticPrompt;
    /// The payload of upstream's `desktop_notification` effect, named through
    /// the effect's own signature so the seam has one spelling.
    const DesktopNotification = @typeInfo(@typeInfo(@typeInfo(@FieldType(Handler.Effects, "desktop_notification")).optional.child).pointer.child).@"fn".params[1].type.?;
    const RenderState = ghostty_vt.RenderState;
    const Style = ghostty_vt.Style;
    const Color = ghostty_vt.Style.Color;
    const CursorStyle = ghostty_vt.Screen.CursorStyle;
    const KeyEncodeOptions = ghostty_vt.input.KeyEncodeOptions;
    const DeviceAttributes = ghostty_vt.device_attributes;
    const SizeReport = ghostty_vt.size_report.Size;
    const FocusEvent = ghostty_vt.input.FocusEvent;
    const encodeFocus = ghostty_vt.input.encodeFocus;
    // The key encoder itself, and the three values it takes. Upstream, a key
    // event names a physical key by the W3C code value; Conduit names the keys
    // a terminal has to tell apart (below) and hands the character over as the
    // encoder's own UTF-8 field, which is the same shape Ghostty's own
    // apprts produce.
    const KeyEvent = ghostty_vt.input.KeyEvent;
    const KeyMods = ghostty_vt.input.KeyMods;
    const VtKey = ghostty_vt.input.Key;
    const encodeKey = ghostty_vt.input.encodeKey;
    // The mouse encoder, for the same reason as the key encoder above: a
    // terminal's report encoding is a protocol, and the protocol is upstream's.
    const MouseEncodeOptions = ghostty_vt.input.MouseEncodeOptions;
    const MouseEncodeEvent = ghostty_vt.input.MouseEncodeEvent;
    const MouseButton = ghostty_vt.input.MouseButton;
    const encodeMouse = ghostty_vt.input.encodeMouse;
    const ClipboardContent = ghostty_vt.clipboard.Content;
    const ClipboardLocation = ghostty_vt.clipboard.Location;
    const ClipboardRead = ghostty_vt.clipboard.Read;
    const ClipboardWrite = ghostty_vt.clipboard.Write;
    const isTextMime = ghostty_vt.clipboard.isTextMime;
    const codepointWidth = ghostty_vt.unicode.codepointWidth;
    const graphemeWidth = ghostty_vt.unicode.graphemeWidth;

    // Full-scrollback search. The wrapper below keeps the upstream search,
    // formatter and highlight representations on this side of the boundary;
    // callers only see Conduit's bounded storage and absolute coordinates.
    const Search = ghostty_vt.search.Terminal;
    const Highlight = ghostty_vt.highlight.Flattened;
    const PageFormatter = ghostty_vt.formatter.PageFormatter;
    const Page = ghostty_vt.Page;

    // Selection. Upstream owns the gesture state machine, the pins, and the
    // word/line selection it computes from them, so every one of these is
    // reached through the module rather than reimplemented here.
    const SelectionGesture = ghostty_vt.SelectionGesture;
    const Selection = ghostty_vt.Selection;
    const Coordinate = ghostty_vt.Coordinate;
    const Pin = ghostty_vt.Pin;
};

/// The terminal-cell width of one Unicode codepoint under the pinned
/// terminal engine's width rules: zero for controls and combining marks, one
/// for narrow codepoints and two for wide codepoints.
pub fn codepointWidth(codepoint: u21) u2 {
    return Vt.codepointWidth(codepoint);
}

/// The size of the first grapheme cluster in a codepoint slice.
///
/// `len` is the number of codepoints in that first cluster, not a byte count.
/// `width` is the cluster's display width in terminal cells: zero, one or two.
/// This is Conduit's value so callers never depend on an upstream type.
pub const GraphemeMeasure = struct {
    /// Codepoints consumed by the first grapheme cluster.
    len: usize,
    /// Terminal cells occupied by that cluster: zero, one or two.
    width: u2,
};

/// Measure the first complete grapheme cluster in `codepoints` using the same
/// segmentation and width rules as terminal output.
pub fn graphemeWidth(codepoints: []const u21) GraphemeMeasure {
    const measured = Vt.graphemeWidth(u21, codepoints);
    return .{ .len = measured.len, .width = measured.width };
}

/// Borrowed by every `Cell` that has no grapheme tail. A `[]const u21` has to
/// point somewhere; this is somewhere.
const no_grapheme: [0]u21 = .{};

/// Encode one scalar from terminal-owned state, dropping a value that cannot
/// be UTF-8 rather than letting impossible/corrupt cached state crash the app.
fn encodeVisibleScalar(encoded: *[4]u8, codepoint: u21) usize {
    return std.unicode.utf8Encode(codepoint, encoded) catch 0;
}

test "Unicode width wrappers preserve pinned terminal semantics" {
    const testing = std.testing;

    try testing.expectEqual(@as(u2, 1), codepointWidth('A'));
    try testing.expectEqual(@as(u2, 0), codepointWidth(0x0301));
    try testing.expectEqual(@as(u2, 2), codepointWidth(0x4e00));
    try testing.expectEqual(@as(u2, 2), codepointWidth(0xff21));

    try testing.expectEqual(
        GraphemeMeasure{ .len = 0, .width = 0 },
        graphemeWidth(&.{}),
    );
    try testing.expectEqual(
        GraphemeMeasure{ .len = 2, .width = 1 },
        graphemeWidth(&.{ 'e', 0x0301, 'x' }),
    );
    try testing.expectEqual(
        GraphemeMeasure{ .len = 2, .width = 2 },
        graphemeWidth(&.{ 0x2764, 0xfe0f }),
    );
    try testing.expectEqual(
        GraphemeMeasure{ .len = 5, .width = 2 },
        graphemeWidth(&.{ 0x1f468, 0x200d, 0x1f469, 0x200d, 0x1f467 }),
    );
    try testing.expectEqual(
        GraphemeMeasure{ .len = 2, .width = 2 },
        graphemeWidth(&.{ 0x1f1e6, 0x1f1e7, 0x1f1e8 }),
    );
}

/// How many 64-bit words a selection bitmask of `cols` by `rows` cells takes.
///
/// One word per 64 columns, per row, rounded up: a grid is rarely a multiple of
/// 64 columns wide, and rounding down would drop the last cell of every row.
fn selectionWords(cols: u16, rows: u16) usize {
    const per_row = (@as(usize, cols) + 63) / 64;
    return per_row * @as(usize, rows);
}

/// The most cursor keys one wheel event may put on a child's input.
///
/// A trackpad flinging its way through a thousand rows of momentum in one
/// event would otherwise put three thousand escape sequences into a program
/// that is trying to read them, from the render thread, which is the one place
/// in Conduit that must not wait. The cap is a bound rather than a policy: the
/// alternative to dropping the tail is a write that blocks.
const max_forwarded_keys: usize = 32;

/// The renderer geometry Ghostty's mouse encoder wants, built without naming
/// it.
///
/// `lib_vt` exports the encoder and its options but not the coordinate type
/// those options hold, because that type belongs to Ghostty's renderer and the
/// `vt` module is terminal state only (decision-1). Reconstructing it from the
/// field names keeps the seam in one function rather than reaching past the
/// module boundary, and a field Ghostty renames becomes a compile error here
/// instead of a mouse report at the wrong coordinates.
fn mouseEncodeSize(pointer: Pointer) @FieldType(Vt.MouseEncodeOptions, "size") {
    return .{
        .screen = .{
            .width = pointer.surface_width_px,
            .height = pointer.surface_height_px,
        },
        .cell = .{
            .width = pointer.cell_width_px,
            .height = pointer.cell_height_px,
        },
        // Conduit has no padding around the grid: the window's cells fill it.
        .padding = .{},
    };
}

/// The event mode the encoder is told, derived from the terminal's modes
/// rather than from the engine's own `flags.mouse_event`.
///
/// Ghostty's `MouseEncodeOptions.fromTerminal` reads `flags.mouse_event`, and
/// upstream clears that flag on *any* of the three DECRSTs — including
/// `?1003l`, which `tmux` sends straight after `?1002h` and which means "stop
/// tracking motion with no button held", not "stop tracking drags". The mode
/// itself is still set, so `mouseTracking` correctly reports `.drag`; the
/// encoder, handed `.none`, then drops every report the user makes. tmux's
/// status bar was dead until this was read from the modes instead.
///
/// The cost of doing it here rather than patching the engine is one switch, and
/// the benefit is that the mode the encoder filters with and the mode Conduit
/// reports cannot drift apart: both are `mouseTracking`.
fn mouseEncodeEvent(tracking: MouseTracking) @FieldType(Vt.MouseEncodeOptions, "event") {
    return switch (tracking) {
        .none => .none,
        .x10 => .x10,
        .press => .normal,
        .drag => .button,
        .any => .any,
    };
}

/// The dimensions of a terminal grid, in cells.
///
/// A grid always has at least one column and one row: there is no zero-sized
/// terminal, and a zero would reach Ghostty's own size type and leave it
/// dividing by it. The invariant is therefore enforced where the value is
/// built, rather than assumed by every reader.
pub const GridSize = struct {
    /// Columns, left to right.
    cols: u16,
    /// Rows, top to bottom.
    rows: u16,

    /// Why a grid cannot be built.
    pub const Error = error{EmptyGrid};

    /// A grid of `cols` by `rows` cells, or `error.EmptyGrid` if either
    /// dimension is zero.
    pub fn init(cols: u16, rows: u16) Error!GridSize {
        if (cols == 0 or rows == 0) return error.EmptyGrid;
        return .{ .cols = cols, .rows = rows };
    }

    /// How many cells the grid holds. The product of two u16 always fits a
    /// u32, so this cannot overflow however large the grid is.
    pub fn cells(self: GridSize) u32 {
        return @as(u32, self.cols) * @as(u32, self.rows);
    }
};

/// A cell position in the grid. Column 0 is the leftmost cell, row 0 the top.
pub const Position = struct {
    /// The column, counting from the left.
    col: u16,
    /// The row, counting from the top.
    row: u16,

    /// The order two positions are in when the grid is read: a later row comes
    /// after every position in an earlier row, and within a row a later column
    /// comes after an earlier one. Every comparison between two positions in
    /// Conduit is this one, so "after" means "later in reading order" everywhere
    /// rather than "further down" in some places and "further right" in others.
    pub fn order(a: Position, b: Position) std.math.Order {
        if (a.row != b.row) return std.math.order(a.row, b.row);
        return std.math.order(a.col, b.col);
    }
};

/// A selection over the grid, as a drag leaves it: the cell the drag started on
/// and the cell it ended on.
///
/// The two ends are kept as they were given because that is the state a live
/// drag is in — moving the mouse past the start of a selection extends it
/// backwards, and dropping the original order would lose the user's direction.
/// `normalized` is what anything that walks the selection asks for.
pub const Selection = struct {
    /// The cell the selection started on.
    anchor: Position,
    /// The cell the selection currently ends on.
    head: Position,

    /// The same selection with its two ends in reading order, so `first` is the
    /// cell it starts at whichever way the user dragged.
    pub fn normalized(self: Selection) Normalized {
        return if (self.anchor.order(self.head) == .gt)
            .{ .first = self.head, .last = self.anchor }
        else
            .{ .first = self.anchor, .last = self.head };
    }
};

/// A selection whose two ends are in reading order: the range every consumer
/// walks, from `first` through `last` inclusive.
pub const Normalized = struct {
    /// The first cell of the selection in reading order.
    first: Position,
    /// The last cell of the selection in reading order, included.
    last: Position,

    /// Whether the selection covers a single cell. Such a selection is still a
    /// selection: it has an anchor the user placed and an extent to grow.
    pub fn isEmpty(self: Normalized) bool {
        return self.first.order(self.last) == .eq;
    }

    /// Whether `position` is one of the selected cells. Both ends are included,
    /// because a selection is a range of cells rather than a range of the
    /// boundaries between them.
    pub fn contains(self: Normalized, position: Position) bool {
        return self.first.order(position) != .gt and position.order(self.last) != .gt;
    }

    /// How many rows the selection touches: at least 1, and at most the number
    /// of rows between its first and last cell inclusive. A highlight drawn
    /// across a partial row needs this, not the cell count.
    pub fn rowCount(self: Normalized) u32 {
        return @as(u32, self.last.row) - @as(u32, self.first.row) + 1;
    }
};

/// A colour, as Conduit carries it across the boundary.
///
/// `default` is not a colour: it is the cell inheriting whatever the palette
/// says for that slot, which is why it is a distinct case rather than a
/// palette index of zero. A renderer resolves `default` against the theme
/// (TASK-38); `term` never resolves a colour itself.
pub const Color = union(enum) {
    /// The terminal's default colour for this slot.
    default,
    /// An index into the 256-entry terminal palette.
    palette: u8,
    /// A direct 24-bit colour.
    rgb: Rgb,

    /// A direct 24-bit colour, with the channels the renderer wants.
    pub const Rgb = struct {
        /// Red.
        r: u8,
        /// Green.
        g: u8,
        /// Blue.
        b: u8,
    };

    fn fromVt(color: Vt.Color) Color {
        return switch (color) {
            .none => .default,
            .palette => |index| .{ .palette = index },
            .rgb => |rgb| .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
        };
    }

    /// Whether two colours are the same colour. Zig does not allow `==` on a
    /// union, so a colour is compared through this.
    pub fn eql(self: Color, other: Color) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .default => true,
            .palette => |index| index == other.palette,
            .rgb => |rgb| rgb.r == other.rgb.r and
                rgb.g == other.rgb.g and
                rgb.b == other.rgb.b,
        };
    }

    /// Conduit's own describer for a colour. `ghostty_vt.Style.Color` ships a
    /// `format` method with the pre-0.16 signature, which Zig 0.16 never
    /// calls, so `{f}` on the upstream type silently produces nothing useful.
    /// This is the replacement that actually runs — though because `Color` is
    /// a union it is reached as `Color.format(color, writer)`, since `{f}`
    /// would read `format` as a payload field rather than a declaration.
    pub fn format(self: Color, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .default => try writer.writeAll("default"),
            .palette => |index| try writer.print("palette({d})", .{index}),
            .rgb => |rgb| try writer.print("rgb({d},{d},{d})", .{ rgb.r, rgb.g, rgb.b }),
        }
    }
};

/// How a cell is underlined. Mirrors the SGR underline styles a program can
/// ask for; `theme` decides what each one looks like.
pub const Underline = enum {
    none,
    single,
    double,
    curly,
    dotted,
    dashed,

    fn fromVt(underline: @FieldType(@FieldType(Vt.Style, "flags"), "underline")) Underline {
        // Written as a switch rather than an `@enumFromInt` so that a new
        // upstream style is a compile error here instead of a wrong
        // underline on screen.
        return switch (underline) {
            .none => .none,
            .single => .single,
            .double => .double,
            .curly => .curly,
            .dotted => .dotted,
            .dashed => .dashed,
        };
    }
};

/// How one cell is painted: its colours and its attributes.
///
/// This is Conduit's value, not `ghostty_vt.Style`: it allocates nothing, has
/// no upstream lifetime attached to it, and can be compared and stored by a
/// renderer or a cache without touching the unstable API.
pub const Style = struct {
    /// The foreground colour.
    fg: Color = .default,
    /// The background colour.
    bg: Color = .default,
    /// The colour of the underline itself, which can differ from the
    /// foreground; a program sets it with SGR 58/59.
    underline_color: Color = .default,
    /// The on/off attributes.
    attributes: Attributes = .{},

    /// The on/off attributes SGR can set. A renderer reads these directly
    /// rather than switching on an attribute bitfield.
    pub const Attributes = struct {
        bold: bool = false,
        italic: bool = false,
        faint: bool = false,
        blink: bool = false,
        inverse: bool = false,
        invisible: bool = false,
        strikethrough: bool = false,
        overline: bool = false,
        underline: Underline = .none,
    };

    /// The default style: no colours and no attributes, which is what a cell
    /// with style id 0 has.
    pub const unset: Style = .{};

    fn fromVt(style: Vt.Style) Style {
        const flags = style.flags;
        return .{
            .fg = .fromVt(style.fg_color),
            .bg = .fromVt(style.bg_color),
            .underline_color = .fromVt(style.underline_color),
            .attributes = .{
                .bold = flags.bold,
                .italic = flags.italic,
                .faint = flags.faint,
                .blink = flags.blink,
                .inverse = flags.inverse,
                .invisible = flags.invisible,
                .strikethrough = flags.strikethrough,
                .overline = flags.overline,
                .underline = .fromVt(flags.underline),
            },
        };
    }

    /// Whether this is the default style, so a renderer can skip a lookup.
    pub fn isDefault(self: Style) bool {
        return self.eql(unset);
    }

    /// Whether two styles would paint identically.
    pub fn eql(self: Style, other: Style) bool {
        return self.fg.eql(other.fg) and
            self.bg.eql(other.bg) and
            self.underline_color.eql(other.underline_color) and
            std.meta.eql(self.attributes, other.attributes);
    }

    /// Conduit's own describer for a style — the one `ghostty_vt.Style` does
    /// not provide in a form Zig 0.16 can call (see `Color.format`). Only the
    /// fields that differ from the default are written, so the output says
    /// what is set rather than what every cell has.
    pub fn format(self: Style, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var first = true;
        try writer.writeAll("Style{");
        if (self.fg != .default) try field(writer, &first, "fg", self.fg);
        if (self.bg != .default) try field(writer, &first, "bg", self.bg);
        if (self.underline_color != .default) {
            try field(writer, &first, "underline_color", self.underline_color);
        }
        const attributes = self.attributes;
        if (attributes.bold) try flag(writer, &first, "bold");
        if (attributes.italic) try flag(writer, &first, "italic");
        if (attributes.faint) try flag(writer, &first, "faint");
        if (attributes.blink) try flag(writer, &first, "blink");
        if (attributes.inverse) try flag(writer, &first, "inverse");
        if (attributes.invisible) try flag(writer, &first, "invisible");
        if (attributes.strikethrough) try flag(writer, &first, "strikethrough");
        if (attributes.overline) try flag(writer, &first, "overline");
        if (attributes.underline != .none) {
            try separator(writer, &first);
            try writer.print("underline={s}", .{@tagName(attributes.underline)});
        }
        try writer.writeAll("}");
    }

    /// Writes one `name=value` pair. `Color.format` is called through its
    /// type rather than through the value: on a union, `value.format` is
    /// payload field access, not a call to the union's own `format`.
    fn field(
        writer: *std.Io.Writer,
        first: *bool,
        name: []const u8,
        value: Color,
    ) std.Io.Writer.Error!void {
        try separator(writer, first);
        try writer.print("{s}=", .{name});
        try Color.format(value, writer);
    }

    fn flag(writer: *std.Io.Writer, first: *bool, name: []const u8) std.Io.Writer.Error!void {
        try separator(writer, first);
        try writer.writeAll(name);
    }

    fn separator(writer: *std.Io.Writer, first: *bool) std.Io.Writer.Error!void {
        if (first.*) first.* = false else try writer.writeAll(",");
    }
};

/// One grid cell, as Conduit carries it across the boundary.
///
/// Borrowed from the terminal: `grapheme` points into the cached grid view and
/// stays valid until the next `Terminal.refresh` or `deinit`. The value itself
/// is a copy, so a caller may keep it in a frame arena without saying who
/// frees it.
pub const Cell = struct {
    /// The base codepoint of the cell, or 0 when the cell holds no text. A
    /// cell with no text may still have a background colour, which is in
    /// `style`.
    codepoint: u21,
    /// The codepoints that follow `codepoint` in the same grapheme cluster:
    /// the combining marks of `e` plus U+0301, for example. Empty for a cell
    /// holding a single codepoint.
    grapheme: []const u21,
    /// Whether this cell holds the left half of a double-width glyph. Such a
    /// glyph occupies this cell and `wide_tail`'s cell.
    wide: bool,
    /// Whether this cell is the empty second half of a double-width glyph, in
    /// which case a renderer draws nothing here.
    wide_tail: bool,
    /// How this cell is painted.
    style: Style = Style.unset,
    /// Whether the cell is inside the current selection, as of the last
    /// `refresh`.
    ///
    /// Read from the engine's own selection rather than from anything Conduit
    /// keeps beside it, and resolved once per frame rather than once per cell —
    /// see `Terminal.selection_bits`.
    selected: bool = false,

    /// Whether the cell holds any text at all.
    pub fn hasText(self: Cell) bool {
        return self.codepoint != 0;
    }
};

/// OSC 8 metadata attached to one terminal cell.
///
/// A valid `uri` is borrowed from Ghostty's owning page and remains valid only
/// until the next terminal mutation, `Terminal.refresh`, or `Terminal.deinit`.
/// `invalid_utf8` deliberately carries no bytes: callers need to preserve the
/// link's presence so lexical detection cannot reinterpret its label, but must
/// never pass an untrusted non-text target to a launcher.
pub const Hyperlink = union(enum) {
    uri: []const u8,
    invalid_utf8,
};

/// The shape a cursor is drawn in. Which one is used is the running program's
/// choice (DECSCUSR); what it looks like is the theme's (TASK-38).
pub const CursorShape = enum {
    /// A filled rectangle over the cell. DECSCUSR 1 and 2.
    block,
    /// A filled rectangle with an empty centre. Ghostty's own shape, not
    /// reachable from DECSCUSR.
    block_hollow,
    /// A vertical line on the leading edge of the cell. DECSCUSR 5 and 6.
    bar,
    /// A horizontal line under the cell. DECSCUSR 3 and 4.
    underline,

    fn fromVt(shape: Vt.CursorStyle) CursorShape {
        // A switch, not an `@enumFromInt`: a new upstream shape becomes a
        // compile error here rather than the wrong cursor on screen.
        return switch (shape) {
            .block => .block,
            .block_hollow => .block_hollow,
            .bar => .bar,
            .underline => .underline,
        };
    }
};

/// Where the cursor is and how it should be drawn. Read from the terminal
/// after `refresh`.
pub const Cursor = struct {
    /// The cursor's cell in viewport coordinates, or null when it has
    /// scrolled out of the viewport and so has nowhere to be drawn.
    position: ?Position,
    /// The shape the running program asked for.
    shape: CursorShape,
    /// Whether the cursor is shown at all: DECTCEM.
    visible: bool,
    /// Whether the cursor blinks: mode 12.
    blinking: bool,
    /// Whether the cursor sits on the empty second half of a double-width
    /// glyph, which a renderer may use to step the cursor back one cell.
    wide_tail: bool,
};

/// The terminal modes that change how a key is encoded back to the child.
///
/// These are exactly the eight options `ghostty-vt`'s `input/key_encode.zig`
/// derives from terminal state, in Conduit's own types, so the key encoder
/// (`input`, TASK-12) reads them without naming the upstream module. Read them
/// with `Terminal.keyModes` after every `feed`: a program can change any of
/// them at any moment.
pub const KeyModes = struct {
    /// DEC mode 1: the arrow keys send `ESC O A` rather than `ESC [ A`.
    cursor_key_application: bool = false,
    /// DEC mode 66: the keypad sends application sequences.
    keypad_key_application: bool = false,
    /// DECBKM: Backspace sends 0x08 rather than 0x7f.
    backarrow_key_mode: bool = false,
    /// DEC mode 1035: the keypad is ignored while NumLock is on.
    ignore_keypad_with_numlock: bool = false,
    /// DEC mode 1036: Alt prefixes the key with `ESC`.
    alt_esc_prefix: bool = false,
    /// xterm's "modifyOtherKeys mode 2".
    modify_other_keys_state_2: bool = false,
    /// The Kitty keyboard protocol flags, i.e. how much the program wants to
    /// be told about each key.
    kitty_keyboard: KittyKeyboard = .{},
    /// Whether the macOS Option key counts as Alt. This one is *not* terminal
    /// state — no escape sequence sets it — so it comes from configuration
    /// (TASK-37) and `Terminal.keyModes` reports whatever was last set with
    /// `setMacosOptionAsAlt`.
    macos_option_as_alt: bool = false,

    /// The Kitty keyboard protocol flags. All off is "the protocol is off",
    /// which is the default and the common case.
    pub const KittyKeyboard = struct {
        /// Report the keys that would otherwise be ambiguous.
        disambiguate: bool = false,
        /// Report key releases as well as presses.
        report_events: bool = false,
        /// Report the shifted and base layout keys of a key.
        report_alternates: bool = false,
        /// Report every key as an escape sequence, including Enter and Tab.
        report_all: bool = false,
        /// Report the text a key would insert alongside the key itself.
        report_associated: bool = false,
    };
};

/// What happened to a key: it went down, came up, or repeated.
///
/// The distinction matters to the Kitty keyboard protocol, which can be asked
/// to report releases and repeats (`KeyModes.kitty_keyboard.report_events`) and
/// to nothing else. Every other protocol encodes presses only, so the encoder
/// itself decides what to do with the other two.
pub const KeyAction = enum {
    /// The key went down. The default, and the only one most programs see.
    press,
    /// The key came up.
    release,
    /// The key went down again because it is being held.
    repeat,
};

/// The keys a terminal tells apart by which key was pressed, as opposed to by
/// what character the layout produced.
///
/// These are the keys that have no character of their own: the navigation
/// block, the editing keys and the function row. Layout-independent by
/// construction — `.enter` is the enter key whatever the layout is — which is
/// what a terminal program needs, because it binds by escape sequence rather
/// than by letter. A letter or a digit is *not* here: the layout has already
/// turned it into a character, and `KeyPress.text` carries it. Inventing the
/// whole W3C code-value space to say what a scancode is would be a second,
/// never-exercised copy of the keyboard, and nothing above this file reads it.
pub const PhysicalKey = enum {
    /// The key is one Conduit has no name for: a media key, an international
    /// key, a keypad key. It encodes to nothing unless it produced text.
    unidentified,
    enter,
    tab,
    backspace,
    escape,
    insert,
    delete,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,

    /// The upstream key this one is. A switch rather than an `@enumFromInt` so
    /// that a key added upstream is a compile error here instead of a
    /// silently unnamed key on a user's keyboard.
    fn toVt(self: PhysicalKey) Vt.VtKey {
        return switch (self) {
            .unidentified => .unidentified,
            .enter => .enter,
            .tab => .tab,
            .backspace => .backspace,
            .escape => .escape,
            .insert => .insert,
            .delete => .delete,
            .up => .arrow_up,
            .down => .arrow_down,
            .left => .arrow_left,
            .right => .arrow_right,
            .home => .home,
            .end => .end,
            .page_up => .page_up,
            .page_down => .page_down,
            .f1 => .f1,
            .f2 => .f2,
            .f3 => .f3,
            .f4 => .f4,
            .f5 => .f5,
            .f6 => .f6,
            .f7 => .f7,
            .f8 => .f8,
            .f9 => .f9,
            .f10 => .f10,
            .f11 => .f11,
            .f12 => .f12,
        };
    }
};

/// The modifiers that were down when a key was pressed.
///
/// Conduit's own six, in the same order as `input`'s: the four that change
/// what a key means, and the two locks, which do not. The encoder is given the
/// locks because a program reading the keypad with NumLock on has to be able to
/// tell.
///
/// Which *side* a modifier came from is not tracked. Nothing in Conduit reads
/// it yet — it matters only for macOS Option-as-Alt, which is configuration
/// (TASK-37) — so the upstream side bits stay at their default rather than
/// being filled in with a guess.
pub const KeyMods = struct {
    /// Control.
    ctrl: bool = false,
    /// Alt, called option on macOS.
    alt: bool = false,
    /// Shift. The keyboard has already applied it to the character.
    shift: bool = false,
    /// The command key: cmd on macOS, the Windows key elsewhere.
    super: bool = false,
    /// Caps lock.
    caps_lock: bool = false,
    /// Num lock.
    num_lock: bool = false,

    fn toVt(self: KeyMods) Vt.KeyMods {
        return .{
            .ctrl = self.ctrl,
            .alt = self.alt,
            .shift = self.shift,
            .super = self.super,
            .caps_lock = self.caps_lock,
            .num_lock = self.num_lock,
        };
    }
};

/// One key press, in Conduit's own words, on its way to the encoder.
///
/// This is the value `input` builds from what the operating system reported,
/// and it is deliberately *not* a binding event: it carries what the terminal
/// needs to encode the press and nothing else. Conduit never decodes the bytes
/// it gets back, so a program cannot address the UI by sending a key.
pub const KeyPress = struct {
    /// What happened to the key.
    action: KeyAction = .press,
    /// Which key it was, or `.unidentified` for a key with no name.
    key: PhysicalKey = .unidentified,
    /// The modifiers that were down with it.
    mods: KeyMods = .{},
    /// The modifiers the keyboard itself consumed producing `text`: shift,
    /// when it is what turned `a` into `A`. The encoder subtracts these from
    /// `mods` before deciding what binding a press is, which is how ctrl+A
    /// stays distinguishable from ctrl+a.
    consumed_mods: KeyMods = .{},
    /// The text this press produces, as UTF-8, or empty for none.
    ///
    /// Empty for a key with no character (the navigation and function keys),
    /// and for one whose character is a control: a control character is what
    /// the *encoder* produces from ctrl and the letter, not something the
    /// keyboard hands over, and sending it here as well would send it twice.
    text: []const u8 = "",
    /// The layout's codepoint for this key with shift and caps lock *not*
    /// applied, or 0 when there is none. This is what tells the encoder that
    /// ctrl+a and ctrl+A are the same key, and it is what the Kitty protocol
    /// falls back to when it wants a codepoint for a key with no name.
    unshifted_codepoint: u21 = 0,
    /// True while an input method is composing this press into a preedit.
    ///
    /// The encoder emits nothing at all for a composing press, so a preedit
    /// cannot reach the child: not because a caller remembered to check, but
    /// because the encoder never encodes one. `input` therefore needs no rule
    /// of its own about what to do with a key pressed during composition.
    composing: bool = false,

    fn toVt(self: KeyPress) Vt.KeyEvent {
        return .{
            .action = switch (self.action) {
                .press => .press,
                .release => .release,
                .repeat => .repeat,
            },
            .key = self.key.toVt(),
            .mods = self.mods.toVt(),
            .consumed_mods = self.consumed_mods.toVt(),
            .composing = self.composing,
            .utf8 = self.text,
            .unshifted_codepoint = self.unshifted_codepoint,
        };
    }
};

/// The longest sequence the encoder can write for one key.
///
/// The longest sequences are Kitty's, at roughly thirty bytes, and the
/// encoder's own tests write into 128-byte buffers. 256 is twice that, and it
/// is a *fixed* size because the hot path may not allocate: a key press is
/// encoded into a value the caller already has.
pub const max_encoded_key_bytes = 256;

/// The bytes one key press encodes to.
///
/// Zero-length when the key encodes to nothing, which is a real answer and not
/// an error: an unidentified key, a release under a protocol that does not
/// report releases, and every key of every protocol while an input method is
/// composing.
pub const EncodedKey = struct {
    /// The bytes, of which only `bytes[0..len]` were written.
    bytes: [max_encoded_key_bytes]u8 = undefined,
    /// How many bytes of `bytes` are live.
    len: usize = 0,

    /// The encoded bytes, or an empty slice for a key that encodes to nothing.
    pub fn slice(self: *const EncodedKey) []const u8 {
        return self.bytes[0..self.len];
    }

    /// Whether this key produced no bytes at all.
    pub fn isEmpty(self: *const EncodedKey) bool {
        return self.len == 0;
    }
};

/// The largest clipboard or paste payload accepted from an external source.
pub const max_clipboard_bytes: usize = 8 * 1024 * 1024;

/// What an untrusted program may do through OSC 52. `.ask` is the safe
/// default: M1 records a permission request but has no prompt UI, so the
/// operation is refused until a later user gesture answers it.
pub const ClipboardPolicy = enum { allow, ask, deny };

/// Read and write are separate because disclosing clipboard contents is a
/// different permission from letting a program offer new contents.
pub const ClipboardPolicies = struct {
    read: ClipboardPolicy = .ask,
    write: ClipboardPolicy = .ask,
};

/// A clipboard name after Ghostty has interpreted the OSC 52 selector.
pub const ClipboardLocation = enum { standard, selection, primary };

/// Which permission an untrusted terminal program requested.
pub const ClipboardOperation = enum { read, write };

/// Non-sensitive metadata for a request that policy left at `.ask`.
pub const PermissionRequest = struct {
    operation: ClipboardOperation,
    location: ClipboardLocation,
    /// Known for writes; null for reads because policy is checked before the
    /// native clipboard is opened.
    byte_count: ?usize,
};

/// What became of one OSC 52 request.
pub const ClipboardOutcome = enum {
    /// `.allow`: the app's adapter wrote the clipboard.
    written,
    /// `.allow`: the app's adapter read the clipboard and the program got it.
    read,
    /// `.ask`: refused, and a `permission_request` event was recorded.
    asked,
    /// `.deny`: refused.
    denied,
    /// No adapter, or a payload with no text representation.
    unsupported,
    /// The payload was not text Conduit will put on a clipboard.
    invalid,
    /// The adapter tried and failed.
    failed,
};

/// One OSC 52 request as the log sees it.
///
/// The log line for a clipboard request is built from this and nothing else,
/// and no field of it can hold clipboard contents: two enums, an outcome and a
/// count. That is what makes "never logged" structural rather than a habit
/// every call site has to keep (CONDUIT.md §11); a test asserts the struct has
/// no pointer in it, so adding one fails the build's tests.
pub const ClipboardDiagnostic = struct {
    operation: ClipboardOperation,
    location: ClipboardLocation,
    outcome: ClipboardOutcome,
    /// The decoded size of a write, or of a read's answer; null when nothing
    /// was read.
    byte_count: ?usize,

    /// The one line a request is logged as.
    pub fn format(self: ClipboardDiagnostic, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("OSC 52 {s} of the {s} clipboard: {s}", .{
            @tagName(self.operation),
            @tagName(self.location),
            @tagName(self.outcome),
        });
        if (self.byte_count) |count| try writer.print(" ({d} byte(s))", .{count});
    }
};

/// Failures a platform adapter may report without exposing platform types to
/// the terminal boundary.
pub const ClipboardAccessError = Allocator.Error || error{
    Unsupported,
    Unavailable,
    PayloadTooLarge,
    InvalidText,
};

/// Synchronous native clipboard access supplied by the app.
///
/// A read returns memory allocated with `alloc`; `term` frees it immediately
/// after Ghostty has encoded the reply. A write only borrows `text` for the
/// callback. Neither callback may retain any argument.
pub const ClipboardAccess = struct {
    context: ?*anyopaque = null,
    read_fn: ?*const fn (?*anyopaque, ClipboardLocation, Allocator) ClipboardAccessError![]u8 = null,
    write_fn: ?*const fn (?*anyopaque, ClipboardLocation, []const u8, Allocator) ClipboardAccessError!void = null,
};

/// An encoded user paste. `.encoded` is owned by the caller and must be freed
/// with the allocator passed to `Terminal.preparePaste`.
pub const Paste = union(enum) {
    encoded: []u8,
    confirmation_required,

    pub fn deinit(self: Paste, alloc: Allocator) void {
        switch (self) {
            .encoded => |bytes| alloc.free(bytes),
            .confirmation_required => {},
        }
    }
};

/// Why a user paste could not be prepared.
pub const PasteError = Allocator.Error || error{
    NotOwned,
    PayloadTooLarge,
    InvalidText,
};

const bracketed_paste_prefix = "\x1b[200~";
const bracketed_paste_suffix = "\x1b[201~";

fn validateClipboardPayload(bytes: []const u8) error{ PayloadTooLarge, InvalidText }!void {
    if (bytes.len > max_clipboard_bytes) return error.PayloadTooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidText;
    for (bytes) |byte| {
        if ((byte < 0x20 and byte != '\t' and byte != '\n' and byte != '\r') or byte == 0x7f) {
            return error.InvalidText;
        }
    }
}

/// One step of a command, as the shell reported it with OSC 133.
///
/// Recorded because a prompt the shell marked is a place a user can jump back
/// to; the marks themselves live on the grid's rows, and this is the event
/// that says one was made. Nothing here is acted on: a mark is the shell's
/// claim about its own output, and terminal text never triggers an action
/// (CONDUIT.md §11).
pub const PromptMark = struct {
    /// Which step of the command this is.
    kind: Kind,
    /// The exit status the shell reported for a `command_end`, or null when it
    /// reported none. Always null for every other kind.
    exit_code: ?i32,

    pub const Kind = enum {
        /// The shell started drawing a prompt (OSC 133 `A`, `N` or `P`).
        prompt_start,
        /// The prompt is drawn and the user is typing (OSC 133 `B` or `I`).
        input_start,
        /// The user submitted the command and it is running (OSC 133 `C`).
        output_start,
        /// The command finished (OSC 133 `D`).
        command_end,
    };
};

/// Something the running program did that has no place in the grid but that
/// the user should see. Read with `Terminal.takeEvents`.
///
/// Events are queued per `feed`, in the order the program produced them. The
/// payload of a `title` or a `working_directory` borrows the terminal until the
/// next `feed`, which discards the queue and reuses the buffer.
pub const Event = union(enum) {
    /// The program set the window or tab title, with OSC 0 or OSC 2. The text
    /// is untrusted: it is a program's idea of what the user is working on,
    /// and it is never used to open anything.
    title: []const u8,
    /// The program rang the bell, with BEL.
    bell,
    /// OSC 52 reached `.ask`. No clipboard contents are present: the app may
    /// surface this metadata, but must not answer it without a user gesture.
    permission_request: PermissionRequest,
    /// The shell reported its working directory with OSC 7, and the report
    /// passed validation: a `file` or `kitty-shell-cwd` URL naming this host.
    /// The path is decoded and never normalised; an empty slice means the
    /// shell cleared it. Display data only — it is a program's claim, and it
    /// never causes an action. `Terminal.workingDirectory` holds the latest.
    working_directory: []const u8,
    /// The shell marked a step of a command with OSC 133.
    prompt: PromptMark,
    /// The program performed a full reset (RIS, `ESC c`). The working
    /// directory, the title and every prompt mark are gone, and a command
    /// that was running will never report its end.
    reset,
    /// The program asked for a desktop notification with OSC 9
    /// (`ESC ] 9 ; body ST`) or OSC 777 (`ESC ] 777 ; notify ; title ; body
    /// ST`). Both texts are untrusted display data: bounded, cleaned of
    /// control characters, made valid UTF-8 and truncated here, and never
    /// used to open or run anything (TASK-56). They borrow the terminal until
    /// the next `feed`, like a title.
    notification: Notification,
};

/// A desktop notification a program asked for. See `Event.notification`.
pub const Notification = struct {
    /// Empty for OSC 9, which carries a body only.
    title: []const u8,
    body: []const u8,
    /// Set when either text was cut to its bound.
    truncated: bool = false,
};

/// The most bytes of a notification title kept; longer titles are cut at a
/// UTF-8 boundary and the event says so.
pub const max_notification_title_bytes = 256;
/// The most bytes of a notification body kept.
pub const max_notification_body_bytes = 1024;

/// Copy `text` into `out` as display text: invalid UTF-8 becomes U+FFFD, C0
/// and C1 controls and DEL become spaces, and the copy stops at the last
/// whole character that fits. Returns the written slice and whether anything
/// was left out. Never fails: notification text is display data, and a
/// malformed one must still produce something harmless.
pub fn sanitizeNotificationText(out: []u8, text: []const u8) struct { text: []const u8, truncated: bool } {
    var written: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        var encoded: [4]u8 = undefined;
        var piece: []const u8 = undefined;
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch 0;
        const decoded: ?u21 = if (length != 0 and index + length <= text.len)
            std.unicode.utf8Decode(text[index .. index + length]) catch null
        else
            null;
        if (decoded) |codepoint| {
            if (codepoint < 0x20 or codepoint == 0x7f or (codepoint >= 0x80 and codepoint < 0xa0)) {
                encoded[0] = ' ';
                piece = encoded[0..1];
            } else {
                piece = text[index .. index + length];
            }
            index += length;
        } else {
            const n = std.unicode.utf8Encode(std.unicode.replacement_character, &encoded) catch unreachable;
            piece = encoded[0..n];
            index += 1;
        }
        if (written + piece.len > out.len) return .{ .text = out[0..written], .truncated = true };
        @memcpy(out[written..][0..piece.len], piece);
        written += piece.len;
    }
    return .{ .text = out[0..written], .truncated = false };
}

/// The longest OSC 7 report this terminal will believe, in bytes.
///
/// Upstream truncates a report at this length before storing it, and a
/// truncated path is a different, wrong path. A report that reaches the limit
/// is therefore rejected rather than trusted with its tail cut off; Linux's
/// `PATH_MAX` is this same 4096, so no real directory is lost.
const max_working_directory_bytes = 4096;

/// Why an OSC 7 report was ignored. Logged at debug by its name and nothing
/// else: the URL itself is the program's text and never reaches a log line.
const CwdRejection = error{
    TooLong,
    Malformed,
    UnknownScheme,
    UserinfoOrPort,
    NoHost,
    ForeignHost,
    QueryOrFragment,
    NotAbsolute,
    ContainsNul,
};

/// Validate and decode one OSC 7 report into `out`.
///
/// Returns the decoded path, a subslice of `out`, or the empty slice when the
/// shell cleared its directory with an empty report. Upstream stores OSC 7
/// raw and leaves this to the embedder; this is the embedder's half, and it is
/// the defence against a program that names a directory it is not in:
///
/// - The scheme is `file` or `kitty-shell-cwd`; anything else is not a
///   working directory.
/// - The host is `localhost` or exactly `local_host`, the name this machine
///   reports. A shell on the far side of `ssh` reports *its* host, and a
///   program forging a path names whatever it likes; both are refused. A
///   missing host, a user, a port or a percent-encoded host never matches.
///   Refusing a real local report costs a stale directory; believing a forged
///   one costs a new tab that opens somewhere the user never went.
/// - A `kitty-shell-cwd` path is taken byte for byte, which is that scheme's
///   rule; a `file` path is percent-decoded, and must carry no query or
///   fragment, because a `?` or `#` in a real path is percent-encoded.
/// - The path is absolute, and a decoded NUL is refused: no path holds one,
///   and every consumer downstream would truncate at it.
/// - Nothing is normalised. `..` and `//` are what the shell said, and a
///   symlinked directory's `..` is not its parent's.
fn decodeWorkingDirectory(
    url: []const u8,
    local_host: ?[]const u8,
    out: *[max_working_directory_bytes]u8,
) CwdRejection![]const u8 {
    if (url.len == 0) return out[0..0];
    if (url.len >= max_working_directory_bytes) return error.TooLong;

    const uri = std.Uri.parse(url) catch return error.Malformed;
    const raw_path = if (std.mem.eql(u8, uri.scheme, "kitty-shell-cwd"))
        true
    else if (std.mem.eql(u8, uri.scheme, "file"))
        false
    else
        return error.UnknownScheme;

    if (uri.user != null or uri.password != null or uri.port != null) return error.UserinfoOrPort;
    const host = switch (uri.host orelse return error.NoHost) {
        .raw, .percent_encoded => |bytes| bytes,
    };
    const is_local = std.mem.eql(u8, host, "localhost") or
        (if (local_host) |name| name.len != 0 and std.mem.eql(u8, host, name) else false);
    if (!is_local) return error.ForeignHost;

    // `std.Uri` hands back slices of `url`, so the path starts where its
    // component does. A raw path runs to the end of the report: `?` and `#`
    // are ordinary bytes in a `kitty-shell-cwd` path.
    const encoded_path = switch (uri.path) {
        .raw, .percent_encoded => |bytes| bytes,
    };
    const path_start = @intFromPtr(encoded_path.ptr) - @intFromPtr(url.ptr);
    const path: []const u8 = if (raw_path) raw: {
        const rest = url[path_start..];
        @memcpy(out[0..rest.len], rest);
        break :raw out[0..rest.len];
    } else decoded: {
        if (uri.query != null or uri.fragment != null) return error.QueryOrFragment;
        // Decoding never lengthens a path, and std decodes towards the back
        // of the buffer, so the result is moved down to start at `out`.
        @memcpy(out[0..encoded_path.len], encoded_path);
        const tail = std.Uri.percentDecodeInPlace(out[0..encoded_path.len]);
        std.mem.copyForwards(u8, out[0..tail.len], tail);
        break :decoded out[0..tail.len];
    };

    if (path.len == 0 or path[0] != '/') return error.NotAbsolute;
    if (std.mem.findScalar(u8, path, 0) != null) return error.ContainsNul;
    return path;
}

/// Whether this target has a host name for `localHostName` to read.
const has_host_name = switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

/// The name this machine reports for itself, into `buffer`, or null where it
/// cannot be read. Null makes every host but `localhost` foreign, which is the
/// safe direction to fail in.
fn localHostName(buffer: *[std.Io.net.HostName.max_len]u8) ?[]const u8 {
    if (comptime !has_host_name) return null;
    var name: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const got = std.posix.gethostname(&name) catch return null;
    if (got.len > buffer.len) return null;
    @memcpy(buffer[0..got.len], got);
    return buffer[0..got.len];
}

/// Which rows of the viewport changed since the previous `refresh`. Read with
/// `Terminal.damage`, which reports the damage of the last `refresh`.
pub const Damage = union(enum) {
    /// Nothing changed; a renderer can skip the frame's grid work entirely.
    none,
    /// These viewport rows changed, top to bottom and without repeats.
    rows: []const u16,
    /// Something that is not row content changed — the palette, the grid
    /// dimensions, or which screen is active — so the whole grid, and
    /// anything derived from the palette, has to be redrawn.
    full,
};

// ---------------------------------------------------------------------------
// Scrollback and the viewport
// ---------------------------------------------------------------------------

/// What brings a scrolled-back viewport back to the bottom.
///
/// This is the whole of the "as configured" in criterion 2, and it is a real
/// setting rather than a hardcoded assumption: `ScrollConfig.return_policy`
/// carries it, and `Terminal.userInput` and `Terminal.refresh` are the two
/// places that read it.
///
/// The default is `.on_typing`, and the reason is the failure the other
/// default has. A build printing ten thousand lines a second while the user
/// reads history three screens up is the ordinary case in a terminal, and a
/// policy that returns on output would drag the view back to the bottom on the
/// first line of it — making the scrollback unreadable exactly when it is
/// wanted. Typing, by contrast, is unambiguous: a keypress means the user is
/// at the prompt now, and a view showing lines from a minute ago is a lie.
pub const ReturnPolicy = enum {
    /// Typing returns the viewport to the bottom; new output does not.
    ///
    /// The default, and the reason `CONDUIT.md` §7 can promise that scrolling
    /// back "sticks".
    on_typing,
    /// Typing and any new output both return it to the bottom.
    ///
    /// What a user wants when the program in front of them owns the whole
    /// screen and they are watching it run — a `yes`, a test suite, a build
    /// whose last line is the answer.
    on_typing_or_output,
    /// Nothing returns it but an explicit scroll to the bottom.
    ///
    /// For reading a log while it is still being written, where even the
    /// prompt moving is noise.
    explicit_only,
};

/// How much history the terminal keeps, and how the viewport behaves.
///
/// The scrollback buffer itself is Ghostty's (`PageList`): this configuration
/// is what Conduit hands it, and reading a document that says the buffer is
/// upstream's is what stops the two from drifting into two implementations of
/// the same thing.
pub const ScrollConfig = struct {
    /// Rows of history retained above the grid, or null for the engine's own
    /// bound.
    ///
    /// Bounded by the ceiling below rather than trusted: a scrollback limit is
    /// a claim about memory, and a configuration file that asks for ten million
    /// rows on a machine with a hundred megabytes of spare would otherwise be a
    /// configuration file that runs the process out of memory.
    max_scrollback_lines: ?usize = default_scrollback_lines,
    /// Bytes of history retained above the grid, or null for the engine's own
    /// bound. Clamped by the same ceiling logic as the line limit.
    max_scrollback_bytes: ?usize = null,
    /// What brings a scrolled-back viewport to the bottom.
    return_policy: ReturnPolicy = .on_typing,
    /// Rows one notch of a notched wheel moves.
    ///
    /// Three is what xterm, iTerm2 and Ghostty all use, and it is a choice
    /// rather than a truth: one notch is three lines everywhere because that is
    /// what felt right to the programs that picked it.
    lines_per_notch: f32 = default_lines_per_notch,
    /// Pixels of smooth travel that make one row.
    ///
    /// The trackpad analogue of `lines_per_notch`. Divided, not multiplied,
    /// because a precise device reports distance rather than steps.
    pixels_per_row: f32 = default_pixels_per_row,

    /// Rows of history Conduit keeps when nothing says otherwise.
    ///
    /// Ten thousand rows is about what a person scrolls through in a long
    /// session, and it is bounded in bytes as well as lines, so it costs
    /// something predictable rather than something proportional to how long
    /// the machine was left alone.
    pub const default_scrollback_lines: usize = 10_000;
    /// The largest history limit a configuration may ask for.
    pub const line_ceiling: usize = 1_000_000;
    /// The largest byte limit a configuration may ask for.
    pub const byte_ceiling: usize = 512 * 1024 * 1024;
    /// Rows a wheel notch moves by default.
    pub const default_lines_per_notch: f32 = 3.0;
    /// Pixels of trackpad travel that make a row by default.
    pub const default_pixels_per_row: f32 = 40.0;
    /// The smallest sensible trackpad ratio: below this a device would report
    /// a whole row of travel per pixel and the view would fly.
    pub const min_pixels_per_row: f32 = 4.0;
    /// The largest sensible wheel step: a configuration above this turns one
    /// notch into a whole screen.
    pub const max_lines_per_notch: f32 = 100.0;

    /// This configuration with every field inside its bounds.
    ///
    /// Clamping here rather than in each setter means a value that arrived from
    /// a file, a flag or a future hot-reload is bounded by the same code, and
    /// `Terminal.setScrollConfig` is safe to call with anything. A value that
    /// had to be clamped is logged, because silently keeping a different limit
    /// from the one that was asked for is the failure mode this exists to
    /// avoid.
    pub fn bounded(self: ScrollConfig) ScrollConfig {
        var out = self;
        out.max_scrollback_lines = if (self.max_scrollback_lines) |lines|
            @min(lines, line_ceiling)
        else
            null;
        out.max_scrollback_bytes = if (self.max_scrollback_bytes) |bytes|
            @min(bytes, byte_ceiling)
        else
            null;
        // A non-finite or absurd ratio is a configuration mistake, and both
        // produce a view that either will not move or will not stop.
        out.lines_per_notch = clampRatio(self.lines_per_notch, 1.0, max_lines_per_notch);
        out.pixels_per_row = clampRatio(self.pixels_per_row, min_pixels_per_row, 4000.0);
        return out;
    }

    /// Clamp a ratio that is not a number, or is out of range, to `default`.
    ///
    /// NaN is the case that matters: every comparison against NaN is false, so
    /// a `@min`/`@max` of it silently passes the NaN through, and one NaN row
    /// ratio is an endless scroll.
    fn clampRatio(value: f32, low: f32, high: f32) f32 {
        if (!std.math.isFinite(value)) return default_lines_per_notch;
        return @min(@max(value, low), high);
    }
};

/// Where the viewport is, relative to the bottom of the history.
///
/// The contract, in three numbers and two questions:
///
/// - `offset` is how many rows the top of the view sits **above** the bottom of
///   history. Zero means the view is pinned to the active area: the cursor is
///   on screen and a program printing here is being watched.
///
///   While the view is scrolled back it is pinned to a *row*, not to a
///   distance, and that is the whole of what "scrolling back sticks" means:
///   output arriving does not move the view, so `offset` grows by however many
///   rows the program printed, while what is on screen does not change at all.
///   A caller that wants to know whether the view moved reads the rows, not
///   this number.
/// - `history_rows` is how far it *could* go: rows of scrollback above the
///   active area. `offset` is clamped to it by the engine, so a caller never
///   has to clamp a request itself.
/// - "At the bottom" means `offset == 0` and nothing else. It does not mean
///   "the last row printed is visible" — with output still arriving, the two
///   differ, and only the first is a statement about where the view is.
pub const Viewport = struct {
    /// Rows above the bottom of history that the top of the view sits at.
    offset: usize,
    /// Rows of history above the active area: the most the view could scroll.
    history_rows: usize,
    /// Rows the view is tall, which is the grid's row count.
    view_rows: usize,

    /// Whether the view is showing the active area.
    pub fn atBottom(self: Viewport) bool {
        return self.offset == 0;
    }

    /// Rows the view could still move back.
    pub fn rowsToTop(self: Viewport) usize {
        return self.offset;
    }
};

/// Case treatment shared by literal and regex scrollback search.
///
/// ASCII-insensitive deliberately means ASCII only. Terminal contents are
/// UTF-8, but Unicode case folding can change byte length and display-cell
/// boundaries; silently applying it would make a returned cell range
/// ambiguous. Regex mode applies the same ASCII-only fold through Oniguruma's
/// `IGNORECASE_IS_ASCII` option.
pub const SearchCase = enum {
    sensitive,
    ascii_insensitive,
};

/// Matcher selected for one scrollback search.
pub const SearchKind = enum {
    literal,
    regex,
};

/// One cell in the active screen's retained text, addressed from the oldest
/// row still in scrollback rather than from the current viewport.
///
/// `row` remains meaningful while the terminal's search generation is
/// unchanged. A `SearchMatch` carries that generation so stale coordinates
/// are refused after output, resize, reset or history pruning.
pub const SearchPoint = struct {
    col: u16,
    row: u32,
};

/// An inclusive search-match range in full-scrollback coordinates.
///
/// A match may span soft-wrapped or hard-newline-separated rows. `first` and
/// `last` name its first and last terminal cells; byte offsets inside a
/// grapheme are intentionally not exposed because navigation and rendering
/// operate on cells.
pub const SearchMatch = struct {
    first: SearchPoint,
    last: SearchPoint,
    generation: u64,
};

/// Progress made by one bounded `ScrollbackSearch.step` call.
pub const SearchProgress = enum {
    /// More page-sized search ticks remain.
    running,
    /// Every retained page has been searched as of the last `sync`.
    complete,
    /// The caller-provided work buffer was too small. Existing results remain
    /// readable, but completing this query requires a new search with more
    /// scratch space.
    scratch_exhausted,
};

/// Direction a bounded result scan moves through Ghostty's stable candidate
/// order. Older starts at the newest candidate and increases its raw index;
/// newer moves back toward raw index zero.
pub const SearchDirection = enum {
    older,
    newer,
};

/// Opaque continuation for bounded search-result materialization.
///
/// Literal cursors advance `next_index` for every upstream candidate, not just
/// accepted exact-case matches. Regex cursors use the row/byte continuation.
/// Both forms prevent page N from rescanning pages 0..N-1.
pub const SearchCursor = struct {
    direction: SearchDirection,
    next_index: usize,
    generation: u64,
    /// Regex-only logical-line continuation. The first attempt may begin on
    /// any physical row, then normalizes this to the logical line's first
    /// row. Null identifies a literal cursor, keeping the upstream candidate
    /// index opaque to callers.
    regex_row: ?u32 = null,
    /// Regex-only byte boundary inside the formatted logical line. `maxInt`
    /// means the line's end for an older/backward scan.
    regex_byte: usize = 0,
};

const RegexAnchor = struct {
    /// Absolute physical row at which this logical line begins.
    row: u32,
    start_byte: usize,
    end_byte: usize,
};

const RegexLineBounds = struct {
    start: Vt.Pin,
    end: Vt.Pin,
    start_row: u32,
    end_row: u32,
    row_count: usize,
};

const RegexNodeRun = struct {
    offset: usize,
    node: @FieldType(Vt.Pin, "node"),
};

const RegexRange = struct {
    start: usize,
    end: usize,
};

/// One accepted result plus the raw candidate that anchored it.
///
/// The anchor lets callers start an adjacent page without remembering or
/// copying every earlier match.
pub const LocatedSearchMatch = struct {
    match: SearchMatch,
    candidate_index: usize,
    regex_anchor: ?RegexAnchor = null,
};

pub const SearchScanStop = enum {
    /// The caller's output slice filled before the candidate budget did.
    output_full,
    /// The explicit candidate-verification budget was consumed.
    budget,
    /// Every candidate currently materialized in this direction was visited.
    current_boundary,
    /// Fixed scratch could no longer verify or discover candidates.
    scratch_exhausted,
};

/// Result of one caller-storage, candidate-bounded materialization step.
pub const SearchScan = struct {
    items: []LocatedSearchMatch,
    examined: usize,
    /// Literal candidates or regex row work units currently addressable.
    /// Regex matching can yield more than one result from a row, so this is a
    /// progress boundary rather than a total-match count.
    available_candidates: usize,
    progress: SearchProgress,
    stop: SearchScanStop,
};

/// Why a materialized search result could not drive viewport navigation.
pub const SearchNavigationError = error{
    NotOwned,
    StaleSearchMatch,
};

/// Maximum literal or regex pattern size accepted by the terminal wrapper.
///
/// Search text comes from a one-line UI input, and one KiB is already far
/// beyond an interactive query. Bounding it also bounds the exact-case
/// verification buffer independently of scrollback size.
pub const max_search_needle_bytes = 1024;

pub const ScrollbackSearchError = Allocator.Error || error{
    InvalidUtf8,
    NeedleTooLong,
    NotOwned,
    WrongTerminal,
    StaleSearch,
    SearchScratchExhausted,
    InvalidRegex,
    RegexTooComplex,
    RegexWorkLimit,
    RegexEngineFailure,
};

// Oniguruma counts internal retry/backtracking steps rather than elapsed
// time. One event-loop poll verifies at most the caller's candidate budget,
// and every verification gets these independent limits. Pattern bytes and
// nesting are bounded before compilation as well, so neither compilation nor
// matching can grow from untrusted terminal/search input without a ceiling.
const regex_retry_limit: c_ulong = 25_000;
const regex_match_stack_limit: c_uint = 4096;
const regex_nesting_limit: usize = 64;
const regex_candidate_budget: usize = 4;
// A malformed or adversarial stream can create a soft-wrapped logical line
// whose rows contain almost no text. Subject bytes alone would not bound the
// time spent walking it, so one attempt also has a fixed physical-row limit.
// Exceeding the work limit is distinct from a subject which cannot fit the
// caller's scratch; the latter retains the existing scratch-exhaustion path.
const regex_logical_row_limit: usize = 4096;

const RegexBackend = struct {
    value: oniguruma.OnigRegex,
    region: *oniguruma.OnigRegion,
    match_param: *oniguruma.OnigMatchParam,

    fn init(pattern: []const u8, case: SearchCase) ScrollbackSearchError!RegexBackend {
        if (!regexPatternWithinLimits(pattern)) return error.RegexTooComplex;

        var encodings = [_]oniguruma.OnigEncoding{oniguruma.ONIG_ENCODING_UTF8()};
        const initialize_result = oniguruma.onig_initialize(@ptrCast(&encodings), 1);
        if (initialize_result == oniguruma.ONIGERR_MEMORY) return error.OutOfMemory;
        if (initialize_result != oniguruma.ONIG_NORMAL) return error.RegexEngineFailure;

        var value: oniguruma.OnigRegex = null;
        const pattern_start: [*c]const oniguruma.OnigUChar = @ptrCast(pattern.ptr);
        var error_info: oniguruma.OnigErrorInfo = undefined;
        const options: oniguruma.OnigOptionType = if (case == .ascii_insensitive)
            oniguruma.ONIG_OPTION_IGNORECASE | oniguruma.ONIG_OPTION_IGNORECASE_IS_ASCII
        else
            oniguruma.ONIG_OPTION_NONE;
        const compile_result = oniguruma.onig_new(
            &value,
            pattern_start,
            pattern_start + pattern.len,
            options,
            oniguruma.ONIG_ENCODING_UTF8(),
            oniguruma.ONIG_SYNTAX_ONIGURUMA(),
            &error_info,
        );
        if (compile_result == oniguruma.ONIGERR_MEMORY) return error.OutOfMemory;
        if (compile_result == oniguruma.ONIGERR_PARSE_DEPTH_LIMIT_OVER) {
            return error.RegexTooComplex;
        }
        if (compile_result != oniguruma.ONIG_NORMAL) return error.InvalidRegex;
        errdefer oniguruma.onig_free(value);

        const region = oniguruma.onig_region_new() orelse return error.OutOfMemory;
        errdefer oniguruma.onig_region_free(region, 1);
        const match_param = oniguruma.onig_new_match_param() orelse return error.OutOfMemory;
        errdefer oniguruma.onig_free_match_param(match_param);
        if (oniguruma.onig_set_retry_limit_in_search_of_match_param(
            match_param,
            regex_retry_limit,
        ) != oniguruma.ONIG_NORMAL or
            oniguruma.onig_set_retry_limit_in_match_of_match_param(
                match_param,
                regex_retry_limit,
            ) != oniguruma.ONIG_NORMAL or
            oniguruma.onig_set_match_stack_limit_size_of_match_param(
                match_param,
                regex_match_stack_limit,
            ) != oniguruma.ONIG_NORMAL)
        {
            return error.RegexEngineFailure;
        }

        return .{
            .value = value,
            .region = region,
            .match_param = match_param,
        };
    }

    fn deinit(self: *RegexBackend) void {
        oniguruma.onig_free_match_param(self.match_param);
        oniguruma.onig_region_free(self.region, 1);
        oniguruma.onig_free(self.value);
        self.* = undefined;
    }

    const Result = union(enum) {
        mismatch,
        work_limit,
        match: RegexRange,
    };

    fn search(
        self: *RegexBackend,
        subject: []const u8,
        direction: SearchDirection,
        byte_boundary: usize,
    ) ScrollbackSearchError!Result {
        oniguruma.onig_region_clear(self.region);
        const base: [*c]const oniguruma.OnigUChar = @ptrCast(subject.ptr);
        const end = base + subject.len;
        const start, const range = switch (direction) {
            .newer => .{ base + @min(byte_boundary, subject.len), end },
            .older => older: {
                if (subject.len == 0) return .mismatch;
                const exclusive = @min(byte_boundary, subject.len);
                const offset = if (exclusive == subject.len and byte_boundary == std.math.maxInt(usize))
                    subject.len
                else
                    previousUtf8Boundary(subject, exclusive) orelse return .mismatch;
                break :older .{ base + offset, base };
            },
        };
        const result = oniguruma.onig_search_with_param(
            self.value,
            base,
            end,
            start,
            range,
            self.region,
            oniguruma.ONIG_OPTION_NONE,
            self.match_param,
        );
        if (result == oniguruma.ONIG_MISMATCH) return .mismatch;
        if (result == oniguruma.ONIGERR_RETRY_LIMIT_IN_MATCH_OVER or
            result == oniguruma.ONIGERR_RETRY_LIMIT_IN_SEARCH_OVER or
            result == oniguruma.ONIGERR_MATCH_STACK_LIMIT_OVER or
            result == oniguruma.ONIGERR_SUBEXP_CALL_LIMIT_IN_SEARCH_OVER)
        {
            return .work_limit;
        }
        if (result == oniguruma.ONIGERR_MEMORY) return error.OutOfMemory;
        if (result < 0) return error.RegexEngineFailure;
        if (self.region.num_regs <= 0) return error.RegexEngineFailure;
        const begins = self.region.beg;
        const ends = self.region.end;
        if (begins == null or ends == null) return error.RegexEngineFailure;
        if (begins[0] < 0 or ends[0] < begins[0]) return error.RegexEngineFailure;
        return .{ .match = .{
            .start = @intCast(begins[0]),
            .end = @intCast(ends[0]),
        } };
    }
};

fn regexPatternWithinLimits(pattern: []const u8) bool {
    var escaped = false;
    var in_class = false;
    var depth: usize = 0;
    for (pattern) |byte| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            escaped = true;
            continue;
        }
        if (byte == '[') {
            in_class = true;
            continue;
        }
        if (byte == ']' and in_class) {
            in_class = false;
            continue;
        }
        if (in_class) continue;
        if (byte == '(') {
            depth += 1;
            if (depth > regex_nesting_limit) return false;
        } else if (byte == ')' and depth != 0) {
            depth -= 1;
        }
    }
    return true;
}

fn previousUtf8Boundary(bytes: []const u8, exclusive: usize) ?usize {
    if (exclusive == 0) return null;
    var index = @min(exclusive, bytes.len) - 1;
    while (index != 0 and bytes[index] & 0xc0 == 0x80) index -= 1;
    return index;
}

fn nextUtf8Boundary(bytes: []const u8, offset: usize) usize {
    if (offset >= bytes.len) return bytes.len;
    var index = offset + 1;
    while (index < bytes.len and bytes[index] & 0xc0 == 0x80) index += 1;
    return index;
}

/// A bounded, incremental search over the active screen's complete retained
/// scrollback.
///
/// Initialize this value in place and do not move it: the upstream engine's
/// allocator points at `scratch_allocator` inside the value. `scratch` is
/// borrowed until `deinit`; all query copies, page windows and match metadata
/// live there. Results are copied into caller-owned slices by `scan`, so
/// searching and navigating never copy the whole history and never allocate
/// from Conduit's general allocator on the render path.
///
/// Literal mode delegates page discovery to Ghostty. Regex mode formats one
/// logical line (joining its soft-wrapped physical rows) into the borrowed
/// scratch per candidate and applies a retry/stack-limited Oniguruma search.
/// The caller's scan budget and the logical-row ceiling are therefore hard
/// per-poll caps; neither mode copies complete history.
pub const ScrollbackSearch = struct {
    scratch_allocator: std.heap.FixedBufferAllocator,
    backend: union(SearchKind) {
        literal: Vt.Search,
        regex: RegexBackend,
    },
    terminal: *Terminal,
    case: SearchCase,
    generation: u64,
    exhausted: bool,

    /// Errors that can be caused by caller input or bounded storage.
    pub const Error = ScrollbackSearchError;

    /// Start a search, borrowing `scratch` until `deinit`.
    ///
    /// The first active-area snapshot is taken here. Use `step` with a small
    /// tick budget to search history without monopolising the UI thread.
    pub fn init(
        self: *ScrollbackSearch,
        terminal: *Terminal,
        needle: []const u8,
        case: SearchCase,
        scratch: []u8,
    ) Error!void {
        return self.initWithKind(terminal, needle, case, .literal, scratch);
    }

    /// Start a bounded regex search using the same cursor/page contract as
    /// literal search. A malformed or over-complex pattern is returned as a
    /// normal input error; terminal state is untouched.
    pub fn initRegex(
        self: *ScrollbackSearch,
        terminal: *Terminal,
        pattern: []const u8,
        case: SearchCase,
        scratch: []u8,
    ) Error!void {
        return self.initWithKind(terminal, pattern, case, .regex, scratch);
    }

    fn initWithKind(
        self: *ScrollbackSearch,
        terminal: *Terminal,
        needle: []const u8,
        case: SearchCase,
        kind: SearchKind,
        scratch: []u8,
    ) Error!void {
        if (!terminal.claim()) return error.NotOwned;
        if (needle.len > max_search_needle_bytes) return error.NeedleTooLong;
        if (!std.unicode.utf8ValidateSlice(needle)) return error.InvalidUtf8;

        self.* = .{
            .scratch_allocator = .init(scratch),
            .backend = undefined,
            .terminal = terminal,
            .case = case,
            .generation = terminal.search_generation,
            .exhausted = false,
        };
        switch (kind) {
            .literal => {
                self.backend = .{ .literal = try Vt.Search.init(
                    self.scratch_allocator.allocator(),
                    needle,
                ) };
                errdefer self.backend.literal.deinit(&terminal.vt);
                try self.sync(terminal, true);
            },
            .regex => self.backend = .{ .regex = try RegexBackend.init(needle, case) },
        }
    }

    /// Release the search-owned portions of the borrowed work buffer.
    ///
    /// The terminal must still be alive so tracked page pins can be released.
    pub fn deinit(self: *ScrollbackSearch) void {
        switch (self.backend) {
            .literal => |*engine| engine.deinit(&self.terminal.vt),
            .regex => |*engine| engine.deinit(),
        }
        self.* = undefined;
    }

    /// Reconcile a search after terminal state changed.
    ///
    /// `active_dirty` should be true after output or resize. Passing true when
    /// unsure is correct; it only repeats the small active-area scan. The
    /// generation is captured after the feed so results materialized after
    /// this call can safely drive viewport navigation.
    pub fn sync(
        self: *ScrollbackSearch,
        terminal: *Terminal,
        active_dirty: bool,
    ) Error!void {
        if (terminal != self.terminal) return error.WrongTerminal;
        if (!terminal.claim()) return error.NotOwned;
        self.generation = terminal.search_generation;
        switch (self.backend) {
            .literal => |*engine| {
                if (self.exhausted) return error.SearchScratchExhausted;
                engine.feed(&terminal.vt, active_dirty);

                // Upstream deliberately swallows OOM and retries at the next
                // feed. Fixed scratch cannot recover without a new search.
                if (engine.activeScreenSearch() == null) {
                    self.exhausted = true;
                    return error.SearchScratchExhausted;
                }
            },
            .regex => {},
        }
    }

    /// Advance at most `max_ticks` page-sized units of history work.
    pub fn step(self: *ScrollbackSearch, max_ticks: usize) Error!SearchProgress {
        if (!self.terminal.claim()) return error.NotOwned;
        if (self.generation != self.terminal.search_generation) return error.StaleSearch;
        if (self.exhausted) return .scratch_exhausted;

        const engine = switch (self.backend) {
            .regex => return .complete,
            .literal => |*literal| literal,
        };

        var ticks: usize = 0;
        while (ticks < max_ticks) {
            switch (engine.status()) {
                .complete => return .complete,
                .feed_required => {
                    engine.feed(&self.terminal.vt, false);
                    if (engine.status() == .feed_required) {
                        self.exhausted = true;
                        return .scratch_exhausted;
                    }
                },
                .running => {
                    ticks += 1;
                    const result = engine.tick();
                    // A complete tick while the state remains incomplete is
                    // upstream's OOM path: the error is logged and swallowed.
                    if (result == .complete and engine.status() != .complete) {
                        self.exhausted = true;
                        return .scratch_exhausted;
                    }
                },
            }
        }

        return switch (engine.status()) {
            .complete => .complete,
            .feed_required, .running => .running,
        };
    }

    /// Start a bounded scan at the newest or oldest candidate currently known.
    ///
    /// A newer cursor should normally be requested only once search progress
    /// is complete or exhausted; older candidates may still append while a
    /// running engine is catching up with history.
    pub fn startCursor(
        self: *ScrollbackSearch,
        terminal: *Terminal,
        direction: SearchDirection,
    ) Error!SearchCursor {
        try self.validateTerminal(terminal);
        return switch (self.backend) {
            .literal => .{
                .direction = direction,
                .next_index = switch (direction) {
                    .older => 0,
                    .newer => self.literalCandidateCount(),
                },
                .generation = self.generation,
            },
            .regex => .{
                .direction = direction,
                .next_index = 0,
                .generation = self.generation,
                .regex_row = switch (direction) {
                    .older => if (self.regexRowCount() == 0)
                        null
                    else
                        @intCast(self.regexRowCount() - 1),
                    .newer => if (self.regexRowCount() == 0) null else 0,
                },
                .regex_byte = if (direction == .older) std.math.maxInt(usize) else 0,
            },
        };
    }

    /// Continue immediately beyond one accepted match in `direction`.
    pub fn cursorAfter(
        self: *ScrollbackSearch,
        terminal: *Terminal,
        located: LocatedSearchMatch,
        direction: SearchDirection,
    ) Error!SearchCursor {
        try self.validateTerminal(terminal);
        if (located.match.generation != self.generation) return error.StaleSearch;
        if (located.regex_anchor) |anchor| return .{
            .direction = direction,
            .next_index = 0,
            .generation = self.generation,
            .regex_row = anchor.row,
            .regex_byte = switch (direction) {
                .older => anchor.start_byte,
                .newer => anchor.end_byte,
            },
        };
        return .{
            .direction = direction,
            .next_index = switch (direction) {
                .older => located.candidate_index +| 1,
                .newer => located.candidate_index,
            },
            .generation = self.generation,
        };
    }

    /// Materialize at most `max_candidates` upstream candidates into caller
    /// storage and advance `cursor` for every candidate inspected.
    ///
    /// Items follow the scan direction. Older scans therefore emit canonical
    /// newest-to-oldest order; newer scans emit oldest-to-newest and callers
    /// reverse the bounded page once it is complete. No prefix is revisited;
    /// temporary formatting uses fixed caller scratch, and exact-case or regex
    /// verification consumes the same explicit candidate budget.
    pub fn scan(
        self: *ScrollbackSearch,
        terminal: *Terminal,
        cursor: *SearchCursor,
        max_candidates: usize,
        output: []LocatedSearchMatch,
    ) Error!SearchScan {
        try self.validateTerminal(terminal);
        if (cursor.generation != self.generation) return error.StaleSearch;

        return switch (self.backend) {
            .literal => self.scanLiteral(terminal, cursor, max_candidates, output),
            .regex => self.scanRegex(terminal, cursor, max_candidates, output),
        };
    }

    fn scanLiteral(
        self: *ScrollbackSearch,
        terminal: *Terminal,
        cursor: *SearchCursor,
        max_candidates: usize,
        output: []LocatedSearchMatch,
    ) Error!SearchScan {
        if (cursor.regex_row != null) return error.StaleSearch;

        const available = self.literalCandidateCount();
        var written: usize = 0;
        var examined: usize = 0;
        var stop: SearchScanStop = .budget;
        while (examined < max_candidates and written < output.len) {
            const candidate_index = switch (cursor.direction) {
                .older => blk: {
                    if (cursor.next_index >= available) {
                        stop = .current_boundary;
                        break;
                    }
                    const index = cursor.next_index;
                    cursor.next_index += 1;
                    break :blk index;
                },
                .newer => blk: {
                    if (cursor.next_index == 0) {
                        stop = .current_boundary;
                        break;
                    }
                    cursor.next_index -= 1;
                    break :blk cursor.next_index;
                },
            };
            examined += 1;

            const match = self.materializeCandidate(terminal, candidate_index) catch |err| switch (err) {
                error.SearchScratchExhausted => {
                    stop = .scratch_exhausted;
                    break;
                },
                else => return err,
            } orelse continue;
            output[written] = .{
                .match = match,
                .candidate_index = candidate_index,
                .regex_anchor = null,
            };
            written += 1;
        }

        if (stop == .budget) {
            const at_boundary = switch (cursor.direction) {
                .older => cursor.next_index >= available,
                .newer => cursor.next_index == 0,
            };
            stop = if (at_boundary)
                .current_boundary
            else if (written == output.len)
                .output_full
            else
                .budget;
        }

        return .{
            .items = output[0..written],
            .examined = examined,
            .available_candidates = available,
            .progress = self.progress(),
            .stop = stop,
        };
    }

    fn scanRegex(
        self: *ScrollbackSearch,
        terminal: *Terminal,
        cursor: *SearchCursor,
        max_candidates: usize,
        output: []LocatedSearchMatch,
    ) Error!SearchScan {
        if (cursor.regex_row == null) return .{
            .items = output[0..0],
            .examined = 0,
            .available_candidates = self.regexRowCount(),
            .progress = self.progress(),
            .stop = .current_boundary,
        };

        var written: usize = 0;
        var examined: usize = 0;
        var stop: SearchScanStop = .budget;
        // Formatting a compressed row can require restoring its containing
        // page. Keep an engine-owned cap below the caller's general literal
        // budget so a regex-heavy row cannot monopolise one event-loop poll.
        const attempt_limit = @min(max_candidates, regex_candidate_budget);
        while (examined < attempt_limit and written < output.len) {
            if (cursor.regex_row == null) {
                stop = .current_boundary;
                break;
            }
            examined += 1;
            const located = self.regexAttempt(terminal, cursor) catch |err| switch (err) {
                error.SearchScratchExhausted => {
                    self.exhausted = true;
                    stop = .scratch_exhausted;
                    break;
                },
                else => return err,
            } orelse continue;
            output[written] = located;
            written += 1;
        }

        if (stop == .budget) {
            stop = if (cursor.regex_row == null)
                .current_boundary
            else if (written == output.len)
                .output_full
            else
                .budget;
        }
        return .{
            .items = output[0..written],
            .examined = examined,
            .available_candidates = self.regexRowCount(),
            .progress = self.progress(),
            .stop = stop,
        };
    }

    /// Perform exactly one retry-bounded regex search or one empty-line skip.
    /// The formatted logical line and byte-to-cell map both live in the
    /// caller's fixed scratch and are discarded before this call returns.
    fn regexAttempt(
        self: *ScrollbackSearch,
        terminal: *Terminal,
        cursor: *SearchCursor,
    ) Error!?LocatedSearchMatch {
        const row = cursor.regex_row orelse return null;
        const bounds = try self.regexLineBounds(terminal, row);

        var chunk_count: usize = 0;
        var max_decode_bytes: usize = 0;
        var sizing = bounds.start.pageIterator(.right_down, bounds.end);
        while (sizing.next()) |chunk| {
            chunk_count += 1;
            if (chunk.node.storage() == .compressed) {
                max_decode_bytes = @max(
                    max_decode_bytes,
                    Vt.Page.layout(chunk.node.capacity()).total_size,
                );
            }
        }
        if (chunk_count == 0 or chunk_count > bounds.row_count) {
            return error.RegexEngineFailure;
        }

        const decode_slack = if (max_decode_bytes == 0)
            0
        else
            std.heap.page_size_min - 1;
        const decode_reserve = std.math.add(
            usize,
            max_decode_bytes,
            decode_slack,
        ) catch return error.SearchScratchExhausted;
        if (decode_reserve >= self.scratch_allocator.buffer.len) {
            return error.SearchScratchExhausted;
        }
        const data_len = self.scratch_allocator.buffer.len - decode_reserve;
        const data_buffer = self.scratch_allocator.buffer[0..data_len];
        const decode_buffer = self.scratch_allocator.buffer[data_len..];
        var data = std.heap.FixedBufferAllocator.init(data_buffer);
        const data_alloc = data.allocator();

        const node_runs = data_alloc.alloc(RegexNodeRun, chunk_count) catch
            return error.SearchScratchExhausted;
        const coordinate_slack = @alignOf(Vt.Coordinate) - 1;
        const remaining = data_buffer.len - data.end_index;
        if (remaining <= coordinate_slack) return error.SearchScratchExhausted;
        const bytes_per_subject_byte = 1 + @sizeOf(Vt.Coordinate);
        const subject_capacity = (remaining - coordinate_slack) /
            bytes_per_subject_byte;
        if (subject_capacity == 0) return error.SearchScratchExhausted;

        const subject_storage = data_alloc.alloc(u8, subject_capacity) catch
            return error.SearchScratchExhausted;
        var points = std.ArrayList(Vt.Coordinate).initCapacity(
            data_alloc,
            subject_capacity,
        ) catch return error.SearchScratchExhausted;
        defer points.deinit(data_alloc);
        var bytes: std.Io.Writer = .fixed(subject_storage);
        var trailing: ?Vt.PageFormatter.TrailingState = null;
        var node_run_count: usize = 0;

        var chunks = bounds.start.pageIterator(.right_down, bounds.end);
        while (chunks.next()) |chunk| {
            node_runs[node_run_count] = .{
                .offset = bytes.end,
                .node = chunk.node,
            };
            node_run_count += 1;

            // Compressed pages decode into a tail reserved independently of
            // the growing line buffers. Reinitialising this allocator for
            // every chunk makes the largest single page, rather than every
            // page in the logical line, the storage bound.
            var decode = std.heap.FixedBufferAllocator.init(decode_buffer);
            var preserved = chunk.node.pagePreservingState(decode.allocator()) catch
                return error.SearchScratchExhausted;
            defer preserved.deinit();

            var formatter = Vt.PageFormatter.init(preserved.page(), .{
                .emit = .plain,
                .unwrap = true,
                .trim = true,
            });
            formatter.start_y = chunk.start;
            formatter.end_y = chunk.end - 1;
            formatter.trailing_state = trailing;
            formatter.point_map = .{
                .alloc = data_alloc,
                .map = &points,
                .base = points.items.len,
            };
            trailing = formatter.formatWithState(&bytes) catch
                return error.SearchScratchExhausted;
        }

        const subject = subject_storage[0..bytes.end];
        if (subject.len == 0 or points.items.len != subject.len) {
            self.advanceRegexLine(cursor, bounds);
            return null;
        }

        const backend = switch (self.backend) {
            .regex => |*regex| regex,
            .literal => return error.RegexEngineFailure,
        };
        const found = try backend.search(subject, cursor.direction, cursor.regex_byte);
        const range = switch (found) {
            .mismatch => {
                self.advanceRegexLine(cursor, bounds);
                return null;
            },
            .work_limit => return error.RegexWorkLimit,
            .match => |match| match,
        };
        if (range.start >= subject.len or range.end > subject.len or range.end <= range.start) {
            self.advancePastEmptyRegex(subject, cursor, bounds, range.start);
            return null;
        }

        const first_pin = regexPinAt(
            node_runs[0..node_run_count],
            points.items,
            range.start,
        ) orelse {
            self.advancePastRegex(cursor, bounds, range);
            return null;
        };
        const last_pin = regexPinAt(
            node_runs[0..node_run_count],
            points.items,
            range.end - 1,
        ) orelse {
            self.advancePastRegex(cursor, bounds, range);
            return null;
        };
        const first = terminal.vt.screens.active.pages.pointFromPin(
            .screen,
            first_pin,
        ) orelse {
            self.advancePastRegex(cursor, bounds, range);
            return null;
        };
        const last = terminal.vt.screens.active.pages.pointFromPin(
            .screen,
            last_pin,
        ) orelse {
            self.advancePastRegex(cursor, bounds, range);
            return null;
        };

        self.advancePastRegex(cursor, bounds, range);
        const anchor: RegexAnchor = .{
            .row = bounds.start_row,
            .start_byte = range.start,
            .end_byte = range.end,
        };
        return .{
            .match = .{
                .first = .{ .col = first.screen.x, .row = first.screen.y },
                .last = .{ .col = last.screen.x, .row = last.screen.y },
                .generation = self.generation,
            },
            .candidate_index = @as(usize, first.screen.y) *|
                (@as(usize, std.math.maxInt(u16)) + 1) +| @as(usize, first.screen.x),
            .regex_anchor = anchor,
        };
    }

    fn advancePastRegex(
        self: *ScrollbackSearch,
        cursor: *SearchCursor,
        bounds: RegexLineBounds,
        range: RegexRange,
    ) void {
        switch (cursor.direction) {
            .older => if (range.start == 0) {
                self.advanceRegexLine(cursor, bounds);
            } else {
                cursor.regex_row = bounds.start_row;
                cursor.regex_byte = range.start;
            },
            .newer => {
                cursor.regex_row = bounds.start_row;
                cursor.regex_byte = range.end;
            },
        }
    }

    fn advancePastEmptyRegex(
        self: *ScrollbackSearch,
        subject: []const u8,
        cursor: *SearchCursor,
        bounds: RegexLineBounds,
        offset: usize,
    ) void {
        switch (cursor.direction) {
            .older => if (previousUtf8Boundary(subject, offset)) |previous| {
                cursor.regex_row = bounds.start_row;
                cursor.regex_byte = previous + 1;
            } else {
                self.advanceRegexLine(cursor, bounds);
            },
            .newer => {
                const next = nextUtf8Boundary(subject, offset);
                if (next < subject.len) {
                    cursor.regex_row = bounds.start_row;
                    cursor.regex_byte = next;
                } else self.advanceRegexLine(cursor, bounds);
            },
        }
    }

    fn advanceRegexLine(
        self: *ScrollbackSearch,
        cursor: *SearchCursor,
        bounds: RegexLineBounds,
    ) void {
        switch (cursor.direction) {
            .older => {
                cursor.regex_row = if (bounds.start_row == 0)
                    null
                else
                    bounds.start_row - 1;
                cursor.regex_byte = std.math.maxInt(usize);
            },
            .newer => {
                const next = @as(usize, bounds.end_row) + 1;
                cursor.regex_row = if (next >= self.regexRowCount()) null else @intCast(next);
                cursor.regex_byte = 0;
            },
        }
    }

    fn regexLineBounds(
        self: *ScrollbackSearch,
        terminal: *Terminal,
        row: u32,
    ) Error!RegexLineBounds {
        const pages = &terminal.vt.screens.active.pages;
        const seed = pages.pin(.{ .screen = .{
            .x = 0,
            .y = row,
        } }) orelse return error.RegexEngineFailure;

        var start = seed;
        var start_row = row;
        var row_count: usize = 1;
        while ((try self.regexRowFlags(start)).continuation) {
            if (row_count >= regex_logical_row_limit) {
                return error.RegexWorkLimit;
            }
            start = start.up(1) orelse break;
            start.x = 0;
            start_row -= 1;
            row_count += 1;
        }

        var end = start;
        var end_row = start_row;
        while ((try self.regexRowFlags(end)).wraps) {
            if (row_count >= regex_logical_row_limit) {
                return error.RegexWorkLimit;
            }
            end = end.down(1) orelse break;
            end.x = 0;
            end_row += 1;
            row_count += 1;
        }

        return .{
            .start = start,
            .end = end,
            .start_row = start_row,
            .end_row = end_row,
            .row_count = row_count,
        };
    }

    fn regexRowFlags(
        self: *ScrollbackSearch,
        pin: Vt.Pin,
    ) Error!struct { wraps: bool, continuation: bool } {
        var temporary = std.heap.FixedBufferAllocator.init(
            self.scratch_allocator.buffer,
        );
        var preserved = pin.node.pagePreservingState(temporary.allocator()) catch
            return error.SearchScratchExhausted;
        defer preserved.deinit();
        const row = preserved.page().getRow(pin.y);
        return .{
            .wraps = row.wrap,
            .continuation = row.wrap_continuation,
        };
    }

    fn regexPinAt(
        node_runs: []const RegexNodeRun,
        points: []const Vt.Coordinate,
        offset: usize,
    ) ?Vt.Pin {
        if (offset >= points.len) return null;
        var run_index = node_runs.len;
        while (run_index != 0) {
            run_index -= 1;
            const run = node_runs[run_index];
            if (run.offset > offset) continue;
            const point = points[offset];
            return .{
                .node = run.node,
                .x = point.x,
                .y = @intCast(point.y),
            };
        }
        return null;
    }

    fn regexRowCount(self: *const ScrollbackSearch) usize {
        const total = self.terminal.vt.screens.active.pages.scrollbar().total;
        return @min(total, @as(usize, std.math.maxInt(u32)));
    }

    fn validateTerminal(self: *ScrollbackSearch, terminal: *Terminal) Error!void {
        if (terminal != self.terminal) return error.WrongTerminal;
        if (!terminal.claim()) return error.NotOwned;
        if (self.generation != terminal.search_generation) return error.StaleSearch;
    }

    fn literalCandidateCount(self: *ScrollbackSearch) usize {
        const engine = switch (self.backend) {
            .literal => |*literal| literal,
            .regex => return 0,
        };
        const screen_search = engine.activeScreenSearch() orelse return 0;
        return screen_search.matchesLen();
    }

    fn progress(self: *ScrollbackSearch) SearchProgress {
        if (self.exhausted) return .scratch_exhausted;
        return switch (self.backend) {
            .regex => .complete,
            .literal => |*engine| switch (engine.status()) {
                .complete => .complete,
                .feed_required, .running => .running,
            },
        };
    }

    fn materializeCandidate(
        self: *ScrollbackSearch,
        terminal: *Terminal,
        candidate_index: usize,
    ) Error!?SearchMatch {
        const engine = switch (self.backend) {
            .literal => |*literal| literal,
            .regex => return null,
        };
        const screen_search = engine.activeScreenSearch() orelse return null;
        const highlight = screen_search.matchAt(candidate_index) orelse return null;
        if (self.case == .sensitive and !try self.hasExactCase(highlight)) return null;

        const untracked = highlight.untracked();
        const first = terminal.vt.screens.active.pages.pointFromPin(
            .screen,
            untracked.start,
        ) orelse return null;
        const last = terminal.vt.screens.active.pages.pointFromPin(
            .screen,
            untracked.end,
        ) orelse return null;
        return .{
            .first = .{ .col = first.screen.x, .row = first.screen.y },
            .last = .{ .col = last.screen.x, .row = last.screen.y },
            .generation = self.generation,
        };
    }

    /// Ghostty's literal candidate search is ASCII-insensitive. Re-format the
    /// candidate's bounded cell range and require the original bytes for the
    /// sensitive mode. This keeps one search implementation while preserving
    /// exact case semantics, including matches that cross page boundaries.
    fn hasExactCase(self: *ScrollbackSearch, highlight: Vt.Highlight) Error!bool {
        // A candidate contributes at most the needle plus the unmatched bytes
        // in its two boundary graphemes. The pinned engine limits a grapheme
        // suffix to 64 codepoints; 2 KiB therefore leaves ample space for a
        // 1 KiB query even when both boundaries use four-byte scalars.
        var bytes: [2048]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&bytes);
        var trailing: ?Vt.PageFormatter.TrailingState = null;

        const chunks = highlight.chunks.slice();
        const nodes = chunks.items(.node);
        const starts = chunks.items(.start);
        const ends = chunks.items(.end);
        for (nodes, starts, ends, 0..) |node, start, end, index| {
            // Persistent search allocations grow from the front. A temporary
            // allocator over the untouched tail lets a compressed page decode
            // without consuming that tail permanently (page alignment can
            // otherwise leave padding behind even after `free`). Recreate it
            // per chunk because only the small trailing-state value crosses
            // chunk boundaries.
            var temporary = std.heap.FixedBufferAllocator.init(
                self.scratch_allocator.buffer[self.scratch_allocator.end_index..],
            );
            var preserved = node.pagePreservingState(temporary.allocator()) catch {
                self.exhausted = true;
                return error.SearchScratchExhausted;
            };
            defer preserved.deinit();

            var formatter = Vt.PageFormatter.init(preserved.page(), .{
                .emit = .plain,
                .unwrap = true,
            });
            formatter.start_x = if (index == 0) highlight.top_x else 0;
            formatter.start_y = start;
            formatter.end_x = if (index + 1 == nodes.len) highlight.bot_x else null;
            formatter.end_y = end - 1;
            formatter.trailing_state = trailing;
            trailing = formatter.formatWithState(&writer) catch {
                self.exhausted = true;
                return error.SearchScratchExhausted;
            };
        }

        const engine = switch (self.backend) {
            .literal => |*literal| literal,
            .regex => return false,
        };
        return std.mem.indexOf(u8, bytes[0..writer.end], engine.needle()) != null;
    }
};

/// One wheel or trackpad event, as the platform reported it.
///
/// The three fields are the platform's own vocabulary rather than Conduit's,
/// because the mapping from them to rows is a policy decision this module
/// makes (`ScrollAccumulator.rows`) and the platform should not make it twice.
pub const WheelDelta = struct {
    /// Vertical travel, in whatever unit the device uses: notches for a wheel,
    /// pixels for a trackpad. Positive is away from the user.
    dy: f32 = 0,
    /// Whether the device reported precise, sub-notch motion.
    ///
    /// True for a trackpad and for a high-resolution wheel, false for a
    /// notched one. A notched wheel's `dy` is a step count; a precise device's
    /// is a distance, and treating the second as the first is what makes a
    /// trackpad either useless or uncontrollable.
    precise: bool = false,
    /// Whether the platform inverted the axis, as macOS natural scrolling does.
    flipped: bool = false,
};

/// Where the pointer is, in the units a mouse report needs.
///
/// Carried rather than kept: it is a fact about one event, and a terminal that
/// remembered the last pointer position would be reporting a position the
/// pointer had left.
pub const Pointer = struct {
    /// Position in surface pixels, origin at the top left of the window.
    x: f32 = 0,
    y: f32 = 0,
    /// The window's surface size, so a report can tell "inside" from "outside".
    surface_width_px: u32 = 0,
    surface_height_px: u32 = 0,
    /// One cell's size in surface pixels, so a pixel position names a cell.
    cell_width_px: u32 = 1,
    cell_height_px: u32 = 1,
};

/// Fractional scroll travel carried between events.
///
/// A trackpad reports tenths of a pixel and a terminal moves whole rows, so
/// something has to hold the remainder or a slow, smooth gesture scrolls
/// nothing at all. This is that something: it is the only state the delta
/// mapping has, it is bounded to less than a row, and it resets when the
/// viewport hits an edge so a gesture that ran into the top of the history
/// does not fire a row of scroll in the opposite direction on the way back.
pub const ScrollAccumulator = struct {
    /// Rows of travel not yet turned into a whole row. Always in `(-1, 1)`.
    pending: f32 = 0,

    /// Turn one device delta into whole rows.
    ///
    /// Negative is back into history, matching `Vt.Terminal.scrollViewport`'s
    /// convention, so the caller forwards the answer without inverting it.
    ///
    /// The rules, in order:
    ///
    /// - A delta that is not a number, or is absurd, is refused rather than
    ///   believed. The value came from a driver.
    /// - `flipped` inverts the sign, so macOS natural scrolling scrolls the way
    ///   the user set it rather than the way X11 does.
    /// - A notched wheel multiplies by `lines_per_notch`; a precise device
    ///   divides by `pixels_per_row`.
    /// - The fraction is added to `pending` and the whole rows are taken out of
    ///   it, so ten tenths of a row make one row and two tenths make none.
    pub fn rows(self: *ScrollAccumulator, delta: WheelDelta, config: ScrollConfig) isize {
        // Bounded first, so the bound below is the one that was asked for and
        // the ratio is the one that will be used.
        const bounded = config.bounded();
        if (!std.math.isFinite(delta.dy)) {
            log.warn("a scroll delta of {d} is not a number; the event was ignored", .{delta.dy});
            return 0;
        }
        // A bound, not a guess: a driver reporting a million pixels of travel
        // in one event is broken or hostile, and either way it is not a reason
        // to move the view a million rows.
        const limit: f32 = @floatFromInt(bounded.max_scrollback_lines orelse ScrollConfig.line_ceiling);
        var travel: f32 = std.math.clamp(delta.dy, -limit, limit);
        if (delta.flipped) travel = -travel;

        // Negated on the way out, so the answer is already in the engine's
        // convention: a positive device delta is travel away from the user,
        // which is scrolling *up*, and `scrollViewport` calls up a negative
        // delta. The caller forwards the answer without inverting it, and the
        // sign of `rows` is the sign of "went back into history" everywhere
        // above this file.
        const wanted_rows: f32 = if (delta.precise)
            -travel / bounded.pixels_per_row
        else
            -travel * bounded.lines_per_notch;
        self.pending += wanted_rows;
        // Guard the sum rather than the result. The fraction left behind is
        // bounded by the truncation below rather than by a clamp: clamping the
        // sum first would cap a three-row notch at one row, which is the
        // "wheel does not scroll" bug wearing a bound's clothes.
        if (!std.math.isFinite(self.pending)) {
            log.warn("a scroll delta of {d} overflowed the row accumulator; the event was ignored", .{
                delta.dy,
            });
            self.pending = 0;
            return 0;
        }

        // `@trunc` takes the whole rows and leaves a remainder strictly inside
        // (-1, 1), so a long gesture cannot build up a reserve that fires a
        // screenful of scroll at the end of it.
        const whole: f32 = @trunc(self.pending);
        self.pending -= whole;
        return @intFromFloat(whole);
    }

    /// Forget the carried fraction.
    ///
    /// Called when the viewport could not move as asked, so the next event in
    /// the other direction is answered from zero rather than from a fraction
    /// the edge made meaningless.
    pub fn reset(self: *ScrollAccumulator) void {
        self.pending = 0;
    }
};

/// How the running program asked for mouse events, or that it did not.
///
/// Read from the modes a program sets, never from what Conduit thinks is
/// convenient: the alternative is a terminal that reports a wheel event to a
/// program that never asked, which is the one thing that makes a full-screen
/// application misbehave in a way its author cannot reproduce.
pub const MouseTracking = enum {
    /// The program asked for nothing.
    none,
    /// DECSET 9: button presses of the first three buttons only, and no wheel.
    x10,
    /// DECSET 1000: presses, releases and wheel, no motion.
    press,
    /// DECSET 1002: as 1000 plus motion while a button is held.
    drag,
    /// DECSET 1003: everything, motion included.
    any,

    /// Whether a wheel event is something the program wants to hear about.
    ///
    /// X10 is the exception and it is not a detail: mode 9 reports only the
    /// first three buttons, so a program in that mode has said it does not want
    /// wheel events, and sending them anyway is how a program that only wants
    /// clicks ends up scrolling.
    pub fn reportsWheel(self: MouseTracking) bool {
        return switch (self) {
            .x10 => false,
            .none => false,
            .press, .drag, .any => true,
        };
    }
};

// ---------------------------------------------------------------------------
// What a click selects: the decisions
//
// A drag is unambiguous — it is the cells between two points. A second and a
// third click are not, and the answers below are Conduit's, recorded in one
// place so nobody has to go hunting for them. Each one is what the code does
// today, and each is asserted by a test further down this file or in
// `--mouse-test`; a decision that is only a comment is worth nothing.
//
// **What a word is.** The codepoints in `word_boundaries` are boundaries and
// everything else is not: a double-click selects the run of cells around the
// pointer that are all boundaries or all non-boundaries. There is no Unicode
// word segmentation, no East Asian width rule and no per-language table.
//
//   * Digits, `_`, `.`, `-`, `+`, `=`, `/` and every letter are *inside* a
//     word, so `snake_case`, `12ab`, `v1.2`, `a-b`, `x9` and `src/term.zig`
//     each select whole. A double-click on a path or a dotted filename
//     selecting the path is the point: a user reaching for
//     `src/term.zig` wants that, not `src/` and `term.zig`.
//   * What the list *does* split is shell and URL punctuation: `:`, `|`,
//     `,`, `;`, the brackets, the quotes and `$`. So `e:f` is two words and
//     `$HOME` is a boundary and a word.
//   * A boundary selected directly selects a *boundary run* and never the word
//     beside it: `$HOME` double-clicked on the `$` gives ` $` — the run
//     includes the space in front of it, because a space and a `$` agree about
//     being boundaries — and on the `H` gives `HOME`. Trimming that space is a
//     decision about what to *do* with a selection, which is why
//     `selectionText` hands it over untrimmed.
//   * A CJK ideograph is not a boundary, so an unbroken run of them is one
//     word — the same rule as a 40-letter English word, and for the same
//     reason: there are no spaces to find and inventing boundaries from
//     character width would break every Japanese sentence that has no
//     punctuation in it.
//   * A combining mark is not a cell of its own. It lives on the cell before
//     it, so a double-click on a decomposed `é` selects the base character
//     *and* the marks attached to it: the selection is the grapheme, never
//     half of one.
//
// **A wide character is never half-selected.** A double-click on either half
// of a two-cell glyph selects the same word, because `selectWordCodepoint`
// resolves a wide spacer to the cell that owns it before asking whether it is
// a boundary. The alternative — selecting the half the pointer happened to be
// over — can only ever produce text that was never on the screen.
//
// **Clamping, never wrapping.** A pointer outside the grid clamps to the
// nearest edge (`cellAt`): dragging past the right of the last column is how a
// selection is made to *include* the end of that line, and answering "there is
// no cell there" would end the gesture exactly when the user is reaching for
// something. A selection does not carry on round to the start of the next row
// by itself — it carries on because the pointer has physically moved onto that
// next row, and a soft-wrapped row and the row it wraps onto are one
// continuous run either way.
//
// **Stream unless Alt.** `drag_rectangle` is the decision for one drag: Alt
// held at the press makes it a rectangle, and so does `setBlockSelection` for
// every drag, because Alt+drag is the block selection every other terminal
// binds. A double- or triple-click is *always* a stream selection: the word
// and the line the engine computes carry no rectangle flag, and making them
// into one would mean a rectangle whose corners are word boundaries, which is
// not a thing a user asks for.
//
// **A line is a run, trimmed.** A triple-click selects the whole run of rows a
// line occupies across a soft wrap, with leading and trailing whitespace
// (NUL, space, tab) removed, and stops at a shell integration's prompt
// boundary so that triple-clicking output cannot swallow the next prompt.
// Trailing blank cells are therefore never in a triple-click selection: the
// selection ends on the last cell with text in it.
//
// **What counts as the same click.** `double_click_interval_ns` (500ms, the
// platform figure macOS and Windows use) and `max_distance` of one cell
// width. Two presses further apart than either are two single clicks, and the
// second one clears the selection.
// ---------------------------------------------------------------------------

/// The characters that end a word when a selection is made by double-click.
///
/// Ghostty has this list in `selection_codepoints.zig`, and `lib_vt` does not
/// re-export it, so Conduit carries its own copy rather than reaching past the
/// module boundary for a private constant. The values are Ghostty's defaults,
/// verbatim — whitespace, the quotes, the brackets, and the punctuation a URL,
/// a pipeline or a quoted shell argument is broken into pieces by. It is worth
/// being exact about what is *not* in it: `/` and `.` are not boundaries, so a
/// path and a dotted filename are each one word. See the decisions above.
///
/// Every omission and every entry is spelled out, with what it means, in the
/// decisions above. Digits, `_`, `.` and `/` are the ones that surprise
/// people, so the tests further down assert each of them by what a
/// double-click over it selects rather than by membership in this array.
///
/// TASK-37 makes this configurable; until then this is the list, and it is a
/// `comptime` array so handing it to the gesture allocates nothing.
pub const word_boundaries = [_]u21{
    0, // null: the empty cell a program has not written is a boundary
    ' ',
    '\t',
    '\'',
    '"',
    '│', // U+2502 box drawing: Conduit's own chrome draws with this
    '`',
    '|',
    ':',
    ';',
    ',',
    '(',
    ')',
    '[',
    ']',
    '{',
    '}',
    '<',
    '>',
    '$',
};

/// A pointer button a report has a code for.
///
/// Only the three X11 buttons, because those are the three X10 has codes for.
/// A side button has no code in any format Ghostty's encoder speaks, so there is
/// nothing honest to hand the encoder for one.
pub const Button = enum {
    left,
    middle,
    right,
};

/// What a pointer event did.
pub const ButtonAction = enum {
    /// A button went down.
    press,
    /// A button came up.
    release,
    /// The pointer moved, with or without a button held.
    motion,
};

/// The modifiers a pointer event carried, in the vocabulary a mouse report
/// encodes them in.
///
/// The four the X11 report has bits for. Caps and num lock are deliberately not
/// here: no report format codes them, so carrying them would be a field nothing
/// could ever read.
pub const Mods = packed struct {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
};

/// One pointer event as the terminal's input path receives it: what happened,
/// where, and with what held.
pub const PointerEvent = struct {
    /// What happened.
    action: ButtonAction,
    /// Which button, or null for motion that no button was down for. A motion
    /// with nothing held is a real event in any-event mode (DECSET 1003) and a
    /// real event to a selection gesture, so the difference is carried rather
    /// than guessed from the action.
    button: ?Button = null,
    /// The modifiers that were down.
    mods: Mods = .{},
    /// Whether any button was down at all, for a motion event.
    any_button_pressed: bool = false,
    /// Where the pointer is, and the geometry needed to turn that into a cell.
    pointer: Pointer = .{},
};

/// Who a pointer event belongs to.
///
/// This is the one question a terminal cannot answer from the mouse alone, and
/// Conduit's answer is fixed by CONDUIT.md §7: *Shift overrides a program's
/// mouse capture*. A program in a mouse mode owns the pointer until the user
/// holds shift, at which point the user owns it for as long as they hold it, and
/// the program sees nothing — not a motion, not a release, nothing that could
/// leave a program believing it was still being driven.
///
/// The alternative was to give the program the pointer outright, and it is the
/// one every other implementation rejects: `vim` cannot be dragged out of, its
/// scroll wheel cannot be used to read the output above it, and there is no
/// gesture left to copy anything with. Holding shift is a modifier nobody
/// types into a running program, so the cost to the program is nothing.
pub const PointerOwner = enum {
    /// The user: the event drives a selection.
    user,
    /// The running program: the event becomes a mouse report.
    program,
};

/// The mouse report format a terminal encodes in.
///
/// Ghostty's own enum, named here so `term`'s public surface does not change
/// when upstream adds a format: `lib_vt` exports the encoder and its options
/// but not the format type by name, so this is the field type reached through
/// the options rather than a copy.
pub const MouseFormat = @FieldType(Vt.MouseEncodeOptions, "format");

/// What a pointer event turned into.
pub const PointerOutcome = union(enum) {
    /// Nothing happened and nothing should: the event was for a button the
    /// selection gesture does not use, or for a program that asked for no mouse
    /// events. Named rather than silent so a caller can log it.
    ignored,
    /// The event belonged to the user and changed what is selected.
    selection,
    /// The event belonged to the program and these are the bytes it was sent.
    reported: usize,
};

/// How long after one left press a second one still counts as the same click
/// sequence, in nanoseconds.
///
/// The platform double-click interval, so a click the operating system treats
/// as a double-click is the same click the selection gesture treats as one.
/// Upstream's own default is 400ms; macOS and Windows both use 500ms, and a
/// terminal that answered in 400ms would make a deliberate double-click feel
/// like it had missed.
const double_click_interval_ns: u64 = 500 * std.time.ns_per_ms;

/// Which way a drag has reached past the edge of the window, when it has.
pub const Autoscroll = enum {
    /// Past the top edge: the selection grows towards older output.
    up,
    /// Past the bottom edge: the selection grows towards the prompt.
    down,
};

/// What a wheel event turned into.
///
/// A wheel event has two possible owners and the return says which, because the
/// caller's next move differs: a viewport that moved is a repaint, and bytes
/// for a child are a write to the PTY.
pub const ScrollOutcome = union(enum) {
    /// The viewport moved by this many rows: negative went back into history.
    viewport: isize,
    /// The event belonged to the program and these are the bytes it was sent.
    forwarded: Forwarded,

    /// How the wheel reached the program.
    pub const Forwarded = struct {
        /// Why the program got it rather than the viewport.
        reason: Reason,
        /// How many bytes were written into the caller's buffer. Zero is a real
        /// answer: an alternate-screen program with no mouse tracking and no
        /// cursor keys to spare may be sent nothing.
        bytes: usize,
    };

    /// Why a wheel event went to the program instead of the viewport.
    pub const Reason = enum {
        /// The alternate screen is active and the program asked for mouse
        /// events, so the wheel is a mouse report.
        mouse_report,
        /// The alternate screen is active and the program asked for no mouse
        /// events, so the wheel is arrow keys — which is what xterm, iTerm2,
        /// VTE and Ghostty all do, and what `less` and `nano` are written to
        /// read.
        arrow_keys,
        /// The alternate screen is active and there was nothing to send: no
        /// mouse tracking, and the cursor keys encode to nothing in the mode
        /// the program is in.
        nothing,
    };
};

/// How many events one `feed` can queue before the rest are dropped. A
/// program that rings the bell a thousand times in one write is not a case
/// Conduit needs to represent exactly; `Terminal.droppedEvents` counts what
/// did not fit.
const max_events_per_feed = 32;

/// How many response bytes a terminal will hold for its child. Device answers
/// are small — a device attributes reply is nine bytes, a colour report about
/// thirty — so this leaves room for the answers to a whole frame's worth of
/// queries. A program that floods queries until the queue is full loses the
/// excess, which `Terminal.droppedResponses` counts; a queue that grew instead
/// would let an untrusted program make the terminal allocate without bound.
pub const response_capacity = 4096;

/// A single OSC 52 read response can expand by base64's 4/3 ratio. The queue
/// starts small and grows only for one individually bounded response, so
/// ordinary terminals still pay 4 KiB and query floods cannot grow it.
const max_clipboard_response_bytes = ((max_clipboard_bytes + 2) / 3) * 4 + 16;

/// The bytes the terminal owes the program it is talking to: device
/// attributes replies, colour reports, size reports, anything the engine
/// asked to write to the child during a parse.
///
/// Owned by the terminal's owning thread like every other piece of terminal
/// state, and deliberately not locked. The thread that owns the terminal also
/// owns the PTY in Conduit's architecture (`docs/architecture.md` §5), so the
/// same thread parses the bytes and drains the answers, and a lock here would
/// buy nothing but a syscall per frame. What the lock *cannot* buy is
/// correctness under misuse: a mutex serialises threads that both intend to
/// mutate, whereas the real rule is that only one thread ever should — which
/// is what `Terminal.claim` enforces and counts.
pub const ResponseQueue = struct {
    /// The bytes waiting for the child, oldest first.
    storage: []u8,
    /// How many of `storage` are live. A drain compacts towards the front.
    len: usize = 0,
    /// How many bytes have been dropped because the queue was full.
    dropped: usize = 0,

    /// Why a response queue could not be created.
    pub const Error = Allocator.Error;

    /// A queue that can hold `response_capacity` bytes.
    pub fn create(alloc: Allocator) Error!ResponseQueue {
        return .{ .storage = try alloc.alloc(u8, response_capacity) };
    }

    /// Free the queue's storage. The terminal this belonged to is gone, so
    /// anything still waiting is dropped rather than delivered.
    pub fn destroy(self: *ResponseQueue, alloc: Allocator) void {
        alloc.free(self.storage);
        self.* = undefined;
    }

    /// Append bytes for the child. Called from inside the parser, on the
    /// thread that is feeding.
    ///
    /// Ordinary responses share the fixed 4 KiB queue. A single response may
    /// grow an empty queue up to the OSC 52 bound so an explicitly allowed
    /// clipboard read is not dropped after Ghostty has encoded it. A flood of
    /// small replies never takes this path.
    pub fn append(self: *ResponseQueue, alloc: Allocator, bytes: []const u8) void {
        if (bytes.len == 0) return;
        if (self.len == 0 and bytes.len > self.storage.len and bytes.len <= max_clipboard_response_bytes) {
            self.storage = alloc.realloc(self.storage, bytes.len) catch {
                self.drop(bytes.len);
                return;
            };
        }
        if (self.storage.len - self.len < bytes.len) {
            self.drop(bytes.len);
            return;
        }
        @memcpy(self.storage[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn drop(self: *ResponseQueue, count: usize) void {
        self.dropped += count;
        // Warn once, then stay quiet: a program flooding queries would
        // otherwise produce one line per dropped answer. Only byte counts are
        // logged; a response may contain clipboard contents.
        if (self.dropped == count) {
            log.warn("dropping responses for the child: the queue is full ({d} bytes so far)", .{self.dropped});
        } else {
            log.debug("dropped {d} response bytes for the child ({d} in total)", .{ count, self.dropped });
        }
    }

    /// Copy out up to `dest.len` bytes into a buffer the caller already owns,
    /// oldest first, and report how many were copied. `0` means the terminal
    /// owes nothing. Never blocks and never allocates.
    pub fn take(self: *ResponseQueue, dest: []u8) usize {
        const count = @min(dest.len, self.len);
        @memcpy(dest[0..count], self.storage[0..count]);
        // Compact rather than ring-buffer: a drain happens once per frame and
        // the queue is empty again immediately, so the copy costs nothing and
        // the queue stays a plain readable buffer.
        std.mem.copyForwards(u8, self.storage[0 .. self.len - count], self.storage[count..self.len]);
        self.len -= count;
        return count;
    }

    /// How many bytes are waiting for the child right now.
    pub fn pending(self: *const ResponseQueue) usize {
        return self.len;
    }
};

/// The terminal this thread is currently feeding, so the two effect callbacks
/// Ghostty invokes from inside the parser can reach the `Terminal` that owns
/// the stream. Ghostty hands a callback its `Handler`, whose only pointer is
/// the upstream `Terminal`; this recovers the wrapper around it without
/// assuming anything about a struct's layout.
///
/// Set for the duration of one `feed` and restored afterwards, so it is
/// correct to nest, and it is thread-local because a `Terminal` has exactly
/// one owning thread (`docs/architecture.md` §5).
threadlocal var feeding: ?*Terminal = null;

/// One terminal: the grid, the parser and the state that goes with them.
///
/// Create it in place and destroy it with the same allocator; see the module
/// doc comment for why the address matters.
///
///     var terminal: Terminal = undefined;
///     try terminal.init(io, alloc, .{ .cols = 80, .rows = 24 });
///     defer terminal.deinit(alloc);
///
/// Bytes go in through `feed` and the results come back out through `refresh`
/// and the read-only accessors. There is no separate "render" step and no
/// frame callback: this module has no opinion about frames.
pub const Terminal = struct {
    /// The upstream terminal state: pages, scrollback, modes, title, palette.
    vt: Vt.Terminal,
    /// The parser, held for the terminal's lifetime so that a sequence split
    /// across two reads continues where it left off.
    stream: Vt.Stream,
    /// The cached, denormalised view of the grid that `cell`, `cursor` and
    /// `damage` read. `refresh` is what brings it up to date.
    view: Vt.RenderState,
    /// Scratch for event payloads, reset at the start of every `feed`.
    payload: std.heap.ArenaAllocator,
    /// The allocator borrowed for this terminal's lifetime. Clipboard access
    /// uses it only on explicit requests, never on a frame path.
    allocator: Allocator,
    /// Native clipboard callbacks supplied by the app. Empty by default.
    clipboard_access: ClipboardAccess,
    /// OSC 52 policy, safe by default even before configuration exists.
    clipboard_policies: ClipboardPolicies,
    /// The last OSC 52 request, as the log saw it. Metadata only; see
    /// `ClipboardDiagnostic`.
    last_clipboard: ?ClipboardDiagnostic,
    /// The working directory the shell last reported with an OSC 7 that
    /// passed `decodeWorkingDirectory`, decoded. The first `cwd_len` bytes are
    /// live, and zero means none.
    ///
    /// Inline rather than allocated: upstream caps the report at
    /// `max_working_directory_bytes`, decoding never lengthens it, and a fixed
    /// buffer is a report that cannot fail to be kept.
    cwd: [max_working_directory_bytes]u8,
    /// How many bytes of `cwd` are live.
    cwd_len: usize,
    /// The host a remote shell names in its OSC 7 reports, set by the owner
    /// of a terminal whose program runs on another machine (an SSH session,
    /// decision-8). When `cwd_host_len` is non-zero this name replaces this
    /// machine's own in `decodeWorkingDirectory`'s host check, so the remote
    /// shell's own reports are believed and this machine's name is foreign.
    cwd_host: [std.Io.net.HostName.max_len]u8,
    cwd_host_len: usize,
    /// Whether the shell has marked a step of a command with OSC 133 since
    /// `init` or the last full reset. See `hasSeenPromptMarks`.
    seen_prompt_marks: bool,
    /// The events one `feed` produced, oldest first.
    events: [max_events_per_feed]Event,
    /// How many of `events` are live.
    event_count: usize,
    /// How many events were lost, because the queue filled or a payload could
    /// not be allocated. Never negative, never wraps in practice.
    events_dropped: usize,
    /// The rows of the last `refresh` that changed. Its length is the row
    /// count of the grid, so it always fits every row there is.
    dirty_rows: []u16,
    /// The damage of the last `refresh`, ready for `damage` to hand out.
    frame_damage: Damage,
    /// The grid size as the terminal currently has it.
    size: GridSize,
    /// Whether an allocation failure inside the parser has ever left this
    /// terminal's state short of something it should have applied.
    degraded: bool,
    /// The non-terminal-state half of `KeyModes`; see that type.
    macos_option_as_alt: bool,
    /// The thread that created this terminal, and the only one allowed to
    /// touch the grid, the parser or the modes. See the module doc comment.
    owner: std.Thread.Id,
    /// How many calls reached this terminal from a thread that does not own
    /// it. Always zero in a correct program; it exists so a violation is a
    /// number a test can read rather than a race to reproduce.
    ownership_violations: usize,
    /// The answers this terminal owes the program it is talking to. The one
    /// piece of state a second thread may reach; see `takeResponses`.
    responses: ResponseQueue,
    /// How much history this terminal keeps and how the viewport behaves, and
    /// the one piece of scroll state that is not the engine's: the sub-row
    /// travel a precise device has reported. See `ScrollConfig` and
    /// `ScrollAccumulator`.
    scroll: Scroll,
    /// Whether the engine has been told to return the viewport to the bottom
    /// when output arrives, as the current policy asks for.
    ///
    /// A flag rather than a call into the engine on every `feed`: the decision
    /// is made once, when the policy changes, and `feed` then only has to test
    /// a bool on a path where every instruction is being paid for.
    return_on_output: bool,
    /// The text-selection gesture, upstream's own state machine.
    ///
    /// Held here rather than in `input` because it is not concurrency safe and
    /// it holds a tracked pin inside this terminal's own page list: it belongs
    /// to the terminal's owner thread, and `claim` is the gate. See
    /// `selectionPress`.
    gesture: Vt.SelectionGesture,
    /// Bumped by every change to what is selected.
    ///
    /// A renderer reads this instead of tracking the selection itself: a frame
    /// whose value is unchanged can be skipped even though no cell's content
    /// changed, and a frame whose value moved has to repaint every row the old
    /// selection touched as well as every row the new one does.
    selection_generation: u64,
    /// Bumped whenever full-scrollback search coordinates may have changed.
    ///
    /// Search results are snapshots of page pins mapped to absolute rows. A
    /// conservative bump on every non-empty feed, resize and history-limit
    /// change makes using an old row a recoverable `StaleSearchMatch` instead
    /// of silently scrolling to unrelated output after pruning or reflow.
    search_generation: u64,
    /// Which of the visible cells are selected: one bit per column, row-major,
    /// rebuilt by `refresh` from the engine's tracked pins.
    ///
    /// A bitmask rather than asking the engine per cell because resolving a
    /// tracked pin costs a walk of the page list, and `cell` is called once per
    /// visible cell per frame. Resolving once per frame is also what makes the
    /// answer *the same* for every cell of the frame: a viewport that scrolled
    /// between two cells would otherwise show two different selections.
    selection_bits: []u64,
    /// The number of columns `selection_bits` covers, which is the grid's.
    selection_cols: u16,
    /// Whether `selection_bits` was filled from a selection at all, rather than
    /// left all zero by a refresh that found none.
    ///
    /// Not a second copy of "is something selected" — that is read from the
    /// engine by `hasSelection` — but a cache of what the last `refresh`
    /// projected, because the bitmask is all zero in two different cases and a
    /// cell lookup that cannot tell them apart is a cell lookup that is wrong
    /// one of the times.
    selection_projected: bool,
    /// The cell the last motion report was encoded for.
    ///
    /// Upstream's encoder drops a motion that lands in the cell the last one
    /// landed in, which is what keeps a mouse at rest from filling a program's
    /// input with identical reports. The state is per terminal because that is
    /// what "the last one" means.
    last_mouse_cell: ?Vt.Coordinate,
    /// Whether the drag in progress is a rectangle rather than a stream.
    ///
    /// Recorded when the gesture starts rather than read per event, because a
    /// gesture is one decision: the autoscroll ticks that follow a drag past
    /// the edge of the window have to keep the shape the drag was given, and
    /// re-reading a modifier that came and went mid-drag would silently change
    /// a stream selection into a block one halfway through it.
    ///
    /// **The decision, and what it costs.** A drag is a stream selection
    /// unless Alt (Option on macOS) is held at the press, or
    /// `setBlockSelection` has turned the rectangle on for good. Alt is what
    /// every terminal binds it to — xterm, VTE, iTerm2 and Ghostty all make
    /// Alt+drag a block selection and nothing else — so a user arriving from
    /// any of them gets the rectangle they expect from the same gesture. The
    /// cost is that Alt is the one modifier a selection consumes: a drag that
    /// starts with Alt held is a block selection, and the Alt never reaches
    /// the program because a block selection is by definition the user's.
    drag_rectangle: bool,

    /// Whether a drag makes a block selection rather than a stream one.
    ///
    /// False by default and set by `setBlockSelection`. CONDUIT.md §7 says a
    /// drag is *normal terminal text selection*, so the stream is what a drag
    /// does unless something says otherwise; the capability is wired because it
    /// is the engine's, and turning it on is a keybinding (TASK-20) rather than
    /// a guess made here.
    block_selection: bool,

    /// The scrollback configuration and the delta mapping that uses it.
    ///
    /// Grouped rather than spread over the terminal because they are one
    /// thing: a mapping is meaningless without the ratios it is mapping with,
    /// and a caller that could set one without the other would build a
    /// configuration that cannot be built.
    pub const Scroll = struct {
        /// How much history is kept and what brings the viewport back.
        config: ScrollConfig,
        /// The sub-row travel a trackpad has reported and not yet spent.
        accumulator: ScrollAccumulator = .{},
    };

    /// Why a terminal could not be created, resized, or reached.
    pub const Error = Allocator.Error || pty.Error || error{
        /// The calling thread does not own this terminal. A bug in the caller:
        /// the call was refused and counted in `ownershipViolations` rather
        /// than racing the owner.
        NotOwned,
    };

    /// Create a terminal of `size` cells.
    ///
    /// `io` is borrowed for as long as this terminal lives and must outlive
    /// it; `alloc` owns everything the terminal allocates and is the allocator
    /// `deinit` must be given. The caller must not move the value afterwards.
    pub fn init(self: *Terminal, io: std.Io, alloc: Allocator, size: GridSize) Error!void {
        self.* = .{
            .vt = try Vt.Terminal.init(io, alloc, .{
                .cols = size.cols,
                .rows = size.rows,
            }),
            .stream = undefined,
            .view = .empty,
            .payload = .init(alloc),
            .events = undefined,
            .event_count = 0,
            .events_dropped = 0,
            .dirty_rows = &.{},
            .frame_damage = .none,
            .size = size,
            .degraded = false,
            .macos_option_as_alt = false,
            .allocator = alloc,
            .clipboard_access = .{},
            .clipboard_policies = .{},
            .last_clipboard = null,
            .cwd = undefined,
            .cwd_len = 0,
            .cwd_host = undefined,
            .cwd_host_len = 0,
            .seen_prompt_marks = false,
            .owner = std.Thread.getCurrentId(),
            .ownership_violations = 0,
            .responses = undefined,
            .scroll = .{
                .config = ScrollConfig{},
                .accumulator = .{},
            },
            .return_on_output = false,
            .gesture = .init,
            .selection_generation = 0,
            .search_generation = 0,
            .selection_bits = &.{},
            .selection_cols = size.cols,
            .selection_projected = false,
            .last_mouse_cell = null,
            .block_selection = false,
            .drag_rectangle = false,
        };
        errdefer self.vt.deinit(alloc);

        self.responses = try ResponseQueue.create(alloc);
        errdefer self.responses.destroy(alloc);

        self.dirty_rows = try alloc.alloc(u16, size.rows);
        errdefer alloc.free(self.dirty_rows);

        // One bit per visible cell, allocated once. `refresh` only clears and
        // sets bits, so a frame allocates nothing — this is the hot path the
        // render thread is not allowed to make slower with the allocator.
        self.selection_bits = try alloc.alloc(u64, selectionWords(size.cols, size.rows));
        errdefer alloc.free(self.selection_bits);

        // The defaults are applied to the engine here rather than left to
        // whoever calls `setScrollConfig`, so a terminal that nobody configured
        // still has a real, bounded scrollback: the limit is part of what a
        // terminal is, not something that appears once someone remembers.
        self.applyScrollbackLimits();

        // DEC mode 1007, "alternate scroll": on the alternate screen a wheel
        // becomes cursor keys. xterm, VTE, iTerm2 and Ghostty all have it on by
        // default, and so does this terminal — a full-screen program that asked
        // for no mouse events is asking to be scrolled with the keyboard, and
        // `less` and `nano` are written on that assumption.
        self.vt.modes.set(.mouse_alternate_scroll, true);

        // Upstream's Zig default assumes a shell that redraws its prompt after
        // a resize, and clears the prompt rows on every resize to make room for
        // that redraw. Only its C embedder turns this off. A shell without
        // integration redraws nothing, so the default would erase a real
        // prompt; a shell that can redraw says so with OSC 133 `redraw=`.
        self.vt.flags.shell_redraws_prompt = .false;

        // The effect callbacks are Conduit's only entry points into the
        // parser's inner loop, and they reach this value through `feeding`.
        // Everything Conduit has an opinion about is wired here; everything
        // else stays `.readonly`, so an effect Conduit has not implemented is
        // ignored rather than half-handled.
        var handler: Vt.Handler = self.vt.vtHandler();
        handler.effects.bell = &onBell;
        handler.effects.title_changed = &onTitleChanged;
        handler.effects.clipboard_write = &onClipboardWrite;
        handler.effects.clipboard_read = &onClipboardRead;
        // Shell integration: OSC 7 and OSC 133, and the full reset that
        // forgets both. Upstream stores OSC 7 raw and unvalidated; the
        // validation is `decodeWorkingDirectory`, here.
        handler.effects.pwd_changed = &onPwdChanged;
        handler.effects.semantic_prompt = &onSemanticPrompt;
        handler.effects.reset = &onReset;
        // OSC 9 and OSC 777 desktop notifications (TASK-56). Upstream parses
        // both into one action; the text is cleaned and bounded here.
        handler.effects.desktop_notification = &onDesktopNotification;
        // The response seam: every answer the engine owes the child is queued
        // here rather than written anywhere, because the parse that produces
        // it may not be on the thread that owns the PTY.
        handler.effects.write_pty = &onWritePty;
        handler.effects.device_attributes = &onDeviceAttributes;
        handler.effects.size = &onSize;
        handler.effects.enquiry = &onEnquiry;
        handler.effects.xtversion = &onXtversion;
        self.stream = .init(.{
            .allocator = alloc,
            .handler = handler,
        });
    }

    /// Free everything the terminal holds. The `io` given to `init` is only
    /// borrowed, so it is not touched here.
    pub fn deinit(self: *Terminal, alloc: Allocator) void {
        // The gesture may hold a tracked pin inside the page list, and the page
        // list is about to go: released first, or the pin outlives the pool it
        // was allocated from.
        self.gesture.deinit(&self.vt);
        self.stream.deinit();
        self.view.deinit(alloc);
        self.payload.deinit();
        self.responses.destroy(alloc);
        alloc.free(self.dirty_rows);
        alloc.free(self.selection_bits);
        self.vt.deinit(alloc);
        self.* = undefined;
    }

    /// Whether the calling thread is the one that owns this terminal: the
    /// thread that called `init`. Read it to assert the invariant in a caller
    /// of your own, or to see which thread a value belongs to.
    pub fn ownedByCallingThread(self: *const Terminal) bool {
        return self.owner == std.Thread.getCurrentId();
    }

    /// How many calls have reached this terminal from a thread that does not
    /// own it. Always zero in a correct program: those calls are refused, so
    /// a non-zero count is a bug in the caller, not a race to chase.
    pub fn ownershipViolations(self: *const Terminal) usize {
        return self.ownership_violations;
    }

    /// The gate every method that touches terminal state goes through.
    ///
    /// A call from a thread that does not own the terminal is refused and
    /// counted rather than allowed to run: two threads mutating one parser
    /// produce a terminal that reports corruption, which is far harder to
    /// diagnose than a log line naming the mistake. The read-only accessors
    /// that run per cell per frame deliberately skip this, because the check
    /// would cost more than the read it protects.
    fn claim(self: *Terminal) bool {
        if (self.ownedByCallingThread()) return true;
        self.ownership_violations += 1;
        // Warn once, then stay quiet: a caller looping on the mistake must not
        // turn one bug into a thousand log lines, and the counter is the
        // record. This is a warning rather than an error because the terminal
        // is unharmed — the call was refused, not half-applied — but it is
        // certainly a bug in the caller, and one this module cannot fix.
        if (self.ownership_violations == 1) {
            log.warn("terminal state was touched by a thread that does not own it; the call was refused", .{});
        } else {
            log.debug("terminal state was touched by a thread that does not own it ({d} refusals so far)", .{
                self.ownership_violations,
            });
        }
        return false;
    }

    /// The grid size the terminal currently has. Correct from the moment the
    /// terminal exists, before any `refresh`.
    pub fn gridSize(self: *const Terminal) GridSize {
        return self.size;
    }

    /// Feed bytes read from the PTY into the terminal.
    ///
    /// `bytes` may be any slice at all, including one that stops in the middle
    /// of a UTF-8 sequence, a CSI, an OSC or a DCS: the parser keeps whatever
    /// state it needs and the rest arrives in the next call. It may also be
    /// garbage — a truncated sequence, invalid UTF-8, a CSI parameter with a
    /// thousand digits. Nothing here asserts on the input and nothing fails:
    /// the parser discards what it cannot use and the terminal stays usable.
    ///
    /// Whatever the bytes produced that is not grid content arrives through
    /// `takeEvents` afterwards.
    pub fn feed(self: *Terminal, bytes: []const u8) void {
        if (!self.claim()) return;
        if (bytes.len != 0) self.search_generation +%= 1;
        const outer = feeding;
        feeding = self;
        defer feeding = outer;

        // One feed owns the event queue outright: the queue and its payload
        // buffer describe this write and nothing older.
        self.event_count = 0;
        _ = self.payload.reset(.retain_capacity);

        self.stream.nextSlice(bytes);

        // Ghostty records an allocation failure inside the parser here and
        // keeps going, because a terminal cannot stop mid-stream. Surfacing
        // it is the only honest thing to do with it.
        if (self.stream.handler.semantic_failure) {
            self.stream.handler.semantic_failure = false;
            self.degraded = true;
            log.err("terminal state is degraded: an allocation failed inside the parser", .{});
        }

        // The return policy's half that watches output. It is a flag tested
        // once per feed rather than a call into the engine, and it is tested
        // only when the view is not already at the bottom, because the common
        // case is a terminal the user is watching and there is nothing to do.
        if (self.return_on_output and self.viewport().offset != 0) {
            self.vt.scrollViewport(.{ .bottom = {} });
        }
    }

    /// Change the grid size, keeping the terminal consistent: text reflows or
    /// truncates, the cursor is clamped, and the scroll region is reset.
    ///
    /// The next `refresh` reports `Damage.full`, because the dimensions
    /// changed.
    ///
    /// This moves the terminal only. A live session resizes the child in the
    /// same operation through `resizeChild`, which is what a caller with a PTY
    /// wants; this one is for a terminal with no child behind it.
    pub fn resize(self: *Terminal, alloc: Allocator, size: GridSize) !void {
        if (!self.claim()) return error.NotOwned;
        try self.vt.resize(alloc, .{ .cols = size.cols, .rows = size.rows });
        self.search_generation +%= 1;

        // The damage buffer is sized to the row count, so a terminal that grew
        // rows needs a bigger one before the next `refresh` writes into it.
        if (self.dirty_rows.len != size.rows) {
            const grown = try alloc.alloc(u16, size.rows);
            alloc.free(self.dirty_rows);
            self.dirty_rows = grown;
        }
        // The selection bitmask is sized to the grid, so it has to move with
        // it. The old bits are dropped rather than carried: a resize reflows
        // every row, and the engine's tracked pins are what say where the
        // selection ended up, not the positions they had before.
        const wanted = selectionWords(size.cols, size.rows);
        if (self.selection_bits.len != wanted) {
            const grown = try alloc.alloc(u64, wanted);
            alloc.free(self.selection_bits);
            self.selection_bits = grown;
        }
        self.selection_cols = size.cols;
        self.selection_projected = false;
        self.selection_generation +%= 1;
        self.size = size;
    }

    /// Change the grid size *and* tell the child, in one operation and in a
    /// defined order: the terminal's own state first, then the PTY.
    ///
    /// The order is the point. `pty.resize` delivers `SIGWINCH`, and the first
    /// thing a program does with that is ask the terminal how big it now is —
    /// `CSI 18 t`, or `stty size` — so the state that answers that question
    /// has to be in place *before* the signal goes out. Resizing the PTY first
    /// would let the child ask a terminal that still believes in the old size
    /// and be told a lie. The same order means a failed terminal resize leaves
    /// the child untouched, which the reverse order would not.
    ///
    /// If the PTY resize fails, the terminal keeps the new size: there is
    /// nothing left to keep it consistent with (`error.Closed` means the child
    /// is gone), and the grid is what the window will draw.
    ///
    /// `child` is borrowed for the duration of this call and never stored: its
    /// lifetime belongs to the session, not to the terminal.
    pub fn resizeChild(
        self: *Terminal,
        alloc: Allocator,
        child: pty.Pty,
        size: GridSize,
    ) !void {
        try self.resize(alloc, size);
        try child.resize(pty.WindowSize.init(size.rows, size.cols));
    }

    /// Bring the cached grid view up to date with the terminal state, and
    /// work out what changed since the previous `refresh`.
    ///
    /// Everything read from the terminal afterwards — `cell`, `cursor`,
    /// `damage` — describes the state as of this call, and `cell` borrows
    /// storage this call owns, so a caller that wants to keep cells past the
    /// next frame must copy what it needs out of them.
    pub fn refresh(self: *Terminal, alloc: Allocator) Allocator.Error!void {
        if (!self.claim()) return;
        try self.view.update(alloc, &self.vt);

        // Ghostty's per-row dirty flags are sticky by design — its renderer is
        // the one that clears them — so they are consumed here: whatever is
        // set now describes this refresh and nothing older.
        const range = self.view.rowDataRange();
        const row_dirty = self.view.row_data.items(.dirty);
        var count: usize = 0;
        for (range.start..range.end) |index| {
            const changed = row_dirty[index];
            row_dirty[index] = false;
            if (!changed) continue;
            const y = self.view.viewportY(index);
            if (y < 0 or y >= @as(isize, self.size.rows)) continue;
            self.dirty_rows[count] = @intCast(y);
            count += 1;
        }

        self.frame_damage = switch (self.view.dirty) {
            .full => .full,
            .partial => if (count == 0) .none else .{ .rows = self.dirty_rows[0..count] },
            .false => .none,
        };
        // The global flag is consumed here too; the damage union is where a
        // caller reads it.

        self.view.dirty = .false;

        // The selection is resolved after the view, because resolving a tracked
        // pin means asking the page list where that pin is *now* — which is
        // exactly the question a scrolled viewport changes the answer to.
        self.rebuildSelection();
    }

    /// What changed since the previous `refresh`. Borrows the terminal, and is
    /// replaced by the next `refresh`.
    ///
    /// Damage covers cell content only. A cursor that moved without any text
    /// changing leaves no damage, because the cursor is read separately with
    /// `cursor` and a renderer redraws the two cells it occupies.
    pub fn damage(self: *const Terminal) Damage {
        return self.frame_damage;
    }

    /// The cell at `at`, or null when the cached view does not cover it:
    /// outside the grid, or not yet `refresh`ed at that size.
    ///
    /// The cached view is the authority, not `gridSize`, so a `resize` that has
    /// not been refreshed yet cannot make this read past the view.
    ///
    /// `Cell.grapheme` borrows storage the cached view owns; it stays valid
    /// until the next `refresh` or `deinit`.
    pub fn cell(self: *const Terminal, at: Position) ?Cell {
        if (at.col >= self.view.cols or at.row >= self.view.rows) return null;

        const range = self.view.rowDataRange();
        if (at.row < range.start or at.row >= range.end) return null;

        const row = self.view.row_data.get(at.row);
        const raw = row.cells.items(.raw)[at.col];
        return .{
            .codepoint = raw.codepoint(),
            .grapheme = if (raw.hasGrapheme())
                row.cells.items(.grapheme)[at.col]
            else
                &no_grapheme,
            .wide = raw.wide == .wide,
            .wide_tail = raw.wide == .spacer_tail,
            // A cell's per-cell style is only defined when it carries a
            // non-default style id; id 0 is the default style by definition.
            .style = if (raw.style_id == 0)
                Style.unset
            else
                .fromVt(row.cells.items(.style)[at.col]),
            .selected = self.cellSelected(at),
        };
    }

    /// The OSC 8 metadata attached to the visible cell at `at`, or null when
    /// that cell is outside the last refreshed view or carries no link.
    ///
    /// The metadata is read from Ghostty's owning page, never inferred from the
    /// displayed label. A `.uri` slice is borrowed from that page and is valid
    /// only until the next terminal mutation, `refresh`, or `deinit`. Callers
    /// must therefore use or copy it during the same owner-thread frame in
    /// which they obtained it; like the other read-only cell accessors this
    /// method does not make cross-thread access safe.
    ///
    /// Invalid UTF-8 is reported as `.invalid_utf8` rather than absence. That
    /// distinction lets a caller mask the OSC 8 label from lexical detection
    /// without exposing the malformed target as launchable text.
    pub fn hyperlink(self: *const Terminal, at: Position) ?Hyperlink {
        if (at.col >= self.view.cols or at.row >= self.view.rows) return null;

        const pages = &self.vt.screens.active.pages;
        const pin = pages.pin(.{
            .viewport = .{ .x = at.col, .y = at.row },
        }) orelse return null;
        const page = pin.node.page();
        const linked_cell = pin.rowAndCell().cell;
        if (!linked_cell.hyperlink) return null;

        const link_id = page.lookupHyperlink(linked_cell) orelse return null;
        const link = page.hyperlink_set.get(page.memory, link_id);
        const uri = link.uri.slice(page.memory);
        if (!std.unicode.utf8ValidateSlice(uri)) return .invalid_utf8;
        return .{ .uri = uri };
    }

    /// The valid UTF-8 OSC 8 URI attached to `at`, or null when the cell has no
    /// link, is outside the refreshed viewport, or has an invalid target.
    ///
    /// The returned URI has the same borrowed lifetime as `hyperlink`. Use
    /// `hyperlink` when invalid OSC 8 presence must remain distinguishable from
    /// absence, such as while masking labels from lexical link detection.
    pub fn hyperlinkUri(self: *const Terminal, at: Position) ?[]const u8 {
        const link = self.hyperlink(at) orelse return null;
        return switch (link) {
            .uri => |uri| uri,
            .invalid_utf8 => null,
        };
    }

    /// A byte iterator over the canonical visible-text serialization.
    ///
    /// Copying an iterator copies only traversal state. `visibleTextContains`
    /// uses that property to inspect a candidate match without consuming the
    /// outer scan or allocating a prefix table proportional to the needle.
    const VisibleTextIterator = struct {
        terminal: *const Terminal,
        row: u16 = 0,
        col: u16 = 0,
        row_end: ?u16 = null,
        row_ready: bool = false,
        grapheme: []const u21 = &no_grapheme,
        grapheme_index: usize = 0,
        encoded: [4]u8 = undefined,
        encoded_index: usize = 0,
        encoded_len: usize = 0,

        fn next(self: *VisibleTextIterator) ?u8 {
            while (self.row < self.terminal.view.rows) {
                if (self.encoded_index < self.encoded_len) {
                    const byte = self.encoded[self.encoded_index];
                    self.encoded_index += 1;
                    return byte;
                }

                while (self.grapheme_index < self.grapheme.len) {
                    const codepoint = self.grapheme[self.grapheme_index];
                    self.grapheme_index += 1;
                    if (self.queueScalar(codepoint)) break;
                }
                if (self.encoded_index < self.encoded_len) continue;

                if (!self.row_ready) {
                    var scan_col: u16 = 0;
                    while (scan_col < self.terminal.view.cols) : (scan_col += 1) {
                        const cached = self.terminal.cell(.{
                            .col = scan_col,
                            .row = self.row,
                        }) orelse continue;
                        if (!cached.wide_tail and cached.hasText()) {
                            self.row_end = scan_col;
                        }
                    }
                    self.row_ready = true;
                }

                if (self.row_end) |last| {
                    while (self.col <= last) {
                        const at = Position{ .col = self.col, .row = self.row };
                        self.col += 1;
                        const cached = self.terminal.cell(at) orelse return ' ';
                        if (cached.wide_tail) continue;

                        self.grapheme = cached.grapheme;
                        self.grapheme_index = 0;
                        if (cached.codepoint == 0) return ' ';
                        if (self.queueScalar(cached.codepoint)) break;
                        if (self.grapheme_index < self.grapheme.len) break;
                    }
                    if (self.encoded_index < self.encoded_len) continue;
                    if (self.grapheme_index < self.grapheme.len) continue;
                }

                self.row += 1;
                self.col = 0;
                self.row_end = null;
                self.row_ready = false;
                self.grapheme = &no_grapheme;
                self.grapheme_index = 0;
                if (self.row < self.terminal.view.rows) return '\n';
            }
            return null;
        }

        fn queueScalar(self: *VisibleTextIterator, codepoint: u21) bool {
            self.encoded_index = 0;
            self.encoded_len = encodeVisibleScalar(&self.encoded, codepoint);
            return self.encoded_len != 0;
        }
    };

    fn visibleTextIterator(self: *const Terminal) VisibleTextIterator {
        return .{ .terminal = self };
    }

    /// Write the visible text from the last `refresh` without allocating.
    ///
    /// Empty cells before a row's last textual cell become ASCII spaces;
    /// trailing empty cells are omitted. Wide spacer tails emit nothing, while
    /// a cell's base codepoint and grapheme tail are emitted in that order.
    /// Every cached viewport row is represented, separated by `\n`, with no
    /// newline after the final row. Invalid scalar values in impossible or
    /// corrupt cached state are skipped rather than crashing. The caller must
    /// call `refresh` when it wants newer content or dimensions.
    pub fn writeVisibleText(
        self: *const Terminal,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        var iterator = self.visibleTextIterator();
        while (iterator.next()) |byte| {
            try writer.writeByte(byte);
        }
    }

    /// Whether the visible text from the last `refresh` contains `needle`.
    ///
    /// The searched bytes are exactly those `writeVisibleText` writes. The
    /// search allocates nothing and has no output-size limit; an empty needle
    /// always matches, including in an empty viewport.
    pub fn visibleTextContains(self: *const Terminal, needle: []const u8) bool {
        if (needle.len == 0) return true;

        var iterator = self.visibleTextIterator();
        while (iterator.next()) |byte| {
            if (byte != needle[0]) continue;

            var candidate = iterator;
            var index: usize = 1;
            while (index < needle.len) : (index += 1) {
                const next_byte = candidate.next() orelse break;
                if (next_byte != needle[index]) break;
            }
            if (index == needle.len) return true;
        }
        return false;
    }

    /// Where the cursor is and what shape it has, as of the last `refresh`.
    pub fn cursor(self: *const Terminal) Cursor {
        const view = self.view.cursor;
        return .{
            .position = if (view.viewport) |in_viewport|
                .{ .col = in_viewport.x, .row = in_viewport.y }
            else
                null,
            .shape = .fromVt(view.visual_style),
            .visible = view.visible,
            .blinking = view.blinking,
            .wide_tail = if (view.viewport) |in_viewport| in_viewport.wide_tail else false,
        };
    }

    /// The modes the key encoder needs, as they stand right now. Read after
    /// every `feed`: a program can change any of them in any write.
    pub fn keyModes(self: *const Terminal) KeyModes {
        const options = self.keyEncodeOptions();
        return .{
            .cursor_key_application = options.cursor_key_application,
            .keypad_key_application = options.keypad_key_application,
            .backarrow_key_mode = options.backarrow_key_mode,
            .ignore_keypad_with_numlock = options.ignore_keypad_with_numlock,
            .alt_esc_prefix = options.alt_esc_prefix,
            .modify_other_keys_state_2 = options.modify_other_keys_state_2,
            .kitty_keyboard = .{
                .disambiguate = options.kitty_flags.disambiguate,
                .report_events = options.kitty_flags.report_events,
                .report_alternates = options.kitty_flags.report_alternates,
                .report_all = options.kitty_flags.report_all,
                .report_associated = options.kitty_flags.report_associated,
            },
            .macos_option_as_alt = self.macos_option_as_alt,
        };
    }

    /// The encoder's own options, read from the terminal's state at this
    /// moment. The one mode that is not terminal state — macOS Option-as-Alt —
    /// is filled in here, so `keyModes` and `encodeKey` can never disagree
    /// about which protocol is in force.
    fn keyEncodeOptions(self: *const Terminal) Vt.KeyEncodeOptions {
        var options = Vt.KeyEncodeOptions.fromTerminal(&self.vt);
        options.macos_option_as_alt = if (self.macos_option_as_alt) .true else .false;
        return options;
    }

    /// Encode one key press into the bytes the child behind this terminal
    /// expects to read.
    ///
    /// This is the whole of Conduit's key encoding, and it is a forwarder on
    /// purpose: the encoder is Ghostty's, it reads the terminal's own modes
    /// (`keyEncodeOptions`), and nothing above this file names it. A protocol
    /// Conduit has never heard of therefore works the moment the child asks
    /// for it, with no change here — which is what happened with the Kitty
    /// keyboard protocol: the test below enables it by feeding the escape
    /// sequence a program sends, and the same key then encodes differently.
    ///
    /// The result is written into `out`, which is the caller's own value: a
    /// key press is on the hot path and allocates nothing here. A press that
    /// encodes to nothing leaves `out` empty rather than reporting an error,
    /// because "nothing to send" is what an unidentified key, an unreported
    /// release and every key during composition all mean.
    ///
    ///     var encoded: term.EncodedKey = .{};
    ///     terminal.encodeKey(press, &encoded);
    ///     if (!encoded.isEmpty()) _ = child.write(encoded.slice());
    pub fn encodeKey(self: *const Terminal, press: KeyPress, out: *EncodedKey) void {
        out.len = 0;
        var writer: std.Io.Writer = .fixed(&out.bytes);
        Vt.encodeKey(&writer, press.toVt(), self.keyEncodeOptions()) catch {
            // Only a write that does not fit can fail, and the buffer is
            // larger than the longest sequence the encoder produces. Refusing
            // to invent bytes is the only honest response to the alternative,
            // so say what happened and send nothing.
            log.err("key encoder wrote past {d} bytes; the key was dropped", .{
                max_encoded_key_bytes,
            });
            return;
        };
        out.len = writer.end;
    }

    // --- scrollback and the viewport ---------------------------------------

    /// Replace the scrollback configuration: how much history is kept, how a
    /// device's deltas become rows, and what brings the viewport back to the
    /// bottom.
    ///
    /// Every field is bounded before it is used (`ScrollConfig.bounded`), so a
    /// value that arrived from a configuration file or a future hot reload
    /// cannot ask for a scrollback the machine has no memory for. A clamped
    /// field is logged, because quietly keeping a different limit from the one
    /// that was asked for is the failure this is here to prevent.
    pub fn setScrollConfig(self: *Terminal, config: ScrollConfig) void {
        if (!self.claim()) return;
        const bounded = config.bounded();
        if (bounded.max_scrollback_lines != config.max_scrollback_lines or
            bounded.max_scrollback_bytes != config.max_scrollback_bytes or
            bounded.lines_per_notch != config.lines_per_notch or
            bounded.pixels_per_row != config.pixels_per_row)
        {
            log.warn("the scrollback configuration asked for {} rows, {} bytes, {d} lines per notch and {d} pixels per row; it was clamped to {} rows, {} bytes, {d} and {d}", .{
                config.max_scrollback_lines orelse ScrollConfig.line_ceiling,
                config.max_scrollback_bytes orelse ScrollConfig.byte_ceiling,
                config.lines_per_notch,
                config.pixels_per_row,
                bounded.max_scrollback_lines orelse ScrollConfig.line_ceiling,
                bounded.max_scrollback_bytes orelse ScrollConfig.byte_ceiling,
                bounded.lines_per_notch,
                bounded.pixels_per_row,
            });
        }
        self.scroll.config = bounded;
        self.return_on_output = bounded.return_policy == .on_typing_or_output;
        self.applyScrollbackLimits();
        self.search_generation +%= 1;
    }

    /// The scrollback configuration in force, after bounding.
    pub fn scrollConfig(self: *const Terminal) ScrollConfig {
        return self.scroll.config;
    }

    /// Hand the engine the history limits the configuration asks for.
    ///
    /// The buffer is Ghostty's (`PageList`), and this is the whole of what
    /// Conduit does about its size: a limit is a number the engine enforces
    /// when it grows, and a second copy of the pruning logic here would be two
    /// answers to "how much history is there".
    fn applyScrollbackLimits(self: *Terminal) void {
        self.vt.setScrollbackMaxLines(self.scroll.config.max_scrollback_lines);
        // A request for *no* history cannot be spelled as a line limit of
        // zero, because the engine always keeps at least one page of history
        // whatever the lines say. The engine's own spelling is a byte limit of
        // zero, which erases what is retained as well as preventing more.
        self.vt.setScrollbackMaxBytes(if (self.scroll.config.max_scrollback_lines == 0)
            0
        else
            self.scroll.config.max_scrollback_bytes);
        // Shrinking the history can drop the rows the viewport was pinned to,
        // and the engine then leaves it wherever the clamp put it. The bottom is
        // the only place a view of history that no longer exists can honestly
        // be, so it goes there.
        if (self.viewport().offset != 0) self.vt.scrollViewport(.{ .bottom = {} });
    }

    /// Where the viewport is, relative to the bottom of the history.
    ///
    /// Read back from the engine rather than kept beside it. A cached offset
    /// would be a second answer to the same question, and the question is asked
    /// on every frame by the return policy and by every wheel event by the
    /// delta mapping — two answers that could disagree is how a terminal ends up
    /// claiming it is at the bottom while showing lines from a minute ago.
    pub fn viewport(self: *const Terminal) Viewport {
        const bar = self.vt.screens.active.pages.scrollbar();
        const history = bar.total - bar.len;
        return .{
            .offset = history - bar.offset,
            .history_rows = history,
            .view_rows = bar.len,
        };
    }

    /// Whether the alternate screen is the active one.
    ///
    /// This is the whole of "a full-screen program owns the terminal": the
    /// alternate screen keeps no history by design, so there is nothing for a
    /// wheel to scroll, and Conduit scrolling anyway would be Conduit editing
    /// a program's screen.
    pub fn isAlternateScreen(self: *const Terminal) bool {
        return self.vt.screens.active_key != .primary;
    }

    /// How the running program asked for mouse events, or that it did not.
    pub fn mouseTracking(self: *const Terminal) MouseTracking {
        if (self.vt.modes.get(.mouse_event_any)) return .any;
        if (self.vt.modes.get(.mouse_event_button)) return .drag;
        if (self.vt.modes.get(.mouse_event_normal)) return .press;
        if (self.vt.modes.get(.mouse_event_x10)) return .x10;
        return .none;
    }

    /// The format mouse reports are encoded in, which is the format the running
    /// program asked for, or Conduit's own preference when it asked for none.
    ///
    /// **Conduit prefers SGR (DEC mode 1006).** The decision, and what it does
    /// to a program that wants something else:
    ///
    /// - A program that sets 1005, 1006, 1015 or 1016 gets exactly that. A
    ///   format mode is an explicit choice and is never overridden.
    /// - A program that sets only an event mode — 9, 1000, 1002, 1003 — gets
    ///   SGR. There is no mode that says "x10 please": a program that wants the
    ///   legacy encoding cannot ask for it, because the only thing it can do is
    ///   *not* set 1006, which is also what a program that has never heard of
    ///   1006 does.
    ///
    /// The upgrade is worth it because the legacy encoding has two defects a
    /// real program runs into. X10 reports every release as button 3, so a
    /// program in 1000 mode cannot tell the end of a left drag from a right
    /// click and drops the release's coordinates. And X10 puts the coordinate
    /// in a byte biased by 32, so it cannot express a column past 222: the
    /// report is *silently dropped* on a terminal wider than that, which is
    /// every terminal anyone has used since 1980. `vim` in a 240-column window
    /// loses clicks in the right-hand fifth of the screen under X10 and works
    /// under SGR.
    ///
    /// Every program that implements 1000 implements 1006, because xterm
    /// introduced them together and a program written against one predates the
    /// other by nothing. Ghostty makes exactly this upgrade, so a program
    /// broken by it is broken by Ghostty too and is a program bug.
    pub fn mouseFormat(self: *const Terminal) MouseFormat {
        // Last-set-wins, matching `stream_terminal`'s own mapping of these
        // modes onto `flags.mouse_format`: if more than one is set, the most
        // recently enabled is the one in force, and the order below is the
        // order of that history.
        if (self.vt.modes.get(.mouse_format_sgr_pixels)) return .sgr_pixels;
        if (self.vt.modes.get(.mouse_format_urxvt)) return .urxvt;
        if (self.vt.modes.get(.mouse_format_sgr)) return .sgr;
        if (self.vt.modes.get(.mouse_format_utf8)) return .utf8;
        return .sgr;
    }

    /// Whether the running program has taken the mouse, or the user has taken
    /// it back with Shift.
    ///
    /// CONDUIT.md §7: Shift overrides a program's mouse capture. See
    /// `PointerOwner` for why the user's way round is the only one that works.
    pub fn pointerOwner(self: *const Terminal, mods: Mods) PointerOwner {
        if (mods.shift) return .user;
        return if (self.mouseTracking() == .none) .user else .program;
    }

    /// Make a full-scrollback search result visible, scrolling only when its
    /// range is wholly outside the current viewport.
    ///
    /// The match is placed at the top when scrolling is necessary. Keeping an
    /// already-visible match still avoids disorienting jumps, while an exact
    /// top row gives the caller deterministic following for next/previous
    /// navigation. No allocation or search work occurs here.
    pub fn revealSearchMatch(
        self: *Terminal,
        match: SearchMatch,
    ) SearchNavigationError!bool {
        if (!self.claim()) return error.NotOwned;
        if (match.generation != self.search_generation) return error.StaleSearchMatch;

        const bar = self.vt.screens.active.pages.scrollbar();
        const first: usize = match.first.row;
        const last: usize = match.last.row;
        const viewport_end = bar.offset + bar.len;
        if (last >= bar.offset and first < viewport_end) return false;

        self.vt.scrollViewport(.{ .row = first });
        self.scroll.accumulator.reset();
        return true;
    }

    /// Move the viewport by `rows`: negative goes back into history.
    ///
    /// The engine clamps at both ends, and the clamp is not a failure: a view
    /// asked to go past the top of the history is at the top of the history.
    /// What is *not* kept is the sub-row travel the request carried, because it
    /// described motion that did not happen and firing it on the way back is
    /// how a gesture that hit an edge comes unstuck and runs away.
    pub fn scrollLines(self: *Terminal, rows: isize) void {
        if (!self.claim()) return;
        if (rows == 0) return;
        // Read as travel rather than as position: the offset grows when the
        // view goes back, and a row delta is negative when it goes back, so
        // `before - after` is the movement in the same convention `rows` is in.
        const before = self.viewport().offset;
        self.vt.scrollViewport(.{ .delta = rows });
        const after = self.viewport().offset;
        const moved = @as(isize, @intCast(before)) - @as(isize, @intCast(after));
        if (moved != rows) self.scroll.accumulator.reset();
    }

    /// Pin the viewport to the active area — the bottom of the history.
    pub fn scrollToBottom(self: *Terminal) void {
        if (!self.claim()) return;
        self.vt.scrollViewport(.{ .bottom = {} });
        self.scroll.accumulator.reset();
    }

    /// Pin the viewport to the oldest row still retained.
    pub fn scrollToTop(self: *Terminal) void {
        if (!self.claim()) return;
        self.vt.scrollViewport(.{ .top = {} });
        self.scroll.accumulator.reset();
    }

    /// What a keystroke does to the viewport, which is the policy's whole job.
    ///
    /// Called by the input path when a press is handed to the child. A key is
    /// unambiguous evidence that the user is at the prompt now, which is why
    /// every policy but `.explicit_only` brings the view back; the one that
    /// does not exists for reading a log while it is still being written, where
    /// even the prompt moving is noise.
    pub fn userInput(self: *Terminal) void {
        if (!self.claim()) return;
        switch (self.scroll.config.return_policy) {
            .on_typing, .on_typing_or_output => self.scrollToBottom(),
            .explicit_only => {},
        }
    }

    // -----------------------------------------------------------------------
    // Pointer: reporting to a program, or selecting for the user
    //
    // Everything below is one decision made in one place, for the same reason
    // `scrollByWheel` is: only this module can say whether a program has
    // captured the mouse, what format it asked for, and where a pointer is on
    // the grid. The encoder and the gesture machine are Ghostty's in both
    // cases; what lives here is the choice between them and the geometry that
    // maps a surface pixel to a cell.
    // -----------------------------------------------------------------------

    /// Whether anything is selected, and so whether a copy key should copy
    /// rather than send its control character (CONDUIT.md §7).
    pub fn hasSelection(self: *const Terminal) bool {
        return self.vt.screens.active.selection != null;
    }

    /// A counter that changes whenever what is selected changes, for a
    /// renderer deciding whether a frame has to repaint.
    ///
    /// Wrapping is deliberate and harmless: a renderer compares the value it
    /// last drew with the value now, and two values that happen to be equal
    /// after 2^64 selections are not a frame anyone is still running.
    pub fn selectionGeneration(self: *const Terminal) u64 {
        return self.selection_generation;
    }

    /// Whether every drag makes a block selection rather than a stream one.
    ///
    /// An on/off switch for the rectangle, for a caller that wants one always
    /// or never; see `drag_rectangle` for the per-gesture decision and why Alt
    /// is the modifier that makes it.
    pub fn setBlockSelection(self: *Terminal, block: bool) void {
        if (!self.claim()) return;
        self.block_selection = block;
    }

    /// Drop the selection and end any gesture in progress.
    ///
    /// The gesture is *reset*, not released: a release keeps the click count so
    /// the next press can become a double-click, and a caller that has decided
    /// the click sequence is over — because new output arrived, or because a
    /// program took the mouse — must not have the next press complete it.
    pub fn clearSelection(self: *Terminal) void {
        if (!self.claim()) return;
        self.gesture.reset(&self.vt);
        self.vt.screens.active.clearSelection();
        self.selection_projected = false;
        self.selection_generation +%= 1;
        self.drag_rectangle = false;
    }

    /// The selected text, or null when nothing is selected.
    ///
    /// Reads it back out of the engine rather than out of anything Conduit kept,
    /// so what comes back is what the terminal holds. The caller owns the
    /// returned slice and frees it with the allocator it passes in.
    pub fn selectionText(self: *Terminal, alloc: Allocator) Allocator.Error!?[:0]const u8 {
        if (!self.claim()) return null;
        const selection = self.vt.screens.active.selection orelse return null;
        // The same rule `rebuildSelection` applies, applied before the string is
        // built rather than after: a pin whose page was pruned names text that
        // is gone, and formatting whatever now occupies those cells would hand
        // the caller a copy of something the user never selected.
        if (selection.start().garbage or selection.end().garbage) return null;
        // `trim = false`: the caller asked what is selected, and trimming it is a
        // decision about what to *do* with it. A copy key may want the trimmed
        // text and a test wants the literal selection; both can trim a string
        // that was handed over whole.
        return try self.vt.screens.active.selectionString(alloc, .{
            .sel = selection,
            .trim = false,
        });
    }

    /// Act on one pointer event.
    ///
    /// The single decision every pointer event goes through:
    ///
    /// - A program has captured the mouse (DECSET 9, 1000, 1002 or 1003) and
    ///   the user is not holding Shift: the event is a mouse report, encoded by
    ///   Ghostty's encoder in the format `mouseFormat` chose, and written to
    ///   `out`.
    /// - Otherwise the event is the user's, and it drives the selection gesture.
    ///
    /// The middle and right buttons are named and ignored for selection. Both
    /// have an owner and neither is this task's: the middle button pastes where
    /// the platform is configured to (CONDUIT.md §7, clipboard is TASK-15) and
    /// the right button opens the context menu. Encoding a guess here would put
    /// bytes in a program's input on the strength of a decision nobody made.
    ///
    /// **Stream or block.** A press with Alt held starts a rectangle; see
    /// `drag_rectangle` for why that modifier and not another. Everything else
    /// about the gesture — wrapping at the line end, the word a double-click
    /// takes, the line a triple-click takes — is upstream's, reached through
    /// this one call.
    pub fn pointerEvent(
        self: *Terminal,
        event: PointerEvent,
        time: ?std.Io.Timestamp,
        out: *EncodedKey,
    ) PointerOutcome {
        if (!self.claim()) return .ignored;
        out.len = 0;

        switch (self.pointerOwner(event.mods)) {
            .program => return .{ .reported = self.encodePointerReport(event, out) },
            .user => {},
        }

        // The gesture's shape is settled here, once, and every event that
        // follows reads it: see `drag_rectangle`. Alt is the only modifier that
        // changes it, because Alt+drag is the block selection every other
        // terminal already has. A release clears it, so the next press starts
        // from whatever that press says rather than from the last drag.
        if (event.action == .release) {
            self.drag_rectangle = false;
        } else if (event.mods.alt or self.block_selection) {
            self.drag_rectangle = true;
        }

        // A motion with the left button down extends a drag. Whether one was is
        // carried on the event rather than counted here, because a release
        // outside the window would otherwise leave a drag running for ever.
        switch (event.action) {
            .press => {
                if (event.button != .left) return .ignored;
                return if (self.selectionPress(event.pointer, time)) .selection else .ignored;
            },
            .motion => {
                const left_held = event.any_button_pressed and
                    (event.button == null or event.button == .left);
                if (!left_held) return .ignored;
                return if (self.selectionDrag(event.pointer)) .selection else .ignored;
            },
            .release => {
                if (event.button != .left) return .ignored;
                self.selectionRelease(event.pointer);
                return .selection;
            },
        }
    }

    /// Encode one pointer event as a mouse report, or produce nothing.
    ///
    /// Ghostty's encoder, and its own `shouldReport` is what decides whether
    /// this event is one the mode in force wants to hear about: an X10 report
    /// of a middle click, or a motion in button mode with nothing held, is
    /// dropped upstream rather than being filtered a second time here.
    fn encodePointerReport(self: *Terminal, event: PointerEvent, out: *EncodedKey) usize {
        var options = Vt.MouseEncodeOptions.fromTerminal(&self.vt, mouseEncodeSize(event.pointer));
        // Neither of the two fields the engine fills in here is trusted. See
        // `mouseEncodeEvent` for why the event mode has to come from Conduit's
        // own reading of the modes, and `mouseFormat` for why the format does
        // too: a format mode is an explicit choice and is never overridden, and
        // a program that named no format gets SGR.
        options.event = mouseEncodeEvent(self.mouseTracking());
        options.format = self.mouseFormat();
        options.any_button_pressed = event.any_button_pressed or
            event.action == .press;
        // Motion deduplication lives in this terminal, because "the last report"
        // is per terminal. Without it a mouse resting on one cell would send a
        // program in any-event mode hundreds of identical reports a second.
        options.last_cell = if (event.action == .motion) &self.last_mouse_cell else null;

        var writer: std.Io.Writer = .fixed(&out.bytes);
        Vt.encodeMouse(&writer, .{
            .action = switch (event.action) {
                .press => .press,
                .release => .release,
                .motion => .motion,
            },
            .button = switch (event.button orelse .left) {
                .left => .left,
                .middle => .middle,
                .right => .right,
            },
            .mods = .{
                .shift = event.mods.shift,
                .alt = event.mods.alt,
                .ctrl = event.mods.ctrl,
                .super = event.mods.super,
            },
            .pos = .{ .x = event.pointer.x, .y = event.pointer.y },
        }, options) catch {
            log.err("the mouse encoder wrote past {d} bytes; the report was dropped", .{
                max_encoded_key_bytes,
            });
            out.len = 0;
            return 0;
        };
        out.len = writer.end;
        return out.len;
    }

    /// The grid cell a pointer is over, clamped into the grid.
    ///
    /// **The scroll mapping.** The division is the same one Ghostty's own mouse
    /// encoder makes from a surface pixel to a cell — `floor(max(0, x) / cell
    /// width)`, clamped to the last row and column — so a mouse report and a
    /// selection can never name different cells for the same pixel. Conduit has
    /// no padding around the grid, so there is nothing to subtract first.
    ///
    /// A pointer outside the grid clamps to the nearest edge rather than
    /// producing no cell: dragging past the right of the last row is how a
    /// selection is made to include the end of that line, and returning null
    /// there would make the gesture stop exactly when the user is reaching for
    /// something.
    pub fn cellAt(self: *const Terminal, pointer: Pointer) Position {
        const cols = self.view.cols;
        const rows = self.view.rows;
        // One pixel is the floor for a cell size: a zero here would be divided
        // by, and a grid whose cell has no pixels has no cells to name.
        const width = @as(f64, @floatFromInt(@max(@as(u32, 1), pointer.cell_width_px)));
        const height = @as(f64, @floatFromInt(@max(@as(u32, 1), pointer.cell_height_px)));
        const col: f64 = @min(
            @as(f64, @floatFromInt(cols -| 1)),
            @floor(@as(f64, @max(@as(f64, 0), @as(f64, pointer.x))) / width),
        );
        const row: f64 = @min(
            @as(f64, @floatFromInt(rows -| 1)),
            @floor(@as(f64, @max(@as(f64, 0), @as(f64, pointer.y))) / height),
        );
        return .{
            .col = @intFromFloat(@max(@as(f64, 0), col)),
            .row = @intFromFloat(@max(@as(f64, 0), row)),
        };
    }

    /// The pinned cell a pointer is over, or null when the pointer is not over
    /// the active screen at all.
    ///
    /// The pin is what makes a gesture survive scrolling: it is a reference to a
    /// cell rather than a row number, so when output scrolls the screen the pin
    /// moves with the text it pointed at. A `Position` would silently change
    /// meaning the moment the viewport moved under it.
    fn pinAt(self: *const Terminal, pointer: Pointer) ?Vt.Pin {
        const at = self.cellAt(pointer);
        const pages = &self.vt.screens.active.pages;
        return pages.pin(.{
            .viewport = .{ .x = at.col, .y = at.row },
        });
    }

    /// The geometry the gesture needs from the surface, for one pointer event.
    fn gestureGeometry(self: *const Terminal, pointer: Pointer) Vt.SelectionGesture.Drag.Geometry {
        return .{
            .columns = self.view.cols,
            .cell_width = @max(1, pointer.cell_width_px),
            .padding_left = 0,
            .screen_height = pointer.surface_height_px,
        };
    }

    /// A left press started a click sequence, and applied whatever it selected.
    ///
    /// `time` is what makes a second press a double-click and a third a
    /// triple-click; null means "no clock", and the gesture then treats every
    /// press as a first press. `cell` returns false for a press outside the
    /// grid, which leaves any existing selection alone rather than clearing it:
    /// a click in the window manager's title bar is not a click in the terminal.
    pub fn selectionPress(self: *Terminal, pointer: Pointer, time: ?std.Io.Timestamp) bool {
        if (!self.claim()) return false;
        const pin = self.pinAt(pointer) orelse return false;
        const selection = self.gesture.press(&self.vt, .{
            .time = time,
            .pin = pin,
            .xpos = pointer.x,
            .ypos = pointer.y,
            // One cell: a repeat press further than a cell away is a new
            // gesture, which is what makes double-clicking one word and then
            // double-clicking another two words away work.
            .max_distance = @as(f64, @floatFromInt(pointer.cell_width_px)),
            .repeat_interval = double_click_interval_ns,
            .word_boundary_codepoints = &word_boundaries,
        }) catch |err| {
            // The only failure is the tracked pin's allocation. A selection is
            // not worth ending a terminal over.
            log.warn("a selection gesture could not track its anchor: {s}", .{@errorName(err)});
            return false;
        };
        return self.applySelection(selection);
    }

    /// A drag moved, and applied whatever it now selects.
    pub fn selectionDrag(self: *Terminal, pointer: Pointer) bool {
        if (!self.claim()) return false;
        const pin = self.pinAt(pointer) orelse return false;
        const selection = self.gesture.drag(&self.vt, .{
            .pin = pin,
            .xpos = pointer.x,
            .ypos = pointer.y,
            .rectangle = self.drag_rectangle,
            .word_boundary_codepoints = &word_boundaries,
            .geometry = self.gestureGeometry(pointer),
        });
        return self.applySelection(selection);
    }

    /// One autoscroll step for a drag that has reached past the edge of the
    /// window, and the selection that follows from it.
    ///
    /// The direction is not a parameter: the gesture knows which way it is
    /// being dragged, from the pointer position it was last given, and a caller
    /// that passed one in could only disagree with it. Returns false when
    /// there is nothing to scroll, which is also the signal to stop the timer
    /// driving this — a gesture whose anchor has been scrolled out from under
    /// it resets itself upstream and says so here.
    pub fn selectionAutoscroll(self: *Terminal, pointer: Pointer) bool {
        if (!self.claim()) return false;
        // No anchor is resolved here: the gesture already holds a tracked one,
        // and what this call needs is the cell under the pointer *after* the
        // scroll, which is what `autoscrollTick` recomputes itself.
        const selection = self.gesture.autoscrollTick(&self.vt, .{
            .viewport = .{ .x = self.cellAt(pointer).col, .y = self.cellAt(pointer).row },
            .xpos = pointer.x,
            .ypos = pointer.y,
            .rectangle = self.drag_rectangle,
            .word_boundary_codepoints = &word_boundaries,
            .geometry = self.gestureGeometry(pointer),
        });
        return self.applySelection(selection);
    }

    /// Whether the gesture wants the viewport scrolled, and which way.
    ///
    /// A drag whose pointer is within a pixel of the top or bottom edge of the
    /// window is a drag that has reached past it, and a timer driving
    /// `selectionAutoscroll` is what keeps the selection growing as it does.
    pub fn selectionAutoscrollDirection(self: *Terminal) ?Autoscroll {
        return switch (self.gesture.left_drag_autoscroll) {
            .none => null,
            .up => .up,
            .down => .down,
        };
    }

    /// The left button came up, ending the drag but not the click sequence.
    ///
    /// A release deliberately keeps the click count: that is what lets the next
    /// press become a double-click. `left_click_dragged` is left for a caller to
    /// read, because a click that turned into a drag must not also open a link.
    pub fn selectionRelease(self: *Terminal, pointer: Pointer) void {
        if (!self.claim()) return;
        self.gesture.release(&self.vt, .{ .pin = self.pinAt(pointer) });
    }

    /// Whether the last click became a drag, so a caller knows not to treat it
    /// as a click on whatever is under the pointer.
    pub fn selectionDragged(self: *const Terminal) bool {
        return self.gesture.left_click_dragged;
    }

    /// Put a selection the engine computed into the screen, or clear the screen's
    /// selection when the gesture produced none.
    ///
    /// A null selection from a single click is the gesture's way of saying "there
    /// is nothing selected any more", which is why this clears rather than
    /// leaves the old one: clicking an empty part of the screen is how a user
    /// dismisses a selection.
    fn applySelection(self: *Terminal, selection: ?Vt.Selection) bool {
        const screen = self.vt.screens.active;
        if (selection) |sel| {
            screen.select(sel) catch |err| {
                // Only the tracked pins allocate, and a selection that cannot be
                // tracked is one that cannot survive the next line of output —
                // not worth ending a terminal over.
                log.warn("a selection could not be tracked: {s}", .{@errorName(err)});
                return false;
            };
            self.selection_projected = true;
            self.selection_generation +%= 1;
            return true;
        }
        if (self.hasSelection()) {
            screen.clearSelection();
            self.selection_projected = false;
            self.selection_generation +%= 1;
        }
        return false;
    }

    /// Rebuild the visible-cell bitmask from the engine's selection.
    ///
    /// Two things make this cheap enough for every frame. The pins are *tracked*,
    /// so they are resolved once here rather than once per cell; and the answer
    /// is a range — a stream selection is every cell between its ends, a block
    /// selection is a rectangle — so the bits are set between two corners
    /// rather than by walking the page list per cell.
    ///
    /// Clipping to the viewport is what makes the selection survive scrolling:
    /// the selection is a region of the *buffer*, and this projects that region
    /// onto whatever rows happen to be visible. Scroll back and the same
    /// selection lights up the rows it covers; scroll away and it lights up
    /// none, and comes back when those rows do.
    /// **When new output clears a selection.** It does not, as a rule: the
    /// pins are tracked, so a program printing under a selection leaves the
    /// selection where it was and the text it names moves with it. That is the
    /// property that makes a selection survive a `tail -f`.
    ///
    /// It is dropped in exactly one case: when the engine has pruned the pages
    /// the pins were on. Pruning remaps a pin onto the nearest surviving page
    /// and marks it `garbage`, so the selection would otherwise keep answering
    /// with rows the user never selected — a copy that returns the wrong text is
    /// worse than no selection at all. Clearing here means the next drag or
    /// click starts from nothing, which is the honest state once the selected
    /// text no longer exists.
    fn rebuildSelection(self: *Terminal) void {
        @memset(self.selection_bits, 0);
        const screen = self.vt.screens.active;
        const selection = screen.selection orelse {
            self.selection_projected = false;
            return;
        };

        if (selection.start().garbage or selection.end().garbage) {
            log.debug("the selection was dropped: its rows were pruned out of the scrollback", .{});
            self.clearSelection();
            return;
        }

        const cols = self.view.cols;
        const rows = self.view.rows;
        if (cols == 0 or rows == 0) return;

        // Resolve both ends to viewport coordinates. `pointFromPin` is the only
        // conversion there is, and it is why this runs once per frame and not
        // once per cell.
        //
        // There is a selection; whether any of it is *visible* is a separate
        // question the loops below answer, and both answers leave the projected
        // flag true — a selection scrolled off the screen has to come back when
        // it scrolls on.
        self.selection_projected = true;

        const pages = &screen.pages;
        const start = pages.pointFromPin(.viewport, selection.start()) orelse return;
        const end = pages.pointFromPin(.viewport, selection.end()) orelse return;
        const a = start.coord();
        const b = end.coord();

        if (selection.rectangle) {
            const left = @min(a.x, b.x);
            const right = @max(a.x, b.x);
            const top = @min(a.y, b.y);
            const bottom = @max(a.y, b.y);
            if (top >= rows) return;
            const last = @min(bottom, rows - 1);
            var row: usize = top;
            while (row <= last) : (row += 1) {
                self.setSelectionRow(@intCast(row), @intCast(left), @intCast(right));
            }
        } else {
            if (a.y >= rows) return;
            const last_y = @min(b.y, rows - 1);
            var row = a.y;
            while (row <= last_y) : (row += 1) {
                const left = if (row == a.y) a.x else 0;
                const right = if (row == last_y) b.x else cols - 1;
                self.setSelectionRow(@intCast(row), @intCast(left), @intCast(right));
            }
        }
    }

    /// Set bits for `from..=to` on one visible row.
    fn setSelectionRow(self: *Terminal, row: u16, from: u16, to: u16) void {
        const per_row = (@as(usize, self.selection_cols) + 63) / 64;
        var col = from;
        while (col <= to) : (col += 1) {
            self.selection_bits[@as(usize, row) * per_row + (col / 64)] |=
                @as(u64, 1) << @intCast(col % 64);
        }
    }

    /// Whether the visible cell at `at` is inside the selection, as of the last
    /// `refresh`.
    fn cellSelected(self: *const Terminal, at: Position) bool {
        if (!self.selection_projected) return false;
        if (at.col >= self.selection_cols or at.row >= self.view.rows) return false;
        const per_row = (@as(usize, self.selection_cols) + 63) / 64;
        const word = self.selection_bits[@as(usize, at.row) * per_row + (at.col / 64)];
        return word & (@as(u64, 1) << @intCast(at.col % 64)) != 0;
    }

    /// Turn one wheel event into a scroll or into bytes for the program.
    ///
    /// The decision is made here rather than by the caller because it is a
    /// terminal question: only this module can say whether the alternate
    /// screen is up and what modes the running program has set. `out` receives
    /// the bytes to send to the child when the answer is `.forwarded`, and is
    /// left empty otherwise.
    ///
    /// On the alternate screen the wheel is the program's, and which encoding
    /// it gets follows what the program asked for:
    ///
    /// - Mouse tracking on (DECSET 1000, 1002 or 1003) means a mouse report,
    ///   which is what a full-screen program with a scrollable pane reads to
    ///   know the wheel moved.
    /// - No mouse tracking means cursor keys, which is what `less`, `nano` and
    ///   `vi` are written to read and what xterm, iTerm2, VTE and Ghostty all
    ///   send. It is DEC mode 1007, "alternate scroll", and the engine has it
    ///   on by default for the same reason.
    ///
    /// The viewport is not moved in either case: the alternate screen has no
    /// history, so a scroll would show nothing and would hide a screen the
    /// program drew.
    pub fn scrollByWheel(
        self: *Terminal,
        delta: WheelDelta,
        pointer: Pointer,
        out: *EncodedKey,
    ) ScrollOutcome {
        if (!self.claim()) return .{ .viewport = 0 };
        out.len = 0;

        if (self.isAlternateScreen()) {
            if (self.mouseTracking().reportsWheel()) {
                self.encodeWheelReport(delta, pointer, out);
                return .{ .forwarded = .{ .reason = .mouse_report, .bytes = out.len } };
            }
            if (self.vt.modes.get(.mouse_alternate_scroll)) {
                const sent = self.encodeWheelArrows(delta, out);
                return .{ .forwarded = .{
                    .reason = if (sent == 0) .nothing else .arrow_keys,
                    .bytes = sent,
                } };
            }
            log.debug("a wheel event arrived on the alternate screen with no mouse tracking and no alternate scroll; it was dropped", .{});
            return .{ .forwarded = .{ .reason = .nothing, .bytes = 0 } };
        }

        const rows = self.scroll.accumulator.rows(delta, self.scroll.config);
        if (rows == 0) return .{ .viewport = 0 };
        self.scrollLines(rows);
        return .{ .viewport = rows };
    }

    /// Encode the wheel as a mouse report for a program that asked for one.
    ///
    /// The encoder is Ghostty's, because the report format is a protocol that
    /// grows (X10, UTF-8, SGR, urxvt, SGR-pixels) and a second copy of it here
    /// would be a second thing to keep right.
    fn encodeWheelReport(self: *const Terminal, delta: WheelDelta, pointer: Pointer, out: *EncodedKey) void {
        const travel: f32 = if (delta.flipped) -delta.dy else delta.dy;
        // The same format `pointerEvent` uses, for the same reason: a program
        // that gets a button report in SGR and a wheel report in X10 has two
        // protocols on its input and neither of them is the one it asked for.
        var options = Vt.MouseEncodeOptions.fromTerminal(&self.vt, mouseEncodeSize(pointer));
        // The same two fields the pointer path overrides, for the same two
        // reasons: `mouseEncodeEvent` for the mode a `?1003l` would otherwise
        // have cleared, and `mouseFormat` for the format a program that named
        // one must get.
        options.event = mouseEncodeEvent(self.mouseTracking());
        options.format = self.mouseFormat();
        var writer: std.Io.Writer = .fixed(&out.bytes);
        Vt.encodeMouse(&writer, .{
            .action = .press,
            // Button 4 is the wheel up and button 5 the wheel down. They are
            // buttons 64 and 65 in the report encoding, which is what makes a
            // wheel distinguishable from a click at all.
            .button = if (travel >= 0) .four else .five,
            .pos = .{ .x = pointer.x, .y = pointer.y },
        }, options) catch {
            log.err("the mouse encoder wrote past {d} bytes; the wheel report was dropped", .{
                max_encoded_key_bytes,
            });
            return;
        };
        out.len = writer.end;
    }

    /// Send the wheel to a full-screen program as cursor keys.
    ///
    /// One press per row the wheel asked to move, capped, and encoded through
    /// the terminal's own key encoder — so a program in DECCKM gets `ESC O A`
    /// and a program in the normal mode gets `ESC [ A`. Sending the bytes
    /// directly instead would be a wheel that works in `less` and does nothing
    /// in a program that enabled application cursor keys.
    fn encodeWheelArrows(self: *const Terminal, delta: WheelDelta, out: *EncodedKey) usize {
        // The mapping runs against a copy of the accumulator: a gesture that
        // started on the primary screen and ended over a full-screen program
        // must not leave a partial row behind for the primary screen to spend.
        var motion = self.scroll.accumulator;
        const rows = motion.rows(delta, self.scroll.config);
        if (rows == 0) return 0;
        const key: PhysicalKey = if (rows < 0) .up else .down;
        // One press per row the wheel asked to move, capped. The cap is the
        // buffer and the count together: a trackpad flinging momentum must not
        // be able to make the render thread write thousands of escape
        // sequences into a program that is trying to read them.
        const wanted: usize = @intCast(@min(@abs(rows), @as(isize, @intCast(max_forwarded_keys))));
        var writer: std.Io.Writer = .fixed(&out.bytes);
        var scratch: EncodedKey = .{};
        var sent: usize = 0;
        while (sent < wanted) : (sent += 1) {
            self.encodeKey(.{ .key = key }, &scratch);
            writer.writeAll(scratch.slice()) catch {
                // The buffer is full, which is the cap: a trackpad flinging
                // momentum must not be able to make the render thread write
                // thousands of escape sequences into a program that is trying
                // to read them.
                log.debug("a wheel event sent {d} cursor keys before the buffer filled; the rest was dropped", .{
                    sent,
                });
                break;
            };
        }
        out.len = writer.end;
        return out.len;
    }

    /// Whether the macOS Option key counts as Alt. This is configuration
    /// (TASK-37), not terminal state: no escape sequence sets it, so it is the
    /// one `KeyModes` field a caller has to supply.
    pub fn setMacosOptionAsAlt(self: *Terminal, is_alt: bool) void {
        if (!self.claim()) return;
        self.macos_option_as_alt = is_alt;
    }

    /// Replace the native clipboard adapter used by allowed OSC 52 requests.
    /// The callbacks and their context must outlive this terminal.
    pub fn setClipboardAccess(self: *Terminal, access: ClipboardAccess) void {
        if (!self.claim()) return;
        self.clipboard_access = access;
    }

    /// Set independent OSC 52 read and write policy. The default is `.ask`
    /// for both, which records permission metadata and refuses synchronously.
    pub fn setClipboardPolicies(self: *Terminal, policies: ClipboardPolicies) void {
        if (!self.claim()) return;
        self.clipboard_policies = policies;
    }

    /// The last OSC 52 request and what became of it, exactly as it was
    /// logged, or null when a program has made none. Carries no contents.
    pub fn lastClipboardRequest(self: *const Terminal) ?ClipboardDiagnostic {
        return self.last_clipboard;
    }

    /// Whether DEC mode 2004 is active in the terminal right now.
    pub fn bracketedPasteEnabled(self: *const Terminal) bool {
        return self.vt.modes.get(.bracketed_paste);
    }

    /// Prepare a user-initiated paste using the terminal's actual mode.
    ///
    /// Bracketed paste preserves the payload exactly between `ESC[200~` and
    /// `ESC[201~`. Without mode 2004, any CR or LF requires confirmation; a
    /// confirmed paste is still copied byte-for-byte, never rewritten. Invalid
    /// UTF-8 and terminal control bytes are errors rather than silently
    /// removed. `.encoded` is owned by the caller.
    pub fn preparePaste(
        self: *Terminal,
        alloc: Allocator,
        text: []const u8,
        multiline_confirmed: bool,
    ) PasteError!Paste {
        if (!self.claim()) return error.NotOwned;
        try validateClipboardPayload(text);
        const bracketed = self.bracketedPasteEnabled();
        const multiline = std.mem.indexOfAny(u8, text, "\r\n") != null;
        if (!bracketed and multiline and !multiline_confirmed) return .confirmation_required;

        const frame_bytes = if (bracketed)
            bracketed_paste_prefix.len + bracketed_paste_suffix.len
        else
            0;
        const encoded = try alloc.alloc(u8, text.len + frame_bytes);
        if (bracketed) {
            @memcpy(encoded[0..bracketed_paste_prefix.len], bracketed_paste_prefix);
            @memcpy(encoded[bracketed_paste_prefix.len..][0..text.len], text);
            @memcpy(encoded[bracketed_paste_prefix.len + text.len ..], bracketed_paste_suffix);
        } else {
            @memcpy(encoded, text);
        }
        return .{ .encoded = encoded };
    }

    /// The title the running program last set with OSC 0 or OSC 2, or null
    /// when it has set none. Borrows the terminal; the copy handed out by a
    /// `title` event is the one to keep.
    pub fn title(self: *const Terminal) ?[]const u8 {
        return self.vt.getTitle();
    }

    /// The working directory the shell last reported with OSC 7, decoded, or
    /// null when it has reported none, cleared it, or the terminal was reset.
    ///
    /// Only a report that passed `decodeWorkingDirectory` lands here: a
    /// `file` or `kitty-shell-cwd` URL naming `localhost` or this machine's
    /// own host name. Anything else — a remote shell, a URL that names some
    /// other host, a path with a NUL in it — is ignored and the previous value
    /// stands. The path is not normalised (`..` is a real directory name) and
    /// not checked against the file system: it is what the shell said, and it
    /// is display data. Nothing in Conduit acts on it (CONDUIT.md §11).
    ///
    /// Borrows the terminal until the next `feed`; the copy handed out by a
    /// `working_directory` event is the one to keep.
    pub fn workingDirectory(self: *const Terminal) ?[]const u8 {
        if (self.cwd_len == 0) return null;
        return self.cwd[0..self.cwd_len];
    }

    /// Accept OSC 7 reports that name `host` instead of this machine, for a
    /// terminal whose shell runs on that host (an SSH session). `localhost`
    /// stays accepted: on the remote side it names the remote machine. A
    /// name that is empty or longer than a host name can be is refused and
    /// changes nothing. The path is still only display data and is never
    /// resolved locally.
    pub fn setWorkingDirectoryHost(self: *Terminal, host: []const u8) error{InvalidHost}!void {
        if (host.len == 0 or host.len > self.cwd_host.len) return error.InvalidHost;
        @memcpy(self.cwd_host[0..host.len], host);
        self.cwd_host_len = host.len;
    }

    /// Whether the cursor sits in a prompt or in the user's input rather than
    /// in a command's output, by the shell's own OSC 133 marks. Always false
    /// on the alternate screen and for a shell that sends no marks, so a
    /// caller cannot mistake "no integration" for "at a prompt".
    pub fn cursorIsAtPrompt(self: *const Terminal) bool {
        // Upstream's predicate is read-only but declared on a mutable
        // pointer; it reads the cursor's row and content tag and writes
        // nothing, so the cast does not let a const caller mutate anything.
        return @constCast(&self.vt).cursorIsAtPrompt();
    }

    /// Whether the shell has marked any step of a command with OSC 133 since
    /// the terminal was created or last fully reset.
    ///
    /// The gate for a jump-to-prompt: the engine's walk over prompt marks has
    /// to read the whole scrollback to find that there are none, so a caller
    /// asks this first and skips the walk when the answer is no. A yes means
    /// marks may exist, not that one is still in the history: scrollback that
    /// held them can since have been pruned.
    pub fn hasSeenPromptMarks(self: *const Terminal) bool {
        return self.seen_prompt_marks;
    }

    /// The screen rows where a prompt starts, oldest first, written into
    /// `rows`; returns how many were written. Rows count from the top of the
    /// retained history, so they stay meaningful while the viewport scrolls.
    ///
    /// This is what a jump-to-prompt reads. A shell that sends no OSC 133
    /// marks has no prompt rows, and neither has the alternate screen. Rows
    /// beyond `rows.len` are not reported: the caller sizes the buffer, and
    /// nothing is allocated here.
    pub fn promptRows(self: *const Terminal, rows: []u32) usize {
        if (!self.seen_prompt_marks or rows.len == 0) return 0;
        const pages = &self.vt.screens.active.pages;
        var iterator = pages.promptIterator(.right_down, .{ .screen = .{} }, null);
        var count: usize = 0;
        while (iterator.next()) |pin| {
            const at = pages.pointFromPin(.screen, pin) orelse continue;
            rows[count] = at.screen.y;
            count += 1;
            if (count == rows.len) break;
        }
        return count;
    }

    /// The events the last `feed` produced, oldest first, and empties the
    /// queue. The returned slice and any `title` payload it borrows are valid
    /// until the next `feed`.
    pub fn takeEvents(self: *Terminal) []const Event {
        if (!self.claim()) return &.{};
        const taken = self.events[0..self.event_count];
        self.event_count = 0;
        return taken;
    }

    /// Copy out the bytes the terminal owes the program it is talking to —
    /// device attributes replies, colour reports, cursor position reports,
    /// XTWINOPS size reports, whatever a `feed` produced that was not grid
    /// content — oldest first, into a buffer the caller already owns.
    ///
    /// Returns how many bytes were copied; `0` means the terminal owes
    /// nothing. This is the mirror of `Pty.takeBytes`: it never blocks, never
    /// allocates, and never drops a byte it has not handed over, so a caller
    /// can drain in as many steps as it likes without losing order.
    ///
    /// The owner thread takes the answers and writes them to the PTY it also
    /// owns, in that order, between feeding the child and refreshing the
    /// grid. That is the whole contract: the bytes leave `term` as data, and
    /// the one thread allowed to write the PTY is the one that receives them.
    pub fn takeResponses(self: *Terminal, dest: []u8) usize {
        if (!self.claim()) return 0;
        return self.responses.take(dest);
    }

    /// How many response bytes are waiting for the child right now. Reads the
    /// same queue `takeResponses` drains, and is how a caller tells an idle
    /// terminal from one that owes something without copying it out.
    pub fn pendingResponses(self: *Terminal) usize {
        if (!self.claim()) return 0;
        return self.responses.pending();
    }

    /// How many response bytes have been dropped, across the terminal's whole
    /// life, because the queue was full. A non-zero count means a program
    /// asked more questions than the queue could hold before the caller
    /// drained it; the terminal itself is fine.
    pub fn droppedResponses(self: *Terminal) usize {
        if (!self.claim()) return 0;
        return self.responses.dropped;
    }

    /// How many events have been dropped, across the terminal's whole life.
    /// A non-zero count means the queue or an allocation failed, not that the
    /// terminal is broken.
    pub fn droppedEvents(self: *const Terminal) usize {
        return self.events_dropped;
    }

    /// Whether an allocation failure has ever stopped the parser from applying
    /// something it should have. Once true it stays true: the grid may be
    /// missing an update and a session is the thing to restart, not this
    /// predicate.
    pub fn isDegraded(self: *const Terminal) bool {
        return self.degraded;
    }

    /// Whether the running program asked to be told about focus changes, with
    /// DEC mode 1004. Off by default, and a program that has not asked is
    /// never sent a focus report however often the window changes — that is
    /// what makes the report worth having on the child's input at all.
    pub fn focusReportingEnabled(self: *const Terminal) bool {
        return self.vt.modes.get(.focus_event);
    }

    fn record(self: *Terminal, event: Event) void {
        if (self.event_count == self.events.len) {
            self.events_dropped += 1;
            log.debug("terminal event dropped: one feed produced more than {d}", .{
                self.events.len,
            });
            return;
        }
        self.events[self.event_count] = event;
        self.event_count += 1;
    }
};

/// Ghostty calls this from inside the parser when the program rings the bell.
fn onBell(_: *Vt.Handler) void {
    const terminal = feeding orelse return;
    terminal.record(.bell);
}

/// Ghostty calls this from inside the parser once the program's new title is
/// already in the terminal state. The title is copied because the terminal
/// only ever holds the most recent one, and a single write can set several.
fn onTitleChanged(handler: *Vt.Handler) void {
    const terminal = feeding orelse return;
    const title = handler.terminal.getTitle() orelse "";
    const owned = terminal.payload.allocator().dupe(u8, title) catch {
        // The callback runs mid-parse and cannot report an error, and a
        // dropped title leaves the terminal perfectly usable: the title is
        // still readable with `title`. Counted rather than swallowed.
        terminal.events_dropped += 1;
        log.debug("terminal event dropped: a title did not fit in memory", .{});
        return;
    };
    terminal.record(.{ .title = owned });
}

/// Ghostty calls this from inside the parser once an OSC 7 report is in its
/// state, stored raw. The report is validated and decoded here, and only one
/// that passes replaces the working directory; a refused one changes nothing
/// and produces no event. Upstream's raw copy never leaves this module.
fn onPwdChanged(handler: *Vt.Handler) void {
    const terminal = feeding orelse return;
    const url: []const u8 = handler.terminal.getPwd() orelse "";
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    var decoded: [max_working_directory_bytes]u8 = undefined;
    const expected_host = if (terminal.cwd_host_len != 0)
        terminal.cwd_host[0..terminal.cwd_host_len]
    else
        localHostName(&host_buffer);
    const path = decodeWorkingDirectory(url, expected_host, &decoded) catch |err| {
        // The reason, and never the URL: the URL is the program's text.
        log.debug("OSC 7 working directory ignored: {s}", .{@errorName(err)});
        return;
    };
    @memcpy(terminal.cwd[0..path.len], path);
    terminal.cwd_len = path.len;

    const owned = terminal.payload.allocator().dupe(u8, path) catch {
        // As for a title: the directory is still readable with
        // `workingDirectory`, so only the event is lost, and it is counted.
        terminal.events_dropped += 1;
        log.debug("terminal event dropped: a working directory did not fit in memory", .{});
        return;
    };
    terminal.record(.{ .working_directory = owned });
}

/// Ghostty calls this once an OSC 133 mark is already applied to the grid.
/// The mark itself stays on the row it was made on, where a jump-to-prompt
/// will find it; this records that one exists and reports the step.
fn onSemanticPrompt(_: *Vt.Handler, step: Vt.SemanticPrompt) void {
    const terminal = feeding orelse return;
    const kind: PromptMark.Kind = switch (step.kind) {
        // Upstream never reports it; it exists so a zeroed C value is not
        // mistaken for a real step.
        .invalid => return,
        .prompt_start => .prompt_start,
        .input_start => .input_start,
        .output_start => .output_start,
        .command_end => .command_end,
    };
    terminal.seen_prompt_marks = true;
    terminal.record(.{ .prompt = .{
        .kind = kind,
        .exit_code = if (kind == .command_end) step.exit_code else null,
    } });
}

/// Ghostty calls this after a full reset (RIS) has already cleared the
/// screen, the scrollback, the title and its raw working directory, without
/// calling `onTitleChanged` or `onPwdChanged` for any of it.
fn onReset(handler: *Vt.Handler) void {
    const terminal = feeding orelse return;
    terminal.cwd_len = 0;
    // The scrollback that held every mark is gone, so the gate goes with it.
    terminal.seen_prompt_marks = false;
    // A reset restores upstream's flag defaults, and its default is the one
    // `init` turned off; see there.
    handler.terminal.flags.shell_redraws_prompt = .false;
    terminal.record(.reset);
}

/// Ghostty calls this for a complete OSC 9 or OSC 777 notification. The
/// texts are copied, cleaned and bounded into the per-feed payload; when that
/// arena is out of memory the event is dropped and counted like a title.
fn onDesktopNotification(_: *Vt.Handler, notification: Vt.DesktopNotification) void {
    const terminal = feeding orelse return;
    var title_buffer: [max_notification_title_bytes]u8 = undefined;
    var body_buffer: [max_notification_body_bytes]u8 = undefined;
    const title = sanitizeNotificationText(&title_buffer, notification.title);
    const body = sanitizeNotificationText(&body_buffer, notification.body);
    const allocator = terminal.payload.allocator();
    const owned_title = allocator.dupe(u8, title.text) catch return dropNotification(terminal);
    const owned_body = allocator.dupe(u8, body.text) catch return dropNotification(terminal);
    terminal.record(.{ .notification = .{
        .title = owned_title,
        .body = owned_body,
        .truncated = title.truncated or body.truncated,
    } });
}

fn dropNotification(terminal: *Terminal) void {
    terminal.events_dropped += 1;
    log.debug("terminal event dropped: a notification did not fit in memory", .{});
}

fn clipboardLocation(location: Vt.ClipboardLocation) ClipboardLocation {
    return switch (location) {
        .standard => .standard,
        .selection => .selection,
        .primary => .primary,
        _ => .standard,
    };
}

/// Log one OSC 52 request and keep it as the terminal's last one.
///
/// The only place an OSC 52 request is logged. It takes a
/// `ClipboardDiagnostic`, which has nowhere to put contents, so no caller can
/// log a payload through it. Kept on the terminal as well so the tests can
/// assert on the exact line a request produced rather than on the absence of
/// a line they cannot see.
fn noteClipboard(terminal: *Terminal, diagnostic: ClipboardDiagnostic) void {
    terminal.last_clipboard = diagnostic;
    log.debug("{f}", .{diagnostic});
}

/// Handle an OSC 52 write after Ghostty has parsed and base64-decoded it.
///
/// Every outcome goes through `noteClipboard`, which logs the operation, the
/// destination, the outcome and the byte count — never the contents.
fn onClipboardWrite(_: *Vt.Handler, op: Vt.ClipboardWrite) void {
    const terminal = feeding orelse return;
    const location = clipboardLocation(op.location);
    var diagnostic: ClipboardDiagnostic = .{
        .operation = .write,
        .location = location,
        .outcome = .unsupported,
        .byte_count = null,
    };
    const text: []const u8 = text: {
        if (op.contents.len == 0) break :text "";
        for (op.contents) |content| {
            if (Vt.isTextMime(content.mime)) break :text content.data;
        }
        noteClipboard(terminal, diagnostic);
        op.reply(.unsupported);
        return;
    };
    diagnostic.byte_count = text.len;

    validateClipboardPayload(text) catch {
        diagnostic.outcome = .invalid;
        noteClipboard(terminal, diagnostic);
        op.reply(.invalid_data);
        return;
    };

    switch (terminal.clipboard_policies.write) {
        .deny => {
            diagnostic.outcome = .denied;
            op.reply(.denied);
        },
        .ask => {
            terminal.record(.{ .permission_request = .{
                .operation = .write,
                .location = location,
                .byte_count = text.len,
            } });
            diagnostic.outcome = .asked;
            op.reply(.denied);
        },
        .allow => allow: {
            const write = terminal.clipboard_access.write_fn orelse {
                op.reply(.unsupported);
                break :allow;
            };
            write(terminal.clipboard_access.context, location, text, terminal.allocator) catch |err| {
                diagnostic.outcome = switch (err) {
                    error.Unsupported => .unsupported,
                    error.PayloadTooLarge, error.InvalidText => .invalid,
                    error.OutOfMemory, error.Unavailable => .failed,
                };
                op.reply(switch (err) {
                    error.Unsupported => .unsupported,
                    error.PayloadTooLarge, error.InvalidText => .invalid_data,
                    error.OutOfMemory, error.Unavailable => .io_error,
                });
                break :allow;
            };
            diagnostic.outcome = .written;
            op.reply(.{ .success = .{} });
        },
    }
    noteClipboard(terminal, diagnostic);
}

/// Handle an OSC 52 read synchronously. `.ask` and `.deny` answer with an
/// empty OSC 52 response (Ghostty's encoding of a refusal); only `.allow`
/// opens the native clipboard adapter.
fn onClipboardRead(_: *Vt.Handler, op: Vt.ClipboardRead) void {
    const terminal = feeding orelse return;
    const location = clipboardLocation(op.location);
    var diagnostic: ClipboardDiagnostic = .{
        .operation = .read,
        .location = location,
        .outcome = .unsupported,
        .byte_count = null,
    };
    switch (terminal.clipboard_policies.read) {
        .deny => {
            diagnostic.outcome = .denied;
            op.reply(.denied);
        },
        .ask => {
            terminal.record(.{ .permission_request = .{
                .operation = .read,
                .location = location,
                .byte_count = null,
            } });
            diagnostic.outcome = .asked;
            op.reply(.denied);
        },
        .allow => allow: {
            const read = terminal.clipboard_access.read_fn orelse {
                op.reply(.unsupported);
                break :allow;
            };
            const text = read(terminal.clipboard_access.context, location, terminal.allocator) catch |err| {
                diagnostic.outcome = if (err == error.Unsupported) .unsupported else .failed;
                op.reply(switch (err) {
                    error.Unsupported => .unsupported,
                    error.OutOfMemory, error.Unavailable, error.PayloadTooLarge, error.InvalidText => .io_error,
                });
                break :allow;
            };
            defer terminal.allocator.free(text);
            diagnostic.byte_count = text.len;
            validateClipboardPayload(text) catch {
                diagnostic.outcome = .invalid;
                op.reply(.io_error);
                break :allow;
            };
            const contents = [_]Vt.ClipboardContent{.{ .mime = "text/plain", .data = text }};
            diagnostic.outcome = .read;
            op.reply(.{ .success = .{ .contents = &contents } });
        },
    }
    noteClipboard(terminal, diagnostic);
}

/// Ghostty calls this from inside the parser whenever the engine owes the
/// program bytes: a device attributes reply, a colour report, a size report,
/// DECRQSS, a kitty graphics acknowledgement. This is the seam — the bytes
/// are queued on the terminal and read out with `takeResponses`, never
/// written to anything from inside a parse.
///
/// The slice is only valid for this call, which is why it is copied straight
/// into the queue rather than borrowed.
fn onWritePty(_: *Vt.Handler, bytes: []const u8) void {
    const terminal = feeding orelse return;
    terminal.responses.append(terminal.allocator, bytes);
}

/// What Conduit says it is when a program asks. A VT220-level terminal that
/// understands ANSI colour, which is exactly what this module implements —
/// a claim Conduit has not earned is a claim that lies to a program deciding
/// whether it can use colour.
fn onDeviceAttributes(_: *Vt.Handler) Vt.DeviceAttributes.Attributes {
    return .{};
}

/// The grid as the engine is reporting it, in cells. Read from the engine's
/// own fields rather than through `feeding`, so the answer is right even if
/// the engine asks outside a `feed`.
///
/// The cell's pixel size is zero because `term` has no font metrics and no
/// reason to invent any — the same answer `pty.WindowSize` gives the OS. A
/// program asking about cells, which is what `CSI 18 t` and mode 2048 come
/// down to in practice, is answered exactly; one asking about pixels is told
/// zero rather than a number Conduit made up.
fn onSize(handler: *Vt.Handler) ?Vt.SizeReport {
    return .{
        .rows = handler.terminal.rows,
        .columns = handler.terminal.cols,
        .cell_width = 0,
        .cell_height = 0,
    };
}

/// ENQ (0x05) asks the terminal to identify itself. Conduit has nothing to
/// say beyond what the device attributes already said, so the response is
/// empty, which the engine treats as no reply at all.
fn onEnquiry(_: *Vt.Handler) []const u8 {
    return "";
}

/// XTVERSION asks which terminal this is. Answering "conduit" is the honest
/// minimum; the engine's own default would answer "libghostty", which is a
/// different product wearing this terminal's clothes.
fn onXtversion(_: *Vt.Handler) []const u8 {
    return "conduit";
}

test "a grid is never zero-sized, and its cell count fits" {
    const testing = std.testing;

    try testing.expectError(error.EmptyGrid, GridSize.init(0, 24));
    try testing.expectError(error.EmptyGrid, GridSize.init(80, 0));
    try testing.expectError(error.EmptyGrid, GridSize.init(0, 0));

    const size = try GridSize.init(80, 24);
    try testing.expectEqual(@as(u16, 80), size.cols);
    try testing.expectEqual(@as(u16, 24), size.rows);
    try testing.expectEqual(@as(u32, 1920), size.cells());

    // The largest legal grid still produces a count the caller can use.
    const largest = try GridSize.init(std.math.maxInt(u16), std.math.maxInt(u16));
    try testing.expectEqual(@as(u32, 4294836225), largest.cells());
}

test "a selection normalised upwards keeps the same two ends" {
    const testing = std.testing;

    // Dragged from the bottom left of the screen upwards to the top right.
    const upwards: Selection = .{
        .anchor = .{ .col = 0, .row = 3 },
        .head = .{ .col = 2, .row = 1 },
    };
    const forward = upwards.normalized();

    try testing.expectEqual(Position{ .col = 2, .row = 1 }, forward.first);
    try testing.expectEqual(Position{ .col = 0, .row = 3 }, forward.last);
    try testing.expect(!forward.isEmpty());

    // Normalising again changes nothing, and normalising the drag that went
    // the other way lands on the same range.
    const other: Selection = .{ .anchor = upwards.head, .head = upwards.anchor };
    try testing.expectEqual(forward.first, other.normalized().first);
    try testing.expectEqual(forward.last, other.normalized().last);

    try testing.expect(forward.contains(.{ .col = 0, .row = 3 }));
    try testing.expect(forward.contains(.{ .col = 2, .row = 1 }));
    try testing.expect(forward.contains(.{ .col = 5, .row = 1 }));

    // Reading order runs left to right, so a cell to the left of the first cell
    // on the same row is before the selection, not inside it.
    try testing.expect(!forward.contains(.{ .col = 0, .row = 1 }));
    try testing.expect(!forward.contains(.{ .col = 1, .row = 4 }));
    try testing.expectEqual(@as(u32, 3), forward.rowCount());
}

test "a selection that covers one cell contains only that cell" {
    const testing = std.testing;

    const single = (Selection{
        .anchor = .{ .col = 4, .row = 0 },
        .head = .{ .col = 4, .row = 0 },
    }).normalized();

    try testing.expect(single.isEmpty());
    try testing.expect(single.contains(.{ .col = 4, .row = 0 }));
    try testing.expect(!single.contains(.{ .col = 5, .row = 0 }));
    try testing.expect(!single.contains(.{ .col = 4, .row = 1 }));
    try testing.expectEqual(@as(u32, 1), single.rowCount());

    // Reading order is by row first, and only then by column.
    try testing.expectEqual(
        std.math.Order.lt,
        (Position{ .col = 0, .row = 0 }).order(.{ .col = 99, .row = 0 }),
    );
    try testing.expectEqual(
        std.math.Order.gt,
        (Position{ .col = 0, .row = 1 }).order(.{ .col = 99, .row = 0 }),
    );
    try testing.expectEqual(
        std.math.Order.eq,
        (Position{ .col = 7, .row = 2 }).order(.{ .col = 7, .row = 2 }),
    );
}

// --- tests -----------------------------------------------------------------

/// The `std.Io` every test terminal borrows. `TinyIo` is the upstream
/// no-threads implementation, which is all a terminal that only parses bytes
/// ever asks for.
fn testIo() std.Io {
    return ghostty_vt.TinyIo.init.io();
}

/// One row of the grid as text, the way a caller walks it: cell by cell,
/// base codepoint first and then any combining marks. Trailing blanks are
/// dropped so a test can compare against the text it typed.
fn readRow(terminal: *const Terminal, y: u16, out: []u8) ![]const u8 {
    var len: usize = 0;
    var x: u16 = 0;
    while (x < terminal.gridSize().cols) : (x += 1) {
        const cell = terminal.cell(.{ .col = x, .row = y }) orelse return error.OutOfRange;
        if (cell.wide_tail) continue; // no glyph of its own

        if (cell.codepoint != 0) {
            var encoded: [4]u8 = undefined;
            const width = try std.unicode.utf8Encode(cell.codepoint, &encoded);
            @memcpy(out[len..][0..width], encoded[0..width]);
            len += width;
        }
        for (cell.grapheme) |cp| {
            var encoded: [4]u8 = undefined;
            const width = try std.unicode.utf8Encode(cp, &encoded);
            @memcpy(out[len..][0..width], encoded[0..width]);
            len += width;
        }
        if (cell.codepoint == 0) {
            out[len] = ' ';
            len += 1;
        }
    }
    return std.mem.trimEnd(u8, out[0..len], " ");
}

test "a terminal is created at the grid size asked for, and freed without a leak" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 40, .rows = 6 });
    defer terminal.deinit(testing.allocator);

    try testing.expectEqual(GridSize{ .cols = 40, .rows = 6 }, terminal.gridSize());
    try testing.expectEqual(@as(u32, 240), terminal.gridSize().cells());

    // Nothing has been fed and nothing has been refreshed, so there is
    // nothing to report and nothing to read.
    try testing.expectEqual(Damage.none, terminal.damage());
    try testing.expectEqual(@as(usize, 0), terminal.droppedEvents());
    try testing.expect(!terminal.isDegraded());
    // Nothing has been refreshed yet, so there is no grid to read.
    try testing.expect(terminal.cell(.{ .col = 0, .row = 0 }) == null);

    try terminal.refresh(testing.allocator);
    try testing.expect(terminal.cell(.{ .col = 0, .row = 0 }) != null);

    // Out of the grid is out, not clamped.
    try testing.expect(terminal.cell(.{ .col = 40, .row = 0 }) == null);
    try testing.expect(terminal.cell(.{ .col = 0, .row = 6 }) == null);
}

test "fed bytes land in the grid where they were written" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 20, .rows = 3 });
    defer terminal.deinit(testing.allocator);

    // Exactly what a shell would write: a prompt, a command, then its output.
    terminal.feed("conduit$ echo hi\r\nhi\r\n");
    try terminal.refresh(testing.allocator);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("conduit$ echo hi", try readRow(&terminal, 0, &buf));
    try testing.expectEqualStrings("hi", try readRow(&terminal, 1, &buf));
    try testing.expectEqualStrings("", try readRow(&terminal, 2, &buf));

    const cell = terminal.cell(.{ .col = 0, .row = 0 }).?;
    try testing.expectEqual(@as(u21, 'c'), cell.codepoint);
    try testing.expect(cell.hasText());
    try testing.expect(!cell.wide);
    try testing.expect(!cell.wide_tail);
    try testing.expect(cell.style.isDefault());
}

test "OSC 8 label cells expose their metadata URI only" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 16, .rows = 2 });
    defer terminal.deinit(testing.allocator);

    terminal.feed("\x1b]8;;https://example.test/path\x1b\\LINK\x1b]8;;\x1b\\ plain");
    try terminal.refresh(testing.allocator);

    try testing.expectEqualStrings(
        "https://example.test/path",
        terminal.hyperlinkUri(.{ .col = 0, .row = 0 }).?,
    );
    try testing.expectEqualStrings(
        "https://example.test/path",
        terminal.hyperlinkUri(.{ .col = 3, .row = 0 }).?,
    );
    try testing.expect(terminal.hyperlinkUri(.{ .col = 4, .row = 0 }) == null);
    try testing.expect(terminal.hyperlinkUri(.{ .col = 0, .row = 1 }) == null);
    try testing.expect(terminal.hyperlinkUri(.{ .col = 16, .row = 0 }) == null);
    try testing.expect(terminal.hyperlinkUri(.{ .col = 0, .row = 2 }) == null);
}

test "distinct OSC 8 labels retain distinct metadata targets" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 16, .rows = 1 });
    defer terminal.deinit(testing.allocator);

    terminal.feed("\x1b]8;;https://one.test\x1b\\one\x1b]8;;\x1b\\ " ++
        "\x1b]8;id=second;file:///tmp/two\x1b\\two\x1b]8;;\x1b\\");
    try terminal.refresh(testing.allocator);

    try testing.expectEqualStrings(
        "https://one.test",
        terminal.hyperlinkUri(.{ .col = 1, .row = 0 }).?,
    );
    try testing.expect(terminal.hyperlinkUri(.{ .col = 3, .row = 0 }) == null);
    try testing.expectEqualStrings(
        "file:///tmp/two",
        terminal.hyperlinkUri(.{ .col = 4, .row = 0 }).?,
    );
    try testing.expectEqualStrings(
        "file:///tmp/two",
        terminal.hyperlinkUri(.{ .col = 6, .row = 0 }).?,
    );
}

test "invalid UTF-8 OSC 8 metadata remains present but is not a URI" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 24, .rows = 1 });
    defer terminal.deinit(testing.allocator);

    // The label is itself a lexical URL. Its malformed explicit metadata must
    // remain visible to link detection as a mask, but never become launchable.
    terminal.feed("\x1b]8;;https://invalid.test/\xff\x1b\\https://label.test\x1b]8;;\x1b\\");
    try terminal.refresh(testing.allocator);

    const link = terminal.hyperlink(.{ .col = 0, .row = 0 }).?;
    switch (link) {
        .invalid_utf8 => {},
        .uri => return error.TestUnexpectedResult,
    }
    try testing.expect(terminal.hyperlinkUri(.{ .col = 0, .row = 0 }) == null);
    try testing.expect(terminal.hyperlink(.{ .col = 18, .row = 0 }) == null);
}

test "OSC 8 metadata lookup follows the scrolled viewport" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 12, .rows = 2 });
    defer terminal.deinit(testing.allocator);

    terminal.feed("\x1b]8;;https://old.test\x1b\\OLD\x1b]8;;\x1b\\\r\n" ++
        "two\r\nthree\r\nfour");
    terminal.scrollToTop();
    try terminal.refresh(testing.allocator);

    var row: [16]u8 = undefined;
    try testing.expectEqualStrings("OLD", try readRow(&terminal, 0, &row));
    const link = terminal.hyperlink(.{ .col = 1, .row = 0 }).?;
    switch (link) {
        .uri => |uri| try testing.expectEqualStrings("https://old.test", uri),
        .invalid_utf8 => return error.TestUnexpectedResult,
    }
    try testing.expect(terminal.hyperlink(.{ .col = 0, .row = 1 }) == null);
}

test "cleared and malformed OSC 8 sequences expose no URI" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 12, .rows = 1 });
    defer terminal.deinit(testing.allocator);

    // The first cell is linked, the explicit empty URI clears that state, and
    // the malformed option/URI form is discarded by the parser. Both following
    // cells must remain ordinary terminal text rather than stale links.
    terminal.feed("\x1b]8;;https://valid.test\x1b\\L\x1b]8;;\x1b\\C" ++
        "\x1b]8;broken\x1b\\M");
    try terminal.refresh(testing.allocator);

    try testing.expectEqualStrings(
        "https://valid.test",
        terminal.hyperlinkUri(.{ .col = 0, .row = 0 }).?,
    );
    try testing.expect(terminal.hyperlinkUri(.{ .col = 1, .row = 0 }) == null);
    try testing.expect(terminal.hyperlinkUri(.{ .col = 2, .row = 0 }) == null);
}

test "an escape sequence split across three reads still parses as one sequence" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 10, .rows = 2 });
    defer terminal.deinit(testing.allocator);

    // A real read can stop anywhere: inside the parameter bytes, before the
    // final byte, and inside a UTF-8 sequence.
    terminal.feed("\x1b[1;3");
    terminal.feed("1");
    terminal.feed("mR");
    try terminal.refresh(testing.allocator);

    const cell = terminal.cell(.{ .col = 0, .row = 0 }).?;
    try testing.expectEqual(@as(u21, 'R'), cell.codepoint);
    try testing.expect(cell.style.attributes.bold);
    try testing.expectEqual(Color{ .palette = 1 }, cell.style.fg);

    // And the same for a multi-byte codepoint split down the middle.
    terminal.feed("\x1b[1;1H\xe6\xbc");
    terminal.feed("\xa2");
    try terminal.refresh(testing.allocator);
    try testing.expectEqual(
        @as(u21, 0x6f22),
        terminal.cell(.{ .col = 0, .row = 0 }).?.codepoint,
    );
}

test "resizing changes the grid and leaves the terminal usable" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 40, .rows = 6 });
    defer terminal.deinit(testing.allocator);

    terminal.feed("first\r\nsecond\r\nthird");
    try terminal.refresh(testing.allocator);

    try terminal.resize(testing.allocator, .{ .cols = 10, .rows = 3 });
    try testing.expectEqual(GridSize{ .cols = 10, .rows = 3 }, terminal.gridSize());
    try terminal.refresh(testing.allocator);

    // The dimensions changed, so the whole grid is damaged rather than a few
    // rows of it.
    try testing.expectEqual(Damage.full, terminal.damage());

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("second", try readRow(&terminal, 1, &buf));

    // The parser and the grid both work at the new size.
    terminal.feed("\x1b[3;1Hafter");
    try terminal.refresh(testing.allocator);
    try testing.expectEqualStrings("after", try readRow(&terminal, 2, &buf));

    try terminal.resize(testing.allocator, .{ .cols = 20, .rows = 4 });
    try testing.expectEqual(GridSize{ .cols = 20, .rows = 4 }, terminal.gridSize());

    // Reading before the next refresh reads the view as it stands: cells the
    // grown grid has and the cached view does not are simply not there yet.
    try testing.expect(terminal.cell(.{ .col = 15, .row = 3 }) == null);
    try testing.expect(terminal.cell(.{ .col = 0, .row = 0 }) != null);
}

test "a double-width character owns two cells, and its tail cell says so" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 6, .rows = 1 });
    defer terminal.deinit(testing.allocator);

    terminal.feed("\x1b[Ha\u{6f22}b");
    try terminal.refresh(testing.allocator);

    const first = terminal.cell(.{ .col = 0, .row = 0 }).?;
    try testing.expectEqual(@as(u21, 'a'), first.codepoint);
    try testing.expect(!first.wide);
    try testing.expect(!first.wide_tail);

    // U+6F22 is two cells wide: the glyph in one, an empty tail in the next.
    const han = terminal.cell(.{ .col = 1, .row = 0 }).?;
    try testing.expectEqual(@as(u21, 0x6f22), han.codepoint);
    try testing.expect(han.wide);
    try testing.expect(!han.wide_tail);

    const tail = terminal.cell(.{ .col = 2, .row = 0 }).?;
    try testing.expectEqual(@as(u21, 0), tail.codepoint);
    try testing.expect(!tail.hasText());
    try testing.expect(tail.wide_tail);

    // The next character starts after the tail, so it lands in the fourth.
    try testing.expectEqual(
        @as(u21, 'b'),
        terminal.cell(.{ .col = 3, .row = 0 }).?.codepoint,
    );
}

test "a combining mark rides in the same cell as its base character" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 4, .rows = 1 });
    defer terminal.deinit(testing.allocator);

    terminal.feed("\x1b[He\u{0301}x");
    try terminal.refresh(testing.allocator);

    const accented = terminal.cell(.{ .col = 0, .row = 0 }).?;
    try testing.expectEqual(@as(u21, 'e'), accented.codepoint);
    try testing.expectEqual(@as(usize, 1), accented.grapheme.len);
    try testing.expectEqual(@as(u21, 0x0301), accented.grapheme[0]);
    // One cell, not two: a combining mark adds no width.
    try testing.expect(!accented.wide);

    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("e\u{0301}x", try readRow(&terminal, 0, &buf));
}

test "visible text preserves internal blanks and every row boundary" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 8, .rows = 3 });
    defer terminal.deinit(testing.allocator);

    terminal.feed("\x1b[1;1HA B\x1b[3;1HZ  Q");
    try terminal.refresh(testing.allocator);

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try terminal.writeVisibleText(&writer);
    try testing.expectEqualStrings("A B\n\nZ  Q", writer.buffered());
}

test "visible text emits wide and combining graphemes once" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 10, .rows = 2 });
    defer terminal.deinit(testing.allocator);

    terminal.feed("\x1b[1;1Ha\u{6f22}b\x1b[2;1He\u{0301}x");
    try terminal.refresh(testing.allocator);

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try terminal.writeVisibleText(&writer);
    try testing.expectEqualStrings("a\u{6f22}b\ne\u{0301}x", writer.buffered());
}

test "visible text contains same-row text and rejects absent text" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 16, .rows = 1 });
    defer terminal.deinit(testing.allocator);

    terminal.feed("alpha aaab");
    try terminal.refresh(testing.allocator);

    try testing.expect(terminal.visibleTextContains("pha"));
    try testing.expect(terminal.visibleTextContains("aab"));
    try testing.expect(!terminal.visibleTextContains("phz"));
}

test "visible text contains matches across row separators" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 6, .rows = 3 });
    defer terminal.deinit(testing.allocator);

    terminal.feed("\x1b[1;1HAB\x1b[3;1HCD");
    try terminal.refresh(testing.allocator);

    try testing.expect(terminal.visibleTextContains("B\n\nC"));
}

test "visible text contains an empty needle" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 4, .rows = 1 });
    defer terminal.deinit(testing.allocator);

    try terminal.refresh(testing.allocator);

    try testing.expect(terminal.visibleTextContains(""));
}

test "visible text contains wide and combining text across cell boundaries" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 10, .rows = 1 });
    defer terminal.deinit(testing.allocator);

    terminal.feed("a\u{6f22}be\u{0301}z");
    try terminal.refresh(testing.allocator);

    try testing.expect(terminal.visibleTextContains("\u{6f22}be\u{0301}z"));
    try testing.expect(!terminal.visibleTextContains("bez"));
}

test "visible text contains observes trimmed trailing row blanks" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 5, .rows = 2 });
    defer terminal.deinit(testing.allocator);

    terminal.feed("\x1b[1;1HA\x1b[2;1HB");
    try terminal.refresh(testing.allocator);

    try testing.expect(terminal.visibleTextContains("A\nB"));
    try testing.expect(!terminal.visibleTextContains("A \n"));
    try testing.expect(!terminal.visibleTextContains("B "));
}

test "visible text retains cached dimensions until refresh" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 6, .rows = 2 });
    defer terminal.deinit(testing.allocator);

    terminal.feed("old\r\nrow");
    try terminal.refresh(testing.allocator);
    try terminal.resize(testing.allocator, .{ .cols = 10, .rows = 3 });

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try terminal.writeVisibleText(&writer);
    try testing.expectEqualStrings("old\nrow", writer.buffered());
}

test "visible text skips scalar values that cannot be UTF-8" {
    const testing = std.testing;

    var encoded: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), encodeVisibleScalar(&encoded, 0xd800));
    try testing.expectEqual(@as(usize, 0), encodeVisibleScalar(&encoded, 0x110000));
    const len = encodeVisibleScalar(&encoded, 'A');
    try testing.expectEqualStrings("A", encoded[0..len]);
}

test "SGR colours and attributes reach the cell" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 12, .rows = 1 });
    defer terminal.deinit(testing.allocator);

    terminal.feed("\x1b[H");
    terminal.feed("\x1b[1;3;4;38;2;10;20;30;48;5;99mA");
    terminal.feed("\x1b[0m");
    terminal.feed("B");
    try terminal.refresh(testing.allocator);

    const styled = terminal.cell(.{ .col = 0, .row = 0 }).?;
    try testing.expectEqual(Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } }, styled.style.fg);
    try testing.expectEqual(Color{ .palette = 99 }, styled.style.bg);
    try testing.expect(styled.style.attributes.bold);
    try testing.expect(styled.style.attributes.italic);
    try testing.expectEqual(Underline.single, styled.style.attributes.underline);
    try testing.expectEqual(Color.default, styled.style.underline_color);

    // SGR 0 really resets: the cell after it is the default style again.
    const plain = terminal.cell(.{ .col = 1, .row = 0 }).?;
    try testing.expect(plain.style.isDefault());
    try testing.expectEqual(Color.default, plain.style.fg);
    try testing.expectEqual(Color.default, plain.style.bg);
}

test "erasing clears the cells it covers and leaves the rest alone" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 10, .rows = 3 });
    defer terminal.deinit(testing.allocator);

    terminal.feed("abcdefghij\r\nklmnopqrst\r\nuvwxyzabcd");
    try terminal.refresh(testing.allocator);

    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("abcdefghij", try readRow(&terminal, 0, &buf));

    // EL 2: erase from the cursor to the end of the line. Move to column 4
    // first, so the first three cells survive.
    terminal.feed("\x1b[1;4H\x1b[0K");
    try terminal.refresh(testing.allocator);
    try testing.expectEqualStrings("abc", try readRow(&terminal, 0, &buf));
    try testing.expectEqualStrings("klmnopqrst", try readRow(&terminal, 1, &buf));

    // ED 2: erase the whole grid.
    terminal.feed("\x1b[2J");
    try terminal.refresh(testing.allocator);
    try testing.expectEqualStrings("", try readRow(&terminal, 0, &buf));
    try testing.expectEqualStrings("", try readRow(&terminal, 1, &buf));
    try testing.expectEqualStrings("", try readRow(&terminal, 2, &buf));
    try testing.expect(!terminal.cell(.{ .col = 9, .row = 2 }).?.hasText());
}

test "the cursor position and shape follow CUP, DECSCUSR and DECTCEM" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 20, .rows = 5 });
    defer terminal.deinit(testing.allocator);
    try terminal.refresh(testing.allocator);

    // A fresh terminal has a visible block cursor at the origin.
    var cursor = terminal.cursor();
    try testing.expectEqual(Position{ .col = 0, .row = 0 }, cursor.position.?);
    try testing.expectEqual(CursorShape.block, cursor.shape);
    try testing.expect(cursor.visible);

    // CUP is one-based; the grid is not.
    terminal.feed("\x1b[5;9H");
    try terminal.refresh(testing.allocator);
    cursor = terminal.cursor();
    try testing.expectEqual(Position{ .col = 8, .row = 4 }, cursor.position.?);

    // DECSCUSR 3 is an underline cursor and DECSCUSR 5 is a bar.
    terminal.feed("\x1b[3 q");
    try terminal.refresh(testing.allocator);
    try testing.expectEqual(CursorShape.underline, terminal.cursor().shape);
    terminal.feed("\x1b[5 q");
    try terminal.refresh(testing.allocator);
    try testing.expectEqual(CursorShape.bar, terminal.cursor().shape);

    // DECTCEM hides it without moving it.
    terminal.feed("\x1b[?25l");
    try terminal.refresh(testing.allocator);
    cursor = terminal.cursor();
    try testing.expect(!cursor.visible);
    try testing.expectEqual(Position{ .col = 8, .row = 4 }, cursor.position.?);
}

test "the key-encoding modes follow the modes a program sets" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 10, .rows = 2 });
    defer terminal.deinit(testing.allocator);

    // Nothing is set except the two modes the engine defaults to on.
    var modes = terminal.keyModes();
    try testing.expect(!modes.cursor_key_application);
    try testing.expect(!modes.keypad_key_application);
    try testing.expect(!modes.backarrow_key_mode);
    try testing.expect(!modes.modify_other_keys_state_2);
    try testing.expect(!modes.kitty_keyboard.disambiguate);
    try testing.expect(!modes.macos_option_as_alt);

    // DEC modes 1, 66 and 67.
    terminal.feed("\x1b[?1h\x1b[?66h\x1b[?67h");
    modes = terminal.keyModes();
    try testing.expect(modes.cursor_key_application);
    try testing.expect(modes.keypad_key_application);
    try testing.expect(modes.backarrow_key_mode);

    // DEC modes 1035 and 1036, turned off and on again so the assertion does
    // not depend on how the engine is configured to start.
    terminal.feed("\x1b[?1035l\x1b[?1036l");
    modes = terminal.keyModes();
    try testing.expect(!modes.ignore_keypad_with_numlock);
    try testing.expect(!modes.alt_esc_prefix);
    terminal.feed("\x1b[?1035h\x1b[?1036h");
    modes = terminal.keyModes();
    try testing.expect(modes.ignore_keypad_with_numlock);
    try testing.expect(modes.alt_esc_prefix);

    // xterm modifyOtherKeys mode 2, then the Kitty keyboard protocol asking
    // for ambiguous keys.
    terminal.feed("\x1b[>4;2m\x1b[>1u");
    modes = terminal.keyModes();
    try testing.expect(modes.modify_other_keys_state_2);
    try testing.expect(modes.kitty_keyboard.disambiguate);
    try testing.expect(!modes.kitty_keyboard.report_all);

    // Option-as-Alt is configuration, not terminal state, so it changes only
    // because Conduit said so.
    terminal.setMacosOptionAsAlt(true);
    try testing.expect(terminal.keyModes().macos_option_as_alt);
}

test "every named key encodes to the bytes a terminal program binds" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 20, .rows = 2 });
    defer terminal.deinit(testing.allocator);

    // Every key Conduit names, and the sequence a program has always expected
    // for it. This is the encoding table, written out in full rather than
    // spot-checked: a key that silently stopped encoding would take every
    // binding of it with it, and nothing else in the codebase would notice.
    const cases = [_]struct { key: PhysicalKey, want: []const u8 }{
        .{ .key = .enter, .want = "\r" },
        .{ .key = .tab, .want = "\t" },
        .{ .key = .backspace, .want = "\x7f" },
        .{ .key = .escape, .want = "\x1b" },
        .{ .key = .insert, .want = "\x1b[2~" },
        .{ .key = .delete, .want = "\x1b[3~" },
        .{ .key = .up, .want = "\x1b[A" },
        .{ .key = .down, .want = "\x1b[B" },
        .{ .key = .right, .want = "\x1b[C" },
        .{ .key = .left, .want = "\x1b[D" },
        .{ .key = .home, .want = "\x1b[H" },
        .{ .key = .end, .want = "\x1b[F" },
        .{ .key = .page_up, .want = "\x1b[5~" },
        .{ .key = .page_down, .want = "\x1b[6~" },
        .{ .key = .f1, .want = "\x1bOP" },
        .{ .key = .f2, .want = "\x1bOQ" },
        .{ .key = .f3, .want = "\x1bOR" },
        .{ .key = .f4, .want = "\x1bOS" },
        .{ .key = .f5, .want = "\x1b[15~" },
        .{ .key = .f6, .want = "\x1b[17~" },
        .{ .key = .f7, .want = "\x1b[18~" },
        .{ .key = .f8, .want = "\x1b[19~" },
        .{ .key = .f9, .want = "\x1b[20~" },
        .{ .key = .f10, .want = "\x1b[21~" },
        .{ .key = .f11, .want = "\x1b[23~" },
        .{ .key = .f12, .want = "\x1b[24~" },
    };
    // Every key the table names is in the table, and no key outside it.
    try testing.expectEqual(cases.len, @typeInfo(PhysicalKey).@"enum".fields.len - 1);

    var encoded: EncodedKey = .{};
    for (cases) |case| {
        terminal.encodeKey(.{ .key = case.key }, &encoded);
        testing.expectEqualStrings(case.want, encoded.slice()) catch |err| {
            std.debug.print("key {s}: encoded {x}\n", .{ @tagName(case.key), encoded.slice() });
            return err;
        };
    }

    // A key Conduit has no name for and that produced no text encodes to
    // nothing at all: a media key must not become a stray byte in the child's
    // input.
    terminal.encodeKey(.{ .key = .unidentified }, &encoded);
    try testing.expect(encoded.isEmpty());
}

test "a letter with ctrl is the C0 byte, and with ctrl and shift it is a sequence" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 20, .rows = 2 });
    defer terminal.deinit(testing.allocator);

    // These expectations are Alt's: ESC-prefixed. On macOS the key is Option,
    // which composes characters unless Option-as-Alt is configured (and the
    // product policy for that is TASK-15), so ask for Alt explicitly there.
    // Off macOS the setting is inert.
    terminal.setMacosOptionAsAlt(true);

    var encoded: EncodedKey = .{};

    // ctrl+c: the byte every shell in history binds SIGINT to.
    terminal.encodeKey(.{
        .mods = .{ .ctrl = true },
        .text = "c",
        .unshifted_codepoint = 'c',
    }, &encoded);
    try testing.expectEqualStrings("\x03", encoded.slice());

    // Shift on its own is the keyboard's character, and the encoder takes it
    // back off the modifier set: the key is still ctrl+a.
    terminal.encodeKey(.{
        .mods = .{ .ctrl = true, .shift = true },
        .text = "A",
        .unshifted_codepoint = 'a',
    }, &encoded);
    try testing.expectEqualStrings("\x1b[97;6u", encoded.slice());

    // The same key under caps lock: the character is upper case, the key is
    // still `a`, and the program gets the byte ctrl+a is — which is why the
    // unshifted codepoint is carried at all.
    terminal.encodeKey(.{
        .mods = .{ .ctrl = true, .caps_lock = true },
        .text = "A",
        .unshifted_codepoint = 'a',
    }, &encoded);
    try testing.expectEqualStrings("\x01", encoded.slice());

    // A character with no command modifier is text, unchanged.
    terminal.encodeKey(.{ .text = "a", .unshifted_codepoint = 'a' }, &encoded);
    try testing.expectEqualStrings("a", encoded.slice());

    // Alt prefixes the key with ESC by default, which is what DEC mode 1036
    // asks for and what this engine starts in: readline and vim both read
    // `\eb` as "back a word". Turning the mode off makes alt a modifier the
    // encoder ignores for text, which is the behaviour a program that asked
    // for it expects.
    terminal.encodeKey(.{ .mods = .{ .alt = true }, .text = "f" }, &encoded);
    try testing.expectEqualStrings("\x1bf", encoded.slice());
    try testing.expect(terminal.keyModes().alt_esc_prefix);
    terminal.feed("\x1b[?1036l");
    try testing.expect(!terminal.keyModes().alt_esc_prefix);
    terminal.encodeKey(.{ .mods = .{ .alt = true }, .text = "f" }, &encoded);
    try testing.expectEqualStrings("f", encoded.slice());
    terminal.feed("\x1b[?1036h");
    terminal.encodeKey(.{ .mods = .{ .alt = true }, .text = "f" }, &encoded);
    try testing.expectEqualStrings("\x1bf", encoded.slice());
}

test "a release and an unidentified key encode to nothing on the legacy path" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 20, .rows = 2 });
    defer terminal.deinit(testing.allocator);

    var encoded: EncodedKey = .{};

    // Legacy has no way to report a release, and inventing one would put a
    // key a program did not ask for into its input.
    terminal.encodeKey(.{ .action = .release, .text = "a", .unshifted_codepoint = 'a' }, &encoded);
    try testing.expect(encoded.isEmpty());

    // A repeat is a press as far as legacy is concerned: holding a key down
    // sends it again.
    terminal.encodeKey(.{ .action = .repeat, .text = "a", .unshifted_codepoint = 'a' }, &encoded);
    try testing.expectEqualStrings("a", encoded.slice());
}

test "the cursor keys follow the mode the program set, in both directions" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 20, .rows = 2 });
    defer terminal.deinit(testing.allocator);

    var encoded: EncodedKey = .{};
    terminal.encodeKey(.{ .key = .up }, &encoded);
    try testing.expectEqualStrings("\x1b[A", encoded.slice());

    // DECCKM, which is what a full-screen program turns on when it takes the
    // keyboard: vim, less and tmux all send it on entry.
    terminal.feed("\x1b[?1h");
    try testing.expect(terminal.keyModes().cursor_key_application);
    terminal.encodeKey(.{ .key = .up }, &encoded);
    try testing.expectEqualStrings("\x1bOA", encoded.slice());
    // The other cursor keys move with it, and the ones that have no
    // application form are unchanged.
    terminal.encodeKey(.{ .key = .delete }, &encoded);
    try testing.expectEqualStrings("\x1b[3~", encoded.slice());

    // And off again, because a program that dies without clearing the mode
    // must not leave the user's shell with application cursor keys.
    terminal.feed("\x1b[?1l");
    try testing.expect(!terminal.keyModes().cursor_key_application);
    terminal.encodeKey(.{ .key = .up }, &encoded);
    try testing.expectEqualStrings("\x1b[A", encoded.slice());

    // DECBKM: the backspace key sends 0x08 rather than 0x7f.
    terminal.feed("\x1b[?67h");
    try testing.expect(terminal.keyModes().backarrow_key_mode);
    terminal.encodeKey(.{ .key = .backspace }, &encoded);
    try testing.expectEqualStrings("\x08", encoded.slice());
}

test "the Kitty keyboard protocol changes the bytes, and only when it is enabled" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 20, .rows = 2 });
    defer terminal.deinit(testing.allocator);

    var encoded: EncodedKey = .{};

    // The key: ctrl+c, which legacy cannot express unambiguously.
    const ctrl_c: KeyPress = .{
        .mods = .{ .ctrl = true },
        .text = "c",
        .unshifted_codepoint = 'c',
    };

    // Off: one byte, the C0 control. This is what a shell binds SIGINT to.
    try testing.expect(!terminal.keyModes().kitty_keyboard.disambiguate);
    terminal.encodeKey(ctrl_c, &encoded);
    const legacy = try testing.allocator.dupe(u8, encoded.slice());
    defer testing.allocator.free(legacy);
    try testing.expectEqualStrings("\x03", legacy);

    // On: the program asked to be told which key this was, so it is told —
    // as a CSI u sequence carrying the key's Kitty code and the modifier.
    // Nothing about the encoder changed to make this happen; the mode did.
    terminal.feed("\x1b[>1u");
    try testing.expect(terminal.keyModes().kitty_keyboard.disambiguate);
    terminal.encodeKey(ctrl_c, &encoded);
    const kitty = encoded.slice();
    try testing.expect(!std.mem.eql(u8, legacy, kitty));
    try testing.expectEqualStrings("\x1b[99;5u", kitty);

    // A key the two protocols express differently: legacy reaches for the
    // fixterms sequence, which says "enter with ctrl" in a form a program has
    // to know how to parse, and Kitty has a codepoint for it.
    const ctrl_enter: KeyPress = .{ .key = .enter, .mods = .{ .ctrl = true } };
    terminal.feed("\x1b[<u");
    try testing.expect(!terminal.keyModes().kitty_keyboard.disambiguate);
    terminal.encodeKey(ctrl_enter, &encoded);
    try testing.expectEqualStrings("\x1b[27;5;13~", encoded.slice());
    terminal.feed("\x1b[>1u");
    terminal.encodeKey(ctrl_enter, &encoded);
    try testing.expectEqualStrings("\x1b[13;5u", encoded.slice());

    // The keys both protocols agree on are still the keys both protocols
    // agree on, which is the point of the protocol: it adds what was missing.
    terminal.feed("\x1b[>1u");
    terminal.encodeKey(.{ .key = .up }, &encoded);
    try testing.expectEqualStrings("\x1b[A", encoded.slice());
    terminal.encodeKey(.{ .key = .f5 }, &encoded);
    try testing.expectEqualStrings("\x1b[15~", encoded.slice());
    terminal.encodeKey(.{ .text = "a", .unshifted_codepoint = 'a' }, &encoded);
    try testing.expectEqualStrings("a", encoded.slice());

    // "Report all keys as escape codes" is a separate flag, and it does
    // change even the unmodified keys: this is the flag that stops Enter and
    // Tab from being the two bytes a user can type with.
    terminal.feed("\x1b[>9u");
    try testing.expect(terminal.keyModes().kitty_keyboard.report_all);
    terminal.encodeKey(.{ .key = .enter }, &encoded);
    try testing.expectEqualStrings("\x1b[13u", encoded.slice());

    // Releases are only reported when the program asked for events.
    terminal.feed("\x1b[>1u");
    terminal.encodeKey(.{ .action = .release, .key = .f5 }, &encoded);
    try testing.expect(encoded.isEmpty());
    terminal.feed("\x1b[>3u");
    try testing.expect(terminal.keyModes().kitty_keyboard.report_events);
    terminal.encodeKey(.{ .action = .release, .key = .f5 }, &encoded);
    try testing.expectEqualStrings("\x1b[15;1:3~", encoded.slice());
}

test "a composing press encodes to nothing, in either protocol" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 20, .rows = 2 });
    defer terminal.deinit(testing.allocator);

    var encoded: EncodedKey = .{};

    // The property that makes an input method safe: text the user has typed
    // but not committed is *display only*. The encoder is what guarantees it —
    // there is no check in Conduit to forget — and the guarantee holds in both
    // protocols, including the one that reports every key as an escape code.
    const composing: KeyPress = .{
        .mods = .{ .ctrl = true, .shift = true, .alt = true },
        .text = "konnichiha",
        .unshifted_codepoint = 'k',
        .composing = true,
    };

    terminal.encodeKey(composing, &encoded);
    try testing.expect(encoded.isEmpty());
    terminal.encodeKey(.{ .key = .enter, .composing = true }, &encoded);
    try testing.expect(encoded.isEmpty());

    // Under the Kitty protocol, with both flags that report the most.
    terminal.feed("\x1b[>15u");
    try testing.expect(terminal.keyModes().kitty_keyboard.disambiguate);
    try testing.expect(terminal.keyModes().kitty_keyboard.report_all);
    terminal.encodeKey(composing, &encoded);
    try testing.expect(encoded.isEmpty());
    terminal.encodeKey(.{ .key = .enter, .composing = true }, &encoded);
    try testing.expect(encoded.isEmpty());

    // The commit is not a composing press: the same text without the flag is
    // exactly what the child must receive.
    terminal.feed("\x1b[<u");
    terminal.encodeKey(.{ .text = "konnichiha" }, &encoded);
    try testing.expectEqualStrings("konnichiha", encoded.slice());
}

test "no key press ever writes past the fixed encoding buffer" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 20, .rows = 2 });
    defer terminal.deinit(testing.allocator);

    var encoded: EncodedKey = .{};
    var longest: usize = 0;

    // Every key, with every modifier that the protocols can carry, under the
    // protocol that reports the most of everything: if any sequence could
    // overflow, this is where it shows up. There is no allocation to grow,
    // because the hot path may not make one.
    terminal.feed("\x1b[>31u");
    inline for (std.enums.values(PhysicalKey)) |key| {
        inline for (std.enums.values(KeyAction)) |action| {
            const mods = KeyMods{ .ctrl = true, .shift = true, .alt = true, .super = true };
            terminal.encodeKey(.{
                .action = action,
                .key = key,
                .mods = mods,
                .text = "\xe6\x97\xa5\xe6\x9c\xac",
                .unshifted_codepoint = 0x65e5,
            }, &encoded);
            longest = @max(longest, encoded.len);
        }
    }
    try testing.expect(longest <= max_encoded_key_bytes);
    try testing.expect(encoded.len <= max_encoded_key_bytes);
}

test "OSC 9 and OSC 777 notifications arrive as bounded, cleaned events" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 20, .rows = 2 });
    defer terminal.deinit(testing.allocator);

    // OSC 9 carries a body only, ST-terminated, and leaves the grid alone.
    terminal.feed("\x1b]9;Build finished\x1b\\after");
    var events = terminal.takeEvents();
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("", events[0].notification.title);
    try testing.expectEqualStrings("Build finished", events[0].notification.body);
    try testing.expect(!events[0].notification.truncated);

    // OSC 777 notify carries a title and a body, here BEL-terminated, beside
    // a bell in the same write and in order.
    terminal.feed("\x07\x1b]777;notify;Claude;Needs approval\x07");
    events = terminal.takeEvents();
    try testing.expectEqual(@as(usize, 2), events.len);
    try testing.expectEqual(Event.bell, events[0]);
    try testing.expectEqualStrings("Claude", events[1].notification.title);
    try testing.expectEqualStrings("Needs approval", events[1].notification.body);

    // An over-long body is cut to its bound at a character boundary.
    const long = "\xc3\xa9" ** (max_notification_body_bytes / 2 + 8);
    terminal.feed("\x1b]9;" ++ long ++ "\x1b\\");
    events = terminal.takeEvents();
    try testing.expectEqual(@as(usize, 1), events.len);
    const body = events[0].notification.body;
    try testing.expect(events[0].notification.truncated);
    try testing.expect(body.len <= max_notification_body_bytes);
    try testing.expect(std.unicode.utf8ValidateSlice(body));
}

test "notification text is cleaned of controls and invalid UTF-8" {
    const testing = std.testing;
    var out: [16]u8 = undefined;
    const cleaned = sanitizeNotificationText(&out, "a\x1bb\xffc\xc2\x85d");
    try testing.expectEqualStrings("a b\xef\xbf\xbdc d", cleaned.text);
    try testing.expect(!cleaned.truncated);
    // A character that does not fit whole is left out entirely.
    var small: [4]u8 = undefined;
    const cut = sanitizeNotificationText(&small, "abc\xe2\x82\xac");
    try testing.expectEqualStrings("abc", cut.text);
    try testing.expect(cut.truncated);
    try testing.expect(std.unicode.utf8ValidateSlice(cut.text));
}

test "a title change and a bell arrive as events, in order" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 20, .rows = 2 });
    defer terminal.deinit(testing.allocator);

    try testing.expect(terminal.title() == null);

    // OSC 0 with a BEL terminator, exactly as a shell sets its title.
    terminal.feed("\x1b]0;conduit: ~/src\x07");
    var events = terminal.takeEvents();
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("conduit: ~/src", events[0].title);
    try testing.expectEqualStrings("conduit: ~/src", terminal.title().?);

    // The queue belongs to one feed: reading it empties it.
    try testing.expectEqual(@as(usize, 0), terminal.takeEvents().len);

    // Two bells and an OSC 2 title in one write.
    terminal.feed("out\x07\x07\x1b]2;second\x07");
    events = terminal.takeEvents();
    try testing.expectEqual(@as(usize, 3), events.len);
    try testing.expectEqual(Event.bell, events[0]);
    try testing.expectEqual(Event.bell, events[1]);
    try testing.expectEqualStrings("second", events[2].title);
    try testing.expectEqualStrings("second", terminal.title().?);

    // A write with nothing in it produces nothing.
    terminal.feed("plain text");
    try testing.expectEqual(@as(usize, 0), terminal.takeEvents().len);
    try testing.expectEqual(@as(usize, 0), terminal.droppedEvents());

    try terminal.refresh(testing.allocator);
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("outplain text", try readRow(&terminal, 0, &buf));
}

test "damage names the rows that changed since the last refresh" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 20, .rows = 8 });
    defer terminal.deinit(testing.allocator);

    terminal.feed("one\r\ntwo\r\nthree\r\nfour");
    // The first refresh of a terminal hands over the whole grid: the engine
    // has state that predates this caller's first frame, so everything counts
    // as changed.
    try terminal.refresh(testing.allocator);
    try testing.expectEqual(Damage.full, terminal.damage());

    // Refreshing again with nothing fed reports nothing at all, so an idle
    // terminal costs a renderer no grid work.
    try terminal.refresh(testing.allocator);
    try testing.expectEqual(Damage.none, terminal.damage());

    // A write that lands on one row damages that row, not the whole grid.
    terminal.feed("\x1b[5;1Hthree");
    try terminal.refresh(testing.allocator);
    switch (terminal.damage()) {
        .rows => |rows| {
            // The row the write landed on is in it.
            try testing.expect(std.mem.indexOfScalar(u16, rows, 4) != null);
            // And the damage is local: most of the grid is untouched.
            try testing.expect(rows.len < 8);
        },
        .full, .none => return error.TestUnexpectedResult,
    }

    // And it is reported once: reading it consumed it, and nothing has
    // changed since.
    try terminal.refresh(testing.allocator);
    try testing.expectEqual(Damage.none, terminal.damage());
}

test "hostile input cannot crash the parser, and the terminal still works" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 16, .rows = 3 });
    defer terminal.deinit(testing.allocator);

    // Every one of these is untrusted input from a process on the other end
    // of a PTY. None of them may assert, and none of them may end the
    // terminal's usefulness.
    const hostile = [_][]const u8{
        "\x1b[", // a CSI with no parameters and no final byte
        "\x1b]2;an OSC that never ends", // an OSC with no terminator
        "\x1b[99999999999999999999;99999H", // absurd CSI parameters
        "\x1b[1;99999999999999999999P", // an absurd erase count
        "\xff\xfe\xfd\x80", // invalid UTF-8, including a lone continuation byte
        "\xf0\x9f", // a UTF-8 sequence cut in half
        "\x1bP1$r0m\x1b\\", // a DCS the engine answers rather than prints
        "\x1b[<0;1;1M", // an SGR mouse report
        "\x1b[38;2;", // an incomplete truecolour sequence
        "\x07\x07\x07", // bells, which are events and nothing more
    };
    for (hostile) |bytes| terminal.feed(bytes);
    try terminal.refresh(testing.allocator);

    try testing.expect(!terminal.isDegraded());
    try testing.expectEqual(@as(usize, 3), terminal.takeEvents().len);
    try testing.expectEqual(@as(usize, 0), terminal.droppedEvents());

    // Still a working terminal: it erases, it styles, it moves the cursor,
    // and it holds a wide character and a combining mark.
    terminal.feed("\x1b[1;32m\x1b[2;1H\x1b[K\u{6f22}e\u{0301}\x07\x1b[0m");
    try terminal.refresh(testing.allocator);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("\u{6f22}e\u{0301}", try readRow(&terminal, 1, &buf));

    const cell = terminal.cell(.{ .col = 0, .row = 1 }).?;
    try testing.expect(cell.wide);
    try testing.expectEqual(Color{ .palette = 2 }, cell.style.fg);

    // The cursor sits after the combining mark: the wide glyph took two cells
    // and the `e` took the third.
    const cursor = terminal.cursor();
    try testing.expectEqual(Position{ .col = 3, .row = 1 }, cursor.position.?);
}

test "a style describes itself through Conduit's own describer" {
    const testing = std.testing;

    // The upstream `ghostty_vt.Style` ships a `format` method with the
    // pre-0.16 signature, which Zig 0.16 never calls; this is the one that
    // does. Only what differs from the default is written, so the text says
    // what is set.
    try testing.expectFmt("Style{}", "{f}", .{Style.unset});
    try testing.expectFmt(
        "Style{fg=palette(1),underline_color=rgb(1,2,3),bold,underline=curly}",
        "{f}",
        .{Style{
            .fg = .{ .palette = 1 },
            .underline_color = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
            .attributes = .{ .bold = true, .underline = .curly },
        }},
    );
    try testing.expectFmt(
        "Style{bg=palette(9),italic,blink,inverse,invisible,strikethrough,overline}",
        "{f}",
        .{Style{
            .bg = .{ .palette = 9 },
            .attributes = .{
                .italic = true,
                .blink = true,
                .inverse = true,
                .invisible = true,
                .strikethrough = true,
                .overline = true,
            },
        }},
    );
    // A colour is a union, so `{f}` cannot reach its `format`: on a union,
    // `value.format` is payload field access. Call it through the type.
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try Color.format(Color.default, &writer);
    try testing.expectEqualStrings("default", writer.buffered());

    writer = .fixed(&buf);
    try Color.format(.{ .palette = 200 }, &writer);
    try testing.expectEqualStrings("palette(200)", writer.buffered());

    writer = .fixed(&buf);
    try Color.format(.{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, &writer);
    try testing.expectEqualStrings("rgb(1,2,3)", writer.buffered());
}

// --- device responses: the seam out to the child -------------------------

/// Every response one `feed` produced, as a slice the test can compare
/// against. The caller-side contract in one line: drain, then look.
fn takeAllResponses(terminal: *Terminal) ![]u8 {
    var buffer: [response_capacity]u8 = undefined;
    const count = terminal.takeResponses(&buffer);
    return try std.testing.allocator.dupe(u8, buffer[0..count]);
}

test "a device attributes query is answered with bytes for the child, not grid content" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 20, .rows = 3 });
    defer terminal.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), terminal.pendingResponses());

    // CSI c: the primary device attributes query every VT-aware program asks
    // before it decides what the terminal can do.
    terminal.feed("\x1b[c");

    // The answer is waiting as data for the caller, and the terminal is owed
    // nothing until somebody asks.
    try testing.expect(terminal.pendingResponses() > 0);
    const answer = try takeAllResponses(&terminal);
    defer testing.allocator.free(answer);

    // CSI ? 62 ; 22 c — VT220 conformance, ANSI colour. Those two numbers are
    // exactly the claim `onDeviceAttributes` makes, so a change to what
    // Conduit supports changes them and nothing else has to.
    try testing.expectEqualStrings("\x1b[?62;22c", answer);
    try testing.expectEqual(@as(usize, 0), terminal.pendingResponses());

    // And none of it touched the grid: an answer is not something to draw.
    // The first refresh of any terminal hands over the whole grid, so the
    // evidence is the second one — nothing changed between the two, because
    // the query and its answer wrote no cells.
    try terminal.refresh(testing.allocator);
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("", try readRow(&terminal, 0, &buf));
    try terminal.refresh(testing.allocator);
    try testing.expectEqual(Damage.none, terminal.damage());
}

test "every query Conduit can answer produces its own response, in order" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(testing.allocator);

    // Three queries in one write, so the ordering of the answers is the
    // ordering of the questions — which is what a child reading its own input
    // relies on when it fires them off back to back.
    terminal.feed("\x1b[c\x1b[>c\x1b[18t");
    const answers = try takeAllResponses(&terminal);
    defer testing.allocator.free(answers);

    // Primary: VT220 + ANSI colour. Secondary: a VT220, firmware 0, no ROM
    // cartridge. Size: the grid this terminal was built with, in cells.
    try testing.expectEqualStrings("\x1b[?62;22c\x1b[>1;0;0c\x1b[8;24;80t", answers);
}

test "a cursor position report is answered from the state the terminal holds" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 20, .rows = 12 });
    defer terminal.deinit(testing.allocator);

    // DSR 6 asks where the cursor is. The answer is one-based, because the
    // query is one-based, and it comes from the state the terminal actually
    // holds — which is what makes it a report rather than a guess.
    terminal.feed("\x1b[10;5H\x1b[6n");
    const answer = try takeAllResponses(&terminal);
    defer testing.allocator.free(answer);
    try testing.expectEqualStrings("\x1b[10;5R", answer);

    // And it tracks the cursor: moved, asked again, answered differently.
    terminal.feed("\x1b[2;3H\x1b[6n");
    const moved = try takeAllResponses(&terminal);
    defer testing.allocator.free(moved);
    try testing.expectEqualStrings("\x1b[2;3R", moved);
}

test "a colour query is answered from the terminal's own palette" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 20, .rows = 3 });
    defer terminal.deinit(testing.allocator);

    // A terminal with no configured background has no colour to report, and
    // says nothing — which is the right answer, not a placeholder. So set
    // one first, exactly as a program would, and then ask for it back.
    try testing.expectEqual(@as(usize, 0), terminal.pendingResponses());
    terminal.feed("\x1b]11;?\x07");
    try testing.expectEqual(@as(usize, 0), terminal.pendingResponses());

    terminal.feed("\x1b]11;rgb:1c1c/2d2d/3e3e\x07");
    try testing.expectEqual(@as(usize, 0), terminal.pendingResponses());
    terminal.feed("\x1b]11;?\x07");
    const answer = try takeAllResponses(&terminal);
    defer testing.allocator.free(answer);

    // The reply is `OSC 11 ; rgb : RRRR/GGGG/BBBB BEL`, read back out of the
    // terminal's own state. Two different channels in, three out, so this
    // cannot be a constant that happens to look like a colour.
    try testing.expectEqualStrings("\x1b]11;rgb:1c1c/2d2d/3e3e\x07", answer);
}

test "a query the terminal has nothing to say about produces no bytes" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 20, .rows = 3 });
    defer terminal.deinit(testing.allocator);

    // XTGETTCAP for a capability Conduit does not have, and a DECRQCRA the
    // handler has disabled because answering it would let a program read back
    // the screen a character at a time. Both are questions; neither gets an
    // answer, and neither is an error.
    terminal.feed("\x1bP+q544e\x1b\\");
    terminal.feed("\x1bP0$r0m\x1b\\");
    try testing.expectEqual(@as(usize, 0), terminal.pendingResponses());
    try testing.expectEqual(@as(usize, 0), terminal.droppedResponses());
}

test "responses wait until the caller takes them, and a short take keeps the rest" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 20, .rows = 3 });
    defer terminal.deinit(testing.allocator);

    terminal.feed("\x1b[c\x1b[>c");
    try testing.expectEqual(@as(usize, 18), terminal.pendingResponses());

    // A drain in two steps, because that is what a caller with a small buffer
    // does, and the second half must not have been thrown away. The split
    // falls in the middle of the first answer, which is the case that matters:
    // a queue that dropped "the part that did not fit" would lose it.
    var first: [3]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), terminal.takeResponses(&first));
    try testing.expectEqualStrings("\x1b[?", first[0..3]);
    try testing.expectEqual(@as(usize, 15), terminal.pendingResponses());

    const rest = try takeAllResponses(&terminal);
    defer testing.allocator.free(rest);
    try testing.expectEqualStrings("62;22c\x1b[>1;0;0c", rest);
    try testing.expectEqual(@as(usize, 0), terminal.pendingResponses());
}

test "a program that floods queries loses the excess and keeps a working terminal" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 20, .rows = 3 });
    defer terminal.deinit(testing.allocator);

    // Four times the queue's capacity in questions, in a single write. Each
    // answer is nine bytes, so this cannot fit and must not try to grow.
    const answer_bytes = "\x1b[?62;22c".len;
    var flood: [response_capacity * 4]u8 = undefined;
    for (0..flood.len / 3) |i| {
        @memcpy(flood[i * 3 ..][0..3], "\x1b[c");
    }
    terminal.feed(&flood);

    // The queue stopped at its capacity without splitting an answer: whole
    // nine-byte replies to the last full one, and nothing past that.
    try testing.expectEqual(response_capacity - (response_capacity % answer_bytes), terminal.pendingResponses());
    try testing.expect(terminal.droppedResponses() > 0);

    // The terminal is still a terminal. First it erases and writes, then — the
    // part that matters — it answers, so the flood cost the program its
    // backlog of answers and nothing more. The backlog goes first, because a
    // queue with a thousand answers in it would answer the next query by
    // handing over the oldest one.
    const backlog = try takeAllResponses(&terminal);
    defer testing.allocator.free(backlog);
    try testing.expectEqual(@as(usize, 0), terminal.pendingResponses());

    terminal.feed("text\x1b[2J");
    try terminal.refresh(testing.allocator);
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("", try readRow(&terminal, 0, &buf));
    terminal.feed("\x1b[c");
    const answer = try takeAllResponses(&terminal);
    defer testing.allocator.free(answer);
    try testing.expectEqualStrings("\x1b[?62;22c", answer);
    try testing.expect(!terminal.isDegraded());
}

test "focus reporting is off until the program asks for it" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 20, .rows = 3 });
    defer terminal.deinit(testing.allocator);

    // Off by default. A program that never asked must never be sent a focus
    // report, which is what makes one worth having when it does arrive.
    try testing.expect(!terminal.focusReportingEnabled());
    try testing.expectEqual(@as(usize, 0), terminal.pendingResponses());

    terminal.feed("\x1b[?1004h");
    try testing.expect(terminal.focusReportingEnabled());

    terminal.feed("\x1b[?1004l");
    try testing.expect(!terminal.focusReportingEnabled());
}

// --- thread ownership ------------------------------------------------------

test "a terminal belongs to the thread that created it, and knows it" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 20, .rows = 3 });
    defer terminal.deinit(testing.allocator);

    try testing.expect(terminal.ownedByCallingThread());
    try testing.expectEqual(@as(usize, 0), terminal.ownershipViolations());

    // A real second thread, not a simulated one: this is the check that the
    // ownership record is a thread identity and not a flag that is always true.
    const Probe = struct {
        fn ownsItHere(subject: *const Terminal, result: *bool) void {
            result.* = subject.ownedByCallingThread();
        }
    };
    var foreign_owns_it = true;
    const probe = try std.Thread.spawn(.{}, Probe.ownsItHere, .{ &terminal, &foreign_owns_it });
    probe.join();
    try testing.expect(!foreign_owns_it);
    // And the owner still does, after the other thread has been and gone.
    try testing.expect(terminal.ownedByCallingThread());
    try testing.expectEqual(@as(usize, 0), terminal.ownershipViolations());
}

/// How many times the intruder thread below repeats its round of calls. Large
/// enough that the two threads genuinely overlap in wall-clock time, since
/// the owner is looping on the same terminal throughout.
const intruder_iterations = 200;

/// How many state-touching calls `intrudeOn` makes per iteration. Counted
/// rather than written into the assertion, so adding a call to the list above
/// cannot leave the test quietly checking a stale number.
const intruder_calls_per_iteration = 5;

/// One round of everything a caller is allowed to do to a terminal, run on a
/// thread that does not own it.
///
/// Every call is refused before it touches anything, so this allocates
/// nothing and never reaches the engine — which is the point: a caller that
/// gets this wrong must find out from a counted refusal, not from a grid full
/// of another thread's bytes.
fn intrudeOn(subject: *Terminal) void {
    for (0..intruder_iterations) |_| {
        subject.feed("intruder\r\n");
        subject.refresh(std.testing.allocator) catch {};
        subject.resize(std.testing.allocator, .{ .cols = 30, .rows = 4 }) catch {};
        _ = subject.takeEvents();
        var out: [64]u8 = undefined;
        _ = subject.takeResponses(&out);
    }
}

test "a second thread cannot touch terminal state, and the refusal is counted" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 20, .rows = 3 });
    defer terminal.deinit(testing.allocator);

    terminal.feed("owner\r\n");
    try terminal.refresh(testing.allocator);
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("owner", try readRow(&terminal, 0, &buf));

    // Every call that mutates state is offered to a real second thread while
    // the owner works on the same value, so the two genuinely contend for the
    // terminal rather than running in sequence.
    var finished: std.atomic.Value(bool) = .init(false);
    const intruder = try std.Thread.spawn(.{}, struct {
        fn go(subject: *Terminal, done: *std.atomic.Value(bool)) void {
            intrudeOn(subject);
            done.store(true, .release);
        }
    }.go, .{ &terminal, &finished });

    // The owner does its own work throughout, so the grid the intruder is
    // trying to change is being read while it tries to change it.
    while (!finished.load(.acquire)) {
        try terminal.refresh(testing.allocator);
        var row: [32]u8 = undefined;
        try testing.expectEqualStrings("owner", try readRow(&terminal, 0, &row));
    }
    intruder.join();

    // Every one of the intruder's calls was refused, and none of its bytes
    // reached the grid. This is the assertion that fails the moment two
    // threads *can* touch the state: the row would read "intruder", the grid
    // would be 30x4, or the violation count would be zero.
    try testing.expectEqual(intruder_iterations * intruder_calls_per_iteration, terminal.ownershipViolations());
    try testing.expectEqual(GridSize{ .cols = 20, .rows = 3 }, terminal.gridSize());
    try terminal.refresh(testing.allocator);
    try testing.expectEqualStrings("owner", try readRow(&terminal, 0, &buf));
    try testing.expectEqual(@as(usize, 0), terminal.pendingResponses());
}

// --- a real child, both directions ----------------------------------------

/// The environment every integration test hands a child: fixed, minimal, and
/// nothing from the developer's own shell, so what a test reads back cannot
/// vary with the machine.
const test_env = [_][]const u8{
    "PATH=/usr/bin:/bin",
    "HOME=/tmp",
    "TERM=xterm-256color",
    "LANG=C",
};

/// The directory a test's child starts in. Fixed, so nothing depends on where
/// the test was run from.
const test_cwd = "/";

/// A shell that reads commands from the terminal and nothing else. `-s` reads
/// stdin without making the shell interactive, so no profile, no prompt and no
/// dotfile of the developer's can appear in what a test reads back.
const shell_argv = [_][]const u8{ "/bin/sh", "-s" };

/// How long a test waits for a child to say something before calling it a
/// failure, and how long one wait lasts. Short enough that a failure is
/// reported promptly, long enough that a loaded machine does not lose a race
/// with its own process. A condition with a deadline, never a sleep.
const test_timeout_ms = 5_000;
const test_step_ms = 25;

/// Whether this build has a PTY backend to spawn a real child on. Where it
/// does not, `pty.spawn` reports `error.UnsupportedPlatform` and the
/// integration tests below skip rather than pretend.
const has_pty_backend = switch (@import("builtin").os.tag) {
    .linux, .macos => true,
    else => false,
};

/// A spawn of any program at all: the integration tests below run shells, an
/// editor and a line editor, and they all get the same fixed environment, the
/// same working directory and the same window size, so what comes back cannot
/// vary with the machine.
fn request(argv: []const []const u8) pty.SpawnRequest {
    return requestIn(argv, &test_env);
}

/// The same spawn in an environment of its own. Only the line editor below
/// needs one, and only for the two settings that would otherwise come from the
/// machine: its prompt and its key bindings.
fn requestIn(argv: []const []const u8, env: []const []const u8) pty.SpawnRequest {
    return .{
        .argv = argv,
        .env = env,
        .cwd = test_cwd,
        .size = pty.WindowSize.init(24, 80),
    };
}

/// Encode one key press and hand the bytes to the child, which is the whole
/// of what a session does with a key that no binding claimed.
///
/// The `KeyPress` values the tests below pass are written out as `input.translate`
/// produces them from the corresponding OS key event: this module knows nothing
/// about `input`, and pretending otherwise would mean testing a table this file
/// does not have. `out` is the caller's because the bytes are only good until
/// the next press is encoded over them.
fn sendKey(terminal: *const Terminal, child: pty.Pty, press: KeyPress, out: *EncodedKey) ![]const u8 {
    terminal.encodeKey(press, out);
    if (!out.isEmpty()) try writeAll(child, out.slice());
    return out.slice();
}

/// One round of the loop a session runs: take what the child has written,
/// feed it to the terminal, hand the terminal's answers back to the child —
/// the seam `takeResponses` exists for — and refresh the grid.
///
/// Neither side blocks the other: `takeBytes` and `takeResponses` copy into
/// buffers this call already owns, and the only write is the answer to a
/// question the child just asked.
fn pumpOnce(gpa: Allocator, child: pty.Pty, terminal: *Terminal) !void {
    var incoming: [1024]u8 = undefined;
    const count = child.takeBytes(&incoming);
    if (count != 0) terminal.feed(incoming[0..count]);

    var answers: [response_capacity]u8 = undefined;
    const owed = terminal.takeResponses(&answers);
    if (owed != 0) try writeAll(child, answers[0..owed]);

    try terminal.refresh(gpa);
}

/// Feed the child's output into the terminal until `ready` says the test is
/// waiting for what it wants to see, or the budget runs out.
///
/// A condition with a deadline, never a sleep: each round is `pumpOnce` and a
/// question, so a loaded machine that is slow does not fail the test and a fast
/// one does not have to wait.
///
/// The deadline is wall clock, and the round count is only its floor. A round
/// that returns at once — because the child is writing faster than this loop
/// takes its bytes, or because the ring still holds something it has not read
/// yet — costs no time at all, so two hundred of those would be milliseconds
/// rather than the five seconds the budget names, and the wait would give up on
/// a child that was about to say what it had been asked for. That is not a
/// hypothetical: it is what `waitForExit` was doing, measured.
fn waitFor(
    gpa: Allocator,
    child: pty.Pty,
    terminal: *Terminal,
    context: anytype,
    ready: fn (@TypeOf(context)) bool,
) !void {
    const started = monotonicMillis();
    const round_limit = test_timeout_ms / test_step_ms;
    var rounds: usize = 0;
    while (rounds < round_limit) : (rounds += 1) {
        try pumpOnce(gpa, child, terminal);
        if (ready(context)) return;
        // Out of time on the wall clock.
        if (budgetSpent(started, test_timeout_ms)) return error.TimedOut;
        _ = child.waitReadable(test_step_ms);
    }
    return error.TimedOut;
}

/// Whether `budget_ms` has gone by since `started` was read.
///
/// False where this build has no clock to measure it with, which leaves the
/// caller's round count as the only budget it has.
fn budgetSpent(started: ?u64, budget_ms: u64) bool {
    const begin = started orelse return false;
    const now = monotonicMillis() orelse return false;
    return now - begin >= budget_ms;
}

/// Milliseconds on a monotonic clock, or null where this build has no clock to
/// read.
///
/// A count of rounds is not a deadline. A round that returns at once — because
/// the child is writing faster than the loop takes its bytes, or because the
/// ring still holds something — costs no wall-clock time at all, so two
/// hundred of those are milliseconds rather than the seconds the budget names,
/// and a wait can time out on a child that was about to say what it was asked.
/// The one OS call this makes is `countOpenDescriptors`'s neighbour and for the
/// same reason: only tests make it.
fn monotonicMillis() ?u64 {
    var ts: std.c.timespec = undefined;
    switch (builtin.os.tag) {
        .linux => if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return null,
        .macos => if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return null,
        else => return null,
    }
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
}

/// What a wait is looking for on the grid: whether one row holds a piece of
/// text, or no longer does.
///
/// It reads parsed grid state rather than raw bytes on purpose. A wait over raw
/// bytes can be satisfied by a program echoing a sequence back at us, which is
/// exactly what these tests must not mistake for a program acting on a key.
const GridHas = struct {
    /// The terminal whose grid is read.
    terminal: *const Terminal,
    /// The row to read.
    row: u16,
    /// The text to look for.
    needle: []const u8,
    /// Whether the row is expected to hold `needle`. False waits for the text
    /// to be *gone*, which is how a test waits for a program to leave a state
    /// it announced.
    present: bool = true,
    /// The row as text, owned here so that `holds` allocates nothing. An
    /// 80-column row of the ASCII these programs print fits with room to spare.
    scratch: [256]u8 = undefined,

    /// Whether the grid is in the state being waited for.
    fn holds(self: *GridHas) bool {
        const text = readRow(self.terminal, self.row, &self.scratch) catch return false;
        return (std.mem.indexOf(u8, text, self.needle) != null) == self.present;
    }
};

/// Type `text` one key at a time, through the encoder, as `input.translate`
/// describes a printable key: the character, its own codepoint, and no
/// modifiers.
fn typeText(terminal: *const Terminal, child: pty.Pty, text: []const u8) !void {
    var encoded: EncodedKey = .{};
    for (text) |character| {
        const one = [_]u8{character};
        _ = try sendKey(terminal, child, .{
            .text = &one,
            .unshifted_codepoint = character,
        }, &encoded);
    }
}

/// Write every byte of `bytes`, looping over the short writes the interface
/// allows.
fn writeAll(child: pty.Pty, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        written += try child.write(bytes[written..]);
    }
}

/// Pump the child's bytes into the terminal and collect what came back, until
/// `marker` appears in it or the budget runs out.
///
/// This is a session's whole per-iteration body in one function: take the
/// child's bytes, feed them to the terminal, and hand back everything the
/// child has produced. Writing the terminal's answers back out is left to the
/// caller, because *when* to write them is the session's decision and not this
/// module's — which is exactly the seam `takeResponses` exists to express.
fn pumpUntil(gpa: Allocator, child: pty.Pty, terminal: *Terminal, marker: []const u8) ![]u8 {
    var collected: std.ArrayList(u8) = .empty;
    errdefer collected.deinit(gpa);

    var buffer: [1024]u8 = undefined;
    var rounds: usize = 0;
    while (rounds < test_timeout_ms / test_step_ms) : (rounds += 1) {
        const count = child.takeBytes(&buffer);
        if (count != 0) {
            terminal.feed(buffer[0..count]);
            try collected.appendSlice(gpa, buffer[0..count]);
        }
        if (std.mem.indexOf(u8, collected.items, marker) != null) break;
        _ = child.waitReadable(test_step_ms);
    }
    return collected.toOwnedSlice(gpa);
}

/// Wait for a child to end, and report how it ended.
///
/// A condition with a deadline like `waitFor`, and the deadline is wall clock:
/// see the note on that one for why a count of rounds is not one.
fn waitForExit(child: pty.Pty) !pty.ChildState {
    var scratch: [256]u8 = undefined;
    const started = monotonicMillis();
    var rounds: usize = 0;
    while (rounds < test_timeout_ms / test_step_ms) : (rounds += 1) {
        switch (child.state()) {
            .running => {},
            .exited => |status| return .{ .exited = status },
        }
        // Take whatever the child wrote before waiting again, which is what a
        // session does on every turn anyway. `waitReadable` answers "is there
        // something to read", and a child that echoed a key it was sent answers
        // yes for as long as those bytes are in the ring: left there, this loop
        // spins and burns a budget meant to be five seconds in a few
        // milliseconds, and calls a child that is about to end a timeout.
        _ = child.takeBytes(&scratch);
        if (budgetSpent(started, test_timeout_ms)) return error.TimedOut;
        _ = child.waitReadable(test_step_ms);
    }
    return error.TimedOut;
}

/// Count the descriptors this process holds, by asking the OS about every one
/// it could have. This is how the teardown test measures rather than assumes
/// — the same `fcntl(F_GETFD)` probe `pty`'s own leak test uses, inlined
/// because it is the only OS call this module would otherwise make, and only
/// its tests make it.
fn countOpenDescriptors() ?usize {
    // Conduit opens tens of descriptors, not thousands.
    const probe_limit = 1024;
    // POSIX fixes `F_GETFD` at 1: it fails on a descriptor that is not open.
    const f_getfd: i32 = 1;

    var count: usize = 0;
    var fd: i32 = 0;
    while (fd < probe_limit) : (fd += 1) {
        const open = switch (builtin.os.tag) {
            .linux => blk: {
                const linux = std.os.linux;
                break :blk linux.errno(linux.fcntl(fd, f_getfd, 0)) == .SUCCESS;
            },
            .macos => std.c.fcntl(fd, f_getfd, @as(c_int, 0)) >= 0,
            else => return null,
        };
        if (open) count += 1;
    }
    return count;
}

test "a real child's device attributes query is answered on its own input" {
    if (!has_pty_backend) return error.SkipZigTest;
    const testing = std.testing;
    const gpa = testing.allocator;

    // One terminal, one real shell behind it, wired the way a session wires
    // it: the child's bytes are fed to the terminal, and the terminal's
    // answers go back to the child.
    const child = try pty.spawn(gpa, request(&shell_argv));
    defer child.destroy();

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(gpa);

    // Turn off the terminal's own echo, put it out of canonical mode, print a
    // primary device attributes query, and hand the shell's input to `cat`.
    //
    // Echo off is what makes this a proof rather than a reflection: with it,
    // whatever comes back after the answer was read by a real process, not
    // bounced off the line discipline. `cat` is the reader that proves it.
    try writeAll(child, "stty -echo -icanon; printf '\\033[c'; cat\n");

    // Pump until the child has emitted the query. The bytes collected before
    // it are the shell echoing its own command line; the query itself is the
    // first real escape sequence the child produced.
    const query = "\x1b[c";
    const before_answer = try pumpUntil(gpa, child, &terminal, query);
    defer gpa.free(before_answer);
    try testing.expect(std.mem.indexOf(u8, before_answer, query) != null);

    // The exact answer, nine bytes, produced by the terminal and nothing else.
    var answers: [64]u8 = undefined;
    const answered = terminal.takeResponses(&answers);
    try testing.expectEqualStrings("\x1b[?62;22c", answers[0..answered]);
    try testing.expectEqual(@as(usize, 0), terminal.pendingResponses());

    // Now the part that matters: those nine bytes go to the child, which is a
    // real process with `cat` reading its input, and come back out of it.
    try writeAll(child, answers[0..answered]);
    const came_back = try pumpUntil(gpa, child, &terminal, "\x1b[?62;22c");
    defer gpa.free(came_back);
    try testing.expect(std.mem.indexOf(u8, came_back, "\x1b[?62;22c") != null);

    // The whole round trip ran on the owning thread, so nothing was refused.
    try testing.expectEqual(@as(usize, 0), terminal.ownershipViolations());
}

test "a real command's output lands in the grid as parsed state" {
    if (!has_pty_backend) return error.SkipZigTest;
    const testing = std.testing;
    const gpa = testing.allocator;

    // A child with no shell around it, so everything it produces is the output
    // of the command and nothing is echoed back.
    const child = try pty.spawn(gpa, request(
        &.{ "/bin/sh", "-c", "printf 'conduit-term-%s\\n' grid" },
    ));
    defer child.destroy();

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 40, .rows = 6 });
    defer terminal.deinit(gpa);

    // The same shape of proof the unit tests use, with bytes that came out of
    // an actual process rather than out of a literal in this file.
    const printed = try pumpUntil(gpa, child, &terminal, "conduit-term-grid");
    defer gpa.free(printed);
    // It really was the child that printed it: no shell was reading a line and
    // echoing it, so the only source of these bytes is the command itself.
    try testing.expect(std.mem.indexOf(u8, printed, "conduit-term-grid") != null);

    // And the bytes it printed are grid state: a row of text, with each
    // character in the column it was written to.
    try terminal.refresh(gpa);

    // The grid now holds what the process printed: a row of text, each
    // character in the column it was written to.
    var row: [64]u8 = undefined;
    try testing.expectEqualStrings("conduit-term-grid", try readRow(&terminal, 0, &row));
    try testing.expectEqual(@as(u21, 'c'), terminal.cell(.{ .col = 0, .row = 0 }).?.codepoint);
    try testing.expectEqual(@as(usize, 0), terminal.ownershipViolations());
}

test "a resize moves the terminal and the child together" {
    if (!has_pty_backend) return error.SkipZigTest;
    const testing = std.testing;
    const gpa = testing.allocator;

    const child = try pty.spawn(gpa, request(&shell_argv));
    defer child.destroy();

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(gpa);

    // The size the child was started at, asked of the child itself.
    try writeAll(child, "stty size\n");
    const at_start = try pumpUntil(gpa, child, &terminal, "24 80");
    defer gpa.free(at_start);
    try testing.expect(std.mem.indexOf(u8, at_start, "24 80") != null);
    try testing.expectEqual(GridSize{ .cols = 80, .rows = 24 }, terminal.gridSize());

    // One call, and both sides move. The order inside it is the terminal's
    // state first and the PTY second, so a child that asks its size the moment
    // it sees SIGWINCH gets the new one — which is what the next checks are for.
    try terminal.resizeChild(gpa, child, .{ .cols = 100, .rows = 40 });

    // The child's view of its own terminal, from the child.
    try writeAll(child, "stty size\n");
    const after_resize = try pumpUntil(gpa, child, &terminal, "40 100");
    defer gpa.free(after_resize);
    try testing.expect(std.mem.indexOf(u8, after_resize, "40 100") != null);

    // The terminal's own answer to a size query, at the same new size — so
    // the two sides are not merely both "changed", they agree.
    terminal.feed("\x1b[18t");
    var answers: [64]u8 = undefined;
    const answered = terminal.takeResponses(&answers);
    try testing.expectEqualStrings("\x1b[8;40;100t", answers[0..answered]);

    // And Conduit's copy says the same thing.
    try testing.expectEqual(GridSize{ .cols = 100, .rows = 40 }, terminal.gridSize());
    try testing.expect(!terminal.isDegraded());
    try testing.expectEqual(@as(usize, 0), terminal.ownershipViolations());
}

// --- keys, into a program that is really there ----------------------------

/// Vim with every file that could change what it does switched off: `-u NONE`
/// skips the vimrc *and* the defaults, `-i NONE` skips the viminfo, and `-N`
/// says nocompatible, which is what makes an editor read the arrow and
/// function keys as a terminal program. What is left is the editor itself, on
/// an empty buffer, on the terminal this file's tests give it.
// `-n`: no swap file. The editor is killed when a check ends, and an unnamed
// buffer's swap file lands in the first writable directory of vim's list
// (`/tmp` when the cwd is `/`); enough leftovers and vim refuses to start
// ("E326: Too many swap files found"), which once failed this test on a box
// where other checks had been killing editors all day.
const vim_argv = [_][]const u8{ "vim", "-u", "NONE", "-i", "NONE", "-N", "-n" };

/// The line editor's environment: the fixed test environment, plus the two
/// settings that would otherwise come from the machine. `INPUTRC=/dev/null`
/// keeps readline's key bindings at their compiled-in defaults, and `PS1` is a
/// prompt of our own so that waiting for the line editor to be ready does not
/// depend on which shell is installed.
const line_editor_env = [_][]const u8{
    "PATH=/usr/bin:/bin",
    "HOME=/tmp",
    "TERM=xterm-256color",
    "LANG=C",
    "INPUTRC=/dev/null",
    "PS1=conduit> ",
    // macOS's /bin/bash otherwise opens with two lines saying zsh is the default shell, which
    // pushes the prompt off the row the tests read. Other systems ignore it.
    "BASH_SILENCE_DEPRECATION_WARNING=1",
};

test "an editor on the far side of the pty acts on the keys this module encoded" {
    if (!has_pty_backend) return error.SkipZigTest;
    const testing = std.testing;
    const gpa = testing.allocator;

    // A real editor under a real pty, at the same 80 by 24 the terminal is
    // given: a session gives a program the size it drew for, and a test that
    // did not would be reading a screen the editor never intended to show.
    const child = try pty.spawn(gpa, request(&vim_argv));
    defer child.destroy();

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(gpa);

    var encoded: EncodedKey = .{};
    var row: [256]u8 = undefined;
    var waiting: GridHas = .{ .terminal = &terminal, .row = 1, .needle = "~" };

    // Ready: an empty buffer is a screen of tildes. Waited for with a condition
    // rather than a pause, because a key typed before the editor has read its
    // own startup would be racing it — and because the modes the editor asked
    // for only exist in the terminal once its own bytes have been fed in.
    try waitFor(gpa, child, &terminal, &waiting, GridHas.holds);

    // What the editor asked for on the way up, read back out of the terminal it
    // has been talking to, and the bytes those modes make ctrl+u encode to. A
    // comparison against what the *program* asked for rather than against a
    // table written down here: the editor turns on application cursor keys and
    // xterm's modifyOtherKeys before it draws anything, and a terminal that
    // ignored that would go on sending a key form the editor has already
    // promised to stop understanding.
    const ctrl_u_bytes = if (terminal.keyModes().modify_other_keys_state_2)
        "\x1b[27;5;117~" // xterm's modifyOtherKeys form of ctrl+u
    else
        "\x15"; // the C0 control, which is what every shell binds to

    // A plain key. `i` puts the editor in insert mode, and the mode it
    // announces is on the last row of the screen.
    try testing.expectEqualStrings("i", try sendKey(&terminal, child, .{
        .text = "i",
        .unshifted_codepoint = 'i',
    }, &encoded));
    waiting = .{ .terminal = &terminal, .row = 23, .needle = "-- INSERT --" };
    try waitFor(gpa, child, &terminal, &waiting, GridHas.holds);

    // Text, one key at a time, through the same encoder.
    try typeText(&terminal, child, "hello world");
    waiting = .{ .terminal = &terminal, .row = 0, .needle = "hello world" };
    try waitFor(gpa, child, &terminal, &waiting, GridHas.holds);
    try testing.expectEqualStrings("hello world", try readRow(&terminal, 0, &row));

    // A ctrl key, and the part that makes this a measurement rather than an
    // echo: ctrl+u in insert mode deletes what was inserted before the
    // cursor, so the line goes empty. Anything that only reflected the byte
    // would have left `hello world` where it was.
    try testing.expectEqualStrings(ctrl_u_bytes, try sendKey(&terminal, child, .{
        .mods = .{ .ctrl = true },
        .text = "u",
        .unshifted_codepoint = 'u',
    }, &encoded));
    waiting = .{ .terminal = &terminal, .row = 0, .needle = "hello world", .present = false };
    try waitFor(gpa, child, &terminal, &waiting, GridHas.holds);
    try testing.expectEqualStrings("", try readRow(&terminal, 0, &row));

    // Which the next keys show. If the encoder had sent ctrl+u as text the
    // row would read `hello worldCtrl`; if it had dropped the key the row
    // would read `Ctrl` on top of `hello world`. It reads `Ctrl` alone.
    try typeText(&terminal, child, "Ctrl");
    waiting = .{ .terminal = &terminal, .row = 0, .needle = "Ctrl" };
    try waitFor(gpa, child, &terminal, &waiting, GridHas.holds);
    try testing.expectEqualStrings("Ctrl", try readRow(&terminal, 0, &row));

    // Escape leaves insert mode, which the editor announces by taking the
    // message off the screen.
    try testing.expectEqualStrings("\x1b", try sendKey(&terminal, child, .{ .key = .escape }, &encoded));
    waiting = .{ .terminal = &terminal, .row = 23, .needle = "-- INSERT --", .present = false };
    try waitFor(gpa, child, &terminal, &waiting, GridHas.holds);

    // A function key. F1 is the editor's help window: a full-screen change of
    // state that nothing about the terminal's own state could produce, and
    // that only a program which read the key it was sent can make.
    try testing.expectEqualStrings("\x1bOP", try sendKey(&terminal, child, .{ .key = .f1 }, &encoded));
    waiting = .{ .terminal = &terminal, .row = 0, .needle = "help.txt" };
    try waitFor(gpa, child, &terminal, &waiting, GridHas.holds);

    // The window the buffer was in is gone: the help file is on the screen
    // instead, and the text the keys above typed is not.
    try testing.expect(std.mem.indexOf(u8, try readRow(&terminal, 0, &row), "help.txt") != null);
    try testing.expect(std.mem.indexOf(u8, try readRow(&terminal, 0, &row), "Ctrl") == null);

    // Still the same editor, still running, after every key above: the session
    // never dropped the child it was talking to.
    try testing.expectEqual(pty.ChildState.running, child.state());
    try testing.expectEqual(@as(usize, 0), terminal.ownershipViolations());
}

test "a line editor moves its cursor on the alt key the encoder sent" {
    if (!has_pty_backend) return error.SkipZigTest;
    const testing = std.testing;
    const gpa = testing.allocator;

    // A shell with its line editor on it: `bash --norc --noprofile -i` is
    // interactive, so it edits the line the way a user sees it being edited,
    // and it reads no startup file of anybody's, so what its keys mean is
    // decided by the binary and not by the machine.
    const child = try pty.spawn(gpa, requestIn(
        &.{ "bash", "--norc", "--noprofile", "-i" },
        &line_editor_env,
    ));
    defer child.destroy();

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(gpa);
    // These expectations are Alt's: ESC-prefixed. On macOS the key is Option,
    // which composes characters unless Option-as-Alt is configured (and the
    // product policy for that is TASK-15), so ask for Alt explicitly there.
    // Off macOS the setting is inert.
    terminal.setMacosOptionAsAlt(true);

    var encoded: EncodedKey = .{};
    var row: [256]u8 = undefined;
    var waiting: GridHas = .{ .terminal = &terminal, .row = 0, .needle = "conduit>" };

    // The prompt is the line editor saying it has a line to edit. Until it
    // has printed one, a key typed at it would be read and echoed by the line
    // discipline, and the test would be measuring the tty rather than the
    // program. The needle has no trailing space because a row of the grid is
    // read with its trailing blanks trimmed.
    try waitFor(gpa, child, &terminal, &waiting, GridHas.holds);

    try typeText(&terminal, child, "echo one two");
    waiting = .{ .terminal = &terminal, .row = 0, .needle = "echo one two" };
    try waitFor(gpa, child, &terminal, &waiting, GridHas.holds);

    // Alt+b, which the line editor reads as backward-word. The bytes depend on
    // the mode in force, so the expectation follows the mode rather than being
    // written down: with nothing here having asked for a protocol beyond the
    // legacy one, alt is the ESC prefix — the two bytes every terminal has
    // sent for it since there were terminals — and what is being pinned here
    // is that the encoder sends what the program asked for.
    const alt_b_bytes = if (terminal.keyModes().modify_other_keys_state_2)
        "\x1b[27;3;98~" // xterm's modifyOtherKeys form of alt+b
    else
        "\x1bb"; // ESC then the key
    try testing.expect(terminal.keyModes().alt_esc_prefix);
    try testing.expectEqualStrings(alt_b_bytes, try sendKey(&terminal, child, .{
        .mods = .{ .alt = true },
        .text = "b",
        .unshifted_codepoint = 'b',
    }, &encoded));

    // A character typed after it lands where the cursor went, and Enter hands
    // the line to the shell.
    try typeText(&terminal, child, "X");
    try testing.expectEqualStrings("\r", try sendKey(&terminal, child, .{ .key = .enter }, &encoded));

    // The proof is the command the shell *ran*, not the line on screen: the
    // cursor went back over `two`, so the line was `echo one Xtwo` and echo
    // printed the word with the `X` in the middle of it. Had the key been
    // dropped the output would read `one twoX`; had it been sent as a plain
    // `b` it would read `one twob`.
    waiting = .{ .terminal = &terminal, .row = 1, .needle = "one Xtwo" };
    try waitFor(gpa, child, &terminal, &waiting, GridHas.holds);
    try testing.expectEqualStrings("one Xtwo", try readRow(&terminal, 1, &row));

    // And the editor drew that line itself: the two ESC-prefixed bytes are not
    // printable, so the text on the screen came from the program.
    try testing.expect(std.mem.indexOf(u8, try readRow(&terminal, 0, &row), "echo one Xtwo") != null);
    try testing.expectEqual(@as(usize, 0), terminal.ownershipViolations());
}

test "ctrl+c reaches a real process as the interrupt, and the process dies of it" {
    if (!has_pty_backend) return error.SkipZigTest;
    const testing = std.testing;
    const gpa = testing.allocator;

    // A process with nothing at all reading its input, so nothing it prints
    // can be the echo of what was typed: the only road from a key to this
    // child is the terminal's own input.
    //
    // It prints one word first, so that "the child is up and the terminal is
    // parsing what it says" is something the test waits for rather than
    // assumes. `pty.spawn` returns only once the child has exec'd, so the pty
    // is already this child's controlling terminal by the time the key below
    // goes out, and that is what turns one byte into a signal.
    const child = try pty.spawn(gpa, request(
        &.{ "/bin/sh", "-c", "printf 'conduit-sigint\\n'; exec sleep 30" },
    ));
    defer child.destroy();

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(gpa);

    var waiting: GridHas = .{ .terminal = &terminal, .row = 0, .needle = "conduit-sigint" };
    try waitFor(gpa, child, &terminal, &waiting, GridHas.holds);

    // The key every shell in history has bound to interrupt: one byte, the C0
    // control, because no program here has asked for anything else.
    var encoded: EncodedKey = .{};
    try testing.expectEqualStrings("\x03", try sendKey(&terminal, child, .{
        .mods = .{ .ctrl = true },
        .text = "c",
        .unshifted_codepoint = 'c',
    }, &encoded));

    // And what the process did about it: it died of SIGINT. Not a line of
    // output, not a redrawn prompt — an exit status, collected from the OS
    // after the byte went through the same encoder as every key above.
    try testing.expectEqual(
        pty.ChildState{ .exited = .{ .signal = .interrupt } },
        try waitForExit(child),
    );
    try testing.expectEqual(@as(usize, 0), terminal.ownershipViolations());
}

// --- a multiplexer, which is a program with state of its own ----------------

/// tmux's environment: the fixed test environment plus `SHELL`. tmux names a
/// window after the command it starts, so the window list this test reads off
/// the status line is only fixed if the shell is.
const tmux_env = [_][]const u8{
    // Homebrew's prefixes come after the system's, so where a distribution ships tmux in
    // /usr/bin that is the one found; macOS has no system tmux, and CI installs it with brew.
    "PATH=/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME=/tmp",
    "TERM=xterm-256color",
    "LANG=C",
    "SHELL=/bin/sh",
};

/// Everything this test tells tmux, and nothing else.
///
/// Two of the lines take the machine out of what the status line shows:
/// automatic renaming would name a window after whatever its shell has run so
/// far, and the status-right segment carries the host name and the clock — so
/// what the test reads is the window list and nothing else.
///
/// The other two are the bindings. tmux 3.6 binds no function key and no meta
/// key in its root table at all — `list-keys -T root` has no `F1` and no `M-`
/// entry that is not a mouse binding — so a function key and an alt key that
/// tmux itself acts on need one binding each, and the test gives them the two a
/// user's `tmux.conf` would. What that makes the test prove is not that tmux
/// runs those commands: it is that the bytes `encodeKey` produced were parsed
/// by tmux as `F1` and as `M-n`, because a binding on any other key would not
/// have fired.
const tmux_config =
    \\set -g automatic-rename off
    \\set -g status-right ""
    // The test types keys faster than any human. tmux treats a key arriving
    // within assume-paste-time (default 1 ms) of the previous one as pasted
    // text and skips bindings for it, so F1 would reach the pane as a literal.
    \\set -g assume-paste-time 0
    \\bind -n F1 new-window
    \\bind -n M-n next-window
    \\
;

/// This process's id, which is what makes a scratch directory belong to one
/// run of a test: two test binaries at once must not find each other's server.
fn currentProcessId() ?u64 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        .macos => @intCast(std.c.getpid()),
        else => null,
    };
}

/// End the tmux server on `socket` and report how the command ended.
///
/// A tmux server outlives its client by design — that is most of what a
/// multiplexer is for — so ending it belongs to the test rather than to the
/// pty. What is left behind would be a process nobody asked for, holding a
/// socket that the next run deletes out from under it.
fn killTmuxServer(gpa: Allocator, socket: []const u8) !pty.ChildState {
    const argv = [_][]const u8{ "tmux", "-S", socket, "kill-server" };
    const killer = try pty.spawn(gpa, requestIn(&argv, &tmux_env));
    defer killer.destroy();
    return waitForExit(killer);
}

test "tmux runs a command for the keys this module encoded, and its status line says which" {
    if (!has_pty_backend) return error.SkipZigTest;
    const testing = std.testing;
    const gpa = testing.allocator;
    const pid = currentProcessId() orelse return error.SkipZigTest;

    // tmux's socket and configuration live in a directory named for this run.
    var scratch = try std.Io.Dir.openDirAbsolute(testing.io, "/tmp", .{});
    defer scratch.close(testing.io);
    const name = try std.fmt.allocPrint(gpa, "conduit-term-tmux-{d}", .{pid});
    defer gpa.free(name);
    // Removing a path that is not there is not an error, so this also clears
    // anything a run of this test that died before it could clean up left
    // behind: the name is the test's own, so nothing else can be in it. The
    // same call on the way out is deliberately not a failure — what it removes
    // is a directory this test created, and a green test is not the place to
    // report that a removal failed.
    scratch.deleteTree(testing.io, name) catch {};
    defer scratch.deleteTree(testing.io, name) catch {};
    var home = try scratch.createDirPathOpen(testing.io, name, .{});
    defer home.close(testing.io);
    const config = try std.fmt.allocPrint(gpa, "/tmp/{s}/tmux.conf", .{name});
    defer gpa.free(config);
    try home.writeFile(testing.io, .{ .sub_path = "tmux.conf", .data = tmux_config });
    const socket = try std.fmt.allocPrint(gpa, "/tmp/{s}/tmux.sock", .{name});
    defer gpa.free(socket);

    // The server first and detached, so that the client below has a session to
    // attach to and both ends of it belong to this test. This command runs once
    // and exits; the daemon it leaves behind is this test's to end.
    const tmux_server = [_][]const u8{
        "tmux", "-S", socket,    "-f", config,  "new-session",
        "-d",   "-s", "conduit", "-n", "probe", "/bin/sh",
    };
    const server = try pty.spawn(gpa, requestIn(&tmux_server, &tmux_env));
    defer server.destroy();
    try testing.expectEqual(pty.ChildState{ .exited = .{ .code = 0 } }, try waitForExit(server));

    // Then the client, over the pty, drawing into the terminal below.
    const tmux_client = [_][]const u8{ "tmux", "-S", socket, "attach-session", "-t", "conduit" };
    const client = try pty.spawn(gpa, requestIn(&tmux_client, &tmux_env));
    defer client.destroy();
    // Registered after the client's own teardown so that it runs *before* it:
    // from here on the server is this test's to end, whether the test goes on
    // to pass or gives up half way through. The call at the bottom of this
    // function is the one that checks the ending worked; this one is the net,
    // and it is deliberately blind to the "no server running" it will be the
    // first to see on the path where the call below already did the work.
    defer {
        _ = killTmuxServer(gpa, socket) catch {};
    }

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(gpa);
    // The M-n binding is Alt's: ESC-prefixed. On macOS the key is Option,
    // which composes characters unless Option-as-Alt is configured (and the
    // product policy for that is TASK-15), so ask for Alt explicitly there.
    // Off macOS the setting is inert.
    terminal.setMacosOptionAsAlt(true);

    var encoded: EncodedKey = .{};
    var row: [256]u8 = undefined;
    var waiting: GridHas = .{ .terminal = &terminal, .row = 23, .needle = "0:probe*" };

    // Ready: the client has drawn and the status line names the session's one
    // window. tmux asks the terminal questions on the way up, and every round
    // of `waitFor` answers them, which is what a session does and what lets the
    // client finish starting without waiting anything out.
    try waitFor(gpa, client, &terminal, &waiting, GridHas.holds);

    // tmux has asked for application cursor keys and nothing beyond the legacy
    // protocol, so a ctrl key is the C0 control and an alt key is the ESC
    // prefix. The expectation follows the mode rather than being written down,
    // so what is pinned is that the encoder sends what the program asked for.
    const ctrl_b_bytes = if (terminal.keyModes().modify_other_keys_state_2)
        "\x1b[98;5u" // xterm's modifyOtherKeys form of ctrl+b
    else
        "\x02"; // the C0 control, which is tmux's own prefix key
    const alt_n_bytes = if (terminal.keyModes().modify_other_keys_state_2)
        "\x1b[27;3;110~" // xterm's modifyOtherKeys form of alt+n
    else
        "\x1bn"; // ESC then the key
    try testing.expect(terminal.keyModes().alt_esc_prefix);

    // 1. A ctrl key. ctrl+b is tmux's prefix and `c` behind it is a new window
    //    in tmux's own default table, so nothing in the configuration above is
    //    involved: the status line grows a second entry and the star moves to
    //    it, which is tmux creating a window because of a key it read.
    try testing.expectEqualStrings(ctrl_b_bytes, try sendKey(&terminal, client, .{
        .mods = .{ .ctrl = true },
        .text = "b",
        .unshifted_codepoint = 'b',
    }, &encoded));
    try testing.expectEqualStrings("c", try sendKey(&terminal, client, .{
        .text = "c",
        .unshifted_codepoint = 'c',
    }, &encoded));
    waiting = .{ .terminal = &terminal, .row = 23, .needle = "1:sh*" };
    try waitFor(gpa, client, &terminal, &waiting, GridHas.holds);

    // 2. A function key, on the binding the configuration gave it: a third
    //    window, and the star on it.
    try testing.expectEqualStrings("\x1bOP", try sendKey(&terminal, client, .{ .key = .f1 }, &encoded));
    waiting = .{ .terminal = &terminal, .row = 23, .needle = "2:sh*" };
    try waitFor(gpa, client, &terminal, &waiting, GridHas.holds);

    // 3. An alt key, on its binding — and this one adds no window, so it is the
    //    clearest of the three: the star leaves window 2 and comes to rest on
    //    window 0. A key that had been dropped would leave it on 2, and one
    //    that had arrived as a plain `n` would have typed an `n` into a shell.
    try testing.expectEqualStrings(alt_n_bytes, try sendKey(&terminal, client, .{
        .key = .unidentified,
        .mods = .{ .alt = true },
        .text = "n",
        .unshifted_codepoint = 'n',
    }, &encoded));
    waiting = .{ .terminal = &terminal, .row = 23, .needle = "0:probe*" };
    try waitFor(gpa, client, &terminal, &waiting, GridHas.holds);

    // The window list as the last key left it. tmux gives the active window a
    // `*`, the window that *was* active a `-` and the rest nothing — and it
    // keeps that flag column's width whether it is used or not, which is why
    // the middle entry is followed by two spaces and not one.
    //
    // So this one line is the whole claim about the alt key: before it the star
    // was on window 2, and now it is on window 0 with window 2 the one that
    // was, which is what `next-window` does and nothing else does.
    const status = try readRow(&terminal, 23, &row);
    try testing.expect(std.mem.indexOf(u8, status, "[conduit] 0:probe* 1:sh  2:sh-") != null);
    // And the star is on the first window and on no other.
    try testing.expect(std.mem.indexOf(u8, status, "1:sh*") == null);
    try testing.expect(std.mem.indexOf(u8, status, "2:sh*") == null);
    try testing.expectEqual(pty.ChildState.running, client.state());
    try testing.expectEqual(@as(usize, 0), terminal.ownershipViolations());

    // End the server here, in the body, so that the fact there *was* a server
    // to end is something the test checks rather than something it assumes.
    try testing.expectEqual(pty.ChildState{ .exited = .{ .code = 0 } }, try killTmuxServer(gpa, socket));
}

test "a terminal, a real child and its descriptors are all released" {
    if (!has_pty_backend) return error.SkipZigTest;
    const testing = std.testing;
    const gpa = testing.allocator;

    const before = countOpenDescriptors() orelse return error.SkipZigTest;
    for (0..5) |_| {
        const child = try pty.spawn(gpa, request(&.{ "/bin/sh", "-c", "exit 0" }));

        var terminal: Terminal = undefined;
        try terminal.init(testIo(), gpa, .{ .cols = 80, .rows = 24 });

        // The whole session-shaped lifecycle, then let it all go.
        try terminal.resizeChild(gpa, child, .{ .cols = 100, .rows = 40 });
        terminal.feed("hello\r\n");
        try terminal.refresh(gpa);
        var answers: [64]u8 = undefined;
        _ = terminal.takeResponses(&answers);

        // The exit status is only ever reported by a wait, so observing it is
        // also proof the child was collected rather than left behind as a
        // process.
        try testing.expectEqual(
            pty.ChildState{ .exited = .{ .code = 0 } },
            try waitForExit(child),
        );
        terminal.deinit(gpa);
        child.destroy();
    }

    // Measured, not assumed: the descriptors the session held are the
    // terminal's own, which `pty` has already proven it returns, so the
    // terminal adding none is what this number shows.
    try testing.expectEqual(before, countOpenDescriptors().?);
}

// --- scrollback and the viewport -------------------------------------------

/// `count` numbered lines, each ending a row, as a program would print them.
///
/// Numbered because a scrollback test has to say which line it is looking at:
/// "there is text" cannot tell a view of history from a view of the screen.
fn numberedLines(gpa: Allocator, count: usize) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    var scratch: [32]u8 = undefined;
    var line: usize = 1;
    while (line <= count) : (line += 1) {
        const one = try std.fmt.bufPrint(&scratch, "line-{d:0>4}\r\n", .{line});
        try text.appendSlice(gpa, one);
    }
    return text.toOwnedSlice(gpa);
}

test "a notched wheel moves three lines and a trackpad pixel moves a fraction of one" {
    const testing = std.testing;

    var motion: ScrollAccumulator = .{};
    const config: ScrollConfig = .{};

    // One notch is three rows, in the engine's convention: up is negative.
    try testing.expectEqual(@as(isize, -3), motion.rows(.{ .dy = 1 }, config));
    try testing.expectEqual(@as(isize, 3), motion.rows(.{ .dy = -1 }, config));
    try testing.expectEqual(@as(f32, 0), motion.pending);

    // A trackpad is a distance, not a count, so the mapping divides. Forty
    // pixels is one row at the default ratio.
    var smooth: ScrollAccumulator = .{};
    try testing.expectEqual(@as(isize, 0), smooth.rows(.{ .dy = 20, .precise = true }, config));
    try testing.expectEqual(@as(isize, -1), smooth.rows(.{ .dy = 20, .precise = true }, config));
    try testing.expectEqual(@as(isize, -1), smooth.rows(.{ .dy = 40, .precise = true }, config));

    // macOS natural scrolling inverts the axis, and the terminal follows the
    // user's setting rather than X11's.
    var flipped: ScrollAccumulator = .{};
    try testing.expectEqual(@as(isize, 3), flipped.rows(.{ .dy = 1, .flipped = true }, config));
}

test "sub-row travel is carried, spent, and never grows without bound" {
    const testing = std.testing;

    var motion: ScrollAccumulator = .{};
    const config: ScrollConfig = .{};

    // Ten tenths of a row make one row and no more; the fraction in between is
    // not thrown away, which is the whole reason the accumulator exists.
    var total: isize = 0;
    for (0..10) |_| total += motion.rows(.{ .dy = 4, .precise = true }, config);
    try testing.expectEqual(@as(isize, -1), total);
    try testing.expect(motion.pending > -0.01 and motion.pending < 0.01);

    // The carried fraction never leaves (-1, 1), so a long gesture cannot build
    // up a reserve that fires a screenful of scroll at the end of it.
    for (0..1000) |_| _ = motion.rows(.{ .dy = 4000, .precise = true }, config);
    try testing.expect(motion.pending > -1.0 and motion.pending < 1.0);

    // Reset is what an edge calls: the fraction described travel that did not
    // happen, so the reversal starts from nothing.
    motion.pending = 0.9;
    motion.reset();
    try testing.expectEqual(@as(f32, 0), motion.pending);
}

test "a delta that is not a number or is absurd is refused rather than believed" {
    const testing = std.testing;

    var motion: ScrollAccumulator = .{};
    const config: ScrollConfig = .{};

    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |bad| {
        try testing.expectEqual(@as(isize, 0), motion.rows(.{ .dy = bad }, config));
    }
    try testing.expectEqual(@as(f32, 0), motion.pending);

    // A driver reporting a million pixels in one event is bounded, not obeyed.
    try testing.expect(motion.rows(.{ .dy = 1_000_000, .precise = true }, config) >= -@as(isize, @intCast(ScrollConfig.line_ceiling)));
}

test "the scrollback configuration is bounded before anything uses it" {
    const testing = std.testing;

    const defaults: ScrollConfig = .{};
    try testing.expectEqual(@as(?usize, 10_000), defaults.max_scrollback_lines);
    try testing.expectEqual(ReturnPolicy.on_typing, defaults.return_policy);

    // A limit that asks for more than a terminal can hold is clamped, not
    // believed: a scrollback limit is a claim about memory.
    const greedy = (ScrollConfig{
        .max_scrollback_lines = ScrollConfig.line_ceiling * 4,
        .max_scrollback_bytes = ScrollConfig.byte_ceiling * 4,
    }).bounded();
    try testing.expectEqual(@as(?usize, ScrollConfig.line_ceiling), greedy.max_scrollback_lines);
    try testing.expectEqual(@as(?usize, ScrollConfig.byte_ceiling), greedy.max_scrollback_bytes);

    // A ratio that is not a number is the case a clamp cannot catch on its own:
    // every comparison against NaN is false, so it would otherwise sail through
    // and make a view that will not stop.
    const broken = (ScrollConfig{
        .lines_per_notch = std.math.nan(f32),
        .pixels_per_row = std.math.inf(f32),
    }).bounded();
    try testing.expect(std.math.isFinite(broken.lines_per_notch));
    try testing.expect(std.math.isFinite(broken.pixels_per_row));
    // A null limit is still null after bounding: "no line limit" is a real
    // request, and clamping it would silently become a number.
    try testing.expectEqual(@as(?usize, null), (ScrollConfig{ .max_scrollback_lines = null }).bounded().max_scrollback_lines);
}

fn finishScrollbackSearch(search: *ScrollbackSearch) !void {
    // Each tick consumes at least one page-sized unit. This guard is not a
    // timeout: it makes a stalled state-machine failure deterministic.
    for (0..4096) |_| {
        switch (try search.step(8)) {
            .running => {},
            .complete => return,
            .scratch_exhausted => return error.SearchScratchExhausted,
        }
    }
    return error.SearchDidNotComplete;
}

const TestSearchCollection = struct {
    count: usize,
    truncated: bool,
    progress: SearchProgress,
};

fn collectScrollbackSearch(
    search: *ScrollbackSearch,
    terminal: *Terminal,
    output: []SearchMatch,
) !TestSearchCollection {
    var cursor = try search.startCursor(terminal, .older);
    var count: usize = 0;
    var truncated = false;
    var page: [64]LocatedSearchMatch = undefined;
    for (0..4096) |_| {
        const batch = try search.scan(terminal, &cursor, page.len, &page);
        for (batch.items) |located| {
            if (count < output.len) {
                output[count] = located.match;
                count += 1;
            } else {
                truncated = true;
            }
        }
        if (batch.stop == .current_boundary or batch.stop == .scratch_exhausted) return .{
            .count = count,
            .truncated = truncated,
            .progress = batch.progress,
        };
    }
    return error.SearchDidNotComplete;
}

test "scrollback search returns visible and off-screen ranges newest first" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 20, .rows = 2 });
    defer terminal.deinit(gpa);
    terminal.feed("old needle\r\nfiller one\r\nfiller two\r\nnew needle");

    var scratch: [512 * 1024]u8 = undefined;
    var search: ScrollbackSearch = undefined;
    try search.init(&terminal, "needle", .ascii_insensitive, &scratch);
    defer search.deinit();
    try finishScrollbackSearch(&search);

    var storage: [4]SearchMatch = undefined;
    const found = try collectScrollbackSearch(&search, &terminal, &storage);
    try testing.expectEqual(SearchProgress.complete, found.progress);
    try testing.expectEqual(@as(usize, 2), found.count);
    try testing.expect(!found.truncated);

    // Index zero is the newest match, so a UI can keep a stable current index
    // while more, older pages are discovered. Both ranges are cell-inclusive.
    try testing.expect(storage[0].first.row > storage[1].first.row);
    try testing.expectEqual(@as(u16, 4), storage[0].first.col);
    try testing.expectEqual(@as(u16, 9), storage[0].last.col);
    try testing.expectEqual(storage[0].first.row, storage[0].last.row);

    var limited_storage: [1]SearchMatch = undefined;
    const limited = try collectScrollbackSearch(&search, &terminal, &limited_storage);
    try testing.expectEqual(@as(usize, 1), limited.count);
    try testing.expect(limited.truncated);
    try testing.expectEqual(storage[0].first.row, limited_storage[0].first.row);

    // The recent result is already visible. Following the older result moves
    // the real viewport into history without rerunning or reallocating search.
    try testing.expect(!try terminal.revealSearchMatch(storage[0]));
    try testing.expect(try terminal.revealSearchMatch(storage[1]));
    try testing.expect(terminal.viewport().offset != 0);
}

test "scrollback literal search has distinct exact and ASCII-insensitive modes" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 30, .rows = 2 });
    defer terminal.deinit(gpa);
    terminal.feed("Alpha alpha ALPHA");

    var scratch: [512 * 1024]u8 = undefined;
    var storage: [4]SearchMatch = undefined;
    {
        var search: ScrollbackSearch = undefined;
        try search.init(&terminal, "alpha", .ascii_insensitive, &scratch);
        defer search.deinit();
        try finishScrollbackSearch(&search);
        const found = try collectScrollbackSearch(&search, &terminal, &storage);
        try testing.expectEqual(@as(usize, 3), found.count);
        try testing.expectEqual(@as(u16, 12), storage[0].first.col);
        try testing.expectEqual(@as(u16, 6), storage[1].first.col);
        try testing.expectEqual(@as(u16, 0), storage[2].first.col);
    }
    {
        var search: ScrollbackSearch = undefined;
        try search.init(&terminal, "alpha", .sensitive, &scratch);
        defer search.deinit();
        try finishScrollbackSearch(&search);
        const found = try collectScrollbackSearch(&search, &terminal, &storage);
        try testing.expectEqual(@as(usize, 1), found.count);
        try testing.expectEqual(@as(u16, 6), storage[0].first.col);
        try testing.expectEqual(@as(u16, 10), storage[0].last.col);
    }
}

test "bounded exact-case cursors cross arbitrary output pages without rescanning" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 20, .rows = 2 });
    defer terminal.deinit(gpa);
    var content: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&content);
    for (0..280) |index| {
        try writer.print("{s}-{d:0>3}\r\n", .{
            if (index % 2 == 0) "needle" else "NEEDLE",
            index,
        });
    }
    terminal.feed(content[0..writer.end]);

    var scratch: [1024 * 1024]u8 = undefined;
    var search: ScrollbackSearch = undefined;
    try search.init(&terminal, "needle", .sensitive, &scratch);
    defer search.deinit();
    try finishScrollbackSearch(&search);

    var page: [5]LocatedSearchMatch = undefined;
    var older = try search.startCursor(&terminal, .older);
    var older_total: usize = 0;
    var older_previous: ?usize = null;
    for (0..4096) |_| {
        const batch = try search.scan(&terminal, &older, 3, &page);
        try testing.expect(batch.examined <= 3);
        for (batch.items) |located| {
            if (older_previous) |previous| try testing.expect(located.candidate_index > previous);
            older_previous = located.candidate_index;
            older_total += 1;
        }
        if (batch.stop == .current_boundary) break;
    } else return error.SearchDidNotComplete;
    try testing.expectEqual(@as(usize, 140), older_total);
    try testing.expect(older_total > 128);

    var newer = try search.startCursor(&terminal, .newer);
    var newer_total: usize = 0;
    var newer_previous: ?usize = null;
    for (0..4096) |_| {
        const batch = try search.scan(&terminal, &newer, 3, &page);
        try testing.expect(batch.examined <= 3);
        for (batch.items) |located| {
            if (newer_previous) |previous| try testing.expect(located.candidate_index < previous);
            newer_previous = located.candidate_index;
            newer_total += 1;
        }
        if (batch.stop == .current_boundary) break;
    } else return error.SearchDidNotComplete;
    try testing.expectEqual(older_total, newer_total);
}

test "regex scrollback search is bounded, case-aware, and navigates both directions" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 24, .rows = 2 });
    defer terminal.deinit(gpa);
    terminal.feed(
        "alpha-123\r\nfill\r\nALPHA-456\r\nfill\r\nalpha-789\r\nfill",
    );

    var scratch: [512 * 1024]u8 = undefined;
    var storage: [8]SearchMatch = undefined;
    {
        var search: ScrollbackSearch = undefined;
        try search.initRegex(&terminal, "alpha-[0-9]{3}", .ascii_insensitive, &scratch);
        defer search.deinit();
        try finishScrollbackSearch(&search);
        const found = try collectScrollbackSearch(&search, &terminal, &storage);
        try testing.expectEqual(@as(usize, 3), found.count);
        try testing.expect(storage[0].first.row > storage[1].first.row);
        try testing.expect(storage[1].first.row > storage[2].first.row);

        var newer = try search.startCursor(&terminal, .newer);
        var page: [1]LocatedSearchMatch = undefined;
        var previous_row: ?u32 = null;
        var count: usize = 0;
        for (0..128) |_| {
            const batch = try search.scan(&terminal, &newer, 1, &page);
            try testing.expect(batch.examined <= 1);
            for (batch.items) |located| {
                if (previous_row) |previous| try testing.expect(located.match.first.row > previous);
                previous_row = located.match.first.row;
                count += 1;
            }
            if (batch.stop == .current_boundary) break;
        } else return error.SearchDidNotComplete;
        try testing.expectEqual(found.count, count);
    }
    {
        var search: ScrollbackSearch = undefined;
        try search.initRegex(&terminal, "alpha-[0-9]{3}", .sensitive, &scratch);
        defer search.deinit();
        const found = try collectScrollbackSearch(&search, &terminal, &storage);
        try testing.expectEqual(@as(usize, 2), found.count);
    }
}

test "regex scrollback search joins soft wraps in both directions and resyncs after resize" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 8, .rows = 3 });
    defer terminal.deinit(gpa);
    // Only the first `abCD` is one logical line. The second pair is split by
    // a hard newline and must never be promoted into a match.
    terminal.feed("prefixabCDsuffix\r\nab\r\nCD");

    var scratch: [512 * 1024]u8 = undefined;
    var search: ScrollbackSearch = undefined;
    try search.initRegex(&terminal, "abC[D]", .sensitive, &scratch);
    defer search.deinit();

    var older_page: [2]LocatedSearchMatch = undefined;
    var older = try search.startCursor(&terminal, .older);
    const older_batch = try search.scan(&terminal, &older, 8, &older_page);
    try testing.expectEqual(@as(usize, 1), older_batch.items.len);
    const before_resize = older_batch.items[0].match;
    try testing.expect(before_resize.first.row < before_resize.last.row);
    try testing.expectEqual(@as(u16, 6), before_resize.first.col);
    try testing.expectEqual(@as(u16, 1), before_resize.last.col);

    var newer_page: [2]LocatedSearchMatch = undefined;
    var newer = try search.startCursor(&terminal, .newer);
    var newer_count: usize = 0;
    for (0..16) |_| {
        const batch = try search.scan(&terminal, &newer, 8, &newer_page);
        newer_count += batch.items.len;
        if (batch.stop == .current_boundary) break;
    } else return error.SearchDidNotComplete;
    try testing.expectEqual(@as(usize, 1), newer_count);

    // Seven columns reflow the logical line to "prefixa" / "bCDsuff" / "ix",
    // so the match still crosses a soft wrap after resync. Six columns would
    // put the whole of `abCD` on the second row and prove nothing about
    // wrap joining.
    try terminal.resize(gpa, .{ .cols = 7, .rows = 3 });
    try testing.expectError(error.StaleSearch, search.startCursor(&terminal, .older));
    try testing.expectError(
        error.StaleSearchMatch,
        terminal.revealSearchMatch(before_resize),
    );
    try search.sync(&terminal, true);

    var storage: [2]SearchMatch = undefined;
    const resized = try collectScrollbackSearch(&search, &terminal, &storage);
    try testing.expectEqual(@as(usize, 1), resized.count);
    try testing.expect(storage[0].first.row < storage[0].last.row);
    try testing.expectEqual(@as(u16, 6), storage[0].first.col);
    try testing.expectEqual(@as(u16, 2), storage[0].last.col);
    try testing.expectEqual(terminal.search_generation, storage[0].generation);
}

test "regex scrollback search joins a soft wrap across page nodes" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 200, .rows = 2 });
    defer terminal.deinit(gpa);

    // One 50,001-cell logical line: 251 soft-wrapped rows at 200 columns,
    // which exceeds a standard page's row capacity and therefore spans two
    // page nodes. The match must start in the first node and end in the
    // last, so the subject is `a`, a long run of `Z`, then a final `a`.
    //
    // The pattern is `a.*a` rather than a greedy run such as `Z+a` because
    // the search is deliberately bounded. Oniguruma compiles a greedy
    // single-character repeat to one backtrack entry per consumed cell, so
    // a run longer than `regex_match_stack_limit` cells is reported as a
    // work-limit overflow in either direction. `.*` followed by a literal
    // compiles to a peek-next scan that only pushes where that literal
    // occurs, so the whole line costs one push and one retry. The leading
    // `a` matters too: newest-first search runs Oniguruma backwards, which
    // reports the newest start and never lets a match extend past the
    // search start, so without a unique leading anchor only a short match
    // inside the last node would ever be reported. The subject has no
    // newline between rows, so `.*` crossing every soft wrap is itself proof
    // that the rows were joined.
    const content = try gpa.alloc(u8, 50_001);
    defer gpa.free(content);
    @memset(content, 'Z');
    content[0] = 'a';
    content[content.len - 1] = 'a';
    terminal.feed(content);

    const pages = &terminal.vt.screens.active.pages;
    try testing.expect(pages.pages.first.? != pages.pages.last.?);

    var scratch: [1024 * 1024]u8 = undefined;
    var search: ScrollbackSearch = undefined;
    try search.initRegex(&terminal, "a.*a", .sensitive, &scratch);
    defer search.deinit();

    var storage: [2]SearchMatch = undefined;
    const found = try collectScrollbackSearch(&search, &terminal, &storage);
    try testing.expectEqual(SearchProgress.complete, found.progress);
    try testing.expectEqual(@as(usize, 1), found.count);
    try testing.expect(storage[0].first.row < storage[0].last.row);
    try testing.expectEqual(@as(u16, 0), storage[0].first.col);
    try testing.expectEqual(@as(u32, 0), storage[0].first.row);
    try testing.expectEqual(@as(u16, 0), storage[0].last.col);
    try testing.expectEqual(@as(u32, 250), storage[0].last.row);

    const first = pages.pin(.{ .screen = .{
        .x = storage[0].first.col,
        .y = storage[0].first.row,
    } }).?;
    const last = pages.pin(.{ .screen = .{
        .x = storage[0].last.col,
        .y = storage[0].last.row,
    } }).?;
    try testing.expect(first.node != last.node);
}

test "regex search rejects malformed and excessive patterns without terminal damage" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 20, .rows = 2 });
    defer terminal.deinit(gpa);
    terminal.feed("still alive");

    var scratch: [64 * 1024]u8 = undefined;
    var search: ScrollbackSearch = undefined;
    try testing.expectError(
        error.InvalidRegex,
        search.initRegex(&terminal, "(", .sensitive, &scratch),
    );

    var nested: [regex_nesting_limit + 2]u8 = undefined;
    @memset(nested[0..], '(');
    nested[nested.len - 1] = 'x';
    try testing.expectError(
        error.RegexTooComplex,
        search.initRegex(&terminal, &nested, .sensitive, &scratch),
    );
    try terminal.refresh(gpa);
    try testing.expect(terminal.visibleTextContains("still alive"));
}

test "regex search reports fixed scratch exhaustion and recovers on restart" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 160, .rows = 1 });
    defer terminal.deinit(gpa);
    var content: [150]u8 = @splat('a');
    content[149] = '7';
    terminal.feed(content[0..]);

    var tiny: [64]u8 = undefined;
    {
        var search: ScrollbackSearch = undefined;
        try search.initRegex(&terminal, "a+7", .sensitive, &tiny);
        defer search.deinit();
        var page: [1]LocatedSearchMatch = undefined;
        var cursor = try search.startCursor(&terminal, .older);
        const batch = try search.scan(&terminal, &cursor, 1, &page);
        try testing.expectEqual(SearchScanStop.scratch_exhausted, batch.stop);
        try testing.expectEqual(SearchProgress.scratch_exhausted, batch.progress);
    }

    var roomy: [512 * 1024]u8 = undefined;
    {
        var search: ScrollbackSearch = undefined;
        try search.initRegex(&terminal, "a+7", .sensitive, &roomy);
        defer search.deinit();
        var storage: [2]SearchMatch = undefined;
        const found = try collectScrollbackSearch(&search, &terminal, &storage);
        try testing.expectEqual(@as(usize, 1), found.count);
        try testing.expectEqual(SearchProgress.complete, found.progress);
    }
}

test "output and resize invalidate scrollback matches until search is synced" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 18, .rows = 2 });
    defer terminal.deinit(gpa);
    terminal.feed("needle one\r\nspacer");

    var scratch: [512 * 1024]u8 = undefined;
    var search: ScrollbackSearch = undefined;
    try search.init(&terminal, "needle", .sensitive, &scratch);
    defer search.deinit();
    try finishScrollbackSearch(&search);

    var storage: [8]SearchMatch = undefined;
    var found = try collectScrollbackSearch(&search, &terminal, &storage);
    try testing.expectEqual(@as(usize, 1), found.count);
    const before_output = storage[0];

    terminal.feed("\r\nneedle two");
    try testing.expectError(error.StaleSearch, search.startCursor(&terminal, .older));
    try testing.expectError(error.StaleSearchMatch, terminal.revealSearchMatch(before_output));

    try search.sync(&terminal, true);
    try finishScrollbackSearch(&search);
    found = try collectScrollbackSearch(&search, &terminal, &storage);
    try testing.expectEqual(@as(usize, 2), found.count);
    const before_resize = storage[0];

    try terminal.resize(gpa, .{ .cols = 10, .rows = 3 });
    try testing.expectError(error.StaleSearch, search.startCursor(&terminal, .older));
    try testing.expectError(error.StaleSearchMatch, terminal.revealSearchMatch(before_resize));

    try search.sync(&terminal, true);
    try finishScrollbackSearch(&search);
    found = try collectScrollbackSearch(&search, &terminal, &storage);
    try testing.expectEqual(@as(usize, 2), found.count);
    for (storage[0..found.count]) |match| {
        try testing.expect(match.first.col < terminal.gridSize().cols);
        try testing.expectEqual(match.generation, terminal.search_generation);
    }
}

test "the viewport starts at the bottom, scrolls into real history, and stops at the top" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 20, .rows = 5 });
    defer terminal.deinit(gpa);

    const printed = try numberedLines(gpa, 40);
    defer gpa.free(printed);
    terminal.feed(printed);
    try terminal.refresh(gpa);

    // "At the bottom" is one number, and this is it: nothing above the active
    // area is being shown.
    try testing.expect(terminal.viewport().atBottom());
    // Forty numbered lines on a five-row grid: thirty-six of them are history
    // and the last five rows are the active area.
    try testing.expectEqual(@as(usize, 36), terminal.viewport().history_rows);

    // Back three rows, and the top of the view is the thirty-fourth line: real
    // history, not blank cells where the history would be.
    terminal.scrollLines(-3);
    try terminal.refresh(gpa);
    try testing.expectEqual(@as(usize, 3), terminal.viewport().offset);
    var row: [64]u8 = undefined;
    try testing.expectEqualStrings("line-0034", try readRow(&terminal, 0, &row));
    // Every visible row moved, so the damage is the whole grid rather than a row.
    try testing.expectEqual(Damage.full, terminal.damage());

    // The top of the history is a real line too, and asking for more is not an
    // error: the engine clamps and the view is at the top.
    terminal.scrollToTop();
    try terminal.refresh(gpa);
    try testing.expectEqual(@as(usize, 36), terminal.viewport().offset);
    try testing.expectEqualStrings("line-0001", try readRow(&terminal, 0, &row));

    // A request past the top moves nothing and leaves the view where it was.
    terminal.scrollLines(-10_000);
    try terminal.refresh(gpa);
    try testing.expectEqual(@as(usize, 36), terminal.viewport().offset);

    terminal.scrollToBottom();
    try terminal.refresh(gpa);
    try testing.expect(terminal.viewport().atBottom());
    try testing.expectEqualStrings("line-0037", try readRow(&terminal, 0, &row));
}

test "visible text serializes the cached scrollback viewport" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 20, .rows = 5 });
    defer terminal.deinit(gpa);

    const printed = try numberedLines(gpa, 40);
    defer gpa.free(printed);
    terminal.feed(printed);
    terminal.scrollLines(-3);
    try terminal.refresh(gpa);

    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try terminal.writeVisibleText(&writer);
    try testing.expectEqualStrings(
        "line-0034\nline-0035\nline-0036\nline-0037\nline-0038",
        writer.buffered(),
    );
}

test "a resize while scrolled back keeps the view over history that still exists" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 20, .rows = 5 });
    defer terminal.deinit(gpa);

    const printed = try numberedLines(gpa, 40);
    defer gpa.free(printed);
    terminal.feed(printed);
    terminal.scrollLines(-3);
    try terminal.refresh(gpa);
    try testing.expectEqual(@as(usize, 3), terminal.viewport().offset);

    // A resize pulls rows out of scrollback into the active area, so the view
    // has less history above it. What it must never be is an offset past the
    // end of what is retained: that is a view of rows that are gone.
    try terminal.resize(gpa, .{ .cols = 30, .rows = 8 });
    try terminal.refresh(gpa);
    const view = terminal.viewport();
    try testing.expect(view.offset <= view.history_rows);
    // And the rows it does show are still real ones.
    var row: [64]u8 = undefined;
    const first = try readRow(&terminal, 0, &row);
    try testing.expect(std.mem.startsWith(u8, first, "line-"));
}

test "the scrollback limit is real: the terminal prunes what it was told to" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const printed = try numberedLines(gpa, 10_000);
    defer gpa.free(printed);

    // The default is a limit, not "no limit", and it is applied to the engine
    // by `init` rather than waiting for somebody to configure one.
    var roomy: Terminal = undefined;
    try roomy.init(testIo(), gpa, .{ .cols = 20, .rows = 5 });
    defer roomy.deinit(gpa);
    try testing.expectEqual(@as(?usize, 10_000), roomy.scrollConfig().max_scrollback_lines);
    roomy.feed(printed);
    try roomy.refresh(gpa);
    const unlimited_history = roomy.viewport().history_rows;
    try testing.expectEqual(@as(usize, 9_996), unlimited_history);

    var tight: Terminal = undefined;
    try tight.init(testIo(), gpa, .{ .cols = 20, .rows = 5 });
    defer tight.deinit(gpa);
    tight.setScrollConfig(.{ .max_scrollback_lines = 64 });
    try testing.expectEqual(@as(?usize, 64), tight.scrollConfig().max_scrollback_lines);
    tight.feed(printed);
    try tight.refresh(gpa);
    const limited_history = tight.viewport().history_rows;

    // The engine prunes whole pages and always keeps at least one, so the
    // number is not exactly 64. What it must be is a bound: the 295 rows an
    // unlimited terminal kept are not all still there.
    try testing.expect(limited_history < unlimited_history);
    try testing.expect(limited_history < unlimited_history / 2);
    // Whatever survived is still readable history, and the newest lines are
    // the ones kept: pruning drops the oldest.
    var row: [64]u8 = undefined;
    // The last line printed is the fourth row of a five-row grid: the trailing
    // line feed left an empty row under it.
    try testing.expectEqualStrings("line-10000", try readRow(&tight, 3, &row));

    // Zero lines means no history at all, which the engine spells as a byte
    // limit of zero, and then there is nowhere for the viewport to go.
    var none: Terminal = undefined;
    try none.init(testIo(), gpa, .{ .cols = 20, .rows = 5 });
    defer none.deinit(gpa);
    none.setScrollConfig(.{ .max_scrollback_lines = 0 });
    none.feed(printed);
    try none.refresh(gpa);
    try testing.expectEqual(@as(usize, 0), none.viewport().history_rows);
    try testing.expect(none.viewport().atBottom());
}

test "output does not drag a scrolled-back viewport away, and typing brings it back" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 20, .rows = 5 });
    defer terminal.deinit(gpa);

    const first = try numberedLines(gpa, 40);
    defer gpa.free(first);
    const more = try numberedLines(gpa, 10);
    defer gpa.free(more);

    // The default is `.on_typing`, and this is the reason it is the default: a
    // build printing while the user reads history must not drag the view to the
    // bottom on the first line.
    try testing.expectEqual(ReturnPolicy.on_typing, terminal.scrollConfig().return_policy);
    terminal.feed(first);
    terminal.scrollLines(-10);
    try terminal.refresh(gpa);
    try testing.expectEqual(@as(usize, 10), terminal.viewport().offset);

    // What is on screen, which is the claim a user would make about it. The
    // view is pinned to a row, so output scrolls past underneath it and the
    // row at the top does not change — even though the offset from the bottom
    // does, because the bottom has moved down.
    var row: [64]u8 = undefined;
    const before_output = try gpa.dupe(u8, try readRow(&terminal, 0, &row));
    defer gpa.free(before_output);

    terminal.feed(more);
    try terminal.refresh(gpa);
    try testing.expect(!terminal.viewport().atBottom());
    try testing.expectEqualStrings(before_output, try readRow(&terminal, 0, &row));
    try testing.expectEqual(@as(usize, 20), terminal.viewport().offset);

    // Typing is the unambiguous signal that the user is at the prompt now.
    terminal.userInput();
    try terminal.refresh(gpa);
    try testing.expect(terminal.viewport().atBottom());
    var found = false;
    for (0..5) |y| {
        if (std.mem.eql(u8, try readRow(&terminal, @intCast(y), &row), "line-0010")) found = true;
    }
    try testing.expect(found);

    // `.on_typing_or_output` is the other real answer, and it is chosen rather
    // than assumed: output brings the view back too.
    terminal.setScrollConfig(.{ .return_policy = .on_typing_or_output });
    terminal.scrollLines(-10);
    try terminal.refresh(gpa);
    try testing.expectEqual(@as(usize, 10), terminal.viewport().offset);
    terminal.feed(more);
    try terminal.refresh(gpa);
    try testing.expect(terminal.viewport().atBottom());

    // `.explicit_only` is the third: neither typing nor output moves it, which
    // is what reading a log that is still being written needs.
    terminal.setScrollConfig(.{ .return_policy = .explicit_only });
    terminal.scrollLines(-10);
    try terminal.refresh(gpa);
    const held = try gpa.dupe(u8, try readRow(&terminal, 0, &row));
    defer gpa.free(held);
    terminal.userInput();
    terminal.feed(more);
    try terminal.refresh(gpa);
    try testing.expect(!terminal.viewport().atBottom());
    try testing.expectEqualStrings(held, try readRow(&terminal, 0, &row));
}

test "the alternate screen is the program's: a wheel becomes cursor keys or a mouse report" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 20, .rows = 5 });
    defer terminal.deinit(gpa);

    const printed = try numberedLines(gpa, 40);
    defer gpa.free(printed);
    terminal.feed(printed);
    try terminal.refresh(gpa);
    try testing.expect(!terminal.isAlternateScreen());

    var out: EncodedKey = .{};
    // On the primary screen a wheel is Conduit's, and moves the viewport.
    const scrolled = terminal.scrollByWheel(.{ .dy = 1 }, .{}, &out);
    try testing.expectEqual(@as(usize, 0), out.len);
    switch (scrolled) {
        .viewport => |rows| try testing.expectEqual(@as(isize, -3), rows),
        .forwarded => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 3), terminal.viewport().offset);

    // DECSET 1049 is what a full-screen program sends to take the terminal
    // over. The wheel stops being Conduit's from that moment.
    terminal.feed("\x1b[?1049h");
    try terminal.refresh(gpa);
    try testing.expect(terminal.isAlternateScreen());
    try testing.expectEqual(MouseTracking.none, terminal.mouseTracking());

    // No mouse tracking: cursor keys, which is what less, nano and vi read and
    // what every real terminal sends. One notch is three presses.
    const arrows = terminal.scrollByWheel(.{ .dy = 1 }, .{}, &out);
    try testing.expectEqualStrings("\x1b[A\x1b[A\x1b[A", out.slice());
    switch (arrows) {
        .forwarded => |sent| {
            try testing.expectEqual(ScrollOutcome.Reason.arrow_keys, sent.reason);
            try testing.expectEqual(@as(usize, 9), sent.bytes);
        },
        .viewport => return error.TestUnexpectedResult,
    }
    // The view did not move: the alternate screen keeps no history at all, so
    // there is nothing above it to scroll and a viewport move would hide a
    // screen the program drew.
    try testing.expect(terminal.viewport().atBottom());
    try testing.expectEqual(@as(usize, 0), terminal.viewport().history_rows);

    // A wheel pointing down sends downs, not ups.
    _ = terminal.scrollByWheel(.{ .dy = -2 }, .{}, &out);
    try testing.expectEqualStrings("\x1b[B\x1b[B\x1b[B\x1b[B\x1b[B\x1b[B", out.slice());

    // Cursor keys are encoded through the terminal's own encoder, so a program
    // in application cursor key mode gets SS3 rather than CSI.
    terminal.feed("\x1b[?1h\x1b=");
    _ = terminal.scrollByWheel(.{ .dy = 1 }, .{}, &out);
    try testing.expectEqualStrings("\x1bOA\x1bOA\x1bOA", out.slice());
    terminal.feed("\x1b[?1l\x1b>");

    // With mouse tracking on, the wheel is a mouse report instead — button 64
    // for up, in the format the program asked for (SGR here).
    terminal.feed("\x1b[?1000h\x1b[?1006h");
    try terminal.refresh(gpa);
    try testing.expectEqual(MouseTracking.press, terminal.mouseTracking());
    const report = terminal.scrollByWheel(
        .{ .dy = 1 },
        .{
            .x = 24,
            .y = 32,
            .surface_width_px = 400,
            .surface_height_px = 200,
            .cell_width_px = 8,
            .cell_height_px = 16,
        },
        &out,
    );
    try testing.expectEqualStrings("\x1b[<64;4;3M", out.slice());
    switch (report) {
        .forwarded => |sent| {
            try testing.expectEqual(ScrollOutcome.Reason.mouse_report, sent.reason);
            try testing.expectEqual(out.len, sent.bytes);
        },
        .viewport => return error.TestUnexpectedResult,
    }
    _ = terminal.scrollByWheel(.{ .dy = -1 }, .{ .cell_width_px = 8, .cell_height_px = 16 }, &out);
    try testing.expectEqualStrings("\x1b[<65;1;1M", out.slice());

    // Mode 9 reports the first three buttons and no wheel, so a program in it
    // has said it does not want these: they go as cursor keys instead.
    terminal.feed("\x1b[?1000l\x1b[?9h");
    try terminal.refresh(gpa);
    try testing.expectEqual(MouseTracking.x10, terminal.mouseTracking());
    try testing.expect(!MouseTracking.x10.reportsWheel());
    const x10 = terminal.scrollByWheel(.{ .dy = 1 }, .{}, &out);
    switch (x10) {
        .forwarded => |sent| try testing.expectEqual(ScrollOutcome.Reason.arrow_keys, sent.reason),
        .viewport => return error.TestUnexpectedResult,
    }
    try testing.expectEqualStrings("\x1b[A\x1b[A\x1b[A", out.slice());

    // And the primary screen's scrollback is exactly where it was left: taking
    // the terminal over and giving it back does not disturb what the user had
    // scrolled to.
    terminal.feed("\x1b[?1049l");
    try terminal.refresh(gpa);
    try testing.expect(!terminal.isAlternateScreen());
    try testing.expectEqual(@as(usize, 3), terminal.viewport().offset);
}

// --- a real child, scrolling -----------------------------------------------

/// What a wait is looking for: the grid has grown past `rows`, so there is
/// history above the active area to scroll into.
const HistoryGrew = struct {
    /// The terminal being watched.
    terminal: *const Terminal,
    /// The grid's row count, which is also the view's height.
    rows: u16,

    fn holds(self: HistoryGrew) bool {
        return self.terminal.viewport().history_rows > self.rows;
    }
};

/// Feed a child's output in until it has produced more rows of history than
/// the grid is tall, or the budget runs out.
///
/// A condition with a deadline, like every other wait here: the shell decides
/// when it has printed enough, and the test only decides when to stop asking.
fn waitForHistory(gpa: Allocator, child: pty.Pty, terminal: *Terminal, rows: u16) !void {
    try waitFor(gpa, child, terminal, HistoryGrew{ .terminal = terminal, .rows = rows }, HistoryGrew.holds);
}

/// What a wait is looking for: the program has printed more, which the history
/// says even when the view is scrolled somewhere it cannot be seen.
///
/// Reading a row would not do: while the view is scrolled back, the rows the
/// output landed on are not the rows on the screen. This is the honest signal
/// for "the child's output was parsed", which is what the test is waiting on.
const MoreOutput = struct {
    /// The terminal being watched.
    terminal: *const Terminal,
    /// How many rows of history there were before the program was asked again.
    before: usize,

    fn holds(self: MoreOutput) bool {
        return self.terminal.viewport().history_rows > self.before;
    }
};

test "a real shell's output is scrolled back through with a wheel, and the rows are real history" {
    if (!has_pty_backend) return error.SkipZigTest;
    const testing = std.testing;
    const gpa = testing.allocator;

    // A real shell printing numbered lines, with no shell to echo the command
    // back: every byte the grid shows afterwards came out of `seq`.
    const child = try pty.spawn(gpa, request(
        &.{ "/bin/sh", "-c", "seq 1 400" },
    ));
    defer child.destroy();

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 20, .rows = 5 });
    defer terminal.deinit(gpa);

    // Six notches scroll eighteen rows, so the history must hold at least that
    // many before the wheel is turned. A slow runner can deliver `seq`'s first
    // read with only a handful of lines, and waiting for "some history" let the
    // offset clamp at whatever had arrived (seen on a hosted runner: 17).
    try waitForHistory(gpa, child, &terminal, 18);
    const history = terminal.viewport().history_rows;
    try testing.expect(history > 18);

    // The wheel event goes through exactly the call `App.onWheel` makes, with
    // the delta a real notched device would report.
    var out: EncodedKey = .{};
    const outcome = terminal.scrollByWheel(.{ .dy = 6 }, .{}, &out);
    switch (outcome) {
        .viewport => |rows| try testing.expectEqual(@as(isize, -18), rows),
        .forwarded => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 0), out.len);
    try terminal.refresh(gpa);

    try testing.expectEqual(@as(usize, 18), terminal.viewport().offset);

    // The top of the view is real history, and which history is arithmetic
    // rather than a guess: `seq` printed one line per row, so the first row of
    // the active area is the first line after the history.
    var row: [64]u8 = undefined;
    const first_visible = history + 1;
    const wanted = try std.fmt.allocPrint(gpa, "{d}", .{first_visible - 18});
    defer gpa.free(wanted);
    try testing.expectEqualStrings(wanted, try readRow(&terminal, 0, &row));

    // And the rows below it are the rows after it, not blank cells where the
    // history should be: five consecutive numbers ending in five.
    for (1..5) |y| {
        const next = try std.fmt.allocPrint(gpa, "{d}", .{first_visible - 18 + y});
        defer gpa.free(next);
        try testing.expectEqualStrings(next, try readRow(&terminal, @intCast(y), &row));
    }

    // Scrolling back the other way returns to the bottom, and the cursor's row
    // is on screen again because the view is showing the active area.
    terminal.scrollToBottom();
    try terminal.refresh(gpa);
    try testing.expect(terminal.viewport().atBottom());
    try testing.expect(terminal.cursor().position != null);
}

test "output arriving while scrolled back does not move the view, and typing brings it back" {
    if (!has_pty_backend) return error.SkipZigTest;
    const testing = std.testing;
    const gpa = testing.allocator;

    // The shell prints two hundred lines and then keeps reading, so the test can
    // make it print more on demand: the output that arrives while the view is
    // scrolled back is a real program's, produced by a real command.
    const child = try pty.spawn(gpa, request(
        &.{ "/bin/sh", "-c", "stty -echo; seq 1 200; while read line; do printf 'late:%s\\n' \"$line\"; done" },
    ));
    defer child.destroy();

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 30, .rows = 6 });
    defer terminal.deinit(gpa);

    try waitForHistory(gpa, child, &terminal, 6);

    // Scroll back to the top of what the first run printed, and remember what
    // is on screen.
    terminal.scrollToTop();
    try terminal.refresh(gpa);
    try testing.expect(!terminal.viewport().atBottom());
    var row: [64]u8 = undefined;
    const held = try gpa.dupe(u8, try readRow(&terminal, 0, &row));
    defer gpa.free(held);

    // The program prints, for real, while the user is reading history.
    const before_more = terminal.viewport().history_rows;
    try writeAll(child, "more\n");
    try waitFor(gpa, child, &terminal, MoreOutput{ .terminal = &terminal, .before = before_more }, MoreOutput.holds);
    try terminal.refresh(gpa);

    // The view did not move: the same line is still at the top of it, and the
    // bottom moved down instead.
    try testing.expect(!terminal.viewport().atBottom());
    try testing.expectEqualStrings(held, try readRow(&terminal, 0, &row));
    try testing.expect(terminal.viewport().offset > 6);

    // Typing is what the input path calls when a key goes to the child, and it
    // is the signal that the user is at the prompt now. The bytes really do
    // reach the child, which is the seam the same test would use for a key.
    var encoded: EncodedKey = .{};
    _ = try sendKey(&terminal, child, .{
        .text = "x",
        .unshifted_codepoint = 'x',
    }, &encoded);
    try testing.expectEqualStrings("x", encoded.slice());

    terminal.userInput();
    try terminal.refresh(gpa);
    try testing.expect(terminal.viewport().atBottom());
}

/// What a wait is looking for: the program's screen has changed, which is how a
/// test knows the bytes it wrote were read and acted on rather than queued.
const ScreenChanged = struct {
    /// The terminal being watched.
    terminal: *const Terminal,
    /// The screen as it was before the bytes went out.
    before: []const u8,

    fn holds(self: ScreenChanged) bool {
        var scratch: [64]u8 = undefined;
        const now = readRow(self.terminal, 0, &scratch) catch return false;
        return !std.mem.eql(u8, now, self.before);
    }
};

test "a real full-screen program gets the wheel as cursor keys, and the view does not scroll" {
    if (!has_pty_backend) return error.SkipZigTest;
    const testing = std.testing;
    const gpa = testing.allocator;
    const pid = currentProcessId() orelse return error.SkipZigTest;

    // `less` needs a seekable file to have anything to scroll, so the check
    // makes one: numbered lines, under a name this test owns, removed on the
    // way out whether or not the test gets to the end.
    const lines = try numberedLines(gpa, 400);
    defer gpa.free(lines);
    var tmp = try std.Io.Dir.openDirAbsolute(testing.io, "/tmp", .{});
    defer tmp.close(testing.io);
    const name = try std.fmt.allocPrint(gpa, "conduit-term-less-{d}.txt", .{pid});
    defer gpa.free(name);
    tmp.deleteFile(testing.io, name) catch {};
    defer tmp.deleteFile(testing.io, name) catch {};
    try tmp.writeFile(testing.io, .{ .sub_path = name, .data = lines });
    // The child's working directory is `/`, so the path it is given has to be
    // absolute: a relative name would be a `less` that exits with a message
    // rather than a pager that started.
    const path = try std.fmt.allocPrint(gpa, "/tmp/{s}", .{name});
    defer gpa.free(path);

    // 1. `less` with no mouse support: the wheel arrives as cursor keys, which
    //    is what less is written to read.
    const plain = [_][]const u8{ "less", path };
    const pager = try pty.spawn(gpa, requestIn(&plain, &test_env));
    defer pager.destroy();

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 20, .rows = 5 });
    defer terminal.deinit(gpa);

    const AltScreen = struct {
        terminal: *const Terminal,
        // The mode switch and the first drawn line can arrive in separate
        // reads, so an alternate screen alone does not mean the program has
        // drawn yet: the first row must hold text too.
        fn holds(self: @This()) bool {
            if (!self.terminal.isAlternateScreen()) return false;
            var scratch: [64]u8 = undefined;
            const first = readRow(self.terminal, 0, &scratch) catch return false;
            return std.mem.trim(u8, first, " ").len != 0;
        }
    };
    try waitFor(gpa, pager, &terminal, AltScreen{ .terminal = &terminal }, AltScreen.holds);
    try terminal.refresh(gpa);

    // The alternate screen is the program's own: it keeps no history, so there
    // is nothing for Conduit to scroll and scrolling would hide its screen.
    try testing.expectEqual(@as(usize, 0), terminal.viewport().history_rows);
    try testing.expect(terminal.viewport().atBottom());

    var row: [64]u8 = undefined;
    const first_screen = try gpa.dupe(u8, try readRow(&terminal, 0, &row));
    defer gpa.free(first_screen);
    try testing.expect(first_screen.len > 0);

    // Forward, because `less` is showing the top of the file and there is
    // nothing above it: a wheel pointing back would be correctly answered with
    // nine up arrows that a pager at the top of its file rightly ignores.
    var out: EncodedKey = .{};
    const keys = terminal.scrollByWheel(.{ .dy = -3 }, .{}, &out);
    switch (keys) {
        .forwarded => |sent| {
            try testing.expectEqual(ScrollOutcome.Reason.arrow_keys, sent.reason);
            try testing.expectEqual(out.len, sent.bytes);
        },
        .viewport => return error.TestUnexpectedResult,
    }
    // Three notches is nine rows, and nine rows is nine presses of the down
    // arrow: the exact bytes the program will see.
    try testing.expectEqual(@as(usize, 27), out.len);
    // SS3, not CSI: `less` enabled application cursor keys (DECCKM) when it
    // took the terminal over, and the encoder read that mode out of the
    // terminal's own state rather than from a table. A wheel that sent `ESC [ A`
    // regardless would scroll `less` in some other terminal and do nothing here.
    var want: [9 * 3]u8 = undefined;
    for (0..9) |i| @memcpy(want[i * 3 ..][0..3], "\x1bOB");
    try testing.expectEqualSlices(u8, &want, out.slice());
    try writeAll(pager, out.slice());
    try waitFor(gpa, pager, &terminal, ScreenChanged{ .terminal = &terminal, .before = first_screen }, ScreenChanged.holds);
    try terminal.refresh(gpa);

    // The program acted on them: its first line is a different numbered line
    // from the same file, ten lines further on.
    const after_keys = try readRow(&terminal, 0, &row);
    try testing.expect(!std.mem.eql(u8, after_keys, first_screen));
    // `less` pads and marks lines its own way, so the claim is that the row is
    // still a numbered line from the same file and not a blank or a prompt.
    // The file is numbered, so the row the pager shows says which part of it is
    // on screen: after the wheel it is further down the same file.
    const prefix = "line-".len;
    if (first_screen.len > prefix and after_keys.len > prefix) {
        const was = std.fmt.parseInt(usize, first_screen[prefix..], 10) catch 0;
        const now = std.fmt.parseInt(usize, after_keys[prefix..], 10) catch 0;
        if (was != 0 and now != 0) try testing.expect(now > was);
    }
    // The view never moved: the alternate screen has no rows above it.
    try testing.expect(terminal.viewport().atBottom());

    // The mouse-report branch is not exercised here: `less -M` does not turn
    // mouse reporting on over this pty on this machine, so a test that claimed
    // it would be claiming something it did not observe. The encoding it
    // produces is pinned by exact bytes in the unit test above, which drives the
    // same `scrollByWheel` call with the modes a program sets.

}

// ---------------------------------------------------------------------------
// The mouse layer: the bytes a program receives, and who owns the pointer
// ---------------------------------------------------------------------------

/// What `vim` sends when `set mouse=a` has taken effect, verbatim.
///
/// Captured off the program over a pty on this machine, not written from the
/// protocol document: the order is the order `vim` sends it in, and a test that
/// fed a tidied-up version would be testing a fiction. `?1006;1000h` is one
/// sequence carrying two modes, which is the first thing worth proving about a
/// real program's enable.
const vim_mouse_on = "\x1b[?1006;1000h\x1b[?1002h";

/// What `htop` sends. It asks for presses and the wheel and says nothing about
/// motion, so it is the one real program here that would not hear about a drag.
const htop_mouse_on = "\x1b[?1006;1000h";

/// What `tmux` sends, in its own order and with `?1003l` because it turns any-
/// event tracking back off after using it to read the status bar.
const tmux_mouse_on = "\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[?1003l";

/// The cell geometry the mouse tests use: 10x20 pixels in an 80x24 grid, so a
/// column is a pixel position no rounding can be argued about.
const mouse_test_cell: struct { w: u32 = 10, h: u32 = 20 } = .{};

/// A pointer over the middle of the cell at `col`, `row`.
///
/// The middle rather than the corner because a corner is the one position where
/// a rounding decision could change which cell is meant, and a mouse report that
/// names the cell to its left is a bug this would hide.
fn atCell(col: u16, row: u16) Pointer {
    return .{
        .x = @floatFromInt(col * mouse_test_cell.w + mouse_test_cell.w / 2),
        .y = @floatFromInt(row * mouse_test_cell.h + mouse_test_cell.h / 2),
        .surface_width_px = 80 * mouse_test_cell.w,
        .surface_height_px = 24 * mouse_test_cell.h,
        .cell_width_px = mouse_test_cell.w,
        .cell_height_px = mouse_test_cell.h,
    };
}

/// A pointer event of the kind a hand makes, at a cell.
fn pressAt(col: u16, row: u16) PointerEvent {
    return .{ .action = .press, .button = .left, .pointer = atCell(col, row) };
}

test "a program that turned the mouse on receives the exact report bytes" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(testing.allocator);

    var out: EncodedKey = .{};

    // Nothing on screen yet, so nothing is reported and nothing is selected:
    // the ownership decision has to read the program's modes, not the grid.
    try testing.expectEqual(PointerOwner.user, terminal.pointerOwner(.{}));
    try testing.expectEqual(
        PointerOutcome.ignored,
        terminal.pointerEvent(pressAt(10, 4), null, &out),
    );
    try testing.expectEqual(@as(usize, 0), out.len);

    // `vim`'s own enable. It says 1002 and 1006, and both have to land: a
    // terminal that answered 1000 for it would stop reporting drags, which is
    // how a click-and-drag in vim silently becomes a click.
    terminal.feed(vim_mouse_on);
    try testing.expectEqual(MouseTracking.drag, terminal.mouseTracking());
    try testing.expectEqual(MouseFormat.sgr, terminal.mouseFormat());
    try testing.expectEqual(PointerOwner.program, terminal.pointerOwner(.{}));

    // A left press at column 10, row 4. SGR is one-based, so the bytes name
    // column 11 and row 5: these are the nine bytes vim reads, and they are
    // asserted rather than described.
    try testing.expectEqual(
        PointerOutcome{ .reported = 10 },
        terminal.pointerEvent(pressAt(10, 4), null, &out),
    );
    try testing.expectEqualStrings("\x1b[<0;11;5M", out.slice());

    // The release ends in `m`, not `M`. This is the whole reason the format
    // exists: under X10 every release is button 3, so a program in 1000 mode
    // cannot tell the end of a left drag from a right click.
    try testing.expectEqual(
        PointerOutcome{ .reported = 10 },
        terminal.pointerEvent(.{
            .action = .release,
            .button = .left,
            .pointer = atCell(10, 4),
        }, null, &out),
    );
    try testing.expectEqualStrings("\x1b[<0;11;5m", out.slice());

    // The other two buttons, and the modifier bits: shift 4, alt 8, ctrl 16.
    try testing.expectEqual(
        PointerOutcome{ .reported = 10 },
        terminal.pointerEvent(.{
            .action = .press,
            .button = .middle,
            .pointer = atCell(10, 4),
        }, null, &out),
    );
    try testing.expectEqualStrings("\x1b[<1;11;5M", out.slice());

    try testing.expectEqual(
        PointerOutcome{ .reported = 10 },
        terminal.pointerEvent(.{
            .action = .press,
            .button = .right,
            .pointer = atCell(10, 4),
        }, null, &out),
    );
    try testing.expectEqualStrings("\x1b[<2;11;5M", out.slice());

    // Ctrl and Alt, which are 16 and 8. Shift is deliberately absent from this
    // list: a Shift held is what gives the pointer to the user, so no report
    // Conduit sends can ever carry the shift bit — the one modifier a mouse
    // report has that Conduit will not put in one.
    try testing.expectEqual(
        PointerOutcome{ .reported = 11 },
        terminal.pointerEvent(.{
            .action = .press,
            .button = .left,
            .mods = .{ .alt = true, .ctrl = true },
            .pointer = atCell(10, 4),
        }, null, &out),
    );
    try testing.expectEqualStrings("\x1b[<24;11;5M", out.slice());

    // A drag. 32 is the motion bit and the button is still the left one, so
    // this is how a program tells a drag from a press that has not moved.
    try testing.expectEqual(
        PointerOutcome{ .reported = 11 },
        terminal.pointerEvent(.{
            .action = .motion,
            .button = .left,
            .any_button_pressed = true,
            .pointer = atCell(12, 4),
        }, null, &out),
    );
    try testing.expectEqualStrings("\x1b[<32;13;5M", out.slice());

    // And the same cell again is not reported twice: a mouse resting on one
    // character must not send a program hundreds of identical reports a second.
    try testing.expectEqual(
        PointerOutcome{ .reported = 0 },
        terminal.pointerEvent(.{
            .action = .motion,
            .button = .left,
            .any_button_pressed = true,
            .pointer = atCell(12, 4),
        }, null, &out),
    );
    try testing.expectEqual(@as(usize, 0), out.len);

    // `htop` asks for presses and the wheel only. A drag is not one of the
    // events it said it wanted, so it gets nothing rather than a report it has
    // no handler for.
    var plain: Terminal = undefined;
    try plain.init(testIo(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer plain.deinit(testing.allocator);
    plain.feed(htop_mouse_on);
    try testing.expectEqual(MouseTracking.press, plain.mouseTracking());
    try testing.expectEqual(
        PointerOutcome{ .reported = 9 },
        plain.pointerEvent(pressAt(3, 6), null, &out),
    );
    try testing.expectEqualStrings("\x1b[<0;4;7M", out.slice());
    // Zero bytes, and the outcome says the event belonged to the program: a
    // program in press mode has said it does not want motion, so the drag
    // produces no report at all rather than one it has no handler for.
    try testing.expectEqual(
        PointerOutcome{ .reported = 0 },
        plain.pointerEvent(.{
            .action = .motion,
            .button = .left,
            .any_button_pressed = true,
            .pointer = atCell(5, 6),
        }, null, &out),
    );
    try testing.expectEqual(@as(usize, 0), out.len);

    // `tmux` sets 1002 and turns 1003 back off, so it hears about a drag but
    // not about a pointer moving with nothing held — which is exactly what a
    // status bar wants and what would be a firehose for anything else.
    var mux: Terminal = undefined;
    try mux.init(testIo(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer mux.deinit(testing.allocator);
    mux.feed(tmux_mouse_on);
    try testing.expectEqual(MouseTracking.drag, mux.mouseTracking());
    try testing.expectEqual(
        PointerOutcome{ .reported = 11 },
        mux.pointerEvent(.{
            .action = .motion,
            .button = .left,
            .any_button_pressed = true,
            .pointer = atCell(8, 23),
        }, null, &out),
    );
    try testing.expectEqualStrings("\x1b[<32;9;24M", out.slice());
    // A pointer moving with nothing held is not an event in 1002 mode, so it
    // produces no bytes — this is the mode tmux runs in behind its status bar.
    try testing.expectEqual(
        PointerOutcome{ .reported = 0 },
        mux.pointerEvent(.{ .action = .motion, .pointer = atCell(8, 23) }, null, &out),
    );
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "the report is SGR unless the program named a format of its own" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(testing.allocator);

    var out: EncodedKey = .{};
    const ask: []const struct { mode: []const u8, format: MouseFormat, bytes: []const u8 } = &.{
        // An event mode and no format mode at all: `vim` on a terminal that has
        // never heard of 1006, `less -M`, anything written before 1006 existed.
        // This is the case the preference exists for, and it is also the case
        // that would be lost if Conduit read "the program did not ask for SGR"
        // as "the program asked for X10".
        .{ .mode = "\x1b[?1000h", .format = .sgr, .bytes = "\x1b[<0;11;5M" },
        // X10 alone (DECSET 9): presses of the first three buttons, no wheel.
        // SGR is still the answer, and that is what makes a click in the
        // right-hand fifth of a wide window work at all — see below.
        .{ .mode = "\x1b[?9h", .format = .sgr, .bytes = "\x1b[<0;11;5M" },
        // Each format a program can ask for, asked for. The UTF-8 answer is
        // `ESC [ M`, a space for button 0, and the two coordinates biased by
        // 33 — which is why it cannot address a column past 223 and is the one
        // almost nothing uses.
        .{ .mode = "\x1b[?1000h\x1b[?1005h", .format = .utf8, .bytes = "\x1b[M +%" },
        .{ .mode = "\x1b[?1000h\x1b[?1006h", .format = .sgr, .bytes = "\x1b[<0;11;5M" },
        .{ .mode = "\x1b[?1000h\x1b[?1015h", .format = .urxvt, .bytes = "\x1b[32;11;5M" },
        // SGR-pixels (1016) is the one format with no column limit at all: it
        // names a pixel, so the numbers are the pixel position itself.
        .{ .mode = "\x1b[?1000h\x1b[?1016h", .format = .sgr_pixels, .bytes = "\x1b[<0;105;90M" },
    };

    for (ask) |case| {
        terminal.feed("\x1b[?1000l\x1b[?9l\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?1016l");
        terminal.feed(case.mode);
        try testing.expectEqual(case.format, terminal.mouseFormat());
        _ = terminal.pointerEvent(pressAt(10, 4), null, &out);
        try testing.expectEqualStrings(case.bytes, out.slice());
    }

    // The point of the preference, measured: a program in X10 mode on a window
    // wider than 222 columns would have its clicks dropped by the X10 encoding
    // (the coordinate is a byte biased by 32). SGR has no such limit, so the
    // click that X10 loses arrives.
    var wide: Terminal = undefined;
    try wide.init(testIo(), testing.allocator, .{ .cols = 300, .rows = 24 });
    defer wide.deinit(testing.allocator);
    wide.feed("\x1b[?9h");
    const far = Pointer{
        .x = @floatFromInt(280 * mouse_test_cell.w + 5),
        .y = @floatFromInt(4 * mouse_test_cell.h + 10),
        .surface_width_px = 300 * mouse_test_cell.w,
        .surface_height_px = 24 * mouse_test_cell.h,
        .cell_width_px = mouse_test_cell.w,
        .cell_height_px = mouse_test_cell.h,
    };
    _ = wide.pointerEvent(.{ .action = .press, .button = .left, .pointer = far }, null, &out);
    try testing.expectEqualStrings("\x1b[<0;281;5M", out.slice());
}

test "shift takes the pointer from the program and gives it back" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(testing.allocator);
    terminal.feed(vim_mouse_on);
    var out: EncodedKey = .{};

    // Twenty-four rows of text, so a selection is a selection *of something*
    // rather than a claim about blank cells.
    terminal.feed("row-0-abcdefghijklmnop\r\nrow-1-abcdefghijklmnop\r\n" ++
        "row-2-abcdefghijklmnop\r\nrow-3-abcdefghijklmnop\r\n");
    try terminal.refresh(testing.allocator);

    // Unshifted, the program owns it: a press is a report and nothing is
    // selected.
    try testing.expectEqual(
        PointerOutcome{ .reported = 9 },
        terminal.pointerEvent(pressAt(4, 2), null, &out),
    );
    try testing.expectEqualStrings("\x1b[<0;5;3M", out.slice());
    try testing.expect(!terminal.hasSelection());

    // Shift held: the user owns it. The press itself selects nothing — a click
    // on its own never selects anything, shifted or not — and the claim that
    // matters is that `out` is empty: the program was not told a press started.
    try testing.expectEqual(PointerOwner.user, terminal.pointerOwner(.{ .shift = true }));
    _ = terminal.pointerEvent(.{
        .action = .press,
        .button = .left,
        .mods = .{ .shift = true },
        .pointer = atCell(4, 2),
    }, null, &out);
    try testing.expectEqual(@as(usize, 0), out.len);

    // The drag, still shifted: the user is selecting real text and the program
    // is still being told nothing.
    try testing.expectEqual(
        PointerOutcome.selection,
        terminal.pointerEvent(.{
            .action = .motion,
            .button = .left,
            .any_button_pressed = true,
            .mods = .{ .shift = true },
            .pointer = atCell(12, 2),
        }, null, &out),
    );
    try testing.expectEqual(@as(usize, 0), out.len);
    try testing.expect(terminal.hasSelection());
    const selected = (try terminal.selectionText(testing.allocator)).?;
    defer testing.allocator.free(selected);
    // Columns 4 to 11 inclusive: the cell the pointer is over is the cell the
    // selection ends *before*, which is what makes a drag read as "up to
    // where I am" rather than "including where I am".
    try testing.expectEqualStrings("2-abcdef", selected);

    // And the release, still shifted. This is the one that would otherwise
    // leave a program that believed a drag was in progress for as long as it
    // ran.
    _ = terminal.pointerEvent(.{
        .action = .release,
        .button = .left,
        .mods = .{ .shift = true },
        .pointer = atCell(12, 2),
    }, null, &out);
    try testing.expectEqual(@as(usize, 0), out.len);

    // Shift released: the program owns the pointer again and the very next
    // event is a report again. The override lasts exactly as long as it is
    // held, and is not a latch.
    try testing.expectEqual(PointerOwner.program, terminal.pointerOwner(.{}));
    try testing.expectEqual(
        PointerOutcome{ .reported = 11 },
        terminal.pointerEvent(.{
            .action = .motion,
            .button = .left,
            .any_button_pressed = true,
            .pointer = atCell(14, 2),
        }, null, &out),
    );
    try testing.expectEqualStrings("\x1b[<32;15;3M", out.slice());

    // Shift alongside the other modifiers is still the user: the ownership
    // test reads the bit, not the whole modifier set.
    try testing.expectEqual(PointerOwner.user, terminal.pointerOwner(.{
        .shift = true,
        .alt = true,
        .ctrl = true,
    }));
    _ = terminal.pointerEvent(.{
        .action = .press,
        .button = .left,
        .mods = .{ .shift = true, .alt = true, .ctrl = true },
        .pointer = atCell(20, 3),
    }, null, &out);
    try testing.expectEqual(@as(usize, 0), out.len);
    try testing.expectEqual(
        PointerOutcome.selection,
        terminal.pointerEvent(.{
            .action = .motion,
            .button = .left,
            .any_button_pressed = true,
            .mods = .{ .shift = true, .alt = true, .ctrl = true },
            .pointer = atCell(24, 3),
        }, null, &out),
    );
    try testing.expectEqual(@as(usize, 0), out.len);

    // With the program gone, the same unshifted drag is the user's. Read from
    // the other end, it is the same rule.
    terminal.feed("\x1b[?1002l\x1b[?1000l\x1b[?9l");
    terminal.clearSelection();
    try testing.expectEqual(PointerOwner.user, terminal.pointerOwner(.{}));
    _ = terminal.pointerEvent(pressAt(30, 3), null, &out);
    try testing.expectEqual(
        PointerOutcome.selection,
        terminal.pointerEvent(.{
            .action = .motion,
            .button = .left,
            .any_button_pressed = true,
            .pointer = atCell(34, 3),
        }, null, &out),
    );
    try testing.expectEqual(@as(usize, 0), out.len);
    try testing.expect(terminal.hasSelection());
}

// ---------------------------------------------------------------------------
// The second and third click
//
// A burst of presses is one gesture: upstream counts the presses by how close
// together they are in time and in space, and answers the second with a word
// and the third with a line. What follows proves what those words and lines
// *are*, read back out of the engine — not that the boundary list holds the
// codepoints it holds, which would only be a restatement of the list.
// ---------------------------------------------------------------------------

/// How far apart the clicks below are stamped, in nanoseconds.
///
/// Synthesised rather than read from a clock, on purpose. The gesture's only
/// question about time is whether two presses were within
/// `double_click_interval_ns` of each other, and a counter answers that
/// exactly. A real clock would make every case here depend on how loaded the
/// machine is, which is a flaky test rather than a strict one.
const click_step_ns: u64 = 10 * std.time.ns_per_ms;

/// Press and release the left button at `col`, `row`, `times` times over, each
/// press `step` nanoseconds after the one before.
///
/// The release matters as much as the press: `selectionRelease` deliberately
/// keeps the click count so the next press can complete a double-click, which
/// is why this is a click and not a sequence of presses.
fn clickAt(terminal: *Terminal, col: u16, row: u16, times: u8, step: u64) void {
    var out: EncodedKey = .{};
    var at: i96 = 0;
    for (0..times) |_| {
        at += @intCast(step);
        _ = terminal.pointerEvent(pressAt(col, row), .{ .nanoseconds = at }, &out);
        _ = terminal.pointerEvent(.{
            .action = .release,
            .button = .left,
            .pointer = atCell(col, row),
        }, .{ .nanoseconds = at }, &out);
    }
}

/// Assert that a double-click at `col`, `row` selects exactly `want`.
///
/// The starting selection is dropped first, so every case is measured from
/// nothing: a case that inherited the previous case's click count would be
/// proving that the clicks compose rather than what a double-click selects.
///
/// A failure names its call site, and the call site is the case.
fn expectDoubleClick(terminal: *Terminal, col: u16, row: u16, want: []const u8) !void {
    const testing = std.testing;
    terminal.clearSelection();
    clickAt(terminal, col, row, 2, click_step_ns);
    const text = (try terminal.selectionText(testing.allocator)) orelse
        return error.DoubleClickSelectedNothing;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(want, text);
}

test "a double-click selects the word under the pointer and nothing past it" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(testing.allocator);
    terminal.feed("alpha bravo charlie\r\ndelta echo foxtrot\r\n");
    try terminal.refresh(testing.allocator);

    // The first word, with two words and a half of a third behind it that must
    // not come with it.
    try expectDoubleClick(&terminal, 1, 0, "alpha");
    // A word in the middle, which is the ordinary case and the one that has to
    // stop on both sides rather than running to the end of the line.
    try expectDoubleClick(&terminal, 8, 0, "bravo");
    // The last word of the line: it runs to the end of what is there and stops
    // there, rather than running on into the blank cells after it.
    try expectDoubleClick(&terminal, 15, 0, "charlie");
    // And the same shape on another row, so nothing here depends on row 0.
    try expectDoubleClick(&terminal, 7, 1, "echo");

    // A single click still selects nothing, after all of that: the word came
    // from the second press, not from the first having been sticky.
    terminal.clearSelection();
    clickAt(&terminal, 1, 0, 1, click_step_ns);
    try testing.expect((try terminal.selectionText(testing.allocator)) == null);
}

test "a word is the run of cells that are not boundaries, and here is what that means" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(testing.allocator);
    //     0         1         2         3         4
    //     0123456789012345678901234567890123456789
    terminal.feed("foo_bar 12ab x9 $HOME a/b c.d e:f g,h\r\n");
    try terminal.refresh(testing.allocator);

    // `_` is not a boundary, so an identifier is one word rather than three.
    try expectDoubleClick(&terminal, 2, 0, "foo_bar");
    // Digits are not boundaries on either side of the letters: a number mixed
    // into a token stays inside it.
    try expectDoubleClick(&terminal, 9, 0, "12ab");
    try expectDoubleClick(&terminal, 14, 0, "x9");
    // A boundary clicked directly selects a boundary, not the word beside it —
    // which is what makes a quoted argument selectable a piece at a time. The
    // run comes back whole, so the space in front of it comes with it: a word
    // is a run of cells that agree about being boundaries, and a space and a
    // `$` agree. Trimming that space is a decision about what to *do* with a
    // selection, and `selectionText` deliberately leaves it to the caller.
    try expectDoubleClick(&terminal, 16, 0, " $");
    // And the word after that boundary is its own word, not "$HOME".
    try expectDoubleClick(&terminal, 17, 0, "HOME");
    // `/` is not a boundary, so a path is one word: a double-click on `a/b`
    // gives `a/b`. This is the case that looks like a missing boundary next to
    // the `$` above, and is not — the user reaching for a path wants the whole
    // of it, and a terminal that split it would make a filename unsplittable.
    try expectDoubleClick(&terminal, 22, 0, "a/b");
    // A dot is not a boundary either, so a filename with an extension is one
    // word for the same reason.
    try expectDoubleClick(&terminal, 27, 0, "c.d");
    // `:` and `,` *are* boundaries, which is where the list earns its keep: a
    // URL scheme and a pipeline are each split off from what they name, and a
    // CSV field is one field rather than the whole row.
    try expectDoubleClick(&terminal, 30, 0, "e");
    try expectDoubleClick(&terminal, 32, 0, "f");
    try expectDoubleClick(&terminal, 34, 0, "g");
    try expectDoubleClick(&terminal, 36, 0, "h");
    // And the boundary between them selects on its own, with no whitespace
    // beside it to bring along.
    try expectDoubleClick(&terminal, 31, 0, ":");
    try expectDoubleClick(&terminal, 35, 0, ",");
}

test "a double-click on a wide character or a combining mark selects the whole grapheme" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(testing.allocator);
    //     0         1         2         3         4
    //     0123456789012345678901234567890123456789
    // 漢字 are two cells each: 0-1 and 2-3. `e`+U+0301 is one cell, at 5.
    terminal.feed("漢字 éx ok\r\n");
    try terminal.refresh(testing.allocator);

    // Two ideographs with nothing between them are one word: there are no
    // spaces to find, and a width rule would break any sentence without
    // punctuation in it.
    try expectDoubleClick(&terminal, 0, 0, "漢字");
    // The other half of the first wide glyph. A selection can only ever be text
    // that was on the screen, so a double-click on a spacer resolves to the
    // cell that owns it and selects the same word — never half a glyph.
    try expectDoubleClick(&terminal, 1, 0, "漢字");
    // And the other half of the second, to say that it is not a special case
    // of the first.
    try expectDoubleClick(&terminal, 3, 0, "漢字");
    // The base character and its combining mark travel together, and the `x`
    // after them is not a boundary, so this is one word of two cells.
    try expectDoubleClick(&terminal, 5, 0, "éx");
}

test "a triple-click selects the whole line, trimmed on both ends" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(testing.allocator);
    terminal.feed("   alpha bravo charlie   \r\ndelta echo\r\n");
    try terminal.refresh(testing.allocator);

    terminal.clearSelection();
    clickAt(&terminal, 9, 0, 3, click_step_ns);
    const line = (try terminal.selectionText(testing.allocator)).?;
    defer testing.allocator.free(line);
    // The whole run of the row including its last word, with the leading and
    // trailing spaces left out: a user triple-clicking a prompt wants the
    // command, not the indentation in front of it.
    try testing.expectEqualStrings("alpha bravo charlie", line);

    // And the row below it, which is a different line and not a continuation.
    terminal.clearSelection();
    clickAt(&terminal, 1, 1, 3, click_step_ns);
    const next = (try terminal.selectionText(testing.allocator)).?;
    defer testing.allocator.free(next);
    try testing.expectEqualStrings("delta echo", next);
}

test "what makes a press a repeat: the interval, and one cell of travel" {
    const testing = std.testing;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(testing.allocator);
    terminal.feed("alpha bravo charlie\r\n");
    try terminal.refresh(testing.allocator);
    var out: EncodedKey = .{};

    // Exactly the interval apart is still the same click: the interval is the
    // longest gap that counts, not the shortest, so this pins the comparison
    // rather than just the constant.
    terminal.clearSelection();
    clickAt(&terminal, 1, 0, 2, double_click_interval_ns);
    const same_click = (try terminal.selectionText(testing.allocator)).?;
    defer testing.allocator.free(same_click);
    try testing.expectEqualStrings("alpha", same_click);

    // One nanosecond more is not, and the press that misses starts a new click
    // of its own — which selects nothing and clears what was there.
    terminal.clearSelection();
    clickAt(&terminal, 1, 0, 2, double_click_interval_ns + 1);
    try testing.expect((try terminal.selectionText(testing.allocator)) == null);

    // In space the limit is `max_distance`, one cell width: the middle of one
    // cell to the middle of its neighbour is exactly one cell away and still
    // counts, while two cells is past it. The limit decides whether two
    // presses are *one click*, not which cells the word covers — a word is a
    // word from wherever in it the pointer lands, so the adjacent press still
    // selects all of "alpha".
    terminal.clearSelection();
    _ = terminal.pointerEvent(pressAt(1, 0), .{ .nanoseconds = 0 }, &out);
    _ = terminal.pointerEvent(pressAt(2, 0), .{ .nanoseconds = @intCast(click_step_ns) }, &out);
    const next_cell = (try terminal.selectionText(testing.allocator)).?;
    defer testing.allocator.free(next_cell);
    try testing.expectEqualStrings("alpha", next_cell);

    // Two cells away is past the limit, so the second press is a click of its
    // own: a click on its own selects nothing, and it clears what was there.
    terminal.clearSelection();
    _ = terminal.pointerEvent(pressAt(1, 0), .{ .nanoseconds = 0 }, &out);
    _ = terminal.pointerEvent(pressAt(3, 0), .{ .nanoseconds = @intCast(click_step_ns) }, &out);
    try testing.expect((try terminal.selectionText(testing.allocator)) == null);
}

// ---------------------------------------------------------------------------
// The mouse, against the programs it is for
//
// Everything above proves that the bytes are right. These prove that the bytes
// are what `vim`, `htop` and `tmux` read: each program is started on a real pty
// with its own mouse mode turned on the way a user turns it on, each report is
// produced by the same `pointerEvent` the app calls, and the claim is about
// something the program *did* — a cursor that moved, a selection bar that moved,
// a window that came to the front.
// ---------------------------------------------------------------------------

/// The cursor the running program has put somewhere.
const CursorAt = struct {
    terminal: *const Terminal,
    col: u16,
    row: u16,

    fn holds(self: @This()) bool {
        const position = self.terminal.cursor().position orelse return false;
        return position.col == self.col and position.row == self.row;
    }
};

/// That the running program has asked for mouse events in the way it was
/// waited for. Read out of the modes rather than out of anything this file set,
/// so it can only be satisfied by the program's own bytes.
const MouseModeOn = struct {
    terminal: *const Terminal,
    tracking: MouseTracking,

    fn holds(self: @This()) bool {
        return self.terminal.mouseTracking() == self.tracking;
    }
};

/// Encode one pointer event into `out` and hand it to the child, which is the
/// whole of what a session does with a mouse report. Returns how many bytes
/// the child was given, so a caller can assert them rather than trust them.
fn sendPointer(terminal: *Terminal, child: pty.Pty, out: *EncodedKey, event: PointerEvent) !usize {
    // Every call site below expects a report, so anything else is a test that
    // has stopped proving what it says it proves.
    switch (terminal.pointerEvent(event, null, out)) {
        .reported => |sent| try std.testing.expectEqual(out.len, sent),
        else => return error.TestUnexpectedResult,
    }
    try writeAll(child, out.slice());
    return out.len;
}

/// `vim` with the mouse on the way a user turns it on, and with `ruler` so
/// that the position it moved its cursor to is drawn rather than only held.
///
/// `set mouse=a` is the whole of the mouse enable: vim sends `?1006;1000h` and
/// `?1002h` itself, and the test waits for those bytes to arrive rather than
/// setting the modes by hand.
const mouse_editor_argv = [_][]const u8{
    "vim",
    "-u",
    "NONE",
    "-i",
    "NONE",
    "-N",
    "-c",
    "set noswapfile",
    "-c",
    "set mouse=a",
    "-c",
    "set ruler",
};

test "vim moves its cursor to the cell a mouse report named" {
    if (!has_pty_backend) return error.SkipZigTest;
    const testing = std.testing;
    const gpa = testing.allocator;

    const pid = currentProcessId() orelse return error.SkipZigTest;

    // Four known lines, so the cell the click names is a cell with text in it
    // and the selection below has something to select. The name carries this
    // process's id so two test binaries cannot share the file.
    var tmp = try std.Io.Dir.openDirAbsolute(testing.io, "/tmp", .{});
    defer tmp.close(testing.io);
    const name = try std.fmt.allocPrint(gpa, "conduit-mouse-vim-{d}.txt", .{pid});
    defer gpa.free(name);
    tmp.deleteFile(testing.io, name) catch {};
    defer tmp.deleteFile(testing.io, name) catch {};
    try tmp.writeFile(testing.io, .{
        .sub_path = name,
        .data = "conduit-row-0\nconduit-row-1\nconduit-row-2\nconduit-row-3\n",
    });
    // The child's working directory is `/`, so the path it is given has to be
    // absolute: a relative name would be a vim that opened no file at all.
    const path = try std.fmt.allocPrint(gpa, "/tmp/{s}", .{name});
    defer gpa.free(path);

    var argv: [mouse_editor_argv.len + 1][]const u8 = undefined;
    @memcpy(argv[0..mouse_editor_argv.len], &mouse_editor_argv);
    argv[mouse_editor_argv.len] = path;

    const editor = try pty.spawn(gpa, request(&argv));
    defer editor.destroy();

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(gpa);

    // vim turned its own mouse mode on, and the modes say so. Until this is
    // true nothing below could be a report, so it is waited for first.
    try waitFor(gpa, editor, &terminal, MouseModeOn{
        .terminal = &terminal,
        .tracking = .drag,
    }, MouseModeOn.holds);
    try testing.expectEqual(MouseFormat.sgr, terminal.mouseFormat());
    var out: EncodedKey = .{};

    // A click at column 4, row 1. The bytes are the ones vim reads; asserted
    // here so that a change in them fails here rather than silently turning
    // this into a test about something else.
    _ = try sendPointer(&terminal, editor, &out, .{
        .action = .press,
        .button = .left,
        .pointer = atCell(4, 1),
    });
    try testing.expectEqualStrings("\x1b[<0;5;2M", out.slice());
    _ = try sendPointer(&terminal, editor, &out, .{
        .action = .release,
        .button = .left,
        .pointer = atCell(4, 1),
    });
    try testing.expectEqualStrings("\x1b[<0;5;2m", out.slice());

    // And the program acted: its cursor is on the character it was clicked on.
    // `?1006;1000h` on its own would have proved nothing; this is the report
    // reaching a cursor inside another program.
    try waitFor(gpa, editor, &terminal, CursorAt{
        .terminal = &terminal,
        .col = 4,
        .row = 1,
    }, CursorAt.holds);
    var row: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, try readRow(&terminal, 23, &row), "2,5") != null);

    // Shift: the user's press, the program's nothing. `out` is empty, which is
    // the claim — vim cannot have been told anything, because nothing was
    // written to it. What the user gets is the drag that follows.
    _ = terminal.pointerEvent(.{
        .action = .press,
        .button = .left,
        .mods = .{ .shift = true },
        .pointer = atCell(2, 0),
    }, null, &out);
    try testing.expectEqual(@as(usize, 0), out.len);
    try testing.expectEqual(
        PointerOutcome.selection,
        terminal.pointerEvent(.{
            .action = .motion,
            .button = .left,
            .any_button_pressed = true,
            .mods = .{ .shift = true },
            .pointer = atCell(14, 0),
        }, null, &out),
    );
    try testing.expectEqual(@as(usize, 0), out.len);
    const selected = (try terminal.selectionText(gpa)).?;
    defer gpa.free(selected);
    try testing.expectEqualStrings("nduit-row-0", selected);
    _ = terminal.pointerEvent(.{
        .action = .release,
        .button = .left,
        .mods = .{ .shift = true },
        .pointer = atCell(14, 0),
    }, null, &out);
    try testing.expectEqual(@as(usize, 0), out.len);

    // And the pointer goes back to vim the moment Shift is released. The click
    // names a cell that exists — the file has four lines of thirteen columns —
    // because vim clamps a click past the end of a line to the end of that
    // line, and a check waiting for a cell vim would never put its cursor on
    // would be waiting for nothing.
    _ = try sendPointer(&terminal, editor, &out, .{
        .action = .press,
        .button = .left,
        .pointer = atCell(10, 2),
    });
    try testing.expectEqualStrings("\x1b[<0;11;3M", out.slice());
    _ = try sendPointer(&terminal, editor, &out, .{
        .action = .release,
        .button = .left,
        .pointer = atCell(10, 2),
    });
    try testing.expectEqualStrings("\x1b[<0;11;3m", out.slice());
    try waitFor(gpa, editor, &terminal, CursorAt{
        .terminal = &terminal,
        .col = 10,
        .row = 2,
    }, CursorAt.holds);
}

/// tmux with the mouse on, in a directory of its own so that its socket and
/// configuration belong to this test and to nothing else.
const tmux_mouse_config =
    \\set -g automatic-rename off
    \\set -g status-right ""
    \\set -g mouse on
    \\
;

test "tmux switches window on a click in its status bar" {
    if (!has_pty_backend) return error.SkipZigTest;
    const testing = std.testing;
    const gpa = testing.allocator;
    const pid = currentProcessId() orelse return error.SkipZigTest;

    var scratch = try std.Io.Dir.openDirAbsolute(testing.io, "/tmp", .{});
    defer scratch.close(testing.io);
    const name = try std.fmt.allocPrint(gpa, "conduit-mouse-tmux-{d}", .{pid});
    defer gpa.free(name);
    scratch.deleteTree(testing.io, name) catch {};
    defer scratch.deleteTree(testing.io, name) catch {};
    var home = try scratch.createDirPathOpen(testing.io, name, .{});
    defer home.close(testing.io);
    try home.writeFile(testing.io, .{ .sub_path = "tmux.conf", .data = tmux_mouse_config });
    const config = try std.fmt.allocPrint(gpa, "/tmp/{s}/tmux.conf", .{name});
    defer gpa.free(config);
    const socket = try std.fmt.allocPrint(gpa, "/tmp/{s}/tmux.sock", .{name});
    defer gpa.free(socket);

    const server_argv = [_][]const u8{
        "tmux", "-S", socket,    "-f", config,  "new-session",
        "-d",   "-s", "conduit", "-n", "probe", "/bin/sh",
    };
    const server = try pty.spawn(gpa, requestIn(&server_argv, &tmux_env));
    defer server.destroy();
    try testing.expectEqual(pty.ChildState{ .exited = .{ .code = 0 } }, try waitForExit(server));

    const client_argv = [_][]const u8{ "tmux", "-S", socket, "attach-session", "-t", "conduit" };
    const client = try pty.spawn(gpa, requestIn(&client_argv, &tmux_env));
    defer client.destroy();
    defer {
        _ = killTmuxServer(gpa, socket) catch {};
    }

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(gpa);

    // tmux turned the mouse on itself, because its configuration says so, and
    // it did it by setting 1002 and then turning 1003 back off. That is the
    // exact sequence that used to leave the encoder filtering every report away
    // (`mouseEncodeEvent`), so waiting for it here is the regression guard for
    // a defect only a real program could show.
    try waitFor(gpa, client, &terminal, MouseModeOn{
        .terminal = &terminal,
        .tracking = .drag,
    }, MouseModeOn.holds);

    // A second window, made by tmux itself through the socket rather than
    // through the terminal, so the status line has something to switch between.
    // Detached, because a window created in the foreground would come up
    // active and there would be nothing for the click to switch to.
    const add = [_][]const u8{ "tmux", "-S", socket, "new-window", "-d", "-n", "second", "/bin/sh" };
    const adder = try pty.spawn(gpa, requestIn(&add, &tmux_env));
    defer adder.destroy();
    try testing.expectEqual(pty.ChildState{ .exited = .{ .code = 0 } }, try waitForExit(adder));

    var row: [256]u8 = undefined;
    var waiting = GridHas{ .terminal = &terminal, .row = 23, .needle = "1:second" };
    try waitFor(gpa, client, &terminal, &waiting, GridHas.holds);

    // The status line is one row, and it is the last one. With tmux's default
    // status-left the window list starts at column 11, so column 20 is inside
    // the second window's entry: tmux lays that row out itself, and the star
    // the click has to move is the proof.
    const status = try readRow(&terminal, 23, &row);
    try testing.expect(std.mem.indexOf(u8, status, "[conduit] 0:probe* 1:second") != null);

    var out: EncodedKey = .{};
    _ = try sendPointer(&terminal, client, &out, .{
        .action = .press,
        .button = .left,
        .pointer = atCell(19, 23),
    });
    try testing.expectEqualStrings("\x1b[<0;20;24M", out.slice());
    _ = try sendPointer(&terminal, client, &out, .{
        .action = .release,
        .button = .left,
        .pointer = atCell(19, 23),
    });
    try testing.expectEqualStrings("\x1b[<0;20;24m", out.slice());

    // tmux acted: the star moved to the window that was clicked, which is what
    // `select-window` does and what nothing else on that row does.
    waiting = .{ .terminal = &terminal, .row = 23, .needle = "1:second*" };
    try waitFor(gpa, client, &terminal, &waiting, GridHas.holds);
    try testing.expect(std.mem.indexOf(u8, try readRow(&terminal, 23, &row), "0:probe-") != null);
    try testing.expectEqual(pty.ChildState.running, client.state());
}

// ---------------------------------------------------------------------------
// Selection: characters, words, lines
//
// The gesture machine is Ghostty's and these tests are about the decisions
// around it: what Conduit feeds it, what it answers, and what a selection means
// once output or scrolling has moved under it. Every assertion reads the
// selection back out of the engine with `selectionText`, because a claim about
// what is selected that does not say what the text is is a claim about
// nothing.
// ---------------------------------------------------------------------------

/// One row with a double-width character and a grapheme cluster in it, for the
/// cases where a cell is not one character. Spaces separate the pieces because
/// `-` is deliberately *not* a word boundary in Conduit: a terminal that split
/// on it would break every command-line flag into two words.
const wide_and_combining = "aa \u{4e00} e\u{301} zz";

/// Drag from `from` to `to` the way a hand does, as one gesture.
///
/// The press carries the pointer's pixel position as well as the cell, because
/// the gesture decides whether a cell is inside the selection from where in the
/// cell the pointer was: `atCell` puts it in the middle, which is on the
/// "include" side of the 60% threshold upstream uses.
fn dragOver(terminal: *Terminal, from: Position, to: Position, mods: Mods) bool {
    var out: EncodedKey = .{};
    _ = terminal.pointerEvent(.{
        .action = .press,
        .button = .left,
        .mods = mods,
        .pointer = atCell(from.col, from.row),
    }, null, &out);
    const outcome = terminal.pointerEvent(.{
        .action = .motion,
        .button = .left,
        .any_button_pressed = true,
        .mods = mods,
        .pointer = atCell(to.col, to.row),
    }, null, &out);
    _ = terminal.pointerEvent(.{
        .action = .release,
        .button = .left,
        .mods = mods,
        .pointer = atCell(to.col, to.row),
    }, null, &out);
    return outcome == .selection;
}

test "a drag selects characters, and stops before the cell the pointer is over" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 40, .rows = 6 });
    defer terminal.deinit(gpa);
    terminal.feed("abcdefghij\r\nklmnopqrst\r\n");
    try terminal.refresh(gpa);

    // A drag reads as "up to where I am", not "including where I am": the
    // pointer in the middle of a cell is on the near side of the 60% threshold
    // upstream uses, so the cell it is in ends the selection one before.
    // Columns 2 through 5 are `cdef`.
    try testing.expect(dragOver(&terminal, .{ .col = 2, .row = 0 }, .{ .col = 6, .row = 0 }, .{}));
    const one_row = (try terminal.selectionText(gpa)).?;
    defer gpa.free(one_row);
    try testing.expectEqualStrings("cdef", one_row);

    // Across rows it wraps: the end of the first row and the start of the
    // second are both in, and the text is what a terminal would copy.
    try testing.expect(dragOver(&terminal, .{ .col = 6, .row = 0 }, .{ .col = 3, .row = 1 }, .{}));
    const two_rows = (try terminal.selectionText(gpa)).?;
    defer gpa.free(two_rows);
    try testing.expectEqualStrings("ghij\nklm", two_rows);

    // Backwards is the same selection read the other way round, not the
    // complement of it.
    try testing.expect(dragOver(&terminal, .{ .col = 3, .row = 1 }, .{ .col = 6, .row = 0 }, .{}));
    const backwards = (try terminal.selectionText(gpa)).?;
    defer gpa.free(backwards);
    try testing.expectEqualStrings(two_rows, backwards);
}

test "a double click selects a word, a triple click a line, and a click alone nothing" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 40, .rows = 6 });
    defer terminal.deinit(gpa);
    terminal.feed("alpha bravo charlie\r\ndelta echo foxtrot\r\n");
    try terminal.refresh(gpa);

    // The clock is passed in rather than read, so the click sequence is a fact
    // of the test rather than a race with the machine it runs on. Two presses
    // 100ms apart are a double-click and two presses 600ms apart are two
    // clicks, because the interval is 500ms.
    const base: u64 = 1_000_000_000;
    const press = struct {
        fn at(
            t: *Terminal,
            col: u16,
            row: u16,
            nanos: u64,
        ) void {
            var out: EncodedKey = .{};
            _ = t.pointerEvent(pressAt(col, row), .{ .nanoseconds = nanos }, &out);
            _ = t.pointerEvent(.{
                .action = .release,
                .button = .left,
                .pointer = atCell(col, row),
            }, .{ .nanoseconds = nanos }, &out);
        }
    }.at;

    // One click: nothing is selected. A click on its own clears whatever was
    // selected, which is how a user dismisses a selection.
    try testing.expect(dragOver(&terminal, .{ .col = 0, .row = 0 }, .{ .col = 5, .row = 0 }, .{}));
    try testing.expect(terminal.hasSelection());
    press(&terminal, 0, 0, base);
    try testing.expect(!terminal.hasSelection());

    // Two clicks on a word: the word, not the cell and not the row. Column 8 is
    // inside `bravo`.
    press(&terminal, 8, 0, base);
    press(&terminal, 8, 0, base + 100 * std.time.ns_per_ms);
    try testing.expect(terminal.hasSelection());
    const word = (try terminal.selectionText(gpa)).?;
    defer gpa.free(word);
    try testing.expectEqualStrings("bravo", word);

    // Three: the line, trimmed of the whitespace around it. Ghostty's
    // `selectLine` trims leading and trailing whitespace by default, which is
    // what makes a triple-click on an indented line select the line rather than
    // the indent.
    press(&terminal, 8, 1, base + 200 * std.time.ns_per_ms);
    press(&terminal, 8, 1, base + 300 * std.time.ns_per_ms);
    press(&terminal, 8, 1, base + 400 * std.time.ns_per_ms);
    try testing.expect(terminal.hasSelection());
    const line = (try terminal.selectionText(gpa)).?;
    defer gpa.free(line);
    try testing.expectEqualStrings("delta echo foxtrot", line);

    // Two clicks too late are two single clicks: the selection is cleared
    // rather than a word appearing from presses that were not adjacent.
    press(&terminal, 0, 0, base + 5_000 * std.time.ns_per_ms);
    press(&terminal, 8, 0, base + 5_600 * std.time.ns_per_ms);
    try testing.expect(!terminal.hasSelection());
}

test "a double click on a wide character selects it whole, and never half of it" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 40, .rows = 6 });
    defer terminal.deinit(gpa);
    terminal.feed(wide_and_combining);
    try terminal.refresh(gpa);

    // `aa` is columns 0-1, the CJK character is columns 3 and 4, the grapheme
    // cluster is column 6, and `zz` is columns 8-9. Spaces rather than
    // punctuation separate them because Conduit's word boundaries deliberately
    // do *not* include `-`: a terminal that split on it would break every
    // command-line flag into two words.
    //
    // **The decision: a double click never selects half a character.** A
    // selection is a range of cells, and a wide character is two cells that
    // are one glyph; upstream's `selectWordCodepoint` follows a wide spacer
    // back to the cell that owns it, so clicking either half selects the same
    // word. A grapheme cluster is one cell holding one codepoint plus its
    // combining marks, and there is no codepoint-level selection in a terminal,
    // so it comes out whole too. Neither half is text anything could paste.
    const base: u64 = 1_000_000_000;
    var out: EncodedKey = .{};

    // A double click on the *tail* half of the wide character. Upstream's
    // `selectWordCodepoint` follows a wide spacer back to the cell that owns
    // it, so this is the same word as clicking the head — the character is
    // never half-selected, which is the property that matters: half a CJK
    // character is not text anything can paste.
    for ([_]u16{ 3, 4 }) |col| {
        _ = terminal.pointerEvent(pressAt(col, 0), .{ .nanoseconds = base }, &out);
        _ = terminal.pointerEvent(pressAt(col, 0), .{
            .nanoseconds = base + 100 * std.time.ns_per_ms,
        }, &out);
        try testing.expect(terminal.hasSelection());
        const selected = (try terminal.selectionText(gpa)).?;
        defer gpa.free(selected);
        try testing.expectEqualStrings("\u{4e00}", selected);
        // And the selection covers both cells of the wide glyph, not one.
        try terminal.refresh(gpa);
        try testing.expect(terminal.cell(.{ .col = 3, .row = 0 }).?.selected);
        try testing.expect(terminal.cell(.{ .col = 4, .row = 0 }).?.selected);
        try testing.expect(!terminal.cell(.{ .col = 5, .row = 0 }).?.selected);

        terminal.clearSelection();
        // Far enough in time that the next pair of presses is a new sequence.
        const later: u64 = base + @as(u64, col) * 10 * std.time.ns_per_ms;
        _ = terminal.pointerEvent(pressAt(col, 0), .{ .nanoseconds = later }, &out);
        _ = terminal.pointerEvent(pressAt(col, 0), .{
            .nanoseconds = later + 100 * std.time.ns_per_ms,
        }, &out);
    }

    // The grapheme cluster: `e` plus U+0301 is one cell holding one codepoint
    // plus a combining mark. A word selection is a range of *cells*, so the
    // cluster comes out whole — there is no codepoint-level selection in a
    // terminal, and a half-cluster is not text either.
    _ = terminal.pointerEvent(pressAt(6, 0), .{ .nanoseconds = base + 100 * std.time.ns_per_ms }, &out);
    _ = terminal.pointerEvent(pressAt(6, 0), .{
        .nanoseconds = base + 200 * std.time.ns_per_ms,
    }, &out);
    const cluster = (try terminal.selectionText(gpa)).?;
    defer gpa.free(cluster);
    try testing.expectEqualStrings("e\u{301}", cluster);
}

test "a stream drag wraps at the line end, and a block drag clamps" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 20, .rows = 6 });
    defer terminal.deinit(gpa);
    terminal.feed("0123456789abcdefghij\r\nABCDEFGHIJKLMNOPQRST\r\n");
    try terminal.refresh(gpa);

    // The ambiguous case, decided: **a stream selection wraps and a block one
    // clamps.** A stream selection is text, and text continues past the end of
    // a row into the next one — that is what a soft-wrapped command line is,
    // and a selection that stopped at column 20 would break every wrapped
    // line in the scrollback. A block selection is a rectangle, and a rectangle
    // has no meaning past the column it was dragged to, so upstream clamps it
    // with `leftClamp`/`rightClamp` rather than wrapping. The threshold the two
    // share is the cell, so dragging to the last column of a row selects up to
    // it and no further.
    try testing.expect(dragOver(
        &terminal,
        .{ .col = 15, .row = 0 },
        .{ .col = 3, .row = 1 },
        .{},
    ));
    const stream = (try terminal.selectionText(gpa)).?;
    defer gpa.free(stream);
    // From `fghij` at the end of row 0 through `ABC` on row 1: the row break is
    // inside the selection.
    try testing.expectEqualStrings("fghij\nABC", stream);

    terminal.clearSelection();
    try testing.expect(dragOver(
        &terminal,
        .{ .col = 15, .row = 0 },
        .{ .col = 3, .row = 1 },
        .{ .alt = true },
    ));
    const block = (try terminal.selectionText(gpa)).?;
    defer gpa.free(block);
    // A rectangle takes the same columns from every row it covers and no
    // others, so the row break is not in it at all.
    try testing.expectEqualStrings("3456789abcde\nDEFGHIJKLMNO", block);
}

test "alt turns one drag into a block selection and does not leak into the next" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 20, .rows = 6 });
    defer terminal.deinit(gpa);
    terminal.feed("0123456789\r\nabcdefghij\r\n");
    try terminal.refresh(gpa);

    // Alt+drag is a rectangle.
    try testing.expect(dragOver(
        &terminal,
        .{ .col = 1, .row = 0 },
        .{ .col = 4, .row = 1 },
        .{ .alt = true },
    ));
    const block = (try terminal.selectionText(gpa)).?;
    defer gpa.free(block);
    try testing.expectEqualStrings("123\nbcd", block);
    try terminal.refresh(gpa);
    // The rectangle lights up a rectangle of cells and nothing else: cell 0 of
    // row 0 is outside it even though it is inside the rows it covers.
    try testing.expect(!terminal.cell(.{ .col = 0, .row = 0 }).?.selected);
    try testing.expect(terminal.cell(.{ .col = 1, .row = 0 }).?.selected);
    try testing.expect(terminal.cell(.{ .col = 3, .row = 1 }).?.selected);
    try testing.expect(!terminal.cell(.{ .col = 4, .row = 1 }).?.selected);

    // The modifier decides one gesture and not the next: a plain drag
    // afterwards is a stream selection again. A rectangle that outlived its
    // Alt would make every later drag in the session a block selection.
    try testing.expect(dragOver(
        &terminal,
        .{ .col = 1, .row = 0 },
        .{ .col = 4, .row = 1 },
        .{},
    ));
    const stream = (try terminal.selectionText(gpa)).?;
    defer gpa.free(stream);
    try testing.expectEqualStrings("123456789\nabcd", stream);
}

test "a selection survives scrolling, and comes back when its rows do" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 20, .rows = 5 });
    defer terminal.deinit(gpa);

    // Enough numbered output that the selection can be scrolled off the screen
    // and back on, which is the only way to prove it survived rather than
    // merely not been drawn.
    const printed = try numberedLines(gpa, 200);
    defer gpa.free(printed);
    terminal.feed(printed);
    try terminal.refresh(gpa);

    // Row 1 of the visible screen holds `line-0198` in a five-row grid whose
    // last two rows are empty; what matters is that the selection is made over
    // real text and read back.
    try testing.expect(dragOver(&terminal, .{ .col = 0, .row = 1 }, .{ .col = 8, .row = 1 }, .{}));
    const before = (try terminal.selectionText(gpa)).?;
    defer gpa.free(before);
    try testing.expect(before.len > 0);
    try terminal.refresh(gpa);
    const row_with_selection: u16 = 1;
    try testing.expect(terminal.cell(.{ .col = 0, .row = row_with_selection }).?.selected);
    try testing.expect(!terminal.cell(.{ .col = 9, .row = row_with_selection }).?.selected);

    // Scroll back far enough that the selected row is above the viewport.
    terminal.scrollLines(-40);
    try terminal.refresh(gpa);
    const scrolled = terminal.viewport();
    try testing.expect(scrolled.offset > 0);
    // The text is unchanged: it is a region of the buffer, not of the screen.
    const during = (try terminal.selectionText(gpa)).?;
    defer gpa.free(during);
    try testing.expectEqualStrings(before, during);
    // Nothing of it is visible, so nothing of it is lit: a row that is not on
    // screen cannot be drawn.
    var lit: usize = 0;
    for (0..terminal.gridSize().rows) |row| {
        for (0..20) |col| {
            if (terminal.cell(.{ .col = @intCast(col), .row = @intCast(row) }).?.selected) lit += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), lit);

    // And scrolling back to the bottom brings the highlight with it, over the
    // same text.
    terminal.scrollToBottom();
    try terminal.refresh(gpa);
    try testing.expect(terminal.cell(.{ .col = 0, .row = row_with_selection }).?.selected);
    const after = (try terminal.selectionText(gpa)).?;
    defer gpa.free(after);
    try testing.expectEqualStrings(before, after);
}

test "output does not clear a selection, and pruning it does" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 20, .rows = 5 });
    defer terminal.deinit(gpa);
    terminal.feed("alpha bravo\r\ncharlie delta\r\n");
    try terminal.refresh(gpa);

    try testing.expect(dragOver(&terminal, .{ .col = 0, .row = 0 }, .{ .col = 8, .row = 0 }, .{}));
    const before = (try terminal.selectionText(gpa)).?;
    defer gpa.free(before);
    try testing.expectEqualStrings("alpha br", before);

    // New output scrolls the screen under the selection. The pins are tracked,
    // so the selection moves with the text rather than staying behind at fixed
    // coordinates — which is the property that makes selecting something a
    // program is still printing possible at all. Here the four line feeds push
    // the selected row off the screen and into the scrollback, so nothing of it
    // is lit; the claim is that the *text* is unchanged and the highlight comes
    // back when the row does.
    terminal.feed("\r\nnewer line\r\nnewer line\r\n");
    try terminal.refresh(gpa);
    try testing.expect(terminal.hasSelection());
    const after_output = (try terminal.selectionText(gpa)).?;
    defer gpa.free(after_output);
    try testing.expectEqualStrings(before, after_output);
    terminal.scrollToTop();
    try terminal.refresh(gpa);
    const first: u16 = 0;
    try testing.expect(terminal.cell(.{ .col = 0, .row = first }).?.selected);
    try testing.expect(!terminal.cell(.{ .col = 9, .row = first }).?.selected);

    // Now the case that does clear it: enough output to prune the pages the
    // pins were on. The engine prunes whole pages and always keeps at least
    // one, so this is ten thousand lines rather than a hundred — a flood that
    // stayed inside one page would prove nothing about pruning at all. Pruning
    // remaps the pins onto a surviving page and marks them `garbage`, and a
    // selection whose text no longer exists must not keep answering with
    // whatever now occupies those cells: a copy key returning the wrong text is
    // worse than no selection at all.
    terminal.setScrollConfig(.{ .max_scrollback_lines = 64 });
    const flood = try numberedLines(gpa, 10_000);
    defer gpa.free(flood);
    terminal.feed(flood);
    try terminal.refresh(gpa);
    try testing.expect(!terminal.hasSelection());
    try testing.expectEqual(@as(?[:0]const u8, null), try terminal.selectionText(gpa));
    // And nothing of it is lit, which is what a renderer would otherwise draw.
    var lit: usize = 0;
    for (0..terminal.gridSize().rows) |row| {
        for (0..terminal.gridSize().cols) |col| {
            if (terminal.cell(.{ .col = @intCast(col), .row = @intCast(row) }).?.selected) lit += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), lit);
}

// ---------------------------------------------------------------------------
// Tests: OSC 52 and paste
// ---------------------------------------------------------------------------

/// A clipboard adapter for the tests: one in-memory clipboard per location,
/// and a count of every call, so a test can say whether the "native"
/// clipboard was touched at all and what it holds now. It never reaches a
/// real clipboard.
const FakeClipboard = struct {
    held: [3]std.ArrayList(u8) = .{ .empty, .empty, .empty },
    reads: usize = 0,
    writes: usize = 0,

    fn deinit(self: *FakeClipboard) void {
        for (&self.held) |*one| one.deinit(std.testing.allocator);
    }

    fn access(self: *FakeClipboard) ClipboardAccess {
        return .{ .context = self, .read_fn = read, .write_fn = write };
    }

    fn of(self: *FakeClipboard, location: ClipboardLocation) *std.ArrayList(u8) {
        return &self.held[@intFromEnum(location)];
    }

    fn read(context: ?*anyopaque, location: ClipboardLocation, alloc: Allocator) ClipboardAccessError![]u8 {
        const self: *FakeClipboard = @ptrCast(@alignCast(context.?));
        self.reads += 1;
        return alloc.dupe(u8, self.of(location).items);
    }

    fn write(context: ?*anyopaque, location: ClipboardLocation, text: []const u8, _: Allocator) ClipboardAccessError!void {
        const self: *FakeClipboard = @ptrCast(@alignCast(context.?));
        self.writes += 1;
        const held = self.of(location);
        held.clearRetainingCapacity();
        try held.appendSlice(std.testing.allocator, text);
    }
};

/// The one line `noteClipboard` logged for the last request, rendered with the
/// same `format` the log uses, into the caller's buffer.
fn loggedLine(terminal: *const Terminal, buffer: []u8) ![]const u8 {
    const diagnostic = terminal.lastClipboardRequest() orelse return error.NothingLogged;
    return std.fmt.bufPrint(buffer, "{f}", .{diagnostic});
}

/// The permission requests the last feed recorded.
fn permissionRequests(terminal: *Terminal, into: []PermissionRequest) []PermissionRequest {
    var count: usize = 0;
    for (terminal.takeEvents()) |event| switch (event) {
        .permission_request => |req| {
            into[count] = req;
            count += 1;
        },
        else => {},
    };
    return into[0..count];
}

test "a clipboard diagnostic has nowhere to put contents" {
    // Every field is an enum or a count. A pointer, a slice or an array of
    // bytes added to it would be a place a payload could go, and the log line
    // is built from this struct alone.
    inline for (@typeInfo(ClipboardDiagnostic).@"struct".fields) |field| {
        const info = @typeInfo(field.type);
        const ok = switch (info) {
            .@"enum" => true,
            .optional => |optional| optional.child == usize,
            else => false,
        };
        if (!ok) @compileError("ClipboardDiagnostic." ++ field.name ++ " could carry contents");
    }
}

test "OSC 52 write under allow, ask and deny: the clipboard, the event, the log" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var fake: FakeClipboard = .{};
    defer fake.deinit();
    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 40, .rows = 4 });
    defer terminal.deinit(gpa);
    terminal.setClipboardAccess(fake.access());

    const write_c = "\x1b]52;c;Y29uZHVpdC1vc2M1Mi13cml0ZQ==\x1b\\";
    const fixture = "conduit-osc52-write";
    var line: [128]u8 = undefined;
    var requests: [4]PermissionRequest = undefined;

    // Allow: the decoded text reaches the clipboard, and OSC 52 has no write
    // acknowledgement, so the program is owed nothing.
    terminal.setClipboardPolicies(.{ .read = .deny, .write = .allow });
    terminal.feed(write_c);
    try testing.expectEqual(@as(usize, 1), fake.writes);
    try testing.expectEqualStrings(fixture, fake.of(.standard).items);
    try testing.expectEqual(@as(usize, 0), terminal.pendingResponses());
    try testing.expectEqual(@as(usize, 0), permissionRequests(&terminal, &requests).len);
    try testing.expectEqualStrings("OSC 52 write of the standard clipboard: written (19 byte(s))", try loggedLine(&terminal, &line));

    // Ask: refused, the clipboard untouched, and the request recorded with
    // its size and nothing else.
    fake.of(.standard).clearRetainingCapacity();
    terminal.setClipboardPolicies(.{ .read = .deny, .write = .ask });
    terminal.feed(write_c);
    try testing.expectEqual(@as(usize, 1), fake.writes);
    try testing.expectEqual(@as(usize, 0), fake.of(.standard).items.len);
    try testing.expectEqual(@as(usize, 0), terminal.pendingResponses());
    const asked = permissionRequests(&terminal, &requests);
    try testing.expectEqual(@as(usize, 1), asked.len);
    try testing.expectEqual(PermissionRequest{ .operation = .write, .location = .standard, .byte_count = fixture.len }, asked[0]);
    try testing.expectEqualStrings("OSC 52 write of the standard clipboard: asked (19 byte(s))", try loggedLine(&terminal, &line));

    // Deny: refused, untouched, and no event — there is nothing to ask.
    terminal.setClipboardPolicies(.{ .read = .deny, .write = .deny });
    terminal.feed(write_c);
    try testing.expectEqual(@as(usize, 1), fake.writes);
    try testing.expectEqual(@as(usize, 0), fake.of(.standard).items.len);
    try testing.expectEqual(@as(usize, 0), terminal.pendingResponses());
    try testing.expectEqual(@as(usize, 0), permissionRequests(&terminal, &requests).len);
    try testing.expectEqualStrings("OSC 52 write of the standard clipboard: denied (19 byte(s))", try loggedLine(&terminal, &line));

    // The primary selector reaches the primary clipboard and no other.
    terminal.setClipboardPolicies(.{ .read = .deny, .write = .allow });
    terminal.feed("\x1b]52;p;Y29uZHVpdC1vc2M1Mi1wcmltYXJ5\x1b\\");
    try testing.expectEqualStrings("conduit-osc52-primary", fake.of(.primary).items);
    try testing.expectEqual(@as(usize, 0), fake.of(.standard).items.len);

    // A payload that decodes to a control byte is not text a clipboard gets,
    // under any policy.
    terminal.feed("\x1b]52;c;YQBi\x1b\\");
    try testing.expectEqual(@as(usize, 2), fake.writes);
    try testing.expectEqualStrings("OSC 52 write of the standard clipboard: invalid (3 byte(s))", try loggedLine(&terminal, &line));
}

test "OSC 52 read under allow, ask and deny: the exact reply, the event, the log" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var fake: FakeClipboard = .{};
    defer fake.deinit();
    try fake.of(.standard).appendSlice(gpa, "conduit-osc52-read");
    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 40, .rows = 4 });
    defer terminal.deinit(gpa);
    terminal.setClipboardAccess(fake.access());

    var line: [128]u8 = undefined;
    var requests: [4]PermissionRequest = undefined;

    // Allow: the program is answered with the clipboard, base64-encoded, and
    // in the terminator it asked with.
    terminal.setClipboardPolicies(.{ .read = .allow, .write = .deny });
    terminal.feed("\x1b]52;c;?\x1b\\");
    const allowed = try takeAllResponses(&terminal);
    defer gpa.free(allowed);
    try testing.expectEqualStrings("\x1b]52;c;Y29uZHVpdC1vc2M1Mi1yZWFk\x1b\\", allowed);
    try testing.expectEqual(@as(usize, 1), fake.reads);
    try testing.expectEqualStrings("OSC 52 read of the standard clipboard: read (18 byte(s))", try loggedLine(&terminal, &line));
    terminal.feed("\x1b]52;c;?\x07");
    const bel = try takeAllResponses(&terminal);
    defer gpa.free(bel);
    try testing.expectEqualStrings("\x1b]52;c;Y29uZHVpdC1vc2M1Mi1yZWFk\x07", bel);

    // Ask: the empty reply, the clipboard never opened, and a request with no
    // size, because nothing was read to have one.
    terminal.setClipboardPolicies(.{ .read = .ask, .write = .deny });
    terminal.feed("\x1b]52;c;?\x1b\\");
    const asked_reply = try takeAllResponses(&terminal);
    defer gpa.free(asked_reply);
    try testing.expectEqualStrings("\x1b]52;c;\x1b\\", asked_reply);
    try testing.expectEqual(@as(usize, 2), fake.reads);
    const asked = permissionRequests(&terminal, &requests);
    try testing.expectEqual(@as(usize, 1), asked.len);
    try testing.expectEqual(PermissionRequest{ .operation = .read, .location = .standard, .byte_count = null }, asked[0]);
    try testing.expectEqualStrings("OSC 52 read of the standard clipboard: asked", try loggedLine(&terminal, &line));

    // Deny: the same empty reply, untouched, and no event.
    terminal.setClipboardPolicies(.{ .read = .deny, .write = .deny });
    terminal.feed("\x1b]52;c;?\x1b\\");
    const denied_reply = try takeAllResponses(&terminal);
    defer gpa.free(denied_reply);
    try testing.expectEqualStrings("\x1b]52;c;\x1b\\", denied_reply);
    try testing.expectEqual(@as(usize, 2), fake.reads);
    try testing.expectEqual(@as(usize, 0), permissionRequests(&terminal, &requests).len);
    try testing.expectEqualStrings("OSC 52 read of the standard clipboard: denied", try loggedLine(&terminal, &line));

    // The default, before anything is configured, is ask for both.
    try testing.expectEqual(ClipboardPolicies{ .read = .ask, .write = .ask }, ClipboardPolicies{});
}

test "a paste is bracketed when the program asked, and a multi-line one waits otherwise" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var terminal: Terminal = undefined;
    try terminal.init(testIo(), gpa, .{ .cols = 40, .rows = 4 });
    defer terminal.deinit(gpa);

    // Mode 2004 off: one line goes as-is, more than one needs confirmation and
    // no bytes are produced to send.
    try testing.expect(!terminal.bracketedPasteEnabled());
    const single = try terminal.preparePaste(gpa, "echo one", false);
    defer single.deinit(gpa);
    try testing.expectEqualStrings("echo one", single.encoded);
    try testing.expectEqual(Paste.confirmation_required, try terminal.preparePaste(gpa, "echo one\nrm -rf x\n", false));
    try testing.expectEqual(Paste.confirmation_required, try terminal.preparePaste(gpa, "a\rb", false));

    // The program turns it on the way bash does, and the payload is framed
    // exactly, newline and all.
    terminal.feed("\x1b[?2004h");
    try testing.expect(terminal.bracketedPasteEnabled());
    const framed = try terminal.preparePaste(gpa, "echo one\necho two", false);
    defer framed.deinit(gpa);
    try testing.expectEqualStrings("\x1b[200~echo one\necho two\x1b[201~", framed.encoded);

    // A payload that would end the bracket early is refused rather than sent.
    try testing.expectError(error.InvalidText, terminal.preparePaste(gpa, "x\x1b[201~rm -rf ~\n", false));

    terminal.feed("\x1b[?2004l");
    try testing.expect(!terminal.bracketedPasteEnabled());
}

// ---------------------------------------------------------------------------
// Tests: shell integration (OSC 7, OSC 133, RIS)
// ---------------------------------------------------------------------------

/// Feed one OSC 7 report of `url` and return the events it produced.
fn feedCwd(terminal: *Terminal, url: []const u8) ![]const Event {
    var buffer: [max_working_directory_bytes + 16]u8 = undefined;
    terminal.feed(try std.fmt.bufPrint(&buffer, "\x1b]7;{s}\x07", .{url}));
    return terminal.takeEvents();
}

/// This machine's host name, or a skip: the cases that name it prove nothing
/// on a target that has none to name.
fn testHostName(buffer: *[std.Io.net.HostName.max_len]u8) ![]const u8 {
    return localHostName(buffer) orelse {
        std.debug.print("skipped: this target reports no host name, so OSC 7 can only be tested with localhost\n", .{});
        return error.SkipZigTest;
    };
}

/// Assert that `url` was refused: no event, and the directory is unchanged.
fn expectCwdIgnored(terminal: *Terminal, url: []const u8, before: ?[]const u8) !void {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 0), (try feedCwd(terminal, url)).len);
    if (before) |want| {
        try testing.expectEqualStrings(want, terminal.workingDirectory().?);
    } else {
        try testing.expectEqual(@as(?[]const u8, null), terminal.workingDirectory());
    }
}

test "a remote terminal believes OSC 7 from its remote host and refuses this machine's name" {
    const testing = std.testing;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = try testHostName(&host_buffer);
    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 40, .rows = 4 });
    defer terminal.deinit(testing.allocator);
    var url: [256]u8 = undefined;

    try testing.expectError(error.InvalidHost, terminal.setWorkingDirectoryHost(""));
    try terminal.setWorkingDirectoryHost("remote-box");
    try testing.expectEqual(@as(usize, 1), (try feedCwd(&terminal, "file://remote-box/srv/app")).len);
    try testing.expectEqualStrings("/srv/app", terminal.workingDirectory().?);
    // The remote side's own `localhost` is still that machine.
    try testing.expectEqual(@as(usize, 1), (try feedCwd(&terminal, "file://localhost/srv")).len);
    try testing.expectEqualStrings("/srv", terminal.workingDirectory().?);
    // This machine's name, or a third host (a nested ssh), is foreign here.
    if (!std.mem.eql(u8, host, "remote-box")) {
        try expectCwdIgnored(&terminal, try std.fmt.bufPrint(&url, "file://{s}/tmp", .{host}), "/srv");
    }
    try expectCwdIgnored(&terminal, "file://other-box/tmp", "/srv");
}

test "OSC 7 from this host becomes the working directory, decoded by its scheme's rule" {
    const testing = std.testing;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = try testHostName(&host_buffer);
    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 40, .rows = 4 });
    defer terminal.deinit(testing.allocator);
    var url: [256]u8 = undefined;

    try testing.expectEqual(@as(?[]const u8, null), terminal.workingDirectory());

    // `file://localhost`, the form every shell can send without knowing its
    // own name.
    var events = try feedCwd(&terminal, "file://localhost/tmp/x");
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("/tmp/x", events[0].working_directory);
    try testing.expectEqualStrings("/tmp/x", terminal.workingDirectory().?);

    // `kitty-shell-cwd://` with this machine's own name.
    events = try feedCwd(&terminal, try std.fmt.bufPrint(&url, "kitty-shell-cwd://{s}/tmp/y", .{host}));
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("/tmp/y", events[0].working_directory);
    try testing.expectEqualStrings("/tmp/y", terminal.workingDirectory().?);

    // A `file` path is percent-decoded...
    events = try feedCwd(&terminal, "file://localhost/tmp/a%20b");
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("/tmp/a b", events[0].working_directory);
    try testing.expectEqualStrings("/tmp/a b", terminal.workingDirectory().?);

    // ...and a `kitty-shell-cwd` path is not: its bytes are the path, and
    // `?` and `#` are ordinary characters in it.
    events = try feedCwd(&terminal, try std.fmt.bufPrint(&url, "kitty-shell-cwd://{s}/tmp/a%20b", .{host}));
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("/tmp/a%20b", events[0].working_directory);
    try testing.expectEqualStrings("/tmp/a%20b", terminal.workingDirectory().?);
    events = try feedCwd(&terminal, try std.fmt.bufPrint(&url, "kitty-shell-cwd://{s}/tmp/what?#now", .{host}));
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("/tmp/what?#now", terminal.workingDirectory().?);

    // A `file` URL with this machine's own name, and a path that is not
    // normalised: `..` is a directory name the shell is entitled to use.
    events = try feedCwd(&terminal, try std.fmt.bufPrint(&url, "file://{s}/srv/link/../data", .{host}));
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("/srv/link/../data", terminal.workingDirectory().?);

    // The event's copy outlives the terminal's own buffer being replaced
    // within the same feed: two reports, two distinct payloads.
    terminal.feed("\x1b]7;file://localhost/one\x07\x1b]7;file://localhost/two\x07");
    events = terminal.takeEvents();
    try testing.expectEqual(@as(usize, 2), events.len);
    try testing.expectEqualStrings("/one", events[0].working_directory);
    try testing.expectEqualStrings("/two", events[1].working_directory);
    try testing.expectEqualStrings("/two", terminal.workingDirectory().?);
    try testing.expectEqual(@as(usize, 0), terminal.droppedEvents());
}

test "OSC 7 with no host, another host or another scheme is ignored, and the last good one stands" {
    const testing = std.testing;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = try testHostName(&host_buffer);
    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 40, .rows = 4 });
    defer terminal.deinit(testing.allocator);
    var url: [256]u8 = undefined;

    // Refused before anything was ever accepted: still none.
    try expectCwdIgnored(&terminal, "file:///tmp/x", null);

    try testing.expectEqual(@as(usize, 1), (try feedCwd(&terminal, "file://localhost/home/me")).len);
    const good = "/home/me";

    // No host at all. `file:///` is a local path to a URL parser, but it is
    // also what a remote shell sends when it does not say where it is.
    try expectCwdIgnored(&terminal, "file:///tmp/x", good);
    // Not a working-directory scheme.
    try expectCwdIgnored(&terminal, "http://localhost/tmp", good);
    try expectCwdIgnored(&terminal, "https://localhost/tmp", good);
    // A remote or spoofed host.
    try expectCwdIgnored(&terminal, "file://evil-host/tmp", good);
    try expectCwdIgnored(&terminal, "kitty-shell-cwd://evil-host/tmp", good);
    // A host that merely contains, or is contained in, this one's name.
    try expectCwdIgnored(&terminal, try std.fmt.bufPrint(&url, "file://{s}.evil.example/tmp", .{host}), good);
    try expectCwdIgnored(&terminal, try std.fmt.bufPrint(&url, "file://{s}/tmp", .{host[0 .. host.len - 1]}), good);
    try expectCwdIgnored(&terminal, "file://localhostx/tmp", good);
    // A user or a port rides with the host and the host is no longer just a
    // name; neither is a form a shell sends.
    try expectCwdIgnored(&terminal, "file://me@localhost/tmp", good);
    try expectCwdIgnored(&terminal, "file://localhost:22/tmp", good);
    // A `file` path with a query or a fragment is not a path.
    try expectCwdIgnored(&terminal, "file://localhost/tmp?x", good);
    try expectCwdIgnored(&terminal, "file://localhost/tmp#x", good);
    // Not a URL, and not an absolute path.
    try expectCwdIgnored(&terminal, "/tmp/x", good);
    try expectCwdIgnored(&terminal, "file://localhost", good);
    try expectCwdIgnored(&terminal, "file:relative", good);
    // A NUL, however it is spelled, is in no path.
    try expectCwdIgnored(&terminal, "file://localhost/tmp/a%00b", good);
    // A report at upstream's truncation limit would be stored cut short, so
    // it is not believed at all.
    var long: [max_working_directory_bytes + 8]u8 = undefined;
    const prefix = "file://localhost/";
    @memcpy(long[0..prefix.len], prefix);
    @memset(long[prefix.len..], 'a');
    try expectCwdIgnored(&terminal, long[0..], good);

    try testing.expectEqual(@as(usize, 0), terminal.droppedEvents());
}

test "an empty OSC 7 clears the working directory" {
    const testing = std.testing;
    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 40, .rows = 4 });
    defer terminal.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), (try feedCwd(&terminal, "file://localhost/tmp/x")).len);
    try testing.expectEqualStrings("/tmp/x", terminal.workingDirectory().?);

    const events = try feedCwd(&terminal, "");
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("", events[0].working_directory);
    try testing.expectEqual(@as(?[]const u8, null), terminal.workingDirectory());
}

test "an OSC 7 split across two feeds is one report" {
    const testing = std.testing;
    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 40, .rows = 4 });
    defer terminal.deinit(testing.allocator);

    terminal.feed("\x1b]7;file://local");
    try testing.expectEqual(@as(usize, 0), terminal.takeEvents().len);
    try testing.expectEqual(@as(?[]const u8, null), terminal.workingDirectory());

    terminal.feed("host/tmp/a%2");
    try testing.expectEqual(@as(usize, 0), terminal.takeEvents().len);

    terminal.feed("0b\x1b\\");
    const events = terminal.takeEvents();
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("/tmp/a b", events[0].working_directory);
    try testing.expectEqualStrings("/tmp/a b", terminal.workingDirectory().?);
}

test "OSC 133 marks arrive as prompt events, and the prompt predicates follow them" {
    const testing = std.testing;
    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 40, .rows = 6 });
    defer terminal.deinit(testing.allocator);

    // A shell without integration: no marks, never at a prompt.
    terminal.feed("$ ls\r\nfile\r\n$ ");
    try testing.expectEqual(@as(usize, 0), terminal.takeEvents().len);
    try testing.expect(!terminal.hasSeenPromptMarks());
    try testing.expect(!terminal.cursorIsAtPrompt());

    // A: the prompt starts.
    terminal.feed("\x1b]133;A\x07");
    var events = terminal.takeEvents();
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(Event{ .prompt = .{ .kind = .prompt_start, .exit_code = null } }, events[0]);
    try testing.expect(terminal.hasSeenPromptMarks());
    try testing.expect(terminal.cursorIsAtPrompt());

    // B: the prompt is drawn and the user is typing.
    terminal.feed("$ \x1b]133;B\x07");
    events = terminal.takeEvents();
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(Event{ .prompt = .{ .kind = .input_start, .exit_code = null } }, events[0]);
    try testing.expect(terminal.cursorIsAtPrompt());

    // C: the command runs, and its output is not a prompt.
    terminal.feed("false\r\n\x1b]133;C\x07");
    events = terminal.takeEvents();
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(Event{ .prompt = .{ .kind = .output_start, .exit_code = null } }, events[0]);
    try testing.expect(!terminal.cursorIsAtPrompt());

    // D;1: the command ended with status 1.
    terminal.feed("\x1b]133;D;1\x07");
    events = terminal.takeEvents();
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(Event{ .prompt = .{ .kind = .command_end, .exit_code = 1 } }, events[0]);
    try testing.expect(!terminal.cursorIsAtPrompt());

    // A bare D reports no status rather than a made-up zero, and P is a
    // prompt start too: zsh re-marks its prompt with it.
    terminal.feed("\x1b]133;D\x07\x1b]133;P;k=i\x07");
    events = terminal.takeEvents();
    try testing.expectEqual(@as(usize, 2), events.len);
    try testing.expectEqual(Event{ .prompt = .{ .kind = .command_end, .exit_code = null } }, events[0]);
    try testing.expectEqual(Event{ .prompt = .{ .kind = .prompt_start, .exit_code = null } }, events[1]);
    try testing.expect(terminal.cursorIsAtPrompt());

    // The alternate screen is a full-screen program's, never a prompt.
    terminal.feed("\x1b[?1049h");
    try testing.expect(!terminal.cursorIsAtPrompt());
    terminal.feed("\x1b[?1049l");
    try testing.expect(terminal.cursorIsAtPrompt());
    try testing.expect(terminal.hasSeenPromptMarks());
}

test "prompt rows are recorded through scrollback, and only where the shell marked them" {
    const testing = std.testing;
    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 20, .rows = 4 });
    defer terminal.deinit(testing.allocator);
    var rows: [8]u32 = undefined;

    // Unmarked prompts are not prompts.
    terminal.feed("$ ls\r\nfile\r\n");
    try testing.expectEqual(@as(usize, 0), terminal.promptRows(&rows));

    // Three marked prompts, each followed by output, on a 4-row screen: the
    // first two scroll into history and are still found, at their own rows.
    for (0..3) |_| terminal.feed("\x1b]133;A\x07$ \x1b]133;B\x07x\r\n\x1b]133;C\x07out\r\n\x1b]133;D;0\x07");
    try testing.expectEqual(@as(usize, 3), terminal.promptRows(&rows));
    try testing.expectEqualSlices(u32, &.{ 2, 4, 6 }, rows[0..3]);
    try testing.expect(terminal.viewport().history_rows > 0);

    // A buffer smaller than the history gets the oldest prompts and no more.
    var two: [2]u32 = undefined;
    try testing.expectEqual(@as(usize, 2), terminal.promptRows(&two));
    try testing.expectEqualSlices(u32, &.{ 2, 4 }, &two);

    // The alternate screen is a program's, and has no prompts of its own.
    terminal.feed("\x1b[?1049h");
    try testing.expectEqual(@as(usize, 0), terminal.promptRows(&rows));
    terminal.feed("\x1b[?1049l");
    try testing.expectEqual(@as(usize, 3), terminal.promptRows(&rows));
}

test "a resize leaves a marked prompt on screen, because no shell was promised to redraw it" {
    const testing = std.testing;
    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 20, .rows = 4 });
    defer terminal.deinit(testing.allocator);

    try testing.expectEqual(.false, terminal.vt.flags.shell_redraws_prompt);
    terminal.feed("\x1b]133;A\x07prompt$ \x1b]133;B\x07");
    try testing.expect(terminal.cursorIsAtPrompt());

    // Upstream's Zig default would erase this row on resize, expecting the
    // shell to draw it again.
    try terminal.resize(testing.allocator, .{ .cols = 30, .rows = 5 });
    try terminal.refresh(testing.allocator);
    var row: [64]u8 = undefined;
    try testing.expectEqualStrings("prompt$", try readRow(&terminal, 0, &row));
}

test "a full reset forgets the working directory and the prompt marks, and says so" {
    const testing = std.testing;
    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 40, .rows = 4 });
    defer terminal.deinit(testing.allocator);

    terminal.feed("\x1b]7;file://localhost/tmp/x\x07\x1b]2;title\x07\x1b]133;A\x07$ ");
    _ = terminal.takeEvents();
    try testing.expectEqualStrings("/tmp/x", terminal.workingDirectory().?);
    try testing.expect(terminal.hasSeenPromptMarks());

    terminal.feed("\x1bc");
    const events = terminal.takeEvents();
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(Event.reset, events[0]);
    try testing.expectEqual(@as(?[]const u8, null), terminal.workingDirectory());
    try testing.expectEqual(@as(?[]const u8, null), terminal.title());
    try testing.expect(!terminal.hasSeenPromptMarks());
    try testing.expect(!terminal.cursorIsAtPrompt());
    // A reset restores upstream's flag defaults, and this one stays Conduit's.
    try testing.expectEqual(.false, terminal.vt.flags.shell_redraws_prompt);

    // And the terminal takes a new report afterwards.
    try testing.expectEqual(@as(usize, 1), (try feedCwd(&terminal, "file://localhost/tmp/y")).len);
    try testing.expectEqualStrings("/tmp/y", terminal.workingDirectory().?);
}

test "a thread that does not own the terminal cannot set its working directory or read its events" {
    const testing = std.testing;
    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 40, .rows = 4 });
    defer terminal.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), (try feedCwd(&terminal, "file://localhost/owner")).len);
    terminal.feed("\x1b]133;A\x07");

    // What the intruder read back, written on its thread and read after
    // `join`. Starts at a value a refused take can never produce.
    var taken: usize = std.math.maxInt(usize);
    const intruder = try std.Thread.spawn(.{}, struct {
        fn go(subject: *Terminal, out: *usize) void {
            subject.feed("\x1b]7;file://localhost/intruder\x07\x1b]133;D;9\x07");
            out.* = subject.takeEvents().len;
        }
    }.go, .{ &terminal, &taken });
    intruder.join();

    try testing.expectEqual(@as(usize, 2), terminal.ownershipViolations());
    try testing.expectEqual(@as(usize, 0), taken);
    try testing.expectEqualStrings("/owner", terminal.workingDirectory().?);
    // The owner's own prompt mark is still the one waiting for it.
    const events = terminal.takeEvents();
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(Event{ .prompt = .{ .kind = .prompt_start, .exit_code = null } }, events[0]);
}

test "no working directory, accepted or refused, reaches a log line, and refusals stay at debug" {
    const testing = std.testing;
    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 40, .rows = 4 });
    defer terminal.deinit(testing.allocator);

    const marker = "conduit-cwd-marker";
    log_witness.clear();
    const reports = [_][]const u8{
        "file://localhost/tmp/" ++ marker,
        "kitty-shell-cwd://localhost/tmp/" ++ marker,
        "file:///tmp/" ++ marker,
        "file://" ++ marker ++ "/tmp",
        "http://localhost/" ++ marker,
        "file://localhost/" ++ marker ++ "%00",
        "",
    };
    for (reports) |report| _ = try feedCwd(&terminal, report);

    try testing.expect(!log_witness.overflowed);
    const logged = log_witness.text();
    // The witness saw the refusals, so an empty log is not what passes this.
    try testing.expect(std.mem.indexOf(u8, logged, "OSC 7 working directory ignored") != null);
    try testing.expect(std.mem.indexOf(u8, logged, marker) == null);
    var lines = std.mem.splitScalar(u8, logged, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try testing.expect(std.mem.startsWith(u8, line, "debug: "));
    }
}

/// Whether the engine was compiled with Ghostty's slow runtime safety, which
/// re-verifies the screen and page integrity on every scroll.
///
/// Upstream does not export its build options, but it sizes one bookkeeping
/// field by that flag, so the field's type is the flag. Those checks cost a
/// linefeed about 75 µs in an otherwise ReleaseSafe Conduit and about 1.5 ms
/// in Debug (TASK-72): they belong to Ghostty's own Debug builds and must
/// never reach an optimised Conduit.
const engine_integrity_checks = @FieldType(ghostty_vt.PageList, "pause_integrity_checks") != void;

test "an optimised build never links the engine with its per-scroll integrity checks" {
    // A Debug Conduit may run the engine in Ghostty's Debug contract; an
    // optimised one that still carries the checks pays them on every
    // linefeed, which is what made a 200,000-line flood take 15 s.
    if (builtin.mode == .Debug) return error.SkipZigTest;
    try std.testing.expect(!engine_integrity_checks);
}

test "200,000 short lines go through feed in bounded time" {
    const testing = std.testing;
    // Ghostty's Debug integrity checks cost about 1.5 ms per scroll by
    // design, so a Debug build linked with them cannot meet any useful bound;
    // every other combination must.
    if (builtin.mode == .Debug and engine_integrity_checks) return error.SkipZigTest;

    var terminal: Terminal = undefined;
    try terminal.init(testIo(), testing.allocator, .{ .cols = 120, .rows = 40 });
    defer terminal.deinit(testing.allocator);

    // `seq`-shaped output with the CR LF a PTY's onlcr produces, fed in the
    // 64 KiB slices a draining pump hands over.
    var flood: std.ArrayList(u8) = .empty;
    defer flood.deinit(testing.allocator);
    const lines = 200_000;
    for (0..lines) |n| {
        var line: [32]u8 = undefined;
        try flood.appendSlice(testing.allocator, try std.fmt.bufPrint(&line, "{d}\r\n", .{n}));
    }

    const started = std.Io.Clock.awake.now(testing.io).nanoseconds;
    var offset: usize = 0;
    while (offset < flood.items.len) {
        const end = @min(flood.items.len, offset + 64 * 1024);
        terminal.feed(flood.items[offset..end]);
        offset = end;
    }
    const elapsed = std.Io.Clock.awake.now(testing.io).nanoseconds - started;

    // Measured at about 0.1-0.25 s on the dev box without the engine's
    // integrity checks and 15 s with them in ReleaseSafe; 5 s leaves a slow
    // CI runner a wide margin while still catching a per-line regression.
    try testing.expect(elapsed < 5 * std.time.ns_per_s);
    try testing.expect(!terminal.isDegraded());

    try terminal.refresh(testing.allocator);
    // The last line scrolled into place above the cursor, so the flood was
    // consumed rather than dropped.
    var expected: [16]u8 = undefined;
    const last = try std.fmt.bufPrint(&expected, "{d}", .{lines - 1});
    const row = terminal.gridSize().rows - 2;
    for (last, 0..) |ch, col| {
        const c = terminal.cell(.{ .col = @intCast(col), .row = row }) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(u21, ch), c.codepoint);
    }
}
