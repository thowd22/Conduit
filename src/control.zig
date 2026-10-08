//! The local control API (TASK-60): lets a harness running inside a Conduit
//! terminal open a tab or split pane in its own workspace, show an agent or
//! backlog view, set its tab's status, raise a notification and deliver agent
//! hook/extension events, over a token-scoped local socket (a protected
//! named pipe on Windows, TASK-82).
//!
//! - `protocol`: tokens, the enumerated methods, typed requests, faults and
//!   reply encoding (transport-neutral, bounded, untrusted input).
//! - `queue`: the bounded hand-off from connection threads to the owner.
//! - `server`: the listener and connection threads, the token registry and
//!   the owner-side `service`/`complete` calls through a `Handler` vtable.
//!
//! The owner (the app, part two) starts one `Server` per run with an
//! endpoint inside the run's private 0700 directory, issues one token per
//! workspace, injects `CONDUIT_CONTROL_ENDPOINT`, `CONDUIT_CONTROL_TOKEN` and
//! `CONDUIT_CONTROL_SESSION` into that workspace's non-scratchpad children,
//! and revokes the token when the workspace closes. The scratchpad is never
//! addressable: its child gets no control environment and the server refuses
//! its session id. See `docs/control-api.md`.
//!
//! The single-instance endpoint (TASK-66) is a second `Server` the app runs
//! at `instanceEndpoint` with one token, `instance_workspace`, kept 0600 in
//! the state directory's `instance.token`. A `conduit <command>` reads that
//! token and forwards its command as one of the `instance.*` methods.

const std = @import("std");
const builtin = @import("builtin");

pub const protocol = @import("control/protocol.zig");
pub const queue = @import("control/queue.zig");
pub const server = @import("control/server.zig");

pub const endpoint_env_name = protocol.endpoint_env_name;
pub const token_env_name = protocol.token_env_name;
pub const session_env_name = protocol.session_env_name;
/// The endpoint's file name inside the run's private state directory.
pub const endpoint_file_name = "control.sock";
/// The single-instance endpoint's file name inside `runtimeDirectory`.
pub const instance_endpoint_file_name = "instance.sock";
/// The instance token's file name inside the state directory.
pub const instance_token_file_name = "instance.token";
/// The scope the instance token resolves to. Workspace refs are workspace
/// keys (one-based), which never reach this value.
pub const instance_workspace: WorkspaceRef = std.math.maxInt(WorkspaceRef);

/// What `runtimeDirectory` reads from the environment. Each is null when unset.
pub const RuntimeEnv = struct {
    xdg_runtime_dir: ?[]const u8 = null,
    tmpdir: ?[]const u8 = null,
    /// The real user id, for the shared-`/tmp` fallback's name.
    uid: u32 = 0,
    /// Windows: the user's SID text (`platform.currentUserId`), which names
    /// the per-user pipes. Unused elsewhere.
    windows_user: ?[]const u8 = null,
};

/// The Windows namespace every local endpoint is a pipe in.
pub const windows_pipe_prefix = "\\\\.\\pipe\\";

