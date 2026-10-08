//! The Codex CLI adapter (TASK-54, decision-7, doc-3's Codex column).
//!
//! Codex's structured side channel is its app-server: JSON-RPC 2.0 without
//! the `"jsonrpc"` member, one JSON value per message. A TUI Conduit launches
//! runs its thread on the shared app-server daemon by default, and this adapter
//! connects to the same daemon as a second client over its control socket
//! (`$CODEX_HOME/app-server-control/app-server-control.sock`, WebSocket over
//! AF_UNIX). A headless agent is `codex app-server --listen stdio://`, a child
//! the owner spawns and whose pipes this adapter speaks over, one JSON value
//! per line. The owner picks the path through `Options.mode` and the
//! `Transport` it constructs (`WebSocketTransport` over `FdStream.connectUnix`
//! for `.daemon`, `LineTransport` over the child's pipes for `.stdio`).
//! Sessions started with `--no-daemon` have no app-server to join; they keep
//! the PTY baseline plus whatever the rollout transcript gives
//! (`RolloutReader`), and hook-level fidelity is TASK-60's.
//!
//! Protocol names, verified against `codex app-server generate-json-schema`
//! for codex-cli 0.160.1 (the list is checked in as
//! `test/fixtures/agent/codex/protocol-0.160.1.txt`, and a test proves every
//! name used here is in it):
//!   client requests   `initialize` {clientInfo{name, version},
//!                     capabilities{optOutNotificationMethods}}, `thread/start`
//!                     {cwd}, `thread/resume` {threadId, excludeTurns},
//!                     `thread/loaded/list` → {data: [threadId]}, `thread/list`
//!                     {cwd, limit, sortKey, sortDirection} → {data: [Thread]},
//!                     `turn/start` {threadId, input: [{type: text, text}]},
//!                     `turn/steer` {threadId, input, expectedTurnId},
//!                     `turn/interrupt` {threadId, turnId}
//!   client notification `initialized`
//!   notifications     `thread/status/changed` {threadId, status{type: idle |
//!                     active{activeFlags: waitingOnApproval |
//!                     waitingOnUserInput} | systemError | notLoaded}},
//!                     `turn/started` / `turn/completed` {threadId, turn{id,
//!                     status: completed | interrupted | failed | inProgress,
//!                     error{message}}}, `item/started` / `item/completed`
//!                     {threadId, item{type, ...}}, `serverRequest/resolved`
//!                     {threadId, requestId}, `error` {threadId, error{message},
//!                     willRetry}, `thread/started`
//!   server requests   `item/commandExecution/requestApproval` {threadId,
//!                     command, reason, availableDecisions} → {decision},
//!                     `item/fileChange/requestApproval` {threadId, reason,
//!                     grantRoot} → {decision}, `item/permissions/requestApproval`
//!                     {threadId, permissions, reason} → {permissions, scope:
//!                     turn | session}, the legacy `execCommandApproval` /
//!                     `applyPatchApproval` {conversationId, ...} → {decision:
//!                     ReviewDecision}, and `item/tool/requestUserInput` /
//!                     `mcpServer/elicitation/request`, which only mark the agent
//!                     as waiting for input (the human answers in the TUI).
//!   decisions         command: `accept`, `acceptForSession`,
//!                     {acceptWithExecpolicyAmendment}, {applyNetworkPolicyAmendment},
//!                     `decline`, `cancel`; file change: `accept`,
//!                     `acceptForSession`, `decline`, `cancel`; legacy:
//!                     `approved`, `approved_for_session`, `denied`, `abort`, ...
//! The approval round trip in `app-server-approval-0.160.1.jsonl` was recorded
//! from the real 0.160.1 binary against a local mock model provider (no OpenAI
//! endpoint was contacted).
//!
//! Version gating (decision-7, rule 4): the app-server is labelled
//! experimental and already differs between 0.160.1 and 0.161.0. The adapter
//! accepts `tested_min` ≤ version < `tested_end` — the version comes from
//! `detect` (`codex --version` run through the workspace's ExecutionContext)
//! or `Options.cli_version`, and is
//! confirmed from the `initialize` response's `userAgent` — and otherwise
//! refuses with `error.Protocol` and reports heuristic-only capabilities, so
//! the agent degrades to the PTY baseline instead of guessing.
//!
//! Hand-started detection (best effort): with no harness session id,
//! `attach` in `.daemon` mode asks the daemon for its loaded threads
//! (`thread/loaded/list`) and the most recently updated thread whose cwd is
//! `Options.cwd` (`thread/list`), and resumes that one. When the correlation
//! token reaches Conduit through Codex hooks (TASK-60), the owner passes the
//! hook's session id as `AttachRequest.harness_session_id` and the guess is
//! skipped.
//!
//! Safety: everything received is untrusted harness data. Nothing here
//! executes or answers anything because of it; `respondPermission` sends only
//! a decision the request itself offered, from the caller's user gesture.
//! Logging is `.debug` and structural only (methods, sizes, counts), never
//! message, command or prompt text.
//!
//! Threads and IO: every method except `harness` and `capabilities` may block
//! on the transport and runs on an IO worker, one caller at a time, per the
//! adapter contract. No method is called on the owner thread.
//!
//! Memory: `init` copies `Options.cwd`; the transport and the client name and
//! version are borrowed for the adapter's lifetime. The event backlog, the
//! parse arena and pending approvals are owned and released by `deinit`
//! (which `Adapter.destroy` calls). Every received message is bounded by the
//! transport's `max_message_bytes`; oversized messages are skipped, not
//! buffered.

const std = @import("std");
const builtin = @import("builtin");
const adapter_mod = @import("adapter.zig");
const event = @import("event.zig");
const state_model = @import("state.zig");
const Harness = @import("harness.zig").Harness;

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const State = state_model.State;
const log = std.log.scoped(.agent_codex);

/// The default bound on one received message. Codex's largest routine
/// messages are completed items carrying command output; anything larger is
/// skipped rather than buffered.
pub const default_max_message_bytes: usize = 8 * 1024 * 1024;

// Versions -------------------------------------------------------------------

/// A `major.minor.patch` version, as Codex prints it.
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn order(a: Version, b: Version) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        return std.math.order(a.patch, b.patch);
    }

    /// The first `N.N.N` in `text` (`codex --version` prints
    /// `codex-cli 0.160.1`; the app-server's `userAgent` is
    /// `<client>/0.160.1 (...)`), or null.
    pub fn find(text: []const u8) ?Version {
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (!std.ascii.isDigit(text[i])) continue;
            if (i > 0 and (std.ascii.isDigit(text[i - 1]) or text[i - 1] == '.')) continue;
            if (parseAt(text[i..])) |version| return version;
        }
        return null;
    }

    fn parseAt(text: []const u8) ?Version {
        var parts: [3]u32 = undefined;
        var rest = text;
        for (&parts, 0..) |*part, n| {
            var end: usize = 0;
            while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
            if (end == 0) return null;
            part.* = std.fmt.parseInt(u32, rest[0..end], 10) catch return null;
            rest = rest[end..];
            if (n < 2) {
                if (rest.len == 0 or rest[0] != '.') return null;
                rest = rest[1..];
            }
        }
        return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
    }
};

/// The oldest app-server this adapter was verified against (0.160.1's schema
/// and a recorded round trip).
pub const tested_min: Version = .{ .major = 0, .minor = 160, .patch = 0 };
/// The first version not accepted. 0.161.x is admitted because the user's
/// daemon runs 0.161.0 and every name used here is in the stable surface, but
/// its shapes were not re-recorded; anything newer is refused until verified.
pub const tested_end: Version = .{ .major = 0, .minor = 162, .patch = 0 };

/// Bounds on the `codex --version` probe.
const detect_max_output: usize = 4096;
const detect_timeout_ms: u32 = 5000;
/// The longest first line of `codex --version` output that is parsed.
const max_version_line_bytes: usize = 256;

/// The version in `codex --version` output (`codex-cli 0.160.1`): the last
/// word of the first line, a bare `N.N.N` with an optional `v`/`name/`
/// prefix and pre-release suffix. Anything else is null.
pub fn parseVersionOutput(stdout: []const u8) ?Version {
    var lines = std.mem.tokenizeAny(u8, stdout, "\r\n");
    const line = std.mem.trim(u8, lines.next() orelse return null, " \t");
    if (line.len > max_version_line_bytes) return null;
    var words = std.mem.tokenizeAny(u8, line, " \t");
    var last: ?[]const u8 = null;
    while (words.next()) |word| last = word;
    var word = last orelse return null;
    if (std.mem.lastIndexOfScalar(u8, word, '/')) |slash| word = word[slash + 1 ..];
    if (word.len > 1 and word[0] == 'v') word = word[1..];
    if (word.len == 0 or !std.ascii.isDigit(word[0])) return null;
    for (word) |c| switch (c) {
        '0'...'9', 'a'...'z', 'A'...'Z', '.', '-', '+' => {},
        else => return null,
    };
    return Version.find(word);
}

/// Whether the adapter speaks to this app-server version.
pub fn versionSupported(version: Version) bool {
    return version.order(tested_min) != .lt and version.order(tested_end) == .lt;
}

// Byte streams ---------------------------------------------------------------

/// What one read produced.
pub const ReadResult = union(enum) {
    bytes: usize,
    /// Nothing arrived within the timeout.
    timeout,
    /// The peer closed the stream.
    eof,
};

/// A bidirectional byte stream under a transport: a socket, or a child's
/// stdout/stdin pair. Errors collapse to `Disconnected`; the adapter cannot do
/// anything more specific with them.
pub const ByteStream = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{Disconnected};

    pub const VTable = struct {
        /// Read into `buffer`, waiting at most `timeout_ms` (0: do not wait).
        read: *const fn (*anyopaque, buffer: []u8, timeout_ms: u32) Error!ReadResult,
        /// Write all of `bytes`.
        write: *const fn (*anyopaque, bytes: []const u8) Error!void,
        close: *const fn (*anyopaque) void,
    };

    pub fn read(self: ByteStream, buffer: []u8, timeout_ms: u32) Error!ReadResult {
        return self.vtable.read(self.ptr, buffer, timeout_ms);
    }

    pub fn write(self: ByteStream, bytes: []const u8) Error!void {
        return self.vtable.write(self.ptr, bytes);
    }

    pub fn close(self: ByteStream) void {
        self.vtable.close(self.ptr);
    }
};

const posix_streams = builtin.os.tag != .windows;

/// A POSIX file-descriptor stream: a connected Unix socket (one fd both
/// ways) or a child's stdout and stdin pipes.
///
/// Socket writes use `MSG_NOSIGNAL` (or `SO_NOSIGPIPE`), so a closed peer is
/// `Disconnected` rather than a signal. Pipe writes check for a closed reader
/// first, but a reader that closes between that check and the write raises
/// SIGPIPE; an owner that cannot ignore SIGPIPE process-wide should give the
/// child a socketpair instead of pipes. Windows named pipes are not
/// implemented (TASK-54 covers Linux; the daemon socket is POSIX-only today).
pub const FdStream = struct {
    read_fd: std.posix.fd_t,
    write_fd: std.posix.fd_t,
    is_socket: bool,
    /// Whether `close` closes the descriptors.
    owns: bool,
    /// How long a write may wait for a full pipe or socket buffer to drain.
    write_timeout_ms: u32 = 10_000,

    pub const ConnectError = error{ Unsupported, PathTooLong, ConnectFailed };

    /// Borrow or adopt a pair of pipe descriptors.
    pub fn fromPipes(read_fd: std.posix.fd_t, write_fd: std.posix.fd_t, owns: bool) FdStream {
        return .{ .read_fd = read_fd, .write_fd = write_fd, .is_socket = false, .owns = owns };
    }

    /// Connect to a Unix stream socket at `path`. The result owns the socket.
    pub fn connectUnix(path: []const u8) ConnectError!FdStream {
        if (comptime !posix_streams) return error.Unsupported;
        const posix = std.posix;
        var address: posix.sockaddr.un = std.mem.zeroes(posix.sockaddr.un);
        if (path.len == 0 or path.len >= address.path.len) return error.PathTooLong;
        address.family = posix.AF.UNIX;
        @memcpy(address.path[0..path.len], path);
        const address_len: posix.socklen_t = @intCast(@offsetOf(posix.sockaddr.un, "path") + path.len + 1);
        if (@hasField(posix.sockaddr.un, "len")) address.len = @intCast(address_len);

        const flags: u32 = posix.SOCK.STREAM | if (@hasDecl(posix.SOCK, "CLOEXEC")) posix.SOCK.CLOEXEC else 0;
        const socket_result = posix.system.socket(posix.AF.UNIX, flags, 0);
        if (posix.errno(socket_result) != .SUCCESS) return error.ConnectFailed;
        const fd: posix.fd_t = @intCast(socket_result);
        errdefer _ = posix.system.close(fd);
        if (@hasDecl(posix.SO, "NOSIGPIPE")) {
            const one: c_int = 1;
            posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, std.mem.asBytes(&one)) catch
                return error.ConnectFailed;
        }
        while (true) {
            const result = posix.system.connect(fd, @ptrCast(&address), address_len);
            switch (posix.errno(result)) {
                .SUCCESS => break,
                .INTR => continue,
                else => return error.ConnectFailed,
            }
        }
        return .{ .read_fd = fd, .write_fd = fd, .is_socket = true, .owns = true };
    }

    const vtable: ByteStream.VTable = .{ .read = readFn, .write = writeFn, .close = closeFn };

    /// Lend this stream; `self` must outlive the returned value.
    pub fn stream(self: *FdStream) ByteStream {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn cast(ptr: *anyopaque) *FdStream {
        return @ptrCast(@alignCast(ptr));
    }

    fn waitFor(fd: std.posix.fd_t, events: i16, timeout_ms: u32) ByteStream.Error!?i16 {
        if (comptime !posix_streams) return error.Disconnected;
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        const timeout: i32 = @intCast(@min(timeout_ms, std.math.maxInt(i32)));
        const ready = std.posix.poll(&fds, timeout) catch return error.Disconnected;
        if (ready == 0) return null;
        return fds[0].revents;
    }

    fn readFn(ptr: *anyopaque, buffer: []u8, timeout_ms: u32) ByteStream.Error!ReadResult {
        if (comptime !posix_streams) return error.Disconnected;
        const self = cast(ptr);
        if (buffer.len == 0) return .{ .bytes = 0 };
        if (try waitFor(self.read_fd, std.posix.POLL.IN, timeout_ms) == null) return .timeout;
        const n = std.posix.read(self.read_fd, buffer) catch |err| switch (err) {
            error.WouldBlock => return .timeout,
            else => return error.Disconnected,
        };
        if (n == 0) return .eof;
        return .{ .bytes = n };
    }

    fn writeFn(ptr: *anyopaque, bytes: []const u8) ByteStream.Error!void {
        if (comptime !posix_streams) return error.Disconnected;
        const self = cast(ptr);
        const posix = std.posix;
        if (!self.is_socket) {
            // A pipe whose reader is gone reports POLLERR; refuse before the
            // write would raise SIGPIPE.
            if (try waitFor(self.write_fd, posix.POLL.OUT, 0)) |revents| {
                if (revents & (posix.POLL.ERR | posix.POLL.HUP) != 0) return error.Disconnected;
            }
        }
        const nosignal: u32 = if (@hasDecl(posix.MSG, "NOSIGNAL")) posix.MSG.NOSIGNAL else 0;
        var rest = bytes;
        while (rest.len != 0) {
            const rc = if (self.is_socket)
                posix.system.sendto(self.write_fd, rest.ptr, rest.len, nosignal, null, 0)
            else
                posix.system.write(self.write_fd, rest.ptr, rest.len);
            switch (posix.errno(rc)) {
                .SUCCESS => rest = rest[@intCast(rc)..],
                .INTR => continue,
                .AGAIN => {
                    const revents = try waitFor(self.write_fd, posix.POLL.OUT, self.write_timeout_ms) orelse
                        return error.Disconnected;
                    if (revents & (posix.POLL.ERR | posix.POLL.HUP) != 0) return error.Disconnected;
                },
                else => return error.Disconnected,
            }
        }
    }

    fn closeFn(ptr: *anyopaque) void {
        if (comptime !posix_streams) return;
        const self = cast(ptr);
        if (!self.owns) return;
        _ = std.posix.system.close(self.read_fd);
        if (self.write_fd != self.read_fd) _ = std.posix.system.close(self.write_fd);
        self.owns = false;
    }
};

// Transports -----------------------------------------------------------------

/// One JSON-RPC message channel. `receive` returns one complete message, or
/// null when none arrived within the timeout; the slice stays valid until the
/// next `receive` or `close`.
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = Allocator.Error || error{ Disconnected, Protocol };

    pub const VTable = struct {
        connect: *const fn (*anyopaque) Error!void,
        send: *const fn (*anyopaque, message: []const u8) Error!void,
        receive: *const fn (*anyopaque, timeout_ms: u32) Error!?[]const u8,
        close: *const fn (*anyopaque) void,
    };

    pub fn connect(self: Transport) Error!void {
        return self.vtable.connect(self.ptr);
    }

    pub fn send(self: Transport, message: []const u8) Error!void {
        return self.vtable.send(self.ptr, message);
    }

    pub fn receive(self: Transport, timeout_ms: u32) Error!?[]const u8 {
        return self.vtable.receive(self.ptr, timeout_ms);
    }

    pub fn close(self: Transport) void {
        self.vtable.close(self.ptr);
    }
};

const read_chunk_bytes: usize = 16 * 1024;

