//! The WSL `ExecutionContext` (TASK-47): every process of a WSL workspace is a
//! Local spawn of Windows' `wsl.exe` launcher that runs inside one installed
//! distribution.
//!
//! - **Distributions.** `listDistributions` reads the per-user registration
//!   list WSL keeps under `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss`
//!   (no process, so a palette can list them on the UI thread), and falls back
//!   to `wsl.exe --list --quiet`, whose UTF-16LE output `parseDistributionList`
//!   decodes. Both answer only names; nothing is started.
//! - **Sessions.** `spawn` runs `wsl.exe -d <distro> --cd ~ -e /bin/sh -c
//!   <script>` under ConPTY. The script is `ssh.sessionScript`: enter the
//!   requested cwd (OSC 7 from the distribution, falling back to its home),
//!   export the crossing part of the request's environment, then exec the
//!   program, or the user's login shell when argv is empty. `--exec` hands the
//!   arguments to the program directly, so no Linux shell reparses the script
//!   and a cwd from OSC 7 (untrusted terminal data) is only ever a quoted word.
//!   `wsl.exe` itself gets `Options.local_env`, the Windows environment.
//! - **Exec channels.** `readFile`, `readFileAt`, `listDir`, `statPath`,
//!   `writeFile`, `makePrivateDir`, `stateDir`, `run` and `watch` run the
//!   same `/bin/sh` helper scripts the SSH context uses (`ssh.zig`) through
//!   `wsl.exe -d <distro> -e /bin/sh -c <script>` over pipes, with no console
//!   window. Their exit codes map onto `FsError` exactly as SSH's do.
//! - **Paths.** The context's paths are the distribution's (`/home/me`). A
//!   Windows spelling (`C:\Users\me\a.txt`, `\\wsl.localhost\<distro>\...`)
//!   from a file reference is translated with `toContextPath`, and back with
//!   `toLocalPath`, by `link.WslPaths`; the drive mount root is learned once
//!   per context from `wslpath` (`learnMountRoot`) and is `/mnt/` until then.
//!
//! Threads: the owner thread creates and destroys the context. `spawn`, the
//! file capabilities, `run` and `learnMountRoot` may be called from any worker
//! holding a `Ref`; they read immutable configuration and block on a local
//! `wsl.exe`, so the render thread must not call them. `toContextPath` and
//! `toLocalPath` never block and may be called from any thread. The context's
//! allocator must be thread-safe.
//!
//! Platforms: WSL exists only on Windows, so `supported` is Windows. The
//! launcher is a parameter, which is how the tests drive the whole context on
//! Linux and on a Windows runner without a distribution: through a stand-in
//! that speaks `wsl.exe`'s command line and runs the command locally.

const std = @import("std");
const builtin = @import("builtin");
const pty = @import("pty");
const link = @import("link");
const workspace = @import("workspace.zig");
const ssh = @import("ssh.zig");

const Allocator = std.mem.Allocator;
const ExecutionContext = workspace.ExecutionContext;
const log = std.log.scoped(.wsl);

/// Whether this build can open WSL workspaces.
pub const supported = builtin.os.tag == .windows;

/// The most distributions listed, and the longest name kept.
pub const max_distributions: usize = 32;
pub const max_name_bytes: usize = 64;

/// Whether `name` can be a distribution name Conduit passes to `wsl.exe -d`:
/// non-empty, at most `max_name_bytes`, printable ASCII without spaces, path
/// separators, quotes or a leading `-` (WSL's own names are letters, digits,
/// `.`, `_` and `-`).
pub fn validDistributionName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes or name[0] == '-') return false;
    for (name) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-')) return false;
    }
    return true;
}

/// Distribution names, in the order WSL lists them.
pub const Distributions = struct {
    names: [max_distributions][max_name_bytes]u8 = undefined,
    lens: [max_distributions]usize = @splat(0),
    count: usize = 0,

    pub fn at(self: *const Distributions, index: usize) []const u8 {
        return self.names[index][0..self.lens[index]];
    }

    /// Add `name` once; an invalid name or a full list is skipped.
    pub fn add(self: *Distributions, name: []const u8) void {
        if (self.count == max_distributions or !validDistributionName(name)) return;
        for (0..self.count) |index| {
            if (std.ascii.eqlIgnoreCase(self.at(index), name)) return;
        }
        @memcpy(self.names[self.count][0..name.len], name);
        self.lens[self.count] = name.len;
        self.count += 1;
    }
};

/// Decode `wsl.exe --list --quiet` output into `out`.
///
/// `wsl.exe` writes its own messages as UTF-16LE (with or without a byte
/// order mark) unless `WSL_UTF8=1` is set, when they are UTF-8; both are
/// accepted. One name per line, CRLF or LF; blank lines and anything that is
/// not a valid distribution name are skipped.
pub fn parseDistributionList(bytes: []const u8, out: *Distributions) void {
    var text_buffer: [4096]u8 = undefined;
    const text = decodeListing(bytes, &text_buffer);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const name = std.mem.trim(u8, line, " \t\r\x00");
        if (name.len != 0) out.add(name);
    }
}

fn decodeListing(bytes: []const u8, buffer: []u8) []const u8 {
    var input = bytes;
    const utf16 = looksUtf16(input);
    if (!utf16) {
        if (std.mem.startsWith(u8, input, "\xef\xbb\xbf")) input = input[3..];
        return input[0..@min(input.len, buffer.len)];
    }
    if (std.mem.startsWith(u8, input, "\xff\xfe")) input = input[2..];
    var length: usize = 0;
    var index: usize = 0;
    while (index + 1 < input.len and length < buffer.len) : (index += 2) {
        const unit = std.mem.readInt(u16, input[index..][0..2], .little);
        // Names are ASCII; anything else becomes a byte no valid name contains.
        buffer[length] = if (unit < 0x80) @intCast(unit) else 0x7f;
        length += 1;
    }
    return buffer[0..length];
}

fn looksUtf16(bytes: []const u8) bool {
    if (std.mem.startsWith(u8, bytes, "\xff\xfe")) return true;
    // ASCII text in UTF-16LE has a zero in every odd byte.
    if (bytes.len < 2) return false;
    var zeros: usize = 0;
    var index: usize = 1;
    while (index < bytes.len) : (index += 2) {
        if (bytes[index] == 0) zeros += 1;
    }
    return zeros * 2 >= bytes.len / 2;
}

/// The distributions installed for this Windows user, read from the registry
/// (`HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss\{guid}\DistributionName`).
/// Never blocks on a process. Windows only; elsewhere the list is empty.
pub fn listRegisteredDistributions(out: *Distributions) void {
    if (builtin.os.tag != .windows) return;
    registry.list(out);
}

