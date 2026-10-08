//! The backlog.md data layer.
//!
//! `backlog` owns the data behind the board and the task-detail views:
//! projects, tasks, milestones, docs, decisions, statuses and dependencies,
//! and (TASK-64) the linking of a backlog task to an agent. It owns *data*;
//! the views are `ui` compositions of that data.
//!
//! TASK-62 provides three pieces:
//!
//! - **The model.** `Project.load` reads a `backlog/` directory — `config.yml`,
//!   `tasks/`, `completed/`, `drafts/`, `milestones/`, `docs/`, `decisions/` —
//!   into typed `Task`, `Milestone`, `Doc` and `Decision` values with
//!   per-file `Diagnostic`s. Front matter is read with the YAML subset in
//!   `backlog/yaml.zig` (only what Backlog.md writes), sections and the
//!   acceptance-criteria checklist with `backlog/markdown.zig`.
//! - **Live update.** `Project.watch` takes one `WatchHandle` per directory
//!   from the workspace's ExecutionContext and `Project.poll` re-reads only the
//!   files whose size or mtime changed, reporting each as a `Change`. A burst
//!   of writes between two polls is one change per file.
//! - **Writes.** `Cli` runs the `backlog` CLI through `ExecutionContext.run`
//!   with the project directory as cwd. Conduit never edits backlog markdown
//!   itself; the file changes the CLI makes come back through `poll`.
//!
//! Every read and every command goes through the `ExecutionContext.Ref` the
//! caller passes in (P7, invariant 5), so a remote workspace's backlog is read
//! where it lives. Paths are `/`-separated in the context's own syntax.
//!
//! Backlog file content is untrusted text (§11). Parsing is bounded (`Limits`:
//! file size, line length, list, criterion and file counts), tolerant
//! (malformed front matter becomes a `Diagnostic`, unknown keys are ignored)
//! and never fatal. No path, command or action is derived from file content:
//! files are found by listing the fixed directories, and the CLI wrappers take
//! ids and values from the caller, validate them, and pass them as single argv
//! entries with no shell.
//!
//! Threads: a `Project` belongs to the thread that loaded it; its methods
//! block on the context's IO. For a Local context that is a local file read;
//! for a remote context it is network IO, so the caller runs it off the
//! render thread (`docs/architecture.md`, thread ownership). `Cli` methods wait
//! for the child process and belong on a worker thread.
//!
//! Memory: each loaded file owns an arena holding its path, text, parsed item
//! and diagnostics, so re-reading one file frees exactly that file's memory.
//! `Project` owns those arenas, its config arena, its read buffer, its root
//! path and its watches; `deinit` releases them all. Item slices borrow the
//! project and stay valid until the next `poll` replaces or removes that file,
//! or `deinit`. `Change` strings are copied into the caller's allocator.
//!
//! It may depend on `config`, `input`, `theme`, `ui` and `workspace`
//! (`build.zig`); today it imports only `workspace`, for the context type.

const std = @import("std");
const workspace = @import("workspace");
pub const yaml = @import("backlog/yaml.zig");
pub const markdown = @import("backlog/markdown.zig");

const Allocator = std.mem.Allocator;
const ContextRef = workspace.ExecutionContext.Ref;
const log = std.log.scoped(.backlog);

/// The id of one backlog task, as written in the file's front matter: `TASK-27`.
///
/// The canonical spelling is `TASK-` followed by the decimal number, no
/// leading zeros and no padding. That is what makes the id, the
/// `backlog/tasks/task-27 - ….md` file name and the `task-27` the CLI prints
/// the same task, and it is why a non-canonical spelling is an error rather
/// than something to normalise into a second representation of the same task.
///
/// Invariant: a `TaskId` is never zero, and `parse` accepts exactly the
/// canonical spellings.
pub const TaskId = struct {
    /// The task's number. Task 1 is the first task; there is no task 0.
    number: u32,

    /// The prefix every id is written with.
    pub const prefix = "TASK-";

    /// The error any non-canonical spelling produces. Backlog files are
    /// untrusted input (§11), so a malformed id is reported, never asserted on
    /// (`AGENTS.md`, coding standards).
    pub const Error = error{MalformedTaskId};

    /// Parse the id out of its canonical spelling.
    pub fn parse(text: []const u8) Error!TaskId {
        if (!std.mem.startsWith(u8, text, prefix)) return error.MalformedTaskId;

        const digits = text[prefix.len..];
        if (digits.len == 0) return error.MalformedTaskId;
        // A leading zero would let one task be written two ways.
        if (digits.len > 1 and digits[0] == '0') return error.MalformedTaskId;
        for (digits) |c| {
            if (!std.ascii.isDigit(c)) return error.MalformedTaskId;
        }

        // Out of range is malformed too, not a wrap or a crash.
        const number = std.fmt.parseInt(u32, digits, 10) catch
            return error.MalformedTaskId;
        if (number == 0) return error.MalformedTaskId;
        return .{ .number = number };
    }

    /// Write the canonical spelling into `buf` and return the written slice.
    /// `buf` stays owned by the caller.
    pub fn format(self: TaskId, buf: []u8) std.fmt.BufPrintError![]const u8 {
        return std.fmt.bufPrint(buf, prefix ++ "{d}", .{self.number});
    }
};

/// Where a task sits in a default project: to do, in progress, or done. These
/// are the three statuses Backlog.md's default `config.yml` declares, spelled
/// the way the backlog tool writes them.
///
/// The enum is closed. A project may configure other columns, so the model
/// keeps each task's status as text (`Task.status`) and checks it against the
/// project's `Config.statuses`; this enum is the vocabulary for the default
/// columns, and a spelling outside it is malformed rather than silently
/// dropped.
pub const Status = enum {
    to_do,
    in_progress,
    done,

    /// Every status, in board order.
    pub const all = [_]Status{ .to_do, .in_progress, .done };

    /// The error a spelling that is not one of the three produces.
    pub const Error = error{MalformedStatus};

    /// Parse the status as it is stored in a task's front matter.
    pub fn parse(text: []const u8) Error!Status {
        inline for (@typeInfo(Status).@"enum".fields) |field| {
            const status: Status = @enumFromInt(field.value);
            if (std.mem.eql(u8, text, status.display())) return status;
        }
        return error.MalformedStatus;
    }

    /// The spelling this status is stored and shown with.
    pub fn display(self: Status) []const u8 {
        return switch (self) {
            .to_do => "To Do",
            .in_progress => "In Progress",
            .done => "Done",
        };
    }

    /// Whether the task is finished, so the board stops asking an agent about
    /// it.
    pub fn isComplete(self: Status) bool {
        return self == .done;
    }
};

