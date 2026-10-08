//! Wire protocol of the TASK-60 control API: tokens, methods, typed requests,
//! faults and reply encoding. Transport-neutral and allocation-bounded.
//!
//! A frame is one JSON object without its newline (the transport owns
//! framing), at most `max_frame_bytes`:
//!
//!   {"id":1,"method":"tab.open","token":"<32 hex>","session":4,"params":{...}}
//!
//! `jsonrpc` may be present and must then be "2.0"; `params` and `session`
//! are optional. A reply is `{"jsonrpc":"2.0","id":…,"result":…}` or
//! `{"jsonrpc":"2.0","id":…,"error":{"code":…,"message":…}}`.
//!
//! Everything here is untrusted harness input. Nothing is resolved, opened or
//! executed: paths are opaque strings for the workspace's ExecutionContext,
//! `command` is an argv (never a shell line), and payload text is never
//! logged. Memory: `Parsed` owns one arena holding every decoded string; the
//! typed `Envelope` borrows it.

const std = @import("std");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;

/// The child environment variable naming the control endpoint path.
pub const endpoint_env_name = "CONDUIT_CONTROL_ENDPOINT";
/// The child environment variable carrying the workspace's control token.
pub const token_env_name = "CONDUIT_CONTROL_TOKEN";
/// The child environment variable carrying the child's own session id, which
/// a client passes back as `session` so the owner knows which tab or pane is
/// "mine". Never set for the scratchpad's child.
pub const session_env_name = "CONDUIT_CONTROL_SESSION";

/// Largest request frame, excluding the newline.
pub const max_frame_bytes: usize = 64 * 1024;
/// Largest encoded reply. Replies carry only ids and fixed messages.
pub const max_reply_bytes: usize = 1024;
/// JSON nesting allowed before a parse tree is built (agent payloads nest).
pub const max_json_depth: usize = 32;
/// Longest string request id echoed back.
pub const max_id_bytes: usize = 128;
/// Longest working directory accepted, matching the terminal's OSC 7 limit.
pub const max_path_bytes: usize = 4096;
/// Most argv items in a `command`.
pub const max_argv_items: usize = 256;
/// Longest single argv item.
pub const max_arg_bytes: usize = 4096;
/// Longest tab title.
pub const max_title_bytes: usize = 256;
/// Longest tab status text.
pub const max_status_bytes: usize = 64;
/// Longest notification title.
pub const max_notify_title_bytes: usize = 256;
/// Longest notification body.
pub const max_notify_body_bytes: usize = 4096;
/// Longest agent id named by `view.agent`.
pub const max_agent_id_bytes: usize = 256;
/// Longest SSH destination `instance.open_ssh` accepts (TASK-66).
pub const max_destination_bytes: usize = 256;
/// Longest workspace name `instance.open_workspace` accepts.
pub const max_workspace_name_bytes: usize = 256;
/// Longest harness name `instance.agent` accepts.
pub const max_harness_bytes: usize = 32;
/// Longest initial prompt `instance.agent` accepts.
pub const max_prompt_bytes: usize = 4096;

/// A random 128-bit control token, kept as 32 lowercase hex digits. The owner
/// supplies the random bytes, so this module needs no OS entropy.
pub const Token = struct {
    pub const byte_count = 16;
    pub const text_len = byte_count * 2;

    digits: [text_len]u8,

    pub fn fromBytes(bytes: [byte_count]u8) Token {
        return .{ .digits = std.fmt.bytesToHex(bytes, .lower) };
    }

    /// Parse an untrusted token: exactly 32 lowercase hex digits.
    pub fn parse(text_value: []const u8) error{InvalidToken}!Token {
        var token: Token = undefined;
        if (!parseHex32(text_value, &token.digits)) return error.InvalidToken;
        return token;
    }

    pub fn text(self: *const Token) []const u8 {
        return &self.digits;
    }

    /// Constant-time comparison, so a probing client learns nothing from timing.
    pub fn eql(a: Token, b: Token) bool {
        return std.crypto.timing_safe.eql([text_len]u8, a.digits, b.digits);
    }
};

/// An agent correlation token named by `agent.event`, in the same 32
/// lowercase hex form as `agent.CorrelationToken` (decision-7, rule 1).
pub const AgentToken = [Token.text_len]u8;

fn parseHex32(text_value: []const u8, out: *[Token.text_len]u8) bool {
    if (text_value.len != Token.text_len) return false;
    for (text_value, 0..) |c, i| switch (c) {
        '0'...'9', 'a'...'f' => out[i] = c,
        else => return false,
    };
    return true;
}