/// The distributions WSL reports: the registry first, else `<program> --list
/// --quiet` (which blocks on a process, so call it from a worker).
pub fn listDistributions(allocator: Allocator, io: std.Io, program: []const u8, prefix: []const []const u8, out: *Distributions) void {
    listRegisteredDistributions(out);
    if (out.count != 0) return;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    argv.append(allocator, program) catch return;
    argv.appendSlice(allocator, prefix) catch return;
    argv.appendSlice(allocator, &.{ "--list", "--quiet" }) catch return;
    var result = workspace.runLocalProcess(allocator, io, .{ .argv = argv.items, .cwd = "", .max_output = 64 * 1024, .timeout_ms = 15_000 }) catch |err| {
        log.debug("wsl --list: {s}", .{@errorName(err)});
        return;
    };
    defer result.deinit(allocator);
    if (!result.succeeded()) return;
    parseDistributionList(result.stdout, out);
}

const registry = if (builtin.os.tag == .windows) struct {
    const HKEY = *opaque {};
    const hkey_current_user: HKEY = @ptrFromInt(0x80000001);
    const key_read: u32 = 0x20019;
    const rrf_rt_reg_sz: u32 = 0x00000002;

    extern "advapi32" fn RegOpenKeyExW(key: HKEY, sub_key: [*:0]const u16, options: u32, sam: u32, result: *?HKEY) callconv(.winapi) i32;
    extern "advapi32" fn RegEnumKeyExW(key: HKEY, index: u32, name: [*]u16, name_len: *u32, reserved: ?*u32, class: ?[*]u16, class_len: ?*u32, last_write: ?*anyopaque) callconv(.winapi) i32;
    extern "advapi32" fn RegGetValueW(key: HKEY, sub_key: ?[*:0]const u16, value: [*:0]const u16, flags: u32, kind: ?*u32, data: ?*anyopaque, data_len: ?*u32) callconv(.winapi) i32;
    extern "advapi32" fn RegCloseKey(key: HKEY) callconv(.winapi) i32;

    fn list(out: *Distributions) void {
        var lxss: ?HKEY = null;
        const path = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Lxss");
        if (RegOpenKeyExW(hkey_current_user, path, 0, key_read, &lxss) != 0) return;
        const key = lxss orelse return;
        defer _ = RegCloseKey(key);
        var index: u32 = 0;
        while (index < 256) : (index += 1) {
            var sub: [128:0]u16 = undefined;
            var sub_len: u32 = sub.len;
            if (RegEnumKeyExW(key, index, &sub, &sub_len, null, null, null, null) != 0) return;
            sub[sub_len] = 0;
            var value: [max_name_bytes + 1]u16 = undefined;
            var value_bytes: u32 = @sizeOf(@TypeOf(value));
            const name_value = std.unicode.utf8ToUtf16LeStringLiteral("DistributionName");
            if (RegGetValueW(key, sub[0..sub_len :0], name_value, rrf_rt_reg_sz, null, &value, &value_bytes) != 0) continue;
            const units = std.mem.sliceTo(value[0 .. value_bytes / 2], 0);
            var name: [max_name_bytes]u8 = undefined;
            if (units.len > name.len) continue;
            var ascii = true;
            for (units, 0..) |unit, at| {
                if (unit >= 0x80) ascii = false else name[at] = @intCast(unit);
            }
            if (ascii) out.add(name[0..units.len]);
        }
    }
} else struct {};

/// What a WSL workspace is created with. Every slice is copied.
pub const Options = struct {
    /// The distribution, as `listDistributions` names it.
    distribution: []const u8,
    /// The launcher: `wsl.exe`, resolved on `local_env`'s PATH. Tests name a
    /// stand-in.
    program: []const u8 = "wsl.exe",
    /// Arguments placed between the launcher and Conduit's own, for a
    /// stand-in that is a script run by an interpreter. Empty for `wsl.exe`.
    program_prefix: []const []const u8 = &.{},
    /// The launcher's own environment (`KEY=VALUE`): this machine's, because
    /// `wsl.exe` is a Windows process. The distribution's processes get only
    /// the crossing part of each request's environment.
    local_env: []const []const u8,
};

pub const CreateError = Allocator.Error || error{InvalidDistribution};