/// Whether `text` is a task id the CLI can be handed: a letter-led prefix, a
/// dash and a decimal number without leading zeros, optionally followed by
/// `.N` subtask numbers (`TASK-62`, `TASK-69.1`, `DRAFT-3`). This is broader
/// than `TaskId`, which names only top-level `TASK-N` tasks, and it is what
/// keeps an id from ever being read as a CLI flag.
pub fn isTaskId(text: []const u8) bool {
    if (text.len == 0 or text.len > 64 or !std.ascii.isAlphabetic(text[0])) return false;
    const dash = std.mem.indexOfScalar(u8, text, '-') orelse return false;
    for (text[0..dash]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    var parts = std.mem.splitScalar(u8, text[dash + 1 ..], '.');
    while (parts.next()) |part| {
        if (part.len == 0 or part.len > 9) return false;
        if (part.len > 1 and part[0] == '0') return false;
        for (part) |c| {
            if (!std.ascii.isDigit(c)) return false;
        }
    }
    return true;
}

/// The bounds on reading one project. Every input dimension is capped, so a
/// hostile or corrupt backlog costs at most these amounts.
pub const Limits = struct {
    /// Files larger than this are reported and not read.
    max_file_bytes: usize = 1024 * 1024,
    /// Markdown files read from one directory; the rest are reported.
    max_files_per_dir: usize = 4096,
    /// Front-matter line length.
    max_line_bytes: usize = 4096,
    /// Items in one front-matter list.
    max_list_items: usize = 256,
    /// Acceptance criteria in one task.
    max_criteria: usize = 256,
    /// Diagnostics kept per file.
    max_diagnostics_per_file: usize = 32,
};

/// The directories of a Backlog.md project, relative to its root.
pub const Location = enum {
    tasks,
    completed,
    drafts,
    milestones,
    docs,
    decisions,

    pub const all = [_]Location{ .tasks, .completed, .drafts, .milestones, .docs, .decisions };

    /// The directory name under the project root.
    pub fn dirName(self: Location) []const u8 {
        return @tagName(self);
    }
};

/// Where a task file lives: the active board, the completed archive, or the
/// drafts.
pub const TaskState = enum { active, completed, draft };

/// The priorities Backlog.md writes.
pub const Priority = enum {
    high,
    medium,
    low,

    pub fn parse(text: []const u8) ?Priority {
        inline for (@typeInfo(Priority).@"enum".fields) |field| {
            if (std.ascii.eqlIgnoreCase(text, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

/// One acceptance criterion: the `#N` index the CLI addresses, whether it is
/// checked, and its text.
pub const Criterion = markdown.Criterion;

/// The project settings from `config.yml` that the model and views use.
pub const Config = struct {
    project_name: []const u8 = "",
    /// The board's columns, in order.
    statuses: []const []const u8 = &default_statuses,
    default_status: []const u8 = "To Do",
    labels: []const []const u8 = &.{},
    date_format: []const u8 = "yyyy-mm-dd",
    task_prefix: []const u8 = "task",

    pub const default_statuses = [_][]const u8{ "To Do", "In Progress", "Done" };

    /// Whether `status` is one of the configured columns.
    pub fn hasStatus(self: Config, status: []const u8) bool {
        for (self.statuses) |known| {
            if (std.mem.eql(u8, known, status)) return true;
        }
        return false;
    }

    /// Whether two configs parse task files identically: the same statuses
    /// in the same order, and the same default.
    fn parsesLike(a: Config, b: Config) bool {
        if (!std.mem.eql(u8, a.default_status, b.default_status)) return false;
        if (a.statuses.len != b.statuses.len) return false;
        for (a.statuses, b.statuses) |left, right| {
            if (!std.mem.eql(u8, left, right)) return false;
        }
        return true;
    }
};

/// One task, from `tasks/`, `completed/` or `drafts/`.
pub const Task = struct {
    id: []const u8,
    title: []const u8,
    /// The status text as written; `Config.hasStatus` says whether it is a
    /// configured column (a mismatch is also a diagnostic).
    status: []const u8,
    assignee: []const []const u8 = &.{},
    labels: []const []const u8 = &.{},
    /// A milestone id (`m-7`) or title, as written.
    milestone: ?[]const u8 = null,
    /// Task ids, as written.
    dependencies: []const []const u8 = &.{},
    priority: ?Priority = null,
    ordinal: ?f64 = null,
    created_date: ?[]const u8 = null,
    updated_date: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    description: ?[]const u8 = null,
    acceptance_criteria: []const Criterion = &.{},
    plan: ?[]const u8 = null,
    notes: ?[]const u8 = null,
    final_summary: ?[]const u8 = null,
    path: []const u8,
    state: TaskState,
};

/// One milestone file.
pub const Milestone = struct {
    id: []const u8,
    title: []const u8,
    description: ?[]const u8 = null,
    path: []const u8,
};

/// One document under `docs/`.
pub const Doc = struct {
    id: []const u8,
    title: []const u8,
    doc_type: ?[]const u8 = null,
    created_date: ?[]const u8 = null,
    updated_date: ?[]const u8 = null,
    path: []const u8,
};

/// One decision record.
pub const Decision = struct {
    id: []const u8,
    title: []const u8,
    status: ?[]const u8 = null,
    date: ?[]const u8 = null,
    path: []const u8,
};

/// The parsed content of one file.
pub const Item = union(enum) {
    task: Task,
    milestone: Milestone,
    doc: Doc,
    decision: Decision,

    pub fn id(self: *const Item) []const u8 {
        return switch (self.*) {
            inline else => |*value| value.id,
        };
    }
};

/// Something wrong with one file or directory. `line` is 1-based, or 0 for
/// the whole file. `message` is static text; `path` borrows the project.
pub const Diagnostic = struct {
    path: []const u8,
    line: u32 = 0,
    message: []const u8,
};

/// A file's item (when it has one) and its diagnostics, as `parseFile`
/// returns them.
pub const Parsed = struct {
    item: ?Item,
    diagnostics: []const Diagnostic,
};

const DiagnosticList = struct {
    arena: Allocator,
    path: []const u8,
    limit: usize,
    items: std.ArrayList(Diagnostic) = .empty,

    fn add(self: *DiagnosticList, line: u32, message: []const u8) Allocator.Error!void {
        if (self.items.items.len >= self.limit) return;
        try self.items.append(self.arena, .{ .path = self.path, .line = line, .message = message });
    }
};

const FrontMatter = struct {
    yaml: []const u8,
    body: []const u8,
};

fn splitFrontMatter(text: []const u8) error{ Missing, Unterminated }!FrontMatter {
    var rest = text;
    if (std.mem.startsWith(u8, rest, "\xEF\xBB\xBF")) rest = rest[3..];
    const first_end = std.mem.indexOfScalar(u8, rest, '\n') orelse return error.Missing;
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, rest[0..first_end], " \t\r"), "---")) return error.Missing;
    const yaml_start = first_end + 1;
    var offset = yaml_start;
    while (offset <= rest.len) {
        const end = std.mem.indexOfScalarPos(u8, rest, offset, '\n') orelse rest.len;
        if (std.mem.eql(u8, std.mem.trimEnd(u8, rest[offset..end], " \t\r"), "---")) {
            return .{ .yaml = rest[yaml_start..offset], .body = rest[@min(end + 1, rest.len)..] };
        }
        if (end == rest.len) break;
        offset = end + 1;
    }
    return error.Unterminated;
}

fn kindOf(location: Location) std.meta.Tag(Item) {
    return switch (location) {
        .tasks, .completed, .drafts => .task,
        .milestones => .milestone,
        .docs => .doc,
        .decisions => .decision,
    };
}

fn nonEmpty(text: ?[]const u8) ?[]const u8 {
    const value = text orelse return null;
    return if (value.len == 0) null else value;
}

/// Parse one backlog file. Pure: no IO, no state. Everything returned is
/// allocated in `arena` or borrows `text` and `path`, which must outlive it.
/// Allocation failure is the only error; a malformed file is a `Parsed` with
/// diagnostics and, when the file names no usable id, no item.
pub fn parseFile(
    arena: Allocator,
    location: Location,
    path: []const u8,
    text: []const u8,
    config: *const Config,
    limits: Limits,
) Allocator.Error!Parsed {
    var diagnostics: DiagnosticList = .{ .arena = arena, .path = path, .limit = limits.max_diagnostics_per_file };

    if (!std.unicode.utf8ValidateSlice(text)) {
        try diagnostics.add(0, "not valid UTF-8");
        return .{ .item = null, .diagnostics = diagnostics.items.items };
    }
    const front = splitFrontMatter(text) catch |err| {
        try diagnostics.add(1, switch (err) {
            error.Missing => "no front matter: the file must start with a `---` line",
            error.Unterminated => "unterminated front matter: no closing `---` line",
        });
        return .{ .item = null, .diagnostics = diagnostics.items.items };
    };

    const doc = try yaml.parse(arena, front.yaml, .{
        .max_line_bytes = limits.max_line_bytes,
        .max_list_items = limits.max_list_items,
    });
    // Front matter starts on the file's second line.
    for (doc.issues) |issue| try diagnostics.add(issue.line + 1, issue.message);

    const id = nonEmpty(doc.scalar("id")) orelse {
        try diagnostics.add(0, "missing `id`");
        return .{ .item = null, .diagnostics = diagnostics.items.items };
    };
    const title = doc.scalar("title") orelse blk: {
        try diagnostics.add(0, "missing `title`");
        break :blk "";
    };
    const body = front.body;

    const item: Item = switch (kindOf(location)) {
        .task => blk: {
            if (!isTaskId(id)) try diagnostics.add(lineOf(doc, "id"), "malformed task id");
            const status = nonEmpty(doc.scalar("status")) orelse missing: {
                try diagnostics.add(0, "missing `status`; showing the default status");
                break :missing config.default_status;
            };
            if (!config.hasStatus(status)) try diagnostics.add(lineOf(doc, "status"), "status is not one of config.yml's statuses");

            var priority: ?Priority = null;
            if (nonEmpty(doc.scalar("priority"))) |text_priority| {
                priority = Priority.parse(text_priority);
                if (priority == null) try diagnostics.add(lineOf(doc, "priority"), "unknown priority");
            }
            var ordinal: ?f64 = null;
            if (nonEmpty(doc.scalar("ordinal"))) |text_ordinal| {
                ordinal = std.fmt.parseFloat(f64, text_ordinal) catch null;
                if (ordinal == null or !std.math.isFinite(ordinal.?)) {
                    ordinal = null;
                    try diagnostics.add(lineOf(doc, "ordinal"), "ordinal is not a number");
                }
            }
            var cut = false;
            const criteria = try markdown.acceptanceCriteria(arena, body, .{ .max_criteria = limits.max_criteria }, &cut);
            if (cut) try diagnostics.add(0, "acceptance criteria exceed the limit; the rest are ignored");

            break :blk .{ .task = .{
                .id = id,
                .title = title,
                .status = status,
                .assignee = try doc.list(arena, "assignee"),
                .labels = try doc.list(arena, "labels"),
                .milestone = nonEmpty(doc.scalar("milestone")),
                .dependencies = try doc.list(arena, "dependencies"),
                .priority = priority,
                .ordinal = ordinal,
                .created_date = nonEmpty(doc.scalar("created_date")),
                .updated_date = nonEmpty(doc.scalar("updated_date")),
                .parent = nonEmpty(doc.scalar("parent_task_id")),
                .description = markdown.section(body, "DESCRIPTION", "Description"),
                .acceptance_criteria = criteria,
                .plan = markdown.section(body, "PLAN", "Implementation Plan"),
                .notes = markdown.section(body, "NOTES", "Implementation Notes"),
                .final_summary = markdown.section(body, "FINAL_SUMMARY", "Final Summary"),
                .path = path,
                .state = switch (location) {
                    .completed => .completed,
                    .drafts => .draft,
                    else => .active,
                },
            } };
        },
        .milestone => .{ .milestone = .{
            .id = id,
            .title = title,
            .description = markdown.headingSection(body, "Description"),
            .path = path,
        } },
        .doc => .{ .doc = .{
            .id = id,
            .title = title,
            .doc_type = nonEmpty(doc.scalar("type")),
            .created_date = nonEmpty(doc.scalar("created_date")),
            .updated_date = nonEmpty(doc.scalar("updated_date")),
            .path = path,
        } },
        .decision => .{ .decision = .{
            .id = id,
            .title = title,
            .status = nonEmpty(doc.scalar("status")),
            .date = nonEmpty(doc.scalar("date")),
            .path = path,
        } },
    };
    return .{ .item = item, .diagnostics = diagnostics.items.items };
}

/// The file line of a front-matter key, for a diagnostic.
fn lineOf(doc: yaml.Document, key: []const u8) u32 {
    const field = doc.get(key) orelse return 0;
    return field.line + 1;
}

/// Parse `config.yml`. Missing or malformed settings fall back to the
/// defaults with a diagnostic. Same memory rules as `parseFile`.
pub fn parseConfig(arena: Allocator, path: []const u8, text: []const u8, limits: Limits) Allocator.Error!struct {
    config: Config,
    diagnostics: []const Diagnostic,
} {
    var diagnostics: DiagnosticList = .{ .arena = arena, .path = path, .limit = limits.max_diagnostics_per_file };
    var config: Config = .{};
    if (!std.unicode.utf8ValidateSlice(text)) {
        try diagnostics.add(0, "not valid UTF-8; using the default settings");
        return .{ .config = config, .diagnostics = diagnostics.items.items };
    }
    const doc = try yaml.parse(arena, text, .{
        .max_line_bytes = limits.max_line_bytes,
        .max_list_items = limits.max_list_items,
    });
    for (doc.issues) |issue| try diagnostics.add(issue.line, issue.message);

    if (nonEmpty(doc.scalar("project_name"))) |name| config.project_name = name;
    const statuses = try doc.list(arena, "statuses");
    if (statuses.len > 0) {
        config.statuses = statuses;
    } else {
        try diagnostics.add(lineOf(doc, "statuses") -| 1, "no `statuses`; using To Do, In Progress, Done");
    }
    if (nonEmpty(doc.scalar("default_status"))) |status| {
        if (config.hasStatus(status)) {
            config.default_status = status;
        } else {
            try diagnostics.add(lineOf(doc, "default_status") -| 1, "`default_status` is not one of the statuses");
            config.default_status = config.statuses[0];
        }
    } else if (!config.hasStatus(config.default_status)) {
        config.default_status = config.statuses[0];
    }
    config.labels = try doc.list(arena, "labels");
    if (nonEmpty(doc.scalar("date_format"))) |format| config.date_format = format;
    if (nonEmpty(doc.scalar("task_prefix"))) |prefix| config.task_prefix = prefix;
    return .{ .config = config, .diagnostics = diagnostics.items.items };
}

/// What `Project.poll` saw happen to one file.
pub const ChangeKind = enum { added, updated, removed };

/// One file that changed. `path` and `id` are copies owned by the allocator
/// passed to `poll`. `id` is null for a file with no usable id.
pub const Change = struct {
    kind: ChangeKind,
    location: Location,
    path: []const u8,
    id: ?[]const u8,
};

/// Size and mtime: what decides whether a file is re-read.
const Signature = struct {
    size: u64,
    mtime_ns: i128,

    fn of(stat: workspace.PathStat) Signature {
        return .{ .size = stat.size, .mtime_ns = stat.mtime_ns };
    }

    fn eql(a: Signature, b: Signature) bool {
        return a.size == b.size and a.mtime_ns == b.mtime_ns;
    }
};

/// One loaded file. Heap-allocated so its address is stable; owns its arena.
const Entry = struct {
    arena: std.heap.ArenaAllocator,
    location: Location,
    path: []const u8,
    signature: Signature,
    /// Set when the config changed, so the next scan re-parses this file.
    stale: bool = false,
    item: ?Item,
    diagnostics: []const Diagnostic,

    fn destroy(self: *Entry, allocator: Allocator) void {
        self.arena.deinit();
        allocator.destroy(self);
    }
};

/// The errors `Project.load` can return. Everything else wrong with a
/// backlog is a diagnostic.
pub const LoadError = Allocator.Error || error{
    /// `root` does not exist or is not a directory.
    NotABacklog,
    /// The context cannot read files.
    Unsupported,
    /// The context could not be reached.
    Unavailable,
};

/// A Backlog.md project read through an ExecutionContext. See the module
/// documentation for ownership and threads.
pub const Project = struct {
    allocator: Allocator,
    io: std.Io,
    context: ContextRef,
    limits: Limits,
    /// Owned path of the `backlog/` directory.
    root_path: []u8,
    /// Owned scratch buffer of `limits.max_file_bytes` for reads.
    read_buffer: []u8,
    config_arena: std.heap.ArenaAllocator,
    settings: Config = .{},
    config_signature: ?Signature = null,
    config_diagnostics: []const Diagnostic = &.{},
    /// Sorted by location, then path.
    entries: std.ArrayList(*Entry) = .empty,
    /// A directory that could not be listed in full, per location.
    dir_problems: [Location.all.len]?Diagnostic = .{null} ** Location.all.len,
    /// Index 0 watches the root; index 1 + location watches that directory.
    watches: [Location.all.len + 1]?workspace.WatchHandle = .{null} ** (Location.all.len + 1),

    /// The `backlog/` directory of a workspace, `<workspace_dir>/backlog`,
    /// written into `buffer`.
    pub fn rootFor(buffer: []u8, workspace_dir: []const u8) error{NoSpaceLeft}![]const u8 {
        const trimmed = std.mem.trimEnd(u8, workspace_dir, "/");
        return std.fmt.bufPrint(buffer, "{s}/backlog", .{trimmed});
    }

    /// Read the whole project at `root_dir` (a `backlog/` directory) through
    /// `context`. The context must outlive the project.
    pub fn load(allocator: Allocator, io: std.Io, context: ContextRef, root_dir: []const u8, limits: Limits) LoadError!Project {
        const stat = context.statPath(io, root_dir) catch |err| return switch (err) {
            error.NotFound, error.NotADirectory, error.IsADirectory, error.NameTooLong, error.AccessDenied => error.NotABacklog,
            error.Unsupported => error.Unsupported,
            error.OutOfMemory => error.OutOfMemory,
            error.TooLarge, error.Unavailable => error.Unavailable,
        };
        if (stat.kind != .directory) return error.NotABacklog;

        const root_path = try allocator.dupe(u8, std.mem.trimEnd(u8, root_dir, "/"));
        errdefer allocator.free(root_path);
        const read_buffer = try allocator.alloc(u8, limits.max_file_bytes);
        errdefer allocator.free(read_buffer);

        var project: Project = .{
            .allocator = allocator,
            .io = io,
            .context = context,
            .limits = limits,
            .root_path = root_path,
            .read_buffer = read_buffer,
            .config_arena = .init(allocator),
        };
        errdefer project.releaseContent();
        _ = try project.refreshConfig();
        for (Location.all) |location| try project.scanLocation(location, null, null);
        return project;
    }

    /// Release every file, the config, the watches and the buffers.
    pub fn deinit(self: *Project) void {
        self.unwatch();
        self.releaseContent();
        self.allocator.free(self.read_buffer);
        self.allocator.free(self.root_path);
        self.* = undefined;
    }

    fn releaseContent(self: *Project) void {
        for (self.entries.items) |entry| entry.destroy(self.allocator);
        self.entries.deinit(self.allocator);
        self.config_arena.deinit();
    }

    /// The `backlog/` directory this project reads.
    pub fn root(self: *const Project) []const u8 {
        return self.root_path;
    }

    /// The directory that contains `backlog/`: where the CLI runs.
    pub fn projectDirectory(self: *const Project) []const u8 {
        return std.fs.path.dirnamePosix(self.root_path) orelse ".";
    }

    /// The settings from `config.yml`, or the defaults.
    pub fn config(self: *const Project) *const Config {
        return &self.settings;
    }

    /// Iterate one kind of item, in location then path order. Pointers stay
    /// valid until the next `poll` or `deinit`.
    pub fn Iterator(comptime tag: std.meta.Tag(Item)) type {
        const Value = @FieldType(Item, @tagName(tag));
        return struct {
            entries: []const *Entry,
            index: usize = 0,

            pub fn next(self: *@This()) ?*const Value {
                while (self.index < self.entries.len) {
                    const entry = self.entries[self.index];
                    self.index += 1;
                    if (entry.item) |*item| {
                        if (item.* == tag) return &@field(item.*, @tagName(tag));
                    }
                }
                return null;
            }
        };
    }

    pub fn tasks(self: *const Project) Iterator(.task) {
        return .{ .entries = self.entries.items };
    }

    pub fn milestones(self: *const Project) Iterator(.milestone) {
        return .{ .entries = self.entries.items };
    }

    pub fn docs(self: *const Project) Iterator(.doc) {
        return .{ .entries = self.entries.items };
    }

    pub fn decisions(self: *const Project) Iterator(.decision) {
        return .{ .entries = self.entries.items };
    }

    /// The number of tasks in every location.
    pub fn taskCount(self: *const Project) usize {
        var count: usize = 0;
        var iterator = self.tasks();
        while (iterator.next()) |_| count += 1;
        return count;
    }

    /// The task with `id` (ASCII case-insensitive, as the CLI matches ids).
    pub fn findTask(self: *const Project, id: []const u8) ?*const Task {
        var iterator = self.tasks();
        while (iterator.next()) |task| {
            if (std.ascii.eqlIgnoreCase(task.id, id)) return task;
        }
        return null;
    }

    /// The milestone a task names: by id, else by exact title.
    pub fn findMilestone(self: *const Project, key: []const u8) ?*const Milestone {
        var iterator = self.milestones();
        while (iterator.next()) |milestone| {
            if (std.ascii.eqlIgnoreCase(milestone.id, key)) return milestone;
        }
        iterator = self.milestones();
        while (iterator.next()) |milestone| {
            if (std.mem.eql(u8, milestone.title, key)) return milestone;
        }
        return null;
    }

    /// Every current diagnostic: config, directories, then files.
    pub fn diagnostics(self: *const Project) DiagnosticIterator {
        return .{ .project = self };
    }

    pub const DiagnosticIterator = struct {
        project: *const Project,
        stage: enum { config, dirs, files, done } = .config,
        index: usize = 0,
        inner: usize = 0,

        pub fn next(self: *DiagnosticIterator) ?Diagnostic {
            while (true) switch (self.stage) {
                .config => {
                    if (self.index < self.project.config_diagnostics.len) {
                        self.index += 1;
                        return self.project.config_diagnostics[self.index - 1];
                    }
                    self.stage = .dirs;
                    self.index = 0;
                },
                .dirs => {
                    while (self.index < self.project.dir_problems.len) {
                        self.index += 1;
                        if (self.project.dir_problems[self.index - 1]) |problem| return problem;
                    }
                    self.stage = .files;
                    self.index = 0;
                },
                .files => {
                    const entries = self.project.entries.items;
                    while (self.index < entries.len) {
                        const entry = entries[self.index];
                        if (self.inner < entry.diagnostics.len) {
                            self.inner += 1;
                            return entry.diagnostics[self.inner - 1];
                        }
                        self.index += 1;
                        self.inner = 0;
                    }
                    self.stage = .done;
                },
                .done => return null,
            };
        }
    };

    /// The number of current diagnostics.
    pub fn diagnosticCount(self: *const Project) usize {
        var count: usize = 0;
        var iterator = self.diagnostics();
        while (iterator.next()) |_| count += 1;
        return count;
    }

    /// Start watching the root and every location directory through the
    /// context. Directories that do not exist yet are watched for their
    /// appearance. On `error.Unsupported` (a context without watches) `poll`
    /// still works by comparing every file's size and mtime.
    pub fn watch(self: *Project) workspace.WatchError!void {
        errdefer self.unwatch();
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        if (self.watches[0] == null) {
            self.watches[0] = try self.context.watch(self.allocator, self.io, self.root_path);
        }
        for (Location.all, 1..) |location, slot| {
            if (self.watches[slot] != null) continue;
            const path = self.locationPath(&path_buffer, location) catch return error.Unavailable;
            self.watches[slot] = try self.context.watch(self.allocator, self.io, path);
        }
    }

    /// Release every watch; `poll` falls back to full comparison.
    pub fn unwatch(self: *Project) void {
        for (&self.watches) |*slot| {
            if (slot.*) |*handle| handle.deinit();
            slot.* = null;
        }
    }

    fn watching(self: *const Project) bool {
        for (self.watches) |slot| {
            if (slot == null) return false;
        }
        return true;
    }

    /// Bring the model up to date with the files and report what changed.
    ///
    /// With watches, only directories whose watch fired are listed, and in
    /// them only files whose size or mtime differ are re-read; without, every
    /// directory is compared. Change paths and ids are allocated with
    /// `change_allocator` (an arena is the natural choice).
    pub fn poll(self: *Project, change_allocator: Allocator) Allocator.Error![]Change {
        var changes: std.ArrayList(Change) = .empty;
        errdefer changes.deinit(change_allocator);

        var dirty: [Location.all.len]bool = .{true} ** Location.all.len;
        var root_dirty = true;
        if (self.watching()) {
            // Poll every handle so each one's pending flag is consumed.
            root_dirty = self.watches[0].?.pollChanges();
            for (&dirty, 1..) |*flag, slot| flag.* = self.watches[slot].?.pollChanges();
        }
        if (root_dirty) {
            if (try self.refreshConfig()) {
                // New statuses change which tasks are diagnosed: re-parse all.
                // The CLI rewriting config.yml with the same statuses does not.
                for (self.entries.items) |entry| entry.stale = true;
            }
            dirty = .{true} ** Location.all.len;
        }
        for (Location.all, dirty) |location, flag| {
            if (flag) try self.scanLocation(location, &changes, change_allocator);
        }
        return changes.toOwnedSlice(change_allocator);
    }

    fn locationPath(self: *const Project, buffer: []u8, location: Location) error{NoSpaceLeft}![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}/{s}", .{ self.root_path, location.dirName() });
    }

    /// Re-read `config.yml` when its signature changed. Returns whether the
    /// replacement changes how task files parse (`Config.parsesLike`).
    fn refreshConfig(self: *Project) Allocator.Error!bool {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "{s}/config.yml", .{self.root_path}) catch {
            return self.replaceConfig(null, "the project path is too long");
        };
        const stat = self.context.statPath(self.io, path) catch |err| {
            if (self.config_signature == null and self.config_diagnostics.len > 0) return false;
            return self.replaceConfig(null, switch (err) {
                error.NotFound => "config.yml is missing; using the default settings",
                else => "config.yml could not be read; using the default settings",
            });
        };
        const signature = Signature.of(stat);
        if (self.config_signature) |previous| {
            if (previous.eql(signature)) return false;
        }
        if (stat.size > self.limits.max_file_bytes) return self.replaceConfig(signature, "config.yml is larger than the limit; using the default settings");
        const text = self.context.readFile(self.io, path, self.read_buffer) catch {
            return self.replaceConfig(signature, "config.yml could not be read; using the default settings");
        };

        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        errdefer arena.deinit();
        const owned_path = try arena.allocator().dupe(u8, path);
        const owned_text = try arena.allocator().dupe(u8, text);
        const parsed = try parseConfig(arena.allocator(), owned_path, owned_text, self.limits);
        const reparse = !parsed.config.parsesLike(self.settings);
        self.config_arena.deinit();
        self.config_arena = arena;
        self.settings = parsed.config;
        self.config_diagnostics = parsed.diagnostics;
        self.config_signature = signature;
        return reparse;
    }

    fn replaceConfig(self: *Project, signature: ?Signature, message: []const u8) Allocator.Error!bool {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        errdefer arena.deinit();
        const one = try arena.allocator().alloc(Diagnostic, 1);
        one[0] = .{ .path = "config.yml", .message = message };
        const reparse = !(Config{}).parsesLike(self.settings);
        self.config_arena.deinit();
        self.config_arena = arena;
        self.settings = .{};
        self.config_diagnostics = one;
        self.config_signature = signature;
        return reparse;
    }

    const NameCollector = struct {
        arena: Allocator,
        names: std.ArrayList([]const u8) = .empty,
        limit: usize,
        overflow: bool = false,
        out_of_memory: bool = false,

        fn visit(ptr: *anyopaque, entry: workspace.DirEntry) bool {
            const self: *NameCollector = @ptrCast(@alignCast(ptr));
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) return true;
            if (self.names.items.len >= self.limit) {
                self.overflow = true;
                return false;
            }
            const name = self.arena.dupe(u8, entry.name) catch {
                self.out_of_memory = true;
                return false;
            };
            self.names.append(self.arena, name) catch {
                self.out_of_memory = true;
                return false;
            };
            return true;
        }
    };

    /// Compare one directory with the model: read new and changed files,
    /// drop removed ones, and report each when `changes` is given.
    fn scanLocation(
        self: *Project,
        location: Location,
        changes: ?*std.ArrayList(Change),
        change_allocator: ?Allocator,
    ) Allocator.Error!void {
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        const temp = scratch.allocator();

        var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const dir_path = self.locationPath(&dir_buffer, location) catch {
            self.dir_problems[@intFromEnum(location)] = .{ .path = location.dirName(), .message = "the project path is too long" };
            return;
        };
        var collector: NameCollector = .{ .arena = temp, .limit = self.limits.max_files_per_dir };
        self.dir_problems[@intFromEnum(location)] = null;
        self.context.listDir(self.io, dir_path, .{ .context = &collector, .visit_fn = NameCollector.visit }) catch |err| switch (err) {
            // An absent directory is an empty one: Backlog.md creates them lazily.
            error.NotFound => {},
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                // Keep what was loaded rather than report every file removed
                // because one listing failed.
                self.dir_problems[@intFromEnum(location)] = .{
                    .path = location.dirName(),
                    .message = "the directory could not be listed; showing its last contents",
                };
                return;
            },
        };
        if (collector.out_of_memory) return error.OutOfMemory;
        if (collector.overflow) {
            self.dir_problems[@intFromEnum(location)] = .{
                .path = location.dirName(),
                .message = "too many files; the rest are ignored",
            };
        }

        var seen: std.AutoHashMapUnmanaged(*Entry, void) = .empty;
        for (collector.names.items) |name| {
            const path = try std.fmt.allocPrint(temp, "{s}/{s}", .{ dir_path, name });
            const existing_index = self.indexOfPath(path);
            const stat = self.context.statPath(self.io, path) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                // Gone between listing and stat: the next scan settles it.
                if (existing_index) |index| try seen.put(temp, self.entries.items[index], {});
                continue;
            };
            const signature = Signature.of(stat);
            if (existing_index) |index| {
                const existing = self.entries.items[index];
                if (!existing.stale and existing.signature.eql(signature)) {
                    try seen.put(temp, existing, {});
                    continue;
                }
            }
            const fresh = try self.readEntry(location, path, signature);
            errdefer fresh.destroy(self.allocator);
            // Recorded before `fresh` joins `entries`, so the errdefer above
            // can never free an entry the model still holds.
            try seen.put(temp, fresh, {});
            if (existing_index) |index| {
                const old = self.entries.items[index];
                try self.report(changes, change_allocator, .updated, fresh);
                self.entries.items[index] = fresh;
                old.destroy(self.allocator);
            } else {
                try self.entries.ensureUnusedCapacity(self.allocator, 1);
                try self.report(changes, change_allocator, .added, fresh);
                self.entries.appendAssumeCapacity(fresh);
            }
        }

        var index: usize = 0;
        while (index < self.entries.items.len) {
            const entry = self.entries.items[index];
            if (entry.location != location or seen.contains(entry)) {
                index += 1;
                continue;
            }
            try self.report(changes, change_allocator, .removed, entry);
            _ = self.entries.orderedRemove(index);
            entry.destroy(self.allocator);
        }
        std.mem.sort(*Entry, self.entries.items, {}, entryLessThan);
    }

    fn entryLessThan(_: void, a: *Entry, b: *Entry) bool {
        if (a.location != b.location) return @intFromEnum(a.location) < @intFromEnum(b.location);
        return std.mem.lessThan(u8, a.path, b.path);
    }

    fn indexOfPath(self: *const Project, path: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.path, path)) return index;
        }
        return null;
    }

    fn report(
        _: *Project,
        changes: ?*std.ArrayList(Change),
        change_allocator: ?Allocator,
        kind: ChangeKind,
        entry: *const Entry,
    ) Allocator.Error!void {
        const list = changes orelse return;
        const allocator = change_allocator.?;
        try list.ensureUnusedCapacity(allocator, 1);
        const path = try allocator.dupe(u8, entry.path);
        errdefer allocator.free(path);
        const id: ?[]const u8 = if (entry.item) |*item| try allocator.dupe(u8, item.id()) else null;
        list.appendAssumeCapacity(.{ .kind = kind, .location = entry.location, .path = path, .id = id });
    }

    /// Read and parse one file into a new entry. Read failures become the
    /// entry's diagnostic, so the file still shows up as present.
    fn readEntry(self: *Project, location: Location, path: []const u8, signature: Signature) Allocator.Error!*Entry {
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .arena = .init(self.allocator),
            .location = location,
            .path = &.{},
            .signature = signature,
            .item = null,
            .diagnostics = &.{},
        };
        errdefer entry.arena.deinit();
        const arena = entry.arena.allocator();
        entry.path = try arena.dupe(u8, path);

        const failure: ?[]const u8 = if (signature.size > self.limits.max_file_bytes)
            "the file is larger than the size limit and was not read"
        else if (self.context.readFile(self.io, path, self.read_buffer)) |text| blk: {
            const owned = try arena.dupe(u8, text);
            const parsed = try parseFile(arena, location, entry.path, owned, &self.settings, self.limits);
            entry.item = parsed.item;
            entry.diagnostics = parsed.diagnostics;
            break :blk null;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooLarge => "the file is larger than the size limit and was not read",
            else => "the file could not be read",
        };
        if (failure) |message| {
            const one = try arena.alloc(Diagnostic, 1);
            one[0] = .{ .path = entry.path, .message = message };
            entry.diagnostics = one;
        }
        return entry;
    }
};

