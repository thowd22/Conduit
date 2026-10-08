//! The accessibility bridge: exposes the semantic tree to platform
//! accessibility APIs (TASK-68).
//!
//! The semantic tree is the only source (invariant 3). After a frame the
//! owner thread `publish`es the tree; the bridge copies it into an immutable
//! `Snapshot` and hands that to its worker thread through a one-slot mailbox
//! (a newer snapshot replaces one the worker has not taken yet). The worker
//! never touches `ui`. Requests from an assistive technology (activate,
//! focus) travel the other way through a bounded queue that the owner drains
//! on its loop tick, so AT never runs code outside the owner thread.
//!
//! On Linux the worker speaks AT-SPI2 over D-Bus (`accessibility/atspi.zig`,
//! `accessibility/dbus.zig`): it finds the accessibility bus through
//! `org.a11y.Bus.GetAddress` on the session bus, embeds the application into
//! the registry with `org.a11y.atspi.Socket.Embed`, serves the snapshot as
//! AT-SPI objects and emits `Object` events when snapshots differ. macOS and
//! Windows are planned in `docs/accessibility.md`; there the bridge is off.
//!
//! Threads: `publish`, `drainRequests`, `setScreenOrigin` and `deinit` run on
//! the owner (main) thread. The worker owns the bus connection. The mailbox
//! and request queue are guarded by `mutex`; `status` is atomic.
//!
//! Memory: `init` allocates everything: four snapshot buffers, the request
//! ring and, on the worker, the connection buffers. `publish` and
//! `drainRequests` allocate nothing.

const std = @import("std");
const builtin = @import("builtin");
const ui = @import("ui");

pub const dbus = @import("accessibility/dbus.zig");
pub const atspi = @import("accessibility/atspi.zig");
pub const snapshot = @import("accessibility/snapshot.zig");
pub const Snapshot = snapshot.Snapshot;

const log = std.log.scoped(.accessibility);
const linux = std.os.linux;

/// Wakes the owner's loop after an AT request was queued. Called from the
/// worker thread; must be thread-safe and must not block (for example
/// `platform.Window.postDriverWake`).
pub const Waker = struct {
    context: ?*anyopaque = null,
    wakeFn: *const fn (context: ?*anyopaque) void,
};

/// Bridge configuration. Strings are copied by `init`.
pub const Options = struct {
    /// The `accessibility.enabled` setting. When false the bridge starts no
    /// thread and `publish` is a no-op.
    enabled: bool = true,
    /// `DBUS_SESSION_BUS_ADDRESS`. Null means no session bus: the bridge is
    /// off.
    session_bus_address: ?[]const u8 = null,
    /// The application and window name screen readers announce.
    application_name: []const u8 = "Conduit",
    /// Reported as `Application.Version`.
    version: []const u8 = "0.0.0-dev",
    waker: ?Waker = null,
    /// The most elements one snapshot holds; more are dropped.
    node_capacity: u32 = 2048,
    /// The most label, id, role and action bytes one snapshot holds.
    string_capacity: u32 = 128 * 1024,
    /// How long each bus call during start-up may take, in milliseconds.
    call_timeout_ms: i32 = 2000,
};

/// What an assistive technology asks the owner to do.
pub const RequestKind = atspi.RequestKind;

/// The longest element id a request carries; longer ids are refused.
pub const max_request_id_bytes = 256;

/// The most requests queued before the owner drains them; more are refused
/// (the AT sees `false` from `DoAction`/`GrabFocus`).
pub const request_capacity = 32;

/// One AT request: activate or focus the element with semantic id `id()`.
pub const Request = struct {
    kind: RequestKind,
    id_buf: [max_request_id_bytes]u8 = undefined,
    id_len: u16 = 0,

    pub fn id(self: *const Request) []const u8 {
        return self.id_buf[0..self.id_len];
    }
};

/// Whether the bridge is serving.
pub const Status = enum(u8) {
    /// Connecting to the session and accessibility buses.
    starting,
    /// Embedded and serving the tree.
    connected,
    /// Disabled, unsupported, or the bus is unavailable or went away.
    off,
};