/// Newline-delimited JSON over a byte stream: `codex app-server --listen
/// stdio://`. A line longer than `max_message_bytes` is discarded through its
/// newline and counted in `skipped`.
///
/// Memory: the read buffer grows on demand to at most `max_message_bytes`
/// plus one read chunk and is freed by `deinit`. The stream is borrowed;
/// `close` closes it.
pub const LineTransport = struct {
    allocator: Allocator,
    stream: ByteStream,
    max_message_bytes: usize,
    buffer: std.ArrayList(u8) = .empty,
    /// Bytes at the front of `buffer` already handed out.
    consumed: usize = 0,
    /// Bytes at the front of `buffer` already searched for a newline.
    scanned: usize = 0,
    discarding: bool = false,
    skipped: u64 = 0,
    closed: bool = false,

    pub fn init(allocator: Allocator, stream: ByteStream, max_message_bytes: usize) LineTransport {
        return .{ .allocator = allocator, .stream = stream, .max_message_bytes = max_message_bytes };
    }

    pub fn deinit(self: *LineTransport) void {
        self.buffer.deinit(self.allocator);
        self.* = undefined;
    }

    const vtable: Transport.VTable = .{ .connect = connect, .send = send, .receive = receive, .close = close };

    /// Lend this transport; `self` must outlive the returned value.
    pub fn transport(self: *LineTransport) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn cast(ptr: *anyopaque) *LineTransport {
        return @ptrCast(@alignCast(ptr));
    }

    fn connect(_: *anyopaque) Transport.Error!void {}

    fn send(ptr: *anyopaque, message: []const u8) Transport.Error!void {
        const self = cast(ptr);
        if (self.closed) return error.Disconnected;
        // A raw newline would split the message; JSON never needs one.
        if (std.mem.indexOfScalar(u8, message, '\n') != null) return error.Protocol;
        try self.stream.write(message);
        try self.stream.write("\n");
    }

    fn dropFront(self: *LineTransport, n: usize) void {
        const items = self.buffer.items;
        std.mem.copyForwards(u8, items[0 .. items.len - n], items[n..]);
        self.buffer.items.len -= n;
        self.scanned -|= n;
    }

    fn nextLine(self: *LineTransport) ?[]const u8 {
        while (true) {
            const items = self.buffer.items;
            const newline = std.mem.indexOfScalarPos(u8, items, self.scanned, '\n') orelse {
                self.scanned = items.len;
                if (self.discarding) {
                    self.buffer.clearRetainingCapacity();
                    self.scanned = 0;
                } else if (items.len > self.max_message_bytes) {
                    self.discarding = true;
                    self.skipped += 1;
                    self.buffer.clearRetainingCapacity();
                    self.scanned = 0;
                }
                return null;
            };
            if (self.discarding) {
                self.discarding = false;
                self.dropFront(newline + 1);
                continue;
            }
            var line = items[0..newline];
            if (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (line.len == 0) {
                self.dropFront(newline + 1);
                continue;
            }
            if (line.len > self.max_message_bytes) {
                self.skipped += 1;
                self.dropFront(newline + 1);
                continue;
            }
            self.consumed = newline + 1;
            return line;
        }
    }

    fn receive(ptr: *anyopaque, timeout_ms: u32) Transport.Error!?[]const u8 {
        const self = cast(ptr);
        if (self.closed) return error.Disconnected;
        if (self.consumed != 0) {
            self.dropFront(self.consumed);
            self.consumed = 0;
        }
        var wait = timeout_ms;
        while (true) {
            if (self.nextLine()) |line| return line;
            try self.buffer.ensureUnusedCapacity(self.allocator, read_chunk_bytes);
            const spare = self.buffer.unusedCapacitySlice()[0..read_chunk_bytes];
            switch (try self.stream.read(spare, wait)) {
                .timeout => return null,
                .eof => return error.Disconnected,
                .bytes => |n| self.buffer.items.len += n,
            }
            wait = 0;
        }
    }

    fn close(ptr: *anyopaque) void {
        const self = cast(ptr);
        if (self.closed) return;
        self.closed = true;
        self.stream.close();
    }
};

/// A minimal RFC 6455 WebSocket client over a byte stream, for the Codex
/// daemon's control socket: the opening handshake (with
/// `Sec-WebSocket-Accept` verified), masked text frames out, unmasked text and
/// continuation frames in, ping answered with pong, close echoed. Binary
/// frames carry nothing Codex sends and are skipped. A message larger than
/// `max_message_bytes` is skipped as its bytes arrive and counted in
/// `skipped`; it is never buffered whole.
///
/// Memory: buffers grow on demand up to the message bound and are freed by
/// `deinit`. Masking keys and the handshake nonce come from a ChaCha CSPRNG
/// seeded by the caller, so this module draws no OS entropy.
pub const WebSocketTransport = struct {
    allocator: Allocator,
    stream: ByteStream,
    max_message_bytes: usize,
    host: []const u8,
    path: []const u8,
    handshake_timeout_ms: u32,
    rng: std.Random.DefaultCsprng,
    input: std.ArrayList(u8) = .empty,
    /// Parsed bytes at the front of `input`.
    consumed: usize = 0,
    message: std.ArrayList(u8) = .empty,
    output: std.ArrayList(u8) = .empty,
    in_message: bool = false,
    /// The rest of an oversized or binary message is being dropped.
    discarding_message: bool = false,
    discard_remaining: u64 = 0,
    discard_ends_message: bool = false,
    connected: bool = false,
    closed: bool = false,
    skipped: u64 = 0,

    pub const Config = struct {
        /// Seeds the masking-key and nonce generator; must be unpredictable.
        seed: [std.Random.DefaultCsprng.secret_seed_length]u8,
        max_message_bytes: usize = default_max_message_bytes,
        host: []const u8 = "localhost",
        path: []const u8 = "/",
        handshake_timeout_ms: u32 = 5_000,
    };

    const accept_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    const max_handshake_bytes: usize = 8 * 1024;
    const max_control_payload: usize = 125;

    pub fn init(allocator: Allocator, stream: ByteStream, options: Config) WebSocketTransport {
        return .{
            .allocator = allocator,
            .stream = stream,
            .max_message_bytes = options.max_message_bytes,
            .host = options.host,
            .path = options.path,
            .handshake_timeout_ms = options.handshake_timeout_ms,
            .rng = std.Random.DefaultCsprng.init(options.seed),
        };
    }

    pub fn deinit(self: *WebSocketTransport) void {
        self.input.deinit(self.allocator);
        self.message.deinit(self.allocator);
        self.output.deinit(self.allocator);
        self.* = undefined;
    }

    const vtable: Transport.VTable = .{ .connect = connect, .send = send, .receive = receive, .close = close };

    /// Lend this transport; `self` must outlive the returned value.
    pub fn transport(self: *WebSocketTransport) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn cast(ptr: *anyopaque) *WebSocketTransport {
        return @ptrCast(@alignCast(ptr));
    }

    /// The `Sec-WebSocket-Accept` value for a request key.
    pub fn acceptFor(key: []const u8, out: *[28]u8) []const u8 {
        var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
        var sha = std.crypto.hash.Sha1.init(.{});
        sha.update(key);
        sha.update(accept_guid);
        sha.final(&digest);
        return std.base64.standard.Encoder.encode(out, &digest);
    }

    fn connect(ptr: *anyopaque) Transport.Error!void {
        const self = cast(ptr);
        if (self.closed) return error.Disconnected;
        if (self.connected) return;
        var nonce: [16]u8 = undefined;
        self.rng.fill(&nonce);
        var key_buffer: [24]u8 = undefined;
        const key = std.base64.standard.Encoder.encode(&key_buffer, &nonce);

        self.output.clearRetainingCapacity();
        var aw: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &self.output);
        defer self.output = aw.toArrayList();
        aw.writer.print(
            "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
            .{ self.path, self.host, key },
        ) catch return error.OutOfMemory;
        try self.stream.write(aw.written());

        // Read the response head; bytes after it already belong to frames.
        self.input.clearRetainingCapacity();
        self.consumed = 0;
        var waited: u32 = 0;
        const slice_ms: u32 = 50;
        const head_end = while (true) {
            if (std.mem.indexOf(u8, self.input.items, "\r\n\r\n")) |end| break end;
            if (self.input.items.len > max_handshake_bytes) return error.Protocol;
            try self.input.ensureUnusedCapacity(self.allocator, 1024);
            const spare = self.input.unusedCapacitySlice()[0..1024];
            switch (try self.stream.read(spare, slice_ms)) {
                .timeout => {
                    waited += slice_ms;
                    if (waited >= self.handshake_timeout_ms) return error.Disconnected;
                },
                .eof => return error.Disconnected,
                .bytes => |n| self.input.items.len += n,
            }
        };
        const head = self.input.items[0..head_end];
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        const status = lines.first();
        if (!std.mem.startsWith(u8, status, "HTTP/1.1 101")) return error.Protocol;
        var expected_buffer: [28]u8 = undefined;
        const expected = acceptFor(key, &expected_buffer);
        var accepted = false;
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon], " \t");
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept") and std.mem.eql(u8, value, expected))
                accepted = true;
        }
        if (!accepted) return error.Protocol;
        self.consumed = head_end + 4;
        self.connected = true;
    }

    /// Frame `payload` with `opcode`, FIN set and a fresh masking key.
    fn writeFrame(self: *WebSocketTransport, opcode: u4, payload: []const u8) Transport.Error!void {
        self.output.clearRetainingCapacity();
        try self.output.ensureUnusedCapacity(self.allocator, payload.len + 14);
        self.output.appendAssumeCapacity(0x80 | @as(u8, opcode));
        if (payload.len < 126) {
            self.output.appendAssumeCapacity(0x80 | @as(u8, @intCast(payload.len)));
        } else if (payload.len <= std.math.maxInt(u16)) {
            self.output.appendAssumeCapacity(0x80 | 126);
            var length: [2]u8 = undefined;
            std.mem.writeInt(u16, &length, @intCast(payload.len), .big);
            self.output.appendSliceAssumeCapacity(&length);
        } else {
            self.output.appendAssumeCapacity(0x80 | 127);
            var length: [8]u8 = undefined;
            std.mem.writeInt(u64, &length, payload.len, .big);
            self.output.appendSliceAssumeCapacity(&length);
        }
        var mask: [4]u8 = undefined;
        self.rng.fill(&mask);
        self.output.appendSliceAssumeCapacity(&mask);
        for (payload, 0..) |byte, i| self.output.appendAssumeCapacity(byte ^ mask[i % 4]);
        try self.stream.write(self.output.items);
    }

    fn send(ptr: *anyopaque, message: []const u8) Transport.Error!void {
        const self = cast(ptr);
        if (self.closed or !self.connected) return error.Disconnected;
        try self.writeFrame(0x1, message);
    }

    const Frame = struct {
        fin: bool,
        opcode: u4,
        header_len: usize,
        payload_len: u64,
    };

    /// The frame header at the parse position, or null when incomplete.
    fn peekHeader(bytes: []const u8) Transport.Error!?Frame {
        if (bytes.len < 2) return null;
        const b0 = bytes[0];
        const b1 = bytes[1];
        if (b0 & 0x70 != 0) return error.Protocol; // no extension was negotiated
        // RFC 6455 §5.1: a client must close on a masked server frame.
        if (b1 & 0x80 != 0) return error.Protocol;
        var frame: Frame = .{ .fin = b0 & 0x80 != 0, .opcode = @intCast(b0 & 0x0f), .header_len = 2, .payload_len = b1 & 0x7f };
        if (frame.payload_len == 126) {
            if (bytes.len < 4) return null;
            frame.payload_len = std.mem.readInt(u16, bytes[2..4], .big);
            frame.header_len = 4;
        } else if (frame.payload_len == 127) {
            if (bytes.len < 10) return null;
            frame.payload_len = std.mem.readInt(u64, bytes[2..10], .big);
            if (frame.payload_len >> 63 != 0) return error.Protocol;
            frame.header_len = 10;
        }
        if (frame.opcode >= 0x8) {
            if (!frame.fin or frame.payload_len > max_control_payload) return error.Protocol;
        }
        return frame;
    }

    fn nextMessage(self: *WebSocketTransport) Transport.Error!?[]const u8 {
        while (true) {
            const pending = self.input.items[self.consumed..];
            if (self.discard_remaining != 0) {
                const n: usize = @intCast(@min(self.discard_remaining, pending.len));
                self.consumed += n;
                self.discard_remaining -= n;
                if (self.discard_remaining != 0) return null;
                if (self.discard_ends_message) self.discarding_message = false;
                continue;
            }
            const frame = try peekHeader(pending) orelse return null;
            const is_data = frame.opcode < 0x8;
            if (is_data) {
                switch (frame.opcode) {
                    0x0 => if (!self.in_message and !self.discarding_message) return error.Protocol,
                    0x1, 0x2 => if (self.in_message or self.discarding_message) return error.Protocol,
                    else => return error.Protocol,
                }
                const so_far: u64 = if (frame.opcode == 0x0) self.message.items.len else 0;
                const oversized = so_far + frame.payload_len > self.max_message_bytes;
                if (self.discarding_message or oversized or frame.opcode == 0x2) {
                    if (!self.discarding_message) self.skipped += 1;
                    self.in_message = false;
                    self.message.clearRetainingCapacity();
                    self.discarding_message = true;
                    self.discard_ends_message = frame.fin;
                    self.consumed += frame.header_len;
                    self.discard_remaining = frame.payload_len;
                    if (self.discard_remaining == 0 and frame.fin) self.discarding_message = false;
                    continue;
                }
            }
            const total = frame.header_len + @as(usize, @intCast(frame.payload_len));
            if (pending.len < total) return null;
            const payload = pending[frame.header_len..total];
            switch (frame.opcode) {
                0x1 => {
                    self.consumed += total;
                    if (frame.fin) return payload;
                    self.message.clearRetainingCapacity();
                    try self.message.appendSlice(self.allocator, payload);
                    self.in_message = true;
                },
                0x0 => {
                    try self.message.appendSlice(self.allocator, payload);
                    self.consumed += total;
                    if (frame.fin) {
                        self.in_message = false;
                        return self.message.items;
                    }
                },
                0x8 => {
                    // Echo the status code, then report the channel gone.
                    const code = payload[0..@min(payload.len, 2)];
                    var echo: [2]u8 = undefined;
                    @memcpy(echo[0..code.len], code);
                    self.consumed += total;
                    // The echo is a courtesy to a peer that is already
                    // closing; a failed write changes nothing, since the
                    // channel is reported gone either way.
                    self.writeFrame(0x8, echo[0..code.len]) catch {};
                    self.connected = false;
                    return error.Disconnected;
                },
                0x9 => {
                    var pong: [max_control_payload]u8 = undefined;
                    @memcpy(pong[0..payload.len], payload);
                    self.consumed += total;
                    try self.writeFrame(0xA, pong[0..payload.len]);
                },
                0xA => self.consumed += total,
                else => return error.Protocol,
            }
        }
    }

    fn receive(ptr: *anyopaque, timeout_ms: u32) Transport.Error!?[]const u8 {
        const self = cast(ptr);
        if (self.closed or !self.connected) return error.Disconnected;
        if (self.consumed != 0) {
            const items = self.input.items;
            std.mem.copyForwards(u8, items[0 .. items.len - self.consumed], items[self.consumed..]);
            self.input.items.len -= self.consumed;
            self.consumed = 0;
        }
        var wait = timeout_ms;
        while (true) {
            if (try self.nextMessage()) |message| return message;
            // Compact before growing so the buffer stays bounded by one frame.
            if (self.consumed != 0) {
                const items = self.input.items;
                std.mem.copyForwards(u8, items[0 .. items.len - self.consumed], items[self.consumed..]);
                self.input.items.len -= self.consumed;
                self.consumed = 0;
            }
            try self.input.ensureUnusedCapacity(self.allocator, read_chunk_bytes);
            const spare = self.input.unusedCapacitySlice()[0..read_chunk_bytes];
            switch (try self.stream.read(spare, wait)) {
                .timeout => return null,
                .eof => {
                    self.connected = false;
                    return error.Disconnected;
                },
                .bytes => |n| self.input.items.len += n,
            }
            wait = 0;
        }
    }

    fn close(ptr: *anyopaque) void {
        const self = cast(ptr);
        if (self.closed) return;
        if (self.connected) {
            // 1000: normal closure. Ignoring a failure is correct: the
            // stream is closed next regardless, which the peer also sees.
            self.writeFrame(0x8, &.{ 0x03, 0xe8 }) catch {};
        }
        self.connected = false;
        self.closed = true;
        self.stream.close();
    }
};

/// The daemon control socket for a Codex home:
/// `<codex_home>/app-server-control/app-server-control.sock` (a symlink into
/// `/tmp/codex-daemon-<uid>/`, because of the AF_UNIX path limit).
pub fn daemonSocketPath(out: []u8, codex_home: []const u8) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(out, "{s}/app-server-control/app-server-control.sock", .{
        std.mem.trimEnd(u8, codex_home, "/"),
    });
}

// The adapter ----------------------------------------------------------------

/// Which app-server the adapter talks to.
pub const Mode = enum {
    /// The shared daemon, as one more client beside the TUI: observe the
    /// TUI's thread and answer its approvals. Unknown server requests are left
    /// for the TUI.
    daemon,
    /// An owner-spawned `codex app-server --listen stdio://` with Conduit as
    /// its only client (a headless agent). `attach` starts a thread, and
    /// server requests Conduit cannot answer get a JSON-RPC error so the
    /// harness is never left waiting on nobody.
    stdio,
};

pub const Options = struct {
    /// The channel to the app-server, borrowed; the adapter connects it in
    /// `attach` and closes it in `deinit`.
    transport: Transport,
    mode: Mode = .daemon,
    /// The agent's working directory in its ExecutionContext. Copied.
    cwd: []const u8,
    /// The output of `codex --version`, when the owner already has it.
    /// Optional: `detect` runs the same probe through the ExecutionContext and
    /// sets the gate itself. Outside the tested range the adapter degrades to
    /// heuristics.
    cli_version: ?[]const u8 = null,
    /// Sent as `clientInfo`; borrowed for the adapter's lifetime.
    client_name: []const u8 = "conduit",
    client_version: []const u8 = "0.0.0",
    /// How long a blocking call (`attach`'s handshake and thread selection)
    /// waits for its response.
    call_timeout_ms: u32 = 10_000,
    /// Events converted but not yet accepted by the owner's queue.
    backlog_capacity: usize = 64,
    /// The most messages one `poll` reads before returning.
    max_messages_per_poll: usize = 256,
};

/// Notifications the adapter never reads; opting out keeps the stream small
/// (streamed deltas would otherwise dominate it).
const opted_out_notifications = [_][]const u8{
    "item/agentMessage/delta",
    "item/plan/delta",
    "item/reasoning/summaryTextDelta",
    "item/reasoning/summaryPartAdded",
    "item/reasoning/textDelta",
    "item/commandExecution/outputDelta",
    "item/fileChange/outputDelta",
    "command/exec/outputDelta",
    "thread/tokenUsage/updated",
    "account/rateLimits/updated",
};

/// A fixed-capacity copy of a short identifier.
fn Text(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        /// Copy `text`, or refuse it whole when it does not fit.
        fn set(self: *Self, text: []const u8) bool {
            if (text.len > capacity) return false;
            @memcpy(self.bytes[0..text.len], text);
            self.len = text.len;
            return true;
        }

        fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        fn eql(self: *const Self, text: []const u8) bool {
            return std.mem.eql(u8, self.slice(), text);
        }
    };
}

/// Thread and turn ids are UUIDs today; this leaves room for growth.
const IdText = Text(128);
const RequestIdText = Text(event.max_identifier_bytes);

const CallKind = enum {
    initialize,
    thread_start,
    thread_resume,
    thread_loaded_list,
    thread_list,
    turn_start,
    turn_steer,
    turn_interrupt,
};

const Call = struct {
    id: i64 = 0,
    kind: CallKind = .initialize,
    status: enum { free, pending, succeeded, failed } = .free,
};

const max_calls = 8;
const max_approvals = 8;
const max_loaded_threads = 64;
/// The most events one received message converts into (a file change with
/// many paths is cut to this many references).
const max_events_per_message = 10;
const max_file_references = max_events_per_message - 1;

const ApprovalKind = enum { command, file_change, permissions, legacy_exec, legacy_patch };

/// A byte range inside an `Approval`'s storage.
const Span = struct {
    start: usize = 0,
    len: usize = 0,

    fn of(self: Span, storage: []const u8) []const u8 {
        return storage[self.start..][0..self.len];
    }
};

const ApprovalDecision = struct {
    /// What `respondPermission` names: the decision string, or an object
    /// decision's single key, suffixed with `#<n>` when repeated.
    id: Span,
    label: []const u8,
    kind: event.DecisionKind,
    /// For `.permissions`: the grant scope; otherwise the decision's JSON.
    raw: Span,
};

/// A pending approval server request. Everything sent back is a copy of what
/// the request carried, so no answer is invented here.
const Approval = struct {
    kind: ApprovalKind,
    id_text: RequestIdText = .{},
    raw_id: Span = .{},
    /// For `.permissions`: the requested profile, echoed as the grant.
    permissions: Span = .{},
    decisions: [event.max_decisions]ApprovalDecision = undefined,
    decision_count: usize = 0,
    storage: std.ArrayList(u8) = .empty,
    answered: ?event.DecisionKind = null,

    fn append(self: *Approval, allocator: Allocator, bytes: []const u8) Allocator.Error!Span {
        const start = self.storage.items.len;
        try self.storage.appendSlice(allocator, bytes);
        return .{ .start = start, .len = bytes.len };
    }

    fn decisionId(self: *const Approval, i: usize) []const u8 {
        return self.decisions[i].id.of(self.storage.items);
    }
};

