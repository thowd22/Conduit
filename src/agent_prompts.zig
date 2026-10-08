//! The prompts view's model (TASK-59): what one agent's instructions are
//! made of, as rows a person can read and, where the harness allows it,
//! open for editing.
//!
//! Three kinds of item: the instruction files the agent's harness reads for
//! its cwd (its adapter's `agent.InstructionProfile`: project memory up the
//! tree, user files in the home directory, subagent definitions, the
//! harness's own settings), the initial prompt Conduit launched it with, and
//! the prompts the human sent in this session (the user messages in its
//! event log). Prompts already sent are history and read-only; settings
//! belong to the harness and are read-only; a system prompt no harness
//! exposes is listed as such. Every item that is read-only says why.
//!
//! A file of the `app` module rather than a module of its own because only
//! the composition root shows it. Nothing here knows a harness (invariant
//! 9): which files exist is the adapter's profile, and every file is found
//! through the agent's workspace ExecutionContext (`statPath`, `listDir`,
//! `run` for a remote home), never on this machine by assumption (invariant
//! 5), so an SSH workspace lists the remote host's files.
//!
//! Safety (CONDUIT.md §11): file names, sizes and prompt text are display
//! data. Nothing here reads instruction text into anything that acts, runs
//! or answers; an editor opens only from an explicit gesture in the app.
//! Directory entries are untrusted: a name with a control character or a
//! separator is skipped.
//!
//! Threads: `discover` blocks on the context (one exec channel per call in
//! an SSH workspace), so the app runs it on a `Job` worker; the resulting
//! `List` is handed to the owner thread whole and never shared.
//!
//! Memory: a `List` owns an arena holding every item's strings; `deinit`
//! frees it. Items and file counts are bounded.

const std = @import("std");
const agent = @import("agent");
const workspace = @import("workspace");
const agent_view = @import("agent_view.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Ref = workspace.ExecutionContext.Ref;

const log = std.log.scoped(.agent_prompts);

/// The most items one list keeps; discovery stops adding beyond it.
pub const max_items = 64;
/// The most directories `project_tree` sources climb.
pub const max_depth = 32;
/// The most Markdown files one `<dir>/*.md` source lists.
pub const max_listed = 24;
/// The most bytes of one prompt kept for its preview.
pub const max_prompt_bytes = 16 * 1024;

/// Why an item is read-only.
pub const Reason = enum {
    /// A prompt that was already sent: history, not a draft.
    sent,
    /// The harness's own settings: its format and meaning are its own.
    harness_owned,
    /// The harness does not let Conduit read it (a system prompt).
    not_exposed,
    /// The context could not read it.
    read_only_host,

    pub fn text(self: Reason) []const u8 {
        return switch (self) {
            .sent => "sent",
            .harness_owned => "harness-owned",
            .not_exposed => "not exposed by this harness",
            .read_only_host => "read-only on this host",
        };
    }
};

pub const Kind = enum {
    instructions,
    subagent,
    settings,
    initial_prompt,
    prompt,
    system_prompt,

    pub fn isFile(self: Kind) bool {
        return switch (self) {
            .instructions, .subagent, .settings => true,
            else => false,
        };
    }
};

/// One row of the view.
pub const Item = struct {
    kind: Kind,
    /// What the row is called: a path shortened against the cwd or home, or
    /// a prompt's first line. Display text, cleaned of controls.
    name: []const u8,
    /// A file's absolute path in the agent's context, or a prompt's whole
    /// (bounded) text. Empty for the system prompt.
    value: []const u8,
    exists: bool = true,
    size: ?u64 = null,
    mtime_ns: ?i128 = null,
    /// Null when the item may be edited.
    reason: ?Reason = null,

    pub fn editable(self: *const Item) bool {
        return self.reason == null;
    }
};

pub const List = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Item) = .empty,
    /// Why no files are listed, when the context could not be asked.
    problem: ?[]const u8 = null,

    pub fn init(allocator: Allocator) List {
        return .{ .arena = .init(allocator) };
    }

    pub fn deinit(self: *List) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn append(self: *List, item: Item) Allocator.Error!bool {
        if (self.items.items.len >= max_items) return false;
        try self.items.append(self.arena.allocator(), item);
        return true;
    }

    /// The file item at `path`, if listed.
    pub fn fileAt(self: *const List, path: []const u8) ?*const Item {
        for (self.items.items) |*item| {
            if (item.kind.isFile() and std.mem.eql(u8, item.value, path)) return item;
        }
        return null;
    }
};

