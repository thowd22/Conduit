//! The backlog view's model (TASK-63, TASK-64): the board and list rows a
//! workspace's `backlog.Project` is shown as, keyboard movement between them,
//! the rows of one task's detail, and the parsing of the view's element ids.
//!
//! A file of `app`, like `agent_view.zig`: it holds no semantic-tree code, so
//! everything here is testable without a window. `main.zig` registers the
//! elements and runs the `backlog` CLI on a worker.
//!
//! Backlog file content is untrusted text (CONDUIT.md §11). Every string a
//! row shows is a sanitised display copy (valid UTF-8, no controls, one line
//! where a row is one line); nothing here derives an action, a path or a
//! command from it. Element ids carry only task ids the parser accepted
//! (`backlog.isTaskId`), so an id never smuggles a second element's suffix.
//!
//! Memory: `build` and `detailRows` allocate in the caller's arena and borrow
//! the project, so their results live until the arena is reset or the project
//! next polls, whichever comes first. `State` owns fixed inline storage.

const std = @import("std");
const backlog = @import("backlog");
const workspace = @import("workspace");
const agent_view = @import("agent_view.zig");

const Allocator = std.mem.Allocator;

/// How the view lays tasks out: a column per status, or one ordinal list.
pub const Mode = enum { board, list };

/// The most board columns: the configured statuses plus any status text a
/// task carries that the config does not name. Further unknown statuses
/// share the last column.
pub const max_columns: usize = 16;

/// The longest task id an element id or a selection holds
/// (`backlog.isTaskId`'s own bound).
pub const max_id_bytes: usize = 64;

/// What a card, a list row and the detail show about the agent working on
/// the task (TASK-64). Borrowed display text from the agent runtime.
pub const AgentBadge = struct {
    /// The configured status icon (`app_agents.statusIcon`, TASK-86), the
    /// same one the sidebar row shows for the state.
    glyph: []const u8,
    harness: []const u8,
    /// The state word the manager shows (`working`, `exited`, ...).
    state: []const u8,
};

/// One task as the board shows it.
pub const Card = struct {
    /// Borrowed from the project; valid until its next poll.
    task: *const backlog.Task,
    /// `<id> <title>`, sanitised to one line.
    label: []const u8,
    /// Labels and assignees, `#ui #board-view  @codex`, sanitised to one
    /// line; empty when the task has neither.
    meta: []const u8,
    /// The board column the card sits in.
    column: usize,
};

/// One board column: a status and its cards in ordinal order.
pub const Column = struct {
    /// The status text, borrowed from the config or (for a status the config
    /// does not name) from a task.
    title: []const u8,
    cards: []const Card,
};

/// The whole view model of one project at one moment.
pub const Board = struct {
    columns: []const Column,
    /// Every card in ordinal order: the list mode's rows.
    list: []const Card,

    /// Where the card of task `id` sits on the board.
    pub fn locate(self: Board, id: []const u8) ?Cursor {
        for (self.columns, 0..) |column, column_index| {
            for (column.cards, 0..) |card, row| {
                if (std.ascii.eqlIgnoreCase(card.task.id, id)) return .{ .column = column_index, .row = row };
            }
        }
        return null;
    }

    /// The list row of task `id`.
    pub fn listIndex(self: Board, id: []const u8) ?usize {
        for (self.list, 0..) |card, index| {
            if (std.ascii.eqlIgnoreCase(card.task.id, id)) return index;
        }
        return null;
    }

    /// The card of task `id`.
    pub fn cardOf(self: Board, id: []const u8) ?*const Card {
        const index = self.listIndex(id) orelse return null;
        return &self.list[index];
    }

    /// Whether the board has no task at all.
    pub fn isEmpty(self: Board) bool {
        return self.list.len == 0;
    }
};

/// A board position.
pub const Cursor = struct { column: usize, row: usize };

/// Build the board and the list of the active tasks (`tasks/`): completed
/// and draft tasks are not on the board, as in Backlog.md's own board.
pub fn build(arena: Allocator, project: *const backlog.Project) Allocator.Error!Board {
    const config = project.config();
    var titles: std.ArrayList([]const u8) = .empty;
    for (config.statuses) |status| {
        if (titles.items.len == max_columns) break;
        try titles.append(arena, status);
    }

    var cards: std.ArrayList(Card) = .empty;
    var iterator = project.tasks();
    while (iterator.next()) |task| {
        if (task.state != .active) continue;
        const column = columnFor(&titles, arena, task.status) catch |err| return err;
        try cards.append(arena, .{
            .task = task,
            .label = try cardLabel(arena, task),
            .meta = try cardMeta(arena, task),
            .column = column,
        });
    }
    std.mem.sort(Card, cards.items, {}, cardLess);

    const columns = try arena.alloc(Column, titles.items.len);
    for (columns, titles.items, 0..) |*column, title, index| {
        var count: usize = 0;
        for (cards.items) |one| {
            if (one.column == index) count += 1;
        }
        const column_cards = try arena.alloc(Card, count);
        var filled: usize = 0;
        for (cards.items) |one| {
            if (one.column != index) continue;
            column_cards[filled] = one;
            filled += 1;
        }
        column.* = .{ .title = title, .cards = column_cards };
    }
    return .{ .columns = columns, .list = cards.items };
}

/// The column of `status`: a configured one, else a column of its own
/// appended after them (the last column once `max_columns` is reached).
fn columnFor(titles: *std.ArrayList([]const u8), arena: Allocator, status: []const u8) Allocator.Error!usize {
    for (titles.items, 0..) |title, index| {
        if (std.mem.eql(u8, title, status)) return index;
    }
    if (titles.items.len == max_columns) return max_columns - 1;
    try titles.append(arena, status);
    return titles.items.len - 1;
}

/// Ordinal first (a task without one after every task with one), then the
/// id in natural order, so `TASK-2` < `TASK-2.1` < `TASK-10`.
fn cardLess(_: void, a: Card, b: Card) bool {
    if (a.task.ordinal) |left| {
        if (b.task.ordinal) |right| {
            if (left != right) return left < right;
        } else return true;
    } else if (b.task.ordinal != null) return false;
    return idLess(a.task.id, b.task.id);
}

/// Natural order of two task ids: the prefix, then each number in turn.
pub fn idLess(a: []const u8, b: []const u8) bool {
    var left = a;
    var right = b;
    while (left.len != 0 and right.len != 0) {
        const left_digit = std.ascii.isDigit(left[0]);
        const right_digit = std.ascii.isDigit(right[0]);
        if (left_digit and right_digit) {
            const left_end = digitRun(left);
            const right_end = digitRun(right);
            const left_number = std.fmt.parseUnsigned(u64, left[0..left_end], 10) catch std.math.maxInt(u64);
            const right_number = std.fmt.parseUnsigned(u64, right[0..right_end], 10) catch std.math.maxInt(u64);
            if (left_number != right_number) return left_number < right_number;
            left = left[left_end..];
            right = right[right_end..];
            continue;
        }
        const l = std.ascii.toLower(left[0]);
        const r = std.ascii.toLower(right[0]);
        if (l != r) return l < r;
        left = left[1..];
        right = right[1..];
    }
    return left.len < right.len;
}

