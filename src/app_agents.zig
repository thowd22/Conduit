//! The app's agent runtime (TASK-56): the one owner of the agent registry,
//! the per-agent adapters and their owner-side transports, the PTY
//! heuristics every agent has, the in-app notification list and the OS
//! notification seam. TASK-57 (permission UI), TASK-58 (agent manager),
//! TASK-60 (control API) and TASK-64 build on this API rather than on the
//! adapters directly.
//!
//! A file of the `app` module rather than a module of its own because only
//! the composition root consumes it; it may use everything `app` may.
//! Nothing here special-cases a harness beyond constructing its adapter and
//! the owner-side IO that adapter asks for (invariant 9 keeps harness
//! behaviour inside `agent/`); everything else talks to `agent.Adapter`.
//!
//! Threads: `Runtime` and every `Runner` field not marked otherwise belong to
//! the owner (UI) thread. Each launched agent has one IO worker that alone
//! calls its adapter's `attach` and `poll` and pushes into that agent's
//! `EventQueue`; the owner drains the queues in `Runtime.poll`. The spawn
//! worker (`App`'s `Load`) calls `Runner.prepare` before the poll worker
//! exists, so an adapter never has two callers at once. Harness detection
//! and OS notifications run on short-lived workers joined by `poll` and
//! `deinit`. No worker touches the registry, the list or any UI.
//!
//! Safety (CONDUIT.md §11): harness and terminal text is display data. It is
//! copied, bounded and shown; nothing here opens, runs or answers anything
//! because of it, and none of it is logged above debug.
//!
//! Memory: the runtime owns every runner, detection and OS job, allocated
//! from the allocator given to `init` and released by `deinit`. Bounded
//! fixed storage everywhere text is kept.

const std = @import("std");
const builtin = @import("builtin");
const agent = @import("agent");
const workspace = @import("workspace");
const session = @import("session");
const config = @import("config");
const platform = @import("platform");
const inputmod = @import("input");
const agent_view = @import("agent_view.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;

pub const log = std.log.scoped(.agents);

const WorkspaceKey = workspace.WorkspaceKey;
const SessionId = session.SessionId;
const State = agent.State;
const Harness = agent.Harness;
const AgentId = agent.AgentId;

// Glyphs ------------------------------------------------------------------------

/// The sidebar glyph for an agent state (TASK-56). Box-drawing-adjacent
/// symbols from the bundled face, never emoji: `·` idle, `▸` working,
/// `?` waiting for input, `!` waiting for permission, `✓` done, `×` errored.
pub fn stateGlyph(state: State) []const u8 {
    return switch (state) {
        .idle => "·",
        .working => "▸",
        .waiting_input => "?",
        .waiting_permission => "!",
        .done => "✓",
        .errored => "×",
    };
}

/// How much a state needs the human, highest first: a blocked agent beats a
/// failed one, which beats a finished one, which beats a busy one.
pub fn urgency(state: State) u8 {
    return switch (state) {
        .waiting_permission => 5,
        .waiting_input => 4,
        .errored => 3,
        .done => 2,
        .working => 1,
        .idle => 0,
    };
}

/// The most urgent of `states`, or null for none.
pub fn mostUrgent(states: []const State) ?State {
    var best: ?State = null;
    for (states) |state| {
        if (best == null or urgency(state) > urgency(best.?)) best = state;
    }
    return best;
}

// The agent manager (TASK-58) ------------------------------------------------------

/// The word the manager shows for an agent's state: `exited` once its
/// process ended, otherwise the state's label.
pub fn managerStateWord(record: *const agent.Agent) []const u8 {
    if (record.hasExited()) return "exited";
    return record.state.label();
}

/// What one manager row shows. Every text is borrowed display data.
pub const ManagerColumns = struct {
    glyph: []const u8,
    harness: []const u8,
    workspace: []const u8,
    tab: []const u8,
    /// The backlog task the agent works on (TASK-64, `Runner.taskId`), or
    /// null for an agent not started from a task: the column shows `–`.
    task: ?[]const u8 = null,
    state: []const u8,
    age: []const u8,
};

/// `<glyph> <harness>  <workspace> › <tab>  <task>  <state>  <age>`, cut at
/// the last whole character that fits `buffer`.
pub fn formatManagerRow(buffer: []u8, columns: ManagerColumns) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    writer.print("{s} {s}  {s} › {s}  {s}  {s}  {s}", .{
        columns.glyph,
        columns.harness,
        columns.workspace,
        columns.tab,
        columns.task orelse "–",
        columns.state,
        columns.age,
    }) catch {
        // A row cut by the fixed buffer still starts with its glyph and name.
    };
    var len = writer.end;
    while (len != 0 and !std.unicode.utf8ValidateSlice(buffer[0..len])) len -= 1;
    return buffer[0..len];
}

/// Where a manager row sorts: its workspace in sidebar order, then its tab
/// in that workspace's tab order (agents whose session is in no tab last),
/// then its agent id.
pub const ManagerSortKey = struct {
    workspace_rank: usize,
    tab_rank: usize,
    id: AgentId,

    fn lessThan(_: void, a: ManagerSortKey, b: ManagerSortKey) bool {
        if (a.workspace_rank != b.workspace_rank) return a.workspace_rank < b.workspace_rank;
        if (a.tab_rank != b.tab_rank) return a.tab_rank < b.tab_rank;
        return @intFromEnum(a.id) < @intFromEnum(b.id);
    }
};

/// Sort manager rows in place into the order the manager lists them.
pub fn sortManagerRows(keys: []ManagerSortKey) void {
    std.sort.pdq(ManagerSortKey, keys, {}, ManagerSortKey.lessThan);
}

// Notifications -------------------------------------------------------------------

/// What a notification is about; each kind has its own `notifications.*`
/// switch.
pub const Kind = enum {
    permission,
    input,
    done,
    @"error",
    terminal,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .permission => "permission",
            .input => "input",
            .done => "done",
            .@"error" => "error",
            .terminal => "terminal",
        };
    }

    /// The kind an agent state announces, or null when it announces nothing.
    pub fn forState(state: State) ?Kind {
        return switch (state) {
            .waiting_permission => .permission,
            .waiting_input => .input,
            .done => .done,
            .errored => .@"error",
            .idle, .working => null,
        };
    }
};

/// Whether `settings` lets a notification of `kind` from `harness` (null for
/// a plain terminal) through at all.
pub fn allowed(settings: config.Notifications, kind: Kind, harness: ?Harness) bool {
    if (!settings.enabled) return false;
    const by_kind = switch (kind) {
        .permission => settings.permission,
        .input => settings.input,
        .done => settings.done,
        .@"error" => settings.@"error",
        .terminal => settings.terminal,
    };
    if (!by_kind) return false;
    const h = harness orelse return true;
    return switch (h) {
        .claude_code => settings.claude_code,
        .codex => settings.codex,
        .pi => settings.pi,
        .opencode => settings.opencode,
    };
}

pub const entry_title_capacity = 96;
pub const entry_body_capacity = 256;

/// One notification. Its text is copied, cleaned display data.
pub const Entry = struct {
    /// Monotonic, never reused; the list's newest has the highest.
    seq: u64,
    kind: Kind,
    workspace: WorkspaceKey,
    session: SessionId,
    agent: ?AgentId = null,
    harness: ?Harness = null,
    /// `Io.Clock.awake` nanoseconds when it was raised, for its age.
    raised_ns: i96,
    title_bytes: [entry_title_capacity]u8 = undefined,
    title_len: usize = 0,
    body_bytes: [entry_body_capacity]u8 = undefined,
    body_len: usize = 0,

    pub fn title(self: *const Entry) []const u8 {
        return self.title_bytes[0..self.title_len];
    }

    pub fn body(self: *const Entry) []const u8 {
        return self.body_bytes[0..self.body_len];
    }

    fn setTitle(self: *Entry, text: []const u8) void {
        self.title_len = copyDisplay(&self.title_bytes, text).len;
    }

    fn setBody(self: *Entry, text: []const u8) void {
        self.body_len = copyDisplay(&self.body_bytes, text).len;
    }
};

/// Copy `text` into `out` as one display line: controls become spaces and the
/// copy ends at the last whole UTF-8 character that fits. Text that is not
/// UTF-8 is cut at its first malformed byte.
pub fn copyDisplay(out: []u8, text: []const u8) []const u8 {
    var end: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch break;
        if (index + length > text.len) break;
        _ = std.unicode.utf8Decode(text[index .. index + length]) catch break;
        if (end + length > out.len) break;
        @memcpy(out[end..][0..length], text[index .. index + length]);
        if (length == 1 and (out[end] < 0x20 or out[end] == 0x7f)) out[end] = ' ';
        end += length;
        index += length;
    }
    return out[0..end];
}

/// A bounded list of notifications, newest kept, oldest evicted.
pub const NotificationList = struct {
    pub const capacity = 32;

    entries: [capacity]Entry = undefined,
    /// Index of the oldest entry.
    head: usize = 0,
    len: usize = 0,
    next_seq: u64 = 1,

    /// Append a new entry, evicting the oldest when full, and return it.
    pub fn push(self: *NotificationList, kind: Kind, key: WorkspaceKey, id: SessionId, raised_ns: i96) *Entry {
        if (self.len == capacity) {
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
        }
        const index = (self.head + self.len) % capacity;
        self.len += 1;
        self.entries[index] = .{
            .seq = self.next_seq,
            .kind = kind,
            .workspace = key,
            .session = id,
            .raised_ns = raised_ns,
        };
        self.next_seq += 1;
        return &self.entries[index];
    }

    pub fn count(self: *const NotificationList) usize {
        return self.len;
    }

    /// The `index`th entry, newest first.
    pub fn newest(self: *const NotificationList, index: usize) ?*const Entry {
        if (index >= self.len) return null;
        return &self.entries[(self.head + self.len - 1 - index) % capacity];
    }

    /// The entry with sequence number `seq`, if it is still kept.
    pub fn bySeq(self: *const NotificationList, seq: u64) ?*const Entry {
        var index: usize = 0;
        while (index < self.len) : (index += 1) {
            const entry = &self.entries[(self.head + index) % capacity];
            if (entry.seq == seq) return entry;
        }
        return null;
    }

    pub fn clear(self: *NotificationList) void {
        self.head = 0;
        self.len = 0;
    }

    /// Forget every entry of a closed workspace.
    pub fn removeWorkspace(self: *NotificationList, key: WorkspaceKey) void {
        var kept: [capacity]Entry = undefined;
        var kept_len: usize = 0;
        var index: usize = 0;
        while (index < self.len) : (index += 1) {
            const entry = self.entries[(self.head + index) % capacity];
            if (entry.workspace == key) continue;
            kept[kept_len] = entry;
            kept_len += 1;
        }
        @memcpy(self.entries[0..kept_len], kept[0..kept_len]);
        self.head = 0;
        self.len = kept_len;
    }
};

// The OS notification seam ------------------------------------------------------