/// Where Conduit's local endpoints live for this user, written into
/// `buffer`:
///
/// - Linux and other Unix: the directory `$XDG_RUNTIME_DIR/conduit` (an
///   absolute `XDG_RUNTIME_DIR` only), else `/tmp/conduit-<uid>`.
/// - macOS: `$XDG_RUNTIME_DIR/conduit` when set, else `$TMPDIR/conduit`
///   (the per-user temporary directory), else `/tmp/conduit-<uid>`.
/// - Windows (TASK-82): not a directory but a pipe-name prefix,
///   `\\.\pipe\conduit-<user SID>`, with `-x<16 hex>` (a hash of
///   `XDG_RUNTIME_DIR`) appended when that is set, so an isolated test run
///   names pipes of its own. Null without a usable user SID.
///
/// The caller creates a POSIX directory 0700, and
/// `platform.LocalSocketListener` refuses one with group or other
/// permissions; on Windows it creates each pipe for the current user only.
/// `conduit-test launch` and `--control-test` set an isolated
/// `XDG_RUNTIME_DIR`, so a test never reaches the user's instance.
pub fn runtimeDirectory(buffer: []u8, os: std.Target.Os.Tag, env: RuntimeEnv) ?[]const u8 {
    if (os == .windows) {
        const user = env.windows_user orelse return null;
        if (user.len == 0 or user.len > 128) return null;
        for (user) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return null;
        if (env.xdg_runtime_dir) |dir| if (dir.len != 0) {
            const hash = std.hash.Wyhash.hash(0, dir);
            return std.fmt.bufPrint(buffer, "{s}conduit-{s}-x{x:0>16}", .{ windows_pipe_prefix, user, hash }) catch null;
        };
        return std.fmt.bufPrint(buffer, "{s}conduit-{s}", .{ windows_pipe_prefix, user }) catch null;
    }
    if (env.xdg_runtime_dir) |dir| {
        if (dir.len != 0 and dir[0] == '/') return std.fmt.bufPrint(buffer, "{s}/conduit", .{std.mem.trimEnd(u8, dir, "/")}) catch null;
    }
    if (os == .macos) if (env.tmpdir) |dir| {
        if (dir.len != 0 and dir[0] == '/') return std.fmt.bufPrint(buffer, "{s}/conduit", .{std.mem.trimEnd(u8, dir, "/")}) catch null;
    };
    return std.fmt.bufPrint(buffer, "/tmp/conduit-{d}", .{env.uid}) catch null;
}

/// The run's control endpoint in the runtime directory `dir`:
/// `<dir>/r-<8 hex>.sock` (short, since the whole path must fit
/// `sockaddr_un`), or on Windows the pipe `<dir>-r-<8 hex>`.
pub fn runEndpoint(buffer: []u8, os: std.Target.Os.Tag, dir: []const u8, suffix: [4]u8) ?[]const u8 {
    if (os == .windows) return std.fmt.bufPrint(buffer, "{s}-r-{x}", .{ dir, &suffix }) catch null;
    return std.fmt.bufPrint(buffer, "{s}/r-{x}.sock", .{ dir, &suffix }) catch null;
}

/// The single-instance endpoint in the runtime directory `dir`:
/// `<dir>/instance.sock`, or on Windows the pipe `<dir>-instance`.
pub fn instanceEndpointIn(buffer: []u8, os: std.Target.Os.Tag, dir: []const u8) ?[]const u8 {
    if (os == .windows) return std.fmt.bufPrint(buffer, "{s}-instance", .{dir}) catch null;
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ dir, instance_endpoint_file_name }) catch null;
}

/// `instanceEndpointIn(runtimeDirectory(...))`, or null.
pub fn instanceEndpoint(buffer: []u8, os: std.Target.Os.Tag, env: RuntimeEnv) ?[]const u8 {
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = runtimeDirectory(&dir_buffer, os, env) orelse return null;
    return instanceEndpointIn(buffer, os, dir);
}

pub const Token = protocol.Token;
pub const Method = protocol.Method;
pub const Params = protocol.Params;
pub const Reply = protocol.Reply;
pub const Result = protocol.Result;
pub const Opened = protocol.Opened;
pub const FaultCode = protocol.FaultCode;
pub const Request = queue.Request;
pub const Ticket = queue.Ticket;
pub const WorkspaceRef = queue.WorkspaceRef;
pub const Queue = queue.Queue;
pub const Server = server.Server;
pub const Options = server.Options;
pub const Handler = server.Handler;
pub const Disposition = server.Disposition;
pub const Scope = server.Scope;
pub const Waker = server.Waker;
pub const enabledIn = server.enabledIn;
pub const isEnabled = server.isEnabled;

test {
    std.testing.refAllDecls(@This());
    _ = protocol;
    _ = queue;
    _ = server;
}

// ---------------------------------------------------------------------------
// Integration tests: a real socket, real connection threads, a fake owner.
// ---------------------------------------------------------------------------

const testing = std.testing;
const platform = @import("platform");

test "the endpoint is on in Debug builds and in release builds only when enabled" {
    try testing.expect(enabledIn(.Debug, false));
    try testing.expect(!enabledIn(.ReleaseSafe, false));
    try testing.expect(!enabledIn(.ReleaseFast, false));
    try testing.expect(enabledIn(.ReleaseSafe, true));
}

