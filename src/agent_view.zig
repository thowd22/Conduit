//! The agent view's model (TASK-57): a per-agent log of structured events,
//! the terminal-styled rows built from it, and the scroll, selection and
//! search state a view keeps over those rows.
//!
//! A file of the `app` module rather than a module of its own because only
//! the composition root draws it. It knows nothing about the semantic tree:
//! `main.zig` registers each visible row as `Text` or `InteractiveText` from
//! what this file computes, so every pixel still comes from the one tree.
//! Nothing here is harness-specific (invariant 9): rows are built from the
//! common `agent.Event` stream only.
//!
//! Safety (CONDUIT.md §11): every string in the log is the harness's claim.
//! It is copied, cleaned of controls and shown; nothing here opens, runs or
//! answers anything. A file reference or a permission decision becomes an
//! action only through an explicit click or Enter on its row in the app.
//!
//! Wrapping: this is the one place Conduit's UI wraps text. Chrome clips at
//! its edge, but a transcript is content, so messages, titles and summaries
//! wrap at the pane width into further rows, breaking at a space where one
//! fits and inside a word only when it does not.
//!
//! Threads: everything here belongs to the owner (UI) thread. The runner's
//! worker never touches a `View`; the owner appends what it drains.
//!
//! Memory: `EventLog` owns one allocation per entry, sized to that event's
//! text, bounded by an entry count and a byte budget (the oldest entries go
//! first). `Rows` owns an arena reset on every rebuild; a rebuild happens
//! only when the log or the width changed, never per frame.

const std = @import("std");
const agent = @import("agent");
const term = @import("term");

const Allocator = std.mem.Allocator;

/// The most choices one permission request carries, as `agent` stores them.
pub const max_decisions = @typeInfo(@FieldType(agent.StoredEvent, "decisions")).array.len;

/// Default bounds for one agent's log.
pub const default_entry_capacity = 4096;
pub const default_byte_budget = 4 * 1024 * 1024;
/// The most rows one view keeps; the oldest rows beyond it are not shown.
pub const max_rows = 20_000;
/// The narrowest width rows are wrapped at; a narrower pane clips instead.
pub const min_wrap_cells = 8;

// The event log --------------------------------------------------------------

/// One logged event and the view-side state of a permission request.
pub const Entry = struct {
    /// Monotonic per log, never reused.
    seq: u64,
    /// Slices point into `bytes` and `decisions`.
    event: agent.Event,
    decisions: [max_decisions]agent.Decision = undefined,
    bytes: []u8,
    /// The decision the human chose in this view, once sent.
    answered: ?u8 = null,
    /// How the request ended, once the harness said so.
    outcome: ?agent.PermissionOutcome = null,
};

