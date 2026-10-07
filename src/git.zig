//! Git repository and branch resolution for the sidebar (TASK-76).
//!
//! Resolution never starts git and never reads the local file system
//! directly: every stat and read goes through the workspace's
//! `ExecutionContext.Ref`, so an SSH or WSL workspace resolves its own
//! repository on its own side (AGENTS.md invariant 5). The walk is bounded in
//! depth, path length and bytes read, and every malformed or unreadable input
//! resolves to "no repository" rather than an error, so a hostile `.git` can
//! neither crash nor hang the app.
//!
//! Threads: `resolve` blocks on the context for as long as its few reads take,
//! which is why the app calls it through `Lookup`, a one-shot worker. A
//! `Lookup` is created and finished on the owner thread; the worker touches
//! only its own copied cwd and result.

const std = @import("std");
const workspace = @import("workspace");

const Allocator = std.mem.Allocator;
const Ref = workspace.ExecutionContext.Ref;
const log = std.log.scoped(.git);

/// The most bytes read from `HEAD` or from a `.git` indirection file.
pub const max_file_bytes: usize = 4096;
/// The most directories examined walking up from the cwd.
pub const max_depth: usize = 32;
/// The longest branch name shown; a longer one is treated as malformed.
pub const max_name_bytes: usize = 128;
/// The longest path the walk builds, the cwd included.
pub const max_path_bytes: usize = 4096;
/// Hex digits of a detached commit that are shown.
pub const short_commit_len: usize = 8;

/// What `HEAD` names.
pub const HeadKind = enum {
    /// `ref: refs/heads/<name>`; the text is the branch name.
    branch,
    /// A bare commit id; the text is its first `short_commit_len` digits.
    detached,
};

/// The displayable state of one repository's `HEAD`. Self-contained, so it
/// can be copied out of a worker and kept by value.
pub const Head = struct {
    kind: HeadKind,
    bytes: [max_name_bytes]u8 = undefined,
    len: u8 = 0,

    /// The validated, printable text to display.
    pub fn text(self: *const Head) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(a: *const Head, b: *const Head) bool {
        return a.kind == b.kind and std.mem.eql(u8, a.text(), b.text());
    }

    fn init(kind: HeadKind, name: []const u8) Head {
        std.debug.assert(name.len <= max_name_bytes);
        var head: Head = .{ .kind = kind, .len = @intCast(name.len) };
        @memcpy(head.bytes[0..name.len], name);
        return head;
    }
};

/// A resolved repository: its `HEAD` and the git directory that holds it
/// (`<work tree>/.git`, or the directory a `gitdir:` file points at).
pub const Repo = struct {
    head: Head,
    git_dir_bytes: [max_path_bytes]u8 = undefined,
    git_dir_len: usize = 0,

    /// The git directory in the context's own path syntax.
    pub fn gitDir(self: *const Repo) []const u8 {
        return self.git_dir_bytes[0..self.git_dir_len];
    }
};

/// Whether `name` may be shown as a branch: non-empty, at most
/// `max_name_bytes`, valid UTF-8 and free of every C0/C1 control and DEL.
/// Terminal-derived text is untrusted, and a control byte drawn into the UI
/// could misplace the cells around it.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    const view = std.unicode.Utf8View.init(name) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |codepoint| {
        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint < 0xa0)) return false;
    }
    return true;
}

/// Parse the contents of a `HEAD` file. Null for anything malformed.
pub fn parseHead(contents: []const u8) ?Head {
    const line = std.mem.trimEnd(u8, contents, " \t\r\n");
    if (std.mem.startsWith(u8, line, "ref:")) {
        const target = std.mem.trim(u8, line["ref:".len..], " \t");
        const prefix = "refs/heads/";
        const name = if (std.mem.startsWith(u8, target, prefix)) target[prefix.len..] else target;
        if (!validName(name)) return null;
        return Head.init(.branch, name);
    }
    if (line.len != 40 and line.len != 64) return null;
    for (line) |byte| {
        if (!std.ascii.isHex(byte)) return null;
    }
    return Head.init(.detached, line[0..short_commit_len]);
}

/// A path being built in fixed storage.
const PathBuffer = struct {
    bytes: [max_path_bytes]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const PathBuffer) []const u8 {
        return self.bytes[0..self.len];
    }

    fn set(self: *PathBuffer, value: []const u8) bool {
        if (value.len > self.bytes.len) return false;
        @memcpy(self.bytes[0..value.len], value);
        self.len = value.len;
        return true;
    }

    /// `base` + `/` + `leaf`, without doubling a root's slash.
    fn join(self: *PathBuffer, base: []const u8, leaf: []const u8) bool {
        const separator: usize = if (base.len != 0 and base[base.len - 1] == '/') 0 else 1;
        const total = base.len + separator + leaf.len;
        if (total > self.bytes.len) return false;
        std.mem.copyForwards(u8, self.bytes[0..base.len], base);
        if (separator == 1) self.bytes[base.len] = '/';
        @memcpy(self.bytes[base.len + separator .. total], leaf);
        self.len = total;
        return true;
    }
};