test "the runtime directory follows XDG_RUNTIME_DIR, then the platform's private fallback" {
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings("/run/user/1000/conduit", runtimeDirectory(&buffer, .linux, .{ .xdg_runtime_dir = "/run/user/1000/", .uid = 1000 }).?);
    // A relative XDG_RUNTIME_DIR is invalid by specification and ignored.
    try testing.expectEqualStrings("/tmp/conduit-1000", runtimeDirectory(&buffer, .linux, .{ .xdg_runtime_dir = "run", .uid = 1000 }).?);
    try testing.expectEqualStrings("/tmp/conduit-501", runtimeDirectory(&buffer, .linux, .{ .tmpdir = "/var/tmp", .uid = 501 }).?);
    try testing.expectEqualStrings("/var/folders/x/T/conduit", runtimeDirectory(&buffer, .macos, .{ .tmpdir = "/var/folders/x/T/", .uid = 501 }).?);
    try testing.expectEqualStrings("/run/user/7/conduit/instance.sock", instanceEndpoint(&buffer, .linux, .{ .xdg_runtime_dir = "/run/user/7" }).?);
    try testing.expectEqualStrings("/run/user/7/conduit/r-0a0b0c0d.sock", runEndpoint(&buffer, .linux, "/run/user/7/conduit", .{ 0x0a, 0x0b, 0x0c, 0x0d }).?);
}

test "Windows endpoints are per-user pipes, isolated by XDG_RUNTIME_DIR" {
    var buffer: [256]u8 = undefined;
    const sid = "S-1-5-21-1004336348-1177238915-682003330-512";
    // No user SID, or one that is not a SID's text, names no pipe at all.
    try testing.expectEqual(@as(?[]const u8, null), runtimeDirectory(&buffer, .windows, .{ .tmpdir = "C:\\t" }));
    try testing.expectEqual(@as(?[]const u8, null), runtimeDirectory(&buffer, .windows, .{ .windows_user = "S-1\\..\\x" }));
    const dir = runtimeDirectory(&buffer, .windows, .{ .windows_user = sid }).?;
    try testing.expectEqualStrings("\\\\.\\pipe\\conduit-" ++ sid, dir);
    var endpoint_buffer: [256]u8 = undefined;
    try testing.expectEqualStrings("\\\\.\\pipe\\conduit-" ++ sid ++ "-instance", instanceEndpointIn(&endpoint_buffer, .windows, dir).?);
    try testing.expectEqualStrings("\\\\.\\pipe\\conduit-" ++ sid ++ "-r-0a0b0c0d", runEndpoint(&endpoint_buffer, .windows, dir, .{ 0x0a, 0x0b, 0x0c, 0x0d }).?);
    // An isolated run's XDG_RUNTIME_DIR gives it pipes of its own, the same
    // for the server and for every client that sees the same variable.
    var isolated_buffer: [256]u8 = undefined;
    const isolated = runtimeDirectory(&isolated_buffer, .windows, .{ .windows_user = sid, .xdg_runtime_dir = "C:\\runs\\a\\rt" }).?;
    try testing.expect(std.mem.startsWith(u8, isolated, "\\\\.\\pipe\\conduit-" ++ sid ++ "-x"));
    try testing.expectEqual(dir.len + 18, isolated.len);
    var other_buffer: [256]u8 = undefined;
    try testing.expect(!std.mem.eql(u8, isolated, runtimeDirectory(&other_buffer, .windows, .{ .windows_user = sid, .xdg_runtime_dir = "C:\\runs\\b\\rt" }).?));
    // Every name the pipe listener accepts: letters, digits, '.', '_' and '-'.
    for (isolated["\\\\.\\pipe\\".len..]) |c| try testing.expect(std.ascii.isAlphanumeric(c) or c == '-');
}