/// Read sizes for the two connections. Incoming AT calls are small; replies
/// can be large (`Cache.GetItems` over a full snapshot).
const session_read_capacity = 64 * 1024;
const session_write_capacity = 64 * 1024;
const bus_read_capacity = 256 * 1024;
const bus_write_capacity = dbus.max_message_bytes;

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    enabled: bool,
    session_address: ?[]u8,
    application_name: []u8,
    version: []u8,
    waker: ?Waker,
    call_timeout_ms: i32,

    /// Four buffers: the owner's back buffer, the mailbox or a spare, and
    /// the worker's current and incoming snapshots while it diffs them.
    buffers: [4]Snapshot,
    /// Owner only.
    back: u8 = 0,
    /// Worker only.
    front: u8 = 1,
    /// Guarded by `mutex`.
    mailbox: ?u8 = null,
    spares: [2]u8 = .{ 2, 3 },
    spare_len: u8 = 2,
    /// Owner only: the fingerprint last handed to the worker.
    published: ?u64 = null,

    requests: [request_capacity]Request = undefined,
    request_head: usize = 0,
    request_len: usize = 0,

    mutex: std.Io.Mutex = .init,
    screen_x: std.atomic.Value(i32) = .init(0),
    screen_y: std.atomic.Value(i32) = .init(0),
    status: std.atomic.Value(Status) = .init(.off),
    stopping: std.atomic.Value(bool) = .init(false),
    /// Read end then write end of the worker's wake pipe.
    wake_pipe: [2]i32 = .{ -1, -1 },
    thread: ?std.Thread = null,

    /// Create the bridge and, when enabled on a supported platform with a
    /// session bus, start its worker. Never fails because a bus is missing:
    /// the bridge is then simply `off`. Fails only on allocation, pipe or
    /// thread creation. The caller owns the result and calls `deinit`.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !*Bridge {
        const self = try allocator.create(Bridge);
        errdefer allocator.destroy(self);
        const session_address = if (options.session_bus_address) |a| try allocator.dupe(u8, a) else null;
        errdefer if (session_address) |a| allocator.free(a);
        const application_name = try allocator.dupe(u8, options.application_name);
        errdefer allocator.free(application_name);
        const version = try allocator.dupe(u8, options.version);
        errdefer allocator.free(version);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .enabled = options.enabled,
            .session_address = session_address,
            .application_name = application_name,
            .version = version,
            .waker = options.waker,
            .call_timeout_ms = options.call_timeout_ms,
            .buffers = undefined,
        };
        var made: usize = 0;
        errdefer for (self.buffers[0..made]) |*b| b.deinit();
        for (&self.buffers) |*b| {
            b.* = try Snapshot.init(allocator, options.node_capacity, options.string_capacity);
            made += 1;
            b.begin(ui.Bounds.empty);
            b.finish();
        }

        if (!options.enabled) {
            log.info("accessibility bridge disabled by setting", .{});
            return self;
        }
        if (builtin.os.tag != .linux) {
            log.info("accessibility bridge not implemented on this platform", .{});
            return self;
        }
        if (session_address == null) {
            log.info("accessibility bridge off: no session bus", .{});
            return self;
        }
        var fds: [2]i32 = undefined;
        if (linux.errno(linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true })) != .SUCCESS) {
            return error.PipeFailed;
        }
        self.wake_pipe = fds;
        errdefer {
            _ = linux.close(fds[0]);
            _ = linux.close(fds[1]);
        }
        self.status.store(.starting, .release);
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
        return self;
    }

    /// Stop the worker, close the bus and free everything.
    pub fn deinit(self: *Bridge) void {
        if (self.thread) |thread| {
            self.stopping.store(true, .release);
            self.wakeWorker();
            thread.join();
        }
        if (self.wake_pipe[0] >= 0) {
            _ = linux.close(self.wake_pipe[0]);
            _ = linux.close(self.wake_pipe[1]);
        }
        for (&self.buffers) |*b| b.deinit();
        if (self.session_address) |a| self.allocator.free(a);
        self.allocator.free(self.application_name);
        self.allocator.free(self.version);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// The bridge's current state.
    pub fn currentStatus(self: *const Bridge) Status {
        return self.status.load(.acquire);
    }

    /// Where the window's top-left corner is on screen, for screen
    /// coordinates. Defaults to (0, 0); Wayland exposes no global position.
    pub fn setScreenOrigin(self: *Bridge, x: i32, y: i32) void {
        self.screen_x.store(x, .release);
        self.screen_y.store(y, .release);
    }

    /// Copy `tree` for the worker if it changed since the last publish.
    /// Call on the owner thread after a frame's tree is complete. Allocation
    /// free; a no-op while the bridge is off.
    pub fn publish(self: *Bridge, tree: *const ui.Tree) void {
        if (self.status.load(.acquire) == .off) return;
        const back = &self.buffers[self.back];
        back.capture(tree);
        if (self.published) |fingerprint| if (fingerprint == back.fingerprint) return;
        if (back.truncated) log.debug("accessibility snapshot truncated to {d} elements", .{back.len});
        self.published = back.fingerprint;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.mailbox) |stale| {
                // The worker has not taken the previous snapshot: replace it.
                self.mailbox = self.back;
                self.back = stale;
            } else {
                self.mailbox = self.back;
                self.spare_len -= 1;
                self.back = self.spares[self.spare_len];
            }
        }
        self.wakeWorker();
    }

    /// Hand every queued AT request to `handler(context, request)` on the
    /// owner thread, in arrival order. Returns how many were handled.
    pub fn drainRequests(
        self: *Bridge,
        context: anytype,
        comptime handler: fn (@TypeOf(context), *const Request) void,
    ) usize {
        var taken: [request_capacity]Request = undefined;
        var count: usize = 0;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            while (self.request_len > 0) : (count += 1) {
                taken[count] = self.requests[self.request_head];
                self.request_head = (self.request_head + 1) % request_capacity;
                self.request_len -= 1;
            }
        }
        for (taken[0..count]) |*request| handler(context, request);
        return count;
    }

    // -- worker side -------------------------------------------------------

    fn wakeWorker(self: *Bridge) void {
        if (self.wake_pipe[1] < 0) return;
        const byte = [1]u8{1};
        // A full pipe already holds a pending wake, so EAGAIN is success.
        _ = linux.write(self.wake_pipe[1], &byte, 1);
    }

    fn drainWake(self: *Bridge) void {
        var buf: [64]u8 = undefined;
        while (true) {
            const rc = linux.read(self.wake_pipe[0], &buf, buf.len);
            if (linux.errno(rc) != .SUCCESS or rc == 0) return;
        }
    }

    /// Queue a request from the worker. False when the queue is full or the
    /// id is too long.
    fn pushRequest(context: *anyopaque, kind: RequestKind, id: []const u8) bool {
        const self: *Bridge = @ptrCast(@alignCast(context));
        if (id.len > max_request_id_bytes) return false;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.request_len == request_capacity) return false;
            const slot = &self.requests[(self.request_head + self.request_len) % request_capacity];
            slot.* = .{ .kind = kind, .id_len = @intCast(id.len) };
            @memcpy(slot.id_buf[0..id.len], id);
            self.request_len += 1;
        }
        if (self.waker) |waker| waker.wakeFn(waker.context);
        return true;
    }

    /// Take the mailbox snapshot, if any. The worker keeps both the old
    /// front and the new one until `release` returns the old one.
    fn take(self: *Bridge) ?u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const incoming = self.mailbox orelse return null;
        self.mailbox = null;
        return incoming;
    }

    fn release(self: *Bridge, old: u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.spares[self.spare_len] = old;
        self.spare_len += 1;
    }

    fn workerMain(self: *Bridge) void {
        self.serve() catch |err| {
            if (!self.stopping.load(.acquire)) log.info("accessibility bridge off: {s}", .{@errorName(err)});
        };
        self.status.store(.off, .release);
    }

    /// Ask the session bus where the accessibility bus is.
    fn discover(self: *Bridge, buf: []u8) ![]const u8 {
        var session = try dbus.Connection.open(self.allocator, self.session_address.?, session_read_capacity, session_write_capacity);
        defer session.close();
        try session.hello(self.call_timeout_ms, self.io);
        const reply = try session.call(.{
            .type = .method_call,
            .serial = 0,
            .path = "/org/a11y/bus",
            .interface = "org.a11y.Bus",
            .member = "GetAddress",
            .destination = "org.a11y.Bus",
        }, "", self.call_timeout_ms, self.io);
        if (!std.mem.eql(u8, reply.signature, "s")) return error.Malformed;
        var r = reply.bodyReader();
        const address = try r.string();
        if (address.len > buf.len) return error.Malformed;
        @memcpy(buf[0..address.len], address);
        return buf[0..address.len];
    }

    fn serve(self: *Bridge) !void {
        var address_buf: [1024]u8 = undefined;
        const address = try self.discover(&address_buf);
        var bus = try dbus.Connection.open(self.allocator, address, bus_read_capacity, bus_write_capacity);
        defer bus.close();
        try bus.hello(self.call_timeout_ms, self.io);

        var embed_body_buf: [512]u8 = undefined;
        var embed_body = dbus.Writer.init(&embed_body_buf);
        try embed_body.reference(bus.uniqueName(), atspi.root_path);
        const embed_serial = bus.nextSerial();
        try bus.send(.{
            .type = .method_call,
            .serial = embed_serial,
            .path = atspi.root_path,
            .interface = "org.a11y.atspi.Socket",
            .member = "Embed",
            .destination = "org.a11y.atspi.Registry",
            .signature = "(so)",
        }, embed_body.written());
        self.status.store(.connected, .release);
        log.info("accessibility bridge connected as {s}", .{bus.uniqueName()});

        var worker: Worker = .{ .bridge = self, .bus = &bus, .embed_serial = embed_serial };
        try worker.run();
    }
};

