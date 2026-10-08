//! Allocation-free detection of actionable terminal text.
//!
//! The detector accepts one already-visible UTF-8 row at a time. It borrows
//! that row, explicit OSC 8 targets and caller-provided match storage; it owns
//! nothing and performs no IO. Filesystem meaning, cwd resolution, opening a
//! browser and spawning an editor deliberately belong to later layers.
//!
//! OSC 8 ranges are authoritative. Every well-formed range masks lexical
//! detection even when its URI is unusable, so an explicit hyperlink label is
//! never reinterpreted as a different URL or file reference.

const std = @import("std");

/// Default upper bound for one borrowed URL or file-reference spelling.
pub const default_max_target_bytes: usize = 2048;

/// Half-open byte offsets into one visible UTF-8 row.
pub const Span = struct {
    /// First included byte.
    start: usize,
    /// First excluded byte.
    end: usize,

    /// Whether this span contains at least one byte and fits inside `length`.
    pub fn isValid(self: Span, length: usize) bool {
        return self.start < self.end and self.end <= length;
    }
};

/// A parsed file reference. `path` borrows the detected row.
pub const FileReference = struct {
    /// Path spelling without the optional location suffix.
    path: []const u8,
    /// One-based line, when present.
    line: ?u32 = null,
    /// One-based column, when present. A column never exists without a line.
    column: ?u32 = null,
};

/// The action target represented by terminal text.
pub const Target = union(enum) {
    /// An exact HTTP or HTTPS URL. Lexical URLs borrow the row; OSC 8 URLs
    /// borrow the supplied range's `uri`.
    url: []const u8,
    /// An explicit path, optionally followed by a positive line and column.
    file: FileReference,
};

/// How a match acquired its target.
pub const Source = enum {
    /// Detected from visible row text.
    lexical,
    /// Supplied explicitly by the terminal's OSC 8 state.
    osc8,
};

/// One actionable visual span in a row.
pub const Match = struct {
    /// Display bytes borrowed from the row.
    text: []const u8,
    /// Byte offsets of `text` in the row.
    span: Span,
    /// Whether visible bytes or OSC 8 supplied the action target.
    source: Source,
    /// Borrowed action target.
    target: Target,
};

/// An explicit hyperlink supplied by the terminal engine.
///
/// Ranges must be non-empty, in bounds and on UTF-8 boundaries. Invalid
/// ranges are ignored. In-bounds overlapping ranges are coalesced for masking;
/// the leftmost range (then the longest, then input order) supplies the one
/// emitted target for that coalesced region.
pub const Osc8Range = struct {
    /// Display extent in the visible row.
    span: Span,
    /// Exact explicit URI, borrowed from the terminal engine.
    uri: []const u8,
};

/// Detection limits chosen by the caller without allocating storage.
pub const Options = struct {
    /// Largest accepted complete target spelling.
    max_target_bytes: usize = default_max_target_bytes,
};

/// The part of a candidate retained after surrounding syntax is removed.
pub const ParsedCandidate = struct {
    /// Offsets relative to the candidate passed to `parseCandidate`.
    span: Span,
    /// Borrowed parsed target.
    target: Target,
};

/// A completed row scan. `matches` borrows the caller's output storage.
pub const Detection = struct {
    /// Visual-order prefix retained in caller storage.
    matches: []Match,
    /// At least one valid later match did not fit. The retained prefix is
    /// always the same for the same row, ranges, options and storage length.
    truncated: bool,
};

/// Malformed visible rows are rejected atomically.
pub const DetectError = error{InvalidUtf8};

/// Parse one prospective URL or file reference without allocating.
///
/// Matching surrounding quotes/brackets, unmatched closing brackets and
/// sentence punctuation are excluded from `span`. The returned target slices
/// borrow `candidate`.
pub fn parseCandidate(candidate: []const u8, options: Options) ?ParsedCandidate {
    if (!std.unicode.utf8ValidateSlice(candidate)) return null;
    const span = trimCandidate(candidate);
    if (!span.isValid(candidate.len)) return null;

    const text = candidate[span.start..span.end];
    if (text.len > options.max_target_bytes) return null;
    if (parseUrlExact(text, options.max_target_bytes)) |url| {
        return .{ .span = span, .target = .{ .url = url } };
    }
    const file = parseFileExact(text, options.max_target_bytes) orelse return null;
    return .{ .span = span, .target = .{ .file = file } };
}