/// A bounded, ordered log of one agent's events.
pub const EventLog = struct {
    allocator: Allocator,
    slots: []Entry,
    head: usize = 0,
    len: usize = 0,
    bytes_used: usize = 0,
    byte_budget: usize,
    next_seq: u64 = 1,
    /// Entries evicted to stay within the bounds.
    dropped: u64 = 0,
    /// Bumped on every change a view shows.
    generation: u64 = 0,

    pub fn init(allocator: Allocator, capacity: usize, byte_budget: usize) Allocator.Error!EventLog {
        std.debug.assert(capacity != 0);
        return .{ .allocator = allocator, .slots = try allocator.alloc(Entry, capacity), .byte_budget = byte_budget };
    }

    pub fn deinit(self: *EventLog) void {
        var index: usize = 0;
        while (index < self.len) : (index += 1) self.allocator.free(self.slots[(self.head + index) % self.slots.len].bytes);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn count(self: *const EventLog) usize {
        return self.len;
    }

    /// The `index`th entry, oldest first.
    pub fn at(self: *const EventLog, index: usize) *Entry {
        std.debug.assert(index < self.len);
        return &self.slots[(self.head + index) % self.slots.len];
    }

    /// The entry with sequence number `seq`, if it is still kept.
    pub fn bySeq(self: *const EventLog, seq: u64) ?*Entry {
        if (self.len == 0) return null;
        const first = self.at(0).seq;
        if (seq < first or seq - first >= self.len) return null;
        const entry = self.at(@intCast(seq - first));
        return if (entry.seq == seq) entry else null;
    }

    /// Record that the human chose decision `index` of request `seq`.
    pub fn markAnswered(self: *EventLog, seq: u64, index: u8) bool {
        const entry = self.bySeq(seq) orelse return false;
        if (entry.event != .permission_request or entry.answered != null or entry.outcome != null) return false;
        if (index >= entry.event.permission_request.decisions.len) return false;
        entry.answered = index;
        self.generation += 1;
        return true;
    }

    /// Deep-copy `ev` into the log. A `permission_resolved` that names a
    /// logged request settles that request instead of adding a row.
    pub fn append(self: *EventLog, ev: agent.Event) Allocator.Error!void {
        if (ev == .permission_resolved) {
            const resolved = ev.permission_resolved;
            var index = self.len;
            while (index > 0) {
                index -= 1;
                const entry = self.at(index);
                if (entry.event != .permission_request) continue;
                if (!std.mem.eql(u8, entry.event.permission_request.id, resolved.id)) continue;
                if (entry.outcome == null) {
                    entry.outcome = resolved.outcome;
                    self.generation += 1;
                }
                return;
            }
        }
        const size = eventBytes(ev);
        if (size > self.byte_budget) return;
        while (self.len != 0 and (self.len == self.slots.len or self.bytes_used + size > self.byte_budget)) self.dropOldest();
        const bytes = try self.allocator.alloc(u8, size);
        const slot = &self.slots[(self.head + self.len) % self.slots.len];
        slot.* = .{ .seq = self.next_seq, .event = undefined, .bytes = bytes };
        slot.event = copyEvent(ev, bytes, &slot.decisions);
        self.next_seq += 1;
        self.len += 1;
        self.bytes_used += size;
        self.generation += 1;
    }

    fn dropOldest(self: *EventLog) void {
        const entry = &self.slots[self.head];
        self.bytes_used -= entry.bytes.len;
        self.allocator.free(entry.bytes);
        self.head = (self.head + 1) % self.slots.len;
        self.len -= 1;
        self.dropped += 1;
        self.generation += 1;
    }
};

fn eventBytes(ev: agent.Event) usize {
    return switch (ev) {
        .message => |m| m.text.len,
        .tool_use => |t| t.name.len + t.summary.len,
        .file_reference => |f| f.path.len,
        .permission_request => |p| blk: {
            var total = p.id.len + p.title.len;
            for (p.decisions[0..@min(p.decisions.len, max_decisions)]) |d| total += d.id.len + d.label.len;
            break :blk total;
        },
        .permission_resolved => |r| r.id.len,
        .subagent => |s| s.id.len + s.name.len,
        .notification => |n| n.title.len + n.body.len,
        .status_change, .exited => 0,
    };
}

fn copyEvent(ev: agent.Event, bytes: []u8, decisions: *[max_decisions]agent.Decision) agent.Event {
    var used: usize = 0;
    const take = struct {
        fn f(buffer: []u8, at: *usize, text: []const u8) []const u8 {
            const out = buffer[at.*..][0..text.len];
            @memcpy(out, text);
            at.* += text.len;
            return out;
        }
    }.f;
    return switch (ev) {
        .message => |m| .{ .message = .{ .role = m.role, .text = take(bytes, &used, m.text), .truncated = m.truncated } },
        .tool_use => |t| .{ .tool_use = .{ .name = take(bytes, &used, t.name), .summary = take(bytes, &used, t.summary), .truncated = t.truncated } },
        .file_reference => |f| .{ .file_reference = .{ .path = take(bytes, &used, f.path), .line = f.line, .column = f.column } },
        .permission_request => |p| blk: {
            const n = @min(p.decisions.len, max_decisions);
            for (p.decisions[0..n], 0..) |d, i| decisions[i] = .{
                .id = take(bytes, &used, d.id),
                .label = take(bytes, &used, d.label),
                .kind = d.kind,
            };
            break :blk .{ .permission_request = .{
                .id = take(bytes, &used, p.id),
                .title = take(bytes, &used, p.title),
                .decisions = decisions[0..n],
            } };
        },
        .permission_resolved => |r| .{ .permission_resolved = .{ .id = take(bytes, &used, r.id), .outcome = r.outcome } },
        .subagent => |s| .{ .subagent = .{ .id = take(bytes, &used, s.id), .name = take(bytes, &used, s.name), .phase = s.phase } },
        .notification => |n| .{ .notification = .{ .title = take(bytes, &used, n.title), .body = take(bytes, &used, n.body), .truncated = n.truncated } },
        .status_change => |s| .{ .status_change = s },
        .exited => |e| .{ .exited = e },
    };
}

// Rows ------------------------------------------------------------------------

/// What a row shows, which decides its role and whether it is clickable.
pub const Kind = enum {
    /// "… N earlier events dropped".
    truncated,
    blank,
    message,
    tool,
    /// A file reference: clickable, opens the file at its line.
    reference,
    permission_title,
    /// The pending request's decisions, each clickable.
    permission_choices,
    /// What happened to an answered or resolved request.
    permission_outcome,
    /// A resolution for a request the log no longer holds.
    resolved,
    subagent,
    notification,
    status,
    exited,
};

/// How a row (or its prefix) is coloured; `main.zig` maps tones to theme roles.
pub const Tone = enum { normal, user, assistant, system, tool, reference, attention, dim, success, danger };

/// One clickable decision on a `permission_choices` row.
pub const Choice = struct {
    /// First cell of its label within the row.
    col: u32,
    cells: u32,
    /// Index into the request's decisions.
    index: u8,
};

pub const Row = struct {
    kind: Kind,
    /// The log entry the row came from, 0 for the dropped-events marker.
    seq: u64,
    /// The whole display line: no controls, valid UTF-8.
    text: []const u8,
    /// Bytes of `text` that are the speaker prefix.
    prefix_len: usize = 0,
    prefix_tone: Tone = .normal,
    tone: Tone = .normal,
    choices: [max_decisions]Choice = undefined,
    choice_count: u8 = 0,

    /// The row's width in cells.
    pub fn cells(self: *const Row) u32 {
        return displayCells(self.text);
    }
};

/// The name a harness speaks under: the first word of its display name,
/// lowercased ("Claude Code" → "claude"). Generic over every harness.
pub fn speakerName(buffer: []u8, display_name: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, display_name, ' ') orelse display_name.len;
    const n = @min(end, buffer.len);
    for (display_name[0..n], buffer[0..n]) |c, *out| out.* = std.ascii.toLower(c);
    return buffer[0..n];
}

