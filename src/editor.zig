//! The VSCodium editor pane's model (TASK-79, decision-12): detection,
//! launch argv, the per-workspace user-data-dir, path resolution and the
//! per-workspace editor state that decides whether a request opens a new
//! pane or reuses the open one.
//!
//! Nothing here spawns, draws or embeds. Every process and file access goes
//! through a borrowed `workspace.ExecutionContext.Ref` (invariant 5): `detect`
//! and the launch use `run` (bounded, so callers run them on a worker
//! thread), `checkTarget` uses `statPath`, and `seedSettings` writes only
//! inside Conduit's own user-data-dir. VSCodium is detected, never bundled or
//! installed. Remote (SSH, WSL) workspaces are refused with a hint naming the
//! `vi` fallback; the app hosts the editor's native window over the pane
//! through `platform` where the windowing system allows it.
//!
//! Untrusted input: paths come from harnesses and terminals. They are only
//! resolved lexically, checked through the context and passed to VSCodium as
//! single argv items that are always absolute, so none can be read as an
//! option; nothing from an editor or a request is ever executed.
//!
//! Memory: `Detection`, `LaunchSpec` and `Editor` own what they hold and are
//! released with `deinit`. Thread ownership: an `Editor` belongs to the owner
//! (UI) thread; `detect` and `LaunchSpec` runs belong on a worker.

const std = @import("std");
const workspace = @import("workspace");

const Allocator = std.mem.Allocator;
const ContextRef = workspace.ExecutionContext.Ref;

/// The command tried when `editor.command` is empty, or after it fails.
pub const default_command = "codium";
/// Longest path accepted, matching the control API's bound.
pub const max_path_bytes: usize = 4096;
/// Largest one-based line or column passed to `--goto`.
pub const max_position: u32 = 10_000_000;
/// How long `--version` may take before the candidate counts as missing.
pub const detect_timeout_ms: u32 = 5_000;
/// How long the CLI launcher may take to hand off to the editor's main
/// process. The launcher exits once it has; the editor keeps running.
pub const launch_timeout_ms: u32 = 20_000;
/// Longest version line kept from `--version`.
pub const max_version_bytes: usize = 64;

/// What the UI says when VSCodium is not installed. Conduit never installs it.
pub const install_hint = "VSCodium not found: install it from https://vscodium.com or your package manager, " ++
    "or set editor.command to its path";
/// What the UI says in a remote workspace.
pub const remote_hint = "the editor pane runs only in local workspaces; files open in vi here";

/// A one-based position in a file. `column` is meaningful only with `line`.
pub const Location = struct {
    path: []const u8,
    line: ?u32 = null,
    column: ?u32 = null,
};

/// Where a new editor pane goes beside the requesting pane.
pub const Split = enum { right, down };

// ---------------------------------------------------------------------------
// Detection
// ---------------------------------------------------------------------------

/// A VSCodium that answered `--version`. Both strings are owned.
pub const Found = struct {
    /// The argv[0] that answered: `editor.command` or `codium`.
    command: []u8,
    /// The first line of its answer, for example `1.95.3`.
    version: []u8,
};

/// The result of `detect`.
pub const Detection = union(enum) {
    found: Found,
    /// Neither candidate answered: the actions are hidden and requests get
    /// `install_hint`.
    not_installed,
    /// The workspace is remote; the editor pane is refused there.
    remote,

    pub fn deinit(self: *Detection, allocator: Allocator) void {
        switch (self.*) {
            .found => |found| {
                allocator.free(found.command);
                allocator.free(found.version);
            },
            .not_installed, .remote => {},
        }
        self.* = undefined;
    }

    /// The availability this detection gives the editor actions.
    pub fn availability(self: Detection) Availability {
        return switch (self) {
            .found => .installed,
            .not_installed => .not_installed,
            .remote => .remote,
        };
    }
};

/// Whether the editor actions exist in a workspace.
pub const Availability = enum {
    /// Detection has not answered yet.
    unknown,
    installed,
    not_installed,
    remote,
};