fn digitRun(text: []const u8) usize {
    var end: usize = 0;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    return end;
}

/// A one-line display copy of untrusted text: line breaks and other
/// controls become spaces, malformed UTF-8 becomes U+FFFD.
pub fn oneLine(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    const clean = try agent_view.sanitize(arena, text);
    const copy = try arena.dupe(u8, clean);
    for (copy) |*byte| {
        if (byte.* == '\n') byte.* = ' ';
    }
    return copy;
}

fn cardLabel(arena: Allocator, task: *const backlog.Task) Allocator.Error![]const u8 {
    const raw = try std.fmt.allocPrint(arena, "{s} {s}", .{ task.id, task.title });
    return oneLine(arena, raw);
}

fn cardMeta(arena: Allocator, task: *const backlog.Task) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (task.labels) |label| {
        if (out.items.len != 0) try out.append(arena, ' ');
        try out.append(arena, '#');
        // A label with spaces stays one token on the card.
        for (label) |byte| try out.append(arena, if (byte == ' ') '-' else byte);
    }
    for (task.assignee, 0..) |name, index| {
        if (out.items.len != 0) try out.appendSlice(arena, if (index == 0) "  " else " ");
        try out.appendSlice(arena, name);
    }
    return oneLine(arena, out.items);
}

/// A card's second row: the badge of the agent working on it first
/// (`▸ Fake agent working`), so a narrow column still shows it, then its
/// labels and assignees; written into `buffer` and cut at the last whole
/// character that fits.
pub fn metaWithBadge(buffer: []u8, meta: []const u8, badge: ?AgentBadge) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    if (badge) |shown| {
        writer.print("{s} {s} {s}", .{ shown.glyph, shown.harness, shown.state }) catch {};
        if (meta.len != 0) writer.writeAll("  ") catch {};
    }
    writer.writeAll(meta) catch {};
    var len = writer.end;
    while (len != 0 and !std.unicode.utf8ValidateSlice(buffer[0..len])) len -= 1;
    return buffer[0..len];
}

/// The status after `current` in the configured order, wrapping; the first
/// status when `current` is not configured.
pub fn nextStatus(config: *const backlog.Config, current: []const u8) ?[]const u8 {
    if (config.statuses.len == 0) return null;
    for (config.statuses, 0..) |status, index| {
        if (std.mem.eql(u8, status, current)) return config.statuses[(index + 1) % config.statuses.len];
    }
    return config.statuses[0];
}

// Selection and movement -------------------------------------------------------

/// One keyboard movement.
pub const Motion = enum { left, right, up, down, first, last, page_up, page_down };

/// The view's per-workspace state: the mode, the selected task and how far
/// each column (or the list) is scrolled. The selection follows a task id,
/// never a position, so a reload that reorders the board keeps it.
pub const State = struct {
    mode: Mode = .board,
    selected_bytes: [max_id_bytes]u8 = undefined,
    selected_len: usize = 0,
    /// The column the selection was last in, kept for when its task goes.
    selected_column: usize = 0,
    selected_row: usize = 0,
    /// First visible card of each column.
    scroll: [max_columns]usize = @splat(0),
    /// First visible list row.
    list_scroll: usize = 0,
    /// Whether the scroll follows the selection. The wheel scrolls freely
    /// and clears it; a keyboard move sets it again.
    follow: bool = true,

    pub fn selected(self: *const State) ?[]const u8 {
        if (self.selected_len == 0) return null;
        return self.selected_bytes[0..self.selected_len];
    }

    /// Select task `id`; an id longer than any task id clears the selection.
    pub fn select(self: *State, id: []const u8) void {
        if (id.len > self.selected_bytes.len) {
            self.selected_len = 0;
            return;
        }
        @memcpy(self.selected_bytes[0..id.len], id);
        self.selected_len = id.len;
    }

    /// Re-anchor the selection on `board`: keep its task when it is still
    /// there, else the card now at the remembered position, else nothing.
    pub fn reconcile(self: *State, board: Board) void {
        if (self.selected()) |id| {
            if (board.locate(id)) |cursor| {
                self.selected_column = cursor.column;
                self.selected_row = cursor.row;
                return;
            }
        }
        if (board.isEmpty()) {
            self.selected_len = 0;
            return;
        }
        const column = nearestNonEmpty(board, @min(self.selected_column, board.columns.len -| 1), true) orelse {
            self.selected_len = 0;
            return;
        };
        const cards = board.columns[column].cards;
        self.selectCursor(board, .{ .column = column, .row = @min(self.selected_row, cards.len - 1) });
    }

    fn selectCursor(self: *State, board: Board, cursor: Cursor) void {
        self.select(board.columns[cursor.column].cards[cursor.row].task.id);
        self.selected_column = cursor.column;
        self.selected_row = cursor.row;
    }

    /// Move the selection by `motion`; `page` is how many cards (or rows)
    /// one page holds. Without a selection any motion selects the first card.
    pub fn move(self: *State, board: Board, motion: Motion, page: usize) void {
        self.follow = true;
        if (board.isEmpty()) return;
        const step = @max(page, 1);
        switch (self.mode) {
            .list => {
                const count = board.list.len;
                const current = if (self.selected()) |id| board.listIndex(id) else null;
                const at = current orelse {
                    self.selectListRow(board, 0);
                    return;
                };
                const target: usize = switch (motion) {
                    .up, .left => at -| 1,
                    .down, .right => @min(at + 1, count - 1),
                    .first => 0,
                    .last => count - 1,
                    .page_up => at -| step,
                    .page_down => @min(at + step, count - 1),
                };
                self.selectListRow(board, target);
            },
            .board => {
                const current = if (self.selected()) |id| board.locate(id) else null;
                const at = current orelse {
                    const column = nearestNonEmpty(board, 0, true) orelse return;
                    self.selectCursor(board, .{ .column = column, .row = 0 });
                    return;
                };
                const cards = board.columns[at.column].cards;
                switch (motion) {
                    .up => self.selectCursor(board, .{ .column = at.column, .row = at.row -| 1 }),
                    .down => self.selectCursor(board, .{ .column = at.column, .row = @min(at.row + 1, cards.len - 1) }),
                    .first => self.selectCursor(board, .{ .column = at.column, .row = 0 }),
                    .last => self.selectCursor(board, .{ .column = at.column, .row = cards.len - 1 }),
                    .page_up => self.selectCursor(board, .{ .column = at.column, .row = at.row -| step }),
                    .page_down => self.selectCursor(board, .{ .column = at.column, .row = @min(at.row + step, cards.len - 1) }),
                    .left, .right => {
                        const forward = motion == .right;
                        if (forward and at.column + 1 >= board.columns.len) return;
                        if (!forward and at.column == 0) return;
                        const start = if (forward) at.column + 1 else at.column - 1;
                        const column = nearestNonEmpty(board, start, forward) orelse return;
                        const target = board.columns[column].cards;
                        self.selectCursor(board, .{ .column = column, .row = @min(at.row, target.len - 1) });
                    },
                }
            },
        }
    }

    fn selectListRow(self: *State, board: Board, index: usize) void {
        const one = board.list[index];
        self.select(one.task.id);
        if (board.locate(one.task.id)) |cursor| {
            self.selected_column = cursor.column;
            self.selected_row = cursor.row;
        }
    }
};