/// The write path: the `backlog` CLI, run through the workspace's
/// ExecutionContext with the project directory as its cwd.
///
/// Conduit never edits backlog markdown itself. Each wrapper validates its
/// arguments (ids by `isTaskId`, values as single-line or note text), passes
/// each value as one `--option=value` argv entry with no shell, and returns
/// the CLI's verdict: `.ok` with stdout, or `.failed` with the exit status and
/// stderr for the view to show. `error.CliUnavailable` means the context has
/// no `backlog` program (or cannot run commands), so the caller can present
/// the backlog read-only.
///
/// Threads: every call waits for the child, up to `timeout_ms`, so it runs on
/// a worker thread. All slices are borrowed for the call; outcomes are owned
/// by `allocator`.
pub const Cli = struct {
    allocator: Allocator,
    io: std.Io,
    context: ContextRef,
    /// The directory that contains `backlog/` (`Project.projectDirectory`).
    project_dir: []const u8,
    program: []const u8 = "backlog",
    timeout_ms: u32 = 15_000,
    max_output: usize = 256 * 1024,

    pub const Error = error{
        /// The context has no `backlog` program, or cannot run commands.
        CliUnavailable,
        /// An id or value failed validation; nothing was run.
        InvalidArgument,
        Timeout,
        OutputTooLarge,
        OutOfMemory,
        /// The command could not be started or observed.
        Unavailable,
    };

    /// A command that ran and failed. `stderr` is owned.
    pub const Failure = struct {
        /// The exit status, or null when the CLI was killed by a signal.
        exit_code: ?u8,
        signal: ?u32,
        stderr: []u8,

        /// The CLI's own explanation, trimmed for display.
        pub fn message(self: Failure) []const u8 {
            return std.mem.trim(u8, self.stderr, " \t\r\n");
        }
    };

    /// The verdict of one CLI call. Release it with `deinit`.
    pub const Outcome = union(enum) {
        /// The CLI's stdout.
        ok: []u8,
        failed: Failure,

        pub fn deinit(self: *Outcome, allocator: Allocator) void {
            switch (self.*) {
                .ok => |stdout| allocator.free(stdout),
                .failed => |failure| allocator.free(failure.stderr),
            }
            self.* = undefined;
        }
    };

    pub const Version = struct { major: u32, minor: u32, patch: u32 };

    /// The most argv entries one call passes.
    pub const max_args = 16;
    /// The longest single-line value (status, title, assignee, priority).
    pub const max_value_bytes = 1024;
    /// The longest note.
    pub const max_note_bytes = 16 * 1024;

    /// Whether the context has a working `backlog`, and its version when the
    /// CLI prints one (`backlog --version`). `error.CliUnavailable` when not.
    pub fn detect(self: Cli) Error!?Version {
        var outcome = try self.run(&.{"--version"});
        defer outcome.deinit(self.allocator);
        switch (outcome) {
            .failed => return error.CliUnavailable,
            .ok => |stdout| {
                const text = std.mem.trim(u8, stdout, " \t\r\n");
                const version = std.SemanticVersion.parse(text) catch return null;
                return .{
                    .major = std.math.cast(u32, version.major) orelse return null,
                    .minor = std.math.cast(u32, version.minor) orelse return null,
                    .patch = std.math.cast(u32, version.patch) orelse return null,
                };
            },
        }
    }

    /// Run `backlog <args>` in the project directory. `args` are passed
    /// verbatim, so callers build them from validated user input, never from
    /// backlog file content; the wrappers below are the supported surface.
    pub fn run(self: Cli, args: []const []const u8) Error!Outcome {
        if (args.len >= max_args) return error.InvalidArgument;
        var argv: [max_args][]const u8 = undefined;
        argv[0] = self.program;
        @memcpy(argv[1 .. args.len + 1], args);

        var result = self.context.run(self.allocator, self.io, .{
            .argv = argv[0 .. args.len + 1],
            .cwd = self.project_dir,
            .max_output = self.max_output,
            .timeout_ms = self.timeout_ms,
        }) catch |err| return switch (err) {
            error.CommandNotFound, error.AccessDenied, error.Unsupported => error.CliUnavailable,
            error.InvalidRequest => error.InvalidArgument,
            error.Timeout => error.Timeout,
            error.OutputTooLarge => error.OutputTooLarge,
            error.OutOfMemory => error.OutOfMemory,
            error.SpawnFailed, error.Unavailable => error.Unavailable,
        };
        if (result.succeeded()) {
            self.allocator.free(result.stderr);
            return .{ .ok = result.stdout };
        }
        self.allocator.free(result.stdout);
        if (result.exit_code == null) {
            log.warn("backlog CLI ended without an exit status (signal {?d})", .{result.signal});
        }
        return .{ .failed = .{ .exit_code = result.exit_code, .signal = result.signal, .stderr = result.stderr } };
    }

    /// `backlog task edit <id> --status=<status>`.
    pub fn setStatus(self: Cli, id: []const u8, status: []const u8) Error!Outcome {
        return self.editOne(id, "--status=", status, .single_line);
    }

    /// Check (or uncheck) acceptance criterion `index` (the 1-based `#N`).
    pub fn checkAcceptance(self: Cli, id: []const u8, index: u32, checked: bool) Error!Outcome {
        if (index == 0) return error.InvalidArgument;
        var buffer: [32]u8 = undefined;
        const value = std.fmt.bufPrint(&buffer, "{d}", .{index}) catch unreachable; // 32 bytes hold any u32.
        return self.editOne(id, if (checked) "--check-ac=" else "--uncheck-ac=", value, .single_line);
    }

    /// `backlog task edit <id> --title=<title>`.
    pub fn editTitle(self: Cli, id: []const u8, title: []const u8) Error!Outcome {
        return self.editOne(id, "--title=", title, .single_line);
    }

    /// Append to the task's implementation notes.
    pub fn addNote(self: Cli, id: []const u8, note: []const u8) Error!Outcome {
        return self.editOne(id, "--append-notes=", note, .note);
    }

    /// Replace the task's assignees with one (`@name`).
    pub fn setAssignee(self: Cli, id: []const u8, assignee: []const u8) Error!Outcome {
        return self.editOne(id, "--assignee=", assignee, .single_line);
    }

    /// `backlog task edit <id> --priority=<high|medium|low>`.
    pub fn setPriority(self: Cli, id: []const u8, priority: Priority) Error!Outcome {
        return self.editOne(id, "--priority=", @tagName(priority), .single_line);
    }

    const ValueKind = enum { single_line, note };

    fn editOne(self: Cli, id: []const u8, option: []const u8, value: []const u8, kind: ValueKind) Error!Outcome {
        if (!isTaskId(id)) return error.InvalidArgument;
        if (!validValue(value, kind)) return error.InvalidArgument;
        const argument = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ option, value }) catch return error.OutOfMemory;
        defer self.allocator.free(argument);
        return self.run(&.{ "task", "edit", id, argument, "--plain" });
    }

    /// Non-empty valid UTF-8 with no control characters (a note may also hold
    /// newlines and tabs), within the length bound.
    fn validValue(value: []const u8, kind: ValueKind) bool {
        const limit: usize = switch (kind) {
            .single_line => max_value_bytes,
            .note => max_note_bytes,
        };
        if (value.len == 0 or value.len > limit) return false;
        if (!std.unicode.utf8ValidateSlice(value)) return false;
        if (std.mem.trim(u8, value, " \t\r\n").len == 0) return false;
        for (value) |c| {
            const control = c < 0x20 or c == 0x7f;
            const allowed = kind == .note and (c == '\n' or c == '\t');
            if (control and !allowed) return false;
        }
        return true;
    }
};