/// A WSL workspace's execution context. See the module documentation.
pub const WslContext = struct {
    allocator: Allocator,
    distribution: []u8,
    program: []u8,
    prefix: [][]u8,
    local_env: [][]u8,
    /// The learned drive mount root, ending in `/`; `/mnt/` until learned.
    mount_root: [64]u8 = undefined,
    mount_root_len: std.atomic.Value(usize) = .init(0),
    mount_lock: std.Io.Mutex = .init,

    const vtable: ExecutionContext.VTable = .{
        .spawn = spawnFn,
        .kind = kindFn,
        .destroy = destroyFn,
        .read_file = readFileFn,
        .list_dir = listDirFn,
        .stat_path = statPathFn,
        .watch = watchFn,
        .run = runFn,
        .read_file_at = readFileAtFn,
        .write_file = writeFileFn,
        .make_private_dir = makePrivateDirFn,
        .state_dir = stateDirFn,
    };

    /// Create an owned context of kind `.wsl`. Nothing is started: the
    /// distribution boots on its first spawn or exec, as `wsl.exe` does.
    pub fn create(allocator: Allocator, options: Options) CreateError!ExecutionContext {
        if (!validDistributionName(options.distribution)) return error.InvalidDistribution;
        const self = try allocator.create(WslContext);
        errdefer allocator.destroy(self);
        const distribution = try allocator.dupe(u8, options.distribution);
        errdefer allocator.free(distribution);
        const program = try allocator.dupe(u8, options.program);
        errdefer allocator.free(program);
        const prefix = try dupeList(allocator, options.program_prefix);
        errdefer freeList(allocator, prefix);
        const local_env = try dupeList(allocator, options.local_env);
        errdefer freeList(allocator, local_env);
        self.* = .{
            .allocator = allocator,
            .distribution = distribution,
            .program = program,
            .prefix = prefix,
            .local_env = local_env,
        };
        return ExecutionContext.initOwned(self, &vtable);
    }

    /// The concrete context behind an owned WSL context, or null for any
    /// other kind.
    pub fn fromContext(context: *const ExecutionContext) ?*WslContext {
        return fromRef(context.borrow());
    }

    /// The concrete context behind a borrowed WSL context, or null.
    pub fn fromRef(ref: ExecutionContext.Ref) ?*WslContext {
        if (ref.vtable != &vtable) return null;
        return @ptrCast(@alignCast(ref.ptr));
    }

    /// The distribution this workspace runs in.
    pub fn distributionName(self: *const WslContext) []const u8 {
        return self.distribution;
    }

    /// The path translation in force: the distribution and its mount root.
    pub fn paths(self: *const WslContext) link.WslPaths {
        const length = self.mount_root_len.load(.acquire);
        return .{
            .distribution = self.distribution,
            .mount_root = if (length == 0) "/mnt/" else self.mount_root[0..length],
        };
    }

    /// A file reference spelled the Windows way, as this distribution sees
    /// it (`C:\x` is `/mnt/c/x`); a path already in the distribution's syntax
    /// is returned unchanged. Null when there is no translation. Never blocks.
    pub fn toContextPath(self: *const WslContext, path: []const u8, buffer: []u8) ?[]const u8 {
        if (!link.isWindowsPath(path)) return path;
        return self.paths().toWsl(path, buffer);
    }

    /// A distribution path as Windows sees it (`/mnt/c/x` is `C:\x`, `/home/me`
    /// is `\\wsl.localhost\<distro>\home\me`). Never blocks.
    pub fn toLocalPath(self: *const WslContext, path: []const u8, buffer: []u8) ?[]const u8 {
        return self.paths().toWindows(path, buffer);
    }

    /// Ask the distribution's `wslpath` where it mounts drive C once, and use
    /// its root for every later translation. Blocks on an exec: call it from
    /// a worker. Keeps `/mnt/` when `wslpath` is missing or answers oddly.
    pub fn learnMountRoot(self: *WslContext, io: std.Io) void {
        if (self.mount_root_len.load(.acquire) != 0) return;
        var result = self.runArgv(self.allocator, io, &.{ "wslpath", "-u", "C:\\" }, "", 4096, 15_000) catch |err| {
            log.debug("wslpath: {s}", .{@errorName(err)});
            return;
        };
        defer result.deinit(self.allocator);
        if (!result.succeeded()) return;
        const root = mountRootFromWslpath(result.stdout) orelse return;
        if (root.len > self.mount_root.len) return;
        self.mount_lock.lockUncancelable(io);
        defer self.mount_lock.unlock(io);
        if (self.mount_root_len.load(.acquire) != 0) return;
        @memcpy(self.mount_root[0..root.len], root);
        self.mount_root_len.store(root.len, .release);
        log.info("wsl {s}: drives are mounted under {s}", .{ self.distribution, root });
    }

    fn fromPtr(ptr: *anyopaque) *WslContext {
        return @ptrCast(@alignCast(ptr));
    }

    /// `<program> <prefix...> -d <distro> --cd ~ -e /bin/sh -c <script>`.
    fn launchArgv(self: *const WslContext, arena: Allocator, script: []const u8) Allocator.Error![]const []const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, self.program);
        for (self.prefix) |arg| try argv.append(arena, arg);
        try argv.appendSlice(arena, &.{ "-d", self.distribution, "--cd", "~", "-e", "/bin/sh", "-c", script });
        return argv.items;
    }

    fn spawnFn(ptr: *anyopaque, request: pty.SpawnRequest) pty.Error!pty.Pty {
        return fromPtr(ptr).spawnSession(request);
    }

    /// Start one interactive session in the distribution under ConPTY.
    /// `request.argv` is the program (empty: the user's login shell),
    /// `request.cwd` a distribution directory (empty: the home directory),
    /// `request.env` the overlay whose crossing entries are exported there.
    pub fn spawnSession(self: *WslContext, request: pty.SpawnRequest) pty.Error!pty.Pty {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const script = ssh.sessionScript(arena, request.cwd, request.env, request.argv) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.EmbeddedNul => error.EmbeddedNul,
        };
        const argv = try self.launchArgv(arena, script);
        return pty.spawn(self.allocator, .{
            .argv = argv,
            .env = @ptrCast(self.local_env),
            .cwd = "",
            .size = request.size,
        });
    }

    fn kindFn(_: *const anyopaque) workspace.ExecutionContextKind {
        return .wsl;
    }

    fn destroyFn(ptr: *anyopaque) void {
        const self = fromPtr(ptr);
        const allocator = self.allocator;
        allocator.free(self.distribution);
        allocator.free(self.program);
        freeList(allocator, self.prefix);
        freeList(allocator, self.local_env);
        allocator.destroy(self);
    }

    /// Run one `/bin/sh` script in the distribution over pipes.
    fn runScript(
        self: *WslContext,
        allocator: Allocator,
        io: std.Io,
        script: []const u8,
        stdin: ?[]const u8,
        max_output: usize,
        timeout_ms: u32,
    ) workspace.RunError!workspace.RunResult {
        if (std.mem.indexOfScalar(u8, script, 0) != null) return error.InvalidRequest;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const argv = try self.launchArgv(arena_state.allocator(), script);
        return workspace.runLocalProcess(allocator, io, .{
            .argv = argv,
            .cwd = "",
            .stdin = stdin,
            .max_output = max_output,
            .timeout_ms = timeout_ms,
        }) catch |err| return switch (err) {
            // The launcher itself is missing or unusable.
            error.CommandNotFound, error.AccessDenied, error.SpawnFailed => error.Unavailable,
            else => |other| other,
        };
    }

    fn runArgv(self: *WslContext, allocator: Allocator, io: std.Io, argv: []const []const u8, cwd: []const u8, max_output: usize, timeout_ms: u32) workspace.RunError!workspace.RunResult {
        const script = ssh.execScript(self.allocator, cwd, argv) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.EmbeddedNul => error.InvalidRequest,
        };
        defer self.allocator.free(script);
        return self.runScript(allocator, io, script, null, max_output, timeout_ms);
    }

    /// Run one file helper script and map a non-zero exit onto `FsError`.
    fn runHelper(self: *WslContext, io: std.Io, script: []const u8, stdin: ?[]const u8, max_output: usize) workspace.FsError!workspace.RunResult {
        var result = self.runScript(self.allocator, io, script, stdin, max_output, 30_000) catch |err| return fsFromRun(err);
        if (!result.succeeded()) {
            const err = helperError(result.exit_code);
            result.deinit(self.allocator);
            return err;
        }
        return result;
    }

    fn readFileFn(ptr: *anyopaque, io: std.Io, path: []const u8, buffer: []u8) workspace.FsError![]u8 {
        const self = fromPtr(ptr);
        const script = ssh.readFileScript(self.allocator, path, buffer.len + 1) catch |err| return quoteFs(err);
        defer self.allocator.free(script);
        var result = try self.runHelper(io, script, null, buffer.len + 1);
        defer result.deinit(self.allocator);
        if (result.stdout.len > buffer.len) return error.TooLarge;
        @memcpy(buffer[0..result.stdout.len], result.stdout);
        return buffer[0..result.stdout.len];
    }

    const max_listing_bytes = 1024 * 1024;

    fn listDirFn(ptr: *anyopaque, io: std.Io, path: []const u8, visitor: workspace.DirVisitor) workspace.FsError!void {
        const self = fromPtr(ptr);
        const script = ssh.listDirScript(self.allocator, path) catch |err| return quoteFs(err);
        defer self.allocator.free(script);
        var result = try self.runHelper(io, script, null, max_listing_bytes);
        defer result.deinit(self.allocator);
        return ssh.parseListing(result.stdout, visitor);
    }

    fn statPathFn(ptr: *anyopaque, io: std.Io, path: []const u8) workspace.FsError!workspace.PathStat {
        const self = fromPtr(ptr);
        const script = ssh.statScript(self.allocator, path) catch |err| return quoteFs(err);
        defer self.allocator.free(script);
        var result = try self.runHelper(io, script, null, 4096);
        defer result.deinit(self.allocator);
        return ssh.parseStat(result.stdout);
    }

    fn watchFn(ptr: *anyopaque, allocator: Allocator, io: std.Io, path: []const u8) workspace.WatchError!workspace.WatchHandle {
        return WslWatch.create(fromPtr(ptr), allocator, io, path);
    }

    fn runFn(ptr: *anyopaque, allocator: Allocator, io: std.Io, request: workspace.RunRequest) workspace.RunError!workspace.RunResult {
        const self = fromPtr(ptr);
        if (request.argv.len == 0) return error.InvalidRequest;
        if (request.stdin) |bytes| {
            if (bytes.len > workspace.RunRequest.max_stdin) return error.InvalidRequest;
        }
        const script = ssh.execScript(self.allocator, request.cwd, request.argv) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.EmbeddedNul => error.InvalidRequest,
        };
        defer self.allocator.free(script);
        var result = try self.runScript(allocator, io, script, request.stdin, request.max_output, request.timeout_ms);
        if (result.exit_code == 127 and std.mem.endsWith(u8, result.stderr, not_found_marker ++ "\n")) {
            result.deinit(allocator);
            return error.CommandNotFound;
        }
        return result;
    }

    fn readFileAtFn(ptr: *anyopaque, io: std.Io, path: []const u8, offset: u64, buffer: []u8) workspace.FsError!usize {
        const self = fromPtr(ptr);
        if (buffer.len == 0) return 0;
        const script = ssh.readFileAtScript(self.allocator, path, offset, buffer.len) catch |err| return quoteFs(err);
        defer self.allocator.free(script);
        var result = try self.runHelper(io, script, null, buffer.len);
        defer result.deinit(self.allocator);
        if (result.stdout.len > buffer.len) return error.Unavailable;
        @memcpy(buffer[0..result.stdout.len], result.stdout);
        return result.stdout.len;
    }

    /// Distinguishes the temporaries of concurrent writes.
    var next_write_serial = std.atomic.Value(u32).init(0);

    /// As SSH's: `ssh.write_chunk_bytes` pieces into a hidden temporary that
    /// the last piece renames into place.
    fn writeFileFn(ptr: *anyopaque, io: std.Io, path: []const u8, bytes: []const u8, mode: u32) workspace.FsError!void {
        const self = fromPtr(ptr);
        if (bytes.len > workspace.max_write_bytes) return error.TooLarge;
        var tmp_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const tmp = ssh.writeTempPath(&tmp_buffer, path, processId(), next_write_serial.fetchAdd(1, .monotonic)) catch return error.NameTooLong;
        var offset: usize = 0;
        while (true) {
            const end = @min(bytes.len, offset + ssh.write_chunk_bytes);
            const step: ssh.WriteStep = .{ .first = offset == 0, .last = end == bytes.len, .mode = mode };
            self.writeStep(io, path, tmp, step, bytes[offset..end]) catch |err| {
                if (offset != 0) self.discard(io, tmp);
                return err;
            };
            if (step.last) return;
            offset = end;
        }
    }

    fn writeStep(self: *WslContext, io: std.Io, path: []const u8, tmp: []const u8, step: ssh.WriteStep, chunk: []const u8) workspace.FsError!void {
        const script = ssh.writeFileScript(self.allocator, path, tmp, step) catch |err| return quoteFs(err);
        defer self.allocator.free(script);
        var result = try self.runHelper(io, script, chunk, 4096);
        result.deinit(self.allocator);
    }

    fn discard(self: *WslContext, io: std.Io, tmp: []const u8) void {
        const script = ssh.discardScript(self.allocator, tmp) catch return;
        defer self.allocator.free(script);
        var result = self.runHelper(io, script, null, 4096) catch |err| {
            log.debug("a write's temporary was not removed: {s}", .{@errorName(err)});
            return;
        };
        result.deinit(self.allocator);
    }

    fn makePrivateDirFn(ptr: *anyopaque, io: std.Io, path: []const u8) workspace.FsError!void {
        const self = fromPtr(ptr);
        const script = ssh.makePrivateDirScript(self.allocator, path) catch |err| return quoteFs(err);
        defer self.allocator.free(script);
        var result = try self.runHelper(io, script, null, 4096);
        result.deinit(self.allocator);
    }

    fn stateDirFn(ptr: *anyopaque, io: std.Io, buffer: []u8) workspace.FsError![]u8 {
        const self = fromPtr(ptr);
        var result = try self.runHelper(io, ssh.state_dir_script, null, std.fs.max_path_bytes);
        defer result.deinit(self.allocator);
        const dir = ssh.parseStateDir(result.stdout) orelse return error.Unavailable;
        if (dir.len > buffer.len) return error.NameTooLong;
        @memcpy(buffer[0..dir.len], dir);
        return buffer[0..dir.len];
    }
};