/// The rows built from one log at one width.
pub const Rows = struct {
    arena: std.heap.ArenaAllocator,
    items: []Row = &.{},
    /// The log generation and width `items` were built from.
    generation: u64 = 0,
    width: u32 = 0,
    built: bool = false,
    /// Rows left out beyond `max_rows`.
    clipped: usize = 0,

    pub fn init(allocator: Allocator) Rows {
        return .{ .arena = .init(allocator) };
    }

    pub fn deinit(self: *Rows) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn stale(self: *const Rows, log: *const EventLog, width: u32) bool {
        return !self.built or self.generation != log.generation or self.width != width;
    }

    /// Rebuild every row from `log` at `width` cells. `speaker` names the
    /// assistant; `answerable` says whether decisions can be clicked at all.
    pub fn build(self: *Rows, log: *const EventLog, width: u32, speaker: []const u8) Allocator.Error!void {
        _ = self.arena.reset(.retain_capacity);
        const allocator = self.arena.allocator();
        var builder: Builder = .{ .allocator = allocator, .width = @max(width, min_wrap_cells) };
        if (log.dropped != 0) {
            const text = try std.fmt.allocPrint(allocator, "… {d} earlier event(s) dropped", .{log.dropped});
            try builder.push(.{ .kind = .truncated, .seq = 0, .text = text, .tone = .dim });
        }
        var index: usize = 0;
        while (index < log.count()) : (index += 1) try builder.entry(log.at(index), speaker);
        var rows = builder.rows.items;
        self.clipped = rows.len -| max_rows;
        rows = rows[self.clipped..];
        self.items = rows;
        self.generation = log.generation;
        self.width = width;
        self.built = true;
    }
};

const Builder = struct {
    allocator: Allocator,
    width: u32,
    rows: std.ArrayList(Row) = .empty,

    fn push(self: *Builder, row: Row) Allocator.Error!void {
        try self.rows.append(self.allocator, row);
    }

    fn blankBefore(self: *Builder, seq: u64) Allocator.Error!void {
        if (self.rows.items.len == 0) return;
        if (self.rows.items[self.rows.items.len - 1].kind == .blank) return;
        try self.push(.{ .kind = .blank, .seq = seq, .text = "" });
    }

    /// Wrap `body` after `prefix`; continuation rows indent by the prefix's
    /// width so the text forms one block.
    fn wrapped(self: *Builder, kind: Kind, seq: u64, prefix: []const u8, prefix_tone: Tone, body: []const u8, tone: Tone) Allocator.Error!void {
        const clean = try sanitize(self.allocator, body);
        const prefix_cells = displayCells(prefix);
        var first = true;
        var indent_cells = prefix_cells;
        if (prefix_cells + 4 > self.width) {
            // No room beside the prefix: it gets its own row and the body
            // starts flush on the next.
            try self.push(.{ .kind = kind, .seq = seq, .text = prefix, .prefix_len = prefix.len, .prefix_tone = prefix_tone, .tone = tone });
            first = false;
            indent_cells = 0;
        }
        const available = self.width - @min(self.width - 1, indent_cells);
        var lines = std.mem.splitScalar(u8, clean, '\n');
        while (lines.next()) |line| {
            var rest = line;
            while (true) {
                const room = available;
                const cut = wrapCut(rest, room);
                const lead: []const u8 = if (first) prefix else try spaces(self.allocator, indent_cells);
                const text = try std.mem.concat(self.allocator, u8, &.{ lead, rest[0..cut.end] });
                try self.push(.{
                    .kind = kind,
                    .seq = seq,
                    .text = text,
                    .prefix_len = lead.len,
                    .prefix_tone = if (first) prefix_tone else tone,
                    .tone = tone,
                });
                first = false;
                rest = rest[cut.next..];
                if (rest.len == 0) break;
            }
        }
    }

    fn entry(self: *Builder, logged: *const Entry, speaker: []const u8) Allocator.Error!void {
        const seq = logged.seq;
        switch (logged.event) {
            .message => |m| {
                try self.blankBefore(seq);
                var prefix_buffer: [64]u8 = undefined;
                const prefix = switch (m.role) {
                    .user => "you › ",
                    .assistant => std.fmt.bufPrint(&prefix_buffer, "{s} › ", .{speaker}) catch "agent › ",
                    .system => "system › ",
                };
                const owned_prefix = try self.allocator.dupe(u8, prefix);
                const tone: Tone = switch (m.role) {
                    .user => .user,
                    .assistant => .assistant,
                    .system => .system,
                };
                const body = if (m.truncated) try std.mem.concat(self.allocator, u8, &.{ m.text, " …" }) else m.text;
                try self.wrapped(.message, seq, owned_prefix, tone, body, .normal);
            },
            .tool_use => |t| {
                const name = try sanitize(self.allocator, t.name);
                const head = try std.mem.concat(self.allocator, u8, &.{ "⚙ ", name, " " });
                try self.wrapped(.tool, seq, head, .tool, t.summary, .dim);
            },
            .file_reference => |f| {
                const path = try sanitize(self.allocator, f.path);
                const spelled = if (f.line) |line|
                    if (f.column) |column|
                        try std.fmt.allocPrint(self.allocator, "{s}:{d}:{d}", .{ path, line, column })
                    else
                        try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ path, line })
                else
                    path;
                // A reference is one clickable row: a long path loses its
                // start rather than the file name and line that identify it.
                const lead = "  ↳ ";
                const room = self.width -| displayCells(lead);
                const text = if (displayCells(spelled) <= room)
                    try std.mem.concat(self.allocator, u8, &.{ lead, spelled })
                else
                    try std.mem.concat(self.allocator, u8, &.{ lead, "…", tailCells(spelled, room -| 1) });
                try self.push(.{ .kind = .reference, .seq = seq, .text = text, .tone = .reference });
            },
            .permission_request => |p| {
                try self.blankBefore(seq);
                try self.wrapped(.permission_title, seq, "? ", .attention, p.title, .attention);
                if (logged.outcome) |outcome| {
                    try self.push(.{ .kind = .permission_outcome, .seq = seq, .text = try outcomeText(self.allocator, p, logged.answered, outcome), .tone = outcomeTone(outcome) });
                } else if (logged.answered) |index| {
                    const label = try sanitize(self.allocator, p.decisions[index].label);
                    const text = try std.mem.concat(self.allocator, u8, &.{ "  › ", label, " — sent" });
                    try self.push(.{ .kind = .permission_outcome, .seq = seq, .text = text, .tone = .dim });
                } else {
                    try self.choiceRows(seq, p);
                }
            },
            .permission_resolved => |r| {
                const id = try sanitize(self.allocator, r.id);
                const text = try std.fmt.allocPrint(self.allocator, "· permission {s}: {s}", .{ id, outcomeWords(r.outcome) });
                try self.push(.{ .kind = .resolved, .seq = seq, .text = text, .tone = .dim });
            },
            .status_change => |s| {
                const text = try std.mem.concat(self.allocator, u8, &.{ "· ", s.state.label() });
                try self.push(.{ .kind = .status, .seq = seq, .text = text, .tone = .dim });
            },
            .subagent => |s| {
                const body = try std.fmt.allocPrint(self.allocator, "subagent {s} {s}", .{ s.name, switch (s.phase) {
                    .start => "started",
                    .stop => "finished",
                } });
                const head = switch (s.phase) {
                    .start => "◆ ",
                    .stop => "◇ ",
                };
                try self.wrapped(.subagent, seq, head, .dim, body, .dim);
            },
            .notification => |n| {
                const title = try sanitize(self.allocator, n.title);
                const head = if (title.len == 0) "▪ " else try std.mem.concat(self.allocator, u8, &.{ "▪ ", title, ": " });
                try self.wrapped(.notification, seq, head, .attention, n.body, .normal);
            },
            .exited => |e| {
                const text = switch (e) {
                    .code => |code| try std.fmt.allocPrint(self.allocator, "■ exited: status {d}", .{code}),
                    .signal => |signal| try std.fmt.allocPrint(self.allocator, "■ exited: signal {d}", .{signal}),
                };
                try self.push(.{ .kind = .exited, .seq = seq, .text = text, .tone = if (e.succeeded()) .dim else .danger });
            },
        }
    }

    /// Lay the decisions out left to right, two cells apart, starting a new
    /// row when the next one does not fit.
    fn choiceRows(self: *Builder, seq: u64, request: agent.PermissionRequest) Allocator.Error!void {
        const indent = "  ";
        var line: std.ArrayList(u8) = .empty;
        var row: Row = .{ .kind = .permission_choices, .seq = seq, .text = "", .tone = .dim };
        try line.appendSlice(self.allocator, indent);
        var col: u32 = 2;
        for (request.decisions, 0..) |decision, index| {
            const label = try sanitize(self.allocator, decision.label);
            const cells = @max(displayCells(label), 1);
            if (row.choice_count != 0 and col + 2 + cells > self.width) {
                row.text = line.items;
                try self.push(row);
                line = .empty;
                try line.appendSlice(self.allocator, indent);
                col = 2;
                row = .{ .kind = .permission_choices, .seq = seq, .text = "", .tone = .dim };
            }
            if (row.choice_count != 0) {
                try line.appendSlice(self.allocator, "  ");
                col += 2;
            }
            row.choices[row.choice_count] = .{ .col = col, .cells = cells, .index = @intCast(index) };
            row.choice_count += 1;
            try line.appendSlice(self.allocator, if (label.len == 0) "?" else label);
            col += cells;
        }
        row.text = line.items;
        try self.push(row);
    }
};