test "the instance endpoint takes only the instance token and reaches the owner with instance methods" {
    try skipWithoutTransport();
    const dir = try TestDir.create(0o700);
    defer dir.remove();
    var endpoint_buffer: [96]u8 = undefined;
    const endpoint = try dir.join(&endpoint_buffer, instance_endpoint_file_name);

    var wake: TestWake = .{};
    const instance = try Server.start(testing.allocator, testing.io, .{
        .endpoint = endpoint,
        .enabled = true,
        .waker = wake.waker(),
        .reply_timeout_ms = 2000,
    });
    defer instance.deinit();
    const token = try instance.issueToken(.{ .workspace = instance_workspace, .scratchpad_session = 0 }, @splat(0x42));
    var owner: FakeOwner = .{ .workspace = instance_workspace };

    var buffers: [4][512]u8 = undefined;
    const frames = [_][]const u8{
        try frameFor(&buffers[0], 1, "instance.open_directory", token.text(), ",\"params\":{\"path\":\"/srv/app\"}"),
        try frameFor(&buffers[1], 2, "instance.agent", token.text(), ",\"params\":{\"harness\":\"claude\"}"),
        // A workspace token is not registered here at all.
        try frameFor(&buffers[2], 3, "instance.open_ssh", "0123456789abcdef0123456789abcdef", ",\"params\":{\"destination\":\"h\"}"),
    };
    var script: ClientScript = .{ .endpoint = endpoint, .frames = &frames };
    defer script.deinit();
    const thread = try std.Thread.spawn(.{}, ClientScript.run, .{&script});
    serviceUntilDone(instance, &wake, &owner, &script) catch |err| {
        instance.queue.stop();
        thread.join();
        return err;
    };
    thread.join();
    // The fake owner answers only `ping`, `tab.open` and `agent.event`; the
    // point is that both instance methods reached it with the instance scope.
    try testing.expectEqualSlices(Method, &.{ .instance_open_directory, .instance_agent }, owner.methods[0..owner.method_count]);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32001,\"message\":\"Unauthorized\"}}",
        script.replies[2] orelse return error.TestMissingReply,
    );
}

/// A private directory under /tmp (worktree paths are too long for
/// sun_path), or on Windows a unique pipe-name prefix: pipes need no
/// directory (TASK-82).
const TestDir = struct {
    path_buffer: [prefix.len + 16]u8,

    const prefix = if (builtin.os.tag == .windows) windows_pipe_prefix ++ "conduit-ctl-" else "/tmp/conduit-ctl-";

    fn create(mode: u32) !TestDir {
        var dir: TestDir = undefined;
        var random: [8]u8 = undefined;
        testing.io.random(&random);
        _ = try std.fmt.bufPrint(&dir.path_buffer, prefix ++ "{x:0>16}", .{std.mem.readInt(u64, &random, .little)});
        if (comptime builtin.os.tag == .windows) return dir;
        try std.Io.Dir.cwd().createDir(testing.io, dir.path(), .fromMode(0o700));
        try std.Io.Dir.cwd().setFilePermissions(testing.io, dir.path(), .fromMode(@intCast(mode)), .{});
        return dir;
    }

    fn path(self: *const TestDir) []const u8 {
        return &self.path_buffer;
    }

    fn join(self: *const TestDir, buffer: []u8, name: []const u8) ![]const u8 {
        const separator: u8 = if (builtin.os.tag == .windows) '-' else '/';
        return std.fmt.bufPrint(buffer, "{s}{c}{s}", .{ self.path(), separator, name });
    }

    fn remove(self: *const TestDir) void {
        if (comptime builtin.os.tag == .windows) return;
        // Best-effort cleanup of a test directory; a leftover only wastes /tmp space.
        std.Io.Dir.cwd().deleteTree(testing.io, self.path()) catch {};
    }
};

/// The control server's socket tests run where it has a transport: POSIX
/// sockets on Linux and macOS, named pipes on Windows.
fn skipWithoutTransport() !void {
    switch (builtin.os.tag) {
        .linux, .macos, .windows => {},
        else => return error.SkipZigTest,
    }
}

const TestWake = struct {
    event: std.Io.Event = .unset,
    count: std.atomic.Value(u32) = .init(0),

    fn wake(context: ?*anyopaque) void {
        const self: *TestWake = @ptrCast(@alignCast(context.?));
        _ = self.count.fetchAdd(1, .acq_rel);
        self.event.set(testing.io);
    }

    fn waker(self: *TestWake) Waker {
        return .{ .context = self, .wakeFn = wake };
    }
};

