//! Allocation-bounded command-palette search and key-chord presentation.
//!
//! This module owns no UI and dispatches no actions. It borrows the action
//! registry's definitions, retains only result indices and recency counters,
//! and allocates all of its search storage during `Model.init`.

const std = @import("std");
const input = @import("input");

const Allocator = std.mem.Allocator;

/// A bounded command-palette result set over borrowed action definitions.
///
/// `definitions`, their strings, and their palette metadata must outlive the
/// model. Refreshing, navigation, and recency updates allocate nothing.
pub const Model = struct {
    allocator: Allocator,
    definitions: []const input.ActionDefinition,
    recency: []u64,
    result_indices: []usize,
    result_scores: []i64,
    result_count: usize = 0,
    selected_result: ?usize = null,
    recency_clock: u64 = 0,
    query_empty: bool = true,

    /// Allocate fixed-capacity search and recency storage for `definitions`.
    pub fn init(allocator: Allocator, definitions: []const input.ActionDefinition) Allocator.Error!Model {
        const recency = try allocator.alloc(u64, definitions.len);
        errdefer allocator.free(recency);
        @memset(recency, 0);

        const result_indices = try allocator.alloc(usize, definitions.len);
        errdefer allocator.free(result_indices);
        const result_scores = try allocator.alloc(i64, definitions.len);
        errdefer allocator.free(result_scores);

        return .{
            .allocator = allocator,
            .definitions = definitions,
            .recency = recency,
            .result_indices = result_indices,
            .result_scores = result_scores,
        };
    }

    /// Release the fixed storage. Borrowed definitions are not released.
    pub fn deinit(self: *Model) void {
        self.allocator.free(self.result_scores);
        self.allocator.free(self.result_indices);
        self.allocator.free(self.recency);
        self.* = undefined;
    }

    /// Rebuild the retained result indices for `query` without allocating.
    ///
    /// Empty queries rank most-recently-used actions first and use registration
    /// order for ties. Non-empty queries rank their best label/name fuzzy score
    /// first and use registration order for ties. The selected definition is
    /// preserved when it still matches; otherwise selection resets to first.
    pub fn refresh(self: *Model, query: []const u8) void {
        const previously_selected = self.selectedDefinitionIndex();
        self.result_count = 0;
        self.query_empty = query.len == 0;

        for (self.definitions, 0..) |definition, definition_index| {
            if (definition.palette == null) continue;
            const score: i64 = if (self.query_empty)
                0
            else
                bestFuzzyScore(query, definition) orelse continue;
            self.insertResult(definition_index, score);
        }

        self.selected_result = null;
        if (previously_selected) |definition_index| {
            for (self.result_indices[0..self.result_count], 0..) |candidate, result_index| {
                if (candidate == definition_index) {
                    self.selected_result = result_index;
                    break;
                }
            }
        }
        if (self.selected_result == null and self.result_count != 0) self.selected_result = 0;
    }

    /// Current definition indices, in palette display order.
    pub fn results(self: *const Model) []const usize {
        return self.result_indices[0..self.result_count];
    }

    /// The definition index for one display result, or `null` out of bounds.
    pub fn definitionIndexAt(self: *const Model, result_index: usize) ?usize {
        if (result_index >= self.result_count) return null;
        return self.result_indices[result_index];
    }

    /// The borrowed definition for one display result, or `null` out of bounds.
    pub fn definitionAt(self: *const Model, result_index: usize) ?*const input.ActionDefinition {
        const definition_index = self.definitionIndexAt(result_index) orelse return null;
        return &self.definitions[definition_index];
    }

    /// The selected position within `results`, or `null` when there are none.
    pub fn selectedResultIndex(self: *const Model) ?usize {
        return self.selected_result;
    }

    /// The selected index within the registered definitions.
    pub fn selectedDefinitionIndex(self: *const Model) ?usize {
        const result_index = self.selected_result orelse return null;
        return self.definitionIndexAt(result_index);
    }

    /// The selected borrowed definition.
    pub fn selectedDefinition(self: *const Model) ?*const input.ActionDefinition {
        const definition_index = self.selectedDefinitionIndex() orelse return null;
        return &self.definitions[definition_index];
    }

    /// Select the first ranked result, or clear selection when none match.
    pub fn selectFirst(self: *Model) void {
        self.selected_result = if (self.result_count == 0) null else 0;
    }

    /// Select the next result, wrapping from last to first.
    pub fn selectNext(self: *Model) void {
        if (self.result_count == 0) {
            self.selected_result = null;
            return;
        }
        const current = self.selected_result orelse 0;
        self.selected_result = (current + 1) % self.result_count;
    }

    /// Select the previous result, wrapping from first to last.
    pub fn selectPrevious(self: *Model) void {
        if (self.result_count == 0) {
            self.selected_result = null;
            return;
        }
        const current = self.selected_result orelse 0;
        self.selected_result = if (current == 0) self.result_count - 1 else current - 1;
    }

    /// Record an exact action name as most recently used.
    ///
    /// Returns false for an unknown name. An empty result set is refreshed in
    /// place when its last query was empty so MRU order is immediately visible.
    pub fn noteUsed(self: *Model, action_name: []const u8) bool {
        for (self.definitions, 0..) |definition, index| {
            if (!std.mem.eql(u8, definition.name, action_name)) continue;
            if (self.recency_clock == std.math.maxInt(u64)) {
                // This path needs roughly 584 years at one billion commands a
                // second. Halving preserves useful order without allocating.
                for (self.recency) |*value| value.* /= 2;
                self.recency_clock /= 2;
            }
            self.recency_clock += 1;
            self.recency[index] = self.recency_clock;
            if (self.query_empty) self.refresh("");
            return true;
        }
        return false;
    }

    fn insertResult(self: *Model, definition_index: usize, score: i64) void {
        var insertion = self.result_count;
        while (insertion != 0) {
            const previous = insertion - 1;
            if (!self.before(
                definition_index,
                score,
                self.result_indices[previous],
                self.result_scores[previous],
            )) break;
            self.result_indices[insertion] = self.result_indices[previous];
            self.result_scores[insertion] = self.result_scores[previous];
            insertion = previous;
        }
        self.result_indices[insertion] = definition_index;
        self.result_scores[insertion] = score;
        self.result_count += 1;
    }

    fn before(
        self: *const Model,
        candidate_index: usize,
        candidate_score: i64,
        existing_index: usize,
        existing_score: i64,
    ) bool {
        if (self.query_empty) {
            const candidate_recency = self.recency[candidate_index];
            const existing_recency = self.recency[existing_index];
            if (candidate_recency != existing_recency) return candidate_recency > existing_recency;
        } else if (candidate_score != existing_score) {
            return candidate_score > existing_score;
        }
        return candidate_index < existing_index;
    }
};

