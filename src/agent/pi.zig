//! The Pi adapter (TASK-55, decision-7, `doc-3` Pi column). It also covers
//! omp (oh-my-pi), the Pi fork, as `Variant.omp`.
//!
//! Pi has no hooks and no permission prompts of its own. Everything it
//! exposes reaches either an extension (`pi.on(...)` events, `ctx.ui.confirm`)
//! or an RPC client (`pi --mode rpc`, JSON lines on stdio). So the adapter has
//! two structured channels, chosen by `Mode`:
//!
//! - `tui` (the default; the human keeps Pi's own TUI in a Conduit PTY):
//!   Conduit's extension (`pi/conduit.js`, embedded as `extension_source`) is
//!   loaded with `-e` and appends one JSON line per forwarded event to
//!   `<sink>/events.jsonl`, tagged with `CONDUIT_AGENT_TOKEN`. When the gate
//!   is on it also asks Pi's own confirm dialog before bash/write/edit, writes
//!   a `permission_request` line, and accepts an answer from the file
//!   `<sink>/decisions/<id>` ("yes"/"no"); whichever of the TUI or Conduit
//!   answers first wins, and the other is told through `permission_resolved`
//!   (`resolved_elsewhere` when the human answered in Pi).
//! - `rpc` (headless agents): `pi --mode rpc`, whose stdout carries Pi's
//!   agent events and whose stdin takes commands. The gate's confirm arrives
//!   as `extension_ui_request {method: confirm}` and is answered with
//!   `extension_ui_response {confirmed}`; input is `prompt`/`steer`; stop is
//!   `abort`.
//!
//! Sink line format (version 1, written by `conduit.js`; one object per LF):
//! `{"v":1,"token":"<32 hex>","type":T,...}` with `T` one of `session_start`
//! (`reason`, `sessionId`, `sessionFile`, `cwd`), `agent_start`, `agent_end`
//! (`stopReason`, `errorMessage`), `message_end` (`role` user/assistant,
//! `text` ≤ 4000 UTF-16 units, `stopReason`), `tool_execution_start`
//! (`toolCallId`, `toolName`, `summary`, `path`), `tool_execution_end`
//! (`toolCallId`, `toolName`, `isError`), `permission_request` (`id`,
//! `toolName`, `toolCallId`, `title`, `summary`), `permission_resolved`
//! (`id`, `outcome` allowed/rejected, `by` conduit/harness) and
//! `session_shutdown` (`reason`). Unknown versions and types are ignored.
//!
//! Mapping, both channels: `agent_start` → working; `agent_end` → done, or
//! errored for `stopReason: error`, or idle for `aborted`; a user or assistant
//! `message_end` → message (Pi's own coalesced text, so streaming deltas are
//! not needed); `tool_execution_start` → tool_use plus a file_reference when
//! the tool names a `path`; a confirm → permission_request with decisions
//! `yes`/`no`; its resolution → permission_resolved; RPC `select`/`input`/
//! `editor` dialogs → waiting_input plus a notification (they are not
//! answerable here); `auto_retry_end` failure → errored; `extension_error` and
//! `notify` → notification; `get_state.isStreaming` → working/idle.
//!
//! Transcript: `SessionReader` reads Pi's own session JSONL (format v3, see
//! its doc comment) incrementally, for history and for sessions started by
//! hand without the extension (`sessionDirName` locates their directory).
//!
//! Gaps versus Claude Code and Codex (decision-7, `doc-3`):
//! - No native permission prompts: "waiting for permission" exists only while
//!   Conduit's gate extension is loaded (`Gate` not `off`); a plain `pi`
//!   started by hand never reports one, and `Capabilities.permission_requests`
//!   says so. A confirm raised by another extension is answerable in RPC mode
//!   only.
//! - No subagents (`Capabilities.subagents` is false); extensions or packages
//!   may add them, invisibly to this adapter.
//! - No hooks: without the extension (a manual start, until the user installs
//!   it with consent, TASK-60) the only sources are the session JSONL and the
//!   PTY baseline.
//! - Prompt and instructions (`read_prompt`/`update_prompt`) are unsupported
//!   here; Pi reads `AGENTS.md`/`CLAUDE.md` and `--system-prompt` files, which
//!   TASK-59 owns.
//! - Interrupting a TUI turn has no structured path (`stop` is RPC only); the
//!   owner signals the PTY.
//! - omp (`Variant.omp`, unverified, no model access when probed): the same
//!   `-e` extension, RPC and session shapes are assumed (its sessions live in
//!   `~/.omp/agent/sessions` and add `title`/`title_change` entries). omp also
//!   has native approvals (`--approval-mode`), `--mode rpc-ui` and ACP, which
//!   this adapter does not use.
//!
//! Detection (`detect`) needs a probe through the workspace ExecutionContext,
//! which has no run/read capability yet: TODO(TASK-55) implement it with the
//! ExecutionContext probe once that lands. `recognizeCommand` already lets the
//! agent core classify a foreground `pi`/`omp` process it found itself.
//!
//! Threads: as `adapter.zig` says, every method but `harness` and
//! `capabilities` runs on one IO worker at a time. The adapter makes no OS
//! calls itself: all IO goes through the owner-supplied `Transport`.
//!
//! Memory: `init` copies every option string; `deinit` frees them. Lines are
//! buffered up to `Options.max_line_bytes`; a longer line is dropped except
//! for its event type, so an oversized `agent_end` still ends the turn. Each
//! line is parsed in an arena that is reset per line.

const std = @import("std");
const iface = @import("adapter.zig");
const event = @import("event.zig");
const state = @import("state.zig");
const Harness = @import("harness.zig").Harness;

const Allocator = std.mem.Allocator;
const Error = iface.Error;
const json = std.json;
const log = std.log.scoped(.agent_pi);

/// Conduit's Pi extension. `launch` names it at `<sink>/conduit.js`; the
/// owner writes these bytes there through the ExecutionContext before the
/// spawn, so a remote context carries its own copy.
pub const extension_source: []const u8 = @embedFile("pi/conduit.js");
pub const extension_file_name = "conduit.js";
/// The directory the extension reports into, in the agent's context.
pub const sink_env_name = "CONDUIT_AGENT_SINK";
/// "1" gates bash/write/edit, "all" gates every tool; unset means no gate.
pub const gate_env_name = "CONDUIT_AGENT_GATE";
pub const events_file_name = "events.jsonl";
pub const decisions_dir_name = "decisions";
/// The two decision ids every Pi permission request offers.
pub const decision_yes = "yes";
pub const decision_no = "no";

pub const default_max_line_bytes = 1 << 20;
/// The most `sendInput` or an initial RPC prompt may carry.
pub const max_input_bytes = 64 * 1024;
/// The longest request id accepted. Sink ids name a file, so they are also
/// restricted to `[A-Za-z0-9_-]`.
pub const max_request_id_bytes = 64;

const read_chunk_bytes = 16 * 1024;
const max_read_per_poll = 256 * 1024;
const max_events_per_line = 16;
const max_pending = 16;
const overflow_head_bytes = 96;
const max_session_field_bytes = 4096;

const pi_decisions = [_]event.Decision{
    .{ .id = decision_yes, .label = "Yes", .kind = .allow_once },
    .{ .id = decision_no, .label = "No", .kind = .reject },
};

/// Pi itself, or omp (oh-my-pi), its fork. Same shapes; omp's differences
/// are unverified (see the file comment).
pub const Variant = enum {
    pi,
    omp,

    pub fn executable(self: Variant) []const u8 {
        return switch (self) {
            .pi => "pi",
            .omp => "omp",
        };
    }

    /// Where sessions live relative to the user's home, unless
    /// `PI_CODING_AGENT_DIR` (`<dir>/sessions`) or `--session-dir` moves them.
    pub fn sessionsRoot(self: Variant) []const u8 {
        return switch (self) {
            .pi => ".pi/agent/sessions",
            .omp => ".omp/agent/sessions",
        };
    }
};

/// Which structured channel the adapter speaks.
pub const Mode = enum { tui, rpc };

/// Which tool calls Conduit's extension holds for a decision.
pub const Gate = enum {
    off,
    /// bash, write and edit.
    mutating,
    all,

    fn envValue(self: Gate) ?[]const u8 {
        return switch (self) {
            .off => null,
            .mutating => "1",
            .all => "all",
        };
    }
};

/// The owner-supplied IO under the adapter, so no OS call happens here and a
/// remote ExecutionContext can carry it (decision-7, rule 5).
///
/// - `read` returns the bytes of the event stream available now (the sink's
///   `events.jsonl` in `tui` mode, the child's stdout in `rpc` mode) without
///   blocking: 0 when there are none yet, `error.Disconnected` once the
///   stream ended and everything was read.
/// - `write` (rpc) writes bytes to the child's stdin; the adapter always
///   passes whole LF-terminated lines.
/// - `decide` (tui) publishes `decision` ("yes"/"no") as
///   `<sink>/decisions/<request_id>`. It must appear atomically (write a
///   temporary file and rename it) because the extension polls for it.
///   `request_id` has already been validated as a safe file name.
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (*anyopaque, []u8) Error!usize,
        write: ?*const fn (*anyopaque, []const u8) Error!void = null,
        decide: ?*const fn (*anyopaque, []const u8, []const u8) Error!void = null,
    };
};

pub const Options = struct {
    variant: Variant = .pi,
    /// The channel for an attached session; `launch` sets it from
    /// `LaunchRequest.headless`.
    mode: Mode = .tui,
    gate: Gate = .mutating,
    /// Overrides `variant.executable()`.
    executable: ?[]const u8 = null,
    /// A private directory in the agent's ExecutionContext holding the
    /// extension and its sink. Required for a `tui` launch.
    sink_dir: []const u8 = "",
    /// Extra arguments placed before Conduit's own (provider, model…).
    extra_args: []const []const u8 = &.{},
    transport: ?Transport = null,
    max_line_bytes: usize = default_max_line_bytes,
};

/// Whether `argv0` runs Pi or omp, by its basename. Lets the agent core
/// classify a foreground process found in a human terminal.
pub fn recognizeCommand(argv0: []const u8) ?Variant {
    const base = std.fs.path.basenamePosix(argv0);
    if (std.mem.eql(u8, base, "pi")) return .pi;
    if (std.mem.eql(u8, base, "omp")) return .omp;
    return null;
}

/// The session directory name Pi uses for `cwd`:
/// `--<cwd without its leading separator, with / \ : as ->--`
/// (Pi 0.73.1 `session-manager.js`).
pub fn sessionDirName(out: []u8, cwd: []const u8) error{NoSpaceLeft}![]const u8 {
    const trimmed = if (cwd.len != 0 and (cwd[0] == '/' or cwd[0] == '\\')) cwd[1..] else cwd;
    if (out.len < trimmed.len + 4) return error.NoSpaceLeft;
    @memcpy(out[0..2], "--");
    for (trimmed, 0..) |c, i| {
        out[2 + i] = switch (c) {
            '/', '\\', ':' => '-',
            else => c,
        };
    }
    @memcpy(out[2 + trimmed.len ..][0..2], "--");
    return out[0 .. trimmed.len + 4];
}

/// Whether `id` may name a decision file: 1–64 bytes of `[A-Za-z0-9_-]`.
pub fn isSafeRequestId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_request_id_bytes) return false;
    for (id) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// Bounded line splitting with resumable progress, shared by the adapter and