pub const CodexAdapter = struct {
    allocator: Allocator,
    io: std.Io,
    transport: Transport,
    mode: Mode,
    cwd: []u8,
    client_name: []const u8,
    client_version: []const u8,
    call_timeout_ms: u32,
    max_messages_per_poll: usize,

    /// The app-server's version is outside the tested range (or the probe
    /// output named none): heuristics only.
    gated: bool = false,
    /// `launch` targeted a remote context (SSH, WSL): the daemon's control
    /// socket is on that host, so there is no structured channel and the
    /// agent keeps the PTY baseline (see `remote_capabilities`).
    remote: bool = false,
    server_version: ?Version = null,
    connected: bool = false,
    attached: bool = false,

    next_id: i64 = 1,
    calls: [max_calls]Call = @splat(.{}),
    thread_id: IdText = .{},
    turn_id: IdText = .{},
    turn_active: bool = false,
    /// The state last reported, mirroring the registry so every emitted
    /// change is a legal transition.
    reported: State = .idle,
    approvals: [max_approvals]?Approval = @splat(null),
    loaded: [max_loaded_threads]IdText = undefined,
    loaded_count: usize = 0,
    chosen: IdText = .{},

    backlog: []event.StoredEvent,
    backlog_head: usize = 0,
    backlog_len: usize = 0,
    /// Parses one received message; reset per message.
    arena: std.heap.ArenaAllocator,
    /// Builds one outgoing message; reset per send.
    out_arena: std.heap.ArenaAllocator,

    /// Counters for diagnostics; never message content.
    malformed_messages: u64 = 0,
    dropped_events: u64 = 0,

    pub const InitError = Allocator.Error;

    /// The adapter's capabilities when it speaks to a supported app-server.
    pub const structured_capabilities: adapter_mod.Capabilities = .{
        .detect = true,
        .launch = true,
        .attach = true,
        .poll = true,
        .send_input = true,
        .respond_permission = true,
        .stop = true,
        .structured_status = true,
        .permission_requests = true,
        .transcript = true,
        .subagents = true,
    };
    /// What is left outside the tested version range: launch the TUI into a
    /// PTY and rely on the heuristic baseline. `attach` stays callable so it
    /// can report `error.Protocol` rather than a silent `Unsupported`.
    pub const gated_capabilities: adapter_mod.Capabilities = .{ .detect = true, .launch = true, .attach = true };
    /// A TUI launched in an SSH or WSL workspace (TASK-61). Its app-server
    /// daemon listens on a Unix socket on the remote host, which this
    /// adapter's `.daemon` transport (`FdStream.connectUnix`) can only reach
    /// on this machine; it must not dial the local socket, which would be
    /// another codex's daemon. Without `attach` the owner stops at the PTY
    /// baseline instead of retrying. Forwarding the remote socket over the
    /// connection (decision-8's `ssh -O forward`) is not implemented.
    pub const remote_capabilities: adapter_mod.Capabilities = .{ .detect = true, .launch = true };

    pub fn init(allocator: Allocator, io: std.Io, options: Options) InitError!CodexAdapter {
        const cwd = try allocator.dupe(u8, options.cwd);
        errdefer allocator.free(cwd);
        const backlog = try allocator.alloc(event.StoredEvent, @max(options.backlog_capacity, max_events_per_message));
        var self: CodexAdapter = .{
            .allocator = allocator,
            .io = io,
            .transport = options.transport,
            .mode = options.mode,
            .cwd = cwd,
            .client_name = options.client_name,
            .client_version = options.client_version,
            .call_timeout_ms = options.call_timeout_ms,
            .max_messages_per_poll = options.max_messages_per_poll,
            .backlog = backlog,
            .arena = .init(allocator),
            .out_arena = .init(allocator),
        };
        if (options.cli_version) |text| {
            const version = Version.find(text);
            self.gated = if (version) |v| !versionSupported(v) else true;
            if (self.gated) log.debug("codex version outside the tested range; heuristics only", .{});
        }
        return self;
    }

    pub fn deinit(self: *CodexAdapter) void {
        if (self.connected) self.transport.close();
        for (&self.approvals) |*slot| {
            if (slot.*) |*approval| approval.storage.deinit(self.allocator);
        }
        self.allocator.free(self.backlog);
        self.allocator.free(self.cwd);
        self.arena.deinit();
        self.out_arena.deinit();
        self.* = undefined;
    }

    const vtable: adapter_mod.Adapter.VTable = .{
        .harness = harnessFn,
        .capabilities = capabilitiesFn,
        .detect = detectFn,
        .launch = launchFn,
        .attach = attachFn,
        .poll = pollFn,
        .send_input = sendInputFn,
        .respond_permission = respondPermissionFn,
        .stop = stopFn,
        .destroy = destroyFn,
    };

    /// Lend the adapter through the common interface. `destroy` calls
    /// `deinit` but does not free `self`'s own memory.
    pub fn adapter(self: *CodexAdapter) adapter_mod.Adapter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn cast(ptr: *anyopaque) *CodexAdapter {
        return @ptrCast(@alignCast(ptr));
    }

    fn castConst(ptr: *const anyopaque) *const CodexAdapter {
        return @ptrCast(@alignCast(ptr));
    }

    fn harnessFn(_: *const anyopaque) Harness {
        return .codex;
    }

    fn capabilitiesFn(ptr: *const anyopaque) adapter_mod.Capabilities {
        const self = castConst(ptr);
        if (self.remote) return remote_capabilities;
        return if (self.gated) gated_capabilities else structured_capabilities;
    }

    fn destroyFn(ptr: *anyopaque) void {
        cast(ptr).deinit();
    }

    /// The harness thread this adapter follows, once known.
    pub fn threadId(self: *const CodexAdapter) ?[]const u8 {
        return if (self.thread_id.isEmpty()) null else self.thread_id.slice();
    }

    // Launch -------------------------------------------------------------------

    /// The TUI is `codex --cd <cwd> [-- <prompt>]` (it joins the shared daemon
    /// by default, which is what `.daemon` attach relies on); a headless agent
    /// is `codex app-server --listen stdio://`, which the owner must start
    /// with pipes or a socketpair rather than a PTY, since the protocol is
    /// line-framed JSON and a terminal's line discipline would alter it.
    // Detect -------------------------------------------------------------------

    /// Run `codex --version` through the workspace's ExecutionContext, so
    /// remote workspaces probe their own install. A missing command (or exit
    /// 127 from a shell-wrapped context) is "not installed". The version also
    /// sets the gate: outside the tested range the adapter drops to
    /// heuristic-only capabilities, and output that names no version is
    /// refused with `error.Protocol` and gates the adapter too, rather than
    /// guessing.
    fn detectFn(ptr: *anyopaque, request: adapter_mod.DetectRequest) adapter_mod.Error!?[]const u8 {
        const self = cast(ptr);
        var result = request.context.run(self.allocator, self.io, .{
            .argv = &.{ "codex", "--version" },
            .cwd = if (self.cwd.len != 0) self.cwd else "/",
            .max_output = detect_max_output,
            .timeout_ms = detect_timeout_ms,
        }) catch |err| switch (err) {
            error.CommandNotFound => return null,
            error.Unsupported => return error.Unsupported,
            error.OutOfMemory => return error.OutOfMemory,
            error.Unavailable => return error.Disconnected,
            error.AccessDenied, error.InvalidRequest, error.Timeout, error.OutputTooLarge, error.SpawnFailed => {
                log.debug("version probe failed: {s}", .{@errorName(err)});
                return error.Protocol;
            },
        };
        defer result.deinit(self.allocator);
        if (result.exit_code) |code| if (code == 127) return null;
        if (!result.succeeded()) return error.Protocol;
        const version = parseVersionOutput(result.stdout) orelse {
            self.gated = true;
            log.debug("codex --version named no version; heuristics only", .{});
            return error.Protocol;
        };
        self.gated = !versionSupported(version);
        if (self.gated) log.debug("codex version outside the tested range; heuristics only", .{});
        return std.fmt.bufPrint(request.version_buffer, "{d}.{d}.{d}", .{ version.major, version.minor, version.patch }) catch
            error.NoSpaceLeft;
    }

    fn launchFn(ptr: *anyopaque, allocator: Allocator, request: adapter_mod.LaunchRequest) adapter_mod.Error!adapter_mod.LaunchSpec {
        const self = cast(ptr);
        if (request.context_kind.isRemote()) {
            // A headless app-server speaks over pipes the owner holds; a
            // remote one would need them carried over the connection.
            if (request.headless) return error.Unsupported;
            self.remote = true;
        }
        var argv: std.ArrayList([]const u8) = .empty;
        if (request.headless) {
            try argv.appendSlice(allocator, &.{ "codex", "app-server", "--listen", "stdio://" });
        } else {
            try argv.appendSlice(allocator, &.{ "codex", "--cd", try allocator.dupe(u8, request.cwd) });
            if (request.initial_prompt) |prompt| {
                // `--` keeps a prompt that starts with '-' from parsing as a flag.
                try argv.appendSlice(allocator, &.{ "--", try allocator.dupe(u8, prompt) });
            }
        }
        const env = try allocator.alloc([]const u8, 1);
        var entry: [adapter_mod.correlation_env_name.len + 1 + adapter_mod.CorrelationToken.text_len]u8 = undefined;
        env[0] = try allocator.dupe(u8, request.token.envEntry(&entry));
        return .{ .argv = try argv.toOwnedSlice(allocator), .env = env };
    }

    // Attach -------------------------------------------------------------------

    /// Connect the transport and run the `initialize` handshake. `attach`
    /// calls it; it is public so a probe can check an app-server's version
    /// without starting or resuming a thread.
    pub fn handshake(self: *CodexAdapter) adapter_mod.Error!void {
        if (self.gated) return error.Protocol;
        if (self.connected) return;
        self.transport.connect() catch |err| return mapTransportError(err);
        self.connected = true;
        try self.call(.initialize, "initialize", .{
            .clientInfo = .{ .name = self.client_name, .version = self.client_version },
            .capabilities = .{ .optOutNotificationMethods = &opted_out_notifications },
        });
        if (self.gated) return error.Protocol;
        try self.sendRaw("{\"method\":\"initialized\"}");
    }

    fn attachFn(ptr: *anyopaque, request: adapter_mod.AttachRequest) adapter_mod.Error!void {
        const self = cast(ptr);
        if (self.attached) return error.UnknownTarget;
        try self.handshake();
        if (request.harness_session_id) |id| {
            try self.resume_(id);
        } else switch (self.mode) {
            .stdio => try self.call(.thread_start, "thread/start", .{ .cwd = self.cwd }),
            .daemon => {
                try self.call(.thread_loaded_list, "thread/loaded/list", .{ .limit = max_loaded_threads });
                self.chosen = .{};
                try self.call(.thread_list, "thread/list", .{
                    .cwd = self.cwd,
                    .limit = 50,
                    .sortKey = "updated_at",
                    .sortDirection = "desc",
                });
                if (self.chosen.isEmpty()) return error.UnknownTarget;
                var chosen = self.chosen;
                try self.resume_(chosen.slice());
            },
        }
        if (self.thread_id.isEmpty()) return error.Protocol;
        self.attached = true;
    }

    fn resume_(self: *CodexAdapter, thread_id: []const u8) adapter_mod.Error!void {
        var id: IdText = .{};
        if (!id.set(thread_id)) return error.UnknownTarget;
        try self.call(.thread_resume, "thread/resume", .{ .threadId = id.slice(), .excludeTurns = true });
    }

    fn mapTransportError(err: Transport.Error) adapter_mod.Error {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Disconnected => error.Disconnected,
            error.Protocol => error.Protocol,
        };
    }

    fn sendRaw(self: *CodexAdapter, message: []const u8) adapter_mod.Error!void {
        self.transport.send(message) catch |err| return mapTransportError(err);
    }

    /// Send a request and register it. The response is handled by
    /// `onResponse` whenever it arrives.
    fn sendRequest(self: *CodexAdapter, kind: CallKind, method: []const u8, params: anytype) adapter_mod.Error!?*Call {
        const id = self.next_id;
        self.next_id += 1;
        _ = self.out_arena.reset(.retain_capacity);
        const text = std.json.Stringify.valueAlloc(self.out_arena.allocator(), .{
            .id = id,
            .method = method,
            .params = params,
        }, .{ .emit_null_optional_fields = false }) catch return error.OutOfMemory;
        // Untracked when every slot is busy: the response is then ignored,
        // which only loses bookkeeping a later notification repeats.
        var slot: ?*Call = null;
        for (&self.calls) |*c| {
            if (c.status == .free) {
                c.* = .{ .id = id, .kind = kind, .status = .pending };
                slot = c;
                break;
            }
        }
        self.sendRaw(text) catch |err| {
            if (slot) |c| c.* = .{};
            return err;
        };
        log.debug("sent {s} ({d} bytes)", .{ method, text.len });
        return slot;
    }

    /// Send a request and process messages until its response arrives or
    /// `call_timeout_ms` passes. Messages that arrive meanwhile are handled
    /// normally, so their events reach the backlog in order.
    fn call(self: *CodexAdapter, kind: CallKind, method: []const u8, params: anytype) adapter_mod.Error!void {
        const slot = try self.sendRequest(kind, method, params) orelse return error.NoSpaceLeft;
        defer slot.* = .{};
        const slice_ms: u32 = 50;
        var waited: u32 = 0;
        while (slot.status == .pending) {
            const message = self.transport.receive(slice_ms) catch |err| return mapTransportError(err);
            if (message) |bytes| {
                self.handleMessage(bytes);
            } else {
                waited += slice_ms;
                if (waited >= self.call_timeout_ms) {
                    log.debug("{s}: no response in {d} ms", .{ method, self.call_timeout_ms });
                    return error.Disconnected;
                }
            }
        }
        if (slot.status == .failed) return if (kind == .thread_resume) error.UnknownTarget else error.Protocol;
    }

    // Poll ---------------------------------------------------------------------

    fn pollFn(ptr: *anyopaque, queue: *event.EventQueue) adapter_mod.Error!usize {
        const self = cast(ptr);
        if (!self.attached) return error.Disconnected;
        var pushed = self.flush(queue);
        var read: usize = 0;
        while (read < self.max_messages_per_poll and self.backlog.len - self.backlog_len >= max_events_per_message) : (read += 1) {
            const message = self.transport.receive(0) catch |err| {
                // Deliver what is already converted before reporting the loss.
                pushed += self.flush(queue);
                if (pushed != 0) return pushed;
                return mapTransportError(err);
            };
            self.handleMessage(message orelse break);
        }
        pushed += self.flush(queue);
        return pushed;
    }

    fn flush(self: *CodexAdapter, queue: *event.EventQueue) usize {
        var pushed: usize = 0;
        while (self.backlog_len != 0) {
            queue.push(self.backlog[self.backlog_head].event) catch |err| switch (err) {
                // Kept for the next poll.
                error.QueueFull => break,
                // Fit one slot here, so cannot be too large there; dropped if so.
                error.EventTooLarge => self.dropped_events += 1,
            };
            self.backlog_head = (self.backlog_head + 1) % self.backlog.len;
            self.backlog_len -= 1;
            pushed += 1;
        }
        return pushed;
    }

    fn emit(self: *CodexAdapter, ev: event.Event) void {
        if (self.backlog_len == self.backlog.len) {
            self.dropped_events += 1;
            log.debug("backlog full; dropped a {s} event", .{@tagName(std.meta.activeTag(ev))});
            return;
        }
        const index = (self.backlog_head + self.backlog_len) % self.backlog.len;
        self.backlog[index].store(ev) catch {
            self.dropped_events += 1;
            log.debug("a {s} event exceeded storage limits", .{@tagName(std.meta.activeTag(ev))});
            return;
        };
        self.backlog_len += 1;
    }

    /// Report `next` if it is a legal change from what was last reported. A
    /// waiting state after a finished turn implies a new turn, so `working`
    /// is reported first; anything else illegal (`idle → done`) is dropped.
    fn emitState(self: *CodexAdapter, next: State) void {
        if (self.reported == next) return;
        if (!state_model.canTransition(self.reported, next)) {
            const finished = self.reported == .done or self.reported == .errored;
            if (!(finished and next.needsAttention())) return;
            self.emit(.{ .status_change = .{ .state = .working, .source = .structured } });
        }
        self.emit(.{ .status_change = .{ .state = next, .source = .structured } });
        self.reported = next;
    }

    // Messages -----------------------------------------------------------------

    fn handleMessage(self: *CodexAdapter, bytes: []const u8) void {
        _ = self.arena.reset(.retain_capacity);
        const allocator = self.arena.allocator();
        const root = std.json.parseFromSliceLeaky(Value, allocator, bytes, .{
            .duplicate_field_behavior = .use_last,
        }) catch {
            self.malformed_messages += 1;
            log.debug("unparseable message ({d} bytes)", .{bytes.len});
            return;
        };
        if (root != .object) {
            self.malformed_messages += 1;
            return;
        }
        const object = root.object;
        const params = object.get("params") orelse Value.null;
        const result = if (string(object.get("method"))) |method|
            if (object.get("id")) |id| self.onServerRequest(method, id, params) else self.onNotification(method, params)
        else if (object.get("id")) |id|
            self.onResponse(id, object.get("result"), object.get("error") != null)
        else blk: {
            self.malformed_messages += 1;
            break :blk {};
        };
        result catch |err| log.debug("message handling failed: {s}", .{@errorName(err)});
    }

    fn findCall(self: *CodexAdapter, id: Value) ?*Call {
        const number = switch (id) {
            .integer => |n| n,
            else => return null,
        };
        for (&self.calls) |*c| {
            if (c.status == .pending and c.id == number) return c;
        }
        return null;
    }

    fn onResponse(self: *CodexAdapter, id: Value, result: ?Value, failed: bool) Allocator.Error!void {
        const c = self.findCall(id) orelse return;
        if (failed or result == null) {
            log.debug("{s} failed", .{@tagName(c.kind)});
            self.finishCall(c, false);
            return;
        }
        const r = result.?;
        switch (c.kind) {
            .initialize => {
                const agent = string(field(r, "userAgent")) orelse "";
                // `<client>/<version> (...)`: the version follows the slash.
                const after = if (std.mem.indexOfScalar(u8, agent, '/')) |i| agent[i + 1 ..] else agent;
                self.server_version = Version.find(after);
                self.gated = if (self.server_version) |v| !versionSupported(v) else true;
                if (self.gated) log.debug("app-server version outside the tested range; heuristics only", .{});
            },
            .thread_start, .thread_resume => {
                const thread = field(r, "thread") orelse Value.null;
                const id_text = string(field(thread, "id")) orelse {
                    self.finishCall(c, false);
                    return;
                };
                if (!self.thread_id.set(id_text)) {
                    self.finishCall(c, false);
                    return;
                }
                self.applyThreadStatus(field(thread, "status") orelse Value.null);
            },
            .thread_loaded_list => {
                self.loaded_count = 0;
                for (array(field(r, "data"))) |item| {
                    const id_text = string(item) orelse continue;
                    if (self.loaded_count == max_loaded_threads) break;
                    if (self.loaded[self.loaded_count].set(id_text)) self.loaded_count += 1;
                }
            },
            .thread_list => {
                // Sorted most recently updated first: the first loaded thread
                // in this cwd is the best guess.
                for (array(field(r, "data"))) |thread| {
                    const id_text = string(field(thread, "id")) orelse continue;
                    const cwd = string(field(thread, "cwd")) orelse continue;
                    if (!std.mem.eql(u8, cwd, self.cwd)) continue;
                    if (!self.isLoaded(id_text)) continue;
                    if (self.chosen.set(id_text)) break;
                }
            },
            .turn_start, .turn_steer => {
                const turn_id = string(field(field(r, "turn") orelse Value.null, "id"));
                if (turn_id) |t| {
                    if (self.turn_id.isEmpty()) _ = self.turn_id.set(t);
                }
            },
            .turn_interrupt => {},
        }
        self.finishCall(c, true);
    }

    fn finishCall(self: *CodexAdapter, c: *Call, ok: bool) void {
        _ = self;
        // Blocking callers watch the status; fire-and-forget calls free now.
        switch (c.kind) {
            .turn_start, .turn_steer, .turn_interrupt => c.* = .{},
            else => c.status = if (ok) .succeeded else .failed,
        }
    }

    fn isLoaded(self: *const CodexAdapter, id: []const u8) bool {
        for (self.loaded[0..self.loaded_count]) |*loaded| {
            if (loaded.eql(id)) return true;
        }
        return false;
    }

    /// Whether a thread-scoped message concerns the followed thread.
    fn ours(self: *const CodexAdapter, thread_id: ?[]const u8) bool {
        const id = thread_id orelse return false;
        return !self.thread_id.isEmpty() and self.thread_id.eql(id);
    }

    fn applyThreadStatus(self: *CodexAdapter, status: Value) void {
        const kind = string(field(status, "type")) orelse return;
        if (std.mem.eql(u8, kind, "idle")) {
            // Codex reports idle just before `turn/completed`; the turn's own
            // outcome is reported there, and reporting idle first would make
            // it an illegal `idle → done`.
            const turn_was_running = self.turn_active;
            self.turn_active = false;
            if (!turn_was_running and self.reported != .done and self.reported != .errored) self.emitState(.idle);
        } else if (std.mem.eql(u8, kind, "active")) {
            self.turn_active = true;
            var next: State = .working;
            for (array(field(status, "activeFlags"))) |flag| {
                const name = string(flag) orelse continue;
                if (std.mem.eql(u8, name, "waitingOnApproval")) next = .waiting_permission;
                if (std.mem.eql(u8, name, "waitingOnUserInput") and next != .waiting_permission) next = .waiting_input;
            }
            self.emitState(next);
        } else if (std.mem.eql(u8, kind, "systemError")) {
            self.emitState(.errored);
        }
        // `notLoaded` says nothing about the agent.
    }

    fn onNotification(self: *CodexAdapter, method: []const u8, params: Value) Allocator.Error!void {
        const thread_id = string(field(params, "threadId"));
        if (std.mem.eql(u8, method, "thread/status/changed")) {
            if (!self.ours(thread_id)) return;
            self.applyThreadStatus(field(params, "status") orelse Value.null);
        } else if (std.mem.eql(u8, method, "turn/started")) {
            if (!self.ours(thread_id)) return;
            self.turn_active = true;
            if (string(field(field(params, "turn") orelse Value.null, "id"))) |id| _ = self.turn_id.set(id);
            self.emitState(.working);
        } else if (std.mem.eql(u8, method, "turn/completed")) {
            if (!self.ours(thread_id)) return;
            self.turn_active = false;
            self.turn_id = .{};
            const turn = field(params, "turn") orelse Value.null;
            const status = string(field(turn, "status")) orelse "";
            if (std.mem.eql(u8, status, "failed")) {
                const message = string(field(field(turn, "error") orelse Value.null, "message")) orelse "";
                self.emit(.{ .notification = .{ .title = "Codex turn failed", .body = message } });
                self.emitState(.errored);
            } else if (std.mem.eql(u8, status, "interrupted")) {
                self.emitState(.idle);
            } else if (std.mem.eql(u8, status, "completed")) {
                self.emitState(.done);
            }
        } else if (std.mem.eql(u8, method, "item/started")) {
            if (!self.ours(thread_id)) return;
            try self.onItem(field(params, "item") orelse Value.null, .started);
        } else if (std.mem.eql(u8, method, "item/completed")) {
            if (!self.ours(thread_id)) return;
            try self.onItem(field(params, "item") orelse Value.null, .completed);
        } else if (std.mem.eql(u8, method, "serverRequest/resolved")) {
            if (!self.ours(thread_id)) return;
            self.onResolved(field(params, "requestId") orelse Value.null);
        } else if (std.mem.eql(u8, method, "error")) {
            if (!self.ours(thread_id)) return;
            if (boolean(field(params, "willRetry")) orelse false) return;
            const message = string(field(field(params, "error") orelse Value.null, "message")) orelse "";
            self.emit(.{ .notification = .{ .title = "Codex error", .body = message } });
        } else if (std.mem.eql(u8, method, "thread/started")) {
            // Only a thread this adapter started itself is adopted here.
            if (self.mode != .stdio or !self.thread_id.isEmpty()) return;
            const id = string(field(field(params, "thread") orelse Value.null, "id")) orelse return;
            _ = self.thread_id.set(id);
        } else {
            log.debug("ignored notification {s}", .{method});
        }
    }

    const ItemPhase = enum { started, completed };

    fn onItem(self: *CodexAdapter, item: Value, phase: ItemPhase) Allocator.Error!void {
        const arena = self.arena.allocator();
        const kind = string(field(item, "type")) orelse return;
        const eq = std.mem.eql;
        switch (phase) {
            .started => {
                if (eq(u8, kind, "commandExecution")) {
                    self.emit(.{ .tool_use = .{ .name = kind, .summary = string(field(item, "command")) orelse "" } });
                } else if (eq(u8, kind, "fileChange")) {
                    const changes = array(field(item, "changes"));
                    const first = if (changes.len != 0) string(field(changes[0], "path")) orelse "" else "";
                    const summary = if (changes.len > 1)
                        try std.fmt.allocPrint(arena, "{s} (+{d} more)", .{ first, changes.len - 1 })
                    else
                        first;
                    self.emit(.{ .tool_use = .{ .name = kind, .summary = summary } });
                } else if (eq(u8, kind, "mcpToolCall")) {
                    self.emit(.{ .tool_use = .{
                        .name = string(field(item, "tool")) orelse kind,
                        .summary = string(field(item, "server")) orelse "",
                    } });
                } else if (eq(u8, kind, "dynamicToolCall") or eq(u8, kind, "collabAgentToolCall")) {
                    self.emit(.{ .tool_use = .{
                        .name = string(field(item, "tool")) orelse kind,
                        .summary = string(field(item, "prompt")) orelse "",
                    } });
                } else if (eq(u8, kind, "webSearch")) {
                    self.emit(.{ .tool_use = .{ .name = kind, .summary = string(field(item, "query")) orelse "" } });
                } else if (eq(u8, kind, "imageView")) {
                    const path = string(field(item, "path")) orelse "";
                    self.emit(.{ .tool_use = .{ .name = kind, .summary = path } });
                }
            },
            .completed => {
                if (eq(u8, kind, "agentMessage")) {
                    self.emit(.{ .message = .{ .role = .assistant, .text = string(field(item, "text")) orelse "" } });
                } else if (eq(u8, kind, "userMessage")) {
                    const text = try joinTextParts(arena, array(field(item, "content")), "text");
                    self.emit(.{ .message = .{ .role = .user, .text = text } });
                } else if (eq(u8, kind, "fileChange")) {
                    var count: usize = 0;
                    for (array(field(item, "changes"))) |change| {
                        if (count == max_file_references) break;
                        const path = string(field(change, "path")) orelse continue;
                        self.emit(.{ .file_reference = .{ .path = path } });
                        count += 1;
                    }
                } else if (eq(u8, kind, "imageView")) {
                    if (string(field(item, "path"))) |path| self.emit(.{ .file_reference = .{ .path = path } });
                } else if (eq(u8, kind, "subAgentActivity")) {
                    const activity = string(field(item, "kind")) orelse return;
                    const phase_: event.Subagent.Phase = if (eq(u8, activity, "started"))
                        .start
                    else if (eq(u8, activity, "completed") or eq(u8, activity, "interrupted"))
                        .stop
                    else
                        return;
                    const id = string(field(item, "agentThreadId")) orelse return;
                    self.emit(.{ .subagent = .{ .id = id, .name = string(field(item, "agentPath")) orelse "", .phase = phase_ } });
                }
                // Reasoning, plans and command results are not transcript
                // events; the rollout keeps them.
            },
        }
    }

    // Approvals ----------------------------------------------------------------

    fn onServerRequest(self: *CodexAdapter, method: []const u8, id: Value, params: Value) Allocator.Error!void {
        const eq = std.mem.eql;
        const kind: ?ApprovalKind = if (eq(u8, method, "item/commandExecution/requestApproval"))
            .command
        else if (eq(u8, method, "item/fileChange/requestApproval"))
            .file_change
        else if (eq(u8, method, "item/permissions/requestApproval"))
            .permissions
        else if (eq(u8, method, "execCommandApproval"))
            .legacy_exec
        else if (eq(u8, method, "applyPatchApproval"))
            .legacy_patch
        else
            null;

        const thread_id = string(field(params, "threadId")) orelse string(field(params, "conversationId"));
        if (kind) |k| {
            if (!self.ours(thread_id)) return;
            return self.onApproval(k, id, params);
        }
        if (eq(u8, method, "item/tool/requestUserInput") or eq(u8, method, "mcpServer/elicitation/request")) {
            // The question is answered in the TUI; the agent is blocked on it.
            if (self.ours(thread_id)) self.emitState(.waiting_input);
            return;
        }
        log.debug("unanswered server request {s}", .{method});
        if (self.mode == .stdio) {
            // Conduit is the only client: say so rather than leave Codex waiting.
            const arena = self.out_arena.allocator();
            _ = self.out_arena.reset(.retain_capacity);
            const raw_id = try rawJson(arena, id);
            const text = try std.fmt.allocPrint(arena, "{{\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"not supported by Conduit\"}}}}", .{raw_id});
            self.sendRaw(text) catch |err| log.debug("error reply failed: {s}", .{@errorName(err)});
        }
    }

    fn requestIdText(id: Value, out: *RequestIdText) bool {
        var buffer: [24]u8 = undefined;
        return switch (id) {
            .integer => |n| out.set(std.fmt.bufPrint(&buffer, "{d}", .{n}) catch return false),
            .string => |s| out.set(s),
            else => false,
        };
    }

    fn findApproval(self: *CodexAdapter, id_text: []const u8) ?*Approval {
        for (&self.approvals) |*slot| {
            if (slot.*) |*approval| {
                if (approval.id_text.eql(id_text)) return approval;
            }
        }
        return null;
    }

    fn pendingApprovals(self: *const CodexAdapter) usize {
        var n: usize = 0;
        for (self.approvals) |slot| {
            if (slot != null) n += 1;
        }
        return n;
    }

    fn onApproval(self: *CodexAdapter, kind: ApprovalKind, id: Value, params: Value) Allocator.Error!void {
        const arena = self.arena.allocator();
        var id_text: RequestIdText = .{};
        if (!requestIdText(id, &id_text)) {
            log.debug("approval request with an unusable id", .{});
            return;
        }
        if (self.findApproval(id_text.slice()) != null) return; // a replay
        const slot = for (&self.approvals) |*s| {
            if (s.* == null) break s;
        } else {
            log.debug("too many pending approvals; left to the TUI", .{});
            return;
        };

        var approval: Approval = .{ .kind = kind, .id_text = id_text };
        errdefer approval.storage.deinit(self.allocator);
        approval.raw_id = try approval.append(self.allocator, try rawJson(arena, id));

        // The harness's own choices, in its order.
        switch (kind) {
            .command, .file_change => {
                const offered = array(field(params, "availableDecisions"));
                const defaults = [_]Value{
                    .{ .string = "accept" },  .{ .string = "acceptForSession" },
                    .{ .string = "decline" }, .{ .string = "cancel" },
                };
                // Without a list, the schema's full enum is what is on offer.
                for (if (offered.len != 0) offered else &defaults) |decision| {
                    if (!try self.addDecision(&approval, decision)) {
                        approval.storage.deinit(self.allocator);
                        return;
                    }
                }
            },
            .permissions => {
                approval.permissions = try approval.append(self.allocator, try rawJson(arena, field(params, "permissions") orelse .{ .object = .empty }));
                const choices = [_]struct { id: []const u8, label: []const u8, kind: event.DecisionKind, scope: []const u8 }{
                    .{ .id = "grant", .label = "Grant for this turn", .kind = .allow_once, .scope = "turn" },
                    .{ .id = "grantForSession", .label = "Grant for session", .kind = .allow_always, .scope = "session" },
                    .{ .id = "decline", .label = "Decline", .kind = .reject, .scope = "turn" },
                };
                for (choices) |choice| {
                    approval.decisions[approval.decision_count] = .{
                        .id = try approval.append(self.allocator, choice.id),
                        .label = choice.label,
                        .kind = choice.kind,
                        .raw = try approval.append(self.allocator, choice.scope),
                    };
                    approval.decision_count += 1;
                }
            },
            .legacy_exec, .legacy_patch => {
                // Four decisions always fit `event.max_decisions`.
                for ([_][]const u8{ "approved", "approved_for_session", "denied", "abort" }) |name| {
                    _ = try self.addDecision(&approval, .{ .string = name });
                }
            },
        }

        const title = try approvalTitle(arena, kind, params);
        var decisions: [event.max_decisions]event.Decision = undefined;
        for (approval.decisions[0..approval.decision_count], 0..) |d, i| {
            decisions[i] = .{ .id = d.id.of(approval.storage.items), .label = d.label, .kind = d.kind };
        }
        if (self.reported != .waiting_permission) {
            const finished = self.reported == .done or self.reported == .errored;
            if (finished) self.emitState(.working);
        }
        self.emit(.{ .permission_request = .{
            .id = approval.id_text.slice(),
            .title = title,
            .decisions = decisions[0..approval.decision_count],
        } });
        self.reported = .waiting_permission;
        slot.* = approval;
    }

    /// Add one offered decision; false when the request offers more than the
    /// event model can carry, in which case the request is left to the TUI.
    fn addDecision(self: *CodexAdapter, approval: *Approval, decision: Value) Allocator.Error!bool {
        if (approval.decision_count == event.max_decisions) {
            log.debug("approval offers too many decisions; left to the TUI", .{});
            return false;
        }
        const arena = self.arena.allocator();
        const name: []const u8 = switch (decision) {
            .string => |s| s,
            .object => |o| if (o.count() == 1) o.keys()[0] else return true,
            else => return true,
        };
        const described = describeDecision(name, decision);
        // Two offers of one kind (two network rules) need distinct ids.
        var repeats: usize = 0;
        for (0..approval.decision_count) |i| {
            const existing = approval.decisionId(i);
            if (std.mem.eql(u8, existing, name) or (std.mem.startsWith(u8, existing, name) and existing.len > name.len and existing[name.len] == '#'))
                repeats += 1;
        }
        const id = if (repeats == 0) name else try std.fmt.allocPrint(arena, "{s}#{d}", .{ name, repeats + 1 });
        if (id.len > event.max_identifier_bytes) return true;
        approval.decisions[approval.decision_count] = .{
            .id = try approval.append(self.allocator, id),
            .label = described.label,
            .kind = described.kind,
            .raw = try approval.append(self.allocator, try rawJson(arena, decision)),
        };
        approval.decision_count += 1;
        return true;
    }

    fn approvalTitle(arena: Allocator, kind: ApprovalKind, params: Value) Allocator.Error![]const u8 {
        const reason = string(field(params, "reason"));
        const head: []const u8 = switch (kind) {
            .command => if (string(field(params, "command"))) |command|
                try std.fmt.allocPrint(arena, "Run: {s}", .{command})
            else
                "Run a command",
            .legacy_exec => blk: {
                const words = array(field(params, "command"));
                if (words.len == 0) break :blk "Run a command";
                var out: std.ArrayList(u8) = .empty;
                try out.appendSlice(arena, "Run:");
                for (words) |word| {
                    try out.append(arena, ' ');
                    try out.appendSlice(arena, string(word) orelse "");
                }
                break :blk out.items;
            },
            .file_change, .legacy_patch => if (string(field(params, "grantRoot"))) |root|
                try std.fmt.allocPrint(arena, "Apply file changes, allowing writes under {s}", .{root})
            else
                "Apply file changes",
            .permissions => "Grant additional permissions",
        };
        return if (reason) |r| try std.fmt.allocPrint(arena, "{s}\nReason: {s}", .{ head, r }) else head;
    }

    fn onResolved(self: *CodexAdapter, request_id: Value) void {
        var id_text: RequestIdText = .{};
        if (!requestIdText(request_id, &id_text)) return;
        const approval = self.findApproval(id_text.slice()) orelse return;
        self.resolve(approval);
    }

    fn resolve(self: *CodexAdapter, approval: *Approval) void {
        const outcome: event.PermissionOutcome = if (approval.answered) |kind| switch (kind) {
            .allow_once, .allow_always => .allowed,
            .reject => .rejected,
            // Conduit sent a choice it has no name for; its effect is the
            // harness's to report.
            .other => .resolved_elsewhere,
        } else .resolved_elsewhere;
        self.emit(.{ .permission_resolved = .{ .id = approval.id_text.slice(), .outcome = outcome } });
        approval.storage.deinit(self.allocator);
        for (&self.approvals) |*slot| {
            if (slot.*) |*a| if (a == approval) {
                slot.* = null;
                break;
            };
        }
        if (self.pendingApprovals() == 0 and self.reported == .waiting_permission) self.reported = .working;
    }

    fn respondPermissionFn(ptr: *anyopaque, request_id: []const u8, decision_id: []const u8) adapter_mod.Error!void {
        const self = cast(ptr);
        if (!self.attached) return error.Disconnected;
        const approval = self.findApproval(request_id) orelse return error.UnknownTarget;
        const decision = for (approval.decisions[0..approval.decision_count], 0..) |*d, i| {
            if (std.mem.eql(u8, approval.decisionId(i), decision_id)) break d;
        } else return error.UnknownTarget;

        _ = self.out_arena.reset(.retain_capacity);
        const arena = self.out_arena.allocator();
        const storage = approval.storage.items;
        const raw_id = approval.raw_id.of(storage);
        const text = switch (approval.kind) {
            .permissions => if (decision.kind == .reject)
                try std.fmt.allocPrint(arena, "{{\"id\":{s},\"result\":{{\"permissions\":{{}},\"scope\":\"turn\"}}}}", .{raw_id})
            else
                try std.fmt.allocPrint(arena, "{{\"id\":{s},\"result\":{{\"permissions\":{s},\"scope\":\"{s}\"}}}}", .{
                    raw_id, approval.permissions.of(storage), decision.raw.of(storage),
                }),
            else => try std.fmt.allocPrint(arena, "{{\"id\":{s},\"result\":{{\"decision\":{s}}}}}", .{
                raw_id, decision.raw.of(storage),
            }),
        };
        try self.sendRaw(text);
        approval.answered = decision.kind;
        // The legacy requests predate `serverRequest/resolved`.
        if (approval.kind == .legacy_exec or approval.kind == .legacy_patch) self.resolve(approval);
    }

    // Input and stop -----------------------------------------------------------

    /// Start a turn with the human's text, or steer the running one.
    fn sendInputFn(ptr: *anyopaque, bytes: []const u8) adapter_mod.Error!void {
        const self = cast(ptr);
        if (!self.attached) return error.Disconnected;
        const input = .{.{ .type = "text", .text = bytes }};
        if (!self.turn_active) {
            _ = try self.sendRequest(.turn_start, "turn/start", .{ .threadId = self.thread_id.slice(), .input = input });
        } else {
            // A turn that began before attach has no known id to steer.
            if (self.turn_id.isEmpty()) return error.UnknownTarget;
            _ = try self.sendRequest(.turn_steer, "turn/steer", .{
                .threadId = self.thread_id.slice(),
                .input = input,
                .expectedTurnId = self.turn_id.slice(),
            });
        }
    }

    /// Interrupt the running turn. With no turn running there is nothing to
    /// stop; ending the process is the owner's, through the PTY.
    fn stopFn(ptr: *anyopaque) adapter_mod.Error!void {
        const self = cast(ptr);
        if (!self.attached) return error.Disconnected;
        if (!self.turn_active) return;
        if (self.turn_id.isEmpty()) return error.UnknownTarget;
        _ = try self.sendRequest(.turn_interrupt, "turn/interrupt", .{
            .threadId = self.thread_id.slice(),
            .turnId = self.turn_id.slice(),
        });
    }
};