/// Records what reached the owner and answers like part two will.
const FakeOwner = struct {
    workspace: WorkspaceRef,
    methods: [16]Method = undefined,
    method_count: usize = 0,
    sessions: [16]?u32 = undefined,
    argv1: [32]u8 = undefined,
    argv1_len: usize = 0,
    payload: [128]u8 = undefined,
    payload_len: usize = 0,
    deferred: ?Ticket = null,
    defer_next: bool = false,

    const vtable: Handler.VTable = .{ .handle = handle };

    fn handler(self: *FakeOwner) Handler {
        return .{ .context = self, .vtable = &vtable };
    }

    fn handle(context: *anyopaque, ticket: Ticket, request: *const Request) Disposition {
        const self: *FakeOwner = @ptrCast(@alignCast(context));
        if (request.workspace != self.workspace) return .{ .reply = .{ .fault = .not_found } };
        self.methods[self.method_count] = std.meta.activeTag(request.params);
        self.sessions[self.method_count] = request.session;
        self.method_count += 1;
        if (self.defer_next) {
            self.defer_next = false;
            self.deferred = ticket;
            return .deferred;
        }
        return .{ .reply = switch (request.params) {
            .ping => .{ .result = .pong },
            .tab_open => |open| blk: {
                const argv = open.spawn.command orelse break :blk .{ .fault = .invalid_params };
                self.argv1_len = @min(argv[1].len, self.argv1.len);
                @memcpy(self.argv1[0..self.argv1_len], argv[1][0..self.argv1_len]);
                break :blk .{ .result = .{ .opened = .{ .tab = 2, .session = 5 } } };
            },
            .agent_event => |event| blk: {
                self.payload_len = @min(event.payload_json.len, self.payload.len);
                @memcpy(self.payload[0..self.payload_len], event.payload_json[0..self.payload_len]);
                break :blk .{ .result = .ok };
            },
            else => .{ .fault = .unavailable },
        } };
    }
};

const ClientScript = struct {
    endpoint: []const u8,
    frames: []const []const u8,
    replies: [16]?[]u8 = @splat(null),
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *ClientScript) void {
        defer self.done.store(true, .release);
        var client = platform.DriverClient.connect(self.endpoint) catch return;
        defer client.deinit();
        for (self.frames, 0..) |frame, index| {
            self.replies[index] = client.exchange(testing.allocator, frame) catch return;
        }
    }

    fn deinit(self: *ClientScript) void {
        for (self.replies) |reply| if (reply) |bytes| testing.allocator.free(bytes);
    }
};

/// Run the owner loop until `script` finishes, bounded by a deadline rather
/// than a sleep: each wait ends at the next wake.
fn serviceUntilDone(control_server: *Server, wake: *TestWake, owner: *FakeOwner, script: *ClientScript) !void {
    const deadline: std.Io.Clock.Timestamp = .fromNow(testing.io, .{ .raw = .fromSeconds(20), .clock = .awake });
    while (!script.done.load(.acquire)) {
        if (deadline.durationFromNow(testing.io).raw.nanoseconds <= 0) return error.TestTimedOut;
        wake.event.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } }) catch {};
        wake.event.reset();
        _ = control_server.service(owner.handler(), 16);
    }
}