/// `SessionReader`.
const LineFeed = struct {
    buffer: std.ArrayList(u8) = .empty,
    /// Lines are `buffer[start..line_end]`; `buffer[line_end..]` is the
    /// partial line still arriving.
    start: usize = 0,
    line_end: usize = 0,
    limit: usize,
    /// Dropping the rest of an over-long line.
    discarding: bool = false,
    head: [overflow_head_bytes]u8 = undefined,
    head_len: usize = 0,
    /// Events of the first line already handed over.
    progress: usize = 0,

    fn deinit(self: *LineFeed, allocator: Allocator) void {
        self.buffer.deinit(allocator);
    }

    /// Whether another read fits without exceeding the bound.
    fn hasRoom(self: *const LineFeed) bool {
        return self.buffer.items.len - self.start < self.limit;
    }

    fn append(self: *LineFeed, allocator: Allocator, bytes: []const u8) Allocator.Error!void {
        var rest = bytes;
        while (rest.len != 0) {
            const newline = std.mem.indexOfScalar(u8, rest, '\n');
            if (self.discarding) {
                const nl = newline orelse return;
                rest = rest[nl + 1 ..];
                self.discarding = false;
                try self.appendOverflowStub(allocator);
                continue;
            }
            const partial = self.buffer.items.len - self.line_end;
            const content = newline orelse rest.len;
            if (partial + content > self.limit) {
                self.captureHead(rest);
                self.buffer.shrinkRetainingCapacity(self.line_end);
                self.discarding = true;
                continue;
            }
            const piece = if (newline) |nl| nl + 1 else rest.len;
            try self.buffer.appendSlice(allocator, rest[0..piece]);
            if (newline != null) self.line_end = self.buffer.items.len;
            rest = rest[piece..];
        }
    }

    fn captureHead(self: *LineFeed, rest: []const u8) void {
        const partial = self.buffer.items[self.line_end..];
        const from_partial = @min(partial.len, self.head.len);
        @memcpy(self.head[0..from_partial], partial[0..from_partial]);
        const from_rest = @min(rest.len, self.head.len - from_partial);
        @memcpy(self.head[from_partial..][0..from_rest], rest[0..from_rest]);
        self.head_len = from_partial + from_rest;
    }

    /// Replace a dropped line by `{"type":T,"conduit_truncated":true}` so its
    /// type still maps, in order.
    fn appendOverflowStub(self: *LineFeed, allocator: Allocator) Allocator.Error!void {
        const kind = typeFromHead(self.head[0..self.head_len]);
        log.debug("dropped an over-long line of type '{s}'", .{kind});
        var stub: [overflow_head_bytes + 64]u8 = undefined;
        const line = std.fmt.bufPrint(&stub, "{{\"type\":\"{s}\",\"conduit_truncated\":true}}\n", .{kind}) catch unreachable; // `kind` is at most the head's length
        try self.buffer.appendSlice(allocator, line);
        self.line_end = self.buffer.items.len;
    }

    fn peekLine(self: *const LineFeed) ?[]const u8 {
        if (self.start == self.line_end) return null;
        const lines = self.buffer.items[self.start..self.line_end];
        const nl = std.mem.indexOfScalar(u8, lines, '\n').?; // `line_end` always follows a newline
        var line = lines[0..nl];
        if (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        return line;
    }

    fn consumeLine(self: *LineFeed) void {
        const lines = self.buffer.items[self.start..self.line_end];
        const nl = std.mem.indexOfScalar(u8, lines, '\n').?;
        self.start += nl + 1;
        self.progress = 0;
    }

    fn compact(self: *LineFeed) void {
        if (self.start == 0) return;
        const remaining = self.buffer.items.len - self.start;
        std.mem.copyForwards(u8, self.buffer.items[0..remaining], self.buffer.items[self.start..]);
        self.buffer.shrinkRetainingCapacity(remaining);
        self.line_end -= self.start;
        self.start = 0;
    }
};

/// The `"type"` value near the start of a JSON line, or "unknown". Only
/// letters, digits and `_` are taken, so the stub stays valid JSON.
fn typeFromHead(head: []const u8) []const u8 {
    const key = "\"type\":\"";
    const at = std.mem.indexOf(u8, head, key) orelse return "unknown";
    const value = head[at + key.len ..];
    var end: usize = 0;
    while (end < value.len) : (end += 1) switch (value[end]) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
        '"' => return if (end == 0) "unknown" else value[0..end],
        else => return "unknown",
    };
    return "unknown";
}

/// The events one line maps to; extra events beyond the bound are dropped.
const LineEvents = struct {
    items: [max_events_per_line]event.Event = undefined,
    len: usize = 0,

    fn add(self: *LineEvents, ev: event.Event) void {
        if (self.len == self.items.len) {
            log.debug("dropped an event beyond the per-line bound", .{});
            return;
        }
        self.items[self.len] = ev;
        self.len += 1;
    }

    fn status(self: *LineEvents, to: state.State) void {
        self.add(.{ .status_change = .{ .state = to, .source = .structured } });
    }
};

/// Hand `events` to `queue` from `feed.progress` on, counting each push in
/// `pushed`. False when the queue filled first; progress is kept for the
/// next attempt.
fn pushEvents(feed: *LineFeed, events: *const LineEvents, queue: *event.EventQueue, pushed: *usize) bool {
    while (feed.progress < events.len) : (feed.progress += 1) {
        queue.push(events.items[feed.progress]) catch |err| switch (err) {
            error.QueueFull => return false,
            // An over-long identifier names nothing; skip just that event.
            error.EventTooLarge => {
                log.debug("dropped an event too large to store", .{});
                continue;
            },
        };
        pushed.* += 1;
    }
    return true;
}

// JSON accessors: everything from Pi is untrusted, so every lookup tolerates
// a missing or mistyped field.

fn field(value: json.Value, key: []const u8) ?json.Value {
    return switch (value) {
        .object => |object| object.get(key),
        else => null,
    };
}

fn stringField(value: json.Value, key: []const u8) ?[]const u8 {
    const found = field(value, key) orelse return null;
    return switch (found) {
        .string => |s| s,
        else => null,
    };
}

fn boolField(value: json.Value, key: []const u8) ?bool {
    const found = field(value, key) orelse return null;
    return switch (found) {
        .bool => |b| b,
        else => null,
    };
}

fn eql(a: ?[]const u8, b: []const u8) bool {
    return if (a) |s| std.mem.eql(u8, s, b) else false;
}

/// Text blocks of a Pi `content` (a string or an array of blocks), joined by
/// LF and cut to the event store's capacity.
fn contentText(arena: Allocator, content: ?json.Value) Allocator.Error!Clipped {
    const value = content orelse return .{ .text = "", .truncated = false };
    switch (value) {
        .string => |s| return clip(s),
        .array => |array| {
            var text: std.ArrayList(u8) = .empty;
            var truncated = false;
            for (array.items) |block| {
                if (!eql(stringField(block, "type"), "text")) continue;
                const piece = stringField(block, "text") orelse continue;
                if (text.items.len != 0) try text.append(arena, '\n');
                const room = event.stored_text_capacity -| text.items.len;
                const kept = event.truncateUtf8(piece, room);
                try text.appendSlice(arena, kept);
                if (kept.len != piece.len) {
                    truncated = true;
                    break;
                }
            }
            return .{ .text = text.items, .truncated = truncated };
        },
        else => return .{ .text = "", .truncated = false },
    }
}

const Clipped = struct { text: []const u8, truncated: bool };

fn clip(text: []const u8) Clipped {
    const kept = event.truncateUtf8(text, event.stored_text_capacity);
    return .{ .text = kept, .truncated = kept.len != text.len };
}

/// A one-line summary of tool arguments: the command, path or pattern.
fn argsSummary(args: ?json.Value) []const u8 {
    const value = args orelse return "";
    for ([_][]const u8{ "command", "path", "pattern" }) |key| {
        if (stringField(value, key)) |s| return s;
    }
    return "";
}

fn addMessage(events: *LineEvents, role: event.Role, text: []const u8, truncated: bool) void {
    if (text.len == 0) return;
    events.add(.{ .message = .{ .role = role, .text = text, .truncated = truncated } });
}

fn addToolUse(events: *LineEvents, name: ?[]const u8, summary: []const u8, path: ?[]const u8) void {
    const tool = name orelse return;
    events.add(.{ .tool_use = .{ .name = tool, .summary = summary } });
    if (path) |p| {
        if (p.len != 0) events.add(.{ .file_reference = .{ .path = p } });
    }
}

/// The outcome of a finished prompt from an assistant `stopReason`.
fn turnOutcome(stop_reason: ?[]const u8) state.State {
    if (eql(stop_reason, "error")) return .errored;
    if (eql(stop_reason, "aborted")) return .idle;
    return .done;
}

/// A fixed set of request ids, oldest dropped when full.
const IdSet = struct {
    ids: [max_pending][max_request_id_bytes]u8 = undefined,
    lens: [max_pending]usize = undefined,
    len: usize = 0,

    fn indexOf(self: *const IdSet, id: []const u8) ?usize {
        for (0..self.len) |i| {
            if (std.mem.eql(u8, self.ids[i][0..self.lens[i]], id)) return i;
        }
        return null;
    }

    fn add(self: *IdSet, id: []const u8) void {
        if (id.len == 0 or id.len > max_request_id_bytes or self.indexOf(id) != null) return;
        if (self.len == max_pending) self.removeAt(0);
        @memcpy(self.ids[self.len][0..id.len], id);
        self.lens[self.len] = id.len;
        self.len += 1;
    }

    fn remove(self: *IdSet, id: []const u8) bool {
        const i = self.indexOf(id) orelse return false;
        self.removeAt(i);
        return true;
    }

    fn removeAt(self: *IdSet, i: usize) void {
        var j = i;
        while (j + 1 < self.len) : (j += 1) {
            self.ids[j] = self.ids[j + 1];
            self.lens[j] = self.lens[j + 1];
        }
        self.len -= 1;
    }
};

/// Resolutions the adapter itself caused (an RPC answer), reported on the
/// next poll because Pi sends no event for them.
const Resolution = struct {
    id: [max_request_id_bytes]u8,
    id_len: usize,
    outcome: event.PermissionOutcome,
};

