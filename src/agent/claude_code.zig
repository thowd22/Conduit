//! The Claude Code adapter (TASK-53, decision-7, doc-3).
//!
//! Claude Code's TUI always runs in a Conduit PTY. This adapter adds its
//! structured side channels on top:
//!
//! * **Hooks** (live status, permission prompts, subagents). `launch` writes a
//!   per-agent *sink* directory — a `settings.json` passed with `--settings`
//!   and a POSIX `hook.sh` relay — and pins the session id with
//!   `--session-id`. Every registered hook runs `/bin/sh <sink>/hook.sh
//!   <Event>`, which wraps the hook's stdin JSON as one line,
//!   `{"conduit":{"v":1,"event":…,"token":…},"payload":<hook input>}`, and
//!   appends it to `<sink>/events.jsonl`. `poll` tails that file. This is the
//!   interim transport until TASK-60's control endpoint; the line format is
//!   the only contract between the script and this file.
//! * **Permission replies.** The `PermissionRequest` hook appends its request
//!   (with a request id the script chose) and then waits, bounded, for
//!   `<sink>/decisions/<id>` to say `allow` or `deny`, which
//!   `respondPermission` writes. The script then prints the reply Claude Code
//!   reads, `{"hookSpecificOutput":{"hookEventName":"PermissionRequest",
//!   "decision":{"behavior":"allow"|"deny"}}}` (the documented shape, hooks
//!   reference), and appends a synthetic `PermissionEnd` line with the
//!   outcome. Claude Code shows its own dialog in parallel (doc-3, probe 2);
//!   when the human answers there first the hook is cancelled, which the
//!   script reports as `aborted`, and a later `PostToolUse`, `Stop` or new
//!   prompt resolves anything still pending as resolved elsewhere.
//! * **Transcript** (`TranscriptReader`). The session JSONL named by the
//!   hooks' `transcript_path` (or found under `<config>/projects/` for an
//!   attached session) yields user and assistant messages and, when no hook
//!   channel reports them, tool uses and file references. The format is
//!   internal to Claude Code and parsed tolerantly; unknown records are
//!   skipped.
//! * **Session registry** (`findRunningSession`). Claude Code 2.1.x keeps an
//!   undocumented `<config>/sessions/<pid>.json` per running interactive
//!   session with `sessionId`, `cwd` and `status` (`busy`, `waiting`,
//!   `idle`), removed on exit. It is the best-effort way to recognise a
//!   `claude` the human started by hand in a Conduit terminal, and the live
//!   status of such an attached session; it is never the only source of a
//!   permission state.
//!
//! Hook → event mapping (verified against Claude Code 2.1.292 hook inputs):
//!   SessionStart (startup, resume, clear)  → status idle (`compact` → none)
//!   UserPromptSubmit                       → status working
//!   PreToolUse                             → status working, tool_use, file refs
//!   PermissionRequest                      → permission_request (allow / deny)
//!   PermissionEnd (synthetic)              → permission_resolved
//!   PostToolUse, PostToolUseFailure        → status working
//!   Notification                           → notification (+ waiting_input for
//!                                            agent_needs_input / elicitation)
//!   Stop                                   → status done (a finished turn)
//!   StopFailure                            → status errored + notification
//!   SubagentStart / SubagentStop           → subagent start / stop
//!   InstructionsLoaded                     → file_reference to the loaded file
//!   SessionEnd                             → exited, for observed sessions only
//! `Stop` maps to `done`, not `idle`: `done` is "the last turn completed"
//! (state.zig), and the next prompt moves it back to `working`. A launched
//! (owned) agent's exit comes from its PTY child, which carries the real
//! status; only an observed session, whose process is not a Conduit child,
//! takes `exited` from `SessionEnd`.
//!
//! Capabilities: detect, launch, attach, poll, structured status and
//! transcript always; respond_permission, permission_requests and subagents
//! only with a sink (hooks). `send_input` is unsupported because the TUI owns
//! its input and the human types into the PTY; `read_prompt`/`update_prompt`
//! are TASK-59; `stop` is unsupported because the owner ends an owned agent by
//! signalling its PTY child and Conduit never ends a human's own process.
//! Headless launch (`claude -p` stream-json with `--permission-prompt-tool
//! stdio`) needs a stream-json client this adapter does not have yet, so it
//! is refused as unsupported.
//!
//! Safety: hook payloads, transcript records and registry files are untrusted
//! harness data. Nothing here acts on them: they become display events, and
//! the only path that answers a permission is `respondPermission`, called
//! from a user gesture. Identifiers that reach the file system (request ids,
//! session ids) are validated to a fixed alphabet first, and a transcript
//! path a hook reports is followed only inside Claude's own projects
//! directory. Payload text is never logged; debug logs carry structure only.
//!
//! Remote contexts (TASK-61): detection spawns through the workspace
//! ExecutionContext, and every sink, transcript and registry access goes
//! through `Options.sink_io` (`sink_io.zig`): this machine's files for a Local
//! workspace, the workspace's context for an SSH one. In an SSH workspace the
//! sink directory is a path on the remote host, so `launch` writes the relay
//! and settings there, the remote `claude` runs `/bin/sh <sink>/hook.sh`
//! there, and `poll` tails the remote `events.jsonl` over the connection; the
//! relay is plain POSIX sh and needs nothing else on the host.
//!
//! Threads: every method but `harness` and `capabilities` runs on one IO
//! worker at a time (adapter.zig). Memory: the adapter owns copies of its
//! option paths, one line buffer per tail and a per-line JSON arena, all from
//! the allocator given to `init` and released by `deinit`.

const std = @import("std");
const api = @import("adapter.zig");
const event = @import("event.zig");
const state_model = @import("state.zig");
const Harness = @import("harness.zig").Harness;
const sink_io = @import("sink_io.zig");
const workspace = @import("workspace");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;
const SinkIo = sink_io.SinkIo;
const Value = std.json.Value;
const Event = event.Event;
const State = state_model.State;

const log = std.log.scoped(.agent_claude);

// Limits ---------------------------------------------------------------------

/// The hook relay copies at most this much of a hook's input; a larger input
/// is reported as an empty payload rather than a truncated, unparsable one.
pub const max_hook_payload_bytes = 1024 * 1024;
/// The longest hook line `poll` accepts: the payload plus the wrapper.
pub const max_hook_line_bytes = max_hook_payload_bytes + 1024;
/// The longest transcript record kept. Longer records (large tool results)
/// are skipped whole.
pub const max_transcript_line_bytes = 1024 * 1024;
/// Lines one `poll` consumes from one file, so a backlog of history cannot
/// monopolise the worker.
pub const max_lines_per_poll = 256;
/// Bytes one `poll` reads from one file.
pub const max_bytes_per_poll = 4 * 1024 * 1024;
/// The most events one hook line or transcript record yields.
pub const max_events_per_record = 16;
/// Tool summaries and permission titles are one display line at most this
/// long; message text is bounded by the event store itself.
pub const max_summary_bytes = 512;
pub const max_message_bytes = event.stored_text_capacity;
pub const max_notification_bytes = 1024;
/// The longest sink directory path accepted, leaving room for the files
/// inside it in fixed buffers.
pub const max_sink_path_bytes = 1024;
/// How long the permission hook waits for an answer: 2900 polls of 0.2 s,
/// under the 600 s hook timeout it is registered with.
pub const permission_wait_polls = 2900;
pub const permission_hook_timeout_s = 600;
pub const hook_timeout_s = 30;
/// A registry file is a few hundred bytes; anything past this is not one.
const max_registry_file_bytes = 64 * 1024;
/// Directory entries one registry or projects scan looks at.
const max_scan_entries = 4096;
/// The `--version` probe: at most this many bounded waits of `probe_wait_ms`.
const probe_wait_rounds = 50;
const probe_wait_ms = 100;

// Identifiers ----------------------------------------------------------------

/// A Claude Code session id: a UUID in its 36-character text form. Validated
/// before it is ever used in a path.
pub const SessionId = struct {
    pub const len = 36;
    bytes: [len]u8,

    pub fn parse(reported: []const u8) ?SessionId {
        if (reported.len != len) return null;
        var id: SessionId = undefined;
        for (reported, 0..) |c, i| {
            const dash = i == 8 or i == 13 or i == 18 or i == 23;
            if (dash) {
                if (c != '-') return null;
            } else if (!std.ascii.isHex(c)) return null;
            id.bytes[i] = std.ascii.toLower(c);
        }
        return id;
    }

    /// A version-4 UUID made from the agent's correlation token, so the
    /// session id Conduit pins with `--session-id` needs no entropy of its
    /// own and is unique per agent.
    pub fn fromToken(token: api.CorrelationToken) SessionId {
        var raw: [16]u8 = undefined;
        // The token text is 32 lowercase hex digits by construction.
        _ = std.fmt.hexToBytes(&raw, token.text()) catch unreachable;
        raw[6] = (raw[6] & 0x0f) | 0x40;
        raw[8] = (raw[8] & 0x3f) | 0x80;
        const hex = std.fmt.bytesToHex(raw, .lower);
        var id: SessionId = undefined;
        @memcpy(id.bytes[0..8], hex[0..8]);
        id.bytes[8] = '-';
        @memcpy(id.bytes[9..13], hex[8..12]);
        id.bytes[13] = '-';
        @memcpy(id.bytes[14..18], hex[12..16]);
        id.bytes[18] = '-';
        @memcpy(id.bytes[19..23], hex[16..20]);
        id.bytes[23] = '-';
        @memcpy(id.bytes[24..36], hex[20..32]);
        return id;
    }

    pub fn text(self: *const SessionId) []const u8 {
        return &self.bytes;
    }

    pub fn eql(a: SessionId, b: SessionId) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

/// Request ids are chosen by the hook relay as `<pid>-<epoch seconds>`; only
/// digits and one inner dash are accepted, so an id is always a safe file
/// name inside `decisions/`.
pub fn isRequestId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    var dashes: usize = 0;
    for (id, 0..) |c, i| switch (c) {
        '0'...'9' => {},
        '-' => {
            if (i == 0 or i == id.len - 1) return false;
            dashes += 1;
        },
        else => return false,
    };
    return dashes == 1;
}

/// A sink path must be absolute and safe to embed in single quotes in a
/// POSIX shell command and in JSON without surprises.
pub fn isValidSinkPath(path: []const u8) bool {
    if (path.len < 2 or path.len > max_sink_path_bytes or path[0] != '/') return false;
    if (path[path.len - 1] == '/') return false;
    for (path) |c| {
        if (c < 0x20 or c == 0x7f or c == '\'' or c == '\\') return false;
    }
    return true;
}

/// A bounded inline identifier.
fn Ident(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        fn set(self: *Self, value: []const u8) bool {
            if (value.len > capacity) return false;
            @memcpy(self.bytes[0..value.len], value);
            self.len = value.len;
            return true;
        }

        fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

// Sink files -----------------------------------------------------------------

/// The hook events Conduit registers, in settings order, with the name
/// Claude Code uses. `permission_end` is the relay's own synthetic event.
pub const Hook = enum {
    session_start,
    instructions_loaded,
    user_prompt_submit,
    pre_tool_use,
    permission_request,
    post_tool_use,
    post_tool_use_failure,
    notification,
    subagent_start,
    subagent_stop,
    stop,
    stop_failure,
    session_end,
    permission_end,

    pub const registered = [_]Hook{
        .session_start,      .instructions_loaded, .user_prompt_submit,    .pre_tool_use,
        .permission_request, .post_tool_use,       .post_tool_use_failure, .notification,
        .subagent_start,     .subagent_stop,       .stop,                  .stop_failure,
        .session_end,
    };

    pub fn name(self: Hook) []const u8 {
        return switch (self) {
            .session_start => "SessionStart",
            .instructions_loaded => "InstructionsLoaded",
            .user_prompt_submit => "UserPromptSubmit",
            .pre_tool_use => "PreToolUse",
            .permission_request => "PermissionRequest",
            .post_tool_use => "PostToolUse",
            .post_tool_use_failure => "PostToolUseFailure",
            .notification => "Notification",
            .subagent_start => "SubagentStart",
            .subagent_stop => "SubagentStop",
            .stop => "Stop",
            .stop_failure => "StopFailure",
            .session_end => "SessionEnd",
            .permission_end => "PermissionEnd",
        };
    }

    pub fn parse(text: []const u8) ?Hook {
        inline for (@typeInfo(Hook).@"enum".fields) |f| {
            const hook: Hook = @enumFromInt(f.value);
            if (std.mem.eql(u8, text, hook.name())) return hook;
        }
        return null;
    }

    pub fn timeoutSeconds(self: Hook) u32 {
        return if (self == .permission_request) permission_hook_timeout_s else hook_timeout_s;
    }
};

/// The shell command a hook entry runs. `sink` must satisfy
/// `isValidSinkPath`, so single quotes cannot be broken out of.
pub fn writeHookCommand(writer: *Io.Writer, sink: []const u8, hook: Hook) Io.Writer.Error!void {
    try writer.print("/bin/sh '{s}/hook.sh' {s}", .{ sink, hook.name() });
}

/// The hook command when Conduit's control endpoint is up (TASK-60): every
/// hook but `PermissionRequest` runs `conduit control agent.event` with the
/// hook name, which wraps stdin exactly as the relay would and sends it over
/// the endpoint, falling back to the sink when the endpoint does not answer.
/// `PermissionRequest` keeps the relay, whose answer comes back through
/// `decisions/`. `helper` must satisfy `isValidSinkPath` (absolute, quotable).
pub fn writeHookCommandVia(writer: *Io.Writer, sink: []const u8, helper: ?[]const u8, hook: Hook) Io.Writer.Error!void {
    const program = helper orelse return writeHookCommand(writer, sink, hook);
    if (hook == .permission_request) return writeHookCommand(writer, sink, hook);
    try writer.print("'{s}' control agent.event --event={s}", .{ program, hook.name() });
}

/// The `--settings` file: one command hook per registered event, no matcher
/// (every tool), each running the relay.
pub fn writeSettings(writer: *Io.Writer, sink: []const u8) Io.Writer.Error!void {
    return writeSettingsVia(writer, sink, null);
}

/// `writeSettings` with `writeHookCommandVia`'s command choice.
pub fn writeSettingsVia(writer: *Io.Writer, sink: []const u8, helper: ?[]const u8) Io.Writer.Error!void {
    var command_buffer: [2 * max_sink_path_bytes + 64]u8 = undefined;
    try writer.writeAll("{\"hooks\":{");
    for (Hook.registered, 0..) |hook, i| {
        if (i != 0) try writer.writeByte(',');
        var command: Io.Writer = .fixed(&command_buffer);
        try writeHookCommandVia(&command, sink, helper, hook);
        try writer.print("\"{s}\":[{{\"hooks\":[{{\"type\":\"command\",\"command\":", .{hook.name()});
        try std.json.Stringify.encodeJsonString(command.buffered(), .{}, writer);
        try writer.print(",\"timeout\":{d}}}]}}]", .{hook.timeoutSeconds()});
    }
    try writer.writeAll("}}\n");
}

const hook_script_head =
    \\#!/bin/sh
    \\# Conduit's Claude Code hook relay, generated for one agent (TASK-53).
    \\# Appends each hook's input, wrapped, as one line to events.jsonl. For
    \\# PermissionRequest it then waits for Conduit's answer in decisions/.
    \\# It runs nothing from the payload.
    \\umask 077
    \\sink='
;

const hook_script_tail =
    \\'
    \\event=${1:-}
    \\case "$event" in ''|*[!A-Za-z]*) exit 0 ;; esac
    \\token=$(printf '%s' "${CONDUIT_AGENT_TOKEN:-}" | tr -cd '0-9a-f' | cut -c1-32)
    \\scratch="$sink/tmp/$$"
    \\emit() {
    \\  { printf '{"conduit":{"v":1,"event":"%s","token":"%s"%s},"payload":' "$event" "$token" "$1"
    \\    tr '\r\n' '  ' < "$2"
    \\    printf '}\n'
    \\  } > "$scratch.line" && cat "$scratch.line" >> "$sink/events.jsonl"
    \\  rm -f "$scratch.line"
    \\}
    \\head -c 1048577 > "$scratch.in"
    \\size=$(wc -c < "$scratch.in")
    \\if [ "$size" -eq 0 ] || [ "$size" -gt 1048576 ]; then printf '{}' > "$scratch.in"; fi
    \\if [ "$event" != PermissionRequest ]; then
    \\  emit '' "$scratch.in"
    \\  rm -f "$scratch.in"
    \\  exit 0
    \\fi
    \\if [ "$size" -gt 1048576 ]; then rm -f "$scratch.in"; exit 0; fi
    \\request="$$-$(date +%s)"
    \\answer="$sink/decisions/$request"
    \\rm -f "$answer"
    \\emit ",\"request\":\"$request\"" "$scratch.in"
    \\printf '{}' > "$scratch.in"
    \\finish() {
    \\  event=PermissionEnd
    \\  emit ",\"request\":\"$request\",\"outcome\":\"$1\"" "$scratch.in"
    \\  rm -f "$scratch.in" "$answer"
    \\}
    \\trap 'finish aborted; exit 0' HUP INT TERM
    \\outcome=timeout
    \\tries=0
    \\while [ "$tries" -lt 2900 ]; do
    \\  if [ -f "$answer" ]; then
    \\    case "$(head -c 8 "$answer")" in
    \\      allow) outcome=allow; break ;;
    \\      deny) outcome=deny; break ;;
    \\    esac
    \\  fi
    \\  sleep 0.2
    \\  tries=$((tries + 1))
    \\done
    \\trap - HUP INT TERM
    \\finish "$outcome"
    \\case "$outcome" in
    \\  allow) printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}' ;;
    \\  deny) printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}' ;;
    \\esac
    \\exit 0
    \\
