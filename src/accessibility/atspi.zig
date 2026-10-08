//! The AT-SPI2 object model served from a `Snapshot`.
//!
//! This file is pure: it turns incoming D-Bus method calls into reply bodies
//! and snapshot differences into event signals, without sockets or threads,
//! so all of it is unit-testable. `accessibility.zig` owns the connection.
//!
//! Object layout on the bus:
//!
//! - `/org/a11y/atspi/accessible/root` — the application (role
//!   `application`), embedded into the registry's desktop.
//! - `/org/a11y/atspi/accessible/window` — the one window (role `frame`),
//!   whose children are the tree's top-level elements.
//! - `/org/a11y/atspi/accessible/<16 hex digits>` — one semantic element,
//!   named by the stable key of its semantic id.
//! - `/org/a11y/atspi/cache` — the `Cache` interface.

const std = @import("std");
const ui = @import("ui");
const dbus = @import("dbus.zig");
const snapshot_mod = @import("snapshot.zig");

const Snapshot = snapshot_mod.Snapshot;
const Node = snapshot_mod.Node;
const none = snapshot_mod.none;
const Writer = dbus.Writer;
const Reader = dbus.Reader;

pub const root_path = "/org/a11y/atspi/accessible/root";
pub const window_path = "/org/a11y/atspi/accessible/window";
pub const null_path = "/org/a11y/atspi/null";
pub const cache_path = "/org/a11y/atspi/cache";
const element_prefix = "/org/a11y/atspi/accessible/";

/// The length of an element object path.
pub const element_path_len = element_prefix.len + 16;

pub const iface_accessible = "org.a11y.atspi.Accessible";
pub const iface_component = "org.a11y.atspi.Component";
pub const iface_action = "org.a11y.atspi.Action";
pub const iface_application = "org.a11y.atspi.Application";
pub const iface_cache = "org.a11y.atspi.Cache";
pub const iface_event_object = "org.a11y.atspi.Event.Object";
const iface_properties = "org.freedesktop.DBus.Properties";
const iface_introspectable = "org.freedesktop.DBus.Introspectable";
const iface_peer = "org.freedesktop.DBus.Peer";

// ---------------------------------------------------------------------------
// Roles and states
// ---------------------------------------------------------------------------

/// The AT-SPI roles Conduit uses (`AtspiRole` values) with their role names.
pub const Role = enum(u32) {
    alert = 2,
    dialog = 16,
    frame = 23,
    label = 29,
    list_item = 32,
    menu_item = 35,
    page_tab = 37,
    panel = 39,
    popup_menu = 41,
    push_button = 43,
    separator = 50,
    status_bar = 54,
    terminal = 60,
    application = 75,
    entry = 79,
    heading = 83,
    link = 88,
    tree_item = 91,
    notification = 101,

    /// The non-localised AT-SPI role name.
    pub fn name(self: Role) []const u8 {
        return switch (self) {
            .alert => "alert",
            .dialog => "dialog",
            .frame => "frame",
            .label => "label",
            .list_item => "list item",
            .menu_item => "menu item",
            .page_tab => "page tab",
            .panel => "panel",
            .popup_menu => "popup menu",
            .push_button => "button",
            .separator => "separator",
            .status_bar => "status bar",
            .terminal => "terminal",
            .application => "application",
            .entry => "entry",
            .heading => "heading",
            .link => "link",
            .tree_item => "tree item",
            .notification => "notification",
        };
    }
};

/// Map Conduit's product role (and primitive) to an AT-SPI role. Unknown
/// product roles fall back to what their primitive is.
pub fn roleFor(role: []const u8, primitive: ui.Primitive) Role {
    const Entry = struct { []const u8, Role };
    const table = [_]Entry{
        .{ "sidebar", .panel },
        .{ "pane", .panel },
        .{ "region", .panel },
        .{ "surface", .panel },
        .{ "presentation", .panel },
        .{ "agent_view", .panel },
        .{ "dialog", .dialog },
        .{ "menu", .popup_menu },
        .{ "menu_item", .menu_item },
        .{ "workspace", .tree_item },
        .{ "tab", .page_tab },
        .{ "command", .list_item },
        .{ "choice", .list_item },
        .{ "option", .list_item },
        .{ "setting", .list_item },
        .{ "agent_row", .list_item },
        .{ "button", .push_button },
        .{ "action", .push_button },
        .{ "palette_hint", .push_button },
        .{ "sidebar_toggle", .push_button },
        .{ "search_control", .push_button },
        .{ "link", .link },
        .{ "terminal_link", .link },
        .{ "terminal", .terminal },
        .{ "heading", .heading },
        .{ "separator", .separator },
        .{ "notification", .notification },
        .{ "error", .alert },
        .{ "config_error", .alert },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, entry[0], role)) return entry[1];
    }
    return switch (primitive) {
        .text => .label,
        .interactive_text => .push_button,
        .surface => .panel,
        .input => .entry,
    };
}

/// `AtspiStateType` values Conduit reports.
pub const State = enum(u5) {
    active = 1,
    editable = 7,
    enabled = 8,
    focusable = 11,
    focused = 12,
    modal = 16,
    selectable = 22,
    selected = 23,
    sensitive = 24,
    showing = 25,
    single_line = 26,
    visible = 30,
};

/// AT-SPI state bit 6 (`DEFUNCT`) for an object that no longer exists.
const state_defunct: u64 = 1 << 6;

pub fn bit(state: State) u64 {
    return @as(u64, 1) << @intFromEnum(state);
}

fn isSelectableRole(role: Role) bool {
    return switch (role) {
        .tree_item, .page_tab, .list_item, .menu_item => true,
        else => false,
    };
}

/// The state set of one element.
pub fn nodeStates(node: Node, role: Role) u64 {
    var s = bit(.enabled) | bit(.sensitive) | bit(.visible);
    if (!node.bounds.isEmpty()) s |= bit(.showing);
    if (node.primitive.isInteractive()) s |= bit(.focusable);
    if (node.focused) s |= bit(.focused);
    if (isSelectableRole(role)) s |= bit(.selectable);
    if (node.selected) s |= bit(.selected);
    if (node.primitive == .input) s |= bit(.editable) | bit(.single_line);
    if (role == .dialog) s |= bit(.modal);
    return s;
}

const window_states = bit(.active) | bit(.enabled) | bit(.sensitive) | bit(.visible) | bit(.showing);
const app_states: u64 = 0;

// ---------------------------------------------------------------------------
// Objects
// ---------------------------------------------------------------------------

/// One addressable object.
pub const Object = union(enum) {
    app,
    window,
    node: u32,
};