pub const PiAdapter = struct {
    allocator: Allocator,
    variant: Variant,
    mode: Mode,
    gate: Gate,
    executable: []const u8,
    sink_dir: []const u8,
    extra_args: []const []const u8,
    transport: ?Transport,

    feed: LineFeed,
    arena: std.heap.ArenaAllocator,
    token: ?iface.CorrelationToken = null,
    attached: bool = false,
    ended: bool = false,
    /// Whether Pi is running a prompt, for choosing `prompt` or `steer`.
    streaming: bool = false,
    pending: IdSet = .{},
    resolutions: [max_pending]Resolution = undefined,
    resolutions_len: usize = 0,
    /// An initial prompt for an RPC launch, sent on the first poll.
    initial_prompt: ?[]u8 = null,
    session_id_buf: [event.max_identifier_bytes]u8 = undefined,
    session_id_len: usize = 0,
    session_file_buf: [max_session_field_bytes]u8 = undefined,
    session_file_len: usize = 0,

    const vtable: iface.Adapter.VTable = .{
        .harness = harness,
        .capabilities = capabilities,
        .launch = launch,
        .attach = attach,
        .poll = poll,
        .send_input = sendInput,
        .respond_permission = respondPermission,
        .stop = stop,
        .destroy = destroy,
    };

    /// Ownership: the result owns copies of the option strings and must be
    /// released with `deinit` (or `destroy` through the vtable, which only
    /// deinitialises the value; the caller still owns its memory).
    pub fn init(allocator: Allocator, options: Options) Allocator.Error!PiAdapter {
        const executable = try allocator.dupe(u8, options.executable orelse options.variant.executable());
        errdefer allocator.free(executable);
        const sink_dir = try allocator.dupe(u8, options.sink_dir);
        errdefer allocator.free(sink_dir);
        const extra_args = try allocator.alloc([]const u8, options.extra_args.len);
        var copied: usize = 0;
        errdefer {
            for (extra_args[0..copied]) |arg| allocator.free(arg);
            allocator.free(extra_args);
        }
        for (options.extra_args) |arg| {
            extra_args[copied] = try allocator.dupe(u8, arg);
            copied += 1;
        }
        return .{
            .allocator = allocator,
            .variant = options.variant,
            .mode = options.mode,
            .gate = options.gate,
            .executable = executable,
            .sink_dir = sink_dir,
            .extra_args = extra_args,
            .transport = options.transport,
            .feed = .{ .limit = @max(options.max_line_bytes, overflow_head_bytes) },
            .arena = .init(allocator),
        };
    }

    pub fn deinit(self: *PiAdapter) void {
        const allocator = self.allocator;
        allocator.free(self.executable);
        allocator.free(self.sink_dir);
        for (self.extra_args) |arg| allocator.free(arg);
        allocator.free(self.extra_args);
        if (self.initial_prompt) |prompt| allocator.free(prompt);
        self.feed.deinit(allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Lend this adapter as the type-erased interface. `destroy` calls
    /// `deinit`.
    pub fn adapter(self: *PiAdapter) iface.Adapter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Plug in the IO once the owner has spawned the process (rpc) or
    /// opened the sink (tui). Not thread-safe against a running poll.
    pub fn setTransport(self: *PiAdapter, transport: Transport) void {
        self.transport = transport;
        self.ended = false;
    }

    /// Pi's session id, once a structured event reported it.
    pub fn sessionId(self: *const PiAdapter) ?[]const u8 {
        return if (self.session_id_len == 0) null else self.session_id_buf[0..self.session_id_len];
    }

    /// Pi's session JSONL path in the agent's context, once reported; feed
    /// it to a `SessionReader` for the full transcript.
    pub fn sessionFile(self: *const PiAdapter) ?[]const u8 {
        return if (self.session_file_len == 0) null else self.session_file_buf[0..self.session_file_len];
    }

    fn cast(ptr: *anyopaque) *PiAdapter {
        return @ptrCast(@alignCast(ptr));
    }

    fn castConst(ptr: *const anyopaque) *const PiAdapter {
        return @ptrCast(@alignCast(ptr));
    }

    fn harness(_: *const anyopaque) Harness {
        return .pi;
    }

    fn capabilities(ptr: *const anyopaque) iface.Capabilities {
        const self = castConst(ptr);
        const transport = self.transport;
        const connected = transport != null;
        const can_write = if (transport) |t| t.vtable.write != null else false;
        const can_decide = if (transport) |t| t.vtable.decide != null else false;
        const rpc = self.mode == .rpc;
        return .{
            .launch = true,
            .attach = true,
            .poll = connected,
            .send_input = rpc and can_write,
            .respond_permission = if (rpc) can_write else self.gate != .off and can_decide,
            .stop = rpc and can_write,
            .structured_status = connected,
            .permission_requests = connected and (rpc or self.gate != .off),
            .transcript = connected,
        };
    }

    fn launch(ptr: *anyopaque, allocator: Allocator, request: iface.LaunchRequest) Error!iface.LaunchSpec {
        const self = cast(ptr);
        const mode: Mode = if (request.headless) .rpc else .tui;
        const use_extension = mode == .tui or self.gate != .off;
        // The extension file lives in the sink directory, and a TUI reports there.
        if (use_extension and self.sink_dir.len == 0) return error.Unsupported;
        if (request.initial_prompt) |prompt| {
            if (prompt.len > max_input_bytes) return error.NoSpaceLeft;
            // Pi parses a leading '-' as an option and offers no `--`.
            if (mode == .tui and prompt.len != 0 and prompt[0] == '-') return error.Unsupported;
        }

        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(allocator, try allocator.dupe(u8, self.executable));
        for (self.extra_args) |arg| try argv.append(allocator, try allocator.dupe(u8, arg));
        if (mode == .rpc) {
            try argv.append(allocator, "--mode");
            try argv.append(allocator, "rpc");
        }
        if (use_extension) {
            try argv.append(allocator, "-e");
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, self.sink_dir, "/"), extension_file_name }));
        }
        if (mode == .tui) {
            if (request.initial_prompt) |prompt| try argv.append(allocator, try allocator.dupe(u8, prompt));
        }

        var env: std.ArrayList([]const u8) = .empty;
        var entry: [iface.correlation_env_name.len + 1 + iface.CorrelationToken.text_len]u8 = undefined;
        try env.append(allocator, try allocator.dupe(u8, request.token.envEntry(&entry)));
        if (mode == .tui) try env.append(allocator, try std.fmt.allocPrint(allocator, "{s}={s}", .{ sink_env_name, self.sink_dir }));
        if (self.gate.envValue()) |value| {
            if (use_extension) try env.append(allocator, try std.fmt.allocPrint(allocator, "{s}={s}", .{ gate_env_name, value }));
        }

        if (mode == .rpc) {
            if (request.initial_prompt) |prompt| {
                const copy = try self.allocator.dupe(u8, prompt);
                if (self.initial_prompt) |old| self.allocator.free(old);
                self.initial_prompt = copy;
            }
        }
        self.mode = mode;
        self.token = request.token;
        return .{ .argv = try argv.toOwnedSlice(allocator), .env = try env.toOwnedSlice(allocator) };
    }

    fn attach(ptr: *anyopaque, request: iface.AttachRequest) Error!void {
        const self = cast(ptr);
        if (self.attached) return error.UnknownTarget;
        self.attached = true;
        self.token = request.token;
        if (request.harness_session_id) |id| self.recordSessionId(id);
    }

    fn poll(ptr: *anyopaque, queue: *event.EventQueue) Error!usize {
        const self = cast(ptr);
        const transport = self.transport orelse return error.Disconnected;
        if (self.initial_prompt) |prompt| {
            if (transport.vtable.write != null) {
                try self.sendLine(transport, if (self.streaming) "steer" else "prompt", prompt);
                self.allocator.free(prompt);
                self.initial_prompt = null;
            }
        }

        var pushed: usize = 0;
        while (self.resolutions_len != 0) {
            const resolution = &self.resolutions[0];
            queue.push(.{ .permission_resolved = .{
                .id = resolution.id[0..resolution.id_len],
                .outcome = resolution.outcome,
            } }) catch |err| switch (err) {
                error.QueueFull => return pushed,
                error.EventTooLarge => unreachable, // ids are at most 64 bytes
            };
            pushed += 1;
            std.mem.copyForwards(Resolution, self.resolutions[0 .. self.resolutions_len - 1], self.resolutions[1..self.resolutions_len]);
            self.resolutions_len -= 1;
        }

        var read_total: usize = 0;
        while (!self.ended and read_total < max_read_per_poll and self.feed.hasRoom()) {
            var chunk: [read_chunk_bytes]u8 = undefined;
            const n = transport.vtable.read(transport.ptr, &chunk) catch |err| switch (err) {
                error.Disconnected => {
                    self.ended = true;
                    break;
                },
                else => return err,
            };
            if (n == 0) break;
            try self.feed.append(self.allocator, chunk[0..n]);
            read_total += n;
        }

        while (self.feed.peekLine()) |line| {
            _ = self.arena.reset(.retain_capacity);
            var events: LineEvents = .{};
            try self.mapLine(self.arena.allocator(), line, &events);
            if (!pushEvents(&self.feed, &events, queue, &pushed)) {
                self.feed.compact();
                return pushed;
            }
            self.feed.consumeLine();
        }
        self.feed.compact();
        if (self.ended and pushed == 0) return error.Disconnected;
        return pushed;
    }

    fn mapLine(self: *PiAdapter, arena: Allocator, line: []const u8, events: *LineEvents) Allocator.Error!void {
        if (line.len == 0) return;
        const root = json.parseFromSliceLeaky(json.Value, arena, line, .{
            .duplicate_field_behavior = .use_last,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.debug("ignored a line that is not JSON", .{});
                return;
            },
        };
        switch (self.mode) {
            .tui => try self.mapSinkLine(arena, root, events),
            .rpc => try self.mapRpcLine(arena, root, events),
        }
    }

    fn mapSinkLine(self: *PiAdapter, arena: Allocator, root: json.Value, events: *LineEvents) Allocator.Error!void {
        const version = field(root, "v") orelse return;
        if (version != .integer or version.integer != 1) {
            log.debug("ignored a sink line of an unknown version", .{});
            return;
        }
        if (self.token) |token| {
            if (!eql(stringField(root, "token"), token.text())) {
                log.debug("ignored a sink line for another agent", .{});
                return;
            }
        }
        const kind = stringField(root, "type") orelse return;
        if (std.mem.eql(u8, kind, "session_start")) {
            if (stringField(root, "sessionId")) |id| self.recordSessionId(id);
            if (stringField(root, "sessionFile")) |file| self.recordSessionFile(file);
            events.status(.idle);
        } else if (std.mem.eql(u8, kind, "agent_start")) {
            self.streaming = true;
            events.status(.working);
        } else if (std.mem.eql(u8, kind, "agent_end")) {
            self.streaming = false;
            const outcome = turnOutcome(stringField(root, "stopReason"));
            if (outcome == .errored) {
                if (stringField(root, "errorMessage")) |message| {
                    const text = clip(message);
                    addMessage(events, .system, text.text, text.truncated);
                }
            }
            events.status(outcome);
        } else if (std.mem.eql(u8, kind, "message_end")) {
            const role = roleOf(stringField(root, "role")) orelse return;
            const text = clip(stringField(root, "text") orelse "");
            addMessage(events, role, text.text, text.truncated);
        } else if (std.mem.eql(u8, kind, "tool_execution_start")) {
            addToolUse(events, stringField(root, "toolName"), stringField(root, "summary") orelse "", stringField(root, "path"));
        } else if (std.mem.eql(u8, kind, "permission_request")) {
            const id = stringField(root, "id") orelse return;
            if (!isSafeRequestId(id)) {
                log.debug("ignored a permission request with an unsafe id", .{});
                return;
            }
            self.pending.add(id);
            const title = try joinTitle(arena, stringField(root, "title") orelse "Allow tool?", stringField(root, "summary"));
            events.add(.{ .permission_request = .{ .id = id, .title = title, .decisions = &pi_decisions } });
        } else if (std.mem.eql(u8, kind, "permission_resolved")) {
            const id = stringField(root, "id") orelse return;
            _ = self.pending.remove(id);
            const outcome: event.PermissionOutcome = if (eql(stringField(root, "by"), "harness"))
                .resolved_elsewhere
            else if (eql(stringField(root, "outcome"), "allowed"))
                .allowed
            else
                .rejected;
            events.add(.{ .permission_resolved = .{ .id = id, .outcome = outcome } });
        }
        // tool_execution_end, session_shutdown and anything newer: no event.
    }

    fn mapRpcLine(self: *PiAdapter, arena: Allocator, root: json.Value, events: *LineEvents) Allocator.Error!void {
        const kind = stringField(root, "type") orelse return;
        if (std.mem.eql(u8, kind, "response")) {
            if (boolField(root, "success") == false) {
                const text = clip(stringField(root, "error") orelse "command failed");
                events.add(.{ .notification = .{ .title = "Pi", .body = text.text, .truncated = text.truncated } });
                return;
            }
            if (!eql(stringField(root, "command"), "get_state")) return;
            const data = field(root, "data") orelse return;
            if (stringField(data, "sessionId")) |id| self.recordSessionId(id);
            if (stringField(data, "sessionFile")) |file| self.recordSessionFile(file);
            if (boolField(data, "isStreaming")) |streaming| {
                self.streaming = streaming;
                events.status(if (streaming) .working else .idle);
            }
        } else if (std.mem.eql(u8, kind, "agent_start")) {
            self.streaming = true;
            events.status(.working);
        } else if (std.mem.eql(u8, kind, "agent_end")) {
            self.streaming = false;
            var stop_reason: ?[]const u8 = null;
            var error_message: ?[]const u8 = null;
            if (field(root, "messages")) |messages| {
                if (messages == .array) {
                    var i = messages.array.items.len;
                    while (i > 0) {
                        i -= 1;
                        const message = messages.array.items[i];
                        if (!eql(stringField(message, "role"), "assistant")) continue;
                        stop_reason = stringField(message, "stopReason");
                        error_message = stringField(message, "errorMessage");
                        break;
                    }
                }
            }
            const outcome = turnOutcome(stop_reason);
            if (outcome == .errored) {
                if (error_message) |message| {
                    const text = clip(message);
                    addMessage(events, .system, text.text, text.truncated);
                }
            }
            events.status(outcome);
        } else if (std.mem.eql(u8, kind, "message_end")) {
            const message = field(root, "message") orelse return;
            const role = roleOf(stringField(message, "role")) orelse return;
            const text = try contentText(arena, field(message, "content"));
            addMessage(events, role, text.text, text.truncated);
        } else if (std.mem.eql(u8, kind, "tool_execution_start")) {
            const args = field(root, "args");
            addToolUse(events, stringField(root, "toolName"), argsSummary(args), if (args) |a| stringField(a, "path") else null);
        } else if (std.mem.eql(u8, kind, "extension_ui_request")) {
            const method = stringField(root, "method") orelse return;
            const id = stringField(root, "id") orelse "";
            const title = stringField(root, "title") orelse "";
            if (std.mem.eql(u8, method, "confirm")) {
                if (id.len == 0 or id.len > max_request_id_bytes) {
                    log.debug("ignored a confirm with an unusable id", .{});
                    return;
                }
                self.pending.add(id);
                const joined = try joinTitle(arena, if (title.len == 0) "Confirm?" else title, stringField(root, "message"));
                events.add(.{ .permission_request = .{ .id = id, .title = joined, .decisions = &pi_decisions } });
            } else if (std.mem.eql(u8, method, "select") or std.mem.eql(u8, method, "input") or std.mem.eql(u8, method, "editor")) {
                events.status(.waiting_input);
                const text = clip(title);
                events.add(.{ .notification = .{ .title = "Pi", .body = text.text, .truncated = text.truncated } });
            } else if (std.mem.eql(u8, method, "notify")) {
                const text = clip(stringField(root, "message") orelse "");
                if (text.text.len != 0) events.add(.{ .notification = .{ .title = "Pi", .body = text.text, .truncated = text.truncated } });
            }
        } else if (std.mem.eql(u8, kind, "auto_retry_end")) {
            if (boolField(root, "success") == false) {
                const text = clip(stringField(root, "finalError") orelse "retries exhausted");
                events.add(.{ .notification = .{ .title = "Pi", .body = text.text, .truncated = text.truncated } });
                events.status(.errored);
            }
        } else if (std.mem.eql(u8, kind, "extension_error")) {
            const text = clip(stringField(root, "error") orelse "");
            events.add(.{ .notification = .{ .title = "Pi extension error", .body = text.text, .truncated = text.truncated } });
        }
    }

    fn recordSessionId(self: *PiAdapter, id: []const u8) void {
        if (id.len > self.session_id_buf.len) return;
        @memcpy(self.session_id_buf[0..id.len], id);
        self.session_id_len = id.len;
    }

    fn recordSessionFile(self: *PiAdapter, file: []const u8) void {
        if (file.len > self.session_file_buf.len) return;
        @memcpy(self.session_file_buf[0..file.len], file);
        self.session_file_len = file.len;
    }

    fn sendInput(ptr: *anyopaque, bytes: []const u8) Error!void {
        const self = cast(ptr);
        const transport = self.transport orelse return error.Disconnected;
        if (self.mode != .rpc) return error.Unsupported;
        try self.sendLine(transport, if (self.streaming) "steer" else "prompt", bytes);
    }

    /// `{"type":<command>,"message":<text>}` + LF.
    fn sendLine(self: *PiAdapter, transport: Transport, command: []const u8, text: []const u8) Error!void {
        const write = transport.vtable.write orelse return error.Unsupported;
        if (text.len > max_input_bytes) return error.NoSpaceLeft;
        // Pi needs valid JSON strings; Conduit's input is UTF-8 by contract.
        if (!std.unicode.utf8ValidateSlice(text)) return error.Protocol;
        const buffer = try self.allocator.alloc(u8, text.len * 6 + 64);
        defer self.allocator.free(buffer);
        var writer: std.Io.Writer = .fixed(buffer);
        writer.print("{{\"type\":\"{s}\",\"message\":", .{command}) catch return error.NoSpaceLeft;
        json.Stringify.encodeJsonString(text, .{}, &writer) catch return error.NoSpaceLeft;
        writer.writeAll("}\n") catch return error.NoSpaceLeft;
        try write(transport.ptr, writer.buffered());
    }

    fn respondPermission(ptr: *anyopaque, request_id: []const u8, decision_id: []const u8) Error!void {
        const self = cast(ptr);
        const transport = self.transport orelse return error.Disconnected;
        const allow = if (std.mem.eql(u8, decision_id, decision_yes))
            true
        else if (std.mem.eql(u8, decision_id, decision_no))
            false
        else
            return error.UnknownTarget;
        if (self.pending.indexOf(request_id) == null) return error.UnknownTarget;
        switch (self.mode) {
            .rpc => {
                const write = transport.vtable.write orelse return error.Unsupported;
                var buffer: [max_request_id_bytes * 6 + 96]u8 = undefined;
                var writer: std.Io.Writer = .fixed(&buffer);
                writer.writeAll("{\"type\":\"extension_ui_response\",\"id\":") catch return error.NoSpaceLeft;
                json.Stringify.encodeJsonString(request_id, .{}, &writer) catch return error.NoSpaceLeft;
                writer.print(",\"confirmed\":{}}}\n", .{allow}) catch return error.NoSpaceLeft;
                try write(transport.ptr, writer.buffered());
                _ = self.pending.remove(request_id);
                if (self.resolutions_len == self.resolutions.len) {
                    std.mem.copyForwards(Resolution, self.resolutions[0 .. self.resolutions.len - 1], self.resolutions[1..]);
                    self.resolutions_len -= 1;
                }
                const slot = &self.resolutions[self.resolutions_len];
                @memcpy(slot.id[0..request_id.len], request_id);
                slot.id_len = request_id.len;
                slot.outcome = if (allow) .allowed else .rejected;
                self.resolutions_len += 1;
            },
            .tui => {
                const decide = transport.vtable.decide orelse return error.Unsupported;
                if (!isSafeRequestId(request_id)) return error.UnknownTarget;
                // The extension reports the resolution itself.
                try decide(transport.ptr, request_id, decision_id);
            },
        }
    }

    fn stop(ptr: *anyopaque) Error!void {
        const self = cast(ptr);
        const transport = self.transport orelse return error.Disconnected;
        if (self.mode != .rpc) return error.Unsupported;
        const write = transport.vtable.write orelse return error.Unsupported;
        try write(transport.ptr, "{\"type\":\"abort\"}\n");
    }

    fn destroy(ptr: *anyopaque) void {
        cast(ptr).deinit();
    }
};

