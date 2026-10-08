//! An immutable, fixed-capacity copy of the semantic tree for the
//! accessibility worker.
//!
//! The owner thread `capture`s the live `ui.Tree` into a `Snapshot` it owns;
//! the bridge then hands the whole buffer to the worker. The worker reads only
//! snapshots and never touches `ui`, so the tree stays single-threaded
//! (invariant 3: the snapshot is a projection of the one tree, not a second
//! model that anything edits).
//!
//! Storage is allocated once by `init`. `capture` allocates nothing: an
//! element beyond `node_capacity`, or text beyond `string_capacity`, is
//! dropped and the snapshot is marked `truncated`.

const std = @import("std");
const ui = @import("ui");

/// "No node": a parent link of a top-level node, or an empty child list.
pub const none: u32 = std.math.maxInt(u32);

/// The longest id, role, label or action copied, in bytes. Longer text is cut
/// at a UTF-8 boundary.
pub const max_string_bytes: usize = 1024;

/// A slice of `Snapshot.strings`.
pub const Str = struct {
    start: u32 = 0,
    len: u32 = 0,
};

/// One copied element.
pub const Node = struct {
    /// Stable 64-bit key derived from the semantic id; it names the AT-SPI
    /// object path, so the same element keeps the same path across frames.
    key: u64,
    id: Str,
    /// Conduit's product role, as registered in the tree.
    role: Str,
    label: Str,
    /// Named action, empty when the element has none.
    action: Str,
    parent: u32 = none,
    first_child: u32 = none,
    last_child: u32 = none,
    next_sibling: u32 = none,
    child_count: u32 = 0,
    index_in_parent: u32 = 0,
    /// Clipped device pixels relative to the window.
    bounds: ui.Bounds,
    primitive: ui.Primitive,
    selected: bool = false,
    focused: bool = false,
};

/// What `append` copies for one element. Every slice is borrowed for the call.
pub const ElementInput = struct {
    id: []const u8,
    parent: ?[]const u8 = null,
    role: []const u8,
    label: []const u8,
    action: ?[]const u8 = null,
    bounds: ui.Bounds,
    primitive: ui.Primitive,
    selected: bool = false,
    focused: bool = false,
};