/// A decision's display label and kind. Unknown decisions keep their own
/// name as the label and are `other`, never guessed into allow or reject.
fn describeDecision(name: []const u8, decision: Value) struct { label: []const u8, kind: event.DecisionKind } {
    const table = [_]struct { name: []const u8, label: []const u8, kind: event.DecisionKind }{
        .{ .name = "accept", .label = "Accept", .kind = .allow_once },
        .{ .name = "acceptForSession", .label = "Accept for session", .kind = .allow_always },
        .{ .name = "acceptWithExecpolicyAmendment", .label = "Accept and allow similar commands", .kind = .allow_always },
        .{ .name = "decline", .label = "Decline", .kind = .reject },
        .{ .name = "cancel", .label = "Decline and stop the turn", .kind = .reject },
        .{ .name = "approved", .label = "Approve", .kind = .allow_once },
        .{ .name = "approved_for_session", .label = "Approve for session", .kind = .allow_always },
        .{ .name = "approved_execpolicy_amendment", .label = "Approve and allow similar commands", .kind = .allow_always },
        .{ .name = "approved_mcp_policy_amendment", .label = "Approve and allow this tool", .kind = .allow_always },
        .{ .name = "denied", .label = "Deny", .kind = .reject },
        .{ .name = "abort", .label = "Deny and stop the turn", .kind = .reject },
    };
    for (table) |row| {
        if (std.mem.eql(u8, row.name, name)) return .{ .label = row.label, .kind = row.kind };
    }
    if (std.mem.eql(u8, name, "applyNetworkPolicyAmendment") or std.mem.eql(u8, name, "network_policy_amendment")) {
        // {applyNetworkPolicyAmendment: {network_policy_amendment: {host, action}}}
        const inner = field(decision, name) orelse Value.null;
        const amendment = field(inner, "network_policy_amendment") orelse inner;
        const action = string(field(amendment, "action")) orelse "";
        if (std.mem.eql(u8, action, "allow")) return .{ .label = "Always allow this host", .kind = .allow_always };
        if (std.mem.eql(u8, action, "deny")) return .{ .label = "Always deny this host", .kind = .reject };
        return .{ .label = "Apply a network rule", .kind = .other };
    }
    return .{ .label = name, .kind = .other };
}

// JSON helpers ---------------------------------------------------------------

fn field(value: Value, name: []const u8) ?Value {
    return switch (value) {
        .object => |o| o.get(name),
        else => null,
    };
}