/// Detect actionable text in one visible terminal row.
///
/// `storage` fixes the maximum returned match count. Scanning continues after
/// it fills so `truncated` is exact, while the earliest visual matches remain
/// retained. OSC 8 ranges mask lexical candidates before those candidates are
/// parsed, including when the explicit URI is invalid.
pub fn detectRow(
    row: []const u8,
    osc8_ranges: []const Osc8Range,
    storage: []Match,
    options: Options,
) DetectError!Detection {
    if (!std.unicode.utf8ValidateSlice(row)) return error.InvalidUtf8;

    var collector = Collector{ .storage = storage };
    var cursor: usize = 0;
    while (cursor < row.len) {
        const protected = nextProtected(row, osc8_ranges, cursor);
        const lexical_end = if (protected) |range| range.start else row.len;
        detectLexical(row, cursor, lexical_end, &collector, options);
        cursor = lexical_end;

        const range = protected orelse break;
        if (range.winner_span.start == range.start) {
            const explicit = osc8_ranges[range.winner_index];
            if (parseUrlExact(explicit.uri, options.max_target_bytes)) |url| {
                const display = explicit.span;
                collector.append(.{
                    .text = row[display.start..display.end],
                    .span = display,
                    .source = .osc8,
                    .target = .{ .url = url },
                });
            }
        }
        cursor = range.end;
    }

    return .{
        .matches = storage[0..collector.len],
        .truncated = collector.truncated,
    };
}

const Collector = struct {
    storage: []Match,
    len: usize = 0,
    truncated: bool = false,

    fn append(self: *Collector, match: Match) void {
        if (self.len == self.storage.len) {
            self.truncated = true;
            return;
        }
        self.storage[self.len] = match;
        self.len += 1;
    }
};

const Protected = struct {
    start: usize,
    end: usize,
    winner_index: usize,
    winner_span: Span,
};

fn nextProtected(row: []const u8, ranges: []const Osc8Range, cursor: usize) ?Protected {
    var winner_index: ?usize = null;
    for (ranges, 0..) |range, index| {
        if (!validRange(row, range.span) or range.span.end <= cursor) continue;
        if (winner_index) |winner| {
            const chosen = ranges[winner].span;
            if (range.span.start > chosen.start) continue;
            if (range.span.start == chosen.start and range.span.end <= chosen.end) continue;
        }
        winner_index = index;
    }

    const winner = winner_index orelse return null;
    const winner_span = ranges[winner].span;
    var union_start = @max(cursor, winner_span.start);
    var union_end = winner_span.end;

    // Extend to the transitive union. OSC ranges from a real terminal do not
    // overlap, but deterministic handling here keeps malformed supplied data
    // from exposing lexical fragments.
    var changed = true;
    while (changed) {
        changed = false;
        for (ranges) |range| {
            if (!validRange(row, range.span)) continue;
            if (range.span.start >= union_end or range.span.end <= union_start) continue;
            if (range.span.start < union_start) {
                union_start = @max(cursor, range.span.start);
                changed = true;
            }
            if (range.span.end > union_end) {
                union_end = range.span.end;
                changed = true;
            }
        }
    }

    return .{
        .start = union_start,
        .end = union_end,
        .winner_index = winner,
        .winner_span = winner_span,
    };
}

fn validRange(row: []const u8, span: Span) bool {
    if (!span.isValid(row.len)) return false;
    return utf8Boundary(row, span.start) and utf8Boundary(row, span.end);
}

fn utf8Boundary(text: []const u8, index: usize) bool {
    return index == 0 or index == text.len or text[index] & 0xc0 != 0x80;
}

fn detectLexical(
    row: []const u8,
    start: usize,
    end: usize,
    collector: *Collector,
    options: Options,
) void {
    var cursor = start;
    while (cursor < end) {
        const byte = row[cursor];

        if (isQuote(byte)) {
            const close = findByte(row, cursor + 1, end, byte);
            if (close) |close_index| {
                _ = appendCandidate(row, cursor + 1, close_index, .lexical, collector, options);
                cursor = close_index + 1;
                continue;
            }
            cursor += 1;
            continue;
        }

        if (hasUrlPrefix(row[cursor..end]) and urlStartBoundary(row, cursor)) {
            const raw_end = scanUrlEnd(row, cursor, end);
            if (!continuesAcrossProtection(row, raw_end, end)) {
                if (appendCandidate(row, cursor, raw_end, .lexical, collector, options)) |matched_end| {
                    cursor = @max(raw_end, matched_end);
                    continue;
                }
            }
        }

        if (!fileStartBoundary(row, cursor)) {
            cursor += utf8SequenceLength(byte);
            continue;
        }
        if (isFileStop(byte)) {
            cursor += 1;
            continue;
        }

        const raw_end = scanFileEnd(row, cursor, end);
        if (!continuesAcrossProtection(row, raw_end, end)) {
            if (appendCandidate(row, cursor, raw_end, .lexical, collector, options)) |matched_end| {
                cursor = @max(raw_end, matched_end);
                continue;
            }
        }
        cursor = if (raw_end > cursor) raw_end else cursor + 1;
    }
}

