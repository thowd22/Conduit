//! Bounded, transport-neutral protocol core for Conduit's in-app test driver.
//!
//! A transport supplies one complete newline-delimited frame at a time. This
//! module neither searches for nor removes newlines: Unix sockets and Windows
//! named pipes own framing, permissions, connection lifetime and local-only
//! enforcement. The protocol core validates and owns a JSON-RPC request, gives
//! the main thread typed parameters, and produces deterministic owned response
//! bytes. Request payloads are never logged here.
//!
//! Memory is bounded by the public frame, response, nesting and queue limits.
//! `ParsedRequest` owns an arena containing all decoded request strings; callers
//! must keep it alive while using `Request` and call `deinit` exactly once.
//! `EncodedResponse` similarly owns its bytes. Queue insertion transfers
//! ownership only on success; callers retain a rejected value.

const std = @import("std");
const builtin = @import("builtin");
const input = @import("input");
const ui = @import("ui");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;

/// Largest JSON-RPC request frame accepted from a transport.
pub const max_request_bytes: usize = 1024 * 1024;

/// Largest encoded JSON-RPC response a transport may enqueue.
pub const max_response_bytes: usize = 4 * 1024 * 1024;

/// Maximum number of parsed requests waiting for the main thread.
pub const request_queue_depth: usize = 64;

/// Maximum number of encoded responses waiting for a transport.
pub const response_queue_depth: usize = 64;

/// Maximum JSON container nesting accepted before allocating a parse tree.
pub const max_json_depth: usize = 16;

/// Logical coordinates are bounded before a later platform conversion.
pub const max_logical_coordinate: f64 = 16_777_216;

/// One synthetic wheel event may not carry an unreasonably large delta.
pub const max_scroll_delta: f64 = 1_000_000;

/// A wait is bounded so a forgotten caller cannot retain a request forever.
pub const max_wait_timeout_ms: u32 = 5 * 60 * 1000;

/// The methods in the version-one automation contract.
pub const Method = enum {
    inspect,
    click,
    ctrl_click,
    double_click,
    right_click,
    drag,
    key,
    type,
    scroll,
    terminal_text,
    wait_for,
    get_logs,
    screenshot,
    quit,
    /// TASK-79: open a file in the active workspace's editor pane, as the
    /// `editor.open` control method does for a harness.
    editor_open,
    /// TASK-79: move the open editor pane to a file position (`editor.goto`).
    editor_goto,

    /// Every method in deterministic protocol order.
    pub const all = [_]Method{
        .inspect,
        .click,
        .ctrl_click,
        .double_click,
        .right_click,
        .drag,
        .key,
        .type,
        .scroll,
        .terminal_text,
        .wait_for,
        .get_logs,
        .screenshot,
        .quit,
        .editor_open,
        .editor_goto,
    };

    /// Parse an exact method name; method names are never normalized.
    pub fn parse(text: []const u8) ?Method {
        inline for (@typeInfo(Method).@"enum".fields) |field| {
            const method: Method = @enumFromInt(field.value);
            if (std.mem.eql(u8, text, @tagName(method))) return method;
        }
        return null;
    }

    /// Whether this protocol version can execute the method.
    pub fn available(_: Method) bool {
        return true;
    }
};

/// A JSON-RPC request id. String bytes are owned by `ParsedRequest`.
pub const RequestId = union(enum) {
    integer: i64,
    string: []const u8,
};

/// A pointer target is either one semantic id or one logical-pixel point.
pub const Target = union(enum) {
    id: ui.Id,
    point: LogicalPoint,
};

/// Window-relative logical pixels, before display-scale conversion.
pub const LogicalPoint = struct {
    x: f64,
    y: f64,
};

/// Parsed key chord ready for the platform-input adapter.
pub const KeyChord = struct {
    modifiers: input.Modifiers,
    key: input.Key,
};

/// Read-only terminal text targets exposed to automation.
///
/// Input methods deliberately have no target: synthetic key, text, pointer,
/// and scroll events still follow the real active input path. The scratchpad
/// name only permits observation for deterministic persistence checks.
pub const TerminalTarget = enum {
    active,
    scratchpad,
};

/// State fields exposed by one semantic element.
pub const ElementState = enum {
    exists,
    hovered,
    focused,
    pressed,
};

/// Longest path an editor method accepts, matching the control API's bound.
pub const max_editor_path_bytes: usize = 4096;

/// Largest one-based line or column an editor method accepts.
pub const max_editor_position: u32 = 10_000_000;

/// Where a new editor pane goes beside the focused pane.
pub const EditorSplit = enum { right, down };

/// A file position for the editor methods. The app resolves `path` against
/// the focused session's cwd through the workspace's ExecutionContext.
pub const EditorLocation = struct {
    path: []const u8,
    line: ?u32 = null,
    column: ?u32 = null,
};

/// A condition retained by the main loop until it matches or times out.
pub const WaitCondition = union(enum) {
    element: struct {
        id: ui.Id,
        state: ElementState,
        equals: bool,
    },
    terminal_text: struct {
        target: TerminalTarget,
        contains: []const u8,
    },
};

/// Typed parameters for all methods. Every string borrows `ParsedRequest`.
pub const Params = union(Method) {
    inspect: void,
    click: Target,
    ctrl_click: Target,
    double_click: Target,
    right_click: Target,
    drag: struct {
        from: Target,
        to: Target,
    },
    key: struct {
        chord: KeyChord,
    },
    type: struct {
        text: []const u8,
    },
    scroll: struct {
        dy: f64,
        dx: f64 = 0,
        point: ?LogicalPoint = null,
    },
    terminal_text: struct {
        target: TerminalTarget,
    },
    wait_for: struct {
        condition: WaitCondition,
        timeout_ms: u32,
    },
    get_logs: struct {
        max_bytes: ?usize = null,
    },
    screenshot: void,
    quit: void,
    editor_open: struct {
        location: EditorLocation,
        split: ?EditorSplit = null,
    },
    editor_goto: struct {
        location: EditorLocation,
    },
};