/// Where OS notifications go. The default (`notify_fn == null`) shows them
/// through `platform.notify` on a worker; checks install an observer, like
/// the link-opener seam, to prove when one would be raised.
pub const Notifier = struct {
    context: ?*anyopaque = null,
    notify_fn: ?*const fn (?*anyopaque, title: []const u8, body: []const u8) void = null,
};

/// The most OS notifications in flight at once; more are dropped (logged at
/// debug) rather than queued behind a stuck helper.
const max_os_jobs = 4;

const OsJob = struct {
    allocator: Allocator,
    io: Io,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    title_bytes: [platform.max_notify_title_bytes]u8 = undefined,
    title_len: usize = 0,
    body_bytes: [platform.max_notify_body_bytes]u8 = undefined,
    body_len: usize = 0,

    fn work(self: *OsJob) void {
        defer self.done.store(true, .release);
        platform.notify(self.allocator, self.io, self.title_bytes[0..self.title_len], self.body_bytes[0..self.body_len]) catch |err| switch (err) {
            // A missing helper is ordinary on a minimal desktop; say so once
            // at debug from the owner instead of on every notification.
            error.Unavailable, error.Unsupported => unavailable_seen.store(true, .release),
            else => log.debug("the OS notification was not shown: {s}", .{@errorName(err)}),
        };
    }
};

var unavailable_seen: std.atomic.Value(bool) = .init(false);

// Harness choices ----------------------------------------------------------------

/// What `agent.launch` can start: a shipped harness, or the scripted fake
/// that deterministic checks enable.
pub const Choice = union(enum) {
    harness: Harness,
    fake,

    pub fn value(self: Choice) []const u8 {
        return switch (self) {
            .harness => |h| @tagName(h),
            .fake => fake_choice_value,
        };
    }

    pub fn parse(text: []const u8) ?Choice {
        if (std.mem.eql(u8, text, fake_choice_value)) return .fake;
        const h = Harness.parse(text) catch return null;
        return .{ .harness = h };
    }

    /// The harness the registry records. The fake impersonates Claude Code,
    /// so it adds no harness of its own to the closed set.
    pub fn registryHarness(self: Choice) Harness {
        return switch (self) {
            .harness => |h| h,
            .fake => .claude_code,
        };
    }

    /// Whether the side channel needs files on this machine, which only a
    /// Local workspace's harness can read today (TASK-61 moves them behind
    /// the context).
    pub fn needsLocalSink(self: Choice) bool {
        return switch (self) {
            .harness => |h| h == .claude_code or h == .pi,
            .fake => true,
        };
    }
};

pub const fake_choice_value = "fake";
pub const fake_choice_label = "Fake agent (test)";

/// The fake agent's process: a real shell that prints a readiness marker and
/// then turns every line the human types into one step of the script, by
/// appending a byte to `$CONDUIT_AGENT_SINK/steps`. The adapter side releases
/// one step's events per byte, so a check advances the agent through the real
/// keyboard path and never by time.
pub const fake_agent_script =
    "printf 'FAKE-AGENT-READY\\n'; n=0; " ++
    "while IFS= read -r line; do n=$((n+1)); printf x >> \"$CONDUIT_AGENT_SINK/steps\"; " ++
    "printf 'FAKE-STEP %s\\n' \"$n\"; done";

const fake_argv = [_][]const u8{ "/bin/sh", "-c", fake_agent_script };

const fake_decisions = [_]agent.Decision{
    .{ .id = "allow", .label = "Allow once", .kind = .allow_once },
    .{ .id = "deny", .label = "Reject", .kind = .reject },
};

/// The fake's script: idle → working → waiting for permission → (resolved)
/// done → working → errored → working → waiting for permission again,
/// released in the step groups below.
pub const fake_script = [_]agent.Event{
    .{ .status_change = .{ .state = .working, .source = .structured } },
    .{ .permission_request = .{ .id = "fake-1", .title = "Run: make test", .decisions = &fake_decisions } },
    .{ .permission_resolved = .{ .id = "fake-1", .outcome = .allowed } },
    .{ .status_change = .{ .state = .done, .source = .structured } },
    .{ .status_change = .{ .state = .working, .source = .structured } },
    .{ .status_change = .{ .state = .errored, .source = .structured } },
    .{ .status_change = .{ .state = .working, .source = .structured } },
    .{ .permission_request = .{ .id = "fake-2", .title = "Edit: build.zig", .decisions = &fake_decisions } },
};

/// Events released after 1, 2, 3, 4 and 5 steps.
pub const fake_step_ends = [_]usize{ 1, 2, 4, 6, 8 };

/// How many script events `steps` typed lines release.
pub fn fakeReleased(steps: u64) usize {
    return fakeReleasedBy(&fake_step_ends, steps);
}

fn fakeReleasedBy(ends: []const usize, steps: u64) usize {
    if (steps == 0 or ends.len == 0) return 0;
    const index: usize = @intCast(@min(steps, ends.len) - 1);
    return ends[index];
}

/// The file `--agent-view-test`'s scripted file reference names, inside the
/// check's private directory (the parent of the sink root).
pub const fake_view_sample_name = "agent-view-sample.txt";
/// The line that reference points at.
pub const fake_view_sample_line = 3;

const fake_view_decisions = [_]agent.Decision{
    .{ .id = "allow", .label = "Allow once", .kind = .allow_once },
    .{ .id = "deny", .label = "Reject", .kind = .reject },
};

/// `--agent-view-test`'s script (TASK-57): one of every event kind the view
/// shows, two permission requests, and a last step that finishes the turn.
/// `sample_path` is the file reference's target; the result borrows it and
/// is allocated in `allocator`.
pub fn fakeViewScript(allocator: Allocator, sample_path: []const u8) Allocator.Error![]const agent.Event {
    const script = [_]agent.Event{
        .{ .status_change = .{ .state = .working, .source = .structured } },
        .{ .message = .{ .role = .user, .text = "Run the tests and fix whatever fails." } },
        .{ .message = .{ .role = .assistant, .text = "I will run the test suite first, then read the failing file and fix the smallest thing that makes it pass. The build compiles every module and runs the unit tests in each file." } },
        .{ .tool_use = .{ .name = "Bash", .summary = "zig build test" } },
        .{ .message = .{ .role = .assistant, .text = "One test fails in the sample file; the reference below opens it at the failing line." } },
        .{ .file_reference = .{ .path = sample_path, .line = fake_view_sample_line } },
        .{ .permission_request = .{ .id = "view-1", .title = "Run: zig build test --summary all", .decisions = &fake_view_decisions } },
        .{ .subagent = .{ .id = "sub-1", .name = "explore", .phase = .start } },
        .{ .tool_use = .{ .name = "Grep", .summary = "pub fn main" } },
        .{ .subagent = .{ .id = "sub-1", .name = "explore", .phase = .stop } },
        .{ .notification = .{ .title = "Claude", .body = "Claude needs your permission" } },
        .{ .permission_request = .{ .id = "view-2", .title = "Edit: src/sample.zig", .decisions = &fake_view_decisions } },
        .{ .message = .{ .role = .assistant, .text = "All tests pass now." } },
        .{ .status_change = .{ .state = .done, .source = .structured } },
    };
    return allocator.dupe(agent.Event, &script);
}

/// The view script's steps: everything up to the second request, then the
/// end of the turn.
pub const fake_view_step_ends = [_]usize{ 12, 14 };

// Owner-side transports ------------------------------------------------------------

/// The owner half of Pi's sink channel: `events.jsonl` read from where the
/// last read stopped, decisions published by write-then-rename. Local only.
const PiSink = struct {
    io: Io,
    dir_path: []const u8,
    offset: u64 = 0,

    const vtable: agent.pi.Transport.VTable = .{ .read = read, .decide = decide };

    fn transport(self: *PiSink) agent.pi.Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn read(ptr: *anyopaque, out: []u8) agent.AdapterError!usize {
        const self: *PiSink = @ptrCast(@alignCast(ptr));
        var path_buffer: [Dir.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ self.dir_path, agent.pi.events_file_name }) catch return error.NoSpaceLeft;
        const file = Dir.cwd().openFile(self.io, path, .{}) catch return 0;
        defer file.close(self.io);
        const n = file.readPositional(self.io, &.{out}, self.offset) catch return error.Disconnected;
        self.offset += n;
        return n;
    }

    fn decide(ptr: *anyopaque, id: []const u8, decision: []const u8) agent.AdapterError!void {
        const self: *PiSink = @ptrCast(@alignCast(ptr));
        var tmp_buffer: [Dir.max_path_bytes]u8 = undefined;
        var final_buffer: [Dir.max_path_bytes]u8 = undefined;
        const tmp = std.fmt.bufPrint(&tmp_buffer, "{s}/{s}/.{s}.tmp", .{ self.dir_path, agent.pi.decisions_dir_name, id }) catch return error.NoSpaceLeft;
        const final = std.fmt.bufPrint(&final_buffer, "{s}/{s}/{s}", .{ self.dir_path, agent.pi.decisions_dir_name, id }) catch return error.NoSpaceLeft;
        Dir.cwd().writeFile(self.io, .{ .sub_path = tmp, .data = decision, .flags = .{ .permissions = private_file } }) catch return error.Disconnected;
        Dir.cwd().rename(tmp, Dir.cwd(), final, self.io) catch return error.Disconnected;
    }
};

/// The Codex daemon's control socket, connected lazily: the TUI Conduit
/// launches starts the daemon, so the socket may not exist until after the
/// spawn. `connect` opens the Unix socket and then runs the WebSocket
/// handshake; everything else forwards to the WebSocket transport.
const CodexDaemon = struct {
    allocator: Allocator,
    socket_path: []const u8,
    seed: [std.Random.DefaultCsprng.secret_seed_length]u8,
    fd: ?agent.codex.FdStream = null,
    ws: ?agent.codex.WebSocketTransport = null,

    const vtable: agent.codex.Transport.VTable = .{ .connect = connect, .send = send, .receive = receive, .close = close };

    fn transport(self: *CodexDaemon) agent.codex.Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn connect(ptr: *anyopaque) agent.codex.Transport.Error!void {
        const self: *CodexDaemon = @ptrCast(@alignCast(ptr));
        if (self.ws != null) return;
        if (self.socket_path.len == 0) return error.Disconnected;
        self.fd = agent.codex.FdStream.connectUnix(self.socket_path) catch return error.Disconnected;
        self.ws = agent.codex.WebSocketTransport.init(self.allocator, self.fd.?.stream(), .{ .seed = self.seed });
        self.ws.?.transport().connect() catch |err| {
            self.dropConnection();
            return err;
        };
    }

    fn send(ptr: *anyopaque, message: []const u8) agent.codex.Transport.Error!void {
        const self: *CodexDaemon = @ptrCast(@alignCast(ptr));
        var ws = &(self.ws orelse return error.Disconnected);
        return ws.transport().send(message);
    }

    fn receive(ptr: *anyopaque, timeout_ms: u32) agent.codex.Transport.Error!?[]const u8 {
        const self: *CodexDaemon = @ptrCast(@alignCast(ptr));
        var ws = &(self.ws orelse return error.Disconnected);
        return ws.transport().receive(timeout_ms);
    }

    fn close(ptr: *anyopaque) void {
        const self: *CodexDaemon = @ptrCast(@alignCast(ptr));
        self.dropConnection();
    }

    fn dropConnection(self: *CodexDaemon) void {
        if (self.ws) |*ws| {
            ws.transport().close();
            ws.deinit();
        }
        self.ws = null;
        if (self.fd) |*fd| fd.stream().close();
        self.fd = null;
    }
};