fn outcomeWords(outcome: agent.PermissionOutcome) []const u8 {
    return switch (outcome) {
        .allowed => "allowed",
        .rejected => "rejected",
        .resolved_elsewhere => "answered in the terminal",
        .cancelled => "cancelled",
    };
}

fn outcomeTone(outcome: agent.PermissionOutcome) Tone {
    return switch (outcome) {
        .allowed => .success,
        .rejected => .danger,
        .resolved_elsewhere, .cancelled => .dim,
    };
}

fn outcomeText(allocator: Allocator, request: agent.PermissionRequest, answered: ?u8, outcome: agent.PermissionOutcome) Allocator.Error![]const u8 {
    const glyph = switch (outcome) {
        .allowed => "✓",
        .rejected => "×",
        .resolved_elsewhere => "↷",
        .cancelled => "–",
    };
    if (answered) |index| {
        const label = try sanitize(allocator, request.decisions[index].label);
        return std.fmt.allocPrint(allocator, "  {s} {s}: {s}", .{ glyph, label, outcomeWords(outcome) });
    }
    return std.fmt.allocPrint(allocator, "  {s} {s}", .{ glyph, outcomeWords(outcome) });
}

fn spaces(allocator: Allocator, n: u32) Allocator.Error![]const u8 {
    const out = try allocator.alloc(u8, n);
    @memset(out, ' ');
    return out;
}

/// A display copy of untrusted text: valid UTF-8 (malformed bytes become
/// U+FFFD), CR dropped, tabs and other controls as spaces, LF kept as the
/// line break the wrapper honours.
pub fn sanitize(allocator: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(allocator, text.len);
    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch {
            try out.appendSlice(allocator, "\u{FFFD}");
            index += 1;
            continue;
        };
        if (index + length > text.len) {
            try out.appendSlice(allocator, "\u{FFFD}");
            break;
        }
        const codepoint = std.unicode.utf8Decode(text[index .. index + length]) catch {
            try out.appendSlice(allocator, "\u{FFFD}");
            index += 1;
            continue;
        };
        if (codepoint == '\n') {
            try out.append(allocator, '\n');
        } else if (codepoint == '\r') {
            // Dropped: a CRLF is one break.
        } else if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint < 0xa0)) {
            try out.append(allocator, ' ');
        } else {
            try out.appendSlice(allocator, text[index .. index + length]);
        }
        index += length;
    }
    return out.items;
}

