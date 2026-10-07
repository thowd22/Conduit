//! A scripted adapter for tests (TASK-52), and for the fake-adapter E2E
//! scenarios TASK-56 will need.
//!
//! It implements every `Adapter` method without IO: `poll` pushes the next
//! scripted events, and every call that would act on a harness is recorded
//! instead. It impersonates whichever `Harness` the test names, so it adds no
//! harness of its own to the closed set.
//!
//! Memory: `script` and every slice in it are borrowed for the adapter's
//! lifetime. Recorded input and prompt text are copied into fixed inline
//! buffers. `asAdapter` lends the value; `destroy` only marks it destroyed.

const std = @import("std");
const adapter = @import("adapter.zig");
const event = @import("event.zig");
const Harness = @import("harness.zig").Harness;

const Allocator = std.mem.Allocator;

pub const FakeAdapter = struct {
    harness_value: Harness = .claude_code,
    caps: adapter.Capabilities = all_capabilities,
    version: []const u8 = "1.0.0-fake",
    installed: bool = true,
    /// Events delivered by successive polls, `poll_batch` at a time.
    script: []const event.Event = &.{},
    /// Files `launch` asks the owner to write, borrowed.
    launch_files: []const adapter.LaunchSpec.File = &.{},
    /// Overrides the scripted process `launch` describes, borrowed. The app's
    /// fake harness runs a real shell here so its tab has a live child.
    launch_argv: ?[]const []const u8 = null,
    poll_batch: usize = std.math.maxInt(usize),
    cursor: usize = 0,

    // What the adapter was asked to do.
    attached: ?adapter.AttachRequest = null,
    launches: usize = 0,
    stops: usize = 0,
    destroyed: bool = false,
    input_bytes: [256]u8 = undefined,
    input_len: usize = 0,
    prompt_bytes: [256]u8 = undefined,
    prompt_len: usize = 0,
    last_permission_request: [event.max_identifier_bytes]u8 = undefined,
    last_permission_request_len: usize = 0,
    last_permission_decision: [event.max_identifier_bytes]u8 = undefined,
    last_permission_decision_len: usize = 0,
    /// Test-only (TASK-57): answer each `respondPermission` with a
    /// `permission_resolved` for that request on the next poll, as a real
    /// harness reports the outcome of an answer. A `reject` decision in the
    /// script resolves as rejected, anything else as allowed.
    resolve_on_answer: bool = false,
    pending_resolution: ?event.PermissionOutcome = null,
    /// Answers received, for checks.
    answers: usize = 0,

    pub const all_capabilities: adapter.Capabilities = .{
        .detect = true,
        .launch = true,
        .attach = true,
        .poll = true,
        .send_input = true,
        .respond_permission = true,
        .read_prompt = true,
        .update_prompt = true,
        .stop = true,
        .structured_status = true,
        .permission_requests = true,
        .transcript = true,
        .subagents = true,
    };

    const vtable: adapter.Adapter.VTable = .{
        .harness = harness,
        .capabilities = capabilities,
        .detect = detect,
        .launch = launch,
        .attach = attach,
        .poll = poll,
        .send_input = sendInput,
        .respond_permission = respondPermission,
        .read_prompt = readPrompt,
        .update_prompt = updatePrompt,
        .stop = stop,
        .destroy = destroy,
    };

    pub fn asAdapter(self: *FakeAdapter) adapter.Adapter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn input(self: *const FakeAdapter) []const u8 {
        return self.input_bytes[0..self.input_len];
    }

    pub fn permissionAnswer(self: *const FakeAdapter) struct { request: []const u8, decision: []const u8 } {
        return .{
            .request = self.last_permission_request[0..self.last_permission_request_len],
            .decision = self.last_permission_decision[0..self.last_permission_decision_len],
        };
    }

    fn cast(ptr: *anyopaque) *FakeAdapter {
        return @ptrCast(@alignCast(ptr));
    }

    fn castConst(ptr: *const anyopaque) *const FakeAdapter {
        return @ptrCast(@alignCast(ptr));
    }

    fn harness(ptr: *const anyopaque) Harness {
        return castConst(ptr).harness_value;
    }

    fn capabilities(ptr: *const anyopaque) adapter.Capabilities {
        return castConst(ptr).caps;
    }

    fn detect(ptr: *anyopaque, request: adapter.DetectRequest) adapter.Error!?[]const u8 {
        const self = cast(ptr);
        if (!self.installed) return null;
        if (request.version_buffer.len < self.version.len) return error.NoSpaceLeft;
        const out = request.version_buffer[0..self.version.len];
        @memcpy(out, self.version);
        return out;
    }

    fn launch(ptr: *anyopaque, allocator: Allocator, request: adapter.LaunchRequest) adapter.Error!adapter.LaunchSpec {
        const self = cast(ptr);
        self.launches += 1;
        const env = try allocator.alloc([]const u8, 1);
        var entry: [adapter.correlation_env_name.len + 1 + adapter.CorrelationToken.text_len]u8 = undefined;
        env[0] = try allocator.dupe(u8, request.token.envEntry(&entry));
        const files = try allocator.dupe(adapter.LaunchSpec.File, self.launch_files);
        if (self.launch_argv) |scripted| {
            const argv = try allocator.alloc([]const u8, scripted.len);
            for (argv, scripted) |*slot, arg| slot.* = try allocator.dupe(u8, arg);
            return .{ .argv = argv, .env = env, .files = files };
        }
        const argv_len: usize = if (request.initial_prompt == null) 1 else 3;
        const argv = try allocator.alloc([]const u8, argv_len);
        argv[0] = "fake-agent";
        if (request.initial_prompt) |prompt| {
            argv[1] = "--";
            argv[2] = try allocator.dupe(u8, prompt);
        }
        return .{ .argv = argv, .env = env, .files = files };
    }

    fn attach(ptr: *anyopaque, request: adapter.AttachRequest) adapter.Error!void {
        const self = cast(ptr);
        if (self.attached != null) return error.UnknownTarget;
        self.attached = .{ .session = request.session, .token = request.token };
    }

    fn poll(ptr: *anyopaque, queue: *event.EventQueue) adapter.Error!usize {
        const self = cast(ptr);
        var pushed: usize = 0;
        if (self.pending_resolution) |outcome| {
            const id = self.last_permission_request[0..self.last_permission_request_len];
            if (queue.push(.{ .permission_resolved = .{ .id = id, .outcome = outcome } })) |_| {
                self.pending_resolution = null;
                pushed += 1;
            } else |err| switch (err) {
                error.QueueFull => return pushed,
                error.EventTooLarge => return error.Protocol,
            }
        }
        var scripted: usize = 0;
        while (self.cursor < self.script.len and scripted < self.poll_batch) {
            queue.push(self.script[self.cursor]) catch |err| switch (err) {
                // Kept for the next poll, as a real transport would.
                error.QueueFull => break,
                error.EventTooLarge => return error.Protocol,
            };
            self.cursor += 1;
            scripted += 1;
            pushed += 1;
        }
        return pushed;
    }

    fn sendInput(ptr: *anyopaque, bytes: []const u8) adapter.Error!void {
        const self = cast(ptr);
        if (bytes.len > self.input_bytes.len - self.input_len) return error.NoSpaceLeft;
        @memcpy(self.input_bytes[self.input_len..][0..bytes.len], bytes);
        self.input_len += bytes.len;
    }

    fn respondPermission(ptr: *anyopaque, request_id: []const u8, decision_id: []const u8) adapter.Error!void {
        const self = cast(ptr);
        if (request_id.len > event.max_identifier_bytes or decision_id.len > event.max_identifier_bytes)
            return error.UnknownTarget;
        @memcpy(self.last_permission_request[0..request_id.len], request_id);
        self.last_permission_request_len = request_id.len;
        @memcpy(self.last_permission_decision[0..decision_id.len], decision_id);
        self.last_permission_decision_len = decision_id.len;
        self.answers += 1;
        if (self.resolve_on_answer) self.pending_resolution = self.outcomeOf(request_id, decision_id);
    }

    /// How the scripted request `request_id` ends when `decision_id` is chosen.
    fn outcomeOf(self: *const FakeAdapter, request_id: []const u8, decision_id: []const u8) event.PermissionOutcome {
        for (self.script) |scripted| {
            const request = switch (scripted) {
                .permission_request => |p| p,
                else => continue,
            };
            if (!std.mem.eql(u8, request.id, request_id)) continue;
            for (request.decisions) |decision| {
                if (std.mem.eql(u8, decision.id, decision_id)) return if (decision.kind == .reject) .rejected else .allowed;
            }
        }
        return .allowed;
    }

    fn readPrompt(ptr: *anyopaque, out: []u8) adapter.Error![]const u8 {
        const self = cast(ptr);
        if (out.len < self.prompt_len) return error.NoSpaceLeft;
        @memcpy(out[0..self.prompt_len], self.prompt_bytes[0..self.prompt_len]);
        return out[0..self.prompt_len];
    }

    fn updatePrompt(ptr: *anyopaque, text: []const u8) adapter.Error!void {
        const self = cast(ptr);
        if (text.len > self.prompt_bytes.len) return error.NoSpaceLeft;
        @memcpy(self.prompt_bytes[0..text.len], text);
        self.prompt_len = text.len;
    }

    fn stop(ptr: *anyopaque) adapter.Error!void {
        cast(ptr).stops += 1;
    }

    fn destroy(ptr: *anyopaque) void {
        cast(ptr).destroyed = true;
    }
};