const private_dir: File.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
const private_file: File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
const private_executable: File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o700);

/// A free loopback TCP port, by binding port 0 and releasing it. Another
/// process may take it before OpenCode does; the adapter then reports a
/// disconnected channel and the agent keeps its PTY baseline.
fn freeLoopbackPort(io: Io) ?u16 {
    var address = Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch return null;
    var server = address.listen(io, .{}) catch return null;
    defer server.deinit(io);
    return server.socket.address.getPort();
}

// Runners -------------------------------------------------------------------------

/// The adapter of one agent and the owner-side IO under it. Heap-stable:
/// transports point into it.
const Backend = union(enum) {
    fake: agent.FakeAdapter,
    claude: agent.claude_code.ClaudeCodeAdapter,
    pi: struct { adapter: agent.pi.PiAdapter, sink: PiSink },
    codex: struct { adapter: agent.codex.CodexAdapter, daemon: CodexDaemon },
    opencode: agent.opencode.OpenCodeAdapter,
};

/// Everything `prepare` produced for the spawn worker. Borrowed from the
/// runner until it is destroyed.
pub const Prepared = struct {
    argv: []const []const u8,
    env: []const []const u8,
};

pub const PrepareError = Allocator.Error || error{ LaunchRefused, SinkUnavailable, UnsafeFile };

/// One launched agent: its adapter, queue and IO worker.
pub const Runner = struct {
    allocator: Allocator,
    io: Io,
    choice: Choice,
    workspace: WorkspaceKey,
    session: SessionId,
    context_kind: workspace.ExecutionContextKind,
    token: agent.CorrelationToken,
    /// The registry id, once registered.
    agent_id: ?AgentId = null,
    /// Owned; empty when this harness keeps no sink.
    sink_dir: []u8,
    cwd: []u8,
    prompt: ?[]u8,
    backend: Backend,
    queue: agent.EventQueue,
    /// Owned by `prepare` (spawn worker), then read-only.
    arena: std.heap.ArenaAllocator,
    prepared: ?Prepared = null,
    /// Whether `attach` must succeed before `poll` is useful.
    needs_attach: bool = false,
    thread: ?std.Thread = null,
    stop_requested: std.atomic.Value(bool) = .init(false),
    /// Worker-owned.
    attached: bool = false,
    attach_attempts: u32 = 0,
    polling: bool = true,
    wake: Wake,
    /// Owner-thread: a spawn worker holds this runner (between
    /// `startAgentChild` and `spawnFinished`), so it may not be destroyed.
    spawning: bool = false,
    /// Owner-thread: its session closed while spawning; destroyed when the
    /// spawn reports back.
    closing: bool = false,
    /// Owner-thread: the agent view's event log, rows and state (TASK-57).
    /// Filled as the owner drains events; nothing is re-read from the adapter.
    view: agent_view.View,
    /// The fake's release schedule (checks only).
    fake_step_ends: []const usize = &fake_step_ends,
    /// The backlog task the agent was started on (TASK-64), a copy of its
    /// validated id; empty when it was not started from a task.
    task_id_bytes: [max_task_id_bytes]u8 = undefined,
    task_id_len: usize = 0,
    /// Answers and messages waiting for the worker, the adapter's one caller.
    requests_mutex: Io.Mutex = .init,
    requests: [request_capacity]Answer = undefined,
    request_head: usize = 0,
    request_len: usize = 0,

    /// The longest request or decision id an answer carries; stored events
    /// refuse longer ones, so no logged request has one.
    pub const max_answer_id_bytes = 256;
    /// The longest message the agent manager sends in one request (TASK-58).
    pub const max_message_bytes = 1024;
    pub const request_capacity = 8;

    /// One request on its way to the adapter: a permission answer
    /// (`respondPermission`) or a message (`sendInput`).
    pub const Answer = struct {
        kind: RequestKind = .permission,
        request: [max_answer_id_bytes]u8 = undefined,
        request_len: usize = 0,
        decision: [max_answer_id_bytes]u8 = undefined,
        decision_len: usize = 0,
        message: [max_message_bytes]u8 = undefined,
        message_len: usize = 0,

        pub const RequestKind = enum { permission, send_input };
    };

    pub const AnswerError = error{ QueueFull, IdTooLong };

    /// The longest backlog task id a runner records (`backlog.isTaskId`).
    pub const max_task_id_bytes = 64;

    /// The backlog task this agent works on, if it was started from one.
    pub fn taskId(self: *const Runner) ?[]const u8 {
        if (self.task_id_len == 0) return null;
        return self.task_id_bytes[0..self.task_id_len];
    }
    pub const MessageError = error{ QueueFull, MessageTooLong };

    /// Queue the human's answer to permission request `request_id` for the
    /// worker to send. Owner thread; called only from an explicit gesture.
    pub fn answerPermission(self: *Runner, request_id: []const u8, decision_id: []const u8) AnswerError!void {
        if (request_id.len > max_answer_id_bytes or decision_id.len > max_answer_id_bytes) return error.IdTooLong;
        self.requests_mutex.lockUncancelable(self.io);
        defer self.requests_mutex.unlock(self.io);
        if (self.request_len == request_capacity) return error.QueueFull;
        const slot = &self.requests[(self.request_head + self.request_len) % request_capacity];
        slot.kind = .permission;
        @memcpy(slot.request[0..request_id.len], request_id);
        slot.request_len = request_id.len;
        @memcpy(slot.decision[0..decision_id.len], decision_id);
        slot.decision_len = decision_id.len;
        self.request_len += 1;
    }

    /// Queue a message the human typed for the worker to hand to the
    /// adapter's `sendInput` (TASK-58). The text is sent as typed: a
    /// structured channel takes it as one turn, so no line ending is added.
    /// Owner thread; called only from an explicit gesture. The caller checks
    /// the agent's `send_input` capability; an adapter that refuses anyway
    /// is logged at debug by the worker.
    pub fn sendMessage(self: *Runner, text: []const u8) MessageError!void {
        if (text.len > max_message_bytes) return error.MessageTooLong;
        self.requests_mutex.lockUncancelable(self.io);
        defer self.requests_mutex.unlock(self.io);
        if (self.request_len == request_capacity) return error.QueueFull;
        const slot = &self.requests[(self.request_head + self.request_len) % request_capacity];
        slot.kind = .send_input;
        @memcpy(slot.message[0..text.len], text);
        slot.message_len = text.len;
        self.request_len += 1;
    }

    /// Send every queued request. Worker thread (or a test driving
    /// `pollOnce`); the adapter is called outside the lock.
    fn serviceAnswers(self: *Runner) void {
        while (true) {
            var answer: Answer = undefined;
            {
                self.requests_mutex.lockUncancelable(self.io);
                defer self.requests_mutex.unlock(self.io);
                if (self.request_len == 0) return;
                answer = self.requests[self.request_head];
                self.request_head = (self.request_head + 1) % request_capacity;
                self.request_len -= 1;
            }
            switch (answer.kind) {
                .permission => self.adapter().respondPermission(answer.request[0..answer.request_len], answer.decision[0..answer.decision_len]) catch |err| {
                    log.debug("a permission answer was not delivered: {s}", .{@errorName(err)});
                },
                .send_input => self.adapter().sendInput(answer.message[0..answer.message_len]) catch |err| {
                    log.debug("a message was not delivered: {s}", .{@errorName(err)});
                },
            }
        }
    }

    /// The type-erased adapter.
    pub fn adapter(self: *Runner) agent.Adapter {
        return switch (self.backend) {
            .fake => |*fake| fake.asAdapter(),
            .claude => |*claude| claude.adapter(),
            .pi => |*pi| pi.adapter.adapter(),
            .codex => |*codex| codex.adapter.adapter(),
            .opencode => |*opencode| opencode.adapter(),
        };
    }

    /// Describe and stage the launch: run the adapter's `launch`, write every
    /// file it needs into the private sink, and merge its environment over
    /// `base_env`. Called once, on the spawn worker, before the poll worker
    /// starts. The result borrows the runner.
    pub fn prepare(self: *Runner, base_env: []const []const u8) PrepareError!Prepared {
        const arena = self.arena.allocator();
        if (self.sink_dir.len != 0) {
            _ = Dir.cwd().createDirPathStatus(self.io, self.sink_dir, private_dir) catch |err| {
                log.debug("the agent sink cannot be created: {s}", .{@errorName(err)});
                return error.SinkUnavailable;
            };
        }
        const spec = self.adapter().launch(arena, .{
            .context_kind = self.context_kind,
            .cwd = self.cwd,
            .initial_prompt = self.prompt,
            .token = self.token,
        }) catch |err| {
            log.debug("the adapter refused the launch: {s}", .{@errorName(err)});
            return error.LaunchRefused;
        };
        var files: std.ArrayList(agent.LaunchSpec.File) = .empty;
        try files.appendSlice(arena, spec.files);
        var extra_env: std.ArrayList([]const u8) = .empty;
        switch (self.backend) {
            .pi => try files.append(arena, .{
                .path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ self.sink_dir, agent.pi.extension_file_name }),
                .bytes = agent.pi.extension_source,
            }),
            .fake => try extra_env.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ agent.pi.sink_env_name, self.sink_dir })),
            else => {},
        }
        for (files.items) |file| try self.writeLaunchFile(file);
        const env = try mergeEnv(arena, base_env, spec.env, extra_env.items);
        self.prepared = .{ .argv = spec.argv, .env = env };
        return self.prepared.?;
    }

    fn writeLaunchFile(self: *Runner, file: agent.LaunchSpec.File) PrepareError!void {
        // Only a Local workspace's files live on this machine; elsewhere the
        // context would have to carry them (TASK-61).
        if (self.context_kind != .local) return error.UnsafeFile;
        if (self.sink_dir.len == 0 or !std.mem.startsWith(u8, file.path, self.sink_dir) or
            file.path.len <= self.sink_dir.len + 1 or file.path[self.sink_dir.len] != '/' or
            std.mem.indexOf(u8, file.path, "/../") != null) return error.UnsafeFile;
        if (std.fs.path.dirnamePosix(file.path)) |parent| {
            _ = Dir.cwd().createDirPathStatus(self.io, parent, private_dir) catch return error.SinkUnavailable;
        }
        Dir.cwd().writeFile(self.io, .{
            .sub_path = file.path,
            .data = file.bytes,
            .flags = .{ .permissions = if (file.executable) private_executable else private_file },
        }) catch |err| {
            log.debug("a launch file could not be written: {s}", .{@errorName(err)});
            return error.SinkUnavailable;
        };
    }

    /// Start the poll worker once the agent's child is attached.
    pub fn start(self: *Runner) !void {
        if (self.thread != null) return;
        self.thread = try std.Thread.spawn(.{}, work, .{self});
    }

    /// Ask the worker to stop and join it. Owner thread.
    pub fn join(self: *Runner) void {
        self.stop_requested.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn work(self: *Runner) void {
        while (!self.stop_requested.load(.acquire)) {
            self.pollOnce();
            Io.sleep(self.io, .fromMilliseconds(poll_interval_ms), .awake) catch |err| {
                log.debug("the agent worker's wait was cut short: {s}", .{@errorName(err)});
            };
        }
    }

    /// One worker iteration: attach when still needed, then move whatever the
    /// side channel has into the queue. Public so tests can drive a runner
    /// without its thread.
    pub fn pollOnce(self: *Runner) void {
        if (!self.needs_attach or self.attached) self.serviceAnswers();
        if (!self.polling) return;
        if (self.needs_attach and !self.attached) {
            if (self.attach_attempts >= max_attach_attempts) {
                self.polling = false;
                log.debug("the agent's side channel never answered; heuristics only", .{});
                return;
            }
            self.attach_attempts += 1;
            // One attempt per `attach_every` polls, so a daemon that is still
            // starting is not hammered.
            if ((self.attach_attempts - 1) % attach_every != 0) return;
            self.adapter().attach(.{ .session = self.session, .token = self.token }) catch |err| switch (err) {
                error.Unsupported, error.Protocol => {
                    self.polling = false;
                    log.debug("the agent's side channel is unavailable ({s}); heuristics only", .{@errorName(err)});
                    return;
                },
                else => return,
            };
            self.attached = true;
        }
        if (self.backend == .fake) {
            const released = fakeReleasedBy(self.fake_step_ends, self.fakeSteps());
            const fake = &self.backend.fake;
            fake.poll_batch = released -| fake.cursor;
        }
        const pushed = self.adapter().poll(&self.queue) catch |err| switch (err) {
            error.Unsupported => {
                self.polling = false;
                return;
            },
            else => {
                log.debug("the agent poll failed: {s}", .{@errorName(err)});
                return;
            },
        };
        if (pushed != 0) self.wake.send();
    }

    /// Lines the human typed into the fake agent, counted by the bytes its
    /// script appended to the sink.
    fn fakeSteps(self: *Runner) u64 {
        var path_buffer: [Dir.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "{s}/steps", .{self.sink_dir}) catch return 0;
        const stat = Dir.cwd().statFile(self.io, path, .{}) catch return 0;
        return stat.size;
    }

    fn destroy(self: *Runner) void {
        self.join();
        self.adapter().destroy();
        switch (self.backend) {
            .codex => |*codex| codex.daemon.dropConnection(),
            else => {},
        }
        self.queue.deinit(self.allocator);
        self.view.deinit();
        self.arena.deinit();
        if (self.sink_dir.len != 0) {
            // The sink is private run state: gone with the agent.
            Dir.cwd().deleteTree(self.io, self.sink_dir) catch |err| {
                log.debug("the agent sink was not removed: {s}", .{@errorName(err)});
            };
            self.allocator.free(self.sink_dir);
        }
        self.allocator.free(self.cwd);
        if (self.prompt) |prompt| self.allocator.free(prompt);
        self.allocator.destroy(self);
    }
};

