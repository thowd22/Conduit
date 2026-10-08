//! Standalone scripted E2E runner for TASK-25.
//!
//! The runner launches a fresh isolated Conduit for each declarative scenario,
//! then invokes every step through a separate `conduit-test` process. It never
//! imports application state or bypasses the public driver. Failed live runs
//! are inspected before quit so their semantic tree, application log and a
//! current screenshot remain beside the runner transcript.

const std = @import("std");
const builtin = @import("builtin");
const scenarios = @import("scenarios.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const File = std.Io.File;
const Io = std.Io;
const Writer = std.Io.Writer;

const max_command_output: usize = 4 * 1024 * 1024;
const max_screenshot_bytes: usize = 64 * 1024 * 1024;
const diagnostic_log_bytes = "4194304";
const default_artifact_dir = ".zig-cache/conduit-e2e";
const runner_log_name = "runner.log";
const semantic_tree_name = "semantic-tree.json";
const application_log_name = "application.log";
const screenshot_name = "diagnostic.png";
const screenshot_diagnostic_name = "screenshot-diagnostic.json";
const artifact_manifest_name = "artifacts.json";
const png_signature = "\x89PNG\r\n\x1a\n";
const unix_runtime_root_prefix = "/tmp/conduit-e2e-";
const conservative_unix_endpoint_limit: usize = 104;

const usage =
    \\conduit-e2e — usage
    \\
    \\  conduit-e2e <conduit-test-path> [--artifact-dir=<dir>]
    \\
;

const Options = struct {
    conduit_test: []const u8,
    artifact_dir: []const u8 = default_artifact_dir,
};

const ArtifactAvailability = struct {
    semantic_tree: bool = false,
    application_log: bool = false,
    screenshot: bool = false,
};

const CommandResult = struct {
    allocator: Allocator,
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *CommandResult) void {
        self.allocator.free(self.stderr);
        self.allocator.free(self.stdout);
        self.* = undefined;
    }

    fn passed(self: CommandResult) bool {
        return switch (self.term) {
            .exited => |status| status == 0,
            else => false,
        };
    }
};

fn collectArgs(allocator: Allocator, source: std.process.Args) ![]const []const u8 {
    var iterator = try std.process.Args.Iterator.initAllocator(source, allocator);
    defer iterator.deinit();
    var args: std.ArrayList([]const u8) = .empty;
    while (iterator.next()) |arg| try args.append(allocator, arg);
    return args.items;
}

fn parseArgs(args: []const []const u8) !Options {
    if (args.len < 2) return error.MissingConduitTestPath;
    var options: Options = .{ .conduit_test = args[1] };
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.startsWith(u8, arg, "--artifact-dir=") and arg.len > "--artifact-dir=".len) {
            options.artifact_dir = arg["--artifact-dir=".len..];
        } else if (std.mem.eql(u8, arg, "--artifact-dir")) {
            if (index + 1 >= args.len) return error.MissingArtifactDirectory;
            index += 1;
            options.artifact_dir = args[index];
        } else {
            return error.UnknownArgument;
        }
    }
    if (options.conduit_test.len == 0 or options.artifact_dir.len == 0) return error.EmptyArgument;
    return options;
}

fn privateDirPermissions() File.Permissions {
    return if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
}

fn createPrivateDir(io: Io, path: []const u8) !void {
    try Dir.cwd().createDir(io, path, privateDirPermissions());
}

fn writeFile(io: Io, path: []const u8, bytes: []const u8) !void {
    const permissions: File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
    var file = try Dir.cwd().createFile(io, path, .{ .exclusive = true, .permissions = permissions });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var stream = file.writerStreaming(io, &buffer);
    try stream.interface.writeAll(bytes);
    try stream.interface.flush();
}

fn renderUnavailableDiagnostic(
    allocator: Allocator,
    artifact: []const u8,
    stage: []const u8,
    reason: []const u8,
    driver_ready: bool,
) ![]u8 {
    var output: Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"available\":false,\"artifact\":");
    try std.json.Stringify.value(artifact, .{}, &output.writer);
    try output.writer.writeAll(",\"stage\":");
    try std.json.Stringify.value(stage, .{}, &output.writer);
    try output.writer.writeAll(",\"reason\":");
    try std.json.Stringify.value(reason, .{}, &output.writer);
    try output.writer.print(",\"driver_ready\":{s}}}\n", .{if (driver_ready) "true" else "false"});
    return output.toOwnedSlice();
}

fn writeUnavailableDiagnostic(
    io: Io,
    allocator: Allocator,
    path: []const u8,
    artifact: []const u8,
    stage: []const u8,
    reason: []const u8,
    driver_ready: bool,
) !void {
    const diagnostic = try renderUnavailableDiagnostic(allocator, artifact, stage, reason, driver_ready);
    defer allocator.free(diagnostic);
    try writeFile(io, path, diagnostic);
}

fn renderArtifactManifest(
    allocator: Allocator,
    driver_ready: bool,
    failure_stage: []const u8,
    availability: ArtifactAvailability,
) ![]u8 {
    var output: Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"schema\":1,\"driver_ready\":{s},\"failure_stage\":", .{if (driver_ready) "true" else "false"});
    try std.json.Stringify.value(failure_stage, .{}, &output.writer);
    try output.writer.print(
        ",\"artifacts\":{{\"runner_log\":true,\"application_log\":{s},\"semantic_tree\":{s},\"screenshot\":{s}}}}}\n",
        .{
            if (availability.application_log) "true" else "false",
            if (availability.semantic_tree) "true" else "false",
            if (availability.screenshot) "true" else "false",
        },
    );
    return output.toOwnedSlice();
}