fn roleOf(role: ?[]const u8) ?event.Role {
    if (eql(role, "user")) return .user;
    if (eql(role, "assistant")) return .assistant;
    return null;
}

/// "Allow bash? touch x" — the confirm's title and its message on one line.
fn joinTitle(arena: Allocator, title: []const u8, message: ?[]const u8) Allocator.Error![]const u8 {
    const detail = message orelse return title;
    if (detail.len == 0) return title;
    return std.fmt.allocPrint(arena, "{s} {s}", .{ title, event.truncateUtf8(detail, event.stored_text_capacity) });
}

/// Reads a Pi session file (JSONL, format v3; v1 and v2 parse the same way
/// for the entries used here) incrementally into transcript events. Feed it
/// the file's bytes as they grow; it keeps a partial last line for the next
/// feed and never needs the whole file.
///
/// Verified against Pi 0.73.1 (`docs/session-format.md` and files written by
/// the integration probe): the first line is the header
/// `{"type":"session","version":3,"id":<uuid>,"timestamp","cwd"}`, then tree
/// entries with `id`/`parentId`/`timestamp`: `message` (`message.role`
/// user/assistant/toolResult/bashExecution/custom/branchSummary/
/// compactionSummary), `model_change`, `thinking_level_change`,
/// `compaction` (`summary`), `branch_summary` (`summary`), `custom`,
/// `custom_message`, `label` and `session_info`.
///
/// Mapping: user text → message(user); assistant text → message(assistant),
/// each `toolCall` → tool_use (plus file_reference for a `path` argument), an
/// error `stopReason` with `errorMessage` → message(system); `bashExecution`
/// (the human's `!` command) → tool_use("bash"); `compaction` and
/// `branch_summary` → message(system); displayed `custom_message` →
/// message(system). Tool results, thinking and settings entries are not
/// transcript. A header with a version above 3 stops the reader
/// (`error.Protocol`) rather than guessing (decision-7, rule 4). The tree is
/// read in file order, so abandoned branches appear too.
pub const SessionReader = struct {
    allocator: Allocator,
    feed: LineFeed,
    arena: std.heap.ArenaAllocator,
    header_seen: bool = false,
    unsupported: bool = false,
    session_id_buf: [event.max_identifier_bytes]u8 = undefined,
    session_id_len: usize = 0,

    pub const max_supported_version = 3;

    pub fn init(allocator: Allocator, max_line_bytes: usize) SessionReader {
        return .{
            .allocator = allocator,
            .feed = .{ .limit = @max(max_line_bytes, overflow_head_bytes) },
            .arena = .init(allocator),
        };
    }

    pub fn deinit(self: *SessionReader) void {
        self.feed.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn sessionId(self: *const SessionReader) ?[]const u8 {
        return if (self.session_id_len == 0) null else self.session_id_buf[0..self.session_id_len];
    }

    /// Whether `feed` has room for more bytes (callers stop reading
    /// otherwise until `drain` makes some).
    pub fn hasRoom(self: *const SessionReader) bool {
        return self.feed.hasRoom();
    }

    /// Append the next bytes of the file.
    pub fn feedBytes(self: *SessionReader, bytes: []const u8) Allocator.Error!void {
        try self.feed.append(self.allocator, bytes);
    }

    /// Push the events of every complete line into `queue` and return how
    /// many. A full queue keeps the rest for the next call.
    pub fn drain(self: *SessionReader, queue: *event.EventQueue) Error!usize {
        if (self.unsupported) return error.Protocol;
        var pushed: usize = 0;
        while (self.feed.peekLine()) |line| {
            _ = self.arena.reset(.retain_capacity);
            var events: LineEvents = .{};
            try self.mapLine(self.arena.allocator(), line, &events);
            if (self.unsupported) return error.Protocol;
            if (!pushEvents(&self.feed, &events, queue, &pushed)) {
                self.feed.compact();
                return pushed;
            }
            self.feed.consumeLine();
        }
        self.feed.compact();
        return pushed;
    }

    fn mapLine(self: *SessionReader, arena: Allocator, line: []const u8, events: *LineEvents) Allocator.Error!void {
        if (line.len == 0) return;
        const root = json.parseFromSliceLeaky(json.Value, arena, line, .{
            .duplicate_field_behavior = .use_last,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.debug("ignored a session line that is not JSON", .{});
                return;
            },
        };
        const kind = stringField(root, "type") orelse return;
        if (!self.header_seen) {
            if (!std.mem.eql(u8, kind, "session")) return;
            self.header_seen = true;
            const version: i64 = if (field(root, "version")) |v| (if (v == .integer) v.integer else 0) else 1;
            if (version < 1 or version > max_supported_version) {
                log.debug("session format version {d} is not supported", .{version});
                self.unsupported = true;
                return;
            }
            if (stringField(root, "id")) |id| {
                if (id.len <= self.session_id_buf.len) {
                    @memcpy(self.session_id_buf[0..id.len], id);
                    self.session_id_len = id.len;
                }
            }
            return;
        }
        if (std.mem.eql(u8, kind, "message")) {
            const message = field(root, "message") orelse return;
            const role = stringField(message, "role") orelse return;
            if (std.mem.eql(u8, role, "user")) {
                const text = try contentText(arena, field(message, "content"));
                addMessage(events, .user, text.text, text.truncated);
            } else if (std.mem.eql(u8, role, "assistant")) {
                const text = try contentText(arena, field(message, "content"));
                addMessage(events, .assistant, text.text, text.truncated);
                if (field(message, "content")) |content| {
                    if (content == .array) {
                        for (content.array.items) |block| {
                            if (!eql(stringField(block, "type"), "toolCall")) continue;
                            const args = field(block, "arguments");
                            addToolUse(events, stringField(block, "name"), argsSummary(args), if (args) |a| stringField(a, "path") else null);
                        }
                    }
                }
                if (eql(stringField(message, "stopReason"), "error")) {
                    if (stringField(message, "errorMessage")) |error_message| {
                        const clipped = clip(error_message);
                        addMessage(events, .system, clipped.text, clipped.truncated);
                    }
                }
            } else if (std.mem.eql(u8, role, "bashExecution")) {
                addToolUse(events, "bash", stringField(message, "command") orelse "", null);
            }
        } else if (std.mem.eql(u8, kind, "compaction") or std.mem.eql(u8, kind, "branch_summary")) {
            const text = clip(stringField(root, "summary") orelse "");
            addMessage(events, .system, text.text, text.truncated);
        } else if (std.mem.eql(u8, kind, "custom_message")) {
            if (boolField(root, "display") != true) return;
            const text = try contentText(arena, field(root, "content"));
            addMessage(events, .system, text.text, text.truncated);
        }
    }
};

// Tests ---------------------------------------------------------------------

const testing = std.testing;

const test_token = iface.CorrelationToken.parse("0123456789abcdef0123456789abcdef") catch unreachable;

/// An in-memory transport: `input` is served in `chunk`-sized reads, writes
/// and decisions are recorded.
const MemoryTransport = struct {
    input: []const u8 = "",
    offset: usize = 0,
    chunk: usize = 7,
    end_after_input: bool = false,
    written: std.ArrayList(u8) = .empty,
    decided: std.ArrayList(u8) = .empty,
    allocator: Allocator = testing.allocator,

    const vtable_rpc: Transport.VTable = .{ .read = read, .write = write };
    const vtable_tui: Transport.VTable = .{ .read = read, .decide = decide };

    fn rpc(self: *MemoryTransport) Transport {
        return .{ .ptr = self, .vtable = &vtable_rpc };
    }

    fn tui(self: *MemoryTransport) Transport {
        return .{ .ptr = self, .vtable = &vtable_tui };
    }

    fn deinit(self: *MemoryTransport) void {
        self.written.deinit(self.allocator);
        self.decided.deinit(self.allocator);
    }

    fn read(ptr: *anyopaque, out: []u8) Error!usize {
        const self: *MemoryTransport = @ptrCast(@alignCast(ptr));
        if (self.offset == self.input.len) return if (self.end_after_input) error.Disconnected else 0;
        const n = @min(@min(self.chunk, out.len), self.input.len - self.offset);
        @memcpy(out[0..n], self.input[self.offset..][0..n]);
        self.offset += n;
        return n;
    }

    fn write(ptr: *anyopaque, bytes: []const u8) Error!void {
        const self: *MemoryTransport = @ptrCast(@alignCast(ptr));
        try self.written.appendSlice(self.allocator, bytes);
    }

    fn decide(ptr: *anyopaque, id: []const u8, decision: []const u8) Error!void {
        const self: *MemoryTransport = @ptrCast(@alignCast(ptr));
        try self.decided.print(self.allocator, "{s}={s}\n", .{ id, decision });
    }
};

/// Drain everything from `queue` into `out` (owned slots).
fn drainAll(queue: *event.EventQueue, out: []event.StoredEvent) usize {
    return queue.drain(out);
}

fn expectStatus(stored: event.StoredEvent, expected: state.State) !void {
    try testing.expectEqual(event.Event.Kind.status_change, std.meta.activeTag(stored.event));
    try testing.expectEqual(expected, stored.event.status_change.state);
    try testing.expectEqual(state.Source.structured, stored.event.status_change.source);
}

test "the extension reads its sink and token from the environment and writes one line per event" {
    const source = extension_source;
    try testing.expect(std.mem.indexOf(u8, source, "process.env.CONDUIT_AGENT_SINK") != null);
    try testing.expect(std.mem.indexOf(u8, source, "process.env.CONDUIT_AGENT_TOKEN") != null);
    try testing.expect(std.mem.indexOf(u8, source, "process.env.CONDUIT_AGENT_GATE") != null);
    try testing.expect(std.mem.indexOf(u8, source, "export default function (pi)") != null);
    // One appendFileSync of one JSON object plus LF per emitted event.
    try testing.expect(std.mem.indexOf(u8, source, "JSON.stringify({ v: 1, token: TOKEN, type, ...fields }) + \"\\n\"") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "appendFileSync(join(SINK, \"" ++ events_file_name ++ "\")"));
    try testing.expect(std.mem.indexOf(u8, source, "\"" ++ decisions_dir_name ++ "\"") != null);
    try testing.expect(std.mem.indexOf(u8, source, "ctx.ui.confirm(title, summary, { signal: dialog.signal })") != null);
    for ([_][]const u8{ "session_start", "agent_start", "agent_end", "message_end", "tool_execution_start", "tool_execution_end", "session_shutdown", "tool_call" }) |name| {
        var needle: [64]u8 = undefined;
        const quoted = try std.fmt.bufPrint(&needle, "pi.on(\"{s}\"", .{name});
        try testing.expect(std.mem.indexOf(u8, source, quoted) != null);
    }
    // Dependency-free: Node built-ins only.
    var imports = std.mem.splitScalar(u8, source, '\n');
    while (imports.next()) |line| {
        if (!std.mem.startsWith(u8, line, "import ")) continue;
        try testing.expect(std.mem.indexOf(u8, line, "from \"node:") != null);
    }
}