const poll_interval_ms = 50;
const attach_every = 20;
const max_attach_attempts = attach_every * 60;
const queue_capacity = 32;

/// `base` with every `NAME=value` of `overlay` and `extra` replacing the entry
/// of the same name, in `allocator`.
pub fn mergeEnv(
    allocator: Allocator,
    base: []const []const u8,
    overlay: []const []const u8,
    extra: []const []const u8,
) Allocator.Error![]const []const u8 {
    var merged: std.ArrayList([]const u8) = .empty;
    outer: for (base) |entry| {
        const name = envName(entry);
        for (overlay) |added| if (std.mem.eql(u8, envName(added), name)) continue :outer;
        for (extra) |added| if (std.mem.eql(u8, envName(added), name)) continue :outer;
        try merged.append(allocator, entry);
    }
    try merged.appendSlice(allocator, overlay);
    try merged.appendSlice(allocator, extra);
    return merged.toOwnedSlice(allocator);
}

fn envName(entry: []const u8) []const u8 {
    const equals = std.mem.indexOfScalar(u8, entry, '=') orelse return entry;
    return entry[0..equals];
}

/// How a worker tells the owner loop that events are waiting.
pub const Wake = struct {
    context: ?*anyopaque = null,
    wake_fn: ?*const fn (?*anyopaque) void = null,

    fn send(self: Wake) void {
        if (self.wake_fn) |f| f(self.context);
    }
};

// Detection --------------------------------------------------------------------

/// Which harnesses one workspace's context has, found once on a worker.
const Detection = struct {
    allocator: Allocator,
    io: Io,
    key: WorkspaceKey,
    context: workspace.ExecutionContext.Ref,
    probe_env: []const []const u8,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    versions: [Harness.all.len][64]u8 = undefined,
    version_lens: [Harness.all.len]?usize = @splat(null),

    fn work(self: *Detection) void {
        defer self.done.store(true, .release);
        for (Harness.all, 0..) |harness, index| {
            self.version_lens[index] = self.detectOne(harness, &self.versions[index]);
        }
    }

    fn detectOne(self: *Detection, harness: Harness, buffer: *[64]u8) ?usize {
        const request: agent.DetectRequest = .{ .context = self.context, .version_buffer = buffer };
        const found = switch (harness) {
            .claude_code => blk: {
                var a = agent.claude_code.ClaudeCodeAdapter.init(self.allocator, self.io, .{ .probe_env = self.probe_env }) catch return null;
                defer a.deinit();
                break :blk a.adapter().detect(request);
            },
            .pi => blk: {
                var a = agent.pi.PiAdapter.init(self.allocator, self.io, .{}) catch return null;
                defer a.deinit();
                break :blk a.adapter().detect(request);
            },
            .codex => blk: {
                var daemon: CodexDaemon = .{ .allocator = self.allocator, .socket_path = "", .seed = @splat(0) };
                var a = agent.codex.CodexAdapter.init(self.allocator, self.io, .{ .transport = daemon.transport(), .cwd = "/" }) catch return null;
                defer a.deinit();
                break :blk a.adapter().detect(request);
            },
            .opencode => blk: {
                var a = agent.opencode.OpenCodeAdapter.init(self.allocator, self.io, .{ .port = 0 }) catch return null;
                defer a.deinit();
                break :blk a.adapter().detect(request);
            },
        };
        const version = found catch |err| {
            log.debug("{s} detection failed: {s}", .{ @tagName(harness), @errorName(err) });
            return null;
        };
        const text = version orelse return null;
        return text.len;
    }
};

// The runtime -------------------------------------------------------------------

/// One registered agent's PTY baseline.
const Track = struct {
    id: AgentId,
    heuristics: agent.Heuristics = .{},
    last_tick_ns: i96 = 0,
    /// `Io.Clock.awake` nanoseconds of the agent's latest output or event,
    /// for the manager's "last activity" column (TASK-58).
    last_activity_ns: i96 = 0,
};

/// A terminal fact the app reports for one session (see `agent.Observation`).
pub const Observation = agent.Observation;

pub const InitOptions = struct {
    /// Where per-agent sink directories go: private run state. Copied; null
    /// means harnesses that need a sink cannot be launched.
    sink_root: ?[]const u8 = null,
    /// Offer the scripted fake harness (deterministic checks only).
    fake_enabled: bool = false,
    /// Give the fake `--agent-view-test`'s script instead of TASK-56's.
    fake_view: bool = false,
    wake: Wake = .{},
};

pub const LaunchRequest = struct {
    choice: Choice,
    workspace: WorkspaceKey,
    session: SessionId,
    context_kind: workspace.ExecutionContextKind,
    cwd: []const u8,
    prompt: ?[]const u8 = null,
    /// The workspace's child environment, for the `--version` probes.
    probe_env: []const []const u8 = &.{},
    /// `$HOME` and `$CLAUDE_CONFIG_DIR`/`$CODEX_HOME` as this machine sees
    /// them, for the Local side channels.
    home: ?[]const u8 = null,
    claude_config_dir: ?[]const u8 = null,
    codex_home: ?[]const u8 = null,
    /// The backlog task the agent is started on (TASK-64). The caller passes
    /// a validated id; one longer than `Runner.max_task_id_bytes` is dropped.
    task_id: ?[]const u8 = null,
};

pub const LaunchError = Allocator.Error || error{
    /// The harness's side channel needs a Local workspace.
    RemoteUnsupported,
    /// No private state directory for the sink.
    NoSinkRoot,
};

