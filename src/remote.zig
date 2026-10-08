//! The pure half of SSH workspaces in the app (TASK-43 part two, TASK-44):
//! the connection manager's host list and choice values, and how a
//! connection state is shown. No IO happens here; `main.zig` reads files
//! through the Local `ExecutionContext` and hands their bytes in.
//!
//! A file of the `app` module, like `git.zig` and `app_agents.zig`, because
//! only the app consumes it.

const std = @import("std");
const workspace = @import("workspace");

const ssh = workspace.ssh;

/// The most hosts the connection manager lists from ssh configuration.
pub const max_hosts: usize = 64;
/// The longest host alias kept; a longer one is skipped, not cut.
pub const max_host_bytes: usize = 64;
/// The most `Include` patterns followed from the top-level file, and the
/// most files they may expand to. Includes are followed one level deep.
pub const max_includes: usize = 8;
pub const max_include_files: usize = 16;
/// The most bytes read from one configuration file.
pub const max_config_bytes: usize = 64 * 1024;
/// The longest include pattern kept.
pub const max_include_bytes: usize = 512;

/// Concrete `Host` aliases in first-seen order, deduplicated and bounded.
pub const Hosts = struct {
    names: [max_hosts][max_host_bytes]u8 = undefined,
    lens: [max_hosts]usize = undefined,
    count: usize = 0,

    pub fn at(self: *const Hosts, index: usize) []const u8 {
        return self.names[index][0..self.lens[index]];
    }

    fn contains(self: *const Hosts, name: []const u8) bool {
        for (0..self.count) |index| {
            if (std.mem.eql(u8, self.at(index), name)) return true;
        }
        return false;
    }

    fn add(self: *Hosts, name: []const u8) void {
        if (self.count == max_hosts or name.len > max_host_bytes or self.contains(name)) return;
        @memcpy(self.names[self.count][0..name.len], name);
        self.lens[self.count] = name.len;
        self.count += 1;
    }
};

/// `Include` patterns found in the top-level file, bounded.
pub const Includes = struct {
    patterns: [max_includes][max_include_bytes]u8 = undefined,
    lens: [max_includes]usize = undefined,
    count: usize = 0,

    pub fn at(self: *const Includes, index: usize) []const u8 {
        return self.patterns[index][0..self.lens[index]];
    }

    fn add(self: *Includes, pattern: []const u8) void {
        if (self.count == max_includes or pattern.len > max_include_bytes) return;
        @memcpy(self.patterns[self.count][0..pattern.len], pattern);
        self.lens[self.count] = pattern.len;
        self.count += 1;
    }
};

/// Whether a `Host` argument names one concrete host a person could pick:
/// no pattern characters, no negation, and something `ssh` would take as a
/// destination (`ssh.validateDestination`).
pub fn concreteAlias(argument: []const u8) bool {
    if (argument.len == 0 or argument.len > max_host_bytes) return false;
    if (std.mem.indexOfAny(u8, argument, "*?!,\"'") != null) return false;
    ssh.validateDestination(argument) catch return false;
    return true;
}

/// Split one configuration line into its keyword and arguments the way
/// `ssh_config(5)` does: the keyword ends at whitespace or `=`, and
/// arguments are whitespace-separated, optionally in double quotes.
const Line = struct {
    keyword: []const u8,
    rest: []const u8,
};

fn splitLine(raw: []const u8) ?Line {
    const line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0 or line[0] == '#') return null;
    var end: usize = 0;
    while (end < line.len and line[end] != ' ' and line[end] != '\t' and line[end] != '=') : (end += 1) {}
    var rest = std.mem.trimStart(u8, line[end..], " \t");
    if (rest.len != 0 and rest[0] == '=') rest = std.mem.trimStart(u8, rest[1..], " \t");
    return .{ .keyword = line[0..end], .rest = rest };
}

/// Iterate the arguments of a line.
const Arguments = struct {
    rest: []const u8,

    fn next(self: *Arguments) ?[]const u8 {
        self.rest = std.mem.trimStart(u8, self.rest, " \t");
        if (self.rest.len == 0) return null;
        if (self.rest[0] == '"') {
            const close = std.mem.indexOfScalarPos(u8, self.rest, 1, '"') orelse {
                const all = self.rest[1..];
                self.rest = "";
                return all;
            };
            const value = self.rest[1..close];
            self.rest = self.rest[close + 1 ..];
            return value;
        }
        var end: usize = 0;
        while (end < self.rest.len and self.rest[end] != ' ' and self.rest[end] != '\t') : (end += 1) {}
        const value = self.rest[0..end];
        self.rest = self.rest[end..];
        return value;
    }
};

