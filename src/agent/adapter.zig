//! The harness-neutral adapter interface (TASK-52, decision-7).
//!
//! An `Adapter` is one harness's structured side channel for one agent: it
//! detects the harness, says how to launch it, adopts an existing session,
//! turns the harness's own events into `Event`s, and carries the few answers
//! Conduit may send back. The interactive TUI itself always runs in a Conduit
//! PTY session spawned through the workspace's ExecutionContext (invariant 5),
//! so `launch` only *describes* the process; it never spawns.
//!
//! Every capability is optional. `Capabilities` says what this adapter
//! instance supports right now (it may depend on the detected version, or on
//! whether Conduit's own hook or extension was injected), and calling one it
//! does not support returns `error.Unsupported` — never a guess.
//!
//! Threads: `capabilities` and `harness` are cheap, non-blocking and may be
//! called from any thread. Every other method may block on harness IO and is
//! called only from an IO worker, never from the render/UI thread, and by one
//! caller at a time per adapter instance. Events reach the owner thread only
//! through `EventQueue`. `destroy` is called on the owner thread once no
//! worker is using the adapter.
//!
//! Safety: `respondPermission`, `sendInput` and `updatePrompt` act on the
//! harness. Callers invoke them only from an explicit user gesture in
//! Conduit (CONDUIT.md §11); nothing in an event may trigger them.

const std = @import("std");
const session = @import("session");
const workspace = @import("workspace");
const event = @import("event.zig");
const Harness = @import("harness.zig").Harness;

const Allocator = std.mem.Allocator;

/// Failures any adapter method may report. Harness-specific causes are
/// logged by the adapter and mapped onto these.
pub const Error = Allocator.Error || error{
    /// This adapter instance does not support the capability.
    Unsupported,
    /// The harness, its side channel or its session is gone.
    Disconnected,
    /// The harness answered with something this adapter cannot parse for the
    /// installed version (decision-7, rule 4).
    Protocol,
    /// The named request, decision or session is unknown to the harness.
    UnknownTarget,
    /// A caller-provided buffer was too small for the result.
    NoSpaceLeft,
    /// The event queue was full; the adapter keeps the events for later.
    QueueFull,
};

/// What one adapter instance can do. Method bits gate the matching calls;
/// observation bits tell views what to expect (TASK-56 shows "waiting for
/// permission" as unsupported for a Pi without Conduit's gate extension).
pub const Capabilities = packed struct(u16) {
    detect: bool = false,
    launch: bool = false,
    attach: bool = false,
    poll: bool = false,
    send_input: bool = false,
    respond_permission: bool = false,
    read_prompt: bool = false,
    update_prompt: bool = false,
    stop: bool = false,
    /// Status arrives through a structured channel rather than heuristics.
    structured_status: bool = false,
    /// Permission requests are reported as events.
    permission_requests: bool = false,
    /// Messages, tool uses and file references are reported as events.
    transcript: bool = false,
    /// Subagent starts and stops are reported.
    subagents: bool = false,
    _padding: u3 = 0,

    /// Nothing supported: the PTY baseline only.
    pub const none: Capabilities = .{};
};

/// The environment variable Conduit sets on every agent PTY child. Hooks and
/// extensions inherit it and report it back, which is how an event finds its
/// agent (decision-7, rule 1).
pub const correlation_env_name = "CONDUIT_AGENT_TOKEN";

