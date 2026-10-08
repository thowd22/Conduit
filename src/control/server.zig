//! The control endpoint server: a listener thread, one thread per client
//! connection (bounded), a token registry and the owner hand-off.
//!
//! Threads and ownership:
//! - The owner (UI) thread calls `start`, `issueToken`, `revokeWorkspace`,
//!   `service`, `complete` and `deinit`. It never blocks on a client.
//! - The listener thread only accepts, reaps finished connection threads and
//!   refuses connections beyond `Options.max_connections` with `Busy`.
//! - Each connection thread reads one newline-framed request at a time,
//!   validates it, resolves its token, refuses the scratchpad, submits it to
//!   the `Queue`, wakes the owner through `Waker`, waits (bounded) for the
//!   reply and writes it. One request is in flight per connection.
//! - `registry` and `connections` are guarded by `mutex`; the queue has its
//!   own lock. Lock order: `mutex` before the queue's, never the reverse.
//!
//! Security: the endpoint is a 0600 socket inside a private 0700 directory
//! (`platform.LocalSocketListener`), every request carries a workspace token
//! compared in constant time, only the enumerated methods exist, every size
//! is bounded, and request text is never logged.

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform");
const protocol = @import("protocol.zig");
const queue_mod = @import("queue.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.control);

pub const Queue = queue_mod.Queue;
pub const Request = queue_mod.Request;
pub const Ticket = queue_mod.Ticket;
pub const WorkspaceRef = queue_mod.WorkspaceRef;

/// Whether the endpoint runs: always in Debug builds, and in release builds
/// only when the `control.enabled` setting asks for it.
pub fn enabledIn(mode: std.builtin.OptimizeMode, setting_enabled: bool) bool {
    return setting_enabled or mode == .Debug;
}

/// `enabledIn` for this build.
pub fn isEnabled(setting_enabled: bool) bool {
    return enabledIn(builtin.mode, setting_enabled);
}

/// Wakes the owner's loop after a request was queued. Called from connection
/// threads; must be thread-safe and must not block (for example
/// `platform.Window.postDriverWake`, or a dedicated control wake event).
pub const Waker = struct {
    context: ?*anyopaque = null,
    wakeFn: *const fn (context: ?*anyopaque) void,

    fn wake(self: Waker) void {
        self.wakeFn(self.context);
    }
};

/// What the owner registered for one workspace.
pub const Scope = struct {
    workspace: WorkspaceRef,
    /// The workspace's permanent scratchpad session, which no request may name.
    scratchpad_session: u32,
};

/// What the owner does with one request.
pub const Disposition = union(enum) {
    /// Answer now.
    reply: protocol.Reply,
    /// The owner keeps the ticket and calls `Server.complete` later (for
    /// example after an asynchronous spawn). The request it borrowed stays
    /// valid until then.
    deferred,
};

/// The owner's implementation of the API, called on the owner thread from
/// `service`. Part two implements it in `app`: it validates that `session`
/// belongs to `workspace`, performs the action through the workspace (and its
/// ExecutionContext), and never touches the scratchpad.
pub const Handler = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        handle: *const fn (context: *anyopaque, ticket: Ticket, request: *const Request) Disposition,
    };
};

pub const Options = struct {
    /// Absolute socket path inside a private (0700) run directory, for
    /// example `<run state dir>/control.sock`. Copied.
    endpoint: []const u8,
    /// The `control.enabled` setting. See `enabledIn`.
    enabled: bool = false,
    waker: Waker,
    /// How long a connection waits for the owner before replying `TimedOut`.
    reply_timeout_ms: u32 = 5000,
    /// Concurrent client connections; more are refused with `Busy`.
    max_connections: u16 = 32,
    /// Requests waiting for or held by the owner; more are refused with `Busy`.
    queue_capacity: u16 = 32,
    /// Workspaces with a live token.
    max_workspaces: u16 = 256,
};

const Registration = struct {
    token: protocol.Token,
    scope: Scope,
};

const Connection = struct {
    state: enum { free, running, finished } = .free,
    thread: ?std.Thread = null,
    stream: ?std.Io.net.Stream = null,
};