/// Where and for what to look.
pub const DiscoverRequest = struct {
    context: Ref,
    profile: agent.InstructionProfile,
    /// The agent's cwd, absolute in the context.
    cwd: []const u8,
    /// The home directory in the context, when known.
    home: ?[]const u8 = null,
};

pub const Error = Allocator.Error;

/// Fill `list` with the profile's files that exist (and each source's
/// `list_missing` file in the cwd), in profile order and nearest directory
/// first. Blocks on the context; workers only for a remote one. A context
/// that cannot stat files leaves `problem` set and no files.
pub fn discover(list: *List, io: Io, request: DiscoverRequest) Error!void {
    if (request.cwd.len == 0 or request.cwd[0] != '/') {
        list.problem = "the agent's directory is not known";
        return;
    }
    for (request.profile.sources) |source| {
        switch (source.base) {
            .project => try visit(list, io, request, source, request.cwd, true),
            .home => if (request.home) |home| try visit(list, io, request, source, home, false),
            .project_tree => {
                var dir: []const u8 = std.mem.trimEnd(u8, request.cwd, "/");
                if (dir.len == 0) dir = "/";
                var depth: usize = 0;
                while (depth < max_depth) : (depth += 1) {
                    try visit(list, io, request, source, dir, depth == 0);
                    if (std.mem.eql(u8, dir, "/")) break;
                    dir = std.fs.path.dirnamePosix(dir) orelse "/";
                }
            },
        }
        if (list.problem != null) {
            list.items.clearRetainingCapacity();
            return;
        }
    }
}

/// One source in one directory: a file, or a directory's Markdown files.
fn visit(list: *List, io: Io, request: DiscoverRequest, source: agent.InstructionSource, dir: []const u8, at_cwd: bool) Error!void {
    const arena = list.arena.allocator();
    const base = if (std.mem.eql(u8, dir, "/")) "" else dir;
    if (source.isListing()) {
        const sub = source.path[0 .. source.path.len - "/*.md".len];
        const listed_dir = try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, sub });
        var names: Names = .{};
        request.context.listDir(io, listed_dir, .{ .context = &names, .visit_fn = Names.visit }) catch |err| switch (err) {
            error.NotFound, error.NotADirectory => return,
            error.Unsupported, error.Unavailable => {
                list.problem = "files cannot be read on this host";
                return;
            },
            else => return,
        };
        names.sort();
        for (0..names.count) |index| {
            const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ listed_dir, names.name(index) });
            try statInto(list, io, request, source, path, false);
        }
        return;
    }
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, source.path });
    try statInto(list, io, request, source, path, at_cwd and source.list_missing);
}

fn statInto(list: *List, io: Io, request: DiscoverRequest, source: agent.InstructionSource, path: []const u8, keep_missing: bool) Error!void {
    if (list.fileAt(path) != null) return;
    const kind: Kind = switch (source.kind) {
        .instructions => .instructions,
        .subagent => .subagent,
        .settings => .settings,
    };
    var item: Item = .{
        .kind = kind,
        .name = try shortName(list.arena.allocator(), path, request.cwd, request.home),
        .value = path,
        .reason = if (source.editable()) null else .harness_owned,
    };
    if (request.context.statPath(io, path)) |stat| {
        if (stat.kind != .file) return;
        item.size = stat.size;
        item.mtime_ns = stat.mtime_ns;
    } else |err| switch (err) {
        error.NotFound, error.NotADirectory => {
            if (!keep_missing) return;
            item.exists = false;
        },
        error.AccessDenied => item.reason = .read_only_host,
        error.Unsupported, error.Unavailable => {
            list.problem = "files cannot be read on this host";
            return;
        },
        else => return,
    }
    _ = try list.append(item);
}