// Tests ---------------------------------------------------------------------

const testing = std.testing;
const registry_mod = @import("registry.zig");
const heuristics_mod = @import("heuristics.zig");
const workspace = @import("workspace");
const session = @import("session");

test "every method dispatches when supported and is Unsupported otherwise" {
    // A real Local context only lends the probe target; the fake never
    // spawns through it.
    var context = try workspace.ExecutionContext.local(testing.allocator);
    defer context.deinit();
    var fake: FakeAdapter = .{ .harness_value = .pi };
    const a = fake.asAdapter();
    try testing.expectEqual(Harness.pi, a.harness());

    var version: [32]u8 = undefined;
    try testing.expectEqualStrings("1.0.0-fake", (try a.detect(.{ .context = context.borrow(), .version_buffer = &version })).?);
    fake.installed = false;
    try testing.expect((try a.detect(.{ .context = context.borrow(), .version_buffer = &version })) == null);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const token = adapter.CorrelationToken.fromBytes(@splat(0xab));
    const spec = try a.launch(arena_state.allocator(), .{
        .context_kind = .local,
        .cwd = "/work",
        .initial_prompt = "fix it",
        .token = token,
    });
    try testing.expectEqualStrings("fix it", spec.argv[2]);
    try testing.expectEqualStrings(
        "CONDUIT_AGENT_TOKEN=abababababababababababababababab",
        spec.env[0],
    );

    try a.attach(.{ .session = .first, .token = token });
    try testing.expectError(error.UnknownTarget, a.attach(.{ .session = .first, .token = token }));
    try a.sendInput("hello");
    try a.respondPermission("req-1", "allow");
    try a.updatePrompt("be terse");
    var prompt: [32]u8 = undefined;
    try testing.expectEqualStrings("be terse", try a.readPrompt(&prompt));
    try a.stop();
    var queue = try event.EventQueue.init(testing.allocator, testing.io, 4);
    defer queue.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), try a.poll(&queue));
    try testing.expectEqualStrings("hello", fake.input());
    try testing.expectEqualStrings("allow", fake.permissionAnswer().decision);
    try testing.expectEqual(@as(usize, 1), fake.stops);

    // Turn each capability off in turn: exactly that method refuses, and the
    // fake records nothing for it.
    const fields = @typeInfo(adapter.Capabilities).@"struct".fields;
    inline for (fields[0..9]) |field| {
        var limited: FakeAdapter = .{};
        @field(limited.caps, field.name) = false;
        const l = limited.asAdapter();
        const result: adapter.Error!void = switch (std.meta.stringToEnum(std.meta.FieldEnum(adapter.Capabilities), field.name).?) {
            .detect => if (l.detect(.{ .context = context.borrow(), .version_buffer = &version })) |_| {} else |err| err,
            .launch => if (l.launch(arena_state.allocator(), .{ .context_kind = .ssh, .cwd = "/", .token = token })) |_| {} else |err| err,
            .attach => l.attach(.{ .session = .first, .token = token }),
            .poll => if (l.poll(&queue)) |_| {} else |err| err,
            .send_input => l.sendInput("x"),
            .respond_permission => l.respondPermission("r", "d"),
            .read_prompt => if (l.readPrompt(&prompt)) |_| {} else |err| err,
            .update_prompt => l.updatePrompt("p"),
            .stop => l.stop(),
            else => unreachable,
        };
        try testing.expectError(error.Unsupported, result);
        try testing.expectEqual(@as(usize, 0), limited.launches + limited.stops + limited.input_len + limited.prompt_len);
        try testing.expect(limited.attached == null);
    }

    // The PTY baseline: no capability at all, every method refuses.
    var baseline: FakeAdapter = .{ .caps = .none };
    try testing.expectError(error.Unsupported, baseline.asAdapter().stop());
    try testing.expectError(error.Unsupported, baseline.asAdapter().sendInput("x"));

    // A vtable without a slot refuses even if the capability bit is set.
    const sparse: adapter.Adapter.VTable = .{
        .harness = FakeAdapter.harness,
        .capabilities = FakeAdapter.capabilities,
        .destroy = FakeAdapter.destroy,
    };
    var claims_all: FakeAdapter = .{};
    const s: adapter.Adapter = .{ .ptr = &claims_all, .vtable = &sparse };
    try testing.expectError(error.Unsupported, s.stop());
    s.destroy();
    try testing.expect(claims_all.destroyed);
}