/// The worker's per-connection state.
const Worker = struct {
    bridge: *Bridge,
    bus: *dbus.Connection,
    embed_serial: u32,
    parent_name_buf: [255]u8 = undefined,
    parent_name_len: usize = 0,
    parent_path_buf: [255]u8 = undefined,
    parent_path_len: usize = 0,
    app_id: i32 = 0,
    events: [atspi.max_events_per_diff]atspi.Event = undefined,

    fn run(self: *Worker) !void {
        const bridge = self.bridge;
        while (!bridge.stopping.load(.acquire)) {
            try self.applySnapshot();
            var fds = [_]linux.pollfd{
                .{ .fd = self.bus.fd, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = bridge.wake_pipe[0], .events = linux.POLL.IN, .revents = 0 },
            };
            const rc = linux.poll(&fds, fds.len, -1);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return error.PollFailed,
            }
            if (fds[1].revents != 0) bridge.drainWake();
            if (fds[0].revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) != 0) {
                if (!try self.bus.fill()) return error.Disconnected;
                while (try self.bus.next()) |message| try self.dispatch(&message);
            }
        }
    }

    fn service(self: *Worker) atspi.Service {
        const bridge = self.bridge;
        return .{
            .snap = &bridge.buffers[bridge.front],
            .bus_name = self.bus.uniqueName(),
            .parent_name = self.parent_name_buf[0..self.parent_name_len],
            .parent_path = if (self.parent_path_len == 0) atspi.null_path else self.parent_path_buf[0..self.parent_path_len],
            .app_name = bridge.application_name,
            .toolkit_version = bridge.version,
            .app_id = &self.app_id,
            .screen_x = bridge.screen_x.load(.acquire),
            .screen_y = bridge.screen_y.load(.acquire),
            .requests = .{ .context = bridge, .pushFn = Bridge.pushRequest },
        };
    }

    fn dispatch(self: *Worker, message: *const dbus.Message) !void {
        switch (message.type) {
            .method_call => {
                const svc = self.service();
                var body = dbus.Writer.init(self.bus.bodyScratch());
                const reply = svc.handle(message, &body);
                if (!message.wantsReply()) return;
                const sender = message.sender orelse return;
                switch (reply) {
                    .ok => |signature| try self.bus.sendScratch(.{
                        .type = .method_return,
                        .serial = self.bus.nextSerial(),
                        .reply_serial = message.serial,
                        .destination = sender,
                        .signature = signature,
                    }, body.len),
                    .err => |e| {
                        body = dbus.Writer.init(self.bus.bodyScratch());
                        try body.string(e.message);
                        try self.bus.sendScratch(.{
                            .type = .@"error",
                            .serial = self.bus.nextSerial(),
                            .reply_serial = message.serial,
                            .destination = sender,
                            .error_name = e.name,
                            .signature = "s",
                        }, body.len);
                    },
                }
            },
            .method_return => {
                if (message.reply_serial != self.embed_serial) return;
                if (!std.mem.eql(u8, message.signature, "(so)")) return;
                var r = message.bodyReader();
                r.beginStruct() catch return;
                const name = r.string() catch return;
                const path = r.objectPath() catch return;
                if (name.len > self.parent_name_buf.len or path.len > self.parent_path_buf.len) return;
                @memcpy(self.parent_name_buf[0..name.len], name);
                self.parent_name_len = name.len;
                @memcpy(self.parent_path_buf[0..path.len], path);
                self.parent_path_len = path.len;
                log.info("accessibility bridge embedded in the AT-SPI registry", .{});
            },
            .@"error" => if (message.reply_serial == self.embed_serial) {
                // Without a registry nothing discovers us, but a client that
                // already knows our name can still walk the tree.
                log.info("accessibility registry refused Embed: {s}", .{message.error_name orelse "?"});
            },
            else => {},
        }
    }

    /// Take a pending snapshot, emit the events that describe the change,
    /// then make it current.
    fn applySnapshot(self: *Worker) !void {
        const bridge = self.bridge;
        const incoming = bridge.take() orelse return;
        const old = bridge.front;
        const count = atspi.diff(&bridge.buffers[old], &bridge.buffers[incoming], &self.events);
        // Make the new snapshot current before emitting, so a reader that
        // reacts to an event queries the state it describes.
        bridge.front = incoming;
        bridge.release(old);
        for (self.events[0..count]) |event| {
            // A name event borrows its label from the new snapshot, which is
            // now `front` and stays alive until the next `applySnapshot`.
            var path_buf: [atspi.element_path_len]u8 = undefined;
            var body = dbus.Writer.init(self.bus.bodyScratch());
            const signal = try atspi.encodeEvent(event, self.bus.uniqueName(), &path_buf, &body);
            try self.bus.sendScratch(.{
                .type = .signal,
                .serial = self.bus.nextSerial(),
                .path = signal.path,
                .interface = atspi.iface_event_object,
                .member = signal.member,
                .signature = "siiva{sv}",
            }, body.len);
        }
    }
};

test {
    _ = dbus;
    _ = atspi;
    _ = snapshot;
}

// ---------------------------------------------------------------------------
// Integration: a private bus, a fake registry, the real bridge, a test client
// ---------------------------------------------------------------------------

const testing = std.testing;

/// The pieces the integration test and the app's `--a11y-test` share: a
/// private `dbus-daemon`, a stand-in for the AT-SPI bus launcher and
/// registry, and a plain bus client playing the assistive technology. Test
/// support only; nothing in a normal run uses it. Every call takes the
/// caller's `io` so it works outside `zig test` too.
pub const check = struct {
    pub const PrivateBus = CheckBus;
    pub const FakeRegistry = CheckRegistry;
    pub const Client = CheckClient;
};

const PrivateBus = CheckBus;
const FakeRegistry = CheckRegistry;
const Client = CheckClient;