fn string(value: ?Value) ?[]const u8 {
    return switch (value orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn boolean(value: ?Value) ?bool {
    return switch (value orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

fn array(value: ?Value) []const Value {
    return switch (value orelse return &.{}) {
        .array => |a| a.items,
        else => &.{},
    };
}

fn rawJson(allocator: Allocator, value: Value) Allocator.Error![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

/// Concatenate the `text` of every content part whose `type` is `part_type`,
/// separated by newlines.
fn joinTextParts(allocator: Allocator, parts: []const Value, part_type: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (parts) |part| {
        const kind = string(field(part, "type")) orelse continue;
        if (!std.mem.eql(u8, kind, part_type)) continue;
        const text = string(field(part, "text")) orelse continue;
        if (out.items.len != 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, text);
    }
    return out.items;
}

// Transcript -----------------------------------------------------------------

/// Parses a Codex rollout transcript
/// (`$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`)
/// incrementally into events. Feed it bytes as the file grows, then pull
/// events with `next`.
///
/// Mapping: `session_meta` records the session id, cwd and CLI version
/// (`sessionId`, `cwd`, `cliVersion`); `response_item` `message` with role
/// user or assistant → `message` (Codex's injected context — user-role text
/// that is a single `<tag>...</tag>` block such as `<environment_context>` —
/// and developer/system instructions are skipped); `function_call`,
/// `custom_tool_call`, `local_shell_call` and `web_search_call` → `tool_use`;
/// `event_msg` `task_started` → working, `task_complete` → done,
/// `turn_aborted` → idle. Reasoning, tool outputs, token counts, turn context
/// and compaction records are skipped. Approvals are not persisted in
/// rollouts (doc-3), so a transcript never yields permission events; the
/// app-server is their only source.
///
/// Who tails the file is the owner's concern (through the ExecutionContext,
/// so remote workspaces work); this type only parses.
///
/// Memory: `feed` copies into a buffer bounded by `max_line_bytes` plus the
/// chunk; a longer line is skipped through its newline and counted. An event
/// from `next` borrows the reader and is valid until the next `next`, `feed`
/// or `deinit`.
pub const RolloutReader = struct {
    allocator: Allocator,
    max_line_bytes: usize,
    pending: std.ArrayList(u8) = .empty,
    /// Bytes at the front of `pending` already parsed.
    consumed: usize = 0,
    discarding: bool = false,
    arena: std.heap.ArenaAllocator,
    session_id: IdText = .{},
    cli_version: Text(32) = .{},
    cwd_bytes: std.ArrayList(u8) = .empty,
    skipped_lines: u64 = 0,

    pub const default_max_line_bytes: usize = 4 * 1024 * 1024;

    pub fn init(allocator: Allocator, max_line_bytes: usize) RolloutReader {
        return .{ .allocator = allocator, .max_line_bytes = max_line_bytes, .arena = .init(allocator) };
    }

    pub fn deinit(self: *RolloutReader) void {
        self.pending.deinit(self.allocator);
        self.cwd_bytes.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn sessionId(self: *const RolloutReader) ?[]const u8 {
        return if (self.session_id.isEmpty()) null else self.session_id.slice();
    }

    pub fn cliVersion(self: *const RolloutReader) ?[]const u8 {
        return if (self.cli_version.isEmpty()) null else self.cli_version.slice();
    }

    pub fn cwd(self: *const RolloutReader) ?[]const u8 {
        return if (self.cwd_bytes.items.len == 0) null else self.cwd_bytes.items;
    }

    /// Append the next bytes of the file.
    pub fn feed(self: *RolloutReader, bytes: []const u8) Allocator.Error!void {
        if (self.consumed != 0) {
            const items = self.pending.items;
            std.mem.copyForwards(u8, items[0 .. items.len - self.consumed], items[self.consumed..]);
            self.pending.items.len -= self.consumed;
            self.consumed = 0;
        }
        var rest = bytes;
        while (rest.len != 0) {
            const newline = std.mem.indexOfScalar(u8, rest, '\n');
            if (self.discarding) {
                self.discarding = newline == null;
                rest = if (newline) |n| rest[n + 1 ..] else &.{};
                continue;
            }
            // Bound the line being assembled before any of it is copied.
            const partial_start = if (std.mem.lastIndexOfScalar(u8, self.pending.items, '\n')) |i| i + 1 else 0;
            const partial_len = self.pending.items.len - partial_start;
            if (partial_len + (newline orelse rest.len) > self.max_line_bytes) {
                self.pending.items.len = partial_start;
                self.skipped_lines += 1;
                self.discarding = true;
                continue;
            }
            const take = if (newline) |n| n + 1 else rest.len;
            try self.pending.appendSlice(self.allocator, rest[0..take]);
            rest = rest[take..];
        }
    }

    /// The next event from the complete lines fed so far, or null.
    pub fn next(self: *RolloutReader) ?event.Event {
        while (true) {
            const items = self.pending.items[self.consumed..];
            const newline = std.mem.indexOfScalar(u8, items, '\n') orelse return null;
            const line = std.mem.trimEnd(u8, items[0..newline], "\r");
            self.consumed += newline + 1;
            if (line.len == 0) continue;
            if (self.parseLine(line)) |ev| return ev;
        }
    }

    fn parseLine(self: *RolloutReader, line: []const u8) ?event.Event {
        _ = self.arena.reset(.retain_capacity);
        const arena = self.arena.allocator();
        const root = std.json.parseFromSliceLeaky(Value, arena, line, .{ .duplicate_field_behavior = .use_last }) catch {
            self.skipped_lines += 1;
            return null;
        };
        const record = string(field(root, "type")) orelse return null;
        const payload = field(root, "payload") orelse return null;
        const eq = std.mem.eql;
        if (eq(u8, record, "session_meta")) {
            if (string(field(payload, "id"))) |id| _ = self.session_id.set(id);
            if (string(field(payload, "cli_version"))) |v| _ = self.cli_version.set(v);
            if (string(field(payload, "cwd"))) |dir| {
                if (dir.len <= event.max_path_bytes) {
                    self.cwd_bytes.clearRetainingCapacity();
                    self.cwd_bytes.appendSlice(self.allocator, dir) catch return null;
                }
            }
            return null;
        }
        const kind = string(field(payload, "type")) orelse return null;
        if (eq(u8, record, "event_msg")) {
            const next_state: State = if (eq(u8, kind, "task_started"))
                .working
            else if (eq(u8, kind, "task_complete"))
                .done
            else if (eq(u8, kind, "turn_aborted"))
                .idle
            else
                return null;
            return .{ .status_change = .{ .state = next_state, .source = .structured } };
        }
        if (!eq(u8, record, "response_item")) return null;
        if (eq(u8, kind, "message")) {
            const role_text = string(field(payload, "role")) orelse return null;
            const role: event.Role = if (eq(u8, role_text, "user")) .user else if (eq(u8, role_text, "assistant")) .assistant else return null;
            const part_type = if (role == .user) "input_text" else "output_text";
            const text = joinTextParts(arena, array(field(payload, "content")), part_type) catch return null;
            if (text.len == 0) return null;
            if (role == .user and isInjectedContext(text)) return null;
            return .{ .message = .{ .role = role, .text = text } };
        }
        if (eq(u8, kind, "function_call")) {
            const name = string(field(payload, "name")) orelse return null;
            const arguments = string(field(payload, "arguments")) orelse "";
            return .{ .tool_use = .{ .name = name, .summary = commandSummary(arena, arguments) } };
        }
        if (eq(u8, kind, "custom_tool_call")) {
            const name = string(field(payload, "name")) orelse return null;
            return .{ .tool_use = .{ .name = name, .summary = string(field(payload, "input")) orelse "" } };
        }
        if (eq(u8, kind, "local_shell_call")) {
            const command = field(field(payload, "action") orelse Value.null, "command") orelse Value.null;
            return .{ .tool_use = .{ .name = "local_shell", .summary = joinWords(arena, command) } };
        }
        if (eq(u8, kind, "web_search_call")) {
            const query = string(field(field(payload, "action") orelse Value.null, "query")) orelse "";
            return .{ .tool_use = .{ .name = "web_search", .summary = query } };
        }
        return null;
    }
};

/// Codex wraps context it injects as the user (`<environment_context>`,
/// `<user_instructions>`, ...) in one XML-like block; a human prompt is not.
fn isInjectedContext(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len < 3 or trimmed[0] != '<' or trimmed[trimmed.len - 1] != '>') return false;
    const name_end = std.mem.indexOfAny(u8, trimmed[1..], "> \t\n") orelse return false;
    const name = trimmed[1..][0..name_end];
    if (name.len == 0) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    }
    var close_buffer: [64]u8 = undefined;
    const close = std.fmt.bufPrint(&close_buffer, "</{s}>", .{name}) catch return false;
    return std.mem.endsWith(u8, trimmed, close);
}

/// A shell tool call's command, from its JSON arguments (`cmd` or `command`,
/// a string or a word list); otherwise the raw arguments.
fn commandSummary(arena: Allocator, arguments: []const u8) []const u8 {
    const parsed = std.json.parseFromSliceLeaky(Value, arena, arguments, .{ .duplicate_field_behavior = .use_last }) catch return arguments;
    for ([_][]const u8{ "cmd", "command" }) |key| {
        const value = field(parsed, key) orelse continue;
        switch (value) {
            .string => |s| return s,
            .array => return joinWords(arena, value),
            else => {},
        }
    }
    return arguments;
}

fn joinWords(arena: Allocator, words: Value) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (array(words)) |word| {
        const text = string(word) orelse continue;
        if (out.items.len != 0) out.append(arena, ' ') catch return out.items;
        out.appendSlice(arena, text) catch return out.items;
    }
    return out.items;
}

// Tests ----------------------------------------------------------------------

const testing = std.testing;
const test_log = std.log.scoped(.agent_codex_test);
const registry_mod = @import("registry.zig");
const session = @import("session");
const workspace = @import("workspace");

/// A scripted in-memory byte stream. Reads return what the test fed, at most
/// `max_read` bytes at a time; writes are captured, and `responder` (when
/// set) sees each write, the way a peer would.
const MemoryStream = struct {
    allocator: Allocator,
    input: std.ArrayList(u8) = .empty,
    read_pos: usize = 0,
    output: std.ArrayList(u8) = .empty,
    eof: bool = false,
    closed: bool = false,
    max_read: usize = std.math.maxInt(usize),
    responder: ?*const fn (*MemoryStream, []const u8) void = null,

    fn deinit(self: *MemoryStream) void {
        self.input.deinit(self.allocator);
        self.output.deinit(self.allocator);
    }

    fn feed(self: *MemoryStream, bytes: []const u8) void {
        self.input.appendSlice(self.allocator, bytes) catch @panic("test OOM");
    }

    const vtable: ByteStream.VTable = .{ .read = read, .write = write, .close = close };

    fn stream(self: *MemoryStream) ByteStream {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn read(ptr: *anyopaque, buffer: []u8, _: u32) ByteStream.Error!ReadResult {
        const self: *MemoryStream = @ptrCast(@alignCast(ptr));
        const available = self.input.items.len - self.read_pos;
        if (available == 0) return if (self.eof) .eof else .timeout;
        const n = @min(@min(available, buffer.len), self.max_read);
        @memcpy(buffer[0..n], self.input.items[self.read_pos..][0..n]);
        self.read_pos += n;
        return .{ .bytes = n };
    }

    fn write(ptr: *anyopaque, bytes: []const u8) ByteStream.Error!void {
        const self: *MemoryStream = @ptrCast(@alignCast(ptr));
        if (self.closed) return error.Disconnected;
        self.output.appendSlice(self.allocator, bytes) catch return error.Disconnected;
        if (self.responder) |respond| respond(self, bytes);
    }

    fn close(ptr: *anyopaque) void {
        const self: *MemoryStream = @ptrCast(@alignCast(ptr));
        self.closed = true;
    }
};

/// Build an unmasked server frame.
fn serverFrame(allocator: Allocator, fin: bool, opcode: u4, payload: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, (if (fin) @as(u8, 0x80) else 0) | @as(u8, opcode));
    if (payload.len < 126) {
        try out.append(allocator, @intCast(payload.len));
    } else if (payload.len <= 0xffff) {
        try out.append(allocator, 126);
        var length: [2]u8 = undefined;
        std.mem.writeInt(u16, &length, @intCast(payload.len), .big);
        try out.appendSlice(allocator, &length);
    } else {
        try out.append(allocator, 127);
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, payload.len, .big);
        try out.appendSlice(allocator, &length);
    }
    try out.appendSlice(allocator, payload);
    return out.toOwnedSlice(allocator);
}

const DecodedFrame = struct { fin: bool, opcode: u4, payload: []u8, len_code: u8, size: usize };

/// Decode one masked client frame at the front of `bytes`.
fn decodeClientFrame(allocator: Allocator, bytes: []const u8) !DecodedFrame {
    if (bytes.len < 2) return error.Short;
    if (bytes[1] & 0x80 == 0) return error.Unmasked;
    const len_code = bytes[1] & 0x7f;
    var header: usize = 2;
    var len: usize = len_code;
    if (len_code == 126) {
        len = std.mem.readInt(u16, bytes[2..4], .big);
        header = 4;
    } else if (len_code == 127) {
        len = @intCast(std.mem.readInt(u64, bytes[2..10], .big));
        header = 10;
    }
    const mask = bytes[header..][0..4];
    header += 4;
    const payload = try allocator.alloc(u8, len);
    for (payload, 0..) |*b, i| b.* = bytes[header + i] ^ mask[i % 4];
    return .{ .fin = bytes[0] & 0x80 != 0, .opcode = @intCast(bytes[0] & 0x0f), .payload = payload, .len_code = len_code, .size = header + len };
}

fn testSocket(allocator: Allocator, stream: *MemoryStream, max: usize) WebSocketTransport {
    var ws = WebSocketTransport.init(allocator, stream.stream(), .{ .seed = @splat(7), .max_message_bytes = max });
    ws.connected = true;
    return ws;
}

test "versions are found in probe output and gated to the tested range" {
    try testing.expectEqual(Version{ .major = 0, .minor = 160, .patch = 1 }, Version.find("codex-cli 0.160.1").?);
    try testing.expectEqual(Version{ .major = 0, .minor = 161, .patch = 0 }, Version.find("conduit/0.161.0 (Ubuntu 26.4.0; x86_64)").?);
    try testing.expect(Version.find("codex-cli") == null);
    try testing.expect(Version.find("v1.2") == null);
    try testing.expect(Version.find("99999999999.1.1") == null);
    try testing.expect(versionSupported(.{ .major = 0, .minor = 160, .patch = 1 }));
    try testing.expect(versionSupported(.{ .major = 0, .minor = 161, .patch = 9 }));
    try testing.expect(!versionSupported(.{ .major = 0, .minor = 159, .patch = 99 }));
    try testing.expect(!versionSupported(.{ .major = 0, .minor = 162, .patch = 0 }));
    try testing.expect(!versionSupported(.{ .major = 1, .minor = 0, .patch = 0 }));

    var stream: MemoryStream = .{ .allocator = testing.allocator };
    defer stream.deinit();
    var line = LineTransport.init(testing.allocator, stream.stream(), 1024);
    defer line.deinit();
    for ([_]struct { text: []const u8, gated: bool }{
        .{ .text = "codex-cli 0.160.1", .gated = false },
        .{ .text = "codex-cli 0.161.0", .gated = false },
        .{ .text = "codex-cli 0.163.2", .gated = true },
        .{ .text = "codex-cli 0.150.0", .gated = true },
        .{ .text = "not a version", .gated = true },
    }) |case| {
        var codex = try CodexAdapter.init(testing.allocator, testing.io, .{
            .transport = line.transport(),
            .cwd = "/work",
            .cli_version = case.text,
        });
        defer codex.deinit();
        const a = codex.adapter();
        try testing.expectEqual(case.gated, codex.gated);
        try testing.expectEqual(!case.gated, a.capabilities().structured_status);
        try testing.expect(a.capabilities().launch);
        if (case.gated) {
            try testing.expectError(error.Protocol, a.attach(.{ .session = .first, .token = .fromBytes(@splat(1)) }));
            try testing.expectError(error.Unsupported, a.respondPermission("0", "accept"));
            try testing.expectEqual(@as(usize, 0), stream.output.items.len);
        }
    }
}

test "websocket client frames are masked with the right length encoding" {
    var stream: MemoryStream = .{ .allocator = testing.allocator };
    defer stream.deinit();
    var ws = testSocket(testing.allocator, &stream, 1 << 20);
    defer ws.deinit();
    const t = ws.transport();

    for ([_]struct { len: usize, code: u8 }{
        .{ .len = 0, .code = 0 },
        .{ .len = 125, .code = 125 },
        .{ .len = 126, .code = 126 },
        .{ .len = 65535, .code = 126 },
        .{ .len = 65536, .code = 127 },
    }) |case| {
        const payload = try testing.allocator.alloc(u8, case.len);
        defer testing.allocator.free(payload);
        for (payload, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
        stream.output.clearRetainingCapacity();
        try t.send(payload);
        const frame = try decodeClientFrame(testing.allocator, stream.output.items);
        defer testing.allocator.free(frame.payload);
        try testing.expect(frame.fin);
        try testing.expectEqual(@as(u4, 0x1), frame.opcode);
        try testing.expectEqual(case.code, frame.len_code);
        try testing.expectEqualSlices(u8, payload, frame.payload);
        try testing.expectEqual(stream.output.items.len, frame.size);
    }

    // Successive frames use fresh masking keys.
    stream.output.clearRetainingCapacity();
    try t.send("same");
    const first_mask = stream.output.items[2..6].*;
    stream.output.clearRetainingCapacity();
    try t.send("same");
    try testing.expect(!std.mem.eql(u8, &first_mask, stream.output.items[2..6]));
}

test "websocket server frames: 7, 16 and 64 bit lengths, fragments, ping, close" {
    const allocator = testing.allocator;
    var stream: MemoryStream = .{ .allocator = allocator, .max_read = 7 };
    defer stream.deinit();
    var ws = testSocket(allocator, &stream, 1 << 20);
    defer ws.deinit();
    const t = ws.transport();

    for ([_]usize{ 125, 126, 300, 70_000 }) |len| {
        const payload = try allocator.alloc(u8, len);
        defer allocator.free(payload);
        @memset(payload, 'x');
        payload[len - 1] = 'z';
        const frame = try serverFrame(allocator, true, 0x1, payload);
        defer allocator.free(frame);
        stream.feed(frame);
        var got: ?[]const u8 = null;
        // Partial reads leave the frame pending; later receives finish it.
        while (got == null) got = try t.receive(0);
        try testing.expectEqualSlices(u8, payload, got.?);
    }
    try testing.expect(try t.receive(0) == null);

    // A fragmented message with a ping between its fragments.
    stream.output.clearRetainingCapacity();
    const parts = [_][]u8{
        try serverFrame(allocator, false, 0x1, "{\"a\":"),
        try serverFrame(allocator, true, 0x9, "hb"),
        try serverFrame(allocator, true, 0x0, "1}"),
    };
    defer for (parts) |p| allocator.free(p);
    for (parts) |p| stream.feed(p);
    var message: ?[]const u8 = null;
    while (message == null) message = try t.receive(0);
    try testing.expectEqualStrings("{\"a\":1}", message.?);
    const pong = try decodeClientFrame(allocator, stream.output.items);
    defer allocator.free(pong.payload);
    try testing.expectEqual(@as(u4, 0xA), pong.opcode);
    try testing.expectEqualStrings("hb", pong.payload);

    // Close: echoed with its status code, then the channel is gone.
    stream.output.clearRetainingCapacity();
    const close_frame = try serverFrame(allocator, true, 0x8, &.{ 0x03, 0xe8 });
    defer allocator.free(close_frame);
    stream.feed(close_frame);
    var result: Transport.Error!?[]const u8 = null;
    while (true) {
        result = t.receive(0);
        if (result) |m| {
            if (m == null) continue;
        } else |_| {}
        break;
    }
    try testing.expectError(error.Disconnected, result);
    const echo = try decodeClientFrame(allocator, stream.output.items);
    defer allocator.free(echo.payload);
    try testing.expectEqual(@as(u4, 0x8), echo.opcode);
    try testing.expectEqualSlices(u8, &.{ 0x03, 0xe8 }, echo.payload);
}

test "websocket refuses masked server frames and skips oversized messages" {
    const allocator = testing.allocator;
    {
        var stream: MemoryStream = .{ .allocator = allocator };
        defer stream.deinit();
        var ws = testSocket(allocator, &stream, 16);
        defer ws.deinit();
        const big = "x" ** 40;
        const parts = [_][]u8{
            try serverFrame(allocator, true, 0x1, big),
            try serverFrame(allocator, false, 0x1, "0123456789"),
            try serverFrame(allocator, true, 0x0, "0123456789"),
            try serverFrame(allocator, true, 0x2, "bin"),
            try serverFrame(allocator, true, 0x1, "ok"),
        };
        defer for (parts) |p| allocator.free(p);
        for (parts) |p| stream.feed(p);
        try testing.expectEqualStrings("ok", (try ws.transport().receive(0)).?);
        try testing.expectEqual(@as(u64, 3), ws.skipped);
        try testing.expect(!ws.in_message and !ws.discarding_message);
    }
    {
        var stream: MemoryStream = .{ .allocator = allocator };
        defer stream.deinit();
        var ws = testSocket(allocator, &stream, 1024);
        defer ws.deinit();
        stream.feed(&.{ 0x81, 0x82, 1, 2, 3, 4, 'a' ^ 1, 'b' ^ 2 });
        try testing.expectError(error.Protocol, ws.transport().receive(0));
    }
    {
        var stream: MemoryStream = .{ .allocator = allocator };
        defer stream.deinit();
        var ws = testSocket(allocator, &stream, 1024);
        defer ws.deinit();
        // A continuation with no message in progress.
        stream.feed(&.{ 0x80, 0x01, 'a' });
        try testing.expectError(error.Protocol, ws.transport().receive(0));
    }
}

/// Answers a WebSocket opening handshake the way the Codex daemon does.
fn answerHandshake(stream: *MemoryStream, bytes: []const u8) void {
    const marker = "Sec-WebSocket-Key: ";
    const start = (std.mem.indexOf(u8, bytes, marker) orelse return) + marker.len;
    const end = std.mem.indexOfPos(u8, bytes, start, "\r\n") orelse return;
    var accept_buffer: [28]u8 = undefined;
    const accept = WebSocketTransport.acceptFor(bytes[start..end], &accept_buffer);
    var response_buffer: [256]u8 = undefined;
    const response = std.fmt.bufPrint(&response_buffer, "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\n" ++
        "connection: upgrade\r\nsec-websocket-accept: {s}\r\n\r\n", .{accept}) catch return;
    stream.feed(response);
    // A frame arriving in the same read as the response head.
    stream.feed(&.{ 0x81, 0x02, '{', '}' });
}

fn answerHandshakeWrongly(stream: *MemoryStream, bytes: []const u8) void {
    if (std.mem.indexOf(u8, bytes, "Sec-WebSocket-Key") == null) return;
    stream.feed("HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n");
}

test "websocket handshake verifies the accept key" {
    var rfc: [28]u8 = undefined;
    // RFC 6455 §1.3's worked example.
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", WebSocketTransport.acceptFor("dGhlIHNhbXBsZSBub25jZQ==", &rfc));

    var stream: MemoryStream = .{ .allocator = testing.allocator, .responder = answerHandshake };
    defer stream.deinit();
    var ws = WebSocketTransport.init(testing.allocator, stream.stream(), .{ .seed = @splat(3) });
    defer ws.deinit();
    const t = ws.transport();
    try t.connect();
    try testing.expect(std.mem.startsWith(u8, stream.output.items, "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"));
    try testing.expectEqualStrings("{}", (try t.receive(0)).?);

    var bad: MemoryStream = .{ .allocator = testing.allocator, .responder = answerHandshakeWrongly };
    defer bad.deinit();
    var ws_bad = WebSocketTransport.init(testing.allocator, bad.stream(), .{ .seed = @splat(3) });
    defer ws_bad.deinit();
    try testing.expectError(error.Protocol, ws_bad.transport().connect());

    var silent: MemoryStream = .{ .allocator = testing.allocator, .eof = true };
    defer silent.deinit();
    var ws_silent = WebSocketTransport.init(testing.allocator, silent.stream(), .{ .seed = @splat(3) });
    defer ws_silent.deinit();
    try testing.expectError(error.Disconnected, ws_silent.transport().connect());
}

test "line transport frames, bounds and ends" {
    var stream: MemoryStream = .{ .allocator = testing.allocator, .max_read = 3 };
    defer stream.deinit();
    var line = LineTransport.init(testing.allocator, stream.stream(), 8);
    defer line.deinit();
    const t = line.transport();
    stream.feed("{\"a\":1}\r\n\n\n" ++ "{\"toolong\":1}\n" ++ "[2]\n" ++ "[3]");
    var got: std.ArrayList([]const u8) = .empty;
    defer {
        for (got.items) |m| testing.allocator.free(m);
        got.deinit(testing.allocator);
    }
    var idle: usize = 0;
    while (idle < 3) {
        if (try t.receive(0)) |m| {
            try got.append(testing.allocator, try testing.allocator.dupe(u8, m));
        } else idle += 1;
    }
    try testing.expectEqual(@as(usize, 2), got.items.len);
    try testing.expectEqualStrings("{\"a\":1}", got.items[0]);
    try testing.expectEqualStrings("[2]", got.items[1]);
    try testing.expectEqual(@as(u64, 1), line.skipped);
    stream.feed("\n");
    var last: ?[]const u8 = null;
    while (last == null) last = try t.receive(0);
    try testing.expectEqualStrings("[3]", last.?);
    stream.eof = true;
    try testing.expectError(error.Disconnected, t.receive(0));

    try t.send("{\"b\":2}");
    try testing.expectEqualStrings("{\"b\":2}\n", stream.output.items);
    try testing.expectError(error.Protocol, t.send("{\n}"));
}

/// A scripted app-server behind a `LineTransport`: answers each request by
/// method from `results` and records every client line.
const FakeServer = struct {
    allocator: Allocator,
    stream: MemoryStream,
    partial: std.ArrayList(u8) = .empty,
    lines: std.ArrayList([]u8) = .empty,
    results: []const Result = &.{},

    const Result = struct { method: []const u8, json: []const u8 };

    fn create(allocator: Allocator, results: []const Result) !*FakeServer {
        const self = try allocator.create(FakeServer);
        self.* = .{ .allocator = allocator, .stream = .{ .allocator = allocator, .responder = respond }, .results = results };
        return self;
    }

    fn destroy(self: *FakeServer) void {
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.deinit(self.allocator);
        self.partial.deinit(self.allocator);
        self.stream.deinit();
        self.allocator.destroy(self);
    }

    fn last(self: *const FakeServer) []const u8 {
        return self.lines.items[self.lines.items.len - 1];
    }

    fn respond(stream: *MemoryStream, bytes: []const u8) void {
        const self: *FakeServer = @fieldParentPtr("stream", stream);
        self.partial.appendSlice(self.allocator, bytes) catch @panic("test OOM");
        while (std.mem.indexOfScalar(u8, self.partial.items, '\n')) |newline| {
            const line = self.allocator.dupe(u8, self.partial.items[0..newline]) catch @panic("test OOM");
            self.lines.append(self.allocator, line) catch @panic("test OOM");
            std.mem.copyForwards(u8, self.partial.items, self.partial.items[newline + 1 ..]);
            self.partial.items.len -= newline + 1;
            self.answer(line);
        }
    }

    fn answer(self: *FakeServer, line: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSliceLeaky(Value, arena.allocator(), line, .{}) catch return;
        const method = string(field(parsed, "method")) orelse return;
        const id = switch (field(parsed, "id") orelse return) {
            .integer => |n| n,
            else => return,
        };
        for (self.results) |r| {
            if (!std.mem.eql(u8, r.method, method)) continue;
            const text = std.fmt.allocPrint(arena.allocator(), "{{\"id\":{d},\"result\":{s}}}\n", .{ id, r.json }) catch return;
            self.stream.feed(text);
            return;
        }
        const text = std.fmt.allocPrint(arena.allocator(), "{{\"id\":{d},\"error\":{{\"code\":-32601,\"message\":\"nope\"}}}}\n", .{id}) catch return;
        self.stream.feed(text);
    }
};

const default_init_result = "{\"userAgent\":\"conduit/0.160.1 (Ubuntu; x86_64) (conduit; 0.0.0)\",\"codexHome\":\"/h\",\"platformFamily\":\"unix\",\"platformOs\":\"linux\"}";

/// An attached adapter over a `FakeServer`, with a queue to poll into.
const Rig = struct {
    server: *FakeServer,
    line: LineTransport,
    codex: CodexAdapter,
    queue: event.EventQueue,
    out: []event.StoredEvent,
    events: []event.StoredEvent = &.{},

    fn create(mode: Mode, results: []const FakeServer.Result) !*Rig {
        const allocator = testing.allocator;
        const self = try allocator.create(Rig);
        errdefer allocator.destroy(self);
        self.server = try FakeServer.create(allocator, results);
        self.line = LineTransport.init(allocator, self.server.stream.stream(), default_max_message_bytes);
        self.codex = try CodexAdapter.init(allocator, testing.io, .{
            .transport = self.line.transport(),
            .mode = mode,
            .cwd = "/work/proj",
            .call_timeout_ms = 200,
        });
        self.queue = try event.EventQueue.init(allocator, testing.io, 64);
        self.out = try allocator.alloc(event.StoredEvent, 64);
        return self;
    }

    fn destroy(self: *Rig) void {
        const allocator = testing.allocator;
        self.codex.deinit();
        self.line.deinit();
        self.server.destroy();
        self.queue.deinit(allocator);
        allocator.free(self.out);
        allocator.destroy(self);
    }

    fn attach(self: *Rig, session_id: ?[]const u8) adapter_mod.Error!void {
        return self.codex.adapter().attach(.{ .session = .first, .token = .fromBytes(@splat(9)), .harness_session_id = session_id });
    }

    fn feed(self: *Rig, text: []const u8) void {
        self.server.stream.feed(text);
        self.server.stream.feed("\n");
    }

    /// Poll everything available and return the drained events.
    fn poll(self: *Rig) ![]event.StoredEvent {
        _ = try self.codex.adapter().poll(&self.queue);
        const n = self.queue.drain(self.out);
        self.events = self.out[0..n];
        return self.events;
    }
};

const stdio_results = [_]FakeServer.Result{
    .{ .method = "initialize", .json = default_init_result },
    .{ .method = "thread/start", .json = "{\"thread\":{\"id\":\"t-1\",\"cwd\":\"/work/proj\",\"status\":{\"type\":\"idle\"}}}" },
    .{ .method = "turn/start", .json = "{\"turn\":{\"id\":\"turn-9\",\"status\":\"inProgress\"}}" },
};

fn expectStatus(stored: event.StoredEvent, expected: State) !void {
    try testing.expectEqual(event.Event.Kind.status_change, std.meta.activeTag(stored.event));
    try testing.expectEqual(expected, stored.event.status_change.state);
    try testing.expectEqual(state_model.Source.structured, stored.event.status_change.source);
}

/// Read a checked-in fixture. Tests run from the repository root or a
/// directory below it, so look upward for `test/fixtures`.
fn readFixture(allocator: Allocator, name: []const u8) ![]u8 {
    var path_buffer: [512]u8 = undefined;
    var prefix_buffer: [64]u8 = undefined;
    var prefix_len: usize = 0;
    for (0..6) |_| {
        const path = try std.fmt.bufPrint(&path_buffer, "{s}test/fixtures/agent/codex/{s}", .{ prefix_buffer[0..prefix_len], name });
        if (std.Io.Dir.cwd().readFileAlloc(testing.io, path, allocator, .limited(1 << 20))) |bytes| {
            return bytes;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        @memcpy(prefix_buffer[prefix_len..][0..3], "../");
        prefix_len += 3;
    }
    return error.FileNotFound;
}

test "every protocol name the adapter uses is in 0.160.1's generated schema" {
    const protocol = try readFixture(testing.allocator, "protocol-0.160.1.txt");
    defer testing.allocator.free(protocol);
    const used = [_][]const u8{
        "client-request initialize",                      "client-request thread/start",
        "client-request thread/resume",                   "client-request thread/loaded/list",
        "client-request thread/list",                     "client-request turn/start",
        "client-request turn/steer",                      "client-request turn/interrupt",
        "client-notification initialized",                "server-notification thread/status/changed",
        "server-notification turn/started",               "server-notification turn/completed",
        "server-notification item/started",               "server-notification item/completed",
        "server-notification serverRequest/resolved",     "server-notification error",
        "server-notification thread/started",             "server-request item/commandExecution/requestApproval",
        "server-request item/fileChange/requestApproval", "server-request item/permissions/requestApproval",
        "server-request execCommandApproval",             "server-request applyPatchApproval",
        "server-request item/tool/requestUserInput",      "server-request mcpServer/elicitation/request",
        "thread-status idle",                             "thread-status active",
        "thread-status systemError",                      "thread-status notLoaded",
        "thread-active-flag waitingOnApproval",           "thread-active-flag waitingOnUserInput",
        "turn-status completed",                          "turn-status interrupted",
        "turn-status failed",                             "thread-item agentMessage",
        "thread-item userMessage",                        "thread-item commandExecution",
        "thread-item fileChange",                         "thread-item mcpToolCall",
        "thread-item dynamicToolCall",                    "thread-item collabAgentToolCall",
        "thread-item webSearch",                          "thread-item imageView",
        "thread-item subAgentActivity",                   "command-decision accept",
        "command-decision acceptForSession",              "command-decision acceptWithExecpolicyAmendment",
        "command-decision applyNetworkPolicyAmendment",   "command-decision decline",
        "command-decision cancel",                        "file-change-decision accept",
        "file-change-decision acceptForSession",          "file-change-decision decline",
        "file-change-decision cancel",                    "permission-grant-scope turn",
        "permission-grant-scope session",                 "review-decision approved",
        "review-decision approved_for_session",           "review-decision denied",
        "review-decision abort",                          "subagent-activity started",
        "subagent-activity completed",                    "subagent-activity interrupted",
    };
    for (used) |name| {
        var lines = std.mem.splitScalar(u8, protocol, '\n');
        const found = while (lines.next()) |l| {
            if (std.mem.eql(u8, l, name)) break true;
        } else false;
        if (!found) test_log.warn("not in the 0.160.1 schema: {s}", .{name});
        try testing.expect(found);
    }
    for (opted_out_notifications) |method| {
        var buffer: [128]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, "server-notification {s}", .{method});
        try testing.expect(std.mem.indexOf(u8, protocol, name) != null);
    }
}

test "attach runs the handshake and starts a thread for a headless agent" {
    const rig = try Rig.create(.stdio, &stdio_results);
    defer rig.destroy();
    try rig.attach(null);
    const lines = rig.server.lines.items;
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expect(std.mem.startsWith(u8, lines[0], "{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"conduit\",\"version\":\"0.0.0\"},\"capabilities\":{\"optOutNotificationMethods\":[\"item/agentMessage/delta\","));
    try testing.expectEqualStrings("{\"method\":\"initialized\"}", lines[1]);
    try testing.expectEqualStrings("{\"id\":2,\"method\":\"thread/start\",\"params\":{\"cwd\":\"/work/proj\"}}", lines[2]);
    try testing.expectEqualStrings("t-1", rig.codex.threadId().?);
    try testing.expectEqual(Version{ .major = 0, .minor = 160, .patch = 1 }, rig.codex.server_version.?);
    try testing.expectError(error.UnknownTarget, rig.attach(null));
    try testing.expectEqual(@as(usize, 0), (try rig.poll()).len);

    // A server that never answers times the call out instead of hanging.
    const mute = try Rig.create(.stdio, &.{});
    defer mute.destroy();
    mute.server.stream.responder = null;
    try testing.expectError(error.Disconnected, mute.attach(null));

    // A newer server than tested is refused after initialize.
    const newer = try Rig.create(.stdio, &.{.{ .method = "initialize", .json = "{\"userAgent\":\"conduit/0.170.0 (x)\"}" }});
    defer newer.destroy();
    try testing.expectError(error.Protocol, newer.attach(null));
    try testing.expect(!newer.codex.adapter().capabilities().structured_status);
    try testing.expectEqual(@as(usize, 1), newer.server.lines.items.len);
}

test "the recorded 0.160.1 approval round trip maps to legal agent events" {
    const allocator = testing.allocator;
    const fixture = try readFixture(allocator, "app-server-approval-0.160.1.jsonl");
    defer allocator.free(fixture);
    const client_fixture = try readFixture(allocator, "app-server-approval-0.160.1.client.jsonl");
    defer allocator.free(client_fixture);

    const thread_result = "{\"thread\":{\"id\":\"01a11809-508c-7502-b819-337bc182556d\",\"cwd\":\"/work/proj\",\"status\":{\"type\":\"idle\"}}}";
    const rig = try Rig.create(.stdio, &.{
        .{ .method = "initialize", .json = default_init_result },
        .{ .method = "thread/start", .json = thread_result },
    });
    defer rig.destroy();
    try rig.attach(null);

    var reg = registry_mod.Registry.init(allocator);
    defer reg.deinit();
    const agent_id = try reg.create(.{
        .binding = .{ .workspace = .first, .session = session.SessionId.fromOrdinal(1), .session_kind = .agent_terminal, .scratchpad = .first },
        .harness = .codex,
        .ownership = .owned,
        .token = .fromBytes(@splat(9)),
        .capabilities = rig.codex.adapter().capabilities(),
    });

    // Replay the server's side up to and including the approval request.
    // Responses belong to the recording's own request ids and are skipped.
    var lines = std.mem.splitScalar(u8, fixture, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or std.mem.startsWith(u8, line, "{\"id\":") and std.mem.indexOf(u8, line, "\"result\"") != null) continue;
        rig.feed(line);
        if (std.mem.indexOf(u8, line, "requestApproval") != null) break;
    }
    const first = try rig.poll();
    for (first) |*stored| _ = try reg.apply(agent_id, stored.event);
    try testing.expectEqual(@as(usize, 5), first.len);
    try expectStatus(first[0], .working);
    try testing.expectEqual(event.Role.user, first[1].event.message.role);
    try testing.expectEqualStrings("RUNTOOL", first[1].event.message.text);
    try expectStatus(first[2], .waiting_permission);
    try testing.expectEqualStrings("commandExecution", first[3].event.tool_use.name);
    try testing.expectEqualStrings("/bin/bash -lc 'touch probe_file'", first[3].event.tool_use.summary);
    const request = first[4].event.permission_request;
    try testing.expectEqualStrings("0", request.id);
    try testing.expectEqualStrings("Run: /bin/bash -lc 'touch probe_file'\nReason: probe", request.title);
    try testing.expectEqual(@as(usize, 3), request.decisions.len);
    try testing.expectEqualStrings("accept", request.decisions[0].id);
    try testing.expectEqual(event.DecisionKind.allow_once, request.decisions[0].kind);
    try testing.expectEqualStrings("acceptWithExecpolicyAmendment", request.decisions[1].id);
    try testing.expectEqual(event.DecisionKind.allow_always, request.decisions[1].kind);
    try testing.expectEqualStrings("cancel", request.decisions[2].id);
    try testing.expectEqual(event.DecisionKind.reject, request.decisions[2].kind);
    try testing.expectEqual(State.waiting_permission, reg.get(agent_id).?.state);

    // The human picks "accept": the reply is byte-for-byte what the recorded
    // client sent to the real app-server.
    try rig.codex.adapter().respondPermission(request.id, "accept");
    var client_lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, client_fixture, "\n"), '\n');
    var recorded_reply: []const u8 = "";
    while (client_lines.next()) |l| recorded_reply = l;
    try testing.expectEqualStrings("{\"id\":0,\"result\":{\"decision\":\"accept\"}}", recorded_reply);
    try testing.expectEqualStrings(recorded_reply, rig.server.last());
    try testing.expectError(error.UnknownTarget, rig.codex.adapter().respondPermission("0", "nope"));
    try testing.expectError(error.UnknownTarget, rig.codex.adapter().respondPermission("1", "accept"));

    while (lines.next()) |line| {
        if (line.len == 0 or std.mem.startsWith(u8, line, "{\"id\":") and std.mem.indexOf(u8, line, "\"result\"") != null) continue;
        rig.feed(line);
    }
    const rest = try rig.poll();
    for (rest) |*stored| _ = try reg.apply(agent_id, stored.event);
    try testing.expectEqual(@as(usize, 3), rest.len);
    try testing.expectEqualStrings("0", rest[0].event.permission_resolved.id);
    try testing.expectEqual(event.PermissionOutcome.allowed, rest[0].event.permission_resolved.outcome);
    try testing.expectEqual(event.Role.assistant, rest[1].event.message.role);
    try testing.expectEqualStrings("MOCK_OK", rest[1].event.message.text);
    try expectStatus(rest[2], .done);
    try testing.expectEqual(State.done, reg.get(agent_id).?.state);
    try testing.expect(reg.get(agent_id).?.structured);
    // The resolved request is gone.
    try testing.expectError(error.UnknownTarget, rig.codex.adapter().respondPermission("0", "accept"));
    try testing.expectEqual(@as(u64, 0), rig.codex.malformed_messages);
}