test "correlation tokens round-trip and refuse anything else" {
    const token = adapter.CorrelationToken.fromBytes(.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 255 });
    try testing.expectEqualStrings("000102030405060708090a0b0c0d0eff", token.text());
    try testing.expect(token.eql(try adapter.CorrelationToken.parse(token.text())));
    for ([_][]const u8{ "", "000102030405060708090a0b0c0d0eF0", "000102030405060708090a0b0c0d0e", "000102030405060708090a0b0c0d0eff00", "zz0102030405060708090a0b0c0d0eff" }) |bad| {
        try testing.expectError(error.InvalidToken, adapter.CorrelationToken.parse(bad));
    }
}

/// Drive scripted events from the fake through the queue into the registry,
/// the way the app will: poll on an IO worker, drain and apply on the owner.
fn pump(fake: *FakeAdapter, queue: *event.EventQueue, out: []event.StoredEvent, reg: *registry_mod.Registry, id: registry_mod.AgentId, states: []registry_mod.Applied) !usize {
    _ = try fake.asAdapter().poll(queue);
    const count = queue.drain(out);
    for (out[0..count], 0..) |*stored, i| states[i] = try reg.apply(id, stored.event);
    return count;
}

fn ownedBinding() registry_mod.Binding {
    return .{
        .workspace = .first,
        .session = session.SessionId.fromOrdinal(1),
        .session_kind = .agent_terminal,
        .scratchpad = .first,
    };
}