/// One validated request. All borrowed memory belongs to `ParsedRequest`.
pub const Request = struct {
    id: RequestId,
    method: Method,
    params: Params,
};

/// JSON-RPC standard failures and the application failures execution returns.
pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    app_unavailable = -32000,
    not_found = -32004,
    timeout = -32008,
};

/// Error information encoded in a JSON-RPC error object.
pub const Fault = struct {
    code: ErrorCode,
    message: []const u8,

    pub const parse_error: Fault = .{ .code = .parse_error, .message = "Parse error" };
    pub const invalid_request: Fault = .{ .code = .invalid_request, .message = "Invalid Request" };
    pub const method_not_found: Fault = .{ .code = .method_not_found, .message = "Method not found" };
    pub const invalid_params: Fault = .{ .code = .invalid_params, .message = "Invalid params" };
    pub const internal_error: Fault = .{ .code = .internal_error, .message = "Internal error" };

    /// An app feature or state required by a valid method is unavailable.
    pub fn unavailable(message: []const u8) Fault {
        return .{ .code = .app_unavailable, .message = message };
    }

    /// A requested semantic element or named target does not exist.
    pub fn notFound(message: []const u8) Fault {
        return .{ .code = .not_found, .message = message };
    }

    /// A valid wait condition did not match before its deadline.
    pub fn timedOut(message: []const u8) Fault {
        return .{ .code = .timeout, .message = message };
    }
};

/// A parse failure and the id to echo when one was recoverable.
pub const Failure = struct {
    id: ?RequestId,
    fault: Fault,
};

/// Result of decoding one frame. Protocol failures are data, not Zig errors.
pub const Outcome = union(enum) {
    request: Request,
    failure: Failure,
};

/// An owned parse arena plus either a typed request or a protocol failure.
pub const ParsedRequest = struct {
    arena: *std.heap.ArenaAllocator,
    outcome: Outcome,

    /// Release all decoded strings and JSON parsing storage.
    pub fn deinit(self: *ParsedRequest) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.* = undefined;
    }
};

/// Parse one complete frame. Newline framing belongs to the transport.
pub fn parseRequest(allocator: Allocator, frame: []const u8) Allocator.Error!ParsedRequest {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    if (frame.len == 0 or frame.len > max_request_bytes) {
        return .{ .arena = arena, .outcome = .{ .failure = .{ .id = null, .fault = Fault.invalid_request } } };
    }
    if (!std.unicode.utf8ValidateSlice(frame)) {
        return .{ .arena = arena, .outcome = .{ .failure = .{ .id = null, .fault = Fault.parse_error } } };
    }
    if (!depthWithinLimit(frame)) {
        return .{ .arena = arena, .outcome = .{ .failure = .{ .id = null, .fault = Fault.invalid_request } } };
    }

    const root = std.json.parseFromSliceLeaky(JsonValue, arena.allocator(), frame, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = max_request_bytes,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateField => return .{
            .arena = arena,
            .outcome = .{ .failure = .{ .id = null, .fault = Fault.invalid_request } },
        },
        else => return .{
            .arena = arena,
            .outcome = .{ .failure = .{ .id = null, .fault = Fault.parse_error } },
        },
    };

    const object = switch (root) {
        .object => |value| value,
        else => return failed(arena, null, Fault.invalid_request),
    };
    const id = if (object.get("id")) |value| parseId(value) else null;
    if (!hasExactFields(object, &.{ "jsonrpc", "id", "method", "params" })) {
        return failed(arena, id, Fault.invalid_request);
    }
    const version = asString(object.get("jsonrpc").?) orelse
        return failed(arena, id, Fault.invalid_request);
    if (!std.mem.eql(u8, version, "2.0")) return failed(arena, id, Fault.invalid_request);
    const request_id = id orelse return failed(arena, null, Fault.invalid_request);
    const method_text = asString(object.get("method").?) orelse
        return failed(arena, request_id, Fault.invalid_request);
    const method = Method.parse(method_text) orelse
        return failed(arena, request_id, Fault.method_not_found);
    const params_value = object.get("params").?;
    if (params_value != .object) return failed(arena, request_id, Fault.invalid_params);
    const params = parseParams(method, params_value) orelse
        return failed(arena, request_id, Fault.invalid_params);

    return .{
        .arena = arena,
        .outcome = .{ .request = .{
            .id = request_id,
            .method = method,
            .params = params,
        } },
    };
}

fn failed(arena: *std.heap.ArenaAllocator, id: ?RequestId, fault: Fault) ParsedRequest {
    return .{ .arena = arena, .outcome = .{ .failure = .{ .id = id, .fault = fault } } };
}

fn parseId(value: JsonValue) ?RequestId {
    return switch (value) {
        .integer => |integer| .{ .integer = integer },
        .string => |string| .{ .string = string },
        else => null,
    };
}

