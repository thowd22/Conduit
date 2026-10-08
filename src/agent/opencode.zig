//! The OpenCode adapter (TASK-78, decision-7).
//!
//! OpenCode's TUI runs in a Conduit PTY like every harness. Its structured
//! side channel is the HTTP server the TUI itself starts when it is given a
//! `--port`: a Server-Sent Events stream at `GET /event` plus JSON routes to
//! answer permissions, send prompts, abort a turn and read a session's
//! messages. This file is a minimal HTTP/1.1 + SSE client for that server and
//! the mapping from OpenCode's events onto `agent.Event`.
//!
//! Provenance. OpenCode is not installed on the development machine; it is
//! verified live only inside a throwaway ubuntu:24.04 container
//! (`scripts/opencode-container-check.sh`, npm `opencode-ai@1.18.35`, a fixed
//! local model from `scripts/opencode-mock-provider.py`). Observed there on
//! 2026-10-08: `opencode --version` prints `1.18.35`; `/event` serves
//! `data: {"id","type","properties"}` frames starting with `server.connected`
//! and, per turn, `session.created`/`session.updated`, `message.updated`,
//! `message.part.updated` (parts `text`, `step-start`, `step-finish`, and
//! `tool` going pending → running → completed), `message.part.delta`
//! (`{messageID, partID, field: "text", delta}`), `session.status`
//! `busy`/`idle`, `session.idle`, `session.diff`, `permission.asked`
//! `{id, sessionID, permission, patterns, metadata, always, tool:{messageID,
//! callID}}` (sent after the tool part is already `running`),
//! `permission.replied {sessionID, requestID, reply}`, plus startup
//! `plugin.added`/`catalog.updated`/`reference.updated`/`integration.updated`
//! announcements; `POST /permission/:id/reply {"reply":"once"}` answers 200
//! `true`. `test/fixtures/agent/opencode/recorded-turn.sse` and
//! `recorded-messages.json` are that recording. Not observed live:
//! `question.asked`, subagent child sessions, `session.error`, aborts and the
//! v1 shapes, which the hand-written fixtures still cover. Before that,
//! everything was READ, on 2026-10-07, from:
//!   - https://opencode.ai/docs/server/ (flags, auth, route table);
//!   - github.com/anomalyco/opencode (formerly sst/opencode), branch `dev` at
//!     a697115 (latest release v1.18.35):
//!     `packages/opencode/src/server/routes/instance/httpapi/handlers/event.ts`
//!     (SSE framing: `data: {"id","type","properties"}`, first event
//!     `server.connected`, `server.heartbeat` every 10 s, the stream ends
//!     after `server.instance.disposed`, events filtered to the request's
//!     directory), `.../groups/permission.ts` (`POST /permission/:requestID/reply`
//!     with `{"reply":"once"|"always"|"reject","message"?}`),
//!     `.../groups/session.ts` (`/session/:sessionID/message`, `/prompt_async`,
//!     `/abort`, `/children`, and the deprecated
//!     `POST /session/:sessionID/permissions/:permissionID` with
//!     `{"response":...}`), `.../middleware/workspace-routing.ts` (the
//!     instance directory comes from `?directory=`, the
//!     `x-opencode-directory` header, or the server's cwd),
//!     `packages/opencode/src/cli/cmd/tui.ts` (the TUI accepts `--port`,
//!     `--hostname` and `--prompt`; with `--port` it serves externally and
//!     authenticates with `OPENCODE_SERVER_PASSWORD`);
//!   - the v1 and v2 SDK `types.gen.ts` (event payloads: `session.status`
//!     `{sessionID, status:{type:"idle"|"busy"|"retry",...}}`,
//!     `session.idle`, `session.error {sessionID?, error?:{name,data}}`,
//!     `permission.asked {id, sessionID, permission, patterns, always,...}`,
//!     v1 `permission.updated {id, type, pattern, sessionID, title}`,
//!     `permission.replied {sessionID, requestID|permissionID, reply|response}`,
//!     `question.asked {id, sessionID, questions:[{question,...}]}`,
//!     `question.replied`/`question.rejected`, `message.updated {info}`,
//!     `message.part.updated {part, delta?}`, `session.created {info}` with
//!     `info.parentID` for child sessions, and the Part shapes `text`,
//!     `tool {tool, callID, state:{status, input, title?}}`, `file {source?}`).
//! The other fixtures there (`turn-*.sse`, `edge-cases.sse`, `messages.json`)
//! are hand-written from those shapes; the `recorded-*` ones are live.
//!
//! Gaps (also in docs/architecture.md):
//!   - `detect` runs `opencode --version` through the workspace's
//!     ExecutionContext (so it works wherever the context can run commands)
//!     and reads the version from stdout. 1.18.35 prints the bare version
//!     (`1.18.35`); the parser takes the last word of the first line.
//!   - The server is reached at 127.0.0.1 only, so the structured channel is
//!     Local-only. In SSH and WSL workspaces `launch` starts the plain TUI and
//!     the agent stays on the PTY baseline: TASK-61 carries file-based sinks
//!     over the ExecutionContext, but forwarding a TCP port is not
//!     implemented.
//!   - A manually started `opencode` without `--port` has no external server
//!     (the TUI talks to its worker in-process), so it can be attached only by
//!     the PTY heuristics. With `--port` it can be attached by port.
//!   - Read and update prompt are unsupported: instructions are files
//!     (`AGENTS.md`, `opencode.json`), not a running-session API.
//!   - Events larger than `max_event_bytes` (a `write` tool's whole file in
//!     its input, a huge tool output) are dropped and counted.
//!   - Notifications from OpenCode plugins are not consumed.
//!   - When the server becomes unreachable the adapter reports only the PTY
//!     baseline capabilities and retries with backoff, but the registry keeps
//!     ignoring heuristic status for an agent that already produced a
//!     structured event (interface note in the TASK-78 report).
//!
//! Threads: `capabilities` and `harness` read only an atomic and may be
//! called from any thread. Every other method runs on the agent's IO worker,
//! one call at a time (agent/adapter.zig); they make blocking socket calls
//! bounded by `Options.request_timeout_ns` (requests) or `Options.poll_wait_ns`
//! (one read per `poll`). Nothing here runs on the owner thread.
//!
//! Memory: `init` allocates every buffer once (SSE line and data buffers,
//! the event backlog, the read buffers); requests and event decoding use a
//! per-call arena that is reset afterwards. `deinit` frees everything.
//!
//! Safety: event text is untrusted harness output and is only copied into
//! events. `respondPermission`, `sendInput` and `stop` act on the harness and
//! are called only from an explicit user gesture (CONDUIT.md §11). The
//! launched server is bound to 127.0.0.1 and protected with HTTP basic auth
//! whose password is the agent's correlation token, so other local users and
//! processes without the child's environment cannot answer its permissions.

const std = @import("std");
const agent_adapter = @import("adapter.zig");
const event = @import("event.zig");
const state_model = @import("state.zig");
const Harness = @import("harness.zig").Harness;
const workspace = @import("workspace");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = std.json;
const State = state_model.State;
const log = std.log.scoped(.agent_opencode);

/// The largest SSE event (its joined `data:` lines) the adapter decodes.
pub const max_event_bytes = 1024 * 1024;
/// The largest HTTP response head accepted.
pub const max_head_bytes = 16 * 1024;
/// The largest request/response body accepted (the message history).
pub const max_response_bytes = 4 * 1024 * 1024;
/// How many permission requests may be pending at once; matches the registry.
pub const max_pending_permissions = 16;
/// How many child sessions (subagents) are tracked at once.
pub const max_children = 16;

/// Bounds on the `--version` probe.
pub const detect_timeout_ms = 5000;
pub const detect_max_output = 4096;
/// The longest version string `detect` accepts.
pub const max_version_bytes = 64;

const io_buffer_bytes = 64 * 1024;
const backlog_capacity = 64;
/// One OpenCode event maps to at most this many agent events (session idle
/// cancelling every pending permission, then `done`).
const backlog_reserve = max_pending_permissions + 4;
const seen_capacity = 512;
const role_capacity = 64;

/// The server's basic-auth user name. `OPENCODE_SERVER_USERNAME` defaults to
/// it; `launch` sets it explicitly so a user's own export cannot change it.
pub const server_username = "opencode";
/// The loopback address the server is told to bind and the adapter dials.
pub const server_host = "127.0.0.1";

// Transport -------------------------------------------------------------------

/// Transport failures, mapped onto `agent.AdapterError` by the adapter.
pub const TransportError = error{
    /// Nothing is listening (the server has not started or has gone).
    Unreachable,
    /// The connection broke.
    Disconnected,
    /// No bytes arrived within the read's wait.
    WouldBlock,
    OutOfMemory,
};

/// One byte stream to the server. `read` waits at most `wait_ns` and returns
/// 0 at end of stream.
pub const Connection = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (*anyopaque, []const u8) TransportError!void,
        read: *const fn (*anyopaque, []u8, u64) TransportError!usize,
        close: *const fn (*anyopaque) void,
    };

    pub fn write(self: Connection, bytes: []const u8) TransportError!void {
        return self.vtable.write(self.ptr, bytes);
    }

    pub fn read(self: Connection, buffer: []u8, wait_ns: u64) TransportError!usize {
        return self.vtable.read(self.ptr, buffer, wait_ns);
    }

    /// Close and release the connection. It must not be used afterwards.
    pub fn close(self: Connection) void {
        self.vtable.close(self.ptr);
    }
};

/// Opens connections to one server. Tests inject a fake; production uses
/// `TcpTransport`.
pub const Transport = struct {
    ptr: *anyopaque,
    connect_fn: *const fn (*anyopaque) TransportError!Connection,

    pub fn connect(self: Transport) TransportError!Connection {
        return self.connect_fn(self.ptr);
    }
};

/// TCP to 127.0.0.1:`port` through `std.Io`.
pub const TcpTransport = struct {
    allocator: Allocator,
    io: Io,
    port: u16,

    pub fn transport(self: *TcpTransport) Transport {
        return .{ .ptr = self, .connect_fn = connect };
    }

    fn connect(ptr: *anyopaque) TransportError!Connection {
        const self: *TcpTransport = @ptrCast(@alignCast(ptr));
        // A literal dotted quad always parses.
        const address = Io.net.IpAddress.parseIp4(server_host, self.port) catch unreachable;
        const stream = address.connect(self.io, .{ .mode = .stream }) catch |err| {
            log.debug("connect to port {d} failed: {s}", .{ self.port, @errorName(err) });
            return error.Unreachable;
        };
        const connection = self.allocator.create(TcpConnection) catch {
            stream.close(self.io);
            return error.OutOfMemory;
        };
        connection.* = .{ .allocator = self.allocator, .io = self.io, .stream = stream };
        return .{ .ptr = connection, .vtable = &TcpConnection.vtable };
    }
};

const TcpConnection = struct {
    allocator: Allocator,
    io: Io,
    stream: Io.net.Stream,

    const vtable: Connection.VTable = .{ .write = write, .read = read, .close = close };

    fn write(ptr: *anyopaque, bytes: []const u8) TransportError!void {
        const self: *TcpConnection = @ptrCast(@alignCast(ptr));
        var writer = self.stream.writer(self.io, &.{});
        writer.interface.writeAll(bytes) catch return error.Disconnected;
    }

    fn read(ptr: *anyopaque, buffer: []u8, wait_ns: u64) TransportError!usize {
        const self: *TcpConnection = @ptrCast(@alignCast(ptr));
        const wait: i96 = @intCast(@min(wait_ns, std.math.maxInt(i64)));
        const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromNanoseconds(wait), .clock = .awake } };
        const message = self.stream.socket.receiveTimeout(self.io, buffer, timeout) catch |err| switch (err) {
            error.Timeout => return error.WouldBlock,
            else => {
                log.debug("read failed: {s}", .{@errorName(err)});
                return error.Disconnected;
            },
        };
        return message.data.len;
    }

    fn close(ptr: *anyopaque) void {
        const self: *TcpConnection = @ptrCast(@alignCast(ptr));
        self.stream.close(self.io);
        self.allocator.destroy(self);
    }
};

// HTTP ------------------------------------------------------------------------

pub const Method = enum { GET, POST };

/// One HTTP/1.1 request. `target` is the already-encoded path and query.
pub const Request = struct {
    method: Method,
    target: []const u8,
    port: u16,
    /// The full `Authorization` value (`Basic ...`), when the server has one.
    authorization: ?[]const u8 = null,
    accept: []const u8 = "application/json",
    /// A JSON body.
    body: ?[]const u8 = null,
};

/// Write `request` in HTTP/1.1 wire form. Every request asks the server to
/// close the connection after its response, so a response ends at the
/// connection's end at the latest.
pub fn writeRequest(writer: *Io.Writer, request: Request) Io.Writer.Error!void {
    try writer.print("{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\nAccept: {s}\r\nConnection: close\r\n", .{
        @tagName(request.method), request.target, server_host, request.port, request.accept,
    });
    if (request.authorization) |value| try writer.print("Authorization: {s}\r\n", .{value});
    if (request.body) |body| {
        try writer.print("Content-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{body.len});
        try writer.writeAll(body);
    } else if (request.method == .POST) {
        try writer.writeAll("Content-Length: 0\r\n\r\n");
    } else {
        try writer.writeAll("\r\n");
    }
}

/// A piece of a request target: literal path text, or an untrusted value
/// written as one percent-encoded path segment.
pub const TargetPart = union(enum) { literal: []const u8, segment: []const u8 };

/// Write a request target from `parts`, adding `?directory=` (or
/// `&directory=` after a query) when the instance directory is known.
pub fn writeTarget(writer: *Io.Writer, parts: []const TargetPart, directory: ?[]const u8) Io.Writer.Error!void {
    var has_query = false;
    for (parts) |part| switch (part) {
        .literal => |text| {
            if (std.mem.indexOfScalar(u8, text, '?') != null) has_query = true;
            try writer.writeAll(text);
        },
        .segment => |text| try writePercentEncoded(writer, text),
    };
    if (directory) |dir| {
        try writer.writeAll(if (has_query) "&directory=" else "?directory=");
        try writePercentEncoded(writer, dir);
    }
}

/// RFC 3986 unreserved characters pass; every other byte is `%XX`.
pub fn writePercentEncoded(writer: *Io.Writer, bytes: []const u8) Io.Writer.Error!void {
    for (bytes) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try writer.writeByte(c),
        else => try writer.print("%{X:0>2}", .{c}),
    };
}

/// How a response body is delimited.
pub const Framing = union(enum) { length: u64, chunked, until_close };