pub const Runtime = struct {
    allocator: Allocator,
    io: Io,
    registry: agent.Registry,
    runners: std.ArrayList(*Runner) = .empty,
    tracks: std.ArrayList(Track) = .empty,
    detections: std.ArrayList(*Detection) = .empty,
    os_jobs: std.ArrayList(*OsJob) = .empty,
    notifications: NotificationList = .{},
    settings: config.Notifications = .{},
    /// Whether the window has keyboard focus; OS notifications are raised
    /// only while it does not.
    focused: bool = true,
    notifier: Notifier = .{},
    /// OS notifications handed to the seam, for checks and diagnostics.
    os_notifications: usize = 0,
    sink_root: ?[]u8,
    fake_enabled: bool,
    fake_view: bool = false,
    wake: Wake,
    /// The agent the last notification activation or `agent.focus` chose,
    /// for TASK-58's manager to select.
    selected_agent: ?AgentId = null,
    /// Set whenever a glyph, the list or the choices may have changed.
    changed: bool = false,
    /// Owned drain buffer, `drain_capacity` stored events.
    drained: []agent.StoredEvent,
    /// `agent.launch` choices for the workspace last asked about, rebuilt by
    /// `launchChoices`. The registry definition borrows them.
    choice_storage: [Harness.all.len + 1]inputmod.PaletteChoice = undefined,
    choice_labels: [Harness.all.len + 1][96]u8 = undefined,
    choice_count: usize = 0,
    unavailable_logged: bool = false,

    const drain_capacity = 8;

    pub fn init(allocator: Allocator, io: Io, options: InitOptions) Allocator.Error!Runtime {
        const sink_root = if (options.sink_root) |root| try allocator.dupe(u8, root) else null;
        errdefer if (sink_root) |root| allocator.free(root);
        const drained = try allocator.alloc(agent.StoredEvent, drain_capacity);
        return .{
            .allocator = allocator,
            .io = io,
            .registry = agent.Registry.init(allocator),
            .sink_root = sink_root,
            .fake_enabled = options.fake_enabled,
            .fake_view = options.fake_view,
            .wake = options.wake,
            .drained = drained,
        };
    }

    /// Stop every worker and release everything. Sessions are not touched:
    /// the workspaces that own them tear them down.
    pub fn deinit(self: *Runtime) void {
        for (self.runners.items) |runner| runner.destroy();
        self.runners.deinit(self.allocator);
        for (self.detections.items) |detection| self.destroyDetection(detection);
        self.detections.deinit(self.allocator);
        for (self.os_jobs.items) |job| {
            if (job.thread) |thread| thread.join();
            self.allocator.destroy(job);
        }
        self.os_jobs.deinit(self.allocator);
        self.tracks.deinit(self.allocator);
        self.registry.deinit();
        self.allocator.free(self.drained);
        if (self.sink_root) |root| {
            Dir.cwd().deleteTree(self.io, root) catch |err| {
                log.debug("the agent sink root was not removed: {s}", .{@errorName(err)});
            };
            self.allocator.free(root);
        }
        self.* = undefined;
    }

    // Detection and choices ---------------------------------------------------

    /// Start finding the harnesses of one workspace's context, once. The
    /// context and `probe_env` must outlive the detection; `removeWorkspace`
    /// joins it before the workspace goes.
    pub fn ensureDetection(self: *Runtime, key: WorkspaceKey, context: workspace.ExecutionContext.Ref, probe_env: []const []const u8) void {
        for (self.detections.items) |detection| if (detection.key == key) return;
        const detection = self.allocator.create(Detection) catch return;
        detection.* = .{ .allocator = self.allocator, .io = self.io, .key = key, .context = context, .probe_env = probe_env };
        detection.thread = std.Thread.spawn(.{}, Detection.work, .{detection}) catch |err| {
            log.debug("harness detection did not start: {s}", .{@errorName(err)});
            self.allocator.destroy(detection);
            return;
        };
        self.detections.append(self.allocator, detection) catch |err| {
            // Joined here rather than leaked: the list could not take it.
            log.debug("harness detection was abandoned: {s}", .{@errorName(err)});
            detection.thread.?.join();
            self.allocator.destroy(detection);
        };
    }

    fn destroyDetection(self: *Runtime, detection: *Detection) void {
        if (detection.thread) |thread| thread.join();
        self.allocator.destroy(detection);
    }

    /// Whether detection for `key` has finished.
    pub fn detectionFinished(self: *const Runtime, key: WorkspaceKey) bool {
        for (self.detections.items) |detection| {
            if (detection.key == key) return detection.done.load(.acquire);
        }
        return false;
    }

    /// The installed version of `harness` in `key`'s context, once detected.
    pub fn detectedVersion(self: *const Runtime, key: WorkspaceKey, harness: Harness) ?[]const u8 {
        for (self.detections.items) |detection| {
            if (detection.key != key or !detection.done.load(.acquire)) continue;
            const index = std.mem.indexOfScalar(Harness, &Harness.all, harness).?;
            const len = detection.version_lens[index] orelse return null;
            return detection.versions[index][0..len];
        }
        return null;
    }

    /// Rebuild and return the `agent.launch` choices for `key`: the fake when
    /// enabled, then the detected harnesses. The slice stays valid until
    /// the next call.
    pub fn launchChoices(self: *Runtime, key: WorkspaceKey) []const inputmod.PaletteChoice {
        var count: usize = 0;
        // The fake leads when a check enabled it, so its row does not depend
        // on which harnesses the machine has.
        if (self.fake_enabled) {
            self.choice_storage[count] = .{ .label = fake_choice_label, .value = fake_choice_value };
            count += 1;
        }
        for (Harness.all) |harness| {
            const version = self.detectedVersion(key, harness) orelse continue;
            const label = std.fmt.bufPrint(&self.choice_labels[count], "{s} {s}", .{ harness.displayName(), version }) catch harness.displayName();
            self.choice_storage[count] = .{ .label = label, .value = @tagName(harness) };
            count += 1;
        }
        self.choice_count = count;
        return self.choice_storage[0..count];
    }

    // Launching ---------------------------------------------------------------

    /// Create the runner for a launch into `request.session` (an
    /// `agent_terminal` session the caller has created). Not registered yet:
    /// call `register` once the session exists, then hand `Runner.prepare`
    /// to the spawn worker.
    pub fn createRunner(self: *Runtime, request: LaunchRequest) LaunchError!*Runner {
        if (request.choice.needsLocalSink() and request.context_kind != .local) return error.RemoteUnsupported;
        var random: [agent.CorrelationToken.byte_count]u8 = undefined;
        self.io.random(&random);
        const token = agent.CorrelationToken.fromBytes(random);

        const needs_sink = switch (request.choice) {
            .fake => true,
            .harness => |h| h == .claude_code or h == .pi,
        };
        const sink_dir: []u8 = if (needs_sink) blk: {
            const root = self.sink_root orelse return error.NoSinkRoot;
            break :blk try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root, token.text()[0..16] });
        } else try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(sink_dir);
        const cwd = try self.allocator.dupe(u8, request.cwd);
        errdefer self.allocator.free(cwd);
        const prompt: ?[]u8 = if (request.prompt) |text| (if (text.len == 0) null else try self.allocator.dupe(u8, text)) else null;
        errdefer if (prompt) |text| self.allocator.free(text);

        const runner = try self.allocator.create(Runner);
        errdefer self.allocator.destroy(runner);
        var queue = try agent.EventQueue.init(self.allocator, self.io, queue_capacity);
        errdefer queue.deinit(self.allocator);
        var view = try agent_view.View.init(self.allocator, agent_view.default_entry_capacity, agent_view.default_byte_budget);
        errdefer view.deinit();
        runner.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .choice = request.choice,
            .workspace = request.workspace,
            .session = request.session,
            .context_kind = request.context_kind,
            .token = token,
            .sink_dir = sink_dir,
            .cwd = cwd,
            .prompt = prompt,
            .backend = undefined,
            .queue = queue,
            .arena = .init(self.allocator),
            .wake = self.wake,
            .view = view,
        };
        errdefer runner.arena.deinit();
        if (request.task_id) |task| if (task.len <= runner.task_id_bytes.len) {
            @memcpy(runner.task_id_bytes[0..task.len], task);
            runner.task_id_len = task.len;
        };
        try self.initBackend(runner, request);
        try self.runners.append(self.allocator, runner);
        return runner;
    }

    fn initBackend(self: *Runtime, runner: *Runner, request: LaunchRequest) LaunchError!void {
        switch (request.choice) {
            .fake => {
                runner.backend = .{ .fake = .{
                    .harness_value = .claude_code,
                    .script = &fake_script,
                    .poll_batch = 0,
                    .launch_argv = &fake_argv,
                    .resolve_on_answer = true,
                } };
                if (self.fake_view) {
                    const root = self.sink_root orelse return error.NoSinkRoot;
                    const parent = std.fs.path.dirnamePosix(root) orelse root;
                    const arena = runner.arena.allocator();
                    const sample = try std.fmt.allocPrint(arena, "{s}/{s}", .{ parent, fake_view_sample_name });
                    runner.backend.fake.script = try fakeViewScript(arena, sample);
                    runner.fake_step_ends = &fake_view_step_ends;
                }
            },
            .harness => |harness| switch (harness) {
                .claude_code => {
                    var config_buffer: [Dir.max_path_bytes]u8 = undefined;
                    const config_dir: ?[]const u8 = request.claude_config_dir orelse if (request.home) |home|
                        std.fmt.bufPrint(&config_buffer, "{s}/.claude", .{home}) catch null
                    else
                        null;
                    runner.backend = .{ .claude = agent.claude_code.ClaudeCodeAdapter.init(self.allocator, self.io, .{
                        .sink_dir = runner.sink_dir,
                        .config_dir = config_dir,
                        .probe_env = request.probe_env,
                    }) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.InvalidSinkPath => return error.NoSinkRoot,
                    } };
                },
                .pi => {
                    runner.backend = .{ .pi = .{ .adapter = undefined, .sink = .{ .io = self.io, .dir_path = runner.sink_dir } } };
                    const pi = &runner.backend.pi;
                    pi.adapter = try agent.pi.PiAdapter.init(self.allocator, self.io, .{
                        .sink_dir = runner.sink_dir,
                        .transport = pi.sink.transport(),
                    });
                },
                .codex => {
                    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
                    self.io.random(&seed);
                    var home_buffer: [Dir.max_path_bytes]u8 = undefined;
                    const codex_home: ?[]const u8 = request.codex_home orelse if (request.home) |home|
                        std.fmt.bufPrint(&home_buffer, "{s}/.codex", .{home}) catch null
                    else
                        null;
                    const socket_path: []const u8 = if (request.context_kind == .local) path: {
                        const home = codex_home orelse break :path "";
                        var socket_buffer: [Dir.max_path_bytes]u8 = undefined;
                        const found = agent.codex.daemonSocketPath(&socket_buffer, home) catch break :path "";
                        break :path try runner.arena.allocator().dupe(u8, found);
                    } else "";
                    runner.backend = .{ .codex = .{
                        .adapter = undefined,
                        .daemon = .{ .allocator = self.allocator, .socket_path = socket_path, .seed = seed },
                    } };
                    const codex = &runner.backend.codex;
                    codex.adapter = try agent.codex.CodexAdapter.init(self.allocator, self.io, .{
                        .transport = codex.daemon.transport(),
                        .cwd = runner.cwd,
                        .cli_version = self.detectedVersion(request.workspace, .codex),
                    });
                    runner.needs_attach = socket_path.len != 0;
                    runner.polling = socket_path.len != 0;
                },
                .opencode => {
                    const port: u16 = if (request.context_kind == .local) freeLoopbackPort(self.io) orelse 0 else 0;
                    runner.backend = .{ .opencode = try agent.opencode.OpenCodeAdapter.init(self.allocator, self.io, .{ .port = port }) };
                    runner.needs_attach = port != 0;
                    runner.polling = port != 0;
                },
            },
        }
    }

    /// Register a runner's agent, owned, bound to its session.
    pub fn register(self: *Runtime, runner: *Runner, binding: agent.Binding) !AgentId {
        const id = try self.registry.create(.{
            .binding = binding,
            .harness = runner.choice.registryHarness(),
            .ownership = .owned,
            .token = runner.token,
            .capabilities = runner.adapter().capabilities(),
        });
        self.tracks.append(self.allocator, .{ .id = id, .last_activity_ns = Io.Clock.awake.now(self.io).nanoseconds }) catch |err| {
            // The id was issued just above, so it is known to the registry.
            self.registry.remove(id) catch |remove_err| log.debug("an agent was not unregistered: {s}", .{@errorName(remove_err)});
            return err;
        };
        runner.agent_id = id;
        self.changed = true;
        return id;
    }

    /// Forget a runner that never started (its spawn was not attempted).
    pub fn discard(self: *Runtime, runner: *Runner) void {
        if (runner.agent_id) |id| self.forgetAgent(id);
        self.removeRunner(runner);
    }

    /// The spawn worker finished: start polling, or record the failure.
    pub fn spawnFinished(self: *Runtime, runner: *Runner, started: bool) void {
        runner.spawning = false;
        if (runner.closing) {
            self.removeRunner(runner);
            return;
        }
        const id = runner.agent_id orelse return;
        if (!started) {
            self.applyAndAnnounce(id, .{ .status_change = .{ .state = .errored, .source = .structured } }, null);
            return;
        }
        runner.start() catch |err| {
            log.warn("the agent's side channel worker did not start: {s}", .{@errorName(err)});
        };
    }

    /// The runner of a registered agent, if it still has one.
    pub fn runnerForAgent(self: *const Runtime, id: AgentId) ?*Runner {
        for (self.runners.items) |runner| {
            if (runner.agent_id == id and !runner.closing) return runner;
        }
        return null;
    }

    /// The runner of a session, if a launched agent lives there.
    pub fn runnerForSession(self: *const Runtime, key: WorkspaceKey, id: SessionId) ?*Runner {
        for (self.runners.items) |runner| {
            if (runner.workspace == key and runner.session == id and !runner.closing) return runner;
        }
        return null;
    }

    fn removeRunner(self: *Runtime, runner: *Runner) void {
        for (self.runners.items, 0..) |candidate, index| {
            if (candidate != runner) continue;
            _ = self.runners.swapRemove(index);
            break;
        }
        runner.destroy();
    }

    fn forgetAgent(self: *Runtime, id: AgentId) void {
        // Unknown means it was already forgotten, which is the goal.
        self.registry.remove(id) catch |err| log.debug("an agent was already forgotten: {s}", .{@errorName(err)});
        for (self.tracks.items, 0..) |track, index| {
            if (track.id != id) continue;
            _ = self.tracks.swapRemove(index);
            break;
        }
        if (self.selected_agent == id) self.selected_agent = null;
        self.changed = true;
    }

    /// The session of an agent is gone (its tab or pane closed): stop its
    /// worker and forget it.
    pub fn sessionClosed(self: *Runtime, key: WorkspaceKey, id: SessionId) void {
        if (self.runnerForSession(key, id)) |runner| {
            // A spawn worker may still be in `prepare`; the runner goes when
            // it reports back.
            if (runner.spawning) runner.closing = true else self.removeRunner(runner);
        }
        // Exited agents stay in the registry for views; a closed session's
        // record goes, whether or not its process ended first.
        var index: usize = 0;
        while (index < self.registry.all().len) {
            const record = self.registry.all()[index];
            if (record.workspace == key and record.session == id) {
                self.forgetAgent(record.id);
                continue;
            }
            index += 1;
        }
    }

    /// A workspace is closing: join its detection and forget its agents and
    /// notifications. Its sessions are closed by the workspace itself.
    pub fn removeWorkspace(self: *Runtime, key: WorkspaceKey) void {
        var index: usize = 0;
        while (index < self.runners.items.len) {
            const runner = self.runners.items[index];
            if (runner.workspace != key) {
                index += 1;
                continue;
            }
            _ = self.runners.swapRemove(index);
            runner.destroy();
        }
        index = 0;
        while (index < self.detections.items.len) {
            const detection = self.detections.items[index];
            if (detection.key != key) {
                index += 1;
                continue;
            }
            _ = self.detections.swapRemove(index);
            self.destroyDetection(detection);
        }
        var removed: std.ArrayList(AgentId) = .empty;
        defer removed.deinit(self.allocator);
        for (self.registry.all()) |record| {
            if (record.workspace != key) continue;
            removed.append(self.allocator, record.id) catch |err| {
                log.warn("a closed workspace's agents were not all forgotten: {s}", .{@errorName(err)});
                break;
            };
        }
        for (removed.items) |id| self.forgetAgent(id);
        self.notifications.removeWorkspace(key);
        self.changed = true;
    }

    // Observation and events --------------------------------------------------

    /// Feed one terminal fact about a session to its agent's heuristics.
    /// Sessions without an agent are ignored.
    pub fn observe(self: *Runtime, key: WorkspaceKey, id: SessionId, observation: Observation, now_ns: i96) void {
        const agent_id = self.registry.findBySession(key, id) orelse return;
        const track_record = self.trackFor(agent_id) orelse return;
        switch (observation) {
            .output, .title, .command_started => {
                track_record.last_tick_ns = now_ns;
                track_record.last_activity_ns = now_ns;
            },
            else => {},
        }
        const batch = track_record.heuristics.observe(observation);
        for (batch.events()) |ev| self.applyAndAnnounce(agent_id, ev, null);
    }

    fn trackFor(self: *Runtime, id: AgentId) ?*Track {
        for (self.tracks.items) |*candidate| {
            if (candidate.id == id) return candidate;
        }
        return null;
    }

    /// Whether a session belongs to an agent (its terminal facts become
    /// agent notifications rather than terminal ones).
    pub fn hasAgent(self: *const Runtime, key: WorkspaceKey, id: SessionId) bool {
        return self.registry.findBySession(key, id) != null;
    }

    /// The live agent bound to a session, if any.
    pub fn agentForSession(self: *const Runtime, key: WorkspaceKey, id: SessionId) ?*const agent.Agent {
        for (self.registry.all()) |*record| {
            if (record.workspace == key and record.session == id) return record;
        }
        return null;
    }

    /// The most urgent state among a workspace's agents.
    pub fn workspaceState(self: *const Runtime, key: WorkspaceKey) ?State {
        var best: ?State = null;
        var iterator = self.registry.inWorkspace(key);
        while (iterator.next()) |record| {
            if (best == null or urgency(record.state) > urgency(best.?)) best = record.state;
        }
        return best;
    }

    /// Fold an event into an agent and raise the notification a new state
    /// or a harness notification asks for. `merge` is the entry this batch
    /// already raised for the agent, which a following harness notification
    /// fills in rather than duplicating.
    fn applyAndAnnounce(self: *Runtime, id: AgentId, ev: agent.Event, merge: ?*?*Entry) void {
        const applied = self.registry.apply(id, ev) catch |err| {
            log.debug("an agent event was not applied: {s}", .{@errorName(err)});
            return;
        };
        // The view logs every structured event, and a state change only when
        // it changed something, so a heuristic tick does not fill the log.
        if (ev != .status_change or applied.outcome == .changed) {
            if (self.runnerForAgent(id)) |runner| {
                runner.view.log.append(ev) catch |err| log.debug("an event was not logged for the view: {s}", .{@errorName(err)});
                self.changed = true;
            }
        }
        const record = self.registry.get(id) orelse return;
        if (applied.outcome == .changed) {
            self.changed = true;
            if (Kind.forState(applied.current)) |kind| {
                const entry = self.raiseAgent(record, kind, record.summary());
                if (merge) |slot| slot.* = entry;
            }
        }
        switch (ev) {
            .notification => |n| {
                if (merge) |slot| {
                    if (slot.*) |entry| {
                        entry.setBody(n.body);
                        return;
                    }
                }
                const entry = self.raiseAgent(record, .input, n.body);
                if (merge) |slot| slot.* = entry;
            },
            else => {},
        }
    }

    /// The name an agent is shown under: its harness, or the fake's own.
    pub fn displayName(self: *const Runtime, record: *const agent.Agent) []const u8 {
        for (self.runners.items) |runner| {
            if (runner.agent_id == record.id and runner.choice == .fake) return "Fake agent";
        }
        return record.harness.displayName();
    }

    /// When an agent last produced output or an event, as
    /// `Io.Clock.awake` nanoseconds (TASK-58's "last activity" column).
    pub fn lastActivity(self: *Runtime, id: AgentId) ?i96 {
        const track_record = self.trackFor(id) orelse return null;
        return track_record.last_activity_ns;
    }

    /// Whether `id` may be restarted from the agent manager: Conduit launched
    /// it, its process has ended or it errored, and no spawn is in flight.
    pub fn restartable(self: *const Runtime, id: AgentId) bool {
        const record = self.registry.get(id) orelse return false;
        if (record.ownership != .owned) return false;
        if (!record.hasExited() and record.state != .errored) return false;
        const runner = self.runnerForAgent(id) orelse return false;
        return !runner.spawning;
    }

    /// The launch an agent was started with, to start it again (TASK-58):
    /// the same harness, workspace, session, cwd and initial prompt. Borrows
    /// the agent's runner; the caller adds the app-level fields (probe
    /// environment, home and config directories) before `replaceRunner`.
    pub fn relaunchRequest(self: *const Runtime, id: AgentId) ?LaunchRequest {
        const runner = self.runnerForAgent(id) orelse return null;
        return .{
            .choice = runner.choice,
            .workspace = runner.workspace,
            .session = runner.session,
            .context_kind = runner.context_kind,
            .cwd = runner.cwd,
            .prompt = runner.prompt,
            .task_id = runner.taskId(),
        };
    }

    pub const ReplaceError = LaunchError || @typeInfo(@typeInfo(@TypeOf(agent.Registry.create)).@"fn".return_type.?).error_union.error_set || error{NotRestartable};

    /// Restart agent `old` in its own session under a new agent id: a fresh
    /// runner for `request` (from `relaunchRequest`), the old runner and
    /// record forgotten, and the new one registered against `binding`. The
    /// caller then spawns the runner's child into the same session. On error
    /// before the old agent is forgotten nothing changes.
    pub fn replaceRunner(self: *Runtime, old: AgentId, request: LaunchRequest, binding: agent.Binding) ReplaceError!*Runner {
        if (!self.restartable(old)) return error.NotRestartable;
        const previous = self.runnerForAgent(old) orelse return error.NotRestartable;
        // The request borrows `previous`; the new runner copies it first.
        const runner = try self.createRunner(request);
        const was_selected = self.selected_agent == old;
        self.forgetAgent(old);
        self.removeRunner(previous);
        _ = self.register(runner, binding) catch |err| {
            self.removeRunner(runner);
            return err;
        };
        if (was_selected) self.selected_agent = runner.agent_id;
        return runner;
    }

    fn raiseAgent(self: *Runtime, record: *const agent.Agent, kind: Kind, body: []const u8) ?*Entry {
        if (!allowed(self.settings, kind, record.harness)) return null;
        var title_buffer: [entry_title_capacity]u8 = undefined;
        const name = self.displayName(record);
        const title = std.fmt.bufPrint(&title_buffer, "{s}: {s}", .{ name, record.state.label() }) catch name;
        const entry = self.notifications.push(kind, record.workspace, record.session, Io.Clock.awake.now(self.io).nanoseconds);
        entry.agent = record.id;
        entry.harness = record.harness;
        entry.setTitle(title);
        // A wait names what it waits on; an outcome says only that it came,
        // and a harness notification in the same batch fills in the detail.
        entry.setBody(switch (kind) {
            .permission, .input, .terminal => if (body.len == 0) record.state.label() else body,
            .done => "the turn finished",
            .@"error" => "the turn failed",
        });
        self.changed = true;
        self.raiseOs(entry);
        return entry;
    }

    /// A terminal notification from a session without an agent: OSC 9/777,
    /// or a bell from a tab the human is not looking at.
    pub fn raiseTerminal(self: *Runtime, key: WorkspaceKey, id: SessionId, title: []const u8, body: []const u8) void {
        if (!allowed(self.settings, .terminal, null)) return;
        const entry = self.notifications.push(.terminal, key, id, Io.Clock.awake.now(self.io).nanoseconds);
        entry.setTitle(if (title.len == 0) "Terminal" else title);
        entry.setBody(body);
        self.changed = true;
        self.raiseOs(entry);
    }

    fn raiseOs(self: *Runtime, entry: *const Entry) void {
        if (!self.settings.os or self.focused) return;
        self.os_notifications += 1;
        if (self.notifier.notify_fn) |f| {
            f(self.notifier.context, entry.title(), entry.body());
            return;
        }
        if (self.os_jobs.items.len >= max_os_jobs) {
            log.debug("an OS notification was dropped: {d} are still being shown", .{max_os_jobs});
            return;
        }
        const job = self.allocator.create(OsJob) catch return;
        job.* = .{ .allocator = self.allocator, .io = self.io };
        job.title_len = copyDisplay(&job.title_bytes, entry.title()).len;
        job.body_len = copyDisplay(&job.body_bytes, entry.body()).len;
        self.os_jobs.append(self.allocator, job) catch |err| {
            log.debug("an OS notification was dropped: {s}", .{@errorName(err)});
            self.allocator.destroy(job);
            return;
        };
        job.thread = std.Thread.spawn(.{}, OsJob.work, .{job}) catch |err| {
            log.debug("the OS notification worker did not start: {s}", .{@errorName(err)});
            _ = self.os_jobs.pop();
            self.allocator.destroy(job);
            return;
        };
    }

    /// Owner-thread service: drain every agent's queue into the registry,
    /// tick the heuristics, record exits and reap finished workers. Returns
    /// whether anything a view shows changed.
    pub fn poll(self: *Runtime, now_ns: i96) bool {
        for (self.runners.items) |runner| {
            const id = runner.agent_id orelse continue;
            var batch_entry: ?*Entry = null;
            while (true) {
                const n = runner.queue.drain(self.drained);
                if (n == 0) break;
                if (self.trackFor(id)) |track_record| track_record.last_activity_ns = now_ns;
                for (self.drained[0..n]) |*stored| self.applyAndAnnounce(id, stored.event, &batch_entry);
            }
        }
        for (self.tracks.items) |*candidate| {
            if (now_ns - candidate.last_tick_ns < tick_interval_ns) continue;
            candidate.last_tick_ns = now_ns;
            const record = self.registry.get(candidate.id) orelse continue;
            if (record.hasExited()) continue;
            const batch = candidate.heuristics.observe(.{ .tick = .{ .now_ns = clampNs(now_ns) } });
            for (batch.events()) |ev| self.applyAndAnnounce(candidate.id, ev, null);
        }
        var index: usize = 0;
        while (index < self.os_jobs.items.len) {
            const job = self.os_jobs.items[index];
            if (!job.done.load(.acquire)) {
                index += 1;
                continue;
            }
            if (job.thread) |thread| thread.join();
            _ = self.os_jobs.swapRemove(index);
            self.allocator.destroy(job);
        }
        if (!self.unavailable_logged and unavailable_seen.load(.acquire)) {
            self.unavailable_logged = true;
            log.debug("OS notifications are unavailable here (no notify-send, or an unsupported platform)", .{});
        }
        for (self.detections.items) |detection| {
            if (detection.thread != null and detection.done.load(.acquire)) {
                detection.thread.?.join();
                detection.thread = null;
                self.changed = true;
            }
        }
        const changed = self.changed;
        self.changed = false;
        return changed;
    }

    /// An agent's PTY child ended with `status`.
    pub fn childExited(self: *Runtime, key: WorkspaceKey, id: SessionId, status: agent.ExitStatus, now_ns: i96) void {
        self.observe(key, id, .{ .child_exited = status }, now_ns);
        if (self.registry.findBySession(key, id)) |agent_id| {
            if (self.trackFor(agent_id)) |track_record| track_record.last_activity_ns = now_ns;
        }
        // The structured channel may have ignored the heuristic claim; the
        // exit is a fact either way.
        if (self.registry.findBySession(key, id)) |agent_id| {
            self.applyAndAnnounce(agent_id, .{ .exited = status }, null);
        }
        if (self.runnerForSession(key, id)) |runner| runner.join();
    }
};