;

comptime {
    // The script's literals must agree with the limits `poll` enforces.
    std.debug.assert(std.mem.indexOf(u8, hook_script_tail, "head -c 1048577") != null);
    std.debug.assert(max_hook_payload_bytes == 1048576);
    std.debug.assert(std.mem.indexOf(u8, hook_script_tail, "-lt 2900") != null);
    std.debug.assert(permission_wait_polls == 2900);
}

/// The relay script for `sink` (which must satisfy `isValidSinkPath`).
pub fn writeHookScript(writer: *Io.Writer, sink: []const u8) Io.Writer.Error!void {
    try writer.writeAll(hook_script_head);
    try writer.writeAll(sink);
    try writer.writeAll(hook_script_tail);
}

/// The relay's reply for an answered permission, as Claude Code reads it.
pub fn permissionReply(answer: Answer) []const u8 {
    return switch (answer) {
        .allow => "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"allow\"}}}",
        .deny => "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"deny\"}}}",
    };
}

/// The two answers the relay understands. Claude Code's hook reply also
/// accepts permission-rule updates ("always allow"), whose exact shape this
/// version was not verified against, so Conduit offers only these two.
pub const Answer = enum { allow, deny };

pub const decisions = [_]event.Decision{
    .{ .id = "allow", .label = "Allow once", .kind = .allow_once },
    .{ .id = "deny", .label = "Reject", .kind = .reject },
};

// JSON helpers ----------------------------------------------------------------

fn parseLine(arena: Allocator, line: []const u8) ?Value {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] != '{') return null;
    const value = std.json.parseFromSliceLeaky(Value, arena, trimmed, .{
        .duplicate_field_behavior = .use_last,
    }) catch return null;
    return if (value == .object) value else null;
}

fn field(value: ?Value, key: []const u8) ?Value {
    const v = value orelse return null;
    return switch (v) {
        .object => |object| object.get(key),
        else => null,
    };
}