fn parseParams(method: Method, value: JsonValue) ?Params {
    const object = switch (value) {
        .object => |params| params,
        else => return null,
    };
    return switch (method) {
        .inspect => if (object.count() == 0) .{ .inspect = {} } else null,
        .click => if (parseTarget(value)) |target| .{ .click = target } else null,
        .ctrl_click => if (parseTarget(value)) |target| .{ .ctrl_click = target } else null,
        .double_click => if (parseTarget(value)) |target| .{ .double_click = target } else null,
        .right_click => if (parseTarget(value)) |target| .{ .right_click = target } else null,
        .drag => parseDrag(object),
        .key => parseKeyParams(object),
        .type => parseTypeParams(object),
        .scroll => parseScroll(object),
        .terminal_text => parseTerminalText(object),
        .wait_for => parseWait(object),
        .get_logs => parseGetLogs(object),
        .screenshot => if (object.count() == 0) .{ .screenshot = {} } else null,
        .quit => if (object.count() == 0) .{ .quit = {} } else null,
        .editor_open => parseEditorOpen(object),
        .editor_goto => blk: {
            if (!hasOnlyFields(object, &.{ "path", "line", "column" })) break :blk null;
            break :blk .{ .editor_goto = .{ .location = parseEditorLocation(object) orelse break :blk null } };
        },
    };
}

fn parseEditorOpen(object: std.json.ObjectMap) ?Params {
    if (!hasOnlyFields(object, &.{ "path", "line", "column", "split" })) return null;
    const location = parseEditorLocation(object) orelse return null;
    const split: ?EditorSplit = if (object.get("split")) |value|
        (std.meta.stringToEnum(EditorSplit, asString(value) orelse return null) orelse return null)
    else
        null;
    return .{ .editor_open = .{ .location = location, .split = split } };
}

fn parseEditorLocation(object: std.json.ObjectMap) ?EditorLocation {
    const path = asString(object.get("path") orelse return null) orelse return null;
    if (path.len == 0 or path.len > max_editor_path_bytes) return null;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f) return null;
    const line = if (object.get("line")) |value| (editorPosition(value) orelse return null) else null;
    const column = if (object.get("column")) |value| (editorPosition(value) orelse return null) else null;
    if (column != null and line == null) return null;
    return .{ .path = path, .line = line, .column = column };
}

fn editorPosition(value: JsonValue) ?u32 {
    const position = unsignedInteger(value, max_editor_position) orelse return null;
    return if (position == 0) null else position;
}

fn parseTarget(value: JsonValue) ?Target {
    const object = switch (value) {
        .object => |target| target,
        else => return null,
    };
    if (hasExactFields(object, &.{"id"})) {
        const text = asString(object.get("id").?) orelse return null;
        return .{ .id = ui.Id.parse(text) catch return null };
    }
    if (hasExactFields(object, &.{ "x", "y" })) {
        return .{ .point = parsePoint(object) orelse return null };
    }
    return null;
}

fn parsePoint(object: std.json.ObjectMap) ?LogicalPoint {
    const x = boundedNumber(object.get("x").?, max_logical_coordinate) orelse return null;
    const y = boundedNumber(object.get("y").?, max_logical_coordinate) orelse return null;
    return .{ .x = x, .y = y };
}

fn parseDrag(object: std.json.ObjectMap) ?Params {
    if (!hasExactFields(object, &.{ "from", "to" })) return null;
    const from = parseTarget(object.get("from").?) orelse return null;
    const to = parseTarget(object.get("to").?) orelse return null;
    return .{ .drag = .{ .from = from, .to = to } };
}

fn parseKeyParams(object: std.json.ObjectMap) ?Params {
    if (!hasExactFields(object, &.{"chord"})) return null;
    const text = asString(object.get("chord").?) orelse return null;
    return .{ .key = .{ .chord = parseChord(text) orelse return null } };
}

fn parseTypeParams(object: std.json.ObjectMap) ?Params {
    if (!hasExactFields(object, &.{"text"})) return null;
    const text = asString(object.get("text").?) orelse return null;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return null;
    return .{ .type = .{ .text = text } };
}

fn parseScroll(object: std.json.ObjectMap) ?Params {
    if (!hasOnlyFields(object, &.{ "dy", "dx", "x", "y" }) or object.get("dy") == null) return null;
    const has_x = object.get("x") != null;
    const has_y = object.get("y") != null;
    if (has_x != has_y) return null;
    const dy = boundedNumber(object.get("dy").?, max_scroll_delta) orelse return null;
    const dx = if (object.get("dx")) |number|
        (boundedNumber(number, max_scroll_delta) orelse return null)
    else
        0;
    const point = if (has_x) (parsePoint(object) orelse return null) else null;
    return .{ .scroll = .{ .dy = dy, .dx = dx, .point = point } };
}

fn parseTerminalText(object: std.json.ObjectMap) ?Params {
    if (!hasOnlyFields(object, &.{"target"})) return null;
    return .{ .terminal_text = .{
        .target = if (object.get("target")) |target|
            parseTerminalTarget(target) orelse return null
        else
            .active,
    } };
}