/// Ask the workspace's context whether VSCodium is installed: run
/// `<configured> --version` when `configured` is set, then `codium
/// --version`, in `cwd`. Blocks for up to `detect_timeout_ms` per candidate,
/// so call it on a worker thread. Only allocation failure is an error; every
/// other failure means "not this candidate".
pub fn detect(allocator: Allocator, io: std.Io, context: ContextRef, configured: []const u8, cwd: []const u8) Allocator.Error!Detection {
    if (context.kind().isRemote()) return .remote;
    var candidates: [2][]const u8 = undefined;
    var count: usize = 0;
    if (configured.len != 0 and configured[0] != '-') {
        candidates[count] = configured;
        count += 1;
    }
    if (count == 0 or !std.mem.eql(u8, configured, default_command)) {
        candidates[count] = default_command;
        count += 1;
    }
    for (candidates[0..count]) |command| {
        var result = context.run(allocator, io, .{
            .argv = &.{ command, "--version" },
            .cwd = cwd,
            .max_output = 64 * 1024,
            .timeout_ms = detect_timeout_ms,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer result.deinit(allocator);
        if (!result.succeeded()) continue;
        const version = versionLine(result.stdout) orelse continue;
        const owned_command = try allocator.dupe(u8, command);
        errdefer allocator.free(owned_command);
        return .{ .found = .{ .command = owned_command, .version = try allocator.dupe(u8, version) } };
    }
    return .not_installed;
}

/// The first line of a `--version` answer when it looks like a version: it
/// starts with a digit and is short printable ASCII.
fn versionLine(stdout: []const u8) ?[]const u8 {
    const end = std.mem.indexOfScalar(u8, stdout, '\n') orelse stdout.len;
    const line = std.mem.trim(u8, stdout[0..end], " \t\r");
    if (line.len == 0 or line.len > max_version_bytes or !std.ascii.isDigit(line[0])) return null;
    for (line) |byte| if (byte < 0x20 or byte >= 0x7f) return null;
    return line;
}

// ---------------------------------------------------------------------------
// The per-workspace user-data-dir
// ---------------------------------------------------------------------------

/// Hex digits in a workspace's editor id.
pub const id_len = 16;

/// A stable id for a workspace's editor: 16 hex digits of SHA-256 over its
/// name and directory, so the same workspace finds its editor settings and
/// window state again after a restart.
pub fn workspaceId(name: []const u8, directory: []const u8) [id_len]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("conduit-editor\x00");
    hash.update(name);
    hash.update("\x00");
    hash.update(directory);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest[0 .. id_len / 2].*, .lower);
}

/// `<state_dir>/editor/<id>`: Conduit's own `--user-data-dir` for one
/// workspace, so its editor never shares a main process, settings or window
/// state with the user's own VSCodium. `state_dir` is Conduit's state
/// directory in the context's path syntax.
pub fn userDataDir(buffer: []u8, state_dir: []const u8, id: [id_len]u8) error{NoSpaceLeft}![]const u8 {
    const trimmed = std.mem.trimEnd(u8, state_dir, "/");
    return std.fmt.bufPrint(buffer, "{s}/editor/{s}", .{ trimmed, &id });
}

/// The marker the editor's window title carries, which `platform` matches to
/// find the window to host.
pub fn windowMarker(buffer: []u8, id: [id_len]u8) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buffer, "conduit-editor-{s}", .{&id});
}

/// The `User/settings.json` Conduit seeds into a new user-data-dir: a window
/// title carrying `windowMarker`, and no restored windows, so one launch is
/// one window. Written only when the file does not exist yet.
pub fn seedSettingsJson(buffer: []u8, id: [id_len]u8) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buffer,
        \\{{
        \\  "window.title": "${{activeEditorShort}}${{separator}}${{rootName}}${{separator}}conduit-editor-{s}",
        \\  "window.restoreWindows": "none",
        \\  "window.titleBarStyle": "native",
        \\  "update.mode": "none"
        \\}}
        \\
    , .{&id});
}

/// Create `user_data_dir/User/settings.json` from `seedSettingsJson` unless
/// it exists, through the context's write capability. Never overwrites, so
/// an edit made in that editor's own settings stays. Worker thread.
pub fn seedSettings(io: std.Io, context: ContextRef, user_data_dir: []const u8, id: [id_len]u8) workspace.FsError!void {
    var path_buffer: [max_path_bytes]u8 = undefined;
    const user_dir = std.fmt.bufPrint(&path_buffer, "{s}/User", .{user_data_dir}) catch return error.NameTooLong;
    var file_buffer: [max_path_bytes]u8 = undefined;
    const file = std.fmt.bufPrint(&file_buffer, "{s}/settings.json", .{user_dir}) catch return error.NameTooLong;
    if (context.statPath(io, file)) |_| {
        return;
    } else |err| switch (err) {
        error.NotFound => {},
        else => return err,
    }
    try context.makePrivateDir(io, user_dir);
    var json_buffer: [512]u8 = undefined;
    const json = seedSettingsJson(&json_buffer, id) catch unreachable; // fixed text plus a 16-digit id
    try context.writeFile(io, file, json, 0o600);
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

pub const ResolveError = error{
    /// Empty, too long, not UTF-8, a control character, `~`, or a relative
    /// path with no absolute cwd to resolve it against.
    InvalidPath,
    NoSpaceLeft,
};

/// Resolve `path` against `cwd` lexically (`.` and `..` collapse, repeated
/// separators fold) into `buffer`. The result is always absolute, so it can
/// never be read as an option. No file system is touched: the context
/// checks the result with `checkTarget`. `~` is refused because only the
/// context knows its home; harnesses pass absolute or cwd-relative paths.
pub fn resolvePath(buffer: []u8, cwd: ?[]const u8, path: []const u8) ResolveError![]const u8 {
    if (!validText(path) or path[0] == '~') return error.InvalidPath;
    var out: std.ArrayList(u8) = .initBuffer(buffer);
    if (path[0] != '/') {
        const base = cwd orelse return error.InvalidPath;
        if (base.len == 0 or base[0] != '/' or !validText(base)) return error.InvalidPath;
        try appendSegments(&out, base);
    }
    try appendSegments(&out, path);
    if (out.items.len == 0) out.appendBounded('/') catch return error.NoSpaceLeft;
    if (out.items.len > max_path_bytes) return error.InvalidPath;
    return out.items;
}

fn validText(text: []const u8) bool {
    if (text.len == 0 or text.len > max_path_bytes) return false;
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn appendSegments(out: *std.ArrayList(u8), path: []const u8) ResolveError!void {
    var segments = std.mem.tokenizeScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            const slash = std.mem.lastIndexOfScalar(u8, out.items, '/') orelse 0;
            out.shrinkRetainingCapacity(slash);
            continue;
        }
        out.appendBounded('/') catch return error.NoSpaceLeft;
        out.appendSliceBounded(segment) catch return error.NoSpaceLeft;
    }
}