/// Every method the server dispatches. Nothing else is accepted.
pub const Method = enum {
    ping,
    tab_open,
    pane_split,
    view_agent,
    view_backlog,
    tab_status,
    notify,
    agent_event,
    /// TASK-66's instance methods: what a `conduit <command>` forwards to a
    /// running instance. Accepted with the instance token on the instance
    /// endpoint, or with a workspace token on the run endpoint (a command
    /// typed inside a Conduit terminal).
    instance_open_directory,
    instance_open_ssh,
    instance_open_workspace,
    instance_agent,

    /// Whether this is one of the instance methods.
    pub fn isInstance(self: Method) bool {
        return switch (self) {
            .instance_open_directory, .instance_open_ssh, .instance_open_workspace, .instance_agent => true,
            else => false,
        };
    }

    /// The dotted wire name.
    pub fn wireName(self: Method) []const u8 {
        return switch (self) {
            .ping => "ping",
            .tab_open => "tab.open",
            .pane_split => "pane.split",
            .view_agent => "view.agent",
            .view_backlog => "view.backlog",
            .tab_status => "tab.status",
            .notify => "notify",
            .agent_event => "agent.event",
            .instance_open_directory => "instance.open_directory",
            .instance_open_ssh => "instance.open_ssh",
            .instance_open_workspace => "instance.open_workspace",
            .instance_agent => "instance.agent",
        };
    }

    /// Parse an exact wire name; names are never normalised.
    pub fn parse(text_value: []const u8) ?Method {
        inline for (@typeInfo(Method).@"enum".fields) |field| {
            const method: Method = @enumFromInt(field.value);
            if (std.mem.eql(u8, text_value, method.wireName())) return method;
        }
        return null;
    }
};

/// Where a new pane goes relative to the caller's pane.
pub const Direction = enum { right, down };

/// What to start in a new tab or pane. Absent fields mean "the workspace
/// default": the caller session's tracked cwd and the workspace shell.
pub const Spawn = struct {
    /// Opaque path for the ExecutionContext to resolve; never resolved here.
    cwd: ?[]const u8 = null,
    /// An argv. Never interpreted by a shell.
    command: ?[]const []const u8 = null,
};

/// Typed parameters. Every slice borrows the `Parsed` arena.
pub const Params = union(Method) {
    ping: void,
    tab_open: struct {
        spawn: Spawn,
        title: ?[]const u8 = null,
    },
    pane_split: struct {
        direction: Direction,
        spawn: Spawn,
    },
    view_agent: struct {
        agent_id: ?[]const u8 = null,
    },
    view_backlog: void,
    tab_status: struct {
        /// Replaces the caller tab's status prefix; empty clears it.
        text: ?[]const u8 = null,
        /// Raises (`true`) or clears (`false`) the tab's attention mark.
        attention: ?bool = null,
    },
    notify: struct {
        title: []const u8,
        body: []const u8,
    },
    agent_event: struct {
        /// The agent's correlation token, as its environment reported it.
        agent: AgentToken,
        /// The payload object re-encoded as compact JSON, uninterpreted.
        payload_json: []const u8,
    },
    instance_open_directory: struct {
        /// An absolute local directory. Opened as given; never resolved here.
        path: []const u8,
    },
    instance_open_ssh: struct {
        /// `[user@]host[:port]` or an ssh_config alias; validated by the owner.
        destination: []const u8,
    },
    instance_open_workspace: struct {
        name: []const u8,
        /// Where a new workspace of that name opens when none exists yet.
        path: ?[]const u8 = null,
    },
    instance_agent: struct {
        /// A harness name (`claude`, `codex`, `pi`, `opencode`, ...),
        /// matched by the owner against what it can launch.
        harness: []const u8,
        prompt: ?[]const u8 = null,
    },
};

/// A JSON-RPC style request id. String bytes are owned by `Parsed`.
pub const RequestId = union(enum) {
    integer: i64,
    string: []const u8,
};

/// One validated frame. The token is not yet resolved to a workspace.
pub const Envelope = struct {
    id: RequestId,
    token: Token,
    /// The caller's own session id, if it named one.
    session: ?u32,
    params: Params,
};

/// Stable fault codes. The message is the code's fixed name, so replies never
/// echo request text.
pub const FaultCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    /// The method is valid but the owner cannot perform it now.
    unavailable = -32000,
    /// The token is missing, malformed, unknown or expired.
    unauthorized = -32001,
    /// The request named the workspace's scratchpad session.
    scratchpad_not_addressable = -32002,
    /// Too many requests or connections are in flight.
    busy = -32003,
    /// The named session or agent is not in the caller's workspace.
    not_found = -32004,
    /// The owner did not reply before the server's deadline.
    timed_out = -32008,

    pub fn message(self: FaultCode) []const u8 {
        return switch (self) {
            .parse_error => "ParseError",
            .invalid_request => "InvalidRequest",
            .method_not_found => "MethodNotFound",
            .invalid_params => "InvalidParams",
            .internal_error => "InternalError",
            .unavailable => "Unavailable",
            .unauthorized => "Unauthorized",
            .scratchpad_not_addressable => "ScratchpadNotAddressable",
            .busy => "Busy",
            .not_found => "NotFound",
            .timed_out => "TimedOut",
        };
    }
};

/// A rejected frame and the id to echo when one was recoverable.
pub const Failure = struct {
    id: ?RequestId,
    fault: FaultCode,
};

/// The result of decoding one frame. Protocol failures are data.
pub const Outcome = union(enum) {
    envelope: Envelope,
    failure: Failure,
};