fn parseWait(object: std.json.ObjectMap) ?Params {
    if (!hasExactFields(object, &.{ "condition", "timeout_ms" })) return null;
    const timeout = unsignedInteger(object.get("timeout_ms").?, max_wait_timeout_ms) orelse return null;
    const condition_value = object.get("condition").?;
    const condition_object = switch (condition_value) {
        .object => |condition| condition,
        else => return null,
    };
    if (hasExactFields(condition_object, &.{"element"})) {
        const element_value = condition_object.get("element").?;
        const element = switch (element_value) {
            .object => |fields| fields,
            else => return null,
        };
        if (!hasExactFields(element, &.{ "id", "state", "equals" })) return null;
        const id_text = asString(element.get("id").?) orelse return null;
        const state_text = asString(element.get("state").?) orelse return null;
        const state = std.meta.stringToEnum(ElementState, state_text) orelse return null;
        const equals = asBool(element.get("equals").?) orelse return null;
        return .{ .wait_for = .{
            .condition = .{ .element = .{
                .id = ui.Id.parse(id_text) catch return null,
                .state = state,
                .equals = equals,
            } },
            .timeout_ms = timeout,
        } };
    }
    if (hasExactFields(condition_object, &.{"terminal_text"})) {
        const terminal_value = condition_object.get("terminal_text").?;
        const terminal = switch (terminal_value) {
            .object => |fields| fields,
            else => return null,
        };
        if (!hasOnlyFields(terminal, &.{ "target", "contains" }) or terminal.get("contains") == null) return null;
        return .{ .wait_for = .{
            .condition = .{ .terminal_text = .{
                .target = if (terminal.get("target")) |target|
                    parseTerminalTarget(target) orelse return null
                else
                    .active,
                .contains = asString(terminal.get("contains").?) orelse return null,
            } },
            .timeout_ms = timeout,
        } };
    }
    return null;
}

fn parseGetLogs(object: std.json.ObjectMap) ?Params {
    if (!hasOnlyFields(object, &.{"max_bytes"})) return null;
    const max_bytes = if (object.get("max_bytes")) |number|
        unsignedInteger(number, max_response_bytes) orelse return null
    else
        null;
    return .{ .get_logs = .{ .max_bytes = max_bytes } };
}

fn parseTerminalTarget(value: JsonValue) ?TerminalTarget {
    const text = asString(value) orelse return null;
    return std.meta.stringToEnum(TerminalTarget, text);
}

fn asString(value: JsonValue) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn asBool(value: JsonValue) ?bool {
    return switch (value) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn boundedNumber(value: JsonValue, maximum_magnitude: f64) ?f64 {
    const number: f64 = switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => return null,
    };
    if (!std.math.isFinite(number) or @abs(number) > maximum_magnitude) return null;
    return number;
}

fn unsignedInteger(value: JsonValue, maximum: anytype) ?@TypeOf(maximum) {
    const integer = switch (value) {
        .integer => |number| number,
        else => return null,
    };
    if (integer < 0 or integer > @as(i64, @intCast(maximum))) return null;
    return @intCast(integer);
}