/// What a resolved target must be.
pub const TargetKind = enum {
    /// An existing file, or a new file in an existing directory (`open`).
    file_or_new,
    /// An existing file (`goto`, `diff`).
    file,
    /// Anything that exists (`reveal`).
    existing,
};

pub const TargetError = error{
    NotFound,
    /// A directory where a file was needed, or something that is neither.
    NotAFile,
    /// The context could not answer (a lost connection, permission).
    Unavailable,
};

/// Check a resolved path through the workspace's context. Blocks on IO.
pub fn checkTarget(io: std.Io, context: ContextRef, path: []const u8, kind: TargetKind) TargetError!void {
    const stat = context.statPath(io, path) catch |err| switch (err) {
        error.NotFound => {
            if (kind != .file_or_new) return error.NotFound;
            const parent = std.fs.path.dirnamePosix(path) orelse return error.NotFound;
            const parent_stat = context.statPath(io, parent) catch |parent_err| return switch (parent_err) {
                error.NotFound, error.NotADirectory => error.NotFound,
                else => error.Unavailable,
            };
            if (parent_stat.kind != .directory) return error.NotFound;
            return;
        },
        error.NotADirectory => return error.NotFound,
        else => return error.Unavailable,
    };
    switch (kind) {
        .existing => {},
        .file, .file_or_new => if (stat.kind != .file) return error.NotAFile,
    }
}

/// The `--goto` argument: `path:line:column`, `path:line`, or null when no
/// line was given (the bare path is passed instead).
pub fn gotoArgument(buffer: []u8, location: Location) error{NoSpaceLeft}!?[]const u8 {
    const line = location.line orelse return null;
    if (location.column) |column| return try std.fmt.bufPrint(buffer, "{s}:{d}:{d}", .{ location.path, line, column });
    return try std.fmt.bufPrint(buffer, "{s}:{d}", .{ location.path, line });
}

// ---------------------------------------------------------------------------
// Launching
// ---------------------------------------------------------------------------

/// Whether a launch opens the workspace's editor window or reuses it.
pub const Window = enum { new, reuse };

/// What one launch does, with paths already resolved and checked.
pub const Action = union(enum) {
    open: Location,
    diff: struct { left: []const u8, right: []const u8 },
    reveal: []const u8,
};

/// One VSCodium CLI invocation, run through `ExecutionContext.run` on a
/// worker. Owns its argv in an arena; release with `deinit`.
pub const LaunchSpec = struct {
    arena: std.heap.ArenaAllocator,
    argv: []const []const u8,
    cwd: []const u8,

    pub fn deinit(self: *LaunchSpec) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The bounded run request for the context.
    pub fn runRequest(self: *const LaunchSpec) workspace.RunRequest {
        return .{ .argv = self.argv, .cwd = self.cwd, .max_output = 64 * 1024, .timeout_ms = launch_timeout_ms };
    }
};

/// Build the argv for `action`:
///
/// - open: `<command> --new-window|--reuse-window --user-data-dir <dir>
///   --goto <path>:<line>[:<column>]` (the bare path without a line)
/// - diff: `... --diff <left> <right>`
/// - reveal: `<command> -r --user-data-dir <dir> <path>` (`--new-window`
///   instead of `-r` for a new window), which opens it and lets the
///   explorer's auto-reveal select it.
///
/// `--extensions-dir` is never passed, so the user's own extensions stay in
/// use. Every path must be absolute (from `resolvePath`).
pub fn buildLaunch(
    allocator: Allocator,
    command: []const u8,
    user_data_dir: []const u8,
    cwd: []const u8,
    window: Window,
    action: Action,
) (Allocator.Error || error{InvalidPath})!LaunchSpec {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, try a.dupe(u8, command));
    try argv.append(a, switch (window) {
        .new => "--new-window",
        .reuse => if (action == .reveal) "-r" else "--reuse-window",
    });
    try argv.append(a, "--user-data-dir");
    try argv.append(a, try a.dupe(u8, user_data_dir));
    switch (action) {
        .open => |location| {
            try requireAbsolute(location.path);
            var buffer: [max_path_bytes + 32]u8 = undefined;
            if (gotoArgument(&buffer, location) catch return error.InvalidPath) |goto| {
                try argv.append(a, "--goto");
                try argv.append(a, try a.dupe(u8, goto));
            } else {
                try argv.append(a, try a.dupe(u8, location.path));
            }
        },
        .diff => |diff| {
            try requireAbsolute(diff.left);
            try requireAbsolute(diff.right);
            try argv.append(a, "--diff");
            try argv.append(a, try a.dupe(u8, diff.left));
            try argv.append(a, try a.dupe(u8, diff.right));
        },
        .reveal => |path| {
            try requireAbsolute(path);
            try argv.append(a, try a.dupe(u8, path));
        },
    }
    return .{ .arena = arena, .argv = try argv.toOwnedSlice(a), .cwd = try a.dupe(u8, cwd) };
}