/// Cells one codepoint takes.
fn codepointCells(codepoint: u21) u32 {
    const measured = term.graphemeWidth(&.{codepoint});
    return measured.width;
}

/// The width of valid UTF-8 `text` in cells, codepoint by codepoint.
pub fn displayCells(text: []const u8) u32 {
    var view = (std.unicode.Utf8View.init(text) catch return @intCast(text.len)).iterator();
    var total: u32 = 0;
    while (view.nextCodepoint()) |codepoint| total += codepointCells(codepoint);
    return total;
}

/// The longest suffix of valid UTF-8 `text` that fits `cells`.
fn tailCells(text: []const u8, cells: u32) []const u8 {
    var start = text.len;
    var used: u32 = 0;
    while (start > 0) {
        var at = start - 1;
        while (at > 0 and text[at] & 0xC0 == 0x80) at -= 1;
        const codepoint = std.unicode.utf8Decode(text[at..start]) catch 0xFFFD;
        const width = codepointCells(codepoint);
        if (used + width > cells) break;
        used += width;
        start = at;
    }
    return text[start..];
}

/// The byte offset of cell `col` in `text`: the start of the codepoint that
/// covers it, or `text.len` past the end.
pub fn byteAtCell(text: []const u8, col: u32) usize {
    var view = (std.unicode.Utf8View.init(text) catch return @min(col, text.len)).iterator();
    var cells: u32 = 0;
    var start: usize = 0;
    while (view.nextCodepoint()) |codepoint| {
        const width = codepointCells(codepoint);
        if (cells + width > col and width != 0) return start;
        cells += width;
        start = view.i;
    }
    return text.len;
}

const Cut = struct { end: usize, next: usize };

/// Where to cut `text` to fit `room` cells: at the last space that fits, or
/// inside the word when none does. `next` skips the space it broke at.
fn wrapCut(text: []const u8, room: u32) Cut {
    if (displayCells(text) <= room) return .{ .end = text.len, .next = text.len };
    var view = (std.unicode.Utf8View.init(text) catch return .{ .end = text.len, .next = text.len }).iterator();
    var cells: u32 = 0;
    var last_space: ?usize = null;
    var hard: usize = 0;
    while (view.nextCodepointSlice()) |slice| {
        const start = view.i - slice.len;
        const codepoint = std.unicode.utf8Decode(slice) catch 0xFFFD;
        const width = codepointCells(codepoint);
        if (cells + width > room) {
            // The codepoint that does not fit is the break itself.
            if (codepoint == ' ' and start != 0) return .{ .end = start, .next = start + 1 };
            break;
        }
        if (codepoint == ' ') last_space = start;
        cells += width;
        hard = view.i;
    }
    if (last_space) |space| if (space != 0) return .{ .end = space, .next = space + 1 };
    // At least one codepoint per row, so a too-narrow pane still progresses.
    if (hard == 0) {
        const first = std.unicode.utf8ByteSequenceLength(text[0]) catch 1;
        return .{ .end = @min(first, text.len), .next = @min(first, text.len) };
    }
    return .{ .end = hard, .next = hard };
}

// Scroll, selection and search ----------------------------------------------------

/// A cell in the row list: row index into `Rows.items`, column in cells.
pub const Position = struct {
    row: usize,
    col: u32,

    fn before(a: Position, b: Position) bool {
        return a.row < b.row or (a.row == b.row and a.col < b.col);
    }
};

/// A selection over rows, `anchor` where it began and `caret` where it is now.
/// The cell under the later end is not included.
pub const Selection = struct {
    anchor: Position,
    caret: Position,

    pub fn ordered(self: Selection) struct { start: Position, end: Position } {
        return if (self.caret.before(self.anchor))
            .{ .start = self.caret, .end = self.anchor }
        else
            .{ .start = self.anchor, .end = self.caret };
    }

    pub fn isEmpty(self: Selection) bool {
        return self.anchor.row == self.caret.row and self.anchor.col == self.caret.col;
    }

    /// The selected cell range of `row` (end exclusive), if any.
    pub fn columnsOn(self: Selection, row: usize, row_cells: u32) ?struct { start: u32, end: u32 } {
        const span = self.ordered();
        if (row < span.start.row or row > span.end.row) return null;
        const start = if (row == span.start.row) @min(span.start.col, row_cells) else 0;
        const end = if (row == span.end.row) @min(span.end.col, row_cells) else row_cells;
        if (end <= start) return null;
        return .{ .start = start, .end = end };
    }
};

/// One search hit: a cell range on one row.
pub const Match = struct {
    row: usize,
    col: u32,
    cells: u32,
};

/// Literal matches of `needle` in `rows`, row by row, into `out`. Returns how
/// many were found and whether more were left out. Matching is per row: a
/// phrase wrapped across rows is not found, as in a terminal.
pub fn findMatches(rows: []const Row, needle: []const u8, case_sensitive: bool, out: []Match) struct { count: usize, truncated: bool } {
    var found: usize = 0;
    if (needle.len == 0) return .{ .count = 0, .truncated = false };
    for (rows, 0..) |row, row_index| {
        var from: usize = 0;
        while (from + needle.len <= row.text.len) {
            const at = (if (case_sensitive)
                std.mem.indexOfPos(u8, row.text, from, needle)
            else
                indexOfIgnoreCasePos(row.text, from, needle)) orelse break;
            if (found == out.len) return .{ .count = found, .truncated = true };
            out[found] = .{
                .row = row_index,
                .col = displayCells(row.text[0..at]),
                .cells = @max(displayCells(row.text[at .. at + needle.len]), 1),
            };
            found += 1;
            from = at + needle.len;
        }
    }
    return .{ .count = found, .truncated = false };
}