/// A private `dbus-daemon` listening under /tmp.
const CheckBus = struct {
    io: std.Io,
    dir_buf: ["/tmp/conduit-a11y-".len + 16]u8 = undefined,
    child: std.process.Child = undefined,
    address_buf: [256]u8 = undefined,
    address_len: usize = 0,

    fn dir(self: *const CheckBus) []const u8 {
        return &self.dir_buf;
    }

    pub fn address(self: *const CheckBus) []const u8 {
        return self.address_buf[0..self.address_len];
    }

    /// Start the daemon; false when `dbus-daemon` is not installed.
    pub fn start(bus: *CheckBus) !bool {
        const io = bus.io;
        var random: [8]u8 = undefined;
        io.random(&random);
        _ = try std.fmt.bufPrint(&bus.dir_buf, "/tmp/conduit-a11y-{x:0>16}", .{std.mem.readInt(u64, &random, .little)});
        try std.Io.Dir.cwd().createDir(io, bus.dir(), .fromMode(0o700));
        errdefer std.Io.Dir.cwd().deleteTree(io, bus.dir()) catch {}; // best-effort cleanup of a test directory

        var config_buf: [1024]u8 = undefined;
        const config = try std.fmt.bufPrint(&config_buf,
            \\<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
            \\ "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
            \\<busconfig>
            \\  <type>session</type>
            \\  <listen>unix:path={s}/bus</listen>
            \\  <policy context="default">
            \\    <allow send_destination="*" eavesdrop="true"/>
            \\    <allow eavesdrop="true"/>
            \\    <allow own="*"/>
            \\  </policy>
            \\</busconfig>
            \\
        , .{bus.dir()});
        var path_buf: [128]u8 = undefined;
        const config_path = try std.fmt.bufPrint(&path_buf, "{s}/bus.conf", .{bus.dir()});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = config });
        var arg_buf: [160]u8 = undefined;
        const config_arg = try std.fmt.bufPrint(&arg_buf, "--config-file={s}", .{config_path});

        bus.child = std.process.spawn(io, .{
            .argv = &.{ "dbus-daemon", config_arg, "--nofork", "--print-address=1" },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                std.Io.Dir.cwd().deleteTree(io, bus.dir()) catch {}; // best-effort cleanup of a test directory
                return false;
            },
            else => return err,
        };
        errdefer bus.child.kill(io);
        // The daemon prints its address once it is listening: a readiness
        // signal rather than a guess.
        const fd = bus.child.stdout.?.handle;
        while (bus.address_len == 0 or bus.address_buf[bus.address_len - 1] != '\n') {
            if (bus.address_len == bus.address_buf.len) return error.AddressTooLong;
            const rc = linux.read(fd, bus.address_buf[bus.address_len..].ptr, bus.address_buf.len - bus.address_len);
            if (linux.errno(rc) != .SUCCESS or rc == 0) return error.DaemonFailed;
            bus.address_len += rc;
        }
        bus.address_len -= 1;
        return true;
    }

    pub fn stop(bus: *CheckBus) void {
        bus.child.kill(bus.io);
        std.Io.Dir.cwd().deleteTree(bus.io, bus.dir()) catch {}; // best-effort cleanup of a test directory
    }
};

/// Stands in for the at-spi bus launcher (`org.a11y.Bus`) and the registry
/// (`org.a11y.atspi.Registry`) on the private bus, so the bridge's real
/// discovery and embedding path runs.
const CheckRegistry = struct {
    io: std.Io,
    conn: dbus.Connection,
    bus_address: []const u8,
    stop: std.atomic.Value(bool) = .init(false),
    embedded: std.atomic.Value(bool) = .init(false),
    event: std.Io.Event = .unset,
    embedded_name_buf: [64]u8 = undefined,
    embedded_name_len: usize = 0,
    thread: ?std.Thread = null,

    pub fn requestName(self: *CheckRegistry, name: []const u8) !void {
        var body_buf: [128]u8 = undefined;
        var body = dbus.Writer.init(&body_buf);
        try body.string(name);
        try body.uint32(4); // DBUS_NAME_FLAG_DO_NOT_QUEUE
        const reply = try self.conn.call(.{
            .type = .method_call,
            .serial = 0,
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "RequestName",
            .destination = "org.freedesktop.DBus",
            .signature = "su",
        }, body.written(), 2000, self.io);
        var r = reply.bodyReader();
        if (try r.uint32() != 1) return error.NameNotOwned; // not the primary owner
    }

    /// Claim both well-known names and serve them on a thread until `stop`.
    pub fn serve(self: *CheckRegistry) !void {
        try self.conn.hello(2000, self.io);
        try self.requestName("org.a11y.Bus");
        try self.requestName("org.a11y.atspi.Registry");
        self.thread = try std.Thread.spawn(.{}, CheckRegistry.run, .{self});
    }

    /// Stop serving, join the thread and close the connection.
    pub fn shutdown(self: *CheckRegistry) void {
        self.stop.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.conn.close();
    }

    /// Wait until a bridge has embedded itself, or `timeout_ms` passes.
    pub fn waitEmbedded(self: *CheckRegistry, timeout_ms: i64) bool {
        const deadline = dbus.nowMs(self.io) + timeout_ms;
        while (!self.embedded.load(.acquire)) {
            // A timeout or spurious wake only means the flag is checked again.
            self.event.waitTimeout(self.io, .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } }) catch {};
            if (dbus.nowMs(self.io) > deadline) return false;
        }
        return true;
    }

    /// The bus name the embedded application serves its objects under.
    pub fn embeddedName(self: *const CheckRegistry) []const u8 {
        return self.embedded_name_buf[0..self.embedded_name_len];
    }

    fn run(self: *CheckRegistry) void {
        self.loop() catch |err| log.warn("fake registry stopped: {s}", .{@errorName(err)});
    }

    fn loop(self: *CheckRegistry) !void {
        while (!self.stop.load(.acquire)) {
            // A short poll so `stop` is noticed; this waits on the socket and
            // is not a sleep standing in for a condition.
            if (try self.conn.waitReadable(50)) {
                if (!try self.conn.fill()) return;
            }
            while (try self.conn.next()) |message| try self.handle(&message);
        }
    }

    fn handle(self: *CheckRegistry, m: *const dbus.Message) !void {
        if (m.type != .method_call) return;
        var body_buf: [512]u8 = undefined;
        var body = dbus.Writer.init(&body_buf);
        var signature: []const u8 = "";
        if (m.isCall("org.a11y.Bus", "GetAddress")) {
            try body.string(self.bus_address);
            signature = "s";
        } else if (m.isCall("org.a11y.atspi.Socket", "Embed")) {
            var r = m.bodyReader();
            try r.beginStruct();
            const name = try r.string();
            if (!std.mem.eql(u8, atspi.root_path, try r.objectPath())) return error.WrongRoot;
            if (name.len > self.embedded_name_buf.len) return error.NameTooLong;
            @memcpy(self.embedded_name_buf[0..name.len], name);
            self.embedded_name_len = name.len;
            try body.reference(self.conn.uniqueName(), atspi.root_path);
            signature = "(so)";
            self.embedded.store(true, .release);
            self.event.set(self.io);
        } else {
            return;
        }
        try self.conn.send(.{
            .type = .method_return,
            .serial = self.conn.nextSerial(),
            .reply_serial = m.serial,
            .destination = m.sender,
            .signature = signature,
        }, body.written());
    }
};