fn requireAbsolute(path: []const u8) error{InvalidPath}!void {
    if (path.len == 0 or path[0] != '/') return error.InvalidPath;
}

// ---------------------------------------------------------------------------
// Per-workspace editor state
// ---------------------------------------------------------------------------

/// A request from the palette, the context menu, the control API or the
/// driver, before path resolution.
pub const Request = union(enum) {
    open: struct { location: Location, split: Split = .right },
    goto: Location,
    diff: struct { left: []const u8, right: []const u8 },
    reveal: []const u8,
    close,

    /// What its resolved target must be, per path.
    pub fn targetKind(self: Request) TargetKind {
        return switch (self) {
            .open => .file_or_new,
            .goto, .diff => .file,
            .reveal, .close => .existing,
        };
    }
};

/// Why a request is refused before anything runs.
pub const Refusal = enum {
    /// Detection has not answered yet; ask again shortly.
    detecting,
    not_installed,
    remote,
};

/// What the owner does with a request.
pub const Plan = union(enum) {
    refuse: Refusal,
    /// Split a new editor pane beside the requesting pane and launch with
    /// `Window.new`.
    new_pane: Split,
    /// Launch into the open editor pane with `Window.reuse`.
    reuse,
    /// A launch is already in flight; the request waits for it.
    wait,
    /// Close the editor pane and ask its window to close.
    close,
    /// `close` with no editor open: nothing to do.
    nothing,
};

/// Where the workspace's one editor pane is in its life.
pub const Status = enum {
    closed,
    /// The pane exists and the first launch is running.
    launching,
    /// The editor window is up: hosted over the pane, or separate where the
    /// platform cannot host it.
    open,
};

/// One workspace's editor pane. At most one per workspace; a second open or
/// goto reuses it. Owner thread only.
pub const Editor = struct {
    allocator: Allocator,
    status: Status = .closed,
    /// The pane presenting the editor, once one exists.
    pane: ?u32 = null,
    /// The editor's process id where the platform reports it (X11
    /// `_NET_WM_PID`), for diagnostics and window matching.
    pid: ?u32 = null,
    /// Whether `platform` hosts its window over the pane (X11) rather than
    /// it being a separate window (Wayland, macOS, Windows for now).
    hosted: bool = false,
    /// The workspace's user-data-dir, owned, set by `noteLaunching`.
    user_data_dir: ?[]u8 = null,
    /// What the editor last showed, owned.
    file: ?[]u8 = null,
    line: ?u32 = null,
    column: ?u32 = null,

    pub fn init(allocator: Allocator) Editor {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Editor) void {
        if (self.user_data_dir) |dir| self.allocator.free(dir);
        if (self.file) |file| self.allocator.free(file);
        self.* = undefined;
    }

    /// Decide what `request` does given the workspace's `availability`.
    pub fn plan(self: *const Editor, availability: Availability, request: Request) Plan {
        if (request == .close) return if (self.status == .closed) .nothing else .close;
        switch (availability) {
            .unknown => return .{ .refuse = .detecting },
            .not_installed => return .{ .refuse = .not_installed },
            .remote => return .{ .refuse = .remote },
            .installed => {},
        }
        return switch (self.status) {
            .closed => .{ .new_pane = switch (request) {
                .open => |open| open.split,
                else => .right,
            } },
            .launching => .wait,
            .open => .reuse,
        };
    }

    /// A new editor pane exists and its first launch has started.
    pub fn noteLaunching(self: *Editor, pane: u32, user_data_dir: []const u8) Allocator.Error!void {
        const dir = try self.allocator.dupe(u8, user_data_dir);
        if (self.user_data_dir) |old| self.allocator.free(old);
        self.user_data_dir = dir;
        self.pane = pane;
        self.status = .launching;
    }

    /// The editor window is up (hosted or separate).
    pub fn noteOpen(self: *Editor, hosted: bool, pid: ?u32) void {
        self.status = .open;
        self.hosted = hosted;
        self.pid = pid;
    }

    /// The editor now shows `location`. Copies the path.
    pub fn noteShowing(self: *Editor, location: Location) Allocator.Error!void {
        const file = try self.allocator.dupe(u8, location.path);
        if (self.file) |old| self.allocator.free(old);
        self.file = file;
        self.line = location.line;
        self.column = location.column;
    }

    /// The pane closed or the editor exited; the next open makes a new pane.
    /// The user-data-dir is kept for the next launch.
    pub fn noteClosed(self: *Editor) void {
        if (self.file) |file| self.allocator.free(file);
        self.file = null;
        self.line = null;
        self.column = null;
        self.pane = null;
        self.pid = null;
        self.hosted = false;
        self.status = .closed;
    }

    /// The pane's status line, for the placeholder shown where the window
    /// is not hosted: `editor ─ main.zig:12:5`, `editor ─ starting…`.
    pub fn statusLine(self: *const Editor, buffer: []u8) []const u8 {
        const text = switch (self.status) {
            .closed => std.fmt.bufPrint(buffer, "editor ─ closed", .{}),
            .launching => std.fmt.bufPrint(buffer, "editor ─ starting…", .{}),
            .open => if (self.file) |file| blk: {
                const name = std.fs.path.basenamePosix(file);
                if (self.line) |line| {
                    if (self.column) |column| break :blk std.fmt.bufPrint(buffer, "editor ─ {s}:{d}:{d}", .{ name, line, column });
                    break :blk std.fmt.bufPrint(buffer, "editor ─ {s}:{d}", .{ name, line });
                }
                break :blk std.fmt.bufPrint(buffer, "editor ─ {s}", .{name});
            } else std.fmt.bufPrint(buffer, "editor ─ open", .{}),
        };
        return text catch buffer[0..0];
    }
};