fn bestFuzzyScore(query: []const u8, definition: input.ActionDefinition) ?i64 {
    const label_score = fuzzyScore(query, definition.label);
    const name_score = fuzzyScore(query, definition.name);
    if (label_score) |label| {
        if (name_score) |name| return @max(label, name);
        return label;
    }
    return name_score;
}

/// Score an ASCII-case-insensitive subsequence. UTF-8 bytes outside ASCII are
/// matched exactly, which keeps matching allocation-free and never splits or
/// rewrites borrowed metadata.
fn fuzzyScore(query: []const u8, candidate: []const u8) ?i64 {
    if (query.len == 0) return 0;

    var query_index: usize = 0;
    var last_match: ?usize = null;
    var score: i64 = 0;
    for (candidate, 0..) |byte, candidate_index| {
        if (foldAscii(byte) != foldAscii(query[query_index])) continue;

        score += 32;
        if (isWordBoundary(candidate, candidate_index)) score += 24;
        if (last_match) |previous| {
            if (candidate_index == previous + 1) {
                score += 36;
            } else {
                score -= clampUsizeToI64(candidate_index - previous - 1, 24);
            }
        } else {
            score -= clampUsizeToI64(candidate_index, 24);
        }

        last_match = candidate_index;
        query_index += 1;
        if (query_index == query.len) {
            // Prefer the more compact candidate after its match-quality bonuses.
            score -= clampUsizeToI64(candidate.len - query.len, 32);
            return score;
        }
    }
    return null;
}