fn string(value: ?Value, key: []const u8) ?[]const u8 {
    return switch (field(value, key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn boolean(value: ?Value, key: []const u8) bool {
    return switch (field(value, key) orelse return false) {
        .bool => |b| b,
        else => false,
    };
}

fn integer(value: ?Value, key: []const u8) ?i64 {
    return switch (field(value, key) orelse return null) {
        .integer => |i| i,
        else => null,
    };
}

/// The first line of `text`, bounded for display.
fn displayLine(text: []const u8, limit: usize) []const u8 {
    const end = std.mem.indexOfAny(u8, text, "\r\n") orelse text.len;
    return event.truncateUtf8(text[0..end], limit);
}

/// What a tool use is about, in one line: its command, file, pattern, URL or
/// query, by the field names Claude Code's built-in tools use.
fn toolSummary(input: ?Value) []const u8 {
    const keys = [_][]const u8{ "command", "file_path", "notebook_path", "path", "pattern", "url", "query", "description" };
    for (keys) |key| {
        if (string(input, key)) |s| return displayLine(s, max_summary_bytes);
    }
    return "";
}

/// A file a tool input names, with the starting line `Read` takes.
fn fileReference(input: ?Value) ?event.FileReference {
    const path = string(input, "file_path") orelse string(input, "notebook_path") orelse return null;
    if (path.len == 0 or path.len > event.max_path_bytes) return null;
    var reference: event.FileReference = .{ .path = path };
    if (integer(input, "offset")) |offset| {
        if (offset > 0 and offset <= std.math.maxInt(u32)) reference.line = @intCast(offset);
    }
    return reference;
}

/// The events one record yields, borrowing the record and the arena.
pub const EventBuf = struct {
    items: [max_events_per_record]Event = undefined,
    len: usize = 0,

    fn add(self: *EventBuf, ev: Event) void {
        if (self.len == self.items.len) {
            log.debug("record yielded more than {d} events; the rest are dropped", .{max_events_per_record});
            return;
        }
        self.items[self.len] = ev;
        self.len += 1;
    }

    pub fn slice(self: *const EventBuf) []const Event {
        return self.items[0..self.len];
    }

    fn status(self: *EventBuf, state: State) void {
        self.add(.{ .status_change = .{ .state = state, .source = .structured } });
    }

    fn toolUse(self: *EventBuf, name: []const u8, input: ?Value, with_file: bool) void {
        if (name.len == 0 or name.len > event.max_identifier_bytes) return;
        const summary = toolSummary(input);
        self.add(.{ .tool_use = .{ .name = name, .summary = summary } });
        if (with_file) {
            if (fileReference(input)) |reference| self.add(.{ .file_reference = reference });
        }
    }

    fn message(self: *EventBuf, role: event.Role, text: []const u8) void {
        if (text.len == 0) return;
        const kept = event.truncateUtf8(text, max_message_bytes);
        self.add(.{ .message = .{ .role = role, .text = kept, .truncated = kept.len != text.len } });
    }
};

// Transcript -------------------------------------------------------------------

/// Map one transcript record to events. Messages always; tool uses and the
/// files they name only with `include_tools`, which is off when hooks
/// already report them live. Meta records (local command caveats),
/// sidechain records (a subagent's own conversation), thinking blocks, tool
/// results and every record type this version does not know are skipped.
pub fn mapTranscriptRecord(arena: Allocator, line: []const u8, include_tools: bool, out: *EventBuf) void {
    const record = parseLine(arena, line) orelse return;
    const kind = string(record, "type") orelse return;
    if (boolean(record, "isSidechain") or boolean(record, "isMeta")) return;
    const role: event.Role = if (std.mem.eql(u8, kind, "user"))
        .user
    else if (std.mem.eql(u8, kind, "assistant"))
        .assistant
    else
        return;
    const content = field(field(record, "message"), "content") orelse return;
    switch (content) {
        .string => |text| out.message(role, text),
        .array => |blocks| for (blocks.items) |block| {
            const block_type = string(block, "type") orelse continue;
            if (std.mem.eql(u8, block_type, "text")) {
                out.message(role, string(block, "text") orelse continue);
            } else if (include_tools and role == .assistant and std.mem.eql(u8, block_type, "tool_use")) {
                out.toolUse(string(block, "name") orelse continue, field(block, "input"), true);
            }
        },
        else => {},
    }
}

/// Follows a JSONL file from an offset, one complete line at a time.
///
/// A line is handed out by `peek` and stays the head until `advance`, so a
/// consumer that could not deliver all of a line's events (a full queue)
/// sees the same line again on the next poll and resumes at `resume_index`.
/// A partial last line waits for its newline; a line longer than the buffer
/// is skipped whole. The file is read through the adapter's `SinkIo`, from
/// the offset the previous read stopped at.
const LineTail = struct {
    path: []u8,
    buffer: []u8,
    offset: u64 = 0,
    start: usize = 0,
    end: usize = 0,
    discarding: bool = false,
    resume_index: usize = 0,
    bytes_this_poll: usize = 0,

    const ReadError = error{Disconnected};

    fn init(allocator: Allocator, path: []const u8, capacity: usize) Allocator.Error!LineTail {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        return .{ .path = owned_path, .buffer = try allocator.alloc(u8, capacity) };
    }

    fn deinit(self: *LineTail, allocator: Allocator) void {
        allocator.free(self.buffer);
        allocator.free(self.path);
        self.* = undefined;
    }

    /// The next complete line, without its newline, or null when none is
    /// available yet (including when the file does not exist yet).
    fn peek(self: *LineTail, sink: *SinkIo, io: Io) ReadError!?[]const u8 {
        while (true) {
            if (std.mem.indexOfScalarPos(u8, self.buffer[0..self.end], self.start, '\n')) |newline| {
                if (self.discarding) {
                    self.discarding = false;
                    self.start = newline + 1;
                    continue;
                }
                return self.buffer[self.start..newline];
            }
            if (self.start != 0) {
                std.mem.copyForwards(u8, self.buffer[0 .. self.end - self.start], self.buffer[self.start..self.end]);
                self.end -= self.start;
                self.start = 0;
            }
            if (self.end == self.buffer.len) {
                log.debug("skipping a line longer than {d} bytes", .{self.buffer.len});
                self.discarding = true;
                self.end = 0;
            }
            if (self.bytes_this_poll >= max_bytes_per_poll) return null;
            const read = (sink.readAt(io, self.path, self.offset, self.buffer[self.end..]) catch |err| {
                log.debug("cannot read a followed file: {t}", .{err});
                return error.Disconnected;
            }) orelse return null;
            if (read == 0) return null;
            self.end += read;
            self.offset += read;
            self.bytes_this_poll += read;
        }
    }

    fn advance(self: *LineTail, line_len: usize) void {
        self.start += line_len + 1;
        self.resume_index = 0;
    }
};

/// What draining one file did.
const Drained = struct {
    pushed: usize = 0,
    /// The queue refused an event; the head line stays for the next poll.
    full: bool = false,
};

/// Push `events` from `tail.resume_index` on. Returns false when the queue
/// is full, leaving `resume_index` at the first event not delivered.
fn pushEvents(queue: *event.EventQueue, events: []const Event, tail: *LineTail, drained: *Drained) bool {
    var i = tail.resume_index;
    while (i < events.len) : (i += 1) {
        queue.push(events[i]) catch |err| switch (err) {
            error.QueueFull => {
                tail.resume_index = i;
                drained.full = true;
                return false;
            },
            error.EventTooLarge => {
                log.debug("dropping an oversized {t} event", .{std.meta.activeTag(events[i])});
                continue;
            },
        };
        drained.pushed += 1;
    }
    return true;
}

/// Parses a Claude Code session transcript incrementally into events.
pub const TranscriptReader = struct {
    tail: LineTail,
    include_tools: bool,

    pub fn init(allocator: Allocator, transcript_path: []const u8, include_tools: bool) Allocator.Error!TranscriptReader {
        return .{ .tail = try .init(allocator, transcript_path, max_transcript_line_bytes), .include_tools = include_tools };
    }

    pub fn deinit(self: *TranscriptReader, allocator: Allocator) void {
        self.tail.deinit(allocator);
    }

    pub fn path(self: *const TranscriptReader) []const u8 {
        return self.tail.path;
    }

    /// Push the events of up to `max_lines_per_poll` new records, read
    /// through `sink` (this machine's files or a remote workspace's).
    pub fn poll(self: *TranscriptReader, sink: *SinkIo, io: Io, arena: *std.heap.ArenaAllocator, queue: *event.EventQueue) LineTail.ReadError!Drained {
        var drained: Drained = .{};
        self.tail.bytes_this_poll = 0;
        var lines: usize = 0;
        while (lines < max_lines_per_poll) : (lines += 1) {
            const line = (try self.tail.peek(sink, io)) orelse break;
            _ = arena.reset(.retain_capacity);
            var out: EventBuf = .{};
            mapTranscriptRecord(arena.allocator(), line, self.include_tools, &out);
            if (!pushEvents(queue, out.slice(), &self.tail, &drained)) break;
            self.tail.advance(line.len);
        }
        return drained;
    }
};

// Session registry ------------------------------------------------------------

/// One `<config>/sessions/<pid>.json` record: an interactive Claude Code
/// session that is running right now. Undocumented; best effort.
pub const RegisteredSession = struct {
    pid: u32,
    session_id: SessionId,
    /// `busy` → working, `waiting` → waiting_input (Claude does not say for
    /// what; a permission request is only ever claimed by a hook), `idle` →
    /// idle; anything else is unknown.
    status: ?State,
    started_at: i64,
};

/// Parse a registry record; null when it is not one. `cwd_out` receives the
/// session's cwd when it fits.
pub fn parseRegisteredSession(arena: Allocator, bytes: []const u8, cwd_out: ?*[]const u8) ?RegisteredSession {
    const record = parseLine(arena, bytes) orelse return null;
    const pid = integer(record, "pid") orelse return null;
    if (pid <= 0 or pid > std.math.maxInt(u32)) return null;
    const session_id = SessionId.parse(string(record, "sessionId") orelse return null) orelse return null;
    const status: ?State = if (string(record, "status")) |s|
        if (std.mem.eql(u8, s, "busy"))
            .working
        else if (std.mem.eql(u8, s, "waiting"))
            .waiting_input
        else if (std.mem.eql(u8, s, "idle"))
            .idle
        else
            null
    else
        null;
    if (cwd_out) |out| out.* = string(record, "cwd") orelse "";
    return .{
        .pid = @intCast(pid),
        .session_id = session_id,
        .status = status,
        .started_at = integer(record, "startedAt") orelse 0,
    };
}

/// How to recognise a hand-started session: by the process id of the
/// `claude` the terminal runs (preferred), or by its cwd (the most recently
/// started session there wins), or by its session id.
pub const SessionMatch = union(enum) {
    pid: u32,
    cwd: []const u8,
    session_id: SessionId,
};

// Instructions (TASK-59) ---------------------------------------------------------

/// Where Claude Code reads its instructions, from its memory documentation
/// (doc-3): `CLAUDE.md` in the cwd and every directory above it (also as
/// `.claude/CLAUDE.md` and the personal `CLAUDE.local.md`), the user's
/// `~/.claude/CLAUDE.md`, project and user subagents under `agents/`, and
/// the settings files Claude Code owns. Memory is read when a session
/// starts, so restarting the agent applies an edit; the system prompt
/// itself is not exposed (`--append-system-prompt` adds to it, unread).
pub const instruction_profile: api.InstructionProfile = .{
    .sources = &.{
        .{ .base = .project_tree, .path = "CLAUDE.md", .list_missing = true },
        .{ .base = .project_tree, .path = ".claude/CLAUDE.md" },
        .{ .base = .project_tree, .path = "CLAUDE.local.md" },
        .{ .base = .home, .path = ".claude/CLAUDE.md" },
        .{ .base = .project, .path = ".claude/agents/*.md", .kind = .subagent },
        .{ .base = .home, .path = ".claude/agents/*.md", .kind = .subagent },
        .{ .base = .project, .path = ".claude/settings.json", .kind = .settings },
        .{ .base = .project, .path = ".claude/settings.local.json", .kind = .settings },
        .{ .base = .home, .path = ".claude/settings.json", .kind = .settings },
    },
    .apply = .restart,
};

// The adapter ------------------------------------------------------------------

pub const Options = struct {
    /// The per-agent sink directory: an absolute path inside the run's
    /// private state directory (which the owner keeps 0700). Required for
    /// `launch` and for hooks; null for an adapter that only observes a
    /// hand-started session.
    sink_dir: ?[]const u8 = null,
    /// Claude Code's config directory in the workspace context:
    /// `$CLAUDE_CONFIG_DIR`, else `$HOME/.claude`. Holds `projects/` (the
    /// transcripts) and `sessions/` (the registry). Read only, never written.
    config_dir: ?[]const u8 = null,
    /// The program to run.
    program: []const u8 = "claude",
    /// The environment the `--version` probe runs with (the workspace's
    /// child environment; it needs PATH). Borrowed for the adapter's life.
    probe_env: []const []const u8 = &.{},
    /// Where `sink_dir` and `config_dir` are: this machine's file system when
    /// null, else the workspace's context (`SinkIo.forContext`). Copied; a
    /// borrowed context in it must outlive the adapter.
    sink_io: ?SinkIo = null,
    /// The `conduit` executable the hooks run as `conduit control
    /// agent.event` while the control endpoint is up (TASK-60); null keeps
    /// every hook on the sink relay. Ignored unless it satisfies
    /// `isValidSinkPath`, and for a remote sink, whose hooks run on another
    /// machine where this path and the local endpoint do not exist.
    /// Borrowed for the adapter's life.
    control_helper: ?[]const u8 = null,
};

const Mode = enum { unbound, owned, observed };

const PendingPermission = struct {
    request: Ident(64) = .{},
    tool_use: Ident(256) = .{},
};

const max_pending = 8;

pub const ClaudeCodeAdapter = struct {
    allocator: Allocator,
    io: Io,
    sink_dir: ?[]u8,
    config_dir: ?[]u8,
    program: []u8,
    probe_env: []const []const u8,
    /// Every file access: the sink, the transcript, the registry.
    sink: SinkIo,
    control_helper: ?[]const u8 = null,
    mode: Mode = .unbound,
    token: ?api.CorrelationToken = null,
    session_id: ?SessionId = null,
    hooks: ?LineTail = null,
    transcript: ?TranscriptReader = null,
    /// An attached session's transcript was not found yet; look again.
    transcript_lookup: bool = false,
    /// The registry file followed for an observed session's status.
    registry_pid: ?u32 = null,
    registry_status: ?State = null,
    registry_gone: bool = false,
    pending: [max_pending]PendingPermission = undefined,
    pending_len: usize = 0,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator, io: Io, options: Options) (Allocator.Error || error{InvalidSinkPath})!ClaudeCodeAdapter {
        if (options.sink_dir) |sink| if (!isValidSinkPath(sink)) return error.InvalidSinkPath;
        const sink_dir = if (options.sink_dir) |sink| try allocator.dupe(u8, sink) else null;
        errdefer if (sink_dir) |sink| allocator.free(sink);
        const config_dir = if (options.config_dir) |config| try allocator.dupe(u8, std.mem.trimEnd(u8, config, "/")) else null;
        errdefer if (config_dir) |config| allocator.free(config);
        const program = try allocator.dupe(u8, options.program);
        return .{
            .allocator = allocator,
            .io = io,
            .sink_dir = sink_dir,
            .config_dir = config_dir,
            .program = program,
            .probe_env = options.probe_env,
            .sink = options.sink_io orelse .local(),
            .control_helper = if (options.control_helper) |helper|
                (if (isValidSinkPath(helper) and !(options.sink_io orelse SinkIo.local()).isRemote()) helper else null)
            else
                null,
            .arena = .init(allocator),
        };
    }

    pub fn deinit(self: *ClaudeCodeAdapter) void {
        if (self.hooks) |*tail| tail.deinit(self.allocator);
        if (self.transcript) |*reader| reader.deinit(self.allocator);
        if (self.sink_dir) |sink| self.allocator.free(sink);
        if (self.config_dir) |config| self.allocator.free(config);
        self.allocator.free(self.program);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Lend the adapter through the common interface. `destroy` through it
    /// calls `deinit`; the value itself stays the caller's.
    pub fn adapter(self: *ClaudeCodeAdapter) api.Adapter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: api.Adapter.VTable = .{
        .harness = harnessFn,
        .capabilities = capabilitiesFn,
        .detect = detectFn,
        .launch = launchFn,
        .attach = attachFn,
        .poll = pollFn,
        .respond_permission = respondPermissionFn,
        .destroy = destroyFn,
    };

    pub fn capabilities(self: *const ClaudeCodeAdapter) api.Capabilities {
        const hooks = self.sink_dir != null;
        return .{
            .detect = true,
            .launch = hooks,
            .attach = true,
            .poll = true,
            .respond_permission = hooks,
            .structured_status = true,
            .permission_requests = hooks,
            .transcript = true,
            .subagents = hooks,
        };
    }

    /// The harness's session id, once launched, attached or reported.
    pub fn sessionId(self: *const ClaudeCodeAdapter) ?[]const u8 {
        return if (self.session_id) |*id| id.text() else null;
    }

    /// The transcript being followed, if any.
    pub fn transcriptPath(self: *const ClaudeCodeAdapter) ?[]const u8 {
        return if (self.transcript) |*reader| reader.path() else null;
    }

    fn cast(ptr: *anyopaque) *ClaudeCodeAdapter {
        return @ptrCast(@alignCast(ptr));
    }

    fn harnessFn(_: *const anyopaque) Harness {
        return .claude_code;
    }

    fn capabilitiesFn(ptr: *const anyopaque) api.Capabilities {
        const self: *const ClaudeCodeAdapter = @ptrCast(@alignCast(ptr));
        return self.capabilities();
    }

    fn destroyFn(ptr: *anyopaque) void {
        cast(ptr).deinit();
    }

    // detect ---------------------------------------------------------------

    fn detectFn(ptr: *anyopaque, request: api.DetectRequest) api.Error!?[]const u8 {
        const self = cast(ptr);
        const argv = [_][]const u8{ self.program, "--version" };
        const child = request.context.spawn(.{
            .argv = &argv,
            .env = self.probe_env,
            .cwd = "",
            .size = .{ .rows = 24, .cols = 160 },
        }) catch |err| switch (err) {
            error.ProgramNotFound => return null,
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.debug("version probe failed to start: {t}", .{err});
                return error.Disconnected;
            },
        };
        defer child.destroy();
        var output: [256]u8 = undefined;
        var len: usize = 0;
        var rounds: usize = 0;
        while (len < output.len and rounds < probe_wait_rounds) : (rounds += 1) {
            const took = child.takeBytes(output[len..]);
            len += took;
            if (took == 0 and child.state() != .running) break;
            if (took == 0) _ = child.waitReadable(probe_wait_ms);
        }
        if (child.state() == .running) {
            // The probe overstayed its bound. Ending it is best effort: the
            // handle is destroyed either way, which hangs the terminal up.
            child.kill(.kill) catch |err| log.debug("cannot end the version probe: {t}", .{err});
        }
        return parseVersion(output[0..len], request.version_buffer);
    }

    // launch ---------------------------------------------------------------

    fn launchFn(ptr: *anyopaque, allocator: Allocator, request: api.LaunchRequest) api.Error!api.LaunchSpec {
        const self = cast(ptr);
        // Headless agents speak stream-json with --permission-prompt-tool
        // stdio, which needs a client this adapter does not have yet.
        if (request.headless) return error.Unsupported;
        const sink = self.sink_dir orelse return error.Unsupported;
        if (self.mode != .unbound) return error.UnknownTarget;

        try self.prepareSink(sink);
        const tail = try LineTail.init(self.allocator, try self.sinkPath(allocator, "events.jsonl"), max_hook_line_bytes);
        self.hooks = tail;
        self.mode = .owned;
        self.token = request.token;
        self.session_id = SessionId.fromToken(request.token);

        const settings = try self.sinkPath(allocator, "settings.json");
        const session_text = try allocator.dupe(u8, self.session_id.?.text());
        const argv = try allocator.alloc([]const u8, if (request.initial_prompt == null) 5 else 7);
        argv[0] = try allocator.dupe(u8, self.program);
        argv[1] = "--settings";
        argv[2] = settings;
        argv[3] = "--session-id";
        argv[4] = session_text;
        if (request.initial_prompt) |prompt| {
            // `--` keeps a prompt that starts with a dash, or names a
            // subcommand, a prompt (verified with 2.1.292).
            argv[5] = "--";
            argv[6] = try allocator.dupe(u8, prompt);
        }
        const env = try allocator.alloc([]const u8, 1);
        var entry: [api.correlation_env_name.len + 1 + api.CorrelationToken.text_len]u8 = undefined;
        env[0] = try allocator.dupe(u8, request.token.envEntry(&entry));
        log.debug("launch prepared with hooks", .{});
        return .{ .argv = argv, .env = env };
    }

    fn sinkPath(self: *const ClaudeCodeAdapter, allocator: Allocator, name: []const u8) Allocator.Error![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.sink_dir.?, name });
    }

    /// Create the sink layout, through `self.sink` (so on the remote host in
    /// an SSH workspace): `decisions/`, `tmp/`, the relay, the settings file
    /// and an empty `events.jsonl`. The relay and settings name `sink` itself,
    /// a path in the agent's own context.
    fn prepareSink(self: *ClaudeCodeAdapter, sink: []const u8) api.Error!void {
        const io = self.io;
        var path_buffer: [max_sink_path_bytes + 32]u8 = undefined;
        for ([_][]const u8{ "decisions", "tmp" }) |name| {
            // The sink is at most max_sink_path_bytes (init) and the names are short.
            const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ sink, name }) catch unreachable;
            try self.sink.makePrivateDir(io, path);
        }
        var content: Io.Writer.Allocating = .init(self.allocator);
        defer content.deinit();
        writeHookScript(&content.writer, sink) catch return error.OutOfMemory;
        try self.writeSinkFile(&path_buffer, sink, "hook.sh", content.written());
        content.clearRetainingCapacity();
        writeSettingsVia(&content.writer, sink, self.control_helper) catch return error.OutOfMemory;
        try self.writeSinkFile(&path_buffer, sink, "settings.json", content.written());
        try self.writeSinkFile(&path_buffer, sink, "events.jsonl", "");
    }

    fn writeSinkFile(self: *ClaudeCodeAdapter, path_buffer: []u8, sink: []const u8, name: []const u8, data: []const u8) api.Error!void {
        // Callers pass a buffer of the sink's bound plus room for these names.
        const path = std.fmt.bufPrint(path_buffer, "{s}/{s}", .{ sink, name }) catch unreachable;
        try self.sink.writeFile(self.io, path, data, sink_io.private_file_mode);
    }

    // attach and detection of hand-started sessions --------------------------

    fn attachFn(ptr: *anyopaque, request: api.AttachRequest) api.Error!void {
        const self = cast(ptr);
        const reported = request.harness_session_id orelse return error.UnknownTarget;
        const id = SessionId.parse(reported) orelse return error.UnknownTarget;
        switch (self.mode) {
            .unbound => self.mode = .observed,
            // Re-attaching the session this adapter launched keeps its hooks.
            .owned => if (!SessionId.eql(self.session_id.?, id)) return error.UnknownTarget,
            .observed => return error.UnknownTarget,
        }
        if (self.mode == .observed and self.config_dir == null) {
            self.mode = .unbound;
            return error.Unsupported;
        }
        self.token = request.token;
        self.session_id = id;
        if (self.mode == .observed) {
            var found: RegisteredSession = undefined;
            if (try self.findRunningSession(.{ .session_id = id }, &found)) {
                self.registry_pid = found.pid;
            }
        }
        if (self.transcript == null) {
            self.transcript_lookup = true;
            try self.locateTranscript();
        }
        log.debug("attached ({t})", .{self.mode});
    }

    /// Look for a running interactive session in Claude Code's registry.
    /// Returns whether one matched, filling `out`. Needs `config_dir`.
    pub fn findRunningSession(self: *ClaudeCodeAdapter, match: SessionMatch, out: *RegisteredSession) api.Error!bool {
        const config = self.config_dir orelse return error.Unsupported;
        const io = self.io;
        var path_buffer: [Dir.max_path_bytes]u8 = undefined;
        const read_buffer = try self.allocator.alloc(u8, max_registry_file_bytes);
        defer self.allocator.free(read_buffer);
        defer _ = self.arena.reset(.retain_capacity);

        if (match == .pid) {
            const path = std.fmt.bufPrint(&path_buffer, "{s}/sessions/{d}.json", .{ config, match.pid }) catch return error.NoSpaceLeft;
            const bytes = (self.sink.readFile(io, path, read_buffer) catch return false) orelse return false;
            const record = parseRegisteredSession(self.arena.allocator(), bytes, null) orelse return false;
            if (record.pid != match.pid) return false;
            out.* = record;
            return true;
        }

        const sessions = std.fmt.bufPrint(&path_buffer, "{s}/sessions", .{config}) catch return error.NoSpaceLeft;
        var names: NameList = .{ .allocator = self.allocator, .suffix = ".json", .kind = .file };
        defer names.deinit();
        if (!(self.sink.listDir(io, sessions, names.visitor()) catch return false)) return false;
        if (names.failed) return error.OutOfMemory;
        var found = false;
        var rest = names.bytes.items;
        while (std.mem.indexOfScalar(u8, rest, 0)) |end| {
            const name = rest[0..end];
            rest = rest[end + 1 ..];
            const path = std.fmt.bufPrint(&path_buffer, "{s}/sessions/{s}", .{ config, name }) catch continue;
            const bytes = (self.sink.readFile(io, path, read_buffer) catch continue) orelse continue;
            _ = self.arena.reset(.retain_capacity);
            var cwd: []const u8 = "";
            const record = parseRegisteredSession(self.arena.allocator(), bytes, &cwd) orelse continue;
            const matches = switch (match) {
                .pid => unreachable,
                .cwd => |want| std.mem.eql(u8, std.mem.trimEnd(u8, cwd, "/"), std.mem.trimEnd(u8, want, "/")),
                .session_id => |want| SessionId.eql(record.session_id, want),
            };
            if (!matches) continue;
            if (!found or record.started_at > out.started_at) out.* = record;
            found = true;
        }
        return found;
    }

    /// Find `<config>/projects/*/<session>.jsonl` and start following it.
    fn locateTranscript(self: *ClaudeCodeAdapter) api.Error!void {
        const config = self.config_dir orelse return;
        const id = self.session_id orelse return;
        const io = self.io;
        var path_buffer: [Dir.max_path_bytes]u8 = undefined;
        const projects = std.fmt.bufPrint(&path_buffer, "{s}/projects", .{config}) catch return error.NoSpaceLeft;
        var names: NameList = .{ .allocator = self.allocator, .suffix = "", .kind = .directory };
        defer names.deinit();
        if (!(self.sink.listDir(io, projects, names.visitor()) catch return)) return;
        if (names.failed) return error.OutOfMemory;
        var rest = names.bytes.items;
        while (std.mem.indexOfScalar(u8, rest, 0)) |end| {
            const name = rest[0..end];
            rest = rest[end + 1 ..];
            const full = std.fmt.bufPrint(&path_buffer, "{s}/projects/{s}/{s}.jsonl", .{ config, name, id.text() }) catch continue;
            const found = (self.sink.stat(io, full) catch return) orelse continue;
            if (found.kind != .file) continue;
            try self.followTranscript(full);
            return;
        }
    }

    fn followTranscript(self: *ClaudeCodeAdapter, path: []const u8) Allocator.Error!void {
        if (self.transcript) |*current| {
            if (std.mem.eql(u8, current.path(), path)) return;
            current.deinit(self.allocator);
            self.transcript = null;
        }
        // A launched agent has hooks, whose PreToolUse reports tool uses
        // live; its transcript then contributes messages only, so a view
        // never sees a tool use twice.
        self.transcript = try .init(self.allocator, path, self.mode != .owned);
        self.transcript_lookup = false;
        log.debug("following a transcript", .{});
    }

    /// Whether a transcript path a hook reported may be followed: an
    /// absolute `.jsonl` file inside Claude's projects directory when that is
    /// known, never through `..`.
    fn acceptableTranscriptPath(self: *const ClaudeCodeAdapter, path: []const u8) bool {
        if (path.len == 0 or path.len > event.max_path_bytes or path[0] != '/') return false;
        if (!std.mem.endsWith(u8, path, ".jsonl")) return false;
        if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
        if (std.mem.indexOf(u8, path, "/../") != null or std.mem.indexOf(u8, path, "/./") != null) return false;
        if (self.config_dir) |config| {
            if (!std.mem.startsWith(u8, path, config)) return false;
            if (!std.mem.startsWith(u8, path[config.len..], "/projects/")) return false;
        }
        return true;
    }

    // poll -----------------------------------------------------------------

    fn pollFn(ptr: *anyopaque, queue: *event.EventQueue) api.Error!usize {
        const self = cast(ptr);
        if (self.mode == .unbound) return error.UnknownTarget;
        var pushed: usize = 0;

        if (self.hooks) |*tail| {
            const drained = try self.drainHooks(tail, queue);
            pushed += drained.pushed;
            if (drained.full) return pushed;
        }

        if (self.transcript == null and self.transcript_lookup) try self.locateTranscript();
        if (self.transcript) |*reader| {
            const drained = try reader.poll(&self.sink, self.io, &self.arena, queue);
            pushed += drained.pushed;
            if (drained.full) return pushed;
        }

        if (self.mode == .observed and self.hooks == null) {
            if (self.registry_pid) |pid| {
                var record: RegisteredSession = undefined;
                if (try self.findRunningSession(.{ .pid = pid }, &record)) {
                    if (!SessionId.eql(record.session_id, self.session_id.?)) {
                        // `/clear` or `/resume` in the same process: follow
                        // the new session's transcript from now on.
                        log.debug("the observed process switched sessions", .{});
                        self.session_id = record.session_id;
                        if (self.transcript) |*reader| reader.deinit(self.allocator);
                        self.transcript = null;
                        self.transcript_lookup = true;
                    }
                    if (record.status) |status| if (self.registry_status != status) {
                        queue.push(.{ .status_change = .{ .state = status, .source = .structured } }) catch |err| switch (err) {
                            error.QueueFull => return pushed,
                            error.EventTooLarge => unreachable, // A status change carries no text.
                        };
                        self.registry_status = status;
                        pushed += 1;
                    };
                } else if (!self.registry_gone) {
                    // The session ended; its last records were drained above.
                    self.registry_gone = true;
                    log.debug("the observed session left the registry", .{});
                } else if (pushed == 0) {
                    return error.Disconnected;
                }
            }
        }
        return pushed;
    }

    fn drainHooks(self: *ClaudeCodeAdapter, tail: *LineTail, queue: *event.EventQueue) api.Error!Drained {
        var drained: Drained = .{};
        tail.bytes_this_poll = 0;
        var lines: usize = 0;
        while (lines < max_lines_per_poll) : (lines += 1) {
            const line = (try tail.peek(&self.sink, self.io)) orelse break;
            _ = self.arena.reset(.retain_capacity);
            var out: EventBuf = .{};
            try self.mapHookLine(self.arena.allocator(), line, &out);
            if (!pushEvents(queue, out.slice(), tail, &drained)) break;
            tail.advance(line.len);
        }
        return drained;
    }

    /// Map one relay line to events, updating what the adapter has learned
    /// (session id, transcript, pending requests). Re-mapping the same line
    /// after a full queue must yield the same events, so every update here is
    /// idempotent.
    pub fn mapHookLine(self: *ClaudeCodeAdapter, arena: Allocator, line: []const u8, out: *EventBuf) Allocator.Error!void {
        const root = parseLine(arena, line) orelse {
            log.debug("skipping a malformed hook line", .{});
            return;
        };
        const wrapper = field(root, "conduit") orelse return;
        const hook = Hook.parse(string(wrapper, "event") orelse return) orelse return;
        if (string(wrapper, "token")) |reported| {
            if (reported.len != 0) if (self.token) |token| {
                if (!std.mem.eql(u8, reported, token.text())) {
                    log.debug("skipping a hook line for another agent", .{});
                    return;
                }
            };
        }
        const payload = field(root, "payload");
        if (payload == null or payload.? != .object) return;

        if (SessionId.parse(string(payload, "session_id") orelse "")) |id| {
            if (self.session_id == null or !SessionId.eql(self.session_id.?, id)) {
                log.debug("hooks report a new session id", .{});
                self.session_id = id;
            }
            if (string(payload, "transcript_path")) |path| {
                if (self.acceptableTranscriptPath(path)) try self.followTranscript(path);
            }
        }

        switch (hook) {
            .session_start => {
                const source = string(payload, "source") orelse "startup";
                if (!std.mem.eql(u8, source, "compact")) out.status(.idle);
            },
            .instructions_loaded => if (fileReference(payload)) |reference| out.add(.{ .file_reference = reference }),
            .user_prompt_submit => {
                try self.cancelPending(arena, out, .cancelled);
                out.status(.working);
            },
            .pre_tool_use => {
                out.status(.working);
                out.toolUse(string(payload, "tool_name") orelse "", field(payload, "tool_input"), true);
            },
            .permission_request => {
                const request = string(wrapper, "request") orelse return;
                if (!isRequestId(request)) return;
                const tool = string(payload, "tool_name") orelse "tool";
                const summary = toolSummary(field(payload, "tool_input"));
                const title = if (summary.len == 0)
                    displayLine(tool, max_summary_bytes)
                else
                    try std.fmt.allocPrint(arena, "{s}: {s}", .{ displayLine(tool, 64), summary });
                self.addPending(request, string(payload, "tool_use_id") orelse "");
                out.add(.{ .permission_request = .{ .id = request, .title = title, .decisions = &decisions } });
            },
            .permission_end => {
                const request = string(wrapper, "request") orelse return;
                const index = self.pendingIndex(request) orelse return;
                const outcome = string(wrapper, "outcome") orelse "";
                const resolved: event.PermissionOutcome = if (std.mem.eql(u8, outcome, "allow"))
                    .allowed
                else if (std.mem.eql(u8, outcome, "deny"))
                    .rejected
                else if (std.mem.eql(u8, outcome, "aborted"))
                    .resolved_elsewhere
                else
                    .cancelled;
                out.add(.{ .permission_resolved = .{ .id = request, .outcome = resolved } });
                self.removePending(index);
            },
            .post_tool_use, .post_tool_use_failure => {
                if (string(payload, "tool_use_id")) |tool_use| {
                    var i: usize = 0;
                    while (i < self.pending_len) {
                        const pending = &self.pending[i];
                        if (pending.tool_use.len != 0 and std.mem.eql(u8, pending.tool_use.slice(), tool_use)) {
                            out.add(.{ .permission_resolved = .{ .id = try arena.dupe(u8, pending.request.slice()), .outcome = .resolved_elsewhere } });
                            self.removePending(i);
                        } else i += 1;
                    }
                }
                out.status(.working);
            },
            .notification => {
                const kind = string(payload, "notification_type") orelse "";
                const body = string(payload, "message") orelse "";
                const needs_input = std.mem.eql(u8, kind, "agent_needs_input") or
                    std.mem.eql(u8, kind, "elicitation_dialog") or
                    std.mem.eql(u8, kind, "elicitation_url_dialog");
                if (needs_input) out.status(.waiting_input);
                if (std.mem.eql(u8, kind, "permission_prompt") and self.pending_len == 0) out.status(.waiting_permission);
                const kept = event.truncateUtf8(body, max_notification_bytes);
                out.add(.{ .notification = .{ .title = "Claude Code", .body = kept, .truncated = kept.len != body.len } });
            },
            .subagent_start, .subagent_stop => {
                const id = string(payload, "agent_id") orelse return;
                if (id.len == 0 or id.len > event.max_identifier_bytes) return;
                const name = displayLine(string(payload, "agent_type") orelse "subagent", max_summary_bytes);
                out.add(.{ .subagent = .{ .id = id, .name = name, .phase = if (hook == .subagent_start) .start else .stop } });
            },
            .stop => {
                try self.cancelPending(arena, out, .cancelled);
                out.status(.done);
            },
            .stop_failure => {
                try self.cancelPending(arena, out, .cancelled);
                out.status(.errored);
                const reason = displayLine(string(payload, "error") orelse string(payload, "error_type") orelse "unknown", 64);
                out.add(.{ .notification = .{ .title = "Claude Code", .body = try std.fmt.allocPrint(arena, "turn failed: {s}", .{reason}) } });
            },
            .session_end => {
                try self.cancelPending(arena, out, .cancelled);
                const reason = string(payload, "reason") orelse string(payload, "end_reason") orelse "other";
                // `clear` and `resume` end one session and start another in the
                // same process; a SessionStart follows.
                if (std.mem.eql(u8, reason, "clear") or std.mem.eql(u8, reason, "resume")) return;
                if (self.mode != .observed) return;
                const normal = std.mem.eql(u8, reason, "prompt_input_exit") or std.mem.eql(u8, reason, "logout");
                out.add(.{ .exited = .{ .code = if (normal) 0 else 1 } });
            },
        }
    }

    fn pendingIndex(self: *const ClaudeCodeAdapter, request: []const u8) ?usize {
        for (self.pending[0..self.pending_len], 0..) |*pending, i| {
            if (std.mem.eql(u8, pending.request.slice(), request)) return i;
        }
        return null;
    }

    fn addPending(self: *ClaudeCodeAdapter, request: []const u8, tool_use: []const u8) void {
        if (self.pendingIndex(request) != null) return;
        if (self.pending_len == max_pending) {
            log.debug("too many pending permission requests to track", .{});
            return;
        }
        var pending: PendingPermission = .{};
        _ = pending.request.set(request);
        if (!pending.tool_use.set(tool_use)) pending.tool_use.len = 0;
        self.pending[self.pending_len] = pending;
        self.pending_len += 1;
    }

    fn removePending(self: *ClaudeCodeAdapter, index: usize) void {
        self.pending[index] = self.pending[self.pending_len - 1];
        self.pending_len -= 1;
    }

    /// Resolve every pending request, because the turn it belonged to is
    /// over. The ids are copied into `arena` first, since the events outlive
    /// the table entries they came from.
    fn cancelPending(self: *ClaudeCodeAdapter, arena: Allocator, out: *EventBuf, outcome: event.PermissionOutcome) Allocator.Error!void {
        while (self.pending_len != 0) {
            const id = try arena.dupe(u8, self.pending[self.pending_len - 1].request.slice());
            out.add(.{ .permission_resolved = .{ .id = id, .outcome = outcome } });
            self.pending_len -= 1;
        }
    }

    // respondPermission ----------------------------------------------------

    fn respondPermissionFn(ptr: *anyopaque, request_id: []const u8, decision_id: []const u8) api.Error!void {
        const self = cast(ptr);
        const sink = self.sink_dir orelse return error.Unsupported;
        if (!isRequestId(request_id)) return error.UnknownTarget;
        const answer = std.meta.stringToEnum(Answer, decision_id) orelse return error.UnknownTarget;
        if (self.pendingIndex(request_id) == null) return error.UnknownTarget;

        var final_buffer: [max_sink_path_bytes + 96]u8 = undefined;
        // The sink is at most max_sink_path_bytes and a request id at most 64.
        const final = std.fmt.bufPrint(&final_buffer, "{s}/decisions/{s}", .{ sink, request_id }) catch unreachable;
        // `writeFile` stages aside and renames, so the relay never reads half
        // an answer; in an SSH workspace the relay waits on the remote host.
        self.sink.writeFile(self.io, final, @tagName(answer), sink_io.private_file_mode) catch |err| {
            log.debug("cannot publish a permission answer: {t}", .{err});
            return err;
        };
        log.debug("permission answered: {t}", .{answer});
    }
};