fn indexOfIgnoreCasePos(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    var at = start;
    while (at + needle.len <= haystack.len) : (at += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[at .. at + needle.len], needle)) return at;
    }
    return null;
}

/// One agent's view: its log, the rows built from it and what the human did
/// to them. Owned by the agent's runner; the owner thread only.
pub const View = struct {
    log: EventLog,
    rows: Rows,
    /// Shown in place of the raw terminal.
    active: bool = false,
    /// The first visible row.
    top: usize = 0,
    /// Stay at the bottom as rows arrive; cleared by scrolling up.
    follow: bool = true,
    selection: ?Selection = null,

    pub fn init(allocator: Allocator, entry_capacity: usize, byte_budget: usize) Allocator.Error!View {
        return .{ .log = try EventLog.init(allocator, entry_capacity, byte_budget), .rows = Rows.init(allocator) };
    }

    pub fn deinit(self: *View) void {
        self.rows.deinit();
        self.log.deinit();
        self.* = undefined;
    }

    pub fn rowCount(self: *const View) usize {
        return self.rows.items.len;
    }

    fn maxTop(self: *const View, height: u32) usize {
        return self.rowCount() -| height;
    }

    /// Keep `top` valid for `height` rows, and at the bottom while following.
    pub fn settle(self: *View, height: u32) void {
        const limit = self.maxTop(height);
        if (self.follow or self.top > limit) self.top = limit;
        if (self.top == limit) self.follow = true;
    }

    /// Scroll by `delta` rows (negative is up).
    pub fn scrollBy(self: *View, delta: isize, height: u32) void {
        const limit = self.maxTop(height);
        if (delta < 0) {
            self.top -|= @intCast(-delta);
        } else {
            self.top = @min(limit, self.top + @as(usize, @intCast(delta)));
        }
        self.follow = self.top >= limit;
    }

    pub fn scrollToTop(self: *View) void {
        self.top = 0;
        self.follow = false;
    }

    pub fn scrollToBottom(self: *View, height: u32) void {
        self.top = self.maxTop(height);
        self.follow = true;
    }

    /// Scroll the least so that `row` is visible.
    pub fn reveal(self: *View, row: usize, height: u32) void {
        if (height == 0) return;
        if (row < self.top) {
            self.top = row;
        } else if (row >= self.top + height) {
            self.top = row + 1 - height;
        }
        self.follow = self.top >= self.maxTop(height);
    }

    /// The selected text, rows joined by newlines with trailing spaces cut.
    /// Caller owns the result; null when nothing is selected.
    pub fn selectionText(self: *const View, allocator: Allocator) Allocator.Error!?[]u8 {
        const selection = self.selection orelse return null;
        if (selection.isEmpty()) return null;
        const span = selection.ordered();
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var row = span.start.row;
        while (row <= span.end.row and row < self.rows.items.len) : (row += 1) {
            const text = self.rows.items[row].text;
            const columns = selection.columnsOn(row, displayCells(text));
            // A selection that ends at the start of a row does not take it.
            if (row == span.end.row and row != span.start.row and columns == null) break;
            if (row != span.start.row) try out.append(allocator, '\n');
            const kept = columns orelse continue;
            const piece = text[byteAtCell(text, kept.start)..byteAtCell(text, kept.end)];
            try out.appendSlice(allocator, std.mem.trimEnd(u8, piece, " "));
        }
        if (out.items.len == 0) {
            out.deinit(allocator);
            return null;
        }
        return try out.toOwnedSlice(allocator);
    }
};

// Tests ---------------------------------------------------------------------------

const testing = std.testing;

const two_decisions = [_]agent.Decision{
    .{ .id = "allow", .label = "Allow once", .kind = .allow_once },
    .{ .id = "deny", .label = "Reject", .kind = .reject },
};

test "the log copies events, settles requests and drops the oldest within its bounds" {
    var log = try EventLog.init(testing.allocator, 3, 1024);
    defer log.deinit();
    var text = "hello".*;
    try log.append(.{ .message = .{ .role = .user, .text = &text } });
    @memset(&text, 'x');
    try testing.expectEqualStrings("hello", log.at(0).event.message.text);

    try log.append(.{ .permission_request = .{ .id = "r1", .title = "Run: ls", .decisions = &two_decisions } });
    const request_seq = log.at(1).seq;
    try testing.expectEqualStrings("Reject", log.at(1).event.permission_request.decisions[1].label);
    try testing.expect(log.markAnswered(request_seq, 1));
    try testing.expect(!log.markAnswered(request_seq, 0));
    const before = log.count();
    try log.append(.{ .permission_resolved = .{ .id = "r1", .outcome = .rejected } });
    try testing.expectEqual(before, log.count());
    try testing.expectEqual(agent.PermissionOutcome.rejected, log.bySeq(request_seq).?.outcome.?);
    // An unknown resolution is kept as its own entry.
    try log.append(.{ .permission_resolved = .{ .id = "gone", .outcome = .allowed } });
    try testing.expectEqual(@as(usize, 3), log.count());

    // A fourth entry evicts the first by count.
    try log.append(.{ .status_change = .{ .state = .done, .source = .structured } });
    try testing.expectEqual(@as(usize, 3), log.count());
    try testing.expectEqual(@as(u64, 1), log.dropped);
    try testing.expect(log.bySeq(1) == null);
    try testing.expect(log.bySeq(request_seq) != null);

    // A large entry evicts by bytes.
    const big = "b" ** 1000;
    try log.append(.{ .message = .{ .role = .assistant, .text = big } });
    try testing.expect(log.bytes_used <= 1024);
    try testing.expect(log.dropped >= 2);
    // An event bigger than the whole budget is not kept at all.
    const huge = "h" ** 2000;
    const count_before = log.count();
    try log.append(.{ .message = .{ .role = .assistant, .text = huge } });
    try testing.expectEqual(count_before, log.count());
}