/// A random, opaque correlation value, kept as 32 lowercase hex digits. The
/// caller supplies the random bytes, so this module needs no OS entropy.
pub const CorrelationToken = struct {
    pub const byte_count = 16;
    pub const text_len = byte_count * 2;

    digits: [text_len]u8,

    pub fn fromBytes(bytes: [byte_count]u8) CorrelationToken {
        return .{ .digits = std.fmt.bytesToHex(bytes, .lower) };
    }

    /// Parse a token reported back by a hook or extension. Untrusted input:
    /// anything but exactly 32 lowercase hex digits is refused.
    pub fn parse(reported: []const u8) error{InvalidToken}!CorrelationToken {
        if (reported.len != text_len) return error.InvalidToken;
        var token: CorrelationToken = undefined;
        for (reported, 0..) |c, i| {
            switch (c) {
                '0'...'9', 'a'...'f' => token.digits[i] = c,
                else => return error.InvalidToken,
            }
        }
        return token;
    }

    pub fn text(self: *const CorrelationToken) []const u8 {
        return &self.digits;
    }

    pub fn eql(a: CorrelationToken, b: CorrelationToken) bool {
        return std.mem.eql(u8, &a.digits, &b.digits);
    }

    /// The `NAME=value` entry for a child's environment, written into `out`.
    pub fn envEntry(self: *const CorrelationToken, out: *[correlation_env_name.len + 1 + text_len]u8) []const u8 {
        @memcpy(out[0..correlation_env_name.len], correlation_env_name);
        out[correlation_env_name.len] = '=';
        @memcpy(out[correlation_env_name.len + 1 ..], &self.digits);
        return out;
    }
};

/// Where to look for a harness. `context` is borrowed for the call; the
/// adapter runs its probe through it, so detection works in SSH and WSL
/// workspaces too (decision-7, rule 5).
pub const DetectRequest = struct {
    context: workspace.ExecutionContext.Ref,
    /// Receives the installed version string.
    version_buffer: []u8,
};

/// What Conduit wants launched.
pub const LaunchRequest = struct {
    context_kind: workspace.ExecutionContextKind,
    /// The agent's working directory in that context.
    cwd: []const u8,
    /// An initial prompt to pass at launch, when the harness accepts one.
    initial_prompt: ?[]const u8 = null,
    token: CorrelationToken,
    /// Run without a visible TUI (stream-json, app-server, RPC) instead of
    /// the default interactive TUI in a PTY.
    headless: bool = false,
};

/// The process an adapter wants started. The workspace spawns it through
/// its ExecutionContext into an `agent_terminal` session; `env` holds only
/// the entries this adapter adds on top of the workspace's child environment,
/// and always includes the correlation entry.
///
/// Ownership: every slice is allocated from the allocator passed to
/// `launch`, which should be an arena the caller frees after the spawn.
pub const LaunchSpec = struct {
    argv: []const []const u8,
    env: []const []const u8,
    /// Files the owner writes before the spawn, in the agent's context
    /// (TASK-56): an extension, a settings file. Adapters that write nothing
    /// leave it empty.
    files: []const File = &.{},

    /// One file a launch needs. `path` is absolute in the agent's context
    /// and inside the agent's private sink directory; the owner creates its
    /// parent directories private (0700) and the file owner-only.
    pub const File = struct {
        path: []const u8,
        bytes: []const u8,
        /// Whether the file must be executable (a hook script).
        executable: bool = false,
    };
};

/// An existing session to adopt: one Conduit launched (and knows the token
/// of) or one the human started by hand in a terminal.
pub const AttachRequest = struct {
    session: session.SessionId,
    token: CorrelationToken,
    /// The harness's own session id, once a structured event reported it.
    harness_session_id: ?[]const u8 = null,
};