/// The first column from `start` (inclusive) in direction `forward` that has
/// a card.
fn nearestNonEmpty(board: Board, start: usize, forward: bool) ?usize {
    if (board.columns.len == 0) return null;
    var index = @min(start, board.columns.len - 1);
    while (true) {
        if (board.columns[index].cards.len != 0) return index;
        if (forward) {
            index += 1;
            if (index >= board.columns.len) return null;
        } else {
            if (index == 0) return null;
            index -= 1;
        }
    }
}

/// Scroll `top` so row `index` of `total` shows in `visible` rows.
pub fn keepVisible(top: *usize, index: usize, total: usize, visible: usize) void {
    if (visible == 0) return;
    if (index < top.*) top.* = index;
    if (index >= top.* + visible) top.* = index + 1 - visible;
    const last_start = total -| visible;
    if (top.* > last_start) top.* = last_start;
}

// The detail -------------------------------------------------------------------

/// What activating a detail row does.
pub const Target = union(enum) {
    none,
    /// Cycle the status through the configured ones.
    status,
    /// Toggle acceptance criterion `index` (its `#N`).
    criterion: struct { index: u32, checked: bool },
};

pub const RowKind = enum { title, field, heading, body, criterion, blank };

/// One row of the detail, already wrapped to the detail's width.
pub const DetailRow = struct {
    kind: RowKind,
    text: []const u8,
    /// Only a row's first line is actionable; its continuation rows are not.
    target: Target = .none,

    pub fn actionable(self: DetailRow) bool {
        return self.target != .none;
    }
};

/// The rows of task `task`'s detail, wrapped to `width` cells: title, the
/// fields, the agent working on it, description, acceptance criteria and
/// notes. The status row and each criterion's first row are actionable; the
/// detail's two actions (start an agent, open in vi) are fixed controls of
/// the view, not rows, so they never scroll away. `milestone_title` is the
/// resolved milestone's title when the project has it.
pub fn detailRows(
    arena: Allocator,
    task: *const backlog.Task,
    milestone_title: ?[]const u8,
    width: u32,
    badge: ?AgentBadge,
) Allocator.Error![]const DetailRow {
    var rows: std.ArrayList(DetailRow) = .empty;
    const room = @max(width, 8);
    try wrapInto(arena, &rows, .title, try std.fmt.allocPrint(arena, "{s} {s}", .{ task.id, task.title }), room, .none);
    try rows.append(arena, .{ .kind = .field, .text = try oneLine(arena, try std.fmt.allocPrint(arena, "Status     {s}  ›", .{task.status})), .target = .status });
    if (task.priority) |priority| try field(arena, &rows, "Priority", @tagName(priority), room);
    try field(arena, &rows, "Assignee", try joined(arena, task.assignee, ", "), room);
    try field(arena, &rows, "Labels", try joined(arena, task.labels, ", "), room);
    if (task.milestone) |milestone| {
        const text = if (milestone_title) |title| try std.fmt.allocPrint(arena, "{s} ({s})", .{ milestone, title }) else milestone;
        try field(arena, &rows, "Milestone", text, room);
    }
    try field(arena, &rows, "Depends on", try joined(arena, task.dependencies, ", "), room);
    if (task.parent) |parent| try field(arena, &rows, "Parent", parent, room);
    if (badge) |shown| {
        try field(arena, &rows, "Agent", try std.fmt.allocPrint(arena, "{s} {s} {s}", .{ shown.glyph, shown.harness, shown.state }), room);
    }
    if (task.description) |description| {
        try section(arena, &rows, "Description", description, room);
    }
    if (task.acceptance_criteria.len != 0) {
        try rows.append(arena, .{ .kind = .blank, .text = "" });
        try rows.append(arena, .{ .kind = .heading, .text = "Acceptance criteria" });
        for (task.acceptance_criteria) |criterion| {
            const text = try std.fmt.allocPrint(arena, "[{s}] #{d} {s}", .{ if (criterion.checked) "x" else " ", criterion.index, criterion.text });
            try wrapInto(arena, &rows, .criterion, text, room, .{ .criterion = .{ .index = criterion.index, .checked = criterion.checked } });
        }
    }
    if (task.notes) |notes| try section(arena, &rows, "Notes", notes, room);
    return rows.items;
}

fn joined(arena: Allocator, items: []const []const u8, separator: []const u8) Allocator.Error![]const u8 {
    if (items.len == 0) return "–";
    return std.mem.join(arena, separator, items);
}

fn field(arena: Allocator, rows: *std.ArrayList(DetailRow), name: []const u8, value: []const u8, room: u32) Allocator.Error!void {
    const text = try std.fmt.allocPrint(arena, "{s: <10} {s}", .{ name, value });
    try wrapInto(arena, rows, .field, text, room, .none);
}

fn section(arena: Allocator, rows: *std.ArrayList(DetailRow), heading: []const u8, body: []const u8, room: u32) Allocator.Error!void {
    try rows.append(arena, .{ .kind = .blank, .text = "" });
    try rows.append(arena, .{ .kind = .heading, .text = heading });
    try wrapInto(arena, rows, .body, body, room, .none);
}

/// Wrap untrusted `text` into rows of at most `room` cells. Only the first
/// row carries `target`.
fn wrapInto(arena: Allocator, rows: *std.ArrayList(DetailRow), kind: RowKind, text: []const u8, room: u32, target: Target) Allocator.Error!void {
    const clean = try agent_view.sanitize(arena, text);
    var first = true;
    var lines = std.mem.splitScalar(u8, clean, '\n');
    while (lines.next()) |line| {
        var rest = line;
        while (true) {
            const cut = wrapCut(rest, room);
            try rows.append(arena, .{ .kind = kind, .text = rest[0..cut.end], .target = if (first) target else .none });
            first = false;
            rest = rest[cut.next..];
            if (rest.len == 0) break;
        }
    }
}

const Cut = struct { end: usize, next: usize };