test "approval kinds answer with exactly the offered decision" {
    const rig = try Rig.create(.stdio, &stdio_results);
    defer rig.destroy();
    try rig.attach(null);
    const a = rig.codex.adapter();

    // A command offering object decisions, two of one kind.
    rig.feed(
        \\{"id":3,"method":"item/commandExecution/requestApproval","params":{"threadId":"t-1","turnId":"u","itemId":"i","startedAtMs":1,"command":"curl x","availableDecisions":["accept",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["curl","x"]}},{"applyNetworkPolicyAmendment":{"network_policy_amendment":{"host":"x","action":"allow"}}},{"applyNetworkPolicyAmendment":{"network_policy_amendment":{"host":"x","action":"deny"}}},"decline"]}}
    );
    var events = try rig.poll();
    try testing.expectEqual(@as(usize, 1), events.len);
    const command = events[0].event.permission_request;
    try testing.expectEqualStrings("Run: curl x", command.title);
    try testing.expectEqual(@as(usize, 5), command.decisions.len);
    try testing.expectEqualStrings("applyNetworkPolicyAmendment", command.decisions[2].id);
    try testing.expectEqual(event.DecisionKind.allow_always, command.decisions[2].kind);
    try testing.expectEqualStrings("applyNetworkPolicyAmendment#2", command.decisions[3].id);
    try testing.expectEqual(event.DecisionKind.reject, command.decisions[3].kind);
    try a.respondPermission("3", "acceptWithExecpolicyAmendment");
    try testing.expectEqualStrings(
        \\{"id":3,"result":{"decision":{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["curl","x"]}}}}
    , rig.server.last());

    // A file change with a string id and no list: the schema's four choices.
    rig.feed(
        \\{"id":"req-7","method":"item/fileChange/requestApproval","params":{"threadId":"t-1","turnId":"u","itemId":"f","startedAtMs":1,"grantRoot":"/work/proj/out"}}
    );
    events = try rig.poll();
    const change = events[0].event.permission_request;
    try testing.expectEqualStrings("req-7", change.id);
    try testing.expectEqualStrings("Apply file changes, allowing writes under /work/proj/out", change.title);
    try testing.expectEqual(@as(usize, 4), change.decisions.len);
    try testing.expectEqualStrings("acceptForSession", change.decisions[1].id);
    try a.respondPermission("req-7", "decline");
    try testing.expectEqualStrings("{\"id\":\"req-7\",\"result\":{\"decision\":\"decline\"}}", rig.server.last());

    // A permissions request: the grant echoes the requested profile.
    rig.feed(
        \\{"id":8,"method":"item/permissions/requestApproval","params":{"threadId":"t-1","turnId":"u","itemId":"p","startedAtMs":1,"cwd":"/work/proj","permissions":{"network":{"enabled":true}},"reason":"fetch"}}
    );
    events = try rig.poll();
    try testing.expectEqualStrings("Grant additional permissions\nReason: fetch", events[0].event.permission_request.title);
    try a.respondPermission("8", "grantForSession");
    try testing.expectEqualStrings("{\"id\":8,\"result\":{\"permissions\":{\"network\":{\"enabled\":true}},\"scope\":\"session\"}}", rig.server.last());
    rig.feed(
        \\{"id":9,"method":"item/permissions/requestApproval","params":{"threadId":"t-1","turnId":"u","itemId":"p","startedAtMs":1,"cwd":"/w","permissions":{"network":{"enabled":true}}}}
    );
    _ = try rig.poll();
    try a.respondPermission("9", "decline");
    try testing.expectEqualStrings("{\"id\":9,\"result\":{\"permissions\":{},\"scope\":\"turn\"}}", rig.server.last());

    // Resolution reports what was answered, or that the TUI answered first.
    rig.feed("{\"method\":\"serverRequest/resolved\",\"params\":{\"threadId\":\"t-1\",\"requestId\":3}}");
    rig.feed("{\"method\":\"serverRequest/resolved\",\"params\":{\"threadId\":\"t-1\",\"requestId\":\"req-7\"}}");
    rig.feed("{\"method\":\"serverRequest/resolved\",\"params\":{\"threadId\":\"t-1\",\"requestId\":8}}");
    rig.feed("{\"id\":10,\"method\":\"item/fileChange/requestApproval\",\"params\":{\"threadId\":\"t-1\",\"turnId\":\"u\",\"itemId\":\"g\",\"startedAtMs\":1}}");
    rig.feed("{\"method\":\"serverRequest/resolved\",\"params\":{\"threadId\":\"t-1\",\"requestId\":10}}");
    events = try rig.poll();
    const outcomes = [_]struct { id: []const u8, outcome: event.PermissionOutcome }{
        .{ .id = "3", .outcome = .allowed },
        .{ .id = "req-7", .outcome = .rejected },
        .{ .id = "8", .outcome = .allowed },
    };
    for (outcomes, events[0..3]) |expected, stored| {
        try testing.expectEqualStrings(expected.id, stored.event.permission_resolved.id);
        try testing.expectEqual(expected.outcome, stored.event.permission_resolved.outcome);
    }
    try testing.expectEqual(event.Event.Kind.permission_request, std.meta.activeTag(events[3].event));
    try testing.expectEqual(event.PermissionOutcome.resolved_elsewhere, events[4].event.permission_resolved.outcome);

    // The legacy exec approval resolves as soon as it is answered.
    rig.feed(
        \\{"id":11,"method":"execCommandApproval","params":{"conversationId":"t-1","callId":"c","command":["ls","-la"],"cwd":"/w","parsedCmd":[]}}
    );
    events = try rig.poll();
    try testing.expectEqualStrings("Run: ls -la", events[0].event.permission_request.title);
    try testing.expectEqualStrings("approved_for_session", events[0].event.permission_request.decisions[1].id);
    try a.respondPermission("11", "approved");
    try testing.expectEqualStrings("{\"id\":11,\"result\":{\"decision\":\"approved\"}}", rig.server.last());
    events = try rig.poll();
    try testing.expectEqual(event.PermissionOutcome.allowed, events[0].event.permission_resolved.outcome);
    // Request 9 is still pending (no resolution arrived); nothing else is.
    try testing.expectEqual(@as(usize, 1), rig.codex.pendingApprovals());
}

test "requests for other threads, oversized offers and unknown requests" {
    const rig = try Rig.create(.stdio, &stdio_results);
    defer rig.destroy();
    try rig.attach(null);
    const lines_before = rig.server.lines.items.len;

    // Another thread's approval is not ours to show or answer.
    rig.feed("{\"id\":1,\"method\":\"item/fileChange/requestApproval\",\"params\":{\"threadId\":\"other\",\"turnId\":\"u\",\"itemId\":\"f\",\"startedAtMs\":1}}");
    // Nine choices exceed what an event carries; the TUI keeps it.
    rig.feed("{\"id\":2,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"threadId\":\"t-1\",\"turnId\":\"u\",\"itemId\":\"i\",\"startedAtMs\":1,\"availableDecisions\":[\"a\",\"b\",\"c\",\"d\",\"e\",\"f\",\"g\",\"h\",\"i\"]}}");
    // A question for the human marks the agent waiting for input.
    rig.feed("{\"id\":3,\"method\":\"item/tool/requestUserInput\",\"params\":{\"threadId\":\"t-1\",\"turnId\":\"u\",\"itemId\":\"q\",\"isBlocking\":true,\"questions\":[]}}");
    // Something Conduit cannot answer gets an error, since it is the only client.
    rig.feed("{\"id\":4,\"method\":\"currentTime/read\",\"params\":{}}");
    rig.feed("not json at all");
    rig.feed("[1,2,3]");
    rig.feed("{\"method\":\"some/future/notification\",\"params\":{\"threadId\":\"t-1\"}}");
    const events = try rig.poll();
    try testing.expectEqual(@as(usize, 1), events.len);
    try expectStatus(events[0], .waiting_input);
    try testing.expectEqual(@as(usize, 0), rig.codex.pendingApprovals());
    try testing.expectEqual(@as(u64, 2), rig.codex.malformed_messages);
    try testing.expectEqual(lines_before + 1, rig.server.lines.items.len);
    try testing.expectEqualStrings("{\"id\":4,\"error\":{\"code\":-32601,\"message\":\"not supported by Conduit\"}}", rig.server.last());
}