const TestWake = struct {
    count: std.atomic.Value(u32) = .init(0),

    fn wake(context: ?*anyopaque) void {
        const self: *TestWake = @ptrCast(@alignCast(context.?));
        _ = self.count.fetchAdd(1, .acq_rel);
    }
};

/// The test's assistive technology: a plain bus client walking the bridge.
const CheckClient = struct {
    io: std.Io,
    conn: dbus.Connection,
    app: []const u8,

    pub const Path = struct {
        buf: [64]u8 = undefined,
        len: usize = 0,

        pub fn slice(self: *const Path) []const u8 {
            return self.buf[0..self.len];
        }

        fn set(self: *Path, text: []const u8) void {
            @memcpy(self.buf[0..text.len], text);
            self.len = text.len;
        }
    };

    /// Say hello on the bus and subscribe to `Event.Object` signals.
    pub fn connect(self: *CheckClient) !void {
        try self.conn.hello(2000, self.io);
        var body_buf: [128]u8 = undefined;
        var body = dbus.Writer.init(&body_buf);
        try body.string("type='signal',interface='org.a11y.atspi.Event.Object'");
        _ = try self.conn.call(.{
            .type = .method_call,
            .serial = 0,
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "AddMatch",
            .destination = "org.freedesktop.DBus",
            .signature = "s",
        }, body.written(), 2000, self.io);
    }

    pub fn call(self: *CheckClient, path: []const u8, interface: []const u8, member: []const u8, signature: []const u8, body: []const u8) !dbus.Message {
        return self.conn.call(.{
            .type = .method_call,
            .serial = 0,
            .path = path,
            .interface = interface,
            .member = member,
            .destination = self.app,
            .signature = signature,
        }, body, 2000, self.io);
    }

    pub fn children(self: *CheckClient, path: []const u8, out: []Path) !usize {
        const reply = try self.call(path, atspi.iface_accessible, "GetChildren", "", "");
        var r = reply.bodyReader();
        const end = try r.beginArray(8);
        var n: usize = 0;
        while (r.pos < end) : (n += 1) {
            if (n == out.len) return error.TooManyChildren;
            try r.beginStruct();
            if (!std.mem.eql(u8, self.app, try r.string())) return error.WrongApplication;
            const child = try r.objectPath();
            if (child.len > out[n].buf.len) return error.PathTooLong;
            out[n].set(child);
        }
        return n;
    }

    pub fn role(self: *CheckClient, path: []const u8) !u32 {
        const reply = try self.call(path, atspi.iface_accessible, "GetRole", "", "");
        var r = reply.bodyReader();
        return r.uint32();
    }

    /// A string property, or the path of a `(so)` property.
    pub fn property(self: *CheckClient, path: []const u8, name: []const u8, out: []u8) ![]const u8 {
        var body_buf: [128]u8 = undefined;
        var body = dbus.Writer.init(&body_buf);
        try body.string(atspi.iface_accessible);
        try body.string(name);
        const reply = try self.call(path, "org.freedesktop.DBus.Properties", "Get", "ss", body.written());
        var r = reply.bodyReader();
        const sig = try r.signature();
        const text = if (std.mem.eql(u8, sig, "s")) try r.string() else blk: {
            try r.beginStruct();
            _ = try r.string();
            break :blk try r.objectPath();
        };
        if (text.len > out.len) return error.NoSpaceLeft;
        @memcpy(out[0..text.len], text);
        return out[0..text.len];
    }

    pub fn states(self: *CheckClient, path: []const u8) !u64 {
        const reply = try self.call(path, atspi.iface_accessible, "GetState", "", "");
        var r = reply.bodyReader();
        _ = try r.beginArray(4);
        const low = try r.uint32();
        const high = try r.uint32();
        return @as(u64, high) << 32 | low;
    }

    /// Wait for an `Event.Object` signal; unrelated messages are skipped.
    pub fn waitSignal(self: *CheckClient, member: []const u8, path: []const u8, detail: []const u8, detail1: i32) !void {
        const deadline = dbus.nowMs(self.io) + 5000;
        while (true) {
            while (try self.conn.next()) |m| {
                if (m.type != .signal) continue;
                if (!std.mem.eql(u8, m.member.?, member) or !std.mem.eql(u8, m.path.?, path)) continue;
                var r = m.bodyReader();
                if (!std.mem.eql(u8, try r.string(), detail)) continue;
                if ((try r.int32()) != detail1) continue;
                return;
            }
            const left = deadline - dbus.nowMs(self.io);
            if (left <= 0) return error.TimedOut;
            if (try self.conn.waitReadable(@intCast(left))) {
                if (!try self.conn.fill()) return error.Disconnected;
            }
        }
    }

    /// One element found by `find`: its object path, role and name.
    pub const Found = struct {
        path: Path = .{},
        role: u32 = 0,
        name_buf: [128]u8 = undefined,
        name_len: usize = 0,

        pub fn name(self: *const Found) []const u8 {
            return self.name_buf[0..self.name_len];
        }
    };

    /// Walk the application's whole tree over the bus, from the window down,
    /// and return the element whose `AccessibleId` is `id`, or null.
    pub fn find(self: *CheckClient, id: []const u8) !?Found {
        var stack: [512]Path = undefined;
        var stack_len: usize = 0;
        var top: [64]Path = undefined;
        const top_count = try self.children(atspi.window_path, &top);
        for (top[0..top_count]) |p| {
            stack[stack_len] = p;
            stack_len += 1;
        }
        while (stack_len > 0) {
            stack_len -= 1;
            const path = stack[stack_len];
            var id_buf: [256]u8 = undefined;
            const element_id = try self.property(path.slice(), "AccessibleId", &id_buf);
            if (std.mem.eql(u8, element_id, id)) {
                var found: Found = .{ .path = path };
                found.role = try self.role(path.slice());
                found.name_len = (try self.property(path.slice(), "Name", &found.name_buf)).len;
                return found;
            }
            var kids: [64]Path = undefined;
            const kid_count = try self.children(path.slice(), &kids);
            for (kids[0..kid_count]) |kid| {
                if (stack_len == stack.len) return error.TreeTooLarge;
                stack[stack_len] = kid;
                stack_len += 1;
            }
        }
        return null;
    }

    /// `Component.GrabFocus` on `path`; the bridge's answer.
    pub fn grabFocus(self: *CheckClient, path: []const u8) !bool {
        const reply = try self.call(path, atspi.iface_component, "GrabFocus", "", "");
        var r = reply.bodyReader();
        return r.boolean();
    }

    /// `Action.DoAction(0)` on `path`; the bridge's answer.
    pub fn doAction(self: *CheckClient, path: []const u8) !bool {
        var body_buf: [8]u8 = undefined;
        var body = dbus.Writer.init(&body_buf);
        try body.int32(0);
        const reply = try self.call(path, atspi.iface_action, "DoAction", "i", body.written());
        var r = reply.bodyReader();
        return r.boolean();
    }
};

