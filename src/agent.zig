//! The coding agents Conduit manages, and the boundary around them.
//!
//! `agent` owns the common adapter interface — detect, launch, attach,
//! observe state, send input, answer permission requests, read and write the
//! prompt where supported, stop — the typed event stream every adapter
//! produces, the agent state model, the registry of agents per workspace, the
//! harness-neutral PTY heuristics, and (from TASK-53 on) the harness adapters.
//! Nothing outside this module may special-case a harness (P11, invariant 9),
//! and no transcript, prompt or permission text may trigger an action without
//! an explicit user gesture (§11). An agent never owns, targets or observes
//! the scratchpad (P9, invariant 7); its own PTYs are `agent_terminal`
//! sessions spawned through the workspace's ExecutionContext (P7), which is
//! why `Adapter.launch` describes a process instead of starting one.
//! decision-7 records the strategy: the TUI always runs in a Conduit PTY, an
//! adapter adds the harness's structured side channel, and PTY heuristics are
//! the baseline every agent has.
//!
//! Layout: `agent/state.zig` (states and the transition table),
//! `agent/event.zig` (events and the bounded hand-over queue),
//! `agent/adapter.zig` (the interface), `agent/registry.zig` (agents per
//! workspace), `agent/heuristics.zig` (the PTY baseline),
//! `agent/harness.zig` (the closed harness set), `agent/fake.zig` (the
//! scripted adapter tests use) and `agent/sink_io.zig` (the harness-neutral
//! IO under the sink channels, Local or through a remote context, TASK-61)
//! and `agent/poll.zig` (readiness waits on the transports' descriptors).
//!
//! It may depend on `config`, `input`, `session`, `theme`, `ui` and
//! `workspace` (`build.zig`); today it imports only `session` and `workspace`,
//! for their identity types and the ExecutionContext capability. It makes no
//! OS calls of its own.
//!
//! Threads and memory are documented per file: adapter IO runs on workers,
//! events cross to the owner thread through `EventQueue`, and the registry and
//! heuristics are owner-thread state. Every allocation takes an explicit
//! allocator and every buffer is bounded.

const std = @import("std");
const state = @import("agent/state.zig");
const event = @import("agent/event.zig");
const adapter = @import("agent/adapter.zig");
const registry = @import("agent/registry.zig");
const heuristics = @import("agent/heuristics.zig");

pub const Harness = @import("agent/harness.zig").Harness;

pub const State = state.State;
pub const Source = state.Source;
pub const canTransition = state.canTransition;
pub const transition = state.transition;

pub const Event = event.Event;
pub const Role = event.Role;
pub const Message = event.Message;
pub const ToolUse = event.ToolUse;
pub const FileReference = event.FileReference;
pub const Decision = event.Decision;
pub const DecisionKind = event.DecisionKind;
pub const PermissionRequest = event.PermissionRequest;
pub const PermissionResolved = event.PermissionResolved;
pub const PermissionOutcome = event.PermissionOutcome;
pub const StatusChange = event.StatusChange;
pub const Subagent = event.Subagent;
pub const Notification = event.Notification;
pub const ExitStatus = event.ExitStatus;
pub const StoredEvent = event.StoredEvent;
pub const EventQueue = event.EventQueue;
pub const truncateUtf8 = event.truncateUtf8;

pub const Adapter = adapter.Adapter;
pub const AdapterError = adapter.Error;
pub const Capabilities = adapter.Capabilities;
pub const CorrelationToken = adapter.CorrelationToken;
pub const correlation_env_name = adapter.correlation_env_name;
pub const DetectRequest = adapter.DetectRequest;
pub const LaunchRequest = adapter.LaunchRequest;
pub const LaunchSpec = adapter.LaunchSpec;
pub const AttachRequest = adapter.AttachRequest;
pub const InstructionSource = adapter.InstructionSource;
pub const InstructionApply = adapter.InstructionApply;
pub const InstructionProfile = adapter.InstructionProfile;

pub const AgentId = registry.AgentId;
pub const Agent = registry.Agent;
pub const Ownership = registry.Ownership;
pub const Binding = registry.Binding;
pub const CreateRequest = registry.CreateRequest;
pub const Applied = registry.Applied;
pub const Registry = registry.Registry;

pub const Heuristics = heuristics.Heuristics;
pub const Observation = heuristics.Observation;

pub const FakeAdapter = @import("agent/fake.zig").FakeAdapter;
/// The scripted fake's own program name, which only checks recognize.
pub const fake_command_name = @import("agent/fake.zig").command_name;
pub const recognizeFakeCommand = @import("agent/fake.zig").recognizeCommand;