/// The key an element id maps to. Stable across runs and frames.
pub fn keyOf(id: []const u8) u64 {
    return std.hash.Wyhash.hash(0x636f6e64756974, id);
}

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    nodes: []Node,
    len: u32 = 0,
    strings: []u8,
    strings_len: u32 = 0,
    /// Open-addressing table from key to node index; `none` marks a free slot.
    table: []u32,
    /// The window surface, in device pixels.
    surface: ui.Bounds = ui.Bounds.empty,
    top_first: u32 = none,
    top_last: u32 = none,
    top_count: u32 = 0,
    /// Whether elements or text were dropped because a capacity was reached.
    truncated: bool = false,
    /// Hash of everything copied, to tell an unchanged tree from a changed one.
    fingerprint: u64 = 0,
    hasher: std.hash.Wyhash = std.hash.Wyhash.init(0),

    /// Allocate fixed node, string and lookup storage.
    pub fn init(
        allocator: std.mem.Allocator,
        node_capacity: u32,
        string_capacity: u32,
    ) std.mem.Allocator.Error!Snapshot {
        std.debug.assert(node_capacity > 0 and node_capacity < none / 4);
        const nodes = try allocator.alloc(Node, node_capacity);
        errdefer allocator.free(nodes);
        const strings = try allocator.alloc(u8, string_capacity);
        errdefer allocator.free(strings);
        const table_len = std.math.ceilPowerOfTwoAssert(u32, node_capacity * 2);
        const table = try allocator.alloc(u32, table_len);
        @memset(table, none);
        return .{ .allocator = allocator, .nodes = nodes, .strings = strings, .table = table };
    }

    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.table);
        self.allocator.free(self.strings);
        self.allocator.free(self.nodes);
        self.* = undefined;
    }

    /// Empty the snapshot and set the window surface for the next capture.
    pub fn begin(self: *Snapshot, surface: ui.Bounds) void {
        @memset(self.table, none);
        self.len = 0;
        self.strings_len = 0;
        self.top_first = none;
        self.top_last = none;
        self.top_count = 0;
        self.truncated = false;
        self.surface = surface;
        self.hasher = std.hash.Wyhash.init(0);
        self.hasher.update(std.mem.asBytes(&surface.x));
        self.hasher.update(std.mem.asBytes(&surface.y));
        self.hasher.update(std.mem.asBytes(&surface.width));
        self.hasher.update(std.mem.asBytes(&surface.height));
        self.fingerprint = 0;
    }

    /// Copy one element. Its parent must already have been appended; an
    /// element whose parent is missing (dropped by truncation) becomes
    /// top-level. Returns false if the element was dropped.
    pub fn append(self: *Snapshot, input: ElementInput) bool {
        if (self.len == self.nodes.len) {
            self.truncated = true;
            return false;
        }
        const strings_mark = self.strings_len;
        const id = self.copy(input.id) orelse return self.dropped(strings_mark);
        const role = self.copy(input.role) orelse return self.dropped(strings_mark);
        const label = self.copy(input.label) orelse return self.dropped(strings_mark);
        const action = self.copy(input.action orelse "") orelse return self.dropped(strings_mark);
        if (id.len == 0) return self.dropped(strings_mark);

        var key = keyOf(self.str(id));
        // A 64-bit collision inside one window is vanishingly unlikely, but it
        // must not alias two elements: probe to the next free key.
        while (self.indexOfKey(key) != null) key +%= 1;

        const index = self.len;
        var node: Node = .{
            .key = key,
            .id = id,
            .role = role,
            .label = label,
            .action = action,
            .bounds = input.bounds,
            .primitive = input.primitive,
            .selected = input.selected,
            .focused = input.focused,
        };
        const parent: u32 = if (input.parent) |p| self.indexOfId(p) orelse none else none;
        node.parent = parent;
        if (parent == none) {
            node.index_in_parent = self.top_count;
            if (self.top_last == none) self.top_first = index else self.nodes[self.top_last].next_sibling = index;
            self.top_last = index;
            self.top_count += 1;
        } else {
            const p = &self.nodes[parent];
            node.index_in_parent = p.child_count;
            if (p.last_child == none) p.first_child = index else self.nodes[p.last_child].next_sibling = index;
            p.last_child = index;
            p.child_count += 1;
        }
        self.nodes[index] = node;
        self.len += 1;
        self.insertKey(key, index);

        self.hasher.update(std.mem.asBytes(&key));
        self.hasher.update(std.mem.asBytes(&parent));
        self.hasher.update(self.str(role));
        self.hasher.update(&.{0});
        self.hasher.update(self.str(label));
        self.hasher.update(&.{0});
        self.hasher.update(self.str(action));
        self.hasher.update(&.{ @intFromEnum(input.primitive), @intFromBool(input.selected), @intFromBool(input.focused) });
        self.hasher.update(std.mem.asBytes(&input.bounds.x));
        self.hasher.update(std.mem.asBytes(&input.bounds.y));
        self.hasher.update(std.mem.asBytes(&input.bounds.width));
        self.hasher.update(std.mem.asBytes(&input.bounds.height));
        return true;
    }

    fn dropped(self: *Snapshot, strings_mark: u32) bool {
        self.strings_len = strings_mark;
        self.truncated = true;
        return false;
    }

    /// Seal the snapshot and compute its fingerprint.
    pub fn finish(self: *Snapshot) void {
        self.fingerprint = self.hasher.final();
    }

    /// Copy the live tree. Allocation-free; call between frames on the owner
    /// thread. Hover and press are left out: they are pointer feedback, not
    /// accessible state, and would otherwise republish on every motion.
    pub fn capture(self: *Snapshot, tree: *const ui.Tree) void {
        self.begin(tree.geometry.surface_bounds);
        for (tree.elements()) |element| {
            _ = self.append(.{
                .id = element.id.value,
                .parent = if (element.parent) |p| p.value else null,
                .role = element.role,
                .label = element.label,
                .action = element.action,
                .bounds = element.bounds,
                .primitive = element.primitive,
                .selected = element.state.selected,
                .focused = element.state.focused,
            });
        }
        self.finish();
    }

    /// Copy `text`, sanitised for D-Bus: NUL bytes become spaces and text is
    /// cut to `max_string_bytes` at a UTF-8 boundary. Invalid UTF-8 is copied
    /// as empty. Returns null when the string buffer is full.
    fn copy(self: *Snapshot, text: []const u8) ?Str {
        var len = @min(text.len, max_string_bytes);
        while (len > 0 and len < text.len and (text[len] & 0xc0) == 0x80) len -= 1;
        const source = if (std.unicode.utf8ValidateSlice(text[0..len])) text[0..len] else "";
        if (source.len > self.strings.len - self.strings_len) return null;
        const start = self.strings_len;
        for (source, self.strings[start .. start + source.len]) |c, *out| out.* = if (c == 0) ' ' else c;
        self.strings_len += @intCast(source.len);
        return .{ .start = start, .len = @intCast(source.len) };
    }

    /// The bytes of `s`.
    pub fn str(self: *const Snapshot, s: Str) []const u8 {
        return self.strings[s.start .. s.start + s.len];
    }

    fn insertKey(self: *Snapshot, key: u64, index: u32) void {
        const mask = self.table.len - 1;
        var slot: usize = @intCast(key & mask);
        while (self.table[slot] != none) slot = (slot + 1) & mask;
        self.table[slot] = index;
    }

    /// The node with `key`, if present.
    pub fn indexOfKey(self: *const Snapshot, key: u64) ?u32 {
        const mask = self.table.len - 1;
        var slot: usize = @intCast(key & mask);
        while (self.table[slot] != none) : (slot = (slot + 1) & mask) {
            const index = self.table[slot];
            if (self.nodes[index].key == key) return index;
        }
        return null;
    }

    /// The node with semantic id `id`, if present.
    pub fn indexOfId(self: *const Snapshot, id: []const u8) ?u32 {
        var key = keyOf(id);
        while (self.indexOfKey(key)) |index| : (key +%= 1) {
            if (std.mem.eql(u8, self.str(self.nodes[index].id), id)) return index;
        }
        return null;
    }

    /// All copied nodes in registration (painter and focus) order.
    pub fn slice(self: *const Snapshot) []const Node {
        return self.nodes[0..self.len];
    }

    /// The first child of `parent` (`none` for the window's children).
    pub fn firstChild(self: *const Snapshot, parent: u32) u32 {
        return if (parent == none) self.top_first else self.nodes[parent].first_child;
    }

    /// How many children `parent` has (`none` for the window's children).
    pub fn childCount(self: *const Snapshot, parent: u32) u32 {
        return if (parent == none) self.top_count else self.nodes[parent].child_count;
    }

    /// The `n`th child of `parent`, or null.
    pub fn childAt(self: *const Snapshot, parent: u32, n: u32) ?u32 {
        var index = self.firstChild(parent);
        var i: u32 = 0;
        while (index != none) : (index = self.nodes[index].next_sibling) {
            if (i == n) return index;
            i += 1;
        }
        return null;
    }

    /// The focused node, if any.
    pub fn focused(self: *const Snapshot) ?u32 {
        for (self.slice(), 0..) |node, i| if (node.focused) return @intCast(i);
        return null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn bounds(x: i32, y: i32, w: u32, h: u32) ui.Bounds {
    return .{ .x = x, .y = y, .width = w, .height = h };
}

test "append links parents, children and indices" {
    var s = try Snapshot.init(testing.allocator, 8, 256);
    defer s.deinit();
    s.begin(bounds(0, 0, 100, 50));
    try testing.expect(s.append(.{ .id = "sidebar", .role = "sidebar", .label = "Sidebar", .bounds = bounds(0, 0, 10, 50), .primitive = .surface }));
    try testing.expect(s.append(.{ .id = "ws.1", .parent = "sidebar", .role = "workspace", .label = "one", .action = "ws.go", .bounds = bounds(0, 0, 10, 1), .primitive = .interactive_text, .selected = true }));
    try testing.expect(s.append(.{ .id = "ws.1.tab.1", .parent = "ws.1", .role = "tab", .label = "bash", .action = "tab.go", .bounds = bounds(1, 1, 9, 1), .primitive = .interactive_text }));
    try testing.expect(s.append(.{ .id = "ws.2", .parent = "sidebar", .role = "workspace", .label = "two", .action = "ws.go", .bounds = bounds(0, 2, 10, 1), .primitive = .interactive_text }));
    try testing.expect(s.append(.{ .id = "pane", .role = "pane", .label = "Pane", .bounds = bounds(10, 0, 90, 50), .primitive = .surface }));
    s.finish();

    try testing.expectEqual(@as(u32, 2), s.childCount(none));
    try testing.expectEqual(@as(u32, 2), s.childCount(0));
    try testing.expectEqual(@as(?u32, 3), s.childAt(0, 1));
    try testing.expectEqual(@as(u32, 1), s.nodes[3].index_in_parent);
    try testing.expectEqual(@as(?u32, 4), s.childAt(none, 1));
    try testing.expectEqual(@as(?u32, null), s.childAt(0, 2));
    try testing.expectEqual(@as(?u32, 2), s.indexOfId("ws.1.tab.1"));
    try testing.expectEqual(@as(?u32, 1), s.indexOfKey(keyOf("ws.1")));
    try testing.expectEqualStrings("two", s.str(s.nodes[3].label));
    try testing.expectEqual(@as(u32, 1), s.nodes[2].parent);
}

test "capacity limits truncate rather than fail" {
    var s = try Snapshot.init(testing.allocator, 2, 12);
    defer s.deinit();
    s.begin(bounds(0, 0, 1, 1));
    try testing.expect(s.append(.{ .id = "a", .role = "r", .label = "l", .bounds = bounds(0, 0, 1, 1), .primitive = .text }));
    // Strings no longer fit: dropped, and its partial strings released.
    try testing.expect(!s.append(.{ .id = "b", .role = "role", .label = "a long label", .bounds = bounds(0, 0, 1, 1), .primitive = .text }));
    try testing.expect(s.truncated);
    try testing.expectEqual(@as(u32, 3), s.strings_len);
    try testing.expect(s.append(.{ .id = "c", .parent = "missing", .role = "r", .label = "", .bounds = bounds(0, 0, 1, 1), .primitive = .text }));
    try testing.expect(!s.append(.{ .id = "d", .role = "r", .label = "", .bounds = bounds(0, 0, 1, 1), .primitive = .text }));
    try testing.expectEqual(@as(u32, 2), s.top_count);
}

test "strings are sanitised and cut on a UTF-8 boundary" {
    var s = try Snapshot.init(testing.allocator, 2, 4096);
    defer s.deinit();
    s.begin(bounds(0, 0, 1, 1));
    var long: [max_string_bytes + 1]u8 = undefined;
    @memset(&long, 'a');
    long[max_string_bytes - 1] = 0xc3;
    long[max_string_bytes] = 0xa9;
    try testing.expect(s.append(.{ .id = "x", .role = "r", .label = &long, .bounds = bounds(0, 0, 1, 1), .primitive = .text }));
    try testing.expectEqual(@as(usize, max_string_bytes - 1), s.str(s.nodes[0].label).len);
    try testing.expect(s.append(.{ .id = "y", .role = "r", .label = "a\x00b", .bounds = bounds(0, 0, 1, 1), .primitive = .text }));
    try testing.expectEqualStrings("a b", s.str(s.nodes[1].label));
}

test "fingerprint tracks content and resets cleanly" {
    var s = try Snapshot.init(testing.allocator, 4, 256);
    defer s.deinit();
    const element: ElementInput = .{ .id = "a", .role = "r", .label = "one", .bounds = bounds(0, 0, 1, 1), .primitive = .text };
    s.begin(bounds(0, 0, 9, 9));
    _ = s.append(element);
    s.finish();
    const first = s.fingerprint;
    s.begin(bounds(0, 0, 9, 9));
    _ = s.append(element);
    s.finish();
    try testing.expectEqual(first, s.fingerprint);
    try testing.expectEqual(@as(?u32, 0), s.indexOfId("a"));
    var changed = element;
    changed.focused = true;
    s.begin(bounds(0, 0, 9, 9));
    _ = s.append(changed);
    s.finish();
    try testing.expect(first != s.fingerprint);
    try testing.expectEqual(@as(?u32, 0), s.focused());
}

test "capture copies a ui.Tree" {
    var tree = try ui.Tree.init(testing.allocator, 4, 2);
    defer tree.deinit();
    try tree.beginFrame(.{ .cell_width = 10, .cell_height = 20, .surface_bounds = bounds(0, 0, 200, 100) });
    try tree.addSurface(.{ .id = .{ .value = "palette.dialog" }, .role = "dialog", .label = "Command palette", .bounds = .{ .x = 1, .y = 1, .width = 10, .height = 3 } }, .{ .rect = ui.Rect.empty });
    try tree.addInteractiveText(.{
        .id = .{ .value = "palette.action.0" },
        .parent = .{ .value = "palette.dialog" },
        .role = "command",
        .label = "New tab",
        .selected = true,
        .action = "palette.activate",
        .bounds = .{ .x = 2, .y = 2, .width = 8, .height = 1 },
    }, .{ .id = .{ .value = "x" }, .label = "x", .action = "x" });
    try tree.endFrame();
    _ = tree.focus(.{ .value = "palette.action.0" });

    var s = try Snapshot.init(testing.allocator, 4, 256);
    defer s.deinit();
    s.capture(&tree);
    try testing.expectEqual(@as(u32, 2), s.len);
    const row = s.nodes[1];
    try testing.expectEqualStrings("New tab", s.str(row.label));
    try testing.expectEqualStrings("palette.activate", s.str(row.action));
    try testing.expectEqual(@as(u32, 0), row.parent);
    try testing.expect(row.selected and row.focused);
    try testing.expectEqual(bounds(20, 40, 80, 20), row.bounds);
    try testing.expectEqual(bounds(0, 0, 200, 100), s.surface);
}