/// The Markdown file names of one directory, bounded and checked.
const Names = struct {
    storage: [max_listed][128]u8 = undefined,
    lens: [max_listed]usize = undefined,
    count: usize = 0,

    fn visit(context: *anyopaque, entry: workspace.DirEntry) bool {
        const self: *Names = @ptrCast(@alignCast(context));
        if (entry.kind != .file) return true;
        if (!std.mem.endsWith(u8, entry.name, ".md") or entry.name.len > 128) return true;
        if (!plainName(entry.name)) return true;
        if (self.count == max_listed) return false;
        @memcpy(self.storage[self.count][0..entry.name.len], entry.name);
        self.lens[self.count] = entry.name.len;
        self.count += 1;
        return true;
    }

    fn name(self: *const Names, index: usize) []const u8 {
        return self.storage[index][0..self.lens[index]];
    }

    fn sort(self: *Names) void {
        // Insertion sort over at most `max_listed` names.
        var i: usize = 1;
        while (i < self.count) : (i += 1) {
            var j = i;
            while (j > 0 and std.mem.order(u8, self.name(j - 1), self.name(j)) == .gt) : (j -= 1) {
                std.mem.swap([128]u8, &self.storage[j - 1], &self.storage[j]);
                std.mem.swap(usize, &self.lens[j - 1], &self.lens[j]);
            }
        }
    }
};

/// A directory entry name that can be shown and joined into a path.
fn plainName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return false;
    if (!std.unicode.utf8ValidateSlice(name)) return false;
    for (name) |c| if (c < 0x20 or c == 0x7f or c == '/' or c == '\\') return false;
    return true;
}

/// `path` relative to `cwd` when inside it, `~/…` when inside `home`,
/// otherwise as it is.
pub fn shortName(allocator: Allocator, path: []const u8, cwd: []const u8, home: ?[]const u8) Allocator.Error![]const u8 {
    const trimmed_cwd = std.mem.trimEnd(u8, cwd, "/");
    if (trimmed_cwd.len != 0 and path.len > trimmed_cwd.len + 1 and std.mem.startsWith(u8, path, trimmed_cwd) and path[trimmed_cwd.len] == '/') {
        return allocator.dupe(u8, path[trimmed_cwd.len + 1 ..]);
    }
    if (home) |dir| {
        const trimmed_home = std.mem.trimEnd(u8, dir, "/");
        if (trimmed_home.len != 0 and path.len > trimmed_home.len + 1 and std.mem.startsWith(u8, path, trimmed_home) and path[trimmed_home.len] == '/') {
            return std.fmt.allocPrint(allocator, "~/{s}", .{path[trimmed_home.len + 1 ..]});
        }
    }
    return allocator.dupe(u8, path);
}

/// Append the prompt rows after the files: a system prompt the harness does
/// not expose, the initial prompt the agent was launched with, then every
/// prompt the human sent (oldest first; one that repeats the initial prompt
/// is not listed twice). Owner thread; texts are copied and cleaned.
pub fn addPrompts(list: *List, profile: agent.InstructionProfile, initial: ?[]const u8, sent: []const []const u8) Error!void {
    if (!profile.system_prompt_exposed) {
        _ = try list.append(.{ .kind = .system_prompt, .name = "system prompt", .value = "", .reason = .not_exposed });
    }
    if (initial) |text| if (text.len != 0) {
        _ = try list.append(try promptItem(list, .initial_prompt, text));
    };
    for (sent) |text| {
        if (initial) |first| if (std.mem.eql(u8, first, text)) continue;
        if (!try list.append(try promptItem(list, .prompt, text))) break;
    }
}

fn promptItem(list: *List, kind: Kind, text: []const u8) Error!Item {
    const arena = list.arena.allocator();
    const cut = agent.truncateUtf8(text, max_prompt_bytes);
    const value = try agent_view.sanitize(arena, cut);
    const first_line = std.mem.sliceTo(text, '\n');
    const name = try agent_view.sanitize(arena, agent.truncateUtf8(first_line, 256));
    return .{ .kind = kind, .name = name, .value = value, .size = text.len, .reason = .sent };
}

/// A byte size the way the view shows it: `312 B`, `4.2 KiB`, `1.1 MiB`.
pub fn formatSize(buffer: []u8, size: u64) []const u8 {
    if (size < 1024) return std.fmt.bufPrint(buffer, "{d} B", .{size}) catch "";
    const kib = @as(f64, @floatFromInt(size)) / 1024.0;
    if (kib < 1024) return std.fmt.bufPrint(buffer, "{d:.1} KiB", .{kib}) catch "";
    return std.fmt.bufPrint(buffer, "{d:.1} MiB", .{kib / 1024.0}) catch "";
}