/// The semantic id phase two registers for an editor pane:
/// `workspace.<k>.pane.<n>.editor`.
pub fn elementId(buffer: []u8, workspace_key: u64, pane: u32) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buffer, "workspace.{d}.pane.{d}.editor", .{ workspace_key, pane });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A context whose `run` answers per argv[0] from a script, and whose
/// `statPath` answers from a fixed file list. Records the last run.
const ScriptedContext = struct {
    remote: bool = false,
    answers: []const Answer = &.{},
    files: []const Entry = &.{},
    runs: usize = 0,
    last_argv0: []const u8 = "",
    last_timeout: u32 = 0,
    written: ?[]const u8 = null,
    write_buffer: [1024]u8 = undefined,
    dirs_made: usize = 0,

    const Answer = struct {
        command: []const u8,
        outcome: union(enum) {
            result: struct { exit_code: ?u8, stdout: []const u8 = "" },
            fail: workspace.RunError,
        },
    };
    const Entry = struct { path: []const u8, kind: workspace.PathKind };

    const vtable: workspace.ExecutionContext.VTable = .{
        .spawn = spawn,
        .kind = kind,
        .destroy = destroy,
        .run = run,
        .stat_path = statPath,
        .write_file = writeFile,
        .make_private_dir = makePrivateDir,
    };

    fn ref(self: *ScriptedContext) ContextRef {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const spawn_fn = @typeInfo(@typeInfo(workspace.ExecutionContext.SpawnFn).pointer.child).@"fn";

    fn spawn(_: *anyopaque, _: spawn_fn.params[1].type.?) spawn_fn.return_type.? {
        return error.SystemError;
    }

    fn kind(ptr: *const anyopaque) workspace.ExecutionContextKind {
        const self: *const ScriptedContext = @ptrCast(@alignCast(ptr));
        return if (self.remote) .ssh else .local;
    }

    fn destroy(_: *anyopaque) void {}

    fn run(ptr: *anyopaque, allocator: Allocator, _: std.Io, request: workspace.RunRequest) workspace.RunError!workspace.RunResult {
        const self: *ScriptedContext = @ptrCast(@alignCast(ptr));
        self.runs += 1;
        self.last_argv0 = request.argv[0];
        self.last_timeout = request.timeout_ms;
        for (self.answers) |answer| {
            if (!std.mem.eql(u8, answer.command, request.argv[0])) continue;
            switch (answer.outcome) {
                .fail => |err| return err,
                .result => |r| {
                    const stdout = try allocator.dupe(u8, r.stdout);
                    errdefer allocator.free(stdout);
                    return .{ .exit_code = r.exit_code, .stdout = stdout, .stderr = try allocator.dupe(u8, "") };
                },
            }
        }
        return error.CommandNotFound;
    }

    fn statPath(ptr: *anyopaque, _: std.Io, path: []const u8) workspace.FsError!workspace.PathStat {
        const self: *ScriptedContext = @ptrCast(@alignCast(ptr));
        for (self.files) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return .{ .kind = entry.kind, .size = 0, .mtime_ns = 0 };
        }
        return error.NotFound;
    }

    fn writeFile(ptr: *anyopaque, _: std.Io, path: []const u8, bytes: []const u8, mode: u32) workspace.FsError!void {
        const self: *ScriptedContext = @ptrCast(@alignCast(ptr));
        if (!std.mem.endsWith(u8, path, "/User/settings.json") or mode != 0o600) return error.AccessDenied;
        @memcpy(self.write_buffer[0..bytes.len], bytes);
        self.written = self.write_buffer[0..bytes.len];
    }

    fn makePrivateDir(ptr: *anyopaque, _: std.Io, _: []const u8) workspace.FsError!void {
        const self: *ScriptedContext = @ptrCast(@alignCast(ptr));
        self.dirs_made += 1;
    }
};