/// A parsed response status line and the headers the adapter needs.
pub const Head = struct {
    status: u16,
    framing: Framing,
    event_stream: bool,
};

/// The offset just past the blank line ending a response head, if present.
pub fn headEnd(bytes: []const u8) ?usize {
    const end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return null;
    return end + 4;
}

/// Parse a response head (status line and headers, up to and including the
/// blank line). Untrusted input: anything unexpected is `error.Protocol`.
pub fn parseHead(bytes: []const u8) error{Protocol}!Head {
    var lines = std.mem.splitSequence(u8, bytes, "\r\n");
    const status_line = lines.next() orelse return error.Protocol;
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.")) return error.Protocol;
    var fields = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = fields.next();
    const code_text = fields.next() orelse return error.Protocol;
    if (code_text.len != 3) return error.Protocol;
    const status = std.fmt.parseInt(u16, code_text, 10) catch return error.Protocol;

    var framing: Framing = .until_close;
    var chunked = false;
    var event_stream = false;
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.Protocol;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (std.ascii.indexOfIgnoreCase(value, "chunked") != null) chunked = true;
        } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            const length = std.fmt.parseInt(u64, value, 10) catch return error.Protocol;
            framing = .{ .length = length };
        } else if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            event_stream = std.ascii.startsWithIgnoreCase(value, "text/event-stream");
        }
    }
    // Transfer-Encoding overrides Content-Length (RFC 9112 §6.3).
    if (chunked) framing = .chunked;
    if (status == 204 or status == 304 or (status >= 100 and status < 200)) framing = .{ .length = 0 };
    return .{ .status = status, .framing = framing, .event_stream = event_stream };
}

/// An incremental decoder for a response body: it removes chunked framing
/// and stops at the declared length.
pub const BodyDecoder = struct {
    framing: Framing,
    /// Bytes left in the body (length) or in the current chunk (chunked).
    remaining: u64 = 0,
    phase: Phase = .size,
    size_digits: u8 = 0,

    const Phase = enum { size, extension, size_lf, data, data_cr, data_lf, trailer, trailer_line, trailer_lf, done };

    pub const Step = struct { consumed: usize, produced: usize };

    pub fn init(framing: Framing) BodyDecoder {
        return switch (framing) {
            .length => |length| .{ .framing = framing, .remaining = length, .phase = if (length == 0) .done else .data },
            .chunked => .{ .framing = framing },
            .until_close => .{ .framing = framing, .phase = .data },
        };
    }

    /// Whether the body is complete. An `until_close` body completes only at
    /// the connection's end, which the caller observes.
    pub fn finished(self: *const BodyDecoder) bool {
        return self.phase == .done;
    }

    /// Decode from `input` into `output` and say how much of each was used.
    pub fn decode(self: *BodyDecoder, input: []const u8, output: []u8) error{Protocol}!Step {
        var in: usize = 0;
        var out: usize = 0;
        switch (self.framing) {
            .until_close => {
                const n = @min(input.len, output.len);
                @memcpy(output[0..n], input[0..n]);
                return .{ .consumed = n, .produced = n };
            },
            .length => {
                const n: usize = @intCast(@min(@min(input.len, output.len), self.remaining));
                @memcpy(output[0..n], input[0..n]);
                self.remaining -= n;
                if (self.remaining == 0) self.phase = .done;
                return .{ .consumed = n, .produced = n };
            },
            .chunked => {},
        }
        while (in < input.len and self.phase != .done) {
            const c = input[in];
            switch (self.phase) {
                .size => switch (c) {
                    '0'...'9', 'a'...'f', 'A'...'F' => {
                        if (self.size_digits == 15) return error.Protocol;
                        // `c` matched a hex digit above, so it converts.
                        self.remaining = self.remaining * 16 + (std.fmt.charToDigit(c, 16) catch unreachable);
                        self.size_digits += 1;
                        in += 1;
                    },
                    ';', ' ', '\t' => {
                        self.phase = .extension;
                        in += 1;
                    },
                    '\r' => {
                        self.phase = .size_lf;
                        in += 1;
                    },
                    '\n' => {
                        in += 1;
                        try self.endSizeLine();
                    },
                    else => return error.Protocol,
                },
                .extension => {
                    in += 1;
                    if (c == '\r') self.phase = .size_lf else if (c == '\n') try self.endSizeLine();
                },
                .size_lf => {
                    if (c != '\n') return error.Protocol;
                    in += 1;
                    try self.endSizeLine();
                },
                .data => {
                    if (out == output.len) break;
                    const n: usize = @intCast(@min(@min(input.len - in, output.len - out), self.remaining));
                    @memcpy(output[out..][0..n], input[in..][0..n]);
                    in += n;
                    out += n;
                    self.remaining -= n;
                    if (self.remaining == 0) self.phase = .data_cr;
                },
                .data_cr => {
                    in += 1;
                    if (c == '\r') {
                        self.phase = .data_lf;
                    } else if (c == '\n') {
                        self.phase = .size;
                    } else return error.Protocol;
                },
                .data_lf => {
                    if (c != '\n') return error.Protocol;
                    in += 1;
                    self.phase = .size;
                },
                .trailer => {
                    in += 1;
                    if (c == '\r') {
                        self.phase = .trailer_lf;
                    } else if (c == '\n') {
                        self.phase = .done;
                    } else self.phase = .trailer_line;
                },
                .trailer_line => {
                    in += 1;
                    if (c == '\n') self.phase = .trailer;
                },
                .trailer_lf => {
                    if (c != '\n') return error.Protocol;
                    in += 1;
                    self.phase = .done;
                },
                .done => unreachable,
            }
        }
        return .{ .consumed = in, .produced = out };
    }

    fn endSizeLine(self: *BodyDecoder) error{Protocol}!void {
        if (self.size_digits == 0) return error.Protocol;
        self.size_digits = 0;
        self.phase = if (self.remaining == 0) .trailer else .data;
    }
};

// Server-Sent Events -----------------------------------------------------------

/// An incremental `text/event-stream` parser (WHATWG HTML §9.2). It returns
/// at most one event per `next` call so the caller can stop between events
/// when its own buffers are full. Only `data` matters to OpenCode (the event
/// type is inside the JSON); `event`, `id`, `retry` and comments are skipped.
///
/// Memory: `line` and `data` are caller-provided and bound one line and one
/// event. A longer event is reported as `oversized` instead of its data.
pub const SseParser = struct {
    line: []u8,
    data: []u8,
    line_len: usize = 0,
    data_len: usize = 0,
    line_overflow: bool = false,
    data_overflow: bool = false,
    has_data: bool = false,
    after_cr: bool = false,

    pub const Dispatch = union(enum) {
        /// The event's joined data lines; valid until the next `next` call.
        data: []const u8,
        oversized,
    };

    pub const Step = struct { consumed: usize, dispatch: ?Dispatch = null };

    pub fn init(line: []u8, data: []u8) SseParser {
        return .{ .line = line, .data = data };
    }

    pub fn reset(self: *SseParser) void {
        self.* = .init(self.line, self.data);
    }

    pub fn next(self: *SseParser, input: []const u8) Step {
        for (input, 0..) |c, i| {
            if (self.after_cr) {
                self.after_cr = false;
                if (c == '\n') continue;
            }
            if (c == '\r' or c == '\n') {
                self.after_cr = c == '\r';
                if (self.endLine()) |dispatch| return .{ .consumed = i + 1, .dispatch = dispatch };
                continue;
            }
            if (self.line_len == self.line.len) {
                self.line_overflow = true;
            } else {
                self.line[self.line_len] = c;
                self.line_len += 1;
            }
        }
        return .{ .consumed = input.len };
    }

    fn endLine(self: *SseParser) ?Dispatch {
        defer {
            self.line_len = 0;
            self.line_overflow = false;
        }
        const line = self.line[0..self.line_len];
        if (line.len == 0 and !self.line_overflow) {
            defer {
                self.data_len = 0;
                self.has_data = false;
                self.data_overflow = false;
            }
            if (self.data_overflow) return .oversized;
            if (!self.has_data) return null;
            return .{ .data = self.data[0..self.data_len] };
        }
        if (line.len != 0 and line[0] == ':') return null;
        const colon = std.mem.indexOfScalar(u8, line, ':');
        const name = if (colon) |at| line[0..at] else line;
        if (!std.mem.eql(u8, name, "data")) return null;
        if (self.line_overflow) {
            self.data_overflow = true;
            self.has_data = true;
            return null;
        }
        var value: []const u8 = if (colon) |at| line[at + 1 ..] else "";
        if (value.len != 0 and value[0] == ' ') value = value[1..];
        const separator: usize = if (self.has_data) 1 else 0;
        if (self.data_len + separator + value.len > self.data.len) {
            self.data_overflow = true;
        } else if (!self.data_overflow) {
            if (separator == 1) {
                self.data[self.data_len] = '\n';
                self.data_len += 1;
            }
            @memcpy(self.data[self.data_len..][0..value.len], value);
            self.data_len += value.len;
        }
        self.has_data = true;
        return null;
    }
};

// Event mapping -----------------------------------------------------------------

/// A bounded identifier copy. Identifiers are never truncated (event.zig).
const Id = struct {
    bytes: [event.max_identifier_bytes]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const Id) []const u8 {
        return self.bytes[0..self.len];
    }

    fn set(self: *Id, text: []const u8) bool {
        if (text.len == 0 or text.len > self.bytes.len) return false;
        @memcpy(self.bytes[0..text.len], text);
        self.len = text.len;
        return true;
    }

    fn eql(self: *const Id, text: []const u8) bool {
        return self.len != 0 and std.mem.eql(u8, self.slice(), text);
    }
};

/// OpenCode's permission replies, which are also the decision ids the
/// adapter offers (`Decision.id`).
pub const Reply = enum {
    once,
    always,
    reject,

    pub fn parse(text: []const u8) ?Reply {
        return std.meta.stringToEnum(Reply, text);
    }
};

/// The three decisions every OpenCode permission offers, in its order.
pub const decisions = [_]event.Decision{
    .{ .id = "once", .label = "Allow once", .kind = .allow_once },
    .{ .id = "always", .label = "Always allow", .kind = .allow_always },
    .{ .id = "reject", .label = "Reject", .kind = .reject },
};

/// Agent events waiting for room in the caller's `EventQueue`. Each slot
/// deep-copies one event, so mapping can reuse its JSON arena at once.
const Backlog = struct {
    slots: []event.StoredEvent,
    head: usize = 0,
    len: usize = 0,
    /// Events refused because an identifier was too long.
    refused: u64 = 0,

    const Error = error{BacklogFull};

    fn free(self: *const Backlog) usize {
        return self.slots.len - self.len;
    }

    fn push(self: *Backlog, source: event.Event) Error!void {
        if (self.len == self.slots.len) return error.BacklogFull;
        const index = (self.head + self.len) % self.slots.len;
        self.slots[index].store(source) catch {
            self.refused += 1;
            log.debug("dropped an over-long {s} event", .{@tagName(source)});
            return;
        };
        self.len += 1;
    }

    fn front(self: *Backlog) *event.StoredEvent {
        return &self.slots[self.head];
    }

    fn pop(self: *Backlog) void {
        self.head = (self.head + 1) % self.slots.len;
        self.len -= 1;
    }
};