/// The object path of an element key.
pub fn elementPath(buf: *[element_prefix.len + 16]u8, key: u64) []const u8 {
    return std.fmt.bufPrint(buf, element_prefix ++ "{x:0>16}", .{key}) catch unreachable; // exact fit
}

/// A path's object, or null when the path names nothing in this snapshot.
pub fn resolve(snap: *const Snapshot, path: []const u8) ?Object {
    if (std.mem.eql(u8, path, root_path)) return .app;
    if (std.mem.eql(u8, path, window_path)) return .window;
    if (!std.mem.startsWith(u8, path, element_prefix)) return null;
    const hex = path[element_prefix.len..];
    if (hex.len != 16) return null;
    const key = std.fmt.parseInt(u64, hex, 16) catch return null;
    const index = snap.indexOfKey(key) orelse return null;
    return .{ .node = index };
}

/// Whether `path` has the shape of an element path, existing or not.
fn isElementPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, element_prefix) and path.len == element_prefix.len + 16 and
        !std.mem.eql(u8, path, root_path) and !std.mem.eql(u8, path, window_path);
}

/// What the owner is asked to do on behalf of an assistive technology.
pub const RequestKind = enum { activate, focus };

/// Where `Service` sends AT requests. `push` returns false when the bounded
/// queue is full.
pub const RequestSink = struct {
    context: *anyopaque,
    pushFn: *const fn (context: *anyopaque, kind: RequestKind, id: []const u8) bool,

    pub fn push(self: RequestSink, kind: RequestKind, id: []const u8) bool {
        return self.pushFn(self.context, kind, id);
    }
};

/// The outcome of handling one call.
pub const Reply = union(enum) {
    /// A method return whose body (already written) has this signature.
    ok: []const u8,
    /// An error reply.
    err: struct { name: []const u8, message: []const u8 },
};

fn errReply(name: []const u8, message: []const u8) Reply {
    return .{ .err = .{ .name = name, .message = message } };
}

const err_unknown_method = "org.freedesktop.DBus.Error.UnknownMethod";
const err_unknown_object = "org.freedesktop.DBus.Error.UnknownObject";
const err_unknown_property = "org.freedesktop.DBus.Error.UnknownProperty";
const err_invalid_args = "org.freedesktop.DBus.Error.InvalidArgs";