/// The harness adapters. Each lives in its own file so the adapter tasks
/// (TASK-53, 54, 55, 78) can land independently; a file that is still a stub
/// exports nothing beyond its tests.
pub const claude_code = @import("agent/claude_code.zig");
pub const codex = @import("agent/codex.zig");
pub const pi = @import("agent/pi.zig");
pub const opencode = @import("agent/opencode.zig");

/// The harness-neutral IO under the sink-based side channels: this machine's
/// files, or a remote workspace's through its ExecutionContext (TASK-61).
pub const sink_io = @import("agent/sink_io.zig");
pub const SinkIo = sink_io.SinkIo;

/// Where `harness` reads its instructions and how a change reaches an agent
/// (TASK-59), as its adapter documents it: the one place outside an adapter
/// that maps a harness to its harness knowledge.
pub fn instructionProfile(harness: Harness) InstructionProfile {
    return switch (harness) {
        .claude_code => claude_code.instruction_profile,
        .codex => codex.instruction_profile,
        .pi => pi.instruction_profile,
        .opencode => opencode.instruction_profile,
    };
}
/// Interpreters whose script, not their own name, says which program runs:
/// npm installs harness launchers as `#!/usr/bin/env node` scripts (on
/// Windows, `.cmd`/`.ps1` shims that run `node.exe <package>\cli.js`), so a
/// terminal's foreground job reads `node /usr/lib/node_modules/.../codex`.
const interpreters = [_][]const u8{ "node", "nodejs", "bun", "deno", "python", "python3", "sh", "bash", "dash", "zsh" };

/// POSIX shells whose `-c` takes a command string rather than a script.
const posix_shells = [_][]const u8{ "sh", "bash", "dash", "zsh" };

/// Extensions a program name is spelled without: Windows executables and
/// shims, and the script files npm points them at.
const program_extensions = [_][]const u8{ ".exe", ".cmd", ".bat", ".ps1", ".js", ".mjs", ".cjs" };

/// PowerShell options that take a value, so the word after them is not the
/// command (`-ExecutionPolicy Bypass`), by name and documented alias.
const powershell_valued = [_][]const u8{
    "-executionpolicy",  "-ep",                "-ex",            "-exec",
    "-workingdirectory", "-wd",                "-windowstyle",   "-w",
    "-outputformat",     "-of",                "-o",             "-inputformat",
    "-if",               "-configurationname", "-settingsfile",  "-custompipename",
    "-version",          "-v",                 "-psconsolefile",
};

/// How many wrappers deep a name is followed (`cmd /c pwsh -Command claude`).
const max_wrapper_depth = 4;

/// The program a foreground process runs, as the name that identifies it:
/// `argv0`'s basename, or for an interpreter its script's, or for a shell
/// that runs a command (`cmd /c`, `pwsh -Command|-File`, `sh -c`) that
/// command's. `rest` is every later word, NUL-separated
/// (`pty.ForegroundProcess.argv1`). Names are matched without regard to the
/// path separator (`/` or `\`), and lose a Windows or script extension
/// (`claude.exe`, `claude.cmd`, `cli.js`); a script inside `node_modules` is
/// named by its npm package (`@anthropic-ai/claude-code`), since its own
/// file name is often only `cli`. Case is kept: `recognize` ignores it.
/// Borrows its arguments; harness-neutral, and the same on every platform.
pub fn commandName(argv0: []const u8, rest: []const u8) []const u8 {
    var words: Words = .{ .text = rest };
    return nameOf(argv0, &words, max_wrapper_depth);
}

/// Words of a command line: NUL-separated as the OS reports them, or, inside
/// a command string a shell parses again, also separated by spaces and tabs,
/// with a quoted word taken between its quotes.
const Words = struct {
    text: []const u8,
    spaces: bool = false,

    fn separator(self: Words, c: u8) bool {
        return c == 0 or (self.spaces and (c == ' ' or c == '\t'));
    }

    fn next(self: *Words) ?[]const u8 {
        var i: usize = 0;
        while (i < self.text.len and self.separator(self.text[i])) i += 1;
        if (i >= self.text.len) {
            self.text = "";
            return null;
        }
        if (self.spaces and (self.text[i] == '"' or self.text[i] == '\'')) {
            const quote = self.text[i];
            const start = i + 1;
            const close = std.mem.indexOfScalarPos(u8, self.text, start, quote) orelse self.text.len;
            const word = self.text[start..close];
            self.text = self.text[@min(close + 1, self.text.len)..];
            return word;
        }
        const start = i;
        while (i < self.text.len and !self.separator(self.text[i])) i += 1;
        const word = self.text[start..i];
        self.text = self.text[i..];
        return word;
    }

    /// The unread words as one command string a shell parses again.
    fn commandString(self: Words) Words {
        return .{ .text = self.text, .spaces = true };
    }
};