/// The most bytes `taskPrompt` writes: an agent's initial prompt is one argv
/// entry, so a huge task is cut rather than handed over whole.
pub const max_task_prompt_bytes: usize = 16 * 1024;

/// What a cut prompt ends with.
pub const task_prompt_truncated = "\n[… task truncated]";

/// The initial prompt of an agent started on `task` (TASK-64):
///
/// ```text
/// TASK-7: <title>
///
/// <description>
///
/// Acceptance criteria:
/// - [ ] #1 <criterion>
/// ```
///
/// Written into `buffer` (at most `max_task_prompt_bytes` of it are used)
/// and returned. Task text is untrusted: invalid UTF-8 becomes U+FFFD and
/// control characters other than line breaks and tabs become spaces. A task
/// that does not fit is cut on a character boundary and ends with
/// `task_prompt_truncated`. The prompt is handed to the agent only by the
/// human's explicit start gesture, and is never logged.
pub fn taskPrompt(buffer: []u8, task: *const Task) []const u8 {
    const limit = @min(buffer.len, max_task_prompt_bytes);
    if (limit <= task_prompt_truncated.len) return buffer[0..0];
    const body_limit = limit - task_prompt_truncated.len;
    var writer: std.Io.Writer = .fixed(buffer[0..body_limit]);
    const complete = writePrompt(&writer, task);
    var len = writer.end;
    if (complete) return buffer[0..len];
    while (len != 0 and !std.unicode.utf8ValidateSlice(buffer[0..len])) len -= 1;
    @memcpy(buffer[len .. len + task_prompt_truncated.len], task_prompt_truncated);
    return buffer[0 .. len + task_prompt_truncated.len];
}