/// Where to cut valid UTF-8 `text` to fit `room` cells: at the last space
/// that fits, or inside the word when none does; always at least one
/// codepoint, so a narrow detail still progresses.
fn wrapCut(text: []const u8, room: u32) Cut {
    if (agent_view.displayCells(text) <= room) return .{ .end = text.len, .next = text.len };
    const hard = agent_view.byteAtCell(text, room);
    // The codepoint that does not fit is the break itself.
    if (hard != 0 and hard < text.len and text[hard] == ' ') return .{ .end = hard, .next = hard + 1 };
    if (std.mem.lastIndexOfScalar(u8, text[0..hard], ' ')) |space| {
        if (space != 0) return .{ .end = space, .next = space + 1 };
    }
    if (hard == 0) {
        const first = std.unicode.utf8ByteSequenceLength(text[0]) catch 1;
        return .{ .end = @min(first, text.len), .next = @min(first, text.len) };
    }
    return .{ .end = hard, .next = hard };
}

// Element ids ------------------------------------------------------------------

/// What one of the view's element ids names.
pub const Element = union(enum) {
    /// `backlog.task.<id>`: a card or list row.
    task: []const u8,
    /// `backlog.mode.board` / `backlog.mode.list`.
    mode: Mode,
    /// `backlog.close`.
    close,
    /// `backlog.detail.<id>.<part>`.
    detail: struct { id: []const u8, part: DetailPart },
};

/// A part of the detail.
pub const DetailPart = union(enum) {
    status,
    criterion: u32,
    agent,
    raw,
    close,
    back,
    /// `harness.<n>`: the n-th harness of the start-agent chooser.
    harness: usize,
};

/// Parse one of the view's element ids. Anything else, or an id whose task
/// part is not a task id, is null.
pub fn parseElement(id: []const u8) ?Element {
    if (std.mem.eql(u8, id, "backlog.mode.board")) return .{ .mode = .board };
    if (std.mem.eql(u8, id, "backlog.mode.list")) return .{ .mode = .list };
    if (std.mem.eql(u8, id, "backlog.close")) return .close;
    const task_prefix = "backlog.task.";
    if (std.mem.startsWith(u8, id, task_prefix)) {
        const rest = id[task_prefix.len..];
        const task_id = leadingTaskId(rest) orelse return null;
        if (task_id.len != rest.len) return null;
        return .{ .task = task_id };
    }
    const detail_prefix = "backlog.detail.";
    if (!std.mem.startsWith(u8, id, detail_prefix)) return null;
    const rest = id[detail_prefix.len..];
    const task_id = leadingTaskId(rest) orelse return null;
    if (task_id.len == rest.len or rest[task_id.len] != '.') return null;
    const part = rest[task_id.len + 1 ..];
    const parsed: DetailPart = if (std.mem.eql(u8, part, "status"))
        .status
    else if (std.mem.eql(u8, part, "agent"))
        .agent
    else if (std.mem.eql(u8, part, "raw"))
        .raw
    else if (std.mem.eql(u8, part, "close"))
        .close
    else if (std.mem.eql(u8, part, "back"))
        .back
    else if (numberAfter(part, "ac.")) |index|
        .{ .criterion = std.math.cast(u32, index) orelse return null }
    else if (numberAfter(part, "harness.")) |index|
        .{ .harness = index }
    else
        return null;
    return .{ .detail = .{ .id = task_id, .part = parsed } };
}

/// The task id at the start of `text`: a letter-led prefix, a dash, a number
/// and any `.N` subtask numbers, stopping before a `.` that is not followed
/// by a digit.
fn leadingTaskId(text: []const u8) ?[]const u8 {
    const dash = std.mem.indexOfScalar(u8, text, '-') orelse return null;
    var end = dash + 1;
    while (true) {
        const start = end;
        while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
        if (end == start) return null;
        if (end + 1 < text.len and text[end] == '.' and std.ascii.isDigit(text[end + 1])) {
            end += 1;
            continue;
        }
        break;
    }
    const candidate = text[0..end];
    if (!backlog.isTaskId(candidate)) return null;
    return candidate;
}

fn numberAfter(text: []const u8, prefix: []const u8) ?usize {
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    const digits = text[prefix.len..];
    if (digits.len == 0 or digits.len > 9) return null;
    return std.fmt.parseUnsigned(usize, digits, 10) catch null;
}

// Writes and the per-workspace panel -------------------------------------------

/// One write the view asks the `backlog` CLI for. Values are copied, so a
/// queued request owns everything it needs.
pub const CliRequest = struct {
    kind: Kind,
    id_bytes: [max_id_bytes]u8 = undefined,
    id_len: usize = 0,
    value_bytes: [backlog.Cli.max_value_bytes]u8 = undefined,
    value_len: usize = 0,
    index: u32 = 0,

    pub const Kind = enum { status, check, uncheck };

    pub fn id(self: *const CliRequest) []const u8 {
        return self.id_bytes[0..self.id_len];
    }

    pub fn value(self: *const CliRequest) []const u8 {
        return self.value_bytes[0..self.value_len];
    }

    /// `backlog task edit <id> --status=<status>`, or null for an id or
    /// value that does not fit (the CLI wrapper validates them again).
    pub fn status(task_id: []const u8, new_status: []const u8) ?CliRequest {
        if (task_id.len > max_id_bytes or new_status.len > backlog.Cli.max_value_bytes) return null;
        var request: CliRequest = .{ .kind = .status };
        @memcpy(request.id_bytes[0..task_id.len], task_id);
        request.id_len = task_id.len;
        @memcpy(request.value_bytes[0..new_status.len], new_status);
        request.value_len = new_status.len;
        return request;
    }

    /// Check (or uncheck) acceptance criterion `index` of `task_id`.
    pub fn criterion(task_id: []const u8, index: u32, checked: bool) ?CliRequest {
        if (task_id.len > max_id_bytes or index == 0) return null;
        var request: CliRequest = .{ .kind = if (checked) .check else .uncheck, .index = index };
        @memcpy(request.id_bytes[0..task_id.len], task_id);
        request.id_len = task_id.len;
        return request;
    }

    /// What the view says while the request runs and once it succeeded.
    pub fn describe(self: *const CliRequest, buffer: []u8, done: bool) []const u8 {
        const text = switch (self.kind) {
            .status => std.fmt.bufPrint(buffer, "{s} → {s}{s}", .{ self.id(), self.value(), if (done) "" else " …" }),
            .check, .uncheck => std.fmt.bufPrint(buffer, "{s} #{d} {s}{s}", .{
                self.id(),
                self.index,
                if (self.kind == .check) "checked" else "unchecked",
                if (done) "" else " …",
            }),
        } catch return self.id();
        return text;
    }
};

/// How one CLI call ended, as the view reports it.
pub const CliResult = union(enum) {
    ok,
    /// The CLI ran and failed; the message is the first line of its stderr,
    /// cleaned for display.
    failed: Failure,
    /// No `backlog` program in the workspace's context.
    unavailable,
    /// The call could not complete (`error.Timeout` and the like).
    broken: anyerror,

    pub const Failure = struct {
        exit_code: ?u8,
        message_bytes: [160]u8 = undefined,
        message_len: usize = 0,

        pub fn message(self: *const Failure) []const u8 {
            return self.message_bytes[0..self.message_len];
        }
    };
};