const tick_interval_ns: i96 = 500 * std.time.ns_per_ms;

fn clampNs(value: i96) u64 {
    if (value <= 0) return 0;
    return @intCast(@min(value, std.math.maxInt(u64)));
}

// Tests ---------------------------------------------------------------------------

const testing = std.testing;

test "every state has one glyph, and urgency orders the waits first" {
    const glyphs = [_][]const u8{ "·", "▸", "?", "!", "✓", "×" };
    for (std.enums.values(State), glyphs) |state, glyph| {
        try testing.expectEqualStrings(glyph, stateGlyph(state));
        try testing.expect(std.unicode.utf8CountCodepoints(glyph) catch 0 == 1);
    }
    try testing.expectEqual(State.waiting_permission, mostUrgent(&.{ .done, .waiting_permission, .waiting_input, .working }).?);
    try testing.expectEqual(State.errored, mostUrgent(&.{ .done, .errored, .idle }).?);
    try testing.expectEqual(@as(?State, null), mostUrgent(&.{}));
}

test "the notification list is bounded, newest first, and forgets a workspace" {
    var list: NotificationList = .{};
    const one = WorkspaceKey.fromOrdinal(0);
    const two = WorkspaceKey.fromOrdinal(1);
    var index: usize = 0;
    while (index < NotificationList.capacity + 5) : (index += 1) {
        const entry = list.push(.done, if (index % 2 == 0) one else two, .first, @intCast(index));
        entry.setTitle("t");
    }
    try testing.expectEqual(@as(usize, NotificationList.capacity), list.count());
    try testing.expectEqual(@as(u64, NotificationList.capacity + 5), list.newest(0).?.seq);
    try testing.expectEqual(@as(u64, 6), list.newest(NotificationList.capacity - 1).?.seq);
    try testing.expect(list.bySeq(5) == null);
    try testing.expect(list.bySeq(6) != null);
    list.removeWorkspace(one);
    try testing.expectEqual(@as(usize, NotificationList.capacity / 2), list.count());
    for (0..list.count()) |i| try testing.expectEqual(two, list.newest(i).?.workspace);
    list.clear();
    try testing.expectEqual(@as(usize, 0), list.count());
}