test "a full lifecycle from the fake: idle, working, permission, working, done, exited" {
    const decisions = [_]event.Decision{
        .{ .id = "allow", .label = "Allow once", .kind = .allow_once },
        .{ .id = "always", .label = "Always allow", .kind = .allow_always },
        .{ .id = "deny", .label = "Reject", .kind = .reject },
    };
    const script = [_]event.Event{
        .{ .status_change = .{ .state = .working, .source = .structured } },
        .{ .message = .{ .role = .assistant, .text = "Reading the build." } },
        .{ .tool_use = .{ .name = "Read", .summary = "build.zig" } },
        .{ .file_reference = .{ .path = "build.zig", .line = 42 } },
        .{ .subagent = .{ .id = "sub-1", .name = "explore", .phase = .start } },
        .{ .subagent = .{ .id = "sub-1", .name = "explore", .phase = .stop } },
        .{ .permission_request = .{ .id = "req-1", .title = "Run zig build?", .decisions = &decisions } },
        .{ .permission_resolved = .{ .id = "req-1", .outcome = .allowed } },
        .{ .status_change = .{ .state = .done, .source = .structured } },
        .{ .status_change = .{ .state = .idle, .source = .structured } },
        .{ .exited = .{ .code = 0 } },
    };
    var fake: FakeAdapter = .{ .script = &script, .poll_batch = 3 };
    var queue = try event.EventQueue.init(testing.allocator, testing.io, 4);
    defer queue.deinit(testing.allocator);
    const out = try testing.allocator.alloc(event.StoredEvent, 4);
    defer testing.allocator.free(out);
    var reg = registry_mod.Registry.init(testing.allocator);
    defer reg.deinit();

    const id = try reg.create(.{
        .binding = ownedBinding(),
        .harness = fake.asAdapter().harness(),
        .ownership = .owned,
        .token = adapter.CorrelationToken.fromBytes(@splat(7)),
        .capabilities = fake.asAdapter().capabilities(),
    });
    try testing.expectEqual(@import("state.zig").State.idle, reg.get(id).?.state);

    var applied: [4]registry_mod.Applied = undefined;
    var seen: [script.len]@import("state.zig").State = undefined;
    var total: usize = 0;
    while (total < script.len) {
        const n = try pump(&fake, &queue, out, &reg, id, &applied);
        try testing.expect(n != 0);
        // The request's own decisions reach the owner thread intact.
        for (out[0..n]) |*stored| {
            if (stored.event == .permission_request) {
                try testing.expectEqualStrings("Always allow", stored.event.permission_request.decisions[1].label);
                // The human answers by gesture; the fake records it.
                try fake.asAdapter().respondPermission("req-1", stored.event.permission_request.decisions[0].id);
            }
        }
        for (applied[0..n], 0..) |a, i| seen[total + i] = a.current;
        total += n;
    }
    const S = @import("state.zig").State;
    try testing.expectEqualSlices(S, &.{
        .working,            .working, .working, .working, .working, .working,
        .waiting_permission, .working, .done,    .idle,    .done,
    }, &seen);
    try testing.expectEqualStrings("allow", fake.permissionAnswer().decision);
    const agent = reg.get(id).?;
    try testing.expect(agent.hasExited());
    try testing.expect(agent.structured);
    try testing.expectEqual(event.Event.Kind.exited, agent.last_event.?);
    try testing.expectEqualStrings("Run zig build?", agent.summary());
    // Nothing follows an exit.
    try testing.expectError(error.AgentExited, reg.apply(id, .{ .status_change = .{ .state = .working, .source = .structured } }));
}