fn isOneOf(name: []const u8, comptime list: []const []const u8) bool {
    for (list) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

/// A path's last component, after either separator, without a known
/// extension.
fn programName(path: []const u8) []const u8 {
    const cut = std.mem.lastIndexOfAny(u8, path, "/\\");
    const base = if (cut) |at| path[at + 1 ..] else path;
    for (program_extensions) |extension| {
        if (base.len > extension.len and std.ascii.endsWithIgnoreCase(base, extension)) {
            return base[0 .. base.len - extension.len];
        }
    }
    return base;
}

/// What a script path names: its npm package when it lives in one
/// (`.../node_modules/@scope/name/...` or `.../node_modules/name/...`, the
/// last `node_modules` winning), otherwise its program name.
fn scriptName(path: []const u8) []const u8 {
    var package: ?[]const u8 = null;
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    var after_modules = false;
    while (parts.next()) |part| {
        if (after_modules) {
            after_modules = false;
            if (part[0] == '@') {
                const scope_start = @intFromPtr(part.ptr) - @intFromPtr(path.ptr);
                const name = parts.next() orelse break;
                const end = @intFromPtr(name.ptr) - @intFromPtr(path.ptr) + name.len;
                package = path[scope_start..end];
            } else {
                package = part;
            }
            continue;
        }
        if (std.ascii.eqlIgnoreCase(part, "node_modules")) after_modules = true;
    }
    return package orelse programName(path);
}

fn nameOf(program: []const u8, words: *Words, depth: usize) []const u8 {
    const name = programName(program);
    if (depth == 0) return name;
    if (std.ascii.eqlIgnoreCase(name, "cmd")) {
        // `cmd [/d /s /q ...] /c|/k <command line>`.
        while (words.next()) |word| {
            if (std.ascii.eqlIgnoreCase(word, "/c") or std.ascii.eqlIgnoreCase(word, "/k")) {
                var command = words.commandString();
                const first = command.next() orelse return name;
                return nameOf(first, &command, depth - 1);
            }
            if (word.len == 0 or word[0] != '/') return name;
        }
        return name;
    }
    if (std.ascii.eqlIgnoreCase(name, "powershell") or std.ascii.eqlIgnoreCase(name, "pwsh")) {
        while (words.next()) |word| {
            if (word.len == 0 or word[0] != '-') {
                // A bare word is the command (Windows PowerShell) or the
                // script file (pwsh); either way it names the program.
                var command: Words = .{ .text = word, .spaces = true };
                const first = command.next() orelse return name;
                return nameOf(first, &command, depth - 1);
            }
            if (powershellSwitch(word, "-command", 2) or powershellSwitch(word, "-file", 2)) {
                var command = words.commandString();
                var first = command.next() orelse return name;
                // `-Command & 'C:\path\claude.ps1'`: the call operator.
                if (std.mem.eql(u8, first, "&")) first = command.next() orelse return name;
                return nameOf(first, &command, depth - 1);
            }
            if (isOneOf(word, &powershell_valued)) _ = words.next();
        }
        return name;
    }
    for (interpreters) |interpreter| {
        if (!std.ascii.eqlIgnoreCase(name, interpreter)) continue;
        const script = words.next() orelse return name;
        if (std.mem.eql(u8, script, "-c") and isOneOf(name, &posix_shells)) {
            var command = words.commandString();
            const first = command.next() orelse return name;
            return nameOf(first, &command, depth - 1);
        }
        // A login shell's argv0 starts with '-' and is never an
        // interpreter; an option first (`node -e`) leaves the interpreter.
        if (script.len == 0 or script[0] == '-') return name;
        return scriptName(script);
    }
    return name;
}

/// A PowerShell switch as typed: any unambiguous prefix of `full` at least
/// `min` letters after the dash, in any case (`-c`, `-Com`, `-COMMAND`).
fn powershellSwitch(word: []const u8, full: []const u8, min: usize) bool {
    return word.len >= min and word.len <= full.len and std.ascii.startsWithIgnoreCase(full, word);
}

/// Which harness a foreground program name (`commandName`) is, by each
/// adapter's own spelling, or null. Lets the app classify a process the human
/// started in their own terminal (observed agents, TASK-56) without knowing
/// any harness's name itself.
pub fn recognize(name: []const u8) ?Harness {
    if (claude_code.recognizeCommand(name)) return .claude_code;
    if (codex.recognizeCommand(name)) return .codex;
    if (pi.recognizeCommand(name) != null) return .pi;
    if (opencode.recognizeCommand(name)) return .opencode;
    return null;
}

/// Bounded readiness waits on the pipes and sockets the adapters speak over,
/// the one place the agent layer asks the OS (TASK-5).
pub const poll = @import("agent/poll.zig");

test "foreground programs are named through interpreters and recognized by each adapter's spelling" {
    const testing = std.testing;
    try testing.expectEqualStrings("claude", commandName("/home/u/.local/bin/claude", "--resume"));
    try testing.expectEqualStrings("@openai/codex", commandName("node", "/usr/lib/node_modules/@openai/codex/bin/codex"));
    try testing.expectEqualStrings("opencode-ai", commandName("/usr/bin/node", "/usr/local/lib/node_modules/opencode-ai/bin/opencode"));
    try testing.expectEqualStrings("@mariozechner/pi-coding-agent", commandName("node", "/home/u/.nvm/lib/node_modules/@mariozechner/pi-coding-agent/dist/cli.js\x00--continue"));
    try testing.expectEqualStrings("conduit-fake-agent", commandName("/bin/sh", "/tmp/x/conduit-fake-agent"));
    try testing.expectEqualStrings("node", commandName("node", "-e"));
    try testing.expectEqualStrings("bash", commandName("bash", ""));
    try testing.expectEqualStrings("-bash", commandName("-bash", ""));
    try testing.expectEqualStrings("claude", commandName("sh", "-c\x00claude --resume"));

    try testing.expectEqual(Harness.claude_code, recognize("claude").?);
    try testing.expectEqual(Harness.codex, recognize("codex").?);
    try testing.expectEqual(Harness.pi, recognize("pi").?);
    try testing.expectEqual(Harness.pi, recognize("omp").?);
    try testing.expectEqual(Harness.opencode, recognize("opencode").?);
    try testing.expectEqual(Harness.codex, recognize("@openai/codex").?);
    try testing.expectEqual(Harness.opencode, recognize("opencode-ai").?);
    try testing.expectEqual(Harness.pi, recognize("@mariozechner/pi-coding-agent").?);
    for ([_][]const u8{ "bash", "vim", "claude-code", "pip", "", "conduit-fake-agent", "@anthropic-ai", "@openai/codex-sdk", "opencode-ai-x" }) |other| {
        try testing.expect(recognize(other) == null);
    }
    // The fake is recognized only by its own spelling, never as a harness.
    try testing.expect(recognizeFakeCommand(fake_command_name));
    try testing.expect(!recognizeFakeCommand("claude"));
}

/// The harness a Windows command line names, through `commandName` and
/// `recognize` exactly as the app asks (TASK-81).
fn recognizeWindows(argv0: []const u8, rest: []const u8) ?Harness {
    return recognize(commandName(argv0, rest));
}

test "Windows spellings of harnesses are named through shims, runtimes and shell wrappers" {
    const testing = std.testing;
    // A native or bun-compiled harness, in any case.
    try testing.expectEqual(Harness.claude_code, recognizeWindows("C:\\Users\\u\\.local\\bin\\claude.exe", "").?);
    try testing.expectEqual(Harness.claude_code, recognizeWindows("CLAUDE.EXE", "--resume").?);
    try testing.expectEqual(Harness.pi, recognizeWindows("C:\\Users\\u\\.bun\\bin\\omp.exe", "").?);
    try testing.expectEqual(Harness.opencode, recognizeWindows("C:\\Users\\u\\AppData\\Roaming\\npm\\node_modules\\opencode-ai\\node_modules\\opencode-windows-x64\\bin\\opencode.exe", "").?);

    // npm's `claude.cmd` shim runs node with the package's cli.js.
    try testing.expectEqualStrings("@anthropic-ai\\claude-code", commandName(
        "C:\\Program Files\\nodejs\\node.exe",
        "C:\\Users\\u\\AppData\\Roaming\\npm\\node_modules\\@anthropic-ai\\claude-code\\cli.js",
    ));
    try testing.expectEqual(Harness.claude_code, recognizeWindows(
        "C:\\Program Files\\nodejs\\node.exe",
        "C:\\Users\\u\\AppData\\Roaming\\npm\\node_modules\\@anthropic-ai\\claude-code\\cli.js\x00--resume",
    ).?);
    try testing.expectEqual(Harness.codex, recognizeWindows(
        "node.exe",
        "C:\\Users\\u\\AppData\\Roaming\\npm\\node_modules\\@openai\\codex\\bin\\codex.js",
    ).?);
    try testing.expectEqual(Harness.pi, recognizeWindows(
        "NODE.EXE",
        "C:\\Users\\u\\AppData\\Roaming\\npm\\node_modules\\@mariozechner\\pi-coding-agent\\dist\\cli.js",
    ).?);
    // The shim itself, when it is what runs.
    try testing.expectEqual(Harness.claude_code, recognizeWindows("C:\\Users\\u\\AppData\\Roaming\\npm\\claude.cmd", "").?);
    try testing.expectEqual(Harness.codex, recognizeWindows("bun", "C:\\Users\\u\\.bun\\bin\\codex.js").?);

    // `cmd /c` and PowerShell's -Command and -File run the program named after them.
    try testing.expectEqual(Harness.claude_code, recognizeWindows("cmd.exe", "/c\x00claude").?);
    try testing.expectEqual(Harness.claude_code, recognizeWindows("C:\\Windows\\system32\\cmd.exe", "/d\x00/s\x00/c\x00\"claude.cmd\" --resume").?);
    try testing.expectEqual(Harness.claude_code, recognizeWindows("cmd", "/C\x00claude --resume").?);
    try testing.expectEqual(Harness.claude_code, recognizeWindows("pwsh", "-Command\x00claude").?);
    try testing.expectEqual(Harness.claude_code, recognizeWindows("pwsh.exe", "-NoProfile\x00-ExecutionPolicy\x00Bypass\x00-c\x00claude --resume").?);
    try testing.expectEqual(Harness.claude_code, recognizeWindows("powershell.exe", "-NoLogo\x00-Command\x00& 'C:\\Users\\u\\AppData\\Roaming\\npm\\claude.ps1'").?);
    try testing.expectEqual(Harness.codex, recognizeWindows("pwsh", "-File\x00C:\\Users\\u\\AppData\\Roaming\\npm\\codex.ps1").?);
    try testing.expectEqual(Harness.opencode, recognizeWindows("powershell", "opencode").?);
    try testing.expectEqual(Harness.claude_code, recognizeWindows("cmd.exe", "/c\x00pwsh -c claude").?);

    // Plain shells, and shells running something else, are no harness.
    for ([_][2][]const u8{
        .{ "cmd.exe", "" },
        .{ "C:\\Windows\\System32\\cmd.exe", "/Q" },
        .{ "pwsh.exe", "-NoLogo" },
        .{ "powershell.exe", "" },
        .{ "pwsh", "-NoProfile\x00-Command\x00Get-ChildItem" },
        .{ "cmd", "/c\x00dir" },
        .{ "cmd", "/c" },
        .{ "pwsh", "-c" },
        .{ "pwsh", "-Command\x00\"\"" },
        .{ "cmd", "/c\x00\"\"" },
        .{ "C:\\bin\\sh", "-c" },
        .{ "node.exe", "" },
        .{ "node.exe", "C:\\work\\server.js" },
        .{ "", "" },
    }) |line| {
        try testing.expect(recognizeWindows(line[0], line[1]) == null);
    }
    // The wrappers lead back to the shell's name, so the fake's MSYS `sh` is named as on POSIX.
    try testing.expectEqualStrings("cmd", commandName("C:\\Windows\\System32\\cmd.exe", "/Q"));
    try testing.expectEqualStrings("conduit-fake-agent", commandName("C:\\bin\\sh", "/tmp/conduit-agent-test-1/conduit-fake-agent"));
    try testing.expectEqualStrings("conduit-fake-agent", commandName("/usr/bin/sh", "C:\\tmp\\conduit-agent-test-1\\conduit-fake-agent"));
    // A pathological chain of wrappers ends.
    try testing.expectEqualStrings("cmd", commandName("cmd", "/c\x00cmd /c cmd /c cmd /c cmd /c cmd /c claude"));
}

test {
    _ = @import("agent/harness.zig");
    _ = state;
    _ = event;
    _ = adapter;
    _ = registry;
    _ = heuristics;
    _ = @import("agent/fake.zig");
    _ = claude_code;
    _ = codex;
    _ = pi;
    _ = opencode;
    _ = sink_io;
    _ = poll;
}
