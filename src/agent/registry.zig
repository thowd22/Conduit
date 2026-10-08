//! The agents Conduit knows about, grouped by workspace (TASK-52).
//!
//! An `Agent` record binds one harness to one session in one workspace and
//! folds that agent's events into its `State`. The registry is the model the
//! sidebar glyphs (TASK-56), the agent manager (TASK-58) and the control API
//! (TASK-60) read; adapters and heuristics only produce events for it.
//!
//! Sessions: an agent Conduit launched *owns* an `agent_terminal` session, a
//! kind no tab, pane or scratchpad code treats as a human terminal. An agent
//! the human started by typing its command is *observed* in that
//! `human_terminal`: the terminal stays the human's, and removing the agent
//! only stops observing it. The scratchpad can be neither (P9, invariant 7):
//! the caller passes the workspace's scratchpad id with every binding, so the
//! refusal does not depend on the session kind alone.
//!
//! Dependencies: `workspace.WorkspaceKey` and `session.SessionId` /
//! `session.Session.Kind` are the only types used from below; the registry
//! reads no workspace state and never spawns or closes a session.
//!
//! Threads: owner (UI) thread only.
//!
//! Memory: the registry owns one array of `Agent` values, grown with the
//! allocator passed to `init`; each record's text lives in fixed inline
//! storage. Pointers returned by `get` and iterators are valid until the next
//! `create`, `remove` or `removeWorkspace`.

const std = @import("std");
const session = @import("session");
const workspace = @import("workspace");
const state_model = @import("state.zig");
const event = @import("event.zig");
const adapter = @import("adapter.zig");
const Harness = @import("harness.zig").Harness;

const Allocator = std.mem.Allocator;
const State = state_model.State;
const Source = state_model.Source;
const Event = event.Event;
const WorkspaceKey = workspace.WorkspaceKey;
const SessionId = session.SessionId;

/// Stable identity of one agent. One-based, monotonic and never reused, even
/// after the agent is removed, so a stale id can never name a new agent.
pub const AgentId = enum(u64) {
    first = 1,
    _,

    pub fn fromOrdinal(ordinal_value: u64) AgentId {
        return @enumFromInt(ordinal_value + 1);
    }

    pub fn ordinal(self: AgentId) u64 {
        return @intFromEnum(self) - 1;
    }
};

/// How an agent relates to its session.
pub const Ownership = enum {
    /// Conduit launched the agent into its own `agent_terminal` session.
    owned,
    /// The human started the harness in their own `human_terminal`; Conduit
    /// only observes it there.
    observed,
};

/// The session an agent is bound to, as its workspace describes it.
pub const Binding = struct {
    workspace: WorkspaceKey,
    session: SessionId,
    /// `Workspace.sessionKind(session)`.
    session_kind: session.Session.Kind,
    /// `Workspace.scratchpadId()` of the same workspace.
    scratchpad: SessionId,
};

pub const CreateRequest = struct {
    binding: Binding,
    harness: Harness,
    ownership: Ownership,
    token: adapter.CorrelationToken,
    /// The adapter's capabilities when the agent was registered, for views.
    capabilities: adapter.Capabilities = .none,
};

/// The most permission requests one agent may have pending at once (each
/// subagent can hold one).
pub const max_pending_permissions = 8;
/// Bytes kept of the latest event's display summary.
pub const summary_capacity = 160;

/// A bounded copy of an identifier.
const PendingId = struct {
    bytes: [event.max_identifier_bytes]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const PendingId) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// One agent.