/// An owned parse arena plus its outcome.
pub const Parsed = struct {
    arena: *std.heap.ArenaAllocator,
    outcome: Outcome,

    pub fn deinit(self: *Parsed) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.* = undefined;
    }
};

/// Parse one frame (without its newline). Only allocation failure is a Zig
/// error; everything malformed becomes a `Failure`.
pub fn parseFrame(allocator: Allocator, frame: []const u8) Allocator.Error!Parsed {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = .init(allocator);
    errdefer arena.deinit();

    if (frame.len == 0 or frame.len > max_frame_bytes or !depthWithinLimit(frame)) {
        return failed(arena, null, .invalid_request);
    }
    if (!std.unicode.utf8ValidateSlice(frame)) return failed(arena, null, .parse_error);

    const root = std.json.parseFromSliceLeaky(JsonValue, arena.allocator(), frame, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = max_frame_bytes,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateField => return failed(arena, null, .invalid_request),
        else => return failed(arena, null, .parse_error),
    };

    const object = switch (root) {
        .object => |value| value,
        else => return failed(arena, null, .invalid_request),
    };
    const id = if (object.get("id")) |value| parseId(value) else null;
    if (!hasOnlyFields(object, &.{ "jsonrpc", "id", "method", "params", "token", "session" })) {
        return failed(arena, id, .invalid_request);
    }
    if (object.get("jsonrpc")) |version| {
        const text_value = asString(version) orelse return failed(arena, id, .invalid_request);
        if (!std.mem.eql(u8, text_value, "2.0")) return failed(arena, id, .invalid_request);
    }
    const request_id = id orelse return failed(arena, null, .invalid_request);
    const method_value = object.get("method") orelse return failed(arena, request_id, .invalid_request);
    const method_text = asString(method_value) orelse return failed(arena, request_id, .invalid_request);
    const method = Method.parse(method_text) orelse return failed(arena, request_id, .method_not_found);

    // Authentication precedes parameter validation, so an unauthenticated
    // client learns nothing about which parameters would have been accepted.
    const token_value = object.get("token") orelse return failed(arena, request_id, .unauthorized);
    const token_text = asString(token_value) orelse return failed(arena, request_id, .unauthorized);
    const token = Token.parse(token_text) catch return failed(arena, request_id, .unauthorized);

    const session: ?u32 = if (object.get("session")) |value|
        (positiveU32(value) orelse return failed(arena, request_id, .invalid_params))
    else
        null;

    const empty: std.json.ObjectMap = .empty;
    const params_object = if (object.get("params")) |value| switch (value) {
        .object => |params| params,
        else => return failed(arena, request_id, .invalid_params),
    } else empty;
    const params = (try parseParams(arena.allocator(), method, params_object)) orelse
        return failed(arena, request_id, .invalid_params);

    return .{ .arena = arena, .outcome = .{ .envelope = .{
        .id = request_id,
        .token = token,
        .session = session,
        .params = params,
    } } };
}

fn failed(arena: *std.heap.ArenaAllocator, id: ?RequestId, fault: FaultCode) Parsed {
    return .{ .arena = arena, .outcome = .{ .failure = .{ .id = id, .fault = fault } } };
}

fn parseId(value: JsonValue) ?RequestId {
    return switch (value) {
        .integer => |integer| .{ .integer = integer },
        .string => |string| if (string.len <= max_id_bytes) .{ .string = string } else null,
        else => null,
    };
}