test "the fake errors, and a permission resolved elsewhere unblocks the agent" {
    const decisions = [_]event.Decision{.{ .id = "y", .label = "Yes", .kind = .allow_once }};
    const script = [_]event.Event{
        .{ .status_change = .{ .state = .working, .source = .structured } },
        .{ .permission_request = .{ .id = "p", .title = "Edit?", .decisions = &decisions } },
        // The human answered in the harness's own TUI.
        .{ .permission_resolved = .{ .id = "p", .outcome = .resolved_elsewhere } },
        .{ .status_change = .{ .state = .errored, .source = .structured } },
        .{ .status_change = .{ .state = .working, .source = .structured } },
        .{ .exited = .{ .signal = 9 } },
    };
    var fake: FakeAdapter = .{ .script = &script };
    var queue = try event.EventQueue.init(testing.allocator, testing.io, 8);
    defer queue.deinit(testing.allocator);
    const out = try testing.allocator.alloc(event.StoredEvent, 8);
    defer testing.allocator.free(out);
    var reg = registry_mod.Registry.init(testing.allocator);
    defer reg.deinit();
    const id = try reg.create(.{ .binding = ownedBinding(), .harness = .codex, .ownership = .owned, .token = adapter.CorrelationToken.fromBytes(@splat(1)) });

    var applied: [8]registry_mod.Applied = undefined;
    const n = try pump(&fake, &queue, out, &reg, id, &applied);
    try testing.expectEqual(script.len, n);
    const S = @import("state.zig").State;
    const expected = [_]S{ .working, .waiting_permission, .working, .errored, .working, .errored };
    for (expected, applied[0..n]) |state, a| try testing.expectEqual(state, a.current);
    try testing.expect(!reg.get(id).?.exit.?.succeeded());
}

