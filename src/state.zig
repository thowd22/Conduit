//! Workspace persistence (TASK-65): the saved state model, its versioned JSON
//! file format, where the file lives, how it is written and read, and the
//! restore plan the app executes on launch.
//!
//! **Owns** `Snapshot` (what is remembered), the codec (`encode`/`decode`),
//! forward migration of older documents, the platform state path, atomic
//! save, bounded load, the quarantine of a corrupt file, and `planRestore`.
//! **Never** owns a workspace, a session or a process: `workspace` builds a
//! `Snapshot` from live state and the app replays a `RestorePlan` through the
//! normal workspace, tab and pane operations, so every restored shell still
//! spawns through its workspace's `ExecutionContext` (invariant 5).
//! **May depend on** `std` and `builtin` only.
//!
//! What is remembered is layout, never content: workspace names, kinds and
//! working directories, an SSH workspace's destination, port and `-o`
//! options, tab order and user-chosen tab names, each tab's pane tree with
//! split ratios, focus and zoom, the active selections, the scratchpad size,
//! the theme and the window geometry. Terminal contents, scrollback,
//! environment, clipboard data and credentials are never part of a snapshot;
//! an SSH key or password stays where `~/.ssh/config` and the agent keep it.
//!
//! Untrusted input: the state file may be hand-edited, truncated or written
//! by a newer Conduit. `decode` is bounded (`max_file_bytes`, the per-level
//! counts, pane depth, string lengths), ignores unknown fields, defaults
//! missing optional ones, and turns every structural problem into
//! `error.Corrupt` or a newer version into `error.Incompatible` with a terse
//! diagnostic that names a field path, never a value. It never crashes.
//!
//! Threads: everything runs on the caller's thread. The app encodes on the
//! owner thread; `save` may then run on a worker with an owned copy of the
//! bytes. Saves of one path must not overlap, because they share one
//! temporary name.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = std.json;

const log = std.log.scoped(.state);

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

/// The format version this build writes. A document with a lower version is
/// migrated on load; a higher one is `error.Incompatible`.
pub const current_version: u32 = 1;

/// The largest state file accepted.
pub const max_file_bytes: usize = 1024 * 1024;
/// Workspaces per snapshot.
pub const max_workspaces: usize = 64;
/// Tabs per workspace.
pub const max_tabs: usize = 256;
/// Panes (leaves) per tab.
pub const max_panes: usize = 256;
/// Nesting of splits in one tab; a lone leaf has depth 0.
pub const max_pane_depth: usize = 16;
/// Workspace, tab and theme names.
pub const max_name_bytes: usize = 256;
/// Working directories.
pub const max_path_bytes: usize = 4096;
/// An SSH destination.
pub const max_destination_bytes: usize = 256;
/// SSH `-o` options per workspace.
pub const max_ssh_options: usize = 32;
/// The length of one SSH `-o` option.
pub const max_ssh_option_bytes: usize = 1024;
/// Split ratios are stored with four decimals and kept off the edges.
pub const min_ratio: f32 = 0.01;
pub const max_ratio: f32 = 0.99;
/// The scratchpad sizes the settings accept (`config.min_scratchpad_percent`
/// and `config.max_scratchpad_percent`), repeated because `state` is a leaf.
pub const min_scratchpad_percent: u8 = 10;
pub const max_scratchpad_percent: u8 = 100;

/// Which execution environment a workspace ran in. Mirrors
/// `workspace.ExecutionContextKind`, spelled the same way.
pub const ContextKind = enum {
    local,
    ssh,
    wsl,

    /// Whether restoring this workspace needs a connection the user must
    /// approve first, so the app prompts instead of connecting.
    pub fn needsReconnect(self: ContextKind) bool {
        return self != .local;
    }
};

/// Where a new pane went relative to the pane it split.
pub const SplitDirection = enum { right, down };

/// What reconnecting an SSH workspace needs. The destination is a
/// `~/.ssh/config` alias or `[user@]host`; identity, keys and passwords stay
/// in the user's SSH configuration and agent. `ssh.Target.config_file` is a
/// test-only seam and is deliberately not remembered.
pub const SshTarget = struct {
    destination: []const u8,
    port: ?u16 = null,
    /// `Key=Value` client options, as given to `ssh.Target.options`.
    options: []const []const u8 = &.{},
};

/// The window's last geometry, in logical pixels.
pub const Window = struct {
    x: ?i32 = null,
    y: ?i32 = null,
    width: u32,
    height: u32,
    maximized: bool = false,
};

/// One terminal leaf.
pub const Leaf = struct {
    /// The working directory its shell starts in, or null for the
    /// workspace's own directory.
    cwd: ?[]const u8 = null,
};

/// One divider: `first` is left of or above `second`.
pub const Split = struct {
    direction: SplitDirection,
    /// The first child's share of the space beside the divider, in
    /// `[min_ratio, max_ratio]`.
    ratio: f32,
    first: *const PaneNode,
    second: *const PaneNode,
};

/// A tab's binary pane tree. Leaves are numbered left to right (depth-first,
/// `first` before `second`); `TabState.focused_leaf` and every `RestorePlan`
/// leaf index use that numbering.
pub const PaneNode = union(enum) {
    leaf: Leaf,
    split: Split,

    /// Number of leaves under this node.
    pub fn leafCount(self: *const PaneNode) usize {
        return switch (self.*) {
            .leaf => 1,
            .split => |split| split.first.leafCount() + split.second.leafCount(),
        };
    }

    /// The leftmost leaf: the pane that keeps this node's place when it is
    /// split during restore.
    pub fn firstLeaf(self: *const PaneNode) Leaf {
        return switch (self.*) {
            .leaf => |leaf| leaf,
            .split => |split| split.first.firstLeaf(),
        };
    }
};

/// One tab.
pub const TabState = struct {
    /// The name the user gave it, or null when it carries a derived name the
    /// app assigns again on restore.
    name: ?[]const u8 = null,
    panes: PaneNode = .{ .leaf = .{} },
    /// Left-to-right index of the focused leaf.
    focused_leaf: usize = 0,
    /// Whether the focused leaf fills the tab.
    zoomed: bool = false,
};

/// One workspace.
pub const WorkspaceState = struct {
    name: []const u8,
    kind: ContextKind = .local,
    cwd: []const u8,
    /// Present exactly when `kind` is `.ssh`.
    ssh: ?SshTarget = null,
    active_tab: ?usize = null,
    tabs: []const TabState = &.{},
    /// The scratchpad's last size as a percentage of the window, when known.
    scratchpad_percent: ?u8 = null,
};

/// Everything Conduit remembers between runs.
pub const Snapshot = struct {
    version: u32 = current_version,
    saved_at_unix: i64 = 0,
    theme: ?[]const u8 = null,
    window: ?Window = null,
    active_workspace: ?usize = null,
    workspaces: []const WorkspaceState = &.{},
};

/// A snapshot together with the arena that holds every slice and node in it.
/// Callers may add their own values (the theme, the window, a scratchpad
/// size) through `allocator()` before encoding; `deinit` releases all of it
/// at once. `Owned` must not be copied after `allocator()` has been called.
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    snapshot: Snapshot,

    pub fn allocator(self: *Owned) Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Why a document was refused, for one log line or a status message. It
/// names a field path and the rule, never a value from the file.
pub const Diagnostic = struct {
    buffer: [256]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.buffer[0..self.len];
    }

    fn set(self: *Diagnostic, comptime format: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.buffer, format, args) catch {
            const fallback = "state file is not usable";
            @memcpy(self.buffer[0..fallback.len], fallback);
            self.len = fallback.len;
            return;
        };
        self.len = text.len;
    }
};

// ---------------------------------------------------------------------------
// Validation (shared by encode and decode)
// ---------------------------------------------------------------------------

pub const ValidateError = error{Corrupt};

fn validString(bytes: []const u8, max: usize) bool {
    if (bytes.len > max) return false;
    if (!std.unicode.utf8ValidateSlice(bytes)) return false;
    return std.mem.indexOfScalar(u8, bytes, 0) == null;
}

fn trimName(name: []const u8) []const u8 {
    return std.mem.trim(u8, name, std.ascii.whitespace[0..]);
}

fn validName(bytes: []const u8) bool {
    return validString(bytes, max_name_bytes) and trimName(bytes).len != 0;
}

fn validPath(bytes: []const u8) bool {
    return bytes.len != 0 and validString(bytes, max_path_bytes);
}

/// The same rule as `ssh.validateDestination`, repeated because `state` is a
/// leaf: a destination can never become an option or carry whitespace.
fn validDestination(destination: []const u8) bool {
    if (destination.len == 0 or destination.len > max_destination_bytes) return false;
    if (destination[0] == '-') return false;
    for (destination) |byte| {
        if (byte <= ' ' or byte == 0x7f) return false;
    }
    return true;
}

/// The same rule as `ssh.validateOption`.
fn validOption(option: []const u8) bool {
    if (option.len > max_ssh_option_bytes) return false;
    const eq = std.mem.indexOfScalar(u8, option, '=') orelse return false;
    if (eq == 0 or option[0] == '-') return false;
    for (option) |byte| {
        if (byte < ' ' or byte == 0x7f) return false;
    }
    return true;
}