fn appendCandidate(
    row: []const u8,
    start: usize,
    end: usize,
    source: Source,
    collector: *Collector,
    options: Options,
) ?usize {
    if (start >= end) return null;
    const parsed = parseCandidate(row[start..end], options) orelse return null;
    const span = Span{
        .start = start + parsed.span.start,
        .end = start + parsed.span.end,
    };
    collector.append(.{
        .text = row[span.start..span.end],
        .span = span,
        .source = source,
        .target = parsed.target,
    });
    return span.end;
}

fn scanUrlEnd(row: []const u8, start: usize, end: usize) usize {
    var cursor = start;
    while (cursor < end and !isUrlStop(row[cursor])) : (cursor += 1) {}
    return cursor;
}

fn scanFileEnd(row: []const u8, start: usize, end: usize) usize {
    var cursor = start;
    while (cursor < end and !isFileStop(row[cursor])) : (cursor += 1) {}
    return cursor;
}

fn continuesAcrossProtection(row: []const u8, raw_end: usize, segment_end: usize) bool {
    return raw_end == segment_end and segment_end < row.len and
        !isFileStop(row[segment_end]) and !isUrlStop(row[segment_end]);
}

fn findByte(text: []const u8, start: usize, end: usize, needle: u8) ?usize {
    var index = start;
    while (index < end) : (index += 1) {
        if (text[index] == needle) return index;
    }
    return null;
}

fn urlStartBoundary(row: []const u8, index: usize) bool {
    if (index == 0) return true;
    const previous = row[index - 1];
    if (previous >= 0x80) return false;
    return !std.ascii.isAlphanumeric(previous) and previous != '_' and
        previous != '-' and previous != '.';
}

fn fileStartBoundary(row: []const u8, index: usize) bool {
    return index == 0 or isFileStop(row[index - 1]);
}

fn isQuote(byte: u8) bool {
    return byte == '\'' or byte == '"' or byte == '`';
}

fn isUrlStop(byte: u8) bool {
    return byte <= ' ' or byte == 0x7f or isQuote(byte) or byte == '<' or byte == '>';
}

fn isFileStop(byte: u8) bool {
    return isUrlStop(byte) or byte == '(' or byte == '[' or byte == '{' or
        byte == '=' or byte == ',' or byte == ';';
}

fn utf8SequenceLength(first: u8) usize {
    if (first < 0x80) return 1;
    if (first < 0xe0) return 2;
    if (first < 0xf0) return 3;
    return 4;
}

fn trimCandidate(candidate: []const u8) Span {
    var start: usize = 0;
    var end = candidate.len;
    var changed = true;
    while (changed and start < end) {
        changed = false;
        while (start < end and std.ascii.isWhitespace(candidate[start])) : (start += 1) {
            changed = true;
        }
        while (start < end and std.ascii.isWhitespace(candidate[end - 1])) : (end -= 1) {
            changed = true;
        }
        if (start >= end) break;

        if (matchingWrapper(candidate[start], candidate[end - 1])) {
            start += 1;
            end -= 1;
            changed = true;
            continue;
        }
        if (isSentencePunctuation(candidate[end - 1])) {
            end -= 1;
            changed = true;
            continue;
        }
        if (isUnmatchedClosing(candidate[start..end], candidate[end - 1])) {
            end -= 1;
            changed = true;
        }
    }
    return .{ .start = start, .end = end };
}

fn matchingWrapper(open: u8, close: u8) bool {
    return (open == '(' and close == ')') or
        (open == '[' and close == ']') or
        (open == '{' and close == '}') or
        (open == '"' and close == '"') or
        (open == '\'' and close == '\'') or
        (open == '`' and close == '`');
}

fn isSentencePunctuation(byte: u8) bool {
    return byte == '.' or byte == ',' or byte == ';' or byte == ':' or
        byte == '!' or byte == '?';
}

fn isUnmatchedClosing(text: []const u8, last: u8) bool {
    const open: u8 = switch (last) {
        ')' => '(',
        ']' => '[',
        '}' => '{',
        else => return false,
    };
    var opens: usize = 0;
    var closes: usize = 0;
    for (text) |byte| {
        if (byte == open) opens += 1;
        if (byte == last) closes += 1;
    }
    return closes > opens;
}