fn hasExactFields(object: std.json.ObjectMap, names: []const []const u8) bool {
    return object.count() == names.len and hasOnlyFields(object, names);
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

/// Parse `CTRL+ALT+SHIFT+SUPER+key` without normalizing tokens or modifiers.
pub fn parseChord(text: []const u8) ?KeyChord {
    if (text.len == 0 or text.len > 128) return null;
    if (std.mem.eql(u8, text, "+")) {
        return .{ .modifiers = .{}, .key = .{ .character = '+' } };
    }
    if (std.mem.endsWith(u8, text, "++")) {
        const modifier_text = text[0 .. text.len - 2];
        if (modifier_text.len == 0) return null;
        var modifiers: input.Modifiers = .{};
        var modifier_parts = std.mem.splitScalar(u8, modifier_text, '+');
        while (modifier_parts.next()) |part| {
            if (std.mem.eql(u8, part, "CTRL")) {
                if (modifiers.ctrl) return null;
                modifiers.ctrl = true;
            } else if (std.mem.eql(u8, part, "ALT")) {
                if (modifiers.alt) return null;
                modifiers.alt = true;
            } else if (std.mem.eql(u8, part, "SHIFT")) {
                if (modifiers.shift) return null;
                modifiers.shift = true;
            } else if (std.mem.eql(u8, part, "SUPER")) {
                if (modifiers.super) return null;
                modifiers.super = true;
            } else {
                return null;
            }
        }
        return .{ .modifiers = modifiers, .key = .{ .character = '+' } };
    }
    var modifiers: input.Modifiers = .{};
    var key: ?input.Key = null;
    var parts = std.mem.splitScalar(u8, text, '+');
    while (parts.next()) |part| {
        if (part.len == 0 or key != null) return null;
        if (std.mem.eql(u8, part, "CTRL")) {
            if (modifiers.ctrl) return null;
            modifiers.ctrl = true;
        } else if (std.mem.eql(u8, part, "ALT")) {
            if (modifiers.alt) return null;
            modifiers.alt = true;
        } else if (std.mem.eql(u8, part, "SHIFT")) {
            if (modifiers.shift) return null;
            modifiers.shift = true;
        } else if (std.mem.eql(u8, part, "SUPER")) {
            if (modifiers.super) return null;
            modifiers.super = true;
        } else if (parseNamedKey(part)) |named| {
            key = .{ .named = named };
        } else {
            const view = std.unicode.Utf8View.init(part) catch return null;
            var codepoints = view.iterator();
            const codepoint = codepoints.nextCodepoint() orelse return null;
            if (codepoints.nextCodepoint() != null or isControl(codepoint)) return null;
            key = .{ .character = codepoint };
        }
    }
    return .{ .modifiers = modifiers, .key = key orelse return null };
}

fn parseNamedKey(text: []const u8) ?input.Named {
    const names = [_]struct { wire: []const u8, key: input.Named }{
        .{ .wire = "ENTER", .key = .enter },
        .{ .wire = "TAB", .key = .tab },
        .{ .wire = "BACKSPACE", .key = .backspace },
        .{ .wire = "ESCAPE", .key = .escape },
        .{ .wire = "INSERT", .key = .insert },
        .{ .wire = "DELETE", .key = .delete },
        .{ .wire = "UP", .key = .up },
        .{ .wire = "DOWN", .key = .down },
        .{ .wire = "LEFT", .key = .left },
        .{ .wire = "RIGHT", .key = .right },
        .{ .wire = "HOME", .key = .home },
        .{ .wire = "END", .key = .end },
        .{ .wire = "PAGE_UP", .key = .page_up },
        .{ .wire = "PAGE_DOWN", .key = .page_down },
        .{ .wire = "F1", .key = .f1 },
        .{ .wire = "F2", .key = .f2 },
        .{ .wire = "F3", .key = .f3 },
        .{ .wire = "F4", .key = .f4 },
        .{ .wire = "F5", .key = .f5 },
        .{ .wire = "F6", .key = .f6 },
        .{ .wire = "F7", .key = .f7 },
        .{ .wire = "F8", .key = .f8 },
        .{ .wire = "F9", .key = .f9 },
        .{ .wire = "F10", .key = .f10 },
        .{ .wire = "F11", .key = .f11 },
        .{ .wire = "F12", .key = .f12 },
    };
    for (names) |name| if (std.mem.eql(u8, text, name.wire)) return name.key;
    return null;
}

fn isControl(codepoint: u21) bool {
    return codepoint < 0x20 or (codepoint >= 0x7f and codepoint < 0xa0);
}

/// Scan only enough JSON syntax to bound parser nesting before allocation.
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

/// Results the main thread can encode without constructing dynamic JSON.
pub const Result = union(enum) {
    /// Successful input injection, wait completion or shutdown request.
    ok,
    /// A complete semantic-tree JSON object produced by `ui.Tree.writeJson`.
    inspect: struct { semantic_json: []const u8 },
    /// Visible text from the requested terminal.
    terminal_text: struct { text: []const u8 },
    /// A bounded log tail; request payloads must never be included.
    logs: struct { text: []const u8 },
    /// The PNG artifact path returned after a completed screenshot capture.
    screenshot: struct { path: []const u8 },
};

/// An encoded response owned by `allocator`.
pub const EncodedResponse = struct {
    allocator: Allocator,
    bytes: []u8,

    pub fn deinit(self: *EncodedResponse) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Encoding fails only for allocation or the fixed four-MiB response limit.
pub const EncodeError = Allocator.Error || error{ResponseTooLarge};

/// Encode a deterministic JSON-RPC success object, without transport framing.
pub fn encodeSuccess(allocator: Allocator, id: RequestId, result: Result) EncodeError!EncodedResponse {
    return encodeResponse(allocator, id, result, null);
}

/// Encode a deterministic JSON-RPC error object, without transport framing.
pub fn encodeFailure(allocator: Allocator, id: ?RequestId, fault: Fault) EncodeError!EncodedResponse {
    return encodeResponse(allocator, id, null, fault);
}

fn encodeResponse(
    allocator: Allocator,
    id: ?RequestId,
    result: ?Result,
    fault: ?Fault,
) EncodeError!EncodedResponse {
    var bytes = try allocator.alloc(u8, max_response_bytes);
    errdefer allocator.free(bytes);
    var writer = std.Io.Writer.fixed(bytes);

    writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return error.ResponseTooLarge;
    if (id) |request_id| {
        writeId(&writer, request_id) catch return error.ResponseTooLarge;
    } else {
        writer.writeAll("null") catch return error.ResponseTooLarge;
    }
    if (fault) |rpc_error| {
        writer.writeAll(",\"error\":{\"code\":") catch return error.ResponseTooLarge;
        writer.print("{d}", .{@intFromEnum(rpc_error.code)}) catch return error.ResponseTooLarge;
        writer.writeAll(",\"message\":") catch return error.ResponseTooLarge;
        std.json.Stringify.value(rpc_error.message, .{}, &writer) catch return error.ResponseTooLarge;
        writer.writeAll("}}") catch return error.ResponseTooLarge;
    } else {
        writer.writeAll(",\"result\":") catch return error.ResponseTooLarge;
        writeResult(&writer, result.?) catch return error.ResponseTooLarge;
        writer.writeByte('}') catch return error.ResponseTooLarge;
    }

    const written = writer.buffered().len;
    bytes = try allocator.realloc(bytes, written);
    return .{ .allocator = allocator, .bytes = bytes };
}

fn writeId(writer: *std.Io.Writer, id: RequestId) std.Io.Writer.Error!void {
    switch (id) {
        .integer => |integer| try writer.print("{d}", .{integer}),
        .string => |string| try std.json.Stringify.value(string, .{}, writer),
    }
}

fn writeResult(writer: *std.Io.Writer, result: Result) std.Io.Writer.Error!void {
    switch (result) {
        .ok => try writer.writeAll("{}"),
        .inspect => |inspect| try writer.writeAll(inspect.semantic_json),
        .terminal_text => |terminal| try std.json.Stringify.value(.{ .text = terminal.text }, .{}, writer),
        .logs => |logs| try std.json.Stringify.value(.{ .text = logs.text }, .{}, writer),
        .screenshot => |screenshot| try std.json.Stringify.value(.{ .path = screenshot.path }, .{}, writer),
    }
}

/// A fixed-capacity FIFO. Ownership transfers to the queue only on push success.
pub fn BoundedQueue(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0) @compileError("a bounded queue needs non-zero capacity");
    return struct {
        const Self = @This();

        storage: [capacity]T = undefined,
        head: usize = 0,
        len: usize = 0,

        pub const Error = error{QueueFull};

        pub fn push(self: *Self, value: T) Error!void {
            if (self.len == capacity) return error.QueueFull;
            self.storage[(self.head + self.len) % capacity] = value;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            const value = self.storage[self.head];
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
            return value;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}

/// FIFO used between the local transport and main-thread executor.
pub const RequestQueue = BoundedQueue(ParsedRequest, request_queue_depth);

/// FIFO used between the main-thread executor and local transport.
pub const ResponseQueue = BoundedQueue(EncodedResponse, response_queue_depth);

/// The endpoint is disabled in every build mode without explicit enablement.
pub fn enabledIn(_: std.builtin.OptimizeMode, explicitly_enabled: bool) bool {
    return explicitly_enabled;
}

/// Whether this build should run the server for the explicit user setting.
pub fn isEnabled(explicitly_enabled: bool) bool {
    return enabledIn(builtin.mode, explicitly_enabled);
}

fn expectRequest(frame: []const u8, method: Method) !ParsedRequest {
    var parsed = try parseRequest(std.testing.allocator, frame);
    errdefer parsed.deinit();
    switch (parsed.outcome) {
        .request => |request| try std.testing.expectEqual(method, request.method),
        .failure => return error.TestUnexpectedResult,
    }
    return parsed;
}

fn expectFault(frame: []const u8, code: ErrorCode) !ParsedRequest {
    var parsed = try parseRequest(std.testing.allocator, frame);
    errdefer parsed.deinit();
    switch (parsed.outcome) {
        .failure => |failure| try std.testing.expectEqual(code, failure.fault.code),
        .request => return error.TestUnexpectedResult,
    }
    return parsed;
}

test "every documented method parses to typed parameters" {
    const cases = [_]struct { method: Method, json: []const u8 }{
        .{ .method = .inspect, .json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"inspect\",\"params\":{}}" },
        .{ .method = .click, .json = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"click\",\"params\":{\"id\":\"workspace.infrastructure\"}}" },
        .{ .method = .ctrl_click, .json = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ctrl_click\",\"params\":{\"x\":12.5,\"y\":-2}}" },
        .{ .method = .double_click, .json = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"double_click\",\"params\":{\"id\":\"link:https://ziglang.org\"}}" },
        .{ .method = .right_click, .json = "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"right_click\",\"params\":{\"id\":\"workspace.1.pane.1\"}}" },
        .{ .method = .drag, .json = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"drag\",\"params\":{\"from\":{\"id\":\"pane.one\"},\"to\":{\"x\":40,\"y\":50}}}" },
        .{ .method = .key, .json = "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"key\",\"params\":{\"chord\":\"CTRL+SHIFT+P\"}}" },
        .{ .method = .type, .json = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"type\",\"params\":{\"text\":\"hello 界\"}}" },
        .{ .method = .scroll, .json = "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"scroll\",\"params\":{\"dy\":-3.5,\"dx\":1,\"x\":20,\"y\":30}}" },
        .{ .method = .terminal_text, .json = "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"terminal_text\",\"params\":{\"target\":\"active\"}}" },
        .{ .method = .wait_for, .json = "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"wait_for\",\"params\":{\"condition\":{\"element\":{\"id\":\"palette.input\",\"state\":\"focused\",\"equals\":true}},\"timeout_ms\":1000}}" },
        .{ .method = .get_logs, .json = "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"get_logs\",\"params\":{\"max_bytes\":4096}}" },
        .{ .method = .screenshot, .json = "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"screenshot\",\"params\":{}}" },
        .{ .method = .quit, .json = "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"quit\",\"params\":{}}" },
        .{ .method = .editor_open, .json = "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"editor_open\",\"params\":{\"path\":\"src/a.zig\",\"line\":3,\"column\":7,\"split\":\"down\"}}" },
        .{ .method = .editor_goto, .json = "{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"editor_goto\",\"params\":{\"path\":\"/abs/b.zig\"}}" },
    };
    try std.testing.expectEqual(cases.len, Method.all.len);
    for (cases, Method.all) |case, method| {
        try std.testing.expectEqual(method, case.method);
        var parsed = try expectRequest(case.json, case.method);
        parsed.deinit();
    }
}

test "targets use canonical ui ids or finite bounded logical points exclusively" {
    var id_request = try expectRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":\"id\",\"method\":\"click\",\"params\":{\"id\":\"link:https://ziglang.org/path.part\"}}",
        .click,
    );
    defer id_request.deinit();
    switch (id_request.outcome.request.params.click) {
        .id => |id| try std.testing.expectEqualStrings("link:https://ziglang.org/path.part", id.value),
        else => return error.TestUnexpectedResult,
    }

    const invalid = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"click\",\"params\":{\"id\":\"bad id\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"click\",\"params\":{\"id\":\"a\",\"x\":1,\"y\":2}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"click\",\"params\":{\"x\":1}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"click\",\"params\":{\"x\":1e999,\"y\":2}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"click\",\"params\":{\"x\":16777217,\"y\":2}}",
    };
    for (invalid) |frame| {
        var parsed = try expectFault(frame, .invalid_params);
        parsed.deinit();
    }
}

test "terminal text accepts active and scratchpad read targets only" {
    for ([_]TerminalTarget{ .active, .scratchpad }) |expected| {
        const target = @tagName(expected);
        const frame = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"terminal_text\",\"params\":{{\"target\":\"{s}\"}}}}",
            .{target},
        );
        defer std.testing.allocator.free(frame);
        var parsed = try expectRequest(frame, .terminal_text);
        defer parsed.deinit();
        try std.testing.expectEqual(expected, parsed.outcome.request.params.terminal_text.target);
    }

    var unknown = try expectFault(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"terminal_text\",\"params\":{\"target\":\"unknown\"}}",
        .invalid_params,
    );
    defer unknown.deinit();

    var legacy = try expectRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"terminal_text\",\"params\":{}}",
        .terminal_text,
    );
    defer legacy.deinit();
    try std.testing.expectEqual(
        TerminalTarget.active,
        legacy.outcome.request.params.terminal_text.target,
    );
}