test "display copies are bounded, cleaned and never split a character" {
    var out: [5]u8 = undefined;
    try testing.expectEqualStrings("a b", copyDisplay(&out, "a\x1bb"));
    try testing.expectEqualStrings("ab", copyDisplay(&out, "ab\xff"));
    try testing.expectEqualStrings("abc", copyDisplay(&out, "abc\xe2\x9c\x93"));
}

test "settings filter by kind and by harness" {
    var settings: config.Notifications = .{};
    try testing.expect(allowed(settings, .permission, .claude_code));
    settings.permission = false;
    try testing.expect(!allowed(settings, .permission, .claude_code));
    try testing.expect(allowed(settings, .done, .claude_code));
    settings.pi = false;
    try testing.expect(!allowed(settings, .done, .pi));
    try testing.expect(allowed(settings, .terminal, null));
    settings.enabled = false;
    try testing.expect(!allowed(settings, .terminal, null));
}

test "the environment overlay replaces names and keeps the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const merged = try mergeEnv(arena_state.allocator(), &.{ "PATH=/bin", "HOME=/h", "CONDUIT_AGENT_TOKEN=old" }, &.{"CONDUIT_AGENT_TOKEN=new"}, &.{"CONDUIT_AGENT_SINK=/s"});
    try testing.expectEqual(@as(usize, 4), merged.len);
    try testing.expectEqualStrings("PATH=/bin", merged[0]);
    try testing.expectEqualStrings("CONDUIT_AGENT_TOKEN=new", merged[2]);
    try testing.expectEqualStrings("CONDUIT_AGENT_SINK=/s", merged[3]);
}

test "the fake's steps release its script in groups" {
    try testing.expectEqual(@as(usize, 0), fakeReleased(0));
    try testing.expectEqual(@as(usize, 1), fakeReleased(1));
    try testing.expectEqual(@as(usize, 2), fakeReleased(2));
    try testing.expectEqual(@as(usize, 4), fakeReleased(3));
    try testing.expectEqual(@as(usize, 6), fakeReleased(4));
    try testing.expectEqual(@as(usize, 8), fakeReleased(5));
    try testing.expectEqual(@as(usize, 8), fakeReleased(99));
}

const TestNotifier = struct {
    calls: usize = 0,
    last_title: [96]u8 = undefined,
    last_title_len: usize = 0,

    fn record(context: ?*anyopaque, title: []const u8, body: []const u8) void {
        _ = body;
        const self: *TestNotifier = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.last_title_len = copyDisplay(&self.last_title, title).len;
    }
};