test "launch describes a TUI with the extension and an RPC agent without a sink" {
    var pi = try PiAdapter.init(testing.allocator, .{ .sink_dir = "/run/conduit/agent-1", .extra_args = &.{ "--provider", "mock" } });
    defer pi.deinit();
    const a = pi.adapter();
    try testing.expectEqual(Harness.pi, a.harness());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const tui = try a.launch(arena.allocator(), .{ .context_kind = .local, .cwd = "/home/user/proj", .initial_prompt = "fix it", .token = test_token });
    const expected_tui = [_][]const u8{ "pi", "--provider", "mock", "-e", "/run/conduit/agent-1/conduit.js", "fix it" };
    try testing.expectEqual(expected_tui.len, tui.argv.len);
    for (expected_tui, tui.argv) |want, got| try testing.expectEqualStrings(want, got);
    try testing.expectEqual(@as(usize, 3), tui.env.len);
    try testing.expectEqualStrings("CONDUIT_AGENT_TOKEN=0123456789abcdef0123456789abcdef", tui.env[0]);
    try testing.expectEqualStrings("CONDUIT_AGENT_SINK=/run/conduit/agent-1", tui.env[1]);
    try testing.expectEqualStrings("CONDUIT_AGENT_GATE=1", tui.env[2]);
    try testing.expectError(error.Unsupported, a.launch(arena.allocator(), .{ .context_kind = .local, .cwd = "/", .initial_prompt = "--help", .token = test_token }));

    const rpc = try a.launch(arena.allocator(), .{ .context_kind = .local, .cwd = "/home/user/proj", .initial_prompt = "go", .token = test_token, .headless = true });
    const expected_rpc = [_][]const u8{ "pi", "--provider", "mock", "--mode", "rpc", "-e", "/run/conduit/agent-1/conduit.js" };
    try testing.expectEqual(expected_rpc.len, rpc.argv.len);
    for (expected_rpc, rpc.argv) |want, got| try testing.expectEqualStrings(want, got);
    try testing.expectEqual(@as(usize, 2), rpc.env.len);
    try testing.expectEqualStrings("CONDUIT_AGENT_GATE=1", rpc.env[1]);
    try testing.expectEqual(Mode.rpc, pi.mode);

    // The held initial prompt goes out on the first poll.
    var transport: MemoryTransport = .{};
    defer transport.deinit();
    pi.setTransport(transport.rpc());
    var queue = try event.EventQueue.init(testing.allocator, testing.io, 4);
    defer queue.deinit(testing.allocator);
    _ = try a.poll(&queue);
    try testing.expectEqualStrings("{\"type\":\"prompt\",\"message\":\"go\"}\n", transport.written.items);

    // The extension needs a directory to live and report in.
    var bare = try PiAdapter.init(testing.allocator, .{});
    defer bare.deinit();
    try testing.expectError(error.Unsupported, bare.adapter().launch(arena.allocator(), .{ .context_kind = .local, .cwd = "/", .token = test_token }));
    try testing.expectError(error.Unsupported, bare.adapter().launch(arena.allocator(), .{ .context_kind = .local, .cwd = "/", .token = test_token, .headless = true }));
    // An ungated RPC agent runs plain Pi.
    var plain = try PiAdapter.init(testing.allocator, .{ .gate = .off });
    defer plain.deinit();
    const plain_spec = try plain.adapter().launch(arena.allocator(), .{ .context_kind = .local, .cwd = "/", .token = test_token, .headless = true });
    try testing.expectEqual(@as(usize, 3), plain_spec.argv.len);
    try testing.expectEqualStrings("rpc", plain_spec.argv[2]);
    try testing.expectEqual(@as(usize, 1), plain_spec.env.len);
}