/// Called on the worker when a job finishes, so a blocked event loop wakes.
pub const Wake = struct {
    context: ?*anyopaque = null,
    wake_fn: ?*const fn (?*anyopaque) void = null,

    fn call(self: Wake) void {
        if (self.wake_fn) |wake| wake(self.context);
    }
};

/// One `backlog` CLI call on a short-lived worker thread (the CLI waits for
/// its child, so it never runs on the render thread).
///
/// Threads: the owner starts it and later calls `finished` and `finish`; the
/// worker writes only `result`, then publishes `done`. The context must
/// outlive the job, which `Panel.deinit` guarantees by joining it.
pub const CliJob = struct {
    allocator: Allocator,
    io: std.Io,
    context: workspace.ExecutionContext.Ref,
    /// Owned copies.
    project_dir: []u8,
    program: []u8,
    request: CliRequest,
    wake: Wake,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    result: CliResult = .ok,

    pub fn start(
        allocator: Allocator,
        io: std.Io,
        context: workspace.ExecutionContext.Ref,
        project_dir: []const u8,
        program: []const u8,
        request: CliRequest,
        wake: Wake,
    ) !*CliJob {
        const job = try allocator.create(CliJob);
        errdefer allocator.destroy(job);
        const dir = try allocator.dupe(u8, project_dir);
        errdefer allocator.free(dir);
        const owned_program = try allocator.dupe(u8, program);
        errdefer allocator.free(owned_program);
        job.* = .{
            .allocator = allocator,
            .io = io,
            .context = context,
            .project_dir = dir,
            .program = owned_program,
            .request = request,
            .wake = wake,
        };
        job.thread = try std.Thread.spawn(.{}, work, .{job});
        return job;
    }

    fn work(self: *CliJob) void {
        self.result = self.run();
        self.done.store(true, .release);
        self.wake.call();
    }

    fn run(self: *CliJob) CliResult {
        const cli: backlog.Cli = .{
            .allocator = self.allocator,
            .io = self.io,
            .context = self.context,
            .project_dir = self.project_dir,
            .program = self.program,
        };
        const request = &self.request;
        var outcome = switch (request.kind) {
            .status => cli.setStatus(request.id(), request.value()),
            .check => cli.checkAcceptance(request.id(), request.index, true),
            .uncheck => cli.checkAcceptance(request.id(), request.index, false),
        } catch |err| return switch (err) {
            error.CliUnavailable => .unavailable,
            else => .{ .broken = err },
        };
        defer outcome.deinit(self.allocator);
        switch (outcome) {
            .ok => return .ok,
            .failed => |failure| {
                var result: CliResult.Failure = .{ .exit_code = failure.exit_code };
                const text = failure.message();
                const line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
                result.message_len = copyDisplay(&result.message_bytes, line);
                return .{ .failed = result };
            },
        }
    }

    pub fn finished(self: *const CliJob) bool {
        return self.done.load(.acquire);
    }

    /// Join the worker, release the job and return its result.
    pub fn finish(self: *CliJob) CliResult {
        if (self.thread) |thread| thread.join();
        const result = self.result;
        self.allocator.free(self.project_dir);
        self.allocator.free(self.program);
        self.allocator.destroy(self);
        return result;
    }
};

/// Copy untrusted `text` into `out` as one display line: controls become
/// spaces, malformed UTF-8 is cut, and the copy ends on a whole character.
fn copyDisplay(out: []u8, text: []const u8) usize {
    var len = @min(out.len, text.len);
    @memcpy(out[0..len], text[0..len]);
    for (out[0..len]) |*byte| {
        if (byte.* < 0x20 or byte.* == 0x7f) byte.* = ' ';
    }
    while (len != 0 and !std.unicode.utf8ValidateSlice(out[0..len])) len -= 1;
    return len;
}

/// Why a panel has no project to show.
pub const Problem = enum {
    /// The workspace's directory has no `backlog/`.
    missing,
    /// The workspace is not Local. A remote context's reads block on its
    /// connection, so they belong on a worker, which this view does not
    /// have yet.
    remote,
    /// The directory could not be read.
    unreadable,

    pub fn text(self: Problem) []const u8 {
        return switch (self) {
            .missing => "no backlog/ here",
            .remote => "the backlog view reads Local workspaces only for now",
            .unreadable => "backlog/ could not be read",
        };
    }
};

/// The open task detail: which task, its scroll and keyboard cursor, and
/// whether it is choosing a harness for a new agent.
pub const Detail = struct {
    id_bytes: [max_id_bytes]u8 = undefined,
    id_len: usize = 0,
    /// First visible row.
    scroll: usize = 0,
    /// Index among the actionable rows.
    cursor: usize = 0,
    choosing: bool = false,
    choice: usize = 0,
    /// Whether the scroll follows the cursor (see `State.follow`).
    follow: bool = true,

    pub fn id(self: *const Detail) []const u8 {
        return self.id_bytes[0..self.id_len];
    }

    pub fn of(task_id: []const u8) ?Detail {
        if (task_id.len > max_id_bytes) return null;
        var detail: Detail = .{};
        @memcpy(detail.id_bytes[0..task_id.len], task_id);
        detail.id_len = task_id.len;
        return detail;
    }
};

