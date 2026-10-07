//! `conduit-test`: a bounded command-line client for Conduit's local test driver.
//!
//! Direct commands derive a private local endpoint from a validated run id and
//! exchange one JSON-RPC request through `platform.DriverClient`. `launch`
//! creates the complete run directory before spawning Conduit, but publishes
//! its manifest only after an `inspect` round trip proves the driver is ready.
//! `mcp` exposes the same operations over bounded newline-delimited stdio,
//! supporting both current discovery metadata and legacy initialization.
//! Request payloads are never logged or included in diagnostics.

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const File = std.Io.File;
const Io = std.Io;

const max_request_bytes: usize = 1024 * 1024;
const max_mcp_message_bytes: usize = 1024 * 1024;
const max_mcp_text_bytes: usize = 4 * 1024 * 1024;
const max_mcp_text_output_bytes: usize = max_mcp_text_bytes * 6 + 8192;
const max_mcp_screenshot_bytes: usize = 32 * 1024 * 1024;
const modern_mcp_protocol_version = "2026-07-28";
const legacy_mcp_protocol_version = "2025-11-25";
const default_timeout_ms: u32 = 5_000;
const default_width: u32 = 960;
const default_height: u32 = 640;
const default_scale: f32 = 1.0;
const handshake_attempts: usize = 150;

const usage =
    \\conduit-test — usage
    \\
    \\  conduit-test [--root=<dir>] [--json] launch [--conduit=<path>]
    \\                      [--width=<px>] [--height=<px>] [--scale=<factor>]
    \\                      [--visible] [--no-child] [--command=<line>]
    \\  conduit-test [--root=<dir>] [--run=<id>] [--json] inspect
    \\  conduit-test [global options] click|ctrl-click|double-click|right-click <id>
    \\  conduit-test [global options] drag <from-id> <to-id>
    \\  conduit-test [global options] key <chord>
    \\  conduit-test [global options] type <text>
    \\  conduit-test [global options] scroll <dy> [dx]
    \\  conduit-test [global options] terminal-text [--target active|scratchpad]
    \\  conduit-test [global options] wait-for element <id> <state> <bool> [timeout-ms]
    \\  conduit-test [global options] wait-for terminal-text <needle> [timeout-ms] [--target active|scratchpad]
    \\  conduit-test [global options] logs [max-bytes]
    \\  conduit-test [global options] screenshot|quit
    \\  conduit-test mcp
    \\
    \\  Global environment fallbacks: CONDUIT_TEST_RUN, CONDUIT_TEST_ROOT.
    \\  A flag always wins over its environment fallback.
    \\
;

pub const CliError = error{
    UnknownOption,
    MissingValue,
    MissingCommand,
    InvalidArguments,
    InvalidRunId,
    MissingRunId,
    InvalidNumber,
    InvalidBoolean,
    InvalidState,
    InvalidTarget,
    InvalidResponse,
    DriverError,
    RequestTooLarge,
    CannotCreateRun,
    CannotLaunch,
    DriverNotReady,
    InvalidMcpRequest,
    InvalidMcpParams,
    MissingSelectedRun,
    UnsafeArtifactPath,
    InvalidScreenshot,
    MessageTooLarge,
};

const EnvSource = struct {
    context: *const anyopaque,
    get_fn: *const fn (*const anyopaque, []const u8) ?[]const u8,

    fn get(self: EnvSource, key: []const u8) ?[]const u8 {
        const value = self.get_fn(self.context, key) orelse return null;
        return if (value.len == 0) null else value;
    }
};

fn processEnv(init: std.process.Init) EnvSource {
    return .{
        .context = init.environ_map,
        .get_fn = struct {
            fn get(context: *const anyopaque, key: []const u8) ?[]const u8 {
                const map: *const std.process.Environ.Map = @ptrCast(@alignCast(context));
                return map.get(key);
            }
        }.get,
    };
}

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
    wait_element,
    wait_terminal_text,
    get_logs,
    screenshot,
    quit,
};

/// Read-only terminal text destination. Input commands intentionally have no
/// equivalent selector and always traverse Conduit's real active input path.
pub const TerminalTarget = enum {
    active,
    scratchpad,
};

pub const Direct = struct {
    method: Method,
    terminal_target: TerminalTarget = .active,
    first: ?[]const u8 = null,
    second: ?[]const u8 = null,
    third: ?[]const u8 = null,
    number: ?u32 = null,
    equals: bool = false,
    dx: f64 = 0,
    dy: f64 = 0,
};

const Launch = struct {
    conduit: ?[]const u8 = null,
    width: u32 = default_width,
    height: u32 = default_height,
    scale: f32 = default_scale,
    visible: bool = false,
    no_child: bool = false,
    command: ?[]const u8 = null,
};

const Command = union(enum) {
    launch: Launch,
    direct: Direct,
};

const Options = struct {
    root: ?[]const u8 = null,
    run: ?[]const u8 = null,
    json: bool = false,
    help: bool = false,
    command: ?Command = null,
};

fn namesValue(arg: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, arg, name) or
        (std.mem.startsWith(u8, arg, name) and arg.len > name.len and arg[name.len] == '=');
}

fn takeValue(arg: []const u8, name: []const u8, args: []const []const u8, index: *usize) CliError![]const u8 {
    if (std.mem.eql(u8, arg, name)) {
        if (index.* + 1 >= args.len) return error.MissingValue;
        index.* += 1;
        const value = args[index.*];
        if (value.len == 0) return error.MissingValue;
        return value;
    }
    const value = arg[name.len + 1 ..];
    if (value.len == 0) return error.MissingValue;
    return value;
}

fn parsePositiveU32(text: []const u8) CliError!u32 {
    const value = std.fmt.parseInt(u32, text, 10) catch return error.InvalidNumber;
    if (value == 0) return error.InvalidNumber;
    return value;
}

fn parseTimeout(text: []const u8) CliError!u32 {
    const value = std.fmt.parseInt(u32, text, 10) catch return error.InvalidNumber;
    if (value > 5 * 60 * 1000) return error.InvalidNumber;
    return value;
}

fn parseScale(text: []const u8) CliError!f32 {
    const value = std.fmt.parseFloat(f32, text) catch return error.InvalidNumber;
    if (!std.math.isFinite(value) or value < platform.Scale.min_factor) return error.InvalidNumber;
    return value;
}

fn parseBool(text: []const u8) CliError!bool {
    if (std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "false")) return false;
    return error.InvalidBoolean;
}

fn parseArgs(args: []const []const u8, env: EnvSource) CliError!Options {
    var options: Options = .{};
    var index: usize = if (args.len == 0) 0 else 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.help = true;
            if (index + 1 != args.len) return error.InvalidArguments;
            break;
        } else if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
        } else if (namesValue(arg, "--run")) {
            if (options.run != null) return error.InvalidArguments;
            options.run = try takeValue(arg, "--run", args, &index);
        } else if (namesValue(arg, "--root")) {
            if (options.root != null) return error.InvalidArguments;
            options.root = try takeValue(arg, "--root", args, &index);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else {
            options.command = try parseCommand(arg, args[index + 1 ..]);
            index = args.len;
            break;
        }
    }

    if (options.help) return options;
    if (options.command == null) return error.MissingCommand;
    options.root = options.root orelse env.get("CONDUIT_TEST_ROOT");
    switch (options.command.?) {
        .launch => {
            if (options.run != null) return error.InvalidArguments;
        },
        .direct => {
            options.run = options.run orelse env.get("CONDUIT_TEST_RUN") orelse return error.MissingRunId;
            try validateRunId(options.run.?);
        },
    }
    return options;
}

fn parseCommand(name: []const u8, tail: []const []const u8) CliError!Command {
    if (std.mem.eql(u8, name, "launch")) return .{ .launch = try parseLaunch(tail) };
    return .{ .direct = try parseDirect(name, tail) };
}

fn parseLaunch(args: []const []const u8) CliError!Launch {
    var launch: Launch = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (namesValue(arg, "--conduit")) {
            launch.conduit = try takeValue(arg, "--conduit", args, &index);
        } else if (namesValue(arg, "--width")) {
            launch.width = try parsePositiveU32(try takeValue(arg, "--width", args, &index));
        } else if (namesValue(arg, "--height")) {
            launch.height = try parsePositiveU32(try takeValue(arg, "--height", args, &index));
        } else if (namesValue(arg, "--scale")) {
            launch.scale = try parseScale(try takeValue(arg, "--scale", args, &index));
        } else if (std.mem.eql(u8, arg, "--visible")) {
            launch.visible = true;
        } else if (std.mem.eql(u8, arg, "--no-child")) {
            launch.no_child = true;
        } else if (namesValue(arg, "--command")) {
            launch.command = try takeValue(arg, "--command", args, &index);
        } else {
            return error.UnknownOption;
        }
    }
    if (launch.no_child and launch.command != null) return error.InvalidArguments;
    return launch;
}

fn exactArgs(args: []const []const u8, count: usize) CliError!void {
    if (args.len != count) return error.InvalidArguments;
}

fn parseDirect(name: []const u8, args: []const []const u8) CliError!Direct {
    if (std.mem.eql(u8, name, "inspect")) {
        try exactArgs(args, 0);
        return .{ .method = .inspect };
    }
    if (std.mem.eql(u8, name, "click") or std.mem.eql(u8, name, "ctrl-click") or
        std.mem.eql(u8, name, "double-click") or std.mem.eql(u8, name, "right-click"))
    {
        try exactArgs(args, 1);
        return .{
            .method = if (std.mem.eql(u8, name, "click"))
                .click
            else if (std.mem.eql(u8, name, "ctrl-click"))
                .ctrl_click
            else if (std.mem.eql(u8, name, "double-click"))
                .double_click
            else
                .right_click,
            .first = args[0],
        };
    }
    if (std.mem.eql(u8, name, "drag")) {
        try exactArgs(args, 2);
        return .{ .method = .drag, .first = args[0], .second = args[1] };
    }
    if (std.mem.eql(u8, name, "key") or std.mem.eql(u8, name, "type")) {
        try exactArgs(args, 1);
        return .{ .method = if (std.mem.eql(u8, name, "key")) .key else .type, .first = args[0] };
    }
    if (std.mem.eql(u8, name, "scroll")) {
        if (args.len < 1 or args.len > 2) return error.InvalidArguments;
        const dy = std.fmt.parseFloat(f64, args[0]) catch return error.InvalidNumber;
        const dx = if (args.len == 2) std.fmt.parseFloat(f64, args[1]) catch return error.InvalidNumber else 0;
        if (!std.math.isFinite(dy) or !std.math.isFinite(dx) or @abs(dy) > 1_000_000 or @abs(dx) > 1_000_000) return error.InvalidNumber;
        return .{ .method = .scroll, .dy = dy, .dx = dx };
    }
    if (std.mem.eql(u8, name, "terminal-text")) {
        var target: TerminalTarget = .active;
        var target_seen = false;
        var index: usize = 0;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (!namesValue(arg, "--target")) return error.InvalidArguments;
            if (target_seen) return error.InvalidArguments;
            target = try parseTerminalTarget(try takeValue(arg, "--target", args, &index));
            target_seen = true;
        }
        return .{
            .method = .terminal_text,
            .terminal_target = target,
        };
    }
    if (std.mem.eql(u8, name, "logs")) {
        if (args.len > 1) return error.InvalidArguments;
        const max_bytes = if (args.len == 1)
            std.fmt.parseInt(u32, args[0], 10) catch return error.InvalidNumber
        else
            null;
        if (max_bytes) |value| if (value > 4 * 1024 * 1024) return error.InvalidNumber;
        return .{ .method = .get_logs, .number = max_bytes };
    }
    if (std.mem.eql(u8, name, "screenshot") or std.mem.eql(u8, name, "quit")) {
        try exactArgs(args, 0);
        return .{ .method = if (std.mem.eql(u8, name, "screenshot")) .screenshot else .quit };
    }
    if (std.mem.eql(u8, name, "wait-for")) return parseWait(args);
    return error.InvalidArguments;
}