test "a fake agent's launch writes its files and its events become glyph states and notifications" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(testing.io, &root_buffer);
    var sink_buffer: [Dir.max_path_bytes]u8 = undefined;
    const sink_root = try std.fmt.bufPrint(&sink_buffer, "{s}/agents", .{root_buffer[0..tmp_path_len]});

    var runtime = try Runtime.init(testing.allocator, testing.io, .{ .sink_root = sink_root, .fake_enabled = true });
    defer runtime.deinit();
    var notifier: TestNotifier = .{};
    runtime.notifier = .{ .context = &notifier, .notify_fn = TestNotifier.record };

    const key = WorkspaceKey.fromOrdinal(0);
    const session_id = SessionId.fromOrdinal(1);
    const choices = runtime.launchChoices(key);
    try testing.expectEqual(@as(usize, 1), choices.len);
    try testing.expectEqualStrings(fake_choice_value, choices[0].value);

    const runner = try runtime.createRunner(.{
        .choice = .fake,
        .workspace = key,
        .session = session_id,
        .context_kind = .local,
        .cwd = "/",
    });
    // The fake can be asked for extra files; the runner writes them inside
    // the sink and refuses any path outside it.
    const files = [_]agent.LaunchSpec.File{.{ .path = try std.fmt.allocPrint(runner.arena.allocator(), "{s}/ext/conduit.js", .{runner.sink_dir}), .bytes = "x" }};
    runner.backend.fake.launch_files = &files;
    const prepared = try runner.prepare(&.{ "PATH=/bin", "CONDUIT_AGENT_SINK=stale" });
    try testing.expectEqualStrings("/bin/sh", prepared.argv[0]);
    var sink_env_found = false;
    var token_found = false;
    for (prepared.env) |entry| {
        if (std.mem.startsWith(u8, entry, "CONDUIT_AGENT_SINK=")) {
            try testing.expectEqualStrings(runner.sink_dir, entry["CONDUIT_AGENT_SINK=".len..]);
            sink_env_found = true;
        }
        if (std.mem.startsWith(u8, entry, agent.correlation_env_name)) token_found = true;
    }
    try testing.expect(sink_env_found and token_found);
    var read_buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("x", try Dir.cwd().readFile(testing.io, files[0].path, &read_buffer));
    const sink_stat = try Dir.cwd().statFile(testing.io, runner.sink_dir, .{});
    // Windows has no mode bits: `private_dir` is the default directory permission there.
    if (builtin.os.tag != .windows) {
        try testing.expectEqual(@as(u32, 0o700), @as(u32, @intCast(sink_stat.permissions.toMode() & 0o777)));
    }

    const outside = [_]agent.LaunchSpec.File{.{ .path = "/tmp/elsewhere.js", .bytes = "x" }};
    try testing.expectError(error.UnsafeFile, runner.writeLaunchFile(outside[0]));

    _ = try runtime.register(runner, .{
        .workspace = key,
        .session = session_id,
        .session_kind = .agent_terminal,
        .scratchpad = .first,
    });
    // The scratchpad can never be an agent's session.
    try testing.expectError(error.ScratchpadRefused, runtime.registry.create(.{
        .binding = .{ .workspace = key, .session = .first, .session_kind = .scratchpad, .scratchpad = .first },
        .harness = .claude_code,
        .ownership = .owned,
        .token = runner.token,
    }));

    try testing.expectEqual(State.idle, runtime.agentForSession(key, session_id).?.state);
    runtime.focused = false;
    // Typing a line is a step: the worker releases one group per byte.
    var steps_path: [Dir.max_path_bytes]u8 = undefined;
    const steps = try std.fmt.bufPrint(&steps_path, "{s}/steps", .{runner.sink_dir});
    const expected = [_]State{ .working, .waiting_permission, .done, .errored };
    const kinds = [_]?Kind{ null, .permission, .done, .@"error" };
    for (expected, kinds, 1..) |state, kind, step| {
        const marks = "xxxx";
        try Dir.cwd().writeFile(testing.io, .{ .sub_path = steps, .data = marks[0..step] });
        const before = runtime.notifications.count();
        runner.pollOnce();
        _ = runtime.poll(0);
        try testing.expectEqual(state, runtime.agentForSession(key, session_id).?.state);
        try testing.expectEqual(state, runtime.workspaceState(key).?);
        if (kind) |k| {
            try testing.expectEqual(before + 1, runtime.notifications.count());
            try testing.expectEqual(k, runtime.notifications.newest(0).?.kind);
        } else try testing.expectEqual(before, runtime.notifications.count());
    }
    try testing.expectEqual(@as(usize, 3), notifier.calls);

    // A focused window raises no OS notification; a disabled kind no entry.
    runtime.focused = true;
    runtime.raiseTerminal(key, session_id, "", "build finished");
    try testing.expectEqual(@as(usize, 3), notifier.calls);
    try testing.expectEqual(Kind.terminal, runtime.notifications.newest(0).?.kind);
    runtime.settings.terminal = false;
    const count = runtime.notifications.count();
    runtime.raiseTerminal(key, session_id, "", "silenced");
    try testing.expectEqual(count, runtime.notifications.count());

    runtime.sessionClosed(key, session_id);
    try testing.expect(runtime.agentForSession(key, session_id) == null);
    try testing.expectEqual(@as(usize, 0), runtime.runners.items.len);
}

test "the view log fills from drained events and an answer reaches the adapter through the worker's queue" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(testing.io, &root_buffer);
    var sink_buffer: [Dir.max_path_bytes]u8 = undefined;
    const sink_root = try std.fmt.bufPrint(&sink_buffer, "{s}/agents", .{root_buffer[0..tmp_path_len]});

    var runtime = try Runtime.init(testing.allocator, testing.io, .{ .sink_root = sink_root, .fake_enabled = true, .fake_view = true });
    defer runtime.deinit();
    const key = WorkspaceKey.fromOrdinal(0);
    const session_id = SessionId.fromOrdinal(1);
    const runner = try runtime.createRunner(.{ .choice = .fake, .workspace = key, .session = session_id, .context_kind = .local, .cwd = "/" });
    _ = try runner.prepare(&.{"PATH=/bin"});
    const id = try runtime.register(runner, .{ .workspace = key, .session = session_id, .session_kind = .agent_terminal, .scratchpad = .first });
    try testing.expect(runtime.runnerForAgent(id) == runner);
    // The view script names the sample beside the sink root.
    const reference = runner.backend.fake.script[5].file_reference;
    try testing.expect(std.mem.endsWith(u8, reference.path, "/" ++ fake_view_sample_name));
    try testing.expectEqual(@as(?u32, fake_view_sample_line), reference.line);

    var steps_path: [Dir.max_path_bytes]u8 = undefined;
    const steps = try std.fmt.bufPrint(&steps_path, "{s}/steps", .{runner.sink_dir});
    try Dir.cwd().writeFile(testing.io, .{ .sub_path = steps, .data = "x" });
    var rounds: usize = 0;
    while (rounds < 4) : (rounds += 1) {
        runner.pollOnce();
        _ = runtime.poll(0);
    }
    // Twelve events, the status change among them, all logged in order.
    const log_view = &runner.view.log;
    try testing.expectEqual(@as(usize, 12), log_view.count());
    try testing.expectEqual(agent.Event.Kind.status_change, std.meta.activeTag(log_view.at(0).event));
    const request = log_view.at(6);
    try testing.expectEqualStrings("view-1", request.event.permission_request.id);

    try runner.answerPermission("view-1", "deny");
    try testing.expect(log_view.markAnswered(request.seq, 1));
    runner.pollOnce();
    _ = runtime.poll(0);
    const answer = runner.backend.fake.permissionAnswer();
    try testing.expectEqualStrings("view-1", answer.request);
    try testing.expectEqualStrings("deny", answer.decision);
    try testing.expectEqual(@as(?agent.PermissionOutcome, .rejected), request.outcome);
    // The resolution settled the request rather than adding a row.
    try testing.expectEqual(@as(usize, 12), log_view.count());

    // The queue is bounded and refuses ids no stored event can carry.
    var index: usize = 0;
    while (index < Runner.request_capacity) : (index += 1) try runner.answerPermission("r", "d");
    try testing.expectError(error.QueueFull, runner.answerPermission("r", "d"));
    try testing.expectError(error.IdTooLong, runner.answerPermission("r" ** (Runner.max_answer_id_bytes + 1), "d"));
}

test "manager rows show glyph, names, an empty task slot, the state and the age" {
    var buffer: [128]u8 = undefined;
    const row = formatManagerRow(&buffer, .{
        .glyph = stateGlyph(.working),
        .harness = "Codex",
        .workspace = "work",
        .tab = "Codex",
        .state = State.working.label(),
        .age = "12s",
    });
    try testing.expectEqualStrings("▸ Codex  work › Codex  –  working  12s", row);
    const tasked = formatManagerRow(&buffer, .{ .glyph = "·", .harness = "Pi", .workspace = "w", .tab = "t", .task = "TASK-7", .state = "idle", .age = "3m" });
    try testing.expectEqualStrings("· Pi  w › t  TASK-7  idle  3m", tasked);
    // A narrow buffer never splits the separator or the glyph.
    var small: [10]u8 = undefined;
    const cut = formatManagerRow(&small, .{ .glyph = "▸", .harness = "Codex", .workspace = "w", .tab = "t", .state = "idle", .age = "now" });
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
    try testing.expect(std.mem.startsWith(u8, cut, "▸ Codex"));
}

test "manager rows sort by workspace, then tab, then id" {
    var keys = [_]ManagerSortKey{
        .{ .workspace_rank = 1, .tab_rank = 0, .id = AgentId.fromOrdinal(0) },
        .{ .workspace_rank = 0, .tab_rank = 2, .id = AgentId.fromOrdinal(1) },
        .{ .workspace_rank = 0, .tab_rank = 1, .id = AgentId.fromOrdinal(4) },
        .{ .workspace_rank = 0, .tab_rank = 1, .id = AgentId.fromOrdinal(2) },
        .{ .workspace_rank = 0, .tab_rank = std.math.maxInt(usize), .id = AgentId.fromOrdinal(3) },
    };
    sortManagerRows(&keys);
    const expected = [_]u64{ 2, 4, 1, 3, 0 };
    for (keys, expected) |key, ordinal| try testing.expectEqual(ordinal, key.id.ordinal());
}

test "a message reaches the adapter through the worker's queue, and a restart replaces the agent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(testing.io, &root_buffer);
    var sink_buffer: [Dir.max_path_bytes]u8 = undefined;
    const sink_root = try std.fmt.bufPrint(&sink_buffer, "{s}/agents", .{root_buffer[0..tmp_path_len]});

    var runtime = try Runtime.init(testing.allocator, testing.io, .{ .sink_root = sink_root, .fake_enabled = true });
    defer runtime.deinit();
    const key = WorkspaceKey.fromOrdinal(0);
    const session_id = SessionId.fromOrdinal(1);
    const binding: agent.Binding = .{ .workspace = key, .session = session_id, .session_kind = .agent_terminal, .scratchpad = .first };
    const runner = try runtime.createRunner(.{ .choice = .fake, .workspace = key, .session = session_id, .context_kind = .local, .cwd = "/w", .prompt = "go", .task_id = "TASK-7" });
    try testing.expectEqualStrings("TASK-7", runner.taskId().?);
    _ = try runner.prepare(&.{"PATH=/bin"});
    const id = try runtime.register(runner, binding);
    try testing.expect(runtime.lastActivity(id) != null);

    // Both request kinds share the bounded queue and keep their order.
    try runner.answerPermission("fake-1", "allow");
    try runner.sendMessage("please continue");
    runner.pollOnce();
    try testing.expectEqualStrings("please continue", runner.backend.fake.input());
    try testing.expectEqualStrings("fake-1", runner.backend.fake.permissionAnswer().request);
    try testing.expectError(error.MessageTooLong, runner.sendMessage("m" ** (Runner.max_message_bytes + 1)));
    var index: usize = 0;
    while (index < Runner.request_capacity) : (index += 1) try runner.sendMessage("x");
    try testing.expectError(error.QueueFull, runner.sendMessage("x"));

    // A running agent is not restartable; an exited one is, under a new id
    // bound to the same session with the same launch.
    try testing.expect(!runtime.restartable(id));
    runtime.childExited(key, session_id, .{ .code = 0 }, 5);
    try testing.expectEqualStrings("exited", managerStateWord(runtime.registry.get(id).?));
    try testing.expect(runtime.restartable(id));
    runtime.selected_agent = id;
    const request = runtime.relaunchRequest(id).?;
    try testing.expectEqualStrings("go", request.prompt.?);
    const replacement = try runtime.replaceRunner(id, request, binding);
    const new_id = replacement.agent_id.?;
    try testing.expect(new_id != id);
    try testing.expect(runtime.registry.get(id) == null);
    try testing.expectEqual(new_id, runtime.registry.findBySession(key, session_id).?);
    try testing.expectEqual(@as(?AgentId, new_id), runtime.selected_agent);
    try testing.expectEqualStrings("/w", replacement.cwd);
    try testing.expectEqualStrings("go", replacement.prompt.?);
    // The restarted agent still works on the task it was started on.
    try testing.expectEqualStrings("TASK-7", replacement.taskId().?);
    try testing.expectEqual(@as(usize, 1), runtime.runners.items.len);
    try testing.expectError(error.NotRestartable, runtime.replaceRunner(new_id, runtime.relaunchRequest(new_id).?, binding));
}