test "key chords accept exact modifiers named keys and one Unicode scalar" {
    const chord = parseChord("CTRL+ALT+SHIFT+SUPER+F12") orelse return error.TestUnexpectedResult;
    try std.testing.expect(chord.modifiers.ctrl);
    try std.testing.expect(chord.modifiers.alt);
    try std.testing.expect(chord.modifiers.shift);
    try std.testing.expect(chord.modifiers.super);
    try std.testing.expectEqual(input.Key{ .named = .f12 }, chord.key);

    const unicode = parseChord("CTRL+界") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(input.Key{ .character = 0x754c }, unicode.key);

    const plus = parseChord("CTRL++") orelse return error.TestUnexpectedResult;
    try std.testing.expect(plus.modifiers.ctrl);
    try std.testing.expectEqual(input.Key{ .character = '+' }, plus.key);

    for ([_][]const u8{
        "",
        "CTRL",
        "CTRL+",
        "+P",
        "CTRL+CTRL+P",
        "P+CTRL",
        "ctrl+P",
        "CTRL+ab",
        "CTRL+\x01",
        "UNKNOWN_KEY",
    }) |invalid| try std.testing.expect(parseChord(invalid) == null);
}

test "wait conditions are typed bounded and exact" {
    var terminal = try expectRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"wait_for\",\"params\":{\"condition\":{\"terminal_text\":{\"target\":\"active\",\"contains\":\"READY\"}},\"timeout_ms\":0}}",
        .wait_for,
    );
    defer terminal.deinit();
    switch (terminal.outcome.request.params.wait_for.condition) {
        .terminal_text => |condition| {
            try std.testing.expectEqual(TerminalTarget.active, condition.target);
            try std.testing.expectEqualStrings("READY", condition.contains);
        },
        else => return error.TestUnexpectedResult,
    }

    var scratchpad = try expectRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"wait_for\",\"params\":{\"condition\":{\"terminal_text\":{\"target\":\"scratchpad\",\"contains\":\"PERSISTED\"}},\"timeout_ms\":1}}",
        .wait_for,
    );
    defer scratchpad.deinit();
    switch (scratchpad.outcome.request.params.wait_for.condition) {
        .terminal_text => |condition| {
            try std.testing.expectEqual(TerminalTarget.scratchpad, condition.target);
            try std.testing.expectEqualStrings("PERSISTED", condition.contains);
        },
        else => return error.TestUnexpectedResult,
    }

    var legacy = try expectRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"wait_for\",\"params\":{\"condition\":{\"terminal_text\":{\"contains\":\"LEGACY\"}},\"timeout_ms\":1}}",
        .wait_for,
    );
    defer legacy.deinit();
    switch (legacy.outcome.request.params.wait_for.condition) {
        .terminal_text => |condition| {
            try std.testing.expectEqual(TerminalTarget.active, condition.target);
            try std.testing.expectEqualStrings("LEGACY", condition.contains);
        },
        else => return error.TestUnexpectedResult,
    }

    const invalid = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"wait_for\",\"params\":{\"condition\":{\"element\":{\"id\":\"x\",\"state\":\"visible\",\"equals\":true}},\"timeout_ms\":1}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"wait_for\",\"params\":{\"condition\":{\"terminal_text\":{\"target\":\"unknown\",\"contains\":\"x\"}},\"timeout_ms\":1}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"wait_for\",\"params\":{\"condition\":{\"element\":{\"id\":\"x\",\"state\":\"exists\",\"equals\":true}},\"timeout_ms\":300001}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"wait_for\",\"params\":{\"condition\":{\"element\":{\"id\":\"x\",\"state\":\"exists\",\"equals\":true},\"terminal_text\":{\"target\":\"active\",\"contains\":\"x\"}},\"timeout_ms\":1}}",
    };
    for (invalid) |frame| {
        var parsed = try expectFault(frame, .invalid_params);
        parsed.deinit();
    }
}