/// Folds OpenCode events into agent events for one top-level session (the
/// one the TUI is showing) and its child sessions (subagents). Owned by the
/// adapter; worker thread only.
const Mapper = struct {
    /// The bound top-level session; empty until adopted or attached.
    session: Id = .{},
    children: [max_children]Child = undefined,
    children_len: usize = 0,
    pending: [max_pending_permissions]Pending = undefined,
    pending_len: usize = 0,
    question_pending: bool = false,
    /// What the registry believes, mirrored so every emitted change is a legal
    /// transition (state.zig).
    tracked: State = .idle,
    /// Hashes of transcript parts already emitted, so streaming updates and a
    /// history replay emit each part once.
    seen: [seen_capacity]u64 = undefined,
    seen_len: usize = 0,
    seen_next: usize = 0,
    roles: [role_capacity]RoleEntry = undefined,
    roles_len: usize = 0,
    roles_next: usize = 0,
    /// The server announced it is shutting this instance down.
    disposed: bool = false,

    const Child = struct { id: Id, name: Id };
    const Pending = struct { id: Id, session: Id, answered: ?Reply = null };
    const RoleEntry = struct { hash: u64, role: event.Role };
    const Scope = enum { bound, child, other };

    fn bind(self: *Mapper, id: []const u8) bool {
        if (!self.session.set(id)) return false;
        self.children_len = 0;
        return true;
    }

    /// Which session `sid` is, adopting it as the bound session when none is
    /// bound yet and it is not a known child.
    fn claim(self: *Mapper, sid: ?[]const u8) Scope {
        const id = sid orelse return if (self.session.len != 0) .bound else .other;
        if (self.session.eql(id)) return .bound;
        if (self.childIndex(id) != null) return .child;
        if (self.session.len == 0 and self.bind(id)) {
            log.debug("adopted the first active session", .{});
            return .bound;
        }
        return .other;
    }

    fn childIndex(self: *const Mapper, id: []const u8) ?usize {
        for (self.children[0..self.children_len], 0..) |*child, i| {
            if (child.id.eql(id)) return i;
        }
        return null;
    }

    fn pendingIndex(self: *const Mapper, id: []const u8) ?usize {
        for (self.pending[0..self.pending_len], 0..) |*entry, i| {
            if (entry.id.eql(id)) return i;
        }
        return null;
    }

    fn removePending(self: *Mapper, index: usize) void {
        self.pending[index] = self.pending[self.pending_len - 1];
        self.pending_len -= 1;
    }

    fn status(to: State) event.Event {
        return .{ .status_change = .{ .state = to, .source = .structured } };
    }

    /// Emit a move to `to` when it is a legal change. A waiting state after a
    /// turn outcome is reached through `working`, which is what OpenCode did:
    /// it started another turn.
    fn moveTo(self: *Mapper, sink: *Backlog, to: State) Backlog.Error!void {
        if (self.tracked == to) return;
        if (!state_model.canTransition(self.tracked, to)) {
            const waiting = to == .waiting_input or to == .waiting_permission;
            if (!waiting or !state_model.canTransition(self.tracked, .working)) return;
            try sink.push(status(.working));
            self.tracked = .working;
        }
        try sink.push(status(to));
        self.tracked = to;
    }

    fn cancelPending(self: *Mapper, sink: *Backlog) Backlog.Error!void {
        while (self.pending_len != 0) {
            const entry = &self.pending[self.pending_len - 1];
            try sink.push(.{ .permission_resolved = .{ .id = entry.id.slice(), .outcome = .cancelled } });
            self.pending_len -= 1;
        }
        if (self.tracked == .waiting_permission) self.tracked = .working;
        self.question_pending = false;
    }

    fn finishTurn(self: *Mapper, sink: *Backlog) Backlog.Error!void {
        try self.cancelPending(sink);
        switch (self.tracked) {
            .working, .waiting_input, .waiting_permission => try self.moveTo(sink, .done),
            .idle, .done, .errored => {},
        }
    }

    /// Map one decoded `/event` payload. Unknown types and malformed payloads
    /// are ignored: OpenCode adds event types often.
    fn handle(self: *Mapper, arena: Allocator, sink: *Backlog, root: json.Value) (Backlog.Error || Allocator.Error)!void {
        const kind = string(field(root, "type")) orelse return;
        const props = field(root, "properties") orelse field(root, "data") orelse return;
        const Kind = enum {
            @"server.instance.disposed",
            @"session.created",
            @"session.status",
            @"session.idle",
            @"session.error",
            @"permission.asked",
            @"permission.updated",
            @"permission.replied",
            @"question.asked",
            @"question.replied",
            @"question.rejected",
            @"message.updated",
            @"message.part.updated",
        };
        const known = std.meta.stringToEnum(Kind, kind) orelse return;
        switch (known) {
            .@"server.instance.disposed" => self.disposed = true,
            .@"session.created" => try self.sessionCreated(sink, field(props, "info") orelse return),
            .@"session.status" => {
                const sid = string(field(props, "sessionID"));
                if (self.claim(sid) != .bound) return;
                const status_type = string(field(field(props, "status"), "type")) orelse return;
                if (std.mem.eql(u8, status_type, "idle")) return self.finishTurn(sink);
                if (!std.mem.eql(u8, status_type, "busy") and !std.mem.eql(u8, status_type, "retry")) return;
                // Still busy while the human is asked something: keep showing
                // the question rather than `working`.
                if (self.pending_len == 0 and !self.question_pending) try self.moveTo(sink, .working);
                if (std.mem.eql(u8, status_type, "retry")) {
                    const message = string(field(field(props, "status"), "message")) orelse "";
                    try sink.push(.{ .notification = .{ .title = "OpenCode retrying", .body = message } });
                }
            },
            .@"session.idle" => {
                const sid = string(field(props, "sessionID")) orelse return;
                if (self.childIndex(sid)) |i| {
                    const child = self.children[i];
                    self.children[i] = self.children[self.children_len - 1];
                    self.children_len -= 1;
                    return sink.push(.{ .subagent = .{ .id = child.id.slice(), .name = child.name.slice(), .phase = .stop } });
                }
                if (self.claim(sid) == .bound) try self.finishTurn(sink);
            },
            .@"session.error" => {
                if (self.claim(string(field(props, "sessionID"))) != .bound) return;
                const err = field(props, "error");
                const name = string(field(err, "name")) orelse "UnknownError";
                const message = string(field(field(err, "data"), "message")) orelse name;
                try self.cancelPending(sink);
                if (std.mem.eql(u8, name, "MessageAbortedError")) {
                    // The human interrupted the turn; nothing failed.
                    if (self.tracked != .done and self.tracked != .errored) try self.moveTo(sink, .idle);
                    return;
                }
                try self.moveTo(sink, .errored);
                try sink.push(.{ .notification = .{ .title = "OpenCode error", .body = message } });
            },
            .@"permission.asked", .@"permission.updated" => try self.permissionAsked(arena, sink, props),
            .@"permission.replied" => {
                const id = string(field(props, "requestID")) orelse string(field(props, "permissionID")) orelse return;
                const index = self.pendingIndex(id) orelse return;
                const entry = self.pending[index];
                const outcome: event.PermissionOutcome = if (entry.answered) |reply| switch (reply) {
                    .once, .always => .allowed,
                    .reject => .rejected,
                } else .resolved_elsewhere;
                self.removePending(index);
                try sink.push(.{ .permission_resolved = .{ .id = entry.id.slice(), .outcome = outcome } });
                if (self.pending_len == 0 and self.tracked == .waiting_permission) self.tracked = .working;
            },
            .@"question.asked" => {
                const scope = self.claim(string(field(props, "sessionID")));
                if (scope == .other) return;
                self.question_pending = true;
                try self.moveTo(sink, .waiting_input);
                const questions = field(props, "questions");
                const first = if (questions) |q| (if (q == .array and q.array.items.len != 0) q.array.items[0] else null) else null;
                const text = string(field(first, "question")) orelse "";
                try sink.push(.{ .notification = .{ .title = "OpenCode question", .body = text } });
            },
            .@"question.replied", .@"question.rejected" => {
                if (!self.question_pending) return;
                self.question_pending = false;
                if (self.tracked == .waiting_input) try self.moveTo(sink, .working);
            },
            .@"message.updated" => {
                const info = field(props, "info") orelse return;
                if (self.claim(string(field(info, "sessionID"))) != .bound) return;
                const id = string(field(info, "id")) orelse return;
                const role = parseRole(string(field(info, "role"))) orelse return;
                self.rememberRole(id, role);
            },
            .@"message.part.updated" => {
                const part = field(props, "part") orelse return;
                if (self.claim(string(field(part, "sessionID"))) != .bound) return;
                try self.mapPart(sink, part, null);
            },
        }
    }

    fn sessionCreated(self: *Mapper, sink: *Backlog, info: json.Value) Backlog.Error!void {
        const id = string(field(info, "id")) orelse return;
        if (string(field(info, "parentID"))) |parent| {
            if (!self.session.eql(parent) and self.childIndex(parent) == null) return;
            if (self.childIndex(id) != null) return;
            if (self.children_len == max_children) {
                log.debug("too many child sessions; one is not tracked", .{});
                return;
            }
            var child: Child = .{ .id = .{}, .name = .{} };
            if (!child.id.set(id)) return;
            const title = string(field(info, "title")) orelse "subagent";
            _ = child.name.set(event.truncateUtf8(title, event.max_identifier_bytes));
            self.children[self.children_len] = child;
            self.children_len += 1;
            try sink.push(.{ .subagent = .{ .id = child.id.slice(), .name = child.name.slice(), .phase = .start } });
            return;
        }
        // A new top-level session in this instance: the TUI started or
        // switched to it, so it is the one to follow.
        if (!self.session.eql(id)) {
            if (self.session.len != 0) log.debug("following a new top-level session", .{});
            _ = self.bind(id);
        }
    }

    fn permissionAsked(self: *Mapper, arena: Allocator, sink: *Backlog, props: json.Value) (Backlog.Error || Allocator.Error)!void {
        const sid = string(field(props, "sessionID"));
        if (self.claim(sid) == .other) return;
        const id = string(field(props, "id")) orelse return;
        if (self.pendingIndex(id) == null) {
            if (self.pending_len == max_pending_permissions) {
                log.debug("too many pending permissions; one is not tracked", .{});
                return;
            }
            var entry: Pending = .{ .id = .{}, .session = .{} };
            if (!entry.id.set(id)) return;
            if (sid) |s| _ = entry.session.set(s);
            self.pending[self.pending_len] = entry;
            self.pending_len += 1;
        }
        const title = try permissionTitle(arena, props);
        if (self.tracked == .done or self.tracked == .errored) try self.moveTo(sink, .working);
        try sink.push(.{ .permission_request = .{ .id = id, .title = title, .decisions = &decisions } });
        self.tracked = .waiting_permission;
    }

    /// Map one message part. `role` is known for history; live parts look it
    /// up from `message.updated`.
    fn mapPart(self: *Mapper, sink: *Backlog, part: json.Value, role: ?event.Role) Backlog.Error!void {
        const id = string(field(part, "id")) orelse return;
        const kind = string(field(part, "type")) orelse return;
        if (std.mem.eql(u8, kind, "text")) {
            if (boolean(field(part, "synthetic")) or boolean(field(part, "ignored"))) return;
            const text = string(field(part, "text")) orelse return;
            if (text.len == 0) return;
            const time = field(part, "time");
            // A streaming assistant part has `time.start` until it ends.
            if (time != null and field(time, "end") == null) return;
            if (!self.markSeen(id)) return;
            const message_role = role orelse
                (if (string(field(part, "messageID"))) |m| self.lookupRole(m) else null) orelse
                (if (time == null) event.Role.user else event.Role.assistant);
            return sink.push(.{ .message = .{ .role = message_role, .text = text } });
        }
        if (std.mem.eql(u8, kind, "tool")) {
            const tool_state = field(part, "state");
            const status_text = string(field(tool_state, "status")) orelse return;
            if (std.mem.eql(u8, status_text, "pending")) return;
            if (!self.markSeen(id)) return;
            const name = string(field(part, "tool")) orelse "tool";
            const input = field(tool_state, "input");
            try sink.push(.{ .tool_use = .{ .name = name, .summary = toolSummary(tool_state, input) } });
            if (string(field(input, "filePath"))) |path| try sink.push(.{ .file_reference = .{ .path = path } });
            return;
        }
        if (std.mem.eql(u8, kind, "file")) {
            const path = string(field(field(part, "source"), "path")) orelse return;
            if (!self.markSeen(id)) return;
            return sink.push(.{ .file_reference = .{ .path = path } });
        }
    }

    fn markSeen(self: *Mapper, id: []const u8) bool {
        const hash = std.hash.Wyhash.hash(0x6f70656e636f6465, id);
        for (self.seen[0..self.seen_len]) |h| if (h == hash) return false;
        self.seen[self.seen_next] = hash;
        self.seen_next = (self.seen_next + 1) % seen_capacity;
        self.seen_len = @min(self.seen_len + 1, seen_capacity);
        return true;
    }

    fn rememberRole(self: *Mapper, id: []const u8, role: event.Role) void {
        const hash = std.hash.Wyhash.hash(0, id);
        for (self.roles[0..self.roles_len]) |*entry| if (entry.hash == hash) return;
        self.roles[self.roles_next] = .{ .hash = hash, .role = role };
        self.roles_next = (self.roles_next + 1) % role_capacity;
        self.roles_len = @min(self.roles_len + 1, role_capacity);
    }

    fn lookupRole(self: *const Mapper, id: []const u8) ?event.Role {
        const hash = std.hash.Wyhash.hash(0, id);
        for (self.roles[0..self.roles_len]) |entry| if (entry.hash == hash) return entry.role;
        return null;
    }
};

/// `permission: pattern, pattern` (v2), or the v1 `title`, or the bare
/// permission name.
fn permissionTitle(arena: Allocator, props: json.Value) Allocator.Error![]const u8 {
    if (string(field(props, "title"))) |title| return title;
    const permission = string(field(props, "permission")) orelse string(field(props, "type")) orelse "permission";
    const patterns = field(props, "patterns") orelse field(props, "pattern");
    var out: Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    const w = &out.writer;
    w.writeAll(permission) catch return error.OutOfMemory;
    if (patterns) |p| switch (p) {
        .string => |s| w.print(": {s}", .{s}) catch return error.OutOfMemory,
        .array => |list| for (list.items, 0..) |item, i| {
            const s = string(item) orelse continue;
            w.writeAll(if (i == 0) ": " else ", ") catch return error.OutOfMemory;
            w.writeAll(s) catch return error.OutOfMemory;
        },
        else => {},
    };
    return out.written();
}

fn toolSummary(tool_state: ?json.Value, input: ?json.Value) []const u8 {
    if (string(field(tool_state, "title"))) |title| if (title.len != 0) return title;
    for ([_][]const u8{ "command", "filePath", "pattern", "url", "description" }) |key| {
        if (string(field(input, key))) |value| return value;
    }
    return "";
}

fn parseRole(text: ?[]const u8) ?event.Role {
    const t = text orelse return null;
    if (std.mem.eql(u8, t, "user")) return .user;
    if (std.mem.eql(u8, t, "assistant")) return .assistant;
    return null;
}

fn field(value: ?json.Value, key: []const u8) ?json.Value {
    const v = value orelse return null;
    if (v != .object) return null;
    return v.object.get(key);
}

fn string(value: ?json.Value) ?[]const u8 {
    const v = value orelse return null;
    return if (v == .string) v.string else null;
}

fn boolean(value: ?json.Value) bool {
    const v = value orelse return false;
    return v == .bool and v.bool;
}

const parse_options: json.ParseOptions = .{ .duplicate_field_behavior = .use_last, .max_value_len = max_response_bytes };

/// Whether a foreground program name (`agent.commandName`, a basename) is
/// OpenCode, for observed agents (TASK-56). npm's `opencode-ai` installs a
/// Node launcher `bin/opencode` that runs the native `opencode` binary; the
/// terminal's foreground leader is the launcher, `node .../bin/opencode`
/// (observed with 1.18.35), and a native install runs `opencode` itself.
pub fn recognizeCommand(name: []const u8) bool {
    return std.mem.eql(u8, name, "opencode");
}

// Instructions (TASK-59) -------------------------------------------------------

/// Where OpenCode reads its instructions (TASK-59), from its rules and agents
/// documentation (decision-9, unverified live): `AGENTS.md` along the project
/// hierarchy, the global `~/.config/opencode/AGENTS.md`, custom agents under
/// `.opencode/agent/`, and the `opencode.json` it owns. An edit takes effect
/// on the next session.
pub const instruction_profile: agent_adapter.InstructionProfile = .{
    .sources = &.{
        .{ .base = .project_tree, .path = "AGENTS.md", .list_missing = true },
        .{ .base = .home, .path = ".config/opencode/AGENTS.md" },
        .{ .base = .project, .path = ".opencode/agent/*.md", .kind = .subagent },
        .{ .base = .project, .path = "opencode.json", .kind = .settings },
    },
};

// The adapter -----------------------------------------------------------------

pub const Options = struct {
    /// The port the server listens on: the one `launch` passes, or the
    /// `--port` of a manually started opencode to attach to. Choosing a free
    /// port is the caller's job.
    port: u16,
    /// The executable `launch` names. Borrowed for the adapter's lifetime.
    executable: []const u8 = "opencode",
    /// The server password of a manually started opencode. Copied. When
    /// null, `launch` sets one (the correlation token).
    password: ?[]const u8 = null,
    /// The instance directory to address. Copied. When null, `launch` uses its
    /// cwd, and an attached server uses its own cwd.
    directory: ?[]const u8 = null,
    /// Overrides the TCP transport (tests).
    transport: ?Transport = null,
    /// How long one `poll` may wait for the first bytes. Zero never blocks.
    poll_wait_ns: u64 = 0,
    /// The bound on one request/response exchange.
    request_timeout_ns: u64 = 5 * std.time.ns_per_s,
    /// The most messages replayed from history on attach.
    history_limit: u16 = 32,
    reconnect_min_ns: u64 = 250 * std.time.ns_per_ms,
    reconnect_max_ns: u64 = 5 * std.time.ns_per_s,
};