/// Whether the whole prompt fit.
fn writePrompt(writer: *std.Io.Writer, task: *const Task) bool {
    writeClean(writer, task.id) catch return false;
    writer.writeAll(": ") catch return false;
    writeClean(writer, task.title) catch return false;
    writer.writeAll("\n") catch return false;
    if (task.description) |description| {
        writer.writeAll("\n") catch return false;
        writeClean(writer, description) catch return false;
        writer.writeAll("\n") catch return false;
    }
    if (task.acceptance_criteria.len != 0) {
        writer.writeAll("\nAcceptance criteria:\n") catch return false;
        for (task.acceptance_criteria) |criterion| {
            writer.print("- [{s}] #{d} ", .{ if (criterion.checked) "x" else " ", criterion.index }) catch return false;
            writeClean(writer, criterion.text) catch return false;
            writer.writeAll("\n") catch return false;
        }
    }
    return true;
}

fn writeClean(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch {
            try writer.writeAll("\u{FFFD}");
            index += 1;
            continue;
        };
        if (index + length > text.len) {
            try writer.writeAll("\u{FFFD}");
            return;
        }
        const codepoint = std.unicode.utf8Decode(text[index .. index + length]) catch {
            try writer.writeAll("\u{FFFD}");
            index += 1;
            continue;
        };
        const control = codepoint < 0x20 or (codepoint >= 0x7f and codepoint < 0xa0);
        if (codepoint == '\r') {
            // Dropped: a CRLF is one line break.
        } else if (control and codepoint != '\n' and codepoint != '\t') {
            try writer.writeByte(' ');
        } else {
            try writer.writeAll(text[index .. index + length]);
        }
        index += length;
    }
}