pub const Agent = struct {
    id: AgentId,
    workspace: WorkspaceKey,
    session: SessionId,
    harness: Harness,
    ownership: Ownership,
    token: adapter.CorrelationToken,
    capabilities: adapter.Capabilities,
    state: State = .idle,
    /// Where the current `state` came from.
    source: Source = .heuristic,
    /// Whether any structured event has arrived. From then on heuristic
    /// status claims are ignored (decision-7).
    structured: bool = false,
    /// Set once the agent's process ended; the record then changes no more.
    exit: ?event.ExitStatus = null,
    last_event: ?Event.Kind = null,
    summary_bytes: [summary_capacity]u8 = undefined,
    summary_len: usize = 0,
    pending: [max_pending_permissions]PendingId = undefined,
    pending_len: usize = 0,

    /// Display text from the latest event that had any. Untrusted harness
    /// text, borrowed from the record.
    pub fn summary(self: *const Agent) []const u8 {
        return self.summary_bytes[0..self.summary_len];
    }

    /// How many permission requests are still unanswered.
    pub fn pendingPermissions(self: *const Agent) usize {
        return self.pending_len;
    }

    /// Whether the permission request `id` is still unanswered.
    pub fn isPending(self: *const Agent, id: []const u8) bool {
        return self.pendingIndex(id) != null;
    }

    pub fn hasExited(self: *const Agent) bool {
        return self.exit != null;
    }

    fn pendingIndex(self: *const Agent, id: []const u8) ?usize {
        for (self.pending[0..self.pending_len], 0..) |*pending, i| {
            if (std.mem.eql(u8, pending.slice(), id)) return i;
        }
        return null;
    }

    fn setSummary(self: *Agent, text: []const u8) void {
        const kept = event.truncateUtf8(text, summary_capacity);
        @memcpy(self.summary_bytes[0..kept.len], kept);
        self.summary_len = kept.len;
    }
};

/// What `apply` did with an event.
pub const Applied = struct {
    pub const Outcome = enum {
        /// The state changed from `previous` to `current`.
        changed,
        /// The event was recorded; the state did not change.
        unchanged,
        /// A heuristic status claim about an agent with a structured source.
        ignored,
    };
    outcome: Outcome,
    previous: State,
    current: State,
};

pub const CreateError = Allocator.Error || error{
    /// The session is the workspace's scratchpad.
    ScratchpadRefused,
    /// An owned agent needs an `agent_terminal` session.
    NotAgentSession,
    /// An observed agent lives in a `human_terminal` session.
    NotHumanSession,
    /// A live agent is already bound to this session.
    SessionAlreadyBound,
    AgentLimit,
};

pub const ApplyError = error{
    UnknownAgent,
    /// The agent's process already ended.
    AgentExited,
    /// The event asks for a change the state table refuses.
    IllegalTransition,
    /// More than `max_pending_permissions` unanswered requests.
    TooManyPendingPermissions,
    /// A permission id longer than `event.max_identifier_bytes`.
    EventTooLarge,
};