/// One workspace's backlog view: open or not, the loaded project and its
/// board, the selection and detail, and the CLI writes in flight.
///
/// Thread ownership: the main thread. The project is loaded and polled there
/// (Local contexts only, whose reads are local file reads); writes run on a
/// `CliJob` worker, one at a time, from a bounded queue.
pub const Panel = struct {
    allocator: Allocator,
    io: std.Io,
    wake: Wake,
    open: bool = false,
    project: ?backlog.Project = null,
    problem: ?Problem = null,
    board_arena: std.heap.ArenaAllocator,
    board: Board = .{ .columns = &.{}, .list = &.{} },
    /// Bumped whenever the board is rebuilt from the project.
    generation: u64 = 0,
    state: State = .{},
    detail: ?Detail = null,
    message_bytes: [256]u8 = undefined,
    message_len: usize = 0,
    /// Whether the message reports a failure (shown in the attention colour).
    message_failed: bool = false,
    queue: [queue_capacity]CliRequest = undefined,
    queue_len: usize = 0,
    job: ?*CliJob = null,
    /// The workspace context the writes run in; set by `load`.
    context: ?workspace.ExecutionContext.Ref = null,
    project_dir_bytes: [std.fs.max_path_bytes]u8 = undefined,
    project_dir_len: usize = 0,

    pub const queue_capacity = 4;

    pub fn init(allocator: Allocator, io: std.Io, wake: Wake) Panel {
        return .{ .allocator = allocator, .io = io, .wake = wake, .board_arena = .init(allocator) };
    }

    /// Join any write in flight and release the project.
    pub fn deinit(self: *Panel) void {
        if (self.job) |job| _ = job.finish();
        self.job = null;
        self.unload();
        self.board_arena.deinit();
        self.* = undefined;
    }

    /// Read the project at `root` (a `backlog/` directory) through `context`
    /// and watch it. A missing directory is `Problem.missing`, not an error.
    pub fn load(self: *Panel, context: workspace.ExecutionContext.Ref, root: []const u8) Allocator.Error!void {
        self.unload();
        self.context = context;
        self.problem = null;
        var project = backlog.Project.load(self.allocator, self.io, context, root, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotABacklog => {
                self.problem = .missing;
                return;
            },
            error.Unsupported, error.Unavailable => {
                self.problem = .unreadable;
                return;
            },
        };
        project.watch() catch |err| switch (err) {
            // Without watches `poll` compares every file; still live.
            error.Unsupported, error.Unavailable => {},
            error.OutOfMemory => {
                project.deinit();
                return error.OutOfMemory;
            },
        };
        const dir = project.projectDirectory();
        if (dir.len <= self.project_dir_bytes.len) {
            @memcpy(self.project_dir_bytes[0..dir.len], dir);
            self.project_dir_len = dir.len;
        }
        self.project = project;
        try self.rebuild();
    }

    /// Forget the project (the view closed). Queued writes still run.
    pub fn unload(self: *Panel) void {
        if (self.project) |*project| project.deinit();
        self.project = null;
        self.board = .{ .columns = &.{}, .list = &.{} };
        _ = self.board_arena.reset(.retain_capacity);
    }

    /// The directory that contains `backlog/`: where the CLI runs.
    pub fn projectDirectory(self: *const Panel) ?[]const u8 {
        if (self.project_dir_len == 0) return null;
        return self.project_dir_bytes[0..self.project_dir_len];
    }

    fn rebuild(self: *Panel) Allocator.Error!void {
        _ = self.board_arena.reset(.retain_capacity);
        self.board = .{ .columns = &.{}, .list = &.{} };
        const project = if (self.project) |*loaded| loaded else return;
        self.board = try build(self.board_arena.allocator(), project);
        self.state.reconcile(self.board);
        self.generation +%= 1;
    }

    pub fn message(self: *const Panel) ?[]const u8 {
        if (self.message_len == 0) return null;
        return self.message_bytes[0..self.message_len];
    }

    pub fn setMessage(self: *Panel, failed: bool, comptime format: []const u8, args: anytype) void {
        var writer: std.Io.Writer = .fixed(&self.message_bytes);
        writer.print(format, args) catch {
            // A message cut by the fixed buffer is still its start.
        };
        var len = writer.end;
        while (len != 0 and !std.unicode.utf8ValidateSlice(self.message_bytes[0..len])) len -= 1;
        self.message_len = len;
        self.message_failed = failed;
    }

    /// Queue one write; it runs after the ones before it. `program` is the
    /// CLI to run, normally `backlog` on the context's PATH.
    pub fn enqueue(self: *Panel, request: CliRequest, program: []const u8) error{QueueFull}!void {
        if (self.queue_len == self.queue.len) return error.QueueFull;
        self.queue[self.queue_len] = request;
        self.queue_len += 1;
        var buffer: [192]u8 = undefined;
        self.setMessage(false, "{s}", .{request.describe(&buffer, false)});
        self.startNext(program);
    }

    fn startNext(self: *Panel, program: []const u8) void {
        if (self.job != null or self.queue_len == 0) return;
        const context = self.context orelse return;
        const dir = self.projectDirectory() orelse return;
        const request = self.queue[0];
        std.mem.copyForwards(CliRequest, self.queue[0 .. self.queue_len - 1], self.queue[1..self.queue_len]);
        self.queue_len -= 1;
        self.job = CliJob.start(self.allocator, self.io, context, dir, program, request, self.wake) catch |err| {
            self.setMessage(true, "backlog: the write did not start ({s})", .{@errorName(err)});
            return;
        };
    }

    /// Collect a finished write and bring the board up to date with the
    /// files. Returns whether anything the view shows changed.
    pub fn poll(self: *Panel, program: []const u8) Allocator.Error!bool {
        var changed = false;
        if (self.job) |job| {
            if (job.finished()) {
                const request = job.request;
                const result = job.finish();
                self.job = null;
                self.report(&request, &result);
                changed = true;
                self.startNext(program);
            }
        }
        if (self.project) |*project| {
            var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena_state.deinit();
            const changes = try project.poll(arena_state.allocator());
            if (changes.len != 0) {
                try self.rebuild();
                changed = true;
            }
        }
        return changed;
    }

    fn report(self: *Panel, request: *const CliRequest, result: *const CliResult) void {
        var buffer: [192]u8 = undefined;
        switch (result.*) {
            .ok => self.setMessage(false, "{s}", .{request.describe(&buffer, true)}),
            .failed => |*failure| if (failure.exit_code) |code|
                self.setMessage(true, "backlog failed ({d}): {s}", .{ code, failure.message() })
            else
                self.setMessage(true, "backlog failed: {s}", .{failure.message()}),
            .unavailable => self.setMessage(true, "backlog CLI not found: the view is read-only", .{}),
            .broken => |err| self.setMessage(true, "backlog: {s}", .{@errorName(err)}),
        }
    }

    /// Whether a write is running or waiting.
    pub fn busy(self: *const Panel) bool {
        return self.job != null or self.queue_len != 0;
    }
};

// Tests ------------------------------------------------------------------------

const testing = std.testing;

fn loadFixture(context: *workspace.ExecutionContext) !backlog.Project {
    return backlog.Project.load(testing.allocator, testing.io, context.borrow(), "test/fixtures/backlog/valid", .{});
}