fn parseWait(args: []const []const u8) CliError!Direct {
    if (args.len == 0) return error.InvalidArguments;
    if (std.mem.eql(u8, args[0], "element")) {
        if (args.len < 4 or args.len > 5) return error.InvalidArguments;
        if (!validElementState(args[2])) return error.InvalidState;
        return .{
            .method = .wait_element,
            .first = args[1],
            .second = args[2],
            .equals = try parseBool(args[3]),
            .number = if (args.len == 5) try parseTimeout(args[4]) else default_timeout_ms,
        };
    }
    if (std.mem.eql(u8, args[0], "terminal-text")) {
        if (args.len < 2) return error.InvalidArguments;
        var target: TerminalTarget = .active;
        var target_seen = false;
        var timeout: u32 = default_timeout_ms;
        var timeout_seen = false;
        var index: usize = 2;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (namesValue(arg, "--target")) {
                if (target_seen) return error.InvalidArguments;
                target = try parseTerminalTarget(try takeValue(arg, "--target", args, &index));
                target_seen = true;
            } else {
                if (timeout_seen) return error.InvalidArguments;
                timeout = try parseTimeout(arg);
                timeout_seen = true;
            }
        }
        return .{
            .method = .wait_terminal_text,
            .terminal_target = target,
            .first = args[1],
            .number = timeout,
        };
    }
    return error.InvalidArguments;
}

fn validElementState(text: []const u8) bool {
    for ([_][]const u8{ "exists", "hovered", "focused", "pressed" }) |state| {
        if (std.mem.eql(u8, text, state)) return true;
    }
    return false;
}

fn terminalTarget(text: []const u8) ?TerminalTarget {
    return std.meta.stringToEnum(TerminalTarget, text);
}

fn parseTerminalTarget(text: []const u8) CliError!TerminalTarget {
    return terminalTarget(text) orelse error.InvalidTarget;
}

/// Run ids are one safe path component and one safe Windows pipe-name suffix.
pub fn validateRunId(run_id: []const u8) CliError!void {
    if (run_id.len == 0 or run_id.len > 80 or !std.ascii.isAlphanumeric(run_id[0])) return error.InvalidRunId;
    for (run_id[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return error.InvalidRunId;
    }
}

pub const RunPaths = struct {
    run_dir: []u8,
    home: []u8,
    config: []u8,
    data: []u8,
    state: []u8,
    cache: []u8,
    logs: []u8,
    artifacts: []u8,
    temp: []u8,
    endpoint: []u8,
    stdout_path: []u8,
    stderr_path: []u8,
    manifest_path: []u8,

    pub fn deinit(self: *RunPaths, allocator: Allocator) void {
        inline for (std.meta.fields(RunPaths)) |field| allocator.free(@field(self, field.name));
        self.* = undefined;
    }
};

fn join(allocator: Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(allocator, parts);
}

pub fn deriveRunPaths(allocator: Allocator, root: []const u8, run_id: []const u8) !RunPaths {
    try validateRunId(run_id);
    const run_dir = try join(allocator, &.{ root, run_id });
    errdefer allocator.free(run_dir);
    var paths: RunPaths = undefined;
    paths.run_dir = run_dir;
    paths.home = try join(allocator, &.{ run_dir, "home" });
    errdefer allocator.free(paths.home);
    paths.config = try join(allocator, &.{ run_dir, "config" });
    errdefer allocator.free(paths.config);
    paths.data = try join(allocator, &.{ run_dir, "data" });
    errdefer allocator.free(paths.data);
    paths.state = try join(allocator, &.{ run_dir, "state" });
    errdefer allocator.free(paths.state);
    paths.cache = try join(allocator, &.{ run_dir, "cache" });
    errdefer allocator.free(paths.cache);
    paths.logs = try join(allocator, &.{ run_dir, "logs" });
    errdefer allocator.free(paths.logs);
    paths.artifacts = try join(allocator, &.{ run_dir, "artifacts" });
    errdefer allocator.free(paths.artifacts);
    paths.temp = try join(allocator, &.{ run_dir, "tmp" });
    errdefer allocator.free(paths.temp);
    paths.endpoint = if (builtin.os.tag == .windows)
        try std.fmt.allocPrint(allocator, "\\\\.\\pipe\\conduit-test-{s}", .{run_id})
    else
        try join(allocator, &.{ run_dir, "driver.sock" });
    errdefer allocator.free(paths.endpoint);
    paths.stdout_path = try join(allocator, &.{ run_dir, "stdout.txt" });
    errdefer allocator.free(paths.stdout_path);
    paths.stderr_path = try join(allocator, &.{ run_dir, "stderr.txt" });
    errdefer allocator.free(paths.stderr_path);
    paths.manifest_path = try join(allocator, &.{ run_dir, "manifest.json" });
    return paths;
}

fn defaultRoot(allocator: Allocator, env: EnvSource) ![]u8 {
    const base = env.get("TMPDIR") orelse env.get("TEMP") orelse env.get("TMP") orelse
        if (builtin.os.tag == .windows) "." else "/tmp";
    return join(allocator, &.{ base, "conduit-test" });
}

fn absoluteRoot(io: Io, allocator: Allocator, root: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(root)) return allocator.dupe(u8, root);
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, root });
}

fn rpcName(method: Method) []const u8 {
    return switch (method) {
        .wait_element, .wait_terminal_text => "wait_for",
        else => @tagName(method),
    };
}

fn writeJsonString(writer: *std.Io.Writer, text: []const u8) !void {
    try std.json.Stringify.value(text, .{}, writer);
}

/// Encode one bounded JSON-RPC request. The caller owns the returned bytes.
pub fn buildRequest(allocator: Allocator, direct: Direct) (Allocator.Error || CliError)![]u8 {
    const bytes = try allocator.alloc(u8, max_request_bytes);
    errdefer allocator.free(bytes);
    var writer = std.Io.Writer.fixed(bytes);
    writer.print("{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":", .{rpcName(direct.method)}) catch
        return error.RequestTooLarge;
    switch (direct.method) {
        .inspect, .screenshot, .quit => writer.writeAll("{}") catch return error.RequestTooLarge,
        .click, .ctrl_click, .double_click, .right_click => {
            writer.writeAll("{\"id\":") catch return error.RequestTooLarge;
            writeJsonString(&writer, direct.first.?) catch return error.RequestTooLarge;
            writer.writeByte('}') catch return error.RequestTooLarge;
        },
        .drag => {
            writer.writeAll("{\"from\":{\"id\":") catch return error.RequestTooLarge;
            writeJsonString(&writer, direct.first.?) catch return error.RequestTooLarge;
            writer.writeAll("},\"to\":{\"id\":") catch return error.RequestTooLarge;
            writeJsonString(&writer, direct.second.?) catch return error.RequestTooLarge;
            writer.writeAll("}}") catch return error.RequestTooLarge;
        },
        .key => {
            writer.writeAll("{\"chord\":") catch return error.RequestTooLarge;
            writeJsonString(&writer, direct.first.?) catch return error.RequestTooLarge;
            writer.writeByte('}') catch return error.RequestTooLarge;
        },
        .type => {
            writer.writeAll("{\"text\":") catch return error.RequestTooLarge;
            writeJsonString(&writer, direct.first.?) catch return error.RequestTooLarge;
            writer.writeByte('}') catch return error.RequestTooLarge;
        },
        .scroll => writer.print("{{\"dy\":{d},\"dx\":{d}}}", .{ direct.dy, direct.dx }) catch return error.RequestTooLarge,
        .terminal_text => writer.print(
            "{{\"target\":\"{s}\"}}",
            .{@tagName(direct.terminal_target)},
        ) catch return error.RequestTooLarge,
        .wait_element => {
            writer.writeAll("{\"condition\":{\"element\":{\"id\":") catch return error.RequestTooLarge;
            writeJsonString(&writer, direct.first.?) catch return error.RequestTooLarge;
            writer.writeAll(",\"state\":") catch return error.RequestTooLarge;
            writeJsonString(&writer, direct.second.?) catch return error.RequestTooLarge;
            writer.print(",\"equals\":{s}}}}},\"timeout_ms\":{d}}}", .{ if (direct.equals) "true" else "false", direct.number.? }) catch return error.RequestTooLarge;
        },
        .wait_terminal_text => {
            writer.print(
                "{{\"condition\":{{\"terminal_text\":{{\"target\":\"{s}\",\"contains\":",
                .{@tagName(direct.terminal_target)},
            ) catch return error.RequestTooLarge;
            writeJsonString(&writer, direct.first.?) catch return error.RequestTooLarge;
            writer.print("}}}},\"timeout_ms\":{d}}}", .{direct.number.?}) catch return error.RequestTooLarge;
        },
        .get_logs => if (direct.number) |max_bytes|
            writer.print("{{\"max_bytes\":{d}}}", .{max_bytes}) catch return error.RequestTooLarge
        else
            writer.writeAll("{}") catch return error.RequestTooLarge,
    }
    writer.writeByte('}') catch return error.RequestTooLarge;
    return allocator.realloc(bytes, writer.buffered().len);
}

/// Decode and project one response for plain-text callers. The caller owns the result.
pub fn decodeResponse(allocator: Allocator, response: []const u8, method: Method) (Allocator.Error || CliError)![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = 4 * 1024 * 1024,
    }) catch return error.InvalidResponse;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidResponse,
    };
    if (object.count() != 3) return error.InvalidResponse;
    const version = object.get("jsonrpc") orelse return error.InvalidResponse;
    if (version != .string or !std.mem.eql(u8, version.string, "2.0")) return error.InvalidResponse;
    const id = object.get("id") orelse return error.InvalidResponse;
    if (id != .integer or id.integer != 1) return error.InvalidResponse;
    if (object.get("error") != null) {
        if (object.get("result") != null) return error.InvalidResponse;
        return error.DriverError;
    }
    const result = object.get("result") orelse return error.InvalidResponse;
    return switch (method) {
        .inspect => if (result == .object) stringifyValue(allocator, result) else error.InvalidResponse,
        .terminal_text, .get_logs => objectString(allocator, result, "text"),
        .screenshot => objectString(allocator, result, "path"),
        else => blk: {
            if (result != .object or result.object.count() != 0) return error.InvalidResponse;
            break :blk allocator.dupe(u8, "ok");
        },
    };
}

fn objectString(allocator: Allocator, value: std.json.Value, key: []const u8) (Allocator.Error || CliError)![]u8 {
    if (value != .object or value.object.count() != 1) return error.InvalidResponse;
    const member = value.object.get(key) orelse return error.InvalidResponse;
    if (member != .string) return error.InvalidResponse;
    return allocator.dupe(u8, member.string);
}