fn parseUrlExact(text: []const u8, max_target_bytes: usize) ?[]const u8 {
    if (!validTargetText(text, max_target_bytes, false)) return null;
    const scheme_len = urlSchemeLength(text) orelse return null;
    if (scheme_len == text.len) return null;

    var authority_end = scheme_len;
    while (authority_end < text.len) : (authority_end += 1) {
        const byte = text[authority_end];
        if (byte == '/' or byte == '?' or byte == '#') break;
    }
    var authority = text[scheme_len..authority_end];
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    if (authority.len == 0 or authority[0] == ':' or authority[0] == '.') return null;
    return text;
}

fn hasUrlPrefix(text: []const u8) bool {
    return urlSchemeLength(text) != null;
}

fn urlSchemeLength(text: []const u8) ?usize {
    if (text.len >= 8 and std.ascii.eqlIgnoreCase(text[0..8], "https://")) return 8;
    if (text.len >= 7 and std.ascii.eqlIgnoreCase(text[0..7], "http://")) return 7;
    return null;
}

const NumericSuffix = union(enum) {
    none,
    invalid,
    value: struct {
        colon: usize,
        number: u32,
    },
};

fn parseFileExact(text: []const u8, max_target_bytes: usize) ?FileReference {
    if (!validTargetText(text, max_target_bytes, true)) return null;
    if (std.mem.indexOf(u8, text, "://") != null) return null;

    var path_end = text.len;
    var line: ?u32 = null;
    var column: ?u32 = null;
    switch (numericSuffix(text)) {
        .none => {},
        .invalid => return null,
        .value => |last| if (!isDriveColon(text, last.colon)) {
            line = last.number;
            path_end = last.colon;
            switch (numericSuffix(text[0..path_end])) {
                .none => {},
                .invalid => return null,
                .value => |previous| if (!isDriveColon(text, previous.colon)) {
                    line = previous.number;
                    column = last.number;
                    path_end = previous.colon;
                },
            }
        },
    }

    const path = text[0..path_end];
    if (!validPath(path)) return null;
    const explicit = explicitPath(path);
    if (!explicit) {
        // A bare spelling needs both a filename-like signal and an explicit
        // location. Keeping the requirements together prevents prose and
        // unadorned filenames from becoming row matches.
        if (line == null or !bareFilenameSignal(path)) return null;
    }
    return .{ .path = path, .line = line, .column = column };
}

fn numericSuffix(text: []const u8) NumericSuffix {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return .none;
    const suffix = text[colon + 1 ..];
    if (suffix.len == 0) return .none;
    for (suffix) |byte| if (!std.ascii.isDigit(byte)) return .none;

    var number: u32 = 0;
    for (suffix) |byte| {
        number = std.math.mul(u32, number, 10) catch return .invalid;
        number = std.math.add(u32, number, byte - '0') catch return .invalid;
    }
    if (number == 0) return .invalid;
    return .{ .value = .{ .colon = colon, .number = number } };
}

fn validPath(path: []const u8) bool {
    if (path.len == 0 or std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "..")) return false;
    const last = path[path.len - 1];
    if (last == '/' or last == '\\') return false;
    return true;
}

fn explicitPath(path: []const u8) bool {
    if (path[0] == '/' or path[0] == '\\') return true;
    if (std.mem.startsWith(u8, path, "./") or std.mem.startsWith(u8, path, "../")) return true;
    if (std.mem.indexOfScalar(u8, path, '/') != null or
        std.mem.indexOfScalar(u8, path, '\\') != null) return true;
    return path.len >= 2 and isDriveColon(path, 1);
}

fn isDriveColon(text: []const u8, colon: usize) bool {
    return colon == 1 and text.len >= 2 and text[colon] == ':' and
        std.ascii.isAlphabetic(text[0]);
}

fn bareFilenameSignal(path: []const u8) bool {
    for (path) |byte| {
        if (byte >= 0x80 or std.ascii.isAlphabetic(byte) or byte == '.' or
            byte == '_' or byte == '-') return true;
    }
    return false;
}

fn validTargetText(text: []const u8, max_target_bytes: usize, allow_space: bool) bool {
    if (text.len == 0 or text.len > max_target_bytes) return false;
    const view = std.unicode.Utf8View.init(text) catch return false;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint < 0xa0) or
            codepoint == 0x2028 or codepoint == 0x2029) return false;
        if (!allow_space and codepoint == ' ') return false;
    }
    return true;
}

/// Whether a file reference is spelled as a Windows path: a drive (`C:\x`,
/// `C:/x`) or a UNC share (`\\server\share\x`). A WSL workspace translates
/// such a reference into its own path syntax before resolving it (TASK-47).
pub fn isWindowsPath(path: []const u8) bool {
    if (path.len >= 3 and isDriveColon(path, 1) and (path[2] == '\\' or path[2] == '/')) return true;
    return path.len >= 3 and path[0] == '\\' and path[1] == '\\' and path[2] != '\\';
}