test "detect finds codium through the context and keeps its version line" {
    var context: ScriptedContext = .{ .answers = &.{
        .{ .command = "codium", .outcome = .{ .result = .{ .exit_code = 0, .stdout = "1.95.3\nabc123\nx64\n" } } },
    } };
    var detection = try detect(testing.allocator, testing.io, context.ref(), "", "/home/u");
    defer detection.deinit(testing.allocator);
    try testing.expectEqual(Availability.installed, detection.availability());
    try testing.expectEqualStrings("codium", detection.found.command);
    try testing.expectEqualStrings("1.95.3", detection.found.version);
    try testing.expectEqual(detect_timeout_ms, context.last_timeout);
}

test "a configured editor.command is tried first and codium is the fallback" {
    var configured: ScriptedContext = .{ .answers = &.{
        .{ .command = "/opt/vscodium/codium", .outcome = .{ .result = .{ .exit_code = 0, .stdout = "1.96.0\n" } } },
        .{ .command = "codium", .outcome = .{ .result = .{ .exit_code = 0, .stdout = "1.90.0\n" } } },
    } };
    var first = try detect(testing.allocator, testing.io, configured.ref(), "/opt/vscodium/codium", "/");
    defer first.deinit(testing.allocator);
    try testing.expectEqualStrings("/opt/vscodium/codium", first.found.command);
    try testing.expectEqual(@as(usize, 1), configured.runs);

    var broken: ScriptedContext = .{ .answers = &.{
        .{ .command = "/missing/codium", .outcome = .{ .fail = error.CommandNotFound } },
        .{ .command = "codium", .outcome = .{ .result = .{ .exit_code = 0, .stdout = "1.90.0\n" } } },
    } };
    var fallback = try detect(testing.allocator, testing.io, broken.ref(), "/missing/codium", "/");
    defer fallback.deinit(testing.allocator);
    try testing.expectEqualStrings("codium", fallback.found.command);
    try testing.expectEqual(@as(usize, 2), broken.runs);

    // An option is never run as a command.
    var option: ScriptedContext = .{};
    var refused = try detect(testing.allocator, testing.io, option.ref(), "--help", "/");
    defer refused.deinit(testing.allocator);
    try testing.expectEqualStrings("codium", option.last_argv0);
    try testing.expectEqual(@as(usize, 1), option.runs);
}

test "missing, failing or unrecognisable answers mean not installed, and remote is refused" {
    var missing: ScriptedContext = .{};
    var none = try detect(testing.allocator, testing.io, missing.ref(), "", "/");
    defer none.deinit(testing.allocator);
    try testing.expectEqual(Availability.not_installed, none.availability());

    var failing: ScriptedContext = .{ .answers = &.{
        .{ .command = "codium", .outcome = .{ .result = .{ .exit_code = 1, .stdout = "1.0\n" } } },
    } };
    var failed = try detect(testing.allocator, testing.io, failing.ref(), "", "/");
    defer failed.deinit(testing.allocator);
    try testing.expectEqual(Availability.not_installed, failed.availability());

    var garbage: ScriptedContext = .{ .answers = &.{
        .{ .command = "codium", .outcome = .{ .result = .{ .exit_code = 0, .stdout = "usage: codium\n" } } },
    } };
    var unrecognised = try detect(testing.allocator, testing.io, garbage.ref(), "", "/");
    defer unrecognised.deinit(testing.allocator);
    try testing.expectEqual(Availability.not_installed, unrecognised.availability());

    var timeout: ScriptedContext = .{ .answers = &.{
        .{ .command = "codium", .outcome = .{ .fail = error.Timeout } },
    } };
    var slow = try detect(testing.allocator, testing.io, timeout.ref(), "", "/");
    defer slow.deinit(testing.allocator);
    try testing.expectEqual(Availability.not_installed, slow.availability());

    var remote: ScriptedContext = .{ .remote = true };
    var refused = try detect(testing.allocator, testing.io, remote.ref(), "", "/");
    defer refused.deinit(testing.allocator);
    try testing.expectEqual(Availability.remote, refused.availability());
    try testing.expectEqual(@as(usize, 0), remote.runs);
    try testing.expect(std.mem.indexOf(u8, install_hint, "https://vscodium.com") != null);
}