fn writeArtifactManifest(
    io: Io,
    allocator: Allocator,
    scenario_dir: []const u8,
    driver_ready: bool,
    failure_stage: []const u8,
    availability: ArtifactAvailability,
) !void {
    const path = try joined(allocator, &.{ scenario_dir, artifact_manifest_name });
    defer allocator.free(path);
    const manifest = try renderArtifactManifest(allocator, driver_ready, failure_stage, availability);
    defer allocator.free(manifest);
    try writeFile(io, path, manifest);
}

fn joined(allocator: Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(allocator, parts);
}

fn unixRuntimeRootPath(
    allocator: Allocator,
    artifact_root: []const u8,
    nonce: [16]u8,
) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(artifact_root);
    hasher.update(&nonce);
    hasher.final(&digest);
    const short_digest: [16]u8 = digest[0..16].*;
    const hex = std.fmt.bytesToHex(short_digest, .lower);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ unix_runtime_root_prefix, &hex });
}

const RuntimeRoot = struct {
    allocator: Allocator,
    path: []u8,
    is_short: bool,
    archived: bool = false,

    fn finish(self: *RuntimeRoot, io: Io, artifact_root: []const u8) !void {
        if (self.archived) return;
        if (self.is_short) {
            try archiveRuntimeRoot(io, self.allocator, self.path, artifact_root);
        }
        self.archived = true;
    }

    fn deinit(self: *RuntimeRoot, io: Io, artifact_root: []const u8) void {
        if (!self.archived) {
            self.finish(io, artifact_root) catch |err| {
                // Do not delete an unarchived root: retaining it is preferable
                // to losing failure evidence when the requested volume rejects it.
                std.log.scoped(.e2e).warn("could not archive runtime root {s}: {s}", .{ self.path, @errorName(err) });
            };
        }
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

fn copyRuntimeTree(
    io: Io,
    allocator: Allocator,
    source_path: []const u8,
    destination_path: []const u8,
) !void {
    try createPrivateDir(io, destination_path);
    var source = try Dir.cwd().openDir(io, source_path, .{ .iterate = true, .follow_symlinks = false });
    defer source.close(io);
    var destination = try Dir.cwd().openDir(io, destination_path, .{ .follow_symlinks = false });
    defer destination.close(io);
    var walker = try source.walk(allocator);
    defer walker.deinit();
    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => {
            _ = try destination.createDirPathStatus(io, entry.path, privateDirPermissions());
        },
        .file => try source.copyFile(entry.path, destination, entry.path, io, .{
            .replace = false,
            .make_path = true,
        }),
        .sym_link => {
            const length = try source.readLink(io, entry.path, &link_buffer);
            try destination.symLink(io, link_buffer[0..length], entry.path, .{});
        },
        // The local transport may still be unlinking during shutdown. It is
        // ephemeral, cannot be copied, and is never part of diagnostic data.
        .unix_domain_socket, .named_pipe => {},
        else => return error.UnsupportedRuntimeArtifact,
    };
}

fn archiveRuntimeRoot(
    io: Io,
    allocator: Allocator,
    source_path: []const u8,
    destination_path: []const u8,
) !void {
    Dir.renamePreserve(Dir.cwd(), source_path, Dir.cwd(), destination_path, io) catch |err| switch (err) {
        error.CrossDevice, error.OperationUnsupported => {
            try copyRuntimeTree(io, allocator, source_path, destination_path);
            try Dir.cwd().deleteTree(io, source_path);
        },
        else => return err,
    };
}

/// Create a real private short root for Unix socket transport. Scenario data
/// is archived into `artifact_root` after the driver has shut down.
fn prepareRuntimeRoot(
    io: Io,
    allocator: Allocator,
    artifact_root: []const u8,
) !RuntimeRoot {
    if (builtin.os.tag == .windows) {
        try createPrivateDir(io, artifact_root);
        return .{
            .allocator = allocator,
            .path = try allocator.dupe(u8, artifact_root),
            .is_short = false,
        };
    }

    const absolute_artifact_root = if (std.fs.path.isAbsolute(artifact_root))
        try allocator.dupe(u8, artifact_root)
    else blk: {
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);
        break :blk try std.fs.path.resolve(allocator, &.{ cwd, artifact_root });
    };
    defer allocator.free(absolute_artifact_root);

    for (0..16) |_| {
        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        const short_root = try unixRuntimeRootPath(allocator, absolute_artifact_root, nonce);
        errdefer allocator.free(short_root);
        createPrivateDir(io, short_root) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(short_root);
                continue;
            },
            else => return err,
        };
        return .{
            .allocator = allocator,
            .path = short_root,
            .is_short = true,
        };
    }
    return error.RuntimeRootUnavailable;
}