/// The root `wslpath -u 'C:\'` reports drives under: `/mnt/c/` gives `/mnt/`,
/// `/c/` gives `/`. Null for anything else.
pub fn mountRootFromWslpath(output: []const u8) ?[]const u8 {
    const line = std.mem.trimEnd(u8, output, "\r\n");
    const without_slash = std.mem.trimEnd(u8, line, "/");
    if (without_slash.len < 2 or line[0] != '/') return null;
    if (std.ascii.toLower(without_slash[without_slash.len - 1]) != 'c' or without_slash[without_slash.len - 2] != '/') return null;
    const root = line[0 .. without_slash.len - 1];
    for (root) |byte| {
        if (byte < ' ' or byte == 0x7f or byte == '\\') return null;
    }
    return root;
}

/// The marker `ssh.execScript` prints when the cwd or program is missing.
const not_found_marker = "conduit-ssh: not found";

/// The exit statuses `ssh.zig`'s file helper scripts use for the errors
/// `FsError` names; the helpers are shared, so these must match them (the
/// test "the shared helper scripts report errors with these exit codes"
/// runs the scripts and checks).
const helper_not_found = 64;
const helper_is_dir = 65;
const helper_access_denied = 66;
const helper_not_dir = 67;

fn helperError(exit_code: ?u8) workspace.FsError {
    return switch (exit_code orelse return error.Unavailable) {
        helper_not_found => error.NotFound,
        helper_is_dir => error.IsADirectory,
        helper_access_denied => error.AccessDenied,
        helper_not_dir => error.NotADirectory,
        else => error.Unavailable,
    };
}

