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
//! (with a remote workspace's sink root and Claude Code config directory),
//! the removal of a closed remote agent's sink and OS notifications run on
//! short-lived workers joined by `poll` and `deinit`. No worker touches the
//! registry, the list or any UI.
//!
//! Remote workspaces (TASK-61): an agent's sink lives in its own context,
//! `<remote state dir>/conduit/agents/<run>/<token prefix>` on the remote
//! host of an SSH workspace, and every sink access (launch files, the event
//! tail, decisions, transcripts) goes through the runner's `agent.SinkIo`
//! over the workspace's connection. The run root is removed when the
//! workspace closes or the app exits, a bounded wait at that moment.
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
const pty = @import("pty");
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

// Sidebar agent rows (TASK-80) -----------------------------------------------------

/// The state words a sidebar agent row ends with, the same for every
/// harness: what the human would say the agent is doing.
pub fn rowStateWord(state: State) []const u8 {
    return switch (state) {
        .idle => "idle",
        .working => "working",
        .waiting_input => "input",
        .waiting_permission => "permission",
        .done => "done",
        .errored => "errored",
    };
}

/// The command-style name a sidebar agent row shows: the harness's tag up to
/// its first underscore (`claude_code` reads `claude`), derived the same way
/// for every harness so nothing here special-cases one.
pub fn rowHarnessName(harness: Harness) []const u8 {
    const tag = @tagName(harness);
    const end = std.mem.indexOfScalar(u8, tag, '_') orelse tag.len;
    return tag[0..end];
}

/// The longest row `formatAgentRow` writes: a three-byte glyph, a name of
/// at most `agent_row_name_bytes` and the longest state words.
pub const agent_row_name_bytes = 16;
pub const agent_row_bytes = 3 + 1 + agent_row_name_bytes + 1 + "permission".len;

/// `<glyph> <name> <state>` into `buffer`; a name longer than
/// `agent_row_name_bytes` is cut so the row always fits `agent_row_bytes`.
pub fn formatAgentRow(buffer: *[agent_row_bytes]u8, name: []const u8, state: State) []const u8 {
    const kept = agent.truncateUtf8(name, agent_row_name_bytes);
    return std.fmt.bufPrint(buffer, "{s} {s} {s}", .{ stateGlyph(state), kept, rowStateWord(state) }) catch stateGlyph(state);
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

    /// Whether the side channel keeps a private sink directory: in the
    /// agent's own context, so on the remote host in an SSH workspace
    /// (TASK-61).
    pub fn needsSink(self: Choice) bool {
        return switch (self) {
            .harness => |h| h == .claude_code or h == .pi,
            .fake => true,
        };
    }

    /// Whether this choice only gets the PTY baseline in a remote workspace:
    /// Codex's daemon socket and OpenCode's loopback port are on the remote
    /// host, and forwarding them is not implemented (TASK-61).
    pub fn terminalOnlyRemotely(self: Choice) bool {
        return switch (self) {
            .harness => |h| h == .codex or h == .opencode,
            .fake => false,
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

/// The fake's script in a remote workspace (TASK-61): the same loop, staged
/// as a launch file in the remote sink (so the launch files are proved to be
/// written on the remote host) and naming the host it runs on first.
pub const fake_remote_script =
    "printf 'FAKE-AGENT-HOST:%s\\n' \"$(uname -n)\"; " ++ fake_agent_script ++ "\n";

/// The remote fake's script file, inside its sink.
pub const fake_remote_script_name = "fake-agent.sh";

const fake_decisions = [_]agent.Decision{
    .{ .id = "allow", .label = "Allow once", .kind = .allow_once },
    .{ .id = "deny", .label = "Reject", .kind = .reject },
};

/// The fake's script: idle → working → waiting for permission → (resolved)
/// done → working → errored → working → waiting for permission again →
/// (resolved) waiting for input,
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
    .{ .permission_resolved = .{ .id = "fake-2", .outcome = .allowed } },
    .{ .status_change = .{ .state = .waiting_input, .source = .structured } },
};

/// Events released after 1, 2, 3, 4, 5 and 6 steps.
pub const fake_step_ends = [_]usize{ 1, 2, 4, 6, 8, 10 };

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

/// The message `--agent-prompts-test`'s fake reports the human sent.
pub const fake_prompts_message = "Keep the project rules short and current.";

/// `--agent-prompts-test`'s script (TASK-59): one turn carrying a human's
/// message, released by one step.
pub const fake_prompts_script = [_]agent.Event{
    .{ .status_change = .{ .state = .working, .source = .structured } },
    .{ .message = .{ .role = .user, .text = fake_prompts_message } },
    .{ .message = .{ .role = .assistant, .text = "I will read CLAUDE.md first." } },
    .{ .status_change = .{ .state = .done, .source = .structured } },
};

pub const fake_prompts_step_ends = [_]usize{fake_prompts_script.len};

// Owner-side transports ------------------------------------------------------------

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
    pi: struct { adapter: agent.pi.PiAdapter, sink: agent.pi.SinkTransport },
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
    /// The workspace's context, borrowed for the runner's life (the
    /// workspace outlives its runners: `Runtime.removeWorkspace` runs
    /// first). Null only in tests that never touch a remote sink.
    context: ?workspace.ExecutionContext.Ref = null,
    token: agent.CorrelationToken,
    /// The registry id, once registered.
    agent_id: ?AgentId = null,
    /// Owned; empty when this harness keeps no sink. A path in the agent's
    /// own context: on the remote host in an SSH workspace (TASK-61).
    sink_dir: []u8,
    /// Where `sink_dir` lives: this machine's files, or the workspace's
    /// context. Used by the spawn worker (`prepare`) and then only by the
    /// IO worker (the fake's steps and decisions), never at once; each
    /// adapter keeps its own copy.
    sink: agent.SinkIo = .local(),
    /// Worker-owned: the fake's step bytes already counted.
    fake_steps_seen: u64 = 0,
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
    /// Observed agents only (TASK-56): the foreground process the human
    /// started, whose harness records the worker attaches to. Null for an
    /// agent Conduit launched.
    observed_pid: ?u32 = null,
    /// The adapter's capabilities as the worker last saw them (a
    /// `Capabilities` bit pattern; zero before its first poll), published
    /// after every poll so the owner never calls the adapter while the
    /// worker does: a structured channel may come up only after
    /// registration (OpenCode's event stream).
    published_caps: std.atomic.Value(u16) = .init(0),
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
                .permission => {
                    const request_id = answer.request[0..answer.request_len];
                    const decision_id = answer.decision[0..answer.decision_len];
                    if (self.adapter().respondPermission(request_id, decision_id)) {
                        if (self.backend == .fake) self.publishFakeDecision(request_id, decision_id);
                    } else |err| {
                        log.debug("a permission answer was not delivered: {s}", .{@errorName(err)});
                    }
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
            // Through the sink seam: this machine's files for a Local agent,
            // the remote host's (one exec channel) in an SSH workspace.
            self.sink.makePrivateDir(self.io, self.sink_dir) catch |err| {
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
            // `conduit control agent.event` (the hooks' helper while the
            // control endpoint is up) falls back to this sink when the
            // endpoint does not answer.
            .claude => if (self.sink_dir.len != 0) try extra_env.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ agent.pi.sink_env_name, self.sink_dir })),
            else => {},
        }
        for (files.items) |file| try self.writeLaunchFile(file);
        // Every string is copied: `base_env` belongs to the spawn job, which
        // is freed once the child starts, and `prepared` outlives it.
        const base_copy = try arena.alloc([]const u8, base_env.len);
        for (base_copy, base_env) |*slot, entry| slot.* = try arena.dupe(u8, entry);
        const env = try mergeEnv(arena, base_copy, spec.env, extra_env.items);
        self.prepared = .{ .argv = spec.argv, .env = env };
        return self.prepared.?;
    }

    /// Write one launch file inside the sink, in the agent's context: the
    /// sink seam replaces it atomically, creates missing parents 0700 and
    /// gives it exactly 0700 (executable) or 0600 (TASK-61).
    fn writeLaunchFile(self: *Runner, file: agent.LaunchSpec.File) PrepareError!void {
        if (!insideSink(self.sink_dir, file.path)) return error.UnsafeFile;
        self.sink.writeFile(self.io, file.path, file.bytes, if (file.executable) 0o700 else agent.sink_io.private_file_mode) catch |err| {
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
            self.attach() catch |err| switch (err) {
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
        defer self.published_caps.store(@bitCast(self.adapter().capabilities()), .release);
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

    /// Attach the side channel. An observed agent's adapter was told its
    /// foreground process when it was made, so its `attach` finds the
    /// harness's own session (Claude Code: its registry by pid, else cwd;
    /// Codex: the daemon's newest thread in the cwd). Worker thread.
    fn attach(self: *Runner) agent.AdapterError!void {
        return self.adapter().attach(.{ .session = self.session, .token = self.token });
    }

    /// Lines the human typed into the fake agent, counted by the bytes its
    /// script appended to the sink.
    /// Followed through the sink seam like an event file: a remote fake's
    /// steps are bytes its script appended on the remote host. Worker
    /// thread.
    fn fakeSteps(self: *Runner) u64 {
        var path_buffer: [Dir.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "{s}/steps", .{self.sink_dir}) catch return self.fake_steps_seen;
        var buffer: [64]u8 = undefined;
        while (true) {
            const read = self.sink.readAt(self.io, path, self.fake_steps_seen, &buffer) catch |err| {
                log.debug("the fake's steps were not read: {s}", .{@errorName(err)});
                return self.fake_steps_seen;
            };
            const n = read orelse return self.fake_steps_seen;
            if (n == 0) return self.fake_steps_seen;
            self.fake_steps_seen += n;
        }
    }

    /// The fake has no harness to answer, so it records each answer the way
    /// a sink harness receives one: a decision file in its sink, written
    /// through the seam (on the remote host in an SSH workspace). Worker
    /// thread.
    fn publishFakeDecision(self: *Runner, request_id: []const u8, decision_id: []const u8) void {
        if (self.sink_dir.len == 0 or !safeFileName(request_id)) return;
        var path_buffer: [Dir.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "{s}/decisions/{s}", .{ self.sink_dir, request_id }) catch return;
        self.sink.writeFile(self.io, path, decision_id, agent.sink_io.private_file_mode) catch |err| {
            log.debug("the fake's decision file was not written: {s}", .{@errorName(err)});
        };
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
            // The sink is private run state: gone with the agent. A remote
            // sink is removed by the runtime on a worker (`Cleanup`), since
            // that is a command over the connection.
            if (!self.sink.isRemote()) Dir.cwd().deleteTree(self.io, self.sink_dir) catch |err| {
                log.debug("the agent sink was not removed: {s}", .{@errorName(err)});
            };
            self.allocator.free(self.sink_dir);
        }
        self.allocator.free(self.cwd);
        if (self.prompt) |prompt| self.allocator.free(prompt);
        self.allocator.destroy(self);
    }
};

/// Whether `path` names something strictly inside `sink_dir` without
/// climbing out of it.
fn insideSink(sink_dir: []const u8, path: []const u8) bool {
    if (sink_dir.len == 0 or !std.mem.startsWith(u8, path, sink_dir)) return false;
    if (path.len <= sink_dir.len + 1 or path[sink_dir.len] != '/') return false;
    var parts = std.mem.splitScalar(u8, path[sink_dir.len + 1 ..], '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

/// Whether a harness-supplied id may be a file name in a sink.
fn safeFileName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or name[0] == '.') return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
        else => return false,
    };
    return true;
}

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