fn frameFor(buffer: []u8, id: u32, method: []const u8, token: []const u8, extra: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{{\"id\":{d},\"method\":\"{s}\",\"token\":\"{s}\"{s}}}", .{ id, method, token, extra });
}

test "a client in a workspace reaches the owner through a real socket and is scoped by its token" {
    try skipWithoutTransport();
    const dir = try TestDir.create(0o700);
    defer dir.remove();
    var endpoint_buffer: [96]u8 = undefined;
    const endpoint = try dir.join(&endpoint_buffer, endpoint_file_name);

    var wake: TestWake = .{};
    const control_server = try Server.start(testing.allocator, testing.io, .{
        .endpoint = endpoint,
        .enabled = true,
        .waker = wake.waker(),
        .reply_timeout_ms = 200,
    });
    defer control_server.deinit();

    // The socket is 0600 inside a 0700 directory. (A Windows pipe's
    // protection is its descriptor, which platform's pipe test covers.)
    if (comptime builtin.os.tag != .windows) {
        const socket_stat = try std.Io.Dir.cwd().statFile(testing.io, endpoint, .{ .follow_symlinks = false });
        try testing.expectEqual(std.Io.File.Kind.unix_domain_socket, socket_stat.kind);
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), socket_stat.permissions.toMode() & 0o777);
        const dir_stat = try std.Io.Dir.cwd().statFile(testing.io, dir.path(), .{});
        try testing.expectEqual(@as(std.posix.mode_t, 0o700), dir_stat.permissions.toMode() & 0o777);
    }

    const scratchpad: u32 = 1;
    const token = try control_server.issueToken(.{ .workspace = 7, .scratchpad_session = scratchpad }, @splat(0x5a));
    const other = try control_server.issueToken(.{ .workspace = 8, .scratchpad_session = scratchpad }, @splat(0xa5));
    var owner: FakeOwner = .{ .workspace = 7 };

    var buffers: [10][512]u8 = undefined;
    const frames = [_][]const u8{
        try frameFor(&buffers[0], 1, "ping", token.text(), ""),
        try frameFor(&buffers[1], 2, "tab.open", token.text(), ",\"session\":3,\"params\":{\"command\":[\"sh\",\"-c; rm -rf ~\"]}"),
        try frameFor(&buffers[2], 3, "agent.event", token.text(), ",\"params\":{\"agent\":\"" ++ ("ab" ** 16) ++ "\",\"payload\":{\"conduit\":{\"v\":1},\"payload\":{}}}"),
        try frameFor(&buffers[3], 4, "ping", "ffffffffffffffffffffffffffffffff", ""),
        try frameFor(&buffers[4], 5, "pane.split", token.text(), ",\"session\":1,\"params\":{\"direction\":\"right\"}"),
        try frameFor(&buffers[5], 6, "scratchpad.toggle", token.text(), ""),
        try frameFor(&buffers[6], 7, "ping", other.text(), ""),
        "{\"id\":8,\"method\":\"ping\"}",
        "garbage",
        try frameFor(&buffers[7], 9, "view.backlog", token.text(), ""),
    };
    var script: ClientScript = .{ .endpoint = endpoint, .frames = &frames };
    defer script.deinit();
    const thread = try std.Thread.spawn(.{}, ClientScript.run, .{&script});
    serviceUntilDone(control_server, &wake, &owner, &script) catch |err| {
        control_server.queue.stop();
        thread.join();
        return err;
    };
    thread.join();

    const expected = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"pong\":true}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tab\":2,\"session\":5}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":-32001,\"message\":\"Unauthorized\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"error\":{\"code\":-32002,\"message\":\"ScratchpadNotAddressable\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"error\":{\"code\":-32601,\"message\":\"MethodNotFound\"}}",
        // Workspace 8's token reaches the owner as workspace 8, not 7.
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32004,\"message\":\"NotFound\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"error\":{\"code\":-32001,\"message\":\"Unauthorized\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"ParseError\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"error\":{\"code\":-32000,\"message\":\"Unavailable\"}}",
    };
    for (expected, 0..) |line, index| {
        try testing.expectEqualStrings(line, script.replies[index] orelse return error.TestMissingReply);
    }

    // Only the accepted requests reached the owner, with their argv intact.
    try testing.expectEqual(@as(usize, 4), owner.method_count);
    try testing.expectEqualSlices(Method, &.{ .ping, .tab_open, .agent_event, .view_backlog }, owner.methods[0..4]);
    try testing.expectEqual(@as(?u32, 3), owner.sessions[1]);
    try testing.expectEqualStrings("-c; rm -rf ~", owner.argv1[0..owner.argv1_len]);
    try testing.expectEqualStrings("{\"conduit\":{\"v\":1},\"payload\":{}}", owner.payload[0..owner.payload_len]);
    try testing.expect(wake.count.load(.acquire) >= 4);
}