pub const Registry = struct {
    allocator: Allocator,
    agents: std.ArrayList(Agent) = .empty,
    next_ordinal: u64 = 0,

    pub fn init(allocator: Allocator) Registry {
        return .{ .allocator = allocator };
    }

    /// Forget every agent. Sessions are not touched: they belong to their
    /// workspace.
    pub fn deinit(self: *Registry) void {
        self.agents.deinit(self.allocator);
        self.* = undefined;
    }

    /// Register an agent bound to `request.binding`. Nothing changes on error.
    pub fn create(self: *Registry, request: CreateRequest) CreateError!AgentId {
        const binding = request.binding;
        if (binding.session == binding.scratchpad or binding.session_kind == .scratchpad)
            return error.ScratchpadRefused;
        switch (request.ownership) {
            .owned => if (binding.session_kind != .agent_terminal) return error.NotAgentSession,
            .observed => if (binding.session_kind != .human_terminal) return error.NotHumanSession,
        }
        if (self.findBySession(binding.workspace, binding.session) != null)
            return error.SessionAlreadyBound;
        if (self.next_ordinal == std.math.maxInt(u64) - 1) return error.AgentLimit;

        try self.agents.ensureUnusedCapacity(self.allocator, 1);
        const id = AgentId.fromOrdinal(self.next_ordinal);
        self.next_ordinal += 1;
        self.agents.appendAssumeCapacity(.{
            .id = id,
            .workspace = binding.workspace,
            .session = binding.session,
            .harness = request.harness,
            .ownership = request.ownership,
            .token = request.token,
            .capabilities = request.capabilities,
        });
        return id;
    }

    /// Forget one agent. Its id is never issued again.
    pub fn remove(self: *Registry, id: AgentId) error{UnknownAgent}!void {
        const index = self.indexOf(id) orelse return error.UnknownAgent;
        _ = self.agents.orderedRemove(index);
    }

    /// Forget every agent of a closed workspace; returns how many.
    pub fn removeWorkspace(self: *Registry, key: WorkspaceKey) usize {
        var kept: usize = 0;
        for (self.agents.items) |agent| {
            if (agent.workspace == key) continue;
            self.agents.items[kept] = agent;
            kept += 1;
        }
        const removed = self.agents.items.len - kept;
        self.agents.shrinkRetainingCapacity(kept);
        return removed;
    }

    pub fn get(self: *const Registry, id: AgentId) ?*const Agent {
        const index = self.indexOf(id) orelse return null;
        return &self.agents.items[index];
    }

    /// Record what an agent's adapter can do now. A structured channel may
    /// come up after registration (OpenCode's event stream, a Codex daemon
    /// attach), and views offer answers only while it can take them.
    /// Returns whether anything changed; an unknown or exited agent is left
    /// alone.
    pub fn setCapabilities(self: *Registry, id: AgentId, capabilities: adapter.Capabilities) bool {
        const index = self.indexOf(id) orelse return false;
        const agent = &self.agents.items[index];
        if (agent.hasExited() or agent.capabilities == capabilities) return false;
        agent.capabilities = capabilities;
        return true;
    }

    /// The live (not exited) agent bound to a session, if any.
    pub fn findBySession(self: *const Registry, key: WorkspaceKey, id: SessionId) ?AgentId {
        for (self.agents.items) |*agent| {
            if (agent.workspace == key and agent.session == id and !agent.hasExited()) return agent.id;
        }
        return null;
    }

    /// The agent a hook or extension reported by its correlation token.
    pub fn findByToken(self: *const Registry, token: adapter.CorrelationToken) ?AgentId {
        for (self.agents.items) |*agent| {
            if (agent.token.eql(token)) return agent.id;
        }
        return null;
    }

    /// Every agent, in creation order.
    pub fn all(self: *const Registry) []const Agent {
        return self.agents.items;
    }

    /// The agents of one workspace, in creation order.
    pub fn inWorkspace(self: *const Registry, key: WorkspaceKey) WorkspaceIterator {
        return .{ .agents = self.agents.items, .key = key };
    }

    pub const WorkspaceIterator = struct {
        agents: []const Agent,
        key: WorkspaceKey,
        index: usize = 0,

        pub fn next(self: *WorkspaceIterator) ?*const Agent {
            while (self.index < self.agents.len) {
                const agent = &self.agents[self.index];
                self.index += 1;
                if (agent.workspace == self.key) return agent;
            }
            return null;
        }
    };

    /// Fold one event into an agent. On error the agent is unchanged.
    ///
    /// Permission events move the state themselves: a request enters
    /// `waiting_permission`, and resolving the last pending request returns
    /// to `working`, whatever the outcome — the harness reports what it does
    /// next. `exited` ends the record with `done` or `errored` regardless of
    /// the table, because a process end is a fact, not a claim.
    pub fn apply(self: *Registry, id: AgentId, ev: Event) ApplyError!Applied {
        const index = self.indexOf(id) orelse return error.UnknownAgent;
        const agent = &self.agents.items[index];
        if (agent.hasExited()) return error.AgentExited;
        const previous = agent.state;

        switch (ev) {
            .status_change => |change| {
                if (change.source == .heuristic and agent.structured)
                    return .{ .outcome = .ignored, .previous = previous, .current = previous };
                if (change.state != agent.state) _ = try state_model.transition(agent.state, change.state);
                agent.state = change.state;
                agent.source = change.source;
                if (change.source == .structured) agent.structured = true;
            },
            .permission_request => |request| {
                if (request.id.len > event.max_identifier_bytes) return error.EventTooLarge;
                const known = agent.isPending(request.id);
                if (!known and agent.pending_len == max_pending_permissions)
                    return error.TooManyPendingPermissions;
                if (agent.state != .waiting_permission)
                    _ = try state_model.transition(agent.state, .waiting_permission);
                if (!known) {
                    const slot = &agent.pending[agent.pending_len];
                    @memcpy(slot.bytes[0..request.id.len], request.id);
                    slot.len = request.id.len;
                    agent.pending_len += 1;
                }
                agent.state = .waiting_permission;
                agent.source = .structured;
                agent.structured = true;
                agent.setSummary(request.title);
            },
            .permission_resolved => |resolved| {
                if (agent.pendingIndex(resolved.id)) |i| {
                    agent.pending[i] = agent.pending[agent.pending_len - 1];
                    agent.pending_len -= 1;
                }
                if (agent.pending_len == 0 and agent.state == .waiting_permission) {
                    agent.state = .working;
                    agent.source = .structured;
                }
                agent.structured = true;
            },
            .exited => |status| {
                agent.exit = status;
                agent.state = if (status.succeeded()) .done else .errored;
                agent.pending_len = 0;
            },
            .message => |message| {
                agent.structured = true;
                agent.setSummary(message.text);
            },
            .tool_use => |tool| {
                agent.structured = true;
                agent.setSummary(tool.name);
            },
            .file_reference => |reference| {
                agent.structured = true;
                agent.setSummary(reference.path);
            },
            .subagent => |subagent| {
                agent.structured = true;
                agent.setSummary(subagent.name);
            },
            // A notification may come from OSC 9/777 as well as a hook, so it
            // proves nothing about a structured channel.
            .notification => |notification| agent.setSummary(notification.body),
        }
        agent.last_event = std.meta.activeTag(ev);
        return .{
            .outcome = if (agent.state == previous) .unchanged else .changed,
            .previous = previous,
            .current = agent.state,
        };
    }

    fn indexOf(self: *const Registry, id: AgentId) ?usize {
        for (self.agents.items, 0..) |*agent, i| {
            if (agent.id == id) return i;
        }
        return null;
    }
};