test "items, turns and subagents map to events" {
    const rig = try Rig.create(.stdio, &stdio_results);
    defer rig.destroy();
    try rig.attach(null);
    const script = [_][]const u8{
        "{\"method\":\"turn/started\",\"params\":{\"threadId\":\"t-1\",\"turn\":{\"id\":\"turn-1\",\"status\":\"inProgress\"}}}",
        "{\"method\":\"item/started\",\"params\":{\"threadId\":\"t-1\",\"turnId\":\"turn-1\",\"item\":{\"type\":\"fileChange\",\"id\":\"f\",\"status\":\"inProgress\",\"changes\":[{\"path\":\"src/a.zig\",\"kind\":{\"type\":\"update\"},\"diff\":\"\"},{\"path\":\"src/b.zig\",\"kind\":{\"type\":\"add\"},\"diff\":\"\"}]}}}",
        "{\"method\":\"item/completed\",\"params\":{\"threadId\":\"t-1\",\"turnId\":\"turn-1\",\"item\":{\"type\":\"fileChange\",\"id\":\"f\",\"status\":\"completed\",\"changes\":[{\"path\":\"src/a.zig\",\"kind\":{\"type\":\"update\"},\"diff\":\"\"},{\"path\":\"src/b.zig\",\"kind\":{\"type\":\"add\"},\"diff\":\"\"}]}}}",
        "{\"method\":\"item/started\",\"params\":{\"threadId\":\"t-1\",\"turnId\":\"turn-1\",\"item\":{\"type\":\"mcpToolCall\",\"id\":\"m\",\"server\":\"docs\",\"tool\":\"search\",\"status\":\"inProgress\",\"arguments\":{}}}}",
        "{\"method\":\"item/completed\",\"params\":{\"threadId\":\"t-1\",\"turnId\":\"turn-1\",\"item\":{\"type\":\"subAgentActivity\",\"id\":\"s\",\"kind\":\"started\",\"agentThreadId\":\"t-2\",\"agentPath\":\"explorer\"}}}",
        "{\"method\":\"item/completed\",\"params\":{\"threadId\":\"t-1\",\"turnId\":\"turn-1\",\"item\":{\"type\":\"reasoning\",\"id\":\"r\",\"summary\":[\"private\"]}}}",
        "{\"method\":\"item/completed\",\"params\":{\"threadId\":\"t-1\",\"turnId\":\"turn-1\",\"item\":{\"type\":\"subAgentActivity\",\"id\":\"s2\",\"kind\":\"completed\",\"agentThreadId\":\"t-2\",\"agentPath\":\"explorer\"}}}",
        // Another thread's progress is not this agent's.
        "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"t-2\",\"turn\":{\"id\":\"x\",\"status\":\"completed\"}}}",
        "{\"method\":\"error\",\"params\":{\"threadId\":\"t-1\",\"turnId\":\"turn-1\",\"willRetry\":true,\"error\":{\"message\":\"retrying\"}}}",
        "{\"method\":\"error\",\"params\":{\"threadId\":\"t-1\",\"turnId\":\"turn-1\",\"willRetry\":false,\"error\":{\"message\":\"stream lost\"}}}",
        "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"t-1\",\"status\":{\"type\":\"idle\"}}}",
        "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"t-1\",\"turn\":{\"id\":\"turn-1\",\"status\":\"failed\",\"error\":{\"message\":\"stream lost\"}}}}",
        // A later turn the human interrupts.
        "{\"method\":\"turn/started\",\"params\":{\"threadId\":\"t-1\",\"turn\":{\"id\":\"turn-2\",\"status\":\"inProgress\"}}}",
        "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"t-1\",\"turn\":{\"id\":\"turn-2\",\"status\":\"interrupted\"}}}",
        "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"t-1\",\"status\":{\"type\":\"systemError\"}}}",
    };
    for (script) |line| rig.feed(line);
    const events = try rig.poll();
    var reg = registry_mod.Registry.init(testing.allocator);
    defer reg.deinit();
    const agent_id = try reg.create(.{
        .binding = .{ .workspace = .first, .session = session.SessionId.fromOrdinal(1), .session_kind = .agent_terminal, .scratchpad = .first },
        .harness = .codex,
        .ownership = .owned,
        .token = .fromBytes(@splat(9)),
    });
    for (events) |*stored| _ = try reg.apply(agent_id, stored.event);

    const Kind = event.Event.Kind;
    const kinds = [_]Kind{ .status_change, .tool_use, .file_reference, .file_reference, .tool_use, .subagent, .subagent, .notification, .notification, .status_change, .status_change, .status_change, .status_change };
    try testing.expectEqual(kinds.len, events.len);
    for (kinds, events) |kind, stored| try testing.expectEqual(kind, std.meta.activeTag(stored.event));
    try expectStatus(events[0], .working);
    try testing.expectEqualStrings("src/a.zig (+1 more)", events[1].event.tool_use.summary);
    try testing.expectEqualStrings("src/b.zig", events[3].event.file_reference.path);
    try testing.expectEqualStrings("search", events[4].event.tool_use.name);
    try testing.expectEqualStrings("docs", events[4].event.tool_use.summary);
    try testing.expectEqual(event.Subagent.Phase.start, events[5].event.subagent.phase);
    try testing.expectEqualStrings("t-2", events[6].event.subagent.id);
    try testing.expectEqualStrings("stream lost", events[7].event.notification.body);
    try expectStatus(events[9], .errored);
    try expectStatus(events[10], .working);
    try expectStatus(events[11], .idle);
    try expectStatus(events[12], .errored);
}

test "input starts or steers turns and stop interrupts the running one" {
    const rig = try Rig.create(.stdio, &stdio_results);
    defer rig.destroy();
    const a = rig.codex.adapter();
    try testing.expectError(error.Disconnected, a.sendInput("x"));
    try rig.attach(null);

    // Nothing running: nothing sent.
    const before = rig.server.lines.items.len;
    try a.stop();
    try testing.expectEqual(before, rig.server.lines.items.len);

    try a.sendInput("fix the \"build\"");
    try testing.expectEqualStrings("{\"id\":3,\"method\":\"turn/start\",\"params\":{\"threadId\":\"t-1\",\"input\":[{\"type\":\"text\",\"text\":\"fix the \\\"build\\\"\"}]}}", rig.server.last());
    rig.feed("{\"method\":\"turn/started\",\"params\":{\"threadId\":\"t-1\",\"turn\":{\"id\":\"turn-9\",\"status\":\"inProgress\"}}}");
    _ = try rig.poll();
    try a.sendInput("also tests");
    try testing.expectEqualStrings("{\"id\":4,\"method\":\"turn/steer\",\"params\":{\"threadId\":\"t-1\",\"input\":[{\"type\":\"text\",\"text\":\"also tests\"}],\"expectedTurnId\":\"turn-9\"}}", rig.server.last());
    try a.stop();
    try testing.expectEqualStrings("{\"id\":5,\"method\":\"turn/interrupt\",\"params\":{\"threadId\":\"t-1\",\"turnId\":\"turn-9\"}}", rig.server.last());
    // Fire-and-forget calls release their slots when answered.
    _ = try rig.poll();
    for (rig.codex.calls) |c| try testing.expect(c.status == .free);

    // Mid-turn after attach, with no turn id learned yet, cannot steer.
    rig.feed("{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"t-1\",\"turn\":{\"id\":\"turn-9\",\"status\":\"completed\"}}}");
    rig.feed("{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"t-1\",\"status\":{\"type\":\"active\",\"activeFlags\":[]}}}");
    _ = try rig.poll();
    try testing.expectError(error.UnknownTarget, a.sendInput("more"));
    try testing.expectError(error.UnknownTarget, a.stop());
}

test "daemon attach finds a hand-started TUI's thread by cwd" {
    const results = [_]FakeServer.Result{
        .{ .method = "initialize", .json = default_init_result },
        .{ .method = "thread/loaded/list", .json = "{\"data\":[\"a\",\"b\"],\"nextCursor\":null}" },
        .{ .method = "thread/list", .json = "{\"data\":[{\"id\":\"c\",\"cwd\":\"/work/proj\"},{\"id\":\"b\",\"cwd\":\"/elsewhere\"},{\"id\":\"a\",\"cwd\":\"/work/proj\"}]}" },
        .{ .method = "thread/resume", .json = "{\"thread\":{\"id\":\"a\",\"cwd\":\"/work/proj\",\"status\":{\"type\":\"active\",\"activeFlags\":[\"waitingOnApproval\"]}}}" },
    };
    const rig = try Rig.create(.daemon, &results);
    defer rig.destroy();
    try rig.attach(null);
    const lines = rig.server.lines.items;
    try testing.expectEqualStrings("{\"id\":2,\"method\":\"thread/loaded/list\",\"params\":{\"limit\":64}}", lines[2]);
    try testing.expectEqualStrings("{\"id\":3,\"method\":\"thread/list\",\"params\":{\"cwd\":\"/work/proj\",\"limit\":50,\"sortKey\":\"updated_at\",\"sortDirection\":\"desc\"}}", lines[3]);
    try testing.expectEqualStrings("{\"id\":4,\"method\":\"thread/resume\",\"params\":{\"threadId\":\"a\",\"excludeTurns\":true}}", lines[4]);
    try testing.expectEqualStrings("a", rig.codex.threadId().?);
    const events = try rig.poll();
    try testing.expectEqual(@as(usize, 1), events.len);
    try expectStatus(events[0], .waiting_permission);

    // The daemon replays the pending approval to the new client; a daemon
    // client leaves requests it does not handle to the TUI.
    rig.feed("{\"id\":0,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"threadId\":\"a\",\"turnId\":\"u\",\"itemId\":\"i\",\"startedAtMs\":1,\"command\":\"ls\"}}");
    rig.feed("{\"id\":1,\"method\":\"currentTime/read\",\"params\":{}}");
    const replay = try rig.poll();
    try testing.expectEqualStrings("0", replay[0].event.permission_request.id);
    try testing.expectEqual(@as(usize, 5), rig.server.lines.items.len);

    // No loaded thread in this cwd: nothing to attach to.
    const none = try Rig.create(.daemon, &.{ results[0], results[1], .{ .method = "thread/list", .json = "{\"data\":[{\"id\":\"c\",\"cwd\":\"/work/proj\"}]}" } });
    defer none.destroy();
    try testing.expectError(error.UnknownTarget, none.attach(null));

    // A session id from Codex's hooks skips the guess.
    const known = try Rig.create(.daemon, &.{ results[0], results[3] });
    defer known.destroy();
    try known.attach("a");
    try testing.expectEqualStrings("{\"id\":2,\"method\":\"thread/resume\",\"params\":{\"threadId\":\"a\",\"excludeTurns\":true}}", known.server.lines.items[2]);
    // A resume the daemon refuses names nothing.
    const refused = try Rig.create(.daemon, &.{results[0]});
    defer refused.destroy();
    try testing.expectError(error.UnknownTarget, refused.attach("gone"));
}

test "a full owner queue keeps events with the adapter" {
    const rig = try Rig.create(.stdio, &stdio_results);
    defer rig.destroy();
    try rig.attach(null);
    var small = try event.EventQueue.init(testing.allocator, testing.io, 2);
    defer small.deinit(testing.allocator);
    for (0..5) |i| {
        var buffer: [256]u8 = undefined;
        rig.feed(try std.fmt.bufPrint(&buffer, "{{\"method\":\"item/completed\",\"params\":{{\"threadId\":\"t-1\",\"turnId\":\"u\",\"item\":{{\"type\":\"agentMessage\",\"id\":\"m\",\"text\":\"m{d}\"}}}}}}", .{i}));
    }
    const a = rig.codex.adapter();
    var seen: usize = 0;
    const out = try testing.allocator.alloc(event.StoredEvent, 2);
    defer testing.allocator.free(out);
    while (seen < 5) {
        const pushed = try a.poll(&small);
        try testing.expect(pushed != 0);
        const n = small.drain(out);
        for (out[0..n], seen..) |*stored, i| {
            var expected: [4]u8 = undefined;
            try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "m{d}", .{i}), stored.event.message.text);
        }
        seen += n;
    }
    try testing.expectEqual(@as(u64, 0), rig.codex.dropped_events);
}

test "launch describes the TUI or the headless app-server" {
    var stream: MemoryStream = .{ .allocator = testing.allocator };
    defer stream.deinit();
    var line = LineTransport.init(testing.allocator, stream.stream(), 1024);
    defer line.deinit();
    var codex = try CodexAdapter.init(testing.allocator, testing.io, .{ .transport = line.transport(), .cwd = "/w" });
    defer codex.deinit();
    const a = codex.adapter();
    try testing.expectEqual(Harness.codex, a.harness());
    try testing.expect(a.capabilities().detect);
    try testing.expect(!a.capabilities().read_prompt);
    var prompt: [8]u8 = undefined;
    try testing.expectError(error.Unsupported, a.readPrompt(&prompt));
    var queue = try event.EventQueue.init(testing.allocator, testing.io, 1);
    defer queue.deinit(testing.allocator);
    try testing.expectError(error.Disconnected, a.poll(&queue));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const token = adapter_mod.CorrelationToken.fromBytes(@splat(0xab));
    const tui = try a.launch(arena_state.allocator(), .{ .context_kind = .local, .cwd = "/work/proj", .initial_prompt = "-fix", .token = token });
    const expected = [_][]const u8{ "codex", "--cd", "/work/proj", "--", "-fix" };
    try testing.expectEqual(expected.len, tui.argv.len);
    for (expected, tui.argv) |e, actual| try testing.expectEqualStrings(e, actual);
    try testing.expectEqualStrings("CONDUIT_AGENT_TOKEN=abababababababababababababababab", tui.env[0]);
    const headless = try a.launch(arena_state.allocator(), .{ .context_kind = .local, .cwd = "/w", .token = token, .headless = true });
    try testing.expectEqualStrings("stdio://", headless.argv[3]);
    try testing.expectEqual(@as(usize, 1), headless.env.len);

    var path: [128]u8 = undefined;
    try testing.expectEqualStrings("/h/.codex/app-server-control/app-server-control.sock", try daemonSocketPath(&path, "/h/.codex/"));
}

test "a TUI launched in a remote workspace keeps the PTY baseline and never dials a local daemon" {
    var stream: MemoryStream = .{ .allocator = testing.allocator };
    defer stream.deinit();
    var line = LineTransport.init(testing.allocator, stream.stream(), 1024);
    defer line.deinit();
    var codex = try CodexAdapter.init(testing.allocator, testing.io, .{ .transport = line.transport(), .cwd = "/srv" });
    defer codex.deinit();
    const a = codex.adapter();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const token = adapter_mod.CorrelationToken.fromBytes(@splat(0xcd));
    try testing.expectError(error.Unsupported, a.launch(arena_state.allocator(), .{ .context_kind = .ssh, .cwd = "/srv", .token = token, .headless = true }));
    try testing.expect(a.capabilities().attach);
    const tui = try a.launch(arena_state.allocator(), .{ .context_kind = .ssh, .cwd = "/srv", .token = token });
    try testing.expectEqualStrings("codex", tui.argv[0]);
    try testing.expectEqualStrings("/srv", tui.argv[2]);
    try testing.expectEqual(CodexAdapter.remote_capabilities, a.capabilities());
    // The owner's attach is refused as unsupported, so it stops polling
    // instead of connecting the transport.
    try testing.expectError(error.Unsupported, a.attach(.{ .session = @enumFromInt(1), .token = token }));
    try testing.expect(!codex.connected);
    try testing.expectEqual(@as(usize, 0), stream.output.items.len);
}

test "rollout transcripts parse incrementally into events" {
    const allocator = testing.allocator;
    const fixture = try readFixture(allocator, "rollout-0.160.1.jsonl");
    defer allocator.free(fixture);

    const Expected = struct { kind: event.Event.Kind, text: []const u8 };
    const expected = [_]Expected{
        .{ .kind = .status_change, .text = "working" },
        .{ .kind = .message, .text = "RUNTOOL" },
        .{ .kind = .tool_use, .text = "touch probe_file" },
        .{ .kind = .message, .text = "MOCK_OK" },
        .{ .kind = .status_change, .text = "done" },
    };
    // Whole file, then one byte at a time: the same events.
    for ([_]usize{ fixture.len, 1, 97 }) |chunk| {
        var reader = RolloutReader.init(allocator, RolloutReader.default_max_line_bytes);
        defer reader.deinit();
        var got: usize = 0;
        var offset: usize = 0;
        while (offset < fixture.len) {
            const end = @min(offset + chunk, fixture.len);
            try reader.feed(fixture[offset..end]);
            offset = end;
            while (reader.next()) |ev| : (got += 1) {
                try testing.expect(got < expected.len);
                try testing.expectEqual(expected[got].kind, std.meta.activeTag(ev));
                switch (ev) {
                    .status_change => |s| try testing.expectEqualStrings(expected[got].text, @tagName(s.state)),
                    .message => |m| try testing.expectEqualStrings(expected[got].text, m.text),
                    .tool_use => |t| {
                        try testing.expectEqualStrings("exec_command", t.name);
                        try testing.expectEqualStrings(expected[got].text, t.summary);
                    },
                    else => return error.TestUnexpectedResult,
                }
            }
        }
        try testing.expectEqual(expected.len, got);
        try testing.expectEqualStrings("01a11761-7199-7210-9bcb-3b1de60db841", reader.sessionId().?);
        try testing.expectEqualStrings("/work/proj", reader.cwd().?);
        try testing.expectEqualStrings("0.160.1", reader.cliVersion().?);
        try testing.expectEqual(@as(u64, 0), reader.skipped_lines);
    }

    // Oversized and malformed lines are skipped; the next line still parses.
    var reader = RolloutReader.init(allocator, 64);
    defer reader.deinit();
    try reader.feed("{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"");
    try reader.feed("x" ** 100 ++ "\"}]}}\nnot json\n");
    try reader.feed("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n");
    try testing.expectEqual(State.working, reader.next().?.status_change.state);
    try testing.expect(reader.next() == null);
    try testing.expectEqual(@as(u64, 2), reader.skipped_lines);
    try testing.expect(reader.pending.capacity <= 256);

    var wide = RolloutReader.init(allocator, 4096);
    defer wide.deinit();
    try wide.feed("{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"shell\",\"arguments\":\"{\\\"command\\\":[\\\"ls\\\",\\\"-la\\\"]}\"}}\n");
    try wide.feed("{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"<user_instructions>\\nbe terse\\n</user_instructions>\"}]}}\n");
    try wide.feed("{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"<b>bold</b> is fine\"}]}}\n");
    try wide.feed("{\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\"}}\n");
    try testing.expectEqualStrings("ls -la", wide.next().?.tool_use.summary);
    try testing.expectEqualStrings("<b>bold</b> is fine", wide.next().?.message.text);
    try testing.expectEqual(State.idle, wide.next().?.status_change.state);
    try testing.expect(wide.next() == null);
}

// Integration: a fake app-server daemon on a real Unix socket ---------------

const FakeDaemon = struct {
    listen_fd: std.posix.fd_t,
    reply: [256]u8 = undefined,
    reply_len: usize = 0,
    failure: ?[]const u8 = null,

    fn readExact(fd: std.posix.fd_t, buffer: []u8) !void {
        var got: usize = 0;
        while (got < buffer.len) {
            const n = try std.posix.read(fd, buffer[got..]);
            if (n == 0) return error.EndOfStream;
            got += n;
        }
    }

    fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len != 0) {
            const rc = std.posix.system.write(fd, rest.ptr, rest.len);
            if (std.posix.errno(rc) != .SUCCESS) return error.WriteFailed;
            rest = rest[@intCast(rc)..];
        }
    }

    /// One masked client text frame, unmasked into `buffer`.
    fn readFrame(fd: std.posix.fd_t, buffer: []u8) ![]u8 {
        var head: [2]u8 = undefined;
        try readExact(fd, &head);
        if (head[1] & 0x80 == 0) return error.Unmasked;
        var len: usize = head[1] & 0x7f;
        if (len == 126) {
            var ext: [2]u8 = undefined;
            try readExact(fd, &ext);
            len = std.mem.readInt(u16, &ext, .big);
        } else if (len == 127) return error.TooLong;
        var mask: [4]u8 = undefined;
        try readExact(fd, &mask);
        if (len > buffer.len) return error.TooLong;
        try readExact(fd, buffer[0..len]);
        for (buffer[0..len], 0..) |*b, i| b.* ^= mask[i % 4];
        return buffer[0..len];
    }

    fn sendText(fd: std.posix.fd_t, text: []const u8) !void {
        var frame_buffer: [8192]u8 = undefined;
        var header_len: usize = 2;
        frame_buffer[0] = 0x81;
        if (text.len < 126) {
            frame_buffer[1] = @intCast(text.len);
        } else {
            frame_buffer[1] = 126;
            std.mem.writeInt(u16, frame_buffer[2..4], @intCast(text.len), .big);
            header_len = 4;
        }
        @memcpy(frame_buffer[header_len..][0..text.len], text);
        try writeAll(fd, frame_buffer[0 .. header_len + text.len]);
    }

    fn idOf(request: []const u8) []const u8 {
        const start = (std.mem.indexOf(u8, request, "\"id\":") orelse return "0") + 5;
        var end = start;
        while (end < request.len and std.ascii.isDigit(request[end])) end += 1;
        return request[start..end];
    }

    fn run(self: *FakeDaemon) void {
        self.serve() catch |err| {
            self.failure = @errorName(err);
        };
    }

    fn serve(self: *FakeDaemon) !void {
        const accepted = std.posix.system.accept(self.listen_fd, null, null);
        if (std.posix.errno(accepted) != .SUCCESS) return error.AcceptFailed;
        const fd: std.posix.fd_t = @intCast(accepted);
        defer _ = std.posix.system.close(fd);

        // The opening handshake.
        var request: [2048]u8 = undefined;
        var used: usize = 0;
        while (std.mem.indexOf(u8, request[0..used], "\r\n\r\n") == null) {
            const n = try std.posix.read(fd, request[used..]);
            if (n == 0) return error.EndOfStream;
            used += n;
        }
        const marker = "Sec-WebSocket-Key: ";
        const key_start = (std.mem.indexOf(u8, request[0..used], marker) orelse return error.NoKey) + marker.len;
        const key_end = std.mem.indexOfPos(u8, request[0..used], key_start, "\r\n") orelse return error.NoKey;
        var accept_buffer: [28]u8 = undefined;
        const accept = WebSocketTransport.acceptFor(request[key_start..key_end], &accept_buffer);
        var response: [256]u8 = undefined;
        try writeAll(fd, try std.fmt.bufPrint(&response, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept}));

        var buffer: [8192]u8 = undefined;
        var out: [8192]u8 = undefined;
        while (true) {
            const message = try readFrame(fd, &buffer);
            if (std.mem.indexOf(u8, message, "\"method\":\"initialized\"") != null) continue;
            const id = idOf(message);
            if (std.mem.indexOf(u8, message, "\"method\":\"initialize\"") != null) {
                try sendText(fd, try std.fmt.bufPrint(&out, "{{\"id\":{s},\"result\":{s}}}", .{ id, default_init_result }));
            } else if (std.mem.indexOf(u8, message, "\"method\":\"thread/loaded/list\"") != null) {
                try sendText(fd, try std.fmt.bufPrint(&out, "{{\"id\":{s},\"result\":{{\"data\":[\"th-1\"]}}}}", .{id}));
            } else if (std.mem.indexOf(u8, message, "\"method\":\"thread/list\"") != null) {
                try sendText(fd, try std.fmt.bufPrint(&out, "{{\"id\":{s},\"result\":{{\"data\":[{{\"id\":\"th-1\",\"cwd\":\"/work/proj\"}}]}}}}", .{id}));
            } else if (std.mem.indexOf(u8, message, "\"method\":\"thread/resume\"") != null) {
                try sendText(fd, try std.fmt.bufPrint(&out, "{{\"id\":{s},\"result\":{{\"thread\":{{\"id\":\"th-1\",\"status\":{{\"type\":\"active\",\"activeFlags\":[\"waitingOnApproval\"]}}}}}}}}", .{id}));
                // The daemon replays the pending approval; a long reason
                // takes the 16-bit length path.
                try sendText(fd, "{\"id\":0,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"threadId\":\"th-1\",\"turnId\":\"u\",\"itemId\":\"call_1\",\"startedAtMs\":1,\"command\":\"/bin/bash -lc 'touch probe_file'\",\"reason\":\"" ++ "r" ** 200 ++ "\",\"availableDecisions\":[\"accept\",\"cancel\"]}}");
            } else if (std.mem.startsWith(u8, message, "{\"id\":0,\"result\"")) {
                @memcpy(self.reply[0..message.len], message);
                self.reply_len = message.len;
                try sendText(fd, "{\"method\":\"serverRequest/resolved\",\"params\":{\"threadId\":\"th-1\",\"requestId\":0}}");
                try sendText(fd, "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"th-1\",\"status\":{\"type\":\"active\",\"activeFlags\":[]}}}");
                try sendText(fd, "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"th-1\",\"status\":{\"type\":\"idle\"}}}");
                try sendText(fd, "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"th-1\",\"turn\":{\"id\":\"u\",\"status\":\"completed\"}}}");
                // Close normally.
                try writeAll(fd, &.{ 0x88, 0x02, 0x03, 0xe8 });
                // Wait for the client's close echo; an early EOF is an
                // equally final end, so its error is not a failure here.
                var head: [2]u8 = undefined;
                readExact(fd, &head) catch {};
                return;
            } else return error.UnexpectedRequest;
        }
    }
};