fn stringifyValue(allocator: Allocator, value: std.json.Value) (Allocator.Error || CliError)![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

/// Return true for a JSON-RPC error or a malformed response.
pub fn responseIsError(allocator: Allocator, response: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return true;
    defer parsed.deinit();
    if (parsed.value != .object) return true;
    const object = parsed.value.object;
    if (object.count() != 3) return true;
    const version = object.get("jsonrpc") orelse return true;
    const id = object.get("id") orelse return true;
    if (version != .string or !std.mem.eql(u8, version.string, "2.0")) return true;
    if (id != .integer or id.integer != 1) return true;
    if (object.get("error") != null) return true;
    return object.get("result") == null;
}

fn createPrivateDirectories(io: Io, root: []const u8, paths: RunPaths) !void {
    const permissions: File.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
    _ = try Dir.cwd().createDirPathStatus(io, root, permissions);
    try Dir.cwd().createDir(io, paths.run_dir, permissions);
    inline for (.{ paths.home, paths.config, paths.data, paths.state, paths.cache, paths.logs, paths.artifacts, paths.temp }) |path| {
        try Dir.cwd().createDir(io, path, permissions);
    }
}

fn generateRunId(io: Io, buffer: *[40]u8) []const u8 {
    var random: [12]u8 = undefined;
    io.random(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    return std.fmt.bufPrint(buffer, "run-{s}", .{&hex}) catch unreachable;
}

fn deriveConduitPath(allocator: Allocator, argv0: []const u8) ![]u8 {
    const name = if (builtin.os.tag == .windows) "conduit.exe" else "conduit";
    const parent = std.fs.path.dirname(argv0) orelse return allocator.dupe(u8, name);
    return join(allocator, &.{ parent, name });
}

/// Exchange one typed command with an already running local driver.
/// The caller owns the returned raw JSON-RPC response.
pub fn exchange(allocator: Allocator, endpoint: []const u8, direct: Direct) ![]u8 {
    const request = try buildRequest(allocator, direct);
    defer allocator.free(request);
    var client = try platform.DriverClient.connect(endpoint);
    defer client.deinit();
    return client.exchange(allocator, request);
}

fn driverReady(allocator: Allocator, endpoint: []const u8) bool {
    const response = exchange(allocator, endpoint, .{ .method = .inspect }) catch return false;
    defer allocator.free(response);
    const projected = decodeResponse(allocator, response, .inspect) catch return false;
    allocator.free(projected);
    return true;
}

fn launchConduit(init: std.process.Init, argv0: []const u8, launch: Launch, root: []const u8) ![]u8 {
    var id_buffer: [40]u8 = undefined;
    var paths: RunPaths = undefined;
    var run_id: []const u8 = undefined;
    var created = false;
    for (0..16) |_| {
        run_id = generateRunId(init.io, &id_buffer);
        paths = try deriveRunPaths(init.gpa, root, run_id);
        createPrivateDirectories(init.io, root, paths) catch |err| {
            paths.deinit(init.gpa);
            if (err == error.PathAlreadyExists) continue;
            return error.CannotCreateRun;
        };
        created = true;
        break;
    }
    if (!created) return error.CannotCreateRun;
    defer paths.deinit(init.gpa);

    const conduit_path = if (launch.conduit) |path| try init.gpa.dupe(u8, path) else try deriveConduitPath(init.gpa, argv0);
    defer init.gpa.free(conduit_path);
    const endpoint_arg = try std.fmt.allocPrint(init.gpa, "--test-driver={s}", .{paths.endpoint});
    defer init.gpa.free(endpoint_arg);
    const artifact_arg = try std.fmt.allocPrint(init.gpa, "--test-artifact-dir={s}", .{paths.artifacts});
    defer init.gpa.free(artifact_arg);
    const log_arg = try std.fmt.allocPrint(init.gpa, "--log-dir={s}", .{paths.logs});
    defer init.gpa.free(log_arg);
    const width_arg = try std.fmt.allocPrint(init.gpa, "--width={d}", .{launch.width});
    defer init.gpa.free(width_arg);
    const height_arg = try std.fmt.allocPrint(init.gpa, "--height={d}", .{launch.height});
    defer init.gpa.free(height_arg);
    const scale_arg = try std.fmt.allocPrint(init.gpa, "--scale={d}", .{launch.scale});
    defer init.gpa.free(scale_arg);
    const command_arg = if (launch.command) |line| try std.fmt.allocPrint(init.gpa, "--command={s}", .{line}) else null;
    defer if (command_arg) |arg| init.gpa.free(arg);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(init.gpa);
    try argv.appendSlice(init.gpa, &.{ conduit_path, endpoint_arg, artifact_arg, log_arg, width_arg, height_arg, scale_arg });
    if (!launch.visible) try argv.append(init.gpa, "--hidden");
    if (launch.no_child) try argv.append(init.gpa, "--no-child");
    if (command_arg) |arg| try argv.append(init.gpa, arg);

    var child_env = try init.environ_map.clone(init.gpa);
    defer child_env.deinit();
    try child_env.put("HOME", paths.home);
    try child_env.put("XDG_CONFIG_HOME", paths.config);
    try child_env.put("XDG_DATA_HOME", paths.data);
    try child_env.put("XDG_STATE_HOME", paths.state);
    try child_env.put("XDG_CACHE_HOME", paths.cache);
    try child_env.put("TMPDIR", paths.temp);
    try child_env.put("TEMP", paths.temp);
    try child_env.put("TMP", paths.temp);
    _ = child_env.swapRemove("CONDUIT_LOG_FILE");
    _ = child_env.swapRemove("CONDUIT_LOG_DIR");
    if (builtin.os.tag == .windows) {
        try child_env.put("USERPROFILE", paths.home);
        try child_env.put("APPDATA", paths.config);
        try child_env.put("LOCALAPPDATA", paths.state);
    }
    if (builtin.os.tag == .linux and child_env.get("DISPLAY") == null and child_env.get("WAYLAND_DISPLAY") == null and child_env.get("SDL_VIDEODRIVER") == null) {
        try child_env.put("SDL_VIDEODRIVER", "offscreen");
    }

    const file_permissions: File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
    const stdout_file = Dir.cwd().createFile(init.io, paths.stdout_path, .{ .exclusive = true, .permissions = file_permissions }) catch return error.CannotLaunch;
    defer stdout_file.close(init.io);
    const stderr_file = Dir.cwd().createFile(init.io, paths.stderr_path, .{ .exclusive = true, .permissions = file_permissions }) catch return error.CannotLaunch;
    defer stderr_file.close(init.io);

    var child = std.process.spawn(init.io, .{
        .argv = argv.items,
        .environ_map = &child_env,
        .stdin = .ignore,
        .stdout = .{ .file = stdout_file },
        .stderr = .{ .file = stderr_file },
        .create_no_window = !launch.visible,
    }) catch return error.CannotLaunch;
    var ready = false;
    for (0..handshake_attempts) |_| {
        if (driverReady(init.gpa, paths.endpoint)) {
            ready = true;
            break;
        }
        // Cancellation only shortens the readiness budget; the next probe is
        // still bounded and will either succeed or fail the launch cleanly.
        Io.sleep(init.io, .fromMilliseconds(20), .awake) catch {};
    }
    if (!ready) {
        child.kill(init.io);
        return error.DriverNotReady;
    }

    writeManifest(init.io, paths, run_id) catch |err| {
        child.kill(init.io);
        return err;
    };
    // The launched app intentionally outlives this short client process. Its
    // process resources are reclaimed by the OS when this command exits.
    _ = &child;
    return init.gpa.dupe(u8, run_id);
}

fn writeManifest(io: Io, paths: RunPaths, run_id: []const u8) !void {
    const permissions: File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
    var temp_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temp_path = try std.fmt.bufPrint(&temp_buffer, "{s}.tmp", .{paths.manifest_path});
    var file = try Dir.cwd().createFile(io, temp_path, .{ .exclusive = true, .permissions = permissions });
    var open = true;
    defer {
        if (open) file.close(io);
        // Best-effort rollback cannot make a failed manifest publication less
        // correct: the final name was never published and the run remains private.
        Dir.cwd().deleteFile(io, temp_path) catch {};
    }
    var buffer: [4096]u8 = undefined;
    var stream = file.writerStreaming(io, &buffer);
    const writer = &stream.interface;
    try writer.writeAll("{\"version\":1,\"run\":");
    try writeJsonString(writer, run_id);
    try writer.writeAll(",\"endpoint\":");
    try writeJsonString(writer, paths.endpoint);
    try writer.writeAll(",\"run_dir\":");
    try writeJsonString(writer, paths.run_dir);
    try writer.writeAll(",\"artifacts\":");
    try writeJsonString(writer, paths.artifacts);
    try writer.writeAll(",\"logs\":");
    try writeJsonString(writer, paths.logs);
    try writer.writeAll(",\"stdout\":");
    try writeJsonString(writer, paths.stdout_path);
    try writer.writeAll(",\"stderr\":");
    try writeJsonString(writer, paths.stderr_path);
    try writer.writeAll("}\n");
    try writer.flush();
    file.close(io);
    open = false;
    try Dir.cwd().rename(temp_path, Dir.cwd(), paths.manifest_path, io);
}

fn runDirect(init: std.process.Init, paths: RunPaths, direct: Direct, json: bool) !void {
    const response = try exchange(init.gpa, paths.endpoint, direct);
    defer init.gpa.free(response);

    if (json) {
        const validated = decodeResponse(init.gpa, response, direct.method) catch |err| {
            if (err == error.DriverError) {
                try writeOutput(init.io, response);
                try writeOutput(init.io, "\n");
            }
            return err;
        };
        defer init.gpa.free(validated);
        try writeOutput(init.io, response);
        try writeOutput(init.io, "\n");
        return;
    }
    const projected = try decodeResponse(init.gpa, response, direct.method);
    defer init.gpa.free(projected);
    try writeOutput(init.io, projected);
    try writeOutput(init.io, "\n");
}

fn writeLaunchOutput(io: Io, allocator: Allocator, run_id: []const u8, json: bool) !void {
    if (!json) {
        try writeOutput(io, run_id);
        try writeOutput(io, "\n");
        return;
    }
    const rendered = try std.fmt.allocPrint(allocator, "{{\"run\":\"{s}\"}}\n", .{run_id});
    defer allocator.free(rendered);
    try writeOutput(io, rendered);
}

fn writeOutput(io: Io, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var stream = File.stdout().writerStreaming(io, &buffer);
    try stream.interface.writeAll(bytes);
    try stream.interface.flush();
}

fn writeError(text: []const u8) void {
    var buffer: [1024]u8 = undefined;
    var stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    stderr.writer.writeAll(text) catch return;
    stderr.writer.flush() catch return;
}

fn collectArgs(allocator: Allocator, source: std.process.Args) ![]const []const u8 {
    var iterator = try std.process.Args.Iterator.initAllocator(source, allocator);
    defer iterator.deinit();
    var args: std.ArrayList([]const u8) = .empty;
    while (iterator.next()) |arg| try args.append(allocator, arg);
    return args.items;
}

fn runMain(init: std.process.Init, args: []const []const u8) !void {
    const options = try parseArgs(args, processEnv(init));
    if (options.help) {
        try writeOutput(init.io, usage);
        return;
    }
    const unresolved_root = if (options.root) |root| try init.gpa.dupe(u8, root) else try defaultRoot(init.gpa, processEnv(init));
    defer init.gpa.free(unresolved_root);
    const root_owned = try absoluteRoot(init.io, init.gpa, unresolved_root);
    defer init.gpa.free(root_owned);
    switch (options.command.?) {
        .launch => |launch| {
            const run_id = try launchConduit(init, if (args.len == 0) "conduit-test" else args[0], launch, root_owned);
            defer init.gpa.free(run_id);
            try writeLaunchOutput(init.io, init.gpa, run_id, options.json);
        },
        .direct => |direct| {
            var paths = try deriveRunPaths(init.gpa, root_owned, options.run.?);
            defer paths.deinit(init.gpa);
            try runDirect(init, paths, direct, options.json);
        },
    }
}

fn wantsJson(args: []const []const u8) bool {
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--json")) return true;
    }
    return false;
}

fn jsonFailure(allocator: Allocator, err: anyerror) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{{\"code\":-32000,\"message\":\"{s}\"}}}}\n",
        .{@errorName(err)},
    );
}

const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    read_only: bool = false,
};