fn fsFromRun(err: workspace.RunError) workspace.FsError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unavailable,
    };
}

fn quoteFs(err: ssh.QuoteError) workspace.FsError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.EmbeddedNul => error.NotFound,
    };
}

fn processId() i32 {
    if (builtin.os.tag == .windows) return @bitCast(std.os.windows.GetCurrentProcessId());
    return @intCast(std.posix.system.getpid());
}

/// The WSL `WatchHandle`: one long-lived exec channel running
/// `ssh.watchScript`, read without blocking. `create` waits (at most
/// `ssh.watch_ready_timeout_ms`) for the loop's baseline so a later change is
/// never missed; a channel that ends reports a change and is restarted at most
/// every `ssh.watch_interval_s`.
const WslWatch = struct {
    context: *WslContext,
    allocator: Allocator,
    io: std.Io,
    path: []u8,
    child: ?std.process.Child = null,
    ready: bool = false,
    last_start_ms: i64 = 0,

    const handle_vtable: workspace.WatchHandle.VTable = .{
        .poll_changes = pollChanges,
        .destroy = destroy,
    };

    fn create(context: *WslContext, allocator: Allocator, io: std.Io, path: []const u8) workspace.WatchError!workspace.WatchHandle {
        const self = try allocator.create(WslWatch);
        errdefer allocator.destroy(self);
        self.* = .{ .context = context, .allocator = allocator, .io = io, .path = try allocator.dupe(u8, path) };
        errdefer allocator.free(self.path);
        if (!self.start()) return error.Unavailable;
        errdefer self.stop();
        if (!self.awaitReady()) return error.Unavailable;
        return .{ .ptr = self, .vtable = &handle_vtable };
    }

    fn nowMs(io: std.Io) i64 {
        return std.Io.Clock.awake.now(io).toMilliseconds();
    }

    fn start(self: *WslWatch) bool {
        self.last_start_ms = nowMs(self.io);
        self.ready = false;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const script = ssh.watchScript(arena, self.path) catch return false;
        const argv = self.context.launchArgv(arena, script) catch return false;
        const child = std.process.spawn(self.io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
            .create_no_window = true,
        }) catch |err| {
            log.debug("wsl watch channel: {s}", .{@errorName(err)});
            return false;
        };
        self.child = child;
        return true;
    }

    fn stop(self: *WslWatch) void {
        if (self.child) |*child| child.kill(self.io);
        self.child = null;
        self.ready = false;
    }

    fn awaitReady(self: *WslWatch) bool {
        const deadline = nowMs(self.io) + ssh.watch_ready_timeout_ms;
        while (true) {
            const outcome = self.drain();
            if (self.ready) return true;
            if (outcome == .ended) return false;
            if (nowMs(self.io) >= deadline) return false;
            // The baseline takes one fingerprint inside the distribution; a
            // short sleep between non-blocking reads is the wait.
            self.io.sleep(.fromMilliseconds(20), .awake) catch return false;
        }
    }

    const Drained = enum { quiet, changed, ended };

    fn drain(self: *WslWatch) Drained {
        const child = self.child orelse return .ended;
        var changed = false;
        var buffer: [256]u8 = undefined;
        while (true) {
            switch (pipe.readAvailable(child.stdout.?.handle, &buffer)) {
                .bytes => |n| for (buffer[0..n]) |byte| switch (byte) {
                    'r' => self.ready = true,
                    'c' => changed = true,
                    else => {},
                },
                .would_block => return if (changed) .changed else .quiet,
                .end => {
                    self.stop();
                    return .ended;
                },
            }
        }
    }

    fn pollChanges(ptr: *anyopaque) bool {
        const self: *WslWatch = @ptrCast(@alignCast(ptr));
        if (self.child != null) {
            const was_ready = self.ready;
            return switch (self.drain()) {
                .changed, .ended => true,
                .quiet => !was_ready and self.ready,
            };
        }
        if (nowMs(self.io) - self.last_start_ms < ssh.watch_interval_s * std.time.ms_per_s) return false;
        _ = self.start();
        return false;
    }

    fn destroy(ptr: *anyopaque) void {
        const self: *WslWatch = @ptrCast(@alignCast(ptr));
        self.stop();
        const allocator = self.allocator;
        allocator.free(self.path);
        allocator.destroy(self);
    }
};