/// The sidebar, palette and settings compositions, shaped like `app`'s.
fn composeFixture(tree: *ui.Tree, query: *ui.Input, field: *ui.Input, focus: []const u8) !void {
    try tree.beginFrame(.{ .cell_width = 8, .cell_height = 16, .surface_bounds = .{ .x = 0, .y = 0, .width = 640, .height = 360 } });
    const style: ui.InteractiveText = .{ .id = .{ .value = "unused" }, .label = "", .action = "" };
    const sidebar: ui.Id = .{ .value = "sidebar" };
    try tree.addSurface(.{ .id = sidebar, .role = "sidebar", .label = "Sidebar", .bounds = .{ .x = 0, .y = 0, .width = 20, .height = 22 } }, .{ .rect = ui.Rect.empty });
    try tree.addInteractiveText(.{ .id = .{ .value = "workspace.1" }, .parent = sidebar, .role = "workspace", .label = "main", .selected = true, .action = "workspace.activate", .bounds = .{ .x = 1, .y = 0, .width = 18, .height = 1 } }, style);
    try tree.addInteractiveText(.{ .id = .{ .value = "workspace.1.tab.1" }, .parent = .{ .value = "workspace.1" }, .role = "tab", .label = "bash", .selected = true, .action = "tab.activate", .bounds = .{ .x = 2, .y = 1, .width = 17, .height = 1 } }, style);
    try tree.addInteractiveText(.{ .id = .{ .value = "sidebar.palette" }, .parent = sidebar, .role = "palette_hint", .label = "Palette  Ctrl+Shift+P", .action = "palette.open", .bounds = .{ .x = 0, .y = 20, .width = 20, .height = 1 } }, style);

    const palette: ui.Id = .{ .value = "palette.dialog" };
    try tree.addSurface(.{ .id = palette, .role = "dialog", .label = "Command palette", .bounds = .{ .x = 25, .y = 2, .width = 40, .height = 6 } }, .{ .rect = ui.Rect.empty });
    try tree.addInput(.{ .id = .{ .value = "palette.query" }, .parent = palette, .role = "input", .label = "Filter commands", .action = "palette.activate", .bounds = .{ .x = 27, .y = 3, .width = 36, .height = 1 } }, query, .{});
    try tree.addInteractiveText(.{ .id = .{ .value = "palette.action.0" }, .parent = palette, .role = "command", .label = "New tab  Ctrl+Shift+T", .selected = true, .action = "palette.activate", .bounds = .{ .x = 27, .y = 4, .width = 36, .height = 1 } }, style);
    try tree.addInteractiveText(.{ .id = .{ .value = "palette.action.1" }, .parent = palette, .role = "command", .label = "Close tab", .action = "palette.activate", .bounds = .{ .x = 27, .y = 5, .width = 36, .height = 1 } }, style);

    const settings: ui.Id = .{ .value = "settings.dialog" };
    try tree.addSurface(.{ .id = settings, .role = "dialog", .label = "Settings", .bounds = .{ .x = 22, .y = 10, .width = 50, .height = 8 } }, .{ .rect = ui.Rect.empty });
    try tree.addText(.{ .id = .{ .value = "settings.row.0" }, .parent = settings, .role = "heading", .label = "Appearance", .bounds = .{ .x = 24, .y = 11, .width = 46, .height = 1 } }, .{ .runs = &.{} });
    try tree.addInteractiveText(.{ .id = .{ .value = "settings.row.1" }, .parent = settings, .role = "setting", .label = "font.size  13", .action = "settings.activate", .bounds = .{ .x = 24, .y = 12, .width = 12, .height = 1 } }, style);
    try tree.addInput(.{ .id = .{ .value = "settings.input" }, .parent = settings, .role = "input", .label = "font.size", .action = "settings.activate", .bounds = .{ .x = 36, .y = 12, .width = 34, .height = 1 } }, field, .{});
    try tree.endFrame();
    try testing.expect(tree.focus(.{ .value = focus }));
}