const selector_properties =
    "\"root\":{\"type\":\"string\",\"description\":\"Absolute or working-directory-relative isolated test root\"}," ++
    "\"run\":{\"type\":\"string\",\"pattern\":\"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$\",\"description\":\"Explicit isolated run id; otherwise use the selected run\"}";

const terminal_target_property =
    "\"target\":{\"enum\":[\"active\",\"scratchpad\"],\"default\":\"active\",\"description\":\"Read-only terminal text target\"}";

const tool_specs = [_]ToolSpec{
    .{
        .name = "launch",
        .description = "Launch an isolated Conduit, wait for its driver, and select the returned run.",
        .input_schema = "{\"type\":\"object\",\"properties\":{" ++
            "\"root\":{\"type\":\"string\"},\"conduit\":{\"type\":\"string\"}," ++
            "\"width\":{\"type\":\"integer\",\"minimum\":1},\"height\":{\"type\":\"integer\",\"minimum\":1}," ++
            "\"scale\":{\"type\":\"number\",\"minimum\":0.25},\"visible\":{\"type\":\"boolean\"}," ++
            "\"no_child\":{\"type\":\"boolean\"},\"command\":{\"type\":\"string\"}},\"additionalProperties\":false}",
    },
    .{ .name = "inspect", .description = "Return the semantic element tree for the selected run.", .input_schema = "{\"type\":\"object\",\"properties\":{" ++ selector_properties ++ "},\"additionalProperties\":false}", .read_only = true },
    .{ .name = "click", .description = "Click a semantic element by stable id.", .input_schema = "{\"type\":\"object\",\"properties\":{" ++ selector_properties ++ ",\"id\":{\"type\":\"string\"}},\"required\":[\"id\"],\"additionalProperties\":false}" },
    .{ .name = "ctrl_click", .description = "Control-click a semantic element by stable id.", .input_schema = "{\"type\":\"object\",\"properties\":{" ++ selector_properties ++ ",\"id\":{\"type\":\"string\"}},\"required\":[\"id\"],\"additionalProperties\":false}" },
    .{ .name = "double_click", .description = "Double-click a semantic element by stable id.", .input_schema = "{\"type\":\"object\",\"properties\":{" ++ selector_properties ++ ",\"id\":{\"type\":\"string\"}},\"required\":[\"id\"],\"additionalProperties\":false}" },
    .{ .name = "right_click", .description = "Right-click a semantic element by stable id, opening the terminal context menu where configured.", .input_schema = "{\"type\":\"object\",\"properties\":{" ++ selector_properties ++ ",\"id\":{\"type\":\"string\"}},\"required\":[\"id\"],\"additionalProperties\":false}" },
    .{ .name = "drag", .description = "Drag from one semantic element to another.", .input_schema = "{\"type\":\"object\",\"properties\":{" ++ selector_properties ++ ",\"from\":{\"type\":\"string\"},\"to\":{\"type\":\"string\"}},\"required\":[\"from\",\"to\"],\"additionalProperties\":false}" },
    .{ .name = "key", .description = "Send a key chord through Conduit's real input path.", .input_schema = "{\"type\":\"object\",\"properties\":{" ++ selector_properties ++ ",\"chord\":{\"type\":\"string\"}},\"required\":[\"chord\"],\"additionalProperties\":false}" },
    .{ .name = "type", .description = "Type UTF-8 text through Conduit's real input path.", .input_schema = "{\"type\":\"object\",\"properties\":{" ++ selector_properties ++ ",\"text\":{\"type\":\"string\"}},\"required\":[\"text\"],\"additionalProperties\":false}" },
    .{ .name = "scroll", .description = "Scroll the selected run by vertical and optional horizontal deltas.", .input_schema = "{\"type\":\"object\",\"properties\":{" ++ selector_properties ++ ",\"dy\":{\"type\":\"number\",\"minimum\":-1000000,\"maximum\":1000000},\"dx\":{\"type\":\"number\",\"minimum\":-1000000,\"maximum\":1000000}},\"required\":[\"dy\"],\"additionalProperties\":false}" },
    .{ .name = "terminal_text", .description = "Return visible text from the active terminal or scratchpad.", .input_schema = "{\"type\":\"object\",\"properties\":{" ++ selector_properties ++ "," ++ terminal_target_property ++ "},\"additionalProperties\":false}", .read_only = true },
    .{
        .name = "wait_for",
        .description = "Wait for one semantic-element state or selected-terminal text condition.",
        .input_schema = "{\"type\":\"object\",\"properties\":{" ++ selector_properties ++
            ",\"element\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"state\":{\"enum\":[\"exists\",\"hovered\",\"focused\",\"pressed\"]},\"equals\":{\"type\":\"boolean\"}},\"required\":[\"id\",\"state\",\"equals\"],\"additionalProperties\":false}," ++
            "\"terminal_text\":{\"type\":\"object\",\"properties\":{\"contains\":{\"type\":\"string\"}," ++ terminal_target_property ++ "},\"required\":[\"contains\"],\"additionalProperties\":false}," ++
            "\"timeout_ms\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":300000}}," ++
            "\"oneOf\":[{\"required\":[\"element\"]},{\"required\":[\"terminal_text\"]}],\"additionalProperties\":false}",
        .read_only = true,
    },
    .{ .name = "get_logs", .description = "Return a bounded log tail for the selected run.", .input_schema = "{\"type\":\"object\",\"properties\":{" ++ selector_properties ++ ",\"max_bytes\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":4194304}},\"additionalProperties\":false}", .read_only = true },
    .{ .name = "screenshot", .description = "Capture the selected run and return its PNG as MCP image content.", .input_schema = "{\"type\":\"object\",\"properties\":{" ++ selector_properties ++ "},\"additionalProperties\":false}", .read_only = true },
    .{ .name = "quit", .description = "Quit the selected isolated Conduit run.", .input_schema = "{\"type\":\"object\",\"properties\":{" ++ selector_properties ++ "},\"additionalProperties\":false}" },
};

fn findTool(name: []const u8) ?ToolSpec {
    for (tool_specs) |spec| if (std.mem.eql(u8, name, spec.name)) return spec;
    return null;
}

const ToolInvocation = struct {
    root: ?[]const u8 = null,
    run: ?[]const u8 = null,
    command: Command,
};

fn onlyFields(object: std.json.ObjectMap, allowed: []const []const u8) CliError!void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var accepted = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                accepted = true;
                break;
            }
        }
        if (!accepted) return error.InvalidMcpParams;
    }
}

fn optionalToolString(object: std.json.ObjectMap, name: []const u8, max_len: usize) CliError!?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string or value.string.len == 0 or value.string.len > max_len) return error.InvalidMcpParams;
    return value.string;
}

fn requiredToolString(object: std.json.ObjectMap, name: []const u8, max_len: usize) CliError![]const u8 {
    return (try optionalToolString(object, name, max_len)) orelse error.InvalidMcpParams;
}

fn optionalTerminalTarget(object: std.json.ObjectMap, name: []const u8) CliError!TerminalTarget {
    const text = try optionalToolString(object, name, 16) orelse return .active;
    return terminalTarget(text) orelse error.InvalidMcpParams;
}

fn optionalToolBool(object: std.json.ObjectMap, name: []const u8, default: bool) CliError!bool {
    const value = object.get(name) orelse return default;
    if (value != .bool) return error.InvalidMcpParams;
    return value.bool;
}

fn jsonNumber(value: std.json.Value) CliError!f64 {
    const number: f64 = switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => return error.InvalidMcpParams,
    };
    if (!std.math.isFinite(number)) return error.InvalidMcpParams;
    return number;
}

fn optionalToolU32(object: std.json.ObjectMap, name: []const u8, default: ?u32, max: u32) CliError!?u32 {
    const value = object.get(name) orelse return default;
    if (value != .integer or value.integer < 0 or value.integer > max) return error.InvalidMcpParams;
    return @intCast(value.integer);
}

fn parseToolInvocation(name: []const u8, arguments: std.json.Value) CliError!ToolInvocation {
    if (arguments != .object) return error.InvalidMcpParams;
    const object = arguments.object;
    const root = try optionalToolString(object, "root", std.fs.max_path_bytes);
    const run = try optionalToolString(object, "run", 80);
    if (run) |run_id| try validateRunId(run_id);

    if (std.mem.eql(u8, name, "launch")) {
        try onlyFields(object, &.{ "root", "conduit", "width", "height", "scale", "visible", "no_child", "command" });
        const width = (try optionalToolU32(object, "width", default_width, std.math.maxInt(u32))).?;
        const height = (try optionalToolU32(object, "height", default_height, std.math.maxInt(u32))).?;
        if (width == 0 or height == 0) return error.InvalidMcpParams;
        const scale = if (object.get("scale")) |value| try jsonNumber(value) else default_scale;
        if (scale < platform.Scale.min_factor or scale > std.math.floatMax(f32)) return error.InvalidMcpParams;
        const launch: Launch = .{
            .conduit = try optionalToolString(object, "conduit", std.fs.max_path_bytes),
            .width = width,
            .height = height,
            .scale = @floatCast(scale),
            .visible = try optionalToolBool(object, "visible", false),
            .no_child = try optionalToolBool(object, "no_child", false),
            .command = try optionalToolString(object, "command", max_mcp_message_bytes),
        };
        if (launch.no_child and launch.command != null) return error.InvalidMcpParams;
        return .{ .root = root, .command = .{ .launch = launch } };
    }

    var direct: Direct = undefined;
    if (std.mem.eql(u8, name, "inspect") or std.mem.eql(u8, name, "screenshot") or std.mem.eql(u8, name, "quit")) {
        try onlyFields(object, &.{ "root", "run" });
        direct = .{ .method = if (std.mem.eql(u8, name, "inspect")) .inspect else if (std.mem.eql(u8, name, "screenshot")) .screenshot else .quit };
    } else if (std.mem.eql(u8, name, "terminal_text")) {
        try onlyFields(object, &.{ "root", "run", "target" });
        direct = .{
            .method = .terminal_text,
            .terminal_target = try optionalTerminalTarget(object, "target"),
        };
    } else if (std.mem.eql(u8, name, "click") or std.mem.eql(u8, name, "ctrl_click") or
        std.mem.eql(u8, name, "double_click") or std.mem.eql(u8, name, "right_click"))
    {
        try onlyFields(object, &.{ "root", "run", "id" });
        direct = .{
            .method = if (std.mem.eql(u8, name, "click"))
                .click
            else if (std.mem.eql(u8, name, "ctrl_click"))
                .ctrl_click
            else if (std.mem.eql(u8, name, "double_click"))
                .double_click
            else
                .right_click,
            .first = try requiredToolString(object, "id", max_mcp_message_bytes),
        };
    } else if (std.mem.eql(u8, name, "drag")) {
        try onlyFields(object, &.{ "root", "run", "from", "to" });
        direct = .{ .method = .drag, .first = try requiredToolString(object, "from", max_mcp_message_bytes), .second = try requiredToolString(object, "to", max_mcp_message_bytes) };
    } else if (std.mem.eql(u8, name, "key")) {
        try onlyFields(object, &.{ "root", "run", "chord" });
        direct = .{ .method = .key, .first = try requiredToolString(object, "chord", max_mcp_message_bytes) };
    } else if (std.mem.eql(u8, name, "type")) {
        try onlyFields(object, &.{ "root", "run", "text" });
        direct = .{ .method = .type, .first = try requiredToolString(object, "text", max_mcp_message_bytes) };
    } else if (std.mem.eql(u8, name, "scroll")) {
        try onlyFields(object, &.{ "root", "run", "dy", "dx" });
        const dy = try jsonNumber(object.get("dy") orelse return error.InvalidMcpParams);
        const dx = if (object.get("dx")) |value| try jsonNumber(value) else 0;
        if (@abs(dy) > 1_000_000 or @abs(dx) > 1_000_000) return error.InvalidMcpParams;
        direct = .{ .method = .scroll, .dy = dy, .dx = dx };
    } else if (std.mem.eql(u8, name, "get_logs")) {
        try onlyFields(object, &.{ "root", "run", "max_bytes" });
        direct = .{ .method = .get_logs, .number = try optionalToolU32(object, "max_bytes", null, @intCast(max_mcp_text_bytes)) };
    } else if (std.mem.eql(u8, name, "wait_for")) {
        try onlyFields(object, &.{ "root", "run", "element", "terminal_text", "timeout_ms" });
        const timeout = (try optionalToolU32(object, "timeout_ms", default_timeout_ms, 5 * 60 * 1000)).?;
        const element = object.get("element");
        const terminal_text = object.get("terminal_text");
        if ((element == null) == (terminal_text == null)) return error.InvalidMcpParams;
        if (element) |value| {
            if (value != .object) return error.InvalidMcpParams;
            try onlyFields(value.object, &.{ "id", "state", "equals" });
            const state = try requiredToolString(value.object, "state", 16);
            if (!validElementState(state)) return error.InvalidMcpParams;
            const equals_value = value.object.get("equals") orelse return error.InvalidMcpParams;
            if (equals_value != .bool) return error.InvalidMcpParams;
            direct = .{ .method = .wait_element, .first = try requiredToolString(value.object, "id", max_mcp_message_bytes), .second = state, .equals = equals_value.bool, .number = timeout };
        } else {
            const value = terminal_text.?;
            if (value != .object) return error.InvalidMcpParams;
            try onlyFields(value.object, &.{ "contains", "target" });
            direct = .{
                .method = .wait_terminal_text,
                .terminal_target = try optionalTerminalTarget(value.object, "target"),
                .first = try requiredToolString(value.object, "contains", max_mcp_message_bytes),
                .number = timeout,
            };
        }
    } else {
        return error.InvalidMcpParams;
    }
    return .{ .root = root, .run = run, .command = .{ .direct = direct } };
}