test "a revoked token expires, a slow owner times out, and many clients connect at once" {
    try skipWithoutTransport();
    const dir = try TestDir.create(0o700);
    defer dir.remove();
    var endpoint_buffer: [96]u8 = undefined;
    const endpoint = try dir.join(&endpoint_buffer, endpoint_file_name);

    var wake: TestWake = .{};
    const control_server = try Server.start(testing.allocator, testing.io, .{
        .endpoint = endpoint,
        .enabled = true,
        .waker = wake.waker(),
        .reply_timeout_ms = 100,
    });
    defer control_server.deinit();
    const token = try control_server.issueToken(.{ .workspace = 1, .scratchpad_session = 1 }, @splat(1));

    // An idle client holds its own connection; others are still served.
    var idle = try platform.DriverClient.connect(endpoint);
    defer idle.deinit();

    var owner: FakeOwner = .{ .workspace = 1, .defer_next = true };
    var buffers: [2][256]u8 = undefined;
    const slow = [_][]const u8{
        try frameFor(&buffers[0], 1, "ping", token.text(), ""),
        try frameFor(&buffers[1], 2, "ping", token.text(), ""),
    };
    var script: ClientScript = .{ .endpoint = endpoint, .frames = &slow };
    defer script.deinit();
    const thread = try std.Thread.spawn(.{}, ClientScript.run, .{&script});
    serviceUntilDone(control_server, &wake, &owner, &script) catch |err| {
        control_server.queue.stop();
        thread.join();
        return err;
    };
    thread.join();
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32008,\"message\":\"TimedOut\"}}",
        script.replies[0].?,
    );
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"pong\":true}}", script.replies[1].?);
    // The late answer to the abandoned request is released quietly.
    control_server.complete(owner.deferred.?, .{ .result = .pong });

    // Rotation and revocation: the old token stops working at once.
    const rotated = try control_server.issueToken(.{ .workspace = 1, .scratchpad_session = 1 }, @splat(2));
    try testing.expect(control_server.resolve(token) == null);
    try testing.expectEqual(@as(WorkspaceRef, 1), control_server.resolve(rotated).?.workspace);
    control_server.revokeWorkspace(1);
    try testing.expect(control_server.resolve(rotated) == null);

    var frame_buffer: [256]u8 = undefined;
    const reply = try idle.exchange(testing.allocator, try frameFor(&frame_buffer, 3, "ping", rotated.text(), ""));
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32001,\"message\":\"Unauthorized\"}}", reply);
}

test "a request queued under a token revoked before service never reaches the owner" {
    try skipWithoutTransport();
    const dir = try TestDir.create(0o700);
    defer dir.remove();
    var endpoint_buffer: [96]u8 = undefined;
    const endpoint = try dir.join(&endpoint_buffer, endpoint_file_name);

    var wake: TestWake = .{};
    const control_server = try Server.start(testing.allocator, testing.io, .{
        .endpoint = endpoint,
        .enabled = true,
        .waker = wake.waker(),
        .reply_timeout_ms = 5000,
    });
    defer control_server.deinit();
    const token = try control_server.issueToken(.{ .workspace = 3, .scratchpad_session = 1 }, @splat(3));

    var buffer: [256]u8 = undefined;
    const frames = [_][]const u8{try frameFor(&buffer, 1, "tab.open", token.text(), "")};
    var script: ClientScript = .{ .endpoint = endpoint, .frames = &frames };
    defer script.deinit();
    const thread = try std.Thread.spawn(.{}, ClientScript.run, .{&script});
    var joined = false;
    defer if (!joined) {
        control_server.queue.stop();
        thread.join();
    };
    // Wait for the request to be queued, then close the workspace.
    try wake.event.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    control_server.revokeWorkspace(3);
    var owner: FakeOwner = .{ .workspace = 3 };
    try testing.expectEqual(@as(usize, 1), control_server.service(owner.handler(), 16));
    try testing.expectEqual(@as(usize, 0), owner.method_count);
    thread.join();
    joined = true;
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32001,\"message\":\"Unauthorized\"}}",
        script.replies[0].?,
    );
}

test "a separate process without the token is refused" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const dir = try TestDir.create(0o700);
    defer dir.remove();
    var endpoint_buffer: [96]u8 = undefined;
    const endpoint = try dir.join(&endpoint_buffer, endpoint_file_name);

    var wake: TestWake = .{};
    const control_server = try Server.start(testing.allocator, testing.io, .{
        .endpoint = endpoint,
        .enabled = true,
        .waker = wake.waker(),
    });
    defer control_server.deinit();
    _ = try control_server.issueToken(.{ .workspace = 1, .scratchpad_session = 1 }, @splat(9));

    // python3 is a separate process connecting the way any local program
    // would; where it is missing, the same frames go through an in-process
    // client so the refusal is still asserted.
    const script =
        \\import socket, sys
        \\s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        \\s.connect(sys.argv[1])
        \\f = s.makefile("rwb")
        \\for line in (b'{"id":1,"method":"tab.open"}', b'{"id":2,"method":"tab.open","token":"00000000000000000000000000000000"}'):
        \\    f.write(line + b"\n"); f.flush()
        \\    sys.stdout.write(f.readline().decode())
    ;
    const expected =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32001,\"message\":\"Unauthorized\"}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32001,\"message\":\"Unauthorized\"}}\n";
    if (std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ "python3", "-c", script, endpoint },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(20), .clock = .awake } },
    })) |result| {
        defer testing.allocator.free(result.stdout);
        defer testing.allocator.free(result.stderr);
        try testing.expectEqualStrings(expected, result.stdout);
    } else |err| switch (err) {
        error.FileNotFound => {
            var client = try platform.DriverClient.connect(endpoint);
            defer client.deinit();
            const reply = try client.exchange(testing.allocator, "{\"id\":1,\"method\":\"tab.open\"}");
            defer testing.allocator.free(reply);
            try testing.expectEqualStrings(expected[0 .. expected.len / 2 - 1], reply);
        },
        else => return err,
    }
    try testing.expectEqual(@as(u32, 0), wake.count.load(.acquire));
}