/// Read what a child's stdout pipe already holds, never blocking: poll(2) on
/// POSIX, `PeekNamedPipe` and an overlapped `ReadFile` of at most that much
/// on Windows (the read end Zig creates is overlapped).
const pipe = struct {
    const Result = union(enum) { bytes: usize, would_block, end };

    fn readAvailable(handle: @FieldType(std.Io.File, "handle"), buffer: []u8) Result {
        if (builtin.os.tag == .windows) return windowsRead(handle, buffer);
        var fds = [_]std.posix.pollfd{.{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, 0) catch return .end;
        if (ready == 0) return .would_block;
        const n = std.posix.read(handle, buffer) catch |err| return switch (err) {
            error.WouldBlock => .would_block,
            else => .end,
        };
        return if (n == 0) .end else .{ .bytes = n };
    }

    const win = if (builtin.os.tag == .windows) struct {
        const windows = std.os.windows;
        /// Win32 `OVERLAPPED`, which Zig 0.16's `std.os.windows` does not declare.
        const OVERLAPPED = extern struct {
            internal: usize,
            internal_high: usize,
            offset: u32,
            offset_high: u32,
            event: ?windows.HANDLE,
        };
        extern "kernel32" fn PeekNamedPipe(pipe: windows.HANDLE, buffer: ?*anyopaque, size: u32, read: ?*u32, available: ?*u32, left: ?*u32) callconv(.winapi) windows.BOOL;
        extern "kernel32" fn ReadFile(file: windows.HANDLE, buffer: [*]u8, size: u32, read: ?*u32, overlapped: ?*OVERLAPPED) callconv(.winapi) windows.BOOL;
        extern "kernel32" fn GetOverlappedResult(file: windows.HANDLE, overlapped: *OVERLAPPED, transferred: *u32, wait: windows.BOOL) callconv(.winapi) windows.BOOL;
    } else struct {};

    fn windowsRead(handle: anytype, buffer: []u8) Result {
        if (builtin.os.tag != .windows) unreachable;
        var available: u32 = 0;
        if (win.PeekNamedPipe(handle, null, 0, null, &available, null) == .FALSE) return .end;
        if (available == 0) return .would_block;
        var overlapped = std.mem.zeroes(win.OVERLAPPED);
        const want: u32 = @intCast(@min(buffer.len, available));
        var got: u32 = 0;
        if (win.ReadFile(handle, buffer.ptr, want, null, &overlapped) == .FALSE) {
            if (std.os.windows.GetLastError() != .IO_PENDING) return .end;
        }
        // The bytes were already in the pipe, so this completes at once.
        if (win.GetOverlappedResult(handle, &overlapped, &got, .TRUE) == .FALSE) return .end;
        return if (got == 0) .end else .{ .bytes = got };
    }
};

fn dupeList(allocator: Allocator, items: []const []const u8) Allocator.Error![][]u8 {
    const list = try allocator.alloc([]u8, items.len);
    var filled: usize = 0;
    errdefer {
        for (list[0..filled]) |item| allocator.free(item);
        allocator.free(list);
    }
    for (items) |item| {
        list[filled] = try allocator.dupe(u8, item);
        filled += 1;
    }
    return list;
}

fn freeList(allocator: Allocator, list: [][]u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

// ---------------------------------------------------------------- unit tests

const testing = std.testing;

test "distribution names are WSL's own spelling and nothing else" {
    for ([_][]const u8{ "Ubuntu", "Ubuntu-24.04", "docker-desktop", "Arch_Linux", "a" }) |name| {
        try testing.expect(validDistributionName(name));
    }
    for ([_][]const u8{ "", "-d", "two words", "a/b", "a\\b", "x\"y", "ü", "a;rm" }) |name| {
        try testing.expect(!validDistributionName(name));
    }
}

test "wsl --list --quiet is decoded from UTF-16LE with or without a BOM, and from UTF-8" {
    const utf16 = [_]u8{ 0xff, 0xfe } ++ asciiToUtf16("Ubuntu-24.04\r\ndocker-desktop\r\n\r\n");
    var list: Distributions = .{};
    parseDistributionList(&utf16, &list);
    try testing.expectEqual(@as(usize, 2), list.count);
    try testing.expectEqualStrings("Ubuntu-24.04", list.at(0));
    try testing.expectEqualStrings("docker-desktop", list.at(1));

    const bare = asciiToUtf16("Debian\r\nUbuntu\r\nDebian\r\n");
    var bare_list: Distributions = .{};
    parseDistributionList(&bare, &bare_list);
    try testing.expectEqual(@as(usize, 2), bare_list.count);
    try testing.expectEqualStrings("Debian", bare_list.at(0));

    var utf8_list: Distributions = .{};
    parseDistributionList("Alpine\nnot valid name\n-x\n", &utf8_list);
    try testing.expectEqual(@as(usize, 1), utf8_list.count);
    try testing.expectEqualStrings("Alpine", utf8_list.at(0));

    var empty: Distributions = .{};
    parseDistributionList("", &empty);
    try testing.expectEqual(@as(usize, 0), empty.count);
}

fn asciiToUtf16(comptime text: []const u8) [text.len * 2]u8 {
    var out: [text.len * 2]u8 = undefined;
    for (text, 0..) |byte, index| {
        out[index * 2] = byte;
        out[index * 2 + 1] = 0;
    }
    return out;
}

test "the mount root comes from wslpath's answer for drive C" {
    try testing.expectEqualStrings("/mnt/", mountRootFromWslpath("/mnt/c/\n").?);
    try testing.expectEqualStrings("/mnt/", mountRootFromWslpath("/mnt/c\n").?);
    try testing.expectEqualStrings("/", mountRootFromWslpath("/c/").?);
    try testing.expectEqualStrings("/windows/", mountRootFromWslpath("/windows/c/\r\n").?);
    try testing.expect(mountRootFromWslpath("") == null);
    try testing.expect(mountRootFromWslpath("C:\\") == null);
    try testing.expect(mountRootFromWslpath("/mnt/d/") == null);
}

test "a WSL context is created for a valid distribution only and reports its kind" {
    try testing.expectError(error.InvalidDistribution, WslContext.create(testing.allocator, .{ .distribution = "-oops", .local_env = &.{} }));
    var context = try WslContext.create(testing.allocator, .{ .distribution = "Ubuntu", .local_env = &.{"PATH=/x"} });
    defer context.deinit();
    try testing.expectEqual(workspace.ExecutionContextKind.wsl, context.kind());
    const wsl = WslContext.fromContext(&context).?;
    try testing.expectEqualStrings("Ubuntu", wsl.distributionName());
    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings("/mnt/c/Users/me/a.txt", wsl.toContextPath("C:\\Users\\me\\a.txt", &buffer).?);
    try testing.expectEqualStrings("/home/me/a.txt", wsl.toContextPath("/home/me/a.txt", &buffer).?);
    try testing.expectEqualStrings("\\\\wsl.localhost\\Ubuntu\\home\\me", wsl.toLocalPath("/home/me", &buffer).?);

    var local = try ExecutionContext.local(testing.allocator);
    defer local.deinit();
    try testing.expect(WslContext.fromContext(&local) == null);
}

test "every launch line names the distribution, starts in its home and execs /bin/sh -c" {
    var context = try WslContext.create(testing.allocator, .{
        .distribution = "Ubuntu",
        .program = "C:\\stub\\bash.exe",
        .program_prefix = &.{"C:\\stub\\wsl.sh"},
        .local_env = &.{},
    });
    defer context.deinit();
    const wsl = WslContext.fromContext(&context).?;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const argv = try wsl.launchArgv(arena_state.allocator(), "echo hi");
    const expected = [_][]const u8{ "C:\\stub\\bash.exe", "C:\\stub\\wsl.sh", "-d", "Ubuntu", "--cd", "~", "-e", "/bin/sh", "-c", "echo hi" };
    try testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, got| try testing.expectEqualStrings(want, got);
}

/// The stand-in launcher for these tests: a `/bin/sh` script that speaks the
/// part of `wsl.exe`'s command line Conduit uses (`--list --quiet`, and
/// `-d <name> --cd ~ -e <argv>`) and runs the command on this machine, with
/// a `wslpath` that maps `C:\` to `/mnt/c/`. On Windows the same script runs
/// under Git for Windows' bash (`CONDUIT_TEST_WSL_SH`), and a real
/// distribution is used instead when `CONDUIT_TEST_WSL_DISTRO` names one.
const stand_in_script =
    \\self=$(cygpath -u "$0" 2>/dev/null || printf '%s' "$0")
    \\home=$(cd "$(dirname "$self")/home" && pwd)
    \\case "$1" in --list|-l) printf 'StandIn\nOther\n'; exit 0 ;; esac
    \\[ "$1" = -d ] || { echo "stand-in: expected -d" >&2; exit 2; }
    \\[ "$2" = StandIn ] || { echo "stand-in: no distribution $2" >&2; exit 1; }
    \\shift 2
    \\if [ "$1" = --cd ]; then [ "$2" = "~" ] && cd "$home"; shift 2; fi
    \\[ "$1" = -e ] || { echo "stand-in: expected -e" >&2; exit 2; }
    \\shift
    \\PATH="$home/bin:$PATH" HOME="$home" XDG_STATE_HOME= exec "$@"
    \\
;

const wslpath_script =
    \\#!/bin/sh
    \\[ "$1" = -u ] && [ "$2" = 'C:\' ] && { printf '/mnt/c/\n'; exit 0; }
    \\[ "$1" = -w ] && { printf '\\\\wsl.localhost\\StandIn%s\n' "$(printf '%s' "$2" | tr / '\\')"; exit 0; }
    \\exit 1
    \\
;

const StandIn = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    context: ExecutionContext,
    env: std.process.Environ.Map,

    /// Real WSL (`CONDUIT_TEST_WSL_DISTRO`, Windows only), the stand-in under
    /// `CONDUIT_TEST_WSL_SH` on Windows, or the stand-in under `/bin/sh` on
    /// POSIX. Null skips: Windows without either.
    fn init() !?StandIn {
        // The stand-in runs the shared helper scripts with this machine's
        // tools. WSL distributions are GNU userlands, and macOS's BSD tools
        // still fail the private-directory helper after the `chmod --` fix
        // (ci.yml run 37738762283, no diagnostic in the log), so the stand-in
        // runs on Linux and Windows only.
        if (builtin.os.tag == .macos) return null;
        // Which launcher is decided before anything is allocated, so a
        // skipped test (Windows with neither) leaks nothing.
        const real = testing.environ.getAlloc(testing.allocator, "CONDUIT_TEST_WSL_DISTRO") catch null;
        defer if (real) |name| testing.allocator.free(name);
        const use_real = builtin.os.tag == .windows and real != null;
        const shell: ?[]const u8 = if (use_real)
            null
        else if (builtin.os.tag == .windows)
            (testing.environ.getAlloc(testing.allocator, "CONDUIT_TEST_WSL_SH") catch return null)
        else
            try testing.allocator.dupe(u8, "/bin/sh");
        defer if (shell) |program| testing.allocator.free(program);

        var self: StandIn = undefined;
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.root = try self.tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(self.root);
        self.env = try testing.environ.createMap(testing.allocator);
        errdefer self.env.deinit();

        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const env_list = try envList(arena_state.allocator(), &self.env);
        if (use_real) {
            self.context = try WslContext.create(testing.allocator, .{ .distribution = real.?, .local_env = env_list });
            return self;
        }

        try self.tmp.dir.createDirPath(testing.io, "home/bin");
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "wsl.sh", .data = stand_in_script });
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "home/bin/wslpath", .data = wslpath_script, .flags = .{ .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o755) } });
        const script = try std.fs.path.join(testing.allocator, &.{ self.root, "wsl.sh" });
        defer testing.allocator.free(script);
        self.context = try WslContext.create(testing.allocator, .{
            .distribution = "StandIn",
            .program = shell.?,
            .program_prefix = &.{script},
            .local_env = env_list,
        });
        return self;
    }

    fn deinit(self: *StandIn) void {
        self.context.deinit();
        self.env.deinit();
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }
};