test "bridge serves sidebar, palette and settings over a private AT-SPI bus" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = testing.io;
    var bus: PrivateBus = .{ .io = io };
    if (!try bus.start()) {
        std.log.warn("dbus-daemon is not installed; skipping the AT-SPI integration test", .{});
        return error.SkipZigTest;
    }
    defer bus.stop();

    var registry: FakeRegistry = .{
        .io = io,
        .conn = try dbus.Connection.open(testing.allocator, bus.address(), 64 * 1024, 64 * 1024),
        .bus_address = bus.address(),
    };
    defer registry.conn.close();
    try registry.conn.hello(2000, io);
    try registry.requestName("org.a11y.Bus");
    try registry.requestName("org.a11y.atspi.Registry");
    registry.thread = try std.Thread.spawn(.{}, FakeRegistry.run, .{&registry});
    defer {
        registry.stop.store(true, .release);
        registry.thread.?.join();
    }

    var wake: TestWake = .{};
    const bridge = try Bridge.init(testing.allocator, io, .{
        .session_bus_address = bus.address(),
        .version = "0.0.0-test",
        .waker = .{ .context = &wake, .wakeFn = TestWake.wake },
    });
    defer bridge.deinit();

    // The real discovery path: session bus, org.a11y.Bus, then Embed.
    const deadline = dbus.nowMs(io) + 5000;
    while (!registry.embedded.load(.acquire)) {
        // A timeout or spurious wake only means the flag is checked again.
        registry.event.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch {};
        if (dbus.nowMs(io) > deadline) return error.TimedOut;
    }
    // The registry flags the Embed call when it handles it; the bridge reports
    // `connected` only once it has read the reply, so give it the same deadline.
    while (bridge.currentStatus() == .starting) {
        if (dbus.nowMs(io) > deadline) return error.TimedOut;
        registry.event.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }) catch {};
    }
    try testing.expectEqual(Status.connected, bridge.currentStatus());

    var client: Client = .{
        .io = io,
        .conn = try dbus.Connection.open(testing.allocator, bus.address(), 256 * 1024, 64 * 1024),
        .app = registry.embedded_name_buf[0..registry.embedded_name_len],
    };
    defer client.conn.close();
    try client.conn.hello(2000, io);
    {
        var body_buf: [128]u8 = undefined;
        var body = dbus.Writer.init(&body_buf);
        try body.string("type='signal',interface='org.a11y.atspi.Event.Object'");
        _ = try client.conn.call(.{
            .type = .method_call,
            .serial = 0,
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "AddMatch",
            .destination = "org.freedesktop.DBus",
            .signature = "s",
        }, body.written(), 2000, io);
    }

    var tree = try ui.Tree.init(testing.allocator, 32, 8);
    defer tree.deinit();
    var query = try ui.Input.init(testing.allocator, 64, "");
    defer query.deinit();
    var field = try ui.Input.init(testing.allocator, 64, "13");
    defer field.deinit();
    try composeFixture(&tree, &query, &field, "palette.query");
    bridge.publish(&tree);
    const first = bridge.published;
    // Publishing an unchanged tree hands nothing new to the worker.
    bridge.publish(&tree);
    try testing.expectEqual(first, bridge.published);
    try client.waitSignal("ChildrenChanged", atspi.window_path, "add", 0);

    // Root, then window, then sidebar, palette and settings.
    var top: [8]Client.Path = undefined;
    try testing.expectEqual(@as(usize, 1), try client.children(atspi.root_path, &top));
    try testing.expectEqualStrings(atspi.window_path, top[0].slice());
    try testing.expectEqual(@as(u32, @intFromEnum(atspi.Role.application)), try client.role(atspi.root_path));
    try testing.expectEqual(@as(u32, @intFromEnum(atspi.Role.frame)), try client.role(atspi.window_path));
    const top_count = try client.children(atspi.window_path, &top);
    try testing.expectEqual(@as(usize, 3), top_count);

    // Walk the whole tree and check every element's role, label and parent.
    const Expected = struct { id: []const u8, role: atspi.Role, name: []const u8, parent: []const u8 };
    const expected = [_]Expected{
        .{ .id = "sidebar", .role = .panel, .name = "Sidebar", .parent = "" },
        .{ .id = "workspace.1", .role = .tree_item, .name = "main", .parent = "sidebar" },
        .{ .id = "workspace.1.tab.1", .role = .page_tab, .name = "bash", .parent = "workspace.1" },
        .{ .id = "sidebar.palette", .role = .push_button, .name = "Palette  Ctrl+Shift+P", .parent = "sidebar" },
        .{ .id = "palette.dialog", .role = .dialog, .name = "Command palette", .parent = "" },
        .{ .id = "palette.query", .role = .entry, .name = "Filter commands", .parent = "palette.dialog" },
        .{ .id = "palette.action.0", .role = .list_item, .name = "New tab  Ctrl+Shift+T", .parent = "palette.dialog" },
        .{ .id = "palette.action.1", .role = .list_item, .name = "Close tab", .parent = "palette.dialog" },
        .{ .id = "settings.dialog", .role = .dialog, .name = "Settings", .parent = "" },
        .{ .id = "settings.row.0", .role = .heading, .name = "Appearance", .parent = "settings.dialog" },
        .{ .id = "settings.row.1", .role = .list_item, .name = "font.size  13", .parent = "settings.dialog" },
        .{ .id = "settings.input", .role = .entry, .name = "font.size", .parent = "settings.dialog" },
    };
    var seen: usize = 0;
    var stack: [32]Client.Path = undefined;
    var stack_len: usize = 0;
    for (top[0..top_count]) |p| {
        stack[stack_len] = p;
        stack_len += 1;
    }
    while (stack_len > 0) {
        stack_len -= 1;
        const path = stack[stack_len];
        var id_buf: [64]u8 = undefined;
        const id = try client.property(path.slice(), "AccessibleId", &id_buf);
        const entry = for (expected) |e| {
            if (std.mem.eql(u8, e.id, id)) break e;
        } else return error.UnexpectedElement;
        seen += 1;
        try testing.expectEqual(@as(u32, @intFromEnum(entry.role)), try client.role(path.slice()));
        var name_buf: [64]u8 = undefined;
        try testing.expectEqualStrings(entry.name, try client.property(path.slice(), "Name", &name_buf));
        var parent_buf: [64]u8 = undefined;
        const parent_path = try client.property(path.slice(), "Parent", &parent_buf);
        if (entry.parent.len == 0) {
            try testing.expectEqualStrings(atspi.window_path, parent_path);
        } else {
            var parent_id_buf: [64]u8 = undefined;
            try testing.expectEqualStrings(entry.parent, try client.property(parent_path, "AccessibleId", &parent_id_buf));
        }
        var kids: [8]Client.Path = undefined;
        const kid_count = try client.children(path.slice(), &kids);
        for (kids[0..kid_count]) |kid| {
            stack[stack_len] = kid;
            stack_len += 1;
        }
    }
    try testing.expectEqual(expected.len, seen);

    // Extents are the element's window pixels.
    var tab_path_buf: [atspi.element_path_len]u8 = undefined;
    const tab_path = atspi.elementPath(&tab_path_buf, snapshot.keyOf("workspace.1.tab.1"));
    {
        var body_buf: [8]u8 = undefined;
        var body = dbus.Writer.init(&body_buf);
        try body.uint32(1); // ATSPI_COORD_TYPE_WINDOW
        const reply = try client.call(tab_path, atspi.iface_component, "GetExtents", "u", body.written());
        var r = reply.bodyReader();
        try r.beginStruct();
        try testing.expectEqual(@as(i32, 16), try r.int32());
        try testing.expectEqual(@as(i32, 16), try r.int32());
        try testing.expectEqual(@as(i32, 136), try r.int32());
        try testing.expectEqual(@as(i32, 16), try r.int32());
    }

    // Focus moves to a settings row: the AT hears StateChanged:focused.
    var row_path_buf: [atspi.element_path_len]u8 = undefined;
    const row_path = atspi.elementPath(&row_path_buf, snapshot.keyOf("settings.row.1"));
    try testing.expect((try client.states(row_path)) & atspi.bit(.focused) == 0);
    try composeFixture(&tree, &query, &field, "settings.row.1");
    bridge.publish(&tree);
    try client.waitSignal("StateChanged", row_path, "focused", 1);
    try testing.expect((try client.states(row_path)) & atspi.bit(.focused) != 0);

    // DoAction on a palette row becomes an activation request on the owner.
    var action_path_buf: [atspi.element_path_len]u8 = undefined;
    const action_path = atspi.elementPath(&action_path_buf, snapshot.keyOf("palette.action.0"));
    {
        var body_buf: [8]u8 = undefined;
        var body = dbus.Writer.init(&body_buf);
        try body.int32(0);
        const reply = try client.call(action_path, atspi.iface_action, "DoAction", "i", body.written());
        var r = reply.bodyReader();
        try testing.expect(try r.boolean());
    }
    try testing.expect(wake.count.load(.acquire) >= 1);
    const Owner = struct {
        kind: ?RequestKind = null,
        id_buf: [64]u8 = undefined,
        id_len: usize = 0,

        fn handle(self: *@This(), request: *const Request) void {
            self.kind = request.kind;
            @memcpy(self.id_buf[0..request.id().len], request.id());
            self.id_len = request.id().len;
        }
    };
    var owner: Owner = .{};
    try testing.expectEqual(@as(usize, 1), bridge.drainRequests(&owner, Owner.handle));
    try testing.expectEqual(RequestKind.activate, owner.kind.?);
    try testing.expectEqualStrings("palette.action.0", owner.id_buf[0..owner.id_len]);
    try testing.expectEqual(@as(usize, 0), bridge.drainRequests(&owner, Owner.handle));
}