test "the endpoint refuses a shared parent directory and a disabled setting in release builds" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const dir = try TestDir.create(0o755);
    defer dir.remove();
    var endpoint_buffer: [96]u8 = undefined;
    const endpoint = try dir.join(&endpoint_buffer, endpoint_file_name);
    var wake: TestWake = .{};
    try testing.expectError(error.ParentNotPrivate, Server.start(testing.allocator, testing.io, .{
        .endpoint = endpoint,
        .enabled = true,
        .waker = wake.waker(),
    }));
    if (builtin.mode != .Debug) {
        try testing.expectError(error.Disabled, Server.start(testing.allocator, testing.io, .{
            .endpoint = endpoint,
            .waker = wake.waker(),
        }));
    }
}

test "an oversized frame's tail is still accepted after the refusal" {
    // Regression: the server used to close right after the refusal, so a
    // client still sending the rest of the line got EPIPE instead of the reply.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const dir = try TestDir.create(0o700);
    defer dir.remove();
    var endpoint_buffer: [96]u8 = undefined;
    const endpoint = try dir.join(&endpoint_buffer, endpoint_file_name);
    var wake: TestWake = .{};
    const control_server = try Server.start(testing.allocator, testing.io, .{
        .endpoint = endpoint,
        .enabled = true,
        .waker = wake.waker(),
    });
    defer control_server.deinit();

    const head = try testing.allocator.alloc(u8, protocol.max_frame_bytes + 1);
    defer testing.allocator.free(head);
    @memset(head, ' ');
    var client = try platform.DriverClient.connect(endpoint);
    defer client.deinit();
    const io = testing.io;
    var write_buffer: [4096]u8 = undefined;
    var writer = client.stream.writer(io, &write_buffer);
    try writer.interface.writeAll(head);
    try writer.interface.flush();

    // The refusal arrives while the line is still unfinished.
    var read_buffer: [1024]u8 = undefined;
    var reader = client.stream.reader(io, &read_buffer);
    const framed = try reader.interface.takeDelimiterInclusive('\n');
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"InvalidRequest\"}}\n", framed);

    // The tail of that line, sent after the refusal, is drained rather than
    // refused with a broken pipe; the connection ends once the client hangs up.
    try writer.interface.writeAll("the rest of the oversized line\n");
    try writer.interface.flush();
    try client.stream.shutdown(io, .send);
    try testing.expectError(error.EndOfStream, reader.interface.takeDelimiterInclusive('\n'));
}

test "an oversized frame is refused and its connection closed" {
    try skipWithoutTransport();
    const dir = try TestDir.create(0o700);
    defer dir.remove();
    var endpoint_buffer: [96]u8 = undefined;
    const endpoint = try dir.join(&endpoint_buffer, endpoint_file_name);
    var wake: TestWake = .{};
    const control_server = try Server.start(testing.allocator, testing.io, .{
        .endpoint = endpoint,
        .enabled = true,
        .waker = wake.waker(),
    });
    defer control_server.deinit();

    const frame = try testing.allocator.alloc(u8, protocol.max_frame_bytes + 1);
    defer testing.allocator.free(frame);
    @memset(frame, ' ');
    var client = try platform.DriverClient.connect(endpoint);
    defer client.deinit();
    const reply = try client.exchange(testing.allocator, frame);
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"InvalidRequest\"}}", reply);
}