/// One OpenCode agent's structured side channel. See the file comment for
/// threads and memory; `adapter` lends it as an `agent.Adapter` whose
/// `destroy` calls `deinit`.
pub const OpenCodeAdapter = struct {
    allocator: Allocator,
    io: Io,
    options: Options,
    tcp: TcpTransport,
    /// Whether the event stream is live. Read by `capabilities` from any
    /// thread.
    connected: std.atomic.Value(bool) = .init(false),
    /// Set when `launch` targeted a remote context: no structured channel.
    remote: bool = false,
    attached: bool = false,
    authorization: ?[]u8 = null,
    directory: ?[]u8 = null,
    initial_prompt: ?[]u8 = null,
    history_pending: bool = false,
    mapper: Mapper = .{},
    backlog: Backlog,
    sse: SseParser,
    stream: Stream = .{},
    raw: []u8,
    body: []u8,
    head: []u8,
    json_arena: std.heap.ArenaAllocator,
    next_connect_ns: i96 = 0,
    backoff_ns: u64,
    /// Events that were not JSON, or exceeded `max_event_bytes`.
    malformed_events: u64 = 0,
    oversized_events: u64 = 0,

    const Stream = struct {
        connection: ?Connection = null,
        phase: enum { idle, head, body } = .idle,
        /// When the request was sent: a head that never comes is given up
        /// after `request_timeout_ns` (OpenCode 1.18.35 accepted a
        /// connection made while it was still starting and never answered
        /// it, observed live).
        sent_ns: i96 = 0,
        head_len: usize = 0,
        raw_start: usize = 0,
        raw_end: usize = 0,
        body_start: usize = 0,
        body_end: usize = 0,
        decoder: BodyDecoder = .init(.until_close),
    };

    /// Allocate the adapter's buffers. Strings in `options` other than
    /// `executable` are copied.
    pub fn init(allocator: Allocator, io: Io, options: Options) Allocator.Error!OpenCodeAdapter {
        const slots = try allocator.alloc(event.StoredEvent, backlog_capacity);
        errdefer allocator.free(slots);
        const line = try allocator.alloc(u8, max_event_bytes);
        errdefer allocator.free(line);
        const data = try allocator.alloc(u8, max_event_bytes);
        errdefer allocator.free(data);
        const raw = try allocator.alloc(u8, io_buffer_bytes);
        errdefer allocator.free(raw);
        const body = try allocator.alloc(u8, io_buffer_bytes);
        errdefer allocator.free(body);
        const head = try allocator.alloc(u8, max_head_bytes);
        errdefer allocator.free(head);
        var self: OpenCodeAdapter = .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .tcp = .{ .allocator = allocator, .io = io, .port = options.port },
            .backlog = .{ .slots = slots },
            .sse = .init(line, data),
            .raw = raw,
            .body = body,
            .head = head,
            .json_arena = .init(allocator),
            .backoff_ns = options.reconnect_min_ns,
        };
        errdefer self.freeStrings();
        if (options.password) |password| self.authorization = try basicAuthorization(allocator, password);
        if (options.directory) |dir| self.directory = try allocator.dupe(u8, dir);
        self.options.password = null;
        self.options.directory = null;
        return self;
    }

    pub fn deinit(self: *OpenCodeAdapter) void {
        self.closeStream();
        self.freeStrings();
        self.json_arena.deinit();
        self.allocator.free(self.backlog.slots);
        self.allocator.free(self.sse.line);
        self.allocator.free(self.sse.data);
        self.allocator.free(self.raw);
        self.allocator.free(self.body);
        self.allocator.free(self.head);
        self.* = undefined;
    }

    fn freeStrings(self: *OpenCodeAdapter) void {
        if (self.authorization) |a| self.allocator.free(a);
        if (self.directory) |d| self.allocator.free(d);
        if (self.initial_prompt) |p| self.allocator.free(p);
        self.authorization = null;
        self.directory = null;
        self.initial_prompt = null;
    }

    /// Lend this adapter through the common interface. `destroy` calls
    /// `deinit`; the storage of `self` stays the caller's.
    pub fn adapter(self: *OpenCodeAdapter) agent_adapter.Adapter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Whether the `/event` stream is currently live.
    pub fn isConnected(self: *const OpenCodeAdapter) bool {
        return self.connected.load(.acquire);
    }

    const vtable: agent_adapter.Adapter.VTable = .{
        .harness = harnessOf,
        .capabilities = capabilitiesOf,
        .detect = detect,
        .launch = launch,
        .attach = attach,
        .poll = poll,
        .send_input = sendInput,
        .respond_permission = respondPermission,
        .read_prompt = null,
        .update_prompt = null,
        .stop = stop,
        .destroy = destroy,
    };

    fn cast(ptr: *anyopaque) *OpenCodeAdapter {
        return @ptrCast(@alignCast(ptr));
    }

    fn harnessOf(_: *const anyopaque) Harness {
        return .opencode;
    }

    /// `opencode --version` through the request's context, bounded to
    /// `detect_timeout_ms` and `detect_max_output`. Not installed (the command
    /// is missing, or a remote shell's 127) is null; a context that cannot run
    /// commands is `Unsupported`.
    fn detect(ptr: *anyopaque, request: agent_adapter.DetectRequest) agent_adapter.Error!?[]const u8 {
        const self = cast(ptr);
        var result = request.context.run(self.allocator, self.io, .{
            .argv = &.{ self.options.executable, "--version" },
            .cwd = self.directory orelse "/",
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
        const version = parseVersion(result.stdout) orelse return error.Protocol;
        if (version.len > request.version_buffer.len) return error.NoSpaceLeft;
        const out = request.version_buffer[0..version.len];
        @memcpy(out, version);
        return out;
    }

    /// Launch, attach and poll always; everything structured only while the
    /// event stream is live, so a view shows the PTY baseline otherwise.
    fn capabilitiesOf(ptr: *const anyopaque) agent_adapter.Capabilities {
        const self: *const OpenCodeAdapter = @ptrCast(@alignCast(ptr));
        var caps: agent_adapter.Capabilities = .{ .detect = true, .launch = true, .attach = true, .poll = true };
        if (self.connected.load(.acquire)) {
            caps.send_input = true;
            caps.respond_permission = true;
            caps.stop = true;
            caps.structured_status = true;
            caps.permission_requests = true;
            caps.transcript = true;
            caps.subagents = true;
        }
        return caps;
    }

    fn destroy(ptr: *anyopaque) void {
        cast(ptr).deinit();
    }

    /// `opencode --port P --hostname 127.0.0.1 [--prompt TEXT]` for the TUI,
    /// or `opencode serve --port P --hostname 127.0.0.1` headless. The env
    /// adds the correlation token and makes it the server's basic-auth
    /// password. A remote context gets the plain TUI and no side channel.
    fn launch(ptr: *anyopaque, allocator: Allocator, request: agent_adapter.LaunchRequest) agent_adapter.Error!agent_adapter.LaunchSpec {
        const self = cast(ptr);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(allocator, self.options.executable);
        var env: std.ArrayList([]const u8) = .empty;
        var token_entry: [agent_adapter.correlation_env_name.len + 1 + agent_adapter.CorrelationToken.text_len]u8 = undefined;
        try env.append(allocator, try allocator.dupe(u8, request.token.envEntry(&token_entry)));

        if (request.context_kind.isRemote()) {
            // The server would listen on the remote host's loopback, which
            // this adapter's loopback transport cannot reach; forwarding the
            // port over the connection is not implemented (TASK-61 keeps the
            // PTY baseline here).
            self.remote = true;
            if (request.headless) return error.Unsupported;
            if (request.initial_prompt) |prompt| {
                try argv.append(allocator, "--prompt");
                try argv.append(allocator, try allocator.dupe(u8, prompt));
            }
            return .{ .argv = try argv.toOwnedSlice(allocator), .env = try env.toOwnedSlice(allocator) };
        }

        if (self.options.port == 0) return error.Unsupported;
        const port = try std.fmt.allocPrint(allocator, "{d}", .{self.options.port});
        if (request.headless) try argv.append(allocator, "serve");
        try argv.appendSlice(allocator, &.{ "--port", port, "--hostname", server_host });
        if (request.initial_prompt) |prompt| {
            if (request.headless) {
                // `serve` takes no prompt; it is sent once the server answers.
                const copy = try self.allocator.dupe(u8, prompt);
                if (self.initial_prompt) |old| self.allocator.free(old);
                self.initial_prompt = copy;
            } else {
                try argv.append(allocator, "--prompt");
                try argv.append(allocator, try allocator.dupe(u8, prompt));
            }
        }
        try env.append(allocator, "OPENCODE_SERVER_USERNAME=" ++ server_username);
        try env.append(allocator, try std.fmt.allocPrint(allocator, "OPENCODE_SERVER_PASSWORD={s}", .{request.token.text()}));

        const authorization = try basicAuthorization(self.allocator, request.token.text());
        if (self.authorization) |old| self.allocator.free(old);
        self.authorization = authorization;
        if (self.directory == null) self.directory = try self.allocator.dupe(u8, request.cwd);
        return .{ .argv = try argv.toOwnedSlice(allocator), .env = try env.toOwnedSlice(allocator) };
    }

    /// Adopt a session on the configured port. With `harness_session_id`
    /// the adapter follows that session and replays its recent messages;
    /// without one it adopts the first session that becomes active.
    fn attach(ptr: *anyopaque, request: agent_adapter.AttachRequest) agent_adapter.Error!void {
        const self = cast(ptr);
        if (self.attached) return error.UnknownTarget;
        if (request.harness_session_id) |id| {
            if (!self.mapper.bind(id)) return error.UnknownTarget;
            self.history_pending = true;
        }
        self.attached = true;
    }

    fn poll(ptr: *anyopaque, queue: *event.EventQueue) agent_adapter.Error!usize {
        const self = cast(ptr);
        var pushed = self.flush(queue);
        if (self.backlog.len != 0 or self.remote) return pushed;
        try self.pump();
        pushed += self.flush(queue);
        if (self.initial_prompt != null and self.isConnected()) {
            const prompt = self.initial_prompt.?;
            self.initial_prompt = null;
            defer self.allocator.free(prompt);
            self.sendText(prompt) catch |err| log.debug("initial prompt not sent: {s}", .{@errorName(err)});
        }
        return pushed;
    }

    fn flush(self: *OpenCodeAdapter, queue: *event.EventQueue) usize {
        var pushed: usize = 0;
        while (self.backlog.len != 0) {
            queue.push(self.backlog.front().event) catch |err| switch (err) {
                error.QueueFull => break,
                // It already fit a slot of the same size.
                error.EventTooLarge => unreachable,
            };
            self.backlog.pop();
            pushed += 1;
        }
        return pushed;
    }

    /// Read and map stream bytes until the socket has nothing more, the
    /// backlog lacks room for another event's worth, or this poll's byte
    /// budget is spent. Only the first read may wait.
    fn pump(self: *OpenCodeAdapter) Allocator.Error!void {
        var budget: usize = 4 * io_buffer_bytes;
        var may_wait = true;
        while (self.backlog.free() >= backlog_reserve) {
            switch (self.stream.phase) {
                .idle => if (!self.connect()) return,
                .head => {
                    const s = &self.stream;
                    if (s.head_len == self.head.len) return self.disconnect("response head too large");
                    const conn = s.connection.?;
                    const wait = if (may_wait) self.options.poll_wait_ns else 0;
                    may_wait = false;
                    const n = conn.read(self.head[s.head_len..], wait) catch |err| switch (err) {
                        error.WouldBlock => {
                            const waited = Io.Clock.awake.now(self.io).nanoseconds - s.sent_ns;
                            if (waited > self.options.request_timeout_ns) return self.disconnect("no response head");
                            return;
                        },
                        else => return self.disconnect("stream read failed"),
                    };
                    if (n == 0) return self.disconnect("stream closed before its head");
                    s.head_len += n;
                    const end = headEnd(self.head[0..s.head_len]) orelse continue;
                    const head = parseHead(self.head[0..end]) catch return self.disconnect("malformed response head");
                    if (head.status != 200 or !head.event_stream) {
                        log.debug("event stream refused with status {d}", .{head.status});
                        return self.disconnect("event stream refused");
                    }
                    const leftover = s.head_len - end;
                    @memcpy(self.raw[0..leftover], self.head[end..s.head_len]);
                    s.raw_start = 0;
                    s.raw_end = leftover;
                    s.decoder = .init(head.framing);
                    s.phase = .body;
                    self.backoff_ns = self.options.reconnect_min_ns;
                    self.connected.store(true, .release);
                    if (self.history_pending) self.loadHistory() catch |err| {
                        log.debug("history not loaded: {s}", .{@errorName(err)});
                    };
                },
                .body => {
                    const s = &self.stream;
                    if (s.body_start < s.body_end) {
                        const step = self.sse.next(self.body[s.body_start..s.body_end]);
                        s.body_start += step.consumed;
                        if (step.dispatch) |dispatch| try self.dispatchEvent(dispatch);
                        if (self.mapper.disposed) {
                            self.mapper.disposed = false;
                            return self.disconnect("instance disposed");
                        }
                        continue;
                    }
                    if (s.raw_start < s.raw_end) {
                        const step = s.decoder.decode(self.raw[s.raw_start..s.raw_end], self.body) catch
                            return self.disconnect("malformed body framing");
                        s.raw_start += step.consumed;
                        s.body_start = 0;
                        s.body_end = step.produced;
                        continue;
                    }
                    if (s.decoder.finished()) return self.disconnect("event stream ended");
                    if (budget == 0) return;
                    const wait = if (may_wait) self.options.poll_wait_ns else 0;
                    may_wait = false;
                    const n = s.connection.?.read(self.raw, wait) catch |err| switch (err) {
                        error.WouldBlock => return,
                        else => return self.disconnect("stream read failed"),
                    };
                    if (n == 0) return self.disconnect("event stream closed");
                    s.raw_start = 0;
                    s.raw_end = n;
                    budget -|= n;
                },
            }
        }
    }

    fn dispatchEvent(self: *OpenCodeAdapter, sse_event: SseParser.Dispatch) Allocator.Error!void {
        const data = switch (sse_event) {
            .oversized => {
                self.oversized_events += 1;
                log.debug("dropped an event over {d} bytes", .{max_event_bytes});
                return;
            },
            .data => |d| d,
        };
        defer _ = self.json_arena.reset(.{ .retain_with_limit = 64 * 1024 });
        const arena = self.json_arena.allocator();
        const root = json.parseFromSliceLeaky(json.Value, arena, data, parse_options) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.malformed_events += 1;
                log.debug("ignored a malformed event", .{});
                return;
            },
        };
        self.mapper.handle(arena, &self.backlog, root) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // `pump` keeps `backlog_reserve` slots free before each event.
            error.BacklogFull => log.debug("backlog full; an event was cut short", .{}),
        };
    }

    fn connect(self: *OpenCodeAdapter) bool {
        const now = Io.Clock.awake.now(self.io).nanoseconds;
        if (now < self.next_connect_ns) return false;
        const connection = self.transport().connect() catch |err| {
            self.scheduleReconnect(now);
            if (err != error.Unreachable) log.debug("event stream connect failed: {s}", .{@errorName(err)});
            return false;
        };
        var buffer: [2048]u8 = undefined;
        var writer: Io.Writer = .fixed(&buffer);
        var target_buffer: [1536]u8 = undefined;
        const target = self.formatTarget(&target_buffer, &.{.{ .literal = "/event" }}) orelse {
            connection.close();
            self.scheduleReconnect(now);
            return false;
        };
        writeRequest(&writer, .{
            .method = .GET,
            .target = target,
            .port = self.options.port,
            .authorization = self.authorization,
            .accept = "text/event-stream",
        }) catch {
            connection.close();
            self.scheduleReconnect(now);
            return false;
        };
        connection.write(writer.buffered()) catch {
            connection.close();
            self.scheduleReconnect(now);
            return false;
        };
        self.stream = .{ .connection = connection, .phase = .head, .sent_ns = now };
        self.sse.reset();
        return true;
    }

    fn scheduleReconnect(self: *OpenCodeAdapter, now: i96) void {
        self.next_connect_ns = now + self.backoff_ns;
        self.backoff_ns = @min(self.backoff_ns * 2, self.options.reconnect_max_ns);
    }

    fn closeStream(self: *OpenCodeAdapter) void {
        if (self.stream.connection) |c| c.close();
        self.stream = .{};
        self.sse.reset();
        self.connected.store(false, .release);
    }

    fn disconnect(self: *OpenCodeAdapter, reason: []const u8) void {
        log.debug("event stream down: {s}", .{reason});
        self.closeStream();
        self.scheduleReconnect(Io.Clock.awake.now(self.io).nanoseconds);
    }

    fn transport(self: *OpenCodeAdapter) Transport {
        return self.options.transport orelse self.tcp.transport();
    }

    /// The target for `parts` plus the directory query, or null when it does
    /// not fit `buffer` (an absurd directory).
    fn formatTarget(self: *const OpenCodeAdapter, buffer: []u8, parts: []const TargetPart) ?[]const u8 {
        var writer: Io.Writer = .fixed(buffer);
        writeTarget(&writer, parts, self.directory) catch return null;
        return writer.buffered();
    }

    const Response = struct { status: u16, body: []const u8 };

    /// One request on a fresh connection, bounded by `request_timeout_ns` and
    /// `max_response_bytes`. The body is allocated in `arena`.
    fn roundTrip(self: *OpenCodeAdapter, arena: Allocator, method: Method, parts: []const TargetPart, body: ?[]const u8) agent_adapter.Error!Response {
        var request: Io.Writer.Allocating = .init(arena);
        var target: Io.Writer.Allocating = .init(arena);
        writeTarget(&target.writer, parts, self.directory) catch return error.OutOfMemory;
        writeRequest(&request.writer, .{
            .method = method,
            .target = target.written(),
            .port = self.options.port,
            .authorization = self.authorization,
            .body = body,
        }) catch return error.OutOfMemory;

        const connection = self.transport().connect() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Disconnected,
        };
        defer connection.close();
        connection.write(request.written()) catch return error.Disconnected;

        const deadline = Io.Clock.awake.now(self.io).nanoseconds + self.options.request_timeout_ns;
        var raw: std.ArrayList(u8) = .empty;
        var out: std.ArrayList(u8) = .empty;
        var head: ?Head = null;
        var decoder: BodyDecoder = .init(.until_close);
        var decoded: usize = 0;
        var chunk: [16 * 1024]u8 = undefined;
        while (true) {
            if (head != null and decoder.finished()) break;
            const now = Io.Clock.awake.now(self.io).nanoseconds;
            if (now >= deadline) return error.Disconnected;
            const n = connection.read(&chunk, @intCast(deadline - now)) catch |err| switch (err) {
                error.WouldBlock => continue,
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Disconnected,
            };
            if (n == 0) {
                if (head) |h| if (h.framing == .until_close) break;
                return error.Protocol;
            }
            if (raw.items.len + n > max_head_bytes + max_response_bytes) return error.Protocol;
            try raw.appendSlice(arena, chunk[0..n]);
            if (head == null) {
                const end = headEnd(raw.items) orelse {
                    if (raw.items.len > max_head_bytes) return error.Protocol;
                    continue;
                };
                head = parseHead(raw.items[0..end]) catch return error.Protocol;
                decoder = .init(head.?.framing);
                decoded = end;
            }
            while (decoded < raw.items.len and !decoder.finished()) {
                try out.ensureUnusedCapacity(arena, 4096);
                if (out.items.len > max_response_bytes) return error.Protocol;
                const space = out.unusedCapacitySlice();
                const step = decoder.decode(raw.items[decoded..], space) catch return error.Protocol;
                decoded += step.consumed;
                out.items.len += step.produced;
                if (step.consumed == 0 and step.produced == 0) break;
            }
        }
        const status = head.?.status;
        if (status == 401 or status == 403) log.debug("server refused credentials ({d})", .{status});
        return .{ .status = status, .body = out.items };
    }

    fn requestArena(self: *OpenCodeAdapter) std.heap.ArenaAllocator {
        return .init(self.allocator);
    }

    /// Answer a permission with one of `decisions`. Uses the current
    /// `POST /permission/:id/reply` and falls back to the deprecated
    /// per-session route for older servers.
    fn respondPermission(ptr: *anyopaque, request_id: []const u8, decision_id: []const u8) agent_adapter.Error!void {
        const self = cast(ptr);
        const reply = Reply.parse(decision_id) orelse return error.UnknownTarget;
        if (request_id.len == 0 or request_id.len > event.max_identifier_bytes) return error.UnknownTarget;
        var arena_state = self.requestArena();
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const body = try std.fmt.allocPrint(arena, "{{\"reply\":\"{s}\"}}", .{@tagName(reply)});
        var response = try self.roundTrip(arena, .POST, &.{ .{ .literal = "/permission/" }, .{ .segment = request_id }, .{ .literal = "/reply" } }, body);
        if (response.status == 404) {
            const index = self.mapper.pendingIndex(request_id) orelse return error.UnknownTarget;
            const session_id = self.mapper.pending[index].session;
            if (session_id.len == 0) return error.UnknownTarget;
            const legacy = try std.fmt.allocPrint(arena, "{{\"response\":\"{s}\"}}", .{@tagName(reply)});
            response = try self.roundTrip(arena, .POST, &.{
                .{ .literal = "/session/" },     .{ .segment = session_id.slice() },
                .{ .literal = "/permissions/" }, .{ .segment = request_id },
            }, legacy);
        }
        try checkStatus(response.status);
        if (self.mapper.pendingIndex(request_id)) |i| self.mapper.pending[i].answered = reply;
    }

    fn sendInput(ptr: *anyopaque, bytes: []const u8) agent_adapter.Error!void {
        return cast(ptr).sendText(bytes);
    }

    /// `POST /session/:id/prompt_async` with one text part; creates a session
    /// first when none is bound (a headless server).
    fn sendText(self: *OpenCodeAdapter, text: []const u8) agent_adapter.Error!void {
        var arena_state = self.requestArena();
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        try self.ensureSession(arena);
        const Part = struct { type: []const u8 = "text", text: []const u8 };
        const body = try json.Stringify.valueAlloc(arena, .{ .parts = &[_]Part{.{ .text = text }} }, .{});
        const response = try self.roundTrip(arena, .POST, &.{ .{ .literal = "/session/" }, .{ .segment = self.mapper.session.slice() }, .{ .literal = "/prompt_async" } }, body);
        try checkStatus(response.status);
    }

    fn ensureSession(self: *OpenCodeAdapter, arena: Allocator) agent_adapter.Error!void {
        if (self.mapper.session.len != 0) return;
        const response = try self.roundTrip(arena, .POST, &.{.{ .literal = "/session" }}, "{}");
        try checkStatus(response.status);
        const root = json.parseFromSliceLeaky(json.Value, arena, response.body, parse_options) catch return error.Protocol;
        const id = string(field(root, "id")) orelse return error.Protocol;
        if (!self.mapper.bind(id)) return error.Protocol;
    }

    /// `POST /session/:id/abort`.
    fn stop(ptr: *anyopaque) agent_adapter.Error!void {
        const self = cast(ptr);
        if (self.mapper.session.len == 0) return error.UnknownTarget;
        var arena_state = self.requestArena();
        defer arena_state.deinit();
        const response = try self.roundTrip(arena_state.allocator(), .POST, &.{ .{ .literal = "/session/" }, .{ .segment = self.mapper.session.slice() }, .{ .literal = "/abort" } }, null);
        try checkStatus(response.status);
    }

    /// Replay the bound session's recent messages (`GET /session/:id/message`)
    /// as transcript events. Best effort: what does not fit the backlog is
    /// skipped, and the harness keeps the full history.
    fn loadHistory(self: *OpenCodeAdapter) agent_adapter.Error!void {
        var arena_state = self.requestArena();
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var limit_buffer: [32]u8 = undefined;
        // "/message?limit=" plus at most five digits fits 32 bytes.
        const limit = std.fmt.bufPrint(&limit_buffer, "/message?limit={d}", .{self.options.history_limit}) catch unreachable;
        const response = try self.roundTrip(arena, .GET, &.{ .{ .literal = "/session/" }, .{ .segment = self.mapper.session.slice() }, .{ .literal = limit } }, null);
        try checkStatus(response.status);
        self.history_pending = false;
        try self.mapHistory(arena, response.body);
    }

    fn mapHistory(self: *OpenCodeAdapter, arena: Allocator, body: []const u8) agent_adapter.Error!void {
        const root = json.parseFromSliceLeaky(json.Value, arena, body, parse_options) catch return error.Protocol;
        // The instance route returns an array; newer cursor-paged routes wrap
        // it in `data`.
        const list = if (root == .array) root else (field(root, "data") orelse return error.Protocol);
        if (list != .array) return error.Protocol;
        const items = list.array.items;
        const first = items.len -| self.options.history_limit;
        for (items[first..]) |entry| {
            const info = field(entry, "info");
            const role = parseRole(string(field(info, "role"))) orelse continue;
            if (string(field(info, "id"))) |id| self.mapper.rememberRole(id, role);
            const parts = field(entry, "parts") orelse continue;
            if (parts != .array) continue;
            for (parts.array.items) |part| {
                if (self.backlog.free() < backlog_reserve) {
                    log.debug("history cut short by the backlog", .{});
                    return;
                }
                self.mapper.mapPart(&self.backlog, part, role) catch return;
            }
        }
    }
};