fn parseParams(arena: Allocator, method: Method, object: std.json.ObjectMap) Allocator.Error!?Params {
    return switch (method) {
        .ping => if (object.count() == 0) .{ .ping = {} } else null,
        .view_backlog => if (object.count() == 0) .{ .view_backlog = {} } else null,
        .tab_open => blk: {
            if (!hasOnlyFields(object, &.{ "cwd", "command", "title" })) break :blk null;
            const spawn = (try parseSpawn(arena, object)) orelse break :blk null;
            const title = if (object.get("title")) |value|
                (boundedText(value, 1, max_title_bytes, false) orelse break :blk null)
            else
                null;
            break :blk .{ .tab_open = .{ .spawn = spawn, .title = title } };
        },
        .pane_split => blk: {
            if (!hasOnlyFields(object, &.{ "direction", "cwd", "command" })) break :blk null;
            const direction_value = object.get("direction") orelse break :blk null;
            const direction_text = asString(direction_value) orelse break :blk null;
            const direction = std.meta.stringToEnum(Direction, direction_text) orelse break :blk null;
            const spawn = (try parseSpawn(arena, object)) orelse break :blk null;
            break :blk .{ .pane_split = .{ .direction = direction, .spawn = spawn } };
        },
        .view_agent => blk: {
            if (!hasOnlyFields(object, &.{"agent_id"})) break :blk null;
            const agent_id = if (object.get("agent_id")) |value|
                (agentId(value) orelse break :blk null)
            else
                null;
            break :blk .{ .view_agent = .{ .agent_id = agent_id } };
        },
        .tab_status => blk: {
            if (!hasOnlyFields(object, &.{ "text", "attention" })) break :blk null;
            const status_text = if (object.get("text")) |value|
                (boundedText(value, 0, max_status_bytes, false) orelse break :blk null)
            else
                null;
            const attention = if (object.get("attention")) |value| switch (value) {
                .bool => |flag| flag,
                else => break :blk null,
            } else null;
            break :blk .{ .tab_status = .{ .text = status_text, .attention = attention } };
        },
        .notify => blk: {
            if (!hasOnlyFields(object, &.{ "title", "body" })) break :blk null;
            const title = boundedText(object.get("title") orelse break :blk null, 1, max_notify_title_bytes, false) orelse
                break :blk null;
            const body = if (object.get("body")) |value|
                (boundedText(value, 0, max_notify_body_bytes, true) orelse break :blk null)
            else
                "";
            break :blk .{ .notify = .{ .title = title, .body = body } };
        },
        .agent_event => blk: {
            if (!hasOnlyFields(object, &.{ "agent", "payload" })) break :blk null;
            const agent_text = asString(object.get("agent") orelse break :blk null) orelse break :blk null;
            var agent: AgentToken = undefined;
            if (!parseHex32(agent_text, &agent)) break :blk null;
            const payload = object.get("payload") orelse break :blk null;
            if (payload != .object) break :blk null;
            const payload_json = try std.json.Stringify.valueAlloc(arena, payload, .{});
            if (payload_json.len > max_frame_bytes) break :blk null;
            break :blk .{ .agent_event = .{ .agent = agent, .payload_json = payload_json } };
        },
        .instance_open_directory => blk: {
            if (!hasOnlyFields(object, &.{"path"})) break :blk null;
            const path = boundedText(object.get("path") orelse break :blk null, 1, max_path_bytes, false) orelse break :blk null;
            break :blk .{ .instance_open_directory = .{ .path = path } };
        },
        .instance_open_ssh => blk: {
            if (!hasOnlyFields(object, &.{"destination"})) break :blk null;
            const destination = boundedText(object.get("destination") orelse break :blk null, 1, max_destination_bytes, false) orelse
                break :blk null;
            break :blk .{ .instance_open_ssh = .{ .destination = destination } };
        },
        .instance_open_workspace => blk: {
            if (!hasOnlyFields(object, &.{ "name", "path" })) break :blk null;
            const name = boundedText(object.get("name") orelse break :blk null, 1, max_workspace_name_bytes, false) orelse
                break :blk null;
            const path = if (object.get("path")) |value|
                (boundedText(value, 1, max_path_bytes, false) orelse break :blk null)
            else
                null;
            break :blk .{ .instance_open_workspace = .{ .name = name, .path = path } };
        },
        .instance_agent => blk: {
            if (!hasOnlyFields(object, &.{ "harness", "prompt" })) break :blk null;
            const harness = agentId(object.get("harness") orelse break :blk null) orelse break :blk null;
            if (harness.len > max_harness_bytes) break :blk null;
            const prompt = if (object.get("prompt")) |value|
                (boundedText(value, 0, max_prompt_bytes, true) orelse break :blk null)
            else
                null;
            break :blk .{ .instance_agent = .{ .harness = harness, .prompt = prompt } };
        },
    };
}

fn parseSpawn(arena: Allocator, object: std.json.ObjectMap) Allocator.Error!?Spawn {
    const cwd = if (object.get("cwd")) |value|
        (boundedText(value, 1, max_path_bytes, false) orelse return null)
    else
        null;
    const command: ?[]const []const u8 = if (object.get("command")) |value| blk: {
        const items = switch (value) {
            .array => |array| array.items,
            else => return null,
        };
        if (items.len == 0 or items.len > max_argv_items) return null;
        const argv = try arena.alloc([]const u8, items.len);
        for (items, argv, 0..) |item, *arg, index| {
            const text_value = asString(item) orelse return null;
            if (text_value.len > max_arg_bytes) return null;
            if (index == 0 and text_value.len == 0) return null;
            // An argv item reaches exec as a C string; a NUL would cut it.
            if (std.mem.indexOfScalar(u8, text_value, 0) != null) return null;
            arg.* = text_value;
        }
        break :blk argv;
    } else null;
    return .{ .cwd = cwd, .command = command };
}

/// A UI string: bounded, and free of control characters that would draw or
/// act in the terminal-styled UI. Newlines and tabs only where `multiline`.
fn boundedText(value: JsonValue, min: usize, max: usize, multiline: bool) ?[]const u8 {
    const text_value = asString(value) orelse return null;
    if (text_value.len < min or text_value.len > max) return null;
    const view = std.unicode.Utf8View.init(text_value) catch return null;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (multiline and (codepoint == '\n' or codepoint == '\t')) continue;
        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint < 0xa0)) return null;
    }
    return text_value;
}

fn agentId(value: JsonValue) ?[]const u8 {
    const text_value = asString(value) orelse return null;
    if (text_value.len == 0 or text_value.len > max_agent_id_bytes) return null;
    for (text_value) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '.', '_', ':', '-' => {},
        else => return null,
    };
    return text_value;
}

fn positiveU32(value: JsonValue) ?u32 {
    const integer = switch (value) {
        .integer => |number| number,
        else => return null,
    };
    if (integer < 1 or integer > std.math.maxInt(u32)) return null;
    return @intCast(integer);
}