/// Path translation between one WSL distribution and Windows (TASK-47), the
/// pure half of what `wslpath -u` and `wslpath -w` do, so a file reference can
/// be translated on the UI thread without starting a process.
///
/// `mount_root` is where the distribution mounts Windows drives (`/mnt/` by
/// default, `[automount] root` in `/etc/wsl.conf`); the WSL context learns the
/// real one once with `wslpath` and passes it here. Every result is written
/// into the caller's buffer; null means the path has no translation (or does
/// not fit).
pub const WslPaths = struct {
    /// The distribution's name, as `wsl --list` reports it.
    distribution: []const u8,
    /// Absolute, ending in `/`.
    mount_root: []const u8 = "/mnt/",

    /// A Windows path as the distribution sees it: `C:\Users\me\a.txt` is
    /// `/mnt/c/Users/me/a.txt`, and `\\wsl.localhost\<this distro>\home\me`
    /// (or `\\wsl$\...`) is `/home/me`. A share on another machine or another
    /// distribution has no path here.
    pub fn toWsl(self: WslPaths, path: []const u8, buffer: []u8) ?[]const u8 {
        if (path.len >= 2 and isDriveColon(path, 1) and (path.len == 2 or path[2] == '\\' or path[2] == '/')) {
            var writer: std.Io.Writer = .fixed(buffer);
            writer.writeAll(self.mount_root) catch return null;
            writer.writeByte(std.ascii.toLower(path[0])) catch return null;
            if (path.len > 2) writeSeparated(&writer, path[2..], '/') catch return null;
            return writer.buffered();
        }
        const rest = stripPrefixIgnoreCase(path, "\\\\wsl.localhost\\") orelse
            stripPrefixIgnoreCase(path, "\\\\wsl$\\") orelse return null;
        const separator = std.mem.indexOfScalar(u8, rest, '\\') orelse rest.len;
        if (!std.ascii.eqlIgnoreCase(rest[0..separator], self.distribution)) return null;
        var writer: std.Io.Writer = .fixed(buffer);
        if (separator == rest.len) {
            writer.writeByte('/') catch return null;
        } else {
            writeSeparated(&writer, rest[separator..], '/') catch return null;
        }
        return writer.buffered();
    }

    /// A distribution path as Windows sees it: under the mount root,
    /// `/mnt/c/Users/me` is `C:\Users\me`; any other absolute path is on the
    /// distribution's share, `\\wsl.localhost\<distro>\home\me`. A relative
    /// path has no Windows spelling until it is resolved.
    pub fn toWindows(self: WslPaths, path: []const u8, buffer: []u8) ?[]const u8 {
        if (path.len == 0 or path[0] != '/') return null;
        var writer: std.Io.Writer = .fixed(buffer);
        if (std.mem.startsWith(u8, path, self.mount_root)) {
            const rest = path[self.mount_root.len..];
            if (rest.len >= 1 and std.ascii.isAlphabetic(rest[0]) and (rest.len == 1 or rest[1] == '/')) {
                writer.writeByte(std.ascii.toUpper(rest[0])) catch return null;
                writer.writeByte(':') catch return null;
                if (rest.len <= 2) {
                    writer.writeByte('\\') catch return null;
                } else {
                    writeSeparated(&writer, rest[1..], '\\') catch return null;
                }
                return writer.buffered();
            }
        }
        writer.writeAll("\\\\wsl.localhost\\") catch return null;
        writer.writeAll(self.distribution) catch return null;
        if (path.len == 1) {
            writer.writeByte('\\') catch return null;
        } else {
            writeSeparated(&writer, path, '\\') catch return null;
        }
        return writer.buffered();
    }

    fn writeSeparated(writer: *std.Io.Writer, path: []const u8, separator: u8) std.Io.Writer.Error!void {
        for (path) |byte| try writer.writeByte(if (byte == '/' or byte == '\\') separator else byte);
    }

    fn stripPrefixIgnoreCase(text: []const u8, prefix: []const u8) ?[]const u8 {
        if (text.len < prefix.len or !std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix)) return null;
        return text[prefix.len..];
    }
};

test "Windows paths are recognised by drive or UNC share" {
    for ([_][]const u8{ "C:\\Users\\me\\a.txt", "d:/src/main.zig", "\\\\wsl.localhost\\Ubuntu\\home", "\\\\server\\share\\x" }) |path| {
        try std.testing.expect(isWindowsPath(path));
    }
    for ([_][]const u8{ "/home/me", "src/main.zig", "C:", "C:file", "\\\\\\x", "\\x", "1:\\x" }) |path| {
        try std.testing.expect(!isWindowsPath(path));
    }
}