/// The application's identity and connection state, borrowed by `Service`.
pub const Service = struct {
    snap: *const Snapshot,
    /// This connection's unique bus name.
    bus_name: []const u8,
    /// The registry's desktop object, our application's parent.
    parent_name: []const u8 = "",
    parent_path: []const u8 = null_path,
    app_name: []const u8,
    toolkit_version: []const u8,
    /// The id the registry assigns through `Application.Id`.
    app_id: *i32,
    /// Window origin on screen, for `ATSPI_COORD_TYPE_SCREEN`.
    screen_x: i32 = 0,
    screen_y: i32 = 0,
    requests: RequestSink,

    // -- object model ------------------------------------------------------

    fn ref(self: *const Service, w: *Writer, object: Object) dbus.Error!void {
        switch (object) {
            .app => try w.reference(self.bus_name, root_path),
            .window => try w.reference(self.bus_name, window_path),
            .node => |index| {
                var buf: [element_prefix.len + 16]u8 = undefined;
                try w.reference(self.bus_name, elementPath(&buf, self.snap.nodes[index].key));
            },
        }
    }

    fn nullRef(self: *const Service, w: *Writer) dbus.Error!void {
        try w.reference(self.bus_name, null_path);
    }

    fn parentRef(self: *const Service, w: *Writer, object: Object) dbus.Error!void {
        switch (object) {
            .app => try w.reference(self.parent_name, self.parent_path),
            .window => try self.ref(w, .app),
            .node => |index| {
                const parent = self.snap.nodes[index].parent;
                try self.ref(w, if (parent == none) .window else .{ .node = parent });
            },
        }
    }

    fn childCount(self: *const Service, object: Object) u32 {
        return switch (object) {
            .app => 1,
            .window => self.snap.childCount(none),
            .node => |index| self.snap.childCount(index),
        };
    }

    fn childAt(self: *const Service, object: Object, n: u32) ?Object {
        switch (object) {
            .app => return if (n == 0) .window else null,
            .window => return if (self.snap.childAt(none, n)) |i| .{ .node = i } else null,
            .node => |index| return if (self.snap.childAt(index, n)) |i| .{ .node = i } else null,
        }
    }

    fn indexInParent(self: *const Service, object: Object) i32 {
        return switch (object) {
            .app => -1,
            .window => 0,
            .node => |index| @intCast(self.snap.nodes[index].index_in_parent),
        };
    }

    fn role(self: *const Service, object: Object) Role {
        return switch (object) {
            .app => .application,
            .window => .frame,
            .node => |index| roleFor(self.snap.str(self.snap.nodes[index].role), self.snap.nodes[index].primitive),
        };
    }

    fn name(self: *const Service, object: Object) []const u8 {
        return switch (object) {
            .app, .window => self.app_name,
            .node => |index| self.snap.str(self.snap.nodes[index].label),
        };
    }

    fn states(self: *const Service, object: Object) u64 {
        return switch (object) {
            .app => app_states,
            .window => window_states,
            .node => |index| nodeStates(self.snap.nodes[index], self.role(object)),
        };
    }

    fn hasAction(self: *const Service, object: Object) bool {
        return switch (object) {
            .node => |index| self.snap.nodes[index].action.len != 0 and self.snap.nodes[index].primitive.isInteractive(),
            else => false,
        };
    }

    fn accessibleId(self: *const Service, object: Object) []const u8 {
        return switch (object) {
            .app => "",
            .window => "window",
            .node => |index| self.snap.str(self.snap.nodes[index].id),
        };
    }

    fn bounds(self: *const Service, object: Object) ui.Bounds {
        return switch (object) {
            .app => ui.Bounds.empty,
            .window => self.snap.surface,
            .node => |index| self.snap.nodes[index].bounds,
        };
    }

    fn writeInterfaces(self: *const Service, w: *Writer, object: Object) dbus.Error!void {
        const mark = try w.beginArray(4);
        try w.string(iface_accessible);
        switch (object) {
            .app => try w.string(iface_application),
            .window => try w.string(iface_component),
            .node => {
                try w.string(iface_component);
                if (self.hasAction(object)) try w.string(iface_action);
            },
        }
        try w.endArray(mark);
    }

    fn writeStates(w: *Writer, s: u64) dbus.Error!void {
        const mark = try w.beginArray(4);
        try w.uint32(@truncate(s));
        try w.uint32(@truncate(s >> 32));
        try w.endArray(mark);
    }

    /// Bounds in the requested AT-SPI coordinate type: 0 screen, 1 window,
    /// 2 parent.
    fn extents(self: *const Service, object: Object, coord_type: u32) ui.Bounds {
        var b = self.bounds(object);
        switch (coord_type) {
            0 => {
                b.x +|= self.screen_x;
                b.y +|= self.screen_y;
            },
            2 => switch (object) {
                .node => |index| {
                    const parent = self.snap.nodes[index].parent;
                    const origin = if (parent == none) self.snap.surface else self.snap.nodes[parent].bounds;
                    b.x -|= origin.x;
                    b.y -|= origin.y;
                },
                else => {},
            },
            else => {},
        }
        return b;
    }

    /// Convert an incoming point to window coordinates.
    fn toWindow(self: *const Service, object: Object, x: i32, y: i32, coord_type: u32) ui.Point {
        return switch (coord_type) {
            0 => .{ .x = x -| self.screen_x, .y = y -| self.screen_y },
            2 => blk: {
                const origin = switch (object) {
                    .node => |index| self.snap.nodes[index].bounds,
                    else => self.snap.surface,
                };
                break :blk .{ .x = x +| origin.x, .y = y +| origin.y };
            },
            else => .{ .x = x, .y = y },
        };
    }

    /// The last-painted descendant of `object` containing `point`.
    /// Descendants are searched whatever their ancestors' bounds: a sidebar
    /// tab row lies outside its workspace row, yet is its child.
    fn accessibleAt(self: *const Service, object: Object, point: ui.Point) ?Object {
        const ancestor: u32 = switch (object) {
            .app => return null,
            .window => none,
            .node => |index| index,
        };
        var hit: ?u32 = null;
        for (self.snap.slice(), 0..) |node, i| {
            if (!node.bounds.contains(point)) continue;
            if (ancestor != none and !self.isDescendant(@intCast(i), ancestor)) continue;
            // Registration order is painter order, so the last hit is on top.
            hit = @intCast(i);
        }
        return if (hit) |index| .{ .node = index } else null;
    }

    fn isDescendant(self: *const Service, index: u32, ancestor: u32) bool {
        var current = self.snap.nodes[index].parent;
        var steps: u32 = 0;
        while (current != none and steps < self.snap.len) : (steps += 1) {
            if (current == ancestor) return true;
            current = self.snap.nodes[current].parent;
        }
        return false;
    }

    // -- dispatch ----------------------------------------------------------

    /// Handle one method call addressed to this application, writing any
    /// return body into `out`.
    pub fn handle(self: *const Service, message: *const dbus.Message, out: *Writer) Reply {
        return self.handleInner(message, out) catch |err| switch (err) {
            error.MessageTooLarge => errReply("org.freedesktop.DBus.Error.LimitsExceeded", "reply too large"),
            error.Malformed, error.InvalidString => errReply(err_invalid_args, "invalid arguments"),
        };
    }

    fn handleInner(self: *const Service, m: *const dbus.Message, out: *Writer) dbus.Error!Reply {
        const path = m.path orelse return errReply(err_unknown_object, "no path");
        const member = m.member orelse return errReply(err_unknown_method, "no member");

        if (m.isCall(iface_peer, "Ping")) return .{ .ok = "" };
        if (m.isCall(iface_introspectable, "Introspect")) {
            try out.string(introspection);
            return .{ .ok = "s" };
        }
        if (std.mem.eql(u8, path, cache_path)) {
            if (m.isCall(iface_cache, "GetItems")) {
                try self.writeItems(out);
                return .{ .ok = "a((so)(so)(so)iiassusau)" };
            }
            return errReply(err_unknown_method, member);
        }

        const object = resolve(self.snap, path) orelse {
            // A stale element still answers `GetState` so a reader learns it
            // is gone instead of seeing an error.
            if (isElementPath(path) and m.isCall(iface_accessible, "GetState")) {
                try writeStates(out, state_defunct);
                return .{ .ok = "au" };
            }
            return errReply(err_unknown_object, path);
        };

        if (m.isCall(iface_properties, "Get")) return self.propertyGet(object, m, out);
        if (m.isCall(iface_properties, "GetAll")) return self.propertyGetAll(object, m, out);
        if (m.isCall(iface_properties, "Set")) return self.propertySet(object, m);

        const interface = m.interface orelse "";
        if (interface.len == 0 or std.mem.eql(u8, interface, iface_accessible)) {
            if (try self.accessibleMethod(object, m, member, out)) |reply| return reply;
        }
        if ((interface.len == 0 or std.mem.eql(u8, interface, iface_component)) and object != .app) {
            if (try self.componentMethod(object, m, member, out)) |reply| return reply;
        }
        if ((interface.len == 0 or std.mem.eql(u8, interface, iface_action)) and self.hasAction(object)) {
            if (try self.actionMethod(object, m, member, out)) |reply| return reply;
        }
        if ((interface.len == 0 or std.mem.eql(u8, interface, iface_application)) and object == .app) {
            if (std.mem.eql(u8, member, "GetLocale")) {
                try out.string("");
                return .{ .ok = "s" };
            }
        }
        return errReply(err_unknown_method, member);
    }

    fn expectSignature(m: *const dbus.Message, sig: []const u8) dbus.Error!void {
        if (!std.mem.eql(u8, m.signature, sig)) return error.Malformed;
    }

    fn accessibleMethod(self: *const Service, object: Object, m: *const dbus.Message, member: []const u8, out: *Writer) dbus.Error!?Reply {
        const eql = std.mem.eql;
        if (eql(u8, member, "GetChildAtIndex")) {
            try expectSignature(m, "i");
            var r = m.bodyReader();
            const n = try r.int32();
            const child = if (n >= 0) self.childAt(object, @intCast(n)) else null;
            if (child) |c| try self.ref(out, c) else try self.nullRef(out);
            return .{ .ok = "(so)" };
        }
        if (eql(u8, member, "GetChildren")) {
            const mark = try out.beginArray(8);
            var i: u32 = 0;
            while (self.childAt(object, i)) |child| : (i += 1) try self.ref(out, child);
            try out.endArray(mark);
            return .{ .ok = "a(so)" };
        }
        if (eql(u8, member, "GetIndexInParent")) {
            try out.int32(self.indexInParent(object));
            return .{ .ok = "i" };
        }
        if (eql(u8, member, "GetRelationSet")) {
            const mark = try out.beginArray(8);
            try out.endArray(mark);
            return .{ .ok = "a(ua(so))" };
        }
        if (eql(u8, member, "GetRole")) {
            try out.uint32(@intFromEnum(self.role(object)));
            return .{ .ok = "u" };
        }
        if (eql(u8, member, "GetRoleName") or eql(u8, member, "GetLocalizedRoleName")) {
            try out.string(self.role(object).name());
            return .{ .ok = "s" };
        }
        if (eql(u8, member, "GetState")) {
            try writeStates(out, self.states(object));
            return .{ .ok = "au" };
        }
        if (eql(u8, member, "GetAttributes")) {
            const mark = try out.beginArray(8);
            if (object == .node) {
                const node = self.snap.nodes[object.node];
                try out.beginStruct();
                try out.string("id");
                try out.string(self.snap.str(node.id));
                try out.beginStruct();
                try out.string("conduit-role");
                try out.string(self.snap.str(node.role));
            }
            try out.endArray(mark);
            return .{ .ok = "a{ss}" };
        }
        if (eql(u8, member, "GetApplication")) {
            try self.ref(out, .app);
            return .{ .ok = "(so)" };
        }
        if (eql(u8, member, "GetInterfaces")) {
            try self.writeInterfaces(out, object);
            return .{ .ok = "as" };
        }
        return null;
    }

    fn componentMethod(self: *const Service, object: Object, m: *const dbus.Message, member: []const u8, out: *Writer) dbus.Error!?Reply {
        const eql = std.mem.eql;
        if (eql(u8, member, "GetExtents")) {
            try expectSignature(m, "u");
            var r = m.bodyReader();
            const b = self.extents(object, try r.uint32());
            try out.beginStruct();
            try out.int32(b.x);
            try out.int32(b.y);
            try out.int32(@intCast(@min(b.width, std.math.maxInt(i32))));
            try out.int32(@intCast(@min(b.height, std.math.maxInt(i32))));
            return .{ .ok = "(iiii)" };
        }
        if (eql(u8, member, "GetPosition")) {
            try expectSignature(m, "u");
            var r = m.bodyReader();
            const b = self.extents(object, try r.uint32());
            try out.int32(b.x);
            try out.int32(b.y);
            return .{ .ok = "ii" };
        }
        if (eql(u8, member, "GetSize")) {
            const b = self.bounds(object);
            try out.int32(@intCast(@min(b.width, std.math.maxInt(i32))));
            try out.int32(@intCast(@min(b.height, std.math.maxInt(i32))));
            return .{ .ok = "ii" };
        }
        if (eql(u8, member, "Contains") or eql(u8, member, "GetAccessibleAtPoint")) {
            try expectSignature(m, "iiu");
            var r = m.bodyReader();
            const x = try r.int32();
            const y = try r.int32();
            const coord_type = try r.uint32();
            const point = self.toWindow(object, x, y, coord_type);
            if (eql(u8, member, "Contains")) {
                try out.boolean(self.bounds(object).contains(point));
                return .{ .ok = "b" };
            }
            if (self.accessibleAt(object, point)) |hit| try self.ref(out, hit) else try self.nullRef(out);
            return .{ .ok = "(so)" };
        }
        if (eql(u8, member, "GetLayer")) {
            // AtspiComponentLayer: WINDOW (7) for the frame, WIDGET (3) inside.
            try out.uint32(if (object == .window) 7 else 3);
            return .{ .ok = "u" };
        }
        if (eql(u8, member, "GetMDIZOrder")) {
            try out.int16(-1);
            return .{ .ok = "n" };
        }
        if (eql(u8, member, "GetAlpha")) {
            try out.double(1.0);
            return .{ .ok = "d" };
        }
        if (eql(u8, member, "GrabFocus")) {
            const accepted = switch (object) {
                .node => |index| self.snap.nodes[index].primitive.isInteractive() and
                    self.requests.push(.focus, self.snap.str(self.snap.nodes[index].id)),
                else => false,
            };
            try out.boolean(accepted);
            return .{ .ok = "b" };
        }
        return null;
    }

    fn actionMethod(self: *const Service, object: Object, m: *const dbus.Message, member: []const u8, out: *Writer) dbus.Error!?Reply {
        const eql = std.mem.eql;
        const node = self.snap.nodes[object.node];
        if (eql(u8, member, "GetActions")) {
            const mark = try out.beginArray(8);
            try out.beginStruct();
            try out.string("click");
            try out.string(self.snap.str(node.action));
            try out.string("");
            try out.endArray(mark);
            return .{ .ok = "a(sss)" };
        }
        const indexed = eql(u8, member, "GetName") or eql(u8, member, "GetLocalizedName") or
            eql(u8, member, "GetDescription") or eql(u8, member, "GetKeyBinding") or eql(u8, member, "DoAction");
        if (!indexed) return null;
        try expectSignature(m, "i");
        var r = m.bodyReader();
        const index = try r.int32();
        if (eql(u8, member, "DoAction")) {
            const accepted = index == 0 and self.requests.push(.activate, self.snap.str(node.id));
            try out.boolean(accepted);
            return .{ .ok = "b" };
        }
        if (index != 0) return errReply(err_invalid_args, "no such action");
        if (eql(u8, member, "GetDescription")) {
            try out.string(self.snap.str(node.action));
        } else if (eql(u8, member, "GetKeyBinding")) {
            try out.string("");
        } else {
            try out.string("click");
        }
        return .{ .ok = "s" };
    }

    // -- properties --------------------------------------------------------

    fn propertyGet(self: *const Service, object: Object, m: *const dbus.Message, out: *Writer) dbus.Error!Reply {
        try expectSignature(m, "ss");
        var r = m.bodyReader();
        const interface = try r.string();
        const property = try r.string();
        if (!try self.writeProperty(object, interface, property, out)) {
            return errReply(err_unknown_property, property);
        }
        return .{ .ok = "v" };
    }

    fn propertyGetAll(self: *const Service, object: Object, m: *const dbus.Message, out: *Writer) dbus.Error!Reply {
        try expectSignature(m, "s");
        var r = m.bodyReader();
        const interface = try r.string();
        const names: []const []const u8 = if (std.mem.eql(u8, interface, iface_accessible))
            &.{ "Name", "Description", "Parent", "ChildCount", "Locale", "AccessibleId", "HelpText" }
        else if (std.mem.eql(u8, interface, iface_application) and object == .app)
            &.{ "ToolkitName", "Version", "AtspiVersion", "Id" }
        else if (std.mem.eql(u8, interface, iface_action) and self.hasAction(object))
            &.{"NActions"}
        else
            &.{};
        const mark = try out.beginArray(8);
        for (names) |property| {
            try out.beginStruct();
            try out.string(property);
            _ = try self.writeProperty(object, interface, property, out);
        }
        try out.endArray(mark);
        return .{ .ok = "a{sv}" };
    }

    fn propertySet(self: *const Service, object: Object, m: *const dbus.Message) dbus.Error!Reply {
        if (!std.mem.eql(u8, m.signature, "ssv")) return error.Malformed;
        var r = m.bodyReader();
        const interface = try r.string();
        const property = try r.string();
        if (object == .app and std.mem.eql(u8, interface, iface_application) and std.mem.eql(u8, property, "Id")) {
            const sig = try r.signature();
            if (!std.mem.eql(u8, sig, "i")) return error.Malformed;
            self.app_id.* = try r.int32();
            return .{ .ok = "" };
        }
        return errReply("org.freedesktop.DBus.Error.PropertyReadOnly", property);
    }

    /// Write `property` as a variant. Returns false if it does not exist.
    fn writeProperty(self: *const Service, object: Object, interface: []const u8, property: []const u8, out: *Writer) dbus.Error!bool {
        const eql = std.mem.eql;
        if (eql(u8, interface, iface_accessible)) {
            if (eql(u8, property, "Name")) {
                try out.beginVariant("s");
                try out.string(self.name(object));
            } else if (eql(u8, property, "Description") or eql(u8, property, "Locale") or eql(u8, property, "HelpText")) {
                try out.beginVariant("s");
                try out.string("");
            } else if (eql(u8, property, "AccessibleId")) {
                try out.beginVariant("s");
                try out.string(self.accessibleId(object));
            } else if (eql(u8, property, "Parent")) {
                try out.beginVariant("(so)");
                try self.parentRef(out, object);
            } else if (eql(u8, property, "ChildCount")) {
                try out.beginVariant("i");
                try out.int32(@intCast(self.childCount(object)));
            } else return false;
            return true;
        }
        if (eql(u8, interface, iface_application) and object == .app) {
            if (eql(u8, property, "ToolkitName")) {
                try out.beginVariant("s");
                try out.string("Conduit");
            } else if (eql(u8, property, "Version")) {
                try out.beginVariant("s");
                try out.string(self.toolkit_version);
            } else if (eql(u8, property, "AtspiVersion")) {
                try out.beginVariant("s");
                try out.string("2.1");
            } else if (eql(u8, property, "Id")) {
                try out.beginVariant("i");
                try out.int32(self.app_id.*);
            } else return false;
            return true;
        }
        if (eql(u8, interface, iface_action) and self.hasAction(object) and eql(u8, property, "NActions")) {
            try out.beginVariant("i");
            try out.int32(1);
            return true;
        }
        return false;
    }

    // -- cache -------------------------------------------------------------

    /// One `((so)(so)(so)iiassusau)` cache item.
    fn writeItem(self: *const Service, w: *Writer, object: Object) dbus.Error!void {
        try w.beginStruct();
        try self.ref(w, object);
        try self.ref(w, .app);
        try self.parentRef(w, object);
        try w.int32(self.indexInParent(object));
        try w.int32(@intCast(self.childCount(object)));
        try self.writeInterfaces(w, object);
        try w.string(self.name(object));
        try w.uint32(@intFromEnum(self.role(object)));
        try w.string("");
        try writeStates(w, self.states(object));
    }

    fn writeItems(self: *const Service, w: *Writer) dbus.Error!void {
        const mark = try w.beginArray(8);
        try self.writeItem(w, .app);
        try self.writeItem(w, .window);
        for (0..self.snap.len) |i| try self.writeItem(w, .{ .node = @intCast(i) });
        try w.endArray(mark);
    }
};