fn suitePath(io: Io, allocator: Allocator, artifact_dir: []const u8) ![]u8 {
    var random: [8]u8 = undefined;
    io.random(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const name = try std.fmt.allocPrint(allocator, "suite-{s}", .{&hex});
    defer allocator.free(name);
    return joined(allocator, &.{ artifact_dir, name });
}

/// The default bound on one `conduit-test` client process, in seconds.
const client_timeout_s: i64 = 15;

/// Time a client needs beyond its own wait: process start, connect and reply.
const client_margin_s: i64 = 5;

/// How long one client process may run. A `wait-for` whose own timeout is
/// close to the default is given that timeout plus a fixed margin,
/// so the driver's bounded wait, not the process kill, decides the outcome.
fn clientTimeoutSeconds(tail: []const []const u8) i64 {
    if (tail.len < 2 or !std.mem.eql(u8, tail[0], "wait-for")) return client_timeout_s;
    const wait_ms = std.fmt.parseInt(u32, tail[tail.len - 1], 10) catch return client_timeout_s;
    const wait_s: i64 = @divTrunc(@as(i64, wait_ms) + 999, 1000);
    return @max(client_timeout_s, wait_s + client_margin_s);
}

fn runCli(
    init: std.process.Init,
    executable: []const u8,
    root: []const u8,
    run_id: ?[]const u8,
    tail: []const []const u8,
) !CommandResult {
    return runCliWithEnv(init, executable, root, run_id, tail, &.{});
}

/// `runCli` with `extra_env` set on top of the runner's own environment, so
/// a `launch` can hand the app (and through it the child) known variables.
fn runCliWithEnv(
    init: std.process.Init,
    executable: []const u8,
    root: []const u8,
    run_id: ?[]const u8,
    tail: []const []const u8,
    extra_env: []const scenarios.EnvVar,
) !CommandResult {
    var environ: ?std.process.Environ.Map = null;
    defer if (environ) |*map| map.deinit();
    if (extra_env.len != 0) {
        environ = try init.environ_map.clone(init.gpa);
        for (extra_env) |variable| try environ.?.put(variable.name, variable.value);
    }

    const root_arg = try std.fmt.allocPrint(init.gpa, "--root={s}", .{root});
    defer init.gpa.free(root_arg);
    const run_arg = if (run_id) |id| try std.fmt.allocPrint(init.gpa, "--run={s}", .{id}) else null;
    defer if (run_arg) |arg| init.gpa.free(arg);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(init.gpa);
    try argv.appendSlice(init.gpa, &.{ executable, root_arg });
    if (run_arg) |arg| try argv.append(init.gpa, arg);
    try argv.appendSlice(init.gpa, tail);

    const result = try std.process.run(init.gpa, init.io, .{
        .argv = argv.items,
        .environ_map = if (environ) |*map| map else null,
        .stdout_limit = .limited(max_command_output),
        .stderr_limit = .limited(max_command_output),
        .timeout = .{ .duration = .{
            .raw = .fromSeconds(clientTimeoutSeconds(tail)),
            .clock = .awake,
        } },
    });
    return .{
        .allocator = init.gpa,
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn writeCommandFailure(log: *Writer, label: []const u8, result: CommandResult) !void {
    try log.print("{s}: command failed ({s})\n", .{ label, @tagName(result.term) });
    const stdout = result.stdout[0..@min(result.stdout.len, 4096)];
    const stderr = result.stderr[0..@min(result.stderr.len, 4096)];
    if (stdout.len != 0) try log.print("stdout:\n{s}\n", .{stdout});
    if (stderr.len != 0) try log.print("stderr:\n{s}\n", .{stderr});
}

fn commandPassed(
    init: std.process.Init,
    executable: []const u8,
    root: []const u8,
    run_id: []const u8,
    tail: []const []const u8,
    label: []const u8,
    log: *Writer,
) !bool {
    var result = runCli(init, executable, root, run_id, tail) catch |err| {
        try log.print("{s}: could not start conduit-test: {s}\n", .{ label, @errorName(err) });
        return false;
    };
    defer result.deinit();
    if (!result.passed()) {
        try writeCommandFailure(log, label, result);
        return false;
    }
    try log.print("{s}: ok\n", .{label});
    return true;
}

/// An unexpected runner-side error must not strand an otherwise live app.
/// Cleanup cannot replace the original scenario result, so transport failure
/// here is deliberately non-fatal.
fn bestEffortQuit(
    init: std.process.Init,
    executable: []const u8,
    root: []const u8,
    run_id: []const u8,
) void {
    var result = runCli(init, executable, root, run_id, &.{"quit"}) catch return;
    result.deinit();
}

const ClickDispatch = struct {
    command: []const u8,
    label: []const u8,
    id: []const u8,
};

fn clickDispatch(step: scenarios.Step) ?ClickDispatch {
    return switch (step) {
        .click => |id| .{ .command = "click", .label = "click", .id = id },
        .ctrl_click => |id| .{ .command = "ctrl-click", .label = "ctrl-click", .id = id },
        .right_click => |id| .{ .command = "right-click", .label = "right-click", .id = id },
        else => null,
    };
}

fn runStep(
    init: std.process.Init,
    executable: []const u8,
    root: []const u8,
    run_id: []const u8,
    step: scenarios.Step,
    log: *Writer,
) !bool {
    var number_buffer: [16]u8 = undefined;
    return switch (step) {
        .inspect => commandPassed(init, executable, root, run_id, &.{"inspect"}, "inspect", log),
        .click, .ctrl_click, .right_click => blk: {
            const dispatch = clickDispatch(step) orelse return error.InvalidClickStep;
            break :blk commandPassed(
                init,
                executable,
                root,
                run_id,
                &.{ dispatch.command, dispatch.id },
                dispatch.label,
                log,
            );
        },
        .key => |chord| commandPassed(init, executable, root, run_id, &.{ "key", chord }, "key", log),
        .type_text => |text| commandPassed(init, executable, root, run_id, &.{ "type", text }, "type", log),
        .wait_element => |wait| blk: {
            const timeout = try std.fmt.bufPrint(&number_buffer, "{d}", .{wait.timeout_ms});
            break :blk commandPassed(init, executable, root, run_id, &.{
                "wait-for", "element", wait.id, wait.state, if (wait.equals) "true" else "false", timeout,
            }, "wait-for element", log);
        },
        .wait_terminal_text => |wait| blk: {
            const timeout = try std.fmt.bufPrint(&number_buffer, "{d}", .{wait.timeout_ms});
            break :blk commandPassed(init, executable, root, run_id, &.{
                "wait-for", "terminal-text", wait.contains, timeout,
            }, "wait-for terminal-text", log);
        },
        .screenshot => commandPassed(init, executable, root, run_id, &.{"screenshot"}, "screenshot", log),
    };
}

fn semanticTreePayloadValid(allocator: Allocator, bytes: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = max_command_output,
    }) catch return false;
    defer parsed.deinit();
    return parsed.value == .object;
}

fn diagnosticCommand(
    init: std.process.Init,
    executable: []const u8,
    root: []const u8,
    run_id: []const u8,
    tail: []const []const u8,
    destination: []const u8,
    artifact: []const u8,
    log: *Writer,
) !bool {
    var result = runCli(init, executable, root, run_id, tail) catch |err| {
        try log.print("diagnostic {s}: {s}\n", .{ destination, @errorName(err) });
        try writeUnavailableDiagnostic(
            init.io,
            init.gpa,
            destination,
            artifact,
            "live-diagnostic",
            @errorName(err),
            true,
        );
        return false;
    };
    defer result.deinit();
    if (result.passed()) {
        if (std.mem.eql(u8, artifact, "semantic-tree") and !semanticTreePayloadValid(init.gpa, result.stdout)) {
            try log.writeAll("diagnostic semantic tree: invalid JSON object\n");
            try writeUnavailableDiagnostic(
                init.io,
                init.gpa,
                destination,
                artifact,
                "live-diagnostic",
                "inspect did not return a JSON object",
                true,
            );
            return false;
        }
        try writeFile(init.io, destination, result.stdout);
        return true;
    } else {
        try writeCommandFailure(log, destination, result);
        try writeUnavailableDiagnostic(
            init.io,
            init.gpa,
            destination,
            artifact,
            "live-diagnostic",
            "diagnostic command failed; see runner.log",
            true,
        );
        return false;
    }
}

fn samePath(left: []const u8, right: []const u8) bool {
    return if (builtin.os.tag == .windows)
        std.ascii.eqlIgnoreCase(left, right)
    else
        std.mem.eql(u8, left, right);
}

fn safeScreenshotPath(expected_dir: []const u8, path: []const u8) bool {
    const parent = std.fs.path.dirname(path) orelse return false;
    if (!samePath(parent, expected_dir)) return false;
    const basename = std.fs.path.basename(path);
    const prefix = "screenshot-";
    const suffix = ".png";
    if (!std.mem.startsWith(u8, basename, prefix) or !std.mem.endsWith(u8, basename, suffix)) return false;
    const number = basename[prefix.len .. basename.len - suffix.len];
    if (number.len < 4) return false;
    for (number) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn collectScreenshot(
    init: std.process.Init,
    executable: []const u8,
    root: []const u8,
    run_id: []const u8,
    scenario_dir: []const u8,
    log: *Writer,
) !bool {
    const diagnostic_path = try joined(init.gpa, &.{ scenario_dir, screenshot_diagnostic_name });
    defer init.gpa.free(diagnostic_path);
    var result = runCli(init, executable, root, run_id, &.{"screenshot"}) catch |err| {
        try log.print("diagnostic screenshot: {s}\n", .{@errorName(err)});
        try writeUnavailableDiagnostic(
            init.io,
            init.gpa,
            diagnostic_path,
            "screenshot",
            "live-diagnostic",
            @errorName(err),
            true,
        );
        return false;
    };
    defer result.deinit();
    if (!result.passed()) {
        try writeCommandFailure(log, "diagnostic screenshot", result);
        try writeUnavailableDiagnostic(
            init.io,
            init.gpa,
            diagnostic_path,
            "screenshot",
            "live-diagnostic",
            "diagnostic command failed; see runner.log",
            true,
        );
        return false;
    }

    const source = std.mem.trim(u8, result.stdout, " \t\r\n");
    const expected_dir = try joined(init.gpa, &.{ root, run_id, "artifacts" });
    defer init.gpa.free(expected_dir);
    if (!safeScreenshotPath(expected_dir, source)) {
        try log.print("diagnostic screenshot: unsafe path returned: {s}\n", .{source});
        try writeUnavailableDiagnostic(
            init.io,
            init.gpa,
            diagnostic_path,
            "screenshot",
            "live-diagnostic",
            "driver returned an unsafe screenshot path",
            true,
        );
        return false;
    }
    const png = Dir.cwd().readFileAlloc(init.io, source, init.gpa, .limited(max_screenshot_bytes)) catch |err| {
        try log.print("diagnostic screenshot: could not read PNG: {s}\n", .{@errorName(err)});
        try writeUnavailableDiagnostic(
            init.io,
            init.gpa,
            diagnostic_path,
            "screenshot",
            "live-diagnostic",
            @errorName(err),
            true,
        );
        return false;
    };
    defer init.gpa.free(png);
    if (!std.mem.startsWith(u8, png, png_signature)) {
        try log.writeAll("diagnostic screenshot: driver artifact is not a PNG\n");
        try writeUnavailableDiagnostic(
            init.io,
            init.gpa,
            diagnostic_path,
            "screenshot",
            "live-diagnostic",
            "driver artifact did not contain a PNG signature",
            true,
        );
        return false;
    }
    const destination = try joined(init.gpa, &.{ scenario_dir, screenshot_name });
    defer init.gpa.free(destination);
    try writeFile(init.io, destination, png);
    try log.print("diagnostic screenshot: copied {s}\n", .{screenshot_name});
    return true;
}

fn collectDiagnostics(
    init: std.process.Init,
    executable: []const u8,
    root: []const u8,
    run_id: []const u8,
    scenario_dir: []const u8,
    log: *Writer,
) !ArtifactAvailability {
    const tree_path = try joined(init.gpa, &.{ scenario_dir, semantic_tree_name });
    defer init.gpa.free(tree_path);
    const semantic_tree = try diagnosticCommand(
        init,
        executable,
        root,
        run_id,
        &.{"inspect"},
        tree_path,
        "semantic-tree",
        log,
    );

    const app_log_path = try joined(init.gpa, &.{ scenario_dir, application_log_name });
    defer init.gpa.free(app_log_path);
    const application_log = try diagnosticCommand(
        init,
        executable,
        root,
        run_id,
        &.{ "logs", diagnostic_log_bytes },
        app_log_path,
        "application-log",
        log,
    );
    const screenshot = try collectScreenshot(init, executable, root, run_id, scenario_dir, log);
    return .{
        .semantic_tree = semantic_tree,
        .application_log = application_log,
        .screenshot = screenshot,
    };
}

fn validRunId(id: []const u8) bool {
    if (id.len == 0 or id.len > 80) return false;
    for (id, 0..) |byte, index| {
        const valid = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-';
        if (!valid or (index == 0 and !std.ascii.isAlphanumeric(byte))) return false;
    }
    return true;
}

fn fileExists(io: Io, path: []const u8) bool {
    Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn writeUnavailableIfMissing(
    io: Io,
    allocator: Allocator,
    path: []const u8,
    artifact: []const u8,
    stage: []const u8,
    reason: []const u8,
    driver_ready: bool,
) !void {
    if (fileExists(io, path)) return;
    try writeUnavailableDiagnostic(io, allocator, path, artifact, stage, reason, driver_ready);
}

fn ensureFailureArtifacts(
    io: Io,
    allocator: Allocator,
    scenario_dir: []const u8,
    driver_ready: bool,
    stage: []const u8,
    reason: []const u8,
    availability: ArtifactAvailability,
) !void {
    const tree_path = try joined(allocator, &.{ scenario_dir, semantic_tree_name });
    defer allocator.free(tree_path);
    try writeUnavailableIfMissing(io, allocator, tree_path, "semantic-tree", stage, reason, driver_ready);

    const app_log_path = try joined(allocator, &.{ scenario_dir, application_log_name });
    defer allocator.free(app_log_path);
    try writeUnavailableIfMissing(io, allocator, app_log_path, "application-log", stage, reason, driver_ready);

    const screenshot_path = try joined(allocator, &.{ scenario_dir, screenshot_name });
    defer allocator.free(screenshot_path);
    const screenshot_diagnostic_path = try joined(allocator, &.{ scenario_dir, screenshot_diagnostic_name });
    defer allocator.free(screenshot_diagnostic_path);
    if (!fileExists(io, screenshot_path)) {
        try writeUnavailableIfMissing(
            io,
            allocator,
            screenshot_diagnostic_path,
            "screenshot",
            stage,
            reason,
            driver_ready,
        );
    }

    try writeArtifactManifest(io, allocator, scenario_dir, driver_ready, stage, availability);
}

fn runScenario(
    init: std.process.Init,
    executable: []const u8,
    suite_dir: []const u8,
    scenario: scenarios.Scenario,
) !bool {
    const scenario_dir = try joined(init.gpa, &.{ suite_dir, scenario.name });
    defer init.gpa.free(scenario_dir);
    try createPrivateDir(init.io, scenario_dir);
    const artifact_root = try joined(init.gpa, &.{ scenario_dir, "run" });
    defer init.gpa.free(artifact_root);
    var runtime_root = try prepareRuntimeRoot(init.io, init.gpa, artifact_root);
    defer runtime_root.deinit(init.io, artifact_root);
    const root = runtime_root.path;

    var log: Writer.Allocating = .init(init.gpa);
    defer log.deinit();
    const log_path = try joined(init.gpa, &.{ scenario_dir, runner_log_name });
    defer init.gpa.free(log_path);

    var width_buffer: [16]u8 = undefined;
    var height_buffer: [16]u8 = undefined;
    var scale_buffer: [32]u8 = undefined;
    const width = try std.fmt.bufPrint(&width_buffer, "--width={d}", .{scenario.width});
    const height = try std.fmt.bufPrint(&height_buffer, "--height={d}", .{scenario.height});
    const scale = try std.fmt.bufPrint(&scale_buffer, "--scale={d}", .{scenario.scale});
    const command = try std.fmt.allocPrint(init.gpa, "--command={s}", .{scenario.command});
    defer init.gpa.free(command);

    var launched = runCliWithEnv(init, executable, root, null, &.{ "launch", width, height, scale, command }, scenario.launch_env) catch |err| {
        try log.writer.print("launch: could not start conduit-test: {s}\n", .{@errorName(err)});
        try ensureFailureArtifacts(
            init.io,
            init.gpa,
            scenario_dir,
            false,
            "launch-command",
            @errorName(err),
            .{},
        );
        try writeFile(init.io, log_path, log.written());
        try runtime_root.finish(init.io, artifact_root);
        return false;
    };
    defer launched.deinit();
    if (!launched.passed()) {
        try writeCommandFailure(&log.writer, "launch", launched);
        try ensureFailureArtifacts(
            init.io,
            init.gpa,
            scenario_dir,
            false,
            "driver-readiness",
            "conduit-test launch failed before returning a ready driver; see runner.log",
            .{},
        );
        try writeFile(init.io, log_path, log.written());
        try runtime_root.finish(init.io, artifact_root);
        return false;
    }
    const run_id = std.mem.trim(u8, launched.stdout, " \t\r\n");
    if (!validRunId(run_id)) {
        try log.writer.writeAll("launch: conduit-test returned an invalid run id\n");
        try ensureFailureArtifacts(
            init.io,
            init.gpa,
            scenario_dir,
            false,
            "launch-response",
            "conduit-test did not return a safe run id",
            .{},
        );
        try writeFile(init.io, log_path, log.written());
        try runtime_root.finish(init.io, artifact_root);
        return false;
    }
    try log.writer.print("launch: {s}\n", .{run_id});
    var quit_attempted = false;
    defer if (!quit_attempted) bestEffortQuit(init, executable, root, run_id);

    var passed = true;
    var failure_stage: []const u8 = "none";
    for (scenario.steps, 0..) |step, index| {
        const step_passed = runStep(init, executable, root, run_id, step, &log.writer) catch |err| blk: {
            try log.writer.print("step {d} ({s}) runner error: {s}\n", .{ index + 1, @tagName(step), @errorName(err) });
            break :blk false;
        };
        if (!step_passed) {
            try log.writer.print("step {d} ({s}) failed\n", .{ index + 1, @tagName(step) });
            passed = false;
            failure_stage = "scenario-step";
            break;
        }
    }
    // Capture a fresh frame before quit on every run. Besides making successful
    // runs independently inspectable, this covers a later quit failure too.
    const availability = collectDiagnostics(init, executable, root, run_id, scenario_dir, &log.writer) catch |err| blk: {
        try log.writer.print("diagnostics: runner error: {s}\n", .{@errorName(err)});
        if (passed) failure_stage = "diagnostics";
        passed = false;
        break :blk ArtifactAvailability{};
    };
    if (!availability.semantic_tree or !availability.application_log or !availability.screenshot) {
        if (passed) failure_stage = "diagnostics";
        passed = false;
    }

    quit_attempted = true;
    if (!try commandPassed(init, executable, root, run_id, &.{"quit"}, "quit", &log.writer)) {
        if (passed) failure_stage = "quit";
        passed = false;
    }
    if (!passed) {
        try ensureFailureArtifacts(
            init.io,
            init.gpa,
            scenario_dir,
            true,
            failure_stage,
            "live diagnostics were unavailable; see runner.log",
            availability,
        );
    }
    try writeFile(init.io, log_path, log.written());
    try runtime_root.finish(init.io, artifact_root);
    return passed;
}

fn renderSummary(allocator: Allocator, results: []const bool) ![]u8 {
    if (results.len != scenarios.all.len) return error.ScenarioResultCountMismatch;
    var output: Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var passed: usize = 0;
    for (results) |result| if (result) {
        passed += 1;
    };
    try output.writer.print("{{\"passed\":{d},\"failed\":{d},\"scenarios\":[", .{ passed, results.len - passed });
    for (results, 0..) |result, index| {
        if (index != 0) try output.writer.writeByte(',');
        try output.writer.writeAll("{\"name\":");
        try std.json.Stringify.value(scenarios.all[index].name, .{}, &output.writer);
        try output.writer.print(",\"passed\":{s}}}", .{if (result) "true" else "false"});
    }
    try output.writer.writeAll("]}\n");
    return output.toOwnedSlice();
}

fn writeSummary(
    io: Io,
    allocator: Allocator,
    suite_dir: []const u8,
    results: []const bool,
) !void {
    const output = try renderSummary(allocator, results);
    defer allocator.free(output);
    const path = try joined(allocator, &.{ suite_dir, "summary.json" });
    defer allocator.free(path);
    try writeFile(io, path, output);
}

fn writeStderr(text: []const u8) void {
    var buffer: [1024]u8 = undefined;
    var stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    stderr.writer.writeAll(text) catch return;
    stderr.writer.flush() catch return;
}

fn runMain(init: std.process.Init, options: Options) !u8 {
    _ = try Dir.cwd().createDirPathStatus(init.io, options.artifact_dir, privateDirPermissions());
    const suite_dir = try suitePath(init.io, init.gpa, options.artifact_dir);
    defer init.gpa.free(suite_dir);
    try createPrivateDir(init.io, suite_dir);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = File.stdout().writerStreaming(init.io, &stdout_buffer);
    try stdout.interface.print("E2E artifacts: {s}\n", .{suite_dir});

    var results: [scenarios.all.len]bool = @splat(false);
    var passed: usize = 0;
    for (scenarios.all, 0..) |scenario, index| {
        // A returned false is a fully reported scenario failure with its
        // artifact contract satisfied. Storage/allocation failures are suite
        // infrastructure errors and must not masquerade as such a report.
        results[index] = try runScenario(init, options.conduit_test, suite_dir, scenario);
        if (results[index]) {
            passed += 1;
            try stdout.interface.print("PASS {s}\n", .{scenario.name});
        } else {
            try stdout.interface.print("FAIL {s}\n", .{scenario.name});
        }
        try stdout.interface.flush();
    }
    try writeSummary(init.io, init.gpa, suite_dir, &results);
    try stdout.interface.print("E2E: {d} passed, {d} failed\n", .{ passed, scenarios.all.len - passed });
    try stdout.interface.flush();
    return if (passed == scenarios.all.len) 0 else 1;
}

/// Run every checked-in scenario and return non-zero after reporting all failures.
pub fn main(init: std.process.Init) !void {
    const args = collectArgs(init.arena.allocator(), init.minimal.args) catch |err| {
        writeStderr("conduit-e2e: argument allocation failed: ");
        writeStderr(@errorName(err));
        writeStderr("\n");
        std.process.exit(2);
    };
    const options = parseArgs(args) catch |err| {
        writeStderr("conduit-e2e: ");
        writeStderr(@errorName(err));
        writeStderr("\n\n");
        writeStderr(usage);
        std.process.exit(2);
    };
    const status = runMain(init, options) catch |err| {
        writeStderr("conduit-e2e: ");
        writeStderr(@errorName(err));
        writeStderr("\n");
        std.process.exit(2);
    };
    if (status != 0) std.process.exit(status);
}

test "run ids accepted from conduit-test cannot escape a scenario root" {
    try std.testing.expect(validRunId("run-0123456789abcdef"));
    try std.testing.expect(!validRunId(""));
    try std.testing.expect(!validRunId("../outside"));
    try std.testing.expect(!validRunId("-leading"));
    try std.testing.expect(!validRunId("run/child"));
}

test "summary reporting is deterministic and names every scenario" {
    const results = [_]bool{ true, false, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true };
    const summary = try renderSummary(std.testing.allocator, &results);
    defer std.testing.allocator.free(summary);
    try std.testing.expectEqualStrings(
        "{\"passed\":19,\"failed\":1,\"scenarios\":[{\"name\":\"launch-prompt\",\"passed\":true},{\"name\":\"type-command\",\"passed\":false},{\"name\":\"select-copy\",\"passed\":true},{\"name\":\"terminal-links\",\"passed\":true},{\"name\":\"terminal-file-reference\",\"passed\":true},{\"name\":\"output-flood\",\"passed\":true},{\"name\":\"context-menu\",\"passed\":true},{\"name\":\"child-environment\",\"passed\":true},{\"name\":\"sidebar-palette\",\"passed\":true},{\"name\":\"font-coverage\",\"passed\":true},{\"name\":\"theme-picker\",\"passed\":true},{\"name\":\"font-picker\",\"passed\":true},{\"name\":\"settings-view\",\"passed\":true},{\"name\":\"sidebar-branch\",\"passed\":true},{\"name\":\"agent-notifications\",\"passed\":true},{\"name\":\"agent-view\",\"passed\":true},{\"name\":\"agent-manager\",\"passed\":true},{\"name\":\"backlog-board\",\"passed\":true},{\"name\":\"control-api\",\"passed\":true},{\"name\":\"agent-prompts\",\"passed\":true}]}\n",
        summary,
    );
}

test "ctrl-click steps dispatch through the conduit-test ctrl-click command" {
    const expected_id = "workspace.1.session.2.terminal-link.0.0.fingerprint.29";
    const dispatch = clickDispatch(.{ .ctrl_click = expected_id }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ctrl-click", dispatch.command);
    try std.testing.expectEqualStrings("ctrl-click", dispatch.label);
    try std.testing.expectEqualStrings(expected_id, dispatch.id);
    try std.testing.expect(clickDispatch(.screenshot) == null);
}

test "right-click steps dispatch through the conduit-test right-click command" {
    const dispatch = clickDispatch(.{ .right_click = "workspace.1.pane.1" }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("right-click", dispatch.command);
    try std.testing.expectEqualStrings("right-click", dispatch.label);
    try std.testing.expectEqualStrings("workspace.1.pane.1", dispatch.id);
}

test "unavailable artifacts carry a machine-readable readiness reason" {
    const diagnostic = try renderUnavailableDiagnostic(
        std.testing.allocator,
        "screenshot",
        "driver-readiness",
        "driver was not ready",
        false,
    );
    defer std.testing.allocator.free(diagnostic);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, diagnostic, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(false, object.get("available").?.bool);
    try std.testing.expectEqualStrings("screenshot", object.get("artifact").?.string);
    try std.testing.expectEqualStrings("driver-readiness", object.get("stage").?.string);
    try std.testing.expectEqualStrings("driver was not ready", object.get("reason").?.string);
    try std.testing.expectEqual(false, object.get("driver_ready").?.bool);
}

test "artifact manifest reports the complete failure contract" {
    const manifest = try renderArtifactManifest(
        std.testing.allocator,
        true,
        "scenario-step",
        .{ .semantic_tree = true, .application_log = true, .screenshot = false },
    );
    defer std.testing.allocator.free(manifest);
    try std.testing.expectEqualStrings(
        "{\"schema\":1,\"driver_ready\":true,\"failure_stage\":\"scenario-step\",\"artifacts\":{\"runner_log\":true,\"application_log\":true,\"semantic_tree\":true,\"screenshot\":false}}\n",
        manifest,
    );
}

test "failure screenshot paths stay inside the isolated run artifacts" {
    const expected = if (builtin.os.tag == .windows)
        "suite\\scenario\\run\\run-1\\artifacts"
    else
        "suite/scenario/run/run-1/artifacts";
    const valid = if (builtin.os.tag == .windows)
        "suite\\scenario\\run\\run-1\\artifacts\\screenshot-0001.png"
    else
        "suite/scenario/run/run-1/artifacts/screenshot-0001.png";
    const escaped = if (builtin.os.tag == .windows)
        "suite\\scenario\\run\\run-1\\state\\screenshot-0001.png"
    else
        "suite/scenario/run/run-1/state/screenshot-0001.png";
    try std.testing.expect(safeScreenshotPath(expected, valid));
    try std.testing.expect(!safeScreenshotPath(expected, escaped));
    try std.testing.expect(!safeScreenshotPath(expected, "screenshot.png"));
}

test "long artifact roots use bounded unique Unix runtime roots" {
    var root_a: [512]u8 = @splat('a');
    root_a[0] = '/';
    var root_b = root_a;
    root_b[root_b.len - 1] = 'b';
    const nonce_a: [16]u8 = @splat(0x11);
    const nonce_b: [16]u8 = @splat(0x22);

    const runtime_a = try unixRuntimeRootPath(std.testing.allocator, &root_a, nonce_a);
    defer std.testing.allocator.free(runtime_a);
    const other_root_runtime = try unixRuntimeRootPath(std.testing.allocator, &root_b, nonce_a);
    defer std.testing.allocator.free(other_root_runtime);
    const other_run_runtime = try unixRuntimeRootPath(std.testing.allocator, &root_a, nonce_b);
    defer std.testing.allocator.free(other_run_runtime);

    try std.testing.expect(std.mem.startsWith(u8, runtime_a, unix_runtime_root_prefix));
    try std.testing.expect(!std.mem.eql(u8, runtime_a, other_root_runtime));
    try std.testing.expect(!std.mem.eql(u8, runtime_a, other_run_runtime));
    try std.testing.expect(std.mem.indexOfScalar(u8, runtime_a, 0) == null);

    const endpoint = try joined(std.testing.allocator, &.{
        runtime_a,
        "run-0123456789abcdef01234567",
        "driver.sock",
    });
    defer std.testing.allocator.free(endpoint);
    try std.testing.expect(endpoint.len < conservative_unix_endpoint_limit);
    try std.testing.expect(endpoint.len < root_a.len);
}

test "cross-device fallback retains runtime data before source cleanup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "runtime/run-1/logs");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "runtime/run-1/logs/conduit.log",
        .data = "retained evidence",
    });
    const root = try tmp.parent_dir.realPathFileAlloc(std.testing.io, &tmp.sub_path, std.testing.allocator);
    defer std.testing.allocator.free(root);
    const source = try joined(std.testing.allocator, &.{ root, "runtime" });
    defer std.testing.allocator.free(source);
    const destination = try joined(std.testing.allocator, &.{ root, "scenario", "run" });
    defer std.testing.allocator.free(destination);
    try tmp.dir.createDirPath(std.testing.io, "scenario");

    try copyRuntimeTree(std.testing.io, std.testing.allocator, source, destination);
    try Dir.cwd().deleteTree(std.testing.io, source);

    const retained = try tmp.dir.readFileAlloc(
        std.testing.io,
        "scenario/run/run-1/logs/conduit.log",
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(retained);
    try std.testing.expectEqualStrings("retained evidence", retained);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "runtime", .{}));
}

test "a long wait-for gets a client timeout longer than its own bound" {
    try std.testing.expectEqual(client_timeout_s, clientTimeoutSeconds(&.{"inspect"}));
    try std.testing.expectEqual(client_timeout_s, clientTimeoutSeconds(&.{ "key", "ENTER" }));
    try std.testing.expectEqual(client_timeout_s, clientTimeoutSeconds(&.{ "wait-for", "terminal-text", "x", "5000" }));
    try std.testing.expectEqual(@as(i64, 25), clientTimeoutSeconds(&.{ "wait-for", "terminal-text", "x", "20000" }));
    try std.testing.expectEqual(client_timeout_s, clientTimeoutSeconds(&.{ "wait-for", "terminal-text", "x", "soon" }));
}