/// The parent of an absolute, slash-normalised directory, or null at `/`.
fn parentOf(dir: []const u8) ?[]const u8 {
    if (dir.len <= 1) return null;
    const slash = std.mem.lastIndexOfScalar(u8, dir, '/') orelse return null;
    return if (slash == 0) "/" else dir[0..slash];
}

/// Find the repository enclosing `cwd` and read its `HEAD`.
///
/// `cwd` must be absolute in the context's syntax. The walk examines at most
/// `max_depth` directories and stops at the first `.git` it finds, which is
/// how git itself scopes a nested repository. Returns null outside a work
/// tree, on any read failure and on any malformed content.
pub fn resolve(ctx: Ref, io: std.Io, cwd: []const u8, repo: *Repo) bool {
    if (cwd.len == 0 or cwd[0] != '/' or cwd.len > max_path_bytes) return false;
    var dir_storage: PathBuffer = .{};
    if (!dir_storage.set(std.mem.trimEnd(u8, cwd, "/"))) return false;
    if (dir_storage.len == 0) _ = dir_storage.set("/");

    var candidate: PathBuffer = .{};
    var file_buffer: [max_file_bytes]u8 = undefined;
    var dir: []const u8 = dir_storage.slice();
    var depth: usize = 0;
    while (depth < max_depth) : (depth += 1) {
        if (!candidate.join(dir, ".git")) return false;
        const stat = ctx.statPath(io, candidate.slice()) catch |err| switch (err) {
            error.NotFound, error.NotADirectory => {
                dir = parentOf(dir) orelse return false;
                continue;
            },
            else => {
                log.debug("stopped looking for a repository: {s}", .{@errorName(err)});
                return false;
            },
        };
        var git_dir: PathBuffer = .{};
        switch (stat.kind) {
            .directory => if (!git_dir.set(candidate.slice())) return false,
            .file => {
                // A linked worktree or submodule: `gitdir: <path>`, relative
                // to the directory that holds the file.
                const contents = ctx.readFile(io, candidate.slice(), &file_buffer) catch return false;
                const line = std.mem.trim(u8, contents, " \t\r\n");
                if (!std.mem.startsWith(u8, line, "gitdir:")) return false;
                const target = std.mem.trim(u8, line["gitdir:".len..], " \t");
                if (target.len == 0 or std.mem.indexOfAny(u8, target, "\r\n\x00") != null) return false;
                if (target[0] == '/') {
                    if (!git_dir.set(target)) return false;
                } else if (!git_dir.join(dir, target)) return false;
            },
            .other => return false,
        }
        var head_path: PathBuffer = .{};
        if (!head_path.join(git_dir.slice(), "HEAD")) return false;
        const contents = ctx.readFile(io, head_path.slice(), &file_buffer) catch |err| {
            log.debug("a repository's HEAD could not be read: {s}", .{@errorName(err)});
            return false;
        };
        const head = parseHead(contents) orelse return false;
        repo.head = head;
        @memcpy(repo.git_dir_bytes[0..git_dir.len], git_dir.slice());
        repo.git_dir_len = git_dir.len;
        return true;
    }
    return false;
}