/// Collect the concrete aliases of every `Host` line of one configuration
/// file, and its `Include` patterns when `includes` is given (the top-level
/// file only, so includes are followed one level). Wildcard and negated
/// patterns are skipped; `Match` blocks name no host and are ignored.
/// Malformed text is skipped, never an error: the file is the user's.
pub fn parseHosts(text: []const u8, hosts: *Hosts, includes: ?*Includes) void {
    const bounded = text[0..@min(text.len, max_config_bytes)];
    var lines = std.mem.splitScalar(u8, bounded, '\n');
    while (lines.next()) |raw| {
        const line = splitLine(raw) orelse continue;
        var arguments: Arguments = .{ .rest = line.rest };
        if (std.ascii.eqlIgnoreCase(line.keyword, "host")) {
            while (arguments.next()) |argument| {
                if (concreteAlias(argument)) hosts.add(argument);
            }
        } else if (std.ascii.eqlIgnoreCase(line.keyword, "include")) {
            const list = includes orelse continue;
            while (arguments.next()) |pattern| {
                if (pattern.len != 0) list.add(pattern);
            }
        }
    }
}

/// Resolve an `Include` pattern the way OpenSSH does for a user file: `~/`
/// is the home directory and a relative path is relative to `base_dir`
/// (`~/.ssh`). Null when it cannot be resolved (`~` without a home).
pub fn resolveInclude(buffer: []u8, pattern: []const u8, base_dir: []const u8, home: ?[]const u8) ?[]const u8 {
    if (pattern.len == 0) return null;
    if (pattern[0] == '/') return std.fmt.bufPrint(buffer, "{s}", .{pattern}) catch null;
    if (std.mem.startsWith(u8, pattern, "~/")) {
        const dir = home orelse return null;
        return std.fmt.bufPrint(buffer, "{s}/{s}", .{ dir, pattern[2..] }) catch null;
    }
    if (pattern[0] == '~') return null;
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ base_dir, pattern }) catch null;
}

/// Whether `name` matches a shell glob of `*` and `?` (no classes), as an
/// `Include` file-name pattern does. A leading `.` is matched only by a
/// literal dot.
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    if (name.len != 0 and name[0] == '.' and (pattern.len == 0 or pattern[0] != '.')) return false;
    var p: usize = 0;
    var n: usize = 0;
    var star: ?usize = null;
    var star_n: usize = 0;
    while (n < name.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == name[n])) {
            p += 1;
            n += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            star_n = n;
            p += 1;
        } else if (star) |at| {
            p = at + 1;
            star_n += 1;
            n = star_n;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// Whether a file an `Include` names may be read as configuration. Private
/// and public keys, known-hosts and authorized-keys files are never read,
/// whatever an `Include` line or a glob says: Conduit never handles a
/// credential (decision-8).
pub fn mayReadConfigFile(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.startsWith(u8, name, "id_")) return false;
    if (std.mem.endsWith(u8, name, ".pub")) return false;
    if (std.mem.startsWith(u8, name, "known_hosts")) return false;
    if (std.mem.startsWith(u8, name, "authorized_keys")) return false;
    return true;
}

/// How a connection state shows in the sidebar: a glyph before the
/// workspace name (none when connected) and the status-line wording. The
/// glyphs are in the bundled face (`⇅` is not, so connecting is `↕`).
pub fn stateGlyph(state: ssh.State) []const u8 {
    return switch (state) {
        .connecting => "↕",
        .connected => "",
        .lost => "⚠",
        .failed => "✗",
        .disconnected => "○",
    };
}

/// The words the connection view's header and the status line use.
pub fn stateWords(state: ssh.State) []const u8 {
    return switch (state) {
        .connecting => "connecting…",
        .connected => "connected",
        .lost => "connection lost",
        .failed => "connection failed",
        .disconnected => "disconnected",
    };
}