/// What a row says after its name: the size (or `new` for a file that does
/// not exist yet, `–` for nothing to measure) and `editable` or
/// `read-only · <reason>`.
pub fn formatTail(buffer: []u8, item: *const Item) []const u8 {
    var size_buffer: [24]u8 = undefined;
    const size = if (!item.exists) "new" else if (item.size) |bytes| formatSize(&size_buffer, bytes) else "–";
    var writer: Io.Writer = .fixed(buffer);
    if (item.reason) |reason| {
        writer.print("{s}  read-only · {s}", .{ size, reason.text() }) catch {};
    } else {
        writer.print("{s}  editable", .{size}) catch {};
    }
    return buffer[0..writer.end];
}

/// What the name column starts with for each kind.
pub fn prefix(kind: Kind) []const u8 {
    return switch (kind) {
        .instructions => "▤ ",
        .subagent => "◆ ",
        .settings => "⚙ ",
        .initial_prompt => "launch › ",
        .prompt => "you › ",
        .system_prompt => "· ",
    };
}

/// One row: prefix and name, cut with `…` so the tail fits, then the tail
/// right-aligned in `width` cells. Shorter than `width` only when `buffer`
/// is too small.
pub fn formatRow(buffer: []u8, item: *const Item, width: u32) []const u8 {
    var tail_buffer: [96]u8 = undefined;
    const tail = formatTail(&tail_buffer, item);
    const tail_cells = agent_view.displayCells(tail);
    const head_prefix = prefix(item.kind);
    var writer: Io.Writer = .fixed(buffer);
    const name_room: u32 = width -| (tail_cells + 2);
    const prefix_cells = agent_view.displayCells(head_prefix);
    var used: u32 = 0;
    if (prefix_cells <= name_room) {
        writer.writeAll(head_prefix) catch return buffer[0..writer.end];
        used = prefix_cells;
    }
    const name_cells = agent_view.displayCells(item.name);
    if (used + name_cells <= name_room) {
        writer.writeAll(item.name) catch return buffer[0..writer.end];
        used += name_cells;
    } else if (name_room > used + 1) {
        const keep = agent_view.byteAtCell(item.name, name_room - used - 1);
        writer.writeAll(item.name[0..keep]) catch return buffer[0..writer.end];
        writer.writeAll("…") catch return buffer[0..writer.end];
        used += agent_view.displayCells(item.name[0..keep]) + 1;
    }
    const pad = width -| (used + tail_cells);
    writer.splatByteAll(' ', pad) catch return buffer[0..writer.end];
    writer.writeAll(tail) catch {};
    var len = writer.end;
    while (len != 0 and !std.unicode.utf8ValidateSlice(buffer[0..len])) len -= 1;
    return buffer[0..len];
}

/// The `/bin/sh` command that prints the context's `$HOME`.
const home_script = "case \"${HOME:-}\" in /?*) printf '%s' \"$HOME\" ;; *) exit 1 ;; esac";

/// The home directory as `context` sees it, in `out`; null when unknown.
/// One bounded command: workers only.
pub fn resolveHome(context: Ref, allocator: Allocator, io: Io, out: []u8) ?[]const u8 {
    var result = context.run(allocator, io, .{
        .argv = &.{ "/bin/sh", "-c", home_script },
        .cwd = "",
        .max_output = 4096,
        .timeout_ms = 10_000,
    }) catch |err| {
        log.debug("the home directory was not found: {s}", .{@errorName(err)});
        return null;
    };
    defer result.deinit(allocator);
    if (!result.succeeded()) return null;
    const home = std.mem.trimEnd(u8, result.stdout, "/");
    if (home.len == 0 or home[0] != '/' or home.len > out.len) return null;
    for (home) |c| if (c < 0x20 or c == 0x7f) return null;
    @memcpy(out[0..home.len], home);
    return out[0..home.len];
}