test "WSL path translation matches wslpath for drives and the distribution share" {
    var buffer: [256]u8 = undefined;
    const ubuntu: WslPaths = .{ .distribution = "Ubuntu" };
    try std.testing.expectEqualStrings("/mnt/c/Users/me/a.txt", ubuntu.toWsl("C:\\Users\\me\\a.txt", &buffer).?);
    try std.testing.expectEqualStrings("/mnt/d/src/main.zig", ubuntu.toWsl("D:/src/main.zig", &buffer).?);
    try std.testing.expectEqualStrings("/mnt/c/", ubuntu.toWsl("C:\\", &buffer).?);
    try std.testing.expectEqualStrings("/mnt/c", ubuntu.toWsl("c:", &buffer).?);
    try std.testing.expectEqualStrings("/home/me/x.zig", ubuntu.toWsl("\\\\wsl.localhost\\Ubuntu\\home\\me\\x.zig", &buffer).?);
    try std.testing.expectEqualStrings("/etc", ubuntu.toWsl("\\\\wsl$\\ubuntu\\etc", &buffer).?);
    try std.testing.expectEqualStrings("/", ubuntu.toWsl("\\\\wsl.localhost\\Ubuntu", &buffer).?);
    // Another distribution's share and another machine's are not this distribution's paths.
    try std.testing.expect(ubuntu.toWsl("\\\\wsl.localhost\\Debian\\home", &buffer) == null);
    try std.testing.expect(ubuntu.toWsl("\\\\server\\share\\x", &buffer) == null);
    try std.testing.expect(ubuntu.toWsl("/home/me", &buffer) == null);

    try std.testing.expectEqualStrings("C:\\Users\\me\\a.txt", ubuntu.toWindows("/mnt/c/Users/me/a.txt", &buffer).?);
    try std.testing.expectEqualStrings("D:\\", ubuntu.toWindows("/mnt/d", &buffer).?);
    try std.testing.expectEqualStrings("\\\\wsl.localhost\\Ubuntu\\home\\me\\x.zig", ubuntu.toWindows("/home/me/x.zig", &buffer).?);
    try std.testing.expectEqualStrings("\\\\wsl.localhost\\Ubuntu\\", ubuntu.toWindows("/", &buffer).?);
    // `/mnt/data` is a directory under the mount root, not a drive.
    try std.testing.expectEqualStrings("\\\\wsl.localhost\\Ubuntu\\mnt\\data", ubuntu.toWindows("/mnt/data", &buffer).?);
    try std.testing.expect(ubuntu.toWindows("relative/x", &buffer) == null);

    // A custom automount root, as /etc/wsl.conf can set and `wslpath` reports.
    const custom: WslPaths = .{ .distribution = "Arch", .mount_root = "/" };
    try std.testing.expectEqualStrings("/c/x", custom.toWsl("C:\\x", &buffer).?);
    try std.testing.expectEqualStrings("C:\\x", custom.toWindows("/c/x", &buffer).?);

    // Round trips, and a result that does not fit is refused rather than cut.
    try std.testing.expectEqualStrings("C:\\a\\b", ubuntu.toWindows(ubuntu.toWsl("C:\\a\\b", &buffer).?, buffer[128..]).?);
    var tiny: [4]u8 = undefined;
    try std.testing.expect(ubuntu.toWsl("C:\\Users", &tiny) == null);
}

fn expectUrl(input: []const u8, expected: []const u8) !void {
    const parsed = parseCandidate(input, .{}) orelse return error.ExpectedUrl;
    try std.testing.expectEqualStrings(expected, input[parsed.span.start..parsed.span.end]);
    switch (parsed.target) {
        .url => |url| try std.testing.expectEqualStrings(expected, url),
        .file => return error.ExpectedUrl,
    }
}

fn expectFile(
    input: []const u8,
    expected_text: []const u8,
    expected_path: []const u8,
    expected_line: ?u32,
    expected_column: ?u32,
) !void {
    const parsed = parseCandidate(input, .{}) orelse return error.ExpectedFile;
    try std.testing.expectEqualStrings(expected_text, input[parsed.span.start..parsed.span.end]);
    switch (parsed.target) {
        .url => return error.ExpectedFile,
        .file => |file| {
            try std.testing.expectEqualStrings(expected_path, file.path);
            try std.testing.expectEqual(expected_line, file.line);
            try std.testing.expectEqual(expected_column, file.column);
        },
    }
}