test "the user-data-dir is per workspace, stable, and under Conduit's state directory" {
    const id = workspaceId("api", "/home/u/api");
    try testing.expectEqualSlices(u8, &id, &workspaceId("api", "/home/u/api"));
    try testing.expect(!std.mem.eql(u8, &id, &workspaceId("api", "/home/u/other")));
    try testing.expect(!std.mem.eql(u8, &id, &workspaceId("web", "/home/u/api")));
    for (id) |c| try testing.expect(std.ascii.isHex(c) and !std.ascii.isUpper(c));

    var buffer: [256]u8 = undefined;
    const dir = try userDataDir(&buffer, "/home/u/.local/state/conduit/", id);
    try testing.expect(std.mem.startsWith(u8, dir, "/home/u/.local/state/conduit/editor/"));
    try testing.expectEqual(@as(usize, "/home/u/.local/state/conduit/editor/".len + id_len), dir.len);
    try testing.expectError(error.NoSpaceLeft, userDataDir(buffer[0..8], "/state", id));

    var marker_buffer: [64]u8 = undefined;
    const marker = try windowMarker(&marker_buffer, id);
    var json_buffer: [512]u8 = undefined;
    const json = try seedSettingsJson(&json_buffer, id);
    try testing.expect(std.mem.indexOf(u8, json, marker) != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("none", parsed.value.object.get("window.restoreWindows").?.string);
}

test "settings are seeded once through the context and never overwritten" {
    const id = workspaceId("w", "/w");
    var fresh: ScriptedContext = .{};
    try seedSettings(testing.io, fresh.ref(), "/s/editor/x", id);
    try testing.expectEqual(@as(usize, 1), fresh.dirs_made);
    try testing.expect(std.mem.indexOf(u8, fresh.written.?, "conduit-editor-") != null);

    var existing: ScriptedContext = .{ .files = &.{.{ .path = "/s/editor/x/User/settings.json", .kind = .file }} };
    try seedSettings(testing.io, existing.ref(), "/s/editor/x", id);
    try testing.expectEqual(@as(?[]const u8, null), existing.written);
    try testing.expectEqual(@as(usize, 0), existing.dirs_made);
}

test "paths resolve lexically against the session cwd and are always absolute" {
    var buffer: [max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("/home/u/src/main.zig", try resolvePath(&buffer, "/home/u", "src/main.zig"));
    try testing.expectEqualStrings("/home/u/main.zig", try resolvePath(&buffer, "/home/u/src/", "./../main.zig"));
    try testing.expectEqualStrings("/etc/hosts", try resolvePath(&buffer, "/home/u", "/etc//hosts"));
    try testing.expectEqualStrings("/", try resolvePath(&buffer, "/home", "../../.."));
    try testing.expectEqualStrings("/home/u/-rf", try resolvePath(&buffer, "/home/u", "-rf"));
    try testing.expectEqualStrings("/home/u/a b; rm -rf", try resolvePath(&buffer, "/home/u", "a b; rm -rf"));
    try testing.expectError(error.InvalidPath, resolvePath(&buffer, null, "relative"));
    try testing.expectError(error.InvalidPath, resolvePath(&buffer, "relative/cwd", "x"));
    try testing.expectError(error.InvalidPath, resolvePath(&buffer, "/home/u", ""));
    try testing.expectError(error.InvalidPath, resolvePath(&buffer, "/home/u", "~/x"));
    try testing.expectError(error.InvalidPath, resolvePath(&buffer, "/home/u", "a\nb"));
    try testing.expectError(error.InvalidPath, resolvePath(&buffer, "/home/u", "a\x00b"));
    try testing.expectError(error.InvalidPath, resolvePath(&buffer, "/home/u", "\xff"));
    try testing.expectError(error.NoSpaceLeft, resolvePath(buffer[0..4], "/home/u", "file"));
}

test "targets are checked through the context" {
    var context: ScriptedContext = .{ .files = &.{
        .{ .path = "/p", .kind = .directory },
        .{ .path = "/p/a.zig", .kind = .file },
        .{ .path = "/p/sub", .kind = .directory },
    } };
    const ref = context.ref();
    try checkTarget(testing.io, ref, "/p/a.zig", .file);
    try checkTarget(testing.io, ref, "/p/new.zig", .file_or_new);
    try checkTarget(testing.io, ref, "/p/sub", .existing);
    try testing.expectError(error.NotFound, checkTarget(testing.io, ref, "/p/new.zig", .file));
    try testing.expectError(error.NotFound, checkTarget(testing.io, ref, "/q/new.zig", .file_or_new));
    try testing.expectError(error.NotFound, checkTarget(testing.io, ref, "/p/a.zig/x", .file_or_new));
    try testing.expectError(error.NotAFile, checkTarget(testing.io, ref, "/p/sub", .file_or_new));
    try testing.expectError(error.NotFound, checkTarget(testing.io, ref, "/p/gone", .existing));
}

test "launch argv opens a new window, reuses it, diffs and reveals with Conduit's user-data-dir" {
    const dir = "/s/editor/0123456789abcdef";
    var open = try buildLaunch(testing.allocator, "codium", dir, "/p", .new, .{ .open = .{ .path = "/p/a.zig", .line = 12, .column = 5 } });
    defer open.deinit();
    try expectArgv(&.{ "codium", "--new-window", "--user-data-dir", dir, "--goto", "/p/a.zig:12:5" }, open.argv);
    try testing.expectEqualStrings("/p", open.runRequest().cwd);
    try testing.expectEqual(launch_timeout_ms, open.runRequest().timeout_ms);

    var goto = try buildLaunch(testing.allocator, "codium", dir, "/p", .reuse, .{ .open = .{ .path = "/p/b.zig", .line = 3 } });
    defer goto.deinit();
    try expectArgv(&.{ "codium", "--reuse-window", "--user-data-dir", dir, "--goto", "/p/b.zig:3" }, goto.argv);

    var bare = try buildLaunch(testing.allocator, "codium", dir, "/p", .reuse, .{ .open = .{ .path = "/p/c:1.zig" } });
    defer bare.deinit();
    try expectArgv(&.{ "codium", "--reuse-window", "--user-data-dir", dir, "/p/c:1.zig" }, bare.argv);

    var diff = try buildLaunch(testing.allocator, "/opt/codium", dir, "/p", .reuse, .{ .diff = .{ .left = "/p/a.orig", .right = "/p/a" } });
    defer diff.deinit();
    try expectArgv(&.{ "/opt/codium", "--reuse-window", "--user-data-dir", dir, "--diff", "/p/a.orig", "/p/a" }, diff.argv);

    var reveal = try buildLaunch(testing.allocator, "codium", dir, "/p", .reuse, .{ .reveal = "/p/sub" });
    defer reveal.deinit();
    try expectArgv(&.{ "codium", "-r", "--user-data-dir", dir, "/p/sub" }, reveal.argv);

    var reveal_new = try buildLaunch(testing.allocator, "codium", dir, "/p", .new, .{ .reveal = "/p/sub" });
    defer reveal_new.deinit();
    try expectArgv(&.{ "codium", "--new-window", "--user-data-dir", dir, "/p/sub" }, reveal_new.argv);

    for (open.argv) |arg| try testing.expect(!std.mem.eql(u8, arg, "--extensions-dir"));
    try testing.expectError(error.InvalidPath, buildLaunch(testing.allocator, "codium", dir, "/p", .new, .{ .open = .{ .path = "-r" } }));
    try testing.expectError(error.InvalidPath, buildLaunch(testing.allocator, "codium", dir, "/p", .new, .{ .diff = .{ .left = "/a", .right = "b" } }));
}

fn expectArgv(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try testing.expectEqualStrings(e, a);
}

test "one editor pane per workspace: the first request splits, later ones reuse it" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();
    const open: Request = .{ .open = .{ .location = .{ .path = "a.zig", .line = 2 }, .split = .down } };
    const goto: Request = .{ .goto = .{ .path = "b.zig", .line = 9 } };

    try testing.expectEqual(Plan{ .refuse = .not_installed }, editor.plan(.not_installed, open));
    try testing.expectEqual(Plan{ .refuse = .remote }, editor.plan(.remote, goto));
    try testing.expectEqual(Plan{ .refuse = .detecting }, editor.plan(.unknown, open));
    try testing.expectEqual(Plan.nothing, editor.plan(.not_installed, .close));
    try testing.expectEqual(Plan{ .new_pane = .down }, editor.plan(.installed, open));
    try testing.expectEqual(Plan{ .new_pane = .right }, editor.plan(.installed, goto));

    try editor.noteLaunching(7, "/s/editor/x");
    try testing.expectEqual(Plan.wait, editor.plan(.installed, goto));
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("editor ─ starting…", editor.statusLine(&buffer));

    editor.noteOpen(true, 4242);
    try editor.noteShowing(.{ .path = "/p/a.zig", .line = 2, .column = 4 });
    try testing.expectEqual(Plan.reuse, editor.plan(.installed, open));
    try testing.expectEqual(Plan.reuse, editor.plan(.installed, goto));
    try testing.expectEqual(Plan.reuse, editor.plan(.installed, .{ .reveal = "x" }));
    try testing.expectEqualStrings("editor ─ a.zig:2:4", editor.statusLine(&buffer));
    try editor.noteShowing(.{ .path = "/p/b.zig", .line = 9 });
    try testing.expectEqualStrings("editor ─ b.zig:9", editor.statusLine(&buffer));
    try testing.expectEqual(@as(?u32, 7), editor.pane);

    try testing.expectEqual(Plan.close, editor.plan(.installed, .close));
    editor.noteClosed();
    try testing.expectEqual(@as(?u32, null), editor.pane);
    try testing.expectEqualStrings("/s/editor/x", editor.user_data_dir.?);
    try testing.expectEqual(Plan{ .new_pane = .right }, editor.plan(.installed, goto));
    try testing.expectEqual(TargetKind.file_or_new, open.targetKind());
    try testing.expectEqual(TargetKind.file, goto.targetKind());

    const id = try elementId(&buffer, 2, 7);
    try testing.expectEqualStrings("workspace.2.pane.7.editor", id);
}