test "the valid fixture builds a board column per configured status in ordinal order" {
    var context = try workspace.ExecutionContext.local(testing.allocator);
    defer context.deinit();
    var project = try loadFixture(&context);
    defer project.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const board = try build(arena_state.allocator(), &project);

    try testing.expectEqual(@as(usize, 4), board.columns.len);
    try testing.expectEqualStrings("To Do", board.columns[0].title);
    try testing.expectEqualStrings("In Progress", board.columns[1].title);
    try testing.expectEqualStrings("Review", board.columns[2].title);
    try testing.expectEqualStrings("Done", board.columns[3].title);
    // Only the active tasks: the completed TASK-3 and the draft are not cards.
    try testing.expectEqual(@as(usize, 3), board.list.len);
    try testing.expectEqual(@as(usize, 1), board.columns[0].cards.len);
    try testing.expectEqualStrings("TASK-1", board.columns[0].cards[0].task.id);
    try testing.expectEqualStrings("TASK-2", board.columns[1].cards[0].task.id);
    try testing.expectEqualStrings("TASK-2.1", board.columns[2].cards[0].task.id);
    try testing.expectEqual(@as(usize, 0), board.columns[3].cards.len);

    // The list is ordinal order across columns.
    try testing.expectEqualStrings("TASK-1", board.list[0].task.id);
    try testing.expectEqualStrings("TASK-2", board.list[1].task.id);
    try testing.expectEqualStrings("TASK-2.1", board.list[2].task.id);

    // Labels: one line, folded titles joined, labels then assignees.
    try testing.expectEqualStrings("TASK-1 First task: parse the model", board.list[0].label);
    try testing.expectEqualStrings("#backlog #architecture  @codex @claude", board.list[0].meta);
    try testing.expectEqualStrings("TASK-2 A long title that the backlog tool folded across two lines", board.list[1].label);
    try testing.expectEqualStrings("#ui #board-view", board.list[1].meta);
    try testing.expectEqualStrings("", board.list[2].meta);
    try testing.expectEqual(Cursor{ .column = 2, .row = 0 }, board.locate("task-2.1").?);
}

fn fakeTask(id: []const u8, status: []const u8, ordinal: ?f64) backlog.Task {
    return .{ .id = id, .title = "t", .status = status, .ordinal = ordinal, .path = "", .state = .active };
}

test "unknown statuses get their own columns and ids sort naturally" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var titles: std.ArrayList([]const u8) = .empty;
    try titles.appendSlice(arena, &.{ "To Do", "Done" });
    try testing.expectEqual(@as(usize, 1), try columnFor(&titles, arena, "Done"));
    try testing.expectEqual(@as(usize, 2), try columnFor(&titles, arena, "Blocked"));
    try testing.expectEqual(@as(usize, 2), try columnFor(&titles, arena, "Blocked"));
    try testing.expectEqual(@as(usize, 3), titles.items.len);

    try testing.expect(idLess("TASK-2", "TASK-10"));
    try testing.expect(idLess("TASK-2", "TASK-2.1"));
    try testing.expect(idLess("TASK-2.1", "TASK-2.10"));
    try testing.expect(!idLess("TASK-10", "TASK-9"));
    try testing.expect(idLess("DRAFT-1", "TASK-1"));

    const a = fakeTask("TASK-9", "To Do", 5);
    const b = fakeTask("TASK-1", "To Do", null);
    const c = fakeTask("TASK-3", "To Do", 5);
    const card = struct {
        fn of(task: *const backlog.Task) Card {
            return .{ .task = task, .label = "", .meta = "", .column = 0 };
        }
    }.of;
    var cards = [_]Card{ card(&b), card(&a), card(&c) };
    std.mem.sort(Card, &cards, {}, cardLess);
    try testing.expectEqualStrings("TASK-3", cards[0].task.id);
    try testing.expectEqualStrings("TASK-9", cards[1].task.id);
    try testing.expectEqualStrings("TASK-1", cards[2].task.id);
}

test "movement crosses columns, skips empty ones and follows the task id" {
    var context = try workspace.ExecutionContext.local(testing.allocator);
    defer context.deinit();
    var project = try loadFixture(&context);
    defer project.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const board = try build(arena_state.allocator(), &project);

    var state: State = .{};
    state.move(board, .down, 1);
    try testing.expectEqualStrings("TASK-1", state.selected().?);
    state.move(board, .right, 1);
    try testing.expectEqualStrings("TASK-2", state.selected().?);
    state.move(board, .right, 1);
    try testing.expectEqualStrings("TASK-2.1", state.selected().?);
    // Done is empty: Right stays put.
    state.move(board, .right, 1);
    try testing.expectEqualStrings("TASK-2.1", state.selected().?);
    state.move(board, .left, 1);
    state.move(board, .left, 1);
    try testing.expectEqualStrings("TASK-1", state.selected().?);
    state.move(board, .left, 1);
    try testing.expectEqualStrings("TASK-1", state.selected().?);

    state.mode = .list;
    state.move(board, .last, 4);
    try testing.expectEqualStrings("TASK-2.1", state.selected().?);
    state.move(board, .page_up, 4);
    try testing.expectEqualStrings("TASK-1", state.selected().?);
    state.move(board, .down, 4);
    try testing.expectEqualStrings("TASK-2", state.selected().?);

    // A task that went keeps the position.
    state.select("TASK-77");
    state.selected_column = 1;
    state.selected_row = 4;
    state.reconcile(board);
    try testing.expectEqualStrings("TASK-2", state.selected().?);

    var top: usize = 0;
    keepVisible(&top, 7, 10, 3);
    try testing.expectEqual(@as(usize, 5), top);
    keepVisible(&top, 1, 10, 3);
    try testing.expectEqual(@as(usize, 1), top);
}

test "the detail wraps the task and marks its controls" {
    var context = try workspace.ExecutionContext.local(testing.allocator);
    defer context.deinit();
    var project = try loadFixture(&context);
    defer project.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const task = project.findTask("TASK-1").?;
    const rows = try detailRows(arena_state.allocator(), task, "M1 - First", 24, .{ .glyph = "●", .harness = "Fake agent", .state = "working" });

    try testing.expectEqualStrings("TASK-1 First task: parse", rows[0].text);
    try testing.expectEqualStrings("the model", rows[1].text);
    var status_rows: usize = 0;
    var criteria: [3]Target = undefined;
    var criterion_count: usize = 0;
    var saw_agent_field = false;
    for (rows) |row| {
        try testing.expect(agent_view.displayCells(row.text) <= 24);
        switch (row.target) {
            .status => status_rows += 1,
            .criterion => {
                criteria[criterion_count] = row.target;
                criterion_count += 1;
            },
            .none => {},
        }
        if (std.mem.startsWith(u8, row.text, "Agent") and std.mem.indexOf(u8, row.text, "● Fake agent") != null) saw_agent_field = true;
    }
    try testing.expectEqual(@as(usize, 1), status_rows);
    try testing.expectEqual(@as(usize, 3), criterion_count);
    try testing.expectEqual(@as(u32, 2), criteria[1].criterion.index);
    try testing.expect(criteria[1].criterion.checked);
    try testing.expect(!criteria[0].criterion.checked);
    try testing.expect(saw_agent_field);

    // Untrusted controls never reach a row.
    var hostile = fakeTask("TASK-5", "To Do", null);
    hostile.title = "bad\x1b[2Jtitle";
    hostile.description = "line\x07one\r\nline two";
    const hostile_rows = try detailRows(arena_state.allocator(), &hostile, null, 40, null);
    for (hostile_rows) |row| {
        for (row.text) |byte| try testing.expect(byte >= 0x20 or byte == '\t');
    }
}