const McpEra = enum { legacy, modern };

const ToolOutput = union(enum) {
    text: struct { value: []u8, is_error: bool = false },
    image: struct { path: []u8, png: []u8 },

    fn deinit(self: *ToolOutput, allocator: Allocator) void {
        switch (self.*) {
            .text => |text_output| allocator.free(text_output.value),
            .image => |image_output| {
                allocator.free(image_output.path);
                allocator.free(image_output.png);
            },
        }
        self.* = undefined;
    }
};

fn validRequestId(value: std.json.Value) bool {
    return switch (value) {
        .string => |string| string.len != 0 and string.len <= 1024,
        .integer, .float => true,
        else => false,
    };
}

fn finishMcpMessage(allocating: *std.Io.Writer.Allocating, limit: usize) ![]u8 {
    if (allocating.written().len > limit) return error.MessageTooLarge;
    return allocating.toOwnedSlice();
}

fn writeResponsePrefix(writer: *std.Io.Writer, id: ?std.json.Value) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |request_id| {
        try std.json.Stringify.value(request_id, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
}

fn writeModernResultMetadata(writer: *std.Io.Writer) !void {
    try writer.writeAll(",\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"conduit-test\",\"version\":\"0.1.0\"}}");
}

fn mcpRpcError(
    allocator: Allocator,
    id: ?std.json.Value,
    code: i32,
    message: []const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeResponsePrefix(&output.writer, id);
    try output.writer.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try writeJsonString(&output.writer, message);
    try output.writer.writeAll("}}");
    return finishMcpMessage(&output, max_mcp_text_bytes);
}

fn mcpUnsupportedVersion(allocator: Allocator, id: std.json.Value, requested: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeResponsePrefix(&output.writer, id);
    try output.writer.writeAll(",\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version\",\"data\":{\"supported\":[\"2026-07-28\",\"2025-11-25\"],\"requested\":");
    try writeJsonString(&output.writer, requested);
    try output.writer.writeAll("}}}");
    return finishMcpMessage(&output, max_mcp_text_bytes);
}

fn mcpInitializeResult(allocator: Allocator, id: std.json.Value, version: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeResponsePrefix(&output.writer, id);
    try output.writer.writeAll(",\"result\":{\"protocolVersion\":");
    try writeJsonString(&output.writer, version);
    try output.writer.writeAll(",\"capabilities\":{\"tools\":{\"listChanged\":false}},\"serverInfo\":{\"name\":\"conduit-test\",\"version\":\"0.1.0\"},\"instructions\":\"Launch or explicitly select an isolated run before direct tools. Inspect semantic state, then use screenshot for visual verification.\"}}");
    return finishMcpMessage(&output, max_mcp_text_bytes);
}

fn mcpDiscoverResult(allocator: Allocator, id: std.json.Value) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeResponsePrefix(&output.writer, id);
    try output.writer.writeAll(",\"result\":{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\",\"2025-11-25\"],\"capabilities\":{\"tools\":{\"listChanged\":false}},\"instructions\":\"Pass run on every direct tool; repeat root too when launch used a custom root. Inspect semantic state, then use screenshot for visual verification.\",\"ttlMs\":0,\"cacheScope\":\"private\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"conduit-test\",\"version\":\"0.1.0\"}}}}");
    return finishMcpMessage(&output, max_mcp_text_bytes);
}

fn writeTool(writer: *std.Io.Writer, spec: ToolSpec, era: McpEra) !void {
    try writer.writeAll("{\"name\":");
    try writeJsonString(writer, spec.name);
    try writer.writeAll(",\"description\":");
    try writeJsonString(writer, spec.description);
    try writer.writeAll(",\"inputSchema\":");
    if (era == .modern and !std.mem.eql(u8, spec.name, "launch")) {
        // Clients validate the top-level schema type before looking inside
        // `allOf` (Claude Code 2.1 rejects a tool list whose schema lacks
        // `"type":"object"`), so the wrapper states the type the parts share.
        try writer.writeAll("{\"type\":\"object\",\"allOf\":[");
        try writer.writeAll(spec.input_schema);
        try writer.writeAll(",{\"required\":[\"run\"]}]}");
    } else {
        try writer.writeAll(spec.input_schema);
    }
    try writer.print(",\"annotations\":{{\"readOnlyHint\":{s},\"destructiveHint\":false,\"openWorldHint\":false}}}}", .{if (spec.read_only) "true" else "false"});
}

fn mcpToolsListResult(allocator: Allocator, id: std.json.Value, era: McpEra) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeResponsePrefix(&output.writer, id);
    try output.writer.writeAll(",\"result\":{\"tools\":[");
    for (tool_specs, 0..) |spec, index| {
        if (index != 0) try output.writer.writeByte(',');
        try writeTool(&output.writer, spec, era);
    }
    try output.writer.writeByte(']');
    if (era == .modern) {
        try output.writer.writeAll(",\"ttlMs\":0,\"cacheScope\":\"private\"");
        try writeModernResultMetadata(&output.writer);
    }
    try output.writer.writeAll("}}");
    return finishMcpMessage(&output, max_mcp_text_bytes);
}

fn mcpEmptyResult(allocator: Allocator, id: std.json.Value, era: McpEra) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeResponsePrefix(&output.writer, id);
    try output.writer.writeAll(",\"result\":{");
    if (era == .modern) {
        try output.writer.writeAll("\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"conduit-test\",\"version\":\"0.1.0\"}}");
    }
    try output.writer.writeAll("}}");
    return finishMcpMessage(&output, max_mcp_text_bytes);
}

fn mcpToolTextResult(
    allocator: Allocator,
    id: std.json.Value,
    era: McpEra,
    text_value: []const u8,
    is_error: bool,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeResponsePrefix(&output.writer, id);
    try output.writer.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonString(&output.writer, text_value);
    try output.writer.writeAll("}]");
    if (is_error) try output.writer.writeAll(",\"isError\":true");
    if (era == .modern) try writeModernResultMetadata(&output.writer);
    try output.writer.writeAll("}}");
    return finishMcpMessage(&output, max_mcp_text_output_bytes);
}

fn mcpToolImageResult(
    allocator: Allocator,
    id: std.json.Value,
    era: McpEra,
    path: []const u8,
    png: []const u8,
) ![]u8 {
    if (png.len > max_mcp_screenshot_bytes) return error.MessageTooLarge;
    var output = try std.Io.Writer.Allocating.initCapacity(allocator, std.base64.standard.Encoder.calcSize(png.len) + path.len + 512);
    defer output.deinit();
    try writeResponsePrefix(&output.writer, id);
    try output.writer.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonString(&output.writer, path);
    try output.writer.writeAll("},{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\"");
    try std.base64.standard.Encoder.encodeWriter(&output.writer, png);
    try output.writer.writeAll("\"}]");
    if (era == .modern) try writeModernResultMetadata(&output.writer);
    try output.writer.writeAll("}}");
    const encoded_limit = std.base64.standard.Encoder.calcSize(max_mcp_screenshot_bytes) + 8192;
    return finishMcpMessage(&output, encoded_limit);
}

fn driverFailureText(allocator: Allocator, response: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = max_mcp_text_bytes,
    }) catch return error.InvalidResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const fault = parsed.value.object.get("error") orelse return error.InvalidResponse;
    if (fault != .object) return error.InvalidResponse;
    try onlyFields(fault.object, &.{ "code", "message", "data" });
    const code = fault.object.get("code") orelse return error.InvalidResponse;
    const message = fault.object.get("message") orelse return error.InvalidResponse;
    if (code != .integer or message != .string) return error.InvalidResponse;
    return std.fmt.allocPrint(allocator, "driver {d}: {s}", .{ code.integer, message.string });
}

fn validateScreenshotPath(paths: RunPaths, path: []const u8) CliError![]const u8 {
    if (!std.fs.path.isAbsolute(path)) return error.UnsafeArtifactPath;
    const parent = std.fs.path.dirname(path) orelse return error.UnsafeArtifactPath;
    if (!std.mem.eql(u8, parent, paths.artifacts)) return error.UnsafeArtifactPath;
    const basename = std.fs.path.basename(path);
    const prefix = "screenshot-";
    const suffix = ".png";
    if (!std.mem.startsWith(u8, basename, prefix) or !std.mem.endsWith(u8, basename, suffix)) return error.UnsafeArtifactPath;
    const number = basename[prefix.len .. basename.len - suffix.len];
    if (number.len < 4) return error.UnsafeArtifactPath;
    for (number) |byte| if (!std.ascii.isDigit(byte)) return error.UnsafeArtifactPath;
    return basename;
}