const introspection =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
    \\ "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
    \\ <interface name="org.a11y.atspi.Accessible"/>
    \\ <interface name="org.a11y.atspi.Component"/>
    \\ <interface name="org.a11y.atspi.Action"/>
    \\ <interface name="org.a11y.atspi.Application"/>
    \\ <interface name="org.freedesktop.DBus.Properties"/>
    \\</node>
;

// ---------------------------------------------------------------------------
// Snapshot differences to events
// ---------------------------------------------------------------------------

/// One `org.a11y.atspi.Event.Object` signal to emit.
pub const Event = struct {
    pub const Kind = enum { child_added, child_removed, focused, selected, name };

    kind: Kind,
    /// The object the signal is emitted on: the window or an element key.
    source: Source,
    /// For child events: the child's key and index. For state events: 1 or 0.
    child_key: u64 = 0,
    detail1: i32 = 0,
    /// For name events: the new label, borrowed from the new snapshot.
    text: []const u8 = "",

    pub const Source = union(enum) { window, key: u64 };
};

/// The most events one snapshot change emits. Beyond this, structural churn
/// is summarised: readers re-query the subtree they are in anyway.
pub const max_events_per_diff: usize = 512;

/// Compare two snapshots and append the events an AT needs into `out`.
/// Returns the events written; stops at `out.len`.
pub fn diff(old: *const Snapshot, new: *const Snapshot, out: []Event) usize {
    var n: usize = 0;
    // Structure: for each parent present in the new snapshot, compare its
    // child key list with the same parent's list in the old snapshot.
    n = diffChildren(old, new, .window, none, none, out, n);
    for (new.slice(), 0..) |node, i| {
        if (n >= out.len) return n;
        const old_index = old.indexOfKey(node.key) orelse continue;
        n = diffChildren(old, new, .{ .key = node.key }, @intCast(i), old_index, out, n);
    }
    // State and names, for elements present in both.
    for (new.slice()) |node| {
        const old_index = old.indexOfKey(node.key);
        const before: ?Node = if (old_index) |oi| old.nodes[oi] else null;
        if (n < out.len and (if (before) |b| b.focused != node.focused else node.focused)) {
            out[n] = .{ .kind = .focused, .source = .{ .key = node.key }, .detail1 = @intFromBool(node.focused) };
            n += 1;
        }
        const b = before orelse continue;
        if (n < out.len and b.selected != node.selected) {
            out[n] = .{ .kind = .selected, .source = .{ .key = node.key }, .detail1 = @intFromBool(node.selected) };
            n += 1;
        }
        if (n < out.len and !std.mem.eql(u8, old.str(b.label), new.str(node.label))) {
            out[n] = .{ .kind = .name, .source = .{ .key = node.key }, .text = new.str(node.label) };
            n += 1;
        }
    }
    // Focus that left an element which still exists was handled above; focus
    // on an element that disappeared needs no event (its removal is one).
    return n;
}