test "candidate parsing accepts conservative URLs and explicit file references" {
    const urls = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "(https://example.test/a(b)).", .expected = "https://example.test/a(b)" },
        .{ .input = "`HTTP://localhost:8080/x?y=1`", .expected = "HTTP://localhost:8080/x?y=1" },
        .{ .input = "[https://example.test/a[b]]", .expected = "https://example.test/a[b]" },
    };
    for (urls) |case| try expectUrl(case.input, case.expected);

    const files = [_]struct {
        input: []const u8,
        text: []const u8,
        path: []const u8,
        line: ?u32,
        column: ?u32,
    }{
        .{ .input = "/tmp/main.zig", .text = "/tmp/main.zig", .path = "/tmp/main.zig", .line = null, .column = null },
        .{ .input = "./main.zig", .text = "./main.zig", .path = "./main.zig", .line = null, .column = null },
        .{ .input = "../src/main.zig:9", .text = "../src/main.zig:9", .path = "../src/main.zig", .line = 9, .column = null },
        .{ .input = "src/main.zig:12:3", .text = "src/main.zig:12:3", .path = "src/main.zig", .line = 12, .column = 3 },
        .{ .input = "Makefile:44.", .text = "Makefile:44", .path = "Makefile", .line = 44, .column = null },
        .{ .input = "\"dir/file name.zig:5:2\"", .text = "dir/file name.zig:5:2", .path = "dir/file name.zig", .line = 5, .column = 2 },
        .{ .input = "C:\\src\\main.zig:12:3", .text = "C:\\src\\main.zig:12:3", .path = "C:\\src\\main.zig", .line = 12, .column = 3 },
        .{ .input = "C:12", .text = "C:12", .path = "C:12", .line = null, .column = null },
        .{ .input = "C:12:3", .text = "C:12:3", .path = "C:12", .line = 3, .column = null },
    };
    for (files) |case| {
        try expectFile(case.input, case.text, case.path, case.line, case.column);
    }
}

test "candidate parsing rejects ambiguous malformed and overlong targets" {
    const rejected = [_][]const u8{
        "",
        "https://",
        "http://:80/x",
        "ftp://example.test",
        "main.zig",
        "12:34",
        "main.zig:0",
        "main.zig:2:0",
        "main.zig:4294967296",
        "src/main.zig:4294967296",
        "src/\x01main.zig:2",
        "src/main.zig/",
    };
    for (rejected) |candidate| try std.testing.expect(parseCandidate(candidate, .{}) == null);
    try std.testing.expect(parseCandidate(&.{0xff}, .{}) == null);
    try std.testing.expect(parseCandidate("https://example.test", .{ .max_target_bytes = 8 }) == null);
}

test "row detection does not promote prose or bare filenames" {
    const row = "see main.zig then src/main.zig:12:3 and Makefile:4";
    var storage: [4]Match = undefined;
    const found = try detectRow(row, &.{}, &storage, .{});

    try std.testing.expectEqual(@as(usize, 2), found.matches.len);
    try std.testing.expect(!found.truncated);
    try std.testing.expectEqualStrings("src/main.zig:12:3", found.matches[0].text);
    try std.testing.expectEqualStrings("Makefile:4", found.matches[1].text);
}

test "row detection returns visual offsets in order" {
    const row = "see (https://example.test/a(b)). then src/main.zig:12:3 and Makefile:4.";
    var storage: [8]Match = undefined;
    const found = try detectRow(row, &.{}, &storage, .{});

    try std.testing.expectEqual(@as(usize, 3), found.matches.len);
    try std.testing.expect(!found.truncated);
    const expected = [_][]const u8{
        "https://example.test/a(b)",
        "src/main.zig:12:3",
        "Makefile:4",
    };
    for (found.matches, expected) |match, text| {
        try std.testing.expectEqualStrings(text, match.text);
        try std.testing.expectEqualStrings(text, row[match.span.start..match.span.end]);
        try std.testing.expectEqual(std.mem.indexOf(u8, row, text).?, match.span.start);
        try std.testing.expectEqual(match.span.start + text.len, match.span.end);
        try std.testing.expectEqual(Source.lexical, match.source);
    }
}