/// `KEY=VALUE` entries of `map`, in an arena the caller frees.
fn envList(arena: Allocator, map: *const std.process.Environ.Map) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        try list.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* }));
    }
    return list.items;
}

test "the shared helper scripts report errors with these exit codes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const missing = try ssh.readFileScript(testing.allocator, "/nonexistent/conduit-wsl", 16);
    defer testing.allocator.free(missing);
    var result = try workspace.runLocalProcess(testing.allocator, testing.io, .{ .argv = &.{ "/bin/sh", "-c", missing }, .cwd = "" });
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, helper_not_found), result.exit_code);
    const dir = try ssh.readFileScript(testing.allocator, "/", 16);
    defer testing.allocator.free(dir);
    var dir_result = try workspace.runLocalProcess(testing.allocator, testing.io, .{ .argv = &.{ "/bin/sh", "-c", dir }, .cwd = "" });
    defer dir_result.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, helper_is_dir), dir_result.exit_code);
    const listing = try ssh.listDirScript(testing.allocator, "/etc/hostname");
    defer testing.allocator.free(listing);
    var not_dir = try workspace.runLocalProcess(testing.allocator, testing.io, .{ .argv = &.{ "/bin/sh", "-c", listing }, .cwd = "" });
    defer not_dir.deinit(testing.allocator);
    try testing.expect(not_dir.exit_code.? == helper_not_dir or not_dir.exit_code.? == helper_not_found);
}