test "a task id round-trips through its canonical spelling" {
    try testing.expectEqual(@as(u32, 1), (try TaskId.parse("TASK-1")).number);
    try testing.expectEqual(@as(u32, 70), (try TaskId.parse("TASK-70")).number);

    for ([_]u32{ 1, 9, 10, 27, 70, 1000 }) |number| {
        var buf: [16]u8 = undefined;
        const written = try (TaskId{ .number = number }).format(&buf);
        try testing.expectEqualStrings("TASK-", TaskId.prefix);
        try testing.expectEqual(number, (try TaskId.parse(written)).number);
        // Nothing is written past what is returned.
        try testing.expect(written.len <= buf.len);
    }
}

test "a task id that is not canonical is not an id" {
    for ([_][]const u8{
        "", // nothing at all
        "task-27", // lower case: the file name, not the id
        "TASK-", // prefix with no number
        "TASK-0", // no task zero
        "TASK-027", // one task, two spellings
        "TASK-4a", // trailing junk
        "TASK--1", // sign where a digit belongs
        " TASK-27", // padded
        "TASK-27 ", // padded
        "TASK-4294967296", // past the largest id
    }) |malformed| {
        try testing.expectError(error.MalformedTaskId, TaskId.parse(malformed));
    }
}

test "a task is To Do, In Progress or Done" {
    try testing.expectEqual(@as(usize, 3), Status.all.len);

    for (Status.all) |status| {
        try testing.expectEqual(status, try Status.parse(status.display()));
        // Only "Done" is finished; the other two still want work.
        try testing.expect(status.isComplete() == (status == .done));
    }

    for ([_][]const u8{
        "", // nothing at all
        "todo", // a spelling the files do not use
        "In progress", // right words, wrong case
        "IN PROGRESS",
        "done ",
        "Done!", // punctuation is not part of the status
        "Closed", // backlog.md has no fourth status
    }) |malformed| {
        try testing.expectError(error.MalformedStatus, Status.parse(malformed));
    }
}

test {
    _ = yaml;
    _ = markdown;
}

const testing = std.testing;

/// A Local context for fixture tests, released by the caller.
/// A Local context whose watches report a change on the next poll on every
/// OS: inotify does on Linux, and the polling watch elsewhere is told to scan
/// every time instead of once a second, so a test's write is seen at once.
fn localContext() !workspace.ExecutionContext {
    return workspace.ExecutionContext.localWithWatchInterval(testing.allocator, 0);
}

fn countDiagnostics(project: *const Project, path_fragment: []const u8) usize {
    var count: usize = 0;
    var iterator = project.diagnostics();
    while (iterator.next()) |diagnostic| {
        if (std.mem.indexOf(u8, diagnostic.path, path_fragment) != null) count += 1;
    }
    return count;
}

test "task ids accepted by the CLI wrappers" {
    for ([_][]const u8{ "TASK-1", "TASK-62", "TASK-69.1", "task-7", "DRAFT-3", "T_X-1.2.3" }) |id| {
        try testing.expect(isTaskId(id));
    }
    for ([_][]const u8{ "", "--force", "-s", "TASK-", "TASK-01", "TASK-1.", "TASK-1..2", "TASK-1 ", "1-2", "TASK-1;rm", "TASK-x" }) |id| {
        try testing.expect(!isTaskId(id));
    }
}

test "the valid fixture parses every field of the model" {
    var context = try localContext();
    defer context.deinit();
    var project = try Project.load(testing.allocator, testing.io, context.borrow(), "test/fixtures/backlog/valid", .{});
    defer project.deinit();

    try testing.expectEqual(@as(usize, 0), project.diagnosticCount());
    try testing.expectEqualStrings("Fixture", project.config().project_name);
    try testing.expectEqual(@as(usize, 4), project.config().statuses.len);
    try testing.expectEqualStrings("Review", project.config().statuses[2]);
    try testing.expectEqualStrings("To Do", project.config().default_status);
    try testing.expectEqualStrings("test/fixtures/backlog", project.projectDirectory());

    // Four tasks on the board, one completed, one draft; README.txt is not a task.
    try testing.expectEqual(@as(usize, 5), project.taskCount());

    const first = project.findTask("TASK-1").?;
    try testing.expectEqualStrings("First task: parse the model", first.title);
    try testing.expectEqualStrings("To Do", first.status);
    try testing.expectEqual(@as(usize, 2), first.assignee.len);
    try testing.expectEqualStrings("@codex", first.assignee[0]);
    try testing.expectEqualStrings("@claude", first.assignee[1]);
    try testing.expectEqual(@as(usize, 2), first.labels.len);
    try testing.expectEqualStrings("architecture", first.labels[1]);
    try testing.expectEqualStrings("m-1", first.milestone.?);
    try testing.expectEqual(@as(usize, 2), first.dependencies.len);
    try testing.expectEqualStrings("TASK-2", first.dependencies[0]);
    try testing.expectEqualStrings("TASK-3", first.dependencies[1]);
    try testing.expectEqual(Priority.high, first.priority.?);
    try testing.expectEqual(@as(f64, 1000), first.ordinal.?);
    try testing.expectEqualStrings("2026-10-03 21:39", first.created_date.?);
    try testing.expectEqualStrings("2026-10-06 04:08", first.updated_date.?);
    try testing.expect(first.parent == null);
    try testing.expectEqualStrings("Read the project into a typed model.", first.description.?);
    try testing.expectEqualStrings("1. Parse.\n2. Watch.", first.plan.?);
    try testing.expectEqualStrings("Notes go here.", first.notes.?);
    try testing.expectEqualStrings("Done well.", first.final_summary.?);
    try testing.expectEqual(TaskState.active, first.state);
    try testing.expect(std.mem.endsWith(u8, first.path, "tasks/task-1 - First-task.md"));
    try testing.expectEqual(@as(usize, 3), first.acceptance_criteria.len);
    try testing.expectEqualDeep(Criterion{ .index = 1, .checked = false, .text = "Tasks are parsed" }, first.acceptance_criteria[0]);
    try testing.expect(first.acceptance_criteria[1].checked);
    try testing.expectEqualStrings("Statuses are parsed", first.acceptance_criteria[1].text);
    try testing.expectEqual(@as(u32, 3), first.acceptance_criteria[2].index);
    try testing.expect(!first.acceptance_criteria[2].checked);

    // Milestone linkage, by id and by title.
    const milestone = project.findMilestone(first.milestone.?).?;
    try testing.expectEqualStrings("M1 - First", milestone.title);
    try testing.expectEqualStrings("The first milestone.", milestone.description.?);
    try testing.expectEqual(milestone, project.findMilestone("M1 - First").?);
    try testing.expect(project.findMilestone("m-9") == null);

    const second = project.findTask("task-2").?;
    try testing.expectEqualStrings("A long title that the backlog tool folded across two lines", second.title);
    try testing.expectEqualStrings("In Progress", second.status);
    try testing.expectEqual(@as(usize, 0), second.assignee.len);
    try testing.expectEqual(@as(usize, 2), second.labels.len);
    try testing.expectEqualStrings("board view", second.labels[1]);
    try testing.expectEqual(@as(usize, 1), second.dependencies.len);
    try testing.expectEqual(Priority.medium, second.priority.?);
    try testing.expectEqual(@as(usize, 0), second.acceptance_criteria.len);
    try testing.expect(second.plan == null);

    const subtask = project.findTask("TASK-2.1").?;
    try testing.expectEqualStrings("Review", subtask.status);
    try testing.expectEqualStrings("TASK-2", subtask.parent.?);
    try testing.expectEqual(Priority.low, subtask.priority.?);

    const finished = project.findTask("TASK-3").?;
    try testing.expectEqual(TaskState.completed, finished.state);
    try testing.expectEqualStrings("Done", finished.status);
    try testing.expect(finished.acceptance_criteria[0].checked);
    try testing.expectEqualStrings("M2 - Second", project.findMilestone(finished.milestone.?).?.title);

    try testing.expectEqual(TaskState.draft, project.findTask("DRAFT-1").?.state);

    var milestones = project.milestones();
    var milestone_count: usize = 0;
    while (milestones.next()) |_| milestone_count += 1;
    try testing.expectEqual(@as(usize, 2), milestone_count);

    var docs = project.docs();
    const doc = docs.next().?;
    try testing.expectEqualStrings("doc-1", doc.id);
    try testing.expectEqualStrings("guide", doc.doc_type.?);
    try testing.expect(docs.next() == null);

    var decisions = project.decisions();
    const decision = decisions.next().?;
    try testing.expectEqualStrings("Use the CLI for writes", decision.title);
    try testing.expectEqualStrings("accepted", decision.status.?);
    try testing.expectEqualStrings("2026-10-06 19:53", decision.date.?);
    try testing.expect(decisions.next() == null);

    // Tasks iterate in location order: the board, then completed, then drafts.
    var tasks_in_order = project.tasks();
    try testing.expectEqualStrings("TASK-1", tasks_in_order.next().?.id);
    try testing.expectEqualStrings("TASK-2", tasks_in_order.next().?.id);
    try testing.expectEqualStrings("TASK-2.1", tasks_in_order.next().?.id);
    try testing.expectEqualStrings("TASK-3", tasks_in_order.next().?.id);
    try testing.expectEqualStrings("DRAFT-1", tasks_in_order.next().?.id);
}