test "OSC 8 ranges override lexical detection and invalid targets still mask" {
    const row = "go https://visible.test/path then src/main.zig:7";
    const display_start = std.mem.indexOf(u8, row, "https://") orelse unreachable;
    const display_end = display_start + "https://visible.test/path".len;
    const ranges = [_]Osc8Range{.{
        .span = .{ .start = display_start, .end = display_end },
        .uri = "https://target.test/different",
    }};
    var storage: [4]Match = undefined;
    const found = try detectRow(row, &ranges, &storage, .{});

    try std.testing.expectEqual(@as(usize, 2), found.matches.len);
    try std.testing.expectEqual(Source.osc8, found.matches[0].source);
    try std.testing.expectEqualStrings("https://visible.test/path", found.matches[0].text);
    switch (found.matches[0].target) {
        .url => |url| try std.testing.expectEqualStrings("https://target.test/different", url),
        .file => return error.ExpectedUrl,
    }
    try std.testing.expectEqualStrings("src/main.zig:7", found.matches[1].text);

    const invalid = [_]Osc8Range{.{
        .span = .{ .start = display_start, .end = display_end },
        .uri = "javascript:alert(1)",
    }};
    const masked = try detectRow(row, &invalid, &storage, .{});
    try std.testing.expectEqual(@as(usize, 1), masked.matches.len);
    try std.testing.expectEqualStrings("src/main.zig:7", masked.matches[0].text);
}

test "partial and overlapping OSC 8 ranges cannot expose lexical fragments" {
    const row = "https://visible.test/path";
    const first = [_]Osc8Range{
        .{ .span = .{ .start = 0, .end = 18 }, .uri = "https://first.test" },
        .{ .span = .{ .start = 8, .end = row.len }, .uri = "https://second.test" },
    };
    const reversed = [_]Osc8Range{ first[1], first[0] };
    var first_storage: [4]Match = undefined;
    var second_storage: [4]Match = undefined;
    const a = try detectRow(row, &first, &first_storage, .{});
    const b = try detectRow(row, &reversed, &second_storage, .{});

    try std.testing.expectEqual(@as(usize, 1), a.matches.len);
    try std.testing.expectEqual(@as(usize, 1), b.matches.len);
    try std.testing.expectEqualStrings(a.matches[0].text, b.matches[0].text);
    switch (a.matches[0].target) {
        .url => |url| try std.testing.expectEqualStrings("https://first.test", url),
        .file => return error.ExpectedUrl,
    }

    const partial = [_]Osc8Range{.{
        .span = .{ .start = 8, .end = 15 },
        .uri = "not-a-url",
    }};
    const masked = try detectRow(row, &partial, &first_storage, .{});
    try std.testing.expectEqual(@as(usize, 0), masked.matches.len);
}

test "truncation retains a deterministic visual prefix" {
    const row = "a.zig:1 b.zig:2 c.zig:3 d.zig:4";
    var small_storage: [2]Match = undefined;
    var repeat_storage: [2]Match = undefined;
    var full_storage: [4]Match = undefined;
    const small = try detectRow(row, &.{}, &small_storage, .{});
    const repeated = try detectRow(row, &.{}, &repeat_storage, .{});
    const full = try detectRow(row, &.{}, &full_storage, .{});

    try std.testing.expect(small.truncated);
    try std.testing.expect(repeated.truncated);
    try std.testing.expect(!full.truncated);
    try std.testing.expectEqual(@as(usize, 2), small.matches.len);
    try std.testing.expectEqual(@as(usize, 4), full.matches.len);
    for (small.matches, repeated.matches, full.matches[0..2]) |a, b, c| {
        try std.testing.expectEqualStrings(a.text, b.text);
        try std.testing.expectEqualStrings(a.text, c.text);
        try std.testing.expectEqual(a.span, b.span);
        try std.testing.expectEqual(a.span, c.span);
    }

    var none: [0]Match = .{};
    const zero = try detectRow(row, &.{}, &none, .{});
    try std.testing.expectEqual(@as(usize, 0), zero.matches.len);
    try std.testing.expect(zero.truncated);
}

test "invalid rows and malformed OSC 8 ranges are rejected or ignored atomically" {
    var storage: [2]Match = undefined;
    try std.testing.expectError(error.InvalidUtf8, detectRow(&.{ 0xff, 'x' }, &.{}, &storage, .{}));

    const row = "src/main.zig:3";
    const malformed = [_]Osc8Range{
        .{ .span = .{ .start = 9, .end = 2 }, .uri = "https://ignored.test" },
        .{ .span = .{ .start = 0, .end = row.len + 1 }, .uri = "https://ignored.test" },
    };
    const found = try detectRow(row, &malformed, &storage, .{});
    try std.testing.expectEqual(@as(usize, 1), found.matches.len);
    try std.testing.expectEqualStrings(row, found.matches[0].text);

    const unicode_row = "é src/main.zig:3";
    const split_scalar = [_]Osc8Range{.{
        .span = .{ .start = 1, .end = 2 },
        .uri = "https://ignored.test",
    }};
    const boundary = try detectRow(unicode_row, &split_scalar, &storage, .{});
    try std.testing.expectEqual(@as(usize, 1), boundary.matches.len);
    try std.testing.expectEqualStrings("src/main.zig:3", boundary.matches[0].text);
}