// Opt-in check against a real AT-SPI stack (`docs/accessibility.md`): with
// `CONDUIT_A11Y_PROBE` set to a shell command and a session bus that can
// start `at-spi-bus-launcher`, the bridge serves the fixture through the
// real registry while the probe (a libatspi client) walks it. The probe must
// exit 0 and call `DoAction(0)` on `palette.action.0`. Skipped otherwise.
test "a real AT-SPI client reads the fixture (opt-in)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const probe = testing.environ.getPosix("CONDUIT_A11Y_PROBE") orelse return error.SkipZigTest;
    const address = testing.environ.getPosix("DBUS_SESSION_BUS_ADDRESS") orelse return error.SkipZigTest;
    const io = testing.io;
    const bridge = try Bridge.init(testing.allocator, io, .{ .session_bus_address = address, .version = "0.0.0-probe" });
    defer bridge.deinit();

    var tree = try ui.Tree.init(testing.allocator, 32, 8);
    defer tree.deinit();
    var query = try ui.Input.init(testing.allocator, 64, "");
    defer query.deinit();
    var field = try ui.Input.init(testing.allocator, 64, "13");
    defer field.deinit();
    try composeFixture(&tree, &query, &field, "palette.query");
    bridge.publish(&tree);

    var child = try std.process.spawn(io, .{ .argv = &.{ "sh", "-c", probe } });
    const term = try child.wait(io);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);

    const Owner = struct {
        activated: bool = false,

        fn handle(self: *@This(), request: *const Request) void {
            if (request.kind == .activate and std.mem.eql(u8, request.id(), "palette.action.0")) self.activated = true;
        }
    };
    var owner: Owner = .{};
    _ = bridge.drainRequests(&owner, Owner.handle);
    try testing.expect(owner.activated);
}

test "bridge stays off without a session bus or when disabled" {
    const no_bus = try Bridge.init(testing.allocator, testing.io, .{});
    defer no_bus.deinit();
    try testing.expectEqual(Status.off, no_bus.currentStatus());
    const disabled = try Bridge.init(testing.allocator, testing.io, .{ .enabled = false, .session_bus_address = "unix:path=/nonexistent" });
    defer disabled.deinit();
    try testing.expectEqual(Status.off, disabled.currentStatus());

    var tree = try ui.Tree.init(testing.allocator, 2, 1);
    defer tree.deinit();
    try tree.beginFrame(.{ .cell_width = 1, .cell_height = 1, .surface_bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 } });
    try tree.endFrame();
    no_bus.publish(&tree);
    try testing.expectEqual(@as(?u64, null), no_bus.published);
}

test "an unreachable session bus turns the bridge off" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const bridge = try Bridge.init(testing.allocator, testing.io, .{ .session_bus_address = "unix:path=/nonexistent/conduit-a11y-bus" });
    defer bridge.deinit();
    // The worker exits on its own; joining it is the condition.
    bridge.thread.?.join();
    bridge.thread = null;
    try testing.expectEqual(Status.off, bridge.currentStatus());
}

test "the request queue is bounded" {
    const bridge = try Bridge.init(testing.allocator, testing.io, .{ .enabled = false });
    defer bridge.deinit();
    for (0..request_capacity) |_| try testing.expect(Bridge.pushRequest(bridge, .focus, "x"));
    try testing.expect(!Bridge.pushRequest(bridge, .focus, "x"));
    const Count = struct {
        n: usize = 0,

        fn handle(self: *@This(), _: *const Request) void {
            self.n += 1;
        }
    };
    var count: Count = .{};
    try testing.expectEqual(@as(usize, request_capacity), bridge.drainRequests(&count, Count.handle));
    var long: [max_request_id_bytes + 1]u8 = undefined;
    @memset(&long, 'a');
    try testing.expect(!Bridge.pushRequest(bridge, .activate, &long));
}

test "the mailbox keeps only the newest snapshot" {
    const bridge = try Bridge.init(testing.allocator, testing.io, .{ .enabled = false });
    defer bridge.deinit();
    // Pretend a worker is running but has not taken anything yet.
    bridge.status.store(.starting, .release);
    var tree = try ui.Tree.init(testing.allocator, 2, 1);
    defer tree.deinit();
    for ([_][]const u8{ "one", "two", "three" }) |label| {
        try tree.beginFrame(.{ .cell_width = 1, .cell_height = 1, .surface_bounds = .{ .x = 0, .y = 0, .width = 9, .height = 9 } });
        try tree.addText(.{ .id = .{ .value = "t" }, .role = "text", .label = label, .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 } }, .{ .runs = &.{} });
        try tree.endFrame();
        bridge.publish(&tree);
    }
    const incoming = bridge.take().?;
    try testing.expectEqualStrings("three", bridge.buffers[incoming].str(bridge.buffers[incoming].nodes[0].label));
    try testing.expectEqual(@as(?u8, null), bridge.take());
    // Every buffer is held by exactly one party.
    var seen = [_]u8{0} ** 4;
    seen[bridge.back] += 1;
    seen[bridge.front] += 1;
    seen[incoming] += 1;
    for (bridge.spares[0..bridge.spare_len]) |s| seen[s] += 1;
    for (seen) |s| try testing.expectEqual(@as(u8, 1), s);
    bridge.release(bridge.front);
    bridge.front = incoming;
    bridge.status.store(.off, .release);
}