test "JSON-RPC envelope is exact and request ids are integers or strings" {
    var string_id = try expectRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":\"request-\\\"one\",\"method\":\"quit\",\"params\":{}}",
        .quit,
    );
    defer string_id.deinit();
    try std.testing.expectEqualStrings("request-\"one", string_id.outcome.request.id.string);

    const invalid = [_][]const u8{
        "{\"jsonrpc\":\"2.1\",\"id\":1,\"method\":\"quit\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"quit\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"quit\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1.0,\"method\":\"quit\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"quit\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"quit\",\"params\":[],\"extra\":true}",
    };
    for (invalid) |frame| {
        var parsed = try expectFault(frame, .invalid_request);
        parsed.deinit();
    }
}

test "malformed oversized deeply nested and unknown requests fail deterministically" {
    for ([_][]const u8{ "{", "[] trailing", "\xff" }) |frame| {
        var parsed = try expectFault(frame, .parse_error);
        parsed.deinit();
    }

    const oversized = try std.testing.allocator.alloc(u8, max_request_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    var too_large = try expectFault(oversized, .invalid_request);
    too_large.deinit();

    var nested: [max_json_depth + 2 + max_json_depth + 1]u8 = undefined;
    @memset(nested[0 .. max_json_depth + 1], '[');
    nested[max_json_depth + 1] = '0';
    @memset(nested[max_json_depth + 2 ..], ']');
    var too_deep = try expectFault(&nested, .invalid_request);
    too_deep.deinit();

    var unknown = try expectFault(
        "{\"jsonrpc\":\"2.0\",\"id\":\"known\",\"method\":\"assert\",\"params\":{}}",
        .method_not_found,
    );
    defer unknown.deinit();
    try std.testing.expectEqualStrings("known", unknown.outcome.failure.id.?.string);
}

test "strict params reject unknown fields bad bounds and missing pairs" {
    const invalid = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"inspect\",\"params\":{\"extra\":1}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"inspect\",\"params\":[]}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"drag\",\"params\":{\"from\":{\"id\":\"a\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"key\",\"params\":{\"chord\":\"CTRL\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"type\",\"params\":{\"text\":\"bad\\u0000text\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"scroll\",\"params\":{\"dy\":1000001}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"scroll\",\"params\":{\"dy\":1,\"x\":2}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"terminal_text\",\"params\":{\"target\":\"unknown\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"get_logs\",\"params\":{\"max_bytes\":4194305}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"quit\",\"params\":{\"now\":true}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"editor_open\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"editor_open\",\"params\":{\"path\":\"\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"editor_open\",\"params\":{\"path\":\"a\\nb\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"editor_open\",\"params\":{\"path\":\"a\",\"line\":0}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"editor_open\",\"params\":{\"path\":\"a\",\"column\":4}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"editor_open\",\"params\":{\"path\":\"a\",\"split\":\"up\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"editor_goto\",\"params\":{\"path\":\"a\",\"split\":\"down\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"editor_goto\",\"params\":{\"path\":\"a\",\"line\":10000001}}",
    };
    for (invalid) |frame| {
        var parsed = try expectFault(frame, .invalid_params);
        parsed.deinit();
    }
}