fn foldAscii(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

fn isWordBoundary(text: []const u8, index: usize) bool {
    if (index == 0) return true;
    const previous = text[index - 1];
    const current = text[index];
    return !std.ascii.isAlphanumeric(previous) or
        (std.ascii.isLower(previous) and std.ascii.isUpper(current));
}

fn clampUsizeToI64(value: usize, maximum: i64) i64 {
    return @intCast(@min(value, @as(usize, @intCast(maximum))));
}

/// Result of formatting every binding for one action into caller storage.
pub const FormatResult = struct {
    text: []const u8,
    /// At least one whole matching chord did not fit.
    truncated: bool,
};

/// Format matching chords in binding order, separated by `, `.
///
/// No allocation occurs. If the next complete chord and its separator do not
/// fit, neither is written and `truncated` is set. Super is displayed as `Cmd`
/// on macOS and `Super` elsewhere.
pub fn formatActionBindings(
    buffer: []u8,
    action_name: []const u8,
    bindings: []const input.Binding,
    profile: input.PlatformProfile,
) FormatResult {
    var used: usize = 0;
    var wrote_one = false;
    for (bindings) |binding| {
        if (!std.mem.eql(u8, binding.action, action_name)) continue;

        var chord_storage: [64]u8 = undefined;
        const chord = formatChord(&chord_storage, binding.chord, profile);
        const separator_len: usize = if (wrote_one) 2 else 0;
        if (separator_len + chord.len > buffer.len - used) {
            return .{ .text = buffer[0..used], .truncated = true };
        }
        if (wrote_one) {
            @memcpy(buffer[used..][0..2], ", ");
            used += 2;
        }
        @memcpy(buffer[used..][0..chord.len], chord);
        used += chord.len;
        wrote_one = true;
    }
    return .{ .text = buffer[0..used], .truncated = false };
}

fn formatChord(storage: *[64]u8, chord: input.Chord, profile: input.PlatformProfile) []const u8 {
    var used: usize = 0;
    const modifiers = chord.modifiers.normalized();
    if (modifiers.ctrl) appendLiteral(storage, &used, "Ctrl+");
    if (modifiers.alt) appendLiteral(storage, &used, "Alt+");
    if (modifiers.super) appendLiteral(storage, &used, if (profile == .macos) "Cmd+" else "Super+");
    if (modifiers.shift) appendLiteral(storage, &used, "Shift+");

    switch (chord.key) {
        .named => |named| appendLiteral(storage, &used, namedText(named)),
        .character => |codepoint| {
            if (codepoint >= 'a' and codepoint <= 'z') {
                storage[used] = @intCast(codepoint - ('a' - 'A'));
                used += 1;
            } else if (codepoint >= 0x20 and codepoint <= 0x7e) {
                storage[used] = @intCast(codepoint);
                used += 1;
            } else {
                const rendered = std.fmt.bufPrint(storage[used..], "U+{X:0>4}", .{codepoint}) catch return storage[0..used];
                used += rendered.len;
            }
        },
    }
    return storage[0..used];
}

fn appendLiteral(storage: *[64]u8, used: *usize, text: []const u8) void {
    @memcpy(storage[used.*..][0..text.len], text);
    used.* += text.len;
}

fn namedText(named: input.Named) []const u8 {
    return switch (named) {
        .enter => "Enter",
        .tab => "Tab",
        .backspace => "Backspace",
        .escape => "Esc",
        .insert => "Insert",
        .delete => "Delete",
        .up => "Up",
        .down => "Down",
        .left => "Left",
        .right => "Right",
        .home => "Home",
        .end => "End",
        .page_up => "PageUp",
        .page_down => "PageDown",
        .f1 => "F1",
        .f2 => "F2",
        .f3 => "F3",
        .f4 => "F4",
        .f5 => "F5",
        .f6 => "F6",
        .f7 => "F7",
        .f8 => "F8",
        .f9 => "F9",
        .f10 => "F10",
        .f11 => "F11",
        .f12 => "F12",
    };
}

fn testHandler(_: *anyopaque, _: input.Invocation) anyerror!void {}

fn testDefinition(name: []const u8, label: []const u8) input.ActionDefinition {
    return .{ .name = name, .label = label, .handler = testHandler };
}

test "empty query ranks visible actions by MRU then registration order" {
    const definitions = [_]input.ActionDefinition{
        testDefinition("workspace.open", "Open Workspace"),
        testDefinition("workspace.close", "Close Workspace"),
        .{ .name = "internal.hidden", .label = "Hidden", .handler = testHandler, .palette = null },
        testDefinition("pane.split", "Split Pane"),
    };
    var model = try Model.init(std.testing.allocator, &definitions);
    defer model.deinit();

    model.refresh("");
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 3 }, model.results());
    try std.testing.expect(model.noteUsed("workspace.close"));
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 3 }, model.results());
    try std.testing.expect(model.noteUsed("workspace.open"));
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 3 }, model.results());
    try std.testing.expect(!model.noteUsed("unknown"));
}

test "fuzzy search matches label and stable name case insensitively" {
    const definitions = [_]input.ActionDefinition{
        testDefinition("workspace.new", "Create Project"),
        testDefinition("pane.split-right", "Divide Terminal"),
        testDefinition("tab.close", "Close Tab"),
    };
    var model = try Model.init(std.testing.allocator, &definitions);
    defer model.deinit();

    model.refresh("cpr");
    try std.testing.expectEqual(@as(usize, 1), model.results().len);
    try std.testing.expectEqualStrings("Create Project", model.selectedDefinition().?.label);

    model.refresh("PANE.SR");
    try std.testing.expectEqual(@as(usize, 1), model.results().len);
    try std.testing.expectEqualStrings("pane.split-right", model.selectedDefinition().?.name);
}