/// The version in `opencode --version` output: the last word of the first
/// non-empty line (so both `1.18.35` and `opencode 1.18.35` work), without a
/// leading `v`. Untrusted output: anything that is not a short run of
/// version characters is null.
pub fn parseVersion(stdout: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeAny(u8, stdout, "\r\n");
    const line = std.mem.trim(u8, lines.next() orelse return null, " \t");
    var words = std.mem.tokenizeAny(u8, line, " \t");
    var last: ?[]const u8 = null;
    while (words.next()) |word| last = word;
    var version = last orelse return null;
    if (version.len > 1 and version[0] == 'v') version = version[1..];
    if (version.len == 0 or version.len > max_version_bytes) return null;
    if (!std.ascii.isDigit(version[0])) return null;
    for (version) |c| switch (c) {
        '0'...'9', 'a'...'z', 'A'...'Z', '.', '-', '+' => {},
        else => return null,
    };
    return version;
}

fn checkStatus(status: u16) agent_adapter.Error!void {
    if (status >= 200 and status < 300) return;
    if (status == 404) return error.UnknownTarget;
    return error.Protocol;
}

/// `Basic base64(opencode:password)`, allocated with `allocator`.
fn basicAuthorization(allocator: Allocator, password: []const u8) Allocator.Error![]u8 {
    const encoder = std.base64.standard.Encoder;
    const credentials_len = server_username.len + 1 + password.len;
    const prefix = "Basic ";
    const out = try allocator.alloc(u8, prefix.len + encoder.calcSize(credentials_len));
    errdefer allocator.free(out);
    const credentials = try allocator.alloc(u8, credentials_len);
    defer allocator.free(credentials);
    @memcpy(credentials[0..server_username.len], server_username);
    credentials[server_username.len] = ':';
    @memcpy(credentials[server_username.len + 1 ..], password);
    @memcpy(out[0..prefix.len], prefix);
    _ = encoder.encode(out[prefix.len..], credentials);
    return out;
}

// Tests -------------------------------------------------------------------------

const testing = std.testing;
const fixture_dir = "test/fixtures/agent/opencode/";

fn readFixture(name: []const u8) ![]u8 {
    // Tests run from the build root, like the config tests' relative paths.
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, fixture_dir ++ "{s}", .{name});
    return Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1024 * 1024)) catch |err| {
        std.debug.print("missing fixture {s}{s}: {s}\n", .{ fixture_dir, name, @errorName(err) });
        return err;
    };
}