/// One discovery on its own thread, so a remote context's exec channels
/// never block the owner. The owner polls `finished` and takes the list
/// with `take`; `destroy` joins first.
pub const Job = struct {
    allocator: Allocator,
    io: Io,
    context: Ref,
    profile: agent.InstructionProfile,
    /// Owned copies.
    cwd: []u8,
    home: ?[]u8,
    /// Ask the context for its home (a remote one) instead of `home`.
    resolve_home: bool,
    list: List,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    failed: bool = false,

    pub const Options = struct {
        context: Ref,
        profile: agent.InstructionProfile,
        cwd: []const u8,
        home: ?[]const u8 = null,
        resolve_home: bool = false,
    };

    /// Start a discovery. The context must outlive the job.
    pub fn start(allocator: Allocator, io: Io, options: Options) (Allocator.Error || std.Thread.SpawnError)!*Job {
        const job = try allocator.create(Job);
        errdefer allocator.destroy(job);
        const cwd = try allocator.dupe(u8, options.cwd);
        errdefer allocator.free(cwd);
        const home = if (options.home) |dir| try allocator.dupe(u8, dir) else null;
        errdefer if (home) |dir| allocator.free(dir);
        job.* = .{
            .allocator = allocator,
            .io = io,
            .context = options.context,
            .profile = options.profile,
            .cwd = cwd,
            .home = home,
            .resolve_home = options.resolve_home,
            .list = .init(allocator),
        };
        errdefer job.list.deinit();
        job.thread = try std.Thread.spawn(.{}, work, .{job});
        return job;
    }

    fn work(self: *Job) void {
        defer self.done.store(true, .release);
        var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const home: ?[]const u8 = if (self.resolve_home)
            resolveHome(self.context, self.allocator, self.io, &home_buffer)
        else
            self.home;
        discover(&self.list, self.io, .{ .context = self.context, .profile = self.profile, .cwd = self.cwd, .home = home }) catch |err| {
            log.debug("instruction discovery failed: {s}", .{@errorName(err)});
            self.failed = true;
        };
    }

    pub fn finished(self: *const Job) bool {
        return self.done.load(.acquire);
    }

    /// Join and move the list out; the job keeps an empty one.
    pub fn take(self: *Job) List {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        const list = self.list;
        self.list = .init(self.allocator);
        return list;
    }

    pub fn destroy(self: *Job) void {
        if (self.thread) |thread| thread.join();
        self.list.deinit();
        self.allocator.free(self.cwd);
        if (self.home) |dir| self.allocator.free(dir);
        self.allocator.destroy(self);
    }
};

// Tests ------------------------------------------------------------------------

const testing = std.testing;