test "success and error responses echo ids escape text and have stable field order" {
    var success = try encodeSuccess(std.testing.allocator, .{ .integer = -7 }, .{
        .terminal_text = .{ .text = "line\n\"quoted\"" },
    });
    defer success.deinit();
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":-7,\"result\":{\"text\":\"line\\n\\\"quoted\\\"\"}}",
        success.bytes,
    );

    var failure = try encodeFailure(
        std.testing.allocator,
        .{ .string = "request\n1" },
        Fault.notFound("missing \"element\"\nretry"),
    );
    defer failure.deinit();
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"request\\n1\",\"error\":{\"code\":-32004,\"message\":\"missing \\\"element\\\"\\nretry\"}}",
        failure.bytes,
    );

    var parse_failure = try encodeFailure(std.testing.allocator, null, Fault.parse_error);
    defer parse_failure.deinit();
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}",
        parse_failure.bytes,
    );
}

test "response limit rejects oversized typed output" {
    const text = try std.testing.allocator.alloc(u8, max_response_bytes);
    defer std.testing.allocator.free(text);
    @memset(text, 'x');
    try std.testing.expectError(
        error.ResponseTooLarge,
        encodeSuccess(std.testing.allocator, .{ .integer = 1 }, .{ .logs = .{ .text = text } }),
    );
}

test "every documented method is available" {
    for (Method.all) |method| {
        try std.testing.expect(method.available());
    }
}

test "screenshot response deterministically encodes its artifact path" {
    var response = try encodeSuccess(std.testing.allocator, .{ .integer = 12 }, .{
        .screenshot = .{ .path = "artifacts/run-7/screenshot-0001.png" },
    });
    defer response.deinit();
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":12,\"result\":{\"path\":\"artifacts/run-7/screenshot-0001.png\"}}",
        response.bytes,
    );
}

test "JSON-RPC and application error codes are stable" {
    try std.testing.expectEqual(@as(i32, -32700), @intFromEnum(ErrorCode.parse_error));
    try std.testing.expectEqual(@as(i32, -32600), @intFromEnum(ErrorCode.invalid_request));
    try std.testing.expectEqual(@as(i32, -32601), @intFromEnum(ErrorCode.method_not_found));
    try std.testing.expectEqual(@as(i32, -32602), @intFromEnum(ErrorCode.invalid_params));
    try std.testing.expectEqual(@as(i32, -32603), @intFromEnum(ErrorCode.internal_error));
    try std.testing.expectEqual(@as(i32, -32000), @intFromEnum(ErrorCode.app_unavailable));
    try std.testing.expectEqual(@as(i32, -32004), @intFromEnum(ErrorCode.not_found));
    try std.testing.expectEqual(@as(i32, -32008), @intFromEnum(ErrorCode.timeout));
    try std.testing.expectEqual(ErrorCode.timeout, Fault.timedOut("deadline expired").code);
}

test "bounded queue is FIFO wraps and refuses a sixty-fifth item" {
    const Queue = BoundedQueue(u8, request_queue_depth);
    var queue: Queue = .{};
    for (0..request_queue_depth) |index| try queue.push(@intCast(index));
    try std.testing.expectError(error.QueueFull, queue.push(255));
    for (0..request_queue_depth / 2) |index| {
        try std.testing.expectEqual(@as(u8, @intCast(index)), queue.pop().?);
    }
    for (0..request_queue_depth / 2) |index| {
        try queue.push(@intCast(request_queue_depth + index));
    }
    for (request_queue_depth / 2..request_queue_depth + request_queue_depth / 2) |index| {
        try std.testing.expectEqual(@as(u8, @intCast(index)), queue.pop().?);
    }
    try std.testing.expectEqual(@as(usize, 0), queue.count());
    try std.testing.expect(queue.pop() == null);
}

test "automation is disabled in every build mode without explicit enablement" {
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe, .ReleaseFast, .ReleaseSmall }) |mode| {
        try std.testing.expect(!enabledIn(mode, false));
        try std.testing.expect(enabledIn(mode, true));
    }
    try std.testing.expect(!isEnabled(false));
    try std.testing.expect(isEnabled(true));
}