test "requests are written in HTTP/1.1 wire form with an encoded target" {
    var buffer: [512]u8 = undefined;
    var target_writer: Io.Writer = .fixed(&buffer);
    try writeTarget(&target_writer, &.{ .{ .literal = "/permission/" }, .{ .segment = "per 1/x" }, .{ .literal = "/reply" } }, "/home/me/my proj");
    try testing.expectEqualStrings("/permission/per%201%2Fx/reply?directory=%2Fhome%2Fme%2Fmy%20proj", target_writer.buffered());

    var query_buffer: [128]u8 = undefined;
    var query: Io.Writer = .fixed(&query_buffer);
    try writeTarget(&query, &.{.{ .literal = "/session/s/message?limit=3" }}, "/w");
    try testing.expectEqualStrings("/session/s/message?limit=3&directory=%2Fw", query.buffered());

    var out_buffer: [512]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buffer);
    try writeRequest(&out, .{ .method = .POST, .target = "/x", .port = 4096, .authorization = "Basic abc", .body = "{\"a\":1}" });
    try testing.expectEqualStrings("POST /x HTTP/1.1\r\nHost: 127.0.0.1:4096\r\nAccept: application/json\r\nConnection: close\r\n" ++
        "Authorization: Basic abc\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\n{\"a\":1}", out.buffered());

    var get: Io.Writer = .fixed(&out_buffer);
    try writeRequest(&get, .{ .method = .GET, .target = "/event", .port = 1, .accept = "text/event-stream" });
    try testing.expectEqualStrings("GET /event HTTP/1.1\r\nHost: 127.0.0.1:1\r\nAccept: text/event-stream\r\nConnection: close\r\n\r\n", get.buffered());

    var empty_post: Io.Writer = .fixed(&out_buffer);
    try writeRequest(&empty_post, .{ .method = .POST, .target = "/session/s/abort", .port = 1 });
    try testing.expect(std.mem.endsWith(u8, empty_post.buffered(), "Content-Length: 0\r\n\r\n"));

    const auth = try basicAuthorization(testing.allocator, "secret");
    defer testing.allocator.free(auth);
    try testing.expectEqualStrings("Basic b3BlbmNvZGU6c2VjcmV0", auth);
}

test "response heads parse status, framing and content type; junk is refused" {
    const sse = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\ntransfer-encoding: chunked\r\nContent-Length: 5\r\n\r\n";
    try testing.expectEqual(sse.len, headEnd(sse ++ "rest").?);
    const head = try parseHead(sse);
    try testing.expectEqual(@as(u16, 200), head.status);
    try testing.expect(head.event_stream);
    try testing.expect(head.framing == .chunked);

    const plain = try parseHead("HTTP/1.1 404 Not Found\r\ncontent-length: 12\r\n\r\n");
    try testing.expectEqual(@as(u16, 404), plain.status);
    try testing.expectEqual(@as(u64, 12), plain.framing.length);
    try testing.expect(!plain.event_stream);

    try testing.expect((try parseHead("HTTP/1.1 204 No Content\r\n\r\n")).framing.length == 0);
    try testing.expect((try parseHead("HTTP/1.0 200 OK\r\n\r\n")).framing == .until_close);
    try testing.expect(headEnd("HTTP/1.1 200 OK\r\n") == null);
    for ([_][]const u8{ "", "SSH-2.0\r\n\r\n", "HTTP/1.1 2000 OK\r\n\r\n", "HTTP/1.1 abc\r\n\r\n", "HTTP/1.1 200 OK\r\nno colon\r\n\r\n", "HTTP/1.1 200 OK\r\nContent-Length: x\r\n\r\n" }) |bad| {
        try testing.expectError(error.Protocol, parseHead(bad));
    }
}

test "bodies decode by content length, chunks and connection close, byte by byte" {
    // Chunked, with an extension, a trailer and the payload split anywhere.
    const chunked = "5;ext=1\r\nhello\r\n7\r\n, world\r\n0\r\nX-Trailer: 1\r\n\r\nNEXT";
    var split: usize = 0;
    while (split <= chunked.len) : (split += 1) {
        var decoder: BodyDecoder = .init(.chunked);
        var out: [64]u8 = undefined;
        var produced: usize = 0;
        var consumed: usize = 0;
        for ([_][]const u8{ chunked[0..split], chunked[split..] }) |piece| {
            var at: usize = 0;
            while (at < piece.len and !decoder.finished()) {
                const step = try decoder.decode(piece[at..], out[produced..]);
                at += step.consumed;
                produced += step.produced;
            }
            consumed += at;
        }
        try testing.expect(decoder.finished());
        try testing.expectEqualStrings("hello, world", out[0..produced]);
        try testing.expectEqual(chunked.len - "NEXT".len, consumed);
    }

    // A small output buffer only delays the data.
    var small: BodyDecoder = .init(.chunked);
    var tiny: [3]u8 = undefined;
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    var input: []const u8 = "a\r\n0123456789\r\n0\r\n\r\n";
    while (!small.finished()) {
        const step = try small.decode(input, &tiny);
        input = input[step.consumed..];
        try got.appendSlice(testing.allocator, tiny[0..step.produced]);
    }
    try testing.expectEqualStrings("0123456789", got.items);

    var length: BodyDecoder = .init(.{ .length = 4 });
    var out: [16]u8 = undefined;
    const step = try length.decode("trueEXTRA", &out);
    try testing.expectEqual(@as(usize, 4), step.consumed);
    try testing.expect(length.finished());
    try testing.expect(BodyDecoder.init(.{ .length = 0 }).finished());

    var close: BodyDecoder = .init(.until_close);
    try testing.expectEqual(@as(usize, 3), (try close.decode("abc", &out)).produced);
    try testing.expect(!close.finished());

    for ([_][]const u8{ "zz\r\n", "\r\n", "1\r\nab", "1\r\na\rX", "1234567890abcdef0\r\n" }) |bad| {
        var d: BodyDecoder = .init(.chunked);
        try testing.expectError(error.Protocol, d.decode(bad, &out));
    }
}

test "SSE: multi-line data, comments, CRLF and CR endings, other fields, bounds" {
    var line: [64]u8 = undefined;
    var data: [64]u8 = undefined;
    var parser: SseParser = .init(&line, &data);
    const stream = ": comment\r\nevent: message\r\nid: 7\r\ndata: {\"a\":\r\ndata:1}\r\n\r\ndata: two\rdata\r\r\nretry: 5\n\n";
    var input: []const u8 = stream;
    var events: [4][]u8 = undefined;
    var count: usize = 0;
    defer for (events[0..count]) |e| testing.allocator.free(e);
    while (input.len != 0) {
        const step = parser.next(input);
        input = input[step.consumed..];
        if (step.dispatch) |d| {
            events[count] = try testing.allocator.dupe(u8, d.data);
            count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqualStrings("{\"a\":\n1}", events[0]);
    // `data` with no colon is an empty data line.
    try testing.expectEqualStrings("two\n", events[1]);

    // Byte-at-a-time gives the same events.
    parser.reset();
    var n: usize = 0;
    for (stream) |c| {
        if (parser.next(&.{c}).dispatch != null) n += 1;
    }
    try testing.expectEqual(@as(usize, 2), n);

    // An event over the data bound is reported as oversized, then parsing
    // resumes with the next event.
    parser.reset();
    const big = "data: " ++ "x" ** 40 ++ "\ndata: " ++ "y" ** 40 ++ "\n\ndata: ok\n\n";
    var rest: []const u8 = big;
    var outcomes: [2]std.meta.Tag(SseParser.Dispatch) = undefined;
    var k: usize = 0;
    while (rest.len != 0) {
        const step = parser.next(rest);
        rest = rest[step.consumed..];
        if (step.dispatch) |d| {
            outcomes[k] = d;
            k += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), k);
    try testing.expectEqual(.oversized, outcomes[0]);
    try testing.expectEqual(.data, outcomes[1]);

    // An over-long single line is oversized too.
    parser.reset();
    const long_line = "data: " ++ "z" ** 100 ++ "\n\n";
    const step = parser.next(long_line);
    try testing.expectEqual(SseParser.Dispatch.oversized, step.dispatch.?);
}

/// A transport whose single connection replays `script` and records writes.
const ScriptedTransport = struct {
    script: []const u8,
    /// Bytes delivered per read, to exercise splitting.
    read_size: usize = 7,
    at: usize = 0,
    written: std.ArrayList(u8) = .empty,
    connects: usize = 0,
    reachable: bool = true,
    open: bool = false,
    end_with_eof: bool = false,

    fn transport(self: *ScriptedTransport) Transport {
        return .{ .ptr = self, .connect_fn = connectFn };
    }

    const conn_vtable: Connection.VTable = .{ .write = writeFn, .read = readFn, .close = closeFn };

    fn connectFn(ptr: *anyopaque) TransportError!Connection {
        const self: *ScriptedTransport = @ptrCast(@alignCast(ptr));
        self.connects += 1;
        if (!self.reachable) return error.Unreachable;
        self.open = true;
        return .{ .ptr = self, .vtable = &conn_vtable };
    }

    fn writeFn(ptr: *anyopaque, bytes: []const u8) TransportError!void {
        const self: *ScriptedTransport = @ptrCast(@alignCast(ptr));
        self.written.appendSlice(testing.allocator, bytes) catch return error.OutOfMemory;
    }

    fn readFn(ptr: *anyopaque, buffer: []u8, _: u64) TransportError!usize {
        const self: *ScriptedTransport = @ptrCast(@alignCast(ptr));
        if (self.at == self.script.len) return if (self.end_with_eof) 0 else error.WouldBlock;
        const n = @min(@min(buffer.len, self.read_size), self.script.len - self.at);
        @memcpy(buffer[0..n], self.script[self.at..][0..n]);
        self.at += n;
        return n;
    }

    fn closeFn(ptr: *anyopaque) void {
        const self: *ScriptedTransport = @ptrCast(@alignCast(ptr));
        self.open = false;
    }
};

/// Wrap SSE fixture text as a chunked `200 text/event-stream` response,
/// in chunks of at most 100 bytes.
fn sseResponse(allocator: Allocator, sse_text: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n");
    var rest = sse_text;
    while (rest.len != 0) {
        const n = @min(rest.len, 100);
        try out.writer.print("{x}\r\n{s}\r\n", .{ n, rest[0..n] });
        rest = rest[n..];
    }
    return out.toOwnedSlice();
}

const Collected = struct {
    slots: []event.StoredEvent,
    len: usize = 0,

    fn init() !Collected {
        return .{ .slots = try testing.allocator.alloc(event.StoredEvent, 64) };
    }

    fn deinit(self: *Collected) void {
        testing.allocator.free(self.slots);
    }

    fn drain(self: *Collected, queue: *event.EventQueue) void {
        self.len += queue.drain(self.slots[self.len..]);
    }

    fn at(self: *const Collected, i: usize) event.Event {
        return self.slots[i].event;
    }

    fn kinds(self: *const Collected, out: []event.Event.Kind) []event.Event.Kind {
        for (self.slots[0..self.len], 0..) |*s, i| out[i] = std.meta.activeTag(s.event);
        return out[0..self.len];
    }
};

fn testAdapter(transport: Transport) !OpenCodeAdapter {
    return OpenCodeAdapter.init(testing.allocator, testing.io, .{ .port = 4096, .transport = transport, .directory = "/work" });
}

test "a recorded-shape turn maps onto agent events through the common interface" {
    const before = try readFixture("turn-before-permission.sse");
    defer testing.allocator.free(before);
    const after = try readFixture("turn-after-permission.sse");
    defer testing.allocator.free(after);
    const joined = try std.mem.concat(testing.allocator, u8, &.{ before, after });
    defer testing.allocator.free(joined);
    const response = try sseResponse(testing.allocator, joined);
    defer testing.allocator.free(response);

    var scripted: ScriptedTransport = .{ .script = response };
    defer scripted.written.deinit(testing.allocator);
    var oc = try testAdapter(scripted.transport());
    const a = oc.adapter();
    defer a.destroy();

    try testing.expectEqual(Harness.opencode, a.harness());
    try testing.expect(!a.capabilities().structured_status);
    try testing.expectError(error.Unsupported, a.respondPermission("x", "once"));
    try testing.expectError(error.Unsupported, a.readPrompt(&.{}));

    var queue = try event.EventQueue.init(testing.allocator, testing.io, 64);
    defer queue.deinit(testing.allocator);
    var collected = try Collected.init();
    defer collected.deinit();
    while (scripted.at < scripted.script.len) {
        _ = try a.poll(&queue);
        collected.drain(&queue);
    }
    _ = try a.poll(&queue);
    collected.drain(&queue);

    try testing.expect(std.mem.startsWith(u8, scripted.written.items, "GET /event?directory=%2Fwork HTTP/1.1\r\n"));
    try testing.expect(a.capabilities().structured_status);
    try testing.expect(a.capabilities().respond_permission);

    var kinds_buffer: [64]event.Event.Kind = undefined;
    const K = event.Event.Kind;
    try testing.expectEqualSlices(K, &.{
        .message,            .status_change,       .message,  .tool_use,      .file_reference, .subagent,      .subagent,
        .permission_request, .permission_resolved, .tool_use, .status_change, .notification,   .status_change, .status_change,
    }, collected.kinds(&kinds_buffer));

    try testing.expectEqual(event.Role.user, collected.at(0).message.role);
    try testing.expectEqualStrings("Fix the build", collected.at(0).message.text);
    try testing.expectEqual(State.working, collected.at(1).status_change.state);
    try testing.expectEqual(state_model.Source.structured, collected.at(1).status_change.source);
    try testing.expectEqual(event.Role.assistant, collected.at(2).message.role);
    // Two data lines, joined, and only the finished text.
    try testing.expectEqualStrings("Looking at build.zig.", collected.at(2).message.text);
    try testing.expectEqualStrings("read", collected.at(3).tool_use.name);
    try testing.expectEqualStrings("build.zig", collected.at(3).tool_use.summary);
    try testing.expectEqualStrings("/work/build.zig", collected.at(4).file_reference.path);
    try testing.expectEqualStrings("ses_child", collected.at(5).subagent.id);
    try testing.expectEqualStrings("explore the tests", collected.at(5).subagent.name);
    try testing.expectEqual(event.Subagent.Phase.start, collected.at(5).subagent.phase);
    try testing.expectEqual(event.Subagent.Phase.stop, collected.at(6).subagent.phase);
    const request = collected.at(7).permission_request;
    try testing.expectEqualStrings("per_1", request.id);
    try testing.expectEqualStrings("bash: zig build", request.title);
    try testing.expectEqual(@as(usize, 3), request.decisions.len);
    try testing.expectEqualStrings("once", request.decisions[0].id);
    try testing.expectEqual(event.DecisionKind.allow_always, request.decisions[1].kind);
    try testing.expectEqual(event.DecisionKind.reject, request.decisions[2].kind);
    // Nobody answered through Conduit: the TUI did.
    try testing.expectEqual(event.PermissionOutcome.resolved_elsewhere, collected.at(8).permission_resolved.outcome);
    try testing.expectEqualStrings("zig build", collected.at(9).tool_use.summary);
    try testing.expectEqual(State.waiting_input, collected.at(10).status_change.state);
    try testing.expectEqualStrings("Which target should I build?", collected.at(11).notification.body);
    try testing.expectEqual(State.working, collected.at(12).status_change.state);
    try testing.expectEqual(State.done, collected.at(13).status_change.state);

    // The same events drive the registry without an OpenCode case anywhere.
    const registry_mod = @import("registry.zig");
    var reg = registry_mod.Registry.init(testing.allocator);
    defer reg.deinit();
    const session = @import("session");
    const id = try reg.create(.{
        .binding = .{ .workspace = .first, .session = session.SessionId.fromOrdinal(1), .session_kind = .agent_terminal, .scratchpad = .first },
        .harness = a.harness(),
        .ownership = .owned,
        .token = agent_adapter.CorrelationToken.fromBytes(@splat(3)),
        .capabilities = a.capabilities(),
    });
    var states: [64]State = undefined;
    for (collected.slots[0..collected.len], 0..) |*stored, i| states[i] = (try reg.apply(id, stored.event)).current;
    try testing.expectEqual(State.waiting_permission, states[7]);
    try testing.expectEqual(State.working, states[8]);
    try testing.expectEqual(State.waiting_input, states[10]);
    try testing.expectEqual(State.done, reg.get(id).?.state);
    try testing.expect(reg.get(id).?.structured);
}

test "a turn recorded from opencode 1.18.35 maps onto agent events through the common interface" {
    const recorded = try readFixture("recorded-turn.sse");
    defer testing.allocator.free(recorded);
    const response = try sseResponse(testing.allocator, recorded);
    defer testing.allocator.free(response);

    var scripted: ScriptedTransport = .{ .script = response };
    defer scripted.written.deinit(testing.allocator);
    var oc = try OpenCodeAdapter.init(testing.allocator, testing.io, .{ .port = 4096, .transport = scripted.transport(), .directory = "/tmp/proj" });
    const a = oc.adapter();
    defer a.destroy();

    var queue = try event.EventQueue.init(testing.allocator, testing.io, 64);
    defer queue.deinit(testing.allocator);
    var collected = try Collected.init();
    defer collected.deinit();
    while (scripted.at < scripted.script.len) {
        _ = try a.poll(&queue);
        collected.drain(&queue);
    }
    _ = try a.poll(&queue);
    collected.drain(&queue);

    // The server's first live turn: the human's prompt, busy, the bash tool
    // (OpenCode marks it `running` before it asks), its permission request
    // (answered outside Conduit), the answer and the end of the turn.
    // Startup `session.updated`/`session.diff`, step parts and the streamed
    // deltas add nothing of their own.
    var kinds_buffer: [64]event.Event.Kind = undefined;
    const K = event.Event.Kind;
    try testing.expectEqualSlices(K, &.{
        .message, .status_change, .tool_use, .permission_request, .permission_resolved, .message, .status_change,
    }, collected.kinds(&kinds_buffer));
    try testing.expectEqualStrings("run the marker", collected.at(0).message.text);
    try testing.expectEqual(State.working, collected.at(1).status_change.state);
    try testing.expectEqualStrings("bash", collected.at(2).tool_use.name);
    try testing.expectEqualStrings("echo conduit-live", collected.at(2).tool_use.summary);
    const request = collected.at(3).permission_request;
    try testing.expectEqualStrings("per_1195b1fc1001hVuStfUdg47luK", request.id);
    try testing.expectEqualStrings("bash: echo conduit-live", request.title);
    try testing.expectEqual(event.PermissionOutcome.resolved_elsewhere, collected.at(4).permission_resolved.outcome);
    try testing.expectEqual(event.Role.assistant, collected.at(5).message.role);
    try testing.expectEqualStrings("All done.", collected.at(5).message.text);
    try testing.expectEqual(State.done, collected.at(6).status_change.state);
    try testing.expectEqualStrings("ses_ee6a4e41affeQFeE4NibVv28Gd", oc.mapper.session.slice());

    // The recorded history replays the same turn as transcript events.
    const body = try readFixture("recorded-messages.json");
    defer testing.allocator.free(body);
    var history: ScriptedTransport = .{ .script = "" };
    defer history.written.deinit(testing.allocator);
    var replay = try OpenCodeAdapter.init(testing.allocator, testing.io, .{ .port = 4096, .transport = history.transport(), .directory = "/tmp/proj" });
    defer replay.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try replay.mapHistory(arena_state.allocator(), body);
    _ = replay.flush(&queue);
    var replayed = try Collected.init();
    defer replayed.deinit();
    replayed.drain(&queue);
    try testing.expectEqualSlices(K, &.{ .message, .tool_use, .message }, replayed.kinds(&kinds_buffer));
    try testing.expectEqualStrings("run the marker", replayed.at(0).message.text);
    try testing.expectEqualStrings("All done.", replayed.at(2).message.text);
}

test "older shapes, other sessions, errors, aborts and junk degrade gracefully" {
    const text = try readFixture("edge-cases.sse");
    defer testing.allocator.free(text);
    const response = try sseResponse(testing.allocator, text);
    defer testing.allocator.free(response);
    var scripted: ScriptedTransport = .{ .script = response, .read_size = 4096, .end_with_eof = true };
    defer scripted.written.deinit(testing.allocator);
    var oc = try testAdapter(scripted.transport());
    defer oc.deinit();
    const a = oc.adapter();

    var queue = try event.EventQueue.init(testing.allocator, testing.io, 64);
    defer queue.deinit(testing.allocator);
    var collected = try Collected.init();
    defer collected.deinit();
    _ = try a.poll(&queue);
    collected.drain(&queue);

    var kinds_buffer: [64]event.Event.Kind = undefined;
    try testing.expectEqualSlices(event.Event.Kind, &.{
        .status_change, .permission_request, .permission_resolved, .notification,
        .status_change, .notification,       .status_change,       .status_change,
    }, collected.kinds(&kinds_buffer));
    try testing.expectEqualStrings("Edit src/main.zig", collected.at(1).permission_request.title);
    try testing.expectEqual(event.PermissionOutcome.resolved_elsewhere, collected.at(2).permission_resolved.outcome);
    try testing.expectEqualStrings("rate limited", collected.at(3).notification.body);
    try testing.expectEqual(State.errored, collected.at(4).status_change.state);
    try testing.expectEqualStrings("provider exploded", collected.at(5).notification.body);
    // session.idle after an error changes nothing; busy starts a new turn;
    // an abort settles to idle, not errored.
    try testing.expectEqual(State.working, collected.at(6).status_change.state);
    try testing.expectEqual(State.idle, collected.at(7).status_change.state);
    try testing.expectEqual(@as(u64, 1), oc.malformed_events);
    // server.instance.disposed ended the stream: back to the baseline.
    try testing.expect(!a.capabilities().structured_status);
    try testing.expect(!scripted.open);
}

test "a server that accepts but never answers is given up and dialled again" {
    // Observed live with 1.18.35: a connection made while `opencode` was
    // still starting was accepted and never answered.
    var scripted: ScriptedTransport = .{ .script = "" };
    defer scripted.written.deinit(testing.allocator);
    var oc = try OpenCodeAdapter.init(testing.allocator, testing.io, .{
        .port = 4096,
        .transport = scripted.transport(),
        .request_timeout_ns = 0,
        .reconnect_min_ns = 0,
    });
    defer oc.deinit();
    const a = oc.adapter();
    var queue = try event.EventQueue.init(testing.allocator, testing.io, 4);
    defer queue.deinit(testing.allocator);
    // Past the (zero) request timeout with no head: closed and redialled,
    // rather than waited on for ever.
    for (0..3) |_| _ = try a.poll(&queue);
    try testing.expect(scripted.connects >= 2);
    try testing.expect(!oc.isConnected());

    // With the default timeout a slow head is still waited for.
    var patient: ScriptedTransport = .{ .script = "" };
    defer patient.written.deinit(testing.allocator);
    var slow = try OpenCodeAdapter.init(testing.allocator, testing.io, .{ .port = 4096, .transport = patient.transport(), .reconnect_min_ns = 0 });
    defer slow.deinit();
    for (0..3) |_| _ = try slow.adapter().poll(&queue);
    try testing.expectEqual(@as(usize, 1), patient.connects);
    try testing.expect(patient.open);
}

test "an unreachable server leaves the PTY baseline and retries with backoff" {
    var scripted: ScriptedTransport = .{ .script = "", .reachable = false };
    defer scripted.written.deinit(testing.allocator);
    var oc = try OpenCodeAdapter.init(testing.allocator, testing.io, .{
        .port = 4096,
        .transport = scripted.transport(),
        .reconnect_min_ns = std.time.ns_per_s * 60,
    });
    defer oc.deinit();
    const a = oc.adapter();
    var queue = try event.EventQueue.init(testing.allocator, testing.io, 4);
    defer queue.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), try a.poll(&queue));
    try testing.expectEqual(@as(usize, 0), try a.poll(&queue));
    // The second poll is inside the backoff window: no second attempt.
    try testing.expectEqual(@as(usize, 1), scripted.connects);
    const caps = a.capabilities();
    try testing.expect(caps.launch and caps.attach and caps.poll);
    try testing.expect(!caps.structured_status and !caps.permission_requests and !caps.transcript);
    try testing.expectError(error.Unsupported, a.sendInput("hi"));
    try testing.expectError(error.Unsupported, a.stop());
    // Requests made anyway (a stale view) report the server as gone.
    try testing.expectError(error.Disconnected, OpenCodeAdapter.respondPermission(&oc, "per_1", "once"));
}