const McpServer = struct {
    allocator: Allocator,
    process_init: ?std.process.Init,
    argv0: []const u8,
    selected_root: ?[]u8 = null,
    selected_run: ?[]u8 = null,
    legacy_initialized: bool = false,

    fn deinit(self: *McpServer) void {
        if (self.selected_root) |root| self.allocator.free(root);
        if (self.selected_run) |run| self.allocator.free(run);
        self.* = undefined;
    }

    fn setSelection(self: *McpServer, root: []const u8, run: []const u8) !void {
        const new_root = try self.allocator.dupe(u8, root);
        errdefer self.allocator.free(new_root);
        const new_run = try self.allocator.dupe(u8, run);
        if (self.selected_root) |old| self.allocator.free(old);
        if (self.selected_run) |old| self.allocator.free(old);
        self.selected_root = new_root;
        self.selected_run = new_run;
    }

    fn resolvedRoot(self: *McpServer, requested: ?[]const u8, era: McpEra, direct: bool) ![]u8 {
        const init = self.process_init orelse return error.InvalidMcpRequest;
        if (requested) |root| return absoluteRoot(init.io, self.allocator, root);
        if (era == .legacy and direct) {
            if (self.selected_root) |root| return self.allocator.dupe(u8, root);
        }
        const unresolved = try defaultRoot(self.allocator, processEnv(init));
        defer self.allocator.free(unresolved);
        return absoluteRoot(init.io, self.allocator, unresolved);
    }

    fn execute(self: *McpServer, invocation: ToolInvocation, era: McpEra) !ToolOutput {
        const init = self.process_init orelse return error.InvalidMcpRequest;
        switch (invocation.command) {
            .launch => |launch| {
                const root = try self.resolvedRoot(invocation.root, era, false);
                defer self.allocator.free(root);
                const run_id = try launchConduit(init, self.argv0, launch, root);
                errdefer self.allocator.free(run_id);
                if (era == .legacy) try self.setSelection(root, run_id);
                return .{ .text = .{ .value = run_id } };
            },
            .direct => |direct| {
                const run_id = invocation.run orelse selected: {
                    if (era != .legacy) return error.MissingSelectedRun;
                    break :selected self.selected_run orelse return error.MissingSelectedRun;
                };
                try validateRunId(run_id);
                const root = try self.resolvedRoot(invocation.root, era, true);
                defer self.allocator.free(root);
                var paths = try deriveRunPaths(self.allocator, root, run_id);
                defer paths.deinit(self.allocator);
                const response = try exchange(self.allocator, paths.endpoint, direct);
                defer self.allocator.free(response);
                const projected = decodeResponse(self.allocator, response, direct.method) catch |err| {
                    if (err == error.DriverError) {
                        const failure = try driverFailureText(self.allocator, response);
                        return .{ .text = .{ .value = failure, .is_error = true } };
                    }
                    return err;
                };
                errdefer self.allocator.free(projected);
                if (projected.len > max_mcp_text_bytes) return error.MessageTooLarge;
                if (era == .legacy and direct.method != .quit) try self.setSelection(root, run_id);
                if (direct.method != .screenshot) return .{ .text = .{ .value = projected } };

                _ = try validateScreenshotPath(paths, projected);
                const png = try Dir.cwd().readFileAlloc(init.io, projected, self.allocator, .limited(max_mcp_screenshot_bytes));
                errdefer self.allocator.free(png);
                if (png.len < 8 or !std.mem.eql(u8, png[0..8], "\x89PNG\r\n\x1a\n")) return error.InvalidScreenshot;
                return .{ .image = .{ .path = projected, .png = png } };
            },
        }
    }
};

fn isSupportedLegacyVersion(version: []const u8) bool {
    for ([_][]const u8{ legacy_mcp_protocol_version, "2025-06-18", "2025-03-26", "2024-11-05" }) |supported| {
        if (std.mem.eql(u8, version, supported)) return true;
    }
    return false;
}

fn paramsObject(value: ?std.json.Value) CliError!std.json.ObjectMap {
    const params = value orelse return error.InvalidMcpParams;
    if (params != .object) return error.InvalidMcpParams;
    return params.object;
}

fn validateModernMeta(params: std.json.ObjectMap) CliError![]const u8 {
    const meta_value = params.get("_meta") orelse return error.InvalidMcpParams;
    if (meta_value != .object) return error.InvalidMcpParams;
    const meta = meta_value.object;
    try onlyFields(meta, &.{
        "io.modelcontextprotocol/protocolVersion",
        "io.modelcontextprotocol/clientCapabilities",
        "io.modelcontextprotocol/clientInfo",
    });
    const version = try requiredToolString(meta, "io.modelcontextprotocol/protocolVersion", 32);
    const capabilities = meta.get("io.modelcontextprotocol/clientCapabilities") orelse return error.InvalidMcpParams;
    if (capabilities != .object) return error.InvalidMcpParams;
    if (meta.get("io.modelcontextprotocol/clientInfo")) |client_info| {
        if (client_info != .object) return error.InvalidMcpParams;
    }
    return version;
}

fn requestEra(params: std.json.ObjectMap) McpEra {
    return if (params.get("_meta") != null) .modern else .legacy;
}

fn handleMcpToolCall(
    server: *McpServer,
    id: std.json.Value,
    params: std.json.ObjectMap,
    era: McpEra,
) ![]u8 {
    if (era == .modern) {
        try onlyFields(params, &.{ "name", "arguments", "_meta" });
    } else {
        try onlyFields(params, &.{ "name", "arguments" });
    }
    const name = try requiredToolString(params, "name", 128);
    if (findTool(name) == null) return mcpRpcError(server.allocator, id, -32602, "Unknown tool");
    const arguments = params.get("arguments") orelse return mcpRpcError(server.allocator, id, -32602, "Missing tool arguments");
    const invocation = parseToolInvocation(name, arguments) catch
        return mcpRpcError(server.allocator, id, -32602, "Invalid tool arguments");
    if (era == .modern) switch (invocation.command) {
        .launch => {},
        .direct => if (invocation.run == null)
            return mcpRpcError(server.allocator, id, -32602, "Modern direct tools require an explicit run"),
    };

    var result = server.execute(invocation, era) catch |err| {
        return mcpToolTextResult(server.allocator, id, era, @errorName(err), true);
    };
    defer result.deinit(server.allocator);
    return switch (result) {
        .text => |text_output| mcpToolTextResult(server.allocator, id, era, text_output.value, text_output.is_error),
        .image => |image_output| mcpToolImageResult(server.allocator, id, era, image_output.path, image_output.png),
    };
}

fn handleMcpMessage(server: *McpServer, message: []const u8) !?[]u8 {
    if (message.len == 0 or message.len > max_mcp_message_bytes) {
        return try mcpRpcError(server.allocator, null, -32700, "Parse error");
    }
    const parsed = std.json.parseFromSlice(std.json.Value, server.allocator, message, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = max_mcp_message_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return try mcpRpcError(server.allocator, null, -32700, "Parse error"),
    };
    defer parsed.deinit();
    if (parsed.value != .object) return try mcpRpcError(server.allocator, null, -32600, "Invalid Request");
    const object = parsed.value.object;
    const id_value = object.get("id");
    const notification = id_value == null;

    // JSON-RPC notifications never receive a response, including malformed
    // or unknown notifications. Only the one lifecycle notification mutates state.
    if (notification) {
        const method = object.get("method") orelse return null;
        if (method != .string) return null;
        if (std.mem.eql(u8, method.string, "notifications/initialized")) validate: {
            onlyFields(object, &.{ "jsonrpc", "method", "params" }) catch break :validate;
            const version = object.get("jsonrpc") orelse break :validate;
            if (version != .string or !std.mem.eql(u8, version.string, "2.0")) break :validate;
            const params = paramsObject(object.get("params")) catch break :validate;
            onlyFields(params, &[_][]const u8{}) catch break :validate;
            server.legacy_initialized = true;
        }
        return null;
    }

    const id = id_value.?;
    if (!validRequestId(id)) return try mcpRpcError(server.allocator, null, -32600, "Invalid Request");
    onlyFields(object, &.{ "jsonrpc", "id", "method", "params" }) catch
        return try mcpRpcError(server.allocator, id, -32600, "Invalid Request");
    const version = object.get("jsonrpc") orelse return try mcpRpcError(server.allocator, id, -32600, "Invalid Request");
    const method = object.get("method") orelse return try mcpRpcError(server.allocator, id, -32600, "Invalid Request");
    if (version != .string or !std.mem.eql(u8, version.string, "2.0") or method != .string or method.string.len == 0 or method.string.len > 128) {
        return try mcpRpcError(server.allocator, id, -32600, "Invalid Request");
    }
    const params_value = object.get("params");

    if (std.mem.eql(u8, method.string, "server/discover")) {
        const params = paramsObject(params_value) catch return try mcpRpcError(server.allocator, id, -32602, "Invalid params");
        onlyFields(params, &.{"_meta"}) catch return try mcpRpcError(server.allocator, id, -32602, "Invalid params");
        const requested = validateModernMeta(params) catch return try mcpRpcError(server.allocator, id, -32602, "Invalid params");
        if (!std.mem.eql(u8, requested, modern_mcp_protocol_version)) return try mcpUnsupportedVersion(server.allocator, id, requested);
        return try mcpDiscoverResult(server.allocator, id);
    }

    if (std.mem.eql(u8, method.string, "initialize")) {
        const params = paramsObject(params_value) catch return try mcpRpcError(server.allocator, id, -32602, "Invalid params");
        onlyFields(params, &.{ "protocolVersion", "capabilities", "clientInfo" }) catch return try mcpRpcError(server.allocator, id, -32602, "Invalid params");
        const requested = requiredToolString(params, "protocolVersion", 32) catch return try mcpRpcError(server.allocator, id, -32602, "Invalid params");
        const capabilities = params.get("capabilities") orelse return try mcpRpcError(server.allocator, id, -32602, "Invalid params");
        const client_info = params.get("clientInfo") orelse return try mcpRpcError(server.allocator, id, -32602, "Invalid params");
        if (capabilities != .object or client_info != .object) return try mcpRpcError(server.allocator, id, -32602, "Invalid params");
        if (!isSupportedLegacyVersion(requested)) return try mcpUnsupportedVersion(server.allocator, id, requested);
        server.legacy_initialized = true;
        return try mcpInitializeResult(server.allocator, id, requested);
    }

    const params = paramsObject(params_value) catch return try mcpRpcError(server.allocator, id, -32602, "Invalid params");
    const era = requestEra(params);
    if (era == .modern) {
        const requested = validateModernMeta(params) catch return try mcpRpcError(server.allocator, id, -32602, "Invalid params");
        if (!std.mem.eql(u8, requested, modern_mcp_protocol_version)) return try mcpUnsupportedVersion(server.allocator, id, requested);
    } else if (!server.legacy_initialized) {
        return try mcpRpcError(server.allocator, id, -32002, "Server not initialized");
    }

    if (std.mem.eql(u8, method.string, "ping")) {
        if (era == .modern) {
            onlyFields(params, &.{"_meta"}) catch return try mcpRpcError(server.allocator, id, -32602, "Invalid params");
        } else {
            onlyFields(params, &[_][]const u8{}) catch return try mcpRpcError(server.allocator, id, -32602, "Invalid params");
        }
        return try mcpEmptyResult(server.allocator, id, era);
    }
    if (std.mem.eql(u8, method.string, "tools/list")) {
        if (era == .modern) {
            onlyFields(params, &.{ "_meta", "cursor" }) catch return try mcpRpcError(server.allocator, id, -32602, "Invalid params");
        } else {
            onlyFields(params, &.{"cursor"}) catch return try mcpRpcError(server.allocator, id, -32602, "Invalid params");
        }
        if (params.get("cursor")) |cursor| if (cursor != .null) return try mcpRpcError(server.allocator, id, -32602, "Pagination is not supported");
        return try mcpToolsListResult(server.allocator, id, era);
    }
    if (std.mem.eql(u8, method.string, "tools/call")) {
        return handleMcpToolCall(server, id, params, era) catch |err| switch (err) {
            error.InvalidMcpParams => try mcpRpcError(server.allocator, id, -32602, "Invalid params"),
            else => return err,
        };
    }
    return try mcpRpcError(server.allocator, id, -32601, "Method not found");
}