/// The wait between polls of a real socket or child, inside loops bounded by
/// a condition and a deadline.
fn pause(ms: i64) void {
    // A cancelled sleep only shortens one wait; the caller's deadline still
    // bounds the loop, so the error carries nothing to act on.
    std.Io.sleep(testing.io, .fromMilliseconds(ms), .awake) catch {};
}

/// Poll until `done` says so, for at most about `limit_ms`.
fn pollUntil(a: adapter_mod.Adapter, queue: *event.EventQueue, out: []event.StoredEvent, collected: *std.ArrayList(event.Event.Kind), arena: Allocator, limit_ms: u32, comptime done: fn ([]const event.Event.Kind) bool) !void {
    var waited: u32 = 0;
    while (!done(collected.items)) {
        _ = a.poll(queue) catch |err| switch (err) {
            error.Disconnected => {},
            else => return err,
        };
        const n = queue.drain(out);
        for (out[0..n]) |stored| try collected.append(arena, std.meta.activeTag(stored.event));
        if (n == 0) {
            if (waited >= limit_ms) return error.Timeout;
            pause(10);
            waited += 10;
        }
    }
}

fn hasRequest(kinds: []const event.Event.Kind) bool {
    return std.mem.indexOfScalar(event.Event.Kind, kinds, .permission_request) != null;
}

fn hasResolution(kinds: []const event.Event.Kind) bool {
    return std.mem.indexOfScalar(event.Event.Kind, kinds, .permission_resolved) != null and kinds[kinds.len - 1] == .status_change;
}

test "end to end over a Unix socket: websocket daemon, approval answered" {
    if (comptime !posix_streams) return error.SkipZigTest;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/d.sock", .{tmp.sub_path});

    const posix = std.posix;
    const listen_result = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(listen_result));
    const listen_fd: posix.fd_t = @intCast(listen_result);
    defer _ = posix.system.close(listen_fd);
    var address: posix.sockaddr.un = std.mem.zeroes(posix.sockaddr.un);
    address.family = posix.AF.UNIX;
    @memcpy(address.path[0..path.len], path);
    const address_len: posix.socklen_t = @intCast(@offsetOf(posix.sockaddr.un, "path") + path.len + 1);
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(posix.system.bind(listen_fd, @ptrCast(&address), address_len)));
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(posix.system.listen(listen_fd, 1)));

    var daemon: FakeDaemon = .{ .listen_fd = listen_fd };
    const thread = try std.Thread.spawn(.{}, FakeDaemon.run, .{&daemon});
    var joined = false;
    defer if (!joined) {
        // Wake a daemon still blocked in accept, then wait for it.
        _ = posix.system.shutdown(listen_fd, posix.SHUT.RDWR);
        thread.join();
    };

    var fd_stream = try FdStream.connectUnix(path);
    var ws = WebSocketTransport.init(allocator, fd_stream.stream(), .{ .seed = @splat(0x5a) });
    defer ws.deinit();
    var codex = try CodexAdapter.init(allocator, testing.io, .{
        .transport = ws.transport(),
        .mode = .daemon,
        .cwd = "/work/proj",
        .cli_version = "codex-cli 0.160.1",
    });
    defer codex.deinit();
    const a = codex.adapter();
    try a.attach(.{ .session = .first, .token = .fromBytes(@splat(4)) });
    try testing.expectEqualStrings("th-1", codex.threadId().?);

    var queue = try event.EventQueue.init(allocator, testing.io, 16);
    defer queue.deinit(allocator);
    const out = try allocator.alloc(event.StoredEvent, 16);
    defer allocator.free(out);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var kinds: std.ArrayList(event.Event.Kind) = .empty;
    try pollUntil(a, &queue, out, &kinds, arena_state.allocator(), 5000, hasRequest);
    try a.respondPermission("0", "accept");
    try pollUntil(a, &queue, out, &kinds, arena_state.allocator(), 5000, hasResolution);
    // After the daemon's close the channel reports itself gone.
    var gone = false;
    for (0..500) |_| {
        _ = a.poll(&queue) catch |err| {
            try testing.expectEqual(error.Disconnected, err);
            gone = true;
            break;
        };
        pause(10);
    }
    try testing.expect(gone);
    thread.join();
    joined = true;
    if (daemon.failure) |failure| {
        test_log.warn("fake daemon failed: {s}", .{failure});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings("{\"id\":0,\"result\":{\"decision\":\"accept\"}}", daemon.reply[0..daemon.reply_len]);
    const Kind = event.Event.Kind;
    try testing.expectEqualSlices(Kind, &.{ .status_change, .permission_request, .permission_resolved, .status_change }, kinds.items);
}

// Integration: the installed codex binary ------------------------------------

const RealAppServer = struct {
    child: std.process.Child,
    fd_stream: FdStream,
    line: LineTransport,
    env: std.process.Environ.Map,

    /// Start `codex app-server --listen stdio://` with `codex_home`, or skip
    /// the test when codex is not installed.
    fn start(self: *RealAppServer, allocator: Allocator, codex_home: []const u8, cwd: ?[]const u8) !void {
        self.env = try testing.environ.createMap(allocator);
        errdefer self.env.deinit();
        try self.env.put("CODEX_HOME", codex_home);
        self.child = std.process.spawn(testing.io, .{
            .argv = &.{ "codex", "app-server", "--listen", "stdio://" },
            .environ_map = &self.env,
            .cwd = if (cwd) |dir| .{ .path = dir } else .inherit,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
        self.fd_stream = FdStream.fromPipes(self.child.stdout.?.handle, self.child.stdin.?.handle, false);
        self.line = LineTransport.init(allocator, self.fd_stream.stream(), default_max_message_bytes);
    }

    fn stop(self: *RealAppServer) void {
        self.line.deinit();
        self.child.kill(testing.io);
        self.env.deinit();
    }
};

fn absoluteTmpPath(allocator: Allocator, tmp: *const testing.TmpDir, name: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(testing.io, allocator);
    defer allocator.free(cwd);
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}/{s}", .{ cwd, tmp.sub_path, name });
}

test "the installed codex app-server completes the initialize handshake" {
    if (comptime !posix_streams) return error.SkipZigTest;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // An isolated home whose model provider is a closed local port, so even
    // a stray model call could not leave the machine. Only `initialize` runs.
    try tmp.dir.createDir(testing.io, "home", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "home/config.toml", .data = "model = \"none\"\nmodel_provider = \"none\"\n[model_providers.none]\nname = \"none\"\nbase_url = \"http://127.0.0.1:9/v1\"\nwire_api = \"responses\"\n" });
    const home = try absoluteTmpPath(allocator, &tmp, "home");
    defer allocator.free(home);

    var server: RealAppServer = undefined;
    try server.start(allocator, home, null);
    defer server.stop();
    var codex = try CodexAdapter.init(allocator, testing.io, .{ .transport = server.line.transport(), .mode = .stdio, .cwd = home });
    defer codex.deinit();
    codex.handshake() catch |err| {
        // A codex outside the tested range must be refused, not guessed at.
        try testing.expectEqual(error.Protocol, err);
        try testing.expect(codex.gated);
        return;
    };
    const version = codex.server_version.?;
    try testing.expect(versionSupported(version));
    test_log.debug("handshake with app-server {d}.{d}.{d}", .{ version.major, version.minor, version.patch });
}

test "with a mock-provider CODEX_HOME, a real approval round trip" {
    // Opt-in: `CONDUIT_CODEX_MOCK_HOME` names a CODEX_HOME whose model
    // provider is a local mock that asks for one shell command when the
    // prompt is RUNTOOL, and `CONDUIT_CODEX_MOCK_CWD` a trusted project
    // directory. Never set by CI; never points at a real account.
    if (comptime !posix_streams) return error.SkipZigTest;
    const allocator = testing.allocator;
    var env = try testing.environ.createMap(allocator);
    defer env.deinit();
    const home = env.get("CONDUIT_CODEX_MOCK_HOME") orelse return error.SkipZigTest;
    const cwd = env.get("CONDUIT_CODEX_MOCK_CWD") orelse return error.SkipZigTest;

    var server: RealAppServer = undefined;
    try server.start(allocator, home, cwd);
    defer server.stop();
    var codex = try CodexAdapter.init(allocator, testing.io, .{ .transport = server.line.transport(), .mode = .stdio, .cwd = cwd, .call_timeout_ms = 30_000 });
    defer codex.deinit();
    const a = codex.adapter();
    try a.attach(.{ .session = .first, .token = .fromBytes(@splat(2)) });
    try a.sendInput("RUNTOOL");

    var queue = try event.EventQueue.init(allocator, testing.io, 32);
    defer queue.deinit(allocator);
    const out = try allocator.alloc(event.StoredEvent, 32);
    defer allocator.free(out);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var kinds: std.ArrayList(event.Event.Kind) = .empty;
    var reg = registry_mod.Registry.init(allocator);
    defer reg.deinit();
    const agent_id = try reg.create(.{
        .binding = .{ .workspace = .first, .session = session.SessionId.fromOrdinal(1), .session_kind = .agent_terminal, .scratchpad = .first },
        .harness = .codex,
        .ownership = .owned,
        .token = .fromBytes(@splat(2)),
    });
    var request_id: RequestIdText = .{};
    var waited: u32 = 0;
    var answered = false;
    while (waited < 60_000) {
        _ = try a.poll(&queue);
        const n = queue.drain(out);
        for (out[0..n]) |*stored| {
            try kinds.append(arena_state.allocator(), std.meta.activeTag(stored.event));
            _ = try reg.apply(agent_id, stored.event);
            if (stored.event == .permission_request) _ = request_id.set(stored.event.permission_request.id);
        }
        if (!answered and !request_id.isEmpty()) {
            try a.respondPermission(request_id.slice(), "accept");
            answered = true;
        }
        if (answered and reg.get(agent_id).?.state == .done) break;
        if (n == 0) {
            pause(20);
            waited += 20;
        }
    }
    try testing.expect(answered);
    try testing.expectEqual(State.done, reg.get(agent_id).?.state);
    try testing.expect(std.mem.indexOfScalar(event.Event.Kind, kinds.items, .permission_resolved) != null);
    try testing.expect(std.mem.indexOfScalar(event.Event.Kind, kinds.items, .tool_use) != null);
}

test "with a live codex daemon, a hand-started TUI is found and its approval answered" {
    // Opt-in: `CONDUIT_CODEX_DAEMON_HOME` is an isolated CODEX_HOME whose
    // shared daemon runs a TUI started by hand (outside Conduit) in
    // `CONDUIT_CODEX_DAEMON_CWD`, blocked on a command approval from a local
    // mock provider. Never set by CI; never a real account's home.
    if (comptime !posix_streams) return error.SkipZigTest;
    const allocator = testing.allocator;
    var env = try testing.environ.createMap(allocator);
    defer env.deinit();
    const home = env.get("CONDUIT_CODEX_DAEMON_HOME") orelse return error.SkipZigTest;
    const cwd = env.get("CONDUIT_CODEX_DAEMON_CWD") orelse return error.SkipZigTest;

    var path_buffer: [256]u8 = undefined;
    var fd_stream = try FdStream.connectUnix(try daemonSocketPath(&path_buffer, home));
    var ws = WebSocketTransport.init(allocator, fd_stream.stream(), .{ .seed = @splat(0x33) });
    defer ws.deinit();
    var codex = try CodexAdapter.init(allocator, testing.io, .{
        .transport = ws.transport(),
        .mode = .daemon,
        .cwd = cwd,
        .cli_version = "codex-cli 0.160.1",
    });
    defer codex.deinit();
    const a = codex.adapter();
    try a.attach(.{ .session = .first, .token = .fromBytes(@splat(5)) });

    var queue = try event.EventQueue.init(allocator, testing.io, 32);
    defer queue.deinit(allocator);
    const out = try allocator.alloc(event.StoredEvent, 32);
    defer allocator.free(out);
    var reg = registry_mod.Registry.init(allocator);
    defer reg.deinit();
    const agent_id = try reg.create(.{
        .binding = .{ .workspace = .first, .session = session.SessionId.fromOrdinal(2), .session_kind = .human_terminal, .scratchpad = .first },
        .harness = .codex,
        .ownership = .observed,
        .token = .fromBytes(@splat(5)),
    });
    var request_id: RequestIdText = .{};
    var answered = false;
    var resolved = false;
    var waited: u32 = 0;
    while (waited < 60_000) {
        _ = try a.poll(&queue);
        const n = queue.drain(out);
        for (out[0..n]) |*stored| {
            _ = try reg.apply(agent_id, stored.event);
            switch (stored.event) {
                .permission_request => |r| _ = request_id.set(r.id),
                .permission_resolved => resolved = true,
                else => {},
            }
            test_log.debug("live event {s} -> {s}", .{ @tagName(std.meta.activeTag(stored.event)), reg.get(agent_id).?.state.label() });
        }
        if (!answered and !request_id.isEmpty()) {
            try a.respondPermission(request_id.slice(), "accept");
            answered = true;
        }
        if (resolved and reg.get(agent_id).?.state == .done) break;
        if (n == 0) {
            pause(20);
            waited += 20;
        }
    }
    try testing.expect(answered);
    try testing.expect(resolved);
    try testing.expectEqual(State.done, reg.get(agent_id).?.state);
}

/// An ExecutionContext whose `run` returns one scripted outcome and records
/// the request.
const ScriptedRunContext = struct {
    outcome: union(enum) {
        result: struct { exit_code: ?u8, stdout: []const u8 = "" },
        fail: workspace.RunError,
    },
    argv: [4][]const u8 = undefined,
    argc: usize = 0,
    cwd: []const u8 = "",
    max_output: usize = 0,
    timeout_ms: u32 = 0,

    const vtable: workspace.ExecutionContext.VTable = .{
        .spawn = spawn,
        .kind = kind,
        .destroy = destroy,
        .run = run,
    };

    fn ref(self: *ScriptedRunContext) workspace.ExecutionContext.Ref {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // `agent` does not import `pty`; the spawn entry's types come from the
    // vtable's own function type.
    const spawn_fn = @typeInfo(@typeInfo(workspace.ExecutionContext.SpawnFn).pointer.child).@"fn";

    fn spawn(_: *anyopaque, _: spawn_fn.params[1].type.?) spawn_fn.return_type.? {
        return error.SystemError;
    }

    fn kind(_: *const anyopaque) workspace.ExecutionContextKind {
        return .ssh;
    }

    fn destroy(_: *anyopaque) void {}

    fn run(ptr: *anyopaque, allocator: Allocator, _: std.Io, request: workspace.RunRequest) workspace.RunError!workspace.RunResult {
        const self: *ScriptedRunContext = @ptrCast(@alignCast(ptr));
        // Only string literals and adapter-owned strings that outlive the
        // test's reads are recorded.
        self.argc = @min(request.argv.len, self.argv.len);
        @memcpy(self.argv[0..self.argc], request.argv[0..self.argc]);
        self.cwd = request.cwd;
        self.max_output = request.max_output;
        self.timeout_ms = request.timeout_ms;
        switch (self.outcome) {
            .fail => |err| return err,
            .result => |r| {
                const stdout = try allocator.dupe(u8, r.stdout);
                errdefer allocator.free(stdout);
                return .{ .exit_code = r.exit_code, .stdout = stdout, .stderr = try allocator.dupe(u8, "") };
            },
        }
    }
};

test "detect runs codex --version through the context and sets the gate" {
    var stream: MemoryStream = .{ .allocator = testing.allocator };
    defer stream.deinit();
    var line = LineTransport.init(testing.allocator, stream.stream(), 1024);
    defer line.deinit();
    var codex = try CodexAdapter.init(testing.allocator, testing.io, .{ .transport = line.transport(), .cwd = "/work/proj" });
    defer codex.deinit();
    const a = codex.adapter();
    try testing.expect(a.capabilities().detect);
    var version: [32]u8 = undefined;

    var installed: ScriptedRunContext = .{ .outcome = .{ .result = .{ .exit_code = 0, .stdout = "codex-cli 0.160.1\n" } } };
    try testing.expectEqualStrings("0.160.1", (try a.detect(.{ .context = installed.ref(), .version_buffer = &version })).?);
    try testing.expectEqual(@as(usize, 2), installed.argc);
    try testing.expectEqualStrings("codex", installed.argv[0]);
    try testing.expectEqualStrings("--version", installed.argv[1]);
    try testing.expectEqualStrings("/work/proj", installed.cwd);
    try testing.expectEqual(detect_max_output, installed.max_output);
    try testing.expectEqual(detect_timeout_ms, installed.timeout_ms);
    try testing.expect(!codex.gated);
    try testing.expect(a.capabilities().structured_status);

    // Not installed: the command is missing, or a shell said so.
    var missing: ScriptedRunContext = .{ .outcome = .{ .fail = error.CommandNotFound } };
    try testing.expect((try a.detect(.{ .context = missing.ref(), .version_buffer = &version })) == null);
    var shell_missing: ScriptedRunContext = .{ .outcome = .{ .result = .{ .exit_code = 127 } } };
    try testing.expect((try a.detect(.{ .context = shell_missing.ref(), .version_buffer = &version })) == null);

    // Probe failures are reported, not guessed.
    var failing: ScriptedRunContext = .{ .outcome = .{ .result = .{ .exit_code = 1, .stdout = "codex-cli 0.160.1\n" } } };
    try testing.expectError(error.Protocol, a.detect(.{ .context = failing.ref(), .version_buffer = &version }));
    var slow: ScriptedRunContext = .{ .outcome = .{ .fail = error.Timeout } };
    try testing.expectError(error.Protocol, a.detect(.{ .context = slow.ref(), .version_buffer = &version }));
    var no_run: ScriptedRunContext = .{ .outcome = .{ .fail = error.Unsupported } };
    try testing.expectError(error.Unsupported, a.detect(.{ .context = no_run.ref(), .version_buffer = &version }));
    var tight: [4]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, a.detect(.{ .context = installed.ref(), .version_buffer = &tight }));
    try testing.expect(!codex.gated);

    // A newer codex than tested: installed, but heuristics only.
    var newer: ScriptedRunContext = .{ .outcome = .{ .result = .{ .exit_code = 0, .stdout = "codex-cli 0.170.2\n" } } };
    try testing.expectEqualStrings("0.170.2", (try a.detect(.{ .context = newer.ref(), .version_buffer = &version })).?);
    try testing.expect(codex.gated);
    try testing.expect(!a.capabilities().structured_status);
    try testing.expect(a.capabilities().detect);
    try testing.expectError(error.Protocol, a.attach(.{ .session = .first, .token = .fromBytes(@splat(1)) }));

    // Junk output names no version: refused, and the adapter stays gated.
    var junk: ScriptedRunContext = .{ .outcome = .{ .result = .{ .exit_code = 0, .stdout = "codex-cli 0.160.1;rm -rf /\n" } } };
    try testing.expectError(error.Protocol, a.detect(.{ .context = junk.ref(), .version_buffer = &version }));
    try testing.expect(codex.gated);

    // A supported probe lifts the gate again.
    try testing.expectEqualStrings("0.160.1", (try a.detect(.{ .context = installed.ref(), .version_buffer = &version })).?);
    try testing.expect(!codex.gated);
}

test "codex --version output parses strictly" {
    try testing.expectEqual(Version{ .major = 0, .minor = 160, .patch = 1 }, parseVersionOutput("codex-cli 0.160.1\n").?);
    try testing.expectEqual(Version{ .major = 0, .minor = 161, .patch = 0 }, parseVersionOutput("  codex-cli v0.161.0-alpha.2\r\nextra\n").?);
    try testing.expectEqual(Version{ .major = 1, .minor = 2, .patch = 3 }, parseVersionOutput("codex/1.2.3").?);
    try testing.expect(parseVersionOutput("") == null);
    try testing.expect(parseVersionOutput("codex-cli\n") == null);
    try testing.expect(parseVersionOutput("codex-cli 0.160\n") == null);
    try testing.expect(parseVersionOutput("codex-cli 0.160.1;x\n") == null);
    try testing.expect(parseVersionOutput("codex-cli " ++ "9" ** 300 ++ "\n") == null);
}