test "a full queue keeps events in the adapter until the next poll" {
    const response = try sseResponse(testing.allocator,
        \\data: {"type":"session.status","properties":{"sessionID":"s","status":{"type":"busy"}}}
        \\
        \\data: {"type":"permission.asked","properties":{"id":"p","sessionID":"s","permission":"edit","patterns":["a.zig"]}}
        \\
        \\
    );
    defer testing.allocator.free(response);
    var scripted: ScriptedTransport = .{ .script = response, .read_size = 4096 };
    defer scripted.written.deinit(testing.allocator);
    var oc = try testAdapter(scripted.transport());
    defer oc.deinit();
    var queue = try event.EventQueue.init(testing.allocator, testing.io, 1);
    defer queue.deinit(testing.allocator);
    var collected = try Collected.init();
    defer collected.deinit();
    try testing.expectEqual(@as(usize, 1), try oc.adapter().poll(&queue));
    collected.drain(&queue);
    try testing.expectEqual(@as(usize, 1), try oc.adapter().poll(&queue));
    collected.drain(&queue);
    try testing.expectEqualStrings("edit: a.zig", collected.at(1).permission_request.title);
}

test "launch describes the TUI or the server, with the port, token and password" {
    var scripted: ScriptedTransport = .{ .script = "" };
    defer scripted.written.deinit(testing.allocator);
    var oc = try OpenCodeAdapter.init(testing.allocator, testing.io, .{ .port = 41234, .transport = scripted.transport() });
    defer oc.deinit();
    const a = oc.adapter();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const token = agent_adapter.CorrelationToken.fromBytes(@splat(0xab));

    const tui = try a.launch(arena, .{ .context_kind = .local, .cwd = "/work", .initial_prompt = "fix it", .token = token });
    const expected_tui = [_][]const u8{ "opencode", "--port", "41234", "--hostname", "127.0.0.1", "--prompt", "fix it" };
    try testing.expectEqual(expected_tui.len, tui.argv.len);
    for (expected_tui, tui.argv) |want, got| try testing.expectEqualStrings(want, got);
    try testing.expectEqualStrings("CONDUIT_AGENT_TOKEN=abababababababababababababababab", tui.env[0]);
    try testing.expectEqualStrings("OPENCODE_SERVER_USERNAME=opencode", tui.env[1]);
    try testing.expectEqualStrings("OPENCODE_SERVER_PASSWORD=abababababababababababababababab", tui.env[2]);
    try testing.expectEqualStrings("/work", oc.directory.?);
    try testing.expect(std.mem.startsWith(u8, oc.authorization.?, "Basic "));

    const served = try a.launch(arena, .{ .context_kind = .local, .cwd = "/work", .token = token, .headless = true });
    try testing.expectEqualStrings("serve", served.argv[1]);
    try testing.expectEqualStrings("41234", served.argv[3]);

    // Remote: the plain TUI and no side channel.
    var remote = try OpenCodeAdapter.init(testing.allocator, testing.io, .{ .port = 41234, .transport = scripted.transport() });
    defer remote.deinit();
    const r = try remote.adapter().launch(arena, .{ .context_kind = .ssh, .cwd = "/srv", .token = token });
    try testing.expectEqual(@as(usize, 1), r.argv.len);
    try testing.expectEqual(@as(usize, 1), r.env.len);
    var queue = try event.EventQueue.init(testing.allocator, testing.io, 1);
    defer queue.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), try remote.adapter().poll(&queue));
    try testing.expectEqual(@as(usize, 0), scripted.connects);
}