fn asString(value: JsonValue) ?[]const u8 {
    return switch (value) {
        .string => |text_value| text_value,
        else => null,
    };
}

fn hasOnlyFields(object: std.json.ObjectMap, names: []const []const u8) bool {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var known = false;
        for (names) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                known = true;
                break;
            }
        }
        if (!known) return false;
    }
    return true;
}

/// Scan only enough JSON syntax to bound nesting before building a tree.
fn depthWithinLimit(frame: []const u8) bool {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (frame) |byte| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        if (byte == '"') {
            in_string = true;
        } else if (byte == '{' or byte == '[') {
            depth += 1;
            if (depth > max_json_depth) return false;
        } else if ((byte == '}' or byte == ']') and depth != 0) {
            depth -= 1;
        }
    }
    return true;
}

/// What a successful request produced. Ids only, never request text.
pub const Result = union(enum) {
    /// `{}`: accepted (status, notification, agent event, view shown).
    ok,
    /// `{"pong":true}`.
    pong,
    /// `{"tab":…,"pane":…,"session":…}`, absent members omitted.
    opened: Opened,
};

/// Ids of what `tab.open`, `pane.split` or a view created.
pub const Opened = struct {
    /// A workspace an instance method opened or focused (its ordinal).
    workspace: ?u32 = null,
    tab: ?u32 = null,
    pane: ?u32 = null,
    session: ?u32 = null,
};

/// The owner's answer to one request.
pub const Reply = union(enum) {
    result: Result,
    fault: FaultCode,
};

/// A request id copied out of a parse arena so a reply can outlive it.
pub const IdCopy = struct {
    kind: enum { none, integer, string } = .none,
    integer: i64 = 0,
    bytes: [max_id_bytes]u8 = undefined,
    len: usize = 0,

    pub fn from(id: ?RequestId) IdCopy {
        var copy: IdCopy = .{};
        const value = id orelse return copy;
        switch (value) {
            .integer => |integer| {
                copy.kind = .integer;
                copy.integer = integer;
            },
            .string => |string| {
                // The parser bounds string ids to `max_id_bytes`.
                const len = @min(string.len, max_id_bytes);
                copy.kind = .string;
                @memcpy(copy.bytes[0..len], string[0..len]);
                copy.len = len;
            },
        }
        return copy;
    }

    pub fn get(self: *const IdCopy) ?RequestId {
        return switch (self.kind) {
            .none => null,
            .integer => .{ .integer = self.integer },
            .string => .{ .string = self.bytes[0..self.len] },
        };
    }
};

/// Encode a reply (without its newline) into `buffer`, which must hold
/// `max_reply_bytes`. Never allocates.
pub fn encodeReply(buffer: []u8, id: ?RequestId, reply: Reply) error{NoSpaceLeft}![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    writeReply(&writer, id, reply) catch return error.NoSpaceLeft;
    return writer.buffered();
}