// Tests ---------------------------------------------------------------------

const testing = std.testing;

fn testToken(seed: u8) adapter.CorrelationToken {
    return adapter.CorrelationToken.fromBytes(@splat(seed));
}

fn ownedRequest(key: WorkspaceKey, id: SessionId, seed: u8) CreateRequest {
    return .{
        .binding = .{ .workspace = key, .session = id, .session_kind = .agent_terminal, .scratchpad = .first },
        .harness = .codex,
        .ownership = .owned,
        .token = testToken(seed),
    };
}

test "capabilities follow the adapter until the agent exits" {
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    const id = try registry.create(ownedRequest(WorkspaceKey.fromOrdinal(0), SessionId.fromOrdinal(1), 1));
    try testing.expect(!registry.get(id).?.capabilities.respond_permission);
    try testing.expect(registry.setCapabilities(id, .{ .poll = true, .respond_permission = true }));
    try testing.expect(registry.get(id).?.capabilities.respond_permission);
    try testing.expect(!registry.setCapabilities(id, .{ .poll = true, .respond_permission = true }));
    _ = try registry.apply(id, .{ .exited = .{ .code = 0 } });
    try testing.expect(!registry.setCapabilities(id, .{}));
    try testing.expect(registry.get(id).?.capabilities.respond_permission);
}