/// Collects the names of a bounded directory listing (`SinkIo.listDir`),
/// NUL-separated, so each can be read after the listing ends: a remote
/// listing is one exec channel and cannot be read from inside its visit.
const NameList = struct {
    allocator: Allocator,
    /// Only names ending in this, of this kind, are kept.
    suffix: []const u8,
    kind: workspace.PathKind,
    bytes: std.ArrayList(u8) = .empty,
    seen: usize = 0,
    failed: bool = false,

    fn visitor(self: *NameList) workspace.DirVisitor {
        return .{ .context = self, .visit_fn = visit };
    }

    fn visit(ptr: *anyopaque, entry: workspace.DirEntry) bool {
        const self: *NameList = @ptrCast(@alignCast(ptr));
        self.seen += 1;
        if (self.seen > max_scan_entries) return false;
        if (entry.kind != self.kind or !std.mem.endsWith(u8, entry.name, self.suffix)) return true;
        if (std.mem.indexOfScalar(u8, entry.name, 0) != null or std.mem.indexOfScalar(u8, entry.name, '/') != null) return true;
        self.bytes.ensureUnusedCapacity(self.allocator, entry.name.len + 1) catch {
            self.failed = true;
            return false;
        };
        self.bytes.appendSliceAssumeCapacity(entry.name);
        self.bytes.appendAssumeCapacity(0);
        return true;
    }

    fn deinit(self: *NameList) void {
        self.bytes.deinit(self.allocator);
    }
};