test "variants differ only by executable and session root" {
    var omp = try PiAdapter.init(testing.allocator, .{ .variant = .omp, .sink_dir = "/s" });
    defer omp.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spec = try omp.adapter().launch(arena.allocator(), .{ .context_kind = .local, .cwd = "/", .token = test_token });
    try testing.expectEqualStrings("omp", spec.argv[0]);
    try testing.expectEqualStrings("-e", spec.argv[1]);
    try testing.expectEqual(Harness.pi, omp.adapter().harness());
    try testing.expectEqualStrings(".pi/agent/sessions", Variant.pi.sessionsRoot());
    try testing.expectEqualStrings(".omp/agent/sessions", Variant.omp.sessionsRoot());
    try testing.expectEqual(Variant.pi, recognizeCommand("/home/u/.nvm/bin/pi").?);
    try testing.expectEqual(Variant.omp, recognizeCommand("omp").?);
    try testing.expect(recognizeCommand("pip") == null);
    try testing.expect(recognizeCommand("/usr/bin/pi/x") == null);

    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings("--home-user-proj--", try sessionDirName(&buffer, "/home/user/proj"));
    try testing.expectEqualStrings("--C--work-x--", try sessionDirName(&buffer, "C:\\work\\x"));
    try testing.expectEqualStrings("--tmp-a--b--", try sessionDirName(&buffer, "/tmp/a/-b"));
    try testing.expectError(error.NoSpaceLeft, sessionDirName(buffer[0..4], "/ab"));
}

test "capabilities follow the mode, the gate and the transport" {
    var transport: MemoryTransport = .{};
    defer transport.deinit();

    var pi = try PiAdapter.init(testing.allocator, .{ .sink_dir = "/s" });
    defer pi.deinit();
    var caps = pi.adapter().capabilities();
    try testing.expect(caps.launch and caps.attach);
    try testing.expect(!caps.poll and !caps.structured_status and !caps.permission_requests);
    try testing.expect(!caps.detect and !caps.subagents and !caps.read_prompt and !caps.update_prompt);
    pi.setTransport(transport.tui());
    caps = pi.adapter().capabilities();
    try testing.expect(caps.poll and caps.structured_status and caps.transcript);
    try testing.expect(caps.permission_requests and caps.respond_permission);
    try testing.expect(!caps.send_input and !caps.stop);
    try testing.expectError(error.Unsupported, pi.adapter().sendInput("x"));
    try testing.expectError(error.Unsupported, pi.adapter().readPrompt(&.{}));

    var ungated = try PiAdapter.init(testing.allocator, .{ .gate = .off, .transport = transport.tui() });
    defer ungated.deinit();
    caps = ungated.adapter().capabilities();
    try testing.expect(caps.poll and !caps.permission_requests and !caps.respond_permission);

    var rpc = try PiAdapter.init(testing.allocator, .{ .mode = .rpc, .gate = .off, .transport = transport.rpc() });
    defer rpc.deinit();
    caps = rpc.adapter().capabilities();
    try testing.expect(caps.send_input and caps.stop and caps.respond_permission and caps.permission_requests);
}

test "sink lines map to events, ignoring other agents and unknown versions" {
    var transport: MemoryTransport = .{ .input = @embedFile("pi/testdata/sink_events.jsonl"), .chunk = 13 };
    defer transport.deinit();
    var pi = try PiAdapter.init(testing.allocator, .{ .sink_dir = "/s", .transport = transport.tui() });
    defer pi.deinit();
    try pi.adapter().attach(.{ .session = @enumFromInt(3), .token = test_token });

    var queue = try event.EventQueue.init(testing.allocator, testing.io, 64);
    defer queue.deinit(testing.allocator);
    const pushed = try pi.adapter().poll(&queue);
    const out = try testing.allocator.alloc(event.StoredEvent, 64);
    defer testing.allocator.free(out);
    const n = drainAll(&queue, out);
    try testing.expectEqual(pushed, n);

    try testing.expectEqualStrings("01a11808-5bb8-7752-8dc7-a8449dd128a6", pi.sessionId().?);
    try testing.expect(std.mem.endsWith(u8, pi.sessionFile().?, "_01a11808-5bb8-7752-8dc7-a8449dd128a6.jsonl"));

    var i: usize = 0;
    try expectStatus(out[i], .idle);
    i += 1;
    try expectStatus(out[i], .working);
    i += 1;
    try testing.expectEqual(event.Role.user, out[i].event.message.role);
    try testing.expectEqualStrings("RUNTOOL", out[i].event.message.text);
    i += 1;
    // The empty assistant text (a pure tool call) is no message.
    try testing.expectEqualStrings("bash", out[i].event.tool_use.name);
    try testing.expectEqualStrings("touch probe_file", out[i].event.tool_use.summary);
    i += 1;
    const request = out[i].event.permission_request;
    try testing.expectEqualStrings("c2398549-1", request.id);
    try testing.expectEqualStrings("Allow bash? touch probe_file", request.title);
    try testing.expectEqual(@as(usize, 2), request.decisions.len);
    try testing.expectEqualStrings("yes", request.decisions[0].id);
    try testing.expectEqual(event.DecisionKind.allow_once, request.decisions[0].kind);
    try testing.expectEqual(event.DecisionKind.reject, request.decisions[1].kind);
    i += 1;
    try testing.expectEqual(event.PermissionOutcome.allowed, out[i].event.permission_resolved.outcome);
    i += 1;
    // The foreign-token and version-2 agent_end lines produced nothing.
    try testing.expectEqualStrings("edit", out[i].event.tool_use.name);
    i += 1;
    try testing.expectEqualStrings("src/main.zig", out[i].event.file_reference.path);
    i += 1;
    try testing.expectEqualStrings("c2398549-2", out[i].event.permission_request.id);
    i += 1;
    try testing.expectEqual(event.PermissionOutcome.resolved_elsewhere, out[i].event.permission_resolved.outcome);
    i += 1;
    try testing.expectEqualStrings("MOCK_OK", out[i].event.message.text);
    i += 1;
    try expectStatus(out[i], .done);
    i += 1;
    try expectStatus(out[i], .working);
    i += 1;
    try testing.expectEqual(event.Role.system, out[i].event.message.role);
    try testing.expectEqualStrings("429 rate limited", out[i].event.message.text);
    i += 1;
    try expectStatus(out[i], .errored);
    i += 1;
    try testing.expectEqual(n, i);
}

test "a confirm round trip through the decision file" {
    var transport: MemoryTransport = .{};
    defer transport.deinit();
    var pi = try PiAdapter.init(testing.allocator, .{ .sink_dir = "/s", .transport = transport.tui() });
    defer pi.deinit();
    const a = pi.adapter();
    try a.attach(.{ .session = @enumFromInt(1), .token = test_token });

    transport.input =
        \\{"v":1,"token":"0123456789abcdef0123456789abcdef","type":"permission_request","id":"c9-1","toolName":"bash","title":"Allow bash?","summary":"rm -rf build"}
        \\
    ;
    var queue = try event.EventQueue.init(testing.allocator, testing.io, 8);
    defer queue.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), try a.poll(&queue));

    try testing.expectError(error.UnknownTarget, a.respondPermission("c9-1", "maybe"));
    try testing.expectError(error.UnknownTarget, a.respondPermission("c9-2", "yes"));
    try a.respondPermission("c9-1", "no");
    try testing.expectEqualStrings("c9-1=no\n", transport.decided.items);

    // The extension's own line closes it; the id is then unknown.
    transport.input =
        \\{"v":1,"token":"0123456789abcdef0123456789abcdef","type":"permission_request","id":"c9-1","toolName":"bash","title":"Allow bash?","summary":"rm -rf build"}
        \\{"v":1,"token":"0123456789abcdef0123456789abcdef","type":"permission_resolved","id":"c9-1","outcome":"rejected","by":"conduit"}
        \\
    ;
    transport.offset = 0;
    _ = try a.poll(&queue);
    try testing.expectError(error.UnknownTarget, a.respondPermission("c9-1", "yes"));

    // An id that is not a safe file name never reaches the transport.
    transport.input =
        \\{"v":1,"token":"0123456789abcdef0123456789abcdef","type":"permission_request","id":"../../etc/x","title":"t"}
        \\
    ;
    transport.offset = 0;
    try testing.expectEqual(@as(usize, 0), try a.poll(&queue));
    try testing.expectError(error.UnknownTarget, a.respondPermission("../../etc/x", "yes"));
    try testing.expect(!isSafeRequestId(""));
    try testing.expect(!isSafeRequestId("a/b"));
    try testing.expect(isSafeRequestId("c123-4_x"));
}