test "status cycles through the configured order" {
    const config: backlog.Config = .{ .statuses = &.{ "To Do", "In Progress", "Done" } };
    try testing.expectEqualStrings("In Progress", nextStatus(&config, "To Do").?);
    try testing.expectEqualStrings("To Do", nextStatus(&config, "Done").?);
    try testing.expectEqualStrings("To Do", nextStatus(&config, "Blocked").?);
    const empty: backlog.Config = .{ .statuses = &.{} };
    try testing.expect(nextStatus(&empty, "To Do") == null);
}

test "a card's second row ends with the agent working on it" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("● Fake agent working  #ui", metaWithBadge(&buffer, "#ui", .{ .glyph = "●", .harness = "Fake agent", .state = "working" }));
    try testing.expectEqualStrings("● Pi waiting", metaWithBadge(&buffer, "", .{ .glyph = "●", .harness = "Pi", .state = "waiting" }));
    try testing.expectEqualStrings("#ui", metaWithBadge(&buffer, "#ui", null));
    var small: [7]u8 = undefined;
    // Cut on a character boundary: `…` is three bytes.
    try testing.expectEqualStrings("● x y", metaWithBadge(&small, "#ui", .{ .glyph = "●", .harness = "x", .state = "y…" }));
}

test "element ids parse back to their targets and reject smuggled suffixes" {
    try testing.expectEqualStrings("TASK-2.1", parseElement("backlog.task.TASK-2.1").?.task);
    try testing.expectEqual(Mode.list, parseElement("backlog.mode.list").?.mode);
    try testing.expect(parseElement("backlog.close").? == .close);
    const ac = parseElement("backlog.detail.TASK-2.1.ac.3").?.detail;
    try testing.expectEqualStrings("TASK-2.1", ac.id);
    try testing.expectEqual(@as(u32, 3), ac.part.criterion);
    try testing.expect(parseElement("backlog.detail.TASK-1.status").?.detail.part == .status);
    try testing.expect(parseElement("backlog.detail.TASK-1.agent").?.detail.part == .agent);
    try testing.expect(parseElement("backlog.detail.TASK-1.raw").?.detail.part == .raw);
    try testing.expectEqual(@as(usize, 2), parseElement("backlog.detail.DRAFT-3.harness.2").?.detail.part.harness);
    for ([_][]const u8{
        "backlog.task.",
        "backlog.task.TASK-1.ac.1",
        "backlog.task.--force",
        "backlog.detail.TASK-1",
        "backlog.detail.TASK-1.",
        "backlog.detail.TASK-1.ac.",
        "backlog.detail.TASK-1.ac.x",
        "backlog.detail.TASK-01.status",
        "backlog.detail.TASK-1.unknown",
        "backlog.view",
    }) |id| try testing.expect(parseElement(id) == null);
}

/// Poll `panel` until its writes are done and one more poll has seen their
/// files: the worker joins, then the watch reports what it changed.
fn settle(panel: *Panel, program: []const u8) !void {
    var rounds: usize = 0;
    while (panel.busy()) : (rounds += 1) {
        if (rounds > 2_000_000) return error.TestTimedOut;
        _ = try panel.poll(program);
        std.Thread.yield() catch {};
    }
    _ = try panel.poll(program);
}

test "a panel runs a write on a worker, reports it and reloads what it changed" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buffer[0..try tmp.dir.realPath(testing.io, &path_buffer)];
    try tmp.dir.createDirPath(testing.io, "backlog/tasks");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "backlog/config.yml", .data = "statuses: [\"To Do\", \"Done\"]\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "backlog/tasks/task-1 - A.md", .data = "---\nid: TASK-1\ntitle: A\nstatus: To Do\n---\n" });
    // A stand-in CLI: the status edit the real one makes, or a failure.
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "cli",
        .data = "#!/bin/sh\n[ \"$4\" = --status=Fail ] && { echo 'Error: nope' >&2; exit 3; }\n" ++
            // `-i.bak` is the in-place spelling GNU and BSD sed share.
            "sed -i.bak \"s/^status: .*/status: ${4#--status=}/\" \"backlog/tasks/task-1 - A.md\" && rm -f \"backlog/tasks/task-1 - A.md.bak\"\n",
        .flags = .{ .permissions = .fromMode(0o700) },
    });
    var program_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const program = try std.fmt.bufPrint(&program_buffer, "{s}/cli", .{base});
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, "{s}/backlog", .{base});

    // Off Linux the watch polls; scanning on every poll lets `settle` see
    // the CLI's edit at once, as inotify does.
    var context = try workspace.ExecutionContext.localWithWatchInterval(testing.allocator, 0);
    defer context.deinit();
    var panel = Panel.init(testing.allocator, testing.io, .{});
    defer panel.deinit();
    try panel.load(context.borrow(), root);
    try testing.expect(panel.problem == null);
    try testing.expectEqualStrings(base, panel.projectDirectory().?);
    try testing.expectEqual(@as(usize, 1), panel.board.columns[0].cards.len);
    try testing.expectEqualStrings("TASK-1", panel.state.selected().?);
    const generation = panel.generation;

    try panel.enqueue(CliRequest.status("TASK-1", "Done").?, program);
    try testing.expectEqualStrings("TASK-1 → Done …", panel.message().?);
    try settle(&panel, program);
    try testing.expectEqualStrings("TASK-1 → Done", panel.message().?);
    try testing.expect(!panel.message_failed);
    try testing.expect(panel.generation != generation);
    try testing.expectEqual(@as(usize, 0), panel.board.columns[0].cards.len);
    try testing.expectEqual(@as(usize, 1), panel.board.columns[1].cards.len);
    // The selection followed the task into its new column.
    try testing.expectEqual(@as(usize, 1), panel.state.selected_column);

    try panel.enqueue(CliRequest.status("TASK-1", "Fail").?, program);
    try settle(&panel, program);
    try testing.expectEqualStrings("backlog failed (3): Error: nope", panel.message().?);
    try testing.expect(panel.message_failed);

    try panel.enqueue(CliRequest.criterion("TASK-1", 1, true).?, "conduit-backlog-cli-that-does-not-exist");
    try settle(&panel, program);
    try testing.expectEqualStrings("backlog CLI not found: the view is read-only", panel.message().?);

    // A bounded queue: the fifth write while four wait is refused.
    var queued: usize = 0;
    while (queued < Panel.queue_capacity + 1) : (queued += 1) {
        panel.enqueue(CliRequest.status("TASK-1", "To Do").?, program) catch |err| {
            try testing.expectEqual(error.QueueFull, err);
            break;
        };
    }
    try settle(&panel, program);
    try testing.expectEqualStrings("To Do", panel.board.list[0].task.status);

    // A directory without backlog/ is an empty state, not an error.
    var missing_buffer: [std.fs.max_path_bytes]u8 = undefined;
    try panel.load(context.borrow(), try std.fmt.bufPrint(&missing_buffer, "{s}/nothing/backlog", .{base}));
    try testing.expectEqual(Problem.missing, panel.problem.?);
    try testing.expect(panel.board.isEmpty());
}