pub const Server = struct {
    allocator: Allocator,
    io: std.Io,
    endpoint: []u8,
    listener: platform.LocalSocketListener,
    waker: Waker,
    reply_timeout: std.Io.Duration,
    queue: Queue,
    listener_thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),

    mutex: std.Io.Mutex = .init,
    registry: []Registration,
    registry_len: usize = 0,
    connections: []Connection,

    pub const StartError = platform.LocalSocketListener.ListenError || error{Disabled};

    /// Listen at `options.endpoint` and start the listener thread. Owner thread.
    pub fn start(allocator: Allocator, io: std.Io, options: Options) StartError!*Server {
        if (!isEnabled(options.enabled)) return error.Disabled;
        std.debug.assert(options.max_connections != 0 and options.queue_capacity != 0 and options.max_workspaces != 0);

        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);
        const endpoint = try allocator.dupe(u8, options.endpoint);
        errdefer allocator.free(endpoint);
        var queue = try Queue.init(allocator, io, options.queue_capacity);
        errdefer queue.deinit(allocator);
        const registry = try allocator.alloc(Registration, options.max_workspaces);
        errdefer allocator.free(registry);
        const connections = try allocator.alloc(Connection, options.max_connections);
        errdefer allocator.free(connections);
        @memset(connections, .{});
        var listener = try platform.LocalSocketListener.listen(io, endpoint);
        errdefer listener.deinit(io, endpoint);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .endpoint = endpoint,
            .listener = listener,
            .waker = options.waker,
            .reply_timeout = .fromMilliseconds(options.reply_timeout_ms),
            .queue = queue,
            .registry = registry,
            .connections = connections,
        };
        self.listener_thread = std.Thread.spawn(.{}, listenerMain, .{self}) catch return error.ThreadSpawnFailed;
        return self;
    }

    /// The socket path children receive as `CONDUIT_CONTROL_ENDPOINT`.
    pub fn endpointPath(self: *const Server) []const u8 {
        return self.endpoint;
    }

    /// Register (or rotate) `scope.workspace`'s token from 16 random bytes the
    /// owner supplies. A previous token for that workspace stops working at
    /// once. Owner thread.
    pub fn issueToken(self: *Server, scope: Scope, entropy: [protocol.Token.byte_count]u8) error{TooManyWorkspaces}!protocol.Token {
        const token = protocol.Token.fromBytes(entropy);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.registry[0..self.registry_len]) |*entry| {
            if (entry.scope.workspace == scope.workspace) {
                entry.* = .{ .token = token, .scope = scope };
                return token;
            }
        }
        if (self.registry_len == self.registry.len) return error.TooManyWorkspaces;
        self.registry[self.registry_len] = .{ .token = token, .scope = scope };
        self.registry_len += 1;
        return token;
    }

    /// Expire `workspace`'s token, for example when the workspace closes.
    /// Requests already queued under it are refused by `service`. Owner thread.
    pub fn revokeWorkspace(self: *Server, workspace: WorkspaceRef) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.registry[0..self.registry_len], 0..) |entry, index| {
            if (entry.scope.workspace != workspace) continue;
            self.registry[index] = self.registry[self.registry_len - 1];
            self.registry_len -= 1;
            return;
        }
    }

    /// Resolve a token. Every registered token is compared, in constant time
    /// each, so the scan's duration does not depend on which one matched.
    pub fn resolve(self: *Server, token: protocol.Token) ?Scope {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var found: ?Scope = null;
        for (self.registry[0..self.registry_len]) |entry| {
            if (entry.token.eql(token)) found = entry.scope;
        }
        return found;
    }

    /// Perform up to `max` queued requests through `handler`. Owner thread;
    /// call it on every loop iteration after a wake. Returns how many were
    /// taken. A request whose token was revoked after it was queued is
    /// refused here without reaching the handler.
    pub fn service(self: *Server, handler: Handler, max: usize) usize {
        var count: usize = 0;
        while (count < max) : (count += 1) {
            const taken = self.queue.take() orelse break;
            const scope = self.resolve(taken.token);
            if (scope == null or scope.?.workspace != taken.request.workspace) {
                _ = self.queue.complete(taken.ticket, .{ .fault = .unauthorized });
                continue;
            }
            switch (handler.vtable.handle(handler.context, taken.ticket, taken.request)) {
                .reply => |reply| _ = self.queue.complete(taken.ticket, reply),
                .deferred => {},
            }
        }
        return count;
    }

    /// Answer a deferred request. A ticket whose client already gave up is
    /// released quietly. Owner thread.
    pub fn complete(self: *Server, ticket: Ticket, reply: protocol.Reply) void {
        if (!self.queue.complete(ticket, reply)) log.debug("control reply for a stale ticket ignored", .{});
    }

    /// Stop accepting, wake and join every thread, remove the socket and free
    /// everything. Owner thread; call once.
    pub fn deinit(self: *Server) void {
        self.stopping.store(true, .release);
        self.queue.stop();
        shutdownStream(self.io, .{ .socket = self.listener.server.socket });
        // Darwin's shutdown(2) refuses a listening socket and leaves a blocked
        // accept(2) asleep, where Linux's wakes it, so the join below would
        // wait forever (TASK-5). One connection to the server's own endpoint
        // wakes it there; the listener sees `stopping` and refuses it. The
        // connection stays open until the join so that refusal never writes
        // to a closed peer.
        var waker: ?std.Io.net.Stream = null;
        if (comptime builtin.os.tag != .linux) {
            if (std.Io.net.UnixAddress.init(self.endpoint)) |address| {
                waker = address.connect(self.io) catch null;
            } else |_| {}
        }
        if (self.listener_thread) |thread| thread.join();
        if (waker) |stream| stream.close(self.io);

        self.mutex.lockUncancelable(self.io);
        for (self.connections) |*connection| {
            if (connection.stream) |stream| shutdownStream(self.io, stream);
        }
        self.mutex.unlock(self.io);
        for (self.connections) |*connection| {
            if (connection.thread) |thread| thread.join();
            connection.* = .{};
        }

        self.listener.deinit(self.io, self.endpoint);
        self.queue.deinit(self.allocator);
        const allocator = self.allocator;
        allocator.free(self.registry);
        allocator.free(self.connections);
        allocator.free(self.endpoint);
        allocator.destroy(self);
    }

    fn listenerMain(self: *Server) void {
        while (!self.stopping.load(.acquire)) {
            const stream = self.listener.server.accept(self.io) catch |err| {
                if (self.stopping.load(.acquire)) return;
                log.warn("control accept failed: {s}", .{@errorName(err)});
                // Back off so a persistent failure (descriptor exhaustion) does not spin; the
                // listener stays up for when it clears. `deinit` wakes the accept, not this wait.
                std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(100), .clock = .awake }, self.io) catch {};
                continue;
            };
            self.adopt(stream);
        }
    }

    /// Give `stream` a connection thread, or refuse it with `Busy`.
    fn adopt(self: *Server, stream: std.Io.net.Stream) void {
        var finished: ?std.Thread = null;
        const slot = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.stopping.load(.acquire)) break :blk null;
            for (self.connections) |*connection| {
                if (connection.state == .running) continue;
                if (connection.state == .finished) finished = connection.thread;
                connection.* = .{ .state = .running, .stream = stream };
                break :blk connection;
            }
            break :blk null;
        };
        // A finished thread has released its stream; joining only reaps it.
        if (finished) |thread| thread.join();
        const connection = slot orelse {
            writeFrame(self.io, stream, null, .{ .fault = .busy });
            stream.close(self.io);
            return;
        };
        const thread = std.Thread.spawn(.{}, connectionMain, .{ self, connection }) catch {
            self.mutex.lockUncancelable(self.io);
            connection.* = .{};
            self.mutex.unlock(self.io);
            writeFrame(self.io, stream, null, .{ .fault = .busy });
            stream.close(self.io);
            return;
        };
        self.mutex.lockUncancelable(self.io);
        connection.thread = thread;
        self.mutex.unlock(self.io);
    }

    fn connectionMain(self: *Server, connection: *Connection) void {
        const stream = connection.stream.?;
        self.serve(stream);
        self.mutex.lockUncancelable(self.io);
        // Close under the lock so `deinit` never shuts down a reused descriptor.
        stream.close(self.io);
        connection.stream = null;
        connection.state = .finished;
        self.mutex.unlock(self.io);
    }

    fn serve(self: *Server, stream: std.Io.net.Stream) void {
        const buffer = self.allocator.alloc(u8, protocol.max_frame_bytes + 1) catch {
            writeFrame(self.io, stream, null, .{ .fault = .busy });
            return;
        };
        defer self.allocator.free(buffer);
        var reader = stream.reader(self.io, buffer);

        while (!self.stopping.load(.acquire)) {
            const framed = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    // The rest of the oversized line cannot be resynchronised.
                    writeFrame(self.io, stream, null, .{ .fault = .invalid_request });
                    return;
                },
                error.EndOfStream, error.ReadFailed => return,
            };
            var frame = framed[0 .. framed.len - 1];
            if (frame.len != 0 and frame[frame.len - 1] == '\r') frame = frame[0 .. frame.len - 1];
            if (frame.len == 0) continue;
            const reply = self.handleFrame(frame);
            writeFrame(self.io, stream, reply.id.get(), reply.reply);
        }
    }

    const FrameReply = struct {
        id: protocol.IdCopy,
        reply: protocol.Reply,
    };

    fn handleFrame(self: *Server, frame: []const u8) FrameReply {
        var parsed = protocol.parseFrame(self.allocator, frame) catch {
            return .{ .id = .{}, .reply = .{ .fault = .busy } };
        };
        var owned = true;
        defer if (owned) parsed.deinit();

        const envelope = switch (parsed.outcome) {
            .failure => |failure| return .{ .id = .from(failure.id), .reply = .{ .fault = failure.fault } },
            .envelope => |envelope| envelope,
        };
        const id: protocol.IdCopy = .from(envelope.id);
        const scope = self.resolve(envelope.token) orelse return .{ .id = id, .reply = .{ .fault = .unauthorized } };
        if (envelope.session) |session| if (session == scope.scratchpad_session) {
            return .{ .id = id, .reply = .{ .fault = .scratchpad_not_addressable } };
        };
        log.debug("control request {s}", .{std.meta.activeTag(envelope.params).wireName()});

        const ticket = self.queue.submit(parsed, envelope.token, .{
            .workspace = scope.workspace,
            .session = envelope.session,
            .params = envelope.params,
        }) catch |err| return .{ .id = id, .reply = .{ .fault = switch (err) {
            error.Busy => .busy,
            error.Stopped => .unavailable,
        } } };
        owned = false;
        self.waker.wake();
        return switch (self.queue.wait(ticket, self.reply_timeout)) {
            .reply => |reply| .{ .id = id, .reply = reply },
            .timed_out => .{ .id = id, .reply = .{ .fault = .timed_out } },
            .stopped => .{ .id = id, .reply = .{ .fault = .unavailable } },
        };
    }
};

fn writeFrame(io: std.Io, stream: std.Io.net.Stream, id: ?protocol.RequestId, reply: protocol.Reply) void {
    var encoded: [protocol.max_reply_bytes]u8 = undefined;
    // Ids are bounded and messages fixed, so a reply always fits.
    const bytes = protocol.encodeReply(&encoded, id, reply) catch unreachable;
    var buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    writer.interface.writeAll(bytes) catch return;
    writer.interface.writeByte('\n') catch return;
    // A client that hung up gets nothing; there is no one left to tell.
    writer.interface.flush() catch return;
}

fn shutdownStream(io: std.Io, stream: std.Io.net.Stream) void {
    // Shutdown only cancels a blocked accept or read; a peer that already
    // left (or a listener with no connection) needs no cancelling.
    stream.shutdown(io, .both) catch {};
}