fn rowTexts(rows: []const Row, out: [][]const u8) [][]const u8 {
    for (rows, 0..) |row, i| out[i] = row.text;
    return out[0..rows.len];
}

test "rows wrap messages under the speaker prefix and lay out each event kind" {
    var log = try EventLog.init(testing.allocator, 64, 64 * 1024);
    defer log.deinit();
    try log.append(.{ .message = .{ .role = .user, .text = "fix it" } });
    try log.append(.{ .message = .{ .role = .assistant, .text = "alpha beta gamma delta epsilon\nzeta" } });
    try log.append(.{ .tool_use = .{ .name = "Bash", .summary = "zig build" } });
    try log.append(.{ .file_reference = .{ .path = "src/a.zig", .line = 12 } });
    try log.append(.{ .permission_request = .{ .id = "r1", .title = "Run: make", .decisions = &two_decisions } });
    try log.append(.{ .subagent = .{ .id = "s", .name = "explore", .phase = .start } });
    try log.append(.{ .notification = .{ .title = "Claude", .body = "needs you" } });
    try log.append(.{ .status_change = .{ .state = .done, .source = .structured } });
    try log.append(.{ .exited = .{ .code = 1 } });

    var rows = Rows.init(testing.allocator);
    defer rows.deinit();
    try testing.expect(rows.stale(&log, 20));
    try rows.build(&log, 20, "claude");
    try testing.expect(!rows.stale(&log, 20));
    try testing.expect(rows.stale(&log, 21));

    var storage: [64][]const u8 = undefined;
    const texts = rowTexts(rows.items, &storage);
    const expected = [_][]const u8{
        "you › fix it",
        "",
        "claude › alpha beta",
        "         gamma delta",
        "         epsilon",
        "         zeta",
        "⚙ Bash zig build",
        "  ↳ src/a.zig:12",
        "",
        "? Run: make",
        "  Allow once  Reject",
        "◆ subagent explore",
        "  started",
        "▪ Claude: needs you",
        "· done",
        "■ exited: status 1",
    };
    try testing.expectEqual(expected.len, texts.len);
    for (expected, texts) |want, got| try testing.expectEqualStrings(want, got);
    for (rows.items) |row| try testing.expect(row.cells() <= 20);
    try testing.expectEqual(@as(usize, "you › ".len), rows.items[0].prefix_len);
    try testing.expectEqual(Kind.reference, rows.items[7].kind);

    const choices = rows.items[10];
    try testing.expectEqual(Kind.permission_choices, choices.kind);
    try testing.expectEqual(@as(u8, 2), choices.choice_count);
    try testing.expectEqual(Choice{ .col = 2, .cells = 10, .index = 0 }, choices.choices[0]);
    try testing.expectEqual(Choice{ .col = 14, .cells = 6, .index = 1 }, choices.choices[1]);

    // Too narrow for both decisions: the second moves to its own row.
    try rows.build(&log, 14, "claude");
    var narrow_choices: usize = 0;
    for (rows.items) |row| {
        if (row.kind == .permission_choices) narrow_choices += 1;
    }
    try testing.expectEqual(@as(usize, 2), narrow_choices);

    // Answered, then resolved: the controls go and the outcome stays.
    var request_seq: u64 = 0;
    for (rows.items) |row| {
        if (row.kind == .permission_title) request_seq = row.seq;
    }
    try testing.expect(log.markAnswered(request_seq, 0));
    try rows.build(&log, 20, "claude");
    try testing.expectEqualStrings("  › Allow once — sent", rows.items[10].text);
    try log.append(.{ .permission_resolved = .{ .id = "r1", .outcome = .allowed } });
    try rows.build(&log, 40, "claude");
    var outcome: ?[]const u8 = null;
    for (rows.items) |row| {
        if (row.kind == .permission_choices) return error.ControlsRemained;
        if (row.kind == .permission_outcome) outcome = row.text;
    }
    try testing.expectEqualStrings("  ✓ Allow once: allowed", outcome.?);
}

test "untrusted text is cleaned and a dropped log is marked" {
    var log = try EventLog.init(testing.allocator, 2, 4096);
    defer log.deinit();
    try log.append(.{ .status_change = .{ .state = .working, .source = .structured } });
    try log.append(.{ .message = .{ .role = .assistant, .text = "a\x1b[31mb\tc\r\n\xffd" } });
    try log.append(.{ .status_change = .{ .state = .done, .source = .structured } });
    var rows = Rows.init(testing.allocator);
    defer rows.deinit();
    try rows.build(&log, 40, "pi");
    try testing.expectEqual(Kind.truncated, rows.items[0].kind);
    try testing.expectEqualStrings("… 1 earlier event(s) dropped", rows.items[0].text);
    try testing.expectEqual(Kind.blank, rows.items[1].kind);
    try testing.expectEqualStrings("pi › a [31mb c", rows.items[2].text);
    try testing.expectEqualStrings("     \u{FFFD}d", rows.items[3].text);
    try testing.expectEqualStrings("· done", rows.items[4].text);
    for (rows.items) |row| try testing.expect(std.unicode.utf8ValidateSlice(row.text));
    var name: [16]u8 = undefined;
    try testing.expectEqualStrings("claude", speakerName(&name, "Claude Code"));
    try testing.expectEqualStrings("opencode", speakerName(&name, "OpenCode"));
}