/// What one workspace's context offers agents, found once on a worker:
/// which harnesses it has and, for a remote context, where agent sinks go
/// there and where Claude Code keeps its configuration (TASK-61). Every
/// blocking call happens here, never on the owner thread.
const Detection = struct {
    allocator: Allocator,
    io: Io,
    key: WorkspaceKey,
    context: workspace.ExecutionContext.Ref,
    probe_env: []const []const u8,
    /// Run the harnesses' `--version` probes (checks with only the fake
    /// skip them, so the machine's harnesses never change what they see).
    probe_harnesses: bool = true,
    /// This run's name, the last component of every sink root (copied).
    run_name_bytes: [64]u8 = undefined,
    run_name_len: usize = 0,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    versions: [Harness.all.len][64]u8 = undefined,
    version_lens: [Harness.all.len]?usize = @splat(null),
    /// Remote only, published by `remote_ready`: the run's sink root on the
    /// remote host (`<state dir>/conduit/agents/<run>`), when resolved.
    remote_root_bytes: [Dir.max_path_bytes]u8 = undefined,
    remote_root_len: ?usize = null,
    /// Remote only: Claude Code's config directory there, when resolved.
    claude_config_bytes: [Dir.max_path_bytes]u8 = undefined,
    claude_config_len: ?usize = null,
    remote_ready: std.atomic.Value(bool) = .init(false),
    /// Owner thread: an agent sink was created under the remote root, so the
    /// root is removed when the workspace closes.
    remote_used: bool = false,

    fn isRemote(self: *const Detection) bool {
        return self.context.kind().isRemote();
    }

    fn work(self: *Detection) void {
        defer self.done.store(true, .release);
        if (self.isRemote()) {
            self.resolveRemote();
            self.remote_ready.store(true, .release);
        }
        if (!self.probe_harnesses) return;
        for (Harness.all, 0..) |harness, index| {
            self.version_lens[index] = self.detectOne(harness, &self.versions[index]);
        }
    }

    /// The remote state directory and Claude Code's config directory, each
    /// one bounded command through the context.
    fn resolveRemote(self: *Detection) void {
        var state_buffer: [Dir.max_path_bytes]u8 = undefined;
        if (self.context.stateDir(self.io, &state_buffer)) |state_dir| {
            const run_name = self.run_name_bytes[0..self.run_name_len];
            if (remoteSinkRoot(&self.remote_root_bytes, state_dir, run_name)) |root| {
                self.remote_root_len = root.len;
            } else |err| log.debug("the remote sink root is unusable: {s}", .{@errorName(err)});
        } else |err| log.debug("the remote state directory was not found: {s}", .{@errorName(err)});
        if (agent.claude_code.resolveConfigDir(self.context, self.allocator, self.io, &self.claude_config_bytes)) |found| {
            if (found) |dir| self.claude_config_len = dir.len;
        } else |err| log.debug("the remote Claude Code config directory was not found: {s}", .{@errorName(err)});
    }

    /// The remote sink root, once resolved. Owner thread.
    fn remoteRoot(self: *const Detection) ?[]const u8 {
        if (!self.remote_ready.load(.acquire)) return null;
        const len = self.remote_root_len orelse return null;
        return self.remote_root_bytes[0..len];
    }

    fn remoteClaudeConfig(self: *const Detection) ?[]const u8 {
        if (!self.remote_ready.load(.acquire)) return null;
        const len = self.claude_config_len orelse return null;
        return self.claude_config_bytes[0..len];
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

/// `<state_dir>/conduit/agents/<run_name>` in `out`: where a remote
/// workspace's agent sinks go. Both parts are checked, since the state
/// directory is the remote environment's answer: absolute, no controls, no
/// `.`/`..` components, and a plain run name.
pub fn remoteSinkRoot(out: []u8, state_dir: []const u8, run_name: []const u8) error{ Unsafe, NoSpaceLeft }![]const u8 {
    const trimmed = std.mem.trimEnd(u8, state_dir, "/");
    if (trimmed.len == 0 or trimmed[0] != '/') return error.Unsafe;
    var parts = std.mem.splitScalar(u8, trimmed[1..], '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.Unsafe;
    }
    for (trimmed) |c| if (c < 0x20 or c == 0x7f) return error.Unsafe;
    if (!safeFileName(run_name)) return error.Unsafe;
    return std.fmt.bufPrint(out, "{s}/conduit/agents/{s}", .{ trimmed, run_name }) catch error.NoSpaceLeft;
}

/// Whether `path` is a sink root or sink this runtime may remove with
/// `rm -rf`: absolute, with no `.`/`..` components, under a
/// `/conduit/agents/` directory. Guards the one destructive command against
/// a malformed path ever reaching it.
pub fn removableSinkPath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    const marker = "/conduit/agents/";
    const at = std.mem.indexOf(u8, path, marker) orelse return false;
    if (path.len == at + marker.len) return false;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    for (path) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// `rm -rf -- <path>` through a remote context: one bounded command. Blocks;
/// workers (and the bounded waits at a workspace's close) only.
fn removeRemote(allocator: Allocator, io: Io, context: workspace.ExecutionContext.Ref, path: []const u8) void {
    if (!removableSinkPath(path)) {
        log.debug("a remote agent path was not removed: it is not a sink", .{});
        return;
    }
    var result = context.run(allocator, io, .{
        .argv = &.{ "rm", "-rf", "--", path },
        .cwd = "",
        .max_output = 4096,
        .timeout_ms = remote_cleanup_timeout_ms,
    }) catch |err| {
        log.debug("a remote agent sink was not removed: {s}", .{@errorName(err)});
        return;
    };
    defer result.deinit(allocator);
    if (!result.succeeded()) log.debug("removing a remote agent sink failed", .{});
}

/// The bound on one remote removal, which a workspace's close may wait for.
const remote_cleanup_timeout_ms: u32 = 5_000;

/// Removes one closed agent's remote sink on its own thread, so the owner
/// never waits on the connection. Joined by `Runtime.poll` once done, and
/// before its workspace's context goes (`removeWorkspace`, `deinit`).
const Cleanup = struct {
    allocator: Allocator,
    io: Io,
    key: WorkspaceKey,
    context: workspace.ExecutionContext.Ref,
    /// Owned.
    path: []u8,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),

    fn work(self: *Cleanup) void {
        defer self.done.store(true, .release);
        removeRemote(self.allocator, self.io, self.context, self.path);
    }

    fn destroy(self: *Cleanup) void {
        if (self.thread) |thread| thread.join();
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }
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
    /// Give the fake `--agent-prompts-test`'s script: a human's message and
    /// the end of a turn (TASK-59).
    fake_prompts: bool = false,
    wake: Wake = .{},
};

pub const LaunchRequest = struct {
    choice: Choice,
    workspace: WorkspaceKey,
    session: SessionId,
    context_kind: workspace.ExecutionContextKind,
    /// The workspace's context, borrowed for the agent's life. Required in a
    /// remote workspace: the sink, the launch files and every side-channel
    /// read go through it (TASK-61).
    context: ?workspace.ExecutionContext.Ref = null,
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
    /// Set for an observed agent (TASK-56): the human started the harness as
    /// this process in their own terminal. Nothing is spawned and no sink is
    /// kept; the worker attaches to the harness's own records instead.
    observed_pid: ?u32 = null,
};

// Observed agents (TASK-56, TASK-78) ------------------------------------------------

/// What the app knows about one session when the runtime asks: its binding,
/// its context and the terminal's foreground process.
pub const SessionFacts = struct {
    binding: agent.Binding,
    context_kind: workspace.ExecutionContextKind,
    /// The leader of the terminal's foreground process group, its text in
    /// the buffer the runtime lent; null when the PTY backend cannot say.
    process: ?pty.ForegroundProcess,
    /// `$HOME`, `$CLAUDE_CONFIG_DIR` and `$CODEX_HOME` as this machine sees
    /// them, for the Local side channels an observed agent attaches to.
    /// Borrowed for the call.
    home: ?[]const u8 = null,
    claude_config_dir: ?[]const u8 = null,
    codex_home: ?[]const u8 = null,
};

/// The app's answer to "what runs in this session?", installed by the
/// composition root. Without it no human terminal is ever observed.
pub const SessionProbe = struct {
    context: ?*anyopaque = null,
    /// Owner thread; bounded (`pty.Pty.foregroundProcess` reads `/proc`).
    /// Null when the session is gone.
    probe_fn: ?*const fn (context: ?*anyopaque, key: WorkspaceKey, id: SessionId, buffer: []u8) ?SessionFacts = null,
};

/// At most one foreground look per session per this interval, and only after
/// the session did something (output, a prompt mark, input): never per frame.
pub const observe_interval_ns: i96 = 2 * std.time.ns_per_s;

/// Sessions the runtime remembers looking at; the oldest is forgotten first.
const watch_capacity = 64;

/// One session the runtime looks into for a harness the human started.
const Watch = struct {
    key: WorkspaceKey,
    id: SessionId,
    /// The session did something since the last look.
    due: bool = true,
    last_check_ns: ?i96 = null,
    /// Not a human terminal (the scratchpad, an agent's own terminal, an SSH
    /// connection terminal): never looked at again.
    excluded: bool = false,
    /// The process the human told Conduit to stop observing; not attached
    /// again while it stays in front.
    ignored_pid: ?u32 = null,
};

pub const LaunchError = Allocator.Error || error{
    /// No private state directory for the sink: none on this machine, or a
    /// remote one not resolved yet (or not usable).
    NoSinkRoot,
};

pub const Runtime = struct {
    allocator: Allocator,
    io: Io,
    registry: agent.Registry,
    runners: std.ArrayList(*Runner) = .empty,
    tracks: std.ArrayList(Track) = .empty,
    detections: std.ArrayList(*Detection) = .empty,
    cleanups: std.ArrayList(*Cleanup) = .empty,
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
    /// This run's name: the last component of `sink_root`, reused for each
    /// remote workspace's sink root so one run's sinks share a parent there
    /// too. `run` when there is no local root.
    run_name_bytes: [64]u8 = undefined,
    run_name_len: usize = 0,
    fake_enabled: bool,
    fake_view: bool = false,
    fake_prompts: bool = false,
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
    /// The `conduit` executable Claude Code hooks run as `conduit control
    /// agent.event` while this run's control endpoint is up (TASK-60), and
    /// on Windows always, where there is no relay shell (TASK-82); null
    /// keeps them on the sink relay. Borrowed for the runtime's life.
    control_helper: ?[]const u8 = null,
    /// Owner thread: agent event lines the control endpoint delivered
    /// (`ingestControlEvent`), for checks and diagnostics.
    control_events_ingested: u64 = 0,
    /// Checks only: the program a Claude Code agent runs instead of
    /// `claude` (`--control-test`'s stand-in harness). Borrowed.
    claude_program: ?[]const u8 = null,
    /// How the runtime asks the app what runs in a session (observed agents).
    probe: SessionProbe = .{},
    watches: std.ArrayList(Watch) = .empty,
    /// Foreground looks taken, for checks and diagnostics.
    foreground_checks: usize = 0,

    const drain_capacity = 8;

    pub fn init(allocator: Allocator, io: Io, options: InitOptions) Allocator.Error!Runtime {
        const sink_root = if (options.sink_root) |root| try allocator.dupe(u8, root) else null;
        errdefer if (sink_root) |root| allocator.free(root);
        const drained = try allocator.alloc(agent.StoredEvent, drain_capacity);
        var runtime: Runtime = .{
            .allocator = allocator,
            .io = io,
            .registry = agent.Registry.init(allocator),
            .sink_root = sink_root,
            .fake_enabled = options.fake_enabled,
            .fake_view = options.fake_view,
            .fake_prompts = options.fake_prompts,
            .wake = options.wake,
            .drained = drained,
        };
        const base = if (sink_root) |root| std.fs.path.basenamePosix(root) else "";
        const name = if (base.len != 0 and base.len <= runtime.run_name_bytes.len and safeFileName(base)) base else "run";
        @memcpy(runtime.run_name_bytes[0..name.len], name);
        runtime.run_name_len = name.len;
        return runtime;
    }

    /// The run's name in remote sink roots.
    pub fn runName(self: *const Runtime) []const u8 {
        return self.run_name_bytes[0..self.run_name_len];
    }

    /// Stop every worker and release everything. Sessions are not touched:
    /// the workspaces that own them tear them down.
    pub fn deinit(self: *Runtime) void {
        for (self.runners.items) |runner| runner.destroy();
        self.runners.deinit(self.allocator);
        for (self.cleanups.items) |job| job.destroy();
        self.cleanups.deinit(self.allocator);
        // The workspaces still exist (the app releases them after the
        // runtime), so each remote run root can go now, at a bounded wait.
        for (self.detections.items) |detection| self.removeRemoteRoot(detection);
        for (self.detections.items) |detection| self.destroyDetection(detection);
        self.detections.deinit(self.allocator);
        for (self.os_jobs.items) |job| {
            if (job.thread) |thread| thread.join();
            self.allocator.destroy(job);
        }
        self.os_jobs.deinit(self.allocator);
        self.tracks.deinit(self.allocator);
        self.watches.deinit(self.allocator);
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

    /// Start finding what one workspace's context offers, once: its
    /// harnesses when `probe_harnesses`, and for a remote context its sink
    /// root and Claude Code config directory. A finished detection is redone
    /// when it lacks what is asked now (a remote root that did not resolve,
    /// or probes it skipped). The context and `probe_env` must outlive the
    /// detection; `removeWorkspace` joins it before the workspace goes.
    pub fn ensureDetection(self: *Runtime, key: WorkspaceKey, context: workspace.ExecutionContext.Ref, probe_env: []const []const u8, probe_harnesses: bool) void {
        for (self.detections.items, 0..) |existing, index| {
            if (existing.key != key) continue;
            if (!existing.done.load(.acquire)) return;
            const missing_root = existing.isRemote() and existing.remoteRoot() == null;
            const missing_probes = probe_harnesses and !existing.probe_harnesses;
            if (!missing_root and !missing_probes) return;
            if (existing.remote_used) return;
            _ = self.detections.swapRemove(index);
            self.destroyDetection(existing);
            break;
        }
        const detection = self.allocator.create(Detection) catch return;
        detection.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .key = key,
            .context = context,
            .probe_env = probe_env,
            .probe_harnesses = probe_harnesses,
        };
        @memcpy(detection.run_name_bytes[0..self.run_name_len], self.runName());
        detection.run_name_len = self.run_name_len;
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

    fn detectionFor(self: *const Runtime, key: WorkspaceKey) ?*Detection {
        for (self.detections.items) |detection| {
            if (detection.key == key) return detection;
        }
        return null;
    }

    /// Where `key`'s remote workspace keeps this run's agent sinks, once
    /// its detection resolved it; null for a Local workspace or until then.
    pub fn remoteSinkRootFor(self: *const Runtime, key: WorkspaceKey) ?[]const u8 {
        const detection = self.detectionFor(key) orelse return null;
        return detection.remoteRoot();
    }

    /// Remove a remote workspace's run root, when an agent sink was ever
    /// made under it. Joins the detection first (it may still be running).
    /// A bounded wait on the connection (`remote_cleanup_timeout_ms`), taken
    /// only when a remote workspace closes or the app exits.
    fn removeRemoteRoot(self: *Runtime, detection: *Detection) void {
        if (detection.thread) |thread| thread.join();
        detection.thread = null;
        if (!detection.remote_used) return;
        const root = detection.remoteRoot() orelse return;
        removeRemote(self.allocator, self.io, detection.context, root);
        detection.remote_used = false;
    }

    /// Start removing one closed agent's remote sink on a worker.
    fn startCleanup(self: *Runtime, key: WorkspaceKey, context: workspace.ExecutionContext.Ref, path: []const u8) void {
        const job = self.allocator.create(Cleanup) catch return;
        const owned = self.allocator.dupe(u8, path) catch {
            self.allocator.destroy(job);
            return;
        };
        job.* = .{ .allocator = self.allocator, .io = self.io, .key = key, .context = context, .path = owned };
        self.cleanups.append(self.allocator, job) catch |err| {
            log.debug("a remote agent sink cleanup was not queued: {s}", .{@errorName(err)});
            job.destroy();
            return;
        };
        job.thread = std.Thread.spawn(.{}, Cleanup.work, .{job}) catch |err| {
            // The workspace close removes the whole run root anyway.
            log.debug("a remote agent sink cleanup did not start: {s}", .{@errorName(err)});
            _ = self.cleanups.pop();
            job.destroy();
            return;
        };
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
        const remote = if (self.detectionFor(key)) |detection| detection.isRemote() else false;
        for (Harness.all) |harness| {
            const version = self.detectedVersion(key, harness) orelse continue;
            // In a remote workspace Codex and OpenCode run as plain TUIs on
            // the PTY baseline, and the chooser says so (TASK-61).
            const terminal_only = remote and (Choice{ .harness = harness }).terminalOnlyRemotely();
            const suffix = if (terminal_only) " (terminal only here)" else "";
            const label = std.fmt.bufPrint(&self.choice_labels[count], "{s} {s}{s}", .{ harness.displayName(), version, suffix }) catch harness.displayName();
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
        var random: [agent.CorrelationToken.byte_count]u8 = undefined;
        self.io.random(&random);
        const token = agent.CorrelationToken.fromBytes(random);

        // A remote workspace's sink is on the remote host, under the root
        // its detection resolved there (TASK-61); a Local one is under this
        // run's private state directory.
        const remote = request.context_kind.isRemote();
        const remote_context: ?workspace.ExecutionContext.Ref = if (remote) request.context orelse return error.NoSinkRoot else null;
        // An observed agent was started by the human: no launch files and no
        // hook relay, so it keeps no sink.
        const sink_dir: []u8 = if (request.choice.needsSink() and request.observed_pid == null) blk: {
            const root = if (remote) self.remoteSinkRootFor(request.workspace) orelse return error.NoSinkRoot else self.sink_root orelse return error.NoSinkRoot;
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
            .context = request.context,
            .token = token,
            .sink_dir = sink_dir,
            .sink = if (remote_context) |ref| agent.SinkIo.forContext(ref, .{}) else agent.SinkIo.local(),
            .cwd = cwd,
            .prompt = prompt,
            .backend = undefined,
            .queue = queue,
            .arena = .init(self.allocator),
            .wake = self.wake,
            .view = view,
            .observed_pid = request.observed_pid,
        };
        errdefer runner.arena.deinit();
        if (request.task_id) |task| if (task.len <= runner.task_id_bytes.len) {
            @memcpy(runner.task_id_bytes[0..task.len], task);
            runner.task_id_len = task.len;
        };
        try self.initBackend(runner, request);
        try self.runners.append(self.allocator, runner);
        if (remote and sink_dir.len != 0) {
            if (self.detectionFor(request.workspace)) |detection| detection.remote_used = true;
        }
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
                if (request.observed_pid != null) {
                    // A fake the check started by hand: no script and no
                    // side channel, only the PTY baseline, like an observed
                    // harness whose records cannot be found.
                    runner.backend.fake.script = &.{};
                    runner.backend.fake.caps = .{ .attach = true, .poll = true };
                    runner.polling = false;
                } else if (runner.sink.isRemote()) {
                    // The remote fake runs a script staged in its remote
                    // sink, so its launch files cross the connection too.
                    const arena = runner.arena.allocator();
                    const script_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ runner.sink_dir, fake_remote_script_name });
                    const files = try arena.alloc(agent.LaunchSpec.File, 1);
                    files[0] = .{ .path = script_path, .bytes = fake_remote_script, .executable = true };
                    const argv = try arena.alloc([]const u8, 2);
                    argv[0] = "/bin/sh";
                    argv[1] = script_path;
                    runner.backend.fake.launch_files = files;
                    runner.backend.fake.launch_argv = argv;
                } else if (self.fake_prompts) {
                    runner.backend.fake.script = &fake_prompts_script;
                    runner.fake_step_ends = &fake_prompts_step_ends;
                } else if (self.fake_view) {
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
                    // A remote agent's config directory is the remote
                    // host's, which its detection resolved there; this
                    // machine's `$HOME` means nothing on it.
                    const config_dir: ?[]const u8 = if (runner.sink.isRemote())
                        (if (self.detectionFor(request.workspace)) |detection| detection.remoteClaudeConfig() else null)
                    else
                        request.claude_config_dir orelse if (request.home) |home|
                            std.fmt.bufPrint(&config_buffer, "{s}/.claude", .{home}) catch null
                        else
                            null;
                    runner.backend = .{ .claude = agent.claude_code.ClaudeCodeAdapter.init(self.allocator, self.io, .{
                        .sink_dir = if (runner.sink_dir.len == 0) null else runner.sink_dir,
                        .config_dir = config_dir,
                        .probe_env = request.probe_env,
                        .sink_io = runner.sink,
                        .control_helper = self.control_helper,
                        .program = self.claude_program orelse "claude",
                        .observe = if (request.observed_pid) |pid| .{ .pid = pid, .cwd = runner.cwd } else null,
                    }) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.InvalidSinkPath => return error.NoSinkRoot,
                    } };
                    // An observed Claude Code is found in its own session
                    // registry (by the foreground pid, else the cwd) and
                    // followed through its transcript.
                    if (request.observed_pid != null) runner.needs_attach = true;
                },
                .pi => {
                    runner.backend = .{ .pi = .{ .adapter = undefined, .sink = .init(self.io, runner.sink_dir, runner.sink) } };
                    const pi = &runner.backend.pi;
                    pi.adapter = try agent.pi.PiAdapter.init(self.allocator, self.io, .{
                        .sink_dir = runner.sink_dir,
                        .transport = pi.sink.transport(),
                    });
                    // A hand-started Pi has no extension writing a sink:
                    // only the PTY baseline (its session JSONL is not
                    // followed live yet).
                    if (request.observed_pid != null) runner.polling = false;
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
                    // A hand-started OpenCode serves no port Conduit knows
                    // (the TUI talks to its worker in-process without
                    // `--port`), so an observed one keeps the PTY baseline.
                    const port: u16 = if (request.context_kind == .local and request.observed_pid == null) freeLoopbackPort(self.io) orelse 0 else 0;
                    runner.backend = .{ .opencode = try agent.opencode.OpenCodeAdapter.init(self.allocator, self.io, .{ .port = port }) };
                    runner.needs_attach = port != 0;
                    runner.polling = port != 0;
                },
            },
        }
    }

    /// Register a runner's agent bound to its session: owned, or observed
    /// for a runner made from `LaunchRequest.observed_pid`.
    pub fn register(self: *Runtime, runner: *Runner, binding: agent.Binding) !AgentId {
        const id = try self.registry.create(.{
            .binding = binding,
            .harness = runner.choice.registryHarness(),
            // An observed agent lives in the human's own terminal.
            .ownership = if (runner.observed_pid == null) .owned else .observed,
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

    pub const IngestError = error{
        /// No live agent of workspace `key` has that token.
        NotFound,
        /// The agent's harness has no line channel (Codex, OpenCode).
        Unavailable,
        /// The payload is not one line, or the sink could not be written.
        Rejected,
    };

    /// Deliver one `agent.event` from the control endpoint (TASK-60): the
    /// payload is the adapter's own event-line object, so it is appended,
    /// newline-terminated, to the `events.jsonl` the adapter already tails
    /// (Claude Code's hook relay, Pi's extension and the fake all use that
    /// line format). The token is compared in constant time and must belong
    /// to an agent of `key`. Owner thread; one bounded local append (at most
    /// the control frame size), the same file write the relay makes.
    pub fn ingestControlEvent(self: *Runtime, key: WorkspaceKey, token: *const [agent.CorrelationToken.text_len]u8, payload_json: []const u8) IngestError!void {
        var found: ?*Runner = null;
        for (self.runners.items) |runner| {
            if (runner.workspace != key or runner.closing) continue;
            if (std.crypto.timing_safe.eql([agent.CorrelationToken.text_len]u8, runner.token.text()[0..agent.CorrelationToken.text_len].*, token.*)) found = runner;
        }
        const runner = found orelse return error.NotFound;
        if (runner.sink_dir.len == 0) return error.Unavailable;
        // A remote agent's sink is on the remote host, and its hooks never
        // get the local endpoint: they keep the relay (TASK-61).
        if (runner.sink.isRemote()) return error.Unavailable;
        // The control server re-encodes the payload compactly, so a raw
        // newline cannot be in it; refuse one anyway rather than split lines.
        if (payload_json.len == 0 or std.mem.indexOfAny(u8, payload_json, "\r\n") != null) return error.Rejected;
        var path_buffer: [Dir.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ runner.sink_dir, agent.pi.events_file_name }) catch return error.Rejected;
        const line = self.allocator.alloc(u8, payload_json.len + 1) catch return error.Rejected;
        defer self.allocator.free(line);
        @memcpy(line[0..payload_json.len], payload_json);
        line[payload_json.len] = '\n';
        // One append-mode write (O_APPEND, or FILE_APPEND_DATA on Windows):
        // the relay script appends to the same file (`cat >> events.jsonl`),
        // and an append of the whole line at once can never interleave with
        // or overwrite one of its lines.
        platform.appendToFile(path, line) catch return error.Rejected;
        self.control_events_ingested += 1;
    }

    fn removeRunner(self: *Runtime, runner: *Runner) void {
        for (self.runners.items, 0..) |candidate, index| {
            if (candidate != runner) continue;
            _ = self.runners.swapRemove(index);
            break;
        }
        // A remote sink goes on a worker; the workspace's own close removes
        // the whole run root, so this is only for an agent closed earlier.
        if (runner.sink.isRemote() and runner.sink_dir.len != 0) {
            if (runner.context) |context| self.startCleanup(runner.workspace, context, runner.sink_dir);
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
        // `agent.stop` on an observed agent lands here while the human's
        // process still runs: remember not to attach to it again. A session
        // that is really gone drops its watch at the next look.
        if (self.registry.findBySession(key, id)) |agent_id| {
            if (self.runnerForAgent(agent_id)) |runner| if (runner.observed_pid) |pid| {
                if (self.watchFor(key, id)) |watch| watch.ignored_pid = pid;
            };
        }
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
        // Cleanups borrow the context too, and then the run root goes with
        // the workspace (a bounded wait, at an explicit close).
        index = 0;
        while (index < self.cleanups.items.len) {
            const job = self.cleanups.items[index];
            if (job.key != key) {
                index += 1;
                continue;
            }
            _ = self.cleanups.swapRemove(index);
            job.destroy();
        }
        index = 0;
        while (index < self.detections.items.len) {
            const detection = self.detections.items[index];
            if (detection.key != key) {
                index += 1;
                continue;
            }
            _ = self.detections.swapRemove(index);
            self.removeRemoteRoot(detection);
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
        index = 0;
        while (index < self.watches.items.len) {
            if (self.watches.items[index].key == key) {
                _ = self.watches.orderedRemove(index);
            } else index += 1;
        }
        self.changed = true;
    }

    // Observation and events --------------------------------------------------

    /// Feed one terminal fact about a session to its agent's heuristics.
    /// Sessions without an agent are ignored.
    pub fn observe(self: *Runtime, key: WorkspaceKey, id: SessionId, observation: Observation, now_ns: i96) void {
        switch (observation) {
            // Something happened in the terminal: what runs in front may
            // have changed (a harness started, or left).
            .output, .title, .command_started, .shell_prompt, .user_input => self.noteActivity(key, id),
            else => {},
        }
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

    fn watchFor(self: *Runtime, key: WorkspaceKey, id: SessionId) ?*Watch {
        for (self.watches.items) |*candidate| {
            if (candidate.key == key and candidate.id == id) return candidate;
        }
        return null;
    }

    /// Mark a session for a foreground look at the next due `poll`. Only
    /// sessions that may hold an observed agent are watched: none while no
    /// probe is installed, and never one Conduit launched an agent into.
    fn noteActivity(self: *Runtime, key: WorkspaceKey, id: SessionId) void {
        if (self.probe.probe_fn == null) return;
        if (self.watchFor(key, id)) |watch| {
            watch.due = true;
            return;
        }
        if (self.registry.findBySession(key, id)) |agent_id| {
            const record = self.registry.get(agent_id) orelse return;
            if (record.ownership == .owned) return;
        }
        if (self.watches.items.len >= watch_capacity) _ = self.watches.orderedRemove(0);
        self.watches.append(self.allocator, .{ .key = key, .id = id }) catch |err| {
            log.debug("a session was not watched for agents: {s}", .{@errorName(err)});
        };
    }

    /// Look at every due session's foreground process, at most once per
    /// `observe_interval_ns` each: attach an observed agent to a harness the
    /// human started in their own terminal, and end one whose harness left
    /// the foreground. Owner thread; each look is a few bounded `/proc`
    /// reads through the app's probe.
    fn checkForegrounds(self: *Runtime, now_ns: i96) void {
        const probe_fn = self.probe.probe_fn orelse return;
        var index: usize = 0;
        while (index < self.watches.items.len) {
            const watch = self.watches.items[index];
            const recent = if (watch.last_check_ns) |last| now_ns - last < observe_interval_ns else false;
            if (!watch.due or watch.excluded or recent) {
                index += 1;
                continue;
            }
            self.watches.items[index].due = false;
            self.watches.items[index].last_check_ns = now_ns;
            self.foreground_checks += 1;
            var buffer: [1024]u8 = undefined;
            const facts = probe_fn(self.probe.context, watch.key, watch.id, &buffer) orelse {
                // The session is gone.
                _ = self.watches.orderedRemove(index);
                continue;
            };
            self.checkForeground(&self.watches.items[index], facts);
            index += 1;
        }
    }

    /// What a foreground process is as an agent choice: a harness by its
    /// adapter's spelling, or the scripted fake when checks enable it.
    fn recognizeProcess(self: *const Runtime, process: pty.ForegroundProcess) ?Choice {
        const name = agent.commandName(process.argv0, process.argv1);
        if (self.fake_enabled and agent.recognizeFakeCommand(name)) return .fake;
        const harness = agent.recognize(name) orelse return null;
        return .{ .harness = harness };
    }

    fn checkForeground(self: *Runtime, watch: *Watch, facts: SessionFacts) void {
        // The scratchpad belongs to the human (invariant 7), an agent's own
        // terminal is already its agent's, and a connection terminal is
        // OpenSSH's: only a human terminal is ever observed.
        if (facts.binding.session_kind != .human_terminal) {
            watch.excluded = true;
            return;
        }
        const process = facts.process;
        const choice: ?Choice = if (process) |p| self.recognizeProcess(p) else null;
        if (self.registry.findBySession(watch.key, watch.id)) |agent_id| {
            const record = self.registry.get(agent_id) orelse return;
            if (record.ownership != .observed) return;
            const runner = self.runnerForAgent(agent_id);
            const same = if (runner) |r|
                choice != null and std.meta.eql(choice.?, r.choice) and r.observed_pid == process.?.pid
            else
                false;
            if (same) return;
            // The harness left the foreground, or another took its place.
            // Conduit did not start it and cannot read its status, so the
            // end is recorded as a normal one.
            self.applyAndAnnounce(agent_id, .{ .exited = .{ .code = 0 } }, null);
            if (runner) |r| r.join();
            log.debug("an observed agent left the foreground", .{});
        }
        const found = choice orelse {
            watch.ignored_pid = null;
            return;
        };
        const leader = process.?;
        if (watch.ignored_pid == leader.pid) return;
        // Observed side channels read this machine's files and sockets; a
        // remote workspace's terminal is an SSH client here (TASK-61).
        if (facts.context_kind.isRemote()) return;
        self.startObserved(watch.key, watch.id, found, leader, facts) catch |err| {
            log.debug("a hand-started agent was not observed: {s}", .{@errorName(err)});
        };
    }

    /// Register an observed agent for `process` in a human terminal and start
    /// its worker. A previous observed agent of the session, already ended,
    /// makes way, so the session has one record.
    fn startObserved(self: *Runtime, key: WorkspaceKey, id: SessionId, choice: Choice, process: pty.ForegroundProcess, facts: SessionFacts) !void {
        var index: usize = 0;
        while (index < self.registry.all().len) {
            const record = self.registry.all()[index];
            if (record.workspace == key and record.session == id and record.ownership == .observed and record.hasExited()) {
                if (self.runnerForAgent(record.id)) |old| self.removeRunner(old);
                self.forgetAgent(record.id);
                continue;
            }
            index += 1;
        }
        const runner = try self.createRunner(.{
            .choice = choice,
            .workspace = key,
            .session = id,
            .context_kind = facts.context_kind,
            .cwd = if (process.cwd.len != 0) process.cwd else "/",
            .home = facts.home,
            .claude_config_dir = facts.claude_config_dir,
            .codex_home = facts.codex_home,
            .observed_pid = process.pid,
        });
        _ = self.register(runner, facts.binding) catch |err| {
            self.removeRunner(runner);
            return err;
        };
        runner.start() catch |err| {
            log.warn("the observed agent's side channel worker did not start: {s}", .{@errorName(err)});
        };
        log.debug("observing a {s} the human started", .{choice.value()});
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

    /// The name a sidebar agent row shows (TASK-80): `fake` for the scripted
    /// fake, otherwise `rowHarnessName`.
    pub fn rowName(self: *const Runtime, record: *const agent.Agent) []const u8 {
        for (self.runners.items) |runner| {
            if (runner.agent_id == record.id and runner.choice == .fake) return "fake";
        }
        return rowHarnessName(record.harness);
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
            .context = runner.context,
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
            // Zero until the worker's first poll: keep what registration saw.
            const caps = runner.published_caps.load(.acquire);
            if (caps != 0 and self.registry.setCapabilities(id, @bitCast(caps))) self.changed = true;
            var batch_entry: ?*Entry = null;
            while (true) {
                const n = runner.queue.drain(self.drained);
                if (n == 0) break;
                if (self.trackFor(id)) |track_record| track_record.last_activity_ns = now_ns;
                for (self.drained[0..n]) |*stored| self.applyAndAnnounce(id, stored.event, &batch_entry);
            }
        }
        self.checkForegrounds(now_ns);
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
        index = 0;
        while (index < self.cleanups.items.len) {
            const job = self.cleanups.items[index];
            if (!job.done.load(.acquire)) {
                index += 1;
                continue;
            }
            _ = self.cleanups.swapRemove(index);
            job.destroy();
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

test "sidebar agent rows read glyph, harness and state words" {
    var buffer: [agent_row_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("▸ claude working", formatAgentRow(&buffer, rowHarnessName(.claude_code), .working));
    try std.testing.expectEqualStrings("! codex permission", formatAgentRow(&buffer, rowHarnessName(.codex), .waiting_permission));
    try std.testing.expectEqualStrings("✓ pi done", formatAgentRow(&buffer, rowHarnessName(.pi), .done));
    try std.testing.expectEqualStrings("? opencode input", formatAgentRow(&buffer, rowHarnessName(.opencode), .waiting_input));
    try std.testing.expectEqualStrings("× fake errored", formatAgentRow(&buffer, "fake", .errored));
    try std.testing.expectEqualStrings("· aaaaaaaaaaaaaaaa idle", formatAgentRow(&buffer, "a" ** 40, .idle));
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
    try testing.expectEqual(@as(usize, 10), fakeReleased(6));
    try testing.expectEqual(@as(usize, 10), fakeReleased(99));
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

/// A scripted answer to the runtime's foreground looks: one process per
/// session, changed by the test as a human would by starting and quitting
/// programs.
const ScriptedProbe = struct {
    kind: session.Session.Kind = .human_terminal,
    context_kind: workspace.ExecutionContextKind = .local,
    argv0: []const u8 = "bash",
    argv1: []const u8 = "",
    pid: u32 = 100,
    gone: bool = false,
    looks: usize = 0,

    fn probe(context: ?*anyopaque, key: WorkspaceKey, id: SessionId, buffer: []u8) ?SessionFacts {
        const self: *ScriptedProbe = @ptrCast(@alignCast(context.?));
        self.looks += 1;
        if (self.gone) return null;
        // The real probe copies into the lent buffer; so does this one.
        @memcpy(buffer[0..self.argv0.len], self.argv0);
        @memcpy(buffer[self.argv0.len..][0..self.argv1.len], self.argv1);
        return .{
            .binding = .{ .workspace = key, .session = id, .session_kind = self.kind, .scratchpad = SessionId.fromOrdinal(9) },
            .context_kind = self.context_kind,
            .process = .{
                .pid = self.pid,
                .argv0 = buffer[0..self.argv0.len],
                .argv1 = buffer[self.argv0.len..][0..self.argv1.len],
                .cwd = "/work",
            },
        };
    }
};

test "a harness started by hand in a human terminal is observed, rate-limited, and ends when it leaves" {
    var runtime = try Runtime.init(testing.allocator, testing.io, .{ .fake_enabled = true });
    defer runtime.deinit();
    var notifier: TestNotifier = .{};
    runtime.notifier = .{ .context = &notifier, .notify_fn = TestNotifier.record };
    const key = WorkspaceKey.fromOrdinal(0);
    const human = SessionId.fromOrdinal(1);
    const s: i96 = std.time.ns_per_s;

    // Without a probe nothing is watched.
    runtime.observe(key, human, .{ .output = .{ .now_ns = 0 } }, 0);
    _ = runtime.poll(s);
    try testing.expectEqual(@as(usize, 0), runtime.watches.items.len);

    var scripted: ScriptedProbe = .{};
    runtime.probe = .{ .context = &scripted, .probe_fn = ScriptedProbe.probe };

    // A plain shell in front: looked at once, nothing observed.
    runtime.observe(key, human, .shell_prompt, 0);
    _ = runtime.poll(10 * s);
    try testing.expectEqual(@as(usize, 1), scripted.looks);
    try testing.expect(!runtime.hasAgent(key, human));
    // More activity within the interval waits for it to pass.
    runtime.observe(key, human, .{ .output = .{ .now_ns = 0 } }, 10 * s);
    _ = runtime.poll(11 * s);
    try testing.expectEqual(@as(usize, 1), scripted.looks);
    _ = runtime.poll(12 * s);
    try testing.expectEqual(@as(usize, 2), scripted.looks);
    // No activity: no look, however long it has been.
    _ = runtime.poll(20 * s);
    try testing.expectEqual(@as(usize, 2), scripted.looks);

    // The human starts the fake by hand (a `#!/bin/sh` script in front).
    scripted.argv0 = "/bin/sh";
    scripted.argv1 = "/tmp/bin/conduit-fake-agent";
    scripted.pid = 4242;
    runtime.observe(key, human, .{ .output = .{ .now_ns = 0 } }, 21 * s);
    _ = runtime.poll(22 * s);
    try testing.expectEqual(@as(usize, 3), scripted.looks);
    const record = runtime.agentForSession(key, human) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(agent.Ownership.observed, record.ownership);
    try testing.expectEqualStrings("Fake agent", runtime.displayName(record));
    const first_id = record.id;
    try testing.expect(!runtime.restartable(first_id));
    try testing.expectEqual(@as(?u32, 4242), runtime.runnerForAgent(first_id).?.observed_pid);
    // Its PTY baseline runs like any agent's: output means working.
    runtime.observe(key, human, .{ .output = .{ .now_ns = @intCast(23 * s) } }, 23 * s);
    try testing.expectEqual(State.working, runtime.agentForSession(key, human).?.state);
    // Still in front: the next look keeps it.
    _ = runtime.poll(25 * s);
    try testing.expectEqual(@as(usize, 4), scripted.looks);
    try testing.expectEqual(first_id, runtime.agentForSession(key, human).?.id);

    // It exits and the shell is back in front: the agent ends.
    scripted.argv0 = "bash";
    scripted.argv1 = "";
    scripted.pid = 100;
    runtime.observe(key, human, .shell_prompt, 26 * s);
    _ = runtime.poll(28 * s);
    try testing.expect(!runtime.hasAgent(key, human));
    try testing.expect(runtime.registry.get(first_id).?.hasExited());
    try testing.expectEqual(State.done, runtime.registry.get(first_id).?.state);

    // Started again: a new observed agent replaces the ended record.
    scripted.argv0 = "/bin/sh";
    scripted.argv1 = "/tmp/bin/conduit-fake-agent";
    scripted.pid = 4343;
    runtime.observe(key, human, .{ .output = .{ .now_ns = 0 } }, 30 * s);
    _ = runtime.poll(30 * s);
    const second = runtime.agentForSession(key, human) orelse return error.TestUnexpectedResult;
    try testing.expect(second.id != first_id);
    try testing.expect(runtime.registry.get(first_id) == null);
    try testing.expectEqual(@as(usize, 1), runtime.registry.all().len);

    // The human stops observing it: forgotten, and not attached again while
    // the same process stays in front.
    runtime.sessionClosed(key, human);
    try testing.expect(!runtime.hasAgent(key, human));
    runtime.observe(key, human, .{ .output = .{ .now_ns = 0 } }, 33 * s);
    _ = runtime.poll(33 * s);
    try testing.expect(!runtime.hasAgent(key, human));

    // A real harness's spelling is recognized through its adapter; with no
    // Claude Code config directory its side channel is unavailable and the
    // agent keeps the PTY baseline.
    scripted.argv0 = "/home/u/.local/bin/claude";
    scripted.argv1 = "";
    scripted.pid = 5000;
    runtime.observe(key, human, .{ .output = .{ .now_ns = 0 } }, 36 * s);
    _ = runtime.poll(36 * s);
    const claude = runtime.agentForSession(key, human) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Harness.claude_code, claude.harness);
    try testing.expectEqualStrings("Claude Code", runtime.displayName(claude));
    try testing.expectEqualStrings("/work", runtime.runnerForAgent(claude.id).?.cwd);

    // The scratchpad, an agent terminal and a remote context are never
    // observed, whatever runs there.
    const scratch = SessionId.fromOrdinal(2);
    scripted.kind = .scratchpad;
    runtime.observe(key, scratch, .{ .output = .{ .now_ns = 0 } }, 40 * s);
    _ = runtime.poll(40 * s);
    try testing.expect(!runtime.hasAgent(key, scratch));
    const looks = scripted.looks;
    runtime.observe(key, scratch, .{ .output = .{ .now_ns = 0 } }, 50 * s);
    _ = runtime.poll(50 * s);
    try testing.expectEqual(looks, scripted.looks);
    scripted.kind = .human_terminal;
    scripted.context_kind = .ssh;
    const remote = SessionId.fromOrdinal(3);
    runtime.observe(key, remote, .{ .output = .{ .now_ns = 0 } }, 50 * s);
    _ = runtime.poll(50 * s);
    try testing.expect(!runtime.hasAgent(key, remote));

    // A session that is gone stops being watched.
    scripted.gone = true;
    const before = runtime.watches.items.len;
    runtime.observe(key, remote, .{ .output = .{ .now_ns = 0 } }, 60 * s);
    _ = runtime.poll(60 * s);
    try testing.expectEqual(before - 1, runtime.watches.items.len);
    runtime.removeWorkspace(key);
    try testing.expectEqual(@as(usize, 0), runtime.watches.items.len);
}

test "an agent's capabilities follow its adapter after registration" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(testing.io, &root_buffer);
    var sink_buffer: [Dir.max_path_bytes]u8 = undefined;
    const sink_root = try std.fmt.bufPrint(&sink_buffer, "{s}/agents", .{root_buffer[0..tmp_path_len]});
    var runtime = try Runtime.init(testing.allocator, testing.io, .{ .sink_root = sink_root, .fake_enabled = true });
    defer runtime.deinit();
    const key = WorkspaceKey.fromOrdinal(0);
    const id = SessionId.fromOrdinal(1);
    const runner = try runtime.createRunner(.{ .choice = .fake, .workspace = key, .session = id, .context_kind = .local, .cwd = "/" });
    // Registered while the side channel is not up yet (as OpenCode's is
    // until its event stream answers).
    runner.backend.fake.caps = .{ .launch = true, .poll = true };
    _ = try runtime.register(runner, .{ .workspace = key, .session = id, .session_kind = .agent_terminal, .scratchpad = .first });
    try testing.expect(!runtime.agentForSession(key, id).?.capabilities.respond_permission);
    _ = runtime.poll(0);
    try testing.expect(!runtime.agentForSession(key, id).?.capabilities.respond_permission);
    // The channel comes up: the worker publishes, the owner records it, and
    // the view may offer answers.
    runner.backend.fake.caps = agent.FakeAdapter.all_capabilities;
    runner.pollOnce();
    _ = runtime.poll(1);
    try testing.expect(runtime.agentForSession(key, id).?.capabilities.respond_permission);
}

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

test "a control agent.event reaches its own agent's sink as one line and nothing else" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPath(testing.io, &root_buffer);
    var sink_buffer: [Dir.max_path_bytes]u8 = undefined;
    const sink_root = try std.fmt.bufPrint(&sink_buffer, "{s}/agents", .{root_buffer[0..tmp_path_len]});

    var runtime = try Runtime.init(testing.allocator, testing.io, .{ .sink_root = sink_root, .fake_enabled = true });
    defer runtime.deinit();
    const key = WorkspaceKey.fromOrdinal(0);
    const runner = try runtime.createRunner(.{ .choice = .fake, .workspace = key, .session = SessionId.fromOrdinal(1), .context_kind = .local, .cwd = "/" });
    _ = try runner.prepare(&.{"PATH=/bin"});
    const token = runner.token.text()[0..agent.CorrelationToken.text_len];

    const line = "{\"conduit\":{\"v\":1,\"event\":\"Stop\"},\"payload\":{}}";
    try runtime.ingestControlEvent(key, token, line);
    try runtime.ingestControlEvent(key, token, line);
    var other_token = token.*;
    other_token[0] = if (other_token[0] == 'a') 'b' else 'a';
    try testing.expectError(error.NotFound, runtime.ingestControlEvent(key, &other_token, line));
    // The right token in another workspace's name reaches nothing.
    try testing.expectError(error.NotFound, runtime.ingestControlEvent(WorkspaceKey.fromOrdinal(1), token, line));
    try testing.expectError(error.Rejected, runtime.ingestControlEvent(key, token, "{}\n{}"));

    var path_buffer: [Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ runner.sink_dir, agent.pi.events_file_name });
    var read_buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(line ++ "\n" ++ line ++ "\n", try Dir.cwd().readFile(testing.io, path, &read_buffer));
}

/// A remote-looking context for the runtime's TASK-61 paths: an in-memory
/// file system, a state directory and a command log, so remote sinks,
/// launch files, decisions and cleanups are checked without SSH. Guarded by
/// a mutex because detections and cleanups call it from their workers.
const ScriptedRemote = struct {
    mutex: Io.Mutex = .init,
    files: std.StringArrayHashMapUnmanaged(Stored) = .empty,
    dirs: std.StringArrayHashMapUnmanaged(void) = .empty,
    commands: std.ArrayList([]u8) = .empty,
    state_dir: []const u8 = "/home/remote/.local/state",

    const Stored = struct { bytes: []u8, mode: u32 };

    const vtable: workspace.ExecutionContext.VTable = .{
        .spawn = spawn,
        .kind = kind,
        .destroy = destroy,
        .read_file = readFile,
        .read_file_at = readFileAt,
        .write_file = writeFile,
        .make_private_dir = makePrivateDir,
        .state_dir = stateDir,
        .run = run,
    };

    fn ref(self: *ScriptedRemote) workspace.ExecutionContext.Ref {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn deinit(self: *ScriptedRemote) void {
        for (self.files.keys(), self.files.values()) |key, value| {
            testing.allocator.free(key);
            testing.allocator.free(value.bytes);
        }
        self.files.deinit(testing.allocator);
        for (self.dirs.keys()) |key| testing.allocator.free(key);
        self.dirs.deinit(testing.allocator);
        for (self.commands.items) |command| testing.allocator.free(command);
        self.commands.deinit(testing.allocator);
    }

    const spawn_fn = @typeInfo(@typeInfo(workspace.ExecutionContext.SpawnFn).pointer.child).@"fn";

    fn spawn(_: *anyopaque, _: spawn_fn.params[1].type.?) spawn_fn.return_type.? {
        return error.Closed;
    }

    fn kind(_: *const anyopaque) workspace.ExecutionContextKind {
        return .ssh;
    }

    fn destroy(_: *anyopaque) void {}

    fn cast(ptr: *anyopaque) *ScriptedRemote {
        return @ptrCast(@alignCast(ptr));
    }

    fn readFile(ptr: *anyopaque, io: Io, path: []const u8, buffer: []u8) workspace.FsError![]u8 {
        const self = cast(ptr);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stored = self.files.get(path) orelse return error.NotFound;
        if (stored.bytes.len > buffer.len) return error.TooLarge;
        @memcpy(buffer[0..stored.bytes.len], stored.bytes);
        return buffer[0..stored.bytes.len];
    }

    fn readFileAt(ptr: *anyopaque, io: Io, path: []const u8, offset: u64, buffer: []u8) workspace.FsError!usize {
        const self = cast(ptr);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stored = self.files.get(path) orelse return error.NotFound;
        if (offset >= stored.bytes.len) return 0;
        const rest = stored.bytes[@intCast(offset)..];
        const n = @min(rest.len, buffer.len);
        @memcpy(buffer[0..n], rest[0..n]);
        return n;
    }

    fn put(self: *ScriptedRemote, path: []const u8, bytes: []const u8, mode: u32) workspace.FsError!void {
        const copy = testing.allocator.dupe(u8, bytes) catch return error.OutOfMemory;
        if (self.files.getPtr(path)) |existing| {
            testing.allocator.free(existing.bytes);
            existing.* = .{ .bytes = copy, .mode = mode };
            return;
        }
        const key = testing.allocator.dupe(u8, path) catch {
            testing.allocator.free(copy);
            return error.OutOfMemory;
        };
        self.files.put(testing.allocator, key, .{ .bytes = copy, .mode = mode }) catch {
            testing.allocator.free(key);
            testing.allocator.free(copy);
            return error.OutOfMemory;
        };
    }

    fn writeFile(ptr: *anyopaque, io: Io, path: []const u8, bytes: []const u8, mode: u32) workspace.FsError!void {
        const self = cast(ptr);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.put(path, bytes, mode);
    }

    fn makePrivateDir(ptr: *anyopaque, io: Io, path: []const u8) workspace.FsError!void {
        const self = cast(ptr);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.dirs.contains(path)) return;
        const copy = testing.allocator.dupe(u8, path) catch return error.OutOfMemory;
        self.dirs.put(testing.allocator, copy, {}) catch {
            testing.allocator.free(copy);
            return error.OutOfMemory;
        };
    }

    fn stateDir(ptr: *anyopaque, _: Io, buffer: []u8) workspace.FsError![]u8 {
        const self = cast(ptr);
        if (self.state_dir.len > buffer.len) return error.TooLarge;
        @memcpy(buffer[0..self.state_dir.len], self.state_dir);
        return buffer[0..self.state_dir.len];
    }

    /// `/bin/sh -c …` is Claude Code's config lookup; `rm -rf -- <path>`
    /// removes every file and directory under `path`. Both are logged.
    fn run(ptr: *anyopaque, allocator: Allocator, io: Io, request: workspace.RunRequest) workspace.RunError!workspace.RunResult {
        const self = cast(ptr);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const joined = std.mem.join(testing.allocator, " ", request.argv) catch return error.OutOfMemory;
        self.commands.append(testing.allocator, joined) catch {
            testing.allocator.free(joined);
            return error.OutOfMemory;
        };
        var stdout: []const u8 = "";
        if (std.mem.eql(u8, request.argv[0], "/bin/sh")) stdout = "/home/remote/.claude";
        if (std.mem.eql(u8, request.argv[0], "rm") and request.argv.len == 4) {
            const target = request.argv[3];
            var index: usize = 0;
            while (index < self.files.count()) {
                const key = self.files.keys()[index];
                if (std.mem.startsWith(u8, key, target)) {
                    const value = self.files.values()[index];
                    self.files.swapRemoveAt(index);
                    testing.allocator.free(value.bytes);
                    testing.allocator.free(key);
                    continue;
                }
                index += 1;
            }
            index = 0;
            while (index < self.dirs.count()) {
                const key = self.dirs.keys()[index];
                if (std.mem.startsWith(u8, key, target)) {
                    self.dirs.swapRemoveAt(index);
                    testing.allocator.free(key);
                    continue;
                }
                index += 1;
            }
        }
        const out = allocator.dupe(u8, stdout) catch return error.OutOfMemory;
        const err_out = allocator.alloc(u8, 0) catch {
            allocator.free(out);
            return error.OutOfMemory;
        };
        return .{ .exit_code = 0, .stdout = out, .stderr = err_out };
    }

    fn hasFilesUnder(self: *ScriptedRemote, prefix: []const u8) bool {
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        for (self.files.keys()) |key| if (std.mem.startsWith(u8, key, prefix)) return true;
        for (self.dirs.keys()) |key| if (std.mem.startsWith(u8, key, prefix)) return true;
        return false;
    }

    fn ranCommand(self: *ScriptedRemote, prefix: []const u8) bool {
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        for (self.commands.items) |logged| if (std.mem.startsWith(u8, logged, prefix)) return true;
        return false;
    }
};

/// Join every running detection, as `poll` would once each is done.
fn joinDetections(runtime: *Runtime) void {
    for (runtime.detections.items) |detection| {
        if (detection.thread) |thread| thread.join();
        detection.thread = null;
    }
}

/// Join every queued remote cleanup.
fn joinCleanups(runtime: *Runtime) void {
    for (runtime.cleanups.items) |job| {
        if (job.thread) |thread| thread.join();
        job.thread = null;
    }
}

test "remote sink roots and removable paths refuse anything but a plain sink" {
    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings("/h/.local/state/conduit/agents/r-1", try remoteSinkRoot(&buffer, "/h/.local/state/", "r-1"));
    try testing.expectError(error.Unsafe, remoteSinkRoot(&buffer, "relative/state", "r"));
    try testing.expectError(error.Unsafe, remoteSinkRoot(&buffer, "/h/../etc", "r"));
    try testing.expectError(error.Unsafe, remoteSinkRoot(&buffer, "/h/st\x1bate", "r"));
    try testing.expectError(error.Unsafe, remoteSinkRoot(&buffer, "/h", "a/b"));
    try testing.expectError(error.Unsafe, remoteSinkRoot(&buffer, "/h", ""));
    var small: [8]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, remoteSinkRoot(&small, "/h", "r"));

    try testing.expect(removableSinkPath("/h/.local/state/conduit/agents/r-1"));
    try testing.expect(removableSinkPath("/h/.local/state/conduit/agents/r-1/0123456789abcdef"));
    try testing.expect(!removableSinkPath("/h/.local/state/conduit/agents/"));
    try testing.expect(!removableSinkPath("/"));
    try testing.expect(!removableSinkPath("/h/conduit/agents/../../etc"));
    try testing.expect(!removableSinkPath("h/conduit/agents/r"));

    try testing.expect(insideSink("/s/x", "/s/x/ext/conduit.js"));
    try testing.expect(!insideSink("/s/x", "/s/x/../y"));
    try testing.expect(!insideSink("/s/x", "/s/xy/file"));
    try testing.expect(!insideSink("/s/x", "/s/x/"));
    try testing.expect(safeFileName("fake-1") and !safeFileName("../x") and !safeFileName(".hidden") and !safeFileName("a/b"));
}

test "a remote fake agent's sink, launch files, steps and decisions go through the context, and cleanups remove them" {
    var remote: ScriptedRemote = .{};
    defer remote.deinit();
    var runtime = try Runtime.init(testing.allocator, testing.io, .{ .sink_root = "/local/state/conduit/agents/run-7", .fake_enabled = true });
    defer runtime.deinit();
    try testing.expectEqualStrings("run-7", runtime.runName());
    const key = WorkspaceKey.fromOrdinal(0);
    const session_id = SessionId.fromOrdinal(1);
    const request: LaunchRequest = .{ .choice = .fake, .workspace = key, .session = session_id, .context_kind = .ssh, .context = remote.ref(), .cwd = "/home/remote/project" };

    // Until the detection has resolved the remote root there is nowhere to
    // put a sink, and nothing is made on this machine instead.
    try testing.expectError(error.NoSinkRoot, runtime.createRunner(request));
    runtime.ensureDetection(key, remote.ref(), &.{}, false);
    joinDetections(&runtime);
    const root = runtime.remoteSinkRootFor(key).?;
    try testing.expectEqualStrings("/home/remote/.local/state/conduit/agents/run-7", root);
    // Checks that offer only the fake never probe harnesses.
    try testing.expectEqual(@as(usize, 1), runtime.launchChoices(key).len);

    const runner = try runtime.createRunner(request);
    try testing.expect(runner.sink.isRemote());
    try testing.expect(std.mem.startsWith(u8, runner.sink_dir, "/home/remote/.local/state/conduit/agents/run-7/"));
    const prepared = try runner.prepare(&.{ "TERM=xterm-256color", "CONDUIT_AGENT_SINK=stale" });
    try testing.expectEqualStrings("/bin/sh", prepared.argv[0]);
    var script_path_buffer: [256]u8 = undefined;
    const script_path = try std.fmt.bufPrint(&script_path_buffer, "{s}/{s}", .{ runner.sink_dir, fake_remote_script_name });
    try testing.expectEqualStrings(script_path, prepared.argv[1]);
    try testing.expect(remote.dirs.contains(runner.sink_dir));
    const staged = remote.files.get(script_path).?;
    try testing.expectEqualStrings(fake_remote_script, staged.bytes);
    try testing.expectEqual(@as(u32, 0o700), staged.mode);
    var sink_env: ?[]const u8 = null;
    for (prepared.env) |entry| {
        if (std.mem.startsWith(u8, entry, agent.pi.sink_env_name ++ "=")) sink_env = entry[agent.pi.sink_env_name.len + 1 ..];
    }
    try testing.expectEqualStrings(runner.sink_dir, sink_env.?);

    // A step the remote script appended releases events; an answer becomes
    // a decision file on the remote host.
    const id = try runtime.register(runner, .{ .workspace = key, .session = session_id, .session_kind = .agent_terminal, .scratchpad = .first });
    runner.sink.idle_read_interval_ms = 0;
    var steps_buffer: [256]u8 = undefined;
    try remote.put(try std.fmt.bufPrint(&steps_buffer, "{s}/steps", .{runner.sink_dir}), "xx", 0o600);
    runner.pollOnce();
    _ = runtime.poll(0);
    try testing.expectEqual(State.waiting_permission, runtime.registry.get(id).?.state);
    try runner.answerPermission("fake-1", "allow");
    runner.pollOnce();
    var decision_buffer: [256]u8 = undefined;
    const decision = remote.files.get(try std.fmt.bufPrint(&decision_buffer, "{s}/decisions/fake-1", .{runner.sink_dir})).?;
    try testing.expectEqualStrings("allow", decision.bytes);
    try testing.expectEqual(agent.sink_io.private_file_mode, decision.mode);

    // The control endpoint never reaches a remote sink.
    const token = runner.token.text()[0..agent.CorrelationToken.text_len];
    try testing.expectError(error.Unavailable, runtime.ingestControlEvent(key, token, "{}"));

    // Closing the agent's session removes its remote sink on a worker.
    var sink_copy_buffer: [256]u8 = undefined;
    const sink_copy = try std.fmt.bufPrint(&sink_copy_buffer, "{s}", .{runner.sink_dir});
    runtime.sessionClosed(key, session_id);
    joinCleanups(&runtime);
    _ = runtime.poll(0);
    try testing.expectEqual(@as(usize, 0), runtime.cleanups.items.len);
    var rm_buffer: [300]u8 = undefined;
    try testing.expect(remote.ranCommand(try std.fmt.bufPrint(&rm_buffer, "rm -rf -- {s}", .{sink_copy})));
    try testing.expect(!remote.hasFilesUnder(sink_copy));

    // A second agent, then the workspace closes: the whole run root goes.
    const second = try runtime.createRunner(.{ .choice = .fake, .workspace = key, .session = SessionId.fromOrdinal(2), .context_kind = .ssh, .context = remote.ref(), .cwd = "/" });
    _ = try second.prepare(&.{});
    const remote_root = "/home/remote/.local/state/conduit/agents/run-7";
    try testing.expect(remote.hasFilesUnder(remote_root));
    runtime.removeWorkspace(key);
    try testing.expect(remote.ranCommand("rm -rf -- " ++ remote_root));
    try testing.expect(!remote.hasFilesUnder(remote_root));
}

test "remote Claude Code and Pi agents stage their sinks on the remote host with its config directory" {
    var remote: ScriptedRemote = .{};
    defer remote.deinit();
    var runtime = try Runtime.init(testing.allocator, testing.io, .{ .sink_root = "/local/agents/run-9" });
    defer runtime.deinit();
    runtime.control_helper = "/opt/conduit/bin/conduit";
    const key = WorkspaceKey.fromOrdinal(3);
    runtime.ensureDetection(key, remote.ref(), &.{}, false);
    joinDetections(&runtime);
    try testing.expect(remote.ranCommand("/bin/sh -c "));

    const claude = try runtime.createRunner(.{ .choice = .{ .harness = .claude_code }, .workspace = key, .session = SessionId.fromOrdinal(1), .context_kind = .ssh, .context = remote.ref(), .cwd = "/p", .home = "/local/home" });
    try testing.expectEqualStrings("/home/remote/.claude", claude.backend.claude.config_dir.?);
    try testing.expect(claude.backend.claude.sink.isRemote());
    // No local `conduit control` helper for hooks on another machine.
    try testing.expectEqual(@as(?[]const u8, null), claude.backend.claude.control_helper);
    const spec = try claude.prepare(&.{});
    try testing.expectEqualStrings("claude", spec.argv[0]);
    var path_buffer: [256]u8 = undefined;
    try testing.expect(remote.files.get(try std.fmt.bufPrint(&path_buffer, "{s}/settings.json", .{claude.sink_dir})) != null);
    try testing.expect(remote.files.get(try std.fmt.bufPrint(&path_buffer, "{s}/hook.sh", .{claude.sink_dir})) != null);

    const pi = try runtime.createRunner(.{ .choice = .{ .harness = .pi }, .workspace = key, .session = SessionId.fromOrdinal(2), .context_kind = .ssh, .context = remote.ref(), .cwd = "/p" });
    _ = try pi.prepare(&.{});
    const extension = remote.files.get(try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ pi.sink_dir, agent.pi.extension_file_name })).?;
    try testing.expectEqualStrings(agent.pi.extension_source, extension.bytes);
    try testing.expect(pi.backend.pi.sink.sink.isRemote());

    // Codex and OpenCode keep the PTY baseline remotely and need no sink.
    const codex = try runtime.createRunner(.{ .choice = .{ .harness = .codex }, .workspace = key, .session = SessionId.fromOrdinal(4), .context_kind = .ssh, .context = remote.ref(), .cwd = "/p" });
    try testing.expectEqual(@as(usize, 0), codex.sink_dir.len);
    try testing.expect(!codex.polling);
}