/// The `/bin/sh` command `resolveConfigDir` runs: an absolute
/// `$CLAUDE_CONFIG_DIR`, else `$HOME/.claude`, printed without a newline.
const config_dir_script =
    \\d=${CLAUDE_CONFIG_DIR:-}; case "$d" in /?*) ;; *) case "${HOME:-}" in /?*) d=$HOME/.claude ;; *) exit 1 ;; esac ;; esac; printf '%s' "$d"
;

/// Claude Code's config directory (`Options.config_dir`) as `context` sees
/// it, copied into `out`: `$CLAUDE_CONFIG_DIR` when absolute, else
/// `$HOME/.claude`; null when neither is set to an absolute path. For a
/// remote workspace, whose environment this process cannot read (TASK-61);
/// the remote exec channel's environment is sshd's plus what the login
/// shell's non-interactive startup exports. Runs one bounded command
/// through the context, so it blocks: workers only.
pub fn resolveConfigDir(context: workspace.ExecutionContext.Ref, allocator: Allocator, io: Io, out: []u8) api.Error!?[]const u8 {
    var result = context.run(allocator, io, .{
        .argv = &.{ "/bin/sh", "-c", config_dir_script },
        .cwd = "",
        .max_output = Dir.max_path_bytes,
        .timeout_ms = 10_000,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return error.Unsupported,
        else => {
            log.debug("cannot resolve the config directory: {t}", .{err});
            return error.Disconnected;
        },
    };
    defer result.deinit(allocator);
    if (!result.succeeded()) return null;
    const dir = std.mem.trimEnd(u8, result.stdout, "/");
    if (dir.len == 0 or dir[0] != '/') return null;
    for (dir) |c| if (c < 0x20 or c == 0x7f) return null;
    if (dir.len > out.len) return error.NoSpaceLeft;
    @memcpy(out[0..dir.len], dir);
    return out[0..dir.len];
}

/// The version in `claude --version` output (`2.1.292 (Claude Code)`),
/// copied into `out`; null when the output names no version.
pub fn parseVersion(output: []const u8, out: []u8) api.Error!?[]const u8 {
    const first = std.mem.indexOfAny(u8, output, "0123456789") orelse return null;
    var end = first;
    while (end < output.len) : (end += 1) switch (output[end]) {
        '0'...'9', 'a'...'z', 'A'...'Z', '.', '-', '+' => {},
        else => break,
    };
    const version = output[first..end];
    if (std.mem.indexOfScalar(u8, version, '.') == null) return null;
    if (version.len > out.len) return error.NoSpaceLeft;
    @memcpy(out[0..version.len], version);
    return out[0..version.len];
}

// Tests ------------------------------------------------------------------------

const testing = std.testing;
const File = std.Io.File;
const registry_mod = @import("registry.zig");

const fixture_hooks = @embedFile("claude_code/fixtures/hooks.jsonl");
const fixture_transcript = @embedFile("claude_code/fixtures/transcript.jsonl");
const fixture_registry = @embedFile("claude_code/fixtures/session-registry.json");
const fixture_permission = @embedFile("claude_code/fixtures/permission-request.json");
const fixture_token = "0123456789abcdef0123456789abcdef";

fn fixtureToken() api.CorrelationToken {
    return api.CorrelationToken.parse(fixture_token) catch unreachable;
}

/// A private directory for one test, with its absolute path. It lives
/// under /tmp rather than the build cache because a real Claude Code started
/// inside this repository would load the repository's own CLAUDE.md.
const Scratch = struct {
    tmp: struct { dir: Dir },
    name_buffer: [64]u8,
    name: []const u8,
    path_buffer: [Dir.max_path_bytes]u8,
    path: []const u8,

    fn init(self: *Scratch) !void {
        var random: [8]u8 = undefined;
        testing.io.random(&random);
        const hex = std.fmt.bytesToHex(random, .lower);
        self.name = try std.fmt.bufPrint(&self.name_buffer, "conduit-claude-test-{s}", .{&hex});
        var root = try Dir.openDirAbsolute(testing.io, "/tmp", .{});
        defer root.close(testing.io);
        self.tmp = .{ .dir = try root.createDirPathOpen(testing.io, self.name, .{}) };
        const len = try self.tmp.dir.realPath(testing.io, &self.path_buffer);
        self.path = self.path_buffer[0..len];
    }

    fn deinit(self: *Scratch) void {
        self.tmp.dir.close(testing.io);
        // Removal is best effort: the directory is this test's own, and a
        // green test is not the place to report that a cleanup failed.
        var root = Dir.openDirAbsolute(testing.io, "/tmp", .{}) catch return;
        defer root.close(testing.io);
        root.deleteTree(testing.io, self.name) catch {};
    }

    fn join(self: *const Scratch, buffer: []u8, name: []const u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{s}/{s}", .{ self.path, name }) catch unreachable;
    }
};

test "identifiers: session ids, request ids, sink paths, versions" {
    try testing.expect(SessionId.parse("11111111-2222-4333-8444-555555555555") != null);
    try testing.expectEqualStrings("abcdefab-2222-4333-8444-555555555555", SessionId.parse("ABCDEFAB-2222-4333-8444-555555555555").?.text());
    for ([_][]const u8{ "", "11111111-2222-4333-8444-55555555555", "11111111/2222-4333-8444-555555555555", "../11111-2222-4333-8444-555555555555" }) |bad| {
        try testing.expect(SessionId.parse(bad) == null);
    }
    const uuid = SessionId.fromToken(fixtureToken());
    try testing.expectEqualStrings("01234567-89ab-4def-8123-456789abcdef", uuid.text());
    try testing.expect(SessionId.parse(uuid.text()) != null);

    try testing.expect(isRequestId("4321-1791404474"));
    for ([_][]const u8{ "", "-1", "1-", "1", "1-2-3", "../x", "1-a", "1 -2" }) |bad| try testing.expect(!isRequestId(bad));

    try testing.expect(isValidSinkPath("/run/conduit/agents/1"));
    for ([_][]const u8{ "", "relative", "/a'b", "/a\nb", "/a\\b", "/trailing/" }) |bad| try testing.expect(!isValidSinkPath(bad));

    var version: [32]u8 = undefined;
    try testing.expectEqualStrings("2.1.292", (try parseVersion("2.1.292 (Claude Code)\r\n", &version)).?);
    try testing.expect((try parseVersion("command not found", &version)) == null);
    var tiny: [3]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, parseVersion("2.1.292", &tiny));
}

test "with the control helper every hook but PermissionRequest goes through conduit control" {
    const sink = "/run/conduit/agent-1";
    var content: Io.Writer.Allocating = .init(testing.allocator);
    defer content.deinit();
    try writeSettingsVia(&content.writer, sink, "/opt/conduit/bin/conduit");
    const parsed = try std.json.parseFromSlice(Value, testing.allocator, content.written(), .{});
    defer parsed.deinit();
    const hooks = field(parsed.value, "hooks").?.object;
    try testing.expectEqual(Hook.registered.len, hooks.count());
    for (Hook.registered) |hook| {
        const entries = field(hooks.get(hook.name()).?.array.items[0], "hooks").?.array;
        var expected: [128]u8 = undefined;
        const command = if (hook == .permission_request)
            try std.fmt.bufPrint(&expected, "/bin/sh '/run/conduit/agent-1/hook.sh' {s}", .{hook.name()})
        else
            try std.fmt.bufPrint(&expected, "'/opt/conduit/bin/conduit' control agent.event --event={s}", .{hook.name()});
        try testing.expectEqualStrings(command, string(entries.items[0], "command").?);
    }
    // An unquotable helper is ignored by the adapter, which keeps the relay.
    var a = try ClaudeCodeAdapter.init(testing.allocator, testing.io, .{ .sink_dir = sink, .control_helper = "/opt/it's/conduit" });
    defer a.deinit();
    try testing.expectEqual(@as(?[]const u8, null), a.control_helper);
}

test "the settings file registers every hook with the exact relay command" {
    const sink = "/run/conduit/agent-1";
    var content: Io.Writer.Allocating = .init(testing.allocator);
    defer content.deinit();
    try writeSettings(&content.writer, sink);
    const parsed = try std.json.parseFromSlice(Value, testing.allocator, content.written(), .{});
    defer parsed.deinit();
    const hooks = field(parsed.value, "hooks").?.object;
    try testing.expectEqual(Hook.registered.len, hooks.count());
    for (Hook.registered) |hook| {
        const groups = hooks.get(hook.name()).?.array;
        try testing.expectEqual(@as(usize, 1), groups.items.len);
        try testing.expect(field(groups.items[0], "matcher") == null);
        const entries = field(groups.items[0], "hooks").?.array;
        try testing.expectEqual(@as(usize, 1), entries.items.len);
        try testing.expectEqualStrings("command", string(entries.items[0], "type").?);
        var expected: [128]u8 = undefined;
        const command = try std.fmt.bufPrint(&expected, "/bin/sh '/run/conduit/agent-1/hook.sh' {s}", .{hook.name()});
        try testing.expectEqualStrings(command, string(entries.items[0], "command").?);
        try testing.expectEqual(@as(i64, hook.timeoutSeconds()), integer(entries.items[0], "timeout").?);
    }
    try testing.expectEqual(@as(i64, 600), integer(field(hooks.get("PermissionRequest").?.array.items[0], "hooks").?.array.items[0], "timeout").?);
    try testing.expect(hooks.get("PermissionEnd") == null);

    content.clearRetainingCapacity();
    try writeHookScript(&content.writer, sink);
    try testing.expect(std.mem.startsWith(u8, content.written(), "#!/bin/sh\n"));
    try testing.expect(std.mem.indexOf(u8, content.written(), "sink='/run/conduit/agent-1'\n") != null);
    try testing.expect(std.mem.indexOf(u8, content.written(), permissionReply(.allow)) != null);
    try testing.expect(std.mem.indexOf(u8, content.written(), permissionReply(.deny)) != null);
}

/// Stored events that never move once stored (a `StoredEvent` points into
/// itself, so it must not live in a growing list).
const StoredList = struct {
    slots: []event.StoredEvent,
    items: []event.StoredEvent,

    fn init() !StoredList {
        const slots = try testing.allocator.alloc(event.StoredEvent, 64);
        return .{ .slots = slots, .items = slots[0..0] };
    }

    fn deinit(self: *StoredList) void {
        testing.allocator.free(self.slots);
    }

    fn append(self: *StoredList, ev: Event) !void {
        if (self.items.len == self.slots.len) return error.TestUnexpectedResult;
        try self.slots[self.items.len].store(ev);
        self.items = self.slots[0 .. self.items.len + 1];
    }
};

/// Map every fixture hook line through one adapter, as a single poll would.
fn mapFixtureHooks(self: *ClaudeCodeAdapter, mode: Mode, events: *StoredList) !void {
    self.mode = mode;
    self.token = fixtureToken();
    var lines = std.mem.splitScalar(u8, fixture_hooks, '\n');
    while (lines.next()) |line| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var out: EventBuf = .{};
        try self.mapHookLine(arena.allocator(), line, &out);
        for (out.slice()) |ev| try events.append(ev);
    }
}