/// What one `remote.connect` choice names.
pub const Choice = union(enum) {
    /// A `Host` alias from ssh configuration.
    host: []const u8,
    /// A saved `remote.profile`, by name.
    profile: []const u8,
    /// A `remote.recent` destination.
    recent: []const u8,
    /// Ask for `user@host[:port]`.
    address,

    /// Parse a choice value; null for anything else.
    pub fn parse(value: []const u8) ?Choice {
        if (std.mem.eql(u8, value, "address")) return .address;
        if (std.mem.startsWith(u8, value, "host:") and value.len > 5) return .{ .host = value[5..] };
        if (std.mem.startsWith(u8, value, "profile:") and value.len > 8) return .{ .profile = value[8..] };
        if (std.mem.startsWith(u8, value, "recent:") and value.len > 7) return .{ .recent = value[7..] };
        return null;
    }

    /// Format a choice value into `buffer`.
    pub fn format(self: Choice, buffer: []u8) error{NoSpaceLeft}![]const u8 {
        return switch (self) {
            .host => |name| std.fmt.bufPrint(buffer, "host:{s}", .{name}),
            .profile => |name| std.fmt.bufPrint(buffer, "profile:{s}", .{name}),
            .recent => |destination| std.fmt.bufPrint(buffer, "recent:{s}", .{destination}),
            .address => std.fmt.bufPrint(buffer, "address", .{}),
        };
    }
};

/// TASK-47: an installed WSL distribution as a `remote.connect` choice.
///
/// Kept beside `Choice` rather than inside it so the SSH choices keep their
/// exhaustive switch: the app checks `parseWslChoice` first and hands any
/// other value to `Choice.parse`. The value is `wsl:<name>`; the label the
/// chooser shows is `<name>  WSL`. Distributions are offered only where WSL
/// exists (`workspace.wsl.supported`), listed with
/// `workspace.wsl.listRegisteredDistributions`, which reads the registry and
/// never blocks.
pub const wsl_choice_prefix = "wsl:";

/// Format the choice value for distribution `name` into `buffer`.
pub fn wslChoiceValue(buffer: []u8, name: []const u8) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buffer, wsl_choice_prefix ++ "{s}", .{name});
}

/// Format the chooser label for distribution `name` into `buffer`.
pub fn wslChoiceLabel(buffer: []u8, name: []const u8) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}  WSL", .{name});
}

/// The distribution a choice value names, or null when the value is not a
/// WSL choice or names something `wsl.exe -d` must not be given.
pub fn parseWslChoice(value: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, wsl_choice_prefix)) return null;
    const name = value[wsl_choice_prefix.len..];
    if (!workspace.wsl.validDistributionName(name)) return null;
    return name;
}

// ---------------------------------------------------------------- unit tests

test "a WSL distribution round-trips as a connect choice and is never an SSH choice" {
    var value_buffer: [96]u8 = undefined;
    const value = try wslChoiceValue(&value_buffer, "Ubuntu-24.04");
    try testing.expectEqualStrings("wsl:Ubuntu-24.04", value);
    try testing.expectEqualStrings("Ubuntu-24.04", parseWslChoice(value).?);
    try testing.expectEqual(@as(?Choice, null), Choice.parse(value));
    var label_buffer: [96]u8 = undefined;
    try testing.expectEqualStrings("Ubuntu-24.04  WSL", try wslChoiceLabel(&label_buffer, "Ubuntu-24.04"));
    for ([_][]const u8{ "wsl:", "wsl:-d", "wsl:a b", "wsl:x;y", "host:Ubuntu", "Ubuntu", "address" }) |other| {
        try testing.expect(parseWslChoice(other) == null);
    }
}

const testing = std.testing;