fn writeReply(writer: *std.Io.Writer, id: ?RequestId, reply: Reply) std.Io.Writer.Error!void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |value| switch (value) {
        .integer => |integer| try writer.print("{d}", .{integer}),
        .string => |string| try std.json.Stringify.value(string, .{}, writer),
    } else try writer.writeAll("null");
    switch (reply) {
        .fault => |code| try writer.print(
            ",\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}",
            .{ @intFromEnum(code), code.message() },
        ),
        .result => |result| {
            try writer.writeAll(",\"result\":");
            switch (result) {
                .ok => try writer.writeAll("{}"),
                .pong => try writer.writeAll("{\"pong\":true}"),
                .opened => |opened| {
                    try writer.writeByte('{');
                    var first = true;
                    inline for (.{ "workspace", "tab", "pane", "session" }) |name| {
                        if (@field(opened, name)) |value| {
                            if (!first) try writer.writeByte(',');
                            first = false;
                            try writer.print("\"{s}\":{d}", .{ name, value });
                        }
                    }
                    try writer.writeByte('}');
                },
            }
            try writer.writeByte('}');
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_token = "0123456789abcdef0123456789abcdef";

fn expectEnvelope(frame: []const u8, method: Method) !Parsed {
    var parsed = try parseFrame(testing.allocator, frame);
    errdefer parsed.deinit();
    switch (parsed.outcome) {
        .envelope => |envelope| try testing.expectEqual(method, std.meta.activeTag(envelope.params)),
        .failure => |failure| {
            std.debug.print("unexpected fault {s} for {s}\n", .{ failure.fault.message(), frame });
            return error.TestUnexpectedResult;
        },
    }
    return parsed;
}

fn expectFault(frame: []const u8, fault: FaultCode) !void {
    var parsed = try parseFrame(testing.allocator, frame);
    defer parsed.deinit();
    switch (parsed.outcome) {
        .envelope => return error.TestUnexpectedResult,
        .failure => |failure| try testing.expectEqual(fault, failure.fault),
    }
}

test "tokens round-trip as 32 lowercase hex digits and refuse anything else" {
    const token = Token.fromBytes(.{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef } ++ .{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef });
    try testing.expectEqualStrings(test_token, token.text());
    try testing.expect(token.eql(try Token.parse(test_token)));
    try testing.expectError(error.InvalidToken, Token.parse("0123456789ABCDEF0123456789abcdef"));
    try testing.expectError(error.InvalidToken, Token.parse(test_token[1..]));
    try testing.expectError(error.InvalidToken, Token.parse(test_token ++ "0"));
    try testing.expect(!token.eql(try Token.parse("f123456789abcdef0123456789abcdef")));
}

test "method names are exact dotted wire names" {
    for (std.enums.values(Method)) |method| {
        try testing.expectEqual(method, Method.parse(method.wireName()).?);
    }
    try testing.expectEqual(@as(?Method, null), Method.parse("tab_open"));
    try testing.expectEqual(@as(?Method, null), Method.parse("TAB.OPEN"));
    try testing.expectEqual(@as(?Method, null), Method.parse("scratchpad.open"));
}

test "every method parses its valid parameters" {
    var ping = try expectEnvelope("{\"id\":1,\"method\":\"ping\",\"token\":\"" ++ test_token ++ "\"}", .ping);
    defer ping.deinit();
    try testing.expectEqual(@as(?u32, null), ping.outcome.envelope.session);

    var tab = try expectEnvelope("{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"method\":\"tab.open\",\"token\":\"" ++ test_token ++
        "\",\"session\":3,\"params\":{\"cwd\":\"~/src\",\"command\":[\"vi\",\"\",\"a b; rm -rf /\"],\"title\":\"edit\"}}", .tab_open);
    defer tab.deinit();
    const open = tab.outcome.envelope.params.tab_open;
    try testing.expectEqual(@as(?u32, 3), tab.outcome.envelope.session);
    try testing.expectEqualStrings("~/src", open.spawn.cwd.?);
    try testing.expectEqual(@as(usize, 3), open.spawn.command.?.len);
    try testing.expectEqualStrings("a b; rm -rf /", open.spawn.command.?[2]);
    try testing.expectEqualStrings("edit", open.title.?);
    try testing.expectEqualStrings("a", tab.outcome.envelope.id.string);

    var bare_tab = try expectEnvelope("{\"id\":2,\"method\":\"tab.open\",\"token\":\"" ++ test_token ++ "\",\"params\":{}}", .tab_open);
    defer bare_tab.deinit();
    try testing.expectEqual(@as(?[]const u8, null), bare_tab.outcome.envelope.params.tab_open.spawn.cwd);

    var split = try expectEnvelope("{\"id\":3,\"method\":\"pane.split\",\"token\":\"" ++ test_token ++
        "\",\"params\":{\"direction\":\"down\",\"command\":[\"htop\"]}}", .pane_split);
    defer split.deinit();
    try testing.expectEqual(Direction.down, split.outcome.envelope.params.pane_split.direction);

    var agent_view = try expectEnvelope("{\"id\":4,\"method\":\"view.agent\",\"token\":\"" ++ test_token ++
        "\",\"params\":{\"agent_id\":\"agent-7\"}}", .view_agent);
    defer agent_view.deinit();
    try testing.expectEqualStrings("agent-7", agent_view.outcome.envelope.params.view_agent.agent_id.?);

    var backlog = try expectEnvelope("{\"id\":5,\"method\":\"view.backlog\",\"token\":\"" ++ test_token ++ "\",\"params\":{}}", .view_backlog);
    defer backlog.deinit();

    var status = try expectEnvelope("{\"id\":6,\"method\":\"tab.status\",\"token\":\"" ++ test_token ++
        "\",\"params\":{\"text\":\"\",\"attention\":true}}", .tab_status);
    defer status.deinit();
    try testing.expectEqualStrings("", status.outcome.envelope.params.tab_status.text.?);
    try testing.expectEqual(@as(?bool, true), status.outcome.envelope.params.tab_status.attention);

    var notify = try expectEnvelope("{\"id\":7,\"method\":\"notify\",\"token\":\"" ++ test_token ++
        "\",\"params\":{\"title\":\"Done\",\"body\":\"line one\\nline two\"}}", .notify);
    defer notify.deinit();
    try testing.expectEqualStrings("line one\nline two", notify.outcome.envelope.params.notify.body);

    var event = try expectEnvelope("{\"id\":8,\"method\":\"agent.event\",\"token\":\"" ++ test_token ++
        "\",\"params\":{\"agent\":\"" ++ test_token ++ "\",\"payload\":{ \"v\" : 1, \"type\":\"agent_start\"}}}", .agent_event);
    defer event.deinit();
    try testing.expectEqualStrings("{\"v\":1,\"type\":\"agent_start\"}", event.outcome.envelope.params.agent_event.payload_json);
    try testing.expectEqualStrings(test_token, &event.outcome.envelope.params.agent_event.agent);

    var directory = try expectEnvelope("{\"id\":9,\"method\":\"instance.open_directory\",\"token\":\"" ++ test_token ++
        "\",\"params\":{\"path\":\"/home/me/src\"}}", .instance_open_directory);
    defer directory.deinit();
    try testing.expectEqualStrings("/home/me/src", directory.outcome.envelope.params.instance_open_directory.path);

    var ssh = try expectEnvelope("{\"id\":10,\"method\":\"instance.open_ssh\",\"token\":\"" ++ test_token ++
        "\",\"params\":{\"destination\":\"ops@build:2200\"}}", .instance_open_ssh);
    defer ssh.deinit();
    try testing.expectEqualStrings("ops@build:2200", ssh.outcome.envelope.params.instance_open_ssh.destination);

    var named = try expectEnvelope("{\"id\":11,\"method\":\"instance.open_workspace\",\"token\":\"" ++ test_token ++
        "\",\"params\":{\"name\":\"api (2)\",\"path\":\"/srv\"}}", .instance_open_workspace);
    defer named.deinit();
    try testing.expectEqualStrings("api (2)", named.outcome.envelope.params.instance_open_workspace.name);
    try testing.expectEqualStrings("/srv", named.outcome.envelope.params.instance_open_workspace.path.?);

    var launch = try expectEnvelope("{\"id\":12,\"method\":\"instance.agent\",\"token\":\"" ++ test_token ++
        "\",\"session\":2,\"params\":{\"harness\":\"claude\",\"prompt\":\"fix the build\\nplease\"}}", .instance_agent);
    defer launch.deinit();
    try testing.expectEqualStrings("claude", launch.outcome.envelope.params.instance_agent.harness);
    try testing.expectEqualStrings("fix the build\nplease", launch.outcome.envelope.params.instance_agent.prompt.?);
    try testing.expect(Method.instance_agent.isInstance() and !Method.tab_open.isInstance());
}

test "malformed envelopes map to stable faults" {
    try expectFault("", .invalid_request);
    try expectFault("not json", .parse_error);
    try expectFault("[1]", .invalid_request);
    try expectFault("{\"id\":1,\"id\":2,\"method\":\"ping\"}", .invalid_request);
    try expectFault("{\"method\":\"ping\",\"token\":\"" ++ test_token ++ "\"}", .invalid_request);
    try expectFault("{\"id\":1.5,\"method\":\"ping\",\"token\":\"" ++ test_token ++ "\"}", .invalid_request);
    try expectFault("{\"id\":1,\"jsonrpc\":\"1.0\",\"method\":\"ping\",\"token\":\"" ++ test_token ++ "\"}", .invalid_request);
    try expectFault("{\"id\":1,\"method\":\"ping\",\"token\":\"" ++ test_token ++ "\",\"extra\":1}", .invalid_request);
    try expectFault("{\"id\":1,\"token\":\"" ++ test_token ++ "\"}", .invalid_request);
    try expectFault("{\"id\":1,\"method\":7,\"token\":\"" ++ test_token ++ "\"}", .invalid_request);
    try expectFault("{\"id\":1,\"method\":\"scratchpad.show\",\"token\":\"" ++ test_token ++ "\"}", .method_not_found);
    try expectFault("{\"id\":1,\"method\":\"ping\"}", .unauthorized);
    try expectFault("{\"id\":1,\"method\":\"ping\",\"token\":42}", .unauthorized);
    try expectFault("{\"id\":1,\"method\":\"ping\",\"token\":\"nope\"}", .unauthorized);
    try expectFault("{\"id\":1,\"method\":\"ping\",\"token\":\"" ++ test_token ++ "\",\"session\":0}", .invalid_params);
    try expectFault("{\"id\":1,\"method\":\"ping\",\"token\":\"" ++ test_token ++ "\",\"session\":\"1\"}", .invalid_params);
    try expectFault("{\"id\":1,\"method\":\"ping\",\"token\":\"" ++ test_token ++ "\",\"params\":[]}", .invalid_params);
    try expectFault("{\"id\":1,\"method\":\"ping\",\"token\":\"" ++ test_token ++ "\",\"params\":{\"x\":1}}", .invalid_params);
    try expectFault("{\"id\":\"\xff\",\"method\":\"ping\"}", .parse_error);

    var deep: [max_json_depth + 2]u8 = undefined;
    @memset(&deep, '[');
    try expectFault(&deep, .invalid_request);

    const oversized = try testing.allocator.alloc(u8, max_frame_bytes + 1);
    defer testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try expectFault(oversized, .invalid_request);
}

test "parameters are refused for missing fields, wrong types and oversize values" {
    const prefix = "{\"id\":1,\"token\":\"" ++ test_token ++ "\",";
    const bad = [_][]const u8{
        "\"method\":\"view.backlog\",\"params\":{\"x\":1}}",
        "\"method\":\"tab.open\",\"params\":{\"cwd\":\"\"}}",
        "\"method\":\"tab.open\",\"params\":{\"cwd\":5}}",
        "\"method\":\"tab.open\",\"params\":{\"command\":\"vi file\"}}",
        "\"method\":\"tab.open\",\"params\":{\"command\":[]}}",
        "\"method\":\"tab.open\",\"params\":{\"command\":[\"\"]}}",
        "\"method\":\"tab.open\",\"params\":{\"command\":[\"vi\",3]}}",
        "\"method\":\"tab.open\",\"params\":{\"command\":[\"v\\u0000i\"]}}",
        "\"method\":\"tab.open\",\"params\":{\"title\":\"\"}}",
        "\"method\":\"tab.open\",\"params\":{\"title\":\"a\\u001b[2Jb\"}}",
        "\"method\":\"tab.open\",\"params\":{\"session\":1}}",
        "\"method\":\"pane.split\",\"params\":{}}",
        "\"method\":\"pane.split\",\"params\":{\"direction\":\"left\"}}",
        "\"method\":\"pane.split\",\"params\":{\"direction\":\"right\",\"title\":\"x\"}}",
        "\"method\":\"view.agent\",\"params\":{\"agent_id\":\"a/b\"}}",
        "\"method\":\"view.agent\",\"params\":{\"agent_id\":\"\"}}",
        "\"method\":\"tab.status\",\"params\":{\"attention\":\"yes\"}}",
        "\"method\":\"tab.status\",\"params\":{\"text\":\"multi\\nline\"}}",
        "\"method\":\"notify\",\"params\":{\"body\":\"no title\"}}",
        "\"method\":\"notify\",\"params\":{\"title\":\"\"}}",
        "\"method\":\"notify\",\"params\":{\"title\":\"x\",\"body\":\"bell\\u0007\"}}",
        "\"method\":\"agent.event\",\"params\":{\"payload\":{}}}",
        "\"method\":\"agent.event\",\"params\":{\"agent\":\"short\",\"payload\":{}}}",
        "\"method\":\"agent.event\",\"params\":{\"agent\":\"" ++ test_token ++ "\",\"payload\":[1]}}",
        "\"method\":\"agent.event\",\"params\":{\"agent\":\"" ++ test_token ++ "\"}}",
        "\"method\":\"instance.open_directory\",\"params\":{}}",
        "\"method\":\"instance.open_directory\",\"params\":{\"path\":\"\"}}",
        "\"method\":\"instance.open_directory\",\"params\":{\"path\":\"/a\\u001b\"}}",
        "\"method\":\"instance.open_ssh\",\"params\":{\"destination\":7}}",
        "\"method\":\"instance.open_ssh\",\"params\":{\"host\":\"x\"}}",
        "\"method\":\"instance.open_workspace\",\"params\":{\"path\":\"/x\"}}",
        "\"method\":\"instance.agent\",\"params\":{}}",
        "\"method\":\"instance.agent\",\"params\":{\"harness\":\"two words\"}}",
        "\"method\":\"instance.agent\",\"params\":{\"harness\":\"pi\",\"prompt\":\"bell\\u0007\"}}",
    };
    for (bad) |suffix| {
        const frame = try std.mem.concat(testing.allocator, u8, &.{ prefix, suffix });
        defer testing.allocator.free(frame);
        expectFault(frame, .invalid_params) catch |err| {
            std.debug.print("accepted or misreported: {s}\n", .{frame});
            return err;
        };
    }

    var long_status: [max_status_bytes + 1]u8 = undefined;
    @memset(&long_status, 's');
    const frame = try std.mem.concat(testing.allocator, u8, &.{ prefix, "\"method\":\"tab.status\",\"params\":{\"text\":\"", &long_status, "\"}}" });
    defer testing.allocator.free(frame);
    try expectFault(frame, .invalid_params);

    var many_args: std.ArrayList(u8) = .empty;
    defer many_args.deinit(testing.allocator);
    try many_args.appendSlice(testing.allocator, prefix ++ "\"method\":\"tab.open\",\"params\":{\"command\":[\"x\"");
    for (0..max_argv_items) |_| try many_args.appendSlice(testing.allocator, ",\"a\"");
    try many_args.appendSlice(testing.allocator, "]}}");
    try expectFault(many_args.items, .invalid_params);
}

test "replies encode ids, results and fixed fault names without request text" {
    var buffer: [max_reply_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"pong\":true}}",
        try encodeReply(&buffer, .{ .integer = 7 }, .{ .result = .pong }),
    );
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"q\\\"\",\"result\":{\"tab\":2,\"session\":9}}",
        try encodeReply(&buffer, .{ .string = "q\"" }, .{ .result = .{ .opened = .{ .tab = 2, .session = 9 } } }),
    );
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"workspace\":2,\"session\":4}}",
        try encodeReply(&buffer, .{ .integer = 3 }, .{ .result = .{ .opened = .{ .workspace = 2, .session = 4 } } }),
    );
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}",
        try encodeReply(&buffer, .{ .integer = 1 }, .{ .result = .ok }),
    );
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32002,\"message\":\"ScratchpadNotAddressable\"}}",
        try encodeReply(&buffer, null, .{ .fault = .scratchpad_not_addressable }),
    );

    var long_id: [max_id_bytes]u8 = undefined;
    @memset(&long_id, '\\');
    const copy = IdCopy.from(.{ .string = &long_id });
    const encoded = try encodeReply(&buffer, copy.get(), .{ .fault = .timed_out });
    try testing.expect(encoded.len <= max_reply_bytes);
}