fn validatePanes(
    node: *const PaneNode,
    depth: usize,
    diagnostic: *Diagnostic,
    w: usize,
    t: usize,
) ValidateError!void {
    switch (node.*) {
        .leaf => |leaf| if (leaf.cwd) |cwd| {
            if (!validPath(cwd)) {
                diagnostic.set("workspaces[{d}].tabs[{d}]: a pane cwd is empty, too long or not text", .{ w, t });
                return error.Corrupt;
            }
        },
        .split => |split| {
            if (depth >= max_pane_depth) {
                diagnostic.set("workspaces[{d}].tabs[{d}]: panes nest deeper than {d}", .{ w, t, max_pane_depth });
                return error.Corrupt;
            }
            if (!(split.ratio >= min_ratio and split.ratio <= max_ratio)) {
                diagnostic.set("workspaces[{d}].tabs[{d}]: a split ratio is outside 0.01..0.99", .{ w, t });
                return error.Corrupt;
            }
            try validatePanes(split.first, depth + 1, diagnostic, w, t);
            try validatePanes(split.second, depth + 1, diagnostic, w, t);
        },
    }
}

/// Check every bound and invariant a snapshot must meet to be written or
/// restored. Indices out of range, a missing SSH target and duplicate
/// workspace names are refused here rather than surprising the app later.
pub fn validate(snapshot: *const Snapshot, diagnostic: *Diagnostic) ValidateError!void {
    if (snapshot.version != current_version) {
        diagnostic.set("version {d} is not {d}", .{ snapshot.version, current_version });
        return error.Corrupt;
    }
    if (snapshot.theme) |theme| if (!validName(theme)) {
        diagnostic.set("theme: empty, too long or not text", .{});
        return error.Corrupt;
    };
    if (snapshot.window) |window| {
        if (window.width == 0 or window.height == 0 or window.width > 65535 or window.height > 65535) {
            diagnostic.set("window: size outside 1..65535", .{});
            return error.Corrupt;
        }
    }
    if (snapshot.workspaces.len > max_workspaces) {
        diagnostic.set("workspaces: more than {d}", .{max_workspaces});
        return error.Corrupt;
    }
    if (snapshot.active_workspace) |index| if (index >= snapshot.workspaces.len) {
        diagnostic.set("active_workspace: out of range", .{});
        return error.Corrupt;
    };
    for (snapshot.workspaces, 0..) |workspace, w| {
        if (!validName(workspace.name)) {
            diagnostic.set("workspaces[{d}].name: empty, too long or not text", .{w});
            return error.Corrupt;
        }
        for (snapshot.workspaces[0..w], 0..) |earlier, e| {
            if (std.mem.eql(u8, trimName(earlier.name), trimName(workspace.name))) {
                diagnostic.set("workspaces[{d}].name: duplicates workspaces[{d}]", .{ w, e });
                return error.Corrupt;
            }
        }
        if (!validPath(workspace.cwd)) {
            diagnostic.set("workspaces[{d}].cwd: empty, too long or not text", .{w});
            return error.Corrupt;
        }
        if (workspace.kind == .ssh) {
            const target = workspace.ssh orelse {
                diagnostic.set("workspaces[{d}].ssh: missing for an ssh workspace", .{w});
                return error.Corrupt;
            };
            if (!validDestination(target.destination)) {
                diagnostic.set("workspaces[{d}].ssh.destination: not a valid destination", .{w});
                return error.Corrupt;
            }
            if (target.port) |port| if (port == 0) {
                diagnostic.set("workspaces[{d}].ssh.port: zero", .{w});
                return error.Corrupt;
            };
            if (target.options.len > max_ssh_options) {
                diagnostic.set("workspaces[{d}].ssh.options: more than {d}", .{ w, max_ssh_options });
                return error.Corrupt;
            }
            for (target.options) |option| if (!validOption(option)) {
                diagnostic.set("workspaces[{d}].ssh.options: an option is not Key=Value", .{w});
                return error.Corrupt;
            };
        } else if (workspace.ssh != null) {
            diagnostic.set("workspaces[{d}].ssh: present for a {s} workspace", .{ w, @tagName(workspace.kind) });
            return error.Corrupt;
        }
        if (workspace.scratchpad_percent) |percent| {
            if (percent < min_scratchpad_percent or percent > max_scratchpad_percent) {
                diagnostic.set("workspaces[{d}].scratchpad_percent: outside {d}..{d}", .{ w, min_scratchpad_percent, max_scratchpad_percent });
                return error.Corrupt;
            }
        }
        if (workspace.tabs.len > max_tabs) {
            diagnostic.set("workspaces[{d}].tabs: more than {d}", .{ w, max_tabs });
            return error.Corrupt;
        }
        if (workspace.active_tab) |index| if (index >= workspace.tabs.len) {
            diagnostic.set("workspaces[{d}].active_tab: out of range", .{w});
            return error.Corrupt;
        };
        for (workspace.tabs, 0..) |tab, t| {
            if (tab.name) |tab_name| if (!validName(tab_name)) {
                diagnostic.set("workspaces[{d}].tabs[{d}].name: empty, too long or not text", .{ w, t });
                return error.Corrupt;
            };
            try validatePanes(&tab.panes, 0, diagnostic, w, t);
            const leaves = tab.panes.leafCount();
            if (leaves > max_panes) {
                diagnostic.set("workspaces[{d}].tabs[{d}].panes: more than {d}", .{ w, t, max_panes });
                return error.Corrupt;
            }
            if (tab.focused_leaf >= leaves) {
                diagnostic.set("workspaces[{d}].tabs[{d}].focused_leaf: out of range", .{ w, t });
                return error.Corrupt;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

pub const EncodeError = Allocator.Error || error{Unrepresentable};

/// Encode a snapshot as pretty JSON with a fixed key order, so the same
/// state always produces the same bytes. Optional fields that are null are
/// left out. A snapshot that `decode` would refuse is `error.Unrepresentable`
/// (with the reason in `diagnostic`), so Conduit never writes a file it
/// cannot read back. Caller owns the returned bytes.
pub fn encode(allocator: Allocator, snapshot: *const Snapshot, diagnostic: *Diagnostic) EncodeError![]u8 {
    validate(snapshot, diagnostic) catch return error.Unrepresentable;
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var writer: json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    // The allocating writer fails only when its allocator does.
    writeSnapshot(&writer, snapshot) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    if (out.written().len > max_file_bytes) {
        diagnostic.set("encoded state is larger than {d} bytes", .{max_file_bytes});
        return error.Unrepresentable;
    }
    return out.toOwnedSlice();
}

const WriteError = json.Stringify.Error;

fn writeSnapshot(w: *json.Stringify, snapshot: *const Snapshot) WriteError!void {
    try w.beginObject();
    try w.objectField("version");
    try w.write(snapshot.version);
    try w.objectField("saved_at_unix");
    try w.write(snapshot.saved_at_unix);
    if (snapshot.theme) |theme| {
        try w.objectField("theme");
        try w.write(theme);
    }
    if (snapshot.window) |window| {
        try w.objectField("window");
        try w.beginObject();
        if (window.x) |x| {
            try w.objectField("x");
            try w.write(x);
        }
        if (window.y) |y| {
            try w.objectField("y");
            try w.write(y);
        }
        try w.objectField("width");
        try w.write(window.width);
        try w.objectField("height");
        try w.write(window.height);
        try w.objectField("maximized");
        try w.write(window.maximized);
        try w.endObject();
    }
    if (snapshot.active_workspace) |index| {
        try w.objectField("active_workspace");
        try w.write(index);
    }
    try w.objectField("workspaces");
    try w.beginArray();
    for (snapshot.workspaces) |*workspace| try writeWorkspace(w, workspace);
    try w.endArray();
    try w.endObject();
}

fn writeWorkspace(w: *json.Stringify, workspace: *const WorkspaceState) WriteError!void {
    try w.beginObject();
    try w.objectField("name");
    try w.write(workspace.name);
    try w.objectField("kind");
    try w.write(@tagName(workspace.kind));
    try w.objectField("cwd");
    try w.write(workspace.cwd);
    if (workspace.ssh) |target| {
        try w.objectField("ssh");
        try w.beginObject();
        try w.objectField("destination");
        try w.write(target.destination);
        if (target.port) |port| {
            try w.objectField("port");
            try w.write(port);
        }
        try w.objectField("options");
        try w.beginArray();
        for (target.options) |option| try w.write(option);
        try w.endArray();
        try w.endObject();
    }
    if (workspace.active_tab) |index| {
        try w.objectField("active_tab");
        try w.write(index);
    }
    if (workspace.scratchpad_percent) |percent| {
        try w.objectField("scratchpad_percent");
        try w.write(percent);
    }
    try w.objectField("tabs");
    try w.beginArray();
    for (workspace.tabs) |*tab| {
        try w.beginObject();
        if (tab.name) |tab_name| {
            try w.objectField("name");
            try w.write(tab_name);
        }
        try w.objectField("focused_leaf");
        try w.write(tab.focused_leaf);
        try w.objectField("zoomed");
        try w.write(tab.zoomed);
        try w.objectField("panes");
        try writePane(w, &tab.panes);
        try w.endObject();
    }
    try w.endArray();
    try w.endObject();
}

/// Ratios are written with four decimals so the file stays readable and
/// stable across runs; that precision is far below one terminal cell.
fn quantizeRatio(ratio: f32) f64 {
    return @round(@as(f64, ratio) * 10000.0) / 10000.0;
}

fn writePane(w: *json.Stringify, node: *const PaneNode) WriteError!void {
    try w.beginObject();
    switch (node.*) {
        .leaf => |leaf| {
            try w.objectField("type");
            try w.write("leaf");
            if (leaf.cwd) |cwd| {
                try w.objectField("cwd");
                try w.write(cwd);
            }
        },
        .split => |split| {
            try w.objectField("type");
            try w.write("split");
            try w.objectField("direction");
            try w.write(@tagName(split.direction));
            try w.objectField("ratio");
            try w.print("{d}", .{quantizeRatio(split.ratio)});
            try w.objectField("first");
            try writePane(w, split.first);
            try w.objectField("second");
            try writePane(w, split.second);
        },
    }
    try w.endObject();
}

// ---------------------------------------------------------------------------
// Decoding and migration
// ---------------------------------------------------------------------------

pub const DecodeError = Allocator.Error || error{ Corrupt, Incompatible };

/// Parse and check a state document. Unknown fields are ignored and missing
/// optional fields take their defaults; a document from an older version is
/// migrated first. A newer version is `error.Incompatible`; anything
/// malformed, out of bounds or inconsistent is `error.Corrupt`. Either way
/// `diagnostic` says why. The result owns all of its memory.
pub fn decode(allocator: Allocator, bytes: []const u8, diagnostic: *Diagnostic) DecodeError!Owned {
    if (bytes.len > max_file_bytes) {
        diagnostic.set("state file is larger than {d} bytes", .{max_file_bytes});
        return error.Corrupt;
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var root = json.parseFromSliceLeaky(json.Value, a, bytes, .{
        .duplicate_field_behavior = .use_last,
        .max_value_len = max_file_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diagnostic.set("state file is not valid JSON", .{});
            return error.Corrupt;
        },
    };
    if (root != .object) {
        diagnostic.set("state file is not a JSON object", .{});
        return error.Corrupt;
    }
    const version_value = root.object.get("version") orelse {
        diagnostic.set("version: missing", .{});
        return error.Corrupt;
    };
    if (version_value != .integer or version_value.integer < 0) {
        diagnostic.set("version: not a non-negative integer", .{});
        return error.Corrupt;
    }
    if (version_value.integer > current_version) {
        diagnostic.set("version {d} is newer than this Conduit reads ({d})", .{ version_value.integer, current_version });
        return error.Incompatible;
    }
    try migrate(a, &root.object, @intCast(version_value.integer));

    var decoder: Decoder = .{ .arena = a, .diagnostic = diagnostic };
    const snapshot = try decoder.snapshot(&root.object);
    try validate(&snapshot, diagnostic);
    return .{ .arena = arena, .snapshot = snapshot };
}

/// Bring a parsed document from version `from` (at most `current_version`)
/// up to `current_version` in place, one step at a time, before it is read
/// as a `Snapshot`. Migrations work on the JSON tree because an older
/// document need not fit today's model. Allocations come from `arena`.
///
/// Version 0 was the pre-release spelling that named a workspace's execution
/// environment `context` rather than `kind`.
pub fn migrate(arena: Allocator, root: *json.ObjectMap, from: u32) Allocator.Error!void {
    std.debug.assert(from <= current_version);
    if (from == 0) {
        if (root.getPtr("workspaces")) |workspaces| if (workspaces.* == .array) {
            for (workspaces.array.items) |*item| {
                if (item.* != .object) continue;
                const context = item.object.get("context") orelse continue;
                if (item.object.get("kind") == null) try item.object.put(arena, "kind", context);
                _ = item.object.orderedRemove("context");
            }
        };
    }
    try root.put(arena, "version", .{ .integer = current_version });
}

const Decoder = struct {
    arena: Allocator,
    diagnostic: *Diagnostic,

    const Error = Allocator.Error || error{Corrupt};

    fn fail(self: *Decoder, comptime format: []const u8, args: anytype) error{Corrupt} {
        self.diagnostic.set(format, args);
        return error.Corrupt;
    }

    /// A field that is absent or JSON null.
    fn field(object_map: *const json.ObjectMap, name: []const u8) ?json.Value {
        const value = object_map.get(name) orelse return null;
        if (value == .null) return null;
        return value;
    }

    fn string(self: *Decoder, value: json.Value, comptime path: []const u8, args: anytype) Error![]const u8 {
        if (value != .string) return self.fail(path ++ ": not a string", args);
        return value.string;
    }

    fn unsigned(self: *Decoder, comptime T: type, value: json.Value, comptime path: []const u8, args: anytype) Error!T {
        if (value != .integer) return self.fail(path ++ ": not an integer", args);
        return std.math.cast(T, value.integer) orelse self.fail(path ++ ": out of range", args);
    }

    fn signed(self: *Decoder, comptime T: type, value: json.Value, comptime path: []const u8, args: anytype) Error!T {
        if (value != .integer) return self.fail(path ++ ": not an integer", args);
        return std.math.cast(T, value.integer) orelse self.fail(path ++ ": out of range", args);
    }

    fn boolean(self: *Decoder, value: json.Value, comptime path: []const u8, args: anytype) Error!bool {
        if (value != .bool) return self.fail(path ++ ": not true or false", args);
        return value.bool;
    }

    fn snapshot(self: *Decoder, root: *const json.ObjectMap) Error!Snapshot {
        var result: Snapshot = .{};
        if (field(root, "saved_at_unix")) |value| result.saved_at_unix = try self.signed(i64, value, "saved_at_unix", .{});
        if (field(root, "theme")) |value| result.theme = try self.string(value, "theme", .{});
        if (field(root, "window")) |value| {
            if (value != .object) return self.fail("window: not an object", .{});
            result.window = try self.window(&value.object);
        }
        if (field(root, "active_workspace")) |value| {
            result.active_workspace = try self.unsigned(usize, value, "active_workspace", .{});
        }
        const workspaces_value = field(root, "workspaces") orelse return self.fail("workspaces: missing", .{});
        if (workspaces_value != .array) return self.fail("workspaces: not an array", .{});
        const items = workspaces_value.array.items;
        if (items.len > max_workspaces) return self.fail("workspaces: more than {d}", .{max_workspaces});
        const workspaces = try self.arena.alloc(WorkspaceState, items.len);
        for (items, workspaces, 0..) |item, *out, w| {
            if (item != .object) return self.fail("workspaces[{d}]: not an object", .{w});
            out.* = try self.workspace(&item.object, w);
        }
        result.workspaces = workspaces;
        return result;
    }

    fn window(self: *Decoder, object_map: *const json.ObjectMap) Error!Window {
        const width = field(object_map, "width") orelse return self.fail("window.width: missing", .{});
        const height = field(object_map, "height") orelse return self.fail("window.height: missing", .{});
        var result: Window = .{
            .width = try self.unsigned(u32, width, "window.width", .{}),
            .height = try self.unsigned(u32, height, "window.height", .{}),
        };
        if (field(object_map, "x")) |value| result.x = try self.signed(i32, value, "window.x", .{});
        if (field(object_map, "y")) |value| result.y = try self.signed(i32, value, "window.y", .{});
        if (field(object_map, "maximized")) |value| result.maximized = try self.boolean(value, "window.maximized", .{});
        return result;
    }

    fn workspace(self: *Decoder, object_map: *const json.ObjectMap, w: usize) Error!WorkspaceState {
        const name_value = field(object_map, "name") orelse return self.fail("workspaces[{d}].name: missing", .{w});
        const cwd_value = field(object_map, "cwd") orelse return self.fail("workspaces[{d}].cwd: missing", .{w});
        var result: WorkspaceState = .{
            .name = trimName(try self.string(name_value, "workspaces[{d}].name", .{w})),
            .cwd = try self.string(cwd_value, "workspaces[{d}].cwd", .{w}),
        };
        if (field(object_map, "kind")) |value| {
            const text = try self.string(value, "workspaces[{d}].kind", .{w});
            result.kind = std.meta.stringToEnum(ContextKind, text) orelse
                return self.fail("workspaces[{d}].kind: not local, ssh or wsl", .{w});
        }
        // A target beside a local workspace is ignored like any unknown field.
        if (result.kind == .ssh) {
            const value = field(object_map, "ssh") orelse return self.fail("workspaces[{d}].ssh: missing for an ssh workspace", .{w});
            if (value != .object) return self.fail("workspaces[{d}].ssh: not an object", .{w});
            result.ssh = try self.sshTarget(&value.object, w);
        }
        if (field(object_map, "active_tab")) |value| {
            result.active_tab = try self.unsigned(usize, value, "workspaces[{d}].active_tab", .{w});
        }
        if (field(object_map, "scratchpad_percent")) |value| {
            result.scratchpad_percent = try self.unsigned(u8, value, "workspaces[{d}].scratchpad_percent", .{w});
        }
        if (field(object_map, "tabs")) |value| {
            if (value != .array) return self.fail("workspaces[{d}].tabs: not an array", .{w});
            const items = value.array.items;
            if (items.len > max_tabs) return self.fail("workspaces[{d}].tabs: more than {d}", .{ w, max_tabs });
            const tabs = try self.arena.alloc(TabState, items.len);
            for (items, tabs, 0..) |item, *out, t| {
                if (item != .object) return self.fail("workspaces[{d}].tabs[{d}]: not an object", .{ w, t });
                out.* = try self.tab(&item.object, w, t);
            }
            result.tabs = tabs;
        }
        return result;
    }

    fn sshTarget(self: *Decoder, object_map: *const json.ObjectMap, w: usize) Error!SshTarget {
        const destination = field(object_map, "destination") orelse return self.fail("workspaces[{d}].ssh.destination: missing", .{w});
        var result: SshTarget = .{ .destination = try self.string(destination, "workspaces[{d}].ssh.destination", .{w}) };
        if (field(object_map, "port")) |value| result.port = try self.unsigned(u16, value, "workspaces[{d}].ssh.port", .{w});
        if (field(object_map, "options")) |value| {
            if (value != .array) return self.fail("workspaces[{d}].ssh.options: not an array", .{w});
            const items = value.array.items;
            if (items.len > max_ssh_options) return self.fail("workspaces[{d}].ssh.options: more than {d}", .{ w, max_ssh_options });
            const options = try self.arena.alloc([]const u8, items.len);
            for (items, options) |item, *out| out.* = try self.string(item, "workspaces[{d}].ssh.options", .{w});
            result.options = options;
        }
        return result;
    }

    fn tab(self: *Decoder, object_map: *const json.ObjectMap, w: usize, t: usize) Error!TabState {
        var result: TabState = .{};
        if (field(object_map, "name")) |value| result.name = trimName(try self.string(value, "workspaces[{d}].tabs[{d}].name", .{ w, t }));
        if (field(object_map, "panes")) |value| result.panes = try self.pane(value, 0, w, t);
        if (field(object_map, "focused_leaf")) |value| {
            result.focused_leaf = try self.unsigned(usize, value, "workspaces[{d}].tabs[{d}].focused_leaf", .{ w, t });
        }
        if (field(object_map, "zoomed")) |value| result.zoomed = try self.boolean(value, "workspaces[{d}].tabs[{d}].zoomed", .{ w, t });
        return result;
    }

    /// Recursion is bounded by `max_pane_depth`, checked before descending,
    /// so a hostile document cannot exhaust the stack.
    fn pane(self: *Decoder, value: json.Value, depth: usize, w: usize, t: usize) Error!PaneNode {
        if (value != .object) return self.fail("workspaces[{d}].tabs[{d}]: a pane is not an object", .{ w, t });
        const object_map = &value.object;
        const type_value = field(object_map, "type") orelse return self.fail("workspaces[{d}].tabs[{d}]: a pane has no type", .{ w, t });
        const type_text = try self.string(type_value, "workspaces[{d}].tabs[{d}]: a pane type", .{ w, t });
        if (std.mem.eql(u8, type_text, "leaf")) {
            var leaf: Leaf = .{};
            if (field(object_map, "cwd")) |cwd| leaf.cwd = try self.string(cwd, "workspaces[{d}].tabs[{d}]: a pane cwd", .{ w, t });
            return .{ .leaf = leaf };
        }
        if (!std.mem.eql(u8, type_text, "split")) return self.fail("workspaces[{d}].tabs[{d}]: a pane type is not leaf or split", .{ w, t });
        if (depth >= max_pane_depth) return self.fail("workspaces[{d}].tabs[{d}]: panes nest deeper than {d}", .{ w, t, max_pane_depth });

        const direction_value = field(object_map, "direction") orelse return self.fail("workspaces[{d}].tabs[{d}]: a split has no direction", .{ w, t });
        const direction_text = try self.string(direction_value, "workspaces[{d}].tabs[{d}]: a split direction", .{ w, t });
        const direction = std.meta.stringToEnum(SplitDirection, direction_text) orelse
            return self.fail("workspaces[{d}].tabs[{d}]: a split direction is not right or down", .{ w, t });
        const ratio_value = field(object_map, "ratio") orelse return self.fail("workspaces[{d}].tabs[{d}]: a split has no ratio", .{ w, t });
        const raw_ratio: f64 = switch (ratio_value) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => return self.fail("workspaces[{d}].tabs[{d}]: a split ratio is not a number", .{ w, t }),
        };
        // A hand-edited ratio that is merely extreme is kept inside the
        // edges rather than discarding the whole file.
        const ratio: f32 = @floatCast(std.math.clamp(raw_ratio, min_ratio, max_ratio));
        const first_value = field(object_map, "first") orelse return self.fail("workspaces[{d}].tabs[{d}]: a split has no first pane", .{ w, t });
        const second_value = field(object_map, "second") orelse return self.fail("workspaces[{d}].tabs[{d}]: a split has no second pane", .{ w, t });
        const first = try self.arena.create(PaneNode);
        first.* = try self.pane(first_value, depth + 1, w, t);
        const second = try self.arena.create(PaneNode);
        second.* = try self.pane(second_value, depth + 1, w, t);
        return .{ .split = .{ .direction = direction, .ratio = ratio, .first = first, .second = second } };
    }
};

// ---------------------------------------------------------------------------
// Location
// ---------------------------------------------------------------------------

/// The environment values the state location depends on. Each is null when
/// unset.
pub const PathEnv = struct {
    xdg_state_home: ?[]const u8 = null,
    home: ?[]const u8 = null,
    local_app_data: ?[]const u8 = null,
};

/// The state file's platform path, written into `buffer`:
///
/// - Linux and other Unix: `$XDG_STATE_HOME/conduit/state.json`, else
///   `$HOME/.local/state/conduit/state.json`. A relative `XDG_STATE_HOME` is
///   ignored, as the XDG base directory specification requires.
/// - macOS: `$HOME/Library/Application Support/conduit/state.json`.
/// - Windows: `%LOCALAPPDATA%\conduit\state.json`.
///
/// Null when the environment names no home, or the path does not fit.
/// `conduit-test launch` sets an isolated `XDG_STATE_HOME`, so test runs
/// never touch the user's file.
pub fn statePath(buffer: []u8, os: std.Target.Os.Tag, env: PathEnv) ?[]const u8 {
    switch (os) {
        .windows => {
            const base = env.local_app_data orelse return null;
            if (base.len == 0) return null;
            return std.fmt.bufPrint(buffer, "{s}\\conduit\\state.json", .{std.mem.trimEnd(u8, base, "\\/")}) catch null;
        },
        .macos => {
            const home = env.home orelse return null;
            if (home.len == 0) return null;
            return std.fmt.bufPrint(buffer, "{s}/Library/Application Support/conduit/state.json", .{std.mem.trimEnd(u8, home, "/")}) catch null;
        },
        else => {
            if (env.xdg_state_home) |xdg| {
                if (xdg.len != 0 and xdg[0] == '/') {
                    return std.fmt.bufPrint(buffer, "{s}/conduit/state.json", .{std.mem.trimEnd(u8, xdg, "/")}) catch null;
                }
            }
            const home = env.home orelse return null;
            if (home.len == 0) return null;
            return std.fmt.bufPrint(buffer, "{s}/.local/state/conduit/state.json", .{std.mem.trimEnd(u8, home, "/")}) catch null;
        },
    }
}

fn directoryOf(path: []const u8) ?[]const u8 {
    const index = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return null;
    if (index == 0) return path[0..1];
    return path[0..index];
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

/// Suffix of the temporary file `save` writes before renaming it into place.
pub const temporary_suffix = ".saving";

/// The state file is private to the user: it names hosts and directories.
const state_file_permissions: Io.File.Permissions = if (builtin.os.tag == .windows)
    .default_file
else
    .fromMode(0o600);

/// Write `bytes` to `path` atomically: create the directory, write a
/// temporary file beside the target, flush it to disk, then rename it over
/// the target, so a crash leaves either the old file or the new one and a
/// reader never sees half a document. Runs on any thread with an owned copy
/// of the bytes; saves to one path must not overlap.
pub fn save(io: Io, path: []const u8, bytes: []const u8) !void {
    if (directoryOf(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    var temporary_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temporary = std.fmt.bufPrint(&temporary_buffer, "{s}" ++ temporary_suffix, .{path}) catch return error.NameTooLong;
    errdefer Io.Dir.cwd().deleteFile(io, temporary) catch |err| {
        log.warn("could not remove the temporary state file: {s}", .{@errorName(err)});
    };
    {
        const file = try Io.Dir.cwd().createFile(io, temporary, .{ .permissions = state_file_permissions });
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
        try file.sync(io);
    }
    try Io.Dir.cwd().rename(temporary, Io.Dir.cwd(), path, io);
}

/// What reading the state file found.
pub const LoadResult = union(enum) {
    /// No file: a first run, or state was never saved.
    missing,
    /// The file's bytes: a prefix of the caller's buffer.
    bytes: []u8,
    /// The file exists but cannot be read; the message is terse and carries
    /// no content.
    failed: []const u8,
};

/// The smallest buffer `load` accepts: one byte more than `max_file_bytes`,
/// so an oversized file is detected rather than cut.
pub const load_buffer_bytes: usize = max_file_bytes + 1;

/// Read the state file into `buffer` (at least `load_buffer_bytes` long).
pub fn load(io: Io, path: []const u8, buffer: []u8) LoadResult {
    std.debug.assert(buffer.len >= load_buffer_bytes);
    const bytes = Io.Dir.cwd().readFile(io, path, buffer) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => .missing,
        error.IsDir => .{ .failed = "the state path is a directory" },
        error.AccessDenied, error.PermissionDenied => .{ .failed = "the state file is not readable" },
        else => .{ .failed = "the state file could not be read" },
    };
    return .{ .bytes = bytes };
}

/// Move an unusable state file aside to `<path>.corrupt-<unix>` so the next
/// start is clean and the user keeps the evidence. Writes the new path into
/// `buffer` and returns it.
pub fn quarantine(io: Io, path: []const u8, now_unix: i64, buffer: []u8) ![]const u8 {
    const target = std.fmt.bufPrint(buffer, "{s}.corrupt-{d}", .{ path, now_unix }) catch return error.NameTooLong;
    try Io.Dir.cwd().rename(path, Io.Dir.cwd(), target, io);
    return target;
}

/// The outcome of `restoreFromDisk`.
pub const Restored = union(enum) {
    /// Start clean: no file, or a file that could not be used (the
    /// diagnostic says why, and an unusable document was quarantined).
    clean,
    snapshot: Owned,
};

/// Load and decode the state file at `path`. A file that is corrupt, too
/// large or from a newer Conduit is quarantined and the result is a clean
/// start with a diagnostic; an unreadable one is left alone. Only running
/// out of memory is an error. `buffer` is as for `load`.
pub fn restoreFromDisk(
    io: Io,
    allocator: Allocator,
    path: []const u8,
    buffer: []u8,
    now_unix: i64,
    diagnostic: *Diagnostic,
) Allocator.Error!Restored {
    const bytes = switch (load(io, path, buffer)) {
        .missing => return .clean,
        .failed => |message| {
            diagnostic.set("{s}", .{message});
            return .clean;
        },
        .bytes => |bytes| bytes,
    };
    const owned = decode(allocator, bytes, diagnostic) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Corrupt, error.Incompatible => {
            const reason: Diagnostic = diagnostic.*;
            var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
            if (quarantine(io, path, now_unix, &target_buffer)) |_| {
                diagnostic.set("{s}; moved aside as .corrupt-{d}", .{ reason.message(), now_unix });
            } else |rename_err| {
                diagnostic.set("{s}; not moved aside: {s}", .{ reason.message(), @errorName(rename_err) });
            }
            return .clean;
        },
    };
    return .{ .snapshot = owned };
}

// ---------------------------------------------------------------------------
// Restore plan
// ---------------------------------------------------------------------------

/// One action the app performs, in order, to rebuild a snapshot. Indices are
/// positions in the snapshot: `workspace` in `Snapshot.workspaces`, `tab` in
/// that workspace's `tabs`, and `leaf`/`new_leaf` in the tab's left-to-right
/// leaf numbering. The app keeps a leaf-index to `PaneId` map per tab while
/// it executes the steps. String slices borrow the snapshot.
pub const Step = union(enum) {
    /// Create and insert a workspace. A remote one is created without
    /// connecting; `needs_reconnect` tells the app to ask the user first and
    /// to start that workspace's shells only after a successful connection.
    create_workspace: struct {
        workspace: usize,
        name: []const u8,
        kind: ContextKind,
        cwd: []const u8,
        ssh: ?SshTarget,
        scratchpad_percent: ?u8,
        needs_reconnect: bool,
    },
    /// Create a tab whose first pane (leaf 0) starts in `cwd`. A non-null
    /// `name` is the user's name; null means the app's derived name.
    create_tab: struct {
        workspace: usize,
        tab: usize,
        name: ?[]const u8,
        cwd: []const u8,
    },
    /// Split `leaf` toward `direction`. The new pane is `new_leaf` and starts
    /// in `cwd`; `leaf` keeps the first share. Set the new divider to `ratio`
    /// (`Workspace.setPaneSplitRatio` on the new pane) immediately, before a
    /// later split nests under it.
    split_pane: struct {
        workspace: usize,
        tab: usize,
        leaf: usize,
        new_leaf: usize,
        direction: SplitDirection,
        ratio: f32,
        cwd: []const u8,
    },
    focus_pane: struct { workspace: usize, tab: usize, leaf: usize },
    /// Zoom the tab's focused pane.
    zoom_pane: struct { workspace: usize, tab: usize },
    select_tab: struct { workspace: usize, tab: usize },
    select_workspace: struct { workspace: usize },
};

/// The ordered steps that rebuild a snapshot, plus the window-wide values the
/// app applies before them. It borrows the snapshot, which must outlive it.
pub const RestorePlan = struct {
    steps: []Step,
    theme: ?[]const u8,
    window: ?Window,

    pub fn deinit(self: *RestorePlan, allocator: Allocator) void {
        allocator.free(self.steps);
        self.* = undefined;
    }
};

/// Build the restore plan for a validated snapshot (`decode` validates; a
/// hand-built snapshot should pass `validate` first). An empty snapshot
/// yields no steps, which is a clean start.
///
/// Per workspace, in order: `create_workspace`; for each tab `create_tab`,
/// its splits depth-first, `focus_pane` and, when zoomed, `zoom_pane`; then
/// `select_tab` when one was active. A workspace saved without tabs gets one
/// default tab in its own directory, because a live workspace always shows
/// one. `select_workspace` comes last. Splitting a node splits the pane that
/// stands for it (its leftmost leaf); the original pane keeps the first
/// child, exactly as an interactive split does, so the new leaf's index is
/// the split pane's plus the first child's leaf count. Outer splits come
/// before nested ones, so each split sees the largest space it will have.
pub fn planRestore(allocator: Allocator, snapshot: *const Snapshot) Allocator.Error!RestorePlan {
    var steps: std.ArrayList(Step) = .empty;
    errdefer steps.deinit(allocator);
    for (snapshot.workspaces, 0..) |workspace, w| {
        try steps.append(allocator, .{ .create_workspace = .{
            .workspace = w,
            .name = workspace.name,
            .kind = workspace.kind,
            .cwd = workspace.cwd,
            .ssh = workspace.ssh,
            .scratchpad_percent = workspace.scratchpad_percent,
            .needs_reconnect = workspace.kind.needsReconnect(),
        } });
        if (workspace.tabs.len == 0) {
            try steps.append(allocator, .{ .create_tab = .{ .workspace = w, .tab = 0, .name = null, .cwd = workspace.cwd } });
            try steps.append(allocator, .{ .focus_pane = .{ .workspace = w, .tab = 0, .leaf = 0 } });
            try steps.append(allocator, .{ .select_tab = .{ .workspace = w, .tab = 0 } });
            continue;
        }
        for (workspace.tabs, 0..) |*tab, t| {
            try steps.append(allocator, .{ .create_tab = .{
                .workspace = w,
                .tab = t,
                .name = tab.name,
                .cwd = tab.panes.firstLeaf().cwd orelse workspace.cwd,
            } });
            try planSplits(allocator, &steps, &tab.panes, 0, w, t, workspace.cwd);
            try steps.append(allocator, .{ .focus_pane = .{ .workspace = w, .tab = t, .leaf = tab.focused_leaf } });
            if (tab.zoomed) try steps.append(allocator, .{ .zoom_pane = .{ .workspace = w, .tab = t } });
        }
        if (workspace.active_tab) |t| try steps.append(allocator, .{ .select_tab = .{ .workspace = w, .tab = t } });
    }
    if (snapshot.active_workspace) |w| try steps.append(allocator, .{ .select_workspace = .{ .workspace = w } });
    return .{
        .steps = try steps.toOwnedSlice(allocator),
        .theme = snapshot.theme,
        .window = snapshot.window,
    };
}

fn planSplits(
    allocator: Allocator,
    steps: *std.ArrayList(Step),
    node: *const PaneNode,
    leaf: usize,
    w: usize,
    t: usize,
    workspace_cwd: []const u8,
) Allocator.Error!void {
    switch (node.*) {
        .leaf => {},
        .split => |split| {
            const new_leaf = leaf + split.first.leafCount();
            try steps.append(allocator, .{ .split_pane = .{
                .workspace = w,
                .tab = t,
                .leaf = leaf,
                .new_leaf = new_leaf,
                .direction = split.direction,
                .ratio = split.ratio,
                .cwd = split.second.firstLeaf().cwd orelse workspace_cwd,
            } });
            try planSplits(allocator, steps, split.first, leaf, w, t, workspace_cwd);
            try planSplits(allocator, steps, split.second, new_leaf, w, t, workspace_cwd);
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const test_leaf_a: PaneNode = .{ .leaf = .{ .cwd = "/home/u/a" } };
const test_leaf_b: PaneNode = .{ .leaf = .{ .cwd = "/home/u/b" } };
const test_leaf_c: PaneNode = .{ .leaf = .{} };
const test_leaf_d: PaneNode = .{ .leaf = .{ .cwd = "/srv/d" } };
// right( a, down( b, right(c, d) ) )
const test_inner: PaneNode = .{ .split = .{ .direction = .right, .ratio = 0.25, .first = &test_leaf_c, .second = &test_leaf_d } };
const test_lower: PaneNode = .{ .split = .{ .direction = .down, .ratio = 0.6, .first = &test_leaf_b, .second = &test_inner } };
const test_root: PaneNode = .{ .split = .{ .direction = .right, .ratio = 0.5, .first = &test_leaf_a, .second = &test_lower } };

const test_local_tabs = [_]TabState{
    .{ .name = "build", .panes = test_root, .focused_leaf = 2, .zoomed = true },
    .{},
};
const test_ssh_tabs = [_]TabState{.{ .panes = .{ .leaf = .{ .cwd = "/var/www" } } }};
const test_ssh_options = [_][]const u8{ "ServerAliveInterval=30", "Compression=yes" };
const test_workspaces = [_]WorkspaceState{
    .{
        .name = "main",
        .cwd = "/home/u",
        .active_tab = 1,
        .tabs = &test_local_tabs,
        .scratchpad_percent = 90,
    },
    .{
        .name = "prod box",
        .kind = .ssh,
        .cwd = "/home/deploy",
        .ssh = .{ .destination = "deploy@prod", .port = 2222, .options = &test_ssh_options },
        .active_tab = 0,
        .tabs = &test_ssh_tabs,
    },
};

fn richSnapshot() Snapshot {
    return .{
        .saved_at_unix = 1_790_000_000,
        .theme = "Gruvbox Dark",
        .window = .{ .x = -40, .y = 25, .width = 1280, .height = 800, .maximized = false },
        .active_workspace = 1,
        .workspaces = &test_workspaces,
    };
}

fn expectSamePanes(expected: *const PaneNode, actual: *const PaneNode) !void {
    try testing.expectEqual(std.meta.activeTag(expected.*), std.meta.activeTag(actual.*));
    switch (expected.*) {
        .leaf => |leaf| {
            if (leaf.cwd) |cwd| {
                try testing.expectEqualStrings(cwd, actual.leaf.cwd.?);
            } else {
                try testing.expect(actual.leaf.cwd == null);
            }
        },
        .split => |split| {
            try testing.expectEqual(split.direction, actual.split.direction);
            try testing.expectApproxEqAbs(split.ratio, actual.split.ratio, 0.00005);
            try expectSamePanes(split.first, actual.split.first);
            try expectSamePanes(split.second, actual.split.second);
        },
    }
}

/// Exported for `workspace`'s tests, which compare a live registry's
/// snapshot with an expected model.
pub fn expectSameSnapshot(expected: *const Snapshot, actual: *const Snapshot) !void {
    try testing.expectEqual(expected.version, actual.version);
    try testing.expectEqual(expected.saved_at_unix, actual.saved_at_unix);
    try testing.expectEqualDeep(expected.theme, actual.theme);
    try testing.expectEqualDeep(expected.window, actual.window);
    try testing.expectEqual(expected.active_workspace, actual.active_workspace);
    try testing.expectEqual(expected.workspaces.len, actual.workspaces.len);
    for (expected.workspaces, actual.workspaces) |e, a| {
        try testing.expectEqualStrings(e.name, a.name);
        try testing.expectEqual(e.kind, a.kind);
        try testing.expectEqualStrings(e.cwd, a.cwd);
        try testing.expectEqualDeep(e.ssh, a.ssh);
        try testing.expectEqual(e.active_tab, a.active_tab);
        try testing.expectEqual(e.scratchpad_percent, a.scratchpad_percent);
        try testing.expectEqual(e.tabs.len, a.tabs.len);
        for (e.tabs, a.tabs) |et, at| {
            try testing.expectEqualDeep(et.name, at.name);
            try testing.expectEqual(et.focused_leaf, at.focused_leaf);
            try testing.expectEqual(et.zoomed, at.zoomed);
            try expectSamePanes(&et.panes, &at.panes);
        }
    }
}

fn expectDecodeError(expected: DecodeError, bytes: []const u8, message_part: []const u8) !void {
    var diagnostic: Diagnostic = .{};
    if (decode(testing.allocator, bytes, &diagnostic)) |owned_value| {
        var owned = owned_value;
        owned.deinit();
        return error.TestUnexpectedSuccess;
    } else |err| {
        try testing.expectEqual(expected, err);
        if (std.mem.indexOf(u8, diagnostic.message(), message_part) == null) {
            log.err("unexpected diagnostic: {s}", .{diagnostic.message()});
            return error.TestUnexpectedDiagnostic;
        }
    }
}

test "a rich snapshot round-trips through the codec and encodes deterministically" {
    const snapshot = richSnapshot();
    var diagnostic: Diagnostic = .{};
    const bytes = try encode(testing.allocator, &snapshot, &diagnostic);
    defer testing.allocator.free(bytes);

    var owned = try decode(testing.allocator, bytes, &diagnostic);
    defer owned.deinit();
    try expectSameSnapshot(&snapshot, &owned.snapshot);

    // Encoding the decoded copy yields the same bytes: one state, one file.
    const again = try encode(testing.allocator, &owned.snapshot, &diagnostic);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(bytes, again);

    try testing.expect(std.mem.indexOf(u8, bytes, "\"ratio\": 0.6,") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"destination\": \"deploy@prod\"") != null);
}

test "the encoded document has a fixed key order and omits null optionals" {
    const tabs = [_]TabState{.{}};
    const workspaces = [_]WorkspaceState{.{ .name = "w", .cwd = "/", .tabs = &tabs }};
    const snapshot: Snapshot = .{ .saved_at_unix = 7, .workspaces = &workspaces };
    var diagnostic: Diagnostic = .{};
    const bytes = try encode(testing.allocator, &snapshot, &diagnostic);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(
        \\{
        \\  "version": 1,
        \\  "saved_at_unix": 7,
        \\  "workspaces": [
        \\    {
        \\      "name": "w",
        \\      "kind": "local",
        \\      "cwd": "/",
        \\      "tabs": [
        \\        {
        \\          "focused_leaf": 0,
        \\          "zoomed": false,
        \\          "panes": {
        \\            "type": "leaf"
        \\          }
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
        \\
    , bytes);
}

test "encode refuses a snapshot that decode would refuse" {
    var diagnostic: Diagnostic = .{};
    const tabs = [_]TabState{.{}};
    const bad_index = [_]WorkspaceState{.{ .name = "w", .cwd = "/", .tabs = &tabs, .active_tab = 1 }};
    try testing.expectError(error.Unrepresentable, encode(testing.allocator, &.{ .workspaces = &bad_index }, &diagnostic));
    try testing.expectEqualStrings("workspaces[0].active_tab: out of range", diagnostic.message());

    const no_target = [_]WorkspaceState{.{ .name = "w", .kind = .ssh, .cwd = "/" }};
    try testing.expectError(error.Unrepresentable, encode(testing.allocator, &.{ .workspaces = &no_target }, &diagnostic));

    const duplicate = [_]WorkspaceState{ .{ .name = "w", .cwd = "/" }, .{ .name = " w ", .cwd = "/" } };
    try testing.expectError(error.Unrepresentable, encode(testing.allocator, &.{ .workspaces = &duplicate }, &diagnostic));
    try testing.expectEqualStrings("workspaces[1].name: duplicates workspaces[0]", diagnostic.message());

    const bad_destination = [_]WorkspaceState{.{ .name = "w", .kind = .ssh, .cwd = "/", .ssh = .{ .destination = "-oProxyCommand=x" } }};
    try testing.expectError(error.Unrepresentable, encode(testing.allocator, &.{ .workspaces = &bad_destination }, &diagnostic));
}

test "unknown fields are ignored and missing optionals take defaults" {
    var diagnostic: Diagnostic = .{};
    var owned = try decode(testing.allocator,
        \\{"version": 1, "future": {"x": [1, 2]}, "workspaces": [
        \\  {"name": "  w  ", "cwd": "/tmp", "colour": "red",
        \\   "ssh": {"destination": "ignored-for-local"},
        \\   "tabs": [{"panes": {"type": "split", "direction": "down", "ratio": 0.3, "extra": true,
        \\                      "first": {"type": "leaf"}, "second": {"type": "leaf", "cwd": "/x"}}},
        \\            {}]}
        \\]}
    , &diagnostic);
    defer owned.deinit();
    const snapshot = owned.snapshot;
    try testing.expectEqual(@as(i64, 0), snapshot.saved_at_unix);
    try testing.expect(snapshot.theme == null);
    try testing.expect(snapshot.window == null);
    try testing.expect(snapshot.active_workspace == null);
    const workspace = snapshot.workspaces[0];
    try testing.expectEqualStrings("w", workspace.name);
    try testing.expectEqual(ContextKind.local, workspace.kind);
    try testing.expect(workspace.ssh == null);
    try testing.expect(workspace.active_tab == null);
    try testing.expect(workspace.scratchpad_percent == null);
    try testing.expectEqual(@as(usize, 2), workspace.tabs.len);
    try testing.expectEqual(@as(usize, 2), workspace.tabs[0].panes.leafCount());
    try testing.expectEqualStrings("/x", workspace.tabs[0].panes.split.second.leaf.cwd.?);
    try testing.expect(workspace.tabs[1].name == null);
    try testing.expect(workspace.tabs[1].panes == .leaf);
    try testing.expectEqual(@as(usize, 0), workspace.tabs[1].focused_leaf);
    try testing.expect(!workspace.tabs[1].zoomed);

    // JSON null reads as absent, and an extreme ratio is kept off the edges.
    var nulls = try decode(testing.allocator,
        \\{"version": 1, "theme": null, "workspaces": [{"name": "w", "cwd": "/", "active_tab": null,
        \\ "tabs": [{"panes": {"type": "split", "direction": "right", "ratio": 1,
        \\   "first": {"type": "leaf"}, "second": {"type": "leaf"}}}]}]}
    , &diagnostic);
    defer nulls.deinit();
    try testing.expect(nulls.snapshot.theme == null);
    try testing.expectEqual(max_ratio, nulls.snapshot.workspaces[0].tabs[0].panes.split.ratio);
}

test "a newer version is incompatible and a malformed document is corrupt" {
    try expectDecodeError(error.Incompatible, "{\"version\": 2, \"workspaces\": []}", "version 2 is newer");
    try expectDecodeError(error.Corrupt, "{\"version\": \"1\", \"workspaces\": []}", "version: not a non-negative integer");
    try expectDecodeError(error.Corrupt, "{\"version\": -1, \"workspaces\": []}", "version");
    try expectDecodeError(error.Corrupt, "{\"workspaces\": []}", "version: missing");
    try expectDecodeError(error.Corrupt, "[]", "not a JSON object");
    try expectDecodeError(error.Corrupt, "", "not valid JSON");
    try expectDecodeError(error.Corrupt, "{\"version\": 1}", "workspaces: missing");
    try expectDecodeError(error.Corrupt, "{\"version\": 1, \"workspaces\": [{\"name\": \"w\", \"cwd\": \"/\", \"kind\": \"vm\"}]}", "kind: not local, ssh or wsl");
    try expectDecodeError(error.Corrupt, "{\"version\": 1, \"workspaces\": [{\"name\": \"w\", \"cwd\": \"/\", \"kind\": \"ssh\"}]}", "ssh: missing");
    try expectDecodeError(error.Corrupt, "{\"version\": 1, \"workspaces\": [{\"name\": \"w\", \"cwd\": \"/\", \"tabs\": [{\"focused_leaf\": 1}]}]}", "focused_leaf: out of range");
    try expectDecodeError(error.Corrupt, "{\"version\": 1, \"workspaces\": [{\"name\": \"w\", \"cwd\": \"/\", \"tabs\": [{\"panes\": {\"type\": \"tree\"}}]}]}", "not leaf or split");
    try expectDecodeError(error.Corrupt, "{\"version\": 1, \"workspaces\": [{\"name\": \"w\", \"cwd\": \"/\", \"scratchpad_percent\": 5}]}", "scratchpad_percent: outside");
    try expectDecodeError(error.Corrupt, "{\"version\": 1, \"window\": {\"width\": 0, \"height\": 10}, \"workspaces\": []}", "window: size");
    try expectDecodeError(error.Corrupt, "{\"version\": 1, \"workspaces\": [{\"name\": \"w\", \"cwd\": \"a\\u0000b\"}]}", "cwd");
    try expectDecodeError(error.Corrupt, "{\"version\": 1, \"workspaces\": [{\"name\": \"w\", \"cwd\": 3}]}", "workspaces[0].cwd: not a string");
}

fn appendPaneJson(list: *std.ArrayList(u8), depth: usize) !void {
    if (depth == 0) return list.appendSlice(testing.allocator, "{\"type\":\"leaf\"}");
    try list.appendSlice(testing.allocator, "{\"type\":\"split\",\"direction\":\"right\",\"ratio\":0.5,\"first\":");
    try appendPaneJson(list, depth - 1);
    try list.appendSlice(testing.allocator, ",\"second\":{\"type\":\"leaf\"}}");
}

fn appendBalancedPaneJson(list: *std.ArrayList(u8), depth: usize) !void {
    if (depth == 0) return list.appendSlice(testing.allocator, "{\"type\":\"leaf\"}");
    try list.appendSlice(testing.allocator, "{\"type\":\"split\",\"direction\":\"down\",\"ratio\":0.5,\"first\":");
    try appendBalancedPaneJson(list, depth - 1);
    try list.appendSlice(testing.allocator, ",\"second\":");
    try appendBalancedPaneJson(list, depth - 1);
    try list.append(testing.allocator, '}');
}

fn appendWorkspacesJson(list: *std.ArrayList(u8), count: usize) !void {
    try list.appendSlice(testing.allocator, "{\"version\":1,\"workspaces\":[");
    for (0..count) |i| {
        if (i != 0) try list.append(testing.allocator, ',');
        try list.print(testing.allocator, "{{\"name\":\"w{d}\",\"cwd\":\"/\"}}", .{i});
    }
    try list.appendSlice(testing.allocator, "]}");
}

test "every bound is enforced" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    var diagnostic: Diagnostic = .{};

    // Workspaces: 64 pass, 65 do not.
    try appendWorkspacesJson(&list, max_workspaces);
    {
        var owned = try decode(testing.allocator, list.items, &diagnostic);
        owned.deinit();
    }
    list.clearRetainingCapacity();
    try appendWorkspacesJson(&list, max_workspaces + 1);
    try expectDecodeError(error.Corrupt, list.items, "workspaces: more than 64");

    // Tabs: 257 in one workspace.
    list.clearRetainingCapacity();
    try list.appendSlice(testing.allocator, "{\"version\":1,\"workspaces\":[{\"name\":\"w\",\"cwd\":\"/\",\"tabs\":[");
    for (0..max_tabs + 1) |i| {
        if (i != 0) try list.append(testing.allocator, ',');
        try list.appendSlice(testing.allocator, "{}");
    }
    try list.appendSlice(testing.allocator, "]}]}");
    try expectDecodeError(error.Corrupt, list.items, "tabs: more than 256");

    // Pane depth: 16 nested splits pass, 17 do not.
    list.clearRetainingCapacity();
    try list.appendSlice(testing.allocator, "{\"version\":1,\"workspaces\":[{\"name\":\"w\",\"cwd\":\"/\",\"tabs\":[{\"panes\":");
    try appendPaneJson(&list, max_pane_depth);
    try list.appendSlice(testing.allocator, "}]}]}");
    {
        var owned = try decode(testing.allocator, list.items, &diagnostic);
        defer owned.deinit();
        try testing.expectEqual(max_pane_depth + 1, owned.snapshot.workspaces[0].tabs[0].panes.leafCount());
    }
    list.clearRetainingCapacity();
    try list.appendSlice(testing.allocator, "{\"version\":1,\"workspaces\":[{\"name\":\"w\",\"cwd\":\"/\",\"tabs\":[{\"panes\":");
    try appendPaneJson(&list, max_pane_depth + 1);
    try list.appendSlice(testing.allocator, "}]}]}");
    try expectDecodeError(error.Corrupt, list.items, "panes nest deeper than 16");

    // Panes per tab: a balanced tree of depth 9 has 512 leaves.
    list.clearRetainingCapacity();
    try list.appendSlice(testing.allocator, "{\"version\":1,\"workspaces\":[{\"name\":\"w\",\"cwd\":\"/\",\"tabs\":[{\"panes\":");
    try appendBalancedPaneJson(&list, 9);
    try list.appendSlice(testing.allocator, "}]}]}");
    try expectDecodeError(error.Corrupt, list.items, "panes: more than 256");

    // Strings: a 257-byte name and a 4097-byte cwd.
    list.clearRetainingCapacity();
    try list.appendSlice(testing.allocator, "{\"version\":1,\"workspaces\":[{\"cwd\":\"/\",\"name\":\"");
    try list.appendNTimes(testing.allocator, 'n', max_name_bytes + 1);
    try list.appendSlice(testing.allocator, "\"}]}");
    try expectDecodeError(error.Corrupt, list.items, "workspaces[0].name");
    list.clearRetainingCapacity();
    try list.appendSlice(testing.allocator, "{\"version\":1,\"workspaces\":[{\"name\":\"w\",\"cwd\":\"/");
    try list.appendNTimes(testing.allocator, 'p', max_path_bytes);
    try list.appendSlice(testing.allocator, "\"}]}");
    try expectDecodeError(error.Corrupt, list.items, "workspaces[0].cwd");

    // SSH options: 33.
    list.clearRetainingCapacity();
    try list.appendSlice(testing.allocator, "{\"version\":1,\"workspaces\":[{\"name\":\"w\",\"cwd\":\"/\",\"kind\":\"ssh\",\"ssh\":{\"destination\":\"h\",\"options\":[");
    for (0..max_ssh_options + 1) |i| {
        if (i != 0) try list.append(testing.allocator, ',');
        try list.appendSlice(testing.allocator, "\"A=b\"");
    }
    try list.appendSlice(testing.allocator, "]}}]}");
    try expectDecodeError(error.Corrupt, list.items, "options: more than 32");

    // The file itself: one byte over 1 MiB is refused before parsing.
    const big = try testing.allocator.alloc(u8, max_file_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, ' ');
    try expectDecodeError(error.Corrupt, big, "larger than");

    // Deep JSON nesting outside the pane tree costs memory, never stack.
    list.clearRetainingCapacity();
    try list.appendNTimes(testing.allocator, '[', 100_000);
    try list.appendNTimes(testing.allocator, ']', 100_000);
    try expectDecodeError(error.Corrupt, list.items, "not a JSON object");
}

test "random, truncated and mutated bytes are refused without crashing" {
    const snapshot = richSnapshot();
    var diagnostic: Diagnostic = .{};
    const bytes = try encode(testing.allocator, &snapshot, &diagnostic);
    defer testing.allocator.free(bytes);

    // Every prefix that drops the closing brace is malformed.
    const closing = std.mem.lastIndexOfScalar(u8, bytes, '}').?;
    for (0..closing + 1) |len| {
        try testing.expectError(error.Corrupt, decode(testing.allocator, bytes[0..len], &diagnostic));
    }

    var prng: std.Random.DefaultPrng = .init(0x65_0001);
    const random = prng.random();

    // Single-byte mutations may stay valid; they must never crash or leak.
    const copy = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(copy);
    for (0..2000) |_| {
        @memcpy(copy, bytes);
        const at = random.uintLessThan(usize, copy.len);
        copy[at] = random.int(u8);
        if (decode(testing.allocator, copy, &diagnostic)) |owned_value| {
            var owned = owned_value;
            owned.deinit();
        } else |err| switch (err) {
            error.Corrupt, error.Incompatible => {},
            error.OutOfMemory => return err,
        }
    }

    // Pure noise, including NUL and invalid UTF-8.
    var noise: [512]u8 = undefined;
    for (0..2000) |_| {
        const len = random.uintAtMost(usize, noise.len);
        random.bytes(noise[0..len]);
        if (len != 0) noise[0] = '{';
        if (decode(testing.allocator, noise[0..len], &diagnostic)) |owned_value| {
            var owned = owned_value;
            owned.deinit();
        } else |err| switch (err) {
            error.Corrupt, error.Incompatible => {},
            error.OutOfMemory => return err,
        }
    }
}

test "decode and encode release everything when allocation fails part way" {
    const snapshot = richSnapshot();
    var diagnostic: Diagnostic = .{};
    const bytes = try encode(testing.allocator, &snapshot, &diagnostic);
    defer testing.allocator.free(bytes);
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        if (decode(failing.allocator(), bytes, &diagnostic)) |owned_value| {
            var owned = owned_value;
            owned.deinit();
            break;
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
    }
    fail_index = 0;
    while (true) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        if (encode(failing.allocator(), &snapshot, &diagnostic)) |encoded| {
            testing.allocator.free(encoded);
            break;
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
    }
}

test "a version 0 document migrates its context field to kind" {
    var diagnostic: Diagnostic = .{};
    var owned = try decode(testing.allocator,
        \\{"version": 0, "workspaces": [
        \\  {"name": "remote", "cwd": "/srv", "context": "ssh", "ssh": {"destination": "box"}},
        \\  {"name": "here", "cwd": "/"}
        \\]}
    , &diagnostic);
    defer owned.deinit();
    try testing.expectEqual(current_version, owned.snapshot.version);
    try testing.expectEqual(ContextKind.ssh, owned.snapshot.workspaces[0].kind);
    try testing.expectEqualStrings("box", owned.snapshot.workspaces[0].ssh.?.destination);
    try testing.expectEqual(ContextKind.local, owned.snapshot.workspaces[1].kind);

    // Re-encoding writes the current version and the current spelling.
    const bytes = try encode(testing.allocator, &owned.snapshot, &diagnostic);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.startsWith(u8, bytes, "{\n  \"version\": 1,"));
    try testing.expect(std.mem.indexOf(u8, bytes, "\"context\"") == null);
}

test "the state path follows each platform's convention" {
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings("/x/state/conduit/state.json", statePath(&buffer, .linux, .{ .xdg_state_home = "/x/state/", .home = "/home/u" }).?);
    try testing.expectEqualStrings("/home/u/.local/state/conduit/state.json", statePath(&buffer, .linux, .{ .home = "/home/u" }).?);
    // A relative XDG_STATE_HOME is invalid by specification and ignored.
    try testing.expectEqualStrings("/home/u/.local/state/conduit/state.json", statePath(&buffer, .linux, .{ .xdg_state_home = "rel", .home = "/home/u" }).?);
    try testing.expectEqualStrings("/home/u/.local/state/conduit/state.json", statePath(&buffer, .freebsd, .{ .xdg_state_home = "", .home = "/home/u/" }).?);
    try testing.expectEqualStrings("/Users/u/Library/Application Support/conduit/state.json", statePath(&buffer, .macos, .{ .xdg_state_home = "/x", .home = "/Users/u" }).?);
    try testing.expectEqualStrings("C:\\Users\\u\\AppData\\Local\\conduit\\state.json", statePath(&buffer, .windows, .{ .local_app_data = "C:\\Users\\u\\AppData\\Local\\" }).?);
    try testing.expect(statePath(&buffer, .linux, .{}) == null);
    try testing.expect(statePath(&buffer, .windows, .{ .home = "/home/u" }) == null);
    var tiny: [8]u8 = undefined;
    try testing.expect(statePath(&tiny, .linux, .{ .home = "/home/u" }) == null);
}

test "save is atomic, load is bounded and a corrupt file is moved aside for a clean start" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/state/conduit/state.json", .{tmp.sub_path[0..]});
    const buffer = try testing.allocator.alloc(u8, load_buffer_bytes);
    defer testing.allocator.free(buffer);
    var diagnostic: Diagnostic = .{};

    // Nothing saved yet: a clean start with nothing to report.
    try testing.expect(load(testing.io, path, buffer) == .missing);
    try testing.expect(try restoreFromDisk(testing.io, testing.allocator, path, buffer, 100, &diagnostic) == .clean);
    try testing.expectEqual(@as(usize, 0), diagnostic.len);

    // Save creates the directory, replaces the old file, leaves no temporary
    // behind and reads back.
    const snapshot = richSnapshot();
    const bytes = try encode(testing.allocator, &snapshot, &diagnostic);
    defer testing.allocator.free(bytes);
    try save(testing.io, path, "stale");
    try save(testing.io, path, bytes);
    var temporary_buffer: [300]u8 = undefined;
    const temporary = try std.fmt.bufPrint(&temporary_buffer, "{s}" ++ temporary_suffix, .{path});
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(testing.io, temporary, .{}));
    try testing.expectEqualStrings(bytes, load(testing.io, path, buffer).bytes);
    if (builtin.os.tag != .windows) {
        const stat = try Io.Dir.cwd().statFile(testing.io, path, .{});
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    }
    switch (try restoreFromDisk(testing.io, testing.allocator, path, buffer, 100, &diagnostic)) {
        .clean => return error.TestExpectedSnapshot,
        .snapshot => |owned_value| {
            var owned = owned_value;
            defer owned.deinit();
            try expectSameSnapshot(&snapshot, &owned.snapshot);
        },
    }

    // A corrupt file falls back to a clean start and is kept as evidence.
    try save(testing.io, path, bytes[0 .. bytes.len / 2]);
    try testing.expect(try restoreFromDisk(testing.io, testing.allocator, path, buffer, 1_790_000_123, &diagnostic) == .clean);
    try testing.expectEqualStrings("state file is not valid JSON; moved aside as .corrupt-1790000123", diagnostic.message());
    try testing.expect(load(testing.io, path, buffer) == .missing);
    var corrupt_buffer: [300]u8 = undefined;
    const corrupt = try std.fmt.bufPrint(&corrupt_buffer, "{s}.corrupt-1790000123", .{path});
    try testing.expectEqualStrings(bytes[0 .. bytes.len / 2], load(testing.io, corrupt, buffer).bytes);

    // A file from a newer Conduit is set aside the same way.
    try save(testing.io, path, "{\"version\": 9, \"workspaces\": []}");
    try testing.expect(try restoreFromDisk(testing.io, testing.allocator, path, buffer, 200, &diagnostic) == .clean);
    try testing.expect(std.mem.startsWith(u8, diagnostic.message(), "version 9 is newer"));
    try testing.expect(load(testing.io, path, buffer) == .missing);

    // An oversized file is detected rather than cut, and set aside too.
    const big = try testing.allocator.alloc(u8, max_file_bytes + 10);
    defer testing.allocator.free(big);
    @memset(big, ' ');
    try save(testing.io, path, big);
    try testing.expectEqual(load_buffer_bytes, load(testing.io, path, buffer).bytes.len);
    try testing.expect(try restoreFromDisk(testing.io, testing.allocator, path, buffer, 300, &diagnostic) == .clean);
    try testing.expect(std.mem.startsWith(u8, diagnostic.message(), "state file is larger than"));

    // A directory where the file should be is reported and left alone.
    try Io.Dir.cwd().createDirPath(testing.io, path);
    diagnostic = .{};
    try testing.expect(try restoreFromDisk(testing.io, testing.allocator, path, buffer, 400, &diagnostic) == .clean);
    try testing.expectEqualStrings("the state path is a directory", diagnostic.message());
}

test "the restore plan rebuilds every workspace, split, focus, zoom and selection in order" {
    const snapshot = richSnapshot();
    var plan = try planRestore(testing.allocator, &snapshot);
    defer plan.deinit(testing.allocator);
    try testing.expectEqualStrings("Gruvbox Dark", plan.theme.?);
    try testing.expectEqual(@as(u32, 1280), plan.window.?.width);

    const expected = [_]Step{
        .{ .create_workspace = .{ .workspace = 0, .name = "main", .kind = .local, .cwd = "/home/u", .ssh = null, .scratchpad_percent = 90, .needs_reconnect = false } },
        // Tab 0 is right(a, down(b, right(c, d))); leaves a=0, b=1, c=2, d=3.
        .{ .create_tab = .{ .workspace = 0, .tab = 0, .name = "build", .cwd = "/home/u/a" } },
        .{ .split_pane = .{ .workspace = 0, .tab = 0, .leaf = 0, .new_leaf = 1, .direction = .right, .ratio = 0.5, .cwd = "/home/u/b" } },
        .{ .split_pane = .{ .workspace = 0, .tab = 0, .leaf = 1, .new_leaf = 2, .direction = .down, .ratio = 0.6, .cwd = "/home/u" } },
        .{ .split_pane = .{ .workspace = 0, .tab = 0, .leaf = 2, .new_leaf = 3, .direction = .right, .ratio = 0.25, .cwd = "/srv/d" } },
        .{ .focus_pane = .{ .workspace = 0, .tab = 0, .leaf = 2 } },
        .{ .zoom_pane = .{ .workspace = 0, .tab = 0 } },
        .{ .create_tab = .{ .workspace = 0, .tab = 1, .name = null, .cwd = "/home/u" } },
        .{ .focus_pane = .{ .workspace = 0, .tab = 1, .leaf = 0 } },
        .{ .select_tab = .{ .workspace = 0, .tab = 1 } },
        .{ .create_workspace = .{ .workspace = 1, .name = "prod box", .kind = .ssh, .cwd = "/home/deploy", .ssh = .{ .destination = "deploy@prod", .port = 2222, .options = &test_ssh_options }, .scratchpad_percent = null, .needs_reconnect = true } },
        .{ .create_tab = .{ .workspace = 1, .tab = 0, .name = null, .cwd = "/var/www" } },
        .{ .focus_pane = .{ .workspace = 1, .tab = 0, .leaf = 0 } },
        .{ .select_tab = .{ .workspace = 1, .tab = 0 } },
        .{ .select_workspace = .{ .workspace = 1 } },
    };
    try testing.expectEqualDeep(@as([]const Step, &expected), @as([]const Step, plan.steps));
}

test "a workspace without tabs gets one default tab and an empty snapshot plans nothing" {
    const workspaces = [_]WorkspaceState{.{ .name = "bare", .cwd = "/opt" }};
    var plan = try planRestore(testing.allocator, &.{ .workspaces = &workspaces });
    defer plan.deinit(testing.allocator);
    const expected = [_]Step{
        .{ .create_workspace = .{ .workspace = 0, .name = "bare", .kind = .local, .cwd = "/opt", .ssh = null, .scratchpad_percent = null, .needs_reconnect = false } },
        .{ .create_tab = .{ .workspace = 0, .tab = 0, .name = null, .cwd = "/opt" } },
        .{ .focus_pane = .{ .workspace = 0, .tab = 0, .leaf = 0 } },
        .{ .select_tab = .{ .workspace = 0, .tab = 0 } },
    };
    try testing.expectEqualDeep(@as([]const Step, &expected), @as([]const Step, plan.steps));

    var empty = try planRestore(testing.allocator, &.{});
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), empty.steps.len);
}