test "RPC lines map to events and answers go back as JSON lines" {
    var transport: MemoryTransport = .{ .input = @embedFile("pi/testdata/rpc_events.jsonl"), .chunk = 100, .end_after_input = true };
    defer transport.deinit();
    var pi = try PiAdapter.init(testing.allocator, .{ .mode = .rpc, .transport = transport.rpc() });
    defer pi.deinit();
    const a = pi.adapter();

    var queue = try event.EventQueue.init(testing.allocator, testing.io, 64);
    defer queue.deinit(testing.allocator);
    _ = try a.poll(&queue);
    const out = try testing.allocator.alloc(event.StoredEvent, 64);
    defer testing.allocator.free(out);
    const n = drainAll(&queue, out);

    var i: usize = 0;
    try expectStatus(out[i], .working);
    i += 1;
    try testing.expectEqualStrings("RUNTOOL", out[i].event.message.text);
    i += 1;
    try testing.expectEqualStrings("bash", out[i].event.tool_use.name);
    try testing.expectEqualStrings("touch probe_file", out[i].event.tool_use.summary);
    i += 1;
    const request = out[i].event.permission_request;
    try testing.expectEqualStrings("1de97134-8939-444f-a390-d94a95616540", request.id);
    try testing.expectEqualStrings("Allow bash? touch probe_file", request.title);
    i += 1;
    try testing.expectEqual(event.Role.assistant, out[i].event.message.role);
    try testing.expectEqualStrings("MOCK_OK", out[i].event.message.text);
    i += 1;
    try expectStatus(out[i], .done);
    i += 1;
    try expectStatus(out[i], .idle); // get_state isStreaming false
    i += 1;
    try testing.expectEqual(n, i);
    try testing.expectEqualStrings("/home/user/.pi/agent/sessions/--home-user-proj--/2026-10-07T20-23-04-158Z_01a11808-acde-7196-99bb-73e29c9aa547.jsonl", pi.sessionFile().?);

    try a.respondPermission("1de97134-8939-444f-a390-d94a95616540", "yes");
    try testing.expectEqualStrings("{\"type\":\"extension_ui_response\",\"id\":\"1de97134-8939-444f-a390-d94a95616540\",\"confirmed\":true}\n", transport.written.items);
    try testing.expectError(error.UnknownTarget, a.respondPermission("1de97134-8939-444f-a390-d94a95616540", "yes"));
    // The adapter reports its own answer, then the ended stream.
    try testing.expectEqual(@as(usize, 1), try a.poll(&queue));
    _ = drainAll(&queue, out);
    try testing.expectEqual(event.PermissionOutcome.allowed, out[0].event.permission_resolved.outcome);
    try testing.expectError(error.Disconnected, a.poll(&queue));

    transport.written.clearRetainingCapacity();
    try a.sendInput("say \"hi\"\n");
    try a.stop();
    try testing.expectEqualStrings("{\"type\":\"prompt\",\"message\":\"say \\\"hi\\\"\\n\"}\n{\"type\":\"abort\"}\n", transport.written.items);
    try testing.expectError(error.Protocol, a.sendInput("\xff"));
    const big = try testing.allocator.alloc(u8, max_input_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    try testing.expectError(error.NoSpaceLeft, a.sendInput(big));
}

test "RPC dialogs, failures and steering while streaming" {
    var transport: MemoryTransport = .{ .chunk = 1 << 20 };
    defer transport.deinit();
    var pi = try PiAdapter.init(testing.allocator, .{ .mode = .rpc, .transport = transport.rpc() });
    defer pi.deinit();
    const a = pi.adapter();
    const full =
        \\{"type":"agent_start"}
        \\{"type":"extension_ui_request","id":"u1","method":"select","title":"Pick one","options":["a","b"]}
        \\{"type":"extension_ui_request","id":"u2","method":"setStatus","statusKey":"k","statusText":"x"}
        \\{"type":"extension_ui_request","id":"u3","method":"notify","message":"heads up"}
        \\{"type":"auto_retry_end","success":false,"attempt":3,"finalError":"529 overloaded"}
        \\{"type":"extension_error","extensionPath":"/x.ts","event":"tool_call","error":"boom"}
        \\{"type":"response","command":"prompt","success":false,"error":"busy"}
        \\{"type":"agent_end","messages":[{"role":"assistant","content":[],"stopReason":"aborted"}]}
        \\
    ;
    var queue = try event.EventQueue.init(testing.allocator, testing.io, 16);
    defer queue.deinit(testing.allocator);
    // While agent_start is the latest news, input steers.
    transport.input = full[0.."{\"type\":\"agent_start\"}\n".len];
    _ = try a.poll(&queue);
    try a.sendInput("also this");
    try testing.expect(std.mem.startsWith(u8, transport.written.items, "{\"type\":\"steer\""));
    transport.input = full;
    _ = try a.poll(&queue);

    const out = try testing.allocator.alloc(event.StoredEvent, 16);
    defer testing.allocator.free(out);
    const n = drainAll(&queue, out);
    const kinds = [_]event.Event.Kind{ .status_change, .status_change, .notification, .notification, .notification, .status_change, .notification, .notification, .status_change };
    try testing.expectEqual(kinds.len, n);
    for (kinds, out[0..n]) |kind, stored| try testing.expectEqual(kind, std.meta.activeTag(stored.event));
    try expectStatus(out[1], .waiting_input);
    try testing.expectEqualStrings("Pick one", out[2].event.notification.body);
    try testing.expectEqualStrings("heads up", out[3].event.notification.body);
    try testing.expectEqualStrings("529 overloaded", out[4].event.notification.body);
    try expectStatus(out[5], .errored);
    try testing.expectEqualStrings("boom", out[6].event.notification.body);
    try testing.expectEqualStrings("busy", out[7].event.notification.body);
    try expectStatus(out[8], .idle);
    // A select is not a permission and cannot be answered here.
    try testing.expectError(error.UnknownTarget, a.respondPermission("u1", "yes"));
}

test "a full queue keeps the rest of a line for the next poll" {
    var transport: MemoryTransport = .{ .input = @embedFile("pi/testdata/sink_events.jsonl"), .chunk = 1 << 20 };
    defer transport.deinit();
    var pi = try PiAdapter.init(testing.allocator, .{ .sink_dir = "/s", .transport = transport.tui() });
    defer pi.deinit();
    try pi.adapter().attach(.{ .session = @enumFromInt(3), .token = test_token });

    var queue = try event.EventQueue.init(testing.allocator, testing.io, 1);
    defer queue.deinit(testing.allocator);
    var out: [1]event.StoredEvent = undefined;
    var names: std.ArrayList(event.Event.Kind) = .empty;
    defer names.deinit(testing.allocator);
    var polls: usize = 0;
    while (polls < 100) : (polls += 1) {
        const pushed = try pi.adapter().poll(&queue);
        if (pushed == 0) break;
        try testing.expectEqual(@as(usize, 1), queue.drain(&out));
        try names.append(testing.allocator, std.meta.activeTag(out[0].event));
    }
    // The same fifteen events as one big poll, in order, with the
    // tool_use + file_reference pair split across polls.
    try testing.expectEqual(@as(usize, 15), names.items.len);
    try testing.expectEqual(event.Event.Kind.tool_use, names.items[6]);
    try testing.expectEqual(event.Event.Kind.file_reference, names.items[7]);
}

test "lines are bounded: an over-long line keeps only its type" {
    var transport: MemoryTransport = .{ .chunk = 50 };
    defer transport.deinit();
    var pi = try PiAdapter.init(testing.allocator, .{ .mode = .rpc, .transport = transport.rpc(), .max_line_bytes = 128 });
    defer pi.deinit();
    const long_end = "{\"type\":\"agent_end\",\"messages\":[{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"" ++ "x" ** 400 ++ "\"}],\"stopReason\":\"error\"}]}\n";
    const long_junk = "{\"id\":\"s\",\"type\":\"response\",\"data\":\"" ++ "y" ** 300 ++ "\"}\n";
    transport.input = "{\"type\":\"agent_start\"}\n" ++ long_junk ++ long_end ++ "not json\n{\"type\":\"agent_start\"}\n";
    var queue = try event.EventQueue.init(testing.allocator, testing.io, 8);
    defer queue.deinit(testing.allocator);
    var total: usize = 0;
    for (0..20) |_| total += try pi.adapter().poll(&queue);
    var out: [8]event.StoredEvent = undefined;
    const n = queue.drain(&out);
    try testing.expectEqual(total, n);
    try testing.expectEqual(@as(usize, 3), n);
    try expectStatus(out[0], .working);
    // The cut agent_end still ends the turn, as done: its stopReason was lost.
    try expectStatus(out[1], .done);
    try expectStatus(out[2], .working);
    try testing.expect(pi.feed.buffer.capacity <= 1024);

    try testing.expectEqualStrings("agent_end", typeFromHead("{\"type\":\"agent_end\",\"x"));
    try testing.expectEqualStrings("unknown", typeFromHead("{\"type\":\"a\\\"b\"}"));
    try testing.expectEqualStrings("unknown", typeFromHead("{\"type\":\"agent_e"));
}

test "the session reader parses a v3 file fed in pieces" {
    const fixture = @embedFile("pi/testdata/session_v3.jsonl");
    var reader = SessionReader.init(testing.allocator, default_max_line_bytes);
    defer reader.deinit();
    var queue = try event.EventQueue.init(testing.allocator, testing.io, 32);
    defer queue.deinit(testing.allocator);
    var offset: usize = 0;
    while (offset < fixture.len) {
        const n = @min(37, fixture.len - offset);
        try reader.feedBytes(fixture[offset..][0..n]);
        offset += n;
        _ = try reader.drain(&queue);
    }
    try testing.expectEqualStrings("01a11808-5bb8-7752-8dc7-a8449dd128a6", reader.sessionId().?);

    var out: [32]event.StoredEvent = undefined;
    const n = queue.drain(&out);
    const Expect = union(enum) { message: struct { event.Role, []const u8 }, tool: struct { []const u8, []const u8 }, file: []const u8 };
    const expected = [_]Expect{
        .{ .message = .{ .user, "RUNTOOL" } },
        .{ .tool = .{ "bash", "touch probe_file" } },
        .{ .message = .{ .assistant, "MOCK_OK" } },
        .{ .message = .{ .user, "Read src/main.zig" } },
        .{ .message = .{ .assistant, "Reading it." } },
        .{ .tool = .{ "read", "src/main.zig" } },
        .{ .file = "src/main.zig" },
        .{ .tool = .{ "bash", "git status" } },
        .{ .message = .{ .system, "User asked for a probe file." } },
        .{ .message = .{ .system, "429 rate limited" } },
    };
    try testing.expectEqual(expected.len, n);
    for (expected, out[0..n]) |want, got| switch (want) {
        .message => |m| {
            try testing.expectEqual(m[0], got.event.message.role);
            try testing.expectEqualStrings(m[1], got.event.message.text);
        },
        .tool => |t| {
            try testing.expectEqualStrings(t[0], got.event.tool_use.name);
            try testing.expectEqualStrings(t[1], got.event.tool_use.summary);
        },
        .file => |path| try testing.expectEqualStrings(path, got.event.file_reference.path),
    };
}

test "the session reader refuses an unknown format version" {
    var reader = SessionReader.init(testing.allocator, 4096);
    defer reader.deinit();
    var queue = try event.EventQueue.init(testing.allocator, testing.io, 4);
    defer queue.deinit(testing.allocator);
    try reader.feedBytes("{\"type\":\"session\",\"version\":4,\"id\":\"x\"}\n{\"type\":\"message\",\"id\":\"a\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}\n");
    try testing.expectError(error.Protocol, reader.drain(&queue));
    try testing.expectEqual(@as(usize, 0), queue.pending());
}

// Integration: the real `pi --mode rpc` with Conduit's extension and a local
// mock model. Skipped when `pi` or `python3` is not installed.

const IntegrationFixture = struct {
    tmp: testing.TmpDir,
    root: []const u8,
    mock: std.process.Child,
    env: std.process.Environ.Map,

    fn init(fixture: *IntegrationFixture, root_buf: []u8) !void {
        const io = testing.io;
        fixture.tmp = testing.tmpDir(.{});
        errdefer fixture.tmp.cleanup();
        const len = try fixture.tmp.dir.realPath(io, root_buf);
        fixture.root = root_buf[0..len];
        try fixture.tmp.dir.createDirPath(io, "agent");
        try fixture.tmp.dir.createDirPath(io, "proj");
        try fixture.tmp.dir.createDirPath(io, "sink/" ++ decisions_dir_name);
        try fixture.tmp.dir.writeFile(io, .{ .sub_path = "sink/" ++ extension_file_name, .data = extension_source });
        try fixture.tmp.dir.writeFile(io, .{ .sub_path = "mock_chat.py", .data = @embedFile("pi/testdata/mock_chat.py") });

        var mock_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const mock_path = try std.fmt.bufPrint(&mock_path_buf, "{s}/mock_chat.py", .{fixture.root});
        fixture.mock = std.process.spawn(io, .{
            .argv = &.{ "python3", mock_path },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return error.SkipZigTest;
        errdefer fixture.mock.kill(io);
        var port_buf: [16]u8 = undefined;
        var port_len: usize = 0;
        while (port_len < port_buf.len) {
            const n = fixture.mock.stdout.?.readStreaming(io, &.{port_buf[port_len..]}) catch return error.SkipZigTest;
            port_len += n;
            if (std.mem.indexOfScalar(u8, port_buf[0..port_len], '\n') != null) break;
        }
        const port = std.mem.trim(u8, port_buf[0..port_len], " \r\n");
        _ = try std.fmt.parseInt(u16, port, 10);

        var models_buf: [512]u8 = undefined;
        const models = try std.fmt.bufPrint(&models_buf,
            \\{{"providers":{{"mock":{{"baseUrl":"http://127.0.0.1:{s}/v1","api":"openai-completions","apiKey":"mock","compat":{{"supportsDeveloperRole":false,"supportsReasoningEffort":false}},"models":[{{"id":"mock-model"}}]}}}}}}
        , .{port});
        try fixture.tmp.dir.writeFile(io, .{ .sub_path = "agent/models.json", .data = models });

        fixture.env = try testing.environ.createMap(testing.allocator);
        errdefer fixture.env.deinit();
        var agent_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        try fixture.env.put("PI_CODING_AGENT_DIR", try std.fmt.bufPrint(&agent_dir_buf, "{s}/agent", .{fixture.root}));
        try fixture.env.put("PI_OFFLINE", "1");
    }

    fn deinit(fixture: *IntegrationFixture) void {
        fixture.mock.kill(testing.io);
        fixture.env.deinit();
        fixture.tmp.cleanup();
    }

    fn path(fixture: *const IntegrationFixture, buf: []u8, sub: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ fixture.root, sub });
    }
};

/// The child's stdio as a `Transport`: non-blocking reads via poll(2).
const PipeTransport = struct {
    child: *std.process.Child,

    const vtable: Transport.VTable = .{ .read = read, .write = write };

    fn transport(self: *PipeTransport) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn read(ptr: *anyopaque, out: []u8) Error!usize {
        const self: *PipeTransport = @ptrCast(@alignCast(ptr));
        const stdout = self.child.stdout orelse return error.Disconnected;
        var fds = [_]std.posix.pollfd{.{ .fd = stdout.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, 0) catch return error.Disconnected;
        if (ready == 0) return 0;
        return stdout.readStreaming(testing.io, &.{out}) catch error.Disconnected;
    }

    fn write(ptr: *anyopaque, bytes: []const u8) Error!void {
        const self: *PipeTransport = @ptrCast(@alignCast(ptr));
        const stdin = self.child.stdin orelse return error.Disconnected;
        stdin.writeStreamingAll(testing.io, bytes) catch return error.Disconnected;
    }
};

/// The sink directory as a `Transport`: tails `events.jsonl`, publishes
/// decisions by rename.
const SinkTransport = struct {
    dir: std.Io.Dir,
    offset: u64 = 0,

    const vtable: Transport.VTable = .{ .read = read, .decide = decide };

    fn transport(self: *SinkTransport) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn read(ptr: *anyopaque, out: []u8) Error!usize {
        const self: *SinkTransport = @ptrCast(@alignCast(ptr));
        const io = testing.io;
        const file = self.dir.openFile(io, events_file_name, .{}) catch return 0;
        defer file.close(io);
        const n = file.readPositional(io, &.{out}, self.offset) catch return error.Disconnected;
        self.offset += n;
        return n;
    }

    fn decide(ptr: *anyopaque, id: []const u8, decision: []const u8) Error!void {
        const self: *SinkTransport = @ptrCast(@alignCast(ptr));
        const io = testing.io;
        var tmp_buf: [max_request_id_bytes + 32]u8 = undefined;
        var final_buf: [max_request_id_bytes + 32]u8 = undefined;
        const tmp_name = std.fmt.bufPrint(&tmp_buf, decisions_dir_name ++ "/.{s}.tmp", .{id}) catch return error.NoSpaceLeft;
        const final_name = std.fmt.bufPrint(&final_buf, decisions_dir_name ++ "/{s}", .{id}) catch return error.NoSpaceLeft;
        self.dir.writeFile(io, .{ .sub_path = tmp_name, .data = decision }) catch return error.Disconnected;
        self.dir.rename(tmp_name, self.dir, final_name, io) catch return error.Disconnected;
    }
};

fn spawnPi(fixture: *IntegrationFixture, env: *const std.process.Environ.Map) !std.process.Child {
    var ext_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    return std.process.spawn(testing.io, .{
        .argv = &.{ "pi", "--mode", "rpc", "--offline", "--provider", "mock", "--model", "mock-model", "-e", try fixture.path(&ext_buf, "sink/" ++ extension_file_name) },
        .cwd = .{ .path = try fixture.path(&cwd_buf, "proj") },
        .environ_map = env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
}

/// Poll `pi` until `done` says so or ten seconds pass, collecting events.
/// Events collected by an integration test, in fixed slots because a
/// `StoredEvent` must not move.
const Seen = struct {
    slots: []event.StoredEvent,
    len: usize = 0,

    fn init() !Seen {
        return .{ .slots = try testing.allocator.alloc(event.StoredEvent, 256) };
    }

    fn deinit(self: *Seen) void {
        testing.allocator.free(self.slots);
    }

    fn items(self: *const Seen) []const event.StoredEvent {
        return self.slots[0..self.len];
    }
};

/// Poll until `done` holds, for at most thirty seconds. `discard`, when
/// given, is a pipe whose output nobody else reads and is emptied each round
/// so its writer never blocks.
fn pollUntil(a: iface.Adapter, queue: *event.EventQueue, seen: *Seen, done: *const fn ([]const event.StoredEvent) bool, discard: ?*PipeTransport) !void {
    const io = testing.io;
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(30));
    var out: [16]event.StoredEvent = undefined;
    while (!done(seen.items())) {
        if (std.Io.Clock.awake.now(io).nanoseconds > deadline.nanoseconds) return error.Timeout;
        if (discard) |pipe| {
            var scratch: [4096]u8 = undefined;
            while ((PipeTransport.read(pipe, &scratch) catch 0) != 0) {}
        }
        _ = try a.poll(queue);
        const n = queue.drain(&out);
        for (out[0..n]) |stored| {
            if (seen.len == seen.slots.len) return error.TestUnexpectedResult;
            try seen.slots[seen.len].store(stored.event);
            seen.len += 1;
        }
        if (n == 0) try std.Io.sleep(io, .fromMilliseconds(20), .awake);
    }
}

fn hasRequest(events: []const event.StoredEvent) bool {
    for (events) |stored| if (stored.event == .permission_request) return true;
    return false;
}

fn hasTurnEnd(events: []const event.StoredEvent) bool {
    for (events) |stored| {
        if (stored.event == .status_change and stored.event.status_change.state == .done) return true;
    }
    return false;
}

fn hasIdleAfterDone(events: []const event.StoredEvent) bool {
    var done = false;
    for (events) |stored| {
        if (stored.event != .status_change) continue;
        if (stored.event.status_change.state == .done) done = true;
        if (done and stored.event.status_change.state == .idle) return true;
    }
    return false;
}

fn countKind(events: []const event.StoredEvent, kind: event.Event.Kind) usize {
    var n: usize = 0;
    for (events) |stored| {
        if (std.meta.activeTag(stored.event) == kind) n += 1;
    }
    return n;
}

test "integration: pi --mode rpc with the gate, answered over RPC" {
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    var fixture: IntegrationFixture = undefined;
    try fixture.init(&root_buf);
    defer fixture.deinit();
    try fixture.env.put("CONDUIT_AGENT_TOKEN", test_token.text());
    try fixture.env.put(gate_env_name, "1");

    var child = try spawnPi(&fixture, &fixture.env);
    defer child.kill(testing.io);
    var pipe: PipeTransport = .{ .child = &child };
    var pi = try PiAdapter.init(testing.allocator, .{ .mode = .rpc, .transport = pipe.transport() });
    defer pi.deinit();
    const a = pi.adapter();

    var queue = try event.EventQueue.init(testing.allocator, testing.io, 32);
    defer queue.deinit(testing.allocator);
    var seen = try Seen.init();
    defer seen.deinit();

    try a.sendInput("RUNTOOL");
    try pollUntil(a, &queue, &seen, hasRequest, null);
    var request_id: [max_request_id_bytes]u8 = undefined;
    var request_len: usize = 0;
    for (seen.items()) |stored| if (stored.event == .permission_request) {
        const id = stored.event.permission_request.id;
        @memcpy(request_id[0..id.len], id);
        request_len = id.len;
        try testing.expectEqualStrings("Allow bash? touch probe_file", stored.event.permission_request.title);
    };
    try a.respondPermission(request_id[0..request_len], decision_yes);
    try pollUntil(a, &queue, &seen, hasTurnEnd, null);
    try PipeTransport.write(&pipe, "{\"id\":\"s\",\"type\":\"get_state\"}\n");
    try pollUntil(a, &queue, &seen, hasIdleAfterDone, null);

    try expectStatus(seen.items()[0], .working);
    try testing.expectEqual(@as(usize, 1), countKind(seen.items(), .permission_request));
    try testing.expectEqual(@as(usize, 1), countKind(seen.items(), .permission_resolved));
    try testing.expectEqual(@as(usize, 1), countKind(seen.items(), .tool_use));
    try testing.expect(countKind(seen.items(), .message) >= 2);
    // The tool ran: the confirm answer reached Pi.
    try fixture.tmp.dir.access(testing.io, "proj/probe_file", .{});
    // Pi wrote its session JSONL, and the reader recovers the transcript.
    const session_file = pi.sessionFile() orelse return error.TestUnexpectedResult;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, session_file, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);
    var reader = SessionReader.init(testing.allocator, default_max_line_bytes);
    defer reader.deinit();
    try reader.feedBytes(bytes);
    _ = try reader.drain(&queue);
    var out: [32]event.StoredEvent = undefined;
    const n = queue.drain(&out);
    try testing.expectEqualStrings(pi.sessionId().?, reader.sessionId().?);
    try testing.expectEqualStrings("RUNTOOL", out[0].event.message.text);
    try testing.expectEqualStrings("bash", out[1].event.tool_use.name);
    try testing.expectEqualStrings("MOCK_OK", out[n - 1].event.message.text);
}

test "integration: the extension's sink and decision file, as a TUI session uses them" {
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    var fixture: IntegrationFixture = undefined;
    try fixture.init(&root_buf);
    defer fixture.deinit();
    var sink_buf: [std.fs.max_path_bytes]u8 = undefined;
    try fixture.env.put(sink_env_name, try fixture.path(&sink_buf, "sink"));
    try fixture.env.put("CONDUIT_AGENT_TOKEN", test_token.text());
    try fixture.env.put(gate_env_name, "1");

    // RPC only drives the prompt here; Pi's confirm dialog stays unanswered
    // on stdout, standing in for the TUI dialog the human ignores.
    var child = try spawnPi(&fixture, &fixture.env);
    defer child.kill(testing.io);
    var pipe: PipeTransport = .{ .child = &child };
    try PipeTransport.write(&pipe, "{\"type\":\"prompt\",\"message\":\"RUNTOOL\"}\n");

    var sink_dir = try fixture.tmp.dir.openDir(testing.io, "sink", .{});
    defer sink_dir.close(testing.io);
    var sink: SinkTransport = .{ .dir = sink_dir };
    var pi = try PiAdapter.init(testing.allocator, .{ .sink_dir = "unused", .transport = sink.transport() });
    defer pi.deinit();
    const a = pi.adapter();
    try a.attach(.{ .session = @enumFromInt(1), .token = test_token });

    var queue = try event.EventQueue.init(testing.allocator, testing.io, 32);
    defer queue.deinit(testing.allocator);
    var seen = try Seen.init();
    defer seen.deinit();
    try pollUntil(a, &queue, &seen, hasRequest, &pipe);
    var request_id: [max_request_id_bytes]u8 = undefined;
    var request_len: usize = 0;
    for (seen.items()) |stored| if (stored.event == .permission_request) {
        const id = stored.event.permission_request.id;
        @memcpy(request_id[0..id.len], id);
        request_len = id.len;
    };
    try a.respondPermission(request_id[0..request_len], decision_yes);
    try pollUntil(a, &queue, &seen, hasTurnEnd, &pipe);

    try expectStatus(seen.items()[0], .idle); // session_start
    try expectStatus(seen.items()[1], .working);
    try testing.expectEqual(@as(usize, 1), countKind(seen.items(), .permission_request));
    for (seen.items()) |stored| if (stored.event == .permission_resolved) {
        try testing.expectEqual(event.PermissionOutcome.allowed, stored.event.permission_resolved.outcome);
    };
    try testing.expectEqual(@as(usize, 1), countKind(seen.items(), .permission_resolved));
    try testing.expectEqual(@as(usize, 1), countKind(seen.items(), .tool_use));
    try fixture.tmp.dir.access(testing.io, "proj/probe_file", .{});
    try testing.expect(pi.sessionFile() != null);
}