fn writeMcpFrame(writer: *std.Io.Writer, message: []const u8) !void {
    try writer.writeAll(message);
    try writer.writeByte('\n');
    try writer.flush();
}

fn runMcp(init: std.process.Init, argv0: []const u8) !void {
    const input_buffer = try init.gpa.alloc(u8, max_mcp_message_bytes + 1);
    defer init.gpa.free(input_buffer);
    var input = File.stdin().readerStreaming(init.io, input_buffer);
    var output_buffer: [16 * 1024]u8 = undefined;
    var output = File.stdout().writerStreaming(init.io, &output_buffer);
    var server: McpServer = .{ .allocator = init.gpa, .process_init = init, .argv0 = argv0 };
    defer server.deinit();

    while (true) {
        const framed = input.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                if (input.interface.bufferedLen() != 0) {
                    const response = try mcpRpcError(init.gpa, null, -32700, "Incomplete frame");
                    defer init.gpa.free(response);
                    try writeMcpFrame(&output.interface, response);
                }
                return;
            },
            error.StreamTooLong => {
                const response = try mcpRpcError(init.gpa, null, -32700, "Message too large");
                defer init.gpa.free(response);
                try writeMcpFrame(&output.interface, response);
                return error.MessageTooLarge;
            },
            error.ReadFailed => return error.InvalidMcpRequest,
        };
        var frame = framed[0 .. framed.len - 1];
        if (frame.len != 0 and frame[frame.len - 1] == '\r') frame = frame[0 .. frame.len - 1];
        const response = try handleMcpMessage(&server, frame) orelse continue;
        defer init.gpa.free(response);
        try writeMcpFrame(&output.interface, response);
    }
}

pub fn main(init: std.process.Init) !void {
    const args = collectArgs(init.arena.allocator(), init.minimal.args) catch |err| {
        writeError("conduit-test: ");
        writeError(@errorName(err));
        writeError("\n");
        std.process.exit(2);
    };
    if (args.len == 2 and std.mem.eql(u8, args[1], "mcp")) {
        runMcp(init, args[0]) catch |err| {
            writeError("conduit-test mcp: ");
            writeError(@errorName(err));
            writeError("\n");
            std.process.exit(2);
        };
        return;
    }
    const json = wantsJson(args);
    runMain(init, args) catch |err| {
        if (json and err != error.DriverError) {
            const rendered = jsonFailure(init.gpa, err) catch {
                writeError("conduit-test: unable to render JSON error\n");
                std.process.exit(2);
            };
            defer init.gpa.free(rendered);
            writeOutput(init.io, rendered) catch {};
        } else {
            writeError("conduit-test: ");
            writeError(@errorName(err));
            writeError("\n");
        }
        std.process.exit(2);
    };
}

const TestEnv = struct {
    run: ?[]const u8 = null,
    root: ?[]const u8 = null,

    fn source(self: *const TestEnv) EnvSource {
        return .{ .context = self, .get_fn = get };
    }

    fn get(context: *const anyopaque, key: []const u8) ?[]const u8 {
        const self: *const TestEnv = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, key, "CONDUIT_TEST_RUN")) return self.run;
        if (std.mem.eql(u8, key, "CONDUIT_TEST_ROOT")) return self.root;
        return null;
    }
};

test "strict parsing covers direct methods launch and environment precedence" {
    const env = TestEnv{ .run = "env-run", .root = "/env/root" };
    const click = try parseArgs(&.{ "conduit-test", "--run=flag-run", "click", "pane.one" }, env.source());
    try std.testing.expectEqualStrings("flag-run", click.run.?);
    try std.testing.expectEqualStrings("/env/root", click.root.?);
    try std.testing.expectEqual(Method.click, click.command.?.direct.method);
    try std.testing.expectEqualStrings("pane.one", click.command.?.direct.first.?);

    const right_click = try parseArgs(&.{ "conduit-test", "--run=flag-run", "right-click", "workspace.1.pane.1" }, env.source());
    try std.testing.expectEqual(Method.right_click, right_click.command.?.direct.method);
    try std.testing.expectEqualStrings("workspace.1.pane.1", right_click.command.?.direct.first.?);
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "conduit-test", "right-click" }, env.source()));

    const scratchpad_text = try parseArgs(&.{ "conduit-test", "--run=flag-run", "terminal-text", "--target", "scratchpad" }, env.source());
    try std.testing.expectEqual(Method.terminal_text, scratchpad_text.command.?.direct.method);
    try std.testing.expectEqual(TerminalTarget.scratchpad, scratchpad_text.command.?.direct.terminal_target);
    const scratchpad_wait = try parseArgs(&.{ "conduit-test", "--run=flag-run", "wait-for", "terminal-text", "READY", "25", "--target=scratchpad" }, env.source());
    try std.testing.expectEqual(Method.wait_terminal_text, scratchpad_wait.command.?.direct.method);
    try std.testing.expectEqual(TerminalTarget.scratchpad, scratchpad_wait.command.?.direct.terminal_target);
    try std.testing.expectEqualStrings("READY", scratchpad_wait.command.?.direct.first.?);
    try std.testing.expectEqual(@as(?u32, 25), scratchpad_wait.command.?.direct.number);

    const legacy_scratchpad_needle = try parseArgs(&.{ "conduit-test", "--run=flag-run", "wait-for", "terminal-text", "scratchpad", "25" }, env.source());
    try std.testing.expectEqual(TerminalTarget.active, legacy_scratchpad_needle.command.?.direct.terminal_target);
    try std.testing.expectEqualStrings("scratchpad", legacy_scratchpad_needle.command.?.direct.first.?);
    try std.testing.expectEqual(@as(?u32, 25), legacy_scratchpad_needle.command.?.direct.number);

    const launch = try parseArgs(&.{ "conduit-test", "--json", "launch", "--width=640", "--height", "360", "--scale=2", "--visible", "--no-child" }, env.source());
    try std.testing.expect(launch.json);
    try std.testing.expectEqual(@as(u32, 640), launch.command.?.launch.width);
    try std.testing.expectEqual(@as(u32, 360), launch.command.?.launch.height);
    try std.testing.expectEqual(@as(f32, 2), launch.command.?.launch.scale);
    try std.testing.expect(launch.command.?.launch.visible);
    try std.testing.expect(launch.command.?.launch.no_child);

    try std.testing.expectError(error.UnknownOption, parseArgs(&.{ "conduit-test", "--bogus", "inspect" }, env.source()));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "conduit-test", "inspect", "extra" }, env.source()));
    try std.testing.expectError(error.InvalidBoolean, parseArgs(&.{ "conduit-test", "wait-for", "element", "x", "exists", "yes" }, env.source()));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "conduit-test", "--run=flag-run", "terminal-text", "scratchpad" }, env.source()));
    try std.testing.expectError(error.InvalidTarget, parseArgs(&.{ "conduit-test", "--run=flag-run", "terminal-text", "--target", "unknown" }, env.source()));
    try std.testing.expectError(error.InvalidTarget, parseArgs(&.{ "conduit-test", "--run=flag-run", "wait-for", "terminal-text", "READY", "25", "--target", "unknown" }, env.source()));
}

test "run ids reject traversal separators controls and unsafe leading bytes" {
    try validateRunId("run-20261006-abc_DEF.9");
    for ([_][]const u8{ "", ".hidden", "../escape", "a/b", "a\\b", "a b", "-dash", "a\x00b" }) |invalid| {
        try std.testing.expectError(error.InvalidRunId, validateRunId(invalid));
    }
}

test "request JSON escapes input and covers every driver method" {
    const cases = [_]struct { direct: Direct, expected: []const u8 }{
        .{ .direct = .{ .method = .inspect }, .expected = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"inspect\",\"params\":{}}" },
        .{ .direct = .{ .method = .click, .first = "a\"b" }, .expected = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"click\",\"params\":{\"id\":\"a\\\"b\"}}" },
        .{ .direct = .{ .method = .ctrl_click, .first = "a" }, .expected = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ctrl_click\",\"params\":{\"id\":\"a\"}}" },
        .{ .direct = .{ .method = .double_click, .first = "a" }, .expected = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"double_click\",\"params\":{\"id\":\"a\"}}" },
        .{ .direct = .{ .method = .right_click, .first = "workspace.1.pane.1" }, .expected = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"right_click\",\"params\":{\"id\":\"workspace.1.pane.1\"}}" },
        .{ .direct = .{ .method = .drag, .first = "a", .second = "b" }, .expected = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"drag\",\"params\":{\"from\":{\"id\":\"a\"},\"to\":{\"id\":\"b\"}}}" },
        .{ .direct = .{ .method = .key, .first = "CTRL+P" }, .expected = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"key\",\"params\":{\"chord\":\"CTRL+P\"}}" },
        .{ .direct = .{ .method = .type, .first = "a\nb" }, .expected = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"type\",\"params\":{\"text\":\"a\\nb\"}}" },
        .{ .direct = .{ .method = .scroll, .dy = -2, .dx = 1 }, .expected = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"scroll\",\"params\":{\"dy\":-2,\"dx\":1}}" },
        .{ .direct = .{ .method = .terminal_text }, .expected = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"terminal_text\",\"params\":{\"target\":\"active\"}}" },
        .{ .direct = .{ .method = .terminal_text, .terminal_target = .scratchpad }, .expected = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"terminal_text\",\"params\":{\"target\":\"scratchpad\"}}" },
        .{ .direct = .{ .method = .wait_element, .first = "x", .second = "focused", .equals = true, .number = 50 }, .expected = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"wait_for\",\"params\":{\"condition\":{\"element\":{\"id\":\"x\",\"state\":\"focused\",\"equals\":true}},\"timeout_ms\":50}}" },
        .{ .direct = .{ .method = .wait_terminal_text, .first = "READY", .number = 60 }, .expected = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"wait_for\",\"params\":{\"condition\":{\"terminal_text\":{\"target\":\"active\",\"contains\":\"READY\"}},\"timeout_ms\":60}}" },
        .{ .direct = .{ .method = .wait_terminal_text, .terminal_target = .scratchpad, .first = "READY", .number = 60 }, .expected = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"wait_for\",\"params\":{\"condition\":{\"terminal_text\":{\"target\":\"scratchpad\",\"contains\":\"READY\"}},\"timeout_ms\":60}}" },
        .{ .direct = .{ .method = .get_logs, .number = 100 }, .expected = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"get_logs\",\"params\":{\"max_bytes\":100}}" },
        .{ .direct = .{ .method = .screenshot }, .expected = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"screenshot\",\"params\":{}}" },
        .{ .direct = .{ .method = .quit }, .expected = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"quit\",\"params\":{}}" },
    };
    for (cases) |case| {
        const request = try buildRequest(std.testing.allocator, case.direct);
        defer std.testing.allocator.free(request);
        try std.testing.expectEqualStrings(case.expected, request);
        try std.testing.expect(std.mem.indexOfScalar(u8, request, '\n') == null);
    }
}

test "response projection detects errors and selects stable plain output" {
    const text = try decodeResponse(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"text\":\"line\\nnext\"}}", .terminal_text);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("line\nnext", text);
    const path = try decodeResponse(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"path\":\"a.png\"}}", .screenshot);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("a.png", path);
    try std.testing.expectError(error.DriverError, decodeResponse(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32004,\"message\":\"not found\"}}", .click));
    try std.testing.expectError(error.InvalidResponse, decodeResponse(std.testing.allocator, "[]", .click));
}