test "every hook event maps to the documented events, through the registry" {
    var a = try ClaudeCodeAdapter.init(testing.allocator, testing.io, .{ .sink_dir = "/run/conduit/agent-1", .config_dir = "/home/user/.claude/" });
    defer a.deinit();
    var events = try StoredList.init();
    defer events.deinit();
    try mapFixtureHooks(&a, .owned, &events);

    const K = Event.Kind;
    const kinds = [_]K{
        .status_change, // SessionStart startup → idle
        .file_reference, // InstructionsLoaded
        .status_change, // UserPromptSubmit → working
        .status_change, .tool_use, .file_reference, // PreToolUse Read
        // the malformed line and the other agent's line yield nothing
        .permission_request, // PermissionRequest
        .permission_resolved, // PermissionEnd allow
        .status_change, // PostToolUse → working
        .subagent, .subagent, // SubagentStart, SubagentStop
        .status_change, .notification, // Notification agent_needs_input
        .status_change, // Stop → done
        // SessionStart compact → nothing
        .status_change, // UserPromptSubmit → working
        .status_change, .notification, // StopFailure → errored
        // SessionEnd for an owned agent → nothing (the PTY reports the exit)
    };
    try testing.expectEqual(kinds.len, events.items.len);
    for (kinds, events.items) |kind, *stored| try testing.expectEqual(kind, std.meta.activeTag(stored.event));

    const e = events.items;
    try testing.expectEqualStrings("/work/conduit/CLAUDE.md", e[1].event.file_reference.path);
    try testing.expectEqualStrings("Read", e[4].event.tool_use.name);
    try testing.expectEqualStrings("/work/conduit/build.zig", e[4].event.tool_use.summary);
    try testing.expectEqual(@as(?u32, 42), e[5].event.file_reference.line);
    const request = e[6].event.permission_request;
    try testing.expectEqualStrings("4321-1791404474", request.id);
    try testing.expectEqualStrings("Bash: touch probe_file", request.title);
    try testing.expectEqual(@as(usize, 2), request.decisions.len);
    try testing.expectEqualStrings("allow", request.decisions[0].id);
    try testing.expectEqual(event.DecisionKind.reject, request.decisions[1].kind);
    try testing.expectEqual(event.PermissionOutcome.allowed, e[7].event.permission_resolved.outcome);
    try testing.expectEqualStrings("Explore", e[9].event.subagent.name);
    try testing.expectEqual(event.Subagent.Phase.stop, e[10].event.subagent.phase);
    try testing.expectEqual(State.waiting_input, e[11].event.status_change.state);
    try testing.expectEqualStrings("Claude needs your input", e[12].event.notification.body);
    try testing.expectEqual(State.done, e[13].event.status_change.state);
    try testing.expectEqual(State.errored, e[15].event.status_change.state);
    try testing.expectEqualStrings("turn failed: authentication_failed", e[16].event.notification.body);

    // The session and its transcript were learned from the payloads.
    try testing.expectEqualStrings("11111111-2222-4333-8444-555555555555", a.sessionId().?);
    try testing.expectEqualStrings("/home/user/.claude/projects/-work-conduit/11111111-2222-4333-8444-555555555555.jsonl", a.transcriptPath().?);
    try testing.expect(!a.transcript.?.include_tools);

    // The registry accepts the whole stream and lands on the expected states.
    var reg = registry_mod.Registry.init(testing.allocator);
    defer reg.deinit();
    const id = try reg.create(.{
        .binding = .{ .workspace = .first, .session = @import("session").SessionId.fromOrdinal(1), .session_kind = .agent_terminal, .scratchpad = .first },
        .harness = .claude_code,
        .ownership = .owned,
        .token = fixtureToken(),
        .capabilities = a.capabilities(),
    });
    var states: std.ArrayList(State) = .empty;
    defer states.deinit(testing.allocator);
    for (events.items) |*stored| try states.append(testing.allocator, (try reg.apply(id, stored.event)).current);
    try testing.expectEqualSlices(State, &.{
        .idle,    .idle,    .working, .working,       .working,       .working, .waiting_permission, .working,
        .working, .working, .working, .waiting_input, .waiting_input, .done,    .working,            .errored,
        .errored,
    }, states.items);
    try testing.expect(!reg.get(id).?.hasExited());
}

test "an observed session takes its exit from SessionEnd" {
    var a = try ClaudeCodeAdapter.init(testing.allocator, testing.io, .{ .config_dir = "/home/user/.claude" });
    defer a.deinit();
    var events = try StoredList.init();
    defer events.deinit();
    try mapFixtureHooks(&a, .observed, &events);
    const last = events.items[events.items.len - 1].event;
    try testing.expectEqual(event.ExitStatus{ .code = 1 }, last.exited);
    // Without hooks, transcript tool uses would come from the transcript.
    try testing.expect(a.transcript.?.include_tools);
}

test "pending permissions resolve elsewhere when the tool runs or the turn ends" {
    var a = try ClaudeCodeAdapter.init(testing.allocator, testing.io, .{ .sink_dir = "/run/conduit/agent-1" });
    defer a.deinit();
    a.mode = .owned;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const request_line =
        \\{"conduit":{"v":1,"event":"PermissionRequest","token":"","request":"77-1"},"payload":{"tool_name":"Edit","tool_input":{"file_path":"a.zig"},"tool_use_id":"toolu_A"}}
    ;
    const second_line =
        \\{"conduit":{"v":1,"event":"PermissionRequest","token":"","request":"78-1"},"payload":{"tool_name":"Bash","tool_input":{"command":"ls\nrm"},"tool_use_id":"toolu_B"}}
    ;
    const post_line =
        \\{"conduit":{"v":1,"event":"PostToolUse","token":""},"payload":{"tool_name":"Edit","tool_use_id":"toolu_A"}}
    ;
    const stop_line =
        \\{"conduit":{"v":1,"event":"Stop","token":""},"payload":{}}
    ;
    var out: EventBuf = .{};
    try a.mapHookLine(arena.allocator(), request_line, &out);
    // Mapping the same line twice (a resumed poll) does not track it twice.
    out = .{};
    try a.mapHookLine(arena.allocator(), request_line, &out);
    try testing.expectEqual(@as(usize, 1), a.pending_len);
    out = .{};
    try a.mapHookLine(arena.allocator(), second_line, &out);
    try testing.expectEqualStrings("Bash: ls", out.slice()[0].permission_request.title);
    out = .{};
    try a.mapHookLine(arena.allocator(), post_line, &out);
    try testing.expectEqualStrings("77-1", out.slice()[0].permission_resolved.id);
    try testing.expectEqual(event.PermissionOutcome.resolved_elsewhere, out.slice()[0].permission_resolved.outcome);
    try testing.expectEqual(@as(usize, 1), a.pending_len);
    out = .{};
    try a.mapHookLine(arena.allocator(), stop_line, &out);
    try testing.expectEqualStrings("78-1", out.slice()[0].permission_resolved.id);
    try testing.expectEqual(event.PermissionOutcome.cancelled, out.slice()[0].permission_resolved.outcome);
    try testing.expectEqual(State.done, out.slice()[1].status_change.state);
    try testing.expectEqual(@as(usize, 0), a.pending_len);
    // A request id that is not the relay's shape is refused outright.
    out = .{};
    try a.mapHookLine(arena.allocator(),
        \\{"conduit":{"v":1,"event":"PermissionRequest","token":"","request":"../../x"},"payload":{"tool_name":"Bash"}}
    , &out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "a reported transcript path is followed only inside Claude's projects directory" {
    var a = try ClaudeCodeAdapter.init(testing.allocator, testing.io, .{ .config_dir = "/home/user/.claude" });
    defer a.deinit();
    try testing.expect(a.acceptableTranscriptPath("/home/user/.claude/projects/-work/11111111-2222-4333-8444-555555555555.jsonl"));
    for ([_][]const u8{
        "/etc/passwd",
        "/home/user/.claude/projects/../../.ssh/id_ed25519.jsonl",
        "/home/user/.claude/sessions/x.jsonl",
        "/home/user/.claudeX/projects/a.jsonl",
        "relative/projects/a.jsonl",
    }) |bad| try testing.expect(!a.acceptableTranscriptPath(bad));
}

test "transcript records become messages, tool uses and file references" {
    var events = try StoredList.init();
    defer events.deinit();
    var lines = std.mem.splitScalar(u8, fixture_transcript, '\n');
    while (lines.next()) |line| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var out: EventBuf = .{};
        mapTranscriptRecord(arena.allocator(), line, true, &out);
        for (out.slice()) |ev| try events.append(ev);
    }
    const e = events.items;
    const K = Event.Kind;
    const kinds = [_]K{ .message, .message, .tool_use, .file_reference, .tool_use, .file_reference, .tool_use, .message };
    try testing.expectEqual(kinds.len, e.len);
    for (kinds, e) |kind, *stored| try testing.expectEqual(kind, std.meta.activeTag(stored.event));
    try testing.expectEqual(event.Role.user, e[0].event.message.role);
    try testing.expectEqualStrings("read the build", e[0].event.message.text);
    try testing.expectEqualStrings("I'll read the build first.", e[1].event.message.text);
    try testing.expectEqualStrings("Read", e[2].event.tool_use.name);
    try testing.expectEqual(@as(?u32, 42), e[3].event.file_reference.line);
    try testing.expectEqualStrings("src/main.zig", e[5].event.file_reference.path);
    try testing.expectEqualStrings("zig build test", e[6].event.tool_use.summary);
    try testing.expectEqualStrings("thanks, now explain", e[7].event.message.text);

    // Without tools only the messages remain.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: EventBuf = .{};
    var it = std.mem.splitScalar(u8, fixture_transcript, '\n');
    var messages: usize = 0;
    while (it.next()) |line| {
        out = .{};
        mapTranscriptRecord(arena.allocator(), line, false, &out);
        for (out.slice()) |ev| {
            try testing.expectEqual(K.message, std.meta.activeTag(ev));
            messages += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), messages);

    // Long text is cut at a UTF-8 boundary and flagged.
    const long = try std.fmt.allocPrint(arena.allocator(), "{{\"type\":\"assistant\",\"message\":{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}}}", .{"é" ** (max_message_bytes / 2 + 1)});
    out = .{};
    mapTranscriptRecord(arena.allocator(), long, false, &out);
    try testing.expect(out.slice()[0].message.truncated);
    try testing.expect(out.slice()[0].message.text.len <= max_message_bytes);
    try testing.expect(std.unicode.utf8ValidateSlice(out.slice()[0].message.text));
}

test "the transcript reader is incremental, bounded and resumes after a full queue" {
    var scratch: Scratch = undefined;
    try scratch.init();
    defer scratch.deinit();
    var buffer: [Dir.max_path_bytes]u8 = undefined;
    const path = scratch.join(&buffer, "t.jsonl");

    var reader = try TranscriptReader.init(testing.allocator, path, true);
    defer reader.deinit(testing.allocator);
    var sink = SinkIo.local();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var queue = try event.EventQueue.init(testing.allocator, testing.io, 3);
    defer queue.deinit(testing.allocator);
    const out = try testing.allocator.alloc(event.StoredEvent, 8);
    defer testing.allocator.free(out);

    // No file yet: nothing, and no error.
    try testing.expectEqual(@as(usize, 0), (try reader.poll(&sink, testing.io, &arena, &queue)).pushed);

    // A complete record and a partial one.
    const first = fixture_transcript[0 .. std.mem.indexOf(u8, fixture_transcript, "I'll read").? + 40];
    try scratch.tmp.dir.writeFile(testing.io, .{ .sub_path = "t.jsonl", .data = first });
    var drained = try reader.poll(&sink, testing.io, &arena, &queue);
    try testing.expectEqual(@as(usize, 1), drained.pushed);
    try testing.expectEqual(@as(usize, 1), queue.drain(out));
    try testing.expectEqualStrings("read the build", out[0].event.message.text);

    // The whole fixture: 8 events through a queue of 3 arrive across polls,
    // in order, none twice.
    try scratch.tmp.dir.writeFile(testing.io, .{ .sub_path = "t.jsonl", .data = fixture_transcript });
    var kinds: std.ArrayList(Event.Kind) = .empty;
    defer kinds.deinit(testing.allocator);
    var polls: usize = 0;
    while (polls < 10) : (polls += 1) {
        drained = try reader.poll(&sink, testing.io, &arena, &queue);
        const n = queue.drain(out);
        for (out[0..n]) |*stored| try kinds.append(testing.allocator, std.meta.activeTag(stored.event));
        if (!drained.full and n == 0) break;
    }
    try testing.expectEqualSlices(Event.Kind, &.{ .message, .tool_use, .file_reference, .tool_use, .file_reference, .tool_use, .message }, kinds.items);

    // A record longer than the line buffer is skipped whole; the next one
    // still arrives.
    var file = try scratch.tmp.dir.openFile(testing.io, "t.jsonl", .{ .mode = .write_only });
    defer file.close(testing.io);
    const length = try file.length(testing.io);
    const huge = try testing.allocator.alloc(u8, max_transcript_line_bytes + 10);
    defer testing.allocator.free(huge);
    @memset(huge, 'x');
    try file.writePositionalAll(testing.io, huge, length);
    try file.writePositionalAll(testing.io, "\n{\"type\":\"user\",\"message\":{\"content\":\"after\"}}\n", length + huge.len);
    polls = 0;
    var after: ?[]const u8 = null;
    while (polls < 4 and after == null) : (polls += 1) {
        _ = try reader.poll(&sink, testing.io, &arena, &queue);
        const n = queue.drain(out);
        if (n != 0) after = out[0].event.message.text;
    }
    try testing.expectEqualStrings("after", after.?);
}

test "the session registry finds a hand-started session by pid, cwd or id" {
    var scratch: Scratch = undefined;
    try scratch.init();
    defer scratch.deinit();
    try scratch.tmp.dir.createDirPath(testing.io, "config/sessions");
    try scratch.tmp.dir.writeFile(testing.io, .{ .sub_path = "config/sessions/4242.json", .data = fixture_registry });
    try scratch.tmp.dir.writeFile(testing.io, .{ .sub_path = "config/sessions/9.json", .data = "{\"pid\":9,\"sessionId\":\"not a uuid\"}" });
    try scratch.tmp.dir.writeFile(testing.io, .{ .sub_path = "config/sessions/4242.0123.key", .data = "secret" });
    var buffer: [Dir.max_path_bytes]u8 = undefined;
    var a = try ClaudeCodeAdapter.init(testing.allocator, testing.io, .{ .config_dir = scratch.join(&buffer, "config") });
    defer a.deinit();

    var found: RegisteredSession = undefined;
    try testing.expect(try a.findRunningSession(.{ .pid = 4242 }, &found));
    try testing.expectEqualStrings("a99524b3-acf5-4f2d-9d81-63305a561d2a", found.session_id.text());
    try testing.expectEqual(@as(?State, .working), found.status);
    try testing.expect(!try a.findRunningSession(.{ .pid = 9 }, &found));
    try testing.expect(!try a.findRunningSession(.{ .pid = 1 }, &found));
    try testing.expect(try a.findRunningSession(.{ .cwd = "/work/conduit/" }, &found));
    try testing.expectEqual(@as(u32, 4242), found.pid);
    try testing.expect(!try a.findRunningSession(.{ .cwd = "/elsewhere" }, &found));
    try testing.expect(try a.findRunningSession(.{ .session_id = SessionId.parse("a99524b3-acf5-4f2d-9d81-63305a561d2a").? }, &found));

    var no_config = try ClaudeCodeAdapter.init(testing.allocator, testing.io, .{});
    defer no_config.deinit();
    try testing.expectError(error.Unsupported, no_config.findRunningSession(.{ .pid = 1 }, &found));
}

test "a hand-started session is detected, attached and followed until it exits" {
    var scratch: Scratch = undefined;
    try scratch.init();
    defer scratch.deinit();
    const dir = scratch.tmp.dir;
    try dir.createDirPath(testing.io, "config/sessions");
    try dir.createDirPath(testing.io, "config/projects/-work-conduit");
    try dir.writeFile(testing.io, .{ .sub_path = "config/sessions/4242.json", .data = fixture_registry });
    const transcript_name = "config/projects/-work-conduit/a99524b3-acf5-4f2d-9d81-63305a561d2a.jsonl";
    try dir.writeFile(testing.io, .{ .sub_path = transcript_name, .data = fixture_transcript });

    var buffer: [Dir.max_path_bytes]u8 = undefined;
    var a = try ClaudeCodeAdapter.init(testing.allocator, testing.io, .{ .config_dir = scratch.join(&buffer, "config") });
    const iface = a.adapter();
    defer iface.destroy();
    try testing.expect(!iface.capabilities().respond_permission);
    try testing.expectError(error.Unsupported, iface.respondPermission("1-1", "allow"));
    try testing.expectError(error.Unsupported, iface.stop());
    try testing.expectError(error.Unsupported, iface.sendInput("x"));

    // The owner knows the terminal's cwd (OSC 7); the registry names the session.
    var found: RegisteredSession = undefined;
    try testing.expect(try a.findRunningSession(.{ .cwd = "/work/conduit" }, &found));
    try iface.attach(.{ .session = .first, .token = fixtureToken(), .harness_session_id = found.session_id.text() });
    try testing.expectError(error.UnknownTarget, iface.attach(.{ .session = .first, .token = fixtureToken(), .harness_session_id = found.session_id.text() }));

    var queue = try event.EventQueue.init(testing.allocator, testing.io, 32);
    defer queue.deinit(testing.allocator);
    const out = try testing.allocator.alloc(event.StoredEvent, 32);
    defer testing.allocator.free(out);
    const pushed = try iface.poll(&queue);
    try testing.expectEqual(@as(usize, 9), pushed);
    const n = queue.drain(out);
    try testing.expectEqual(Event.Kind.message, std.meta.activeTag(out[0].event));
    try testing.expectEqual(State.working, out[n - 1].event.status_change.state);
    // Nothing new: nothing pushed, status not repeated.
    try testing.expectEqual(@as(usize, 0), try iface.poll(&queue));

    // The status changes in the registry, then the process exits.
    const idle = try std.mem.replaceOwned(u8, testing.allocator, fixture_registry, "\"busy\"", "\"idle\"");
    defer testing.allocator.free(idle);
    try dir.writeFile(testing.io, .{ .sub_path = "config/sessions/4242.json", .data = idle });
    try testing.expectEqual(@as(usize, 1), try iface.poll(&queue));
    try testing.expectEqual(@as(usize, 1), queue.drain(out));
    try testing.expectEqual(State.idle, out[0].event.status_change.state);
    try dir.deleteFile(testing.io, "config/sessions/4242.json");
    try testing.expectEqual(@as(usize, 0), try iface.poll(&queue));
    try testing.expectError(error.Disconnected, iface.poll(&queue));
}

test "launch writes the sink and describes the claude process" {
    var scratch: Scratch = undefined;
    try scratch.init();
    defer scratch.deinit();
    var buffer: [Dir.max_path_bytes]u8 = undefined;
    const sink = scratch.join(&buffer, "agents/1");
    var a = try ClaudeCodeAdapter.init(testing.allocator, testing.io, .{ .sink_dir = sink });
    const iface = a.adapter();
    defer iface.destroy();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.Unsupported, iface.launch(arena.allocator(), .{ .context_kind = .local, .cwd = "/w", .token = fixtureToken(), .headless = true }));
    const spec = try iface.launch(arena.allocator(), .{ .context_kind = .local, .cwd = "/w", .token = fixtureToken(), .initial_prompt = "-fix it" });
    var settings_buffer: [Dir.max_path_bytes]u8 = undefined;
    const settings = try std.fmt.bufPrint(&settings_buffer, "{s}/settings.json", .{sink});
    const expected = [_][]const u8{ "claude", "--settings", settings, "--session-id", "01234567-89ab-4def-8123-456789abcdef", "--", "-fix it" };
    try testing.expectEqual(expected.len, spec.argv.len);
    for (expected, spec.argv) |want, got| try testing.expectEqualStrings(want, got);
    try testing.expectEqualStrings("CONDUIT_AGENT_TOKEN=" ++ fixture_token, spec.env[0]);
    try testing.expectError(error.UnknownTarget, iface.launch(arena.allocator(), .{ .context_kind = .local, .cwd = "/w", .token = fixtureToken() }));

    var file_buffer: [16 * 1024]u8 = undefined;
    const written_settings = try scratch.tmp.dir.readFile(testing.io, "agents/1/settings.json", &file_buffer);
    var expected_settings: Io.Writer.Allocating = .init(testing.allocator);
    defer expected_settings.deinit();
    try writeSettings(&expected_settings.writer, sink);
    try testing.expectEqualStrings(expected_settings.written(), written_settings);
    const stat = try scratch.tmp.dir.statFile(testing.io, "agents/1/decisions", .{});
    try testing.expectEqual(File.Kind.directory, stat.kind);
    try testing.expectEqual(@as(usize, 0), (try scratch.tmp.dir.readFile(testing.io, "agents/1/events.jsonl", &file_buffer)).len);

    // The permission round trip at file level: a request line arrives, the
    // answer is written where the relay looks for it, and nothing else is
    // answerable.
    var queue = try event.EventQueue.init(testing.allocator, testing.io, 8);
    defer queue.deinit(testing.allocator);
    const line = comptime "{\"conduit\":{\"v\":1,\"event\":\"PermissionRequest\",\"token\":\"" ++ fixture_token ++ "\",\"request\":\"4321-1791404474\"},\"payload\":" ++
        std.mem.trimEnd(u8, fixture_permission, "\n") ++ "}\n";
    try scratch.tmp.dir.writeFile(testing.io, .{ .sub_path = "agents/1/events.jsonl", .data = line });
    try testing.expectEqual(@as(usize, 1), try iface.poll(&queue));
    try testing.expectError(error.UnknownTarget, iface.respondPermission("4321-1791404475", "allow"));
    try testing.expectError(error.UnknownTarget, iface.respondPermission("4321-1791404474", "always"));
    try iface.respondPermission("4321-1791404474", "deny");
    try testing.expectEqualStrings("deny", try scratch.tmp.dir.readFile(testing.io, "agents/1/decisions/4321-1791404474", &file_buffer));
}