fn containsKey(snap: *const Snapshot, parent: u32, key: u64) bool {
    var child = snap.firstChild(parent);
    while (child != none) : (child = snap.nodes[child].next_sibling) {
        if (snap.nodes[child].key == key) return true;
    }
    return false;
}

fn diffChildren(
    old: *const Snapshot,
    new: *const Snapshot,
    source: Event.Source,
    new_parent: u32,
    old_parent: u32,
    out: []Event,
    start: usize,
) usize {
    var n = start;
    var child = old.firstChild(old_parent);
    while (child != none and n < out.len) : (child = old.nodes[child].next_sibling) {
        const key = old.nodes[child].key;
        if (!containsKey(new, new_parent, key)) {
            out[n] = .{ .kind = .child_removed, .source = source, .child_key = key, .detail1 = @intCast(old.nodes[child].index_in_parent) };
            n += 1;
        }
    }
    child = new.firstChild(new_parent);
    while (child != none and n < out.len) : (child = new.nodes[child].next_sibling) {
        const key = new.nodes[child].key;
        if (!containsKey(old, old_parent, key)) {
            out[n] = .{ .kind = .child_added, .source = source, .child_key = key, .detail1 = @intCast(new.nodes[child].index_in_parent) };
            n += 1;
        }
    }
    return n;
}