test "malformed files become diagnostics, never errors" {
    var context = try localContext();
    defer context.deinit();
    var project = try Project.load(testing.allocator, testing.io, context.borrow(), "test/fixtures/backlog/malformed", .{});
    defer project.deinit();

    // The unterminated statuses list falls back to the defaults.
    try testing.expectEqual(@as(usize, 3), project.config().statuses.len);
    try testing.expect(countDiagnostics(&project, "config.yml") >= 2);

    // No front matter, unterminated front matter and a missing id leave no task.
    try testing.expect(project.findTask("TASK-2") == null);
    try testing.expectEqual(@as(usize, 1), countDiagnostics(&project, "No-front-matter"));
    try testing.expectEqual(@as(usize, 1), countDiagnostics(&project, "Unterminated"));
    try testing.expectEqual(@as(usize, 1), countDiagnostics(&project, "Missing-id"));

    // Bad values keep the task with each problem reported.
    const bad = project.findTask("TASK-4").?;
    try testing.expectEqualStrings("", bad.title);
    try testing.expectEqualStrings("Blocked", bad.status);
    try testing.expect(bad.priority == null);
    try testing.expect(bad.ordinal == null);
    try testing.expectEqual(@as(usize, 1), bad.acceptance_criteria.len);
    // Unterminated title, nested map, missing title, unknown status,
    // unknown priority, non-numeric ordinal.
    try testing.expectEqual(@as(usize, 6), countDiagnostics(&project, "Bad-values"));
    var iterator = project.diagnostics();
    var saw_status_line = false;
    while (iterator.next()) |diagnostic| {
        if (std.mem.indexOf(u8, diagnostic.path, "Bad-values") != null and diagnostic.line == 4) {
            try testing.expectEqualStrings("status is not one of config.yml's statuses", diagnostic.message);
            saw_status_line = true;
        }
    }
    try testing.expect(saw_status_line);

    // A flag-shaped id is parsed as data and flagged, and the CLI refuses it.
    try testing.expect(project.findTask("--force") != null);
    try testing.expectEqual(@as(usize, 1), countDiagnostics(&project, "Flag-id"));
    try testing.expectEqual(@as(usize, 2), project.taskCount());
}

test "a task's agent prompt carries its id, title, description and criteria within its bound" {
    var context = try localContext();
    defer context.deinit();
    var project = try Project.load(testing.allocator, testing.io, context.borrow(), "test/fixtures/backlog/valid", .{});
    defer project.deinit();
    var buffer: [max_task_prompt_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        "TASK-1: First task: parse the model\n\nRead the project into a typed model.\n\n" ++
            "Acceptance criteria:\n- [ ] #1 Tasks are parsed\n- [x] #2 Statuses are parsed\n- [ ] #3 Criteria keep their numbers\n",
        taskPrompt(&buffer, project.findTask("TASK-1").?),
    );
    try testing.expectEqualStrings("TASK-2.1: Subtask\n", taskPrompt(&buffer, project.findTask("TASK-2.1").?));

    // Controls are neutralised; a CRLF is one break.
    const hostile: Task = .{ .id = "TASK-9", .title = "a\x1b[2Jb", .status = "To Do", .description = "x\r\ny\x07", .path = "", .state = .active };
    try testing.expectEqualStrings("TASK-9: a [2Jb\n\nx\ny \n", taskPrompt(&buffer, &hostile));

    // A task larger than the bound is cut on a character boundary and marked.
    const huge = try testing.allocator.alloc(u8, 3 * max_task_prompt_bytes);
    defer testing.allocator.free(huge);
    var index: usize = 0;
    while (index + 3 <= huge.len) : (index += 3) @memcpy(huge[index .. index + 3], "é.");
    const big: Task = .{ .id = "TASK-10", .title = "big", .status = "To Do", .description = huge[0..index], .path = "", .state = .active };
    var large: [2 * max_task_prompt_bytes]u8 = undefined;
    const cut = taskPrompt(&large, &big);
    try testing.expect(cut.len <= max_task_prompt_bytes);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
    try testing.expect(std.mem.startsWith(u8, cut, "TASK-10: big\n\n"));
    try testing.expect(std.mem.endsWith(u8, cut, task_prompt_truncated));
    var tiny: [8]u8 = undefined;
    try testing.expectEqualStrings("", taskPrompt(&tiny, &big));
}

test "an empty project has its config and nothing else" {
    var context = try localContext();
    defer context.deinit();
    var project = try Project.load(testing.allocator, testing.io, context.borrow(), "test/fixtures/backlog/empty/", .{});
    defer project.deinit();
    try testing.expectEqualStrings("Empty", project.config().project_name);
    try testing.expectEqual(@as(usize, 0), project.taskCount());
    try testing.expectEqual(@as(usize, 0), project.diagnosticCount());
    var milestones = project.milestones();
    try testing.expect(milestones.next() == null);

    try testing.expectError(error.NotABacklog, Project.load(testing.allocator, testing.io, context.borrow(), "test/fixtures/backlog/absent", .{}));
    try testing.expectError(error.NotABacklog, Project.load(testing.allocator, testing.io, context.borrow(), "test/fixtures/backlog/empty/config.yml", .{}));
}

test "an oversized file is reported and not read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "tasks", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.yml", .data = "statuses: [To Do, Done]\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "tasks/task-1 - Small.md", .data = "---\nid: TASK-1\ntitle: Small\nstatus: To Do\n---\n" });
    const big = try testing.allocator.alloc(u8, 2048);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    @memcpy(big[0..30], "---\nid: TASK-2\ntitle: Big\n---\n");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "tasks/task-2 - Big.md", .data = big });

    var root_buffer: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    var context = try localContext();
    defer context.deinit();
    var project = try Project.load(testing.allocator, testing.io, context.borrow(), root, .{ .max_file_bytes = 1024 });
    defer project.deinit();

    try testing.expect(project.findTask("TASK-1") != null);
    try testing.expect(project.findTask("TASK-2") == null);
    var iterator = project.diagnostics();
    const diagnostic = iterator.next().?;
    try testing.expect(std.mem.endsWith(u8, diagnostic.path, "task-2 - Big.md"));
    try testing.expectEqualStrings("the file is larger than the size limit and was not read", diagnostic.message);
    try testing.expect(iterator.next() == null);
}

fn expectChange(changes: []const Change, kind: ChangeKind, id: ?[]const u8) !void {
    for (changes) |change| {
        if (change.kind != kind) continue;
        if (id == null and change.id == null) return;
        if (id != null and change.id != null and std.mem.eql(u8, id.?, change.id.?)) return;
    }
    return error.TestExpectedChange;
}

test "external edits update the model live through the context's watches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.yml", .data = "statuses: [To Do, In Progress, Done]\n" });

    var root_buffer: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    var context = try localContext();
    defer context.deinit();
    var project = try Project.load(testing.allocator, testing.io, context.borrow(), root, .{});
    defer project.deinit();
    try project.watch();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqual(@as(usize, 0), (try project.poll(arena)).len);

    // The tasks directory does not exist yet: create it and a task in one burst.
    try tmp.dir.createDir(testing.io, "tasks", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "tasks/task-1 - Live.md", .data = "---\nid: TASK-1\ntitle: Live\nstatus: To Do\n---\n" });
    var changes = try project.poll(arena);
    try testing.expectEqual(@as(usize, 1), changes.len);
    try expectChange(changes, .added, "TASK-1");
    try testing.expect(std.mem.endsWith(u8, changes[0].path, "tasks/task-1 - Live.md"));
    try testing.expectEqual(Location.tasks, changes[0].location);
    try testing.expectEqualStrings("Live", project.findTask("TASK-1").?.title);

    // Several writes to one file between polls coalesce into one update.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "tasks/task-1 - Live.md", .data = "---\nid: TASK-1\ntitle: Edit one\nstatus: To Do\n---\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "tasks/task-1 - Live.md", .data = "---\nid: TASK-1\ntitle: Edit two!\nstatus: In Progress\n---\n" });
    changes = try project.poll(arena);
    try testing.expectEqual(@as(usize, 1), changes.len);
    try expectChange(changes, .updated, "TASK-1");
    try testing.expectEqualStrings("Edit two!", project.findTask("TASK-1").?.title);
    try testing.expectEqualStrings("In Progress", project.findTask("TASK-1").?.status);

    // An unrelated file and an unchanged task are not reported.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "tasks/notes.txt", .data = "x" });
    try testing.expectEqual(@as(usize, 0), (try project.poll(arena)).len);

    // A second task, then a completion: the CLI moves the file to completed/.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "tasks/task-2 - Other.md", .data = "---\nid: TASK-2\ntitle: Other\nstatus: To Do\n---\n" });
    changes = try project.poll(arena);
    try expectChange(changes, .added, "TASK-2");
    try tmp.dir.createDir(testing.io, "completed", .default_dir);
    try tmp.dir.rename("tasks/task-2 - Other.md", tmp.dir, "completed/task-2 - Other.md", testing.io);
    changes = try project.poll(arena);
    try testing.expectEqual(@as(usize, 2), changes.len);
    try expectChange(changes, .removed, "TASK-2");
    try expectChange(changes, .added, "TASK-2");
    try testing.expectEqual(TaskState.completed, project.findTask("TASK-2").?.state);

    // Deletion.
    try tmp.dir.deleteFile(testing.io, "tasks/task-1 - Live.md");
    changes = try project.poll(arena);
    try testing.expectEqual(@as(usize, 1), changes.len);
    try expectChange(changes, .removed, "TASK-1");
    try testing.expect(project.findTask("TASK-1") == null);
    try testing.expectEqual(@as(usize, 1), project.taskCount());

    // Rewriting config.yml with the same statuses (the CLI normalises it on
    // every write) re-parses nothing.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.yml", .data = "statuses: [To Do, In Progress, Done]\ndefault_port: 6420\n" });
    try testing.expectEqual(@as(usize, 0), (try project.poll(arena)).len);

    // A config change re-parses every file against the new statuses.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "completed/task-2 - Other.md", .data = "---\nid: TASK-2\ntitle: Other\nstatus: Shipped\n---\n" });
    _ = try project.poll(arena);
    try testing.expectEqual(@as(usize, 1), project.diagnosticCount());
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.yml", .data = "statuses: [To Do, Shipped]\n" });
    changes = try project.poll(arena);
    try expectChange(changes, .updated, "TASK-2");
    try testing.expectEqual(@as(usize, 0), project.diagnosticCount());
}