/// A wall-clock bound for tests that wait on real processes. Each wait
/// inside it is itself bounded by `waitReadable`, so no test sleeps.
const Deadline = struct {
    end_ns: i96,

    fn in(seconds: i96) Deadline {
        return .{ .end_ns = std.Io.Clock.awake.now(testing.io).nanoseconds + seconds * std.time.ns_per_s };
    }

    fn pending(self: Deadline) bool {
        return std.Io.Clock.awake.now(testing.io).nanoseconds < self.end_ns;
    }
};

/// Poll, bounded, until an event of kind `want` arrives, and return it.
fn pollUntil(iface: api.Adapter, queue: *event.EventQueue, out: []event.StoredEvent, want: Event.Kind, child: anytype) !?*event.StoredEvent {
    const deadline: Deadline = .in(20);
    while (deadline.pending()) {
        _ = try iface.poll(queue);
        const n = queue.drain(out);
        for (out[0..n]) |*stored| if (std.meta.activeTag(stored.event) == want) return stored;
        // Waiting on the child's terminal bounds each round without a sleep.
        _ = child.waitReadable(50);
    }
    return null;
}

test "the generated relay blocks on a permission until Conduit answers, then replies" {
    var scratch: Scratch = undefined;
    try scratch.init();
    defer scratch.deinit();
    var buffer: [Dir.max_path_bytes]u8 = undefined;
    const sink = scratch.join(&buffer, "sink");
    var a = try ClaudeCodeAdapter.init(testing.allocator, testing.io, .{ .sink_dir = sink });
    const iface = a.adapter();
    defer iface.destroy();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = try iface.launch(arena.allocator(), .{ .context_kind = .local, .cwd = "/", .token = fixtureToken() });
    try scratch.tmp.dir.writeFile(testing.io, .{ .sub_path = "payload.json", .data = fixture_permission });

    // Run the relay exactly as the settings file tells Claude Code to, with
    // the hook input on stdin.
    var command_buffer: [Dir.max_path_bytes * 2]u8 = undefined;
    var command: Io.Writer = .fixed(&command_buffer);
    try writeHookCommand(&command, sink, .permission_request);
    try command.print(" < '{s}/payload.json'", .{scratch.path});
    var context = try workspace.ExecutionContext.local(testing.allocator);
    defer context.deinit();
    const argv = [_][]const u8{ "/bin/sh", "-c", command.buffered() };
    const env = [_][]const u8{ "PATH=/usr/bin:/bin", "CONDUIT_AGENT_TOKEN=" ++ fixture_token };
    const child = context.borrow().spawn(.{ .argv = &argv, .env = &env, .cwd = "", .size = .{ .rows = 24, .cols = 200 } }) catch |err| switch (err) {
        error.ProgramNotFound, error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer child.destroy();

    var queue = try event.EventQueue.init(testing.allocator, testing.io, 8);
    defer queue.deinit(testing.allocator);
    const out = try testing.allocator.alloc(event.StoredEvent, 8);
    defer testing.allocator.free(out);
    const request = (try pollUntil(iface, &queue, out, .permission_request, child)) orelse return error.TestUnexpectedResult;
    var id_buffer: [64]u8 = undefined;
    const id = id_buffer[0..request.event.permission_request.id.len];
    @memcpy(id, request.event.permission_request.id);
    try testing.expectEqualStrings("Bash: touch probe_file", request.event.permission_request.title);

    // Still blocked: the relay has printed nothing and is still running.
    var output: [1024]u8 = undefined;
    var len = child.takeBytes(&output);
    try testing.expectEqual(@as(usize, 0), len);
    try testing.expect(child.state() == .running);

    try iface.respondPermission(id, "allow");
    const resolved = (try pollUntil(iface, &queue, out, .permission_resolved, child)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(event.PermissionOutcome.allowed, resolved.event.permission_resolved.outcome);

    const deadline: Deadline = .in(20);
    while (deadline.pending() and len < output.len) {
        const took = child.takeBytes(output[len..]);
        len += took;
        if (took == 0 and child.state() != .running) break;
        if (took == 0) _ = child.waitReadable(50);
    }
    try testing.expect(child.state() != .running);
    try testing.expectEqualStrings(permissionReply(.allow), std.mem.trim(u8, output[0..len], "\r\n"));
    // The relay consumed the answer file.
    var answer_buffer: [128]u8 = undefined;
    const answer = try std.fmt.bufPrint(&answer_buffer, "sink/decisions/{s}", .{id});
    try testing.expectError(error.FileNotFound, scratch.tmp.dir.statFile(testing.io, answer, .{}));
}

test "a real claude, unauthenticated and isolated, reports its hooks through the relay" {
    // No model call happens: without credentials Claude Code ends the turn
    // with StopFailure before any network request for a reply, yet runs
    // SessionStart, UserPromptSubmit, StopFailure and SessionEnd. HOME and
    // CLAUDE_CONFIG_DIR are private to the test, so the user's own
    // configuration is never read or written. Skipped where claude is absent.
    var scratch: Scratch = undefined;
    try scratch.init();
    defer scratch.deinit();
    var sink_buffer: [Dir.max_path_bytes]u8 = undefined;
    var config_buffer: [Dir.max_path_bytes]u8 = undefined;
    const sink = scratch.join(&sink_buffer, "sink");
    const config = scratch.join(&config_buffer, "home/.claude");
    try scratch.tmp.dir.createDirPath(testing.io, "home/.claude");
    var a = try ClaudeCodeAdapter.init(testing.allocator, testing.io, .{ .sink_dir = sink, .config_dir = config });
    const iface = a.adapter();
    defer iface.destroy();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spec = try iface.launch(arena.allocator(), .{ .context_kind = .local, .cwd = scratch.path, .token = fixtureToken(), .initial_prompt = "say hi" });

    // The interactive argv plus -p, so the run ends by itself.
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena.allocator(), spec.argv[0]);
    try argv.append(arena.allocator(), "-p");
    try argv.appendSlice(arena.allocator(), spec.argv[1..]);
    const home = try std.fmt.allocPrint(arena.allocator(), "HOME={s}/home", .{scratch.path});
    const config_env = try std.fmt.allocPrint(arena.allocator(), "CLAUDE_CONFIG_DIR={s}", .{config});
    // Only the PATH is taken from the real environment, to find claude.
    const real_path = testing.environ.getAlloc(arena.allocator(), "PATH") catch return error.SkipZigTest;
    const user_bin = try std.fmt.allocPrint(arena.allocator(), "PATH={s}", .{real_path});
    const env = [_][]const u8{ user_bin, home, config_env, "TERM=dumb", "DISABLE_AUTOUPDATER=1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1", spec.env[0] };
    var context = try workspace.ExecutionContext.local(testing.allocator);
    defer context.deinit();
    const child = context.borrow().spawn(.{ .argv = argv.items, .env = &env, .cwd = scratch.path, .size = .{ .rows = 24, .cols = 120 } }) catch |err| switch (err) {
        error.ProgramNotFound, error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer child.destroy();

    var queue = try event.EventQueue.init(testing.allocator, testing.io, 32);
    defer queue.deinit(testing.allocator);
    const out = try testing.allocator.alloc(event.StoredEvent, 32);
    defer testing.allocator.free(out);
    var states: std.ArrayList(State) = .empty;
    defer states.deinit(testing.allocator);
    var sink_output: [4096]u8 = undefined;
    const deadline: Deadline = .in(90);
    while (deadline.pending()) {
        _ = child.takeBytes(&sink_output);
        _ = try iface.poll(&queue);
        const n = queue.drain(out);
        for (out[0..n]) |*stored| if (stored.event == .status_change) try states.append(testing.allocator, stored.event.status_change.state);
        if (states.items.len >= 3 and child.state() != .running) break;
        _ = child.waitReadable(50);
    }
    // An authenticated environment would answer instead; this test only
    // proves the unauthenticated path.
    if (states.items.len == 0) return error.SkipZigTest;
    if (states.items.len < 3 and child.state() == .running) {
        // The relay has proved itself: SessionStart and UserPromptSubmit arrived
        // through the hooks. Claude is still inside its unauthenticated request
        // (network retries, a loaded machine), and the StopFailure that ends it
        // cannot be awaited deterministically, so the rest is not asserted.
        try testing.expectEqualSlices(State, &.{ .idle, .working }, states.items);
        return error.SkipZigTest;
    }
    try testing.expectEqualSlices(State, &.{ .idle, .working, .errored }, states.items);
    try testing.expectEqualStrings("01234567-89ab-4def-8123-456789abcdef", a.sessionId().?);
    try testing.expect(std.mem.startsWith(u8, a.transcriptPath().?, config));
}

test "detection probes the installed version through the execution context" {
    var context = try workspace.ExecutionContext.local(testing.allocator);
    defer context.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const real_path = testing.environ.getAlloc(arena.allocator(), "PATH") catch return error.SkipZigTest;
    const env = [_][]const u8{try std.fmt.allocPrint(arena.allocator(), "PATH={s}", .{real_path})};
    var version: [64]u8 = undefined;

    var missing = try ClaudeCodeAdapter.init(testing.allocator, testing.io, .{ .program = "conduit-no-such-claude", .probe_env = &env });
    defer missing.deinit();
    const absent = missing.adapter().detect(.{ .context = context.borrow(), .version_buffer = &version }) catch |err| switch (err) {
        error.Disconnected => return error.SkipZigTest, // No PTY backend here.
        else => return err,
    };
    try testing.expect(absent == null);

    var real = try ClaudeCodeAdapter.init(testing.allocator, testing.io, .{ .probe_env = &env });
    defer real.deinit();
    const found = (try real.adapter().detect(.{ .context = context.borrow(), .version_buffer = &version })) orelse return error.SkipZigTest;
    try testing.expect(std.ascii.isDigit(found[0]));
    try testing.expect(std.mem.indexOfScalar(u8, found, '.') != null);
}

test "a real interactive claude started by hand is found in the registry, attached, and seen to exit" {
    // Claude Code runs unauthenticated in a private HOME and config dir (it
    // idles at its prompt; no model call), in a PTY exactly as a human's
    // terminal would run it. Skipped where claude is absent.
    var scratch: Scratch = undefined;
    try scratch.init();
    defer scratch.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a_alloc = arena.allocator();
    try scratch.tmp.dir.createDirPath(testing.io, "home/.claude");
    try scratch.tmp.dir.createDirPath(testing.io, "work");
    const config = try std.fmt.allocPrint(a_alloc, "{s}/home/.claude", .{scratch.path});
    const work = try std.fmt.allocPrint(a_alloc, "{s}/work", .{scratch.path});
    // Skip first-run onboarding and the folder trust dialog for this cwd only.
    const seeded = try std.fmt.allocPrint(a_alloc, "{{\"hasCompletedOnboarding\":true,\"projects\":{{\"{s}\":{{\"hasTrustDialogAccepted\":true}}}}}}", .{work});
    try scratch.tmp.dir.writeFile(testing.io, .{ .sub_path = "home/.claude/.claude.json", .data = seeded });

    const real_path = testing.environ.getAlloc(a_alloc, "PATH") catch return error.SkipZigTest;
    const env = [_][]const u8{
        try std.fmt.allocPrint(a_alloc, "PATH={s}", .{real_path}),
        try std.fmt.allocPrint(a_alloc, "HOME={s}/home", .{scratch.path}),
        try std.fmt.allocPrint(a_alloc, "CLAUDE_CONFIG_DIR={s}", .{config}),
        "TERM=xterm-256color",
        "DISABLE_AUTOUPDATER=1",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1",
    };
    var context = try workspace.ExecutionContext.local(testing.allocator);
    defer context.deinit();
    const argv = [_][]const u8{ "claude", "--model", "haiku" };
    const child = context.borrow().spawn(.{ .argv = &argv, .env = &env, .cwd = work, .size = .{ .rows = 40, .cols = 120 } }) catch |err| switch (err) {
        error.ProgramNotFound, error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer child.destroy();

    var a = try ClaudeCodeAdapter.init(testing.allocator, testing.io, .{ .config_dir = config });
    const iface = a.adapter();
    defer iface.destroy();

    // The owner knows the terminal's cwd; the registry names the session.
    var screen: [16 * 1024]u8 = undefined;
    var found: RegisteredSession = undefined;
    var registered = false;
    const registered_by: Deadline = .in(30);
    while (registered_by.pending() and !registered) {
        _ = child.takeBytes(&screen);
        registered = try a.findRunningSession(.{ .cwd = work }, &found);
        if (!registered) _ = child.waitReadable(50);
    }
    try testing.expect(registered);
    try iface.attach(.{ .session = .first, .token = fixtureToken(), .harness_session_id = found.session_id.text() });

    var queue = try event.EventQueue.init(testing.allocator, testing.io, 16);
    defer queue.deinit(testing.allocator);
    const out = try testing.allocator.alloc(event.StoredEvent, 16);
    defer testing.allocator.free(out);
    var status: ?State = null;
    const status_by: Deadline = .in(20);
    while (status_by.pending() and status == null) {
        _ = child.takeBytes(&screen);
        _ = try iface.poll(&queue);
        const n = queue.drain(out);
        for (out[0..n]) |*stored| if (stored.event == .status_change) {
            status = stored.event.status_change.state;
        };
        if (status == null) _ = child.waitReadable(50);
    }
    try testing.expect(status != null);

    // The human closes the terminal: the session leaves the registry and the
    // adapter reports its channel gone.
    try child.kill(.hangup);
    var disconnected = false;
    const exit_by: Deadline = .in(30);
    while (exit_by.pending() and !disconnected) {
        _ = child.takeBytes(&screen);
        _ = iface.poll(&queue) catch |err| switch (err) {
            error.Disconnected => {
                disconnected = true;
                break;
            },
            else => return err,
        };
        _ = queue.drain(out);
        _ = child.waitReadable(50);
    }
    try testing.expect(disconnected);
}

// SSH workspaces (TASK-61) ------------------------------------------------------

test "the config directory is resolved in the context's own environment" {
    // The resolution is a POSIX `/bin/sh` script over the context, and the
    // expectation is read from the POSIX environment.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var context = try workspace.ExecutionContext.local(testing.allocator);
    defer context.deinit();
    var buffer: [Dir.max_path_bytes]u8 = undefined;
    const resolved = try resolveConfigDir(context.borrow(), testing.allocator, testing.io, &buffer);
    var expected_buffer: [Dir.max_path_bytes]u8 = undefined;
    const configured = testing.environ.getPosix("CLAUDE_CONFIG_DIR") orelse "";
    const home = testing.environ.getPosix("HOME") orelse "";
    const expected: ?[]const u8 = if (configured.len > 1 and configured[0] == '/')
        std.mem.trimEnd(u8, configured, "/")
    else if (home.len > 1 and home[0] == '/')
        try std.fmt.bufPrint(&expected_buffer, "{s}/.claude", .{std.mem.trimEnd(u8, home, "/")})
    else
        null;
    if (expected) |want| try testing.expectEqualStrings(want, resolved.?) else try testing.expect(resolved == null);
    var tiny: [2]u8 = undefined;
    if (expected != null) try testing.expectError(error.NoSpaceLeft, resolveConfigDir(context.borrow(), testing.allocator, testing.io, &tiny));
}

/// The events of a remote agent, in order: `until` returns the next one of
/// a kind, polling, bounded, when the drained batch has none. Each poll is
/// one or two exec channels to the remote host, which bounds a round without
/// a sleep. A returned event is valid until the next `until`.
const RemoteFeed = struct {
    iface: api.Adapter,
    queue: *event.EventQueue,
    out: []event.StoredEvent,
    len: usize = 0,
    pos: usize = 0,

    fn until(self: *RemoteFeed, want: Event.Kind) !?*event.StoredEvent {
        const deadline: Deadline = .in(30);
        while (true) {
            while (self.pos < self.len) {
                const stored = &self.out[self.pos];
                self.pos += 1;
                if (std.meta.activeTag(stored.event) == want) return stored;
            }
            if (!deadline.pending()) return null;
            _ = try self.iface.poll(self.queue);
            self.len = self.queue.drain(self.out);
            self.pos = 0;
        }
    }
};

test "in an SSH workspace the sink lives on the remote host: launch writes it, the remote relay reports through it, and an answer unblocks the relay there" {
    const remote = (try workspace.ssh.TestRemote.start()) orelse return error.SkipZigTest;
    defer remote.stop();
    const ref = remote.ref();
    const io = testing.io;

    // The sink is under the remote user's state directory, as part two of
    // TASK-61 places it; the owner creates it private before `launch`.
    var state_buffer: [Dir.max_path_bytes]u8 = undefined;
    const state = try ref.stateDir(io, &state_buffer);
    var sink_buffer: [Dir.max_path_bytes]u8 = undefined;
    const sink = try std.fmt.bufPrint(&sink_buffer, "{s}/conduit/agents/run-1/agent-1", .{state});
    try testing.expectEqualStrings(workspace.ssh.TestRemote.home ++ "/.local/state/conduit/agents/run-1/agent-1", sink);
    try ref.makePrivateDir(io, sink);
    const config = workspace.ssh.TestRemote.home ++ "/.claude";
    var config_buffer: [Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(config, (try resolveConfigDir(ref, testing.allocator, io, &config_buffer)).?);

    var a = try ClaudeCodeAdapter.init(testing.allocator, io, .{
        .sink_dir = sink,
        .config_dir = config,
        .sink_io = SinkIo.forContext(ref, .{ .idle_read_interval_ms = 0 }),
    });
    const iface = a.adapter();
    defer iface.destroy();
    try testing.expect(a.sink.isRemote());
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spec = try iface.launch(arena.allocator(), .{ .context_kind = .ssh, .cwd = workspace.ssh.TestRemote.project, .token = fixtureToken() });
    var settings_buffer: [Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&settings_buffer, "{s}/settings.json", .{sink}), spec.argv[2]);

    // The launch files exist on the remote host, private, and nowhere here.
    var modes = try remote.run(&.{ "sh", "-c", "cd \"$0\" && stat -c '%a %n' . decisions tmp hook.sh settings.json events.jsonl", sink }, null);
    defer modes.deinit(testing.allocator);
    try testing.expectEqualStrings("700 .\n700 decisions\n700 tmp\n600 hook.sh\n600 settings.json\n600 events.jsonl\n", modes.stdout);
    try testing.expectError(error.FileNotFound, Dir.cwd().statFile(io, sink, .{}));
    var file_buffer: [16 * 1024]u8 = undefined;
    var expected_settings: Io.Writer.Allocating = .init(testing.allocator);
    defer expected_settings.deinit();
    try writeSettings(&expected_settings.writer, sink);
    try testing.expectEqualStrings(expected_settings.written(), try ref.readFile(io, settings_buffer[0 .. sink.len + "/settings.json".len], &file_buffer));

    // A transcript where Claude Code keeps it, and a SessionStart hook run
    // remotely exactly as the settings say: the relay appends to the remote
    // sink, `poll` reads it over the connection and follows the transcript
    // the hook names, also over the connection (AC2, AC3).
    const session = SessionId.fromToken(fixtureToken());
    var transcript_buffer: [Dir.max_path_bytes]u8 = undefined;
    const transcript = try std.fmt.bufPrint(&transcript_buffer, config ++ "/projects/-home-conduit-project/{s}.jsonl", .{session.text()});
    try ref.writeFile(io, transcript, fixture_transcript, sink_io.private_file_mode);
    var payload_buffer: [2048]u8 = undefined;
    const start_payload = try std.fmt.bufPrint(&payload_buffer, "{{\"session_id\":\"{s}\",\"transcript_path\":\"{s}\",\"source\":\"startup\",\"hook_event_name\":\"SessionStart\"}}", .{ session.text(), transcript });
    var relay_path_buffer: [Dir.max_path_bytes]u8 = undefined;
    const relay = try std.fmt.bufPrint(&relay_path_buffer, "{s}/hook.sh", .{sink});
    var started = try remote.run(&.{ "env", "CONDUIT_AGENT_TOKEN=" ++ fixture_token, "/bin/sh", relay, "SessionStart" }, start_payload);
    defer started.deinit(testing.allocator);
    try testing.expect(started.succeeded());

    var queue = try event.EventQueue.init(testing.allocator, io, 16);
    defer queue.deinit(testing.allocator);
    const out = try testing.allocator.alloc(event.StoredEvent, 16);
    defer testing.allocator.free(out);
    var feed: RemoteFeed = .{ .iface = iface, .queue = &queue, .out = out };
    const idle = (try feed.until(.status_change)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(State.idle, idle.event.status_change.state);
    const message = (try feed.until(.message)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("read the build", message.event.message.text);
    try testing.expectEqualStrings(transcript, a.transcriptPath().?);

    // A permission request from the remote relay, which then waits on the
    // remote host for the answer: run it in a remote session the way Claude
    // Code runs a hook, with the hook input on stdin.
    var payload_path_buffer: [Dir.max_path_bytes]u8 = undefined;
    const payload_path = try std.fmt.bufPrint(&payload_path_buffer, "{s}/tmp/payload.json", .{sink});
    try ref.writeFile(io, payload_path, fixture_permission, sink_io.private_file_mode);
    var command_buffer: [Dir.max_path_bytes * 2]u8 = undefined;
    var command: Io.Writer = .fixed(&command_buffer);
    try writeHookCommand(&command, sink, .permission_request);
    try command.print(" < '{s}'", .{payload_path});
    const child = try ref.spawn(.{
        .argv = &.{ "/bin/sh", "-c", command.buffered() },
        .env = &.{"CONDUIT_AGENT_TOKEN=" ++ fixture_token},
        .cwd = workspace.ssh.TestRemote.project,
        .size = .{ .rows = 24, .cols = 200 },
    });
    defer child.destroy();

    const request = (try feed.until(.permission_request)) orelse return error.TestUnexpectedResult;
    var id_buffer: [64]u8 = undefined;
    const id = id_buffer[0..request.event.permission_request.id.len];
    @memcpy(id, request.event.permission_request.id);
    try testing.expectEqualStrings("Bash: touch probe_file", request.event.permission_request.title);
    // Still blocked on the remote host.
    var output: [1024]u8 = undefined;
    var len = child.takeBytes(&output);
    try testing.expect(child.state() == .running);

    // The answer crosses the connection atomically, the remote relay takes
    // it, prints Claude Code's reply and reports the outcome to the sink.
    try iface.respondPermission(id, "allow");
    const resolved = (try feed.until(.permission_resolved)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(event.PermissionOutcome.allowed, resolved.event.permission_resolved.outcome);
    const deadline: Deadline = .in(20);
    while (deadline.pending() and len < output.len) {
        const took = child.takeBytes(output[len..]);
        len += took;
        if (took == 0 and child.state() != .running) break;
        if (took == 0) _ = child.waitReadable(50);
    }
    try testing.expect(std.mem.indexOf(u8, output[0..len], permissionReply(.allow)) != null);
    var answer_buffer: [Dir.max_path_bytes]u8 = undefined;
    try testing.expectError(error.NotFound, ref.statPath(io, try std.fmt.bufPrint(&answer_buffer, "{s}/decisions/{s}", .{ sink, id })));
}