test "a heuristic-only agent follows the PTY baseline through the registry" {
    var reg = registry_mod.Registry.init(testing.allocator);
    defer reg.deinit();
    const id = try reg.create(.{
        .binding = .{ .workspace = .first, .session = session.SessionId.fromOrdinal(3), .session_kind = .human_terminal, .scratchpad = .first },
        .harness = .pi,
        .ownership = .observed,
        .token = adapter.CorrelationToken.fromBytes(@splat(2)),
    });
    var h: heuristics_mod.Heuristics = .{ .quiet_after_ns = 10 };
    const observations = [_]heuristics_mod.Observation{
        .{ .output = .{ .now_ns = 1 } },
        .bell,
        .user_input,
        .{ .tick = .{ .now_ns = 50 } },
        .{ .child_exited = .{ .code = 0 } },
    };
    const S = @import("state.zig").State;
    const expected = [_]S{ .working, .waiting_input, .working, .idle, .done };
    for (observations, expected) |observation, state| {
        const batch = h.observe(observation);
        for (batch.events()) |ev| _ = try reg.apply(id, ev);
        try testing.expectEqual(state, reg.get(id).?.state);
        try testing.expectEqual(@import("state.zig").Source.heuristic, reg.get(id).?.source);
    }
    try testing.expect(reg.get(id).?.hasExited());
}

test "launch carries the files and argv the owner must write and spawn" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const files = [_]adapter.LaunchSpec.File{
        .{ .path = "/sink/conduit.js", .bytes = "export default () => {}" },
        .{ .path = "/sink/hook.sh", .bytes = "#!/bin/sh\n", .executable = true },
    };
    const argv = [_][]const u8{ "/bin/sh", "-c", "exec cat" };
    var fake: FakeAdapter = .{ .launch_files = &files, .launch_argv = &argv };
    const spec = try fake.asAdapter().launch(arena_state.allocator(), .{
        .context_kind = .local,
        .cwd = "/work",
        .token = adapter.CorrelationToken.fromBytes(@splat(1)),
    });
    try testing.expectEqual(@as(usize, 2), spec.files.len);
    try testing.expectEqualStrings("/sink/conduit.js", spec.files[0].path);
    try testing.expect(!spec.files[0].executable);
    try testing.expect(spec.files[1].executable);
    try testing.expectEqualStrings("exec cat", spec.argv[2]);
    // The default launch writes nothing.
    var plain: FakeAdapter = .{};
    const plain_spec = try plain.asAdapter().launch(arena_state.allocator(), .{
        .context_kind = .local,
        .cwd = "/work",
        .token = adapter.CorrelationToken.fromBytes(@splat(2)),
    });
    try testing.expectEqual(@as(usize, 0), plain_spec.files.len);
    try testing.expectEqualStrings("fake-agent", plain_spec.argv[0]);
}

test "resolve_on_answer reports each answer's outcome on the next poll" {
    const decisions = [_]event.Decision{
        .{ .id = "allow", .label = "Allow once", .kind = .allow_once },
        .{ .id = "deny", .label = "Reject", .kind = .reject },
    };
    const script = [_]event.Event{.{ .permission_request = .{ .id = "r1", .title = "Run", .decisions = &decisions } }};
    var fake: FakeAdapter = .{ .script = &script, .resolve_on_answer = true };
    var queue = try event.EventQueue.init(testing.allocator, testing.io, 4);
    defer queue.deinit(testing.allocator);
    const handle = fake.asAdapter();
    try testing.expectEqual(@as(usize, 1), try handle.poll(&queue));
    try handle.respondPermission("r1", "deny");
    try testing.expectEqual(@as(usize, 1), fake.answers);
    try testing.expectEqual(@as(usize, 1), try handle.poll(&queue));
    const out = try testing.allocator.alloc(event.StoredEvent, 2);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 2), queue.drain(out));
    try testing.expectEqualStrings("r1", out[1].event.permission_resolved.id);
    try testing.expectEqual(event.PermissionOutcome.rejected, out[1].event.permission_resolved.outcome);
    try testing.expectEqual(@as(usize, 0), try handle.poll(&queue));
}