test "agents group by workspace under monotonic ids that are never reused" {
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    const one = WorkspaceKey.fromOrdinal(0);
    const two = WorkspaceKey.fromOrdinal(1);

    const a = try registry.create(ownedRequest(one, SessionId.fromOrdinal(1), 1));
    const b = try registry.create(ownedRequest(two, SessionId.fromOrdinal(1), 2));
    const c = try registry.create(ownedRequest(one, SessionId.fromOrdinal(2), 3));
    try testing.expectEqual(@as(u64, 0), a.ordinal());
    try testing.expectEqual(@as(u64, 1), b.ordinal());
    try testing.expectEqual(@as(u64, 2), c.ordinal());

    var it = registry.inWorkspace(one);
    try testing.expectEqual(a, it.next().?.id);
    try testing.expectEqual(c, it.next().?.id);
    try testing.expect(it.next() == null);
    var it2 = registry.inWorkspace(two);
    try testing.expectEqual(b, it2.next().?.id);
    try testing.expect(it2.next() == null);

    try testing.expectEqual(c, registry.findBySession(one, SessionId.fromOrdinal(2)).?);
    try testing.expectEqual(b, registry.findByToken(testToken(2)).?);
    try testing.expect(registry.findByToken(testToken(9)) == null);

    try registry.remove(a);
    try testing.expect(registry.get(a) == null);
    try testing.expectError(error.UnknownAgent, registry.remove(a));
    try testing.expectError(error.UnknownAgent, registry.apply(a, .{ .exited = .{ .code = 0 } }));
    const d = try registry.create(ownedRequest(one, SessionId.fromOrdinal(1), 4));
    try testing.expectEqual(@as(u64, 3), d.ordinal());

    try testing.expectEqual(@as(usize, 2), registry.removeWorkspace(one));
    try testing.expectEqual(@as(usize, 1), registry.all().len);
    try testing.expectEqual(b, registry.all()[0].id);
    const e = try registry.create(ownedRequest(one, SessionId.fromOrdinal(2), 5));
    try testing.expectEqual(@as(u64, 4), e.ordinal());
}

test "the scratchpad and human sessions are never an owned agent's" {
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    const key = WorkspaceKey.first;
    const scratchpad = SessionId.first;

    // The scratchpad by id, whatever kind the caller claims, and by kind.
    for ([_]session.Session.Kind{ .agent_terminal, .human_terminal, .scratchpad }) |kind| {
        for ([_]Ownership{ .owned, .observed }) |ownership| {
            var request = ownedRequest(key, scratchpad, 1);
            request.binding.session_kind = kind;
            request.ownership = ownership;
            try testing.expectError(error.ScratchpadRefused, registry.create(request));
        }
    }
    var by_kind = ownedRequest(key, SessionId.fromOrdinal(5), 1);
    by_kind.binding.session_kind = .scratchpad;
    try testing.expectError(error.ScratchpadRefused, registry.create(by_kind));

    // Owned agents need their own agent session; observed ones live in a
    // human terminal and nowhere else.
    var owned_human = ownedRequest(key, SessionId.fromOrdinal(2), 1);
    owned_human.binding.session_kind = .human_terminal;
    try testing.expectError(error.NotAgentSession, registry.create(owned_human));
    var observed_agent = ownedRequest(key, SessionId.fromOrdinal(2), 1);
    observed_agent.ownership = .observed;
    try testing.expectError(error.NotHumanSession, registry.create(observed_agent));
    try testing.expectEqual(@as(usize, 0), registry.all().len);

    var observed = owned_human;
    observed.ownership = .observed;
    const watched = try registry.create(observed);
    try testing.expectEqual(Ownership.observed, registry.get(watched).?.ownership);

    // One live agent per session; once it exits the session may host another.
    try testing.expectError(error.SessionAlreadyBound, registry.create(observed));
    _ = try registry.apply(watched, .{ .exited = .{ .code = 0 } });
    const again = try registry.create(observed);
    try testing.expect(again != watched);
}