test "fuzzy scoring rewards consecutive compact and word-boundary matches" {
    const definitions = [_]input.ActionDefinition{
        testDefinition("scattered", "A very distant B"),
        testDefinition("consecutive", "AB Tool"),
        testDefinition("inside", "Toolbar"),
        testDefinition("boundary", "Tool Box"),
    };
    var model = try Model.init(std.testing.allocator, &definitions);
    defer model.deinit();

    model.refresh("ab");
    try std.testing.expectEqual(@as(usize, 1), model.results()[0]);
    model.refresh("tb");
    try std.testing.expectEqual(@as(usize, 3), model.results()[0]);
}

test "fuzzy ties retain registration order and no match clears selection" {
    const definitions = [_]input.ActionDefinition{
        testDefinition("one", "Alpha"),
        testDefinition("two", "Alpha"),
    };
    var model = try Model.init(std.testing.allocator, &definitions);
    defer model.deinit();

    model.refresh("alp");
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, model.results());
    model.refresh("zzz");
    try std.testing.expectEqual(@as(usize, 0), model.results().len);
    try std.testing.expect(model.selectedResultIndex() == null);
    try std.testing.expect(model.selectedDefinition() == null);
}

test "selection survives matching refresh resets when removed and wraps" {
    const definitions = [_]input.ActionDefinition{
        testDefinition("apple", "Apple"),
        testDefinition("apricot", "Apricot"),
        testDefinition("banana", "Banana"),
    };
    var model = try Model.init(std.testing.allocator, &definitions);
    defer model.deinit();

    model.refresh("a");
    model.selectNext();
    try std.testing.expectEqual(@as(usize, 1), model.selectedDefinitionIndex().?);
    model.refresh("ap");
    try std.testing.expectEqual(@as(usize, 1), model.selectedDefinitionIndex().?);
    model.refresh("app");
    try std.testing.expectEqual(@as(usize, 0), model.selectedResultIndex().?);
    try std.testing.expectEqual(@as(usize, 0), model.selectedDefinitionIndex().?);
    model.selectPrevious();
    try std.testing.expectEqual(@as(usize, 0), model.selectedDefinitionIndex().?);

    model.refresh("");
    model.selectPrevious();
    try std.testing.expectEqual(@as(usize, 2), model.selectedResultIndex().?);
    model.selectNext();
    try std.testing.expectEqual(@as(usize, 0), model.selectedResultIndex().?);
    model.selectNext();
    model.selectFirst();
    try std.testing.expectEqual(@as(usize, 0), model.selectedResultIndex().?);
    try std.testing.expect(model.definitionAt(99) == null);
}

test "binding formatting uses platform names and binding order" {
    const bindings = [_]input.Binding{
        .{ .chord = .{ .key = .{ .character = 'p' }, .modifiers = .{ .ctrl = true, .shift = true } }, .action = "palette.toggle" },
        .{ .chord = .{ .key = .{ .named = .left }, .modifiers = .{ .alt = true } }, .action = "palette.toggle" },
        .{ .chord = .{ .key = .{ .character = 'x' } }, .action = "other" },
        .{ .chord = .{ .key = .{ .character = 'p' }, .modifiers = .{ .shift = true, .super = true } }, .action = "palette.macos" },
    };
    var storage: [64]u8 = undefined;

    const multiple = formatActionBindings(&storage, "palette.toggle", &bindings, .linux_windows);
    try std.testing.expectEqualStrings("Ctrl+Shift+P, Alt+Left", multiple.text);
    try std.testing.expect(!multiple.truncated);

    const macos = formatActionBindings(&storage, "palette.macos", &bindings, .macos);
    try std.testing.expectEqualStrings("Cmd+Shift+P", macos.text);
    try std.testing.expect(!macos.truncated);
}

test "binding formatting truncates only at whole chord boundaries" {
    const bindings = [_]input.Binding{
        .{ .chord = .{ .key = .{ .character = 'p' }, .modifiers = .{ .ctrl = true, .shift = true } }, .action = "palette.toggle" },
        .{ .chord = .{ .key = .{ .named = .left }, .modifiers = .{ .alt = true } }, .action = "palette.toggle" },
    };
    var first_only: [12]u8 = undefined;
    const partial = formatActionBindings(&first_only, "palette.toggle", &bindings, .linux_windows);
    try std.testing.expectEqualStrings("Ctrl+Shift+P", partial.text);
    try std.testing.expect(partial.truncated);

    var too_small: [11]u8 = undefined;
    const empty = formatActionBindings(&too_small, "palette.toggle", &bindings, .linux_windows);
    try std.testing.expectEqualStrings("", empty.text);
    try std.testing.expect(empty.truncated);

    var unused: [1]u8 = undefined;
    const none = formatActionBindings(&unused, "missing", &bindings, .linux_windows);
    try std.testing.expectEqualStrings("", none.text);
    try std.testing.expect(!none.truncated);
}