test "concrete Host aliases are listed once and patterns, negations and option look-alikes are skipped" {
    var hosts: Hosts = .{};
    var includes: Includes = .{};
    parseHosts(
        \\# a comment
        \\Host dev-box prod  "quoted-box"
        \\  HostName 10.0.0.1
        \\host *.example.com !bad  web?  -oProxyCommand=x
        \\HOST=gateway
        \\Match host foo
        \\  User me
        \\Host dev-box
        \\Include config.d/*  ~/.ssh/extra
        \\Hostname not-a-host-line
        \\
    , &hosts, &includes);
    try testing.expectEqual(@as(usize, 4), hosts.count);
    try testing.expectEqualStrings("dev-box", hosts.at(0));
    try testing.expectEqualStrings("prod", hosts.at(1));
    try testing.expectEqualStrings("quoted-box", hosts.at(2));
    try testing.expectEqualStrings("gateway", hosts.at(3));
    try testing.expectEqual(@as(usize, 2), includes.count);
    try testing.expectEqualStrings("config.d/*", includes.at(0));
    try testing.expectEqualStrings("~/.ssh/extra", includes.at(1));

    // An included file's own Include lines are not followed.
    parseHosts("Host inner\nInclude deeper\n", &hosts, null);
    try testing.expectEqual(@as(usize, 5), hosts.count);
    try testing.expectEqual(@as(usize, 2), includes.count);
}

test "the host list and include list are bounded" {
    var hosts: Hosts = .{};
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..max_hosts + 10) |index| {
        try text.print(testing.allocator, "Host h{d}\n", .{index});
    }
    try text.appendSlice(testing.allocator, "Host " ++ "x" ** (max_host_bytes + 1) ++ "\n");
    var includes: Includes = .{};
    for (0..max_includes + 3) |_| try text.appendSlice(testing.allocator, "Include a\n");
    parseHosts(text.items, &hosts, &includes);
    try testing.expectEqual(max_hosts, hosts.count);
    try testing.expectEqualStrings("h0", hosts.at(0));
    try testing.expectEqual(max_includes, includes.count);
}

test "include patterns resolve against the ssh directory and home, and globs match file names" {
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings("/home/u/.ssh/config.d/*", resolveInclude(&buffer, "config.d/*", "/home/u/.ssh", "/home/u").?);
    try testing.expectEqualStrings("/home/u/other", resolveInclude(&buffer, "~/other", "/home/u/.ssh", "/home/u").?);
    try testing.expectEqualStrings("/etc/ssh/x", resolveInclude(&buffer, "/etc/ssh/x", "/home/u/.ssh", null).?);
    try testing.expectEqual(@as(?[]const u8, null), resolveInclude(&buffer, "~/other", "/home/u/.ssh", null));
    try testing.expectEqual(@as(?[]const u8, null), resolveInclude(&buffer, "~bob/x", "/home/u/.ssh", "/home/u"));

    try testing.expect(globMatch("*", "work"));
    try testing.expect(globMatch("*.conf", "a.conf"));
    try testing.expect(!globMatch("*.conf", "a.conf.bak"));
    try testing.expect(globMatch("h?st", "host"));
    try testing.expect(!globMatch("*", ".hidden"));
    try testing.expect(globMatch(".h*", ".hidden"));
    try testing.expect(globMatch("a*b*c", "aXbYbZc"));

    try testing.expect(mayReadConfigFile("work.conf"));
    for ([_][]const u8{ "id_ed25519", "id_rsa.pub", "work.pub", "known_hosts", "known_hosts.old", "authorized_keys", "" }) |name| {
        try testing.expect(!mayReadConfigFile(name));
    }
}

test "each connection state has its glyph and words, and connected shows none" {
    try testing.expectEqualStrings("↕", stateGlyph(.connecting));
    try testing.expectEqualStrings("", stateGlyph(.connected));
    try testing.expectEqualStrings("⚠", stateGlyph(.lost));
    try testing.expectEqualStrings("✗", stateGlyph(.failed));
    try testing.expectEqualStrings("○", stateGlyph(.disconnected));
    try testing.expectEqualStrings("connection lost", stateWords(.lost));
    try testing.expectEqualStrings("connecting…", stateWords(.connecting));
}

test "choice values round-trip and anything else is refused" {
    var buffer: [64]u8 = undefined;
    for ([_]Choice{ .{ .host = "dev-box" }, .{ .profile = "work" }, .{ .recent = "me@h:22" }, .address }) |choice| {
        const value = try choice.format(&buffer);
        const parsed = Choice.parse(value).?;
        try testing.expectEqual(std.meta.activeTag(choice), std.meta.activeTag(parsed));
    }
    try testing.expectEqualStrings("dev-box", Choice.parse("host:dev-box").?.host);
    try testing.expectEqual(@as(?Choice, null), Choice.parse("host:"));
    try testing.expectEqual(@as(?Choice, null), Choice.parse("none"));
}