test "history replays a session's messages as transcript events once" {
    const body = try readFixture("messages.json");
    defer testing.allocator.free(body);
    var scripted: ScriptedTransport = .{ .script = "" };
    defer scripted.written.deinit(testing.allocator);
    var oc = try testAdapter(scripted.transport());
    defer oc.deinit();
    try oc.adapter().attach(.{ .session = .first, .token = agent_adapter.CorrelationToken.fromBytes(@splat(1)), .harness_session_id = "ses_main" });
    try testing.expectError(error.UnknownTarget, oc.adapter().attach(.{ .session = .first, .token = agent_adapter.CorrelationToken.fromBytes(@splat(1)) }));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try oc.mapHistory(arena_state.allocator(), body);
    var queue = try event.EventQueue.init(testing.allocator, testing.io, 64);
    defer queue.deinit(testing.allocator);
    var collected = try Collected.init();
    defer collected.deinit();
    _ = oc.flush(&queue);
    collected.drain(&queue);

    var kinds_buffer: [64]event.Event.Kind = undefined;
    try testing.expectEqualSlices(event.Event.Kind, &.{
        .message, .file_reference, .message, .tool_use, .file_reference, .tool_use,
    }, collected.kinds(&kinds_buffer));
    try testing.expectEqual(event.Role.user, collected.at(0).message.role);
    try testing.expectEqualStrings("build.zig", collected.at(1).file_reference.path);
    try testing.expectEqual(event.Role.assistant, collected.at(2).message.role);
    try testing.expectEqualStrings("edit", collected.at(3).tool_use.name);
    try testing.expectEqualStrings("zig build test", collected.at(5).tool_use.summary);

    // The same parts arriving live are not emitted twice.
    try oc.mapHistory(arena_state.allocator(), body);
    try testing.expectEqual(@as(usize, 0), oc.backlog.len);
    try testing.expectError(error.Protocol, oc.mapHistory(arena_state.allocator(), "{\"nope\":1}"));
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
    timeout_ms: u32 = 0,
    runs: usize = 0,

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

    fn run(ptr: *anyopaque, allocator: Allocator, _: Io, request: workspace.RunRequest) workspace.RunError!workspace.RunResult {
        const self: *ScriptedRunContext = @ptrCast(@alignCast(ptr));
        self.runs += 1;
        // The request's slices live for the call; the test reads only
        // string literals the adapter passed.
        self.argc = @min(request.argv.len, self.argv.len);
        @memcpy(self.argv[0..self.argc], request.argv[0..self.argc]);
        self.cwd = request.cwd;
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

test "detect runs opencode --version through the context and parses the version" {
    var scripted: ScriptedTransport = .{ .script = "" };
    defer scripted.written.deinit(testing.allocator);
    var oc = try OpenCodeAdapter.init(testing.allocator, testing.io, .{ .port = 4096, .transport = scripted.transport() });
    defer oc.deinit();
    const a = oc.adapter();
    try testing.expect(a.capabilities().detect);
    var version: [max_version_bytes]u8 = undefined;

    var installed: ScriptedRunContext = .{ .outcome = .{ .result = .{ .exit_code = 0, .stdout = "1.18.35\n" } } };
    try testing.expectEqualStrings("1.18.35", (try a.detect(.{ .context = installed.ref(), .version_buffer = &version })).?);
    try testing.expectEqual(@as(usize, 2), installed.argc);
    try testing.expectEqualStrings("opencode", installed.argv[0]);
    try testing.expectEqualStrings("--version", installed.argv[1]);
    try testing.expectEqualStrings("/", installed.cwd);
    try testing.expectEqual(@as(u32, detect_timeout_ms), installed.timeout_ms);

    var missing: ScriptedRunContext = .{ .outcome = .{ .fail = error.CommandNotFound } };
    try testing.expect((try a.detect(.{ .context = missing.ref(), .version_buffer = &version })) == null);
    var shell_missing: ScriptedRunContext = .{ .outcome = .{ .result = .{ .exit_code = 127 } } };
    try testing.expect((try a.detect(.{ .context = shell_missing.ref(), .version_buffer = &version })) == null);

    var cannot_run: ScriptedRunContext = .{ .outcome = .{ .fail = error.Unsupported } };
    try testing.expectError(error.Unsupported, a.detect(.{ .context = cannot_run.ref(), .version_buffer = &version }));
    var slow: ScriptedRunContext = .{ .outcome = .{ .fail = error.Timeout } };
    try testing.expectError(error.Protocol, a.detect(.{ .context = slow.ref(), .version_buffer = &version }));
    var failing: ScriptedRunContext = .{ .outcome = .{ .result = .{ .exit_code = 1, .stdout = "1.0.0\n" } } };
    try testing.expectError(error.Protocol, a.detect(.{ .context = failing.ref(), .version_buffer = &version }));
    var junk: ScriptedRunContext = .{ .outcome = .{ .result = .{ .exit_code = 0, .stdout = "\x1b[31m!!\n" } } };
    try testing.expectError(error.Protocol, a.detect(.{ .context = junk.ref(), .version_buffer = &version }));
    var tiny: [3]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, a.detect(.{ .context = installed.ref(), .version_buffer = &tiny }));

    // Launch remembered the cwd; later probes run there.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    _ = try a.launch(arena_state.allocator(), .{ .context_kind = .local, .cwd = "/work", .token = agent_adapter.CorrelationToken.fromBytes(@splat(1)) });
    _ = try a.detect(.{ .context = installed.ref(), .version_buffer = &version });
    try testing.expectEqualStrings("/work", installed.cwd);

    try testing.expectEqualStrings("1.18.35", parseVersion("opencode 1.18.35\nextra\n").?);
    try testing.expectEqualStrings("0.3.0-beta.1+abc", parseVersion("\r\n  v0.3.0-beta.1+abc  \r\n").?);
    for ([_][]const u8{ "", "\n\n", "opencode\n", "v\n", "1.0;rm\n", "1" ** (max_version_bytes + 1) }) |bad| {
        try testing.expect(parseVersion(bad) == null);
    }
}

// The fake OpenCode server: real TCP on 127.0.0.1, scripted from fixtures.

const FakeServer = struct {
    io: Io,
    server: Io.net.Server,
    before: []const u8,
    after: []const u8,
    sse_request: [2048]u8 = undefined,
    sse_request_len: usize = 0,
    post: [2048]u8 = undefined,
    post_len: usize = 0,
    failure: ?anyerror = null,

    fn port(self: *const FakeServer) u16 {
        return self.server.socket.address.getPort();
    }

    fn run(self: *FakeServer) void {
        self.serve() catch |err| {
            self.failure = err;
        };
    }

    fn serve(self: *FakeServer) !void {
        const sse = try self.server.accept(self.io);
        defer sse.close(self.io);
        self.sse_request_len = try readRequest(self.io, sse, &self.sse_request);
        try writeAllTo(self.io, sse, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n");
        try writeChunk(self.io, sse, self.before);

        const post = try self.server.accept(self.io);
        self.post_len = readRequest(self.io, post, &self.post) catch |err| {
            post.close(self.io);
            return err;
        };
        writeAllTo(self.io, post, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4\r\n\r\ntrue") catch {};
        post.close(self.io);

        try writeChunk(self.io, sse, self.after);
        try writeAllTo(self.io, sse, "0\r\n\r\n");
    }

    fn writeAllTo(io: Io, stream: Io.net.Stream, bytes: []const u8) !void {
        var writer = stream.writer(io, &.{});
        try writer.interface.writeAll(bytes);
    }

    fn writeChunk(io: Io, stream: Io.net.Stream, bytes: []const u8) !void {
        var head: [32]u8 = undefined;
        try writeAllTo(io, stream, try std.fmt.bufPrint(&head, "{x}\r\n", .{bytes.len}));
        try writeAllTo(io, stream, bytes);
        try writeAllTo(io, stream, "\r\n");
    }

    /// Read one request (head plus any Content-Length body) within 5 s.
    fn readRequest(io: Io, stream: Io.net.Stream, out: []u8) !usize {
        var len: usize = 0;
        while (true) {
            if (headEnd(out[0..len])) |end| {
                const content_length = blk: {
                    var lines = std.mem.splitSequence(u8, out[0..end], "\r\n");
                    while (lines.next()) |line| {
                        if (std.ascii.startsWithIgnoreCase(line, "content-length:"))
                            break :blk try std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " "), 10);
                    }
                    break :blk 0;
                };
                if (len >= end + content_length) return len;
            }
            if (len == out.len) return error.RequestTooLarge;
            const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } };
            const message = try stream.socket.receiveTimeout(io, out[len..], timeout);
            if (message.data.len == 0) return error.EndOfStream;
            len += message.data.len;
        }
    }
};

test "end to end against a fake OpenCode server over real TCP" {
    // Zig 0.16's threaded Io has no timed socket receive on Windows
    // (`net_receive` under a timeout is `ConcurrencyUnavailable` there), and
    // both `TcpConnection.read` and the fake server need one. Until the
    // adapter has a Windows read path this end-to-end claim is POSIX-only.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const before = try readFixture("turn-before-permission.sse");
    defer testing.allocator.free(before);
    const after = try readFixture("turn-after-permission.sse");
    defer testing.allocator.free(after);

    const io = testing.io;
    const address = try Io.net.IpAddress.parseIp4(server_host, 0);
    var fake: FakeServer = .{ .io = io, .server = try address.listen(io, .{ .reuse_address = true }), .before = before, .after = after };
    defer fake.server.deinit(io);
    const thread = try std.Thread.spawn(.{}, FakeServer.run, .{&fake});
    var joined = false;
    defer if (!joined) {
        // Unblock a server still waiting in accept, then join it.
        for (0..2) |_| {
            const kick = address.connect(io, .{ .mode = .stream }) catch break;
            kick.close(io);
        }
        thread.join();
    };

    var oc = try OpenCodeAdapter.init(testing.allocator, io, .{
        .port = fake.port(),
        .directory = "/work",
        .password = "pw",
        .poll_wait_ns = 50 * std.time.ns_per_ms,
    });
    defer oc.deinit();
    const a = oc.adapter();
    var queue = try event.EventQueue.init(testing.allocator, io, 64);
    defer queue.deinit(testing.allocator);
    var collected = try Collected.init();
    defer collected.deinit();

    const deadline = Io.Clock.awake.now(io).nanoseconds + 10 * std.time.ns_per_s;
    var answered = false;
    while (collected.len < 14 and Io.Clock.awake.now(io).nanoseconds < deadline) {
        _ = try a.poll(&queue);
        const seen = collected.len;
        collected.drain(&queue);
        for (collected.slots[seen..collected.len]) |*stored| {
            if (stored.event == .permission_request and !answered) {
                // The human clicks "Allow once" in Conduit.
                try a.respondPermission(stored.event.permission_request.id, stored.event.permission_request.decisions[0].id);
                answered = true;
            }
        }
    }
    thread.join();
    joined = true;
    if (fake.failure) |err| return err;
    try testing.expect(answered);
    try testing.expectEqual(@as(usize, 14), collected.len);

    const sse_request = fake.sse_request[0..fake.sse_request_len];
    try testing.expect(std.mem.startsWith(u8, sse_request, "GET /event?directory=%2Fwork HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, sse_request, "Accept: text/event-stream\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, sse_request, "Authorization: Basic b3BlbmNvZGU6cHc=\r\n") != null);
    // The exact permission answer on the wire.
    var expected_buffer: [512]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "POST /permission/per_1/reply?directory=%2Fwork HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\n" ++
        "Accept: application/json\r\nConnection: close\r\nAuthorization: Basic b3BlbmNvZGU6cHc=\r\n" ++
        "Content-Type: application/json\r\nContent-Length: 16\r\n\r\n{{\"reply\":\"once\"}}", .{fake.port()});
    try testing.expectEqualStrings(expected, fake.post[0..fake.post_len]);
    // Conduit answered, so the resolution is `allowed`, not elsewhere.
    try testing.expectEqual(event.PermissionOutcome.allowed, collected.at(8).permission_resolved.outcome);
    try testing.expectEqual(State.done, collected.at(13).status_change.state);
}

test "live: a real opencode serve, when installed" {
    // Zig 0.16's std cannot compile the environment block walk this test needs
    // for Windows, and OpenCode has no Windows read path anyway (TASK-5 notes).
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    // Pick a free port by binding 0 and releasing it.
    const probe_address = try Io.net.IpAddress.parseIp4(server_host, 0);
    var probe = try probe_address.listen(io, .{ .reuse_address = true });
    const port = probe.socket.address.getPort();
    probe.deinit(io);
    var port_text: [8]u8 = undefined;
    // The launcher is `#!/usr/bin/env node`: the child needs this process's
    // PATH (and the check's OPENCODE_CONFIG), passed explicitly as the other
    // live harness tests do.
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var child = std.process.spawn(io, .{
        .argv = &.{ "opencode", "serve", "--port", try std.fmt.bufPrint(&port_text, "{d}", .{port}), "--hostname", server_host },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        std.debug.print("skipping the live OpenCode check: cannot start `opencode serve` ({s}); OpenCode is not installed\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        child.kill(io);
    }

    var oc = try OpenCodeAdapter.init(testing.allocator, io, .{ .port = port, .poll_wait_ns = 100 * std.time.ns_per_ms });
    defer oc.deinit();
    var queue = try event.EventQueue.init(testing.allocator, io, 64);
    defer queue.deinit(testing.allocator);
    // A first start in a fresh home migrates its database and installs its
    // plugins before it listens; that took over 30 s in the container.
    const started = Io.Clock.awake.now(io).nanoseconds;
    const deadline = started + 120 * std.time.ns_per_s;
    while (!oc.isConnected() and Io.Clock.awake.now(io).nanoseconds < deadline) {
        oc.next_connect_ns = 0;
        _ = try oc.adapter().poll(&queue);
    }
    std.debug.print("live opencode: event stream {s} after {d} ms\n", .{
        if (oc.isConnected()) "connected" else "NOT connected",
        @divTrunc(Io.Clock.awake.now(io).nanoseconds - started, std.time.ns_per_ms),
    });
    try testing.expect(oc.isConnected());
    // A headless server has no session until one is created.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try oc.ensureSession(arena_state.allocator());
    try testing.expect(oc.mapper.session.len != 0);
    oc.history_pending = true;
    try oc.loadHistory();

    // A whole turn needs a model. `scripts/opencode-container-check.sh`
    // configures a fixed local one (`scripts/opencode-mock-provider.py`,
    // `permission.bash = "ask"`) and sets this variable; anywhere else the
    // check stops at the connection and the session above.
    if (testing.environ.getPosix("CONDUIT_OPENCODE_LIVE_TURN") == null) {
        std.debug.print("the live OpenCode turn needs CONDUIT_OPENCODE_LIVE_TURN and a configured mock model; connection and session only\n", .{});
        return;
    }
    const a = oc.adapter();
    try a.sendInput("run the marker");
    var out: [16]event.StoredEvent = undefined;
    var saw_working = false;
    var saw_tool = false;
    var saw_answer = false;
    var answered = false;
    var resolved: ?event.PermissionOutcome = null;
    var done = false;
    const turn_deadline = Io.Clock.awake.now(io).nanoseconds + 120 * std.time.ns_per_s;
    while (!done and Io.Clock.awake.now(io).nanoseconds < turn_deadline) {
        _ = try a.poll(&queue);
        const n = queue.drain(&out);
        for (out[0..n]) |*stored| {
            std.debug.print("live opencode event: {t}\n", .{std.meta.activeTag(stored.event)});
            switch (stored.event) {
                .status_change => |change| switch (change.state) {
                    .working => saw_working = true,
                    .done => done = saw_answer,
                    else => {},
                },
                .tool_use => |tool| if (std.mem.eql(u8, tool.name, "bash")) {
                    saw_tool = true;
                },
                .permission_request => |request| if (!answered) {
                    // The human's explicit answer, as the agent view sends it.
                    try testing.expectEqualStrings("bash: echo conduit-live", request.title);
                    try a.respondPermission(request.id, "once");
                    answered = true;
                },
                .permission_resolved => |r| resolved = r.outcome,
                .message => |m| if (m.role == .assistant and std.mem.eql(u8, m.text, "All done.")) {
                    saw_answer = true;
                },
                else => {},
            }
        }
    }
    try testing.expect(saw_working and saw_tool and answered and saw_answer and done);
    // Conduit answered, so the outcome is `allowed`, not "elsewhere".
    try testing.expectEqual(@as(?event.PermissionOutcome, .allowed), resolved);
}