/// A type-erased adapter. `ptr` is owned by the value until `destroy`.
pub const Adapter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Method slots are optional; a null slot is unsupported whatever
    /// `capabilities` says.
    pub const VTable = struct {
        harness: *const fn (*const anyopaque) Harness,
        capabilities: *const fn (*const anyopaque) Capabilities,
        detect: ?*const fn (*anyopaque, DetectRequest) Error!?[]const u8 = null,
        launch: ?*const fn (*anyopaque, Allocator, LaunchRequest) Error!LaunchSpec = null,
        attach: ?*const fn (*anyopaque, AttachRequest) Error!void = null,
        poll: ?*const fn (*anyopaque, *event.EventQueue) Error!usize = null,
        send_input: ?*const fn (*anyopaque, []const u8) Error!void = null,
        respond_permission: ?*const fn (*anyopaque, []const u8, []const u8) Error!void = null,
        read_prompt: ?*const fn (*anyopaque, []u8) Error![]const u8 = null,
        update_prompt: ?*const fn (*anyopaque, []const u8) Error!void = null,
        stop: ?*const fn (*anyopaque) Error!void = null,
        destroy: *const fn (*anyopaque) void,
    };

    pub fn harness(self: Adapter) Harness {
        return self.vtable.harness(self.ptr);
    }

    pub fn capabilities(self: Adapter) Capabilities {
        return self.vtable.capabilities(self.ptr);
    }

    /// Whether the harness is installed in the request's context: its version
    /// (a slice of `request.version_buffer`), or null when it is not.
    pub fn detect(self: Adapter, request: DetectRequest) Error!?[]const u8 {
        const f = self.slot(.detect, self.vtable.detect) orelse return error.Unsupported;
        return f(self.ptr, request);
    }

    /// Describe the process to spawn; see `LaunchSpec` for ownership.
    pub fn launch(self: Adapter, allocator: Allocator, request: LaunchRequest) Error!LaunchSpec {
        const f = self.slot(.launch, self.vtable.launch) orelse return error.Unsupported;
        return f(self.ptr, allocator, request);
    }

    /// Adopt an existing session.
    pub fn attach(self: Adapter, request: AttachRequest) Error!void {
        const f = self.slot(.attach, self.vtable.attach) orelse return error.Unsupported;
        return f(self.ptr, request);
    }

    /// Move whatever events the side channel has ready into `queue`, without
    /// blocking, and return how many were pushed. Events the queue refuses
    /// stay with the adapter for the next poll.
    pub fn poll(self: Adapter, queue: *event.EventQueue) Error!usize {
        const f = self.slot(.poll, self.vtable.poll) orelse return error.Unsupported;
        return f(self.ptr, queue);
    }

    /// Send the human's text to the harness through its structured channel.
    pub fn sendInput(self: Adapter, bytes: []const u8) Error!void {
        const f = self.slot(.send_input, self.vtable.send_input) orelse return error.Unsupported;
        return f(self.ptr, bytes);
    }

    /// Answer a pending permission request with one of the decision ids the
    /// request itself offered. User gesture only.
    pub fn respondPermission(self: Adapter, request_id: []const u8, decision_id: []const u8) Error!void {
        const f = self.slot(.respond_permission, self.vtable.respond_permission) orelse return error.Unsupported;
        return f(self.ptr, request_id, decision_id);
    }

    /// Copy the harness's current prompt into `out` and return that slice.
    pub fn readPrompt(self: Adapter, out: []u8) Error![]const u8 {
        const f = self.slot(.read_prompt, self.vtable.read_prompt) orelse return error.Unsupported;
        return f(self.ptr, out);
    }

    /// Replace the harness's prompt. User gesture only.
    pub fn updatePrompt(self: Adapter, text: []const u8) Error!void {
        const f = self.slot(.update_prompt, self.vtable.update_prompt) orelse return error.Unsupported;
        return f(self.ptr, text);
    }

    /// Ask the harness to stop the agent.
    pub fn stop(self: Adapter) Error!void {
        const f = self.slot(.stop, self.vtable.stop) orelse return error.Unsupported;
        return f(self.ptr);
    }

    /// Release the implementation. The value must not be used afterwards.
    pub fn destroy(self: Adapter) void {
        self.vtable.destroy(self.ptr);
    }

    /// The method slot, when both the vtable has it and the instance
    /// currently claims it.
    fn slot(self: Adapter, comptime bit: std.meta.FieldEnum(Capabilities), f: anytype) @TypeOf(f) {
        if (!@field(self.capabilities(), @tagName(bit))) return null;
        return f;
    }
};