test "structured status wins over heuristics, and an exit ends the record" {
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    const id = try registry.create(ownedRequest(.first, SessionId.fromOrdinal(1), 1));

    var applied = try registry.apply(id, .{ .status_change = .{ .state = .working, .source = .heuristic } });
    try testing.expectEqual(Applied.Outcome.changed, applied.outcome);
    try testing.expectEqual(Source.heuristic, registry.get(id).?.source);

    applied = try registry.apply(id, .{ .tool_use = .{ .name = "Bash", .summary = "ls" } });
    try testing.expectEqual(Applied.Outcome.unchanged, applied.outcome);
    try testing.expectEqualStrings("Bash", registry.get(id).?.summary());

    applied = try registry.apply(id, .{ .status_change = .{ .state = .idle, .source = .heuristic } });
    try testing.expectEqual(Applied.Outcome.ignored, applied.outcome);
    try testing.expectEqual(State.working, registry.get(id).?.state);

    // A refused transition leaves the agent untouched.
    _ = try registry.apply(id, .{ .status_change = .{ .state = .done, .source = .structured } });
    try testing.expectError(error.IllegalTransition, registry.apply(id, .{ .status_change = .{ .state = .waiting_input, .source = .structured } }));
    try testing.expectError(error.IllegalTransition, registry.apply(id, .{ .permission_request = .{ .id = "r", .title = "t", .decisions = &.{} } }));
    try testing.expectEqual(State.done, registry.get(id).?.state);
    try testing.expectEqual(@as(usize, 0), registry.get(id).?.pendingPermissions());

    applied = try registry.apply(id, .{ .exited = .{ .signal = 15 } });
    try testing.expectEqual(State.errored, applied.current);
    try testing.expect(registry.get(id).?.hasExited());
    try testing.expectError(error.AgentExited, registry.apply(id, .{ .status_change = .{ .state = .working, .source = .structured } }));
}

test "pending permissions are tracked by id and bounded" {
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
    const id = try registry.create(ownedRequest(.first, SessionId.fromOrdinal(1), 1));
    _ = try registry.apply(id, .{ .status_change = .{ .state = .working, .source = .structured } });

    var names: [max_pending_permissions + 1][2]u8 = undefined;
    for (&names, 0..) |*name, i| name.* = .{ 'p', @intCast('a' + i) };
    for (names[0..max_pending_permissions]) |*name| {
        _ = try registry.apply(id, .{ .permission_request = .{ .id = name, .title = "t", .decisions = &.{} } });
    }
    // A repeat of a pending id is not a new request.
    _ = try registry.apply(id, .{ .permission_request = .{ .id = &names[0], .title = "t", .decisions = &.{} } });
    try testing.expectEqual(@as(usize, max_pending_permissions), registry.get(id).?.pendingPermissions());
    try testing.expectError(error.TooManyPendingPermissions, registry.apply(id, .{ .permission_request = .{
        .id = &names[max_pending_permissions],
        .title = "t",
        .decisions = &.{},
    } }));
    try testing.expectError(error.EventTooLarge, registry.apply(id, .{ .permission_request = .{
        .id = "x" ** (event.max_identifier_bytes + 1),
        .title = "t",
        .decisions = &.{},
    } }));

    // Unknown ids resolve harmlessly; the state returns to working only when
    // the last pending request is gone.
    var applied = try registry.apply(id, .{ .permission_resolved = .{ .id = "nope", .outcome = .resolved_elsewhere } });
    try testing.expectEqual(State.waiting_permission, applied.current);
    for (names[0 .. max_pending_permissions - 1]) |*name| {
        applied = try registry.apply(id, .{ .permission_resolved = .{ .id = name, .outcome = .allowed } });
        try testing.expectEqual(State.waiting_permission, applied.current);
    }
    try testing.expect(registry.get(id).?.isPending(&names[max_pending_permissions - 1]));
    applied = try registry.apply(id, .{ .permission_resolved = .{ .id = &names[max_pending_permissions - 1], .outcome = .rejected } });
    try testing.expectEqual(Applied.Outcome.changed, applied.outcome);
    try testing.expectEqual(State.working, applied.current);
}