test "a WSL context runs commands, files, watches and sessions inside the distribution" {
    var stand_in = (try StandIn.init()) orelse return error.SkipZigTest;
    defer stand_in.deinit();
    const ref = stand_in.context.borrow();
    const wsl = WslContext.fromRef(ref).?;
    const io = testing.io;

    // Where `--cd ~` lands is the distribution's home, in its own path syntax.
    // A cold distribution boots on its first command; WSL2 can take tens of seconds.
    var pwd = try ref.run(testing.allocator, io, .{ .argv = &.{"pwd"}, .cwd = "", .timeout_ms = 120_000 });
    defer pwd.deinit(testing.allocator);
    try testing.expect(pwd.succeeded());
    const home = std.mem.trimEnd(u8, pwd.stdout, "\r\n");
    try testing.expect(home.len > 1 and home[0] == '/');

    // run: argv verbatim, stdin, exit status, a missing program.
    var echoed = try ref.run(testing.allocator, io, .{ .argv = &.{ "sh", "-c", "cat; echo \"[$0]\"; exit 3", "it's \"quoted\"" }, .cwd = home, .stdin = "from stdin\n" });
    defer echoed.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 3), echoed.exit_code);
    try testing.expectEqualStrings("from stdin\n[it's \"quoted\"]\n", echoed.stdout);
    try testing.expectError(error.CommandNotFound, ref.run(testing.allocator, io, .{ .argv = &.{"conduit-no-such-program"}, .cwd = "" }));

    // Files: a private directory, an atomic write, whole and partial reads, stat and listing.
    var path_buffer: [512]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buffer, "{s}/conduit-wsl/state", .{home});
    ref.makePrivateDir(io, dir) catch |err| {
        // Name what the helper said, so a platform's shell or tools that
        // disagree with the script are visible in the failure.
        const script = try ssh.makePrivateDirScript(testing.allocator, dir);
        defer testing.allocator.free(script);
        var probe = try ref.run(testing.allocator, io, .{ .argv = &.{ "sh", "-xc", script }, .cwd = "" });
        defer probe.deinit(testing.allocator);
        log.err("makePrivateDir: {s}; exit {?d}; stderr: {s}", .{ @errorName(err), probe.exit_code, probe.stderr });
        return err;
    };
    var file_buffer: [512]u8 = undefined;
    const file = try std.fmt.bufPrint(&file_buffer, "{s}/sink.txt", .{dir});
    try ref.writeFile(io, file, "kestrel lantern\n", 0o600);
    var read_buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("kestrel lantern\n", try ref.readFile(io, file, &read_buffer));
    try testing.expectEqual(@as(usize, 7), try ref.readFileAt(io, file, 8, read_buffer[0..7]));
    try testing.expectEqualStrings("lantern", read_buffer[0..7]);
    var tiny: [4]u8 = undefined;
    try testing.expectError(error.TooLarge, ref.readFile(io, file, &tiny));
    const stat = try ref.statPath(io, file);
    try testing.expectEqual(workspace.PathKind.file, stat.kind);
    try testing.expectEqual(@as(u64, 16), stat.size);
    try testing.expectError(error.NotFound, ref.statPath(io, "/conduit-wsl-missing/x"));
    try testing.expectError(error.IsADirectory, ref.readFile(io, dir, &read_buffer));
    const Seen = struct {
        found: bool = false,
        fn visit(ptr: *anyopaque, entry: workspace.DirEntry) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (std.mem.eql(u8, entry.name, "sink.txt") and entry.kind == .file) self.found = true;
            return true;
        }
    };
    var seen: Seen = .{};
    try ref.listDir(io, dir, .{ .context = &seen, .visit_fn = Seen.visit });
    try testing.expect(seen.found);

    // stateDir: the distribution's own `$HOME/.local/state` when XDG_STATE_HOME is unset.
    var state_buffer: [512]u8 = undefined;
    const state = try ref.stateDir(io, &state_buffer);
    try testing.expect(std.mem.endsWith(u8, state, "/.local/state"));

    // watch: the baseline exists when `watch` returns, so a later change is reported.
    var handle = try ref.watch(testing.allocator, io, dir);
    defer handle.deinit();
    var other_buffer: [512]u8 = undefined;
    try ref.writeFile(io, try std.fmt.bufPrint(&other_buffer, "{s}/second.txt", .{dir}), "x", 0o600);
    var changed = false;
    var attempts: usize = 0;
    while (!changed and attempts < 400) : (attempts += 1) {
        changed = handle.pollChanges();
        if (!changed) try io.sleep(.fromMilliseconds(25), .awake);
    }
    try testing.expect(changed);

    // Paths: the mount root comes from the distribution's wslpath.
    wsl.learnMountRoot(io);
    var translated: [256]u8 = undefined;
    try testing.expectEqualStrings("/mnt/c/Users/me/a.txt", wsl.toContextPath("C:\\Users\\me\\a.txt", &translated).?);
    // The reverse spelling agrees with the distribution's own `wslpath -w`.
    var windows_form = try ref.run(testing.allocator, io, .{ .argv = &.{ "wslpath", "-w", file }, .cwd = "" });
    defer windows_form.deinit(testing.allocator);
    try testing.expect(windows_form.succeeded());
    try testing.expectEqualStrings(std.mem.trimEnd(u8, windows_form.stdout, "\r\n"), wsl.toLocalPath(file, &translated).?);

    // spawn: three concurrent sessions (a tab, a pane and the scratchpad of a
    // WSL workspace) each start in their requested directory inside the
    // distribution with the overlay exported.
    const distro_check = if (std.mem.eql(u8, wsl.distribution, "StandIn")) "stand-in" else wsl.distribution;
    var sessions: [3]pty.Pty = undefined;
    var started: usize = 0;
    defer for (sessions[0..started]) |session| session.destroy();
    const cwds = [_][]const u8{ dir, home, "/" };
    for (cwds, 0..) |cwd, index| {
        var script_buffer: [256]u8 = undefined;
        const script = try std.fmt.bufPrint(&script_buffer, "printf 'S{d} DIR=%s TERMIS=%s DISTRO=%s\\n' \"$(pwd)\" \"$TERM\" \"${{WSL_DISTRO_NAME:-stand-in}}\"; sleep 5", .{index});
        sessions[index] = try ref.spawn(.{
            .argv = &.{ "sh", "-c", script },
            .env = &.{ "TERM=xterm-256color", "PATH=C:\\not\\crossing" },
            .cwd = cwd,
            .size = .{ .rows = 24, .cols = 160 },
        });
        started += 1;
    }
    for (sessions, cwds, 0..) |session, cwd, index| {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(testing.allocator);
        var expected_buffer: [700]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buffer, "S{d} DIR={s} TERMIS=xterm-256color DISTRO={s}", .{ index, cwd, distro_check });
        var waited: usize = 0;
        while (std.mem.indexOf(u8, output.items, expected) == null and waited < 1200) : (waited += 1) {
            _ = session.waitReadable(25);
            var chunk: [1024]u8 = undefined;
            const n = session.takeBytes(&chunk);
            try output.appendSlice(testing.allocator, chunk[0..n]);
        }
        if (std.mem.indexOf(u8, output.items, expected) == null) {
            log.err("session {d} output: {s}", .{ index, output.items });
            return error.SessionOutputMissing;
        }
    }
}

test "the stand-in lists its distributions through --list --quiet" {
    var stand_in = (try StandIn.init()) orelse return error.SkipZigTest;
    defer stand_in.deinit();
    const wsl = WslContext.fromContext(&stand_in.context).?;
    var list: Distributions = .{};
    listDistributions(testing.allocator, testing.io, wsl.program, @ptrCast(wsl.prefix), &list);
    try testing.expect(list.count >= 1);
    if (std.mem.eql(u8, wsl.distribution, "StandIn")) {
        try testing.expectEqualStrings("StandIn", list.at(0));
        try testing.expectEqualStrings("Other", list.at(1));
    }
}