test "wrapping breaks inside a word only when no space fits and counts wide cells" {
    try testing.expectEqual(Cut{ .end = 5, .next = 6 }, wrapCut("hello world", 8));
    try testing.expectEqual(Cut{ .end = 4, .next = 4 }, wrapCut("abcdefgh", 4));
    try testing.expectEqual(Cut{ .end = 3, .next = 3 }, wrapCut("漢字漢字", 3));
    try testing.expectEqual(Cut{ .end = 3, .next = 3 }, wrapCut("漢字", 1));
    try testing.expectEqual(@as(u32, 4), displayCells("漢字"));
    try testing.expectEqual(@as(usize, 3), byteAtCell("漢字", 2));
    try testing.expectEqual(@as(usize, 6), byteAtCell("漢字", 9));
    try testing.expectEqualStrings("字", tailCells("漢字", 3));
    try testing.expectEqualStrings("e.zig:9", tailCells("/a/b/file.zig:9", 7));

    // A reference wider than the pane keeps its file name and line.
    var log = try EventLog.init(testing.allocator, 4, 4096);
    defer log.deinit();
    try log.append(.{ .file_reference = .{ .path = "/very/long/directory/name/sample.zig", .line = 42 } });
    var rows = Rows.init(testing.allocator);
    defer rows.deinit();
    try rows.build(&log, 20, "claude");
    try testing.expectEqualStrings("  ↳ …e/sample.zig:42", rows.items[0].text);
    try testing.expect(rows.items[0].cells() <= 20);
}

test "selection spans rows, orders its ends and copies newline-joined text" {
    var view = try View.init(testing.allocator, 16, 4096);
    defer view.deinit();
    try view.log.append(.{ .message = .{ .role = .user, .text = "first line" } });
    try view.log.append(.{ .message = .{ .role = .assistant, .text = "second line" } });
    try view.rows.build(&view.log, 40, "claude");
    // Rows: "you › first line", "", "claude › second line".
    view.selection = .{ .anchor = .{ .row = 2, .col = 15 }, .caret = .{ .row = 0, .col = 6 } };
    const text = (try view.selectionText(testing.allocator)).?;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("first line\n\nclaude › second", text);
    try testing.expect(view.selection.?.columnsOn(3, 10) == null);
    const middle = view.selection.?.columnsOn(1, 0);
    try testing.expect(middle == null);
    const first = view.selection.?.columnsOn(0, 16).?;
    try testing.expectEqual(@as(u32, 6), first.start);
    try testing.expectEqual(@as(u32, 16), first.end);

    view.selection = .{ .anchor = .{ .row = 0, .col = 3 }, .caret = .{ .row = 0, .col = 3 } };
    try testing.expect((try view.selectionText(testing.allocator)) == null);
}

test "scrolling follows the bottom until the human scrolls up" {
    var view = try View.init(testing.allocator, 64, 64 * 1024);
    defer view.deinit();
    var index: usize = 0;
    while (index < 10) : (index += 1) try view.log.append(.{ .status_change = .{ .state = .working, .source = .structured } });
    try view.rows.build(&view.log, 20, "claude");
    view.settle(4);
    try testing.expectEqual(@as(usize, 6), view.top);
    view.scrollBy(-2, 4);
    try testing.expect(!view.follow);
    try view.log.append(.{ .status_change = .{ .state = .done, .source = .structured } });
    try view.rows.build(&view.log, 20, "claude");
    view.settle(4);
    try testing.expectEqual(@as(usize, 4), view.top);
    view.scrollBy(100, 4);
    try testing.expect(view.follow);
    try testing.expectEqual(@as(usize, 7), view.top);
    view.scrollToTop();
    view.reveal(9, 4);
    try testing.expectEqual(@as(usize, 6), view.top);
    view.scrollToBottom(4);
    try testing.expectEqual(@as(usize, 7), view.top);
}

test "search finds literal matches per row, by case, and bounds its output" {
    var log = try EventLog.init(testing.allocator, 16, 4096);
    defer log.deinit();
    try log.append(.{ .message = .{ .role = .user, .text = "Build the build" } });
    try log.append(.{ .tool_use = .{ .name = "Bash", .summary = "zig build" } });
    var rows = Rows.init(testing.allocator);
    defer rows.deinit();
    try rows.build(&log, 40, "claude");
    var out: [8]Match = undefined;
    const insensitive = findMatches(rows.items, "build", false, &out);
    try testing.expectEqual(@as(usize, 3), insensitive.count);
    try testing.expectEqual(Match{ .row = 0, .col = 6, .cells = 5 }, out[0]);
    try testing.expectEqual(Match{ .row = 0, .col = 16, .cells = 5 }, out[1]);
    try testing.expectEqual(@as(usize, 1), out[2].row);
    const sensitive = findMatches(rows.items, "Build", true, &out);
    try testing.expectEqual(@as(usize, 1), sensitive.count);
    const bounded = findMatches(rows.items, "build", false, out[0..2]);
    try testing.expect(bounded.truncated);
    try testing.expectEqual(@as(usize, 0), findMatches(rows.items, "", false, &out).count);
}