test "without watches a poll compares every file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.yml", .data = "statuses: [To Do, Done]\n" });
    try tmp.dir.createDir(testing.io, "tasks", .default_dir);

    var root_buffer: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    var context = try localContext();
    defer context.deinit();
    var project = try Project.load(testing.allocator, testing.io, context.borrow(), root, .{});
    defer project.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "tasks/task-9 - Polled.md", .data = "---\nid: TASK-9\ntitle: Polled\nstatus: Done\n---\n" });
    const changes = try project.poll(arena_state.allocator());
    try testing.expectEqual(@as(usize, 1), changes.len);
    try expectChange(changes, .added, "TASK-9");
    try testing.expectEqual(@as(usize, 0), (try project.poll(arena_state.allocator())).len);
}

test "the repository's own backlog parses" {
    var context = try localContext();
    defer context.deinit();
    var project = try Project.load(testing.allocator, testing.io, context.borrow(), "backlog", .{});
    defer project.deinit();

    const task = project.findTask("TASK-62").?;
    try testing.expectEqualStrings("Backlog.md data layer", task.title);
    try testing.expectEqualStrings("m-7", task.milestone.?);
    try testing.expect(task.acceptance_criteria.len >= 4);
    try testing.expect(project.findMilestone("m-7") != null);
    try testing.expect(project.taskCount() >= 70);

    // Every file the tool wrote yields an item and no diagnostic; a failure
    // names the first offending file.
    for (project.entries.items) |entry| {
        if (entry.item == null) try testing.expectEqualStrings("(every file parsed)", entry.path);
    }
    var iterator = project.diagnostics();
    if (iterator.next()) |diagnostic| {
        try testing.expectEqualStrings("(no diagnostics)", diagnostic.path);
        try testing.expectEqualStrings("(no diagnostics)", diagnostic.message);
    }
}

/// A context whose `run` replays a script and records each argv, for the CLI
/// wrappers. It has no other capability.
const ScriptedRunContext = struct {
    allocator: Allocator,
    steps: []const Step,
    next_step: usize = 0,
    last_argv: [Cli.max_args][]u8 = undefined,
    last_argc: usize = 0,
    last_cwd: [256]u8 = undefined,
    last_cwd_len: usize = 0,

    const Step = union(enum) {
        result: struct { exit_code: ?u8, stdout: []const u8 = "", stderr: []const u8 = "" },
        fail: workspace.RunError,
    };

    const vtable: workspace.ExecutionContext.VTable = .{
        .spawn = spawn,
        .kind = kind,
        .destroy = destroy,
        .run = run,
    };

    fn context(self: *ScriptedRunContext) ContextRef {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // `backlog` does not import `pty`; the spawn entry's types come from the
    // vtable's own function type.
    const spawn_fn = @typeInfo(@typeInfo(workspace.ExecutionContext.SpawnFn).pointer.child).@"fn";

    fn spawn(_: *anyopaque, _: spawn_fn.params[1].type.?) spawn_fn.return_type.? {
        return error.SystemError;
    }

    fn kind(_: *const anyopaque) workspace.ExecutionContextKind {
        return .ssh;
    }

    fn destroy(_: *anyopaque) void {}

    fn clearArgv(self: *ScriptedRunContext) void {
        for (self.last_argv[0..self.last_argc]) |arg| self.allocator.free(arg);
        self.last_argc = 0;
    }

    fn run(ptr: *anyopaque, allocator: Allocator, _: std.Io, request: workspace.RunRequest) workspace.RunError!workspace.RunResult {
        const self: *ScriptedRunContext = @ptrCast(@alignCast(ptr));
        self.clearArgv();
        for (request.argv, 0..) |arg, i| {
            self.last_argv[i] = try self.allocator.dupe(u8, arg);
            self.last_argc = i + 1;
        }
        @memcpy(self.last_cwd[0..request.cwd.len], request.cwd);
        self.last_cwd_len = request.cwd.len;
        const step = self.steps[self.next_step];
        self.next_step += 1;
        switch (step) {
            .fail => |err| return err,
            .result => |result| {
                const stdout = try allocator.dupe(u8, result.stdout);
                errdefer allocator.free(stdout);
                return .{ .exit_code = result.exit_code, .stdout = stdout, .stderr = try allocator.dupe(u8, result.stderr) };
            },
        }
    }

    fn argv(self: *const ScriptedRunContext, index: usize) []const u8 {
        return self.last_argv[index];
    }
};

test "CLI wrappers pass validated argv and report success and failure" {
    var fake: ScriptedRunContext = .{
        .allocator = testing.allocator,
        .steps = &.{
            .{ .result = .{ .exit_code = 0, .stdout = "1.53.0\n" } },
            .{ .result = .{ .exit_code = 0, .stdout = "Task TASK-62 - Backlog.md data layer\n" } },
            .{ .result = .{ .exit_code = 1, .stderr = "Error: Task TASK-999 not found.\n" } },
            .{ .result = .{ .exit_code = 0 } },
            .{ .result = .{ .exit_code = 0 } },
            .{ .result = .{ .exit_code = 0 } },
            .{ .result = .{ .exit_code = null, .stderr = "killed" } },
            .{ .fail = error.CommandNotFound },
            .{ .fail = error.Timeout },
            .{ .result = .{ .exit_code = 0, .stdout = "not a version" } },
        },
    };
    defer fake.clearArgv();
    const cli: Cli = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .context = fake.context(),
        .project_dir = "/remote/project",
    };

    try testing.expectEqual(Cli.Version{ .major = 1, .minor = 53, .patch = 0 }, (try cli.detect()).?);
    try testing.expectEqualStrings("--version", fake.argv(1));

    var ok = try cli.setStatus("TASK-62", "In Progress");
    defer ok.deinit(testing.allocator);
    try testing.expect(ok == .ok);
    try testing.expectEqual(@as(usize, 6), fake.last_argc);
    for ([_][]const u8{ "backlog", "task", "edit", "TASK-62", "--status=In Progress", "--plain" }, 0..) |expected, i| {
        try testing.expectEqualStrings(expected, fake.argv(i));
    }
    try testing.expectEqualStrings("/remote/project", fake.last_cwd[0..fake.last_cwd_len]);

    var failed = try cli.editTitle("TASK-999", "New title");
    defer failed.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 1), failed.failed.exit_code);
    try testing.expectEqualStrings("Error: Task TASK-999 not found.", failed.failed.message());
    try testing.expectEqualStrings("--title=New title", fake.argv(4));

    var checked = try cli.checkAcceptance("TASK-62", 2, true);
    checked.deinit(testing.allocator);
    try testing.expectEqualStrings("--check-ac=2", fake.argv(4));
    var unchecked = try cli.checkAcceptance("TASK-69.1", 10, false);
    unchecked.deinit(testing.allocator);
    try testing.expectEqualStrings("TASK-69.1", fake.argv(3));
    try testing.expectEqualStrings("--uncheck-ac=10", fake.argv(4));
    var noted = try cli.addNote("TASK-62", "line one\nline two");
    noted.deinit(testing.allocator);
    try testing.expectEqualStrings("--append-notes=line one\nline two", fake.argv(4));

    var signalled = try cli.setPriority("TASK-62", .high);
    defer signalled.deinit(testing.allocator);
    try testing.expect(signalled.failed.exit_code == null);
    try testing.expectEqualStrings("--priority=high", fake.argv(4));

    try testing.expectError(error.CliUnavailable, cli.setAssignee("TASK-62", "@claude"));
    try testing.expectError(error.Timeout, cli.setStatus("TASK-62", "Done"));
    try testing.expectEqual(@as(?Cli.Version, null), try cli.detect());

    // Invalid arguments never reach the context.
    const before = fake.next_step;
    try testing.expectError(error.InvalidArgument, cli.setStatus("--force", "Done"));
    try testing.expectError(error.InvalidArgument, cli.setStatus("TASK-62", ""));
    try testing.expectError(error.InvalidArgument, cli.setStatus("TASK-62", "Done\n--title=x"));
    try testing.expectError(error.InvalidArgument, cli.editTitle("TASK-62", "bell\x07"));
    try testing.expectError(error.InvalidArgument, cli.addNote("TASK-62", "   "));
    try testing.expectError(error.InvalidArgument, cli.addNote("TASK-62", "esc \x1b[2J"));
    try testing.expectError(error.InvalidArgument, cli.checkAcceptance("TASK-62", 0, true));
    try testing.expectEqual(before, fake.next_step);
}

test "a context without commands makes the CLI unavailable" {
    var fake: ScriptedRunContext = .{ .allocator = testing.allocator, .steps = &.{.{ .fail = error.Unsupported }} };
    defer fake.clearArgv();
    const cli: Cli = .{ .allocator = testing.allocator, .io = testing.io, .context = fake.context(), .project_dir = "." };
    try testing.expectError(error.CliUnavailable, cli.detect());
}

test "the CLI wrapper runs a real command through the Local context" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var context = try localContext();
    defer context.deinit();
    // `/bin/sh -c` stands in for the backlog program: it proves the argv, cwd,
    // exit status and stderr round-trip through `ExecutionContext.run`.
    const cli: Cli = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .context = context.borrow(),
        .project_dir = "/",
        .program = "/bin/sh",
        .timeout_ms = 5000,
    };
    var ok = try cli.run(&.{ "-c", "echo ok; pwd" });
    defer ok.deinit(testing.allocator);
    try testing.expectEqualStrings("ok\n/\n", ok.ok);

    var failed = try cli.run(&.{ "-c", "echo 'no such task' >&2; exit 2" });
    defer failed.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 2), failed.failed.exit_code);
    try testing.expectEqualStrings("no such task", failed.failed.message());

    const missing: Cli = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .context = context.borrow(),
        .project_dir = "/",
        .program = "conduit-backlog-cli-that-does-not-exist",
    };
    try testing.expectError(error.CliUnavailable, missing.detect());
}