/// The signal an `Event` becomes: its path, member and `siiva{sv}` body.
pub fn encodeEvent(event: Event, bus_name: []const u8, path_buf: *[element_prefix.len + 16]u8, body: *Writer) dbus.Error!struct { path: []const u8, member: []const u8 } {
    const path = switch (event.source) {
        .window => window_path,
        .key => |key| elementPath(path_buf, key),
    };
    var child_buf: [element_prefix.len + 16]u8 = undefined;
    switch (event.kind) {
        .child_added, .child_removed => {
            try body.string(if (event.kind == .child_added) "add" else "remove");
            try body.int32(event.detail1);
            try body.int32(0);
            try body.beginVariant("(so)");
            try body.reference(bus_name, elementPath(&child_buf, event.child_key));
        },
        .focused, .selected => {
            try body.string(if (event.kind == .focused) "focused" else "selected");
            try body.int32(event.detail1);
            try body.int32(0);
            try body.beginVariant("i");
            try body.int32(0);
        },
        .name => {
            try body.string("accessible-name");
            try body.int32(0);
            try body.int32(0);
            try body.beginVariant("s");
            try body.string(event.text);
        },
    }
    const props = try body.beginArray(8);
    try body.endArray(props);
    const member = switch (event.kind) {
        .child_added, .child_removed => "ChildrenChanged",
        .focused, .selected => "StateChanged",
        .name => "PropertyChange",
    };
    return .{ .path = path, .member = member };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn rect(x: i32, y: i32, w: u32, h: u32) ui.Bounds {
    return .{ .x = x, .y = y, .width = w, .height = h };
}

/// The sidebar, palette and settings shapes Conduit registers.
fn fixture(s: *Snapshot, focus_tab: bool) void {
    s.begin(rect(0, 0, 640, 360));
    _ = s.append(.{ .id = "sidebar", .role = "sidebar", .label = "Sidebar", .bounds = rect(0, 0, 160, 360), .primitive = .surface });
    _ = s.append(.{ .id = "workspace.1", .parent = "sidebar", .role = "workspace", .label = "main", .action = "workspace.activate", .bounds = rect(8, 0, 152, 18), .primitive = .interactive_text, .selected = true });
    _ = s.append(.{ .id = "workspace.1.tab.1", .parent = "workspace.1", .role = "tab", .label = "bash", .action = "tab.activate", .bounds = rect(16, 18, 144, 18), .primitive = .interactive_text, .focused = focus_tab });
    _ = s.append(.{ .id = "palette.dialog", .role = "dialog", .label = "Command palette", .bounds = rect(200, 40, 300, 120), .primitive = .surface });
    _ = s.append(.{ .id = "palette.query", .parent = "palette.dialog", .role = "input", .label = "Filter commands", .action = "palette.activate", .bounds = rect(216, 58, 268, 18), .primitive = .input, .focused = !focus_tab });
    _ = s.append(.{ .id = "palette.action.0", .parent = "palette.dialog", .role = "command", .label = "New tab", .action = "palette.activate", .bounds = rect(216, 76, 268, 18), .primitive = .interactive_text, .selected = true });
    _ = s.append(.{ .id = "settings.dialog", .role = "dialog", .label = "Settings", .bounds = rect(100, 100, 400, 200), .primitive = .surface });
    _ = s.append(.{ .id = "settings.row.1", .parent = "settings.dialog", .role = "setting", .label = "font.size  13", .action = "settings.activate", .bounds = rect(116, 118, 368, 18), .primitive = .interactive_text });
    _ = s.append(.{ .id = "settings.input", .parent = "settings.dialog", .role = "input", .label = "font.size", .action = "settings.activate", .bounds = rect(216, 118, 268, 18), .primitive = .input });
    s.finish();
}

test "roles map Conduit product roles to AT-SPI roles" {
    try testing.expectEqual(Role.panel, roleFor("sidebar", .surface));
    try testing.expectEqual(Role.dialog, roleFor("dialog", .surface));
    try testing.expectEqual(Role.tree_item, roleFor("workspace", .interactive_text));
    try testing.expectEqual(Role.page_tab, roleFor("tab", .interactive_text));
    try testing.expectEqual(Role.list_item, roleFor("command", .interactive_text));
    try testing.expectEqual(Role.list_item, roleFor("setting", .interactive_text));
    try testing.expectEqual(Role.push_button, roleFor("palette_hint", .interactive_text));
    try testing.expectEqual(Role.terminal, roleFor("terminal", .surface));
    try testing.expectEqual(Role.entry, roleFor("input", .input));
    try testing.expectEqual(Role.label, roleFor("version", .text));
    try testing.expectEqual(Role.push_button, roleFor("unknown", .interactive_text));
    try testing.expectEqualStrings("page tab", Role.page_tab.name());
    try testing.expectEqual(@as(u32, 60), @intFromEnum(Role.terminal));
    try testing.expectEqual(@as(u32, 43), @intFromEnum(Role.push_button));
}

test "states reflect focus, selection and primitive" {
    var s = try Snapshot.init(testing.allocator, 16, 1024);
    defer s.deinit();
    fixture(&s, false);
    const ws = nodeStates(s.nodes[1], .tree_item);
    try testing.expect(ws & bit(.selected) != 0);
    try testing.expect(ws & bit(.selectable) != 0);
    try testing.expect(ws & bit(.focusable) != 0);
    try testing.expect(ws & bit(.focused) == 0);
    try testing.expect(ws & bit(.showing) != 0);
    const query = nodeStates(s.nodes[4], .entry);
    try testing.expect(query & bit(.focused) != 0);
    try testing.expect(query & bit(.editable) != 0);
    try testing.expect(query & bit(.single_line) != 0);
    try testing.expect(nodeStates(s.nodes[3], .dialog) & bit(.modal) != 0);
    try testing.expect(nodeStates(s.nodes[0], .panel) & bit(.focusable) == 0);
}

const TestSink = struct {
    kind: ?RequestKind = null,
    id: [64]u8 = undefined,
    id_len: usize = 0,

    fn push(context: *anyopaque, kind: RequestKind, id: []const u8) bool {
        const self: *TestSink = @ptrCast(@alignCast(context));
        self.kind = kind;
        @memcpy(self.id[0..id.len], id);
        self.id_len = id.len;
        return true;
    }

    fn sink(self: *TestSink) RequestSink {
        return .{ .context = self, .pushFn = push };
    }
};

fn callMessage(buf: []u8, path: []const u8, interface: []const u8, member: []const u8, sig: []const u8, body: []const u8) !dbus.Message {
    var w = Writer.init(buf);
    try dbus.encode(&w, .{ .type = .method_call, .serial = 1, .path = path, .interface = interface, .member = member, .signature = sig }, body);
    return dbus.parse(w.written());
}

test "service answers Accessible, Component, Action and Properties calls" {
    var s = try Snapshot.init(testing.allocator, 16, 1024);
    defer s.deinit();
    fixture(&s, false);
    var sink: TestSink = .{};
    var app_id: i32 = 0;
    const service: Service = .{
        .snap = &s,
        .bus_name = ":1.42",
        .parent_name = "org.a11y.atspi.Registry",
        .parent_path = root_path,
        .app_name = "Conduit",
        .toolkit_version = "0.1.0",
        .app_id = &app_id,
        .requests = sink.sink(),
    };
    var msg_buf: [512]u8 = undefined;
    var out_buf: [8192]u8 = undefined;

    // The window lists sidebar, palette and settings as its children.
    {
        const m = try callMessage(&msg_buf, window_path, iface_accessible, "GetChildren", "", "");
        var out = Writer.init(&out_buf);
        try testing.expectEqualStrings("a(so)", service.handle(&m, &out).ok);
        var r = Reader.init(out.written(), .little);
        const end = try r.beginArray(8);
        var count: usize = 0;
        while (r.pos < end) : (count += 1) {
            try r.beginStruct();
            try testing.expectEqualStrings(":1.42", try r.string());
            _ = try r.objectPath();
        }
        try testing.expectEqual(@as(usize, 3), count);
    }

    var path_buf: [element_prefix.len + 16]u8 = undefined;
    const tab_path = elementPath(&path_buf, snapshot_mod.keyOf("workspace.1.tab.1"));
    // Role and name of a tab row.
    {
        const m = try callMessage(&msg_buf, tab_path, iface_accessible, "GetRole", "", "");
        var out = Writer.init(&out_buf);
        _ = service.handle(&m, &out);
        var r = Reader.init(out.written(), .little);
        try testing.expectEqual(@as(u32, @intFromEnum(Role.page_tab)), try r.uint32());
    }
    {
        var body_buf: [64]u8 = undefined;
        var body = Writer.init(&body_buf);
        try body.string(iface_accessible);
        try body.string("Name");
        const m = try callMessage(&msg_buf, tab_path, iface_properties, "Get", "ss", body.written());
        var out = Writer.init(&out_buf);
        try testing.expectEqualStrings("v", service.handle(&m, &out).ok);
        var r = Reader.init(out.written(), .little);
        try testing.expectEqualStrings("s", try r.signature());
        try testing.expectEqualStrings("bash", try r.string());
    }
    // Parent of the tab is the workspace row.
    {
        var body_buf: [64]u8 = undefined;
        var body = Writer.init(&body_buf);
        try body.string(iface_accessible);
        try body.string("Parent");
        const m = try callMessage(&msg_buf, tab_path, iface_properties, "Get", "ss", body.written());
        var out = Writer.init(&out_buf);
        _ = service.handle(&m, &out);
        var r = Reader.init(out.written(), .little);
        _ = try r.signature();
        try r.beginStruct();
        _ = try r.string();
        var ws_buf: [element_prefix.len + 16]u8 = undefined;
        try testing.expectEqualStrings(elementPath(&ws_buf, snapshot_mod.keyOf("workspace.1")), try r.objectPath());
    }
    // Extents in window and parent coordinates.
    {
        var body_buf: [8]u8 = undefined;
        var body = Writer.init(&body_buf);
        try body.uint32(2);
        const m = try callMessage(&msg_buf, tab_path, iface_component, "GetExtents", "u", body.written());
        var out = Writer.init(&out_buf);
        try testing.expectEqualStrings("(iiii)", service.handle(&m, &out).ok);
        var r = Reader.init(out.written(), .little);
        try testing.expectEqual(@as(i32, 8), try r.int32());
        try testing.expectEqual(@as(i32, 18), try r.int32());
        try testing.expectEqual(@as(i32, 144), try r.int32());
    }
    // Hit testing from the window finds the deepest element.
    {
        var body_buf: [16]u8 = undefined;
        var body = Writer.init(&body_buf);
        try body.int32(20);
        try body.int32(20);
        try body.uint32(1);
        const m = try callMessage(&msg_buf, window_path, iface_component, "GetAccessibleAtPoint", "iiu", body.written());
        var out = Writer.init(&out_buf);
        _ = service.handle(&m, &out);
        var r = Reader.init(out.written(), .little);
        try r.beginStruct();
        _ = try r.string();
        try testing.expectEqualStrings(tab_path, try r.objectPath());
    }
    // DoAction posts an activation request; GrabFocus posts a focus request.
    {
        var body_buf: [8]u8 = undefined;
        var body = Writer.init(&body_buf);
        try body.int32(0);
        const m = try callMessage(&msg_buf, tab_path, iface_action, "DoAction", "i", body.written());
        var out = Writer.init(&out_buf);
        try testing.expectEqualStrings("b", service.handle(&m, &out).ok);
        try testing.expectEqual(RequestKind.activate, sink.kind.?);
        try testing.expectEqualStrings("workspace.1.tab.1", sink.id[0..sink.id_len]);
        const g = try callMessage(&msg_buf, tab_path, iface_component, "GrabFocus", "", "");
        out = Writer.init(&out_buf);
        _ = service.handle(&g, &out);
        try testing.expectEqual(RequestKind.focus, sink.kind.?);
    }
    // Action is not offered on a surface.
    {
        var sb: [element_prefix.len + 16]u8 = undefined;
        const m = try callMessage(&msg_buf, elementPath(&sb, snapshot_mod.keyOf("sidebar")), iface_action, "DoAction", "i", &.{ 0, 0, 0, 0 });
        var out = Writer.init(&out_buf);
        try testing.expect(service.handle(&m, &out) == .err);
    }
    // Registry assigns an id.
    {
        var body_buf: [128]u8 = undefined;
        var body = Writer.init(&body_buf);
        try body.string(iface_application);
        try body.string("Id");
        try body.beginVariant("i");
        try body.int32(7);
        const m = try callMessage(&msg_buf, root_path, iface_properties, "Set", "ssv", body.written());
        var out = Writer.init(&out_buf);
        try testing.expectEqualStrings("", service.handle(&m, &out).ok);
        try testing.expectEqual(@as(i32, 7), app_id);
    }
    // Unknown paths and stale elements.
    {
        const m = try callMessage(&msg_buf, "/nowhere", iface_accessible, "GetRole", "", "");
        var out = Writer.init(&out_buf);
        try testing.expect(service.handle(&m, &out) == .err);
        const stale = try callMessage(&msg_buf, element_prefix ++ "0000000000000001", iface_accessible, "GetState", "", "");
        out = Writer.init(&out_buf);
        try testing.expectEqualStrings("au", service.handle(&stale, &out).ok);
    }
    // Bad arguments are an error reply, not a crash.
    {
        const m = try callMessage(&msg_buf, tab_path, iface_component, "GetExtents", "s", &.{ 1, 0, 0, 0, 'x', 0 });
        var out = Writer.init(&out_buf);
        try testing.expect(service.handle(&m, &out) == .err);
    }
    // The cache lists every object.
    {
        const m = try callMessage(&msg_buf, cache_path, iface_cache, "GetItems", "", "");
        var out = Writer.init(&out_buf);
        try testing.expectEqualStrings("a((so)(so)(so)iiassusau)", service.handle(&m, &out).ok);
        var r = Reader.init(out.written(), .little);
        const end = try r.beginArray(8);
        var count: usize = 0;
        while (r.pos < end) : (count += 1) try r.skip("((so)(so)(so)iiassusau)");
        try testing.expectEqual(@as(usize, 2 + 9), count);
    }
}

test "diff reports children, focus, selection and name changes" {
    var old = try Snapshot.init(testing.allocator, 16, 1024);
    defer old.deinit();
    var new = try Snapshot.init(testing.allocator, 16, 1024);
    defer new.deinit();
    var events: [64]Event = undefined;

    // From nothing: three top-level children appear, and the query is focused.
    var empty = try Snapshot.init(testing.allocator, 1, 1);
    defer empty.deinit();
    empty.begin(rect(0, 0, 640, 360));
    empty.finish();
    fixture(&old, false);
    const first = diff(&empty, &old, &events);
    var added: usize = 0;
    for (events[0..first]) |e| if (e.kind == .child_added and e.source == .window) {
        added += 1;
    };
    try testing.expectEqual(@as(usize, 3), added);

    // Focus moves from the palette query to the tab.
    fixture(&new, true);
    const n = diff(&old, &new, &events);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(Event.Kind.focused, events[0].kind);
    try testing.expectEqual(snapshot_mod.keyOf("workspace.1.tab.1"), events[0].source.key);
    try testing.expectEqual(@as(i32, 1), events[0].detail1);
    try testing.expectEqual(snapshot_mod.keyOf("palette.query"), events[1].source.key);
    try testing.expectEqual(@as(i32, 0), events[1].detail1);

    // The palette closes and a label changes.
    new.begin(rect(0, 0, 640, 360));
    _ = new.append(.{ .id = "sidebar", .role = "sidebar", .label = "Sidebar", .bounds = rect(0, 0, 160, 360), .primitive = .surface });
    _ = new.append(.{ .id = "workspace.1", .parent = "sidebar", .role = "workspace", .label = "renamed", .action = "workspace.activate", .bounds = rect(8, 0, 152, 18), .primitive = .interactive_text });
    new.finish();
    const m = diff(&old, &new, &events);
    var removed: usize = 0;
    var renamed = false;
    var unselected = false;
    for (events[0..m]) |e| switch (e.kind) {
        .child_removed => removed += 1,
        .name => renamed = std.mem.eql(u8, e.text, "renamed"),
        .selected => unselected = e.detail1 == 0,
        else => {},
    };
    // Palette and settings leave the window; the tab leaves its workspace.
    try testing.expectEqual(@as(usize, 3), removed);
    try testing.expect(renamed and unselected);

    // The output bound is respected.
    try testing.expectEqual(@as(usize, 1), diff(&empty, &old, events[0..1]));
}

test "events encode as siiva{sv} signals" {
    var body_buf: [256]u8 = undefined;
    var body = Writer.init(&body_buf);
    var path_buf: [element_prefix.len + 16]u8 = undefined;
    const sig = try encodeEvent(.{ .kind = .child_added, .source = .window, .child_key = 0xabc, .detail1 = 2 }, ":1.9", &path_buf, &body);
    try testing.expectEqualStrings(window_path, sig.path);
    try testing.expectEqualStrings("ChildrenChanged", sig.member);
    var r = Reader.init(body.written(), .little);
    try testing.expectEqualStrings("add", try r.string());
    try testing.expectEqual(@as(i32, 2), try r.int32());
    try testing.expectEqual(@as(i32, 0), try r.int32());
    try testing.expectEqualStrings("(so)", try r.signature());
    try r.beginStruct();
    try testing.expectEqualStrings(":1.9", try r.string());
    try testing.expectEqualStrings(element_prefix ++ "0000000000000abc", try r.objectPath());
    try r.skip("a{sv}");
    try testing.expectEqual(body.len, r.pos);

    body = Writer.init(&body_buf);
    const state = try encodeEvent(.{ .kind = .focused, .source = .{ .key = 1 }, .detail1 = 1 }, ":1.9", &path_buf, &body);
    try testing.expectEqualStrings("StateChanged", state.member);
    try testing.expectEqualStrings(element_prefix ++ "0000000000000001", state.path);
}