/// One resolution on a worker thread.
///
/// Ownership: `start` returns a heap job that owns its copied cwd and result;
/// the owner thread polls `finished` and must call `finish` exactly once,
/// which joins the worker and frees the job. The borrowed context must
/// outlive the job, so whoever releases the context finishes its lookups
/// first.
pub const Lookup = struct {
    allocator: Allocator,
    ctx: Ref,
    io: std.Io,
    cwd: []u8,
    repo: Repo = .{ .head = .{ .kind = .branch } },
    found: bool = false,
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    thread: ?std.Thread = null,

    /// Copy `cwd` and resolve it off the calling thread.
    pub fn start(allocator: Allocator, ctx: Ref, io: std.Io, cwd: []const u8) !*Lookup {
        const self = try allocator.create(Lookup);
        errdefer allocator.destroy(self);
        const owned = try allocator.dupe(u8, cwd);
        errdefer allocator.free(owned);
        self.* = .{ .allocator = allocator, .ctx = ctx, .io = io, .cwd = owned };
        self.thread = try std.Thread.spawn(.{}, work, .{self});
        return self;
    }

    fn work(self: *Lookup) void {
        self.found = resolve(self.ctx, self.io, self.cwd, &self.repo);
        self.state.store(1, .release);
    }

    /// Whether `finish` would not block.
    pub fn finished(self: *const Lookup) bool {
        return self.state.load(.acquire) != 0;
    }

    /// Join the worker, free the job and return what it resolved, if anything.
    /// `into` receives the repository when the result is true.
    pub fn finish(self: *Lookup, into: *Repo) bool {
        if (self.thread) |thread| thread.join();
        const found = self.found;
        if (found) into.* = self.repo;
        const allocator = self.allocator;
        allocator.free(self.cwd);
        allocator.destroy(self);
        return found;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// An in-memory context: a fixed set of directories and files.
const FakeFs = struct {
    dirs: []const []const u8 = &.{},
    files: []const File = &.{},
    stats: usize = 0,
    reads: usize = 0,

    const File = struct { path: []const u8, contents: []const u8 };

    const vtable: workspace.ExecutionContext.VTable = .{
        .spawn = spawnUnsupported,
        .kind = kindRemote,
        .destroy = destroyNothing,
        .read_file = readFile,
        .stat_path = statPath,
    };

    fn ref(self: *FakeFs) Ref {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn spawnUnsupported(_: *anyopaque, _: @import("pty").SpawnRequest) @import("pty").Error!@import("pty").Pty {
        return error.SpawnFailed;
    }
    fn kindRemote(_: *const anyopaque) workspace.ExecutionContextKind {
        return .ssh;
    }
    fn destroyNothing(_: *anyopaque) void {}

    fn readFile(ptr: *anyopaque, _: std.Io, path: []const u8, buffer: []u8) workspace.FsError![]u8 {
        const self: *FakeFs = @ptrCast(@alignCast(ptr));
        self.reads += 1;
        for (self.files) |file| {
            if (!std.mem.eql(u8, file.path, path)) continue;
            if (file.contents.len > buffer.len) return error.TooLarge;
            @memcpy(buffer[0..file.contents.len], file.contents);
            return buffer[0..file.contents.len];
        }
        for (self.dirs) |dir| if (std.mem.eql(u8, dir, path)) return error.IsADirectory;
        return error.NotFound;
    }

    fn statPath(ptr: *anyopaque, _: std.Io, path: []const u8) workspace.FsError!workspace.PathStat {
        const self: *FakeFs = @ptrCast(@alignCast(ptr));
        self.stats += 1;
        for (self.dirs) |dir| if (std.mem.eql(u8, dir, path)) return .{ .kind = .directory, .size = 0, .mtime_ns = 0 };
        for (self.files) |file| if (std.mem.eql(u8, file.path, path)) return .{ .kind = .file, .size = file.contents.len, .mtime_ns = 0 };
        return error.NotFound;
    }
};

fn resolveText(fs: *FakeFs, cwd: []const u8) ?Head {
    var repo: Repo = .{ .head = .{ .kind = .branch } };
    if (!resolve(fs.ref(), testing.io, cwd, &repo)) return null;
    return repo.head;
}

test "a branch HEAD found by walking up from a nested cwd" {
    var fs: FakeFs = .{
        .dirs = &.{"/home/u/repo/.git"},
        .files = &.{.{ .path = "/home/u/repo/.git/HEAD", .contents = "ref: refs/heads/feature/x\n" }},
    };
    var repo: Repo = .{ .head = .{ .kind = .branch } };
    try testing.expect(resolve(fs.ref(), testing.io, "/home/u/repo/src/deep/", &repo));
    try testing.expectEqual(HeadKind.branch, repo.head.kind);
    try testing.expectEqualStrings("feature/x", repo.head.text());
    try testing.expectEqualStrings("/home/u/repo/.git", repo.gitDir());
}

test "a detached HEAD shows the abbreviated commit" {
    var fs: FakeFs = .{
        .dirs = &.{"/r/.git"},
        .files = &.{.{ .path = "/r/.git/HEAD", .contents = "0123456789abcdef0123456789abcdef01234567\n" }},
    };
    const head = resolveText(&fs, "/r").?;
    try testing.expectEqual(HeadKind.detached, head.kind);
    try testing.expectEqualStrings("01234567", head.text());
}

test "a worktree gitdir file is followed, relative or absolute" {
    var fs: FakeFs = .{
        .dirs = &.{ "/main/.git/worktrees/wt", "/w/../main/.git/worktrees/wt" },
        .files = &.{
            .{ .path = "/abs/.git", .contents = "gitdir: /main/.git/worktrees/wt\n" },
            .{ .path = "/w/.git", .contents = "gitdir: ../main/.git/worktrees/wt\n" },
            .{ .path = "/main/.git/worktrees/wt/HEAD", .contents = "ref: refs/heads/wt-branch\n" },
            .{ .path = "/w/../main/.git/worktrees/wt/HEAD", .contents = "ref: refs/heads/rel\n" },
        },
    };
    var repo: Repo = .{ .head = .{ .kind = .branch } };
    try testing.expect(resolve(fs.ref(), testing.io, "/abs", &repo));
    try testing.expectEqualStrings("wt-branch", repo.head.text());
    try testing.expectEqualStrings("/main/.git/worktrees/wt", repo.gitDir());
    try testing.expectEqualStrings("rel", resolveText(&fs, "/w/sub").?.text());
}

test "no repository, malformed, oversized and control-laden HEADs resolve to nothing" {
    var none: FakeFs = .{};
    try testing.expect(resolveText(&none, "/a/b/c") == null);
    try testing.expect(resolveText(&none, "relative/path") == null);
    try testing.expect(resolveText(&none, "") == null);

    const big = "ref: refs/heads/" ++ "x" ** max_file_bytes;
    const cases = [_][]const u8{
        "garbage",
        "ref: refs/heads/",
        "ref: refs/heads/bad\x1bname",
        "ref: refs/heads/bad\xc2\x9bname",
        "ref: refs/heads/\xff\xfe",
        "0123456789abcdef", // too short for a commit
        "zz23456789abcdef0123456789abcdef01234567", // not hex
        "ref: refs/heads/" ++ "y" ** (max_name_bytes + 1),
        big,
    };
    for (cases) |contents| {
        var fs: FakeFs = .{
            .dirs = &.{"/r/.git"},
            .files = &.{.{ .path = "/r/.git/HEAD", .contents = contents }},
        };
        try testing.expect(resolveText(&fs, "/r") == null);
    }

    // A .git file that is not a gitdir indirection, or names nothing.
    var bad_file: FakeFs = .{ .files = &.{.{ .path = "/r/.git", .contents = "not a pointer" }} };
    try testing.expect(resolveText(&bad_file, "/r") == null);
    var dangling: FakeFs = .{ .files = &.{.{ .path = "/r/.git", .contents = "gitdir: /nowhere" }} };
    try testing.expect(resolveText(&dangling, "/r") == null);
}

test "the walk up is bounded in depth" {
    var path_storage: [max_path_bytes]u8 = undefined;
    var len: usize = 0;
    var level: usize = 0;
    while (level < max_depth + 8) : (level += 1) {
        @memcpy(path_storage[len .. len + 2], "/d");
        len += 2;
    }
    var fs: FakeFs = .{
        .dirs = &.{"/.git"},
        .files = &.{.{ .path = "/.git/HEAD", .contents = "ref: refs/heads/main" }},
    };
    try testing.expect(resolveText(&fs, path_storage[0..len]) == null);
    try testing.expectEqual(max_depth, fs.stats);
    // Within the bound the root repository is found.
    var near: FakeFs = .{
        .dirs = &.{"/.git"},
        .files = &.{.{ .path = "/.git/HEAD", .contents = "ref: refs/heads/main" }},
    };
    try testing.expectEqualStrings("main", resolveText(&near, "/d/d").?.text());
}

test "branch-name validation" {
    try testing.expect(validName("main"));
    try testing.expect(validName("feature/ünïcode"));
    try testing.expect(!validName(""));
    try testing.expect(!validName("a\x00b"));
    try testing.expect(!validName("a\x7fb"));
    try testing.expect(!validName("x" ** (max_name_bytes + 1)));
    try testing.expect(validName("x" ** max_name_bytes));
}

test "a lookup resolves on a worker and hands the result back" {
    var fs: FakeFs = .{
        .dirs = &.{"/r/.git"},
        .files = &.{.{ .path = "/r/.git/HEAD", .contents = "ref: refs/heads/remote-side\n" }},
    };
    const job = try Lookup.start(testing.allocator, fs.ref(), testing.io, "/r/x");
    var repo: Repo = .{ .head = .{ .kind = .branch } };
    try testing.expect(job.finish(&repo));
    try testing.expectEqualStrings("remote-side", repo.head.text());

    var empty: FakeFs = .{};
    const miss = try Lookup.start(testing.allocator, empty.ref(), testing.io, "/nowhere");
    try testing.expect(!miss.finish(&repo));
}