test "local JSON failures are one machine-readable response" {
    const rendered = try jsonFailure(std.testing.allocator, error.InvalidArguments);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32000,\"message\":\"InvalidArguments\"}}\n",
        rendered,
    );
}

test "run paths place all mutable state under one run directory" {
    var paths = try deriveRunPaths(std.testing.allocator, "/tmp/conduit-test", "run-safe_1");
    defer paths.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/tmp/conduit-test/run-safe_1", paths.run_dir);
    try std.testing.expectEqualStrings("/tmp/conduit-test/run-safe_1/home", paths.home);
    try std.testing.expectEqualStrings("/tmp/conduit-test/run-safe_1/tmp", paths.temp);
    try std.testing.expectEqualStrings("/tmp/conduit-test/run-safe_1/artifacts", paths.artifacts);
    if (builtin.os.tag != .windows) try std.testing.expectEqualStrings("/tmp/conduit-test/run-safe_1/driver.sock", paths.endpoint);
}

test "MCP tool list covers every CLI capability with valid strict schemas" {
    const expected = [_][]const u8{
        "launch", "inspect", "click",  "ctrl_click",    "double_click", "right_click", "drag",
        "key",    "type",    "scroll", "terminal_text", "wait_for",     "get_logs",    "screenshot",
        "quit",
    };
    try std.testing.expectEqual(expected.len, tool_specs.len);
    for (tool_specs, expected) |spec, name| {
        try std.testing.expectEqualStrings(name, spec.name);
        const schema = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, spec.input_schema, .{});
        defer schema.deinit();
        try std.testing.expect(schema.value == .object);
        const additional = schema.value.object.get("additionalProperties") orelse return error.TestUnexpectedResult;
        try std.testing.expect(additional == .bool and !additional.bool);
    }

    const listed = try mcpToolsListResult(std.testing.allocator, .{ .string = "tools-1" }, .modern);
    defer std.testing.allocator.free(listed);
    try std.testing.expect(std.mem.indexOfScalar(u8, listed, '\n') == null);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, listed, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("tools-1", parsed.value.object.get("id").?.string);
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("complete", result.get("resultType").?.string);
    try std.testing.expectEqual(expected.len, result.get("tools").?.array.items.len);
    try std.testing.expect(result.get("tools").?.array.items[1].object.get("inputSchema").?.object.get("allOf") != null);
    // Every tool's schema, wrapped or not, must declare the object type at the
    // top level: that is what MCP clients validate first.
    for (result.get("tools").?.array.items) |tool| {
        const schema = tool.object.get("inputSchema").?.object;
        try std.testing.expectEqualStrings("object", schema.get("type").?.string);
    }

    const terminal_spec = findTool("terminal_text") orelse return error.TestUnexpectedResult;
    const terminal_schema = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, terminal_spec.input_schema, .{});
    defer terminal_schema.deinit();
    const target = terminal_schema.value.object.get("properties").?.object.get("target").?.object;
    try std.testing.expectEqualStrings("active", target.get("default").?.string);
    const targets = target.get("enum").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), targets.len);
    try std.testing.expectEqualStrings("active", targets[0].string);
    try std.testing.expectEqualStrings("scratchpad", targets[1].string);
}

test "MCP argument dispatch is strict and maps wait forms" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"root\":\"runs\",\"run\":\"run-1\",\"element\":{\"id\":\"palette.open\",\"state\":\"focused\",\"equals\":true},\"timeout_ms\":25}",
        .{},
    );
    defer parsed.deinit();
    const invocation = try parseToolInvocation("wait_for", parsed.value);
    try std.testing.expectEqualStrings("runs", invocation.root.?);
    try std.testing.expectEqualStrings("run-1", invocation.run.?);
    try std.testing.expectEqual(Method.wait_element, invocation.command.direct.method);
    try std.testing.expectEqualStrings("palette.open", invocation.command.direct.first.?);
    try std.testing.expect(invocation.command.direct.equals);
    try std.testing.expectEqual(@as(?u32, 25), invocation.command.direct.number);

    const scratchpad = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"run\":\"run-1\",\"terminal_text\":{\"target\":\"scratchpad\",\"contains\":\"READY\"}}",
        .{},
    );
    defer scratchpad.deinit();
    const scratchpad_invocation = try parseToolInvocation("wait_for", scratchpad.value);
    try std.testing.expectEqual(Method.wait_terminal_text, scratchpad_invocation.command.direct.method);
    try std.testing.expectEqual(TerminalTarget.scratchpad, scratchpad_invocation.command.direct.terminal_target);
    try std.testing.expectEqualStrings("READY", scratchpad_invocation.command.direct.first.?);

    const right_click = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"run\":\"run-1\",\"id\":\"workspace.1.pane.1\"}",
        .{},
    );
    defer right_click.deinit();
    const right_click_invocation = try parseToolInvocation("right_click", right_click.value);
    try std.testing.expectEqual(Method.right_click, right_click_invocation.command.direct.method);
    try std.testing.expectEqualStrings("workspace.1.pane.1", right_click_invocation.command.direct.first.?);

    const default_target = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"run\":\"run-1\",\"terminal_text\":{\"contains\":\"READY\"}}",
        .{},
    );
    defer default_target.deinit();
    const default_invocation = try parseToolInvocation("wait_for", default_target.value);
    try std.testing.expectEqual(TerminalTarget.active, default_invocation.command.direct.terminal_target);

    const scratchpad_text = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"run\":\"run-1\",\"target\":\"scratchpad\"}",
        .{},
    );
    defer scratchpad_text.deinit();
    const scratchpad_text_invocation = try parseToolInvocation("terminal_text", scratchpad_text.value);
    try std.testing.expectEqual(TerminalTarget.scratchpad, scratchpad_text_invocation.command.direct.terminal_target);

    const unknown_target = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"run\":\"run-1\",\"target\":\"unknown\"}", .{});
    defer unknown_target.deinit();
    try std.testing.expectError(error.InvalidMcpParams, parseToolInvocation("terminal_text", unknown_target.value));
    const unknown_wait_target = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"run\":\"run-1\",\"terminal_text\":{\"target\":\"unknown\",\"contains\":\"READY\"}}",
        .{},
    );
    defer unknown_wait_target.deinit();
    try std.testing.expectError(error.InvalidMcpParams, parseToolInvocation("wait_for", unknown_wait_target.value));

    const unknown = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"run\":\"run-1\",\"extra\":true}", .{});
    defer unknown.deinit();
    try std.testing.expectError(error.InvalidMcpParams, parseToolInvocation("inspect", unknown.value));
    const ambiguous = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"run\":\"run-1\",\"element\":{},\"terminal_text\":{}}", .{});
    defer ambiguous.deinit();
    try std.testing.expectError(error.InvalidMcpParams, parseToolInvocation("wait_for", ambiguous.value));
}

test "MCP supports legacy initialize and current discovery with string ids" {
    var server: McpServer = .{ .allocator = std.testing.allocator, .process_init = null, .argv0 = "conduit-test" };
    defer server.deinit();

    const initialize = (try handleMcpMessage(
        &server,
        "{\"jsonrpc\":\"2.0\",\"id\":\"legacy-a\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1\"}}}",
    )).?;
    defer std.testing.allocator.free(initialize);
    const legacy = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, initialize, .{});
    defer legacy.deinit();
    try std.testing.expectEqualStrings("legacy-a", legacy.value.object.get("id").?.string);
    try std.testing.expectEqualStrings("2025-11-25", legacy.value.object.get("result").?.object.get("protocolVersion").?.string);

    const notification = try handleMcpMessage(&server, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}");
    try std.testing.expect(notification == null);

    const discover = (try handleMcpMessage(
        &server,
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"server/discover\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}",
    )).?;
    defer std.testing.allocator.free(discover);
    const modern = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, discover, .{});
    defer modern.deinit();
    const result = modern.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("complete", result.get("resultType").?.string);
    try std.testing.expectEqual(@as(i64, 0), result.get("ttlMs").?.integer);
    try std.testing.expectEqualStrings("private", result.get("cacheScope").?.string);
}

test "MCP notifications stay silent and malformed calls return JSON-RPC errors" {
    var server: McpServer = .{ .allocator = std.testing.allocator, .process_init = null, .argv0 = "conduit-test", .legacy_initialized = true };
    defer server.deinit();
    try std.testing.expect((try handleMcpMessage(&server, "{\"jsonrpc\":\"2.0\",\"method\":\"unknown\",\"params\":{}}")) == null);

    const malformed = (try handleMcpMessage(&server, "{")).?;
    defer std.testing.allocator.free(malformed);
    const malformed_value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, malformed, .{});
    defer malformed_value.deinit();
    try std.testing.expectEqual(@as(i64, -32700), malformed_value.value.object.get("error").?.object.get("code").?.integer);

    const missing_run = (try handleMcpMessage(
        &server,
        "{\"jsonrpc\":\"2.0\",\"id\":\"m\",\"method\":\"tools/call\",\"params\":{\"name\":\"inspect\",\"arguments\":{},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}",
    )).?;
    defer std.testing.allocator.free(missing_run);
    const missing_value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, missing_run, .{});
    defer missing_value.deinit();
    try std.testing.expectEqual(@as(i64, -32602), missing_value.value.object.get("error").?.object.get("code").?.integer);

    const local_failure = (try handleMcpMessage(
        &server,
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"inspect\",\"arguments\":{\"run\":\"run-1\"}}}",
    )).?;
    defer std.testing.allocator.free(local_failure);
    const failure_value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, local_failure, .{});
    defer failure_value.deinit();
    const failure_result = failure_value.value.object.get("result").?.object;
    try std.testing.expect(failure_result.get("isError").?.bool);
    try std.testing.expectEqualStrings("InvalidMcpRequest", failure_result.get("content").?.array.items[0].object.get("text").?.string);
}

test "MCP screenshot result is raw base64 image content and remains one frame" {
    const rendered = try mcpToolImageResult(
        std.testing.allocator,
        .{ .string = "shot-a" },
        .modern,
        "/tmp/run/artifacts/screenshot-0001.png",
        "\x89PNG\r\n\x1a\n",
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOfScalar(u8, rendered, '\n') == null);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    const image = result.get("content").?.array.items[1].object;
    try std.testing.expectEqualStrings("image", image.get("type").?.string);
    try std.testing.expectEqualStrings("image/png", image.get("mimeType").?.string);
    try std.testing.expectEqualStrings("iVBORw0KGgo=", image.get("data").?.string);
    try std.testing.expect(std.mem.indexOf(u8, image.get("data").?.string, "data:") == null);
}

test "MCP framing appends exactly one delimiter" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeMcpFrame(&writer, "{\"ok\":true}");
    try std.testing.expectEqualStrings("{\"ok\":true}\n", writer.buffered());
}

test "MCP screenshot paths cannot escape the selected artifact directory" {
    var paths = try deriveRunPaths(std.testing.allocator, "/tmp/conduit-test", "run-safe");
    defer paths.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("screenshot-0001.png", try validateScreenshotPath(paths, "/tmp/conduit-test/run-safe/artifacts/screenshot-0001.png"));
    try std.testing.expectError(error.UnsafeArtifactPath, validateScreenshotPath(paths, "/tmp/conduit-test/run-safe/artifacts/../state/screenshot-0001.png"));
    try std.testing.expectError(error.UnsafeArtifactPath, validateScreenshotPath(paths, "/tmp/conduit-test/run-safe/artifacts/not-a-shot.png"));
}