/// A context with a fixed tree of files and directories, answering
/// `statPath` and `listDir` like a remote host would.
const ScriptedTree = struct {
    files: []const File,
    denied: []const []const u8 = &.{},
    stats: usize = 0,

    const File = struct { path: []const u8, size: u64, dir: bool = false };

    const vtable: workspace.ExecutionContext.VTable = .{
        .spawn = spawn,
        .kind = kind,
        .destroy = destroy,
        .stat_path = statPath,
        .list_dir = listDir,
    };

    fn ref(self: *ScriptedTree) Ref {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const spawn_fn = @typeInfo(@typeInfo(workspace.ExecutionContext.SpawnFn).pointer.child).@"fn";

    fn spawn(_: *anyopaque, _: spawn_fn.params[1].type.?) spawn_fn.return_type.? {
        return error.Closed;
    }

    fn kind(_: *const anyopaque) workspace.ExecutionContextKind {
        return .ssh;
    }

    fn destroy(_: *anyopaque) void {}

    fn statPath(ptr: *anyopaque, _: Io, path: []const u8) workspace.FsError!workspace.PathStat {
        const self: *ScriptedTree = @ptrCast(@alignCast(ptr));
        self.stats += 1;
        for (self.denied) |denied| if (std.mem.eql(u8, denied, path)) return error.AccessDenied;
        for (self.files) |file| {
            if (std.mem.eql(u8, file.path, path)) return .{ .kind = if (file.dir) .directory else .file, .size = file.size, .mtime_ns = 7 };
        }
        return error.NotFound;
    }

    fn listDir(ptr: *anyopaque, _: Io, path: []const u8, visitor: workspace.DirVisitor) workspace.FsError!void {
        const self: *ScriptedTree = @ptrCast(@alignCast(ptr));
        var found = false;
        for (self.files) |file| {
            if (file.dir and std.mem.eql(u8, file.path, path)) found = true;
        }
        if (!found) return error.NotFound;
        for (self.files) |file| {
            const parent = std.fs.path.dirnamePosix(file.path) orelse continue;
            if (!std.mem.eql(u8, parent, path)) continue;
            const name = std.fs.path.basenamePosix(file.path);
            if (!visitor.visit_fn(visitor.context, .{ .name = name, .kind = if (file.dir) .directory else .file })) return;
        }
    }
};

const test_profile: agent.InstructionProfile = .{
    .sources = &.{
        .{ .base = .project_tree, .path = "CLAUDE.md", .list_missing = true },
        .{ .base = .home, .path = ".claude/CLAUDE.md" },
        .{ .base = .project, .path = ".claude/agents/*.md", .kind = .subagent },
        .{ .base = .project, .path = ".claude/settings.json", .kind = .settings },
    },
    .apply = .restart,
};

test "discovery lists the profile's files through the context, nearest first, with editability" {
    var tree: ScriptedTree = .{ .files = &.{
        .{ .path = "/home/u/work/app/CLAUDE.md", .size = 120 },
        .{ .path = "/home/u/work/CLAUDE.md", .size = 2048 },
        .{ .path = "/home/u/.claude/CLAUDE.md", .size = 9 },
        .{ .path = "/home/u/work/app/.claude", .size = 0, .dir = true },
        .{ .path = "/home/u/work/app/.claude/agents", .size = 0, .dir = true },
        .{ .path = "/home/u/work/app/.claude/agents/reviewer.md", .size = 33 },
        .{ .path = "/home/u/work/app/.claude/agents/architect.md", .size = 44 },
        .{ .path = "/home/u/work/app/.claude/agents/notes.txt", .size = 1 },
        .{ .path = "/home/u/work/app/.claude/agents/\x1bevil.md", .size = 1 },
        .{ .path = "/home/u/work/app/.claude/settings.json", .size = 77 },
    } };
    var list: List = .init(testing.allocator);
    defer list.deinit();
    try discover(&list, testing.io, .{ .context = tree.ref(), .profile = test_profile, .cwd = "/home/u/work/app", .home = "/home/u" });
    try testing.expectEqual(@as(?[]const u8, null), list.problem);
    const items = list.items.items;
    const names = [_][]const u8{ "CLAUDE.md", "~/work/CLAUDE.md", "~/.claude/CLAUDE.md", ".claude/agents/architect.md", ".claude/agents/reviewer.md", ".claude/settings.json" };
    try testing.expectEqual(names.len, items.len);
    for (items, names) |item, name| try testing.expectEqualStrings(name, item.name);
    try testing.expect(items[0].editable() and items[0].exists);
    try testing.expectEqual(@as(?u64, 120), items[0].size);
    try testing.expectEqual(Kind.subagent, items[3].kind);
    try testing.expect(items[3].editable());
    try testing.expectEqual(Kind.settings, items[5].kind);
    try testing.expectEqual(@as(?Reason, .harness_owned), items[5].reason);
    try testing.expectEqualStrings("/home/u/work/app/.claude/settings.json", items[5].value);
}

test "a missing primary file is listed as new, an unreadable one says why, and no file system is a problem" {
    var tree: ScriptedTree = .{
        .files = &.{.{ .path = "/p/.claude/settings.json", .size = 3 }},
        .denied = &.{"/p/.claude/settings.json"},
    };
    var list: List = .init(testing.allocator);
    defer list.deinit();
    try discover(&list, testing.io, .{ .context = tree.ref(), .profile = test_profile, .cwd = "/p" });
    try testing.expectEqual(@as(usize, 2), list.items.items.len);
    const new = list.items.items[0];
    try testing.expectEqualStrings("CLAUDE.md", new.name);
    try testing.expect(!new.exists and new.editable());
    try testing.expectEqual(@as(?Reason, .read_only_host), list.items.items[1].reason);
    // The tree climb stopped at the root and never asked twice for a path.
    try testing.expect(tree.stats <= 4);

    var none = workspace.localFiles();
    none.vtable = &.{ .spawn = ScriptedTree.spawn, .kind = ScriptedTree.kind, .destroy = ScriptedTree.destroy };
    var empty: List = .init(testing.allocator);
    defer empty.deinit();
    try discover(&empty, testing.io, .{ .context = none, .profile = test_profile, .cwd = "/p" });
    try testing.expectEqualStrings("files cannot be read on this host", empty.problem.?);
    try testing.expectEqual(@as(usize, 0), empty.items.items.len);
}

test "prompts follow the files: system prompt, the launch prompt, then sent prompts, all read-only" {
    var list: List = .init(testing.allocator);
    defer list.deinit();
    try addPrompts(&list, test_profile, "TASK-7: fix it\nAcceptance criteria:", &.{ "TASK-7: fix it\nAcceptance criteria:", "now run the tests\x1b[31m" });
    const items = list.items.items;
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqual(Kind.system_prompt, items[0].kind);
    try testing.expectEqual(@as(?Reason, .not_exposed), items[0].reason);
    try testing.expectEqual(Kind.initial_prompt, items[1].kind);
    try testing.expectEqualStrings("TASK-7: fix it", items[1].name);
    try testing.expectEqual(@as(?Reason, .sent), items[1].reason);
    try testing.expectEqual(Kind.prompt, items[2].kind);
    try testing.expect(std.mem.indexOfScalar(u8, items[2].name, 0x1b) == null);
    try testing.expect(!items[2].editable());
}

test "rows cut the name and keep the size and the reason" {
    var buffer: [256]u8 = undefined;
    const editable: Item = .{ .kind = .instructions, .name = "CLAUDE.md", .value = "/p/CLAUDE.md", .size = 1536 };
    const row = formatRow(&buffer, &editable, 40);
    try testing.expectEqual(@as(u32, 40), agent_view.displayCells(row));
    try testing.expect(std.mem.startsWith(u8, row, "▤ CLAUDE.md"));
    try testing.expect(std.mem.endsWith(u8, row, "1.5 KiB  editable"));
    const settings: Item = .{ .kind = .settings, .name = ".claude/a-rather-long-settings-file-name.json", .value = "", .size = 80, .reason = .harness_owned };
    const cut = formatRow(&buffer, &settings, 40);
    try testing.expect(std.mem.endsWith(u8, cut, "80 B  read-only · harness-owned"));
    try testing.expect(std.mem.indexOf(u8, cut, "…") != null);
    try testing.expect(agent_view.displayCells(cut) <= 40);
    const missing: Item = .{ .kind = .instructions, .name = "AGENTS.md", .value = "", .exists = false };
    try testing.expect(std.mem.endsWith(u8, formatRow(&buffer, &missing, 30), "new  editable"));
    var size_buffer: [24]u8 = undefined;
    try testing.expectEqualStrings("312 B", formatSize(&size_buffer, 312));
    try testing.expectEqualStrings("2.0 MiB", formatSize(&size_buffer, 2 * 1024 * 1024));
}

test "short names are relative to the cwd, then the home" {
    const inside = try shortName(testing.allocator, "/w/a/b.md", "/w/", "/h");
    defer testing.allocator.free(inside);
    try testing.expectEqualStrings("a/b.md", inside);
    const home = try shortName(testing.allocator, "/h/.codex/AGENTS.md", "/w", "/h");
    defer testing.allocator.free(home);
    try testing.expectEqualStrings("~/.codex/AGENTS.md", home);
    const other = try shortName(testing.allocator, "/etc/AGENTS.md", "/w", null);
    defer testing.allocator.free(other);
    try testing.expectEqualStrings("/etc/AGENTS.md", other);
}

test "every shipped harness profile lists an editable primary file in the cwd" {
    for (agent.Harness.all) |harness| {
        const profile = agent.instructionProfile(harness);
        try testing.expect(profile.sources.len != 0);
        const first = profile.sources[0];
        try testing.expect(first.base == .project_tree and first.list_missing and first.editable());
        for (profile.sources) |source| {
            try testing.expect(source.path.len != 0 and source.path[0] != '/');
            if (source.kind == .settings) try testing.expect(!source.editable());
        }
    }
    try testing.expectEqual(agent.InstructionApply.restart, agent.instructionProfile(.claude_code).apply);
    try testing.expectEqual(agent.InstructionApply.next_session, agent.instructionProfile(.codex).apply);
}
